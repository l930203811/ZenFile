import 'dart:ui';
import 'package:flutter/material.dart';
import '../../providers/file_manager_provider.dart';
import '../../core/icon_fonts/broken_icons.dart';
import '../../core/utils.dart';

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
      barrierColor: Colors.black.withOpacity(0.4),
      builder: (context) => PopScope(
        canPop: false,
        child: FileOperationProgressDialog(provider: provider),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return BackdropFilter(
      filter: ImageFilter.blur(sigmaX: 8, sigmaY: 8),
      child: Center(
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

            return Card(
              elevation: 24,
              shadowColor: Colors.black.withOpacity(0.3),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(28),
                side: BorderSide(color: theme.colorScheme.outline.withOpacity(0.12)),
              ),
              color: isDark ? const Color(0xFF1E1E2E) : theme.colorScheme.surface.withOpacity(0.95),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(28),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 28, horizontal: 32),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // Title
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            provider.isCut ? Broken.scissor : Broken.document_copy,
                            color: theme.colorScheme.primary,
                            size: 20,
                          ),
                          const SizedBox(width: 8),
                          Text(
                            provider.isCut ? '正在移动文件...' : '正在复制文件...',
                            style: theme.textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 24),

                      // Circular progress with percentage
                      SizedBox(
                        width: 120,
                        height: 120,
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            // Background circle
                            Container(
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: theme.colorScheme.primary.withOpacity(0.08),
                              ),
                            ),
                            // Progress arc
                            ShaderMask(
                              shaderCallback: (bounds) {
                                return SweepGradient(
                                  startAngle: 0.0,
                                  endAngle: 3.141592653589793 * 2 * progress.percentage.clamp(0.0, 1.0),
                                  colors: [
                                    theme.colorScheme.primary,
                                    theme.colorScheme.primary.withRed(
                                      (theme.colorScheme.primary.red * 0.6).round().clamp(0, 255),
                                    ).withBlue(
                                      (theme.colorScheme.primary.blue * 1.2).round().clamp(0, 255),
                                    ),
                                  ],
                                  transform: const GradientRotation(-1.5708),
                                ).createShader(bounds);
                              },
                              blendMode: BlendMode.srcIn,
                              child: Container(
                                decoration: const BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: Colors.white,
                                ),
                              ),
                            ),
                            // Inner circle (cutout)
                            Center(
                              child: Container(
                                width: 96,
                                height: 96,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: isDark ? const Color(0xFF1E1E2E) : theme.colorScheme.surface,
                                ),
                              ),
                            ),
                            // Percentage text
                            Center(
                              child: Text(
                                '$percent%',
                                style: TextStyle(
                                  fontSize: 28,
                                  fontWeight: FontWeight.w900,
                                  color: theme.colorScheme.primary,
                                  letterSpacing: -1,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 20),

                      // Current file info
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                        decoration: BoxDecoration(
                          color: theme.colorScheme.surfaceVariant.withOpacity(0.3),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Row(
                          children: [
                            Icon(
                              Broken.document,
                              size: 16,
                              color: theme.colorScheme.primary.withOpacity(0.7),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                progress.currentFileName,
                                style: theme.textTheme.bodySmall?.copyWith(
                                  fontWeight: FontWeight.w600,
                                  color: theme.colorScheme.onSurface.withOpacity(0.8),
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 8),

                      // Stats row
                      Text(
                        '${progress.currentFileIndex}/${progress.totalFiles}  |  ${FileUtils.formatBytes(progress.bytesProcessed, 1)} / ${FileUtils.formatBytes(progress.totalBytes, 1)}  |  ${progress.speedMBs.toStringAsFixed(1)} MB/s',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurface.withOpacity(0.45),
                          fontSize: 11,
                        ),
                      ),
                      const SizedBox(height: 20),

                      // Cancel button
                      SizedBox(
                        width: double.infinity,
                        child: OutlinedButton.icon(
                          onPressed: () {
                            provider.cancelOperation();
                          },
                          icon: const Icon(Broken.close_square, size: 16),
                          label: const Text('取消操作', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: Colors.redAccent,
                            side: BorderSide(color: Colors.redAccent.withOpacity(0.3)),
                            padding: const EdgeInsets.symmetric(vertical: 10),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(14),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}
