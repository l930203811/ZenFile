import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:local_auth/local_auth.dart';
import '../../core/icon_fonts/broken_icons.dart';
import '../../services/vault_service.dart';
import '../../services/vault_biometric_store.dart';
import 'vault_explorer_screen.dart';
import 'package:zenfile/l10n/generated/app_localizations.dart';

class VaultLockScreen extends StatefulWidget {
  const VaultLockScreen({super.key});

  @override
  State<VaultLockScreen> createState() => _VaultLockScreenState();
}

class _VaultLockScreenState extends State<VaultLockScreen> {
  bool _isPasswordSet = false;
  bool _checkingPasswordStatus = true;

  // Setup Flow State
  bool _isConfirmMode = false;
  String _tempPassword = '';

  // 密码输入：系统输入法（TextField），允许字母/数字/符号，不再使用自定义键盘
  String _inputBuffer = '';
  String _message = '';
  bool _isError = false;
  final TextEditingController _textController = TextEditingController();

  // 生物识别
  final LocalAuthentication _auth = LocalAuthentication();
  bool _biometricAvailable = false;
  bool _biometricEnabled = false;

  @override
  void initState() {
    super.initState();
    _initAll();
  }

  @override
  void dispose() {
    _textController.dispose();
    super.dispose();
  }

  /// 一次性初始化：密码状态 → 生物识别状态 → 偏好方式，并在解锁流程下自动优先弹出指纹。
  Future<void> _initAll() async {
    final isSet = await VaultService.isPasswordSet();
    if (!mounted) return;
    final available = <BiometricType>[];
    bool enabled = false;
    try {
      available.addAll(await _auth.getAvailableBiometrics());
      enabled = await VaultBiometricStore.hasCredential();
    } catch (_) {
      // 设备不支持生物识别：静默降级为手动输入
    }
    final preferred = await VaultBiometricStore.readPreferredUnlock();
    if (!mounted) return;
    setState(() {
      _isPasswordSet = isSet;
      _checkingPasswordStatus = false;
      _biometricAvailable = available.isNotEmpty;
      _biometricEnabled = enabled;
      _message = isSet ? L10n.of(context).vault_enter_password : L10n.of(context).vault_set_password;
    });

    // 已设置密码 + 已启用指纹 + 偏好指纹 → 进页面即自动触发生物识别
    if (isSet && available.isNotEmpty && enabled && preferred == 'biometric') {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _onFingerprint();
      });
    }
  }

  void _onTextChanged(String value) {
    // 字母数字密码限制 64 位，去掉换行
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

  /// 提交当前输入（下一步 / 确认 / 解锁）。
  Future<void> _submit() async {
    final pw = _inputBuffer;
    if (pw.length < 4) {
      _showError(L10n.of(context).vault_min_length);
      return;
    }

    if (!_isPasswordSet) {
      // 设置密码流程
      if (!_isConfirmMode) {
        setState(() {
          _tempPassword = pw;
          _inputBuffer = '';
          _textController.clear();
          _isConfirmMode = true;
          _message = L10n.of(context).vault_confirm_password;
        });
      } else {
        if (pw == _tempPassword) {
          HapticFeedback.mediumImpact();
          await VaultService.setPassword(_inputBuffer);
          // 启用指纹解锁：把密码存入 Keystore 加密存储，之后可指纹直接解锁
          if (_biometricAvailable) {
            try {
              await VaultBiometricStore.save(pw);
            } catch (_) {
              // 存储失败不阻断设置流程
            }
          }
          // 用户本次用密码设置 → 记住偏好为密码
          try {
            await VaultBiometricStore.savePreferredUnlock('password');
          } catch (_) {}
          if (mounted) {
            setState(() {
              _isPasswordSet = true;
              _isConfirmMode = false;
              _message = L10n.of(context).vault_password_set;
            });
            _unlockWallet(pw);
          }
        } else {
          _showError(L10n.of(context).vault_pins_mismatch);
        }
      }
      return;
    }

    // 解锁流程
    final success = await VaultService.verifyPassword(pw);
    if (success) {
      HapticFeedback.mediumImpact();
      // 用户本次用密码解锁 → 记住偏好为密码
      try {
        await VaultBiometricStore.savePreferredUnlock('password');
      } catch (_) {}
      _unlockWallet(pw);
    } else {
      _showError(L10n.of(context).vault_incorrect_password);
    }
  }

  Future<void> _onFingerprint() async {
    try {
      final did = await _auth.authenticate(
        localizedReason: L10n.of(context).vault_fingerprint,
        biometricOnly: true,
      );
      if (!did) return;
      final pw = await VaultBiometricStore.read();
      if (pw != null && await VaultService.verifyPassword(pw)) {
        HapticFeedback.mediumImpact();
        // 用户本次用指纹解锁 → 记住偏好为指纹
        try {
          await VaultBiometricStore.savePreferredUnlock('biometric');
        } catch (_) {}
        _unlockWallet(pw);
      } else {
        // 存储凭据异常，回退手动输入
        _showError(L10n.of(context).vault_incorrect_password);
      }
    } catch (_) {
      _showError(L10n.of(context).vault_fingerprint_failed);
    }
  }

  void _unlockWallet(String password) {
    Navigator.pushReplacement(
      context,
      PageRouteBuilder(
        transitionDuration: const Duration(milliseconds: 400),
        pageBuilder: (context, animation, secondaryAnimation) => VaultExplorerScreen(password: password),
        transitionsBuilder: (context, animation, secondaryAnimation, child) {
          return FadeTransition(
            opacity: animation,
            child: ScaleTransition(
              scale: Tween<double>(begin: 0.95, end: 1.0).animate(CurvedAnimation(parent: animation, curve: Curves.easeOutCubic)),
              child: child,
            ),
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final l10n = L10n.of(context);

    if (_checkingPasswordStatus) {
      return const Scaffold(
        body: Center(
          child: CircularProgressIndicator(),
        ),
      );
    }

    final canSubmit = _inputBuffer.length >= 4;
    final confirmLabel = !_isPasswordSet
        ? (_isConfirmMode ? l10n.ui_confirm : l10n.vault_next)
        : l10n.vault_unlock;

    return Scaffold(
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: isDark
                ? [const Color(0xFF0F172A), const Color(0xFF1E293B), const Color(0xFF020617)]
                : [theme.colorScheme.primaryContainer.withOpacity(0.4), theme.colorScheme.surface, theme.colorScheme.surface],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
        ),
        child: SafeArea(
          child: Column(
            children: [
              Align(
                alignment: Alignment.topLeft,
                child: Padding(
                  padding: const EdgeInsets.only(left: 12.0, top: 12.0),
                  child: IconButton(
                    icon: const Icon(Broken.arrow_left, size: 26),
                    onPressed: () => Navigator.pop(context),
                  ),
                ),
              ),
              const Spacer(),

              Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    padding: const EdgeInsets.all(20),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.primary.withOpacity(0.12),
                      shape: BoxShape.circle,
                      boxShadow: [
                        BoxShadow(
                          color: theme.colorScheme.primary.withOpacity(0.08),
                          blurRadius: 24,
                          spreadRadius: 2,
                        ),
                      ],
                    ),
                    child: Icon(
                      Broken.lock,
                      size: 48,
                      color: theme.colorScheme.primary,
                    ),
                  ),
                  const SizedBox(height: 20),
                  Text(
                    l10n.msgbb590f19,
                    style: theme.textTheme.headlineMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                      letterSpacing: 0.5,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    _message,
                    style: TextStyle(
                      fontSize: 14.5,
                      fontWeight: FontWeight.w600,
                      color: _isError
                          ? theme.colorScheme.error
                          : theme.colorScheme.onSurface.withOpacity(0.6),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 28),

              // 密码输入框（系统输入法，支持字母、数字或符号）
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 48.0),
                child: TextField(
                  controller: _textController,
                  onChanged: _onTextChanged,
                  obscureText: true,
                  keyboardType: TextInputType.visiblePassword,
                  autocorrect: false,
                  enableSuggestions: false,
                  autofocus: true,
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 20, letterSpacing: 4, fontWeight: FontWeight.bold),
                  decoration: InputDecoration(
                    hintText: l10n.vault_pwd_alphanumeric,
                    hintStyle: TextStyle(
                      fontSize: 14,
                      letterSpacing: 0.3,
                      fontWeight: FontWeight.normal,
                      color: theme.colorScheme.onSurface.withOpacity(0.4),
                    ),
                    hintMaxLines: 2,
                    filled: true,
                    fillColor: isDark ? Colors.white.withOpacity(0.04) : Colors.black.withOpacity(0.02),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(16),
                      borderSide: BorderSide.none,
                    ),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                  ),
                ),
              ),

              const SizedBox(height: 28),

              // 主操作按钮
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 48.0),
                child: SizedBox(
                  width: double.infinity,
                  height: 52,
                  child: FilledButton(
                    onPressed: canSubmit ? _submit : null,
                    style: FilledButton.styleFrom(
                      backgroundColor: theme.colorScheme.primary,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                    ),
                    child: Text(confirmLabel, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
                  ),
                ),
              ),

              const SizedBox(height: 12),

              // 指纹解锁（仅解锁流程且已启用凭据时显示）
              if (_isPasswordSet && _biometricAvailable && _biometricEnabled)
                IconButton(
                  onPressed: _onFingerprint,
                  icon: Icon(Broken.finger_scan, size: 30, color: theme.colorScheme.primary),
                  tooltip: l10n.vault_fingerprint,
                ),

              const Spacer(flex: 2),
            ],
          ),
        ),
      ),
    );
  }
}
