import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'dart:ui';
import 'package:provider/provider.dart';
import 'package:path/path.dart' as p;
import '../../providers/file_manager_provider.dart';
import '../../models/file_filter_type.dart';
import '../../models/drag_payload.dart';
import '../widgets/file_filter_bottom_sheet.dart';
import '../widgets/file_item.dart';
import '../widgets/folder_item.dart';
import '../widgets/file_grid_item.dart';
import '../widgets/folder_grid_item.dart';
import '../widgets/drag_drop_handler.dart';
import '../widgets/file_action_dialogs.dart';
import '../widgets/drag_drop_action_dialog.dart';
import '../widgets/create_archive_dialog.dart';
import '../widgets/batch_rename_dialog.dart';
import '../widgets/selection_action_bar.dart';
import '../widgets/selection_context_bottom_sheet.dart';
import '../widgets/file_operation_progress_dialog.dart';
import '../widgets/zenfile_drawer.dart';
import '../../core/icon_fonts/broken_icons.dart';
import 'global_search_screen.dart';
import 'internal_file_picker_screen.dart';
import '../widgets/restricted_folder_banner.dart';
import '../widgets/directory_tab_bar.dart';
import '../../services/pin_service.dart';
import '../../services/folder_share_service.dart';
import '../widgets/pane_browser.dart';
import '../../services/network_connections_service.dart';
import 'network_connection_wizard_screen.dart';


class DirectoryScreen extends StatefulWidget {
  final VoidCallback toggleTheme;
  final Function(int)? onNavigateTab;
  const DirectoryScreen({super.key, required this.toggleTheme, this.onNavigateTab});

  @override
  State<DirectoryScreen> createState() => _DirectoryScreenState();
}

class _DirectoryScreenState extends State<DirectoryScreen> {
  final ScrollController _scrollController = ScrollController();
  final ScrollController _breadcrumbController = ScrollController();
  final ScrollController _tabScrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<FileManagerProvider>().init();
    });
  }

  @override
  void dispose() {
    _scrollController.dispose();
    _breadcrumbController.dispose();
    _tabScrollController.dispose();
    super.dispose();
  }

  void _openFolder(FileManagerProvider provider, String path) {
    if (_scrollController.hasClients) {
      provider.saveScrollOffset(provider.currentPath, _scrollController.offset);
    }
    provider.loadDirectory(path).then((_) {
      if (_scrollController.hasClients) {
        final savedOffset = provider.getSavedScrollOffset(path);
        _scrollController.jumpTo(savedOffset);
      }
    });
  }

  /// 构建当前路径面包屑导航
  Widget _buildPathBreadcrumb(BuildContext context, FileManagerProvider provider) {
    final theme = Theme.of(context);
    final currentPath = provider.currentPath;
    final parts = currentPath.split('/').where((n) => n.isNotEmpty).toList();

    // 如果路径为根目录或太短，显示存储卷名称
    if (parts.isEmpty) {
      return GestureDetector(
        onTap: () => _showStorageVolumeModal(context, provider),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Broken.arrow_down_2, size: 16, color: theme.colorScheme.primary),
            const SizedBox(width: 6),
            Text(
              currentPath,
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15, color: theme.colorScheme.onSurface),
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      );
    }

    // 自动滚动到末尾
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_breadcrumbController.hasClients) {
        _breadcrumbController.animateTo(
          _breadcrumbController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });

    return SingleChildScrollView(
      controller: _breadcrumbController,
      scrollDirection: Axis.horizontal,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // 根目录图标（点击弹出存储卷选择）
          GestureDetector(
            onTap: () => _showStorageVolumeModal(context, provider),
            child: _buildBreadcrumbItem(
              context,
              theme,
              label: parts.isNotEmpty ? parts[0] : currentPath,
              isFirst: true,
              isLast: parts.length <= 1,
              onTap: parts.length <= 1 ? null : () {
                provider.loadDirectory('/${parts[0]}');
              },
              onLongPress: parts.length <= 1 ? null : () {
                Clipboard.setData(ClipboardData(text: '/${parts[0]}'));
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('已复制路径: /${parts[0]}'), behavior: SnackBarBehavior.floating, duration: const Duration(seconds: 2)),
                );
              },
            ),
          ),
          // 各级路径
          for (int i = 1; i < parts.length; i++)
            _buildBreadcrumbItem(
              context,
              theme,
              label: parts[i],
              isFirst: false,
              isLast: i == parts.length - 1,
              onTap: () {
                final targetPath = '/${parts.sublist(0, i + 1).join('/')}';
                if (targetPath != currentPath) {
                  provider.loadDirectory(targetPath);
                }
              },
              onLongPress: () {
                final fullPath = '/${parts.sublist(0, i + 1).join('/')}';
                Clipboard.setData(ClipboardData(text: fullPath));
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('已复制路径: $fullPath'), behavior: SnackBarBehavior.floating, duration: const Duration(seconds: 2)),
                );
              },
            ),
        ],
      ),
    );
  }

  /// 构建锥形箭头面包屑项
  Widget _buildBreadcrumbItem(
    BuildContext context,
    ThemeData theme, {
    required String label,
    required bool isFirst,
    required bool isLast,
    VoidCallback? onTap,
    VoidCallback? onLongPress,
  }) {
    final bgColor = isLast
        ? theme.colorScheme.primary.withOpacity(0.12)
        : theme.colorScheme.surfaceVariant.withOpacity(0.5);
    final textColor = isLast
        ? theme.colorScheme.primary
        : theme.colorScheme.onSurface.withOpacity(0.75);
    final fontWeight = isLast ? FontWeight.bold : FontWeight.w500;
    final arrowWidth = 6.0;

    return GestureDetector(
      onTap: onTap,
      onLongPress: onLongPress,
      child: ClipPath(
        clipper: _BreadcrumbClipper(
          hasLeftIndent: !isFirst,
          arrowWidth: arrowWidth,
        ),
        child: Container(
          height: 24,
          padding: EdgeInsets.only(
            left: isFirst ? 8 : 8 + arrowWidth,
            right: 8 + arrowWidth,
          ),
          decoration: BoxDecoration(
            color: bgColor,
            borderRadius: isFirst
                ? const BorderRadius.only(topLeft: Radius.circular(6), bottomLeft: Radius.circular(6))
                : null,
          ),
          alignment: Alignment.center,
          child: Text(
            label,
            style: TextStyle(fontSize: 12, fontWeight: fontWeight, color: textColor),
            overflow: TextOverflow.ellipsis,
            maxLines: 1,
          ),
        ),
      ),
    );
  }

  /// 构建顶部固定区域（标签页 + 路径面包屑）
  Widget _buildFixedTopArea(BuildContext context, FileManagerProvider provider) {
    final theme = Theme.of(context);
    return Container(
      color: theme.colorScheme.surface,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 第二行：标签页
          if (provider.enableMultipleTabs)
            DirectoryTabBar(provider: provider, scrollController: _tabScrollController),
          // 第三行：导航按钮 + 路径面包屑（受地址栏开关控制）
          if (provider.showAddressBar)
            Padding(
              padding: const EdgeInsets.fromLTRB(4.0, 0.0, 4.0, 1.0),
              child: Row(
                children: [
                  // 上一级按钮（路径栏左边）
                  IconButton(
                    icon: Icon(Broken.arrow_left_2, size: 16, color: provider.canGoBack ? theme.colorScheme.primary : theme.colorScheme.onSurface.withOpacity(0.3)),
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(minWidth: 28, minHeight: 24),
                    onPressed: provider.canGoBack
                        ? () => _goBack(provider)
                        : null,
                    tooltip: '上一级',
                  ),
                  // 路径面包屑
                  Expanded(child: _buildPathBreadcrumb(context, provider)),
                  // 下一级按钮（路径栏右边）
                  IconButton(
                    icon: Icon(Broken.arrow_right_3, size: 16, color: provider.canGoForward ? theme.colorScheme.primary : theme.colorScheme.onSurface.withOpacity(0.3)),
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(minWidth: 28, minHeight: 24),
                    onPressed: provider.canGoForward
                        ? () => provider.goForward()
                        : null,
                    tooltip: '下一级',
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  void _goBack(FileManagerProvider provider) async {
    if (_scrollController.hasClients) {
      provider.saveScrollOffset(provider.currentPath, _scrollController.offset);
    }
    final prevPath = p.posix.dirname(provider.currentPath);
    final handled = await provider.goBack();
    if (handled && _scrollController.hasClients) {
      final savedOffset = provider.getSavedScrollOffset(prevPath);
      _scrollController.jumpTo(savedOffset);
    }
  }

  void _handleAction(BuildContext context, String action, String path) async {
    final provider = context.read<FileManagerProvider>();
    switch (action) {
      case 'archive':
        final res = await CreateArchiveDialog.show(
          context,
          initialName: p.posix.basename(path),
          isMultiSelection: false,
        );
        if (res != null) {
          await provider.createArchive(
            archiveName: res.archiveName,
            format: res.format,
            compressionLevel: res.compressionLevel,
            password: res.password,
            splitSizeMB: res.splitSizeMB,
            deleteSource: res.deleteSource,
            separateArchives: res.separateArchives,
            targetPaths: [path],
            context: context,
          );
        }
        break;
      case 'extract':
        await provider.extractArchiveDirectly(context, path);
        break;
      case 'copy':
        provider.copyFile(path);
        // ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('已复制到剪贴板')));
        break;
      case 'cut':
        provider.cutFile(path);
        // ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('已剪切到剪贴板')));
        break;
      case 'rename':
        final isMulti = provider.selectedPaths.isNotEmpty && provider.selectedPaths.contains(path);
        if (isMulti && provider.selectedPaths.length > 1) {
          await BatchRenameDialog.show(context, provider);
        } else {
          final currentName = p.posix.basename(path);
          final newName = await FileActionDialogs.showTextInputDialog(
            context,
            title: '重命名',
            hint: '输入新名称',
            initialValue: currentName,
            actionText: '重命名',
          );
          if (newName != null && newName.isNotEmpty) {
            await provider.renameFile(path, newName);
            if (isMulti) {
              provider.clearSelection();
            }
          }
        }
        break;
      case 'delete':
        final isMulti = provider.selectedPaths.isNotEmpty && provider.selectedPaths.contains(path);
        final confirm = await FileActionDialogs.showConfirmDialog(
          context,
          title: isMulti ? '删除选中' : '删除项目',
          content: isMulti
              ? '确定要删除 ${provider.selectedPaths.length} 个项目吗？此操作无法撤销。'
              : '确定要删除此项目吗？此操作无法撤销。',
        );
        if (confirm) {
          if (isMulti) {
            await provider.deleteSelected();
          } else {
            await provider.deleteFile(path);
          }
        }
        break;
      case 'share':
        final paths = (provider.selectedPaths.isNotEmpty && provider.selectedPaths.contains(path))
            ? provider.selectedPaths.toList()
            : [path];
        await FolderShareService.sharePaths(context, paths);
        break;
      case 'pin':
        await provider.togglePinPath(path);
        break;
    }
  }

  void _handleMenuAction(BuildContext context, String action, FileManagerProvider provider) async {
    switch (action) {
      case 'file':
        final fileName = await FileActionDialogs.showTextInputDialog(
          context,
          title: '新建文件',
          hint: '文件名',
          actionText: '创建',
        );
        if (fileName != null && fileName.isNotEmpty) {
          final createdName = await provider.createFile(fileName);
          if (createdName != null && createdName != fileName && context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('"$fileName" 已存在，已创建 "$createdName"。'),
                behavior: SnackBarBehavior.floating,
              ),
            );
          }
        }
        break;
      case 'folder':
        final folderName = await FileActionDialogs.showTextInputDialog(
          context,
          title: '新建文件夹',
          hint: '文件夹名称',
          actionText: '创建',
        );
        if (folderName != null && folderName.isNotEmpty) {
          final createdName = await provider.createFolder(folderName);
          if (createdName != null && createdName != folderName && context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('"$folderName" 已存在，已创建 "$createdName"。'),
                behavior: SnackBarBehavior.floating,
              ),
            );
          }
        }
        break;
      case 'archive':
        final currentFolderName = p.posix.basename(provider.currentPath);
        final res = await CreateArchiveDialog.show(
          context,
          initialName: currentFolderName.isEmpty ? 'archive' : currentFolderName,
          isMultiSelection: false,
        );
        if (res != null) {
          await provider.createArchive(
            archiveName: res.archiveName,
            format: res.format,
            compressionLevel: res.compressionLevel,
            password: res.password,
            splitSizeMB: res.splitSizeMB,
            deleteSource: res.deleteSource,
            separateArchives: res.separateArchives,
            targetPaths: [provider.currentPath],
            context: context,
          );
        }
        break;
    }
  }

  void _showAddBottomSheet(BuildContext context, FileManagerProvider provider) {
    final theme = Theme.of(context);
    showModalBottomSheet(
      context: context,
      backgroundColor: theme.scaffoldBackgroundColor,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.only(topLeft: Radius.circular(28), topRight: Radius.circular(28)),
      ),
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 16.0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 40,
                height: 4,
                margin: const EdgeInsets.only(bottom: 16),
                decoration: BoxDecoration(color: Colors.grey.withOpacity(0.3), borderRadius: BorderRadius.circular(2)),
              ),
              ListTile(
                contentPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 4),
                leading: Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(color: theme.colorScheme.primary.withOpacity(0.1), borderRadius: BorderRadius.circular(12)),
                  child: Icon(Broken.folder_add, color: theme.colorScheme.primary, size: 24),
                ),
                title: const Text('新建文件夹', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 16)),
                subtitle: Text('创建新目录', style: TextStyle(fontSize: 12, color: theme.colorScheme.onSurface.withOpacity(0.6))),
                onTap: () {
                  Navigator.pop(context);
                  _handleMenuAction(context, 'folder', provider);
                },
              ),
              ListTile(
                contentPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 4),
                leading: Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(color: theme.colorScheme.primary.withOpacity(0.1), borderRadius: BorderRadius.circular(12)),
                  child: Icon(Broken.document_1, color: theme.colorScheme.primary, size: 24),
                ),
                title: const Text('新建文件', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 16)),
                subtitle: Text('创建新的空白文本文档', style: TextStyle(fontSize: 12, color: theme.colorScheme.onSurface.withOpacity(0.6))),
                onTap: () {
                  Navigator.pop(context);
                  _handleMenuAction(context, 'file', provider);
                },
              ),
              ListTile(
                contentPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 4),
                leading: Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(color: theme.colorScheme.primary.withOpacity(0.1), borderRadius: BorderRadius.circular(12)),
                  child: Icon(Broken.box_add, color: theme.colorScheme.primary, size: 24),
                ),
                title: const Text('新建压缩包', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 16)),
                subtitle: Text('压缩当前文件夹内容', style: TextStyle(fontSize: 12, color: theme.colorScheme.onSurface.withOpacity(0.6))),
                onTap: () {
                  Navigator.pop(context);
                  _handleMenuAction(context, 'archive', provider);
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showSortModal(BuildContext context, FileManagerProvider provider) {
    final theme = Theme.of(context);
    bool isAppearanceExpanded = false;
    showModalBottomSheet(
      context: context,
      backgroundColor: theme.colorScheme.surface,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(28))),
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setStateModal) {
            return SafeArea(
              child: SingleChildScrollView(
                physics: const BouncingScrollPhysics(),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text('查看和排序选项', style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold)),
                        IconButton(icon: const Icon(Broken.close_circle), onPressed: () => Navigator.pop(context)),
                      ],
                    ),
                    const SizedBox(height: 16),
                    Text('布局模式', style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: InkWell(
                            onTap: () {
                              provider.setGridView(false);
                              setStateModal(() {});
                            },
                            borderRadius: BorderRadius.circular(16),
                            child: Container(
                              padding: const EdgeInsets.symmetric(vertical: 12),
                              decoration: BoxDecoration(
                                color: !provider.isGridView ? theme.colorScheme.primary : theme.colorScheme.surfaceVariant,
                                borderRadius: BorderRadius.circular(16),
                              ),
                              child: Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Icon(Broken.row_vertical, color: !provider.isGridView ? theme.colorScheme.onPrimary : theme.colorScheme.onSurface),
                                  const SizedBox(width: 8),
                                  Text('列表视图', style: TextStyle(fontWeight: FontWeight.bold, color: !provider.isGridView ? theme.colorScheme.onPrimary : theme.colorScheme.onSurface)),
                                ],
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 16),
                        Expanded(
                          child: InkWell(
                            onTap: () {
                              provider.setGridView(true);
                              setStateModal(() {});
                            },
                            borderRadius: BorderRadius.circular(16),
                            child: Container(
                              padding: const EdgeInsets.symmetric(vertical: 12),
                              decoration: BoxDecoration(
                                color: provider.isGridView ? theme.colorScheme.primary : theme.colorScheme.surfaceVariant,
                                borderRadius: BorderRadius.circular(16),
                              ),
                              child: Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Icon(Broken.element_3, color: provider.isGridView ? theme.colorScheme.onPrimary : theme.colorScheme.onSurface),
                                  const SizedBox(width: 8),
                                  Text('网格视图', style: TextStyle(fontWeight: FontWeight.bold, color: provider.isGridView ? theme.colorScheme.onPrimary : theme.colorScheme.onSurface)),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 20),
                    Theme(
                      data: theme.copyWith(dividerColor: Colors.transparent),
                      child: Container(
                        decoration: BoxDecoration(
                          color: theme.colorScheme.surfaceVariant.withOpacity(0.5),
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(color: theme.dividerColor.withOpacity(0.1)),
                        ),
                        child: ExpansionTile(
                          initiallyExpanded: isAppearanceExpanded,
                          onExpansionChanged: (exp) {
                            isAppearanceExpanded = exp;
                          },
                          leading: Icon(Broken.setting_2, color: theme.colorScheme.primary),
                          title: Text('大小和间距选项', style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
                          childrenPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                          children: [
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Text('图标和文件夹大小', style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600)),
                                Text('${(provider.iconScale * 100).round()}%', style: TextStyle(fontWeight: FontWeight.bold, color: theme.colorScheme.primary)),
                              ],
                            ),
                            Slider(
                              value: provider.iconScale,
                              min: 0.7,
                              max: 1.5,
                              divisions: 8,
                              activeColor: theme.colorScheme.primary,
                              onChanged: (val) {
                                provider.setIconScale(val);
                                setStateModal(() {});
                              },
                            ),
                            const SizedBox(height: 12),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Text('大小和间距', style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600)),
                                Text('${(provider.itemPaddingMultiplier * 100).round()}%', style: TextStyle(fontWeight: FontWeight.bold, color: theme.colorScheme.primary)),
                              ],
                            ),
                            Slider(
                              value: provider.itemPaddingMultiplier,
                              min: 0.4,
                              max: 2.0,
                              divisions: 16,
                              activeColor: theme.colorScheme.primary,
                              onChanged: (val) {
                                provider.setItemPaddingMultiplier(val);
                                setStateModal(() {});
                              },
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    Text('排序方式', style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        _buildSortChip(context, provider, setStateModal, '名称 (A-Z)', FileSortType.nameAsc),
                        _buildSortChip(context, provider, setStateModal, '名称 (Z-A)', FileSortType.nameDesc),
                        _buildSortChip(context, provider, setStateModal, '最新', FileSortType.dateNewest),
                        _buildSortChip(context, provider, setStateModal, '最旧', FileSortType.dateOldest),
                        _buildSortChip(context, provider, setStateModal, '大小（大）', FileSortType.sizeLargest),
                        _buildSortChip(context, provider, setStateModal, '大小（小）', FileSortType.sizeSmallest),
                        _buildSortChip(context, provider, setStateModal, '类型', FileSortType.type),
                      ],
                    ),
                    const SizedBox(height: 20),
                    Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: provider.isFolderOverrideEnabled(provider.currentPath)
                            ? theme.colorScheme.primary.withOpacity(0.08)
                            : theme.colorScheme.surfaceVariant.withOpacity(0.4),
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(
                          color: provider.isFolderOverrideEnabled(provider.currentPath)
                              ? theme.colorScheme.primary.withOpacity(0.25)
                              : theme.dividerColor.withOpacity(0.08),
                          width: 1.5,
                        ),
                      ),
                      child: Row(
                        children: [
                          Icon(
                            Broken.folder_favorite,
                            color: provider.isFolderOverrideEnabled(provider.currentPath)
                                ? theme.colorScheme.primary
                                : theme.colorScheme.onSurface.withOpacity(0.65),
                            size: 24,
                          ),
                          const SizedBox(width: 14),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  '仅此文件夹',
                                  style: theme.textTheme.titleMedium?.copyWith(
                                    fontWeight: FontWeight.bold,
                                    fontSize: 15,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  '启用此文件夹的自定义排序',
                                  style: theme.textTheme.bodySmall?.copyWith(
                                    color: theme.colorScheme.onSurface.withOpacity(0.55),
                                    fontSize: 11,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          Switch.adaptive(
                            value: provider.isFolderOverrideEnabled(provider.currentPath),
                            activeColor: theme.colorScheme.primary,
                            onChanged: (val) {
                              provider.setFolderOverrideEnabled(provider.currentPath, val);
                              setStateModal(() {});
                            },
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      );
    },
  );
}

  Widget _buildSortChip(BuildContext context, FileManagerProvider provider, StateSetter setStateModal, String label, FileSortType sortType) {
    final theme = Theme.of(context);
    final activeSort = provider.getSortTypeForPath(provider.currentPath);
    final isSelected = activeSort == sortType;
    return ActionChip(
      label: Text(label, style: TextStyle(fontWeight: FontWeight.bold, color: isSelected ? theme.colorScheme.onPrimary : theme.colorScheme.onSurface)),
      backgroundColor: isSelected ? theme.colorScheme.primary : theme.colorScheme.surfaceVariant,
      onPressed: () {
        provider.setSortType(sortType);
        if (sortType == FileSortType.type) {
          Navigator.pop(context); // Close the sort sheet
          FileFilterBottomSheet.show(context); // Open filter sheet
        } else {
          setStateModal(() {});
        }
      },
    );
  }

  void _showStorageVolumeModal(BuildContext context, FileManagerProvider provider) {
    final theme = Theme.of(context);
    showModalBottomSheet(
      context: context,
      backgroundColor: theme.scaffoldBackgroundColor,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (ctx) {
        final connections = NetworkConnectionsService.getConnections();
        return SafeArea(
          child: SingleChildScrollView(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Center(
                    child: Container(width: 40, height: 4, decoration: BoxDecoration(color: Colors.grey.withOpacity(0.3), borderRadius: BorderRadius.circular(2))),
                  ),
                  const SizedBox(height: 16),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12.0),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Expanded(
                          child: Text(
                            '存储卷',
                            style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        TextButton.icon(
                          style: TextButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4)),
                          icon: const Icon(Broken.folder_add, size: 18),
                          label: const Text('添加快捷方式', style: TextStyle(fontSize: 14)),
                          onPressed: () async {
                            Navigator.pop(ctx);
                            final picked = await InternalFilePickerScreen.show(
                              context,
                              rootPath: provider.storageVolumes.isNotEmpty ? provider.storageVolumes.first.path : '/storage/emulated/0',
                              pickDirectory: true,
                            );
                            if (picked != null && picked.isNotEmpty) {
                              for (final path in picked) {
                                final label = p.posix.basename(path).isEmpty ? path : p.posix.basename(path);
                                provider.addPinnedFolderShortcut(path, label);
                              }
                            }
                          },
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                  ...provider.storageVolumes.map((vol) {
                    final isSelected = provider.rootPath == vol.path;
                    return ListTile(
                      leading: Container(
                        width: 42,
                        height: 42,
                        decoration: BoxDecoration(
                          color: isSelected ? theme.colorScheme.primary.withOpacity(0.2) : theme.colorScheme.surfaceVariant,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Icon(vol.isInternal ? Broken.folder_open : Icons.sd_storage_rounded, color: isSelected ? theme.colorScheme.primary : theme.colorScheme.onSurface, size: 24),
                      ),
                      title: Text(vol.name, style: TextStyle(fontWeight: isSelected ? FontWeight.bold : FontWeight.w600, fontSize: 16)),
                      subtitle: Text(vol.path, style: TextStyle(fontSize: 12, color: theme.colorScheme.onSurface.withOpacity(0.6))),
                      trailing: isSelected ? Icon(Icons.check_circle, color: theme.colorScheme.primary) : null,
                      onTap: () {
                        Navigator.pop(ctx);
                        provider.setRootPath(vol.path);
                        provider.loadDirectory(vol.path);
                      },
                    );
                  }),
                  ListTile(
                    leading: Container(
                      width: 42,
                      height: 42,
                      decoration: BoxDecoration(
                        color: provider.rootPath == '/' ? theme.colorScheme.primary.withOpacity(0.2) : theme.colorScheme.surfaceVariant,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Icon(Broken.cpu, color: provider.rootPath == '/' ? theme.colorScheme.primary : theme.colorScheme.onSurface, size: 24),
                    ),
                    title: Text('系统根目录', style: TextStyle(fontWeight: provider.rootPath == '/' ? FontWeight.bold : FontWeight.w600, fontSize: 16)),
                    subtitle: Text('/', style: TextStyle(fontSize: 12, color: theme.colorScheme.onSurface.withOpacity(0.6))),
                    trailing: provider.rootPath == '/' ? Icon(Icons.check_circle, color: theme.colorScheme.primary) : null,
                    onTap: () {
                      Navigator.pop(ctx);
                      provider.setRootPath('/');
                      provider.loadDirectory('/');
                    },
                  ),
                  ...provider.pinnedFolderShortcuts.map((item) {
                    final isSelected = provider.rootPath == item.path || provider.currentPath == item.path;
                    return ListTile(
                      leading: Container(
                        width: 42,
                        height: 42,
                        decoration: BoxDecoration(
                          color: isSelected ? theme.colorScheme.primary.withOpacity(0.2) : theme.colorScheme.surfaceVariant,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Icon(Broken.folder_favorite, color: isSelected ? theme.colorScheme.primary : theme.colorScheme.onSurface, size: 24),
                      ),
                      title: Text(item.label, style: TextStyle(fontWeight: isSelected ? FontWeight.bold : FontWeight.w600, fontSize: 16)),
                      subtitle: Text(item.path, style: TextStyle(fontSize: 12, color: theme.colorScheme.onSurface.withOpacity(0.6))),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (isSelected) ...[
                            Icon(Icons.check_circle, color: theme.colorScheme.primary),
                            const SizedBox(width: 8),
                          ],
                          IconButton(
                            icon: const Icon(Broken.trash, size: 20, color: Colors.redAccent),
                            onPressed: () {
                              provider.removePinnedFolderShortcut(item.id);
                              Navigator.pop(ctx);
                              _showStorageVolumeModal(context, provider);
                            },
                          ),
                        ],
                      ),
                      onTap: () {
                        Navigator.pop(ctx);
                        provider.setRootPath(item.path);
                        provider.loadDirectory(item.path);
                      },
                    );
                  }),

                  // Network Connections Section
                  if (connections.isNotEmpty) ...[
                    const SizedBox(height: 24),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12.0, vertical: 4.0),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            '网络连接',
                            style: theme.textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.bold,
                              color: theme.colorScheme.primary,
                              fontFamily: 'LexendDeca',
                            ),
                          ),
                          IconButton(
                            icon: const Icon(Icons.add_link_rounded, size: 20),
                            tooltip: '添加网络连接',
                            onPressed: () async {
                              Navigator.pop(ctx);
                              final added = await Navigator.push(
                                context,
                                MaterialPageRoute(
                                  builder: (_) => const NetworkConnectionWizardScreen(),
                                ),
                              );
                              if (added == true) {
                                _showStorageVolumeModal(context, provider);
                              }
                            },
                          ),
                        ],
                      ),
                    ),
                    const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 12.0),
                      child: Divider(height: 8, thickness: 1),
                    ),
                    ...connections.map((conn) {
                      IconData iconData;
                      switch (conn.type) {
                        case 'Google Drive':
                          iconData = Icons.cloud_circle_rounded;
                          break;
                        case 'Dropbox':
                          iconData = Icons.folder_shared_rounded;
                          break;
                        case 'OneDrive':
                          iconData = Icons.cloud_queue_rounded;
                          break;
                        case 'Box':
                          iconData = Icons.all_inbox_rounded;
                          break;
                        case '局域网/SMB':
                          iconData = Icons.dns_rounded;
                          break;
                        case 'FTP':
                          iconData = Icons.swap_horizontal_circle_rounded;
                          break;
                        case 'SFTP':
                          iconData = Icons.vpn_lock_rounded;
                          break;
                        case 'WebDav':
                          iconData = Icons.web_rounded;
                          break;
                        default:
                          iconData = Broken.wifi;
                      }
                      return ListTile(
                        leading: Container(
                          width: 42,
                          height: 42,
                          decoration: BoxDecoration(
                            color: theme.colorScheme.primary.withOpacity(0.12),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Icon(iconData, color: theme.colorScheme.primary, size: 22),
                        ),
                        title: Text(conn.name, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 16)),
                        subtitle: Text('${conn.type} • ${conn.host}', style: TextStyle(fontSize: 12, color: theme.colorScheme.onSurface.withOpacity(0.6))),
                        trailing: IconButton(
                          icon: const Icon(Broken.trash, size: 20, color: Colors.redAccent),
                          tooltip: '移除连接',
                          onPressed: () async {
                            await NetworkConnectionsService.deleteConnection(conn.id);
                            Navigator.pop(ctx);
                            _showStorageVolumeModal(context, provider);
                          },
                        ),
                        onTap: () async {
                          Navigator.pop(ctx);
                          // 使用 DirectoryScreen 统一界面打开远程连接
                          final provider = context.read<FileManagerProvider>();
                          final client = FileManagerProvider.createRemoteClient(conn);
                          try {
                            await client.connect();
                            if (context.mounted) {
                              provider.openRemoteTab(client, conn);
                            }
                          } catch (e) {
                            if (context.mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(content: Text('连接失败：$e'), backgroundColor: Colors.redAccent),
                              );
                            }
                          }
                        },
                      );
                    }),
                  ],
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<FileManagerProvider>(
      builder: (context, provider, child) {
        final theme = Theme.of(context);
        final isSelectionMode = provider.isSelectionMode;

        if (provider.shouldScrollToHighlight) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (_scrollController.hasClients) {
              provider.resetScrollToHighlight();
              final firstHighlightedIndex = provider.currentFiles.indexWhere(
                (f) => provider.highlightedPaths.contains(f.path),
              );
              if (firstHighlightedIndex != -1) {
                double targetOffset = 0.0;
                if (provider.isGridView) {
                  final crossAxisCount = (MediaQuery.of(context).size.width / (110 * provider.iconScale)).floor().clamp(2, 6);
                  final row = firstHighlightedIndex ~/ crossAxisCount;
                  final itemHeight = (150 * provider.iconScale * provider.itemPaddingMultiplier).clamp(100.0, 300.0);
                  targetOffset = row * itemHeight;
                } else {
                  final itemHeight = (72 * provider.itemPaddingMultiplier).clamp(40.0, 150.0);
                  targetOffset = firstHighlightedIndex * itemHeight;
                }
                // 滚动到屏幕中间
                final screenHeight = _scrollController.position.viewportDimension;
                final clampedOffset = targetOffset.clamp(0.0, _scrollController.position.maxScrollExtent);
                final centerOffset = (clampedOffset - screenHeight / 3).clamp(0.0, _scrollController.position.maxScrollExtent);
                _scrollController.jumpTo(centerOffset);
              }
            }
          });
        }

        return PopScope(
          canPop: false,
          onPopInvoked: (didPop) {
            if (didPop) return;
            if (isSelectionMode) {
              provider.clearSelection();
            } else if (provider.canGoBack) {
              _goBack(provider);
            } else {
              // 根目录且无选中状态，允许退出当前页面
              Navigator.of(context).maybePop();
            }
          },
          child: Scaffold(
            drawer: ZenFileDrawer(
              toggleTheme: widget.toggleTheme,
              onNavigateTab: widget.onNavigateTab,
            ),
            appBar: AppBar(
              titleSpacing: 0,
              centerTitle: false,
              actionsPadding: const EdgeInsets.only(right: 4),
              leadingWidth: isSelectionMode ? 56 : 160,
              title: isSelectionMode
                  ? const SizedBox.shrink()
                  : const SizedBox.shrink(),
              leading: isSelectionMode
                  ? IconButton(
                      icon: const Icon(Broken.close_square),
                      onPressed: () => provider.clearSelection(),
                    )
                  : Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Builder(
                          builder: (context) => IconButton(
                            icon: Icon(Broken.sidebar_left, color: theme.colorScheme.primary),
                            onPressed: () => Scaffold.of(context).openDrawer(),
                          ),
                        ),
                        IconButton(
                          icon: Icon(Broken.category, color: theme.colorScheme.primary),
                          tooltip: '首页分类',
                          onPressed: () {
                            widget.onNavigateTab?.call(0);
                          },
                        ),
                        IconButton(
                          icon: Icon(Broken.folder, color: theme.colorScheme.primary),
                          tooltip: '浏览',
                          onPressed: () {
                            // 已在浏览页，无需切换
                          },
                        ),
                      ],
                    ),
              actions: isSelectionMode
                  ? provider.showBottomActionBar
                      ? [
                          IconButton(
                            icon: const Icon(Broken.tick_square),
                            tooltip: '全选',
                            onPressed: () => provider.selectAll(),
                          ),
                        ]
                      : [
                          IconButton(
                            icon: const Icon(Broken.tick_square),
                            tooltip: '全选',
                            onPressed: () => provider.selectAll(),
                          ),
                        ]
                  : provider.showBottomActionBar
                      ? [
                          PopupMenuButton<String>(
                            icon: const Icon(Broken.add_square, size: 26),
                            tooltip: '新建',
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                            position: PopupMenuPosition.under,
                            elevation: 8,
                            onSelected: (val) => _handleMenuAction(context, val, provider),
                            itemBuilder: (context) => [
                              const PopupMenuItem(value: 'file', child: Row(children: [Icon(Broken.document, size: 20), SizedBox(width: 12), Text('新建文件', style: TextStyle(fontWeight: FontWeight.w600))])),
                              const PopupMenuItem(value: 'folder', child: Row(children: [Icon(Broken.folder, size: 20), SizedBox(width: 12), Text('新建文件夹', style: TextStyle(fontWeight: FontWeight.w600))])),
                              const PopupMenuItem(value: 'archive', child: Row(children: [Icon(Broken.archive, size: 20), SizedBox(width: 12), Text('新建压缩包', style: TextStyle(fontWeight: FontWeight.w600))])),
                            ],
                          ),
                        ]
                      : [
                          IconButton(
                            icon: Icon(Broken.search_normal, color: theme.colorScheme.primary),
                            onPressed: () {
                              Navigator.push(context, MaterialPageRoute(builder: (_) => GlobalSearchScreen(searchFolderPath: provider.currentPath)));
                            },
                          ),
                          IconButton(
                            icon: Icon(Broken.filter_edit, color: theme.colorScheme.primary),
                            tooltip: '查看和排序选项',
                            onPressed: () => _showSortModal(context, provider),
                          ),
                          PopupMenuButton<String>(
                            icon: Icon(Broken.add_square, size: 26, color: theme.colorScheme.primary),
                            tooltip: '新建',
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                            position: PopupMenuPosition.under,
                            elevation: 8,
                            onSelected: (val) => _handleMenuAction(context, val, provider),
                            itemBuilder: (context) => [
                              const PopupMenuItem(value: 'file', child: Row(children: [Icon(Broken.document, size: 20), SizedBox(width: 12), Text('新建文件', style: TextStyle(fontWeight: FontWeight.w600))])),
                              const PopupMenuItem(value: 'folder', child: Row(children: [Icon(Broken.folder, size: 20), SizedBox(width: 12), Text('新建文件夹', style: TextStyle(fontWeight: FontWeight.w600))])),
                              const PopupMenuItem(value: 'archive', child: Row(children: [Icon(Broken.archive, size: 20), SizedBox(width: 12), Text('新建压缩包', style: TextStyle(fontWeight: FontWeight.w600))])),
                            ],
                          ),
                        ],
            ),
            body: Column(
              children: [
                // 顶部固定区域
                if (!isSelectionMode) _buildFixedTopArea(context, provider),
                if (provider.filterType != FileFilterType.all)
                  _buildActiveFilterBanner(context, provider),
                if (provider.isLoading && provider.currentFiles.isNotEmpty)
                  LinearProgressIndicator(
                    minHeight: 2.5,
                    backgroundColor: theme.colorScheme.primary.withOpacity(0.1),
                    valueColor: AlwaysStoppedAnimation<Color>(theme.colorScheme.primary),
                  ),
                Expanded(
                  child: DragTarget<DragPayload>(
                    onWillAccept: (data) {
                      if (data == null || data.paths.isEmpty) return false;
                      final sourceParent = p.posix.dirname(data.paths.first);
                      if (sourceParent == provider.currentPath) return false;
                      if (data.paths.any((x) => provider.currentPath == x || provider.currentPath.startsWith(x + p.posix.separator))) return false;
                      return true;
                    },
                    onAccept: (data) {
                      if (provider.showDragDropDialog) {
                        DragDropActionDialog.show(
                          context: context,
                          sourcePaths: data.paths,
                          initialTargetPath: provider.currentPath,
                        );
                      } else {
                        for (final path in data.paths) {
                          provider.moveItem(context, path, provider.currentPath);
                        }
                      }
                    },
                    builder: (context, candidateData, rejectedData) {
                      return GestureDetector(
                    onHorizontalDragEnd: (details) {
                      if (!provider.enableMultipleTabs || provider.enableSplitScreen || isSelectionMode) {
                        return;
                      }
                      final velocity = details.primaryVelocity ?? 0.0;
                      // Swipe Left (moves right-to-left) -> Next Tab
                      if (velocity < -300) {
                        if (provider.activeTabIndex < provider.tabs.length - 1) {
                          provider.setActiveTab(provider.activeTabIndex + 1);
                        } else if (provider.activeTabIndex == provider.tabs.length - 1) {
                          provider.addTab(provider.rootPath);
                        }
                      }
                      // Swipe Right (moves left-to-right) -> Previous Tab
                      else if (velocity > 300) {
                        if (provider.activeTabIndex > 0) {
                          provider.setActiveTab(provider.activeTabIndex - 1);
                        }
                      }
                    },
                    behavior: HitTestBehavior.translucent,
                    child: provider.enableSplitScreen
                      ? const Row(
                          children: [
                            Expanded(child: PaneBrowser(tabIndex: 0)),
                            Expanded(child: PaneBrowser(tabIndex: 1)),
                          ],
                        )
                      : (provider.isLoading && provider.currentFiles.isEmpty)
                          ? const Center(child: CircularProgressIndicator())
                          : provider.needsPermission
                              ? RestrictedFolderBanner(
                                  onEnableRoot: () => provider.enableRootMode(),
                                  onEnableShizuku: () => provider.enableShizukuMode(),
                                  onGoBack: provider.canGoBack ? () => _goBack(provider) : null,
                                  isRootAvailable: provider.isRootAvailable,
                                )
                              : Stack(
                                  children: [
                                    CustomScrollView(
                                      controller: _scrollController,
                                      physics: const BouncingScrollPhysics(parent: AlwaysScrollableScrollPhysics()),
                                      slivers: [
                      CupertinoSliverRefreshControl(
                        onRefresh: () => provider.loadDirectory(provider.currentPath, showLoading: false, clearCache: true),
                      ),
                      if (!isSelectionMode && provider.showFolderFileCount)
                        SliverToBoxAdapter(
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
                            decoration: BoxDecoration(
                              color: Theme.of(context).colorScheme.surfaceVariant.withOpacity(0.4),
                              border: Border(bottom: BorderSide(color: Theme.of(context).colorScheme.outline.withOpacity(0.1))),
                            ),
                            child: Row(
                              children: [
                                Icon(Broken.folder, size: 16, color: Theme.of(context).colorScheme.onSurface.withOpacity(0.7)),
                                const SizedBox(width: 6),
                                Text('文件夹：${provider.currentFiles.where((e) => e.isDirectory).length}', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Theme.of(context).colorScheme.onSurface.withOpacity(0.8))),
                                const SizedBox(width: 20),
                                Icon(Broken.document, size: 16, color: Theme.of(context).colorScheme.onSurface.withOpacity(0.7)),
                                const SizedBox(width: 6),
                                Text('文件：${provider.currentFiles.where((e) => !e.isDirectory).length}', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Theme.of(context).colorScheme.onSurface.withOpacity(0.8))),
                              ],
                            ),
                          ),
                        ),
                      if (provider.currentFiles.isEmpty)
                        SliverFillRemaining(
                          hasScrollBody: false,
                          child: Center(
                            child: Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Container(
                                    padding: const EdgeInsets.all(24),
                                    decoration: BoxDecoration(
                                      color: Theme.of(context).colorScheme.primary.withOpacity(0.08),
                                      shape: BoxShape.circle,
                                    ),
                                    child: Icon(
                                      Broken.folder_open,
                                      size: 72,
                                      color: Theme.of(context).colorScheme.primary.withOpacity(0.6),
                                    ),
                                  ),
                                  const SizedBox(height: 24),
                                  Text(
                                    '空文件夹',
                                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                                          fontWeight: FontWeight.bold,
                                          color: Theme.of(context).colorScheme.onSurface,
                                        ),
                                  ),
                                  const SizedBox(height: 8),
                                  Text(
                                    '此目录不包含任何文件或子文件夹。',
                                    textAlign: TextAlign.center,
                                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                                          color: Theme.of(context).colorScheme.onSurface.withOpacity(0.55),
                                        ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        )
                      else
                        SliverPadding(
                          padding: EdgeInsets.only(
                            bottom: 80,
                            left: provider.isGridView ? 16 : 0,
                            right: provider.isGridView ? 16 : 0,
                            top: 8,
                          ),
                          sliver: provider.isGridView
                              ? SliverGrid(
                                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                                    crossAxisCount: (MediaQuery.of(context).size.width / (110 * provider.iconScale)).floor().clamp(2, 6),
                                    mainAxisSpacing: (12 * provider.itemPaddingMultiplier).clamp(4.0, 24.0),
                                    crossAxisSpacing: (12 * provider.itemPaddingMultiplier).clamp(4.0, 24.0),
                                    childAspectRatio: 0.75,
                                  ),
                                  delegate: SliverChildBuilderDelegate(
                                    (context, index) {
                                      final item = provider.currentFiles[index];
                                      final isSelected = provider.selectedPaths.contains(item.path);
                                      if (item.isDirectory) {
                                        final itemLongPress = () {
                                          if (isSelectionMode && isSelected) {
                                            SelectionContextBottomSheet.show(context, provider, item.path);
                                          } else {
                                            provider.toggleSelection(item.path);
                                          }
                                        };
                                        return DragDropHandler(
                                          path: item.path,
                                          isDirectory: true,
                                          onLongPress: itemLongPress,
                                          isRemote: item.isRemote,
                                          remoteItems: item.remoteSource != null ? [item.remoteSource!] : null,
                                          child: FolderGridItem(
                                            folder: item,
                                            isSelected: isSelected,
                                            iconScale: provider.iconScale,
                                            itemPaddingMultiplier: provider.itemPaddingMultiplier,
                                            onTap: () {
                                              if (isSelectionMode) {
                                                provider.toggleSelection(item.path);
                                              } else {
                                                _openFolder(provider, item.path);
                                              }
                                            },
                                            onLongPress: provider.enableDragDrop ? null : itemLongPress,
                                            onIconTap: itemLongPress,
                                            onAction: (action) => _handleAction(context, action, item.path),
                                          ),
                                        );
                                      } else {
                                        final itemLongPress = () {
                                          if (isSelectionMode && isSelected) {
                                            SelectionContextBottomSheet.show(context, provider, item.path);
                                          } else {
                                            provider.toggleSelection(item.path);
                                          }
                                        };
                                        return DragDropHandler(
                                          path: item.path,
                                          isDirectory: false,
                                          onLongPress: itemLongPress,
                                          isRemote: item.isRemote,
                                          remoteItems: item.remoteSource != null ? [item.remoteSource!] : null,
                                          child: FileGridItem(
                                            file: item,
                                            isSelected: isSelected,
                                            iconScale: provider.iconScale,
                                            itemPaddingMultiplier: provider.itemPaddingMultiplier,
                                            onTap: () {
                                              if (isSelectionMode) {
                                                provider.toggleSelection(item.path);
                                              } else {
                                                provider.openFile(context, item.path);
                                              }
                                            },
                                            onLongPress: provider.enableDragDrop ? null : itemLongPress,
                                            onIconTap: itemLongPress,
                                            onAction: (action) => _handleAction(context, action, item.path),
                                          ),
                                        );
                                      }
                                    },
                                    childCount: provider.currentFiles.length,
                                  ),
                                )
                              : SliverList(
                                  delegate: SliverChildBuilderDelegate(
                                    (context, index) {
                                      final item = provider.currentFiles[index];
                                      final isSelected = provider.selectedPaths.contains(item.path);
                                      if (item.isDirectory) {
                                        final itemLongPress = () {
                                          if (isSelectionMode && isSelected) {
                                            SelectionContextBottomSheet.show(context, provider, item.path);
                                          } else {
                                            provider.toggleSelection(item.path);
                                          }
                                        };
                                        return DragDropHandler(
                                          path: item.path,
                                          isDirectory: true,
                                          onLongPress: itemLongPress,
                                          isRemote: item.isRemote,
                                          remoteItems: item.remoteSource != null ? [item.remoteSource!] : null,
                                          child: FolderItem(
                                            folder: item,
                                            isSelected: isSelected,
                                            iconScale: provider.iconScale,
                                            itemPaddingMultiplier: provider.itemPaddingMultiplier,
                                            onTap: () {
                                              if (isSelectionMode) {
                                                provider.toggleSelection(item.path);
                                              } else {
                                                _openFolder(provider, item.path);
                                              }
                                            },
                                            onLongPress: provider.enableDragDrop ? null : itemLongPress,
                                            onIconTap: itemLongPress,
                                            onAction: (action) => _handleAction(context, action, item.path),
                                          ),
                                        );
                                      } else {
                                        final itemLongPress = () {
                                          if (isSelectionMode && isSelected) {
                                            SelectionContextBottomSheet.show(context, provider, item.path);
                                          } else {
                                            provider.toggleSelection(item.path);
                                          }
                                        };
                                        return DragDropHandler(
                                          path: item.path,
                                          isDirectory: false,
                                          onLongPress: itemLongPress,
                                          isRemote: item.isRemote,
                                          remoteItems: item.remoteSource != null ? [item.remoteSource!] : null,
                                          child: FileItem(
                                            file: item,
                                            isSelected: isSelected,
                                            iconScale: provider.iconScale,
                                            itemPaddingMultiplier: provider.itemPaddingMultiplier,
                                            onTap: () {
                                              if (isSelectionMode) {
                                                provider.toggleSelection(item.path);
                                              } else {
                                                provider.openFile(context, item.path);
                                              }
                                            },
                                            onLongPress: provider.enableDragDrop ? null : itemLongPress,
                                            onIconTap: itemLongPress,
                                            onAction: (action) => _handleAction(context, action, item.path),
                                          ),
                                        );
                                      }
                                    },
                                    childCount: provider.currentFiles.length,
                                  ),
                                ),
                        ),
                    ],
                  ),
                  // 文件传输进度条覆盖层
                  ValueListenableBuilder<FileOperationProgress?>(
                    valueListenable: provider.progressNotifier,
                    builder: (context, progress, child) {
                      if (progress == null) return const SizedBox.shrink();
                      final percent = (progress.percentage * 100).clamp(0, 100).toInt();
                      final theme = Theme.of(context);
                      final isDark = theme.brightness == Brightness.dark;
                      return Positioned.fill(
                        child: IgnorePointer(
                          child: BackdropFilter(
                            filter: ImageFilter.blur(sigmaX: 6, sigmaY: 6),
                            child: Container(
                              color: Colors.black.withOpacity(0.25),
                              child: Center(
                                child: Card(
                                  elevation: 24,
                                  shadowColor: Colors.black.withOpacity(0.3),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(28),
                                    side: BorderSide(color: theme.colorScheme.outline.withOpacity(0.12)),
                                  ),
                                  color: isDark ? const Color(0xFF1E1E2E) : theme.colorScheme.surface.withOpacity(0.95),
                                  child: ClipRRect(
                                    borderRadius: BorderRadius.circular(28),
                                    child: Padding(
                                      padding: const EdgeInsets.symmetric(vertical: 24, horizontal: 28),
                                      child: Column(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Row(
                                            mainAxisAlignment: MainAxisAlignment.center,
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              Icon(
                                                provider.isCut ? Broken.scissor : Broken.document_copy,
                                                color: theme.colorScheme.primary,
                                                size: 18,
                                              ),
                                              const SizedBox(width: 8),
                                              Text(
                                                provider.isCut ? '正在移动文件...' : '正在复制文件...',
                                                style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold),
                                              ),
                                            ],
                                          ),
                                          const SizedBox(height: 20),
                                          SizedBox(
                                            width: 100,
                                            height: 100,
                                            child: Stack(
                                              fit: StackFit.expand,
                                              children: [
                                                // Background ring
                                                CircularProgressIndicator(
                                                  value: 1.0,
                                                  strokeWidth: 7,
                                                  backgroundColor: theme.colorScheme.primary.withOpacity(0.08),
                                                  valueColor: AlwaysStoppedAnimation<Color>(theme.colorScheme.primary.withOpacity(0.08)),
                                                ),
                                                // Progress ring
                                                CircularProgressIndicator(
                                                  value: progress.percentage.clamp(0.0, 1.0),
                                                  strokeWidth: 7,
                                                  backgroundColor: Colors.transparent,
                                                  valueColor: AlwaysStoppedAnimation<Color>(theme.colorScheme.primary),
                                                  strokeCap: StrokeCap.round,
                                                ),
                                                Center(
                                                  child: Text(
                                                    '$percent%',
                                                    style: TextStyle(
                                                      fontSize: 24,
                                                      fontWeight: FontWeight.w900,
                                                      color: theme.colorScheme.primary,
                                                      letterSpacing: -1,
                                                    ),
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ),
                                          const SizedBox(height: 16),
                                          Container(
                                            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                                            decoration: BoxDecoration(
                                              color: theme.colorScheme.surfaceVariant.withOpacity(0.3),
                                              borderRadius: BorderRadius.circular(12),
                                            ),
                                            child: Row(
                                              mainAxisSize: MainAxisSize.min,
                                              children: [
                                                Icon(
                                                  Broken.document,
                                                  size: 14,
                                                  color: theme.colorScheme.primary.withOpacity(0.7),
                                                ),
                                                const SizedBox(width: 8),
                                                ConstrainedBox(
                                                  constraints: const BoxConstraints(maxWidth: 200),
                                                  child: Text(
                                                    progress.currentFileName,
                                                    style: theme.textTheme.bodySmall?.copyWith(
                                                      fontWeight: FontWeight.w600,
                                                      color: theme.colorScheme.onSurface.withOpacity(0.8),
                                                    ),
                                                    maxLines: 1,
                                                    overflow: TextOverflow.ellipsis,
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ),
                                          const SizedBox(height: 6),
                                          Text(
                                            '${progress.currentFileIndex}/${progress.totalFiles}',
                                            style: theme.textTheme.bodySmall?.copyWith(
                                              color: theme.colorScheme.onSurface.withOpacity(0.45),
                                              fontSize: 11,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                  ],
                ),
              );
            },
          ),
        ),
      ],
    ),
            floatingActionButtonLocation: isSelectionMode
                ? null
                : provider.showBottomActionBar
                    ? FloatingActionButtonLocation.centerDocked
                    : FloatingActionButtonLocation.endFloat,
            floatingActionButton: (() {
              if (provider.hasClipboard) {
                return Padding(
                  padding: EdgeInsets.only(bottom: provider.showBottomActionBar ? 0 : 16),
                  child: GestureDetector(
                    onLongPress: () {
                      provider.clearClipboard();
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('操作已取消 / 剪贴板已清除'),
                          behavior: SnackBarBehavior.floating,
                        ),
                      );
                    },
                    onDoubleTap: () async {
                      FileOperationProgressDialog.show(context, provider);
                      await provider.pasteFile(context, clearAfterPaste: false);
                    },
                    child: FloatingActionButton.extended(
                      onPressed: () async {
                        FileOperationProgressDialog.show(context, provider);
                        await provider.pasteFile(context, clearAfterPaste: true);
                      },
                      icon: const Icon(Broken.clipboard),
                      label: const Text('粘贴到此处'),
                    ),
                  ),
                );
              }
              if (!isSelectionMode && provider.showFloatingAddButton) {
                return Padding(
                  padding: EdgeInsets.only(bottom: provider.showBottomActionBar ? 0 : 16),
                  child: FloatingActionButton(
                    onPressed: () => _showAddBottomSheet(context, provider),
                    backgroundColor: Theme.of(context).colorScheme.primary,
                    foregroundColor: Colors.white,
                    elevation: 4,
                    shape: provider.showBottomActionBar ? RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)) : null,
                    child: const Icon(Broken.add, size: 28),
                  ),
                );
              }
              return null;
            })(),
            bottomNavigationBar: isSelectionMode
                ? SelectionActionBar(provider: provider)
                : !provider.showBottomActionBar
                    ? null
                    : BottomAppBar(
                    elevation: 8,
                    color: Theme.of(context).colorScheme.surface,
                    shape: const CircularNotchedRectangle(),
                    notchMargin: 8,
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceAround,
                      children: [
                        IconButton(
                          icon: const Icon(Broken.tick_square),
                          tooltip: '选择模式',
                          onPressed: () {
                            if (provider.currentFiles.isNotEmpty) {
                              provider.toggleSelection(provider.currentFiles.first.path);
                            }
                          },
                        ),
                        IconButton(
                          icon: const Icon(Broken.search_normal),
                          tooltip: '全局搜索',
                          onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => GlobalSearchScreen(searchFolderPath: provider.currentPath))),
                        ),
                        const SizedBox(width: 48), // Center dock slot for FAB
                        IconButton(
                          icon: const Icon(Broken.filter_edit),
                          tooltip: '查看和排序选项',
                          onPressed: () => _showSortModal(context, provider),
                        ),
                        IconButton(
                          icon: const Icon(Icons.sd_storage_rounded),
                          tooltip: '存储卷和SD卡',
                          onPressed: () => _showStorageVolumeModal(context, provider),
                        ),
                      ],
                    ),
                  ),
          ),
        );
      },
    );
  }

  Widget _buildActiveFilterBanner(BuildContext context, FileManagerProvider provider) {
    final theme = Theme.of(context);
    final filter = provider.filterType;
    String label = '';
    IconData icon = Broken.category;
    Color color = theme.colorScheme.primary;

    switch (filter) {
      case FileFilterType.all:
        break;
      case FileFilterType.documents:
        label = '仅文档';
        icon = Broken.document;
        color = Colors.blueAccent;
        break;
      case FileFilterType.images:
        label = '仅图片';
        icon = Broken.image;
        color = Colors.purpleAccent;
        break;
      case FileFilterType.audio:
        label = '仅音频';
        icon = Broken.music;
        color = Colors.greenAccent;
        break;
      case FileFilterType.videos:
        label = '仅视频';
        icon = Broken.video;
        color = Colors.redAccent;
        break;
      case FileFilterType.archives:
        label = '仅压缩包';
        icon = Broken.archive;
        color = Colors.brown;
        break;
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        decoration: BoxDecoration(
          color: color.withOpacity(0.12),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: color.withOpacity(0.25), width: 1.5),
        ),
        child: Row(
          children: [
            Icon(icon, color: color, size: 20),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                '$label 筛选已激活',
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 13.5,
                  color: theme.colorScheme.onSurface.withOpacity(0.9),
                ),
              ),
            ),
            TextButton.icon(
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                backgroundColor: color.withOpacity(0.15),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              ),
              onPressed: () => provider.toggleHideFoldersInFilter(),
              icon: Icon(
                provider.hideFoldersInFilter ? Broken.folder : Broken.folder_connection,
                color: color,
                size: 15,
              ),
              label: Text(
                provider.hideFoldersInFilter ? '显示文件夹' : '隐藏文件夹',
                style: TextStyle(
                  color: color,
                  fontWeight: FontWeight.bold,
                  fontSize: 11,
                ),
              ),
            ),
            const SizedBox(width: 10),
            InkWell(
              onTap: () => provider.setFilterType(FileFilterType.all),
              borderRadius: BorderRadius.circular(12),
              child: Container(
                padding: const EdgeInsets.all(4),
                decoration: BoxDecoration(
                  color: color.withOpacity(0.2),
                  shape: BoxShape.circle,
                ),
                child: Icon(Broken.close_square, color: color, size: 16),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 面包屑裁剪器，裁剪为带箭头的形状
class _BreadcrumbClipper extends CustomClipper<Path> {
  final bool hasLeftIndent;
  final double arrowWidth;

  _BreadcrumbClipper({required this.hasLeftIndent, required this.arrowWidth});

  @override
  Path getClip(Size size) {
    final path = Path();
    if (hasLeftIndent) {
      // 左侧凹陷：从左上角开始，向右凹陷到(arrowWidth, height/2)，再回到左下角
      path.moveTo(0, 0);
      path.lineTo(arrowWidth, size.height / 2);
      path.lineTo(0, size.height);
    } else {
      // 第一个按钮左侧平整
      path.moveTo(0, 0);
      path.lineTo(0, size.height);
    }
    // 右侧凸出箭头
    path.lineTo(size.width - arrowWidth, size.height);
    path.lineTo(size.width, size.height / 2);
    path.lineTo(size.width - arrowWidth, 0);
    path.close();
    return path;
  }

  @override
  bool shouldReclip(covariant _BreadcrumbClipper oldDelegate) {
    return hasLeftIndent != oldDelegate.hasLeftIndent || arrowWidth != oldDelegate.arrowWidth;
  }
}

class _AnimatedTitleButton extends StatefulWidget {
  final VoidCallback onTap;
  const _AnimatedTitleButton({required this.onTap});

  @override
  State<_AnimatedTitleButton> createState() => _AnimatedTitleButtonState();
}

class _AnimatedTitleButtonState extends State<_AnimatedTitleButton> with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _scaleAnimation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this, duration: const Duration(milliseconds: 100));
    _scaleAnimation = Tween<double>(begin: 1.0, end: 0.94).animate(CurvedAnimation(parent: _controller, curve: Curves.easeInOut));
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) => Transform.scale(
        scale: _scaleAnimation.value,
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(14),
            splashColor: theme.colorScheme.primary.withOpacity(0.3),
            highlightColor: theme.colorScheme.primary.withOpacity(0.15),
            onTapDown: (_) => _controller.forward(),
            onTapCancel: () => _controller.reverse(),
            onTap: () {
              _controller.reverse();
              widget.onTap();
            },
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10.0, vertical: 6.0),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text(
                    '文件',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 22, letterSpacing: -0.5),
                  ),
                  const SizedBox(width: 8),
                  Container(
                    padding: const EdgeInsets.all(4),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.primary.withOpacity(0.15),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Icon(Broken.arrow_down_2, size: 16, color: theme.colorScheme.primary),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
