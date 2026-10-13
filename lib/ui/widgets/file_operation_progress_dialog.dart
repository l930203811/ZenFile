import 'package:flutter/material.dart';
import '../../providers/file_manager_provider.dart';
import '../../core/utils.dart';
import 'package:zenfile/l10n/generated/app_localizations.dart';
import 'progress_ring_shell.dart';

class FileOperationProgressDialog extends StatelessWidget {
  final FileManagerProvider provider;

  const FileOperationProgressDialog({
    super.key,
    required this.provider,
  });

  static Future<void> show(BuildContext context, FileManagerProvider provider) {
    return showDialog<void>(
      context: context,
      barrierDismissible: false,
      barrierColor: Colors.black54,
      builder: (context) => PopScope(
        canPop: false,
        child: FileOperationProgressDialog(provider: provider),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Center(
      child: ValueListenableBuilder<FileOperationProgress?>(
        valueListenable: provider.progressNotifier,
        builder: (context, progress, child) {
          if (progress == null) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (Navigator.canPop(context)) {
                Navigator.pop(context);
              }
            });
            return const SizedBox.shrink();
          }

          // 文件计数器（如「3/10」）：仅在多文件操作时显示，单文件无意义。
          // 放在「文件总大小」与「剩余时间」之间。
          // ⚠️ 必须走 [ProgressRingShell.counterLabel]：total 为 0 时返回 null；
          // 直接写 `clamp(1, total)` 会抛 ArgumentError，把整个弹窗顶成浅灰
          // 错误块（「白色透明层、没有进度条」，且不会再自动关闭）。
          final counterLabel = ProgressRingShell.counterLabel(
            progress.currentFileIndex,
            progress.totalFiles,
          );

          return ProgressRingShell(
            overall: progress.percentage,
            // 内圈=当前文件字节进度；total 为 0（非字节操作）时显示空环。
            inner: progress.currentFileTotal > 0
                ? (progress.currentFileBytes / progress.currentFileTotal)
                    .clamp(0.0, 1.0)
                : 0.0,
            children: [
              // 顶部后台按钮（文字）
              SizedBox(
                height: 32,
                child: OutlinedButton(
                  onPressed: () {
                    provider.runInBackground();
                    if (Navigator.canPop(context)) Navigator.pop(context);
                    // 最小化到双窗口状态栏，保留重新打开入口
                    provider.minimizeProgress();
                  },
                  style: OutlinedButton.styleFrom(
                    foregroundColor: theme.colorScheme.primary,
                    side: BorderSide(
                      color: theme.colorScheme.primary.withValues(alpha: 0.3),
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                  ),
                  child: Text(
                    L10n.of(context).ui_background,
                    style: const TextStyle(fontSize: 13),
                  ),
                ),
              ),
              const SizedBox(height: 8),

              // 分隔线（限制宽度，避免在圆形边缘外延伸）
              SizedBox(
                width: 200,
                child: Container(
                  height: 1,
                  color: theme.colorScheme.outline.withValues(alpha: 0.15),
                ),
              ),
              const SizedBox(height: 14),

              // 标题
              Text(
                provider.isCut ? L10n.of(context).msg9d69d7a0 : L10n.of(context).msg108feeed,
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  color: theme.colorScheme.onSurface,
                ),
              ),
              const SizedBox(height: 4),

              // 副标题
              Text(
                progress.speedMBs > 0
                    ? '${FileUtils.formatBytes((progress.speedMBs * 1024 * 1024).round(), 1)}/s'
                    : '—',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
                ),
              ),
              const SizedBox(height: 8),

              // 当前文件信息
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 200),
                child: Text(
                  progress.currentFileName,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w500,
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                ),
              ),
              const SizedBox(height: 10),

              // 统计信息
              Column(
                children: [
                  Text(
                    '${FileUtils.formatBytes(progress.bytesProcessed, 1)} / ${FileUtils.formatBytes(progress.totalBytes, 1)}',
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: theme.colorScheme.onSurface,
                    ),
                  ),
                  if (counterLabel != null) ...[
                    const SizedBox(height: 3),
                    Text(
                      counterLabel,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        // 与其它进度弹窗统一：计数器用常规文字色，不做主题色高亮
                        color: theme.colorScheme.onSurface.withValues(
                          alpha: 0.7,
                        ),
                      ),
                    ),
                  ],
                  const SizedBox(height: 3),
                  Text(
                    progress.eta.inSeconds > 0
                        ? '${L10n.of(context).ui_time_remaining} ${_formatDuration(progress.eta)}'
                        : '',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                      color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),

              // 分隔线（限制宽度，避免在圆形边缘外延伸）
              SizedBox(
                width: 200,
                child: Container(
                  height: 1,
                  color: theme.colorScheme.outline.withValues(alpha: 0.15),
                ),
              ),
              const SizedBox(height: 12),

              // 停止按钮
              SizedBox(
                width: 100,
                height: 36,
                child: OutlinedButton(
                  onPressed: () {
                    provider.cancelOperation();
                    Navigator.of(context).pop();
                  },
                  style: OutlinedButton.styleFrom(
                    foregroundColor: theme.colorScheme.onSurface.withValues(alpha: 0.6),
                    side: BorderSide(
                      color: theme.colorScheme.outline.withValues(alpha: 0.2),
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(18),
                    ),
                    padding: EdgeInsets.zero,
                  ),
                  child: Text(
                    L10n.of(context).ui_cancel,
                    style: const TextStyle(fontSize: 13),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  String _formatDuration(Duration duration) {
    if (duration.inHours > 0) {
      return '${duration.inHours}:${(duration.inMinutes % 60).toString().padLeft(2, '0')}:${(duration.inSeconds % 60).toString().padLeft(2, '0')}';
    }
    return '${duration.inMinutes}:${(duration.inSeconds % 60).toString().padLeft(2, '0')}';
  }
}
