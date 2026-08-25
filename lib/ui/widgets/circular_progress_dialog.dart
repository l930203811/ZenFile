import 'package:flutter/material.dart';
import 'package:zenfile/l10n/generated/app_localizations.dart';

/// 通用圆形进度对话框。
///
/// 统一浏览页「复制/剪切」(FileOperationProgressDialog) 与归档备份
/// (BackgroundOperationProgressDialog) 的圆形卡片样式，供「立即备份」等
/// 仅提供文本状态、无精确百分比的场景复用。
///
/// [title]        顶部标题（如「备份」「复制」）。
/// [statusNotifier] 监听状态文本变化（当前文件名 / 阶段说明）。
/// [percentage]   0~1 的确定进度；传 null 时显示不确定环（不显示百分比）。
/// [onCancel]     点「取消」回调；为空则不显示取消按钮。
/// [cancelLabel]  取消按钮文案，默认取 l10n.ui_cancel。
/// [onBackground] 点「后台」回调；为空则不显示后台按钮。
class CircularProgressDialog extends StatelessWidget {
  final String title;
  final ValueNotifier<String> statusNotifier;
  final double? percentage;
  final VoidCallback? onCancel;
  final String? cancelLabel;
  final VoidCallback? onBackground;

  const CircularProgressDialog({
    super.key,
    required this.title,
    required this.statusNotifier,
    this.percentage,
    this.onCancel,
    this.cancelLabel,
    this.onBackground,
  });

  static Future<void> show({
    required BuildContext context,
    required String title,
    required ValueNotifier<String> statusNotifier,
    double? percentage,
    VoidCallback? onCancel,
    String? cancelLabel,
    VoidCallback? onBackground,
    bool barrierDismissible = false,
  }) {
    return showDialog<void>(
      context: context,
      barrierDismissible: barrierDismissible,
      builder: (dialogContext) => PopScope(
        canPop: false,
        child: CircularProgressDialog(
          title: title,
          statusNotifier: statusNotifier,
          percentage: percentage,
          onCancel: onCancel,
          cancelLabel: cancelLabel,
          onBackground: onBackground,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final circleBgColor = isDark
        ? const Color(0xFF1E1E2E)
        : theme.colorScheme.surface;

    return Center(
      child: ValueListenableBuilder<String>(
        valueListenable: statusNotifier,
        builder: (context, status, _) {
          final percent = (percentage ?? 0).clamp(0.0, 1.0);
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Container(
              width: 300,
              height: 300,
              decoration: BoxDecoration(
                color: circleBgColor,
                shape: BoxShape.circle,
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.4),
                    blurRadius: 30,
                    spreadRadius: 2,
                    offset: const Offset(0, 12),
                  ),
                ],
              ),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  // 外圈背景环
                  Padding(
                    padding: const EdgeInsets.all(8),
                    child: CircularProgressIndicator(
                      value: 1.0,
                      strokeWidth: 8,
                      backgroundColor: Colors.transparent,
                      valueColor: AlwaysStoppedAnimation<Color>(
                        theme.colorScheme.primary.withOpacity(0.08),
                      ),
                    ),
                  ),
                  // 实际进度环（percentage 为 null 时显示不确定环）
                  Padding(
                    padding: const EdgeInsets.all(8),
                    child: percentage == null
                        ? CircularProgressIndicator(
                            strokeWidth: 8,
                            backgroundColor: Colors.transparent,
                            valueColor: AlwaysStoppedAnimation<Color>(
                              theme.colorScheme.primary,
                            ),
                            strokeCap: StrokeCap.round,
                          )
                        : TweenAnimationBuilder<double>(
                            tween: Tween<double>(begin: 0, end: percent),
                            duration: const Duration(milliseconds: 300),
                            curve: Curves.easeOut,
                            builder: (context, value, child) {
                              return CircularProgressIndicator(
                                value: value,
                                strokeWidth: 8,
                                backgroundColor: Colors.transparent,
                                valueColor: AlwaysStoppedAnimation<Color>(
                                  theme.colorScheme.primary,
                                ),
                                strokeCap: StrokeCap.round,
                              );
                            },
                          ),
                  ),

                  // 内部内容
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 28),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        // 标题
                        Text(
                          title,
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                            color: theme.colorScheme.onSurface,
                          ),
                        ),
                        const SizedBox(height: 10),

                        // 分隔线
                        Container(
                          height: 1,
                          color: theme.colorScheme.outline.withOpacity(0.15),
                        ),
                        const SizedBox(height: 14),

                        // 百分比（仅确定进度时显示）
                        if (percentage != null)
                          Text(
                            '${(percent * 100).round()}%',
                            style: TextStyle(
                              fontSize: 22,
                              fontWeight: FontWeight.w800,
                              color: theme.colorScheme.primary,
                            ),
                          ),
                        const SizedBox(height: 8),

                        // 状态文本（当前文件名 / 阶段）
                        ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 220),
                          child: Text(
                            status.isEmpty
                                ? L10n.of(context).msg67bd9375
                                : status,
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w500,
                              color: theme.colorScheme.onSurface.withOpacity(0.6),
                            ),
                            maxLines: 3,
                            overflow: TextOverflow.ellipsis,
                            textAlign: TextAlign.center,
                          ),
                        ),
                        const SizedBox(height: 14),

                        // 分隔线
                        Container(
                          height: 1,
                          color: theme.colorScheme.outline.withOpacity(0.15),
                        ),
                        const SizedBox(height: 12),

                        // 操作按钮：取消 / 后台
                        if (onCancel != null || onBackground != null)
                          Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              if (onCancel != null)
                                SizedBox(
                                  width: 100,
                                  height: 36,
                                  child: OutlinedButton(
                                    onPressed: onCancel,
                                    style: OutlinedButton.styleFrom(
                                      foregroundColor: theme.colorScheme.onSurface.withOpacity(0.6),
                                      side: BorderSide(
                                        color: theme.colorScheme.outline.withOpacity(0.2),
                                      ),
                                      shape: RoundedRectangleBorder(
                                        borderRadius: BorderRadius.circular(18),
                                      ),
                                      padding: EdgeInsets.zero,
                                    ),
                                    child: Text(
                                      cancelLabel ?? L10n.of(context).ui_cancel,
                                      style: const TextStyle(fontSize: 13),
                                    ),
                                  ),
                                ),
                              if (onCancel != null && onBackground != null)
                                const SizedBox(width: 12),
                              if (onBackground != null)
                                SizedBox(
                                  width: 100,
                                  height: 36,
                                  child: OutlinedButton(
                                    onPressed: onBackground,
                                    style: OutlinedButton.styleFrom(
                                      foregroundColor: theme.colorScheme.primary,
                                      side: BorderSide(
                                        color: theme.colorScheme.primary.withOpacity(0.3),
                                      ),
                                      shape: RoundedRectangleBorder(
                                        borderRadius: BorderRadius.circular(18),
                                      ),
                                      padding: EdgeInsets.zero,
                                    ),
                                    child: Text(
                                      L10n.of(context).ui_background,
                                      style: const TextStyle(fontSize: 13),
                                    ),
                                  ),
                                ),
                            ],
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}
