import 'dart:convert';
import 'dart:io';
import 'package:archive/archive_io.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'crypt.dart';

/// 保险箱 Crypt 整合服务
///
/// 统一使用「加密设置」中的主密码（+ 盐）作为 crypt 密钥，提供两种模式：
/// - **原地加密（in-place）**：文件留在原目录，加密后文件名变为加密格式，
///   不显示在保险箱列表中，浏览页显示🔐图徽。
/// - **沙盒加密（sandbox）**：文件移动到应用私有目录，显示在保险箱列表中。
///
/// ## 与保险箱解锁密码的关系
/// **完全无关**。保险箱解锁密码 / 指纹只是「进入保险箱界面」的门禁，由
/// [VaultService] 独立管理；本服务所有加解密一律读主密码
/// （[kMasterPasswordKey] / [kMasterSaltKey]）。
/// 因此用户修改门禁密码是瞬时操作，不会触碰任何已加密文件。
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

  /// 主密码相关配置在 SharedPreferences 中的键（由「加密设置」页写入）
  static const String kMasterPasswordKey = 'crypt_last_password';
  static const String kMasterSaltKey = 'crypt_last_salt';
  static const String kFilenameEncodingKey = 'crypt_last_filename_encoding';
  static const String kEncryptedSuffixKey = 'crypt_last_encrypted_suffix';

  /// 是否已配置至少一份加密档案（含 legacy 单组主密码）
  Future<bool> hasMasterPassword() async {
    final profiles = await CryptProfileService.instance.loadProfiles();
    if (profiles.isNotEmpty) return true;
    final prefs = await SharedPreferences.getInstance();
    return (prefs.getString(kMasterPasswordKey) ?? '').isNotEmpty;
  }

  /// 读取当前默认档案的主密码，未配置时返回 null
  Future<String?> readMasterPassword() async {
    final profile = await CryptProfileService.instance.activeProfile();
    if (profile != null && profile.password.isNotEmpty) {
      return profile.password;
    }
    final prefs = await SharedPreferences.getInstance();
    final password = prefs.getString(kMasterPasswordKey) ?? '';
    return password.isEmpty ? null : password;
  }

  /// 读取主密码；未配置时抛 [StateError]（调用方应引导用户去「加密设置」）
  ///
  /// [path] 用于按「路径绑定」取对应档案的密码（不同文件/文件夹可用不同密钥）。
  Future<String> requireMasterPassword({String? path}) async {
    final password = path == null
        ? await readMasterPassword()
        : (await CryptProfileService.instance.resolveFor(path))?.password;
    if (password == null || password.isEmpty) {
      throw StateError('master_password_not_set');
    }
    return password;
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
  ///
  /// 文件名加密模式固定为 standard，但编码与后缀跟随用户在「加密设置」
  /// 中保存的配置，确保与原地加密/OpenList 配置一致。
  Future<RcloneCryptConfig> getSandboxConfig() async {
    // 沙盒保持「单一配置」：整个沙盒目录只挂一份密钥，跟随当前默认档案。
    return requireMasterConfig();
  }

  /// 读取用户在「加密设置」中保存的完整 rclone crypt 配置。
  ///
  /// 优先从**配置档案**读取（多组密钥）；若尚无任何档案（迁移未完成或
  /// 用户从未保存过），回退到 legacy 的 SharedPreferences 单组凭据。
  ///
  /// [path] 用于按绑定取档案：`resolveFor` 会先查「路径 → 档案」绑定，
  /// 命中则用那一份，未命中用当前默认档案 —— 这样同一目录树里不同
  /// 文件夹可以使用不同密钥，而浏览层无需逐个档案试解（scrypt 很贵）。
  ///
  /// 返回 null 表示用户尚未配置任何主密码。
  Future<RcloneCryptConfig?> getMasterConfig({String? path}) async {
    final profile = path == null
        ? await CryptProfileService.instance.activeProfile()
        : await CryptProfileService.instance.resolveFor(path);
    if (profile != null && profile.password.isNotEmpty) {
      return profile.toConfig();
    }
    return _loadLegacyConfig();
  }

  /// legacy 单组凭据（SharedPreferences `crypt_last_*`）→ 配置。
  ///
  /// 仅在配置档案库为空时使用，保证老版本用户/迁移失败时不会突然解不开。
  Future<RcloneCryptConfig?> _loadLegacyConfig() async {
    final prefs = await SharedPreferences.getInstance();
    final password = prefs.getString(kMasterPasswordKey) ?? '';
    if (password.isEmpty) return null;
    final saltStr = prefs.getString(kMasterSaltKey) ?? '';
    final encName = prefs.getString(kFilenameEncodingKey) ?? 'base32';
    final suffix = prefs.getString(kEncryptedSuffixKey) ?? '.bin';

    final filenameEncoding = FilenameEncoding.values.firstWhere(
      (e) => e.name == encName,
      orElse: () => FilenameEncoding.base32,
    );

    return RcloneCryptConfig(
      password: password,
      salt: saltStr.isEmpty ? null : saltStr,
      filenameEncryption: FilenameEncryption.standard,
      directoryNameEncryption: true,
      filenameEncoding: filenameEncoding,
      encryptedSuffix: suffix,
    );
  }

  /// 读取主密码配置；未配置时抛 [StateError]。
  Future<RcloneCryptConfig> requireMasterConfig({String? path}) async {
    final config = await getMasterConfig(path: path);
    if (config == null) {
      throw StateError('master_password_not_set');
    }
    return config;
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
  ///
  /// ⚠️ 已存在的挂载点密码为空（持久化不落盘密码）时，用当前主密码补齐，
  /// 否则后续解密必然失败。
  Future<CryptMountPoint> ensureSandboxMount() async {
    final password = await requireMasterPassword();

    final existing = await getSandboxMount();
    if (existing != null) {
      return existing.config.password.isEmpty
          ? existing.copyWith(password: password)
          : existing;
    }

    final sandboxDir = await getSandboxDir();
    final config = await getSandboxConfig();
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
    void Function(int processed, int total)? onProgress,
    void Function(int bytes, int total)? onFileProgress,
    bool skipEncrypted = false,
  }) async {
    // 密钥取自「加密设置」的配置档案（可按路径绑定）；未配置则抛 StateError
    // （UI 引导去加密设置）。传 sourcePath 让绑定优先于默认档案。
    final masterPassword = await requireMasterPassword(path: sourcePath);

    final sourceEntity = FileSystemEntity.typeSync(sourcePath);
    final isDir = sourceEntity == FileSystemEntityType.directory;
    final parentDir = p.dirname(sourcePath);

    // 确保父目录有对应的 crypt 挂载点
    final mounts = await CryptMountService.loadMountPoints();
    CryptMountPoint? parentMount;
    for (final mount in mounts) {
      // ⚠️ 必须跳过「整机根目录」级别的挂载点：浏览页与解密层都会排除它，
      // 若加密时沿用了它，就会出现「加密用了 A 挂载点、浏览/解密用 B」的错配，
      // 表现为加密后浏览页仍显示密文、重启后目录空白。
      if (mount.isSandboxMode || _isStorageRootPath(mount.physicalPath)) continue;
      if (mount.containsPath(sourcePath)) {
        parentMount = mount;
        break;
      }
    }

    if (parentMount == null) {
      // 创建新的原地加密挂载点：复用用户在「加密设置」中保存的编码与后缀，
      // 保证与 OpenList / rclone 配置一致。
      // 传 sourcePath 让「路径绑定」优先生效：用户给这片目录指定过哪份档案，
      // 加密时就用哪份（未指定则回退当前默认档案）。
      final config = await requireMasterConfig(path: sourcePath);
      parentMount = CryptMountPoint(
        physicalPath: parentDir,
        config: config,
        name: p.basename(parentDir),
        isSandboxMode: false,
      );
      // ⚠️ 严禁把「存储根目录」持久化为挂载点：它的 containsPath 会命中全盘所有
      // 路径，浏览层于是把整个存储当成加密目录（历史事故：所有文件夹上锁、
      // 进入后内容空白），因此浏览层/解密层都明确忽略根挂载点。
      // 这类目录改用**临时挂载点**：本次加密用它完成加解密，之后的显示与打开
      // 由浏览层按「目录内是否确有密文」按需重建（见 file_manager_provider
      // 的 _ephemeralMountForDir）。
      if (!_isStorageRootPath(parentDir)) {
        await CryptMountService.addMountPoint(parentMount);
      }
    } else if (parentMount.config.password.isEmpty) {
      // 已持久化的挂载点可能因安全存储丢失而没有密码：补上主密码**并回写**，
      // 否则本次能用、重启后解密失败 → 浏览页得到一个空目录。
      parentMount = parentMount.copyWith(password: masterPassword);
      await CryptMountService.addMountPoint(parentMount);
    }

    // 执行加密
    final ops = CryptOperations(parentMount);
    if (isDir) {
      await ops.encryptDirectory(
        sourcePath,
        onProgress: onProgress,
        onFileProgress: onFileProgress,
        skipEncrypted: skipEncrypted,
      );
    } else {
      await ops.encryptFile(sourcePath, onFileProgress: onFileProgress);
    }

    // ⚠️ 登记「这片目录执行过原地加密」，且**必须包含存储根目录**。
    // 挂载点无法表达根目录（containsPath 会命中全盘 → 浏览层一律排除），
    // 于是根目录下的密文就失去了依托；而浏览页拿到的又是**虚拟路径**
    // （磁盘上不存在），连「读文件头比对 magic」这条兜底都走不通 ——
    // 结果就是显示密文名、点进去空白、音视频图片全部打不开。
    // 登记表与挂载点解耦，可以安全地记下根目录，供浏览层精确按需挂载。
    await CryptMountService.addEncryptedDir(parentDir);

    // 记下「这片目录用的是哪份档案」，浏览层据此 O(1) 取到正确密钥，
    // 无需逐个档案试解（每个 CryptMountPoint 构造都要跑一次 scrypt）。
    final usedProfile = await CryptProfileService.instance.resolveFor(sourcePath);
    if (usedProfile != null) {
      await CryptProfileService.instance.bindPath(parentDir, usedProfile.id);
    }
  }

  /// 沙盒加密文件/目录
  ///
  /// 文件移动到应用私有目录的 vault 文件夹，加密后显示在保险箱列表中。
  Future<void> encryptToSandbox({
    required String sourcePath,
    void Function(int processed, int total)? onProgress,
    void Function(int bytes, int total)? onFileProgress,
  }) async {
    final sandboxMount = await ensureSandboxMount();
    final sourceEntity = FileSystemEntity.typeSync(sourcePath);
    final isDir = sourceEntity == FileSystemEntityType.directory;

    // 重名处理：EME 加密是确定性的，同名条目必须先在明文层改名，
    // 否则会静默覆盖沙盒里已有的同名条目（旧版用随机 id，天然不会冲突）。
    final baseName = await _uniquePlainName(sandboxMount, p.basename(sourcePath));
    final destPath = p.join(sandboxMount.physicalPath, baseName);

    final ops = CryptOperations(sandboxMount);
    late final String encryptedPath;

    if (isDir) {
      // 目录加密：先复制到沙盒目录，再加密
      final tempDest = Directory(destPath);
      if (await tempDest.exists()) {
        await tempDest.delete(recursive: true);
      }
      await _copyDirectory(Directory(sourcePath), tempDest);
      await ops.encryptDirectory(destPath, onProgress: onProgress,
          onFileProgress: onFileProgress);
      // encryptDirectory 会把目录名一并加密，算出最终密文路径
      encryptedPath = p.join(
        sandboxMount.physicalPath,
        sandboxMount.crypt.encryptDirName(baseName),
      );
      // 删除原目录
      await Directory(sourcePath).delete(recursive: true);
    } else {
      // 文件加密：先复制到沙盒目录，再加密（encryptFile 返回加密后的最终路径）
      await File(sourcePath).copy(destPath);
      encryptedPath = await ops.encryptFile(destPath,
          onFileProgress: onFileProgress);
      // 删除原文件
      final sourceFile = File(sourcePath);
      if (await sourceFile.exists()) {
        await sourceFile.delete();
      }
    }

    // 记录原始路径，供「恢复到原位置」使用（密文名与原始路径无关，无法反推）
    await saveSandboxOrigin(
      encryptedPath: encryptedPath,
      originalPath: sourcePath,
    );
  }

  /// 是否为「整机根目录」级别的路径。
  ///
  /// 这类路径作为 crypt 挂载点是**错误配置**：`containsPath` 会命中全盘所有路径，
  /// 把整个存储当成加密目录。浏览层、解密层与加密层都必须一致忽略它，
  /// 否则会出现「加密用一个挂载点、浏览/解密用另一个」的错配。
  static bool _isStorageRootPath(String path) =>
      CryptMountService.isStorageRootPath(path);

  /// 按路径查找所属挂载点（含沙盒挂载点）
  /// 路径 [path] 是否位于目录 [dir] 之内（POSIX 语义，不依赖运行平台）
  static bool _dirContains(String dir, String path) {
    final d = CryptMountService.normalizePosix(dir);
    final t = CryptMountService.normalizePosix(path);
    if (t == d) return true;
    return t.startsWith(d.endsWith('/') ? d : '$d/');
  }

  Future<CryptMountPoint?> _findMountForPath(String path) async {
    final mounts = await CryptMountService.loadMountPoints();
    for (final m in mounts) {
      if (m.containsPath(path)) return m;
    }
    // 持久化挂载点无法表达存储根目录，但「原地加密目录登记表」可以。
    // 缺了这一步，根目录级别的原地加密**连解密都会失败**
    // （直接抛「未找到对应的加密挂载点」）。
    final dirs = await CryptMountService.loadEncryptedDirs();
    if (dirs.isEmpty) return null;
    RcloneCryptConfig? master;
    for (final d in dirs) {
      if (!_dirContains(d, path)) continue;
      // 命中才派生密钥：CryptMountPoint 构造会跑 scrypt，不要白跑
      // 传 path 让绑定优先生效（该目录可能用的是非默认档案）
      master ??= await getMasterConfig(path: path);
      if (master == null) return null;
      return CryptMountPoint(
        physicalPath: d,
        config: master,
        name: p.basename(d),
      );
    }
    return null;
  }

  /// 解密文件/目录（原地加密的文件解密回原目录）
  Future<void> decryptInPlace({
    required String encryptedPath,
    void Function(int processed, int total)? onProgress,
    void Function(int bytes, int total)? onFileProgress,
  }) async {
    var mount = await _findMountForPath(encryptedPath);
    if (mount == null) {
      throw Exception('未找到对应的加密挂载点');
    }
    // 持久化挂载点不落盘密码 → 用主密码补齐，否则解密必然失败。
    // 传 encryptedPath：该文件可能绑定了非默认档案，用默认档案会解不开。
    if (mount.config.password.isEmpty) {
      mount = mount.copyWith(
        password: await requireMasterPassword(path: encryptedPath),
      );
    }

    // 浏览页传来的是**虚拟（解密后）路径**，磁盘上并不存在 ——
    // 必须先还原成真实物理路径，否则 FileSystemEntity.typeSync 判定为
    // notFound，后续按「文件」处理必然失败。
    if (FileSystemEntity.typeSync(encryptedPath) == FileSystemEntityType.notFound) {
      encryptedPath = await mount.resolvePhysicalPath(encryptedPath);
    }

    final entityType = FileSystemEntity.typeSync(encryptedPath);
    final isDir = entityType == FileSystemEntityType.directory;

    final ops = CryptOperations(mount);
    if (isDir) {
      await ops.decryptDirectory(encryptedPath, onProgress: onProgress,
          onFileProgress: onFileProgress);
    } else {
      await ops.decryptFile(encryptedPath, onFileProgress: onFileProgress);
    }

    // 该目录已还原为明文：从「原地加密目录登记表」里注销，
    // 否则浏览层会继续按加密目录处理它（解密后仍显示密文 / 目录空白）。
    //
    // ⚠️ 必须**确认目录里已没有密文**才注销：只解密其中一个文件时，
    // 同目录可能还有别的加密文件，贸然注销会让剩下那些又变回密文名。
    final parentDir = p.dirname(encryptedPath);
    final stillEncrypted = await CryptOperations.dirContainsCiphertext(
      parentDir,
      config: mount.config,
    );
    if (!stillEncrypted) {
      await CryptMountService.removeEncryptedDir(parentDir);
    }

    // 目录整体解密后自身也是明文：若它当初被登记过（内部直接放过加密文件），
    // 一并注销，包括其所有子目录记录。
    if (isDir) {
      try {
        final plainDir = p.join(
          p.dirname(encryptedPath),
          mount.crypt.decryptDirName(p.basename(encryptedPath)),
        );
        await CryptMountService.removeEncryptedDir(plainDir);
      } catch (_) {}
    }
  }

  /// 从沙盒解密文件/目录回原位置
  Future<void> decryptFromSandbox({
    required String sandboxPath,
    required String originalPath,
    void Function(int processed, int total)? onProgress,
    void Function(int bytes, int total)? onFileProgress,
  }) async {
    // ensureSandboxMount 内部会用主密码补齐（持久化挂载点不落盘密码）
    final sandboxMount = await ensureSandboxMount();

    final entityType = FileSystemEntity.typeSync(sandboxPath);
    final isDir = entityType == FileSystemEntityType.directory;

    final ops = CryptOperations(sandboxMount);

    if (isDir) {
      // 目录解密：先解密（decryptDirectory 会把目录名解密并 rename）
      await ops.decryptDirectory(sandboxPath, onProgress: onProgress,
          onFileProgress: onFileProgress);
      // 算出解密后的实际路径（目录已被 rename，原 sandboxPath 不再存在）
      final decryptedDirPath = p.join(
        p.dirname(sandboxPath),
        sandboxMount.crypt.decryptDirName(p.basename(sandboxPath)),
      );
      final originalDir = Directory(originalPath);
      if (await originalDir.exists()) {
        await originalDir.delete(recursive: true);
      }
      await Directory(p.dirname(originalPath)).create(recursive: true);
      await _moveOrCopy(decryptedDirPath, originalPath, isDir: true);
    } else {
      // ⚠️ 旧实现靠「遍历沙盒目录找第一个非 .bin 文件」定位解密结果：
      // ① 后缀可配置（base64 / 空后缀）时判定失效；
      // ② 沙盒里只要有多个文件就必然取错。
      // decryptFile 直接返回解密后的真实路径，改用它。
      final decryptedPath = await ops.decryptFile(sandboxPath,
          onFileProgress: onFileProgress);
      final originalFile = File(originalPath);
      if (await originalFile.exists()) {
        await originalFile.delete();
      }
      await Directory(p.dirname(originalPath)).create(recursive: true);
      await _moveOrCopy(decryptedPath, originalPath, isDir: false);
    }

    // 已恢复，清掉来源记录
    await removeSandboxOrigin(sandboxPath);
  }

  /// 移动文件/目录，跨分区（EXDEV）时自动退化为复制 + 删除
  ///
  /// 沙盒位于应用私有目录（/data/data/...），恢复到外部存储（/storage/emulated/0）
  /// 几乎必然跨文件系统，`rename` 会抛异常，故必须降级处理。
  Future<void> _moveOrCopy(String from, String to, {required bool isDir}) async {
    try {
      if (isDir) {
        await Directory(from).rename(to);
      } else {
        await File(from).rename(to);
      }
      return;
    } catch (_) {
      // 跨分区失败，退化为复制 + 删除
    }
    if (isDir) {
      await _copyDirectory(Directory(from), Directory(to));
      await Directory(from).delete(recursive: true);
    } else {
      await File(from).copy(to);
      await File(from).delete();
    }
  }

  /// 获取沙盒中的加密文件列表（解密后的文件名）
  Future<List<CryptFileEntry>> listSandboxFiles() async {
    final sandboxMount = await ensureSandboxMount();
    final vfs = CryptVFS();
    vfs.mount(sandboxMount);
    final entries = await vfs.listDirectory(sandboxMount.physicalPath);
    return entries;
  }

  // ---------------------------------------------------------------------------
  // 沙盒原始路径映射
  //
  // 沙盒加密会把文件移出原位置，密文文件名又是 EME 加密结果（与原始路径无关），
  // 因此「恢复到原位置」必须额外记录来源。旧版 V2/V3 把 originalPath 存在
  // VaultFileRecord 里，新版 crypt 沙盒没有落盘记录，故用 SharedPreferences 维护
  // 「加密后物理路径 → 原始路径」映射。
  // ---------------------------------------------------------------------------

  /// SharedPreferences 键：沙盒加密路径 → 原始路径 的 JSON 映射
  static const String _kSandboxOrigins = 'vault_sandbox_origins';

  Future<Map<String, String>> _readOriginMap() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_kSandboxOrigins);
    if (raw == null || raw.isEmpty) return <String, String>{};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        return decoded.map((k, v) => MapEntry('$k', '$v'));
      }
    } catch (_) {}
    return <String, String>{};
  }

  Future<void> _writeOriginMap(Map<String, String> map) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kSandboxOrigins, jsonEncode(map));
  }

  /// 读取全部沙盒原始路径映射（一次性读取，避免列表渲染时逐条 IO）
  Future<Map<String, String>> getSandboxOrigins() => _readOriginMap();

  /// 查询单个加密条目的原始路径（无记录返回 null）
  Future<String?> getSandboxOrigin(String encryptedPath) async {
    return (await _readOriginMap())[encryptedPath];
  }

  /// 记录沙盒条目的原始路径
  Future<void> saveSandboxOrigin({
    required String encryptedPath,
    required String originalPath,
  }) async {
    final map = await _readOriginMap();
    map[encryptedPath] = originalPath;
    await _writeOriginMap(map);
  }

  /// 删除沙盒条目的原始路径记录（文件被移除时调用，避免映射无限增长）
  Future<void> removeSandboxOrigin(String encryptedPath) async {
    final map = await _readOriginMap();
    if (map.remove(encryptedPath) != null) {
      await _writeOriginMap(map);
    }
  }

  /// 批量合并沙盒原始路径映射（备份恢复时使用）
  Future<void> saveSandboxOrigins(Map<String, String> origins) async {
    if (origins.isEmpty) return;
    final map = await _readOriginMap();
    map.addAll(origins);
    await _writeOriginMap(map);
  }

  // ---------------------------------------------------------------------------
  // 便携备份 / 恢复
  //
  // 备份包格式（zip）：
  //   sandbox/**       → 沙盒 vault_crypt/ 下的全部密文（保留目录结构）
  //   crypt_config.json → 主密码/盐/编码/后缀 + 挂载点列表 + 来源映射
  //
  // ⚠️ 因密文由主密码保护，备份包内**包含**主密码才能做到「换机后一键还原」。
  // 导出/导入的用户界面必须明确提示用户妥善保管该文件。
  // ---------------------------------------------------------------------------

  /// 备份包内的配置文件名
  static const String _kBackupConfigName = 'crypt_config.json';

  /// 备份包内沙盒密文的目录名前缀
  static const String _kBackupSandboxPrefix = 'sandbox/';

  /// 导出便携备份到 [destDir]，返回生成的 zip 路径
  Future<String> exportBackup(String destDir) async {
    final outDir = Directory(destDir);
    if (!await outDir.exists()) {
      await outDir.create(recursive: true);
    }

    final archive = Archive();

    // 1) 沙盒密文
    final sandboxDir = Directory(await getSandboxDir());
    if (await sandboxDir.exists()) {
      await for (final ent in sandboxDir.list(recursive: true)) {
        if (ent is! File) continue;
        if (p.basename(ent.path) == '.nomedia') continue;
        final rel = p.relative(ent.path, from: sandboxDir.path);
        final bytes = await ent.readAsBytes();
        archive.addFile(
          ArchiveFile('$_kBackupSandboxPrefix${rel.replaceAll(r'\', '/')}',
              bytes.length, bytes),
        );
      }
    }

    // 2) 配置与来源映射
    final prefs = await SharedPreferences.getInstance();
    final mounts = await CryptMountService.loadMountPoints();
    final profiles = await CryptProfileService.instance.loadProfiles();
    final bindings = await CryptProfileService.instance.loadBindings();
    final config = <String, dynamic>{
      // v3：新增 profiles（多组密码+加盐）与 bindings（路径 → 档案）
      'version': 3,
      'profiles': profiles.map((e) => e.toJson()).toList(),
      'bindings': bindings,
      'password': prefs.getString(kMasterPasswordKey) ?? '',
      'salt': prefs.getString(kMasterSaltKey) ?? '',
      'filenameEncoding': prefs.getString(kFilenameEncodingKey) ?? 'base32',
      'encryptedSuffix': prefs.getString(kEncryptedSuffixKey) ?? '.bin',
      'mounts': mounts
          .where((m) => !m.isSandboxMode)
          .map((m) => <String, dynamic>{
                'physicalPath': m.physicalPath,
                'name': m.name,
                'salt': m.config.salt ?? '',
                'filenameEncoding': m.config.filenameEncoding.name,
                'encryptedSuffix': m.config.encryptedSuffix,
              })
          .toList(),
      // 来源映射的键是绝对路径，跨设备会失效 → 存相对沙盒目录的路径
      'origins': (await getSandboxOrigins()).map(
        (k, v) => MapEntry(
          p.relative(k, from: sandboxDir.path).replaceAll(r'\', '/'),
          v,
        ),
      ),
    };
    final cfgBytes = utf8.encode(jsonEncode(config));
    archive.addFile(ArchiveFile(_kBackupConfigName, cfgBytes.length, cfgBytes));

    final ts = DateTime.now()
        .toIso8601String()
        .replaceAll(RegExp(r'[^0-9]'), '')
        .substring(0, 14);
    final zipBytes = ZipEncoder().encode(archive);
    if (zipBytes == null) {
      throw Exception('备份包生成失败');
    }
    final outPath = p.join(destDir, 'zenfile_vault_backup_$ts.zip');
    await File(outPath).writeAsBytes(zipBytes);
    return outPath;
  }

  /// 从便携备份恢复。返回恢复的沙盒条目数。
  ///
  /// 沙盒密文按备份内容写回 `vault_crypt/`（同名以备份为准），
  /// 并恢复主密码/盐/编码/后缀、原地加密挂载点与来源映射。
  Future<int> importBackup(String zipPath) async {
    final bytes = await File(zipPath).readAsBytes();
    final archive = ZipDecoder().decodeBytes(bytes);

    final sandboxDir = Directory(await getSandboxDir());

    // 恢复语义：清空当前沙盒内容，避免旧密文（可能由另一组主密码加密）残留，
    // 导致列表里出现永远解不开的条目。
    if (await sandboxDir.exists()) {
      await for (final ent in sandboxDir.list()) {
        if (p.basename(ent.path) == '.nomedia') continue;
        try {
          await ent.delete(recursive: true);
        } catch (_) {}
      }
    }

    var imported = 0;
    Map<String, dynamic>? config;

    for (final f in archive) {
      if (!f.isFile) continue;
      final name = f.name;
      if (name == _kBackupConfigName) {
        try {
          config = jsonDecode(utf8.decode(f.content as List<int>))
              as Map<String, dynamic>;
        } catch (_) {}
        continue;
      }
      if (!name.startsWith(_kBackupSandboxPrefix)) continue;
      final rel = name.substring(_kBackupSandboxPrefix.length);
      final outFile = File(p.join(sandboxDir.path, rel));
      await outFile.parent.create(recursive: true);
      await outFile.writeAsBytes(f.content as List<int>);
      imported++;
    }

    if (config == null) return imported;

    // 恢复主密码/盐/编码/后缀
    final password = config['password'] as String? ?? '';
    final prefs = await SharedPreferences.getInstance();
    if (password.isNotEmpty) {
      await prefs.setString(kMasterPasswordKey, password);
      await prefs.setString(kMasterSaltKey, config['salt'] as String? ?? '');
      await prefs.setString(
          kFilenameEncodingKey, config['filenameEncoding'] as String? ?? 'base32');
      await prefs.setString(
          kEncryptedSuffixKey, config['encryptedSuffix'] as String? ?? '.bin');
    }

    // ⚠️ 主密码可能已随备份变化 → 清空全部旧挂载点，按备份重建
    // （沙盒挂载点由 ensureSandboxMount 用新主密码按需重建）
    await CryptMountService.saveMountPoints(const []);

    // 恢复配置档案与路径绑定（v3 备份包）。
    // 老备份包没有 profiles 字段 → 保持现有档案库不动，只恢复单组主密码。
    final profileList = config['profiles'];
    if (profileList is List) {
      final restored = profileList
          .whereType<Map<String, dynamic>>()
          .map(CryptProfile.fromJson)
          .where((e) => e.id.isNotEmpty && e.password.isNotEmpty)
          .toList();
      if (restored.isNotEmpty) {
        await CryptProfileService.instance.saveProfiles(restored);
        final rawBindings = config['bindings'];
        if (rawBindings is Map) {
          await CryptProfileService.instance.saveBindings(
            rawBindings.map((k, v) => MapEntry('$k', '$v')),
          );
        } else {
          await CryptProfileService.instance.saveBindings(<String, String>{});
        }
      }
    }

    // 恢复原地加密挂载点
    final mountList = config['mounts'];
    if (mountList is List) {
      for (final item in mountList) {
        if (item is! Map) continue;
        final map = item.cast<String, dynamic>();
        final path = map['physicalPath'] as String? ?? '';
        if (path.isEmpty) continue;
        final encName = map['filenameEncoding'] as String? ?? 'base32';
        final salt = map['salt'] as String? ?? '';
        await CryptMountService.addMountPoint(
          CryptMountPoint(
            physicalPath: path,
            config: RcloneCryptConfig(
              password: password,
              salt: salt.isEmpty ? null : salt,
              filenameEncryption: FilenameEncryption.standard,
              directoryNameEncryption: true,
              filenameEncoding: FilenameEncoding.values.firstWhere(
                (e) => e.name == encName,
                orElse: () => FilenameEncoding.base32,
              ),
              encryptedSuffix: map['encryptedSuffix'] as String? ?? '.bin',
            ),
            name: map['name'] as String? ?? '加密目录',
            isSandboxMode: false,
          ),
        );
      }
    }

    // 恢复来源映射（备份内是相对路径，按本机沙盒目录重组为绝对路径）
    final origins = config['origins'];
    if (origins is Map) {
      final relPairs = origins.map((k, v) => MapEntry('$k', '$v'));
      await saveSandboxOrigins(
        relPairs.map((k, v) => MapEntry(p.join(sandboxDir.path, k), v)),
      );
    }

    return imported;
  }

  // ---------------------------------------------------------------------------
  // 沙盒内重名处理
  // ---------------------------------------------------------------------------

  /// 为进入沙盒的条目计算一个不冲突的**明文**目标名。
  ///
  /// ⚠️ EME 文件名加密是确定性的（同明文 + 同密码 → 同密文），磁盘上的密文名
  /// 与原始路径无关，因此无法用「明文路径是否存在」判重（沙盒里存的是密文名）。
  /// 必须枚举沙盒已占用的**解密名**集合来去重，否则同名文件导入会静默覆盖。
  Future<String> _uniquePlainName(
    CryptMountPoint mount,
    String baseName,
  ) async {
    Set<String> existing;
    try {
      final lister = CryptDirectoryLister(mount);
      final entries = await lister.listDirectory(mount.physicalPath);
      existing = entries.map((e) => e.name).toSet();
    } catch (_) {
      // 列举失败时退化为不判重，避免阻塞导入
      return baseName;
    }

    if (!existing.contains(baseName)) return baseName;

    final ext = p.extension(baseName);
    final stem = p.basenameWithoutExtension(baseName);
    var i = 2;
    while (true) {
      final candidate = ext.isEmpty ? '${stem}_$i' : '${stem}_$i$ext';
      if (!existing.contains(candidate)) return candidate;
      i++;
    }
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
  }) async {
    var mount = await _findMountForPath(encryptedPath);
    if (mount == null) {
      throw Exception('未找到对应的加密挂载点');
    }
    // 持久化挂载点不落盘密码 → 用主密码补齐，否则解密必然失败。
    // 传 encryptedPath：该文件可能绑定了非默认档案，用默认档案会解不开。
    if (mount.config.password.isEmpty) {
      mount = mount.copyWith(
        password: await requireMasterPassword(path: encryptedPath),
      );
    }

    // 解密到临时目录
    final tempDir = await getTemporaryDirectory();
    final tempFilePath = p.join(tempDir.path, 'vault_temp_${DateTime.now().millisecondsSinceEpoch}_${p.basename(encryptedPath)}');

    final ops = CryptOperations(mount);
    // 先复制加密文件到临时目录，然后原地解密
    final tempEncryptedPath = '$tempFilePath.enc';
    await File(encryptedPath).copy(tempEncryptedPath);

    // ⚠️ 旧实现靠「文件名以 tempFilePath 开头」找解密结果，但 tempFilePath 里嵌的是
    // **密文名**，解密后文件名已还原为明文，前缀永远匹配不上，最终会返回未解密的
    // .enc 文件（预览必然失败）。decryptFile 直接返回解密后的真实路径，改用它。
    final decryptedPath = await ops.decryptFile(tempEncryptedPath);
    return File(decryptedPath);
  }

}
