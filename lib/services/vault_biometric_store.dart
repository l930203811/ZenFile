import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// 生物识别解锁的密码保管。
///
/// 保险箱密码经 Android Keystore（EncryptedSharedPreferences）/ iOS Keychain 加密存储，
/// 仅在 [local_auth] 生物识别验证通过后才读取，用于自动填充并解锁保险箱，避免每次手动输入。
///
/// 注意：此处存储的是用户自设的保险箱密码本身，并非主密钥。即便设备未设置生物识别，
/// 该值也受 Keystore/Keychain 硬件级保护；生物识别只是读取前的第二道身份验证。
class VaultBiometricStore {
  static const String _kPassword = 'vault_biometric_password';

  static const FlutterSecureStorage _storage = FlutterSecureStorage();

  /// 保存（启用指纹解锁时调用）。覆盖式写入。
  static Future<void> save(String password) async {
    await _storage.write(key: _kPassword, value: password);
  }

  /// 读取已保存的密码。未保存则返回 null。
  static Future<String?> read() async {
    return _storage.read(key: _kPassword);
  }

  /// 清除（关闭指纹解锁时调用）。
  static Future<void> clear() async {
    await _storage.delete(key: _kPassword);
  }

  /// 是否已保存过凭据（用于决定是否显示指纹解锁按钮）。
  static Future<bool> hasCredential() async {
    final v = await _storage.read(key: _kPassword);
    return v != null && v.isNotEmpty;
  }

  // ── 偏好解锁方式（下次解锁时优先自动弹出） ─────────────────────────────
  // 取值：'biometric'（指纹）/ 'password'（密码）。分别记录保险箱与远程守卫，
  // 因为二者入口独立、用户可能在不同场景偏好不同方式。

  static const String _kVaultMethod = 'vault_preferred_unlock';
  static const String _kGuardMethod = 'remote_guard_preferred_unlock';

  /// 保存保险箱偏好解锁方式。
  static Future<void> savePreferredUnlock(String method) async {
    await _storage.write(key: _kVaultMethod, value: method);
  }

  /// 读取保险箱偏好解锁方式；未设置返回 null。
  static Future<String?> readPreferredUnlock() async {
    return _storage.read(key: _kVaultMethod);
  }

  /// 保存远程守卫/启动应用保护偏好解锁方式。
  static Future<void> saveGuardPreferredUnlock(String method) async {
    await _storage.write(key: _kGuardMethod, value: method);
  }

  /// 读取远程守卫/启动应用保护偏好解锁方式；未设置返回 null。
  static Future<String?> readGuardPreferredUnlock() async {
    return _storage.read(key: _kGuardMethod);
  }
}
