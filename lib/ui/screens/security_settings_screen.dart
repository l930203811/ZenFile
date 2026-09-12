import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../core/icon_fonts/broken_icons.dart';
import '../../services/remote_guard_service.dart';
import '../../services/vault_biometric_store.dart';
import '../../services/biometric_auth_helper.dart';
import 'remote_guard_screen.dart';
import 'package:zenfile/l10n/generated/app_localizations.dart';

/// 安全设置页面：保险箱 / 远程守卫 / 启动应用保护 / 修改密码 / 指纹解锁。
///
/// 入口统一走 [SecuritySettingsScreen.show]：
///  - 未设置密码 → 引导设置密码（复用现有 PIN 设置引导）
///  - 已设置密码 → 验证密码后方可进入
class SecuritySettingsScreen extends StatefulWidget {
  const SecuritySettingsScreen({super.key});

  /// 统一入口：验证（或首次设置）密码后进入安全设置页面。
  static Future<void> show(BuildContext context) async {
    final isSet = await RemoteGuardService.isPinSet();
    if (!context.mounted) return;
    if (!isSet) {
      // 首次：引导设置安全设置密码
      final ok = await Navigator.push<bool>(
        context,
        MaterialPageRoute(
          builder: (_) => const RemoteGuardScreen(mode: RemoteGuardMode.setupSecurityPin),
        ),
      );
      if (ok != true) return;
    } else {
      // 已设置：验证密码后进入
      final ok = await Navigator.push<bool>(
        context,
        MaterialPageRoute(
          builder: (_) => const RemoteGuardScreen(mode: RemoteGuardMode.securityGate),
        ),
      );
      if (ok != true) return;
    }
    if (context.mounted) {
      await Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => const SecuritySettingsScreen()),
      );
    }
  }

  @override
  State<SecuritySettingsScreen> createState() => _SecuritySettingsScreenState();
}

class _SecuritySettingsScreenState extends State<SecuritySettingsScreen> {
  static const _kVaultEnabled = 'vault_enabled';

  // 保险箱开关
  bool _vaultEnabled = true;

  // 远程守卫 / 启动应用保护
  bool _remoteGuardEnabled = false;
  bool _appLockEnabled = false;

  // 生物识别
  bool _biometricAvailable = false;
  bool _biometricEnabled = false;

  @override
  void initState() {
    super.initState();
    _loadAll();
  }

  Future<void> _loadAll() async {
    final prefs = await SharedPreferences.getInstance();
    final vault = prefs.getBool(_kVaultEnabled) ?? true;
    final rg = await RemoteGuardService.isEnabled();
    final al = await RemoteGuardService.isAppLockEnabled();
    bool available = false;
    bool enabled = false;
    try {
      final bios = await BiometricAuthHelper.auth.getAvailableBiometrics();
      available = bios.isNotEmpty;
      enabled = await VaultBiometricStore.hasCredential();
    } catch (_) {}
    if (!mounted) return;
    setState(() {
      _vaultEnabled = vault;
      _remoteGuardEnabled = rg;
      _appLockEnabled = al;
      _biometricAvailable = available;
      _biometricEnabled = enabled;
    });
  }

  /// 开启任一开关前若尚未设置密码，则跳转设置密码页
  Future<void> _ensurePinThenEnable({
    required Future<void> Function() enable,
  }) async {
    if (!await RemoteGuardService.isPinSet()) {
      final ok = await Navigator.push<bool>(
        context,
        MaterialPageRoute(
          builder: (_) => const RemoteGuardScreen(mode: RemoteGuardMode.setupPinOnly),
        ),
      );
      if (ok != true) {
        await _loadAll();
        return;
      }
    }
    await enable();
    await _loadAll();
  }

  Future<void> _onVaultChanged(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kVaultEnabled, value);
    if (mounted) setState(() => _vaultEnabled = value);
  }

  Future<void> _onRemoteGuardChanged(bool value) async {
    if (value) {
      await _ensurePinThenEnable(enable: () => RemoteGuardService.setEnabled(true));
    } else {
      await RemoteGuardService.setEnabled(false);
      await _loadAll();
    }
  }

  Future<void> _onAppLockChanged(bool value) async {
    if (value) {
      await _ensurePinThenEnable(enable: () => RemoteGuardService.setAppLockEnabled(true));
    } else {
      await RemoteGuardService.setAppLockEnabled(false);
      await _loadAll();
    }
  }

  Future<void> _onBiometricChanged(bool value) async {
    if (value) {
      // 指纹凭据必须是保险箱解锁密码本体，故需用户重新输入确认
      final pw = await _promptUnlockPassword();
      if (pw == null) {
        await _loadAll();
        return;
      }
      try {
        final did = await BiometricAuthHelper.authenticate(
          context,
          scenario: BiometricScenario.vault,
        );
        if (did) {
          await VaultBiometricStore.save(pw);
        }
      } catch (_) {
        // 用户取消或验证失败：保持关闭
      }
    } else {
      await VaultBiometricStore.clear();
    }
    await _loadAll();
  }

  /// 弹出输入框验证保险箱解锁密码（仅用于指纹凭据登记等门禁场景）
  Future<String?> _promptUnlockPassword() async {
    final controller = TextEditingController();
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(L10n.of(context).vault_verify_password_title),
        content: TextField(
          controller: controller,
          obscureText: true,
          autofocus: true,
          decoration: InputDecoration(
            hintText: L10n.of(context).vault_verify_password_hint,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(L10n.of(context).ui_cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text),
            child: Text(L10n.of(context).ui_confirm),
          ),
        ],
      ),
    );
    controller.dispose();
    if (result == null || result.isEmpty) return null;
    final ok = await RemoteGuardService.verifyPin(result);
    return ok ? result : null;
  }

  Widget _buildNavTile({
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
  }) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: theme.colorScheme.outline.withOpacity(0.18),
          width: 1,
        ),
        color: isDark ? Colors.white.withOpacity(0.02) : Colors.black.withOpacity(0.01),
      ),
      child: ListTile(
        leading: Icon(icon, size: 24, color: theme.colorScheme.primary),
        title: Text(title, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
        subtitle: Text(
          subtitle,
          style: TextStyle(fontSize: 12.5, color: theme.colorScheme.onSurface.withOpacity(0.55)),
        ),
        trailing: Icon(
          Icons.chevron_right_rounded,
          color: theme.colorScheme.onSurface.withOpacity(0.4),
        ),
        onTap: onTap,
        contentPadding: const EdgeInsets.symmetric(horizontal: 14),
      ),
    );
  }

  Widget _buildSwitchTile({
    required IconData icon,
    required String title,
    required String subtitle,
    required bool value,
    required Future<void> Function(bool) onChanged,
  }) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: theme.colorScheme.outline.withOpacity(0.18),
          width: 1,
        ),
        color: isDark ? Colors.white.withOpacity(0.02) : Colors.black.withOpacity(0.01),
      ),
      child: ListTile(
        leading: Icon(icon, size: 24, color: theme.colorScheme.primary),
        title: Text(title, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
        subtitle: Text(
          subtitle,
          style: TextStyle(fontSize: 12.5, color: theme.colorScheme.onSurface.withOpacity(0.55)),
        ),
        trailing: Switch(
          value: value,
          onChanged: (v) => onChanged(v),
        ),
        contentPadding: const EdgeInsets.symmetric(horizontal: 14),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = L10n.of(context);

    return Scaffold(
      appBar: AppBar(title: Text(l10n.ui_security_settings)),
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: 12),
        children: [
          // 保险箱开关（默认开启）
          _buildSwitchTile(
            icon: Broken.lock,
            title: l10n.msgbb590f19,
            subtitle: l10n.security_vault_switch_desc,
            value: _vaultEnabled,
            onChanged: _onVaultChanged,
          ),
          // 远程守卫
          _buildSwitchTile(
            icon: Broken.shield_tick,
            title: l10n.ui_remote_guard,
            subtitle: l10n.ui_remote_guard_switch_desc,
            value: _remoteGuardEnabled,
            onChanged: _onRemoteGuardChanged,
          ),
          // 启动应用保护
          _buildSwitchTile(
            icon: Broken.lock,
            title: l10n.ui_app_lock,
            subtitle: l10n.ui_app_lock_desc,
            value: _appLockEnabled,
            onChanged: _onAppLockChanged,
          ),
          // 启用指纹解锁
          if (_biometricAvailable) ...[
            _buildSwitchTile(
              icon: Broken.finger_scan,
              title: l10n.vault_enable_fingerprint,
              subtitle: l10n.vault_biometric_desc,
              value: _biometricEnabled,
              onChanged: _onBiometricChanged,
            ),
          ],
          // 修改密码
          _buildNavTile(
            icon: Broken.unlock,
            title: l10n.ui_remote_guard_change_pin,
            subtitle: l10n.ui_change_vault_pin_desc,
            onTap: () async {
              if (!await RemoteGuardService.isPinSet()) return;
              await Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => const RemoteGuardScreen(mode: RemoteGuardMode.changePin),
                ),
              );
              await _loadAll();
            },
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}
