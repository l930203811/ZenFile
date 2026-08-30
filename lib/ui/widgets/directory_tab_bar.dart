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
            child: Listener(
              onPointerDown: (_) => provider.setTabBarInteracting(true),
              onPointerUp: (_) => provider.setTabBarInteracting(false),
              onPointerCancel: (_) => provider.setTabBarInteracting(false),
              child: ListView.builder(
              scrollDirection: Axis.horizontal,
              controller: scrollController,
              physics: const BouncingScrollPhysics(),
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              itemCount: tabs.length,
              itemBuilder: (context, index) {
                final tab = tabs[index];
                final isRoot = tab.currentPath == provider.rootPath;
                // 双窗口多标签：标签页栏同时承载两个 pane 的标签页。
                // 焦点 pane 的标签用主色高亮；另一 pane 的标签用次级高亮（secondary 边框），
                // 方便区分左右窗口当前各自显示的是哪个标签。
                final isSplitMulti = provider.isSplitMultiTabActive;
                final pane0 = provider.paneTabIndex(0);
                final pane1 = provider.paneTabIndex(1);
                final bool inFocusPane = isSplitMulti && index == activeIndex;
                final bool inOtherPane =
                    isSplitMulti && !inFocusPane && (index == pane0 || index == pane1);
                final isSelected =
                    isSplitMulti ? (inFocusPane || inOtherPane) : index == activeIndex;
                // 「激活态」统一判定：
                // - 双窗口多标签 → 焦点 pane 的标签（inFocusPane）；
                // - 单窗口 → index == activeIndex。
                // 此前单窗口下背景只按 inFocusPane 判定（恒为 false），
                // 导致激活标签只有文字高亮、背景无区分，这里一并修正。
                final bool isActiveTab = isSplitMulti ? inFocusPane : index == activeIndex;
                // 远程标签页固定显示“已保存的远程客户端名称”，方便区分是哪个远程客户端。
                // 单窗口与双窗口多标签模式都生效（此前双窗口多标签被排除，
                // 导致标题随打开的目录变化）。
                final bool useRemoteName =
                    tab.isRemote && tab.remoteConnection != null;
                final title = useRemoteName
                    ? tab.remoteConnection!.name
                    : (isRoot ? L10n.of(context).msgfefea1b3 : p.basename(tab.currentPath));

                return Container(
                  margin: const EdgeInsets.only(right: 4),
                  child: Material(
                    color: isActiveTab
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
                            color: isActiveTab
                                ? theme.colorScheme.primary.withOpacity(0.4)
                                : (inOtherPane
                                    ? theme.colorScheme.secondary.withOpacity(0.6)
                                    : theme.dividerColor.withOpacity(0.05)),
                            width: inOtherPane ? 1.6 : 1.2,
                          ),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            _buildTabIcon(
                              context: context,
                              isRemote: tab.isRemote,
                              isPinned: tab.isPinned,
                              isRoot: isRoot,
                              isSelected: isSelected,
                              size: 14,
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
          ),
          // 新建标签页按钮：点击直接在当前根目录新建标签页
          IconButton(
            constraints: const BoxConstraints(),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            icon: const Icon(Broken.add, size: 20),
            tooltip: L10n.of(context).msgb52d4a73,
            onPressed: () => provider.addTab(provider.rootPath),
          ),
          // 关闭所有标签页按钮：点击弹出多语言确认，确认后
          // 单窗口保留 1 个、双窗口新建 2 个本地根目录标签。
          IconButton(
            constraints: const BoxConstraints(),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            icon: const Icon(Broken.close_circle, size: 18),
            tooltip: L10n.of(context).ui_close_all_tabs,
            onPressed: () => _confirmCloseAllTabs(context, provider),
          ),
        ],
      ),
    );
  }

  /// 标签按钮左侧图标：
  /// - 远程标签 → 云图标（Broken.cloud），**直接替换**文件夹图标，方便一眼辨别远程/本地浏览页。
  /// - 钉住标签 → 图钉图标；根目录 → 房子图标；其余 → 文件夹图标。
  Widget _buildTabIcon({
    required BuildContext context,
    required bool isRemote,
    required bool isPinned,
    required bool isRoot,
    required bool isSelected,
    double size = 14,
  }) {
    final theme = Theme.of(context);
    final Color baseColor = isPinned
        ? Colors.orange
        : (isSelected
            ? theme.colorScheme.primary
            : theme.colorScheme.onSurface.withOpacity(0.6));
    if (isPinned) {
      return Icon(Icons.push_pin_rounded, size: size, color: baseColor);
    }
    // 远程浏览页标签：用云图标直接替换文件夹图标
    if (isRemote) {
      return Icon(Broken.cloud, size: size, color: baseColor);
    }
    final IconData base = isRoot ? Broken.home_1 : Broken.folder;
    return Icon(base, size: size, color: baseColor);
  }

  void _confirmCloseAllTabs(BuildContext context, FileManagerProvider provider) {
    final l10n = L10n.of(context);
    showDialog<void>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: Text(l10n.ui_close_all_tabs),
          content: Text(l10n.ui_close_all_tabs_message),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: Text(l10n.ui_cancel),
            ),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: Colors.redAccent,
                foregroundColor: Colors.white,
              ),
              onPressed: () {
                Navigator.pop(dialogContext);
                provider.closeAllTabs();
              },
              child: Text(l10n.ui_confirm),
            ),
          ],
        );
      },
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
                    _buildTabIcon(
                      context: context,
                      isRemote: tab.isRemote,
                      isPinned: tab.isPinned,
                      isRoot: tab.currentPath == provider.rootPath,
                      isSelected: true,
                      size: 18,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        (tab.isRemote && tab.remoteConnection != null)
                            ? tab.remoteConnection!.name
                            : (tab.currentPath == provider.rootPath
                                ? L10n.of(context).msgfefea1b3
                                : p.basename(tab.currentPath)),
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
