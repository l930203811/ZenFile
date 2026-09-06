import 'package:flutter/material.dart';
// ignore: depend_on_referenced_packages
import 'package:local_auth/local_auth.dart';
// ignore: depend_on_referenced_packages
import 'package:local_auth_android/local_auth_android.dart';

import '../l10n/generated/app_localizations.dart';

/// 生物识别（指纹 / 面容）验证场景。
///
/// 决定系统弹窗展示的标题与说明文案。三个场景共用同一份凭据
/// （[VaultBiometricStore]），但用户在弹窗中看到的业务语义不同，
/// 必须分别给出对应文案，避免「启动应用保护」弹窗上出现「远程守卫」字样。
enum BiometricScenario {
  /// 保险箱解锁
  vault,

  /// 远程守卫：访问远程服务器前的验证
  remoteGuard,

  /// 启动应用保护：冷启动进入应用前的验证
  appLock,
}

/// 统一的生物识别验证入口。
///
/// 封装系统弹窗文案的本地化：
/// - Android `BiometricPrompt` 的标题 / 副标题 / 取消按钮由
///   [AndroidAuthMessages] 提供（不传则回落为插件内置的英文默认串）；
/// - 说明文案 `localizedReason`（Android 为 description）随场景切换。
///
/// 各调用方只需声明 [BiometricScenario]，无需各自拼装文案。
class BiometricAuthHelper {
  BiometricAuthHelper._();

  static final LocalAuthentication _auth = LocalAuthentication();

  /// 供调用方复用同一实例做能力检测（`getAvailableBiometrics` 等）。
  static LocalAuthentication get auth => _auth;

  /// 弹出系统生物识别验证，返回是否通过。
  ///
  /// 用户取消或验证失败会抛出 `PlatformException`，由调用方决定是否提示。
  static Future<bool> authenticate(
    BuildContext context, {
    required BiometricScenario scenario,
  }) async {
    final l10n = L10n.of(context);

    final String title;
    final String reason;
    switch (scenario) {
      case BiometricScenario.vault:
        title = l10n.cat_vault;
        reason = l10n.biometric_reason_vault;
        break;
      case BiometricScenario.remoteGuard:
        title = l10n.ui_remote_guard;
        reason = l10n.biometric_reason_remote_guard;
        break;
      case BiometricScenario.appLock:
        title = l10n.ui_app_lock;
        reason = l10n.biometric_reason_app_lock;
        break;
    }

    return _auth.authenticate(
      localizedReason: reason,
      biometricOnly: true,
      authMessages: <AuthMessages>[
        AndroidAuthMessages(
          signInTitle: title,
          signInHint: l10n.biometric_verify_hint,
          cancelButton: l10n.ui_cancel,
        ),
      ],
    );
  }
}
