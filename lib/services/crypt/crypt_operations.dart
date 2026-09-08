/// 加密目录枚举与原地加解密操作
///
/// 提供加密目录的文件列表枚举（自动解密文件名），
/// 以及文件/文件夹的原地加密和解密操作。
library;

import 'dart:io';
import 'package:path/path.dart' as p;
import 'crypt_mount.dart';
import 'stream_cipher.dart';
import 'rclone_crypt.dart';

/// 加密文件项（枚举目录时返回）
class CryptFileEntry {
  /// 解密后的文件名
  final String name;

  /// 解密后的完整路径（虚拟路径）
  final String virtualPath;

  /// 加密后的完整路径（物理路径）
  final String physicalPath;

  /// 是否为目录
  final bool isDirectory;

  /// 解密后的文件大小（仅文件有效）
  final int size;

  /// 最后修改时间
  final DateTime modified;

  CryptFileEntry({
    required this.name,
    required this.virtualPath,
    required this.physicalPath,
    required this.isDirectory,
    this.size = 0,
    required this.modified,
  });

  /// 文件扩展名（解密后的）
  String get extension => p.extension(name);
}

/// 加密目录枚举器
class CryptDirectoryLister {
  final CryptMountPoint _mount;

  CryptDirectoryLister(this._mount);

  /// 枚举加密目录中的文件和子目录
  ///
  /// [virtualDirPath] 解密后的目录路径（虚拟路径）
  /// [showHidden] 是否显示隐藏文件
  /// [onlyEncrypted] 为 true 时只返回文件名/目录名能被成功解密的条目，
  ///   用于「保险箱-原地加密」列表，避免把挂载点内未加密的普通文件也显示成已加密。
  Future<List<CryptFileEntry>> listDirectory(
    String virtualDirPath, {
    bool showHidden = false,
    bool onlyEncrypted = false,
  }) async {
    // 将虚拟路径转换为物理路径
    final physicalDirPath = _mount.virtualToPhysical(virtualDirPath);

    final dir = Directory(physicalDirPath);
    if (!await dir.exists()) {
      throw FileSystemException('Directory not found', physicalDirPath);
    }

    final entries = <CryptFileEntry>[];
    final entities = await dir.list().toList();

    for (final entity in entities) {
      final physicalName = p.basename(entity.path);

      // 跳过 rclone crypt 的配置文件
      if (physicalName == 'rclone.conf' || physicalName == '.rclone.conf') {
        continue;
      }

      // 跳过加/解密中途的临时文件（失败残留时不应显示给用户）
      if (physicalName.endsWith(CryptOperations._tmpSuffix)) {
        continue;
      }

      // 尝试解密文件名
      String virtualName;
      var decryptionSucceeded = false;
      try {
        if (entity is Directory) {
          virtualName = _mount.crypt.decryptDirName(physicalName);
        } else {
          virtualName = _mount.crypt.decryptFileName(physicalName);
        }
        decryptionSucceeded = true;
      } catch (_) {
        // 解密失败，可能不是加密文件，保留原名
        virtualName = physicalName;
      }

      // 保险箱「原地加密」列表只应显示真实已加密的文件/目录
      if (onlyEncrypted && !decryptionSucceeded) {
        continue;
      }

      // 隐藏文件过滤
      if (!showHidden && virtualName.startsWith('.')) {
        continue;
      }

      // 计算文件大小（解密后的大小）
      var size = 0;
      if (entity is File) {
        try {
          final stat = await entity.stat();
          size = calculateDecryptedSize(stat.size);
        } catch (_) {
          size = 0;
        }
      }

      final stat = await entity.stat();

      entries.add(CryptFileEntry(
        name: virtualName,
        virtualPath: p.join(virtualDirPath, virtualName),
        physicalPath: entity.path,
        isDirectory: entity is Directory,
        size: size,
        modified: stat.modified,
      ));
    }

    // 按名称排序
    entries.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));

    return entries;
  }
}

/// 原地加密/解密操作
class CryptOperations {
  final CryptMountPoint _mount;

  CryptOperations(this._mount);

  /// 加密单个文件（原地加密）
  ///
  /// 将普通文件加密为 crypt 格式，加密后原文件被替换为加密文件。
  ///
  /// 实现要点（修复「加密到一半卡死」）：
  /// - **流式处理**：按 64KiB 分块读 → 加密 → 写，内存占用恒定，
  ///   不再把整个文件 `readAsBytes()` 读进内存（大文件会 OOM）。
  /// - **原子写入**：先写 `*.zencrypt_tmp`，成功后才删除原文件并改名，
  ///   中途失败/取消时原文件保持完好，不会丢数据。
  /// - 保留原文件修改时间。
  Future<String> encryptFile(String sourcePath) async {
    final sourceFile = File(sourcePath);
    if (!await sourceFile.exists()) {
      throw FileSystemException('File not found', sourcePath);
    }

    // 提前取时间戳（删除后读不到）
    final sourceStat = await sourceFile.stat();

    final dir = p.dirname(sourcePath);
    final fileName = p.basename(sourcePath);
    final encryptedFileName = _mount.crypt.encryptFileName(fileName);
    final encryptedPath = p.join(dir, encryptedFileName);

    final tmpPath = '$encryptedPath$_tmpSuffix';
    final tmpFile = File(tmpPath);

    RandomAccessFile? raf;
    try {
      raf = await tmpFile.open(mode: FileMode.write);
      final encrypter = _mount.crypt.createEncrypter();

      // 流式：分块读取 → 加密 → 写盘
      await for (final chunk in sourceFile.openRead()) {
        final out = encrypter.process(chunk);
        if (out.isNotEmpty) {
          await raf.writeFrom(out);
        }
      }
      final tail = encrypter.finish();
      if (tail.isNotEmpty) {
        await raf.writeFrom(tail);
      }
      await raf.close();
      raf = null;

      await tmpFile.setLastModified(sourceStat.modified);

      // 原子替换：先删原文件，再把临时文件改名为最终名
      await sourceFile.delete();
      await tmpFile.rename(encryptedPath);

      return encryptedPath;
    } catch (e) {
      // 任何失败都清理临时文件，原文件保持不变
      if (raf != null) {
        try {
          await raf.close();
        } catch (_) {}
      }
      if (await tmpFile.exists()) {
        try {
          await tmpFile.delete();
        } catch (_) {}
      }
      rethrow;
    }
  }

  /// 解密单个文件（原地解密）
  ///
  /// 同样采用流式处理 + 原子写入，避免大文件 OOM 与中断丢数据。
  Future<String> decryptFile(String encryptedPath) async {
    final encryptedFile = File(encryptedPath);
    if (!await encryptedFile.exists()) {
      throw FileSystemException('Encrypted file not found', encryptedPath);
    }

    final sourceStat = await encryptedFile.stat();

    final dir = p.dirname(encryptedPath);
    final encryptedFileName = p.basename(encryptedPath);
    final decryptedFileName = _mount.crypt.decryptFileName(encryptedFileName);
    final decryptedPath = p.join(dir, decryptedFileName);

    final tmpPath = '$decryptedPath$_tmpSuffix';
    final tmpFile = File(tmpPath);

    RandomAccessFile? raf;
    try {
      raf = await tmpFile.open(mode: FileMode.write);
      final decrypter = _mount.crypt.createDecrypter();

      await for (final chunk in encryptedFile.openRead()) {
        final out = decrypter.process(chunk);
        if (out.isNotEmpty) {
          await raf.writeFrom(out);
        }
      }
      final tail = decrypter.finish();
      if (tail.isNotEmpty) {
        await raf.writeFrom(tail);
      }
      await raf.close();
      raf = null;

      await tmpFile.setLastModified(sourceStat.modified);

      await encryptedFile.delete();
      await tmpFile.rename(decryptedPath);

      return decryptedPath;
    } catch (e) {
      if (raf != null) {
        try {
          await raf.close();
        } catch (_) {}
      }
      if (await tmpFile.exists()) {
        try {
          await tmpFile.delete();
        } catch (_) {}
      }
      rethrow;
    }
  }

  /// 原子写入时使用的临时文件后缀
  static const String _tmpSuffix = '.zencrypt_tmp';

  /// 加密文件夹（递归加密所有文件和子文件夹）
  ///
  /// [sourceDirPath] 源文件夹路径
  /// [onProgress] 进度回调（已处理文件数，总文件数）
  Future<void> encryptDirectory(
    String sourceDirPath, {
    void Function(int processed, int total)? onProgress,
  }) async {
    // 先统计文件总数
    final allFiles = await _listAllFiles(sourceDirPath);
    final total = allFiles.length;
    var processed = 0;

    // 递归加密（从最深层开始，避免路径变化影响）
    await _encryptDirectoryRecursive(sourceDirPath, (file) async {
      await encryptFile(file);
      processed++;
      onProgress?.call(processed, total);
    });

    // 最后加密文件夹名称本身（如果不是挂载点根目录）
    if (!p.equals(sourceDirPath, _mount.physicalPath)) {
      final dir = p.dirname(sourceDirPath);
      final dirName = p.basename(sourceDirPath);
      final encryptedDirName = _mount.crypt.encryptDirName(dirName);
      final encryptedDirPath = p.join(dir, encryptedDirName);
      await Directory(sourceDirPath).rename(encryptedDirPath);
    }
  }

  /// 递归加密目录内部的文件
  Future<void> _encryptDirectoryRecursive(
    String dirPath,
    Future<void> Function(String file) processFile,
  ) async {
    final dir = Directory(dirPath);
    final entities = await dir.list().toList();

    for (final entity in entities) {
      if (entity is Directory) {
        await _encryptDirectoryRecursive(entity.path, processFile);
        // 加密子目录名称
        final parentDir = p.dirname(entity.path);
        final dirName = p.basename(entity.path);
        final encryptedDirName = _mount.crypt.encryptDirName(dirName);
        final encryptedDirPath = p.join(parentDir, encryptedDirName);
        await entity.rename(encryptedDirPath);
      } else if (entity is File) {
        await processFile(entity.path);
      }
    }
  }

  /// 解密文件夹（递归解密所有文件和子文件夹）
  Future<void> decryptDirectory(
    String encryptedDirPath, {
    void Function(int processed, int total)? onProgress,
  }) async {
    // 先统计文件总数
    final allFiles = await _listAllFiles(encryptedDirPath);
    final total = allFiles.length;
    var processed = 0;

    // 递归解密
    await _decryptDirectoryRecursive(encryptedDirPath, (file) async {
      await decryptFile(file);
      processed++;
      onProgress?.call(processed, total);
    });

    // 最后解密文件夹名称本身
    if (!p.equals(encryptedDirPath, _mount.physicalPath)) {
      final dir = p.dirname(encryptedDirPath);
      final encryptedDirName = p.basename(encryptedDirPath);
      final decryptedDirName = _mount.crypt.decryptDirName(encryptedDirName);
      final decryptedDirPath = p.join(dir, decryptedDirName);
      await Directory(encryptedDirPath).rename(decryptedDirPath);
    }
  }

  /// 递归解密目录内部的文件
  Future<void> _decryptDirectoryRecursive(
    String dirPath,
    Future<void> Function(String file) processFile,
  ) async {
    final dir = Directory(dirPath);
    final entities = await dir.list().toList();

    for (final entity in entities) {
      if (entity is Directory) {
        await _decryptDirectoryRecursive(entity.path, processFile);
        // 解密子目录名称
        final parentDir = p.dirname(entity.path);
        final encryptedDirName = p.basename(entity.path);
        try {
          final decryptedDirName = _mount.crypt.decryptDirName(encryptedDirName);
          final decryptedDirPath = p.join(parentDir, decryptedDirName);
          await entity.rename(decryptedDirPath);
        } catch (_) {
          // 解密失败，保留原名
        }
      } else if (entity is File) {
        await processFile(entity.path);
      }
    }
  }

  /// 列出目录下所有文件（递归）
  Future<List<String>> _listAllFiles(String dirPath) async {
    final files = <String>[];
    final dir = Directory(dirPath);
    if (!await dir.exists()) return files;

    final entities = await dir.list(recursive: true).toList();
    for (final entity in entities) {
      if (entity is File) {
        files.add(entity.path);
      }
    }
    return files;
  }
}
