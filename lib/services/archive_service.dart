import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:archive/archive_io.dart';
// .7z / .rar 解码：package:archive 不支持这两种格式，改由纯 Dart 的 koni_archive 处理。
// 与 package:archive 同名（Archive）故加前缀避免冲突。
import 'package:koni_archive/io.dart' as koni;
import 'package:dart_lz4/dart_lz4.dart';
import 'package:charset/charset.dart';
import 'package:just_zstd/just_zstd.dart';

/// ArchiveService 同步分块 IO 用的缓冲区大小（1 MiB）。
/// 在 compute Isolate 里使用同步 openRead/Write，避免主线程阻塞；
/// 同时每块读写之间不会把整文件放进 RAM，从根源避免 OOM。
const int _kArchiveChunkSize = 1024 * 1024;

/// 压缩包需要密码但调用方没有提供。
///
/// 之所以要独立类型：archive 包在「无密码读加密条目」时只会以 `_password!`
/// 非空断言崩溃或静默返回空内容（⇒ 解出 0 字节文件），错误信息既不可读也无法
/// 与「其它失败」区分。解压链路据此把「缺密码」单独提示并重新索要密码。
class ArchivePasswordRequiredException implements Exception {
  const ArchivePasswordRequiredException();
  @override
  String toString() => 'Archive password required';
}

/// 提供了密码但校验不通过（AES 的 macs don't match / ZipCrypto 的 CRC 不符）。
class ArchivePasswordInvalidException implements Exception {
  const ArchivePasswordInvalidException(this.detail);
  final Object? detail;
  @override
  String toString() => 'Archive password invalid: $detail';
}

/// 条目内容取不到（例如加密条目在无密码时解出 null）。
///
/// 解压链路不允许把这种情况当成「空文件」静默写盘：宁可整包报错，也不要
/// 产出一堆 0 字节文件让用户误以为压缩包损坏。
class ArchiveContentUnavailableException implements Exception {
  const ArchiveContentUnavailableException(this.entryName);
  final String entryName;
  @override
  String toString() => 'Archive content unavailable: $entryName';
}

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
        // 密码转 UTF-8「字节串」再交给 ZipEncoder：archive 包用 codeUnits 作 AES
        // 密钥字节，直接传中文会写出其他工具无法解开的密码。
        encodedBytes =
            ZipEncoder(password: zipEncodePassword(pw)).encode(archive, level: level) ?? <int>[];
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

  // ---- 中文密码：ZIP 密码字节编码兼容 ----
  //
  // archive 包内部用 `password.codeUnits`（UTF-16）作为 ZIP 加密的密钥字节，而标准
  // ZIP 的密码字节编码是：WinZip AES 固定 UTF-8；传统 ZipCrypto 用创建端系统 ANSI
  // 码页（中文 Windows 即 GBK）或带 UTF-8 语言标志时的 UTF-8。中文密码直接传入
  // 必然解不对，这里把密码按不同编码重编码成「codeUnits == 目标字节序列」的字符串。

  /// 生成用于 archive 包解码的密码候选（按优先级）。
  ///
  /// 每个候选都是「codeUnits 恰好等于某种编码字节序列」的字符串：archive 包拿
  /// `codeUnits` 当密钥字节，等价于用该编码的字节做密钥。
  static List<String> zipPasswordCandidates(String password) {
    final candidates = <String>[];
    void add(List<int> bytes) {
      final s = String.fromCharCodes(bytes);
      if (!candidates.contains(s)) candidates.add(s);
    }

    // 1) UTF-8：AES 与带 UTF-8 语言标志的现代 ZIP。
    add(utf8.encode(password));

    // 2) GBK：中文 Windows 下 WinRAR / 7-Zip / 资源管理器传统 ZipCrypto。
    try {
      add(gbk.encode(password));
    } catch (_) {}

    // 3) 原始字符串：向后兼容本 App 旧版本（直接用 UTF-16 codeUnits 作密钥）。
    if (!candidates.contains(password)) {
      candidates.add(password);
    }
    return candidates;
  }

  /// 压缩时把密码转成 UTF-8「字节串」，使 ZipEncoder 写出标准 UTF-8 AES 密码，
  /// WinZip / 7-Zip 等第三方工具也能正常解压。
  static String zipEncodePassword(String password) =>
      String.fromCharCodes(utf8.encode(password));

  /// 用中文密码候选解码 ZIP（解码后做内容校验以确认密码正确）。
  ///
  /// archive 包对错误密码不会在 decodeBuffer 阶段立刻抛错：AES 的「password error /
  /// macs don't match」与 ZipCrypto 的坏数据都延迟到读取条目内容时才抛。因此这里
  /// 逐个候选解码并校验条目内容，失败则 reset 流换下一个候选。
  ///
  /// 注意 ZipCrypto 的特殊性：错误密码解出的乱码若恰好能通过 deflate（或被以 STORE
  /// 存储）并不会抛异常，旧实现只「读一下内容」会把第一个候选误当正确密码返回——
  /// 中文密码有 utf8/gbk 多个候选，一旦第一个（utf8）被误判命中，真正的 gbk 候选
  /// 就永远不会被尝试，表现为「中文密码解压失败/解出乱码」。改用 CRC32 判定。
  static Archive decodeZip(InputStreamBase input, String? password,
      {bool requirePasswordIfEncrypted = false}) {
    if (password == null || password.isEmpty) {
      final decoder = ZipDecoder();
      final archive = decoder.decodeBuffer(input);
      if (requirePasswordIfEncrypted) {
        // general purpose bit 0 = 文件加密标志。archive 包在无密码读取加密条目
        // 内容时会以 `_password!` 非空断言崩溃（错误信息不可读），这里提前抛出
        // 明确错误。仅用于「要读内容」的路径；纯列名预览不开启，保留文件名可见。
        final hasEncrypted = decoder.directory.fileHeaders
            .any((h) => (h.generalPurposeBitFlag & 0x1) != 0);
        if (hasEncrypted) {
          throw const ArchivePasswordRequiredException();
        }
      }
      return archive;
    }
    final candidates = zipPasswordCandidates(password);
    Object? lastError;
    Archive? unverified;
    for (final candidate in candidates) {
      input.reset();
      try {
        final archive = ZipDecoder().decodeBuffer(input, password: candidate);
        if (_verifyZipPassword(archive)) return archive;
        // 能读通但 CRC 不符：先留作兜底，继续试下一个候选。
        unverified ??= archive;
      } catch (e) {
        lastError = e;
      }
    }
    // 所有候选都没通过 CRC：若某个候选至少能解出内容（CRC 字段不可信，如 WinZip
    // AES AE-2 不写 CRC），退回它，避免把正确密码误判为错误。
    if (unverified != null) return unverified;
    throw ArchivePasswordInvalidException(lastError);
  }

  /// 是否为「需要密码的 ZIP」（仅 ZIP / ZIP.* 判定；其它格式、读取失败一律 false）。
  ///
  /// 只读中央目录里的 general purpose bit 0（加密标志），不解压任何数据，
  /// 代价很小，可在弹「解压到…」对话框之前预检，从而：
  /// 1) 加密包在用户没填密码时就明确要求密码，而不是解出一堆 0 字节文件；
  /// 2) 非加密包不受影响（不会多问一次密码）。
  static bool zipNeedsPassword(String archivePath) {
    final lower = archivePath.toLowerCase();
    if (!lower.endsWith('.zip') && !lower.contains('.zip.')) return false;
    InputStreamBase? input;
    try {
      final file = File(archivePath);
      if (!file.existsSync()) return false;
      input = InputFileStream(archivePath);
      final decoder = ZipDecoder();
      decoder.decodeBuffer(input);
      return decoder.directory.fileHeaders
          .any((h) => (h.generalPurposeBitFlag & 0x1) != 0);
    } catch (_) {
      // 读取失败（损坏 / 非 ZIP）交给正常解压流程报错，这里不拦截。
      return false;
    } finally {
      try { input?.closeSync(); } catch (_) {}
    }
  }

  /// 校验密码是否匹配：挑一个「有内容」的条目触发解密并比对 CRC32。
  ///
  /// - AES：错误密码会在读取内容时直接抛异常（由 [decodeZip] 捕获），CRC 校验是额外保险。
  /// - ZipCrypto：错误密码不抛异常，只能靠 CRC 识别。
  /// - 条目 CRC 为 0（AE-2 不写 CRC、或全空包）时无从校验，返回 true 放行。
  static bool _verifyZipPassword(Archive archive) {
    ArchiveFile? target;
    for (final file in archive.files) {
      if (!file.isFile || file.size <= 0) continue;
      // 取最小的非空文件，校验成本最低。
      if (target == null || file.size < target.size) target = file;
    }
    if (target == null) return true; // 没有可校验的条目
    final content = target.content; // AES 错误密码在此抛异常
    final expectedCrc = target.crc32;
    if (expectedCrc == null || expectedCrc == 0) return true; // CRC 不可信
    if (content is List<int>) {
      return getCrc32(content) == expectedCrc;
    }
    return true;
  }

  // ==================== .7z / .rar（koni_archive 纯 Dart 实现） ====================

  /// 把解压/压缩过程中抛出的异常归类为稳定字符串码，供 isolate 上报给 UI 层
  /// 决定「弹密码重试」还是「弹失败提示」。
  /// 密码类问题必须单独识别：否则用户只能看到一句通用失败，误以为压缩包损坏。
  static String classifyError(Object e) {
    if (e is ArchivePasswordRequiredException) return 'password_required';
    if (e is ArchivePasswordInvalidException) return 'password_invalid';
    if (e is ArchiveContentUnavailableException) return 'content_unavailable';
    // koni_archive（7z/rar）：InvalidPasswordException 是 EncryptedArchiveException
    // 的子类，必须先判子类，否则「密码错误」会被误判成「需要密码」。
    if (e is koni.InvalidPasswordException) return 'password_invalid';
    if (e is koni.EncryptedArchiveException) return 'password_required';
    return 'other';
  }

  /// 是否属于由 koni_archive 解码的格式（.7z / .rar）。
  static bool isKoniArchivePath(String path) {
    final lower = path.toLowerCase();
    return lower.endsWith('.7z') || lower.endsWith('.rar');
  }

  /// 解压 .7z/.rar：支持 RAR4/RAR5、7z AES-256（含加密头）与中文密码。
  ///
  /// [wrapInSubfolder] 为 true 时沿用 ZIP 路径的「自动建子文件夹」策略：仅当压缩包
  /// 只有一个根条目且该条目本身是目录时才直接解到 [destinationDir]，否则在
  /// [destinationDir] 下创建与压缩包同名的子文件夹。
  ///
  /// [onProgress] 每写入一块内容回调一次，参数依次为：当前文件路径、已处理字节、
  /// 总字节、当前文件已写字节、当前文件总大小、整体进度(0..1)、当前文件序号(1基)、
  /// 文件总数。返回实际解压到的目录。
  static Future<String> extractKoniArchive({
    required String archivePath,
    required String destinationDir,
    String? password,
    bool wrapInSubfolder = true,
    void Function(String currentFile, int bytesProcessed, int totalBytes,
            int currentFileBytes, int currentFileTotal, double progress,
            int currentIndex, int totalFiles)? onProgress,
  }) async {
    final pw = (password != null && password.isNotEmpty) ? password : null;
    final archive = await koni.openArchiveFile(
      archivePath,
      options: koni.ArchiveReadOptions(password: pw),
    );
    try {
      final all = archive.walk().toList();
      final files = all.where((e) => e.isFile && e.path.isNotEmpty).toList();
      final dirs = all.where((e) => e.isDirectory && e.path.isNotEmpty).toList();

      var destDir = destinationDir;
      if (wrapInSubfolder) {
        final rootEntries = <String>{};
        for (final e in all) {
          final name = _normalizeForMatch(e.path);
          if (name.isEmpty) continue;
          final first = name.split('/').first;
          if (first.isNotEmpty) rootEntries.add(first);
        }
        final bool shouldCreateFolder;
        if (rootEntries.length == 1) {
          final single = rootEntries.first;
          final isFolder = all.any((e) {
            final n = _normalizeForMatch(e.path);
            return n == single || n.startsWith('$single/');
          }) && all.any((e) => _normalizeForMatch(e.path).startsWith('$single/'));
          shouldCreateFolder = !isFolder;
        } else {
          shouldCreateFolder = true;
        }
        if (shouldCreateFolder) {
          destDir = p.join(destinationDir, p.basenameWithoutExtension(archivePath));
          Directory(destDir).createSync(recursive: true);
        }
      }

      // 目录条目（含空目录）先建，保证空目录也被还原
      for (final d in dirs) {
        Directory(p.join(destDir, d.path)).createSync(recursive: true);
      }

      final totalBytes = files.fold<int>(0, (s, e) => s + e.uncompressedSize);
      var done = 0;
      var idx = 0;
      for (final e in files) {
        idx++;
        final outFile = File(p.join(destDir, e.path));
        outFile.parent.createSync(recursive: true);
        final sink = outFile.openWrite();
        var written = 0;
        try {
          await for (final chunk in archive.openRead(e)) {
            sink.add(chunk);
            written += chunk.length;
            onProgress?.call(
              e.path,
              done + written,
              totalBytes,
              written,
              e.uncompressedSize,
              totalBytes <= 0 ? 0.0 : (done + written) / totalBytes,
              idx,
              files.length,
            );
          }
        } finally {
          await sink.flush();
          await sink.close();
        }
        done += e.uncompressedSize;
      }
      return destDir;
    } finally {
      await archive.close();
    }
  }

  /// 用 koni_archive 列出 .7z/.rar 条目，构造 package:archive 的 [Archive]
  /// （仅名称 + 大小，不含内容），供 ArchiveViewerScreen 浏览树使用。
  static Future<Archive> _listKoniArchive(String archivePath, String? password) async {
    final pw = (password != null && password.isNotEmpty) ? password : null;
    final src = await koni.openArchiveFile(
      archivePath,
      options: koni.ArchiveReadOptions(password: pw),
    );
    try {
      final out = Archive();
      for (final e in src.entries) {
        var name = _fixZipFilename(e.path);
        if (name.isEmpty) continue;
        if (e.isDirectory && !name.endsWith('/')) name = '$name/';
        final af = ArchiveFile(name, e.uncompressedSize, null);
        af.isFile = e.isFile;
        out.addFile(af);
      }
      return out;
    } finally {
      await src.close();
    }
  }

  /// 从 .7z/.rar 中读取指定内部路径的条目内容（隔离区内完成，只回传字节）。
  static Future<Map<String, Uint8List?>> _extractKoniEntriesToBytes(
      String archivePath, List<String> requested, String? password) async {
    final result = <String, Uint8List?>{for (final p in requested) p: null};
    final pw = (password != null && password.isNotEmpty) ? password : null;
    final archive = await koni.openArchiveFile(
      archivePath,
      options: koni.ArchiveReadOptions(password: pw),
    );
    try {
      final byPath = <String, koni.ArchiveEntry>{};
      for (final e in archive.entries) {
        if (!e.isFile || e.path.isEmpty) continue;
        byPath[_normalizeForMatch(_fixZipFilename(e.path))] = e;
      }
      for (final p in requested) {
        final entry = byPath[p];
        if (entry == null) continue;
        try {
          result[p] = await archive.readBytes(entry);
        } catch (_) {
          result[p] = null;
        }
      }
    } finally {
      await archive.close();
    }
    return result;
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

  static Future<void> _decodeArchiveTask(Map<String, dynamic> args) async {
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

      // 2.5) .7z / .rar：koni_archive 纯 Dart 解码（支持密码）
      if (isKoniArchivePath(lowerPath)) {
        await extractKoniArchive(
          archivePath: archivePath,
          destinationDir: destinationDir,
          password: password,
          wrapInSubfolder: false,
        );
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
        archive = decodeZip(input, pwdStr, requirePasswordIfEncrypted: true);
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
          archive = decodeZip(input, pwdStr, requirePasswordIfEncrypted: true);
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

  static Future<Map<String, Uint8List?>> _extractEntriesToBytesTask(
      Map<String, dynamic> args) async {
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
      if (isKoniArchivePath(archivePath)) {
        return await _extractKoniEntriesToBytes(archivePath, requested, pwdStr);
      }
      final input = InputFileStream(archivePath);
      try {
        final archive = decodeZip(input, pwdStr, requirePasswordIfEncrypted: true);
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

  static Future<Archive?> _readArchiveTask(Map<String, dynamic> args) async {
    final archivePath = args['archivePath'] as String;
    final password = args['password'] as String?;
    final pwdStr = (password != null && password.isNotEmpty) ? password : null;

    try {
      final file = File(archivePath);
      if (!file.existsSync() || file.lengthSync() == 0) return Archive();
      final lowerPath = archivePath.toLowerCase();
      if (isKoniArchivePath(lowerPath)) {
        return await _listKoniArchive(archivePath, pwdStr);
      }

      File? tempTar;
      try {
        late Archive archive;
        if (lowerPath.endsWith('.zip') || lowerPath.contains('.zip.')) {
          final input = InputFileStream(archivePath);
          try {
            archive = decodeZip(input, pwdStr);
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
              archive = decodeZip(input, pwdStr);
            } finally { try { input.closeSync(); } catch (_) {} }
          }
        } else {
          final input = InputFileStream(archivePath);
          try {
            archive = decodeZip(input, pwdStr);
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

  // ==================== zip:// 虚拟路径写操作（重写式，仅 .zip） ====================
  //
  // zip 格式没有原位删除/改名/追加的公开结构（中央目录之后全是 EOCD），任何写操作
  // 都等于「整包重写」。为满足「失败不破坏原包」的硬要求，任务在 compute 隔离区内
  // 完成解码 → 修改条目集 → 编码 → 写**临时文件**；原文件由调用方在成功后原子替换
  // （rename），任何一步失败原 zip 都完好无损。

  /// 通用 zip 重写：删除条目 / 改名（目录=子树前缀）/ 追加字节条目。
  ///
  /// - [deletePaths]：要删除的内部路径；目录以 `/` 结尾（按前缀删除整棵子树），
  ///   文件为精确名。名称按 `_normalizeForMatch` 归一化后比对。
  /// - [renamePaths]：旧内部路径 -> 新内部路径；目录 key 以 `/` 结尾（整棵子树
  ///   前缀替换），文件为精确名。多个 key 按「最长优先」匹配。
  /// - [addEntries]：新条目内部路径 -> 内容；value 为 null 表示**空目录条目**
  ///   （isFile=false）。同名旧条目不会自动覆盖，调用方需自行加入 [deletePaths]。
  ///
  /// 结果写到 [tempOutputPath]（必须是调用方可原子 rename 到原路径的同分区路径）。
  /// 返回是否成功；失败时调用方应删除残留临时文件，原 zip 不受影响。
  static Future<bool> rewriteZipArchive({
    required String archivePath,
    required String tempOutputPath,
    List<String> deletePaths = const <String>[],
    Map<String, String> renamePaths = const <String, String>{},
    Map<String, Uint8List?> addEntries = const <String, Uint8List?>{},
  }) {
    return compute(_rewriteZipArchiveTask, <String, dynamic>{
      'archivePath': archivePath,
      'tempOutputPath': tempOutputPath,
      'deletePaths': deletePaths,
      'renamePaths': renamePaths,
      'addEntries': addEntries,
    });
  }

  /// 匹配「删除目标」：目录（`/` 结尾）按前缀整树删除，文件精确匹配。
  static bool _zipDeleteMatches(String name, List<String> deletePaths) {
    for (final toDel in deletePaths) {
      if (toDel.endsWith('/')) {
        if (name.startsWith(toDel) || name == toDel.substring(0, toDel.length - 1)) {
          return true;
        }
      } else if (name == toDel) {
        return true;
      }
    }
    return false;
  }

  /// 应用「改名」：目录 key（`/` 结尾）做子树前缀替换，文件 key 精确替换。
  /// key 按长度降序匹配（长前缀优先，避免 `a/` 抢走本该 `a/b/` 的条目）。
  /// 返回 null 表示该条目已被改名目标删除（不应发生，防御式跳过）。
  static String? _zipApplyRename(String name, List<MapEntry<String, String>> sortedRenames) {
    for (final r in sortedRenames) {
      if (r.key.endsWith('/')) {
        if (name.startsWith(r.key)) return r.value + name.substring(r.key.length);
        if (name == r.key.substring(0, r.key.length - 1)) {
          return r.value.endsWith('/') ? r.value : '${r.value}/';
        }
      } else if (name == r.key) {
        return r.value;
      }
    }
    return name;
  }

  static bool _rewriteZipArchiveTask(Map<String, dynamic> args) {
    final archivePath = args['archivePath'] as String;
    final tempOutputPath = args['tempOutputPath'] as String;
    final deletePaths = (args['deletePaths'] as List).cast<String>().map(_normalizeForMatch).toList();
    final sortedRenames = (args['renamePaths'] as Map)
        .cast<String, String>()
        .entries
        .map((e) => MapEntry(_normalizeForMatch(e.key), _normalizeForMatch(e.value)))
        .toList()
      ..sort((a, b) => b.key.length.compareTo(a.key.length));
    final addEntries = (args['addEntries'] as Map).cast<String, Uint8List?>();

    // 输入流必须**存活到编码结束**：archive 包 ZipDecoder.decodeBuffer 生成的
    // ArchiveFile 内容是共享 FileBuffer 的惰性窗口（ZipFile.readBytes 返回
    // InputFileStream.clone，仅预读首页），并非全量内存化。若在 ZipEncoder.encode
    // 之前 closeSync，FileBuffer 被关闭（_fileSize=0 且句柄失效），编码阶段读
    // content 时对已关闭句柄 _readBuffer/readInto 必然抛异常 —— 表现为重写任务
    // 恒失败，zip 内删除/改名/粘贴全部「静默无效果」。因此 closeSync 放 finally，
    // 保证编码与写盘完成后才释放。
    try {
      final srcFile = File(archivePath);
      if (!srcFile.existsSync() || srcFile.lengthSync() == 0) return false;

      // 1) 解码原包（条目内容为惰性窗口，编码期间仍需从输入流读取）
      final input = InputFileStream(archivePath);
      try {
        final oldArchive = ZipDecoder().decodeBuffer(input);

        // 2) 构建新条目集：旧条目（过滤/改名）+ 追加条目（从 bytes 构造）
        final out = Archive();
        for (int i = 0; i < oldArchive.length; i++) {
          final f = oldArchive[i];
          final name = _normalizeForMatch(f.name);
          if (name.isEmpty) continue;
          if (_zipDeleteMatches(name, deletePaths)) continue;
          final newName = _zipApplyRename(name, sortedRenames);
          if (newName == null || newName.isEmpty) continue;
          if (newName == name) {
            // 未改名：原条目直接搬入（编码时经仍打开的输入流按需读取）
            out.addFile(f);
          } else {
            // 改名：ArchiveFile.name 只能构造时指定，须从 bytes 重建（保留修改时间）
            final content = f.content;
            final bytes = content is Uint8List
                ? content
                : content is List<int> ? Uint8List.fromList(content) : Uint8List(0);
            final nf = ArchiveFile(newName, bytes.length, bytes);
            nf.isFile = f.isFile;
            if (f.lastModTime != null && f.lastModTime! > 0) nf.lastModTime = f.lastModTime;
            out.addFile(nf);
          }
        }
        for (final e in addEntries.entries) {
          final name = _normalizeForMatch(e.key);
          if (name.isEmpty) continue;
          final bytes = e.value;
          if (bytes == null) {
            // 空目录条目（与 _encodeArchiveTask 的空目录构造方式一致）
            final dirName = name.endsWith('/') ? name : '$name/';
            final af = ArchiveFile(dirName, 0, null);
            af.isFile = false;
            out.addFile(af);
          } else {
            final af = ArchiveFile(name, bytes.length, bytes);
            out.addFile(af);
          }
        }

        // 3) 编码并写临时文件（level 6 与创建压缩包的默认档一致）
        final encoded = ZipEncoder().encode(out, level: 6);
        if (encoded == null || encoded.isEmpty) return false;
        File(tempOutputPath)
          ..createSync(recursive: true)
          ..writeAsBytesSync(encoded is Uint8List ? encoded : Uint8List.fromList(encoded));
        return true;
      } finally {
        try { input.closeSync(); } catch (_) {}
      }
    } catch (e) {
      debugPrint('Error rewriting zip archive: $e');
      return false;
    }
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
