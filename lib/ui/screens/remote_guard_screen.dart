import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:local_auth/local_auth.dart';
import '../../core/icon_fonts/broken_icons.dart';
import '../../services/remote_guard_service.dart';
import '../../services/vault_biometric_store.dart';
import 'package:zenfile/l10n/generated/app_localizations.dart';

/// 远程保护页面模式
enum RemoteGuardMode {
  /// 抽屉「远程保护」入口：未设置 PIN → 设置流程；已设置 → 验证后进入管理面板
  entry,

  /// 访问守卫：仅验证 PIN，通过后 pop(true)
  gate,

  /// 仅设置 PIN（不改动远程守卫/启动保护开关），设置成功后 pop(true)
  setupPinOnly,

  /// 启动应用保护闸门：验证 PIN 后回调 [onUnlocked]，不 pop
  appLock,

  /// 修改 PIN：验证当前 PIN 后直接进入「输入新 PIN → 确认 → 重加密」流程
  changePin,
}

/// 远程访问保护：PIN 设置 / 验证 / 修改 PIN 页面。
///
/// 设计参考私人保险箱（VaultLockScreen）：同款渐变背景、密码输入框（字母/数字/符号）、
/// 抖动动画、指纹解锁。主要入口：
///  - [RemoteGuardMode.entry]      管理面板（现仅保留修改 PIN 入口）
///  - [RemoteGuardMode.gate]       访问远程内容前的 PIN 验证，通过后 pop(true)
///  - [RemoteGuardMode.setupPinOnly] 仅设置 PIN，成功后 pop(true)
///  - [RemoteGuardMode.appLock]    启动应用保护闸门，验证后回调 onUnlocked
///  - [RemoteGuardMode.changePin]  保险箱首页「修改 PIN」直接入口，验证当前 PIN 后直接进入改密流程
///
/// 注：远程守卫 PIN 与保险箱密码共用同一套（RemoteGuardService 委托 VaultService），
/// 故解锁输入同样为密码（字母/数字/符号）；指纹解锁复用 VaultBiometricStore 中保存的同一密码。
class RemoteGuardScreen extends StatefulWidget {
  final RemoteGuardMode mode;
  /// 仅 [RemoteGuardMode.appLock] 使用：PIN 验证成功后的回调（用于通知外层切换到主界面）
  final VoidCallback? onUnlocked;

  const RemoteGuardScreen({
    super.key,
    this.mode = RemoteGuardMode.entry,
    this.onUnlocked,
  });

  @override
  State<RemoteGuardScreen> createState() => _RemoteGuardScreenState();
}

class _RemoteGuardScreenState extends State<RemoteGuardScreen>
    with SingleTickerProviderStateMixin {
  bool _checking = true;
  bool _isPinSet = false;

  // 页面流程：pinEntry（键盘）→ manage（管理面板）
  bool _showManage = false;

  // PIN 输入流程状态
  bool _isConfirmMode = false; // 首次设置：等待二次确认
  String _tempPin = '';
  String _inputBuffer = '';
  String _message = '';
  bool _isError = false;
  final TextEditingController _textController = TextEditingController();

  // 修改 PIN 流程状态
  bool _isChangingPin = false; // 是否处于「修改 PIN」流程
  bool _oldPinVerified = false; // 当前 PIN 是否已验证通过
  String _oldPin = ''; // 已验证的当前 PIN（用于重加密）
  bool _changingProgress = false; // 重加密进行中（显示进度，禁用返回）

  // 生物识别
  final LocalAuthentication _auth = LocalAuthentication();
  bool _biometricAvailable = false;
  bool _biometricEnabled = false;

  late final AnimationController _shakeController;

  @override
  void initState() {
    super.initState();
    _shakeController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 350),
    );
    _initState();
  }

  Future<void> _initState() async {
    final pinSet = await RemoteGuardService.isPinSet();
    if (!mounted) return;
    // 生物识别状态
    bool available = false;
    bool enabled = false;
    try {
      final bios = await _auth.getAvailableBiometrics();
      available = bios.isNotEmpty;
      enabled = await VaultBiometricStore.hasCredential();
    } catch (_) {
      // 设备不支持生物识别：静默降级为手动输入
    }
    final preferred = await VaultBiometricStore.readGuardPreferredUnlock();
    if (!mounted) return;
    setState(() {
      _isPinSet = pinSet;
      _checking = false;
      _biometricAvailable = available;
      _biometricEnabled = enabled;
      // entry 模式：已设置 PIN 且已解锁 → 直接管理面板，否则键盘流程
      if (widget.mode == RemoteGuardMode.entry &&
          pinSet &&
          RemoteGuardService.isUnlocked) {
        _showManage = true;
      }
      _message = _initialMessage();
    });
    // 启动保护闸门：若 PIN 未设置（理论上不会，因启用前置条件已校验），直接放行
    if (widget.mode == RemoteGuardMode.appLock && !pinSet) {
      widget.onUnlocked?.call();
      return;
    }

    // 修改 PIN 模式：已设置 PIN 直接进入改密流程；未设置则直接退出
    if (widget.mode == RemoteGuardMode.changePin) {
      if (pinSet) {
        _startChangePin();
      } else {
        Navigator.pop(context, false);
      }
    }

    // 访问守卫 / 启动闸门：若偏好指纹且可用，进页面即自动弹出生物识别
    if ((widget.mode == RemoteGuardMode.gate || widget.mode == RemoteGuardMode.appLock) &&
        pinSet &&
        available &&
        enabled &&
        preferred == 'biometric') {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _onFingerprint();
      });
    }
  }

  String _initialMessage() {
    final l10n = L10n.of(context);
    if (!_isPinSet) return l10n.ui_remote_guard_set_pin;
    return l10n.ui_remote_guard_enter_pin;
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

  void _onClear() {
    HapticFeedback.mediumImpact();
    setState(() {
      _isError = false;
      _inputBuffer = '';
      _textController.clear();
    });
  }

  void _showError(String msg) {
    HapticFeedback.heavyImpact();
    _shakeController.forward(from: 0.0);
    if (mounted) {
      setState(() {
        _inputBuffer = '';
        _textController.clear();
        _isError = true;
        _message = msg;
      });
    }
  }

  /// 提交当前输入（设置 / 确认 / 验证 / 修改 PIN），由解锁按钮或键盘「完成」触发。
  Future<void> _submit() async {
    final l10n = L10n.of(context);

    // ── 修改 PIN 流程（验证旧 PIN → 设新 PIN → 重加密） ──
    if (_isChangingPin) {
      await _handleChangePinInput(l10n);
      return;
    }

    // A) 首次设置（或修改 PIN）第一步：暂存并进入确认
    if (!_isPinSet && !_isConfirmMode) {
      setState(() {
        _tempPin = _inputBuffer;
        _inputBuffer = '';
        _textController.clear();
        _isConfirmMode = true;
        _message = l10n.ui_remote_guard_confirm_pin;
      });
      return;
    }

    // B) 首次设置（或修改 PIN）确认：两次一致 → 保存
    if (!_isPinSet && _isConfirmMode) {
      if (_inputBuffer == _tempPin) {
        HapticFeedback.mediumImpact();
        await RemoteGuardService.setPin(_inputBuffer);
        // 启用指纹解锁：把密码存入 Keystore，并记录偏好为密码
        try {
          await VaultBiometricStore.save(_inputBuffer);
          await VaultBiometricStore.saveGuardPreferredUnlock('password');
        } catch (_) {}
        if (!mounted) return;
        setState(() {
          _isPinSet = true;
          _isConfirmMode = false;
          _inputBuffer = '';
          _textController.clear();
        });
        if (widget.mode == RemoteGuardMode.setupPinOnly) {
          // 仅设置 PIN，由调用方决定启用哪个开关
          Navigator.pop(context, true);
        } else if (widget.mode == RemoteGuardMode.gate) {
          Navigator.pop(context, true);
        } else if (widget.mode == RemoteGuardMode.appLock) {
          RemoteGuardService.unlockApp();
          widget.onUnlocked?.call();
        } else {
          // entry 模式：设置成功后默认开启远程守卫保护
          await RemoteGuardService.setEnabled(true);
          if (!mounted) return;
          setState(() => _showManage = true);
        }
      } else {
        _showError(l10n.ui_remote_guard_pin_mismatch);
      }
      return;
    }

    // C) 已设置 PIN：验证
    final success = await RemoteGuardService.verifyPin(_inputBuffer);
    if (!mounted) return;
    if (success) {
      // 密码解锁成功：刷新 Keystore 密码 + 记录偏好为密码
      try {
        await VaultBiometricStore.save(_inputBuffer);
        await VaultBiometricStore.saveGuardPreferredUnlock('password');
      } catch (_) {}
      if (widget.mode == RemoteGuardMode.appLock) {
        HapticFeedback.mediumImpact();
        RemoteGuardService.unlockApp();
        widget.onUnlocked?.call();
        return;
      }
      HapticFeedback.mediumImpact();
      RemoteGuardService.unlock();
      setState(() {
        _inputBuffer = '';
        _textController.clear();
      });
      if (widget.mode == RemoteGuardMode.gate) {
        Navigator.pop(context, true);
      } else {
        setState(() => _showManage = true);
      }
    } else {
      _showError(l10n.ui_remote_guard_wrong_pin);
    }
  }

  /// 指纹解锁：验证通过后用 Keystore 中保存的密码自动解锁，并记录偏好为指纹。
  Future<void> _onFingerprint() async {
    final l10n = L10n.of(context);
    try {
      final did = await _auth.authenticate(
        localizedReason: l10n.ui_remote_guard,
        biometricOnly: true,
      );
      if (!did) return;
      final pw = await VaultBiometricStore.read();
      if (pw == null || !await RemoteGuardService.verifyPin(pw)) {
        _showError(l10n.ui_remote_guard_wrong_pin);
        return;
      }
      try {
        await VaultBiometricStore.saveGuardPreferredUnlock('biometric');
      } catch (_) {}
      if (widget.mode == RemoteGuardMode.appLock) {
        RemoteGuardService.unlockApp();
        widget.onUnlocked?.call();
        return;
      }
      RemoteGuardService.unlock();
      setState(() {
        _inputBuffer = '';
        _textController.clear();
      });
      if (widget.mode == RemoteGuardMode.gate) {
        Navigator.pop(context, true);
      } else if (widget.mode == RemoteGuardMode.changePin) {
        // 生物识别等价于当前 PIN 验证通过，直接进入输入新 PIN
        setState(() {
          _oldPin = pw;
          _oldPinVerified = true;
          _isConfirmMode = false;
          _inputBuffer = '';
          _textController.clear();
          _message = l10n.ui_remote_guard_set_pin;
        });
      } else {
        setState(() => _showManage = true);
      }
    } catch (_) {
      _showError(l10n.ui_remote_guard_wrong_pin);
    }
  }

  /// 修改 PIN 流程的输入处理：
  ///  步骤1 验证当前 PIN → 步骤2 输入新 PIN → 步骤3 二次确认后执行重加密
  Future<void> _handleChangePinInput(L10n l10n) async {
    // 步骤1：验证当前 PIN
    if (!_oldPinVerified) {
      final ok = await RemoteGuardService.verifyPin(_inputBuffer);
      if (!mounted) return;
      if (ok) {
        HapticFeedback.mediumImpact();
        setState(() {
          _oldPin = _inputBuffer;
          _oldPinVerified = true;
          _isConfirmMode = false;
          _inputBuffer = '';
          _textController.clear();
          _message = l10n.ui_remote_guard_set_pin; // 复用「设置 PIN 码」作为新 PIN 提示
        });
      } else {
        _showError(l10n.ui_remote_guard_wrong_pin);
      }
      return;
    }

    // 步骤2：输入新 PIN（首次）
    if (!_isConfirmMode) {
      setState(() {
        _tempPin = _inputBuffer;
        _inputBuffer = '';
        _textController.clear();
        _isConfirmMode = true;
        _message = l10n.ui_remote_guard_confirm_pin;
      });
      return;
    }

    // 步骤3：二次确认
    if (_inputBuffer == _tempPin) {
      await _doChangePin(_oldPin, _inputBuffer, l10n);
    } else {
      HapticFeedback.heavyImpact();
      _shakeController.forward(from: 0.0);
      setState(() {
        _inputBuffer = '';
        _textController.clear();
        _isConfirmMode = false;
        _tempPin = '';
        _isError = true;
        _message = l10n.ui_remote_guard_pin_mismatch;
      });
    }
  }

  /// 执行改密：用旧 PIN 还原、新 PIN 重新加锁全部已隐藏文件（委托 VaultService.changePassword）
  Future<void> _doChangePin(String oldPin, String newPin, L10n l10n) async {
    setState(() {
      _changingProgress = true;
      _inputBuffer = '';
      _textController.clear();
      _isError = false;
      _message = l10n.ui_remote_guard_reencrypting;
    });
    final ok = await RemoteGuardService.changePin(oldPin, newPin);
    if (!mounted) return;
    if (ok) {
      // 密码已变更：同步刷新 Keystore 中保存的密码，并记录偏好为密码
      try {
        await VaultBiometricStore.save(newPin);
        await VaultBiometricStore.saveGuardPreferredUnlock('password');
      } catch (_) {}
      setState(() {
        _changingProgress = false;
        _message = l10n.ui_remote_guard_pin_changed;
      });
      // 稍作停顿让用户看到成功提示，再把新 PIN 返回给外层（VaultExplorerScreen）
      // 由其用新密码重建保险箱页面，避免 widget.password 过期导致预览/还原失败
      await Future.delayed(const Duration(milliseconds: 1200));
      if (!mounted) return;
      Navigator.pop(context, newPin);
    } else {
      setState(() {
        _changingProgress = false;
        _isError = true;
        _message = l10n.ui_remote_guard_change_pin_failed;
      });
    }
  }

  /// 修改 PIN：进入「验证当前 PIN → 输入新 PIN 两次 → 重加密」流程
  void _startChangePin() {
    setState(() {
      _isChangingPin = true;
      _oldPinVerified = false;
      _oldPin = '';
      _isConfirmMode = false;
      _tempPin = '';
      _inputBuffer = '';
      _textController.clear();
      _isError = false;
      _showManage = false;
      _message = L10n.of(context).ui_remote_guard_enter_current_pin;
    });
  }

  @override
  void dispose() {
    _shakeController.dispose();
    _textController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    if (_checking) {
      return PopScope(
        canPop: widget.mode != RemoteGuardMode.appLock,
        child: const Scaffold(
          body: Center(child: CircularProgressIndicator()),
        ),
      );
    }

    return PopScope(
      canPop: widget.mode != RemoteGuardMode.appLock,
      child: Scaffold(
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
                  child: (widget.mode == RemoteGuardMode.appLock || _changingProgress)
                      ? const SizedBox.shrink()
                      : Padding(
                          padding: const EdgeInsets.only(left: 12.0, top: 12.0),
                          child: IconButton(
                            icon: const Icon(Broken.arrow_left, size: 26),
                            onPressed: _onBackPressed,
                          ),
                        ),
                ),
                if (_changingProgress)
                  Expanded(child: _buildChangingProgress(theme))
                else if (_showManage && widget.mode == RemoteGuardMode.entry)
                  Expanded(child: _buildManagePanel(theme))
                else
                  Expanded(
                    child: _buildPinPad(
                      theme,
                      isDark,
                      titleOverride: widget.mode == RemoteGuardMode.appLock
                          ? L10n.of(context).ui_app_lock
                          : (_isChangingPin
                              ? L10n.of(context).ui_remote_guard_change_pin
                              : null),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ── 管理面板（entry 模式验证通过后） ────────────────────────────────────

  Widget _buildManagePanel(ThemeData theme) {
    final l10n = L10n.of(context);
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
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
          child: Icon(Broken.shield_tick, size: 48, color: theme.colorScheme.primary),
        ),
        const SizedBox(height: 16),
        Center(
          child: Text(
            l10n.ui_remote_guard,
            style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.bold),
          ),
        ),
        const SizedBox(height: 6),
        Center(
          child: Text(
            l10n.ui_remote_guard_desc,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 13.5,
              color: theme.colorScheme.onSurface.withOpacity(0.6),
            ),
          ),
        ),
        const SizedBox(height: 24),
        _buildSettingCard(
          theme,
          icon: Broken.unlock,
          title: l10n.ui_remote_guard_change_pin,
          subtitle: l10n.ui_remote_guard_pin_hint,
          onTap: _startChangePin,
        ),
      ],
    );
  }

  Widget _buildSettingCard(
    ThemeData theme, {
    required IconData icon,
    required String title,
    required String subtitle,
    Widget? trailing,
    VoidCallback? onTap,
  }) {
    return Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withOpacity(0.45),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: theme.colorScheme.outline.withOpacity(0.12)),
      ),
      child: ListTile(
        onTap: onTap,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        leading: Icon(icon, size: 24, color: theme.colorScheme.primary),
        title: Text(title, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
        subtitle: Text(
          subtitle,
          style: TextStyle(fontSize: 12.5, color: theme.colorScheme.onSurface.withOpacity(0.55)),
        ),
        trailing: trailing,
      ),
    );
  }

  // ── 字母+数字密码输入 + 指纹（参考 VaultLockScreen） ──────────────────────

  Widget _buildPinPad(ThemeData theme, bool isDark, {String? titleOverride}) {
    final l10n = L10n.of(context);
    final canSubmit = _inputBuffer.length >= 4;
    final confirmLabel = _isConfirmMode
        ? l10n.ui_confirm
        : (_isPinSet ? l10n.vault_unlock : l10n.vault_next);

    // 指纹按钮：已设置 PIN 且已启用凭据时显示（改密流程输入新密码阶段隐藏）
    final showFingerprint = _biometricAvailable &&
        _biometricEnabled &&
        _isPinSet &&
        !(_isChangingPin && _oldPinVerified);

    return Column(
      children: [
        const Spacer(),
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
          child: Icon(Broken.lock, size: 48, color: theme.colorScheme.primary),
        ),
        const SizedBox(height: 20),
        Text(
          titleOverride ?? L10n.of(context).ui_remote_guard,
          style: theme.textTheme.headlineMedium?.copyWith(
            fontWeight: FontWeight.bold,
            letterSpacing: 0.5,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          _message,
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 14.5,
            fontWeight: FontWeight.w600,
            color: _isError
                ? theme.colorScheme.error
                : theme.colorScheme.onSurface.withOpacity(0.6),
          ),
        ),
        const SizedBox(height: 36),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 48.0),
          child: _ShakeWidget(
            controller: _shakeController,
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
                hintText: l10n.ui_remote_guard_pin_hint,
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
              onSubmitted: (_) {
                if (canSubmit) _submit();
              },
            ),
          ),
        ),
        const SizedBox(height: 20),
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
        if (showFingerprint)
          IconButton(
            onPressed: _onFingerprint,
            icon: Icon(Broken.finger_scan, size: 30, color: theme.colorScheme.primary),
            tooltip: l10n.ui_remote_guard,
          ),
        const Spacer(flex: 2),
      ],
    );
  }

  /// 返回按钮：修改 PIN 流程中（非重加密）取消；
  /// changePin 模式下直接退出页面，entry 模式下回到管理面板，其余情况直接关闭页面
  void _onBackPressed() {
    if (_isChangingPin && !_changingProgress) {
      if (widget.mode == RemoteGuardMode.changePin) {
        Navigator.pop(context, false);
        return;
      }
      setState(() {
        _isChangingPin = false;
        _oldPinVerified = false;
        _oldPin = '';
        _isConfirmMode = false;
        _tempPin = '';
        _inputBuffer = '';
        _textController.clear();
        _isError = false;
        _showManage = true;
        _message = L10n.of(context).ui_remote_guard_enter_pin;
      });
      return;
    }
    Navigator.pop(context, false);
  }

  /// 重加密进度提示
  Widget _buildChangingProgress(ThemeData theme) {
    return Column(
      children: [
        const Spacer(),
        SizedBox(
          width: 56,
          height: 56,
          child: CircularProgressIndicator(
            strokeWidth: 4,
            color: theme.colorScheme.primary,
          ),
        ),
        const SizedBox(height: 24),
        Text(
          _message,
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 14.5,
            fontWeight: FontWeight.w600,
            color: theme.colorScheme.onSurface.withOpacity(0.7),
          ),
        ),
        const Spacer(flex: 2),
      ],
    );
  }
}

// 抖动动画组件（私有：避免与 vault_lock_screen.dart 的公开 ShakeWidget 命名冲突）
class _ShakeWidget extends StatefulWidget {
  final Widget child;
  final AnimationController controller;

  const _ShakeWidget({
    required this.child,
    required this.controller,
  });

  @override
  State<_ShakeWidget> createState() => _ShakeWidgetState();
}

class _ShakeWidgetState extends State<_ShakeWidget> {
  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.controller,
      builder: (context, child) {
        final sineValue = sin(3 * 2 * pi * widget.controller.value);
        return Transform.translate(
          offset: Offset(sineValue * 16.0, 0),
          child: child,
        );
      },
      child: widget.child,
    );
  }
}
