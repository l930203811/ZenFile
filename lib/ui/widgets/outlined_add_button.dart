import 'package:flutter/material.dart';

/// 带外圈且断线的加号按钮：圆形边框 + 中间加号，加号端点与外圈有间隙。
/// 用于保险箱页面各加密区域的导入/添加按钮。
class OutlinedAddButton extends StatelessWidget {
  final VoidCallback onPressed;
  final String? tooltip;
  final double size;
  final Color? color;

  const OutlinedAddButton({
    super.key,
    required this.onPressed,
    this.tooltip,
    this.size = 22,
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final iconColor = color ?? theme.colorScheme.primary;
    final borderColor = iconColor.withOpacity(0.5);

    return IconButton(
      visualDensity: VisualDensity.compact,
      tooltip: tooltip,
      onPressed: onPressed,
      icon: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(color: borderColor, width: 1.5),
        ),
        child: Icon(
          Icons.add,
          size: size * 0.62,
          color: iconColor,
        ),
      ),
    );
  }
}
