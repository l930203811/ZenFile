/// CryptVFS - 加密虚拟文件系统
///
/// 在 rclone crypt 兼容加密核心库的基础上，提供虚拟文件系统层。
/// 加密挂载点内的文件和文件夹在本应用内可以像普通文件一样操作，
/// 用其他文件管理器打开则是密文。
///
/// ## 核心功能
/// - 挂载点管理：挂载/卸载加密目录
/// - 路径映射：虚拟路径（解密后）<-> 物理路径（加密后）
/// - 文件操作：加密文件的随机读写（自动加解密）
/// - 目录枚举：列出加密目录时自动解密文件名
/// - 原地加解密：将普通文件/文件夹加密为 crypt 格式，或解密回来
///
/// ## 使用示例
///
/// ```dart
/// // 创建 CryptVFS 实例
/// final vfs = CryptVFS();
///
/// // 挂载加密目录
/// final mount = CryptMountPoint(
///   physicalPath: '/storage/emulated/0/MyEncryptedFolder',
///   config: RcloneCryptConfig(
///     password: 'mypassword',
///     filenameEncryption: FilenameEncryption.standard,
///     filenameEncoding: FilenameEncoding.base32,
///     encryptedSuffix: '.bin',
///   ),
/// );
/// vfs.mount(mount);
///
/// // 枚举加密目录（自动解密文件名）
/// final entries = await vfs.listDirectory('/storage/emulated/0/MyEncryptedFolder');
/// for (final entry in entries) {
///   print('${entry.name} (${entry.size} bytes)');
/// }
///
/// // 读取加密文件（自动解密）
/// final file = await vfs.openFile(
///   '/storage/emulated/0/MyEncryptedFolder/document.txt',
///   mode: CryptFileMode.read,
/// );
/// final content = await file.read(0, 1024);
/// await file.close();
///
/// // 原地加密普通文件
/// await vfs.encryptFile('/storage/emulated/0/MyEncryptedFolder/photo.jpg');
/// ```
library;

import 'dart:io';
import 'package:path/path.dart' as p;
import 'crypt_config.dart';
import 'crypt_mount.dart';
import 'crypt_file.dart';
import 'crypt_operations.dart';
import 'rclone_crypt.dart';

export 'crypt_config.dart';
export 'crypt_mount.dart';
export 'crypt_file.dart';
export 'crypt_operations.dart';
export 'rclone_crypt.dart';
export 'scrypt.dart';
export 'stream_cipher.dart';
export 'filename_cipher.dart';

/// 加密虚拟文件系统
class CryptVFS {
  final CryptMountManager _mountManager = CryptMountManager();

  /// 所有挂载点（只读视图）
  List<CryptMountPoint> get mountPoints => _mountManager.mountPoints;

  /// 挂载加密目录
  void mount(CryptMountPoint mountPoint) {
    _mountManager.mount(mountPoint);
  }

  /// 卸载加密目录
  bool unmount(String physicalPath) {
    return _mountManager.unmount(physicalPath);
  }

  /// 查找包含给定路径的挂载点
  CryptMountPoint? findMountPoint(String path) {
    return _mountManager.findMountPointForPath(path);
  }

  /// 判断路径是否在任何加密挂载点内
  bool isEncryptedPath(String path) {
    return _mountManager.isEncryptedPath(path);
  }

  /// 将虚拟路径（解密后）转换为物理路径（加密后）
  ///
  /// 如果路径不在任何挂载点内，返回原路径。
  String virtualToPhysical(String virtualPath) {
    final mount = _mountManager.findMountPointForPath(virtualPath);
    if (mount == null) return virtualPath;
    return mount.virtualToPhysical(virtualPath);
  }

  /// 将物理路径（加密后）转换为虚拟路径（解密后）
  ///
  /// 如果路径不在任何挂载点内，返回原路径。
  String physicalToVirtual(String physicalPath) {
    final mount = _mountManager.findMountPointForPath(physicalPath);
    if (mount == null) return physicalPath;
    return mount.physicalToVirtual(physicalPath);
  }

  /// 枚举加密目录（自动解密文件名）
  ///
  /// [virtualDirPath] 解密后的目录路径（虚拟路径）
  /// [showHidden] 是否显示隐藏文件
  ///
  /// 如果路径不在任何挂载点内，抛出异常。
  Future<List<CryptFileEntry>> listDirectory(
    String virtualDirPath, {
    bool showHidden = false,
  }) async {
    final mount = _mountManager.findMountPointForPath(virtualDirPath);
    if (mount == null) {
      throw StateError('Path is not in any encrypted mount point: $virtualDirPath');
    }

    final lister = CryptDirectoryLister(mount);
    return lister.listDirectory(virtualDirPath, showHidden: showHidden);
  }

  /// 打开加密文件进行读写（自动加解密）
  ///
  /// [virtualPath] 解密后的文件路径（虚拟路径）
  /// [mode] 打开模式（只读/只写/追加）
  ///
  /// 如果路径不在任何挂载点内，抛出异常。
  Future<CryptFile> openFile(
    String virtualPath, {
    CryptFileMode mode = CryptFileMode.read,
  }) async {
    final mount = _mountManager.findMountPointForPath(virtualPath);
    if (mount == null) {
      throw StateError('Path is not in any encrypted mount point: $virtualPath');
    }

    final physicalPath = mount.virtualToPhysical(virtualPath);
    return CryptFile.open(physicalPath, mount.crypt, mode: mode);
  }

  /// 原地加密单个文件
  ///
  /// 将普通文件加密为 crypt 格式，加密后原文件被替换为加密文件。
  /// 文件必须在挂载点内。
  Future<String> encryptFile(String sourcePath) async {
    final mount = _mountManager.findMountPointForPath(sourcePath);
    if (mount == null) {
      throw StateError('Path is not in any encrypted mount point: $sourcePath');
    }

    final operations = CryptOperations(mount);
    return operations.encryptFile(sourcePath);
  }

  /// 原地解密单个文件
  ///
  /// 将 crypt 加密文件解密为普通文件，解密后原文件被替换为解密文件。
  /// 文件必须在挂载点内。
  Future<String> decryptFile(String encryptedPath) async {
    final mount = _mountManager.findMountPointForPath(encryptedPath);
    if (mount == null) {
      throw StateError('Path is not in any encrypted mount point: $encryptedPath');
    }

    final operations = CryptOperations(mount);
    return operations.decryptFile(encryptedPath);
  }

  /// 原地加密文件夹（递归加密所有文件和子文件夹）
  Future<void> encryptDirectory(
    String sourceDirPath, {
    void Function(int processed, int total)? onProgress,
  }) async {
    final mount = _mountManager.findMountPointForPath(sourceDirPath);
    if (mount == null) {
      throw StateError('Path is not in any encrypted mount point: $sourceDirPath');
    }

    final operations = CryptOperations(mount);
    return operations.encryptDirectory(sourceDirPath, onProgress: onProgress);
  }

  /// 原地解密文件夹（递归解密所有文件和子文件夹）
  Future<void> decryptDirectory(
    String encryptedDirPath, {
    void Function(int processed, int total)? onProgress,
  }) async {
    final mount = _mountManager.findMountPointForPath(encryptedDirPath);
    if (mount == null) {
      throw StateError('Path is not in any encrypted mount point: $encryptedDirPath');
    }

    final operations = CryptOperations(mount);
    return operations.decryptDirectory(encryptedDirPath, onProgress: onProgress);
  }

  /// 卸载所有挂载点
  void unmountAll() {
    _mountManager.unmountAll();
  }
}
