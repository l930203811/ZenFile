import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// 保险箱加密/解密进度数据：整体进度 + 当前文件字节进度。
class CryptProgressData {
  /// 整体进度（0.0 ~ 1.0）
  final double overall;

  /// 当前文件已处理字节（内圈绿色进度环）
  final int fileBytes;

  /// 当前文件总字节；0 表示未知/未开始（内圈显示空环）
  final int fileTotal;

  const CryptProgressData({
    required this.overall,
    this.fileBytes = 0,
    this.fileTotal = 0,
  });
}

/// 加密/解密进度控制器：把「文件数粒度」与「当前文件字节粒度」两个回调
/// 合并到同一个 ValueNotifier，供双层圆环弹窗消费。
class CryptProgressController {
  final ValueNotifier<CryptProgressData?> notifier = ValueNotifier(null);

  double _overall = 0;
  int _fileBytes = 0;
  int _fileTotal = 0;

  /// 对应加密/解密目录的 onProgress(processed, total) 回调（文件数粒度）
  void onOverall(int processed, int total) {
    _overall = total > 0 ? processed / total : 0;
    _push();
  }

  /// 直接设置整体进度（0.0 ~ 1.0），用于批量场景自定义折算公式
  void setOverall(double value) {
    _overall = value;
    _push();
  }

  /// 对应单文件加密/解密的当前文件字节回调
  void onFile(int bytes, int total) {
    _fileBytes = bytes;
    _fileTotal = total;
    _push();
  }

  void _push() {
    notifier.value = CryptProgressData(
      overall: _overall.clamp(0.0, 1.0),
      fileBytes: _fileBytes,
      fileTotal: _fileTotal,
    );
  }

  void dispose() => notifier.dispose();
}

/// 保险箱加密/解密进度弹窗：双层圆环（与复制/剪切、压缩/解压一致）。
///
/// 外圈（主题色 8px）= 整体进度；内圈（绿色 5px）= 当前文件进度。
class CryptProgressDialog extends StatelessWidget {
  final String message;
  final CryptProgressData? progress;

  const CryptProgressDialog({
    super.key,
    required this.message,
    this.progress,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final p = progress;
    final overall = (p?.overall ?? 0).clamp(0.0, 1.0);
    final circleBgColor = isDark
        ? const Color(0xFF1E1E2E)
        : theme.colorScheme.surface;

    final fileBytesText = (p != null && p.fileTotal > 0)
        ? '${(p.fileBytes / p.fileTotal).clamp(0.0, 1.0) * 100}%'
        : '';

    return Center(
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
            // 环形进度条（外圈=整体进度：淡底环 + 主题色进度环）
            // padding=strokeWidth/2（4px）：环外缘与圆形背景边缘完全对齐。
            Padding(
              padding: const EdgeInsets.all(4),
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
              padding: const EdgeInsets.all(4),
              child: CircularProgressIndicator(
                value: overall,
                strokeWidth: 8,
                backgroundColor: Colors.transparent,
                valueColor: AlwaysStoppedAnimation<Color>(
                  theme.colorScheme.primary,
                ),
                strokeCap: StrokeCap.round,
              ),
            ),

            // 环形进度条（内圈=当前文件进度，绿色系区分整体）
            Padding(
              padding: const EdgeInsets.all(12),
              child: CircularProgressIndicator(
                value: 1.0,
                strokeWidth: 5,
                backgroundColor: Colors.transparent,
                valueColor: AlwaysStoppedAnimation<Color>(
                  (isDark ? const Color(0xFF81C784) : const Color(0xFF43A047))
                      .withOpacity(0.10),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(12),
              child: CircularProgressIndicator(
                value: (p != null && p.fileTotal > 0)
                    ? (p.fileBytes / p.fileTotal).clamp(0.0, 1.0)
                    : 0.0,
                strokeWidth: 5,
                backgroundColor: Colors.transparent,
                valueColor: AlwaysStoppedAnimation<Color>(
                  isDark ? const Color(0xFF81C784) : const Color(0xFF43A047),
                ),
                strokeCap: StrokeCap.round,
              ),
            ),

            // 内部内容区域
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 34),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    message,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                      color: theme.colorScheme.onSurface,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    '${(overall * 100).toStringAsFixed(0)}%',
                    style: TextStyle(
                      fontSize: 26,
                      fontWeight: FontWeight.w800,
                      color: theme.colorScheme.primary,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    fileBytesText,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: isDark
                          ? const Color(0xFF81C784)
                          : const Color(0xFF43A047),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
