import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';
import 'package:zenfile/l10n/generated/app_localizations.dart';
import '../../core/icon_fonts/broken_icons.dart';
import '../../providers/file_manager_provider.dart';
import '../screens/global_search_screen.dart';
import '../widgets/quick_categories_grid.dart';
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
  late bool _isFavoritesExpanded;

  @override
  void initState() {
    super.initState();
    _isFavoritesExpanded = PreferencesService.getDrawerSectionExpanded('favorites');
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return Drawer(
      backgroundColor: theme.scaffoldBackgroundColor,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.only(topLeft: Radius.circular(28), bottomLeft: Radius.circular(28)),
      ),
      child: SafeArea(
        child: Column(
          children: [
            Container(
              margin: const EdgeInsets.symmetric(horizontal: 12.0, vertical: 8.0),
              padding: const EdgeInsets.all(16.0),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: isDark
                      ? [const Color(0xFF0F172A), const Color(0xFF1E293B)]
                      : [theme.colorScheme.primary.withOpacity(0.85), theme.colorScheme.primary],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                borderRadius: BorderRadius.circular(24),
                boxShadow: [
                  BoxShadow(
                    color: theme.colorScheme.primary.withOpacity(0.25),
                    blurRadius: 16,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: Row(
                children: [
                  Container(
                    width: 52,
                    height: 52,
                    decoration: BoxDecoration(
                      color: Colors.white.withOpacity(0.2),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(Broken.more_circle, color: Colors.white, size: 28),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          L10n.of(context).msge8b8e9b3,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 22,
                            fontWeight: FontWeight.bold,
                            letterSpacing: 0.5,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          L10n.of(context).msg04b7de53,
                          style: TextStyle(
                            color: Colors.white.withOpacity(0.8),
                            fontSize: 12.5,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),

            Expanded(
              child: SingleChildScrollView(
                physics: const BouncingScrollPhysics(),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
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

                    const SizedBox(height: 12),
                    const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 12.0),
                      child: Divider(height: 1, thickness: 1),
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
                        title: Text(
                          L10n.of(context).ui_favorites,
                          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
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
                            : widget.provider!.favorites.map((fav) {
                                return _buildFavoriteItem(
                                  context,
                                  name: fav['name'] as String,
                                  path: fav['path'] as String,
                                  isDirectory: fav['isDirectory'] as bool,
                                  isRemote: fav['isRemote'] == true,
                                  onTap: () {
                                    Navigator.pop(context);
                                    _openFavorite(fav);
                                  },
                                  onRemove: () {
                                    widget.provider!.removeFavorite(fav['path'] as String);
                                  },
                                );
                              }).toList(),
                      ),

                    const SizedBox(height: 24),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFavoriteItem(
    BuildContext context, {
    required String name,
    required String path,
    required bool isDirectory,
    bool isRemote = false,
    required VoidCallback onTap,
    required VoidCallback onRemove,
  }) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          onTap: onTap,
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
                IconButton(
                  icon: Icon(Broken.trash, size: 18, color: Colors.redAccent.withOpacity(0.7)),
                  onPressed: onRemove,
                  padding: EdgeInsets.zero,
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
      provider.openRemoteTab(remoteClient, connection);
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