import 'package:flutter/material.dart';

import '../../core/icon_fonts/broken_icons.dart';

/// 统一的「带圆圈背景」返回按钮。
///
/// 设计来源：设置子页面 AppBar 的 `leading`（Broken.arrow_left 图标按钮），
/// 外面套一层圆形底 —— 参考图片查看器顶栏的圆圈返回按钮样式。用于：
///  · 连接 / 设置主页的全屏头部（home_screen `_buildFullScreenHeader`）；
///  · 设置 / 连接各子页面 AppBar 的 leading（替代裸的 IconButton）。
///
/// 圆底用 6% onSurface：浅色下是极浅灰、深色下是极浅白，与主题自适应，
/// 不依赖 surfaceTint（AppBar 透明背景时也能正确显示）。
class CircledBackButton extends StatelessWidget {
  final VoidCallback? onPressed;

  /// 图标尺寸（默认 20，与 Broken.arrow_left 常规用法一致）。
  final double iconSize;

  const CircledBackButton({super.key, this.onPressed, this.iconSize = 20});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.all(8),
      child: Container(
        decoration: BoxDecoration(
          color: theme.colorScheme.onSurface.withValues(alpha: 0.06),
          shape: BoxShape.circle,
        ),
        child: IconButton(
          icon: Icon(Broken.arrow_left, size: iconSize),
          onPressed: onPressed,
        ),
      ),
    );
  }
}
