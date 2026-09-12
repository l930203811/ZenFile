import 'package:flutter/material.dart';

/// 未知格式文件图标：灰色文件图标 + 中间问号。
/// 用于无法识别格式的文件的兜底显示。
class UnknownFileIcon extends StatelessWidget {
  final double size;
  const UnknownFileIcon({super.key, this.size = 28});

  @override
  Widget build(BuildContext context) {
    final questionSize = size * 0.46;
    return Stack(
      alignment: Alignment.center,
      children: [
        Icon(Icons.insert_drive_file_outlined, color: Colors.grey.shade400, size: size),
        Icon(Icons.question_mark, color: Colors.grey.shade600, size: questionSize),
      ],
    );
  }
}
