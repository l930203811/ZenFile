import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart';
import 'package:provider/provider.dart';
import 'package:path/path.dart' as p;
import '../../providers/file_manager_provider.dart';
import '../../models/file_filter_type.dart';
import '../../models/drag_payload.dart';
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
import '../../core/icon_fonts/broken_icons.dart';
import 'internal_file_picker_screen.dart';
import '../widgets/restricted_folder_banner.dart';
import '../widgets/directory_tab_bar.dart';
import '../../services/folder_share_service.dart';
import '../widgets/pane_browser.dart';
import '../../services/network_connections_service.dart';
import 'network_connection_wizard_screen.dart';
import 'package:zenfile/l10n/generated/app_localizations.dart';


class DirectoryScreen extends StatefulWidget {
  final VoidCallback toggleTheme;
  final Function(int)? onNavigateTab;
  final VoidCallback? onEndDrawerCustomize;
  final VoidCallback? onRefresh;
  final VoidCallback? onOpenDrawer;
  final VoidCallback? onOpenEndDrawer;
  const DirectoryScreen({
    super.key,
    required this.toggleTheme,
    this.onNavigateTab,
    this.onEndDrawerCustomize,
    this.onRefresh,
    this.onOpenDrawer,
    this.onOpenEndDrawer,
  });

  @override
  State<DirectoryScreen> createState() => _DirectoryScreenState();
}

class _DirectoryScreenState extends State<DirectoryScreen> {
  final ScrollController _scrollController = ScrollController();
  final ScrollController _breadcrumbController = ScrollController();
  final ScrollController _tabScrollController = ScrollController();
  final TextEditingController _pathEditController = TextEditingController();
  final FocusNode _pathFocusNode = FocusNode();
  final GlobalKey<EditableTextState> _pathTextFieldKey = GlobalKey<EditableTextState>();
  bool _isEditingPath = false;

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
    _pathEditController.dispose();
    _pathFocusNode.dispose();
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

  /// 进入路径编辑模式：用当前路径填充输入框并请求焦点
  void _startPathEditing(FileManagerProvider provider) {
    setState(() {
      _isEditingPath = true;
      _pathEditController.text = provider.currentPath;
      _pathEditController.selection = TextSelection.fromPosition(
        TextPosition(offset: _pathEditController.text.length),
      );
    });
    provider.setPathEditing(true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _pathFocusNode.requestFocus();
    });
  }

  /// 提交路径跳转：读取输入框路径并导航
  void _submitPathNavigation(FileManagerProvider provider) {
    final path = _pathEditController.text.trim();
    if (path.isEmpty) return;
    _pathFocusNode.unfocus();
    setState(() {
      _isEditingPath = false;
    });
    provider.setPathEditing(false);
    provider.loadDirectory(path);
  }

  /// 编辑态长按路径栏：全选整个路径地址并弹出系统级操作菜单（复制 / 剪切 / 删除 / 粘贴）。
  /// 系统菜单由 Flutter 的 TextSelectionControls 提供，已随 MaterialLocalizations 自动多语言。
  void _selectAllPath() {
    FocusScope.of(context).requestFocus(_pathFocusNode);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _pathTextFieldKey.currentState?.selectAll(SelectionChangedCause.longPress);
    });
  }

  /// 构建当前路径面包屑导航（层叠式）
  Widget _buildPathBreadcrumb(BuildContext context, FileManagerProvider provider) {
    final theme = Theme.of(context);
    final currentPath = provider.currentPath;
    final parts = currentPath.split('/').where((n) => n.isNotEmpty).toList();

    // 如果路径为根目录或太短，显示存储卷名称
    // 存储卷弹窗由左侧向下箭头按钮专责触发，此处仅显示文本避免误触
    if (parts.isEmpty) {
      return Text(
        currentPath,
        style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12, color: theme.colorScheme.onSurface),
        overflow: TextOverflow.ellipsis,
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

    // Stack 层叠面包屑：从右向左渲染，确保左侧项的右箭头绘制在右侧项上方
    // overlap 必须与 _buildBreadcrumbItem 中的 arrowWidth 一致（8.0），
    // 这样左项的右箭头凸出恰好填入右项的左凹陷，无缝隙也无覆盖。
    const overlap = 8.0;
    final itemWidgets = <Widget>[];
    // 先构建所有项
    itemWidgets.add(
      _buildBreadcrumbItem(
        context, theme,
        label: parts[0],
        isFirst: true,
        isActive: parts.length <= 1,
      ),
    );
    for (int i = 1; i < parts.length; i++) {
      itemWidgets.add(
        _buildBreadcrumbItem(
          context, theme,
          label: parts[i],
          isFirst: false,
          isActive: i == parts.length - 1,
        ),
      );
    }

    // 计算总宽度：相邻项通过 overlap 重叠（左项右箭头插入右项左凹陷），
    // 最右项右箭头需要额外 overlap 空间露出。
    double totalWidth = 0;
    final textPainter = TextPainter(textDirection: TextDirection.ltr);
    for (int i = 0; i < itemWidgets.length; i++) {
      textPainter.text = TextSpan(text: parts[i], style: TextStyle(fontSize: 11, fontWeight: FontWeight.w500));
      textPainter.layout();
      final textW = textPainter.width;
      final isFirst = i == 0;
      final leftPad = isFirst ? 6.0 : overlap + 3.0;
      final rightPad = overlap + 3.0;
      totalWidth += leftPad + textW + rightPad;
      if (i < itemWidgets.length - 1) totalWidth -= overlap; // 与右项重叠
      if (i == itemWidgets.length - 1) totalWidth += overlap; // 最右项右箭头露出
    }

    // 从右到左布局，Stack 中先添加的在下层，后添加的在上层
    final stackChildren = <Widget>[];
    double cursor = totalWidth;
    for (int i = itemWidgets.length - 1; i >= 0; i--) {
      final isFirst = i == 0;
      final isRightmost = i == itemWidgets.length - 1;
      textPainter.text = TextSpan(text: parts[i], style: TextStyle(fontSize: 11, fontWeight: FontWeight.w500));
      textPainter.layout();
      final textW = textPainter.width;
      final leftPad = isFirst ? 6.0 : overlap + 3.0;
      final rightPad = overlap + 3.0;
      final itemW = leftPad + textW + rightPad;
      cursor -= itemW;
      if (!isRightmost) cursor += overlap; // 与右项重叠，让左项右箭头插入右项左凹陷

      final targetPath = '/${parts.sublist(0, i + 1).join('/')}';
      stackChildren.add(
        Positioned(
          left: cursor,
          top: 0,
          bottom: 0,
          width: itemW,
          child: GestureDetector(
            onTap: () {
                    if (targetPath != currentPath) provider.loadDirectory(targetPath);
                  },
            child: itemWidgets[i],
          ),
        ),
      );
    }

    return SingleChildScrollView(
      controller: _breadcrumbController,
      scrollDirection: Axis.horizontal,
      child: SizedBox(
        width: totalWidth,
        height: 22,
        child: Stack(children: stackChildren),
      ),
    );
  }

  /// 构建锥形箭头面包屑项（层叠式，所有非首项左侧凹陷、右侧凸出）
  /// 使用 CustomPaint 的 foregroundPainter 沿 V 形路径描边，
  /// 确保斜边（箭头凹陷/凸出）也有完整边框，而非被 ClipPath 裁掉。
  Widget _buildBreadcrumbItem(
    BuildContext context,
    ThemeData theme, {
    required String label,
    required bool isFirst,
    required bool isActive,
  }) {
    final bgColor = isActive
        ? theme.colorScheme.primary.withOpacity(0.15)
        : theme.colorScheme.surfaceVariant.withOpacity(0.5);
    final textColor = isActive
        ? theme.colorScheme.primary
        : theme.colorScheme.onSurface.withOpacity(0.75);
    final fontWeight = isActive ? FontWeight.bold : FontWeight.w500;
    const arrowWidth = 8.0;
    final borderColor = isActive
        ? theme.colorScheme.primary.withOpacity(0.4)
        : theme.colorScheme.onSurface.withOpacity(0.12);
    final clipper = _BreadcrumbClipper(
      hasLeftIndent: !isFirst,
      hasRightArrow: true,
      arrowWidth: arrowWidth,
    );
    return CustomPaint(
      foregroundPainter: _BreadcrumbBorderPainter(
        clipper: clipper,
        color: borderColor,
        width: 1.0,
      ),
      child: ClipPath(
        clipper: clipper,
        child: Container(
          height: 22,
          padding: EdgeInsets.only(
            left: isFirst ? 6 : arrowWidth + 3,
            right: arrowWidth + 3,
          ),
          decoration: BoxDecoration(color: bgColor),
          alignment: Alignment.center,
          child: Text(
            label,
            style: TextStyle(fontSize: 11, fontWeight: fontWeight, color: textColor),
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
    // 双屏模式下隐藏标签页栏（含标签页切换、+ 新建标签页、三点菜单），
    // 因为每个 PaneBrowser 内部已有自己的导航，不需要顶部标签页切换。
    // 隐藏后，下方面包屑栏和文件列表会自然上移，充分利用屏幕空间。
    final hasTabs = provider.enableMultipleTabs && !provider.enableSplitScreen;
    final hasAddressBar = provider.showAddressBar;
    // 当底部导航栏开启时，底部已被镜像 AppBar 占用，浏览操作栏改为显示在顶部
    // showFloatingAddButton（设置项"显示操作按钮"）控制操作栏是否显示
    final hasTopBrowseBar = provider.showBottomActionBar && provider.showFloatingAddButton;
    if (!hasTabs && !hasAddressBar && !hasTopBrowseBar) {
      return const SizedBox.shrink();
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // 当底部导航栏开启时，浏览操作栏显示在顶部（标签页栏上方）
        if (hasTopBrowseBar) _buildBrowseActionBar(context, provider),
        if (hasTabs)
          DirectoryTabBar(provider: provider, scrollController: _tabScrollController),
        if (hasAddressBar)
          Padding(
            padding: const EdgeInsets.only(left: 4, right: 4),
            child: SizedBox(
              height: 22,
              child: Row(
                children: [
                  // 存储卷/网络连接导航按钮（左侧靠左对齐，所有模式一致）
                  GestureDetector(
                    onTap: () => _showStorageVolumeModal(context, provider),
                    child: Container(
                      height: 22,
                      width: 22,
                      decoration: BoxDecoration(
                        color: theme.colorScheme.primary.withOpacity(0.10),
                        borderRadius: BorderRadius.circular(4),
                        border: Border.all(
                          color: theme.colorScheme.primary.withOpacity(0.25),
                          width: 1,
                        ),
                      ),
                      child: Icon(Broken.arrow_down_2, size: 14, color: theme.colorScheme.primary),
                    ),
                  ),
                  const SizedBox(width: 8),
                  // 路径栏：浏览态显示面包屑，编辑态显示输入框。
                  // 浏览态长按路径栏 → 进入编辑态；编辑态长按路径栏 → 全选路径并弹出系统级菜单（复制/剪切/删除/粘贴）。
                  // 编辑态下单击 → 取消全选（由 TextField 原生处理）。
                  Expanded(
                    child: GestureDetector(
                      onLongPress: () {
                        if (_isEditingPath) {
                          _selectAllPath();
                        } else {
                          _startPathEditing(provider);
                        }
                      },
                      child: _isEditingPath
                          ? TextField(
                              key: _pathTextFieldKey,
                              focusNode: _pathFocusNode,
                              controller: _pathEditController,
                              enableInteractiveSelection: true,
                              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500),
                              decoration: InputDecoration(
                                isDense: true,
                                contentPadding: const EdgeInsets.symmetric(vertical: 2),
                                border: InputBorder.none,
                                hintText: L10n.of(context).go_to_path,
                              ),
                              textInputAction: TextInputAction.go,
                              autocorrect: false,
                              onSubmitted: (_) => _submitPathNavigation(provider),
                            )
                          : _buildPathBreadcrumb(context, provider),
                    ),
                  ),
                  // 编辑态跳转按钮：提交路径并导航
                  if (_isEditingPath)
                    GestureDetector(
                      onTap: () => _submitPathNavigation(provider),
                      child: Container(
                        height: 22,
                        width: 22,
                        margin: const EdgeInsets.only(left: 8),
                        decoration: BoxDecoration(
                          color: theme.colorScheme.primary.withOpacity(0.10),
                          borderRadius: BorderRadius.circular(4),
                          border: Border.all(
                            color: theme.colorScheme.primary.withOpacity(0.25),
                            width: 1,
                          ),
                        ),
                        child: Icon(Broken.arrow_right_3, size: 14, color: theme.colorScheme.primary),
                      ),
                    ),
                ],
              ),
            ),
          ),
      ],
    );
  }

  /// 浏览页操作栏：后退 / 前进 / 新建 / 复制标签页 / 向上
  ///
  /// 位置规则：
  /// - 当底部导航栏开启（showBottomActionBar == true）时，底部已被 BottomAppBar
  ///   占用，此操作栏改为显示在顶部 AppBar 下方（作为 _buildFixedTopArea 的一部分）。
  /// - 当底部导航栏关闭时，此操作栏显示在 bottomNavigationBar 位置。
  Widget _buildBrowseActionBar(BuildContext context, FileManagerProvider provider) {
    final theme = Theme.of(context);
    return Container(
      height: 44,
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        border: Border(
          top: BorderSide(color: theme.dividerColor.withOpacity(0.08), width: 0.5),
          bottom: BorderSide(color: theme.dividerColor.withOpacity(0.08), width: 0.5),
        ),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceAround,
        children: [
          // 后退
          IconButton(
            icon: Icon(
              Broken.arrow_left_2,
              color: provider.canGoBack ? theme.colorScheme.primary : theme.colorScheme.onSurface.withOpacity(0.3),
            ),
            tooltip: L10n.of(context).ui_go_up,
            onPressed: provider.canGoBack ? () => _goBack(provider) : null,
          ),
          // 前进
          IconButton(
            icon: Icon(
              Broken.arrow_right_3,
              color: provider.canGoForward ? theme.colorScheme.primary : theme.colorScheme.onSurface.withOpacity(0.3),
            ),
            tooltip: L10n.of(context).msg6ed14da7,
            onPressed: provider.canGoForward ? () => provider.goForward() : null,
          ),
          // 新建（复刻 AppBar 右上角的 PopupMenuButton）
          PopupMenuButton<String>(
            icon: Icon(Broken.add_square, size: 26, color: theme.colorScheme.primary),
            tooltip: L10n.of(context).ui_new,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            position: PopupMenuPosition.under,
            elevation: 8,
            onSelected: (val) => _handleMenuAction(context, val, provider),
            itemBuilder: (context) => [
              PopupMenuItem(value: 'file', child: Row(children: [Icon(Broken.document, size: 20), SizedBox(width: 12), Text(L10n.of(context).msge48a7157, style: TextStyle(fontWeight: FontWeight.w600))])),
              PopupMenuItem(value: 'folder', child: Row(children: [Icon(Broken.folder, size: 20), SizedBox(width: 12), Text(L10n.of(context).msgf3a485df, style: TextStyle(fontWeight: FontWeight.w600))])),
              PopupMenuItem(value: 'archive', child: Row(children: [Icon(Broken.archive, size: 20), SizedBox(width: 12), Text(L10n.of(context).msg68ac91eb, style: TextStyle(fontWeight: FontWeight.w600))])),
              PopupMenuItem(value: 'favorite', child: Row(children: [Icon(Broken.folder_favorite, size: 20), SizedBox(width: 12), Text(L10n.of(context).ui_new_favorite, style: TextStyle(fontWeight: FontWeight.w600))])),
            ],
          ),
          // 向上（返回上一层路径）
          IconButton(
            icon: Icon(
              Broken.arrow_up_1,
              color: provider.canGoBack ? theme.colorScheme.primary : theme.colorScheme.onSurface.withOpacity(0.3),
            ),
            tooltip: L10n.of(context).ui_go_up,
            onPressed: provider.canGoBack ? () => _goBack(provider) : null,
          ),
        ],
      ),
    );
  }

  String _clipboardLabel(FileManagerProvider provider) {
    final prefix = provider.isCut ? L10n.of(context).ui_cut : L10n.of(context).ui_copy;
    if (provider.isRemoteClipboard) {
      final items = provider.remoteClipboardItems;
      if (items.isEmpty) return prefix;
      final name = p.basename(items.first.path);
      return items.length > 1 ? '$prefix: $name +${items.length - 1}' : '$prefix: $name';
    }
    final paths = provider.clipboardPaths;
    if (paths.isEmpty) return prefix;
    final name = p.basename(paths.first);
    return paths.length > 1 ? '$prefix: $name +${paths.length - 1}' : '$prefix: $name';
  }

  void _showClipboardMenuSheet(BuildContext context, FileManagerProvider provider) {
    final theme = Theme.of(context);
    
    final itemNames = <String>[];
    if (provider.isRemoteClipboard) {
      for (final item in provider.remoteClipboardItems) {
        itemNames.add(p.basename(item.path));
      }
    } else {
      for (final path in provider.clipboardPaths) {
        itemNames.add(p.basename(path));
      }
    }
    final prefix = provider.isCut ? L10n.of(context).ui_cut : L10n.of(context).ui_copy;
    final maxItemHeight = 200.0;

    showDialog(
      context: context,
      barrierColor: Colors.black26,
      builder: (sheetContext) => Stack(
        children: [
          GestureDetector(
            onTap: () => Navigator.pop(sheetContext),
            child: Container(color: Colors.transparent),
          ),
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: Container(
              margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
              decoration: BoxDecoration(
                color: theme.colorScheme.surface,
                borderRadius: BorderRadius.circular(16),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.2),
                    blurRadius: 20,
                    offset: const Offset(0, 8),
                  ),
                ],
              ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 剪贴板内容列表
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: Row(
                children: [
                  Icon(
                    provider.isCut ? Broken.scissor : Broken.clipboard,
                    size: 16,
                    color: provider.isCut ? Colors.orange : theme.colorScheme.primary,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    L10n.of(context).ui_cut_copy_items(prefix, itemNames.length),
                    style: theme.textTheme.labelMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                      color: provider.isCut ? Colors.orange : theme.colorScheme.primary,
                    ),
                  ),
                ],
              ),
            ),
            Flexible(
              child: ConstrainedBox(
                constraints: BoxConstraints(maxHeight: maxItemHeight),
                child: ListView.builder(
                  shrinkWrap: true,
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                  itemCount: itemNames.length,
                  itemBuilder: (_, i) => Padding(
                    padding: const EdgeInsets.symmetric(vertical: 3),
                    child: Row(
                      children: [
                        Icon(
                          Icons.insert_drive_file_outlined,
                          size: 14,
                          color: theme.colorScheme.onSurface.withOpacity(0.45),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            itemNames[i],
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurface.withOpacity(0.7),
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 4),
            // 操作按钮
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
              child: Row(
                children: [
                  // 清除按钮（左侧，较小）
                  Expanded(
                    flex: 2,
                    child: OutlinedButton(
                      onPressed: () {
                        Navigator.pop(sheetContext);
                        provider.clearClipboard();
                      },
                      style: OutlinedButton.styleFrom(
                        foregroundColor: theme.colorScheme.error,
                        side: BorderSide(color: theme.colorScheme.error.withOpacity(0.25)),
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                      ),
                      child: Text(L10n.of(context).ui_clear, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500)),
                    ),
                  ),
                  const SizedBox(width: 10),
                  // 粘贴按钮（右侧，较大）
                  Expanded(
                    flex: 5,
                    child: ElevatedButton.icon(
                      onPressed: () async {
                        Navigator.pop(sheetContext);
                        await provider.pasteFile(context, clearAfterPaste: true);
                      },
                      icon: const Icon(Icons.content_paste, size: 16),
                      label: Text(L10n.of(context).ui_paste, style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: theme.colorScheme.primary,
                        foregroundColor: theme.colorScheme.onPrimary,
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
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
        // ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(L10n.of(context).msg4fb42e6e)));
        break;
      case 'cut':
        provider.cutFile(path);
        // ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(L10n.of(context).msge5212c58)));
        break;
      case 'rename':
        final isMulti = provider.selectedPaths.isNotEmpty && provider.selectedPaths.contains(path);
        if (isMulti && provider.selectedPaths.length > 1) {
          await BatchRenameDialog.show(context, provider);
        } else {
          final currentName = p.posix.basename(path);
          final newName = await FileActionDialogs.showRenameDialog(
            context,
            currentName: currentName,
            title: L10n.of(context).msgc8ce4b36,
            hint: L10n.of(context).msgf139c5cf,
            actionText: L10n.of(context).msgc8ce4b36,
          );
          if (newName != null && newName.isNotEmpty) {
            try {
              await provider.renameFile(path, newName);
            } catch (e) {
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('重命名失败: $e')),
                );
              }
              return;
            }
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
          title: isMulti ? L10n.of(context).msgcd0b9aca : L10n.of(context).msg4b342999,
          content: isMulti
              ? L10n.of(context).selectedcount2(provider.selectedPaths.length)
              : L10n.of(context).msgee14ee27,
        );
        if (confirm) {
          try {
            if (isMulti) {
              await provider.deleteSelected();
            } else {
              await provider.deleteFile(path);
            }
          } catch (e) {
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text(L10n.of(context).msg_delete_failed(e)), behavior: SnackBarBehavior.floating),
              );
            }
          }
        }
        break;
      case 'share':
        final paths = (provider.selectedPaths.isNotEmpty && provider.selectedPaths.contains(path))
            ? provider.selectedPaths.toList()
            : [path];
        await FolderShareService.sharePaths(context, paths);
        break;
      case 'favorite':
        final name = p.posix.basename(path);
        final isRemote = provider.currIsRemote;
        final connectionId = provider.activeTab.remoteConnection?.id;
        final isDir = isRemote ? true : await Directory(path).exists();
        provider.addFavorite(path, name, isDir, isRemote: isRemote, connectionId: connectionId);
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(L10n.of(context).msg_favorited(name)), behavior: SnackBarBehavior.floating, duration: const Duration(seconds: 2)),
          );
        }
        break;
      case 'open_with':
        provider.openFile(context, path, forceOpenWith: true);
        break;
      case 'pin':
        await provider.togglePinPath(path);
        break;
      case 'set_as_home':
        await provider.setAsHomeDirectory(path);
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(L10n.of(context).ui_set_as_home),
              behavior: SnackBarBehavior.floating,
              duration: const Duration(seconds: 2),
            ),
          );
        }
        break;
    }
  }

  void _handleMenuAction(BuildContext context, String action, FileManagerProvider provider) async {
    switch (action) {
      case 'file':
        final fileName = await FileActionDialogs.showTextInputDialog(
          context,
          title: L10n.of(context).msge48a7157,
          hint: L10n.of(context).ui_file_name,
          actionText: L10n.of(context).ui_create,
        );
        if (fileName != null && fileName.isNotEmpty) {
          final createdName = await provider.createFile(fileName);
          if (createdName != null && createdName != fileName && context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(L10n.of(context).filenamecreatedname(fileName, createdName)),
                behavior: SnackBarBehavior.floating,
              ),
            );
          }
        }
        break;
      case 'folder':
        final folderName = await FileActionDialogs.showTextInputDialog(
          context,
          title: L10n.of(context).msgf3a485df,
          hint: L10n.of(context).msga98473f2,
          actionText: L10n.of(context).ui_create,
        );
        if (folderName != null && folderName.isNotEmpty) {
          final createdName = await provider.createFolder(folderName);
          if (createdName != null && createdName != folderName && context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(L10n.of(context).foldernamecreatedname(folderName, createdName)),
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
      case 'favorite':
        final currentPath = provider.currentPath;
        final name = p.posix.basename(currentPath);
        final isRemote = provider.currIsRemote;
        final connectionId = provider.activeTab.remoteConnection?.id;
        provider.addFavorite(currentPath, name, true, isRemote: isRemote, connectionId: connectionId);
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(L10n.of(context).msg_favorited(name)), behavior: SnackBarBehavior.floating, duration: const Duration(seconds: 2)),
          );
        }
        break;
    }
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
                            L10n.of(context).ui_storage_volume,
                            style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        TextButton.icon(
                          style: TextButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4)),
                          icon: const Icon(Broken.folder_add, size: 18),
                          label: Text(L10n.of(context).msge4c84f81, style: TextStyle(fontSize: 14)),
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
                      title: Text(vol.isInternal ? L10n.of(context).msg21cefa9b : vol.name, style: TextStyle(fontWeight: isSelected ? FontWeight.bold : FontWeight.w600, fontSize: 16)),
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
                    title: Text(L10n.of(context).msgd730e478, style: TextStyle(fontWeight: provider.rootPath == '/' ? FontWeight.bold : FontWeight.w600, fontSize: 16)),
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
                            L10n.of(context).msg35546526,
                            style: theme.textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.bold,
                              color: theme.colorScheme.primary,
                              fontFamily: 'LexendDeca',
                            ),
                          ),
                          IconButton(
                            icon: const Icon(Icons.add_link_rounded, size: 20),
                            tooltip: L10n.of(context).msg67a6ea5e,
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
                      if (FileManagerProvider.isSmbType(conn.type)) {
                        iconData = Icons.dns_rounded;
                      } else if (conn.type == 'Google Drive') {
                        iconData = Icons.cloud_circle_rounded;
                      } else if (conn.type == 'Dropbox') {
                        iconData = Icons.folder_shared_rounded;
                      } else if (conn.type == 'OneDrive') {
                        iconData = Icons.cloud_queue_rounded;
                      } else if (conn.type == 'Box') {
                        iconData = Icons.all_inbox_rounded;
                      } else if (conn.type == 'FTP') {
                        iconData = Icons.swap_horizontal_circle_rounded;
                      } else if (conn.type == 'SFTP') {
                        iconData = Icons.vpn_lock_rounded;
                      } else if (conn.type == 'WebDav') {
                        iconData = Icons.web_rounded;
                      } else {
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
                          tooltip: L10n.of(context).msgcc51d6c2,
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
                              await provider.openRemoteTab(client, conn);
                            }
                          } catch (e) {
                            if (context.mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(content: Text(L10n.of(context).e13(e)), backgroundColor: Colors.redAccent),
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
        final showBottomActionBar = provider.showBottomActionBar;

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
                  final crossAxisCount = (MediaQuery.of(context).size.width / (110 * provider.iconScale)).floor().clamp(2, 10);
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
            // 编辑路径态下，返回键优先退出编辑而非导航。
            // 注意：此处只清除本地编辑态，共享标记 provider.isPathEditing 交由 home_screen 的
            // PopScope 统一处理，避免嵌套 PopScope 调用顺序导致返回键仍切到分类页。
            if (_isEditingPath) {
              setState(() {
                _isEditingPath = false;
              });
              _pathFocusNode.unfocus();
              return;
            }
            if (isSelectionMode) {
              provider.clearSelection();
            } else if (provider.canGoBack) {
              _goBack(provider);
            }
          },
          child: Scaffold(
            appBar: (isSelectionMode || !showBottomActionBar)
                ? AppBar(
                    automaticallyImplyLeading: isSelectionMode,
                    surfaceTintColor: Colors.transparent,
                    scrolledUnderElevation: 0,
                    titleSpacing: 0,
                    centerTitle: true,
                    title: isSelectionMode
                        ? const SizedBox.shrink()
                        : Row(
                            children: [
                              // 抽屉按钮（靠左）
                              IconButton(
                                icon: Icon(Broken.sidebar_left, color: theme.colorScheme.primary),
                                onPressed: () => widget.onOpenDrawer?.call(),
                              ),
                              const Spacer(),
                              // 分类页按钮
                              IconButton(
                                icon: Icon(Broken.category, color: theme.colorScheme.primary),
                                tooltip: L10n.of(context).msg6e0f9cef,
                                onPressed: () {
                                  widget.onNavigateTab?.call(0);
                                },
                              ),
                              const SizedBox(width: 32),
                              // 浏览页按钮
                              IconButton(
                                icon: Icon(Broken.folder, color: theme.colorScheme.primary),
                                tooltip: L10n.of(context).ui_browse,
                                onPressed: () {
                                  // 已在浏览页，无需切换
                                },
                              ),
                              const Spacer(),
                              // 快捷操作按钮（靠右）
                              IconButton(
                                icon: Icon(Broken.more_circle, color: theme.colorScheme.primary),
                                tooltip: L10n.of(context).msge8b8e9b3,
                                onPressed: () => widget.onOpenEndDrawer?.call(),
                              ),
                            ],
                          ),
                    // 显式占用 actions，避免 Scaffold 因存在 endDrawer
                    // 自动在右上角补一个与“快捷操作”重复的菜单按钮。
                    actions: const [SizedBox.shrink()],
                  )
                : AppBar(
                    automaticallyImplyLeading: false,
                    surfaceTintColor: Colors.transparent,
                    scrolledUnderElevation: 0,
                    toolbarHeight: MediaQuery.of(context).padding.top,
                    // 与上方分支保持一致，禁止自动注入 endDrawer 按钮。
                    actions: const [SizedBox.shrink()],
                  ),
            body: Column(
              children: [
                // 顶部固定区域（标签页 + 路径面包屑）
                if (!isSelectionMode) _buildFixedTopArea(context, provider),
                if (provider.filterType != FileFilterType.all)
                  _buildActiveFilterBanner(context, provider),
                if (provider.isLoading)
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
                        // 本地拖放到本地目录 — 通过剪贴板+paste路径获得字节级进度
                        provider.setClipboard(data.paths, isCut: true);
                        provider.pasteFile(context, clearAfterPaste: true);
                      }
                    },
                    builder: (context, candidateData, rejectedData) {
                      return GestureDetector(
                    behavior: HitTestBehavior.translucent,
                    child: provider.enableSplitScreen
                      ? const Row(
                          children: [
                            Expanded(child: PaneBrowser(tabIndex: 0)),
                            Expanded(child: PaneBrowser(tabIndex: 1)),
                          ],
                        )
                      : (provider.isLoading && provider.currentFiles.isEmpty && !provider.isPasting)
                          ? const Center(child: CircularProgressIndicator())
                          : provider.needsPermission
                              ? RestrictedFolderBanner(
                                  onEnableRoot: () => provider.enableRootMode(),
                                  onEnableShizuku: () => provider.enableShizukuMode(),
                                  onGoBack: provider.canGoBack ? () => _goBack(provider) : null,
                                  isRootAvailable: provider.isRootAvailable,
                                )
                              : Column(
                                  children: [
                                    // 顶部剪贴板栏（折叠/展开）
                                    AnimatedContainer(
                                      duration: const Duration(milliseconds: 200),
                                      curve: Curves.easeInOut,
                                      height: provider.hasClipboard ? 28.0 : 0.0,
                                      padding: const EdgeInsets.symmetric(horizontal: 8),
                                      decoration: BoxDecoration(
                                        color: theme.colorScheme.surfaceVariant.withOpacity(0.25),
                                        border: Border(
                                          bottom: BorderSide(
                                            color: theme.colorScheme.outline.withOpacity(0.08),
                                          ),
                                        ),
                                      ),
                                      child: provider.hasClipboard
                                          ? Row(
                                              children: [
                                                const Spacer(),
                                                GestureDetector(
                                                  onTap: () => _showClipboardMenuSheet(context, provider),
                                                  child: Container(
                                                    height: 22,
                                                    padding: const EdgeInsets.symmetric(horizontal: 7),
                                                    decoration: BoxDecoration(
                                                      borderRadius: BorderRadius.circular(11),
                                                      color: provider.isCut
                                                          ? Colors.orange.withOpacity(0.12)
                                                          : theme.colorScheme.primary.withOpacity(0.12),
                                                      border: Border.all(
                                                        color: provider.isCut
                                                            ? Colors.orange.withOpacity(0.3)
                                                            : theme.colorScheme.primary.withOpacity(0.3),
                                                        width: 0.5,
                                                      ),
                                                    ),
                                                    child: Row(
                                                      mainAxisSize: MainAxisSize.min,
                                                      children: [
                                                        Icon(
                                                          provider.isCut ? Broken.scissor : Broken.clipboard,
                                                          size: 11,
                                                          color: provider.isCut
                                                              ? Colors.orange
                                                              : theme.colorScheme.primary,
                                                        ),
                                                        const SizedBox(width: 3),
                                                        ConstrainedBox(
                                                          constraints: const BoxConstraints(maxWidth: 120),
                                                          child: Text(
                                                            _clipboardLabel(provider),
                                                            style: TextStyle(
                                                              fontSize: 10,
                                                              fontWeight: FontWeight.bold,
                                                              color: provider.isCut
                                                                  ? Colors.orange
                                                                  : theme.colorScheme.primary,
                                                            ),
                                                            maxLines: 1,
                                                            overflow: TextOverflow.ellipsis,
                                                          ),
                                                        ),
                                                      ],
                                                    ),
                                                  ),
                                                ),
                                              ],
                                            )
                                          : null,
                                    ),
                                    Expanded(
                                      child: CustomScrollView(
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
                                Text(L10n.of(context).ui_folders_count(provider.currentFiles.where((e) => e.isDirectory).length), style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Theme.of(context).colorScheme.onSurface.withOpacity(0.8))),
                                const SizedBox(width: 20),
                                Icon(Broken.document, size: 16, color: Theme.of(context).colorScheme.onSurface.withOpacity(0.7)),
                                const SizedBox(width: 6),
                                Text(L10n.of(context).ui_files_count(provider.currentFiles.where((e) => !e.isDirectory).length), style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Theme.of(context).colorScheme.onSurface.withOpacity(0.8))),
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
                                    L10n.of(context).msge9691076,
                                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                                          fontWeight: FontWeight.bold,
                                          color: Theme.of(context).colorScheme.onSurface,
                                        ),
                                  ),
                                  const SizedBox(height: 8),
                                  Text(
                                    L10n.of(context).msg551f98ba,
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
                                    crossAxisCount: (MediaQuery.of(context).size.width / (110 * provider.iconScale)).floor().clamp(2, 10),
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
                                          provider.toggleSelection(item.path);
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
                                          provider.toggleSelection(item.path);
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
                                          provider.toggleSelection(item.path);
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
                                          provider.toggleSelection(item.path);
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
                                            showOpenWithOption: true,
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
                                    ),
                                  ],
                                ),
              );
            },
          ),
        ),
      ],
    ),
            floatingActionButtonLocation: null,
            floatingActionButton: null,
            bottomNavigationBar: isSelectionMode
                ? SelectionActionBar(provider: provider)
                : showBottomActionBar
                    // 导航栏在底部：四个按钮均匀分布（与顶部布局一致）
                    ? PreferredSize(
                        preferredSize: Size.fromHeight(kToolbarHeight + MediaQuery.of(context).padding.bottom),
                        child: Material(
                          color: theme.appBarTheme.backgroundColor ?? theme.colorScheme.surface,
                          elevation: 8,
                          child: SafeArea(
                            top: false,
                            child: SizedBox(
                              height: kToolbarHeight,
                              child: Row(
                                children: [
                                  // 抽屉按钮（靠左）
                                  IconButton(
                                    icon: Icon(Broken.sidebar_left, color: theme.colorScheme.primary),
                                    onPressed: () => widget.onOpenDrawer?.call(),
                                  ),
                                  const Spacer(),
                                  // 分类页按钮
                                  IconButton(
                                    icon: Icon(Broken.category, color: theme.colorScheme.primary),
                                    tooltip: L10n.of(context).msg6e0f9cef,
                                    onPressed: () => widget.onNavigateTab?.call(0),
                                  ),
                                  const SizedBox(width: 32),
                                  // 浏览页按钮
                                  IconButton(
                                    icon: Icon(Broken.folder, color: theme.colorScheme.primary),
                                    tooltip: L10n.of(context).ui_browse,
                                    onPressed: () {},
                                  ),
                                  const Spacer(),
                                  // 快捷操作按钮（靠右）
                                  IconButton(
                                    icon: Icon(Broken.more_circle, color: theme.colorScheme.primary),
                                    tooltip: L10n.of(context).msge8b8e9b3,
                                    onPressed: () => widget.onOpenEndDrawer?.call(),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      )
                    // 导航栏在顶部：showFloatingAddButton 控制浏览操作栏是否显示
                    // 使用 SafeArea 处理安卓虚拟导航键（三键导航）的底部间距，
                    // 避免操作栏与系统导航键重叠。手势导航时 padding.bottom=0 不影响。
                    : (provider.showFloatingAddButton
                        ? Material(
                            color: theme.colorScheme.surface,
                            child: SafeArea(
                              top: false,
                              child: _buildBrowseActionBar(context, provider),
                            ),
                          )
                        : null),
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
        label = L10n.of(context).msg0c36f64f;
        icon = Broken.document;
        color = Colors.blueAccent;
        break;
      case FileFilterType.images:
        label = L10n.of(context).ui_images_only;
        icon = Broken.image;
        color = Colors.purpleAccent;
        break;
      case FileFilterType.audio:
        label = L10n.of(context).msg26b041dd;
        icon = Broken.music;
        color = Colors.greenAccent;
        break;
      case FileFilterType.videos:
        label = L10n.of(context).ui_videos_only;
        icon = Broken.video;
        color = Colors.redAccent;
        break;
      case FileFilterType.archives:
        label = L10n.of(context).msge632ba85;
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
                L10n.of(context).label(label),
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
                provider.hideFoldersInFilter ? L10n.of(context).ui_show_folders : L10n.of(context).msg0e77af8a,
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

/// 面包屑裁剪器：左侧可凹陷（上一级箭头插入处），右侧可凸出箭头（插入下一级）
class _BreadcrumbClipper extends CustomClipper<Path> {
  final bool hasLeftIndent;
  final bool hasRightArrow;
  final double arrowWidth;

  _BreadcrumbClipper({required this.hasLeftIndent, required this.hasRightArrow, required this.arrowWidth});

  @override
  Path getClip(Size size) {
    final path = Path();
    // 左侧凹陷：尖端向内（arrowWidth, mid），形成一个 V 形凹槽
    if (hasLeftIndent) {
      path.moveTo(0, 0);
      path.lineTo(arrowWidth, size.height / 2);
      path.lineTo(0, size.height);
    } else {
      path.moveTo(0, 0);
      path.lineTo(0, size.height);
    }
    // 底部
    if (hasRightArrow) {
      path.lineTo(size.width - arrowWidth, size.height);
    } else {
      path.lineTo(size.width, size.height);
    }
    // 右侧凸出箭头：尖端向外（size.width, mid）
    if (hasRightArrow) {
      path.lineTo(size.width, size.height / 2);
      path.lineTo(size.width - arrowWidth, 0);
    } else {
      path.lineTo(size.width, 0);
    }
    // 顶部
    if (hasLeftIndent) {
      path.lineTo(arrowWidth, 0);
    } else {
      path.lineTo(0, 0);
    }
    path.close();
    return path;
  }

  @override
  bool shouldReclip(covariant _BreadcrumbClipper oldDelegate) {
    return hasLeftIndent != oldDelegate.hasLeftIndent ||
        hasRightArrow != oldDelegate.hasRightArrow ||
        arrowWidth != oldDelegate.arrowWidth;
  }
}

/// 沿 V 形路径描边绘制边框，确保斜边（箭头凹陷/凸出）也有完整边框。
/// 置于 CustomPaint 的 foregroundPainter 中，绘制在 ClipPath 上方，
/// 不被裁剪。
class _BreadcrumbBorderPainter extends CustomPainter {
  final _BreadcrumbClipper clipper;
  final Color color;
  final double width;

  _BreadcrumbBorderPainter({
    required this.clipper,
    required this.color,
    required this.width,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = width
      ..strokeJoin = StrokeJoin.round;
    canvas.drawPath(clipper.getClip(size), paint);
  }

  @override
  bool shouldRepaint(covariant _BreadcrumbBorderPainter oldDelegate) {
    return color != oldDelegate.color ||
        width != oldDelegate.width ||
        clipper.hasLeftIndent != oldDelegate.clipper.hasLeftIndent ||
        clipper.hasRightArrow != oldDelegate.clipper.hasRightArrow ||
        clipper.arrowWidth != oldDelegate.clipper.arrowWidth;
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
                  Text(
                    L10n.of(context).ui_files,
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
