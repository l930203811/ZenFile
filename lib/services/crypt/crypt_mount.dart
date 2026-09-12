/// CryptVFS 挂载点模型与管理
///
/// 挂载点是一个被配置为 rclone crypt 加密的本地目录。
/// 在挂载点内，文件名和文件内容都会被自动加密/解密。
library;

import 'dart:io';

import 'package:path/path.dart' as p;
import 'crypt_config.dart';
import 'rclone_crypt.dart';

/// 加密挂载点
class CryptMountPoint {
  /// 挂载点的物理路径（加密文件实际存储的目录）
  final String physicalPath;

  /// 加密配置（密码、盐、文件名加密模式等）
  final RcloneCryptConfig config;

  /// 挂载点名称（用于显示）
  final String name;

  /// rclone crypt 加密器实例
  late final RcloneCrypt crypt;

  /// 是否为沙盒模式（沙盒模式下加密文件移动到专用沙盒目录）
  final bool isSandboxMode;

  // ── 远程加密目录（客户端解密，v1 只读） ──────────────────────────────
  //
  // 密文存放在原始后端（SFTP/WebDAV/SMB/FTP）上，由客户端按块拉取并解密。
  // 与本地挂载点的区别：没有磁盘物理路径，[physicalPath] 对远程挂载点而言
  // 就是虚拟根 `cryptremote://{connId}|{serverBasePath}`。

  /// 远程连接 id（对应 [NetworkConnectionsService] 中的连接）
  final String? remoteConnId;

  /// 服务器端的**密文**根目录（其内容为 rclone crypt 加密名）
  final String? remoteBasePath;

  /// 使用的加密配置档案 id（用于按档案取回密码/盐）
  final String? remoteProfileId;

  CryptMountPoint({
    required this.physicalPath,
    required this.config,
    String? name,
    this.isSandboxMode = false,
    this.remoteConnId,
    this.remoteBasePath,
    this.remoteProfileId,
  }) : name = name ?? (remoteBasePath ?? p.basename(physicalPath)) {
    crypt = RcloneCrypt(config: config);
  }

  /// 创建一个**远程**加密挂载点（密文在后端，客户端解密）。
  factory CryptMountPoint.remote({
    required String connId,
    required String basePath,
    required RcloneCryptConfig config,
    String? profileId,
    String? name,
  }) {
    return CryptMountPoint(
      physicalPath: 'cryptremote://$connId|$basePath',
      config: config,
      name: name ?? basePath,
      remoteConnId: connId,
      remoteBasePath: basePath,
      remoteProfileId: profileId,
    );
  }

  /// 是否远程（客户端解密）挂载点
  bool get isRemote => remoteConnId != null && remoteBasePath != null;

  /// 远程挂载点的虚拟根：`cryptremote://{connId}|{serverBasePath}`
  String get remoteVirtualRoot => 'cryptremote://$remoteConnId|$remoteBasePath';

  /// 把虚拟路径（`cryptremote://{connId}|{serverEncryptedPath}`）还原成
  /// 服务器真实路径（密文名），用于远程枚举/流式解密时传给 [RemoteClient]。
  String virtualToRemoteServerPath(String virtualPath) {
    final sep = virtualPath.indexOf('|');
    if (sep < 0) return virtualPath;
    return virtualPath.substring(sep + 1);
  }

  /// 创建副本并修改指定字段
  CryptMountPoint copyWith({
    String? physicalPath,
    RcloneCryptConfig? config,
    String? name,
    bool? isSandboxMode,
    String? password,
    String? remoteConnId,
    String? remoteBasePath,
    String? remoteProfileId,
  }) {
    // 仅传 password 时（如 _loadMountsWithPassword 用当前保险箱密码重建），
    // 必须基于已有 config 派生副本。旧写法 `config!` 在 config 为 null 时
    // 会抛 Null check 异常，导致导入/列表加载整体失败。
    final baseConfig = config ?? this.config;
    final connId = remoteConnId ?? this.remoteConnId;
    final basePath = remoteBasePath ?? this.remoteBasePath;
    final profId = remoteProfileId ?? this.remoteProfileId;
    final String phys;
    if (remoteConnId != null && remoteBasePath != null) {
      // 显式更换远程后端时重算虚拟根
      phys = 'cryptremote://$remoteConnId|$remoteBasePath';
    } else {
      phys = physicalPath ?? this.physicalPath;
    }
    return CryptMountPoint(
      physicalPath: phys,
      config: password != null ? baseConfig.copyWith(password: password) : baseConfig,
      name: name ?? this.name,
      isSandboxMode: isSandboxMode ?? this.isSandboxMode,
      remoteConnId: connId,
      remoteBasePath: basePath,
      remoteProfileId: profId,
    );
  }

  /// 判断给定路径是否在此挂载点内
  bool containsPath(String path) {
    // 远程挂载点：按虚拟根前缀匹配（`://` 不能被 p.normalize 处理）。
    if (isRemote) {
      final root = remoteVirtualRoot;
      return path == root || path.startsWith('$root/');
    }
    final normalizedPhysical = p.normalize(physicalPath);
    final normalizedPath = p.normalize(path);
    if (normalizedPath == normalizedPhysical) return true;
    // 用 p.separator 而非硬编码 '/'：Windows 上 normalize 后是反斜杠，
    // 硬编码 '/' 会导致子路径永远匹配不上（Android/Linux 无此问题）。
    return normalizedPath.startsWith(normalizedPhysical + p.separator);
  }

  /// 将虚拟路径（解密后的相对路径）转换为物理路径（加密后的绝对路径）
  String virtualToPhysical(String virtualPath) {
    // 计算相对于挂载点的路径
    final relative = p.relative(virtualPath, from: physicalPath);
    if (relative == '.' || relative.isEmpty) {
      return physicalPath;
    }

    // 分段加密路径
    final segments = p.split(relative);
    final encryptedSegments = <String>[];

    for (var i = 0; i < segments.length; i++) {
      final segment = segments[i];
      final isLast = i == segments.length - 1;

      if (isLast) {
        // 最后一段可能是文件（加后缀）或目录（不加后缀）
        // 这里统一按文件名加密（加后缀），目录枚举时会处理
        encryptedSegments.add(crypt.encryptFileName(segment));
      } else {
        // 中间段是目录
        encryptedSegments.add(crypt.encryptDirName(segment));
      }
    }

    return p.join(physicalPath, p.joinAll(encryptedSegments));
  }

  /// 将物理路径（加密后的绝对路径）转换为虚拟路径（解密后的相对路径）
  String physicalToVirtual(String physicalPath) {
    final relative = p.relative(physicalPath, from: this.physicalPath);
    if (relative == '.' || relative.isEmpty) {
      return physicalPath;
    }

    final segments = p.split(relative);
    final decryptedSegments = <String>[];

    for (var i = 0; i < segments.length; i++) {
      final segment = segments[i];
      try {
        // 先尝试按文件名解密（会自动去除后缀）
        decryptedSegments.add(crypt.decryptFileName(segment));
      } catch (_) {
        try {
          // 再尝试按目录名解密
          decryptedSegments.add(crypt.decryptDirName(segment));
        } catch (_) {
          // 解密失败，保留原文
          decryptedSegments.add(segment);
        }
      }
    }

    return p.join(this.physicalPath, p.joinAll(decryptedSegments));
  }

  /// 解析虚拟路径对应的**磁盘上真实存在**的物理路径（异步，带兜底）。
  ///
  /// ⚠️ 为什么不能只用 [virtualToPhysical]：
  /// `virtualToPhysical` 把虚拟名**重新加密**得到密文名，`decryptFileName` 则是
  /// 把密文名**解密**得到虚拟名。二者并不对称——解密时会先剥掉加密后缀再解码，
  /// 而加密时一定会按配置追加后缀。于是当挂载点配置的「文件名编码 / 加密后缀」
  /// 与文件当初被加密时所用的不一致时（典型场景：
  ///   · OpenList 用 base64 + **空后缀**，而本地挂载点配置仍是 `.bin`；
  ///   · 用户在加密设置里把后缀清空后，此前用 `.bin` 加密的本应用文件），
  /// 目录枚举（走 decryptFileName）**能正常显示解密名**，但
  /// `virtualToPhysical` 算出来的名字在磁盘上不存在 → 打开文件时 File.exists()
  /// 为 false → 图片打不开、音视频拿到一个不存在的路径无法播放。
  ///
  /// 兜底优先级：
  /// 1. 虚拟路径本身存在 → 文件已是明文（已解密），直接用；
  /// 2. `virtualToPhysical` 结果存在 → 正常映射；
  /// 3. `virtualToPhysical` 结果加减后缀后存在 → 兼容后缀配置不一致；
  /// 4. 扫描父目录，找「解密后名字 == 虚拟 basename」的条目
  ///    （与 CryptDirectoryLister 的枚举逻辑互为逆运算，必定命中）；
  /// 5. 都不存在时返回映射结果（调用方自行判空/报错）。
  Future<String> resolvePhysicalPath(String virtualPath) async {
    // 1) 已解密的明文文件/目录
    if (await _pathExists(virtualPath)) return virtualPath;

    // 2) 标准映射
    String mapped;
    try {
      mapped = virtualToPhysical(virtualPath);
    } catch (_) {
      return virtualPath;
    }
    if (await _pathExists(mapped)) return mapped;

    // 3) 后缀不一致：尝试去掉 / 补上配置的加密后缀
    //
    // ⚠️ 目录场景必须有这一步：目录名在 rclone 里**不带**加密后缀，
    // 但 virtualToPhysical 对最后一段统一走 encryptFileName（会加后缀），
    // 于是「进入加密文件夹」算出的路径必然不存在。去掉后缀后即为目录密文名。
    final suffix = config.encryptedSuffix;
    if (suffix.isNotEmpty) {
      final withoutSuffix = mapped.endsWith(suffix)
          ? mapped.substring(0, mapped.length - suffix.length)
          : mapped;
      if (withoutSuffix != mapped && await _pathExists(withoutSuffix)) {
        return withoutSuffix;
      }
      final withSuffix = mapped.endsWith(suffix) ? mapped : '$mapped$suffix';
      if (withSuffix != mapped && await _pathExists(withSuffix)) {
        return withSuffix;
      }
    }

    // 4) 目录扫描兜底：按解密名反查
    try {
      final parent = Directory(p.dirname(virtualPath));
      if (await parent.exists()) {
        final target = p.basename(virtualPath);
        await for (final entity in parent.list()) {
          final name = p.basename(entity.path);
          if (name == target) return entity.path;
          try {
            if (crypt.decryptFileName(name) == target) return entity.path;
          } catch (_) {}
          try {
            if (crypt.decryptDirName(name) == target) return entity.path;
          } catch (_) {}
        }
      }
    } catch (_) {}

    return mapped;
  }

  /// 路径是否以文件或目录形式存在。
  ///
  /// ⚠️ 不能只用 `File(path).exists()`：对**目录**它恒为 false，会让
  /// [resolvePhysicalPath] 跳过正确映射、退化到昂贵的目录扫描，
  /// 甚至在扫描也失败时返回一个不存在的路径。
  static Future<bool> _pathExists(String path) async {
    try {
      if (await File(path).exists()) return true;
    } catch (_) {}
    try {
      if (await Directory(path).exists()) return true;
    } catch (_) {}
    return false;
  }

  /// 序列化为 JSON（用于持久化存储，不含密码）
  Map<String, dynamic> toJson() {
    return {
      'physicalPath': physicalPath,
      'name': name,
      'isSandboxMode': isSandboxMode,
      'config': config.toJson(),
      if (remoteConnId != null) 'remoteConnId': remoteConnId,
      if (remoteBasePath != null) 'remoteBasePath': remoteBasePath,
      if (remoteProfileId != null) 'remoteProfileId': remoteProfileId,
    };
  }

  /// 从 JSON 反序列化（需要额外传入密码）
  factory CryptMountPoint.fromJson(Map<String, dynamic> json, String password) {
    return CryptMountPoint(
      physicalPath: json['physicalPath'] as String,
      name: json['name'] as String?,
      isSandboxMode: json['isSandboxMode'] as bool? ?? false,
      config: RcloneCryptConfig.fromJson(json['config'] as Map<String, dynamic>, password),
      remoteConnId: json['remoteConnId'] as String?,
      remoteBasePath: json['remoteBasePath'] as String?,
      remoteProfileId: json['remoteProfileId'] as String?,
    );
  }
}

/// 挂载点管理器
///
/// 管理所有加密挂载点，提供挂载/卸载/查询功能。
class CryptMountManager {
  final List<CryptMountPoint> _mountPoints = [];

  /// 所有挂载点（只读视图）
  List<CryptMountPoint> get mountPoints => List.unmodifiable(_mountPoints);

  /// 挂载一个加密目录
  void mount(CryptMountPoint mountPoint) {
    // 检查是否已挂载
    final existing = _findMountPoint(mountPoint.physicalPath);
    if (existing != null) {
      throw StateError('Path already mounted: ${mountPoint.physicalPath}');
    }
    _mountPoints.add(mountPoint);
  }

  /// 卸载一个加密目录
  bool unmount(String physicalPath) {
    final index = _mountPoints.indexWhere((m) => p.equals(m.physicalPath, physicalPath));
    if (index >= 0) {
      _mountPoints.removeAt(index);
      return true;
    }
    return false;
  }

  /// 查找包含给定路径的挂载点
  CryptMountPoint? findMountPointForPath(String path) {
    // 找到最长匹配的挂载点
    CryptMountPoint? bestMatch;
    for (final mount in _mountPoints) {
      if (mount.containsPath(path)) {
        if (bestMatch == null ||
            mount.physicalPath.length > bestMatch.physicalPath.length) {
          bestMatch = mount;
        }
      }
    }
    return bestMatch;
  }

  /// 判断路径是否在任何挂载点内
  bool isEncryptedPath(String path) {
    return findMountPointForPath(path) != null;
  }

  /// 查找指定物理路径的挂载点
  CryptMountPoint? _findMountPoint(String physicalPath) {
    for (final mount in _mountPoints) {
      if (p.equals(mount.physicalPath, physicalPath)) {
        return mount;
      }
    }
    return null;
  }

  /// 卸载所有挂载点
  void unmountAll() {
    _mountPoints.clear();
  }
}
