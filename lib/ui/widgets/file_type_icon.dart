import 'package:flutter/material.dart';

/// 通用文件类型图标：图标在上，格式标签（JPG、PNG、PDF、DOC 等）在图标下方。
/// 与 ArchiveTypeIcon 类似的布局，但支持自定义图标。
class FileTypeIcon extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  final double iconScale;

  const FileTypeIcon({
    super.key,
    required this.icon,
    required this.label,
    required this.color,
    this.iconScale = 1.0,
  });

  @override
  Widget build(BuildContext context) {
    final scale = iconScale;
    final baseSize = 28 * scale;
    final iconSize = baseSize * 0.72;
    final fontSize = _labelFontSize(label) * scale;

    return SizedBox(
      width: baseSize,
      height: baseSize,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            icon,
            size: iconSize,
            color: color,
          ),
          SizedBox(height: 1 * scale),
          Text(
            label,
            style: TextStyle(
              fontSize: fontSize,
              fontWeight: FontWeight.w800,
              color: color,
              letterSpacing: 0.3,
              height: 1.0,
            ),
            textAlign: TextAlign.center,
            maxLines: 1,
            overflow: TextOverflow.clip,
          ),
        ],
      ),
    );
  }

  /// 根据标签长度自适应字号
  double _labelFontSize(String label) {
    switch (label.length) {
      case 1:
      case 2:
        return 8.5;
      case 3:
        return 7.5;
      case 4:
        return 6.5;
      default:
        return 5.5;
    }
  }
}
