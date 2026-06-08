import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/icon_fonts/broken_icons.dart';
import '../../providers/file_manager_provider.dart';
import '../screens/global_search_screen.dart';
import '../screens/more_settings_screen.dart';
import '../screens/vault_lock_screen.dart';
import '../screens/ftp_server_screen.dart';
import '../../services/network_connections_service.dart';
import '../screens/network_connection_wizard_screen.dart';
import '../screens/remote_explorer_screen.dart';
import '../screens/about_screen.dart';
import '../screens/web_sharing_screen.dart';
import '../../providers/media_provider.dart';
import 'quick_categories_grid.dart';
import '../screens/internal_file_picker_screen.dart';
import '../screens/recycle_bin_screen.dart';

class ZenFileDrawer extends StatelessWidget {
  final VoidCallback toggleTheme;
  final Function(int)? onNavigateTab;

  const ZenFileDrawer({super.key, required this.toggleTheme, this.onNavigateTab});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final fileManager = context.watch<FileManagerProvider>();
    final mediaProvider = context.watch<MediaProvider>();
    final connections = NetworkConnectionsService.getConnections();
    final allCategoriesMap = QuickCategoriesGrid.getAllCategoriesMap(context, isDark, onNavigateTab ?? (index) {});
    final activeList = mediaProvider.categoryOrder
        .where((label) => mediaProvider.activeCategories.contains(label) && allCategoriesMap.containsKey(label))
        .map((label) => allCategoriesMap[label]!)
        .toList();

    return Drawer(
      backgroundColor: theme.scaffoldBackgroundColor,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.only(topRight: Radius.circular(28), bottomRight: Radius.circular(28)),
      ),
      child: SafeArea(
        child: Column(
          children: [
            // Header Banner
            _buildDrawerHeader(context, theme, isDark),
            const SizedBox(height: 8),

            // Scrollable Menu Items
            Expanded(
              child: SingleChildScrollView(
                physics: const BouncingScrollPhysics(),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _buildSectionTitle(context, '导航'),
                    _buildDrawerTile(
                      context,
                      icon: Broken.home,
                      title: '主页',
                      onTap: () {
                        Navigator.pop(context); // Close drawer
                        onNavigateTab?.call(0);
                      },
                    ),
                    for (final vol in fileManager.storageVolumes)
                      _buildDrawerTile(
                        context,
                        icon: vol.isInternal ? Broken.folder_open : Icons.sd_storage_rounded,
                        title: vol.name,
                        isSelected: fileManager.rootPath == vol.path,
                        onTap: () {
                          Navigator.pop(context);
                          fileManager.setRootPath(vol.path);
                          fileManager.loadDirectory(vol.path);
                          onNavigateTab?.call(1);
                        },
                      ),
                    _buildDrawerTile(
                      context,
                      icon: Broken.cpu,
                      title: '系统根目录',
                      isSelected: fileManager.rootPath == '/',
                      onTap: () {
                        Navigator.pop(context);
                        fileManager.setRootPath('/');
                        fileManager.loadDirectory('/');
                        onNavigateTab?.call(1);
                      },
                    ),
                    _buildDrawerTile(
                      context,
                      icon: Broken.search_normal,
                      title: '全局搜索',
                      onTap: () {
                        Navigator.pop(context);
                        Navigator.push(context, MaterialPageRoute(builder: (_) => const GlobalSearchScreen()));
                      },
                    ),
                    _buildDrawerTile(
                      context,
                      icon: Broken.trash,
                      title: '回收站',
                      onTap: () {
                        Navigator.pop(context);
                        Navigator.push(context, MaterialPageRoute(builder: (_) => const RecycleBinScreen()));
                      },
                    ),

                    _buildDivider(context),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12.0, vertical: 2.0),
                      child: Theme(
                        data: theme.copyWith(dividerColor: Colors.transparent),
                        child: ExpansionTile(
                          leading: Icon(Broken.wifi_square, size: 22, color: theme.colorScheme.onSurface.withOpacity(0.8)),
                          title: Text(
                            '服务器与工具',
                            style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: theme.colorScheme.onSurface.withOpacity(0.9)),
                          ),
                          iconColor: theme.colorScheme.primary,
                          textColor: theme.colorScheme.primary,
                          collapsedIconColor: theme.colorScheme.onSurface.withOpacity(0.8),
                          tilePadding: const EdgeInsets.symmetric(horizontal: 16.0),
                          children: [
                            _buildDrawerTile(
                              context,
                              icon: Broken.lock,
                              title: '私密保险箱',
                              onTap: () {
                                Navigator.pop(context);
                                Navigator.push(context, MaterialPageRoute(builder: (_) => const VaultLockScreen()));
                              },
                            ),
                            _buildDrawerTile(
                              context,
                              icon: Broken.wifi,
                              title: 'FTP 服务器',
                              onTap: () {
                                Navigator.pop(context);
                                Navigator.push(context, MaterialPageRoute(builder: (_) => const FtpServerScreen()));
                              },
                            ),
                            _buildDrawerTile(
                              context,
                              icon: Icons.language_rounded,
                              title: '网页共享',
                              onTap: () {
                                Navigator.pop(context);
                                Navigator.push(context, MaterialPageRoute(builder: (_) => const WebSharingScreen()));
                              },
                            ),
                            ...connections.map((conn) {
                              IconData iconData;
                              switch (conn.type) {
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
                              return _buildDrawerTile(
                                context,
                                icon: iconData,
                                title: conn.name,
                                onTap: () {
                                  Navigator.pop(context);
                                  Navigator.push(
                                    context,
                                    MaterialPageRoute(
                                      builder: (_) => RemoteExplorerScreen(connection: conn),
                                    ),
                                  );
                                },
                              );
                            }),
                            _buildDrawerTile(
                              context,
                              icon: Icons.add_link_rounded,
                              title: '添加远程连接',
                              onTap: () {
                                Navigator.pop(context);
                                Navigator.push(
                                  context,
                                  MaterialPageRoute(
                                    builder: (_) => const NetworkConnectionWizardScreen(),
                                  ),
                                );
                              },
                            ),
                          ],
                        ),
                      ),
                    ),

                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12.0, vertical: 2.0),
                      child: Theme(
                        data: theme.copyWith(dividerColor: Colors.transparent),
                        child: ExpansionTile(
                          leading: Icon(Icons.category_rounded, size: 22, color: theme.colorScheme.onSurface.withOpacity(0.8)),
                          title: Text(
                            '快捷分类',
                            style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: theme.colorScheme.onSurface.withOpacity(0.9)),
                          ),
                          iconColor: theme.colorScheme.primary,
                          textColor: theme.colorScheme.primary,
                          collapsedIconColor: theme.colorScheme.onSurface.withOpacity(0.8),
                          tilePadding: const EdgeInsets.symmetric(horizontal: 16.0),
                          children: [
                            ...activeList.map((cat) {
                              final label = cat['label'] as String;
                              final icon = cat['icon'] as IconData;
                              final action = cat['action'] as VoidCallback;

                              return _buildDrawerTile(
                                context,
                                icon: icon,
                                title: label,
                                onTap: () {
                                  Navigator.pop(context);
                                  action();
                                },
                              );
                            }),
                            _buildDrawerTile(
                              context,
                              icon: Icons.add_rounded,
                              title: '添加快捷方式',
                              onTap: () async {
                                final fileManager = context.read<FileManagerProvider>();
                                final mediaProvider = context.read<MediaProvider>();
                                final paths = await InternalFilePickerScreen.show(context, rootPath: fileManager.rootPath);
                                if (context.mounted) {
                                  Navigator.pop(context);
                                }
                                if (paths != null && paths.isNotEmpty) {
                                  for (final p in paths) {
                                    mediaProvider.addCustomShortcut(p);
                                  }
                                }
                              },
                            ),
                          ],
                        ),
                      ),
                    ),

                    _buildDivider(context),
                    _buildSectionTitle(context, '个性化和设置'),
                    _buildDrawerTile(
                      context,
                      icon: isDark ? Broken.sun_1 : Broken.moon,
                      title: isDark ? '浅色模式' : '深色模式',
                      trailing: Transform.scale(
                        scale: 0.85,
                        child: Switch(
                          value: isDark,
                          activeColor: theme.colorScheme.primary,
                          onChanged: (_) => toggleTheme(),
                        ),
                      ),
                      onTap: toggleTheme,
                    ),

                    _buildDrawerTile(
                      context,
                      icon: Broken.setting_2,
                      title: '更多设置',
                      onTap: () {
                        Navigator.pop(context);
                        Navigator.push(context, MaterialPageRoute(builder: (_) => const MoreSettingsScreen()));
                      },
                    ),
                    _buildDrawerTile(
                      context,
                      icon: Broken.info_circle,
                      title: '关于 ZenFile',
                      onTap: () {
                        Navigator.pop(context);
                        Navigator.push(
                          context,
                          MaterialPageRoute(builder: (_) => const AboutZenFileScreen()),
                        );
                      },
                    ),
                    const SizedBox(height: 24),
                  ],
                ),
              ),
            ),

            // Footer Version Info
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12.0),
              child: Text(
                'ZenFile v1.0.0',
                style: TextStyle(fontSize: 11.5, color: theme.colorScheme.onSurface.withOpacity(0.4), fontWeight: FontWeight.w600),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDrawerHeader(BuildContext context, ThemeData theme, bool isDark) {
    return Container(
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
            child: const Icon(Broken.folder, color: Colors.white, size: 28),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'ZenFile',
                  style: TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.bold, letterSpacing: 0.5),
                ),
                const SizedBox(height: 2),
                Text(
                  '精品媒体套件',
                  style: TextStyle(color: Colors.white.withOpacity(0.8), fontSize: 12.5, fontWeight: FontWeight.w500),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSectionTitle(BuildContext context, String title) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(left: 20.0, top: 12.0, bottom: 8.0),
      child: Text(
        title.toUpperCase(),
        style: TextStyle(
          color: theme.colorScheme.primary.withOpacity(0.8),
          fontSize: 11,
          fontWeight: FontWeight.bold,
          letterSpacing: 1.0,
        ),
      ),
    );
  }

  Widget _buildDrawerTile(
    BuildContext context, {
    required IconData icon,
    required String title,
    required VoidCallback onTap,
    Widget? trailing,
    bool isSelected = false,
  }) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12.0, vertical: 2.0),
      child: Material(
        color: isSelected ? theme.colorScheme.primary.withOpacity(0.15) : Colors.transparent,
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(16),
          splashColor: theme.colorScheme.primary.withOpacity(0.15),
          highlightColor: theme.colorScheme.primary.withOpacity(0.08),
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: 16.0, vertical: trailing != null ? 4.0 : 12.0),
            child: Row(
              children: [
                Icon(icon, size: 22, color: isSelected ? theme.colorScheme.primary : theme.colorScheme.onSurface.withOpacity(0.8)),
                const SizedBox(width: 16),
                Expanded(
                  child: Text(
                    title,
                    style: TextStyle(fontSize: 15, fontWeight: isSelected ? FontWeight.bold : FontWeight.w600, color: isSelected ? theme.colorScheme.primary : theme.colorScheme.onSurface.withOpacity(0.9)),
                  ),
                ),
                // ignore: use_null_aware_elements
                if (trailing != null) trailing,
              ],
            ),
          ),
        ),
      ),
    );
  }


  Widget _buildDivider(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20.0, vertical: 8.0),
      child: Divider(color: Theme.of(context).colorScheme.onSurface.withOpacity(0.1), height: 1),
    );
  }

}
