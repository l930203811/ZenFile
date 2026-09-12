import 'crypt_config.dart';

/// 加密配置档案（一组「名称 + 主密码 + 加盐 + 文件名编码/后缀」的完整配置）
///
/// 一个档案就等价于 rclone crypt 的一份 remote 配置。用户可以在「加密设置」页
/// 保存多份档案，用于给不同的文件/文件夹使用不同的密钥。
///
/// ⚠️ 密码与盐是本App解密的**唯一**凭据：一旦丢失或改错，对应的密文永久不可解。
/// 因此 [CryptProfile] 只保存在 FlutterSecureStorage（Android Keystore）中，
/// 绝不明文写入 SharedPreferences。
class CryptProfile {
  /// 档案唯一 ID（UUID v4 简版）
  final String id;

  /// 档案名称（用户可见，**全库唯一**，比对时 trim + 忽略大小写）
  final String name;

  /// 主密码
  final String password;

  /// 加盐（第二密码，可为空）
  final String? salt;

  final FilenameEncryption filenameEncryption;
  final bool directoryNameEncryption;
  final FilenameEncoding filenameEncoding;

  /// 加密文件后缀（默认 `.bin`，可为空串）
  final String encryptedSuffix;

  /// 创建时间（毫秒）
  final int createdAtMs;

  /// 是否为「当前默认档案」（新建加密 / 未绑定路径时使用的那一份）
  final bool isActive;

  const CryptProfile({
    required this.id,
    required this.name,
    required this.password,
    this.salt,
    this.filenameEncryption = FilenameEncryption.standard,
    this.directoryNameEncryption = true,
    this.filenameEncoding = FilenameEncoding.base32,
    this.encryptedSuffix = '.bin',
    this.createdAtMs = 0,
    this.isActive = false,
  });

  /// 生成新 ID（时间戳 + 随机数，不依赖 uuid 包）
  static String newId() {
    final now = DateTime.now().microsecondsSinceEpoch;
    final rnd = (now ^ (now >> 32)) & 0x7fffffff;
    return 'p${now.toRadixString(36)}${rnd.toRadixString(36)}';
  }

  factory CryptProfile.fromJson(Map<String, dynamic> json) {
    return CryptProfile(
      id: json['id'] as String? ?? '',
      name: json['name'] as String? ?? '',
      password: json['password'] as String? ?? '',
      salt: json['salt'] as String?,
      filenameEncryption: FilenameEncryption.values.firstWhere(
        (e) => e.name == (json['filenameEncryption'] as String? ?? 'standard'),
        orElse: () => FilenameEncryption.standard,
      ),
      directoryNameEncryption: json['directoryNameEncryption'] as bool? ?? true,
      filenameEncoding: FilenameEncoding.values.firstWhere(
        (e) => e.name == (json['filenameEncoding'] as String? ?? 'base32'),
        orElse: () => FilenameEncoding.base32,
      ),
      encryptedSuffix: json['encryptedSuffix'] as String? ?? '.bin',
      createdAtMs: json['createdAtMs'] as int? ?? 0,
      isActive: json['isActive'] as bool? ?? false,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'password': password,
        if (salt != null) 'salt': salt,
        'filenameEncryption': filenameEncryption.name,
        'directoryNameEncryption': directoryNameEncryption,
        'filenameEncoding': filenameEncoding.name,
        'encryptedSuffix': encryptedSuffix,
        'createdAtMs': createdAtMs,
        'isActive': isActive,
      };

  CryptProfile copyWith({
    String? id,
    String? name,
    String? password,
    String? salt,
    FilenameEncryption? filenameEncryption,
    bool? directoryNameEncryption,
    FilenameEncoding? filenameEncoding,
    String? encryptedSuffix,
    int? createdAtMs,
    bool? isActive,
  }) {
    return CryptProfile(
      id: id ?? this.id,
      name: name ?? this.name,
      password: password ?? this.password,
      salt: salt ?? this.salt,
      filenameEncryption: filenameEncryption ?? this.filenameEncryption,
      directoryNameEncryption:
          directoryNameEncryption ?? this.directoryNameEncryption,
      filenameEncoding: filenameEncoding ?? this.filenameEncoding,
      encryptedSuffix: encryptedSuffix ?? this.encryptedSuffix,
      createdAtMs: createdAtMs ?? this.createdAtMs,
      isActive: isActive ?? this.isActive,
    );
  }

  /// 转成 rclone crypt 运行时配置
  RcloneCryptConfig toConfig() => RcloneCryptConfig(
        password: password,
        salt: (salt == null || salt!.isEmpty) ? null : salt,
        filenameEncryption: filenameEncryption,
        directoryNameEncryption: directoryNameEncryption,
        filenameEncoding: filenameEncoding,
        encryptedSuffix: encryptedSuffix,
      );

  /// 名称比对键（trim + 小写），用于查重
  static String nameKey(String name) => name.trim().toLowerCase();

  @override
  String toString() => 'CryptProfile($id, $name)';
}
