import 'package:flutter/material.dart';

import '../../l10n/generated/app_localizations.dart';
import '../../services/crash_forensics_service.dart';
import '../../services/crash_report_upload_service.dart';

/// 用户反馈 / 崩溃上报弹窗。
///
/// 两种入口共用：崩溃后启动提示（'crash'）与关于页「问题反馈」（'feedback'）。
/// 两者都**默认勾选附带诊断日志**（可手动取消），并提供选填联系邮箱，
/// 便于开发者需要补充信息时回信。
///
/// 上传走 [CrashReportUploadService]（Workers 端点转发为 GitHub Issue），
/// 失败不阻塞关闭，已上传过的日志按台账去重、不会重复发送；提交成功后
/// 已上传的崩溃报告会被自动删除（运行时日志除外），目录不积压旧报告。
class CrashReportDialog extends StatefulWidget {
  const CrashReportDialog({
    super.key,
    required this.kind,
    this.logNames = const <String>[],
  });

  /// 'crash'（崩溃后启动）或 'feedback'（关于页入口）。
  final String kind;

  /// 候选日志文件名（弹窗内会过滤掉已上传过的）。
  final List<String> logNames;

  /// 便捷入口：反馈入口（关于页）。
  static Future<void> showFeedback(BuildContext context) {
    return showDialog(
      context: context,
      useRootNavigator: true,
      builder: (_) => CrashReportDialog(
        kind: 'feedback',
        logNames: CrashReportUploadService.listReportNames(),
      ),
    );
  }

  @override
  State<CrashReportDialog> createState() => _CrashReportDialogState();
}

class _CrashReportDialogState extends State<CrashReportDialog> {
  final _controller = TextEditingController();
  final _emailController = TextEditingController();
  final _focusNode = FocusNode();
  // 崩溃与问题反馈都默认勾选日志：多数反馈不带日志等于没有现场，
  // 开发者无法定位；用户可自行取消。
  bool _includeLogs = true;
  bool _uploading = false;
  String? _meta;

  @override
  void initState() {
    super.initState();
    // 环境行（机型 + 安装包指纹）：异步取，失败不影响弹窗
    CrashForensicsService.describe().then((v) {
      if (mounted && v != null && v.isNotEmpty) {
        setState(() => _meta = v);
      }
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    _emailController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    if (_uploading) return;
    setState(() => _uploading = true);
    final ok = await CrashReportUploadService.upload(
      description: _controller.text,
      kind: widget.kind,
      extraMeta: _meta,
      email: _emailController.text,
      includeLogs: _includeLogs,
      logNames: widget.logNames,
    );
    if (!mounted) return;
    Navigator.of(context, rootNavigator: true).pop();
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger != null) {
      messenger.showSnackBar(
        SnackBar(
          behavior: SnackBarBehavior.floating,
          content: Text(
            ok
                ? L10n.of(context).ui_feedback_sent
                : L10n.of(context).ui_feedback_failed,
          ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = L10n.of(context);
    final theme = Theme.of(context);
    final isCrash = widget.kind == 'crash';
    final pendingLogs = CrashReportUploadService.filterUnuploaded(
      widget.logNames,
    );

    return AlertDialog(
      title: Text(
        isCrash ? l10n.ui_crash_dialog_title : l10n.ui_feedback_title,
      ),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                isCrash
                    ? l10n.ui_crash_dialog_body
                    : l10n.ui_feedback_dialog_body,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.7),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _controller,
                focusNode: _focusNode,
                maxLines: 4,
                minLines: 3,
                maxLength: 4000,
                decoration: InputDecoration(
                  hintText: l10n.ui_feedback_hint,
                  border: const OutlineInputBorder(),
                  isDense: true,
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _emailController,
                keyboardType: TextInputType.emailAddress,
                maxLength: 200,
                decoration: InputDecoration(
                  labelText: l10n.ui_feedback_email_label,
                  hintText: l10n.ui_feedback_email_hint,
                  border: const OutlineInputBorder(),
                  isDense: true,
                  prefixIcon: const Icon(Icons.alternate_email, size: 18),
                ),
              ),
              if (pendingLogs.isNotEmpty) ...[
                const SizedBox(height: 4),
                CheckboxListTile(
                  value: _includeLogs,
                  onChanged: (v) => setState(() => _includeLogs = v ?? false),
                  controlAffinity: ListTileControlAffinity.leading,
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  title: Text(
                    l10n.ui_crash_attach_logs(pendingLogs.length),
                    style: theme.textTheme.bodyMedium,
                  ),
                ),
              ] else ...[
                const SizedBox(height: 4),
                Text(
                  l10n.ui_feedback_no_logs,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.45),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _uploading
              ? null
              : () => Navigator.of(context, rootNavigator: true).pop(),
          child: Text(l10n.ui_feedback_later),
        ),
        FilledButton(
          onPressed: _uploading ? null : _send,
          child: _uploading
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text(l10n.ui_feedback_send),
        ),
      ],
    );
  }
}
