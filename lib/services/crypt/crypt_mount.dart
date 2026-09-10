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

  CryptMountPoint({
    required this.physicalPath,
    required this.config,
    String? name,
    this.isSandboxMode = false,
  }) : name = name ?? p.basename(physicalPath) {
    crypt = RcloneCrypt(config: config);
  }

  /// 创建副本并修改指定字段
  CryptMountPoint copyWith({
    String? physicalPath,
    RcloneCryptConfig? config,
    String? name,
    bool? isSandboxMode,
    String? password,
  }) {
    // 仅传 password 时（如 _loadMountsWithPassword 用当前保险箱密码重建），
    // 必须基于已有 config 派生副本。旧写法 `config!` 在 config 为 null 时
    // 会抛 Null check 异常，导致导入/列表加载整体失败。
    final baseConfig = config ?? this.config;
    return CryptMountPoint(
      physicalPath: physicalPath ?? this.physicalPath,
      config: password != null ? baseConfig.copyWith(password: password) : baseConfig,
      name: name ?? this.name,
      isSandboxMode: isSandboxMode ?? this.isSandboxMode,
    );
  }

  /// 判断给定路径是否在此挂载点内
  bool containsPath(String path) {
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
    // 1) 已解密的明文文件
    try {
      if (await File(virtualPath).exists()) return virtualPath;
    } catch (_) {}

    // 2) 标准映射
    String mapped;
    try {
      mapped = virtualToPhysical(virtualPath);
    } catch (_) {
      return virtualPath;
    }
    try {
      if (await File(mapped).exists()) return mapped;
    } catch (_) {}

    // 3) 后缀不一致：尝试去掉 / 补上配置的加密后缀
    final suffix = config.encryptedSuffix;
    if (suffix.isNotEmpty) {
      final withoutSuffix = mapped.endsWith(suffix)
          ? mapped.substring(0, mapped.length - suffix.length)
          : mapped;
      try {
        if (withoutSuffix != mapped && await File(withoutSuffix).exists()) {
          return withoutSuffix;
        }
      } catch (_) {}
      try {
        final withSuffix = mapped.endsWith(suffix) ? mapped : '$mapped$suffix';
        if (withSuffix != mapped && await File(withSuffix).exists()) {
          return withSuffix;
        }
      } catch (_) {}
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

  /// 序列化为 JSON（用于持久化存储，不含密码）
  Map<String, dynamic> toJson() {
    return {
      'physicalPath': physicalPath,
      'name': name,
      'isSandboxMode': isSandboxMode,
      'config': config.toJson(),
    };
  }

  /// 从 JSON 反序列化（需要额外传入密码）
  factory CryptMountPoint.fromJson(Map<String, dynamic> json, String password) {
    return CryptMountPoint(
      physicalPath: json['physicalPath'] as String,
      name: json['name'] as String?,
      isSandboxMode: json['isSandboxMode'] as bool? ?? false,
      config: RcloneCryptConfig.fromJson(json['config'] as Map<String, dynamic>, password),
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
