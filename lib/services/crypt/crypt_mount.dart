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
    return CryptMountPoint(
      physicalPath: physicalPath ?? this.physicalPath,
      config: password != null ? config!.copyWith(password: password) : (config ?? this.config),
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
