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
import '../../models/network_connection_model.dart';
import 'package:zenfile/l10n/generated/app_localizations.dart';

import '../screens/about_screen.dart';
import '../screens/web_sharing_screen.dart';
import '../../providers/media_provider.dart';
import 'quick_categories_grid.dart';
import '../screens/recycle_bin_screen.dart';
import '../../services/preferences_service.dart';

class ZenFileDrawer extends StatefulWidget {
  final VoidCallback toggleTheme;
  final Function(int)? onNavigateTab;
  final double? width;

  const ZenFileDrawer({super.key, required this.toggleTheme, this.onNavigateTab, this.width});

  @override
  State<ZenFileDrawer> createState() => _ZenFileDrawerState();
}

class _ZenFileDrawerState extends State<ZenFileDrawer> {
  // 各栏目的展开状态，key 对应持久化存储的 sectionKey
  late final Map<String, bool> _sectionExpanded = {};

  @override
  void initState() {
    super.initState();
    // 从持久化存储恢复各栏目展开状态，默认折叠
    const keys = ['local', 'network', 'categories', 'tools', 'settings'];
    for (final key in keys) {
      _sectionExpanded[key] = PreferencesService.getDrawerSectionExpanded(key);
    }
  }

  void _toggleSection(String key, bool expanded) {
    setState(() {
      _sectionExpanded[key] = expanded;
    });
    PreferencesService.saveDrawerSectionExpanded(key, expanded);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final fileManager = context.watch<FileManagerProvider>();
    final mediaProvider = context.watch<MediaProvider>();
    final connections = NetworkConnectionsService.getConnections();
    final allCategoriesMap = QuickCategoriesGrid.getAllCategoriesMap(context, isDark, widget.onNavigateTab ?? (index) {});
    final activeList = mediaProvider.categoryOrder
        .where((label) => mediaProvider.activeCategories.contains(label) && allCategoriesMap.containsKey(label))
        .map((label) => allCategoriesMap[label]!)
        .toList();

    return Drawer(
      width: widget.width,
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
                    // ===== 本地 =====
                    _buildExpandableSection(
                      context,
                      sectionKey: 'local',
                      icon: Broken.folder,
                      title: L10n.of(context).ui_nav,
                      children: [
                        for (final vol in fileManager.storageVolumes)
                          _buildDrawerTile(
                            context,
                            icon: vol.isInternal ? Broken.folder_open : Icons.sd_storage_rounded,
                            title: _getLocalizedVolumeName(context, vol),
                            isSelected: fileManager.rootPath == vol.path,
                            onTap: () {
                              Navigator.pop(context);
                              fileManager.setRootPath(vol.path);
                              fileManager.loadDirectory(vol.path);
                              widget.onNavigateTab?.call(1);
                            },
                          ),
                        _buildDrawerTile(
                          context,
                          icon: Broken.cpu,
                          title: L10n.of(context).msgd730e478,
                          isSelected: fileManager.rootPath == '/',
                          onTap: () {
                            Navigator.pop(context);
                            fileManager.setRootPath('/');
                            fileManager.loadDirectory('/');
                            widget.onNavigateTab?.call(1);
                          },
                        ),
                        _buildDrawerTile(
                          context,
                          icon: Broken.trash,
                          title: L10n.of(context).ui_recycle_bin,
                          onTap: () {
                            Navigator.pop(context);
                            Navigator.push(context, MaterialPageRoute(builder: (_) => const RecycleBinScreen()));
                          },
                        ),
                      ],
                    ),

                    // ===== 网络 =====
                    _buildExpandableSection(
                      context,
                      sectionKey: 'network',
                      icon: Broken.wifi_square,
                      title: L10n.of(context).msgf13fc21c,
                      children: [
                        _buildDrawerTile(
                          context,
                          icon: Broken.wifi,
                          title: L10n.of(context).ftp2,
                          onTap: () {
                            Navigator.pop(context);
                            Navigator.push(context, MaterialPageRoute(builder: (_) => const FtpServerScreen()));
                          },
                        ),
                        _buildDrawerTile(
                          context,
                          icon: Icons.language_rounded,
                          title: L10n.of(context).ui_web_share,
                          onTap: () {
                            Navigator.pop(context);
                            Navigator.push(context, MaterialPageRoute(builder: (_) => const WebSharingScreen()));
                          },
                        ),
                        ...connections.map((conn) {
                          IconData iconData;
                          if (FileManagerProvider.isSmbType(conn.type)) {
                            iconData = Icons.dns_rounded;
                          } else if (conn.type == 'FTP') {
                            iconData = Icons.swap_horizontal_circle_rounded;
                          } else if (conn.type == 'SFTP') {
                            iconData = Icons.vpn_lock_rounded;
                          } else if (conn.type == 'WebDav') {
                            iconData = Icons.web_rounded;
                          } else {
                            iconData = Broken.wifi;
                          }
                          return _buildConnectionTile(
                            context,
                            conn: conn,
                            icon: iconData,
                            title: conn.name,
                          );
                        }),
                        _buildDrawerTile(
                          context,
                          icon: Icons.add_link_rounded,
                          title: L10n.of(context).msg41e625d1,
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

                    // ===== 分类 =====
                    _buildExpandableSection(
                      context,
                      sectionKey: 'categories',
                      icon: Icons.category_rounded,
                      title: L10n.of(context).cat_quick_categories,
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
                          icon: Icons.edit_note_rounded,
                          title: L10n.of(context).msge7d18d73,
                          onTap: () {
                            Navigator.pop(context);
                            QuickCategoriesGrid.showCustomizeDialog(context, widget.onNavigateTab);
                          },
                        ),
                      ],
                    ),

                    // ===== 工具 =====
                    _buildExpandableSection(
                      context,
                      sectionKey: 'tools',
                      icon: Broken.search_normal,
                      title: L10n.of(context).drawer_tools,
                      children: [
                        _buildDrawerTile(
                          context,
                          icon: Broken.search_normal,
                          title: L10n.of(context).msg681c0f39,
                          onTap: () {
                            Navigator.pop(context);
                            Navigator.push(context, MaterialPageRoute(builder: (_) => const GlobalSearchScreen()));
                          },
                        ),
                        _buildDrawerTile(
                          context,
                          icon: Broken.lock,
                          title: L10n.of(context).msgbb590f19,
                          onTap: () {
                            Navigator.pop(context);
                            Navigator.push(context, MaterialPageRoute(builder: (_) => const VaultLockScreen()));
                          },
                        ),
                      ],
                    ),

                    // ===== 设置 =====
                    _buildDrawerTile(
                      context,
                      icon: Broken.setting_2,
                      title: L10n.of(context).ui_personalize_settings,
                      isPrimary: true,
                      onTap: () {
                        Navigator.pop(context);
                        Navigator.push(context, MaterialPageRoute(builder: (_) => const MoreSettingsScreen()));
                      },
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 20.0, vertical: 4.0),
                      child: Divider(color: theme.colorScheme.onSurface.withOpacity(0.08), height: 1),
                    ),
                    _buildDrawerTile(
                      context,
                      icon: Broken.info_circle,
                      title: L10n.of(context).zenfile1,
                      isPrimary: true,
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
                'ZenFile v1.1.2',
                style: TextStyle(fontSize: 11.5, color: theme.colorScheme.onSurface.withOpacity(0.4), fontWeight: FontWeight.w600),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildExpandableSection(
    BuildContext context, {
    required String sectionKey,
    required IconData icon,
    required String title,
    required List<Widget> children,
    bool showDivider = true,
  }) {
    final theme = Theme.of(context);
    final expanded = _sectionExpanded[sectionKey] ?? false;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12.0, vertical: 2.0),
          child: Theme(
            data: theme.copyWith(dividerColor: Colors.transparent),
            child: ExpansionTile(
              leading: Icon(icon, size: 24, color: theme.colorScheme.onSurface.withOpacity(0.8)),
              title: Text(
                title,
                style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: theme.colorScheme.onSurface.withOpacity(0.95)),
              ),
              iconColor: theme.colorScheme.primary,
              textColor: theme.colorScheme.primary,
              collapsedIconColor: theme.colorScheme.onSurface.withOpacity(0.8),
              tilePadding: const EdgeInsets.symmetric(horizontal: 16.0),
              initiallyExpanded: expanded,
              onExpansionChanged: (val) => _toggleSection(sectionKey, val),
              children: children,
            ),
          ),
        ),
        if (showDivider)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20.0, vertical: 4.0),
            child: Divider(color: theme.colorScheme.onSurface.withOpacity(0.08), height: 1),
          ),
      ],
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
                  L10n.of(context).msgeef7e30c,
                  style: TextStyle(color: Colors.white.withOpacity(0.8), fontSize: 12.5, fontWeight: FontWeight.w500),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _getLocalizedVolumeName(BuildContext context, StorageVolume vol) {
    final l10n = L10n.of(context);
    if (vol.isInternal) {
      return l10n.msg21cefa9b; // "内部存储" / "Internal Storage"
    }
    // SD Card / USB volumes
    if (vol.name.startsWith('SD Card')) {
      return l10n.msgbb34b7ec; // fallback if no specific SD card l10n
    }
    return vol.name;
  }

  Future<void> _deleteConnection(BuildContext context, NetworkConnectionModel conn) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text(L10n.of(context).msg432fbb31, style: TextStyle(fontWeight: FontWeight.bold)),
        content: Text(L10n.of(context).msgdeleteconn(conn.name)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(L10n.of(context).ui_cancel),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red, foregroundColor: Colors.white),
            child: Text(L10n.of(context).ui_delete),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await NetworkConnectionsService.deleteConnection(conn.id);
      setState(() {});
    }
  }

  Widget _buildConnectionTile(
    BuildContext context, {
    required NetworkConnectionModel conn,
    required IconData icon,
    required String title,
  }) {
    final theme = Theme.of(context);

    void showOptionsSheet() {
      showModalBottomSheet(
        context: context,
        backgroundColor: Colors.transparent,
        shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
        builder: (ctx) {
          return Container(
            decoration: BoxDecoration(
              color: theme.scaffoldBackgroundColor,
              borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
            ),
            padding: const EdgeInsets.symmetric(vertical: 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ListTile(
                  leading: Icon(Broken.edit, color: theme.colorScheme.primary),
                  title: Text(L10n.of(context).drawer_edit_connection),
                  onTap: () async {
                    Navigator.pop(ctx);
                    await Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => NetworkConnectionWizardScreen(existingConnection: conn),
                      ),
                    );
                    setState(() {});
                  },
                ),
                ListTile(
                  leading: const Icon(Broken.trash, color: Colors.red),
                  title: Text(L10n.of(context).ui_delete),
                  onTap: () async {
                    Navigator.pop(ctx);
                    await _deleteConnection(context, conn);
                  },
                ),
                const SizedBox(height: 8),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: SizedBox(
                    width: double.infinity,
                    child: TextButton(
                      onPressed: () => Navigator.pop(ctx),
                      child: Text(L10n.of(context).ui_cancel),
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12.0, vertical: 2.0),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          onTap: () async {
            // 先捕获引用，pop 后 context 会失效
            final provider = context.read<FileManagerProvider>();
            final onNavigateTab = widget.onNavigateTab;
            final navigator = Navigator.of(context);
            final scaffoldMessenger = ScaffoldMessenger.of(context);
            final client = FileManagerProvider.createRemoteClient(conn);
            try {
              await client.connect();
              // 连接成功后再关闭抽屉并跳转
              if (navigator.mounted) {
                navigator.pop();
                await provider.openRemoteTab(client, conn);
                onNavigateTab?.call(1);
              }
            } catch (e) {
              if (scaffoldMessenger.mounted) {
                scaffoldMessenger.showSnackBar(
                  SnackBar(content: Text('连接失败：$e'), backgroundColor: Colors.redAccent),
                );
              }
            }
          },
          onLongPress: showOptionsSheet,
          borderRadius: BorderRadius.circular(16),
          splashColor: theme.colorScheme.primary.withOpacity(0.15),
          highlightColor: theme.colorScheme.primary.withOpacity(0.08),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 12.0),
            child: Row(
              children: [
                Icon(icon, size: 22, color: theme.colorScheme.onSurface.withOpacity(0.8)),
                const SizedBox(width: 16),
                Expanded(
                  child: Text(
                    title,
                    style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: theme.colorScheme.onSurface.withOpacity(0.9)),
                  ),
                ),
                IconButton(
                  icon: Icon(Icons.more_vert_rounded, size: 20, color: theme.colorScheme.onSurface.withOpacity(0.5)),
                  onPressed: showOptionsSheet,
                  padding: const EdgeInsets.all(4),
                  constraints: const BoxConstraints(),
                ),
              ],
            ),
          ),
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
    bool isPrimary = false,
  }) {
    final theme = Theme.of(context);
    // 一级栏目使用与 _buildExpandableSection 一致的字体样式（fontSize 17 / w700）
    final fontSize = isPrimary ? 17.0 : 15.0;
    final fontWeight = isPrimary
        ? FontWeight.w700
        : (isSelected ? FontWeight.bold : FontWeight.w600);
    final color = isSelected
        ? theme.colorScheme.primary
        : theme.colorScheme.onSurface.withOpacity(isPrimary ? 0.95 : 0.9);
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
                    style: TextStyle(fontSize: fontSize, fontWeight: fontWeight, color: color),
                  ),
                ),
                if (trailing != null) trailing,
              ],
            ),
          ),
        ),
      ),
    );
  }
}
