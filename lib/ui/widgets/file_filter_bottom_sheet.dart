import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../models/file_filter_type.dart';
import '../../providers/file_manager_provider.dart';
import '../../core/icon_fonts/broken_icons.dart';

class FileFilterBottomSheet extends StatelessWidget {
  const FileFilterBottomSheet({super.key});

  static Future<void> show(BuildContext context) {
    final theme = Theme.of(context);
    return showModalBottomSheet(
      context: context,
      backgroundColor: theme.colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (context) => const FileFilterBottomSheet(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final provider = context.watch<FileManagerProvider>();
    final activeFilter = provider.filterType;

    final List<_FilterItem> items = [
      _FilterItem(
        type: FileFilterType.all,
        label: '全部文件',
        subtitle: '显示此目录中的所有文件和文件夹',
        icon: Broken.category,
        color: theme.colorScheme.primary,
      ),
      _FilterItem(
        type: FileFilterType.documents,
        label: '仅文档',
        subtitle: 'PDF、Word 文档、电子表格、文本和电子书',
        icon: Broken.document,
        color: Colors.blueAccent,
      ),
      _FilterItem(
        type: FileFilterType.images,
        label: '仅图片',
        subtitle: 'JPEG、PNG、WebP 和原始照片格式',
        icon: Broken.image,
        color: Colors.purpleAccent,
      ),
      _FilterItem(
        type: FileFilterType.audio,
        label: '仅音频',
        subtitle: 'MP3、WAV、AAC 和高保真音频',
        icon: Broken.music,
        color: Colors.greenAccent,
      ),
      _FilterItem(
        type: FileFilterType.videos,
        label: '仅视频',
        subtitle: 'MP4、MKV、WebM 和高分辨率视频片段',
        icon: Broken.video,
        color: Colors.redAccent,
      ),
      _FilterItem(
        type: FileFilterType.archives,
        label: '仅压缩包',
        subtitle: 'ZIP、7Z、RAR 和其他压缩文件',
        icon: Broken.archive,
        color: Colors.brown,
      ),
    ];

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                margin: const EdgeInsets.only(bottom: 16),
                decoration: BoxDecoration(
                  color: theme.dividerColor.withOpacity(0.15),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24.0, vertical: 8.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '按类型筛选文件',
                    style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '选择一个类别以仅显示匹配的文件',
                    style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurface.withOpacity(0.55)),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                physics: const BouncingScrollPhysics(),
                itemCount: items.length,
                itemBuilder: (context, index) {
                  final item = items[index];
                  final isSelected = item.type == activeFilter;

                  return Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 3.0),
                    child: InkWell(
                      onTap: () {
                        provider.setFilterType(item.type);
                        Navigator.pop(context);
                      },
                      borderRadius: BorderRadius.circular(16),
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 200),
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                        decoration: BoxDecoration(
                          color: isSelected
                              ? item.color.withOpacity(0.12)
                              : Colors.transparent,
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(
                            color: isSelected
                                ? item.color.withOpacity(0.3)
                                : Colors.transparent,
                            width: 1.5,
                          ),
                        ),
                        child: Row(
                          children: [
                            Container(
                              padding: const EdgeInsets.all(10),
                              decoration: BoxDecoration(
                                color: isSelected
                                    ? item.color.withOpacity(0.2)
                                    : (isDark ? Colors.white.withOpacity(0.05) : Colors.black.withOpacity(0.03)),
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: Icon(
                                item.icon,
                                color: isSelected ? item.color : theme.colorScheme.onSurface.withOpacity(0.7),
                                size: 22,
                              ),
                            ),
                            const SizedBox(width: 16),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    item.label,
                                    style: TextStyle(
                                      fontWeight: isSelected ? FontWeight.bold : FontWeight.w600,
                                      fontSize: 15,
                                      color: isSelected ? theme.colorScheme.onSurface : theme.colorScheme.onSurface.withOpacity(0.85),
                                    ),
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    item.subtitle,
                                    style: TextStyle(
                                      fontSize: 11,
                                      color: theme.colorScheme.onSurface.withOpacity(0.5),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            if (isSelected)
                              Icon(
                                Icons.check_circle_rounded,
                                color: item.color,
                                size: 22,
                              ),
                          ],
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _FilterItem {
  final FileFilterType type;
  final String label;
  final String subtitle;
  final IconData icon;
  final Color color;

  _FilterItem({
    required this.type,
    required this.label,
    required this.subtitle,
    required this.icon,
    required this.color,
  });
}
