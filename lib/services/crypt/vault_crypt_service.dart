import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'crypt.dart';
import '../vault_service.dart';

/// 保险箱 Crypt 整合服务
///
/// 将保险箱主密码与 rclone crypt 加密系统整合，提供两种加密模式：
/// - **原地加密（in-place）**：文件留在原目录，加密后文件名变为加密格式，
///   不显示在保险箱列表中，浏览页显示🔐图徽。
/// - **沙盒加密（sandbox）**：文件移动到应用私有目录的 vault 文件夹，
///   显示在保险箱列表中。
///
/// 所有 crypt 挂载点共享同一个密码（保险箱主密码），用户只需记住一个密码。
class VaultCryptService {
  static VaultCryptService? _instance;
  VaultCryptService._();

  /// 获取单例
  static VaultCryptService get instance {
    _instance ??= VaultCryptService._();
    return _instance!;
  }

  /// 沙盒加密目录名称
  static const String _sandboxDirName = 'vault_crypt';

  /// 默认沙盒挂载点名称
  static const String sandboxMountName = '私人保险箱';

  /// 是否已解锁（本次启动应用中已验证保险箱主密码）
  bool _isUnlocked = false;
  String? _unlockedPassword;

  /// 是否已解锁
  bool get isUnlocked => _isUnlocked;

  /// 当前解锁的密码
  String? get unlockedPassword => _unlockedPassword;

  /// 标记为已解锁（在保险箱锁定页面验证密码成功后调用）
  void markUnlocked(String password) {
    _isUnlocked = true;
    _unlockedPassword = password;
  }

  /// 锁定（清除内存中的密码）
  void lock() {
    _isUnlocked = false;
    _unlockedPassword = null;
  }

  /// 获取沙盒加密目录路径
  Future<String> getSandboxDir() async {
    final docDir = await getApplicationDocumentsDirectory();
    final sandboxDir = Directory(p.join(docDir.path, _sandboxDirName));
    if (!await sandboxDir.exists()) {
      await sandboxDir.create(recursive: true);
    }
    // 防止媒体扫描器索引
    final nomedia = File(p.join(sandboxDir.path, '.nomedia'));
    if (!await nomedia.exists()) {
      await nomedia.create();
    }
    return sandboxDir.path;
  }

  /// 获取默认的沙盒 crypt 挂载点配置
  Future<RcloneCryptConfig> getSandboxConfig(String password) async {
    return RcloneCryptConfig(
      password: password,
      filenameEncryption: FilenameEncryption.standard,
      directoryNameEncryption: true,
      filenameEncoding: FilenameEncoding.base32,
      encryptedSuffix: '.bin',
    );
  }

  /// 获取沙盒 crypt 挂载点
  Future<CryptMountPoint?> getSandboxMount() async {
    final mounts = await CryptMountService.loadMountPoints();
    final sandboxDir = await getSandboxDir();
    for (final mount in mounts) {
      if (mount.physicalPath == sandboxDir && mount.isSandboxMode) {
        return mount;
      }
    }
    return null;
  }

  /// 确保沙盒挂载点存在（如果不存在则创建）
  Future<CryptMountPoint> ensureSandboxMount(String password) async {
    final existing = await getSandboxMount();
    if (existing != null) return existing;

    final sandboxDir = await getSandboxDir();
    final config = await getSandboxConfig(password);
    final mount = CryptMountPoint(
      physicalPath: sandboxDir,
      config: config,
      name: sandboxMountName,
      isSandboxMode: true,
    );
    await CryptMountService.addMountPoint(mount);
    return mount;
  }

  /// 检测文件/目录是否已加密（在任意 crypt 挂载点内）
  Future<bool> isEncrypted(String path) async {
    final mounts = await CryptMountService.loadMountPoints();
    for (final mount in mounts) {
      if (mount.containsPath(path)) {
        return true;
      }
    }
    return false;
  }

  /// 检测文件/目录是否为原地加密（非沙盒）
  Future<bool> isInPlaceEncrypted(String path) async {
    final mounts = await CryptMountService.loadMountPoints();
    for (final mount in mounts) {
      if (mount.containsPath(path) && !mount.isSandboxMode) {
        return true;
      }
    }
    return false;
  }

  /// 检测文件/目录是否为沙盒加密
  Future<bool> isSandboxEncrypted(String path) async {
    final sandboxDir = await getSandboxDir();
    final normalizedPath = path.replaceAll('\\', '/');
    final normalizedSandbox = sandboxDir.replaceAll('\\', '/');
    return normalizedPath.startsWith('$normalizedSandbox/') ||
        normalizedPath == normalizedSandbox;
  }

  /// 原地加密文件/目录
  ///
  /// 文件留在原目录，加密后文件名变为加密格式。
  /// 加密完成后会自动创建对应的 crypt 挂载点（如果不存在）。
  Future<void> encryptInPlace({
    required String sourcePath,
    required String password,
    void Function(int processed, int total)? onProgress,
  }) async {
    final sourceEntity = FileSystemEntity.typeSync(sourcePath);
    final isDir = sourceEntity == FileSystemEntityType.directory;
    final parentDir = p.dirname(sourcePath);

    // 确保父目录有对应的 crypt 挂载点
    final mounts = await CryptMountService.loadMountPoints();
    CryptMountPoint? parentMount;
    for (final mount in mounts) {
      if (!mount.isSandboxMode && mount.containsPath(sourcePath)) {
        parentMount = mount;
        break;
      }
    }

    if (parentMount == null) {
      // 创建新的原地加密挂载点
      final config = RcloneCryptConfig(
        password: password,
        filenameEncryption: FilenameEncryption.standard,
        directoryNameEncryption: true,
        filenameEncoding: FilenameEncoding.base32,
        encryptedSuffix: '.bin',
      );
      parentMount = CryptMountPoint(
        physicalPath: parentDir,
        config: config,
        name: p.basename(parentDir),
        isSandboxMode: false,
      );
      await CryptMountService.addMountPoint(parentMount);
    }

    // 执行加密
    final ops = CryptOperations(parentMount);
    if (isDir) {
      await ops.encryptDirectory(sourcePath, onProgress: onProgress);
    } else {
      await ops.encryptFile(sourcePath);
    }
  }

  /// 沙盒加密文件/目录
  ///
  /// 文件移动到应用私有目录的 vault 文件夹，加密后显示在保险箱列表中。
  Future<void> encryptToSandbox({
    required String sourcePath,
    required String password,
    void Function(int processed, int total)? onProgress,
  }) async {
    final sandboxMount = await ensureSandboxMount(password);
    final sourceEntity = FileSystemEntity.typeSync(sourcePath);
    final isDir = sourceEntity == FileSystemEntityType.directory;
    final baseName = p.basename(sourcePath);
    final destPath = p.join(sandboxMount.physicalPath, baseName);

    final ops = CryptOperations(sandboxMount);

    if (isDir) {
      // 目录加密：先复制到沙盒目录，再加密
      final tempDest = Directory(destPath);
      if (await tempDest.exists()) {
        await tempDest.delete(recursive: true);
      }
      await _copyDirectory(Directory(sourcePath), tempDest);
      await ops.encryptDirectory(destPath, onProgress: onProgress);
      // 删除原目录
      await Directory(sourcePath).delete(recursive: true);
    } else {
      // 文件加密：先复制到沙盒目录，再加密（使用原地加密会自动重命名）
      final destFile = File(destPath);
      await File(sourcePath).copy(destPath);
      await ops.encryptFile(destPath);
      // 删除原文件
      final sourceFile = File(sourcePath);
      if (await sourceFile.exists()) {
        await sourceFile.delete();
      }
    }
  }

  /// 解密文件/目录（原地加密的文件解密回原目录）
  Future<void> decryptInPlace({
    required String encryptedPath,
    required String password,
    void Function(int processed, int total)? onProgress,
  }) async {
    final mounts = await CryptMountService.loadMountPoints();
    CryptMountPoint? mount;
    for (final m in mounts) {
      if (m.containsPath(encryptedPath)) {
        mount = m;
        break;
      }
    }

    if (mount == null) {
      throw Exception('未找到对应的加密挂载点');
    }

    final entityType = FileSystemEntity.typeSync(encryptedPath);
    final isDir = entityType == FileSystemEntityType.directory;

    final ops = CryptOperations(mount);
    if (isDir) {
      await ops.decryptDirectory(encryptedPath, onProgress: onProgress);
    } else {
      await ops.decryptFile(encryptedPath);
    }
  }

  /// 从沙盒解密文件/目录回原位置
  Future<void> decryptFromSandbox({
    required String sandboxPath,
    required String originalPath,
    required String password,
    void Function(int processed, int total)? onProgress,
  }) async {
    final sandboxMount = await getSandboxMount();
    if (sandboxMount == null) {
      throw Exception('沙盒挂载点不存在');
    }

    final entityType = FileSystemEntity.typeSync(sandboxPath);
    final isDir = entityType == FileSystemEntityType.directory;

    final ops = CryptOperations(sandboxMount);

    if (isDir) {
      // 目录解密：先解密（原地解密会自动重命名），再移动回原位置
      await ops.decryptDirectory(sandboxPath, onProgress: onProgress);
      // 解密后目录名已恢复，移动回原位置
      final decryptedDir = Directory(sandboxPath);
      final originalDir = Directory(originalPath);
      if (await originalDir.exists()) {
        await originalDir.delete(recursive: true);
      }
      await decryptedDir.rename(originalPath);
    } else {
      // 文件解密：先解密到原位置，再删除沙盒中的加密文件
      await ops.decryptFile(sandboxPath);
      // 解密后文件名已恢复，需要找到解密后的文件并移动
      final dir = Directory(p.dirname(sandboxPath));
      final entities = await dir.list().toList();
      for (final entity in entities) {
        if (entity is File && !entity.path.endsWith('.bin')) {
          final originalFile = File(originalPath);
          if (await originalFile.exists()) {
            await originalFile.delete();
          }
          await entity.rename(originalPath);
          break;
        }
      }
    }
  }

  /// 获取沙盒中的加密文件列表（解密后的文件名）
  Future<List<CryptFileEntry>> listSandboxFiles(String password) async {
    final sandboxMount = await ensureSandboxMount(password);
    final vfs = CryptVFS();
    vfs.mount(sandboxMount);
    final entries = await vfs.listDirectory(sandboxMount.physicalPath);
    return entries;
  }

  /// 复制目录（递归）
  Future<void> _copyDirectory(Directory source, Directory dest) async {
    if (!await dest.exists()) {
      await dest.create(recursive: true);
    }
    await for (final entity in source.list(recursive: false)) {
      if (entity is File) {
        final newPath = p.join(dest.path, p.basename(entity.path));
        await entity.copy(newPath);
      } else if (entity is Directory) {
        final newDir = Directory(p.join(dest.path, p.basename(entity.path)));
        await _copyDirectory(entity, newDir);
      }
    }
  }

  /// 临时解密文件到系统临时目录，返回临时文件路径
  ///
  /// 用于预览保险箱中的文件，使用后应删除临时文件。
  Future<File> decryptToTemp({
    required String encryptedPath,
    required String password,
  }) async {
    final mounts = await CryptMountService.loadMountPoints();
    CryptMountPoint? mount;
    for (final m in mounts) {
      if (m.containsPath(encryptedPath)) {
        mount = m;
        break;
      }
    }

    if (mount == null) {
      throw Exception('未找到对应的加密挂载点');
    }

    // 解密到临时目录
    final tempDir = await getTemporaryDirectory();
    final tempFilePath = p.join(tempDir.path, 'vault_temp_${DateTime.now().millisecondsSinceEpoch}_${p.basename(encryptedPath)}');

    final ops = CryptOperations(mount);
    // 先复制加密文件到临时目录，然后原地解密
    final tempEncryptedPath = '$tempFilePath.enc';
    await File(encryptedPath).copy(tempEncryptedPath);
    await ops.decryptFile(tempEncryptedPath);

    // 解密后文件名已恢复，找到解密后的文件
    final dir = Directory(p.dirname(tempEncryptedPath));
    final entities = await dir.list().toList();
    for (final entity in entities) {
      if (entity is File && entity.path.startsWith(tempFilePath) && !entity.path.endsWith('.enc')) {
        return entity;
      }
    }

    // 如果没找到，返回原始路径（可能解密失败）
    return File(tempEncryptedPath);
  }

  /// 从旧版保险箱（V1/V2/V3）迁移文件到新版 crypt 沙盒加密
  ///
  /// 迁移流程：
  /// 1. 加载旧版保险箱的文件记录
  /// 2. 逐个解密旧版文件到原位置
  /// 3. 用 crypt 沙盒加密解密后的文件
  /// 4. 删除旧版加密文件和记录
  ///
  /// 返回迁移的文件数量。
  Future<int> migrateFromOldVault({
    required String password,
    void Function(int current, int total, String fileName)? onProgress,
  }) async {
    final records = await VaultService.loadRecords();
    if (records.isEmpty) return 0;

    int migrated = 0;
    final List<VaultFileRecord> remaining = [];

    for (int i = 0; i < records.length; i++) {
      final record = records[i];
      onProgress?.call(i + 1, records.length, record.originalName);

      try {
        // 1. 解密旧版文件到原位置
        await VaultService.unlockFile(record: record, password: password);

        // 2. 用 crypt 沙盒加密解密后的文件
        if (record.isFolder) {
          await encryptToSandbox(sourcePath: record.originalPath, password: password);
        } else {
          await encryptToSandbox(sourcePath: record.originalPath, password: password);
        }

        // 3. 删除旧版加密文件
        try {
          final oldFile = File(record.scrambledPath);
          if (await oldFile.exists()) {
            await oldFile.delete();
          }
        } catch (_) {}

        migrated++;
      } catch (e) {
        // 迁移失败，保留旧版记录
        remaining.add(record);
      }
    }

    // 4. 保存更新后的旧版记录（只保留迁移失败的）
    await VaultService.saveRecords(remaining);

    return migrated;
  }

  /// 检查旧版保险箱中是否有文件需要迁移
  Future<bool> hasOldVaultFiles() async {
    final records = await VaultService.loadRecords();
    return records.isNotEmpty;
  }
}
