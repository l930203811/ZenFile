/// 加密目录枚举与原地加解密操作
///
/// 提供加密目录的文件列表枚举（自动解密文件名），
/// 以及文件/文件夹的原地加密和解密操作。
library;

import 'dart:io';
import 'package:path/path.dart' as p;
import 'crypt_config.dart';
import 'crypt_mount.dart';
import 'filename_cipher.dart';
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

  /// 是否真实被加密（文件名/目录名解密成功）。
  /// 用于浏览页只给真实加密的条目显示🔐角标，其余正常显示。
  final bool isEncrypted;

  CryptFileEntry({
    required this.name,
    required this.virtualPath,
    required this.physicalPath,
    required this.isDirectory,
    this.size = 0,
    required this.modified,
    this.isEncrypted = false,
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
    // 将虚拟路径转换为物理路径。
    //
    // ⚠️ 必须用 resolvePhysicalPath，不能直接用 virtualToPhysical：
    // 后者对**最后一段**统一走 encryptFileName（会追加加密后缀），而目录名在
    // rclone 里是不带后缀的 —— 于是「点击加密文件夹进入」时算出的
    // `<密文目录名>.bin` 在磁盘上根本不存在 → 抛 Directory not found →
    // 浏览页整目录空白（用户看到的「文件夹消失 / 打不开」）。
    // resolvePhysicalPath 内含「去后缀重试 + 目录扫描反查」两级兜底。
    var physicalDirPath = await _mount.resolvePhysicalPath(virtualDirPath);
    if (!await Directory(physicalDirPath).exists()) {
      if (await Directory(virtualDirPath).exists()) {
        // 挂载点内「未加密的普通子目录」：本身就是明文，直接按明文枚举
        physicalDirPath = virtualDirPath;
      } else {
        throw FileSystemException('Directory not found', physicalDirPath);
      }
    }

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
        isEncrypted: decryptionSucceeded,
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

  /// 名字是否**可能**是 rclone crypt 密文（纯字符串判定：零 I/O、零密钥派生）。
  ///
  /// 依据严格对齐 [FilenameCipher]：密文主体 = PKCS7 补齐到 16 字节倍数后的
  /// EME 密文，再经 base32/base64 编码。因此「去掉配置后缀后能被对应编码解出、
  /// 且字节数是 16 的倍数」才可能成立（base32768 例外，见实现内注释）。
  /// 这一步能滤掉绝大多数普通名字
  /// （DCIM / Download / Android / IMG_20260101.jpg …），
  /// 用于「该目录到底该不该按加密目录处理」的低成本预筛。
  ///
  /// ⚠️ 只是**必要非充分**条件：命中后仍需按文件头的 RCLONE magic 二次确认。
  static bool mayBeCipherName(String name, RcloneCryptConfig config) {
    final stems = <String>[name];
    final suffix = config.encryptedSuffix;
    // 文件名解密会先剥掉配置后缀；目录名解密不剥后缀 —— 两种形态都要试。
    // （顺带兼容「后缀配置与加密时不一致」，如 OpenList 空后缀 + 本地 .bin）
    if (suffix.isNotEmpty && name.endsWith(suffix)) {
      stems.add(name.substring(0, name.length - suffix.length));
    }
    for (final stem in stems) {
      if (stem.isEmpty) continue;
      try {
        final raw = decodeFilename(stem, config.filenameEncoding);
        if (raw.isEmpty) continue;
        if (config.filenameEncoding == FilenameEncoding.base32768) {
          // base32768 每字符承载 15 bit，而 15*字符数 不是 8 的倍数，
          // 解码得到的字节数**不必然是** 16 的倍数，只能做长度下限判定。
          if (raw.length >= nameCipherBlockSize) return true;
        } else if (raw.length % nameCipherBlockSize == 0) {
          return true;
        }
      } catch (_) {}
    }
    return false;
  }

  /// 读文件头判断是否为真实的 rclone crypt 密文（比对 RCLONE magic）。
  static Future<bool> isEncryptedFile(String path) async {
    try {
      final file = File(path);
      if (!await file.exists()) return false;
      final raf = await file.open(mode: FileMode.read);
      try {
        final head = await raf.read(fileMagicSize);
        if (head.length < fileMagicSize) return false;
        for (var i = 0; i < fileMagicSize; i++) {
          if (head[i] != fileHeaderMagicBytes[i]) return false;
        }
        return true;
      } finally {
        await raf.close();
      }
    } catch (_) {
      return false;
    }
  }

  /// 目录内是否**确实**存在 rclone crypt 密文。
  ///
  /// 用于判断「未被任何持久化挂载点覆盖的目录」（典型：存储根目录 ——
  /// 根挂载点会命中全盘所有路径，因此被禁止）该不该按加密目录处理。
  /// 只有目录内**确有**密文时才返回 true，普通目录一律 false，
  /// 避免把整个存储卷进加密视图。
  ///
  /// [maxEntries] 限制扫描条目数，防止超大目录带来额外开销。
  static Future<bool> dirContainsCiphertext(
    String dirPath, {
    required RcloneCryptConfig config,
    int maxEntries = 2000,
  }) async {
    try {
      final dir = Directory(dirPath);
      if (!await dir.exists()) return false;
      var scanned = 0;
      await for (final entity in dir.list(followLinks: false)) {
        if (++scanned > maxEntries) break;
        final name = p.basename(entity.path);
        // 跳过 rclone 配置文件与加解密中途的临时残留
        if (name == 'rclone.conf' || name == '.rclone.conf') continue;
        if (name.endsWith(tmpSuffix)) continue;
        if (!mayBeCipherName(name, config)) continue;
        if (entity is File) {
          if (await isEncryptedFile(entity.path)) return true;
        } else {
          // 目录读不到 magic 头：通过名字级筛查（密文长度必为 16 的倍数）即认定
          return true;
        }
      }
      return false;
    } catch (_) {
      return false;
    }
  }

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

  /// 加密单个文件到**指定目标路径**（非破坏性，保留源文件）。
  ///
  /// 与 [encryptFile]（原地替换、删源）不同：本方法把 [sourcePath] 加密后写入
  /// [destEncryptedPath]，**不动源文件**。用于「复制明文文件到加密目录」「把加密
  /// 文件解密到另一个明文目录（复制场景，源密文保留）」等需求。
  ///
  /// 沿用流式 + 原子写（先写 `*.zencrypt_tmp`，成功后才改名）机制，
  /// 中途失败只清理临时文件，不破坏 [sourcePath]。
  Future<String> encryptFileTo(String sourcePath, String destEncryptedPath) async {
    final sourceFile = File(sourcePath);
    if (!await sourceFile.exists()) {
      throw FileSystemException('File not found', sourcePath);
    }
    final sourceStat = await sourceFile.stat();

    // 确保目标父目录存在（例如把加密文件落到之前不存在的目录）
    final destParent = Directory(p.dirname(destEncryptedPath));
    if (!await destParent.exists()) {
      await destParent.create(recursive: true);
    }

    final tmpPath = '$destEncryptedPath$_tmpSuffix';
    final tmpFile = File(tmpPath);
    RandomAccessFile? raf;
    try {
      raf = await tmpFile.open(mode: FileMode.write);
      final encrypter = _mount.crypt.createEncrypter();
      await for (final chunk in sourceFile.openRead()) {
        final out = encrypter.process(chunk);
        if (out.isNotEmpty) await raf.writeFrom(out);
      }
      final tail = encrypter.finish();
      if (tail.isNotEmpty) await raf.writeFrom(tail);
      await raf.close();
      raf = null;

      await tmpFile.setLastModified(sourceStat.modified);

      // 目标已存在则先删再替换（覆盖写入）
      if (await File(destEncryptedPath).exists()) {
        await File(destEncryptedPath).delete();
      }
      await tmpFile.rename(destEncryptedPath);
      return destEncryptedPath;
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

  /// 解密单个加密文件到**指定明文目标路径**（非破坏性，保留源密文）。
  ///
  /// 与 [decryptFile]（原地替换、删密文）不同：本方法把 [encryptedPath] 解密后
  /// 写入 [destPlainPath]，**不动源密文**。用于「复制密文文件到明文目录」等
  /// 非破坏性场景。同样采用流式 + 原子写。
  Future<String> decryptFileTo(String encryptedPath, String destPlainPath) async {
    final encryptedFile = File(encryptedPath);
    if (!await encryptedFile.exists()) {
      throw FileSystemException('Encrypted file not found', encryptedPath);
    }
    final sourceStat = await encryptedFile.stat();

    final destParent = Directory(p.dirname(destPlainPath));
    if (!await destParent.exists()) {
      await destParent.create(recursive: true);
    }

    final tmpPath = '$destPlainPath$_tmpSuffix';
    final tmpFile = File(tmpPath);
    RandomAccessFile? raf;
    try {
      raf = await tmpFile.open(mode: FileMode.write);
      final decrypter = _mount.crypt.createDecrypter();
      await for (final chunk in encryptedFile.openRead()) {
        final out = decrypter.process(chunk);
        if (out.isNotEmpty) await raf.writeFrom(out);
      }
      final tail = decrypter.finish();
      if (tail.isNotEmpty) await raf.writeFrom(tail);
      await raf.close();
      raf = null;

      await tmpFile.setLastModified(sourceStat.modified);

      if (await File(destPlainPath).exists()) {
        await File(destPlainPath).delete();
      }
      await tmpFile.rename(destPlainPath);
      return destPlainPath;
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

  /// 原子写入时使用的临时文件后缀。
  ///
  /// 公开常量：浏览层做「目录内是否含密文」探测时也要跳过这些残留临时文件，
  /// 否则失败残留会被误判成密文条目。
  static const String tmpSuffix = '.zencrypt_tmp';

  /// 兼容旧引用（内部使用）
  static const String _tmpSuffix = tmpSuffix;

  /// 加密文件夹（递归加密所有文件和子文件夹）
  ///
  /// [sourceDirPath] 源文件夹路径
  /// [onProgress] 进度回调（已处理文件数，总文件数）
  /// [skipEncrypted] 为 true 时跳过「已经是 rclone/OpenList 加密」的文件
  ///   （文件头带 RCLONE magic）和已加密的目录名，避免对导入文件夹里
  ///   混有的已加密文件做二次加密（二次加密会破坏文件）。用于保险箱「导入并
  ///   原地加密」一个含加密+普通文件混合的文件夹。
  Future<void> encryptDirectory(
    String sourceDirPath, {
    void Function(int processed, int total)? onProgress,
    bool skipEncrypted = false,
  }) async {
    // 先统计文件总数
    final allFiles = await _listAllFiles(sourceDirPath);
    final total = allFiles.length;
    var processed = 0;

    // 递归加密（从最深层开始，避免路径变化影响）
    await _encryptDirectoryRecursive(
      sourceDirPath,
      (file) async {
        if (skipEncrypted && await _isEncryptedFile(file)) {
          // 已加密文件：跳过，但仍计入进度，避免进度卡在中途
          processed++;
          onProgress?.call(processed, total);
          return;
        }
        await encryptFile(file);
        processed++;
        onProgress?.call(processed, total);
      },
      skipEncrypted: skipEncrypted,
    );

    // 最后加密文件夹名称本身（如果不是挂载点根目录）
    if (!p.equals(sourceDirPath, _mount.physicalPath)) {
      final dir = p.dirname(sourceDirPath);
      final dirName = p.basename(sourceDirPath);
      // 已加密的目录名不再重复加密
      var alreadyEncryptedDir = false;
      if (skipEncrypted) {
        try {
          _mount.crypt.decryptDirName(dirName);
          alreadyEncryptedDir = true;
        } catch (_) {}
      }
      if (!alreadyEncryptedDir) {
        final encryptedDirName = _mount.crypt.encryptDirName(dirName);
        final encryptedDirPath = p.join(dir, encryptedDirName);
        await Directory(sourceDirPath).rename(encryptedDirPath);
      }
    }
  }

  /// 递归加密目录内部的文件
  Future<void> _encryptDirectoryRecursive(
    String dirPath,
    Future<void> Function(String file) processFile, {
    bool skipEncrypted = false,
  }) async {
    final dir = Directory(dirPath);
    final entities = await dir.list().toList();

    for (final entity in entities) {
      if (entity is Directory) {
        await _encryptDirectoryRecursive(
          entity.path,
          processFile,
          skipEncrypted: skipEncrypted,
        );
        // 加密子目录名称（已加密的跳过）
        final parentDir = p.dirname(entity.path);
        final dirName = p.basename(entity.path);
        var alreadyEncryptedDir = false;
        if (skipEncrypted) {
          try {
            _mount.crypt.decryptDirName(dirName);
            alreadyEncryptedDir = true;
          } catch (_) {}
        }
        if (!alreadyEncryptedDir) {
          final encryptedDirName = _mount.crypt.encryptDirName(dirName);
          final encryptedDirPath = p.join(parentDir, encryptedDirName);
          await entity.rename(encryptedDirPath);
        }
      } else if (entity is File) {
        await processFile(entity.path);
      }
    }
  }

  /// 判断物理文件是否已为 rclone/OpenList 加密（文件头带 RCLONE magic）
  Future<bool> _isEncryptedFile(String path) async {
    try {
      final file = File(path);
      if (!await file.exists()) return false;
      final raf = await file.open(mode: FileMode.read);
      try {
        final head = await raf.read(fileMagicSize);
        if (head.length < fileMagicSize) return false;
        for (var i = 0; i < fileMagicSize; i++) {
          if (head[i] != fileHeaderMagicBytes[i]) return false;
        }
        return true;
      } finally {
        await raf.close();
      }
    } catch (_) {
      return false;
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
