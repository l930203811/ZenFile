import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import '../../providers/file_manager_provider.dart';
import '../../core/icon_fonts/broken_icons.dart';
import 'package:zenfile/l10n/generated/app_localizations.dart';

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

    // 无背景色 Container —— 让标签页栏直接浮在 Scaffold 背景上，
    // 与上方 AppBar 视觉融合为一整块顶部区域（与分类页一致）。
    return SizedBox(
      height: 32,
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
                final title = isRoot ? L10n.of(context).msgfefea1b3 : p.basename(tab.currentPath);

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
          // 多标签页按钮：长按/点击从顶部弹出菜单（复制 / 新建 / 关闭标签页）
          IconButton(
            constraints: const BoxConstraints(),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            icon: const Icon(Broken.add, size: 20),
            tooltip: L10n.of(context).msg47b760ed,
            onPressed: () => _showTabActionsMenu(context, provider),
            onLongPress: () => _showTabActionsMenu(context, provider),
          ),
        ],
      ),
    );
  }

  /// 多标签页菜单：从顶部弹出，含 复制 / 新建 / 关闭标签页（关闭项右侧显示“双击关闭”提示）
  Future<void> _showTabActionsMenu(BuildContext context, FileManagerProvider provider) async {
    final RenderBox overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    final size = overlay.size;
    // 锚定在顶部右侧，菜单从顶部向下弹出
    final position = RelativeRect.fromLTRB(size.width - 8, 0, size.width, 0);
    final value = await showMenu<String>(
      context: context,
      position: position,
      items: [
        PopupMenuItem(
          value: 'copy',
          child: Row(children: [
            const Icon(Broken.copy, size: 20),
            const SizedBox(width: 12),
            Text(L10n.of(context).msg4e9c344a),
          ]),
        ),
        PopupMenuItem(
          value: 'new',
          child: Row(children: [
            const Icon(Broken.add, size: 20),
            const SizedBox(width: 12),
            Text(L10n.of(context).msgb52d4a73),
          ]),
        ),
        PopupMenuItem(
          value: 'close',
          child: Row(children: [
            const Icon(Broken.close_circle, size: 20),
            const SizedBox(width: 12),
            Text(L10n.of(context).ui_close_tab),
            const Spacer(),
            Text(
              L10n.of(context).msgd78603eb,
              style: TextStyle(fontSize: 11, color: Theme.of(context).colorScheme.onSurface.withOpacity(0.4)),
            ),
          ]),
        ),
      ],
    );
    if (value == 'copy') {
      provider.duplicateActiveTab();
    } else if (value == 'new') {
      provider.addTab(provider.rootPath);
    } else if (value == 'close') {
      if (provider.tabs.length > 1) provider.closeTab(provider.activeTabIndex);
    }
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
                        tab.currentPath == provider.rootPath ? L10n.of(context).msgfefea1b3 : p.basename(tab.currentPath),
                        style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold),
                        overflow: TextOverflow.ellipsis,
                        maxLines: 1,
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
                      label: Text(L10n.of(context).ui_close_tab, style: TextStyle(fontWeight: FontWeight.bold)),
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
