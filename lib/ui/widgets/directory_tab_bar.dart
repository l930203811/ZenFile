import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import '../../providers/file_manager_provider.dart';
import '../../core/icon_fonts/broken_icons.dart';

class DirectoryTabBar extends StatelessWidget implements PreferredSizeWidget {
  final FileManagerProvider provider;
  final ScrollController? scrollController;

  const DirectoryTabBar({super.key, required this.provider, this.scrollController});

  @override
  Size get preferredSize => const Size.fromHeight(32);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tabs = provider.tabs;
    final activeIndex = provider.activeTabIndex;

    return Container(
      height: 32,
      decoration: BoxDecoration(
        color: theme.appBarTheme.backgroundColor ?? theme.colorScheme.surface,
      ),
      child: Row(
        children: [
          Expanded(
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              controller: scrollController,
              physics: const BouncingScrollPhysics(),
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              itemCount: tabs.length,
              itemBuilder: (context, index) {
                final tab = tabs[index];
                final isSelected = index == activeIndex;
                final isRoot = tab.currentPath == provider.rootPath;
                final title = isRoot ? '主目录' : p.basename(tab.currentPath);

                return Container(
                  margin: const EdgeInsets.only(right: 4),
                  child: Material(
                    color: isSelected
                        ? theme.colorScheme.primaryContainer.withOpacity(0.35)
                        : theme.colorScheme.surfaceVariant.withOpacity(0.4),
                    borderRadius: BorderRadius.circular(10),
                    child: InkWell(
                      onTap: () => provider.setActiveTab(index),
                      onDoubleTap: () {
                        if (tabs.length > 1 && !tab.isPinned) {
                          provider.closeTab(index);
                        }
                      },
                      onLongPress: () => _showCloseTabSheet(context, provider, index),
                      borderRadius: BorderRadius.circular(10),
                      child: Container(
                        constraints: const BoxConstraints(minWidth: 60, maxWidth: 120),
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(
                            color: isSelected
                                ? theme.colorScheme.primary.withOpacity(0.4)
                                : theme.dividerColor.withOpacity(0.05),
                            width: 1.2,
                          ),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              tab.isPinned
                                  ? Icons.push_pin_rounded
                                  : (isRoot ? Broken.home_1 : Broken.folder),
                              size: 14,
                              color: tab.isPinned
                                  ? Colors.orange
                                  : (isSelected
                                      ? theme.colorScheme.primary
                                      : theme.colorScheme.onSurface.withOpacity(0.6)),
                            ),
                            const SizedBox(width: 6),
                            Flexible(
                              child: Text(
                                title.isEmpty ? '/' : title,
                                style: TextStyle(
                                    fontSize: 12,
                                    fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
                                    color: isSelected
                                        ? theme.colorScheme.primary
                                        : theme.colorScheme.onSurface.withOpacity(0.8)),
                                overflow: TextOverflow.ellipsis,
                                maxLines: 1,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
          Container(
            height: 32,
            width: 1,
            color: theme.dividerColor.withOpacity(0.12),
          ),
          IconButton(
            constraints: const BoxConstraints(),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            icon: const Icon(Broken.add, size: 20),
            tooltip: '新建标签页',
            onPressed: () {
              provider.addTab(provider.rootPath);
              // 自动滚动到新标签页
              WidgetsBinding.instance.addPostFrameCallback((_) {
                scrollController?.animateTo(
                  scrollController?.position.maxScrollExtent ?? 0,
                  duration: const Duration(milliseconds: 300),
                  curve: Curves.easeOut,
                );
              });
            },
          ),
          PopupMenuButton<String>(
            constraints: const BoxConstraints(),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            icon: const Icon(Broken.more, size: 20),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            position: PopupMenuPosition.under,
            onSelected: (value) {
              if (value == 'close_others') {
                provider.closeOtherTabs();
              } else if (value == 'duplicate') {
                provider.duplicateActiveTab();
              }
            },
            itemBuilder: (context) => [
              const PopupMenuItem(
                value: 'duplicate',
                child: Row(
                  children: [
                    Icon(Broken.copy, size: 18),
                    SizedBox(width: 10),
                    Text('复制标签页', style: TextStyle(fontWeight: FontWeight.w500)),
                  ],
                ),
              ),
              const PopupMenuItem(
                value: 'close_others',
                child: Row(
                  children: [
                    Icon(Broken.close_circle, size: 18),
                    SizedBox(width: 10),
                    Text('关闭其他标签页', style: TextStyle(fontWeight: FontWeight.w500)),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  void _showCloseTabSheet(BuildContext context, FileManagerProvider provider, int index) {
    final tab = provider.tabs[index];
    final canClose = provider.tabs.length > 1 && !tab.isPinned;
    final theme = Theme.of(context);

    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) {
        return Container(
          margin: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: theme.colorScheme.surface,
            borderRadius: BorderRadius.circular(20),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.15),
                blurRadius: 20,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: 8),
              Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: theme.dividerColor.withOpacity(0.3),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                child: Row(
                  children: [
                    Icon(
                      tab.isPinned ? Icons.push_pin_rounded : Broken.folder,
                      size: 18,
                      color: theme.colorScheme.primary,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        tab.currentPath == provider.rootPath ? '主目录' : p.basename(tab.currentPath),
                        style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold),
                        overflow: TextOverflow.ellipsis,
                        maxLines: 1,
                      ),
                    ),
                    Text(
                      '双击关闭标签页',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurface.withOpacity(0.4),
                        fontSize: 11,
                      ),
                    ),
                  ],
                ),
              ),
              if (canClose)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8, left: 12, right: 12),
                  child: SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      onPressed: () {
                        Navigator.pop(sheetContext);
                        provider.closeTab(index);
                      },
                      icon: const Icon(Broken.close_circle, size: 18),
                      label: const Text('关闭标签页', style: TextStyle(fontWeight: FontWeight.bold)),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.redAccent,
                        side: BorderSide(color: Colors.redAccent.withOpacity(0.3)),
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                      ),
                    ),
                  ),
                ),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
  }
}
