import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../core/icon_fonts/broken_icons.dart';
import '../../services/vault_service.dart';
import '../../services/vault_biometric_store.dart';
import '../../services/biometric_auth_helper.dart';
import '../../services/preferences_service.dart';
import 'package:zenfile/l10n/generated/app_localizations.dart';

/// 保险箱「会话解锁」验证底部弹窗。
///
/// 用于执行加密相关操作前的二次确认：若用户本次启动应用后**尚未**在保险箱
/// 解锁过，则任何触达加密文件的操作（打开 / 重命名 / 复制 / 移动 / 删除 / 粘贴）
/// 都会弹出此底部面板验证保险箱密码（或指纹）；验证成功后写入进程内存态
/// [VaultService.markSessionUnlocked]，本会话内后续操作不再重复弹窗。
///
/// 与 [VaultLockScreen] 的区别：本弹窗**不进入**保险箱页面，只是一次门禁校验，
/// 校验通过即回调 `true`，由调用方继续执行原操作。
class VaultSessionUnlockBottomSheet extends StatefulWidget {
  const VaultSessionUnlockBottomSheet({super.key});

  @override
  State<VaultSessionUnlockBottomSheet> createState() =>
      _VaultSessionUnlockBottomSheetState();
}

class _VaultSessionUnlockBottomSheetState
    extends State<VaultSessionUnlockBottomSheet> {
  String _inputBuffer = '';
  String _message = '';
  bool _isError = false;
  bool _checking = false;
  final TextEditingController _textController = TextEditingController();

  bool _biometricAvailable = false;
  bool _biometricEnabled = false;

  @override
  void initState() {
    super.initState();
    _initBiometric();
  }

  @override
  void dispose() {
    _textController.dispose();
    super.dispose();
  }

  Future<void> _initBiometric() async {
    try {
      final available = await BiometricAuthHelper.auth.getAvailableBiometrics();
      final enabled = (await VaultBiometricStore.hasCredential()) &&
          PreferencesService.getBiometricUnlockEnabled();
      if (!mounted) return;
      setState(() {
        _biometricAvailable = available.isNotEmpty;
        _biometricEnabled = enabled;
      });
    } catch (_) {
      // 设备不支持生物识别：静默降级为手动输入
    }
  }

  void _onTextChanged(String value) {
    final cleaned = value.replaceAll('\n', '');
    if (cleaned.length > 64) {
      _textController.text = cleaned.substring(0, 64);
      _textController.selection = TextSelection.fromPosition(
        TextPosition(offset: _textController.text.length),
      );
      return;
    }
    setState(() {
      _isError = false;
      _inputBuffer = cleaned;
    });
  }

  void _showError(String msg) {
    HapticFeedback.heavyImpact();
    if (mounted) {
      setState(() {
        _inputBuffer = '';
        _textController.clear();
        _isError = true;
        _message = msg;
      });
    }
  }

  Future<void> _submit() async {
    final pw = _inputBuffer;
    if (pw.length < 4) {
      _showError(L10n.of(context).vault_min_length);
      return;
    }
    setState(() => _checking = true);
    final success = await VaultService.verifyPassword(pw);
    if (!mounted) return;
    setState(() => _checking = false);
    if (success) {
      HapticFeedback.mediumImpact();
      VaultService.markSessionUnlocked();
      Navigator.of(context).pop(true);
    } else {
      _showError(L10n.of(context).vault_incorrect_password);
    }
  }

  Future<void> _onFingerprint() async {
    try {
      final did = await BiometricAuthHelper.authenticate(
        context,
        scenario: BiometricScenario.vault,
      );
      if (!did) return;
      final pw = await VaultBiometricStore.read();
      if (pw != null && await VaultService.verifyPassword(pw)) {
        HapticFeedback.mediumImpact();
        VaultService.markSessionUnlocked();
        if (mounted) Navigator.of(context).pop(true);
      } else {
        _showError(L10n.of(context).vault_incorrect_password);
      }
    } catch (_) {
      _showError(L10n.of(context).vault_fingerprint_failed);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = L10n.of(context);

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        // 拦截系统返回键：用户必须显式「取消」或验证通过，避免误触返回绕过门禁。
        if (!didPop) Navigator.of(context).pop(false);
      },
      child: Container(
        decoration: BoxDecoration(
          color: theme.colorScheme.surface,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.12),
              blurRadius: 24,
              offset: const Offset(0, -4),
            ),
          ],
        ),
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(
                  child: Container(
                    width: 40,
                    height: 4,
                    decoration: BoxDecoration(
                      color: theme.colorScheme.onSurface.withOpacity(0.15),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                const SizedBox(height: 24),
                Row(
                  children: [
                    Icon(
                      Broken.lock,
                      size: 26,
                      color: theme.colorScheme.primary,
                    ),
                    const SizedBox(width: 12),
                    Text(
                      l10n.msgbb590f19,
                      style: theme.textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  _isError ? _message : l10n.vault_enter_password,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: _isError
                        ? theme.colorScheme.error
                        : theme.colorScheme.onSurface.withOpacity(0.65),
                  ),
                ),
                const SizedBox(height: 20),
                TextField(
                  controller: _textController,
                  onChanged: _onTextChanged,
                  obscureText: true,
                  keyboardType: TextInputType.visiblePassword,
                  autocorrect: false,
                  enableSuggestions: false,
                  autofocus: !(_biometricAvailable && _biometricEnabled),
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 18,
                    letterSpacing: 4,
                    fontWeight: FontWeight.bold,
                  ),
                  decoration: InputDecoration(
                    hintText: l10n.vault_pwd_alphanumeric,
                    hintStyle: TextStyle(
                      fontSize: 13,
                      letterSpacing: 0.3,
                      fontWeight: FontWeight.normal,
                      color: theme.colorScheme.onSurface.withOpacity(0.4),
                    ),
                    filled: true,
                    fillColor: theme.brightness == Brightness.dark
                        ? Colors.white.withOpacity(0.04)
                        : Colors.black.withOpacity(0.02),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(16),
                      borderSide: BorderSide.none,
                    ),
                    contentPadding:
                        const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
                  ),
                  onSubmitted: (_) => _submit(),
                ),
                const SizedBox(height: 24),
                Row(
                  children: [
                    TextButton(
                      onPressed: () => Navigator.of(context).pop(false),
                      style: TextButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                      ),
                      child: Text(l10n.ui_cancel),
                    ),
                    if (_biometricAvailable && _biometricEnabled) ...[
                      const SizedBox(width: 8),
                      IconButton(
                        onPressed: _onFingerprint,
                        icon: Icon(
                          Broken.finger_scan,
                          size: 26,
                          color: theme.colorScheme.primary,
                        ),
                        tooltip: l10n.vault_fingerprint,
                      ),
                    ],
                    const Spacer(),
                    FilledButton(
                      onPressed: _checking ? null : _submit,
                      style: FilledButton.styleFrom(
                        backgroundColor: theme.colorScheme.primary,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 24,
                          vertical: 14,
                        ),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                      ),
                      child: _checking
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : Text(l10n.vault_unlock),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 保险箱会话解锁闸门。
///
/// - 若本次启动已解锁过（[VaultService.isSessionUnlocked]），直接返回 `true`；
/// - 否则弹出 [VaultSessionUnlockBottomSheet] 验证保险箱密码 / 指纹，
///   成功返回 `true`（并标记会话已解锁），取消或验证失败返回 `false`。
///
/// 调用方应在返回 `false` 时中止当前加密相关操作。
///
/// ⚠️ 若用户尚未设置保险箱密码（理论上保险箱页会引导先设置），无门禁可验证，
/// 直接放行（返回 `true`），避免把用户锁死在无法继续的状态。
Future<bool> requireVaultSessionUnlock(BuildContext context) async {
  if (VaultService.isSessionUnlocked) return true;
  final set = await VaultService.isPasswordSet();
  if (!set) return true;
  final result = await showModalBottomSheet<bool>(
    context: context,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    isDismissible: false,
    enableDrag: false,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
    ),
    builder: (_) => const VaultSessionUnlockBottomSheet(),
  );
  return result == true;
}
