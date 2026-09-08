/// rclone crypt 兼容加密库 - 配置模型与常量
///
/// 完全对齐 rclone crypt 后端的加密格式和配置项，
/// 确保与 rclone、OpenList 创建的加密文件夹 100% 互操作。
library;

import 'dart:typed_data';

/// 文件名加密模式
enum FilenameEncryption {
  /// 不加密文件名（仅加密文件内容）
  off,

  /// 标准加密：NACL SecretBox (XSalsa20-Poly1305) + base32/base64 编码
  standard,

  /// 简单混淆：XOR + 位移，轻量但不安全
  obfuscate,
}

/// 文件名编码方式
enum FilenameEncoding {
  base64,
  base32,
  base32768,
}

/// rclone crypt 加密配置
///
/// 对应 rclone crypt 后端的全部配置项，与 OpenList 截图中的配置一一对应。
class RcloneCryptConfig {
  /// 主密码（用于派生密钥）
  final String password;

  /// 盐值（第二密码，增强抗暴破能力，可为空）
  final String? salt;

  /// 文件名加密模式
  final FilenameEncryption filenameEncryption;

  /// 是否加密目录名
  final bool directoryNameEncryption;

  /// 文件名编码方式
  final FilenameEncoding filenameEncoding;

  /// 加密文件后缀（默认 .bin）
  final String encryptedSuffix;

  /// 是否显示隐藏文件
  final bool showHidden;

  const RcloneCryptConfig({
    required this.password,
    this.salt,
    this.filenameEncryption = FilenameEncryption.standard,
    this.directoryNameEncryption = true,
    this.filenameEncoding = FilenameEncoding.base32,
    this.encryptedSuffix = '.bin',
    this.showHidden = true,
  });

  /// 从 JSON 反序列化
  ///
  /// [password] 可选密码参数。如果 JSON 中包含密码（includePassword=true 序列化），
  /// 优先使用 JSON 中的密码；否则使用传入的密码。
  factory RcloneCryptConfig.fromJson(Map<String, dynamic> json, [String? password]) {
    return RcloneCryptConfig(
      password: json['password'] as String? ?? password ?? '', 
      salt: json['salt'] as String?,
      filenameEncryption: FilenameEncryption.values.firstWhere(
        (e) => e.name == (json['filename_encryption'] as String? ?? 'standard'),
        orElse: () => FilenameEncryption.standard,
      ),
      directoryNameEncryption: json['directory_name_encryption'] as bool? ?? true,
      filenameEncoding: FilenameEncoding.values.firstWhere(
        (e) => e.name == (json['filename_encoding'] as String? ?? 'base32'),
        orElse: () => FilenameEncoding.base32,
      ),
      encryptedSuffix: json['encrypted_suffix'] as String? ?? '.bin',
      showHidden: json['show_hidden'] as bool? ?? true,
    );
  }

  /// 序列化为 JSON（不含密码明文，用于备份/共享时需单独加密密码）
  Map<String, dynamic> toJson({bool includePassword = false}) {
    return {
      if (includePassword) 'password': password,
      if (salt != null) 'salt': salt,
      'filename_encryption': filenameEncryption.name,
      'directory_name_encryption': directoryNameEncryption,
      'filename_encoding': filenameEncoding.name,
      'encrypted_suffix': encryptedSuffix,
      'show_hidden': showHidden,
    };
  }

  RcloneCryptConfig copyWith({
    String? password,
    String? salt,
    FilenameEncryption? filenameEncryption,
    bool? directoryNameEncryption,
    FilenameEncoding? filenameEncoding,
    String? encryptedSuffix,
    bool? showHidden,
  }) {
    return RcloneCryptConfig(
      password: password ?? this.password,
      salt: salt ?? this.salt,
      filenameEncryption: filenameEncryption ?? this.filenameEncryption,
      directoryNameEncryption: directoryNameEncryption ?? this.directoryNameEncryption,
      filenameEncoding: filenameEncoding ?? this.filenameEncoding,
      encryptedSuffix: encryptedSuffix ?? this.encryptedSuffix,
      showHidden: showHidden ?? this.showHidden,
    );
  }
}

// ============================================================
// rclone crypt 格式常量
//
// 严格对齐 rclone v1.75.1 backend/crypt/cipher.go（OpenList 的 crypt
// 驱动即直接调用该实现），确保与 rclone / OpenList 100% 互操作。
// ============================================================

/// rclone crypt 文件头大小（32 字节）
///
/// 结构（rclone: fileHeaderSize = fileMagicSize + fileNonceSize）：
/// - 0-7:   magic "RCLONE\x00\x00"（8 字节，**大写** RCLONE + 两个 NUL）
/// - 8-31:  nonce（24 字节，加密时由 CSPRNG 随机生成）
///
/// 注意：文件头里 **没有 version 字段、也没有 salt** —— nonce 同时承担
/// 这两个角色（每块加密时 nonce 递增）。
const int fileHeaderSize = 32;

/// magic 长度（8 字节）
const int fileMagicSize = 8;

/// 文件头中 nonce 的长度（24 字节）
const int fileHeaderNonceLength = 24;

/// rclone crypt 文件头 magic："RCLONE\x00\x00"
///
/// 必须是**大写** RCLONE（ASCII 82,67,76,79,78,69）后接两个 0 字节。
/// 早期误写成小写 "rclone\0\0"，会导致与 rclone/OpenList 完全不兼容。
const List<int> fileHeaderMagicBytes = [82, 67, 76, 79, 78, 69, 0, 0];

/// rclone crypt 数据块明文大小（64 KiB）
///
/// 每个块用 secretbox 独立加密，nonce 由「文件头 nonce + 已加密块数」递增得到。
const int cryptBlockSize = 64 * 1024;

/// 每个加密块的额外开销 = secretbox.Overhead = Poly1305 tag（16 字节）
///
/// 加密块布局：`ciphertext(n) || tag(16)`。
/// 注意：rclone **不在块头存 nonce**（nonce 由文件头 nonce 递增派生）。
const int blockOverhead = 16;

/// Poly1305 tag 长度
const int poly1305TagLength = 16;

/// NACL SecretBox (XSalsa20-Poly1305) 的 nonce 长度（24 字节）
const int secretBoxNonceLength = 24;

/// Scrypt 密钥派生参数（rclone crypt 标准参数）
///
/// rclone: scrypt.Key(password, salt, 16384, 8, 1, keySize)
/// 其中 keySize = len(dataKey) + len(nameKey) + len(nameTweak) = 32+32+16 = **80**
const int scryptN = 16384;
const int scryptR = 8;
const int scryptP = 1;
const int scryptKeyLength = 80;

/// 派生密钥各段长度
const int keyLengthData = 32; // dataKey：文件内容加密（secretbox）
const int keyLengthFilename = 32; // nameKey：文件名加密（AES-EME）
const int keyLengthNameTweak = 16; // nameTweak：EME 的 tweak

/// NACL SecretBox 密钥长度
const int secretBoxKeyLength = 32;

/// 文件名加密的 AES 分组大小（EME 以 16 字节为一组）
const int nameCipherBlockSize = 16;

/// rclone 在未配置 salt 时使用的内置 salt（16 字节）
///
/// rclone cipher.go: `defaultSalt = []byte{0xA8, 0x0D, ...}`
/// 早期实现在 salt 为空时传了空字节数组，会派生出完全不同的密钥。
const List<int> defaultSaltBytes = [
  0xA8, 0x0D, 0xF4, 0x3A, //
  0x8F, 0xBD, 0x03, 0x08, //
  0xA7, 0xCA, 0xB8, 0x3E, //
  0x58, 0x1F, 0x86, 0xB1, //
];
