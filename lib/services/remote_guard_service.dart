import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'vault_service.dart';
import '../ui/screens/remote_guard_screen.dart';

/// 远程访问保护服务：用 PIN 码保护「已保存的远程服务器」与「分类页的远程内容」。
///
/// PIN 与私人保险箱（VaultService，键前缀 vault_）**共用同一套**：本服务的
/// isPinSet / setPin / verifyPin / changePin 全部委托 VaultService，因此「修改 PIN 码」
/// 即修改保险箱密码（会重新加密所有已隐藏文件）。
///  - 保护开关 remote_guard_enabled / 启动应用保护 remote_guard_app_lock 仍各自独立
///  - 解锁状态：内存级会话标志，验证通过后本次运行内不再重复弹 PIN；
///    应用重启后自动重新锁定（冷启动保护）。
class RemoteGuardService {
  RemoteGuardService._();

  static const _kEnabled = 'remote_guard_enabled';
  /// 启动应用保护开关（与远程守卫共享同一套 PIN）
  static const _kAppLock = 'remote_guard_app_lock';

  /// 旧版（v1.1.30 及之前）远程守卫的独立 PIN 键，用于一次性迁移
  static const _kLegacySalt = 'remote_guard_salt';
  static const _kLegacyHash = 'remote_guard_hash';
  static bool _migrateChecked = false;

  /// 一次性迁移：旧版远程守卫 PIN 与保险箱使用同一套哈希方案（sha256(pin+salt)），
  /// 故直接将旧哈希搬至保险箱键即可保留用户原有 PIN，避免升级后远程守卫被锁死。
  /// 仅当保险箱尚未设置密码时执行；若已设置（用户已隐藏文件），则以保险箱 PIN 为准。
  static Future<void> _migrateLegacyPinIfNeeded() async {
    if (_migrateChecked) return;
    _migrateChecked = true;
    final prefs = await SharedPreferences.getInstance();
    if (prefs.containsKey('vault_password_hash')) return;
    final legacySalt = prefs.getString(_kLegacySalt);
    final legacyHash = prefs.getString(_kLegacyHash);
    if (legacySalt != null && legacyHash != null) {
      await prefs.setString('vault_salt', legacySalt);
      await prefs.setString('vault_password_hash', legacyHash);
      await prefs.remove(_kLegacySalt);
      await prefs.remove(_kLegacyHash);
    }
  }

  /// 会话级解锁标志（内存，不持久化：重启 App 后重新锁定）
  static bool _unlocked = false;

  /// 启动应用保护的会话级解锁标志（内存，不持久化：重启 App 后重新锁定）
  static bool _appUnlocked = false;

  // ── PIN 管理（委托 VaultService：与私人保险箱共用同一套） ──────────────────

  /// 是否已设置 PIN：等价于保险箱密码是否已设置
  static Future<bool> isPinSet() async {
    await _migrateLegacyPinIfNeeded();
    return VaultService.isPasswordSet();
  }

  /// 设置 PIN：等价于设置保险箱密码
  static Future<void> setPin(String pin) async => VaultService.setPassword(pin);

  /// 验证 PIN：等价于验证保险箱密码
  static Future<bool> verifyPin(String pin) async {
    await _migrateLegacyPinIfNeeded();
    return VaultService.verifyPassword(pin);
  }

  /// 修改 PIN：等价于修改保险箱密码（会重新加密所有已隐藏文件）；
  /// 返回 true 表示全部成功，false 表示存在失败（密码未更改）。
  static Future<bool> changePin(String oldPin, String newPin) async =>
      VaultService.changePassword(oldPin, newPin);

  // ── 保护开关 ────────────────────────────────────────────────────────────

  static Future<bool> isEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_kEnabled) ?? false;
  }

  static Future<void> setEnabled(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kEnabled, enabled);
    // 关闭保护即视为解锁，避免残留锁定态
    if (!enabled) _unlocked = true;
  }

  // ── 会话解锁状态 ────────────────────────────────────────────────────────

  static bool get isUnlocked => _unlocked;

  static void unlock() => _unlocked = true;

  static void lock() => _unlocked = false;

  // ── 启动应用保护 ────────────────────────────────────────────────────────

  /// 启动应用保护开关：开启后冷启动需输入 PIN 才能进入应用。
  /// 仅在已设置 PIN 时允许开启（UI 层保证）。
  static Future<bool> isAppLockEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_kAppLock) ?? false;
  }

  static Future<void> setAppLockEnabled(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kAppLock, enabled);
  }

  /// 启动保护会话级解锁标志（内存，不持久化：重启 App 后重新锁定）
  static bool get isAppUnlocked => _appUnlocked;

  static void unlockApp() => _appUnlocked = true;

  // ── 访问守卫 ────────────────────────────────────────────────────────────

  /// 进入远程内容前的统一守卫：
  ///  - 保护未开启或本次会话已解锁 → 直接放行（true）
  ///  - 否则弹出 PIN 验证页，验证通过则解锁并放行；取消/失败返回 false
  ///
  /// 在抽屉页连接项、网络分类页连接项、媒体分类页远程范围切换三处调用。
  static Future<bool> guard(BuildContext context) async {
    if (!await isEnabled()) return true;
    if (_unlocked) return true;
    if (!context.mounted) return false;
    final ok = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => const RemoteGuardScreen(mode: RemoteGuardMode.gate),
      ),
    );
    if (ok == true) {
      _unlocked = true;
      return true;
    }
    return false;
  }
}
