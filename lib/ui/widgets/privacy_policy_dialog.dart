import 'dart:io';

import 'package:flutter/material.dart';
import 'package:zenfile/l10n/generated/app_localizations.dart';

import '../../services/preferences_service.dart';

/// 《隐私政策》当前版本。
///
/// 政策内容发生实质性变更时 **必须 +1**：所有已同意旧版的用户会在下次启动时
/// 重新看到同意弹窗（合规要求：变更后需再次取得同意；见 main.dart 的版本检查）。
const int kPrivacyPolicyVersion = 1;

/// 首次启动 / 政策更新时的同意弹窗。
///
/// 返回 true = 已同意并写入了版本号；正常路径下不会返回 false ——
/// 用户点「不同意」会先弹确认框，确认退出则直接 [exit](0) 应用（国内合规惯例），
/// 选「继续查看」则回到本弹窗。
Future<bool> showPrivacyPolicyGate(BuildContext context) async {
  final accepted = await _showPrivacyPolicyDialog(context, gateMode: true);
  return accepted ?? false;
}

/// 关于页的只读浏览入口：无同意/拒绝按钮，只有「我知道了」。
Future<void> showPrivacyPolicyReadOnly(BuildContext context) async {
  await _showPrivacyPolicyDialog(context, gateMode: false);
}

Future<bool?> _showPrivacyPolicyDialog(
  BuildContext context, {
  required bool gateMode,
}) {
  final l10n = L10n.of(context);
  return showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (dialogContext) {
      final theme = Theme.of(dialogContext);
      return PopScope(
        canPop: false,
        child: Dialog(
          insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 48),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 20, 24, 4),
                child: Row(
                  children: [
                    Icon(
                      Icons.privacy_tip_rounded,
                      color: theme.colorScheme.primary,
                      size: 22,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        l10n.ui_privacy_policy_title,
                        style: const TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              Flexible(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(24, 8, 24, 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _para(l10n.privacy_intro),
                      _para(l10n.privacy_perm_storage),
                      _para(l10n.privacy_perm_mic),
                      _para(l10n.privacy_perm_location),
                      _para(l10n.privacy_perm_others),
                      _para(l10n.privacy_logs),
                      _para(l10n.privacy_local_third),
                      _para(l10n.privacy_rights),
                    ],
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 4, 20, 16),
                child: gateMode
                    ? Row(
                        children: [
                          Expanded(
                            child: OutlinedButton(
                              onPressed: () =>
                                  _confirmExit(dialogContext, l10n),
                              style: OutlinedButton.styleFrom(
                                padding:
                                    const EdgeInsets.symmetric(vertical: 12),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(12),
                                ),
                              ),
                              child: Text(l10n.ui_privacy_disagree),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            flex: 2,
                            child: FilledButton(
                              onPressed: () async {
                                // 同意即落盘版本号：政策更新后据此重弹。
                                await PreferencesService
                                    .setPrivacyPolicyAcceptedVersion(
                                  kPrivacyPolicyVersion,
                                );
                                if (dialogContext.mounted) {
                                  Navigator.of(dialogContext).pop(true);
                                }
                              },
                              style: FilledButton.styleFrom(
                                padding:
                                    const EdgeInsets.symmetric(vertical: 12),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(12),
                                ),
                              ),
                              child: Text(l10n.ui_privacy_agree),
                            ),
                          ),
                        ],
                      )
                    : SizedBox(
                        width: double.infinity,
                        child: FilledButton(
                          onPressed: () => Navigator.of(dialogContext).pop(),
                          style: FilledButton.styleFrom(
                            padding: const EdgeInsets.symmetric(vertical: 12),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                          ),
                          child: Text(l10n.ui_privacy_read),
                        ),
                      ),
              ),
            ],
          ),
        ),
      );
    },
  );
}

/// 「不同意」后的挽留确认框：继续查看 → 回到政策弹窗；退出 → 立即结束应用。
Future<void> _confirmExit(BuildContext dialogContext, L10n l10n) async {
  final exitConfirmed = await showDialog<bool>(
    context: dialogContext,
    barrierDismissible: false,
    builder: (confirmContext) => AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: Text(
        l10n.ui_privacy_exit_title,
        style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800),
      ),
      content: Text(
        l10n.ui_privacy_exit_body,
        style: const TextStyle(fontSize: 14, height: 1.5),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(confirmContext).pop(false),
          child: Text(l10n.ui_privacy_exit_no),
        ),
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: Theme.of(confirmContext).colorScheme.error,
          ),
          onPressed: () => Navigator.of(confirmContext).pop(true),
          child: Text(l10n.ui_privacy_exit_yes),
        ),
      ],
    ),
  );
  if (exitConfirmed == true) {
    // dart:io exit 立即结束进程：未同意隐私政策前不进入应用（合规要求）。
    exit(0);
  }
}

Widget _para(String text) {
  return Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: Text(
      text,
      style: const TextStyle(fontSize: 13.5, height: 1.55),
    ),
  );
}
