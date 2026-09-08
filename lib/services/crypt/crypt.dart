/// rclone crypt 兼容加密库 + CryptVFS 加密虚拟文件系统
///
/// 完全对齐 rclone crypt 后端的加密格式，支持与 rclone、OpenList
/// 创建的加密文件夹 100% 互操作。
///
/// ## 核心功能
/// - 文件名/目录名加密（standard / obfuscate / off）
/// - 文件内容流式加密/解密（NACL SecretBox XSalsa20-Poly1305）
/// - 随机访问（seek）支持
/// - Scrypt 密钥派生
/// - CryptVFS 加密虚拟文件系统（挂载点管理、路径映射、自动加解密）
/// - 原地加密/解密操作
///
/// ## 快速开始
///
/// ```dart
/// import 'package:zenfile/services/crypt/crypt.dart';
///
/// // 基础加密
/// final crypt = RcloneCrypt(
///   config: RcloneCryptConfig(
///     password: 'mypassword',
///     filenameEncryption: FilenameEncryption.standard,
///     filenameEncoding: FilenameEncoding.base32,
///     encryptedSuffix: '.bin',
///   ),
/// );
///
/// final encrypted = crypt.encryptFileName('video.mp4');
/// final decrypted = crypt.decryptFileName(encrypted);
///
/// // CryptVFS 加密虚拟文件系统
/// final vfs = CryptVFS();
/// vfs.mount(CryptMountPoint(
///   physicalPath: '/path/to/encrypted/folder',
///   config: crypt.config,
/// ));
///
/// final entries = await vfs.listDirectory('/path/to/encrypted/folder');
/// ```
library;

export 'crypt_config.dart';
export 'scrypt.dart';
export 'filename_cipher.dart';
export 'stream_cipher.dart';
export 'rclone_crypt.dart';
export 'crypt_mount.dart';
export 'crypt_mount_service.dart';
export 'crypt_file.dart';
export 'crypt_operations.dart';
export 'crypt_vfs.dart';
export 'crypt_stream_server.dart';
export 'vault_crypt_service.dart';
