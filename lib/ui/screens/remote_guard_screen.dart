import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../core/icon_fonts/broken_icons.dart';
import '../../services/remote_guard_service.dart';
import 'package:zenfile/l10n/generated/app_localizations.dart';

/// 远程保护页面模式
enum RemoteGuardMode {
  /// 抽屉「远程保护」入口：未设置 PIN → 设置流程；已设置 → 验证后进入管理面板
  entry,

  /// 访问守卫：仅验证 PIN，通过后 pop(true)
  gate,
}

/// 远程访问保护：PIN 设置 / 验证 / 管理页面。
///
/// 设计参考私人保险箱（VaultLockScreen）：同款渐变背景、圆形 PIN 键盘、
/// 抖动动画。两种模式：
///  - [RemoteGuardMode.entry] 抽屉入口，完整管理（设置 PIN / 验证 / 开关 / 修改 PIN）
///  - [RemoteGuardMode.gate]  访问远程内容前的 PIN 验证，通过后 pop(true)
class RemoteGuardScreen extends StatefulWidget {
  final RemoteGuardMode mode;

  const RemoteGuardScreen({super.key, this.mode = RemoteGuardMode.entry});

  @override
  State<RemoteGuardScreen> createState() => _RemoteGuardScreenState();
}

class _RemoteGuardScreenState extends State<RemoteGuardScreen>
    with SingleTickerProviderStateMixin {
  bool _checking = true;
  bool _isPinSet = false;
  bool _guardEnabled = false;

  // 页面流程：pinEntry（键盘）→ manage（管理面板）
  bool _showManage = false;

  // PIN 输入流程状态
  bool _isConfirmMode = false; // 首次设置：等待二次确认
  String _tempPin = '';
  String _inputBuffer = '';
  String _message = '';
  bool _isError = false;

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
    final enabled = await RemoteGuardService.isEnabled();
    if (!mounted) return;
    setState(() {
      _isPinSet = pinSet;
      _guardEnabled = enabled;
      _checking = false;
      // entry 模式：已设置 PIN 且已解锁 → 直接管理面板，否则键盘流程
      if (widget.mode == RemoteGuardMode.entry &&
          pinSet &&
          RemoteGuardService.isUnlocked) {
        _showManage = true;
      }
      _message = _initialMessage();
    });
  }

  String _initialMessage() {
    final l10n = L10n.of(context);
    if (!_isPinSet) return l10n.ui_remote_guard_set_pin;
    return l10n.ui_remote_guard_enter_pin;
  }

  void _onKeyPress(String key) {
    if (_inputBuffer.length >= 8) return;
    HapticFeedback.lightImpact();
    setState(() {
      _isError = false;
      _inputBuffer += key;
    });

    if (_inputBuffer.length == 4) {
      Future.delayed(const Duration(milliseconds: 200), () => _onPinComplete());
    }
  }

  Future<void> _onPinComplete() async {
    final l10n = L10n.of(context);

    // A) 首次设置（或修改 PIN）第一步：暂存并进入确认
    if (!_isPinSet && !_isConfirmMode) {
      setState(() {
        _tempPin = _inputBuffer;
        _inputBuffer = '';
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
        // 设置成功后默认开启保护
        await RemoteGuardService.setEnabled(true);
        RemoteGuardService.unlock();
        if (!mounted) return;
        setState(() {
          _isPinSet = true;
          _guardEnabled = true;
          _isConfirmMode = false;
          _inputBuffer = '';
        });
        if (widget.mode == RemoteGuardMode.gate) {
          Navigator.pop(context, true);
        } else {
          setState(() => _showManage = true);
        }
      } else {
        HapticFeedback.heavyImpact();
        _shakeController.forward(from: 0.0);
        setState(() {
          _inputBuffer = '';
          _isError = true;
          _message = l10n.ui_remote_guard_pin_mismatch;
        });
      }
      return;
    }

    // C) 已设置 PIN：验证
    final success = await RemoteGuardService.verifyPin(_inputBuffer);
    if (!mounted) return;
    if (success) {
      HapticFeedback.mediumImpact();
      RemoteGuardService.unlock();
      setState(() => _inputBuffer = '');
      if (widget.mode == RemoteGuardMode.gate) {
        Navigator.pop(context, true);
      } else {
        setState(() => _showManage = true);
      }
    } else {
      HapticFeedback.heavyImpact();
      _shakeController.forward(from: 0.0);
      setState(() {
        _inputBuffer = '';
        _isError = true;
        _message = l10n.ui_remote_guard_wrong_pin;
      });
    }
  }

  void _onDelete() {
    if (_inputBuffer.isEmpty) return;
    HapticFeedback.selectionClick();
    setState(() {
      _isError = false;
      _inputBuffer = _inputBuffer.substring(0, _inputBuffer.length - 1);
    });
  }

  void _onClear() {
    HapticFeedback.mediumImpact();
    setState(() {
      _inputBuffer = '';
      _isError = false;
    });
  }

  /// 修改 PIN：重置为「未设置」流程（旧 PIN 已在进入面板前验证过）
  void _startChangePin() {
    setState(() {
      _isPinSet = false; // 复用「设置 + 确认」流程
      _isConfirmMode = false;
      _inputBuffer = '';
      _isError = false;
      _showManage = false;
      _message = L10n.of(context).ui_remote_guard_set_pin;
    });
  }

  Future<void> _toggleEnabled(bool value) async {
    await RemoteGuardService.setEnabled(value);
    if (!mounted) return;
    setState(() => _guardEnabled = value);
  }

  @override
  void dispose() {
    _shakeController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    if (_checking) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }

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
                    onPressed: () => Navigator.pop(context, false),
                  ),
                ),
              ),
              if (_showManage && widget.mode == RemoteGuardMode.entry)
                Expanded(child: _buildManagePanel(theme))
              else
                Expanded(child: _buildPinPad(theme, isDark)),
            ],
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
          icon: Broken.lock,
          title: l10n.ui_remote_guard,
          subtitle: _guardEnabled
              ? l10n.ui_remote_guard_enabled
              : l10n.ui_remote_guard_disabled,
          trailing: Switch(
            value: _guardEnabled,
            onChanged: _toggleEnabled,
          ),
        ),
        const SizedBox(height: 12),
        _buildSettingCard(
          theme,
          icon: Broken.unlock,
          title: l10n.ui_remote_guard_change_pin,
          subtitle: l10n.ui_remote_guard_pin_hint,
          onTap: _startChangePin,
        ),
        const SizedBox(height: 12),
        _buildSettingCard(
          theme,
          icon: Broken.lock_slash,
          title: l10n.ui_remote_guard_lock_now,
          subtitle: l10n.ui_remote_guard_lock_now_desc,
          onTap: () {
            RemoteGuardService.lock();
            Navigator.pop(context);
          },
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

  // ── PIN 键盘（参考 VaultLockScreen） ───────────────────────────────────

  Widget _buildPinPad(ThemeData theme, bool isDark) {
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
          L10n.of(context).ui_remote_guard,
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
        _ShakeWidget(
          controller: _shakeController,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: List.generate(4, (index) {
              final isFilled = index < _inputBuffer.length;
              return AnimatedContainer(
                duration: const Duration(milliseconds: 180),
                margin: const EdgeInsets.symmetric(horizontal: 12),
                width: 16,
                height: 16,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: isFilled ? theme.colorScheme.primary : Colors.transparent,
                  border: Border.all(
                    color: isFilled
                        ? theme.colorScheme.primary
                        : theme.colorScheme.onSurface.withOpacity(0.24),
                    width: 2,
                  ),
                  boxShadow: isFilled
                      ? [
                          BoxShadow(
                            color: theme.colorScheme.primary.withOpacity(0.4),
                            blurRadius: 10,
                            spreadRadius: 1,
                          ),
                        ]
                      : null,
                ),
              );
            }),
          ),
        ),
        const Spacer(flex: 2),
        _buildKeypad(theme),
        const SizedBox(height: 24),
      ],
    );
  }

  Widget _buildKeypad(ThemeData theme) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 48.0),
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              _buildKeyButton('1'),
              _buildKeyButton('2'),
              _buildKeyButton('3'),
            ],
          ),
          const SizedBox(height: 16),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              _buildKeyButton('4'),
              _buildKeyButton('5'),
              _buildKeyButton('6'),
            ],
          ),
          const SizedBox(height: 16),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              _buildKeyButton('7'),
              _buildKeyButton('8'),
              _buildKeyButton('9'),
            ],
          ),
          const SizedBox(height: 16),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              _buildActionKeyButton(
                icon: Icons.clear_rounded,
                onPressed: _onClear,
                color: theme.colorScheme.onSurface.withOpacity(0.6),
              ),
              _buildKeyButton('0'),
              _buildActionKeyButton(
                icon: Icons.backspace_rounded,
                onPressed: _onDelete,
                color: theme.colorScheme.onSurface.withOpacity(0.6),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildKeyButton(String label) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () => _onKeyPress(label),
        borderRadius: BorderRadius.circular(40),
        splashColor: theme.colorScheme.primary.withOpacity(0.12),
        highlightColor: theme.colorScheme.primary.withOpacity(0.06),
        child: Container(
          width: 72,
          height: 72,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(
              color: theme.colorScheme.outline.withOpacity(0.1),
              width: 1.5,
            ),
            color: isDark
                ? Colors.white.withOpacity(0.02)
                : Colors.black.withOpacity(0.01),
          ),
          child: Center(
            child: Text(
              label,
              style: const TextStyle(
                fontSize: 28,
                fontWeight: FontWeight.bold,
                letterSpacing: 0.5,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildActionKeyButton({
    required IconData icon,
    required VoidCallback onPressed,
    required Color color,
  }) {
    final theme = Theme.of(context);
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(40),
        splashColor: theme.colorScheme.primary.withOpacity(0.12),
        highlightColor: theme.colorScheme.primary.withOpacity(0.06),
        child: Container(
          width: 72,
          height: 72,
          decoration: const BoxDecoration(shape: BoxShape.circle),
          child: Center(child: Icon(icon, size: 24, color: color)),
        ),
      ),
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
