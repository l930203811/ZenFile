import 'dart:convert';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'crypt_config.dart';
import 'crypt_mount.dart';

/// 加密挂载点持久化服务
///
/// 负责保存和加载加密挂载点配置。
/// 配置（不含密码）保存在 SharedPreferences，密码单独保存在 FlutterSecureStorage
/// （Android Keystore / iOS Keychain 硬件级加密）。
class CryptMountService {
  static const String _kMountPointsKey = 'crypt_mount_points';
  static const String _kPasswordPrefix = 'crypt_mount_password_';

  /// 「执行过原地加密的目录」登记表（与挂载点分离）。
  ///
  /// 为什么需要它：挂载点不能表达「存储根目录」（`/storage/emulated/0`）——
  /// `containsPath` 会命中全盘所有路径。于是根目录被排除后，其中的密文
  /// 就失去了挂载点依托，只能靠启发式探测（既慢又可能漏判）。
  /// 登记表记录的是**用户明确加密过的目录**，与「是不是合法挂载点」无关，
  /// 因此可以包含存储根目录，浏览层据此精确地按需建临时挂载点。
  static const String _kEncryptedDirsKey = 'crypt_encrypted_dirs';

  /// 「关联的远程加密目录」登记表。
  ///
  /// 记录用户明确关联过的「后端上的 rclone crypt 目录」，用于在保险箱
  /// 「原地加密」区域显示这些远程密文（客户端解密）。
  /// ⚠️ 不与 [loadMountPoints] 混用：远程挂载点没有磁盘物理路径，不能进
  /// `crypt_mount_points`（否则会被当成含 `cryptremote://` 名的本地目录）。
  static const String _kRemoteEncryptedDirsKey = 'crypt_remote_encrypted_dirs';

  static const FlutterSecureStorage _secureStorage = FlutterSecureStorage();

  /// 加载所有已保存的加密挂载点
  ///
  /// ⚠️ 会自动剔除「整机根目录」级别的挂载点（见 [isStorageRootPath]）：
  /// 它们是历史错误配置（例如旧版本执行原地加密时误把 `/storage/emulated/0`
  /// 写成了挂载点），一旦生效会让整个存储被当成加密目录。在**读取侧统一过滤**，
  /// 可以一次保护所有调用方（浏览/解密/流式服务/保险箱列表）。
  static Future<List<CryptMountPoint>> loadMountPoints() async {
    final prefs = await SharedPreferences.getInstance();
    final jsonStr = prefs.getString(_kMountPointsKey);
    if (jsonStr == null || jsonStr.isEmpty) return [];

    try {
      final List<dynamic> list = jsonDecode(jsonStr);
      final mounts = <CryptMountPoint>[];
      for (final item in list) {
        if (item is! Map<String, dynamic>) continue;
        final physicalPath = item['physicalPath'] as String?;
        if (physicalPath == null || physicalPath.isEmpty) continue;
        if (isStorageRootPath(physicalPath)) continue;

        // 从安全存储读取密码
        final password = await _secureStorage.read(
          key: '$_kPasswordPrefix${_pathHash(physicalPath)}',
        );

        final config = RcloneCryptConfig.fromJson(
          item['config'] as Map<String, dynamic>? ?? {},
          password ?? '',
        );

        // 历史/异常数据里若混入远程挂载点，直接忽略（应由远程登记表负责）
        if (item['remoteConnId'] != null) continue;

        mounts.add(CryptMountPoint(
          physicalPath: physicalPath,
          config: config,
          name: item['name'] as String?,
          isSandboxMode: item['isSandboxMode'] as bool? ?? false,
        ));
      }
      return mounts;
    } catch (_) {
      return [];
    }
  }

  /// 保存所有加密挂载点（覆盖式写入）
  static Future<void> saveMountPoints(List<CryptMountPoint> mounts) async {
    final prefs = await SharedPreferences.getInstance();
    final list = <Map<String, dynamic>>[];

    for (final mount in mounts) {
      // 远程挂载点没有本地物理路径，绝不写进本地挂载点表（用独立登记表）
      if (mount.isRemote) continue;
      // 保存密码到安全存储
      if (mount.config.password.isNotEmpty) {
        await _secureStorage.write(
          key: '$_kPasswordPrefix${_pathHash(mount.physicalPath)}',
          value: mount.config.password,
        );
      } else {
        await _secureStorage.delete(
          key: '$_kPasswordPrefix${_pathHash(mount.physicalPath)}',
        );
      }

      list.add({
        'physicalPath': mount.physicalPath,
        'name': mount.name,
        'isSandboxMode': mount.isSandboxMode,
        'config': mount.config.toJson(includePassword: false),
      });
    }

    await prefs.setString(_kMountPointsKey, jsonEncode(list));
  }

  /// 添加一个加密挂载点
  static Future<void> addMountPoint(CryptMountPoint mount) async {
    final mounts = await loadMountPoints();
    // 移除同路径的旧配置
    mounts.removeWhere((m) => m.physicalPath == mount.physicalPath);
    mounts.add(mount);
    await saveMountPoints(mounts);
  }

  /// 删除一个加密挂载点
  static Future<void> removeMountPoint(String physicalPath) async {
    final mounts = await loadMountPoints();
    mounts.removeWhere((m) => m.physicalPath == physicalPath);
    await saveMountPoints(mounts);
    // 同时删除安全存储中的密码
    await _secureStorage.delete(
      key: '$_kPasswordPrefix${_pathHash(physicalPath)}',
    );
  }

  /// 检查路径是否已配置为加密挂载点
  static Future<bool> isMountPoint(String physicalPath) async {
    final mounts = await loadMountPoints();
    return mounts.any((m) => m.physicalPath == physicalPath);
  }

  /// 判断是否为「整机根目录」级别的路径（`/storage/emulated/0`、`/sdcard`、`/` 等）。
  ///
  /// 这类路径**绝不能**作为 crypt 挂载点：`CryptMountPoint.containsPath` 会命中
  /// 全盘所有路径，于是整个存储被当成加密目录（历史事故：所有文件夹上锁、
  /// 进入后内容空白），而且会让所有文件操作都走加解密分支。
  ///
  /// 因此浏览层、解密层、加密层、保险箱页必须**使用同一判定**：
  /// 一律忽略根挂载点，改为对「确实含密文的目录」按需临时挂载。
  /// （此前四处各写一份、且部分漏了 `/sdcard`，导致「加密用一个挂载点、
  /// 浏览/解密用另一个」的错配 —— 统一到此处避免再次分叉。）
  static bool isStorageRootPath(String path) {
    final n = normalizePosix(path);
    return n == '/storage/emulated/0' ||
        n == '/storage/emulated' ||
        n == '/storage' ||
        n == '/sdcard' ||
        n == '/';
  }

  // ── 原地加密目录登记表 ───────────────────────────────────────────────

  /// 按 POSIX 规则归一化路径（反斜杠 → 正斜杠、折叠重复斜杠、去掉末尾斜杠）。
  ///
  /// ⚠️ 不能用 `p.normalize`：它跟随**运行平台**（Windows 输出反斜杠），
  /// 会让登记表的去重/比对在桌面环境下失效。
  static String normalizePosix(String path) {
    var n = path.replaceAll('\\', '/').replaceAll(RegExp(r'/+'), '/');
    while (n.length > 1 && n.endsWith('/')) {
      n = n.substring(0, n.length - 1);
    }
    return n;
  }

  /// 读取所有「执行过原地加密」的目录
  static Future<List<String>> loadEncryptedDirs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final jsonStr = prefs.getString(_kEncryptedDirsKey);
      if (jsonStr == null || jsonStr.isEmpty) return const [];
      final list = jsonDecode(jsonStr);
      if (list is! List) return const [];
      return list
          .whereType<String>()
          .map(normalizePosix)
          .where((e) => e.isNotEmpty)
          .toList();
    } catch (_) {
      return const [];
    }
  }

  /// 登记一个「执行过原地加密」的目录（含存储根目录）
  static Future<void> addEncryptedDir(String dir) async {
    try {
      final normalized = normalizePosix(dir);
      if (normalized.isEmpty) return;
      final dirs = (await loadEncryptedDirs()).toList();
      if (dirs.contains(normalized)) return;
      dirs.add(normalized);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kEncryptedDirsKey, jsonEncode(dirs));
    } catch (_) {}
  }

  /// 注销目录及其所有子目录（解密还原后调用，避免后续仍按加密目录处理）
  static Future<void> removeEncryptedDir(String dir) async {
    try {
      final normalized = normalizePosix(dir);
      if (normalized.isEmpty) return;
      final dirs = await loadEncryptedDirs();
      final kept = dirs.where((d) {
        if (d == normalized) return false;
        // 子目录：`$normalized/...`
        if (d.startsWith('$normalized/')) return false;
        // 反向：登记的是父目录、而要删的是更深层目录时不动
        return true;
      }).toList();
      if (kept.length == dirs.length) return;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kEncryptedDirsKey, jsonEncode(kept));
    } catch (_) {}
  }

  /// 「整体原地加密过、但**目录名保持明文**」的容器目录登记表。
  ///
  /// 为什么单独记：`CryptOperations.encryptDirectory` 末尾有一条守卫 —— 目标目录
  /// 恰好是挂载点 `physicalPath` 时**跳过给目录改名**（否则挂载点根被改名后
  /// `containsPath` 失配 → 重启后解密层找不到挂载点 → 目录显示密文名甚至空白，
  /// 历史事故）。而挂载点是建在被加密条目的**父目录**上的，所以「先加密过该文件夹
  /// 里的某个文件/子文件夹」这一步就会把挂载点登记在该文件夹自身上 —— 之后再对
  /// **这个文件夹**原地加密时，命中守卫、只加密子项。
  ///
  /// 于是这类文件夹在磁盘上表现为「**名字明文 + 子项密文**」，与「普通文件夹里
  /// 夹带零星密文」**磁盘特征完全一样**，只看磁盘无法区分（而后者被判为加密目录
  /// 就会静默加密用户新粘贴进来的文件，是用户反馈过的 bug）。
  /// 本登记表是唯一的区分依据 —— 写入时机只有「整目录原地加密」本身，可信。
  ///
  /// ⚠️ 判据使用它时必须**同时要求目录内确有密文**（`dirContainsCiphertext`）：
  /// 用户解密/清空后残留的登记不得让明文目录重新被判成加密目录。
  static const String _kInPlaceContainerDirsKey = 'crypt_inplace_container_dirs';

  /// 读取所有「整体原地加密但目录名保持明文」的容器目录（已 POSIX 归一）
  static Future<List<String>> loadInPlaceContainerDirs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final jsonStr = prefs.getString(_kInPlaceContainerDirsKey);
      if (jsonStr == null || jsonStr.isEmpty) return const [];
      final list = jsonDecode(jsonStr);
      if (list is! List) return const [];
      return list
          .whereType<String>()
          .map(normalizePosix)
          .where((e) => e.isNotEmpty)
          .toList();
    } catch (_) {
      return const [];
    }
  }

  /// 登记一个「整体原地加密但目录名保持明文」的容器目录
  static Future<void> addInPlaceContainerDir(String dir) async {
    try {
      final normalized = normalizePosix(dir);
      if (normalized.isEmpty) return;
      final dirs = (await loadInPlaceContainerDirs()).toList();
      if (dirs.contains(normalized)) return;
      dirs.add(normalized);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kInPlaceContainerDirsKey, jsonEncode(dirs));
    } catch (_) {}
  }

  /// 注销容器目录（解密还原后调用，连带其所有子目录记录）
  static Future<void> removeInPlaceContainerDir(String dir) async {
    try {
      final normalized = normalizePosix(dir);
      if (normalized.isEmpty) return;
      final dirs = await loadInPlaceContainerDirs();
      final kept = dirs
          .where((d) => d != normalized && !d.startsWith('$normalized/'))
          .toList();
      if (kept.length == dirs.length) return;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kInPlaceContainerDirsKey, jsonEncode(kept));
    } catch (_) {}
  }

  /// 该目录是否被登记为上述容器目录（**只比对自身**，不含子目录）
  ///
  /// 子目录不参与：容器内真正的加密子目录在磁盘上名字已是密文名，
  /// 由 `resolvePhysicalPath` 解析成不含虚拟路径的另一条分支负责，无需这里兜底；
  /// 而容器内**已解密**的子目录必须继续按明文处理（用户规则：解密了就不再加密）。
  static Future<bool> isInPlaceContainerDir(String dir) async {
    final normalized = normalizePosix(dir);
    if (normalized.isEmpty) return false;
    final dirs = await loadInPlaceContainerDirs();
    return dirs.contains(normalized);
  }

  // ── 关联的远程加密目录登记表 ─────────────────────────────────────────

  /// 读取所有「关联的远程加密目录」记录
  static Future<List<RemoteCryptDirRecord>> loadRemoteEncryptedDirs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final jsonStr = prefs.getString(_kRemoteEncryptedDirsKey);
      if (jsonStr == null || jsonStr.isEmpty) return const [];
      final list = jsonDecode(jsonStr);
      if (list is! List) return const [];
      final out = <RemoteCryptDirRecord>[];
      for (final item in list) {
        if (item is! Map) continue;
        final map = Map<String, dynamic>.from(item);
        final connId = map['connId'] as String?;
        final serverPath = map['serverPath'] as String?;
        if (connId == null || connId.isEmpty) continue;
        if (serverPath == null || serverPath.isEmpty) continue;
        out.add(RemoteCryptDirRecord(
          connId: connId,
          serverPath: normalizePosix(serverPath),
          profileId: map['profileId'] as String?,
          name: map['name'] as String?,
        ));
      }
      return out;
    } catch (_) {
      return const [];
    }
  }

  /// 关联一个远程加密目录（同 connId+serverPath 去重）
  static Future<void> addRemoteEncryptedDir(
    String connId,
    String serverPath, {
    String? profileId,
    String? name,
  }) async {
    try {
      if (connId.isEmpty || serverPath.isEmpty) return;
      final normalized = normalizePosix(serverPath);
      final list = (await loadRemoteEncryptedDirs()).toList();
      list.removeWhere(
        (r) => r.connId == connId && r.serverPath == normalized,
      );
      list.add(RemoteCryptDirRecord(
        connId: connId,
        serverPath: normalized,
        profileId: profileId,
        name: name,
      ));
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _kRemoteEncryptedDirsKey,
        jsonEncode(list.map((r) => r.toJson()).toList()),
      );
    } catch (_) {}
  }

  /// 解除关联一个远程加密目录
  static Future<void> removeRemoteEncryptedDir(
    String connId,
    String serverPath,
  ) async {
    try {
      final normalized = normalizePosix(serverPath);
      final list = await loadRemoteEncryptedDirs();
      final kept = list
          .where((r) => !(r.connId == connId && r.serverPath == normalized))
          .toList();
      if (kept.length == list.length) return;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _kRemoteEncryptedDirsKey,
        jsonEncode(kept.map((r) => r.toJson()).toList()),
      );
    } catch (_) {}
  }

  /// 路径哈希（用于安全存储的 key）
  static String _pathHash(String path) {
    // 简单的字符串哈希，避免路径中包含特殊字符导致 key 非法
    var hash = 0;
    for (var i = 0; i < path.length; i++) {
      hash = (hash * 31 + path.codeUnitAt(i)) & 0x7fffffff;
    }
    return hash.toString();
  }
}

/// 「关联的远程加密目录」记录
///
/// 只存定位信息 + 档案 id，**不存密码**（密码永远从加密档案/安全存储取回）。
class RemoteCryptDirRecord {
  /// 远程连接 id
  final String connId;

  /// 服务器端的密文根目录（POSIX 归一化）
  final String serverPath;

  /// 使用的加密配置档案 id（可空 = 用当前默认档案/主密码）
  final String? profileId;

  /// 展示名（可空）
  final String? name;

  const RemoteCryptDirRecord({
    required this.connId,
    required this.serverPath,
    this.profileId,
    this.name,
  });

  Map<String, dynamic> toJson() => {
        'connId': connId,
        'serverPath': serverPath,
        if (profileId != null) 'profileId': profileId,
        if (name != null) 'name': name,
      };
}
