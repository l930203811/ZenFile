import 'package:flutter/material.dart';
import '../../services/background_archive_service.dart';
import 'package:zenfile/l10n/generated/app_localizations.dart';
import '../../core/utils.dart';

class BackgroundOperationProgressDialog extends StatelessWidget {
  final BackgroundArchiveService service;

  const BackgroundOperationProgressDialog({
    super.key,
    required this.service,
  });

  static Future<void> show(BuildContext context, BackgroundArchiveService service) {
    return showDialog<void>(
      context: context,
      barrierDismissible: false,
      barrierColor: Colors.black.withOpacity(0.4),
      builder: (dialogContext) {
        service.setActiveDialogContext(dialogContext);
        service.dialogCloseCallback = () {
          if (Navigator.canPop(dialogContext)) {
            Navigator.pop(dialogContext);
          }
        };
        return PopScope(
          canPop: false,
          child: BackgroundOperationProgressDialog(service: service),
        );
      },
    );
  }

  String _formatETA(double speedBytesPerSecond, double progress, int totalBytes) {
    if (speedBytesPerSecond <= 0 || progress <= 0) {
      return '--:--';
    }
    final remainingBytes = totalBytes * (1.0 - progress);
    final remainingSeconds = remainingBytes / speedBytesPerSecond;
    if (remainingSeconds < 60) {
      return '${remainingSeconds.round()}s';
    } else if (remainingSeconds < 3600) {
      final minutes = (remainingSeconds / 60).floor();
      final seconds = (remainingSeconds % 60).floor();
      return '${minutes}m ${seconds}s';
    } else {
      final hours = (remainingSeconds / 3600).floor();
      final minutes = ((remainingSeconds % 3600) / 60).floor();
      return '${hours}h ${minutes}m';
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Center(
      child: ValueListenableBuilder<BackgroundOperation?>(
        valueListenable: service.activeOperation,
        builder: (context, operation, child) {
          if (operation == null) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (Navigator.canPop(context)) {
                Navigator.pop(context);
              }
            });
            return const SizedBox.shrink();
          }

          final percent = operation.progress.clamp(0.0, 1.0);
          final isDark = theme.brightness == Brightness.dark;
          final circleBgColor = isDark
              ? const Color(0xFF1E1E2E)
              : theme.colorScheme.surface;

          final speedText = operation.speedBytesPerSecond > 0
              ? '${FileUtils.formatBytes((operation.speedBytesPerSecond).round(), 1)}/s'
              : '—';
          final etaText = _formatETA(operation.speedBytesPerSecond, percent, operation.totalBytes);
          final bytesText = '${FileUtils.formatBytes(operation.bytesProcessed, 1)} / ${FileUtils.formatBytes(operation.totalBytes, 1)}';

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
                  // 环形进度条（外圈背景）
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
                  // 环形进度条（实际进度）
                  Padding(
                    padding: const EdgeInsets.all(8),
                    child: TweenAnimationBuilder<double>(
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
                              service.runInBackground();
                              if (Navigator.canPop(context)) {
                                Navigator.pop(context);
                              }
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
                          operation.title,
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                            color: theme.colorScheme.onSurface,
                          ),
                        ),
                        const SizedBox(height: 4),

                        // 副标题（压缩包名 + 速度）
                        Text(
                          operation.archiveName,
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w500,
                            color: theme.colorScheme.onSurface.withOpacity(0.5),
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 8),

                        // 当前文件信息
                        ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 200),
                          child: Text(
                            operation.currentFile.isEmpty
                                ? L10n.of(context).msg67bd9375
                                : operation.currentFile,
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
                              bytesText,
                              style: TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                                color: theme.colorScheme.onSurface,
                              ),
                            ),
                            const SizedBox(height: 3),
                            Text(
                              speedText,
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w500,
                                color: theme.colorScheme.onSurface.withOpacity(0.5),
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              etaText.isNotEmpty
                                  ? '${L10n.of(context).ui_time_remaining} $etaText'
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
                              service.cancelOperation();
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
}
