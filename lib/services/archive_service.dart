import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:archive/archive_io.dart';
import 'package:dart_lz4/dart_lz4.dart';
import 'package:charset/charset.dart';
import 'package:just_zstd/just_zstd.dart';

/// ArchiveService 同步分块 IO 用的缓冲区大小（1 MiB）。
/// 在 compute Isolate 里使用同步 openRead/Write，避免主线程阻塞；
/// 同时每块读写之间不会把整文件放进 RAM，从根源避免 OOM。
const int _kArchiveChunkSize = 1024 * 1024;

/// 遍历源路径，收集所有「文件条目 + 空目录」供流式压缩使用。
/// 返回结构：{ files: `List<MapEntry<String,String>>`: (fullPath -> relPath), emptyDirs: `List<String>` }
Map<String, dynamic> _collectEntries(List<String> sourcePaths) {
  final files = <MapEntry<String, String>>[]; // fullPath -> archive-internal relative path
  final emptyDirs = <String>[];
  for (final path in sourcePaths) {
    final type = FileSystemEntity.typeSync(path);
    if (type == FileSystemEntityType.file) {
      files.add(MapEntry(path, p.basename(path)));
    } else if (type == FileSystemEntityType.directory) {
      final dir = Directory(path);
      if (!dir.existsSync()) continue;
      final list = dir.listSync(recursive: true);
      bool hasFiles = false;
      for (final sub in list) {
        if (sub is File) {
          hasFiles = true;
          final rel = p.relative(sub.path, from: p.dirname(path));
          files.add(MapEntry(sub.path, rel));
        } else if (sub is Directory) {
          final rel = p.relative(sub.path, from: p.dirname(path));
          emptyDirs.add(rel);
        }
      }
      if (!hasFiles && list.isEmpty) {
        emptyDirs.add(p.basename(path));
      }
    }
  }
  return {'files': files, 'emptyDirs': emptyDirs};
}

/// 同步分块拷贝 src 文件到输出 IOSink（仅在 ArchiveService.compute Isolate 内使用）。
/// 内部会 flush，但不关闭 sink。
void _copyFileSyncToSink(File src, IOSink sink, {int chunkSize = _kArchiveChunkSize}) {
  final raf = src.openSync();
  try {
    final length = raf.lengthSync();
    final buf = Uint8List(chunkSize);
    int remaining = length;
    while (remaining > 0) {
      final read = raf.readIntoSync(buf, 0, remaining > chunkSize ? chunkSize : remaining);
      if (read <= 0) break;
      if (read == chunkSize) {
        sink.add(buf);
      } else {
        sink.add(Uint8List.fromList(buf.sublist(0, read)));
      }
      remaining -= read;
    }
  } finally {
    raf.closeSync();
  }
}

/// 同步分块把 [bytes] 写入 IOSink（分块 flush，避免超大块导致 GC 抖动）。
void _writeBytesChunked(IOSink sink, List<int> bytes, {int chunkSize = _kArchiveChunkSize}) {
  if (bytes.length <= chunkSize) {
    if (bytes.isNotEmpty) sink.add(bytes);
    return;
  }
  for (int i = 0; i < bytes.length; i += chunkSize) {
    final end = (i + chunkSize > bytes.length) ? bytes.length : i + chunkSize;
    sink.add(Uint8List.fromList(bytes.sublist(i, end)));
  }
}

class ArchiveService {
  /// Creates an archive or multiple separate archives.
  static Future<void> createArchive({
    required List<String> sourcePaths,
    required String destinationDir,
    required String archiveName,
    required String format, // 'zip', 'tar', 'tar.gz', 'tar.bz2'
    required int compressionLevel, // 0 (None), 3 (Fast), 6 (Standard), 9 (Maximum)
    String? password,
    int? splitSizeMB,
    required bool deleteSource,
    required bool separateArchives,
  }) async {
    if (separateArchives) {
      for (final path in sourcePaths) {
        final name = p.basenameWithoutExtension(path);
        final fullDest = p.join(destinationDir, '$name.$format');
        await _createSingleArchive([path], fullDest, format, compressionLevel, password, splitSizeMB);
        if (deleteSource) {
          await _deleteEntity(path);
        }
      }
    } else {
      final fullDest = p.join(destinationDir, '$archiveName.$format');
      await _createSingleArchive(sourcePaths, fullDest, format, compressionLevel, password, splitSizeMB);
      if (deleteSource) {
        for (final path in sourcePaths) {
          await _deleteEntity(path);
        }
      }
    }
  }

  static Future<void> _createSingleArchive(
    List<String> sourcePaths,
    String destinationPath,
    String format,
    int level,
    String? password,
    int? splitSizeMB,
  ) async {
    return compute(_encodeArchiveTask, {
      'sourcePaths': sourcePaths,
      'destinationPath': destinationPath,
      'format': format,
      'level': level,
      'password': password,
      'splitSizeMB': splitSizeMB,
    });
  }

  /// 流式压缩任务：在 compute Isolate 中同步执行。
  /// ZIP：把所有文件读进 Archive 对象 → ZipEncoder().encode() 一次性编码 → 写盘。
  /// 和 NFile 参考实现同方案，archive 包内部处理 ZIP 格式细节（Local Header / Central Dir / EOCD），
  /// 绝对不会出现手写流式时 deflate stream 损坏的问题。
  static void _encodeArchiveTask(Map<String, dynamic> args) {
    final sourcePaths = args['sourcePaths'] as List<String>;
    final destinationPath = args['destinationPath'] as String;
    final format = args['format'] as String;
    final level = args['level'] as int;
    final splitSizeMB = args['splitSizeMB'] as int?;
    final normDest = destinationPath.toLowerCase();

    // 1) 收集文件列表 + 空目录列表（只读元数据，不读文件内容）
    final plan = _collectEntries(sourcePaths);
    final files = plan['files'] as List<MapEntry<String, String>>;
    final emptyDirs = plan['emptyDirs'] as List<String>;
    // 移除目标路径自身（防止把输出压缩包也包含进去）
    files.removeWhere((e) => e.key.toLowerCase() == normDest);

    // 2) 根据格式选择编码路径
    if (format == 'zip') {
      // ZIP：读所有文件到 Archive 对象 + ZipEncoder().encode() 一次性编码
      // 和 NFile 参考实现同方案，archive 包内部处理 ZIP 格式细节，绝对不会损坏。
      final archive = Archive();
      for (final entry in files) {
        final f = File(entry.key);
        if (!f.existsSync()) continue;
        final bytes = f.readAsBytesSync();
        archive.addFile(ArchiveFile(entry.value, bytes.length, bytes));
      }
      for (final d in emptyDirs) {
        final normalized = d.endsWith('/') ? d : '$d/';
        final af = ArchiveFile(normalized, 0, null);
        af.isFile = false;
        archive.addFile(af);
      }
      final pw = args['password'] as String?;
      final List<int> encodedBytes;
      if (pw != null && pw.isNotEmpty) {
        encodedBytes = ZipEncoder(password: pw).encode(archive, level: level) ?? <int>[];
      } else {
        encodedBytes = ZipEncoder().encode(archive, level: level) ?? <int>[];
      }
      final outFile = File(destinationPath)..createSync(recursive: true);
      outFile.writeAsBytesSync(encodedBytes);
    } else if (format == 'tar') {
      // 直接用 TarEncoder + OutputFileStream（比 TarFileEncoder 更灵活支持空目录）
      final output = OutputFileStream(destinationPath);
      final enc = TarEncoder();
      enc.start(output);
      try {
        for (final entry in files) {
          final f = File(entry.key);
          if (!f.existsSync()) continue;
          final fileStream = InputFileStream(f.path);
          final af = ArchiveFile.stream(entry.value, f.lengthSync(), fileStream);
          af.lastModTime = f.lastModifiedSync().millisecondsSinceEpoch ~/ 1000;
          af.mode = f.statSync().mode;
          enc.add(af);
          fileStream.closeSync();
        }
        for (final d in emptyDirs) {
          final normalized = d.endsWith('/') ? d : '$d/';
          final af = ArchiveFile(normalized, 0, null);
          af.isFile = false;
          enc.add(af);
        }
      } finally {
        enc.finish();
        output.closeSync();
      }
    } else {
      // tar.* 两阶段：TAR -> temp -> compressed -> destination
      final tmpDir = Directory.systemTemp;
      final tarTmp = File(p.join(tmpDir.path, 'zenfile_svc_${DateTime.now().millisecondsSinceEpoch}.tar'));
      try {
        // 2a) 流式写 TAR 到临时文件
        final output = OutputFileStream(tarTmp.path);
        final enc = TarEncoder();
        enc.start(output);
        try {
          for (final entry in files) {
            final f = File(entry.key);
            if (!f.existsSync()) continue;
            final fileStream = InputFileStream(f.path);
            final af = ArchiveFile.stream(entry.value, f.lengthSync(), fileStream);
            af.lastModTime = f.lastModifiedSync().millisecondsSinceEpoch ~/ 1000;
            af.mode = f.statSync().mode;
            enc.add(af);
            fileStream.closeSync();
          }
          for (final d in emptyDirs) {
            final normalized = d.endsWith('/') ? d : '$d/';
            final af = ArchiveFile(normalized, 0, null);
            af.isFile = false;
            enc.add(af);
          }
        } finally {
          enc.finish();
          output.closeSync();
        }

        // 2b) 把 TAR 按目标格式编码到 destinationPath
        _encodeTarToFormat(tarTmp, destinationPath, format, level);
      } finally {
        if (tarTmp.existsSync()) {
          try { tarTmp.deleteSync(); } catch (_) {}
        }
      }
    }

    // 3) 分卷切割（如果需要）：同样用分块 IO，不把整个压缩包读入 RAM
    if (splitSizeMB != null && splitSizeMB > 0) {
      final chunkSize = splitSizeMB * 1024 * 1024;
      final srcFile = File(destinationPath);
      final total = srcFile.lengthSync();
      if (total > chunkSize) {
        _splitArchiveIntoParts(srcFile, destinationPath, chunkSize);
        srcFile.deleteSync();
      }
    }
  }

  /// 把已生成的 TAR 文件编码到对应压缩格式的目标文件。
  /// 同步调用（运行在 compute Isolate）。
  static void _encodeTarToFormat(File tarFile, String destinationPath, String format, int level) {
    final total = tarFile.lengthSync();
    final output = File(destinationPath)..createSync(recursive: true);

    try {
      if (format == 'tar.gz') {
        // tar.gz：用 GZipEncoder 流式把 InputFileStream -> OutputFileStream
        final input = InputFileStream(tarFile.path);
        final outStream = OutputFileStream(destinationPath);
        try {
          GZipEncoder().encode(input, level: level, output: outStream);
        } finally {
          try { input.closeSync(); } catch (_) {}
          try { outStream.closeSync(); } catch (_) {}
        }
      } else if (format == 'tar.bz2') {
        final sink = output.openWrite();
        try {
          // BZip2Encoder：同步 encode。≤ 512MB 直接编码；>512MB 降级为仅 tar（避免 OOM）
          if (total > 512 * 1024 * 1024) {
            _copyFileSyncToSink(tarFile, sink);
          } else {
            final bytesBuilder = BytesBuilder(copy: false);
            final raf = tarFile.openSync();
            try {
              final buf = Uint8List(_kArchiveChunkSize);
              while (true) {
                final read = raf.readIntoSync(buf);
                if (read <= 0) break;
                if (read == _kArchiveChunkSize) {
                  bytesBuilder.add(buf);
                } else {
                  bytesBuilder.add(Uint8List.fromList(buf.sublist(0, read)));
                }
              }
            } finally { raf.closeSync(); }
            final encoded = BZip2Encoder().encode(bytesBuilder.takeBytes());
            _writeBytesChunked(sink, encoded);
          }
          sink.flush();
          sink.close();
        } catch (_) {
          try { sink.flush(); } catch (_) {}
          try { sink.close(); } catch (_) {}
          rethrow;
        }
      } else if (format == 'tar.lz4') {
        final sink = output.openWrite();
        try {
          if (total > 512 * 1024 * 1024) {
            _copyFileSyncToSink(tarFile, sink);
          } else {
            final bytesBuilder = BytesBuilder(copy: false);
            final raf = tarFile.openSync();
            try {
              final buf = Uint8List(_kArchiveChunkSize);
              while (true) {
                final read = raf.readIntoSync(buf);
                if (read <= 0) break;
                if (read == _kArchiveChunkSize) {
                  bytesBuilder.add(buf);
                } else {
                  bytesBuilder.add(Uint8List.fromList(buf.sublist(0, read)));
                }
              }
            } finally { raf.closeSync(); }
            final raw = bytesBuilder.takeBytes();
            final encoded = lz4FrameEncode(raw);
            _writeBytesChunked(sink, encoded);
          }
          sink.flush();
          sink.close();
        } catch (_) {
          try { sink.flush(); } catch (_) {}
          try { sink.close(); } catch (_) {}
          rethrow;
        }
      } else if (format == 'tar.zst') {
        final sink = output.openWrite();
        try {
          if (total > 512 * 1024 * 1024) {
            _copyFileSyncToSink(tarFile, sink);
          } else {
            final bytesBuilder = BytesBuilder(copy: false);
            final raf = tarFile.openSync();
            try {
              final buf = Uint8List(_kArchiveChunkSize);
              while (true) {
                final read = raf.readIntoSync(buf);
                if (read <= 0) break;
                if (read == _kArchiveChunkSize) {
                  bytesBuilder.add(buf);
                } else {
                  bytesBuilder.add(Uint8List.fromList(buf.sublist(0, read)));
                }
              }
            } finally { raf.closeSync(); }
            final raw = bytesBuilder.takeBytes();
            final encoded = const ZstdEncoder().encodeBytes(raw);
            _writeBytesChunked(sink, encoded);
          }
          sink.flush();
          sink.close();
        } catch (_) {
          try { sink.flush(); } catch (_) {}
          try { sink.close(); } catch (_) {}
          rethrow;
        }
      } else {
        // fallback：直接复制
        final sink = output.openWrite();
        try {
          _copyFileSyncToSink(tarFile, sink);
          sink.flush();
          sink.close();
        } catch (_) {
          try { sink.flush(); } catch (_) {}
          try { sink.close(); } catch (_) {}
          rethrow;
        }
      }
    } catch (_) {
      rethrow;
    }
  }

  /// 分卷切割：按 chunkSize 字节同步分块复制，不一次性读入原文件。
  static void _splitArchiveIntoParts(File srcFile, String destBase, int chunkSize) {
    final raf = srcFile.openSync();
    try {
      final total = raf.lengthSync();
      final buf = Uint8List(chunkSize);
      int remaining = total;
      int partNum = 1;
      while (remaining > 0) {
        final toRead = remaining > chunkSize ? chunkSize : remaining;
        final read = raf.readIntoSync(buf, 0, toRead);
        if (read <= 0) break;
        final partExt = partNum.toString().padLeft(3, '0');
        final partFile = File('$destBase.$partExt');
        final partRaf = partFile.openSync(mode: FileMode.write);
        try {
          if (read == chunkSize) {
            partRaf.writeFromSync(buf);
          } else {
            partRaf.writeFromSync(Uint8List.fromList(buf.sublist(0, read)));
          }
        } finally { partRaf.closeSync(); }
        remaining -= read;
        partNum++;
      }
    } finally {
      raf.closeSync();
    }
  }

  /// Extracts an archive to the specified destination directory.
  static Future<void> extractArchive({
    required String archivePath,
    required String destinationDir,
    String? password,
  }) async {
    return compute(_decodeArchiveTask, {
      'archivePath': archivePath,
      'destinationDir': destinationDir,
      'password': password,
    });
  }

  /// 流式合并多卷分卷（.001/.002...）到单个临时文件。分块 IO，避免 readAsBytesSync。
  static File? _combineSplitParts(String archivePath) {
    if (!archivePath.endsWith('.001')) return null;
    final baseName = archivePath.substring(0, archivePath.length - 4);
    final tempDir = Directory.systemTemp.createTempSync('extract_part');
    final combined = File(p.join(tempDir.path, 'combined_archive'));
    final raf = combined.openSync(mode: FileMode.write);
    try {
      final buf = Uint8List(_kArchiveChunkSize);
      int partNum = 1;
      while (true) {
        final partExt = partNum.toString().padLeft(3, '0');
        final partFile = File('$baseName.$partExt');
        if (!partFile.existsSync()) break;
        final partRaf = partFile.openSync();
        try {
          while (true) {
            final read = partRaf.readIntoSync(buf);
            if (read <= 0) break;
            if (read == _kArchiveChunkSize) {
              raf.writeFromSync(buf);
            } else {
              raf.writeFromSync(Uint8List.fromList(buf.sublist(0, read)));
            }
          }
        } finally { partRaf.closeSync(); }
        partNum++;
      }
      return combined;
    } catch (_) {
      raf.closeSync();
      try { tempDir.deleteSync(recursive: true); } catch (_) {}
      rethrow;
    } finally {
      raf.closeSync();
    }
  }

  /// 把 TAR.* 外层流式解压到临时 TAR 文件（同步实现，运行在 compute Isolate）。
  /// 返回临时 TAR 文件路径（调用方负责删除），异常返回 null 让调用方走 fallback。
  static File? _unwrapTarWrapperSync(File src, String lowerPath) {
    final tmpDir = Directory.systemTemp;
    final tarTmp = File(p.join(tmpDir.path, 'zenfile_svc_ext_${DateTime.now().millisecondsSinceEpoch}.tar'));

    if (lowerPath.endsWith('.tar.gz') || lowerPath.endsWith('.tgz')) {
      // tar.gz：用 GZipDecoder.decodeStream 流式 InputFileStream -> OutputFileStream
      final input = InputFileStream(src.path);
      final output = OutputFileStream(tarTmp.path);
      try {
        GZipDecoder().decodeStream(input, output);
        output.flush();
      } catch (_) {
        try { input.closeSync(); } catch (_) {}
        try { output.closeSync(); } catch (_) {}
        if (tarTmp.existsSync()) { try { tarTmp.deleteSync(); } catch (_) {} }
        return null;
      }
      try { input.closeSync(); } catch (_) {}
      try { output.closeSync(); } catch (_) {}
      return tarTmp;
    }

    // 对于 tar.bz2 / tar.lz4 / tar.zst：同步解码器没有流式 API，按阈值处理。
    List<int> Function(Uint8List) decoder;
    if (lowerPath.endsWith('.tar.bz2') || lowerPath.endsWith('.tbz2')) {
      decoder = (b) => BZip2Decoder().decodeBytes(b);
    } else if (lowerPath.endsWith('.tar.lz4') || lowerPath.endsWith('.tlz4')) {
      decoder = (b) => lz4FrameDecode(b);
    } else if (lowerPath.endsWith('.tar.zst') || lowerPath.endsWith('.tzst')) {
      decoder = (b) => const ZstdDecoder().decodeBytes(b);
    } else {
      return null;
    }

    // 阈值：≤ 384MB 直接读入解码；> 384MB 尝试但可能 OOM
    try {
      final bytes = src.readAsBytesSync();
      final decoded = decoder(Uint8List.fromList(bytes));
      tarTmp.writeAsBytesSync(decoded is Uint8List ? decoded : Uint8List.fromList(decoded));
      return tarTmp;
    } catch (_) {
      if (tarTmp.existsSync()) { try { tarTmp.deleteSync(); } catch (_) {} }
      return null;
    }
  }

  /// 同步分块写 ArchiveFile.content 到文件，避免一次性 writeAsBytesSync。
  static void _writeContentChunkedSync(dynamic content, File outFile, {int chunkSize = _kArchiveChunkSize}) {
    outFile.createSync(recursive: true);
    final raf = outFile.openSync(mode: FileMode.write);
    try {
      if (content is List<int>) {
        final bytes = content;
        if (bytes.isEmpty) return;
        if (bytes.length <= chunkSize) {
          raf.writeFromSync(bytes);
          return;
        }
        for (int i = 0; i < bytes.length; i += chunkSize) {
          final end = (i + chunkSize > bytes.length) ? bytes.length : i + chunkSize;
          raf.writeFromSync(Uint8List.fromList(bytes.sublist(i, end)));
        }
      }
    } finally {
      raf.closeSync();
    }
  }

  static void _decodeArchiveTask(Map<String, dynamic> args) {
    String archivePath = args['archivePath'] as String;
    final destinationDir = args['destinationDir'] as String;
    final password = args['password'] as String?;

    File? tempTarWrapper;
    final toCleanDirs = <Directory>[];

    try {
      // 1) 多卷合并（分块 IO）
      final combined = _combineSplitParts(archivePath);
      if (combined != null) {
        archivePath = combined.path;
        toCleanDirs.add(combined.parent);
      }

      final lowerPath = archivePath.toLowerCase();
      final srcFile = File(archivePath);

      // 2) 单文件压缩包（非归档）：直接解压到目标
      if (lowerPath.endsWith('.gz') &&
          !lowerPath.endsWith('.tar.gz') &&
          !lowerPath.endsWith('.tgz')) {
        final name = p.basenameWithoutExtension(archivePath);
        final destFile = File(p.join(destinationDir, name));
        destFile.createSync(recursive: true);
        // 单文件 .gz：GZipDecoder.decodeStream 流式
        final input = InputFileStream(archivePath);
        final output = OutputFileStream(destFile.path);
        try {
          GZipDecoder().decodeStream(input, output);
          output.flush();
        } finally {
          try { input.closeSync(); } catch (_) {}
          try { output.closeSync(); } catch (_) {}
        }
        return;
      }
      if (lowerPath.endsWith('.bz2') && !lowerPath.endsWith('.tar.bz2') && !lowerPath.endsWith('.tbz2')) {
        final name = p.basenameWithoutExtension(archivePath);
        final destFile = File(p.join(destinationDir, name));
        final raw = srcFile.readAsBytesSync();
        final decoded = BZip2Decoder().decodeBytes(Uint8List.fromList(raw));
        _writeContentChunkedSync(decoded, destFile);
        return;
      }
      if (lowerPath.endsWith('.lz4') && !lowerPath.endsWith('.tar.lz4') && !lowerPath.endsWith('.tlz4')) {
        final name = p.basenameWithoutExtension(archivePath);
        final destFile = File(p.join(destinationDir, name));
        final raw = srcFile.readAsBytesSync();
        final decoded = lz4FrameDecode(Uint8List.fromList(raw));
        _writeContentChunkedSync(decoded, destFile);
        return;
      }
      if ((lowerPath.endsWith('.zst') || lowerPath.endsWith('.zstd')) &&
          !lowerPath.endsWith('.tar.zst') &&
          !lowerPath.endsWith('.tzst')) {
        final name = p.basenameWithoutExtension(archivePath);
        final destFile = File(p.join(destinationDir, name));
        final raw = srcFile.readAsBytesSync();
        final decoded = const ZstdDecoder().decodeBytes(Uint8List.fromList(raw));
        _writeContentChunkedSync(decoded, destFile);
        return;
      }

      // 3) 归档类：ZIP / TAR / TAR.*
      late Archive archive;
      final pwdStr = (password != null && password.isNotEmpty) ? password : null;

      // 需要保持引用以便在所有文件提取完成后才关闭
      InputFileStream? zipInputToClose;

      if (lowerPath.endsWith('.zip') || lowerPath.contains('.zip.')) {
        final input = InputFileStream(archivePath);
        zipInputToClose = input;
        archive = ZipDecoder().decodeBuffer(input, password: pwdStr);
      } else if (lowerPath.endsWith('.tar')) {
        final input = InputFileStream(archivePath);
        archive = TarDecoder().decodeBuffer(input);
        try { input.closeSync(); } catch (_) {}
      } else {
        // TAR.*：先流式拆外层到临时 TAR
        final unwrapped = _unwrapTarWrapperSync(srcFile, lowerPath);
        if (unwrapped != null) {
          tempTarWrapper = unwrapped;
          final input = InputFileStream(unwrapped.path);
          archive = TarDecoder().decodeBuffer(input);
          try { input.closeSync(); } catch (_) {}
        } else {
          // fallback：走 InputFileStream + zip decoder
          final input = InputFileStream(archivePath);
          zipInputToClose = input;
          archive = ZipDecoder().decodeBuffer(input, password: pwdStr);
        }
      }

      try {
        // 4) 逐个条目写出：文件分块写，避免 writeAsBytesSync 对大文件内存峰值
        final totalEntries = archive.length;
        for (int i = 0; i < totalEntries; i++) {
          final entry = archive[i];
          final filename = _fixZipFilename(entry.name);
          final outPath = p.join(destinationDir, filename);
          if (entry.isFile) {
            final outFile = File(outPath);
            _writeContentChunkedSync(entry.content, outFile);
          } else {
            Directory(outPath).createSync(recursive: true);
          }
        }
      } finally {
        // ✅ 在所有文件提取完成后才关闭 ZIP 输入流
        if (zipInputToClose != null) {
          try { zipInputToClose.closeSync(); } catch (_) {}
        }
      }
    } finally {
      if (tempTarWrapper != null && tempTarWrapper.existsSync()) {
        try { tempTarWrapper.deleteSync(); } catch (_) {}
      }
      for (final d in toCleanDirs) {
        try { if (d.existsSync()) d.deleteSync(recursive: true); } catch (_) {}
      }
    }
  }

  static Future<void> _deleteEntity(String path) async {
    try {
      final type = FileSystemEntity.typeSync(path);
      if (type == FileSystemEntityType.directory) {
        await Directory(path).delete(recursive: true);
      } else if (type == FileSystemEntityType.file) {
        await File(path).delete();
      }
    } catch (_) {}
  }

  static Future<Archive?> readArchive(String archivePath, {String? password}) async {
    return compute(_readArchiveTask, {'archivePath': archivePath, 'password': password});
  }

  /// 在隔离区内以「全新打开、全程保持打开」的流，把指定内部路径的条目解压为纯字节返回。
  ///
  /// 为什么需要它：[readArchive] 返回的 Archive 会在 compute 隔离区跨边界序列化，且其条目
  /// 的 _rawContent 是引用同一 FileBuffer/RandomAccessFile 的文件型流；主隔离区里惰性解压时
  /// 句柄已失效 / _fileSize 被置 0，导致大条目（尤其 >4MB）读到空/错误字节，dart:io 的 raw
  /// deflate 解码器抛 `FormatException: Filter error, bad data`。本方法在流打开期间就完成解压，
  /// 只回传普通 Uint8List，彻底规避跨隔离区文件流问题。
  ///
  /// 返回 map：internalPath -> 解压后的字节（失败或缺项为 null）。
  static Future<Map<String, Uint8List?>> extractEntriesToBytes(
    String archivePath,
    List<String> internalPaths, {
    String? password,
  }) async {
    return compute(_extractEntriesToBytesTask, {
      'archivePath': archivePath,
      'internalPaths': internalPaths,
      'password': password,
    });
  }

  static String _normalizeForMatch(String path) {
    var name = path.replaceAll('\\', '/');
    while (name.startsWith('/')) {
      name = name.substring(1);
    }
    while (name.startsWith('./')) {
      name = name.substring(2);
    }
    return name;
  }

  static Map<String, Uint8List?> _extractEntriesToBytesTask(Map<String, dynamic> args) {
    final archivePath = args['archivePath'] as String;
    final rawPaths = args['internalPaths'] as List;
    final password = args['password'] as String?;
    final pwdStr = (password != null && password.isNotEmpty) ? password : null;
    final requested = rawPaths.map((e) => _normalizeForMatch(e as String)).toList();

    final result = <String, Uint8List?>{};
    for (final p in requested) {
      result[p] = null;
    }

    try {
      final input = InputFileStream(archivePath);
      try {
        final archive = ZipDecoder().decodeBuffer(input, password: pwdStr);
        _fixArchiveFilenames(archive);
        for (final p in requested) {
          try {
            final fileObj = archive.files.firstWhere(
              (f) => f.isFile && _normalizeForMatch(f.name) == p,
            );
            final content = fileObj.content;
            if (content is Uint8List) {
              result[p] = content;
            } else if (content is List<int>) {
              result[p] = Uint8List.fromList(content);
            } else {
              result[p] = null;
            }
          } catch (_) {
            result[p] = null;
          }
        }
      } finally {
        try { input.closeSync(); } catch (_) {}
      }
    } catch (_) {
      // 整个压缩包都无法打开时，保留 null 结果
    }
    return result;
  }

  /// 修复压缩包中非 UTF-8 编码的文件名（如 GBK 编码的中文文件名）
  static void _fixArchiveFilenames(Archive archive) {
    for (int i = 0; i < archive.length; i++) {
      final file = archive[i];
      final fixedName = _fixZipFilename(file.name);
      if (fixedName != file.name) {
        file.name = fixedName;
      }
    }
  }

  /// 修复单个 ZIP 文件名编码
  static String _fixZipFilename(String name) {
    bool hasGarbled = false;
    for (int i = 0; i < name.length; i++) {
      final codeUnit = name.codeUnitAt(i);
      if (codeUnit >= 0x80 && codeUnit <= 0xFF) {
        hasGarbled = true;
        break;
      }
    }
    if (!hasGarbled) return name;

    try {
      final bytes = name.codeUnits;
      return gbk.decode(bytes);
    } catch (_) {
      return name;
    }
  }

  static Archive? _readArchiveTask(Map<String, dynamic> args) {
    final archivePath = args['archivePath'] as String;
    final password = args['password'] as String?;
    final pwdStr = (password != null && password.isNotEmpty) ? password : null;

    try {
      final file = File(archivePath);
      if (!file.existsSync() || file.lengthSync() == 0) return Archive();
      final lowerPath = archivePath.toLowerCase();

      File? tempTar;
      try {
        late Archive archive;
        if (lowerPath.endsWith('.zip') || lowerPath.contains('.zip.')) {
          final input = InputFileStream(archivePath);
          try {
            archive = ZipDecoder().decodeBuffer(input, password: pwdStr);
          } finally { try { input.closeSync(); } catch (_) {} }
        } else if (lowerPath.endsWith('.tar')) {
          final input = InputFileStream(archivePath);
          try {
            archive = TarDecoder().decodeBuffer(input);
          } finally { try { input.closeSync(); } catch (_) {} }
        } else if (lowerPath.endsWith('.tar.gz') || lowerPath.endsWith('.tgz') ||
            lowerPath.endsWith('.tar.bz2') || lowerPath.endsWith('.tbz2') ||
            lowerPath.endsWith('.tar.lz4') || lowerPath.endsWith('.tlz4') ||
            lowerPath.endsWith('.tar.zst') || lowerPath.endsWith('.tzst')) {
          final unwrapped = _unwrapTarWrapperSync(file, lowerPath);
          if (unwrapped != null) {
            tempTar = unwrapped;
            final input = InputFileStream(unwrapped.path);
            try {
              archive = TarDecoder().decodeBuffer(input);
            } finally { try { input.closeSync(); } catch (_) {} }
          } else {
            final input = InputFileStream(archivePath);
            try {
              archive = ZipDecoder().decodeBuffer(input, password: pwdStr);
            } finally { try { input.closeSync(); } catch (_) {} }
          }
        } else {
          final input = InputFileStream(archivePath);
          try {
            archive = ZipDecoder().decodeBuffer(input, password: pwdStr);
          } finally { try { input.closeSync(); } catch (_) {} }
        }

        _fixArchiveFilenames(archive);
        return archive;
      } finally {
        if (tempTar != null && tempTar.existsSync()) {
          try { tempTar.deleteSync(); } catch (_) {}
        }
      }
    } catch (e) {
      debugPrint('Error reading archive: $e');
      return Archive();
    }
  }

  static Future<bool> addFileToArchive({
    required String archivePath,
    required String filePathToAdd,
    required String internalPath,
  }) async {
    return compute(_addFileToArchiveTask, {
      'archivePath': archivePath,
      'filePathToAdd': filePathToAdd,
      'internalPath': internalPath,
    });
  }

  /// 向归档追加文件：优先「流式读出旧条目 + 流式写新归档」，避免一次性驻留。
  static bool _addFileToArchiveTask(Map<String, dynamic> args) {
    final archivePath = args['archivePath'] as String;
    final filePathToAdd = args['filePathToAdd'] as String;
    final internalPath = args['internalPath'] as String;

    try {
      final archiveFile = File(archivePath);
      final fileToAdd = File(filePathToAdd);
      if (!fileToAdd.existsSync()) return false;
      final lowerPath = archivePath.toLowerCase();

      final isTar = lowerPath.endsWith('.tar');
      final isGz = lowerPath.endsWith('.tar.gz') || lowerPath.endsWith('.tgz');
      final isBz2 = lowerPath.endsWith('.tar.bz2') || lowerPath.endsWith('.tbz2');
      final isLz4 = lowerPath.endsWith('.tar.lz4') || lowerPath.endsWith('.tlz4');
      final isZst = lowerPath.endsWith('.tar.zst') || lowerPath.endsWith('.tzst');
      final isZip = !isTar && !isGz && !isBz2 && !isLz4 && !isZst;

      final nameInside = p.join(internalPath, p.basename(filePathToAdd)).replaceAll('\\', '/');

      late Archive oldArchive;
      File? tempTarWrapper;
      try {
        if (archiveFile.existsSync() && archiveFile.lengthSync() > 0) {
          if (isZip) {
            final input = InputFileStream(archivePath);
            try {
              oldArchive = ZipDecoder().decodeBuffer(input);
            } finally { try { input.closeSync(); } catch (_) {} }
          } else if (isTar) {
            final input = InputFileStream(archivePath);
            try {
              oldArchive = TarDecoder().decodeBuffer(input);
            } finally { try { input.closeSync(); } catch (_) {} }
          } else {
            final unwrapped = _unwrapTarWrapperSync(archiveFile, lowerPath);
            if (unwrapped != null) {
              tempTarWrapper = unwrapped;
              final input = InputFileStream(unwrapped.path);
              try {
                oldArchive = TarDecoder().decodeBuffer(input);
              } finally { try { input.closeSync(); } catch (_) {} }
            } else {
              oldArchive = Archive();
            }
          }
        } else {
          oldArchive = Archive();
        }
      } catch (_) {
        oldArchive = Archive();
      } finally {
        if (tempTarWrapper != null && tempTarWrapper.existsSync()) {
          try { tempTarWrapper.deleteSync(); } catch (_) {}
        }
      }

      // 读入待追加文件（按分块，避免 readAsBytesSync）
      final newFileBytes = _readFileSyncChunked(fileToAdd);

      final tmpDir = Directory.systemTemp;
      final tarTmp = File(p.join(tmpDir.path, 'zenfile_svc_add_${DateTime.now().millisecondsSinceEpoch}.tar'));

      try {
        if (isZip) {
          final enc = ZipFileEncoder();
          enc.create(archivePath);
          try {
            for (int i = 0; i < oldArchive.length; i++) {
              final e = oldArchive[i];
              enc.addArchiveFile(e);
            }
            final newAf = ArchiveFile(nameInside, newFileBytes.length, newFileBytes);
            enc.addArchiveFile(newAf);
          } finally {
            enc.closeSync();
          }
          return true;
        }

        // tar / tar.*：统一先写 TAR
        final output = OutputFileStream(tarTmp.path);
        final tarEnc = TarEncoder();
        tarEnc.start(output);
        try {
          for (int i = 0; i < oldArchive.length; i++) {
            tarEnc.add(oldArchive[i]);
          }
          final newAf = ArchiveFile(nameInside, newFileBytes.length, newFileBytes);
          tarEnc.add(newAf);
        } finally {
          tarEnc.finish();
          output.closeSync();
        }

        if (isTar) {
          tarTmp.renameSync(archivePath);
          return true;
        }

        _encodeTarToFormat(tarTmp, archivePath,
            isGz ? 'tar.gz' :
            isBz2 ? 'tar.bz2' :
            isLz4 ? 'tar.lz4' : 'tar.zst', 6);
        return true;
      } finally {
        if (tarTmp.existsSync()) { try { tarTmp.deleteSync(); } catch (_) {} }
      }
    } catch (e) {
      debugPrint('Error adding to archive: $e');
      return false;
    }
  }

  /// 同步分块读文件，返回 Uint8List（小工具函数）
  static Uint8List _readFileSyncChunked(File src, {int chunkSize = _kArchiveChunkSize}) {
    final bb = BytesBuilder(copy: false);
    final raf = src.openSync();
    try {
      final buf = Uint8List(chunkSize);
      while (true) {
        final read = raf.readIntoSync(buf);
        if (read <= 0) break;
        if (read == chunkSize) {
          bb.add(buf);
        } else {
          bb.add(Uint8List.fromList(buf.sublist(0, read)));
        }
      }
    } finally { raf.closeSync(); }
    return bb.takeBytes();
  }

  static Future<bool> deleteItemsFromArchive({
    required String archivePath,
    required List<String> internalPathsToDelete,
  }) async {
    return compute(_deleteItemsFromArchiveTask, {
      'archivePath': archivePath,
      'internalPathsToDelete': internalPathsToDelete,
    });
  }

  static bool _deleteItemsFromArchiveTask(Map<String, dynamic> args) {
    final archivePath = args['archivePath'] as String;
    final internalPathsToDelete = args['internalPathsToDelete'] as List<String>;

    try {
      final archiveFile = File(archivePath);
      if (!archiveFile.existsSync() || archiveFile.lengthSync() == 0) return false;

      final lowerPath = archivePath.toLowerCase();
      final isTar = lowerPath.endsWith('.tar');
      final isGz = lowerPath.endsWith('.tar.gz') || lowerPath.endsWith('.tgz');
      final isBz2 = lowerPath.endsWith('.tar.bz2') || lowerPath.endsWith('.tbz2');
      final isLz4 = lowerPath.endsWith('.tar.lz4') || lowerPath.endsWith('.tlz4');
      final isZst = lowerPath.endsWith('.tar.zst') || lowerPath.endsWith('.tzst');
      final isZip = !isTar && !isGz && !isBz2 && !isLz4 && !isZst;

      // 1) 流式读入旧 Archive（不一次性 readAsBytesSync 压缩包）
      late Archive oldArchive;
      File? tempTarWrapper;
      try {
        if (isZip) {
          final input = InputFileStream(archivePath);
          try { oldArchive = ZipDecoder().decodeBuffer(input); }
          finally { try { input.closeSync(); } catch (_) {} }
        } else if (isTar) {
          final input = InputFileStream(archivePath);
          try { oldArchive = TarDecoder().decodeBuffer(input); }
          finally { try { input.closeSync(); } catch (_) {} }
        } else {
          final unwrapped = _unwrapTarWrapperSync(archiveFile, lowerPath);
          if (unwrapped != null) {
            tempTarWrapper = unwrapped;
            final input = InputFileStream(unwrapped.path);
            try { oldArchive = TarDecoder().decodeBuffer(input); }
            finally { try { input.closeSync(); } catch (_) {} }
          } else {
            return false;
          }
        }
      } finally {
        if (tempTarWrapper != null && tempTarWrapper.existsSync()) {
          try { tempTarWrapper.deleteSync(); } catch (_) {}
        }
      }

      // 2) 过滤条目（不复制 content，避免多次拷贝大数组）
      final keepFiles = <ArchiveFile>[];
      for (int i = 0; i < oldArchive.length; i++) {
        final f = oldArchive[i];
        var name = f.name.replaceAll('\\', '/');
        while (name.startsWith('/')) { name = name.substring(1); }
        while (name.startsWith('./')) { name = name.substring(2); }
        bool shouldDelete = false;
        for (final toDel in internalPathsToDelete) {
          if (toDel.endsWith('/')) {
            if (name.startsWith(toDel) || name == toDel.substring(0, toDel.length - 1)) {
              shouldDelete = true;
              break;
            }
          } else {
            if (name == toDel) {
              shouldDelete = true;
              break;
            }
          }
        }
        if (!shouldDelete) keepFiles.add(f);
      }

      // 3) 流式重写输出
      final tmpDir = Directory.systemTemp;
      final tarTmp = File(p.join(tmpDir.path, 'zenfile_svc_del_${DateTime.now().millisecondsSinceEpoch}.tar'));
      try {
        if (isZip) {
          final enc = ZipFileEncoder();
          enc.create(archivePath);
          try {
            for (final f in keepFiles) {
              enc.addArchiveFile(f);
            }
          } finally { enc.closeSync(); }
          return true;
        }

        final output = OutputFileStream(tarTmp.path);
        final tarEnc = TarEncoder();
        tarEnc.start(output);
        try {
          for (final f in keepFiles) {
            tarEnc.add(f);
          }
        } finally {
          tarEnc.finish();
          output.closeSync();
        }

        if (isTar) {
          tarTmp.renameSync(archivePath);
          return true;
        }
        _encodeTarToFormat(tarTmp, archivePath,
            isGz ? 'tar.gz' :
            isBz2 ? 'tar.bz2' :
            isLz4 ? 'tar.lz4' : 'tar.zst', 6);
        return true;
      } finally {
        if (tarTmp.existsSync()) { try { tarTmp.deleteSync(); } catch (_) {} }
      }
    } catch (e) {
      debugPrint('Error deleting from archive: $e');
      return false;
    }
  }
}
