import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:crypto/crypto.dart';
import '../ui/screens/remote_guard_screen.dart';

/// 远程访问保护服务：用 PIN 码保护「已保存的远程服务器」与「分类页的远程内容」。
///
/// 与私人保险箱（VaultService，键前缀 vault_）相互独立，各自维护 PIN：
///  - 设置/验证：SHA-256(salt + pin)，盐为微秒时间戳（与保险箱同方案）
///  - 保护开关：remote_guard_enabled，关闭后所有远程入口不再要求 PIN
///  - 解锁状态：内存级会话标志，验证通过后本次运行内不再重复弹 PIN；
///    应用重启后自动重新锁定（冷启动保护）。
class RemoteGuardService {
  RemoteGuardService._();

  static const _kSalt = 'remote_guard_salt';
  static const _kHash = 'remote_guard_hash';
  static const _kEnabled = 'remote_guard_enabled';

  /// 会话级解锁标志（内存，不持久化：重启 App 后重新锁定）
  static bool _unlocked = false;

  // ── PIN 管理 ────────────────────────────────────────────────────────────

  static Future<bool> isPinSet() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.containsKey(_kHash);
  }

  static Future<void> setPin(String pin) async {
    final prefs = await SharedPreferences.getInstance();
    final salt = DateTime.now().microsecondsSinceEpoch.toString();
    final hash = sha256.convert(utf8.encode(pin + salt)).toString();
    await prefs.setString(_kSalt, salt);
    await prefs.setString(_kHash, hash);
  }

  static Future<bool> verifyPin(String pin) async {
    final prefs = await SharedPreferences.getInstance();
    final salt = prefs.getString(_kSalt);
    final hash = prefs.getString(_kHash);
    if (salt == null || hash == null) return false;
    return hash == sha256.convert(utf8.encode(pin + salt)).toString();
  }

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
