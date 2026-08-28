import 'package:flutter/material.dart';
import '../../core/icon_fonts/broken_icons.dart';

/// 远程文件/文件夹缩略图左上角的云徽标，与分类页远程媒体云徽视觉一致，
/// 用于帮助用户区分本地文件与远程（SMB/FTP/SFTP/WebDAV 等）文件。
///
/// 该 Widget 返回一个 [Positioned]，必须放在缩略图容器的 [Stack] 内使用。
class RemoteCloudBadge extends StatelessWidget {
  final double size;
  final double top;
  final double left;

  const RemoteCloudBadge({
    super.key,
    this.size = 12,
    this.top = 4,
    this.left = 4,
  });

  @override
  Widget build(BuildContext context) {
    return Positioned(
      top: top,
      left: left,
      child: Container(
        padding: const EdgeInsets.all(3),
        decoration: BoxDecoration(
          color: Colors.black.withOpacity(0.5),
          shape: BoxShape.circle,
        ),
        child: Icon(Broken.cloud, color: Colors.white, size: size),
      ),
    );
  }
}
