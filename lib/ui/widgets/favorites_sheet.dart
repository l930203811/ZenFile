import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';
import 'package:zenfile/l10n/generated/app_localizations.dart';
import '../../core/icon_fonts/broken_icons.dart';
import '../../providers/file_manager_provider.dart';
import 'file_action_dialogs.dart';
import '../../services/preferences_service.dart';
import '../../services/network_connections_service.dart';

/// 收藏夹底部面板。
///
/// v3.1.x：原「右侧抽屉」整体下线，改为从**底部**弹出的半屏面板（对齐 MT / NP
/// 管理器书签的交互）。唤起入口：
///   1. 左抽屉「收藏夹」一项（原「设置」的位置），见 HomeScreen._openFavoritesFromDrawer；
///   2. 底部导航栏上滑手势，见 HomeScreen._buildNavBottomBar（**仅导航栏开启时**）；
///   3. 浏览页底部操作栏上滑，见 DirectoryScreen._buildCollapsibleBrowseActionBar
///      （导航栏关闭时唯一的底部手势入口）；
///   4. 左抽屉全局搜索里的「收藏夹」条目，见 feature_search_index。
/// ⚠️ 上滑热区**绝不能贴在屏幕最底边** —— 那里属于系统手势导航的边缘识别区，
/// 上滑会被系统抢走（真机实测：面板弹不出来，还会误触系统手势）。
///
/// 面板高度**内容自适应**：分组折叠得越多面板越矮，展开越多越高，最高约屏高
/// 68%，超过之后面板内部列表滚动（`Flexible` + `SingleChildScrollView`）。
/// ⚠️ 因此这里**不能用 `Expanded`** —— 面板高度由内容决定，`Expanded` 只适合
/// 父级高度已经确定的情形（旧抽屉是撑满整高的，所以能用）。
class FavoritesSheet extends StatefulWidget {
  /// 点击收藏后切到浏览页。
  final VoidCallback? onNavigateToBrowse;

  /// 收藏数据源。由 [show] 传入，并同时以 [ChangeNotifierProvider] 挂到弹窗
  /// 子树上，供面板内部 `context.watch` 订阅（收藏增删后面板自动重建 + 高度自适应）。
  final FileManagerProvider provider;

  const FavoritesSheet({
    super.key,
    required this.provider,
    this.onNavigateToBrowse,
  });

  /// 从底部弹出收藏夹面板。
  ///
  /// 分类页 / 浏览页 / 传输页 / 设置页都可调用：弹窗挂在 Navigator 之上，
  /// 与调用时所在页面无关。
  static Future<void> show(
    BuildContext context, {
    required FileManagerProvider provider,
    VoidCallback? onNavigateToBrowse,
  }) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      // 显式注入 Provider：弹窗的 context 挂在 Navigator 下，拿不到调用处
      // widget 树里的 Provider。
      builder: (_) => ChangeNotifierProvider<FileManagerProvider>.value(
        value: provider,
        child: FavoritesSheet(
          provider: provider,
          onNavigateToBrowse: onNavigateToBrowse,
        ),
      ),
    );
  }

  @override
  State<FavoritesSheet> createState() => _FavoritesSheetState();
}

class _FavoritesSheetState extends State<FavoritesSheet> {
  late Set<String> _collapsedGroups;

  @override
  void initState() {
    super.initState();
    _collapsedGroups = PreferencesService.getFavoritesGroupCollapsed();
  }

  @override
  Widget build(BuildContext context) {
    // 订阅 provider：收藏增删 / 改名后自动重建，面板高度也随之重新自适应。
    context.watch<FileManagerProvider>();
    final theme = Theme.of(context);
    final l10n = L10n.of(context);
    // 面板最高约屏高 68%；内容不足时按实际内容收矮（见下方 Flexible）。
    final maxHeight = MediaQuery.of(context).size.height * 0.68;

    return AnimatedSize(
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOut,
      alignment: Alignment.bottomCenter,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxHeight),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _buildDragHandle(theme),
            _buildHeader(context, theme, l10n),
            // Flexible（而非 Expanded）：内容矮 → 面板就矮；内容超高 → 吃满
            // maxHeight 后由内部 SingleChildScrollView 滚动。
            Flexible(
              child: SingleChildScrollView(
                physics: const BouncingScrollPhysics(),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (widget.provider.favorites.isEmpty)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        child: Text(
                          l10n.msg551f98ba,
                          textAlign: TextAlign.center,
                          style: TextStyle(
                              color: theme.colorScheme.onSurface.withOpacity(0.5)),
                        ),
                      )
                    else
                      ..._buildGroupedFavorites(context),

                    // 底部留白含手势条高度，避免最后一项贴住系统导航栏。
                    SizedBox(height: 12 + MediaQuery.of(context).padding.bottom),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 顶部小把手：提示这是一个可下滑关闭的底部面板。
  Widget _buildDragHandle(ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.only(top: 10, bottom: 4),
      child: Container(
        width: 36,
        height: 4,
        decoration: BoxDecoration(
          color: theme.colorScheme.onSurface.withOpacity(0.22),
          borderRadius: BorderRadius.circular(2),
        ),
      ),
    );
  }

  /// 面板标题行：图标 + 「收藏夹」+ 新建收藏按钮。
  Widget _buildHeader(BuildContext context, ThemeData theme, L10n l10n) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 6, 12, 8),
      child: Row(
        children: [
          Icon(Broken.folder_favorite, color: theme.colorScheme.primary, size: 26),
          const SizedBox(width: 14),
          Expanded(
            child: Text(
              l10n.ui_favorites,
              style: TextStyle(
                color: theme.colorScheme.onSurface,
                fontSize: 21,
                fontWeight: FontWeight.bold,
                letterSpacing: 0.5,
              ),
            ),
          ),
          IconButton(
            icon: Icon(Broken.add_circle, color: theme.colorScheme.primary, size: 26),
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(),
            tooltip: l10n.ui_new_favorite,
            onPressed: () => _showAddFavoriteDialog(context),
          ),
        ],
      ),
    );
  }

  Widget _buildFavoriteItem(
    BuildContext context, {
    required Map<String, dynamic> fav,
    required VoidCallback onTap,
  }) {
    final name = fav['name'] as String;
    final isDirectory = fav['isDirectory'] as bool;
    final isRemote = fav['isRemote'] == true;
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(12),
        child: Row(
          children: [
            // 主内容：点击打开收藏，长按弹出「编辑 / 删除」菜单
            Expanded(
              child: InkWell(
                onTap: onTap,
                onLongPress: () => _showItemMenu(context, fav),
                borderRadius: BorderRadius.circular(12),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  child: Row(
                    children: [
                      Stack(
                        clipBehavior: Clip.none,
                        children: [
                          Icon(
                            isDirectory ? Broken.folder : Broken.document,
                            size: 22,
                            color: isDirectory ? theme.colorScheme.primary : theme.colorScheme.onSurface.withOpacity(0.7),
                          ),
                          if (isRemote)
                            Positioned(
                              right: -3,
                              bottom: -3,
                              child: Container(
                                padding: const EdgeInsets.all(1.5),
                                decoration: BoxDecoration(
                                  color: theme.colorScheme.surface,
                                  shape: BoxShape.circle,
                                ),
                                child: Icon(
                                  Broken.cloud,
                                  size: 9,
                                  color: theme.colorScheme.primary,
                                ),
                              ),
                            ),
                        ],
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          name,
                          style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w500),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            // 右侧三点按钮：竖向三点（⋮），点击同样弹出「编辑 / 删除」菜单，靠右对齐
            IconButton(
              icon: Icon(
                Icons.more_vert,
                size: 22,
                color: theme.colorScheme.onSurface.withOpacity(0.6),
              ),
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(),
              tooltip: L10n.of(context).ui_more,
              onPressed: () => _showItemMenu(context, fav),
            ),
          ],
        ),
      ),
    );
  }

  /// 处理收藏项点击：无论本地还是远程，均使用「新标签页」打开，
  /// 不再覆盖已激活的 Tab；双窗口模式下新标签会落到未激活的那一侧窗口。
  /// 远程收藏需要重建连接会话（见 [_openRemoteFavorite]），本地收藏用 addTab 打开。
  /// 无论哪种情况，完成后都切换到浏览页。
  void _openFavorite(Map<String, dynamic> fav, BuildContext context) {
    final provider = widget.provider;
    final path = fav['path'] as String;
    final isDirectory = fav['isDirectory'] as bool;
    final isRemote = fav['isRemote'] == true;

    if (isRemote) {
      final connectionId = fav['connectionId'] as String?;
      if (connectionId != null) {
        final connections = NetworkConnectionsService.getConnections();
        final conn = connections.where((c) => c.id == connectionId).firstOrNull;
        if (conn != null) {
          _openRemoteFavorite(provider, conn, path, isDirectory, context);
          return;
        }
      }
      // 连接信息缺失或已删除，回退到本地新建标签页
    }

    // 一律使用新标签页打开（不再覆盖已激活的 Tab）；
    // 双窗口模式下 addTab 会自动把新标签放到未激活的那一侧窗口。
    if (isDirectory) {
      provider.addTab(path);
    } else {
      provider.addTab(p.dirname(path));
      // 跳转到父目录后，在新建标签页中打开文件本身
      provider.showFileInLocation(path);
      provider.openFile(context, path);
    }
    widget.onNavigateToBrowse?.call();
  }

  Future<void> _openRemoteFavorite(
    FileManagerProvider provider,
    dynamic connection,
    String path,
    bool isDirectory,
    BuildContext context,
  ) async {
    try {
      final remoteClient = FileManagerProvider.createRemoteClient(connection);
      await remoteClient.connect();
      await provider.openRemoteTab(remoteClient, connection);
      // openRemoteTab 已 loadDirectory 到 rootPath，若收藏目标是子目录或文件的父目录，再加载一次
      final targetPath = isDirectory ? path : p.dirname(path);
      if (targetPath != connection.rootPath) {
        await provider.loadDirectory(targetPath);
      }
      // 文件收藏：导航到父目录后打开文件本身
      if (!isDirectory) {
        provider.showFileInLocation(path);
        provider.openFile(context, path);
      }
    } catch (e) {
      // 连接失败时回退到本地 loadDirectory
      provider.loadDirectory(isDirectory ? path : p.dirname(path));
    }
    widget.onNavigateToBrowse?.call();
  }

  /// 按分组渲染收藏列表。
  /// 无 group 字段的收藏会归入「默认分组」。
  List<Widget> _buildGroupedFavorites(BuildContext context) {
    final l10n = L10n.of(context);
    final favorites = widget.provider.favorites;

    final groups = <String, List<Map<String, dynamic>>>{};
    for (final fav in favorites) {
      final groupName = (fav['group'] as String?)?.trim();
      final key = groupName?.isNotEmpty == true ? groupName! : '';
      groups.putIfAbsent(key, () => []).add(fav);
    }

    final sortedKeys = groups.keys.toList()
      ..sort((a, b) {
        if (a.isEmpty && b.isNotEmpty) return -1;
        if (a.isNotEmpty && b.isEmpty) return 1;
        return a.compareTo(b);
      });

    return [
      for (final key in sortedKeys)
        _buildGroupSection(
          context,
          key,
          key.isEmpty ? l10n.ui_default_group : key,
          groups[key]!,
        ),
    ];
  }

  /// 单个收藏分组的折叠区块：标题靠左，支持折叠/展开，状态持久化。
  Widget _buildGroupSection(BuildContext context, String key, String groupName, List<Map<String, dynamic>> favs) {
    final theme = Theme.of(context);
    final collapsed = _collapsedGroups.contains(key);
    return ExpansionTile(
      key: ValueKey('fav_group_$key'),
      initiallyExpanded: !collapsed,
      onExpansionChanged: (expanded) {
        setState(() {
          if (expanded) {
            _collapsedGroups.remove(key);
          } else {
            _collapsedGroups.add(key);
          }
        });
        PreferencesService.saveFavoritesGroupCollapsed(_collapsedGroups);
      },
      tilePadding: const EdgeInsets.fromLTRB(16, 2, 16, 2),
      title: GestureDetector(
        onLongPress: key.isEmpty ? null : () => _showGroupMenu(context, key, groupName),
        child: Row(
          children: [
            Expanded(
              child: Text(
                groupName,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: theme.colorScheme.primary,
                ),
                textAlign: TextAlign.left,
              ),
            ),
            Text(
              '${favs.length}',
              style: TextStyle(
                fontSize: 11,
                color: theme.colorScheme.onSurface.withOpacity(0.5),
              ),
            ),
          ],
        ),
      ),
      childrenPadding: const EdgeInsets.only(bottom: 4),
      children: favs.map((fav) {
        return _buildFavoriteItem(
          context,
          fav: fav,
          onTap: () {
            Navigator.pop(context);
            _openFavorite(fav, context);
          },
        );
      }).toList(),
    );
  }

  /// 编辑已有收藏：弹出对话框修改名称 / 路径 / 分组，再写回。
  Future<void> _editFavorite(Map<String, dynamic> fav) async {
    final provider = widget.provider;
    final initialGroup = (fav['group'] as String?)?.trim().isNotEmpty == true ? fav['group'] as String : null;
    final result = await FileActionDialogs.showFavoriteEditor(
      context,
      existingGroups: _existingGroups(),
      initialPath: fav['path'] as String,
      initialName: fav['name'] as String,
      initialGroup: initialGroup,
    );
    if (result == null) return;
    // 路径变更时检查是否与其他收藏冲突
    if (provider.isFavorite(result.path) && result.path != fav['path']) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(L10n.of(context).msg_favorite_exists)),
      );
      return;
    }
    provider.updateFavorite(
      fav,
      name: result.name,
      path: result.path,
      group: result.group ?? '',
    );
  }

  /// 长按分组标题：弹出重命名 / 删除分组菜单（默认分组 key 为空，不响应）。
  void _showGroupMenu(BuildContext context, String key, String groupName) {
    final l10n = L10n.of(context);
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: Icon(Broken.edit_2, size: 22),
              title: Text(l10n.ui_rename_group),
              onTap: () {
                Navigator.pop(ctx);
                _renameGroup(key, groupName);
              },
            ),
            ListTile(
              leading: Icon(Broken.trash, size: 22, color: Colors.redAccent),
              title: Text(l10n.ui_delete_group),
              onTap: () {
                Navigator.pop(ctx);
                _deleteGroup(key, groupName);
              },
            ),
          ],
        ),
      ),
    );
  }

  /// 重命名分组：弹输入框，将该分组下所有收藏的 group 字段更新为新名称。
  Future<void> _renameGroup(String oldGroup, String oldName) async {
    final l10n = L10n.of(context);
    final controller = TextEditingController(text: oldName);
    final newName = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.ui_rename_group),
        content: TextField(
          controller: controller,
          decoration: InputDecoration(labelText: l10n.ui_group_name),
          autofocus: true,
          textInputAction: TextInputAction.done,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(l10n.ui_cancel),
          ),
          TextButton(
            onPressed: () {
              final v = controller.text.trim();
              if (v.isEmpty || v == oldGroup) {
                Navigator.pop(ctx);
                return;
              }
              Navigator.pop(ctx, v);
            },
            child: Text(l10n.ui_save),
          ),
        ],
      ),
    );
    if (newName == null || newName == oldGroup) return;
    widget.provider.renameFavoriteGroup(oldGroup, newName);
  }

  /// 删除分组：二次确认后移除该分组下所有收藏。
  Future<void> _deleteGroup(String group, String groupName) async {
    final l10n = L10n.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.ui_delete_group),
        content: Text(l10n.msg_delete_group_confirm(groupName)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(l10n.ui_cancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(l10n.ui_delete, style: const TextStyle(color: Colors.redAccent)),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      widget.provider.deleteFavoriteGroup(group);
    }
  }

  /// 长按收藏项：弹出编辑 / 删除菜单。
  void _showItemMenu(BuildContext context, Map<String, dynamic> fav) {
    final l10n = L10n.of(context);
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: Icon(Broken.edit_2, size: 22),
              title: Text(l10n.ui_edit),
              onTap: () {
                Navigator.pop(ctx);
                _editFavorite(fav);
              },
            ),
            ListTile(
              leading: Icon(Broken.trash, size: 22, color: Colors.redAccent),
              title: Text(l10n.ui_delete),
              onTap: () {
                Navigator.pop(ctx);
                widget.provider.removeFavorite(fav['path'] as String);
              },
            ),
          ],
        ),
      ),
    );
  }

  /// 弹出「添加为收藏」对话框：自定义路径、名称、分组（含新建分组）。
  Future<void> _showAddFavoriteDialog(BuildContext context) async {
    final l10n = L10n.of(context);
    final pathController = TextEditingController();
    final nameController = TextEditingController();
    final newGroupController = TextEditingController();

    final existingGroups = _existingGroups();
    const newGroupValue = '__new__';
    String? selectedGroup;

    await showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) {
          return AlertDialog(
            title: Text(l10n.ui_add_to_favorites),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: pathController,
                    decoration: InputDecoration(labelText: l10n.ui_path),
                    keyboardType: TextInputType.text,
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: nameController,
                    decoration: InputDecoration(labelText: l10n.ui_name),
                    keyboardType: TextInputType.text,
                  ),
                  const SizedBox(height: 12),
                  InputDecorator(
                    decoration: InputDecoration(labelText: l10n.ui_group),
                    child: DropdownButtonHideUnderline(
                      child: DropdownButton<String?>(
                        value: selectedGroup,
                        isDense: true,
                        isExpanded: true,
                        items: [
                          DropdownMenuItem(value: null, child: Text(l10n.ui_default_group)),
                          ...existingGroups.map(
                            (g) => DropdownMenuItem(value: g, child: Text(g)),
                          ),
                          DropdownMenuItem(value: newGroupValue, child: Text(l10n.ui_new_group)),
                        ],
                        onChanged: (value) => setState(() => selectedGroup = value),
                      ),
                    ),
                  ),
                  if (selectedGroup == newGroupValue) ...[
                    const SizedBox(height: 12),
                    TextField(
                      controller: newGroupController,
                      decoration: InputDecoration(labelText: l10n.ui_group_name),
                    ),
                  ],
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: Text(l10n.ui_cancel),
              ),
              TextButton(
                onPressed: () {
                  final path = pathController.text.trim();
                  final name = nameController.text.trim();
                  if (path.isEmpty) {
                    ScaffoldMessenger.of(ctx).showSnackBar(
                      SnackBar(content: Text(l10n.msg_please_enter_path)),
                    );
                    return;
                  }
                  if (name.isEmpty) {
                    ScaffoldMessenger.of(ctx).showSnackBar(
                      SnackBar(content: Text(l10n.msg_please_enter_name)),
                    );
                    return;
                  }

                  String? group;
                  if (selectedGroup == newGroupValue) {
                    group = newGroupController.text.trim();
                    if (group.isEmpty) {
                      ScaffoldMessenger.of(ctx).showSnackBar(
                        SnackBar(content: Text(l10n.msg_please_enter_group_name)),
                      );
                      return;
                    }
                  } else {
                    group = selectedGroup;
                  }

                  if (widget.provider.isFavorite(path)) {
                    ScaffoldMessenger.of(ctx).showSnackBar(
                      SnackBar(content: Text(l10n.msg_favorite_exists)),
                    );
                    return;
                  }

                  widget.provider.addFavorite(path, name, true, group: group);
                  Navigator.of(ctx).pop();
                },
                child: Text(l10n.ui_add),
              ),
            ],
          );
        },
      ),
    );
  }

  List<String> _existingGroups() {
    final groups = <String>{};
    for (final fav in widget.provider.favorites) {
      final group = (fav['group'] as String?)?.trim();
      if (group?.isNotEmpty == true) groups.add(group!);
    }
    return groups.toList()..sort();
  }
}