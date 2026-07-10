import 'package:flutter/material.dart';
import '../../providers/file_manager_provider.dart';
import '../../core/icon_fonts/broken_icons.dart';
import '../../core/utils.dart';
import 'package:zenfile/l10n/generated/app_localizations.dart';

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

          final percent = (progress.percentage * 100).clamp(0, 100).toInt();
          final isDark = theme.brightness == Brightness.dark;
          final circleBgColor = isDark
              ? const Color(0xFF1E1E2E)
              : theme.colorScheme.surface;

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
                  // 环形进度条（外圈）
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
                  Padding(
                    padding: const EdgeInsets.all(8),
                    child: CircularProgressIndicator(
                      value: progress.percentage.clamp(0.0, 1.0),
                      strokeWidth: 8,
                      backgroundColor: Colors.transparent,
                      valueColor: AlwaysStoppedAnimation<Color>(theme.colorScheme.primary),
                      strokeCap: StrokeCap.round,
                    ),
                  ),

                  // 内部内容区域
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 28),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        // 顶部关闭/后台按钮
                        Container(
                          width: 36,
                          height: 36,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: theme.colorScheme.primary.withOpacity(0.1),
                          ),
                          child: IconButton(
                            icon: const Icon(Icons.close, size: 18),
                            color: theme.colorScheme.primary,
                            onPressed: () {
                              provider.runInBackground();
                            },
                          ),
                        ),
                        const SizedBox(height: 12),

                        // 分隔线
                        Container(
                          height: 1,
                          color: theme.colorScheme.outline.withOpacity(0.15),
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
                          L10n.of(context).ui_transferring_files,
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w500,
                            color: theme.colorScheme.onSurface.withOpacity(0.5),
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
                              color: theme.colorScheme.onSurface.withOpacity(0.6),
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
                            const SizedBox(height: 3),
                            Text(
                              progress.eta.inSeconds > 0
                                  ? '${L10n.of(context).ui_time_remaining} ${_formatDuration(progress.eta)}'
                                  : '',
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w500,
                                color: theme.colorScheme.onSurface.withOpacity(0.5),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 14),

                        // 分隔线
                        Container(
                          height: 1,
                          color: theme.colorScheme.outline.withOpacity(0.15),
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
                              L10n.of(context).ui_cancel,
                              style: const TextStyle(fontSize: 13),
                            ),
                          ),
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

  String _formatDuration(Duration duration) {
    if (duration.inHours > 0) {
      return '${duration.inHours}:${(duration.inMinutes % 60).toString().padLeft(2, '0')}:${(duration.inSeconds % 60).toString().padLeft(2, '0')}';
    }
    return '${duration.inMinutes}:${(duration.inSeconds % 60).toString().padLeft(2, '0')}';
  }
}
