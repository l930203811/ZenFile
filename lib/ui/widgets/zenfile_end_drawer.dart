import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:zenfile/l10n/generated/app_localizations.dart';
import '../../core/icon_fonts/broken_icons.dart';
import '../../providers/file_manager_provider.dart';
import '../screens/global_search_screen.dart';
import 'file_action_dialogs.dart';
import '../../services/preferences_service.dart';
import '../../services/network_connections_service.dart';

/// 右侧弹出菜单组件
class ZenFileEndDrawer extends StatefulWidget {
  final VoidCallback toggleTheme;
  final VoidCallback? onRefresh;
  final VoidCallback? onCustomize;
  final VoidCallback? onShowSortModal;
  final VoidCallback? onNavigateToBrowse;
  final String? searchFolderPath;
  final FileManagerProvider? provider;

  const ZenFileEndDrawer({
    super.key,
    required this.toggleTheme,
    this.onRefresh,
    this.onCustomize,
    this.onShowSortModal,
    this.onNavigateToBrowse,
    this.searchFolderPath,
    this.provider,
  });

  @override
  State<ZenFileEndDrawer> createState() => _ZenFileEndDrawerState();
}

class _ZenFileEndDrawerState extends State<ZenFileEndDrawer> {
  late bool _isQuickActionsExpanded;
  late bool _isFavoritesExpanded;
  late Set<String> _collapsedGroups;

  @override
  void initState() {
    super.initState();
    _isQuickActionsExpanded = PreferencesService.getDrawerSectionExpanded('quick_actions');
    _isFavoritesExpanded = PreferencesService.getDrawerSectionExpanded('favorites');
    _collapsedGroups = PreferencesService.getFavoritesGroupCollapsed();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return SafeArea(
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 8),
            child: Row(
              children: [
                Icon(Broken.more_circle, color: theme.colorScheme.primary, size: 28),
                const SizedBox(width: 14),
                Text(
                  L10n.of(context).msg_quick_actions,
                  style: TextStyle(
                    color: theme.colorScheme.onSurface,
                    fontSize: 22,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 0.5,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 4),

          Expanded(
            child: SingleChildScrollView(
              physics: const BouncingScrollPhysics(),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  ExpansionTile(
                    initiallyExpanded: _isQuickActionsExpanded,
                    onExpansionChanged: (expanded) {
                      setState(() => _isQuickActionsExpanded = expanded);
                      PreferencesService.saveDrawerSectionExpanded('quick_actions', expanded);
                    },
                    leading: Icon(Broken.command, color: theme.colorScheme.primary, size: 24),
                    title: Text(
                      L10n.of(context).msge8b8e9b3,
                      style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 17),
                      maxLines: 2,
                      softWrap: true,
                      overflow: TextOverflow.ellipsis,
                    ),
                    childrenPadding: const EdgeInsets.symmetric(horizontal: 12),
                    children: [
                      if (widget.onRefresh != null)
                        _buildMenuItem(
                          context,
                          icon: Broken.refresh,
                          title: L10n.of(context).msg354c1c9a,
                          color: theme.colorScheme.primary,
                          onTap: () {
                            Navigator.pop(context);
                            widget.onRefresh!();
                          },
                        ),
                      if (widget.onCustomize != null)
                        _buildMenuItem(
                          context,
                          icon: Broken.edit_2,
                          title: L10n.of(context).msge7d18d73,
                          color: theme.colorScheme.primary,
                          onTap: () {
                            Navigator.pop(context);
                            widget.onCustomize!();
                          },
                        ),
                      if (widget.onShowSortModal != null && widget.provider != null)
                        _buildMenuItem(
                          context,
                          icon: Broken.filter_edit,
                          title: L10n.of(context).msg97301f64,
                          color: theme.colorScheme.primary,
                          onTap: () {
                            Navigator.pop(context);
                            widget.onShowSortModal!();
                          },
                        ),
                      _buildMenuItem(
                        context,
                        icon: isDark ? Broken.sun_1 : Broken.moon,
                        title: isDark ? L10n.of(context).msg8755e992 : L10n.of(context).ui_dark_mode,
                        color: theme.colorScheme.primary,
                        onTap: () {
                          Navigator.pop(context);
                          widget.toggleTheme();
                        },
                      ),
                      _buildMenuItem(
                        context,
                        icon: Broken.search_normal,
                        title: L10n.of(context).msg681c0f39,
                        color: theme.colorScheme.primary,
                        onTap: () {
                          Navigator.pop(context);
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => GlobalSearchScreen(
                                searchFolderPath: widget.searchFolderPath,
                              ),
                            ),
                          );
                        },
                      ),
                    ],
                  ),

                  const SizedBox(height: 8),

                  if (widget.provider != null)
                    ExpansionTile(
                      initiallyExpanded: _isFavoritesExpanded,
                      onExpansionChanged: (expanded) {
                        setState(() => _isFavoritesExpanded = expanded);
                        PreferencesService.saveDrawerSectionExpanded('favorites', expanded);
                      },
                      leading: Icon(Broken.folder_favorite, color: theme.colorScheme.primary, size: 24),
                      title: Row(
                        children: [
                          Expanded(
                            child: Text(
                              L10n.of(context).ui_favorites,
                              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 17),
                              maxLines: 2,
                              softWrap: true,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          IconButton(
                            icon: Icon(Broken.add_circle, color: theme.colorScheme.primary, size: 22),
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(),
                            tooltip: L10n.of(context).ui_new_favorite,
                            onPressed: () => _showAddFavoriteDialog(context),
                          ),
                        ],
                      ),
                      childrenPadding: const EdgeInsets.symmetric(horizontal: 12),
                      children: widget.provider!.favorites.isEmpty
                          ? [
                              Padding(
                                padding: const EdgeInsets.symmetric(vertical: 16),
                                child: Text(
                                  L10n.of(context).msg551f98ba,
                                  textAlign: TextAlign.center,
                                  style: TextStyle(color: theme.colorScheme.onSurface.withOpacity(0.5)),
                                ),
                              ),
                            ]
                          : _buildGroupedFavorites(context),
                    ),

                  const SizedBox(height: 24),
                ],
              ),
            ),
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
    );
  }

  /// 处理收藏项点击：远程收藏需要重建连接会话，本地收藏直接 loadDirectory。
  /// 无论哪种情况，完成后都切换到浏览页。
  void _openFavorite(Map<String, dynamic> fav) {
    final provider = widget.provider;
    if (provider == null) return;
    final path = fav['path'] as String;
    final isDirectory = fav['isDirectory'] as bool;
    final isRemote = fav['isRemote'] == true;

    if (isRemote) {
      final connectionId = fav['connectionId'] as String?;
      if (connectionId != null) {
        final connections = NetworkConnectionsService.getConnections();
        final conn = connections.where((c) => c.id == connectionId).firstOrNull;
        if (conn != null) {
          _openRemoteFavorite(provider, conn, path, isDirectory);
          return;
        }
      }
      // 连接信息缺失或已删除，回退到本地 loadDirectory（多半会失败，但至少有兜底）
    }

    // 本地收藏：若当前激活 Tab 是远程 Tab，loadDirectory 会走远程分支
    // 用 remoteClient 列本地路径导致空目录，故先切回本地 Tab 再加载。
    if (provider.activeTab.isRemote) {
      final localTabIndex = provider.tabs.indexWhere((t) => !t.isRemote);
      if (localTabIndex >= 0) {
        provider.setActiveTab(localTabIndex);
      }
    }

    if (isDirectory) {
      provider.loadDirectory(path);
    } else {
      provider.loadDirectory(p.dirname(path));
    }
    widget.onNavigateToBrowse?.call();
  }

  Future<void> _openRemoteFavorite(
    FileManagerProvider provider,
    dynamic connection,
    String path,
    bool isDirectory,
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
    final favorites = widget.provider!.favorites;

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
            _openFavorite(fav);
          },
        );
      }).toList(),
    );
  }

  /// 编辑已有收藏：弹出对话框修改名称 / 路径 / 分组，再写回。
  Future<void> _editFavorite(Map<String, dynamic> fav) async {
    final provider = widget.provider;
    if (provider == null) return;
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
    widget.provider?.renameFavoriteGroup(oldGroup, newName);
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
      widget.provider?.deleteFavoriteGroup(group);
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
              title: Text(l10n.ui_edit_favorite),
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
                widget.provider!.removeFavorite(fav['path'] as String);
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

                  if (widget.provider?.isFavorite(path) == true) {
                    ScaffoldMessenger.of(ctx).showSnackBar(
                      SnackBar(content: Text(l10n.msg_favorite_exists)),
                    );
                    return;
                  }

                  widget.provider?.addFavorite(path, name, true, group: group);
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
    for (final fav in widget.provider?.favorites ?? []) {
      final group = (fav['group'] as String?)?.trim();
      if (group?.isNotEmpty == true) groups.add(group!);
    }
    return groups.toList()..sort();
  }

  Widget _buildMenuItem(
    BuildContext context, {
    required IconData icon,
    required String title,
    required Color color,
    required VoidCallback onTap,
  }) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12.0, vertical: 2.0),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(16),
          splashColor: color.withOpacity(0.15),
          highlightColor: color.withOpacity(0.08),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 14.0),
            child: Row(
              children: [
                Icon(icon, size: 24, color: color),
                const SizedBox(width: 16),
                Expanded(
                  child: Text(
                    title,
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      color: theme.colorScheme.onSurface.withOpacity(0.9),
                    ),
                    maxLines: 2,
                    softWrap: true,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}