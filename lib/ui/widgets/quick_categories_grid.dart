import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/icon_fonts/broken_icons.dart';
import '../../providers/media_provider.dart';
import '../../providers/file_manager_provider.dart';
import '../../services/preferences_service.dart';
import '../../services/network_connections_service.dart';
import '../../models/network_connection_model.dart';
import '../screens/media_category_screen.dart';
import '../screens/internal_file_picker_screen.dart';
import '../screens/storage_analyzer/app_manager_screen.dart';
import '../screens/more_settings_screen.dart';
import 'package:zenfile/l10n/generated/app_localizations.dart';

import '../screens/network_connection_wizard_screen.dart';
import '../screens/network_category_screen.dart';
import '../screens/all_recent_files_screen.dart';
import '../screens/ftp_server_screen.dart';
import '../screens/web_sharing_screen.dart';
import '../screens/storage_analyzer/storage_analyzer_screen.dart';

class QuickCategoriesGrid extends StatelessWidget {
  final Function(int) onNavigateTab;
  final bool showTitle;

  const QuickCategoriesGrid({super.key, required this.onNavigateTab, this.showTitle = true});

  static Map<String, Map<String, dynamic>> getAllCategoriesMap(BuildContext context, bool isDark, Function(int) onNavigateTab) {
    final mediaProvider = Provider.of<MediaProvider>(context, listen: false);
    final l10n = L10n.of(context);
    final map = <String, Map<String, dynamic>>{
      '图片': {
        'label': l10n.cat_images,
        'icon': Broken.image,
        'color': isDark ? Colors.purpleAccent : Colors.purple,
        'count': '${mediaProvider.getCategoryItemCount("图片")}',
        'isCustom': false,
        'action': () => Navigator.push(context, MaterialPageRoute(builder: (_) => MediaCategoryScreen(mediaType: MediaType.images, onNavigateTab: onNavigateTab))),
      },
      '视频': {
        'label': l10n.cat_videos,
        'icon': Broken.video,
        'color': isDark ? Colors.redAccent : const Color(0xFFD32F2F),
        'count': '${mediaProvider.getCategoryItemCount("视频")}',
        'isCustom': false,
        'action': () => Navigator.push(context, MaterialPageRoute(builder: (_) => MediaCategoryScreen(mediaType: MediaType.videos, onNavigateTab: onNavigateTab))),
      },
      '音频': {
        'label': l10n.cat_audios,
        'icon': Broken.music,
        'color': isDark ? Colors.orangeAccent : const Color(0xFFE65100),
        'count': '${mediaProvider.getCategoryItemCount("音频")}',
        'isCustom': false,
        'action': () => Navigator.push(context, MaterialPageRoute(builder: (_) => MediaCategoryScreen(mediaType: MediaType.audios, onNavigateTab: onNavigateTab))),
      },
      '文档': {
        'label': l10n.cat_documents,
        'icon': Broken.document,
        'color': isDark ? Colors.blueAccent : const Color(0xFF1976D2),
        'count': '${mediaProvider.getCategoryItemCount("文档")}',
        'isCustom': false,
        'action': () => Navigator.push(context, MaterialPageRoute(builder: (_) => MediaCategoryScreen(mediaType: MediaType.documents, onNavigateTab: onNavigateTab))),
      },
      '压缩包': {
        'label': l10n.msgc806d0fa,
        'icon': Broken.box,
        'color': isDark ? Colors.tealAccent : const Color(0xFF00796B),
        'count': '${mediaProvider.getCategoryItemCount("压缩包")}',
        'isCustom': false,
        'action': () => Navigator.push(context, MaterialPageRoute(builder: (_) => MediaCategoryScreen(mediaType: MediaType.archives, onNavigateTab: onNavigateTab))),
      },
      '下载': {
        'label': l10n.cat_downloads,
        'icon': Broken.document_download,
        'color': isDark ? Colors.greenAccent : const Color(0xFF2E7D32),
        'count': '${mediaProvider.getCategoryItemCount("下载")}',
        'isCustom': false,
        'action': () => Navigator.push(context, MaterialPageRoute(builder: (_) => MediaCategoryScreen(mediaType: MediaType.downloads, onNavigateTab: onNavigateTab))),
      },
      '安装包': {
        'label': l10n.msg03070d08,
        'icon': Broken.box,
        'color': isDark ? Colors.amber : const Color(0xFFF57C00),
        'count': '${mediaProvider.getCategoryItemCount("安装包")}',
        'isCustom': false,
        'action': () => Navigator.push(context, MaterialPageRoute(builder: (_) => MediaCategoryScreen(mediaType: MediaType.apks, onNavigateTab: onNavigateTab))),
      },
      '截图': {
        'label': l10n.cat_screenshots,
        'icon': Broken.mobile,
        'color': isDark ? Colors.pinkAccent : const Color(0xFFC2185B),
        'count': '${mediaProvider.getCategoryItemCount("截图")}',
        'isCustom': false,
        'action': () => Navigator.push(context, MaterialPageRoute(builder: (_) => MediaCategoryScreen(mediaType: MediaType.screenshots, onNavigateTab: onNavigateTab))),
      },
      '最近': {
        'label': l10n.cat_recent,
        'icon': Broken.clock,
        'color': isDark ? Colors.indigoAccent : const Color(0xFF3F51B5),
        'count': '${mediaProvider.getCategoryItemCount("最近")}',
        'isCustom': false,
        'action': () => Navigator.push(context, MaterialPageRoute(builder: (_) => AllRecentFilesScreen(onNavigateTab: onNavigateTab))),
      },
      '网络': {
        'label': l10n.cat_network,
        'icon': Broken.wifi,
        'color': isDark ? Colors.cyanAccent : const Color(0xFF00BCD4),
        'count': '${mediaProvider.getCategoryItemCount("网络")}',
        'isCustom': false,
        'action': () => Navigator.push(context, MaterialPageRoute(builder: (_) => NetworkCategoryScreen(onNavigateTab: onNavigateTab))),
      },
      'FTP共享': {
        'label': l10n.ftp,
        'icon': Icons.swap_horizontal_circle_rounded,
        'color': isDark ? Colors.orangeAccent : const Color(0xFFF57C00),
        'count': l10n.cat_service,
        'isCustom': false,
        'action': () => Navigator.push(context, MaterialPageRoute(builder: (_) => const FtpServerScreen())),
      },
      'Web共享': {
        'label': l10n.web,
        'icon': Icons.language_rounded,
        'color': isDark ? Colors.deepPurpleAccent : const Color(0xFF7B1FA2),
        'count': l10n.cat_service,
        'isCustom': false,
        'action': () => Navigator.push(context, MaterialPageRoute(builder: (_) => const WebSharingScreen())),
      },
      '应用': {
        'label': l10n.cat_apps,
        'icon': Broken.mobile,
        'color': isDark ? Colors.lightGreenAccent : const Color(0xFF4CAF50),
        'count': l10n.cat_manage,
        'isCustom': false,
        'action': () => Navigator.push(context, MaterialPageRoute(builder: (_) => const AppManagerScreen())),
      },
      '设置': {
        'label': l10n.cat_settings,
        'icon': Broken.setting_2,
        'color': isDark ? Colors.blueGrey.shade300 : Colors.blueGrey,
        'count': l10n.cat_config,
        'isCustom': false,
        'action': () => Navigator.push(context, MaterialPageRoute(builder: (_) => const MoreSettingsScreen())),
      },
      '存储': {
        'label': l10n.cat_storage,
        'icon': Broken.driver,
        'color': isDark ? Colors.cyanAccent : const Color(0xFF00ACC1),
        'count': l10n.cat_analyze,
        'isCustom': false,
        'action': () => Navigator.push(context, MaterialPageRoute(builder: (_) => const StorageAnalyzerScreen())),
      },
    };

    for (final cs in mediaProvider.customShortcuts) {
      map[cs.id] = {
        'label': cs.label,
        'icon': cs.isDirectory ? Broken.folder : Broken.document,
        'color': isDark ? Colors.cyanAccent : Colors.cyan,
        'count': cs.isDirectory ? L10n.of(context).msg1f4c1042 : L10n.of(context).ui_file,
        'isCustom': true,
        'path': cs.path,
        'action': () {
          if (cs.isDirectory) {
            final fileManager = context.read<FileManagerProvider>();
            fileManager.loadDirectory(cs.path);
            onNavigateTab(1);
          } else {
            final fileManager = context.read<FileManagerProvider>();
            fileManager.openFile(context, cs.path);
          }
        },
      };
    }

    return map;
  }

  static void _showNetworkConnectionsSheet(BuildContext context) {
    final theme = Theme.of(context);
    final connections = NetworkConnectionsService.getConnections();

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: theme.scaffoldBackgroundColor,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (ctx) {
        return DraggableScrollableSheet(
          initialChildSize: 0.5,
          minChildSize: 0.3,
          maxChildSize: 0.9,
          expand: false,
          builder: (ctx, scrollController) {
            return Column(
              children: [
                const SizedBox(height: 12),
                Container(width: 40, height: 4, decoration: BoxDecoration(color: Colors.grey.withOpacity(0.3), borderRadius: BorderRadius.circular(2))),
                const SizedBox(height: 16),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20.0),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(L10n.of(context).msgce1ec2ce, style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold)),
                      TextButton(
                        onPressed: () => Navigator.pop(ctx),
                        child: Text(L10n.of(context).ui_close, style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                      ),
                    ],
                  ),
                ),
                if (connections.isEmpty)
                  Expanded(
                    child: Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Broken.wifi, size: 48, color: theme.colorScheme.onSurface.withOpacity(0.2)),
                          const SizedBox(height: 16),
                          Text(L10n.of(context).msgc9c900d0, style: TextStyle(color: theme.colorScheme.onSurface.withOpacity(0.5), fontSize: 15)),
                          const SizedBox(height: 8),
                          TextButton.icon(
                            onPressed: () {
                              Navigator.pop(ctx);
                              Navigator.push(context, MaterialPageRoute(builder: (_) => const NetworkConnectionWizardScreen()));
                            },
                            icon: const Icon(Broken.add, size: 18),
                            label: Text(L10n.of(context).msg3358aa10),
                          ),
                        ],
                      ),
                    ),
                  )
                else
                  Expanded(
                    child: ListView.builder(
                      controller: scrollController,
                      physics: const BouncingScrollPhysics(),
                      padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
                      itemCount: connections.length + 1,
                      itemBuilder: (context, index) {
                        if (index == connections.length) {
                          return Padding(
                            padding: const EdgeInsets.symmetric(vertical: 8.0),
                            child: OutlinedButton.icon(
                              onPressed: () {
                                Navigator.pop(ctx);
                                Navigator.push(context, MaterialPageRoute(builder: (_) => const NetworkConnectionWizardScreen()));
                              },
                              icon: const Icon(Broken.add, size: 18),
                              label: Text(L10n.of(context).msgc31116e3, style: TextStyle(fontWeight: FontWeight.bold)),
                              style: OutlinedButton.styleFrom(
                                minimumSize: const Size.fromHeight(48),
                                foregroundColor: theme.colorScheme.primary,
                                side: BorderSide(color: theme.colorScheme.primary.withOpacity(0.5)),
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                              ),
                            ),
                          );
                        }
                        final conn = connections[index];
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
                        return ListTile(
                          leading: Container(
                            width: 42,
                            height: 42,
                            decoration: BoxDecoration(color: theme.colorScheme.primary.withOpacity(0.1), shape: BoxShape.circle),
                            child: Icon(iconData, color: theme.colorScheme.primary, size: 20),
                          ),
                          title: Text(conn.name, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15)),
                          subtitle: Text('${conn.type} · ${conn.host}', style: TextStyle(fontSize: 12, color: theme.colorScheme.onSurface.withOpacity(0.5)), maxLines: 1, overflow: TextOverflow.ellipsis),
                          trailing: const Icon(Icons.chevron_right_rounded),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                          onTap: () async {
                            Navigator.pop(ctx);
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
                                  SnackBar(content: Text(L10n.of(context).e13(e)), backgroundColor: Colors.redAccent),
                                );
                              }
                            }
                          },
                        );
                      },
                    ),
                  ),
              ],
            );
          },
        );
      },
    );
  }

  static void showCustomizeDialog(BuildContext context, [Function(int)? onNavigateTab]) {
    final theme = Theme.of(context);
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: theme.scaffoldBackgroundColor,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (context) {
        return _CustomizeCategoriesSheet(onNavigateTab: onNavigateTab ?? (index) {
          Navigator.popUntil(context, (route) => route.isFirst);
        });
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final mediaProvider = context.watch<MediaProvider>();
    final fileManagerProvider = context.watch<FileManagerProvider>();

    final allCategoriesMap = getAllCategoriesMap(context, isDark, onNavigateTab);

    final activeList = mediaProvider.categoryOrder
        .where((label) => mediaProvider.activeCategories.contains(label) && allCategoriesMap.containsKey(label))
        .map((label) => allCategoriesMap[label]!)
        .toList();

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (showTitle)
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  L10n.of(context).cat_quick_categories,
                  style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold, fontSize: 18),
                ),
                InkWell(
                  onTap: () => showCustomizeDialog(context, onNavigateTab),
                  borderRadius: BorderRadius.circular(16),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8.0, vertical: 4.0),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Broken.edit_2, size: 16, color: theme.colorScheme.primary),
                        const SizedBox(width: 4),
                        Text(
                          L10n.of(context).msgf1d4ff50,
                          style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.primary, fontWeight: FontWeight.w600),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            )
          else
            const SizedBox.shrink(),
          const SizedBox(height: 12),
          if (activeList.isEmpty)
            Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 24.0),
                child: Text(
                  L10n.of(context).msg490ac572,
                  style: TextStyle(color: theme.colorScheme.onSurface.withOpacity(0.5)),
                ),
              ),
            )
          else
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 300),
              child: GridView.builder(
                key: ValueKey(activeList.length),
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 3,
                  crossAxisSpacing: 16,
                  mainAxisSpacing: 8,
                  childAspectRatio: 0.75,
                ),
                itemCount: activeList.length,
                itemBuilder: (context, index) {
                  final cat = activeList[index];
                  final label = cat['label'] as String;
                  final icon = cat['icon'] as IconData;
                  final color = cat['color'] as Color;
                  final count = cat['count'] as String;
                  final action = cat['action'] as VoidCallback;
                  final shape = fileManagerProvider.categoryIconShape;
                  final isSquare = shape == 'square';

                  return Column(
                    key: ValueKey(label),
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Material(
                        color: color.withOpacity(0.15),
                        shape: isSquare ? RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)) : const CircleBorder(),
                        child: InkWell(
                          onTap: action,
                          customBorder: isSquare ? RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)) : const CircleBorder(),
                          splashColor: color.withOpacity(0.25),
                          highlightColor: color.withOpacity(0.15),
                          child: Container(
                            width: 64,
                            height: 64,
                            alignment: Alignment.center,
                            child: Icon(icon, color: color, size: 28),
                          ),
                        ),
                      ),
                      const SizedBox(height: 10),
                      Text(
                        label,
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                          fontSize: 14,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 2),
                      Text(
                        count,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.textTheme.bodySmall?.color?.withOpacity(0.6),
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  );
                },
              ),
            ),
        ],
      ),
    );
  }
}

class _CustomizeCategoriesSheet extends StatelessWidget {
  final Function(int) onNavigateTab;

  const _CustomizeCategoriesSheet({required this.onNavigateTab});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return DraggableScrollableSheet(
      initialChildSize: 0.7,
      minChildSize: 0.4,
      maxChildSize: 0.95,
      expand: false,
      builder: (context, scrollController) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            final iconShape = PreferencesService.getCategoryIconShape();
        return Consumer<MediaProvider>(
          builder: (context, provider, child) {
            final activeCats = provider.activeCategories;
            final order = provider.categoryOrder;
            final categoriesMap = QuickCategoriesGrid.getAllCategoriesMap(context, isDark, onNavigateTab);

            return Column(
              children: [
                const SizedBox(height: 12),
                Container(width: 40, height: 4, decoration: BoxDecoration(color: Colors.grey.withOpacity(0.3), borderRadius: BorderRadius.circular(2))),
                const SizedBox(height: 16),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20.0),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(L10n.of(context).msge7d18d73, style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold)),
                      TextButton(onPressed: () => Navigator.pop(context), child: Text(L10n.of(context).ui_done, style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16))),
                    ],
                  ),
                ),
                // 分类图标形状选项
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20.0, vertical: 8.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(L10n.of(context).msg2c3c5a35, style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold, fontSize: 16)),
                      const SizedBox(height: 10),
                      Row(
                        children: [
                          _buildShapeOption(context, theme, iconShape, 'circle', Icons.circle_outlined, L10n.of(context).ui_circle, setModalState),
                          const SizedBox(width: 8),
                          _buildShapeOption(context, theme, iconShape, 'square', Icons.crop_square, L10n.of(context).ui_square, setModalState),
                        ],
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20.0, vertical: 4.0),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      L10n.of(context).msg445a43cb,
                      style: TextStyle(color: theme.colorScheme.onSurface.withOpacity(0.6), fontSize: 13),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20.0),
                  child: OutlinedButton.icon(
                    icon: const Icon(Broken.add, size: 20),
                    label: Text(L10n.of(context).msg944d5ecd, style: TextStyle(fontWeight: FontWeight.bold)),
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size.fromHeight(46),
                      foregroundColor: theme.colorScheme.primary,
                      side: BorderSide(color: theme.colorScheme.primary.withOpacity(0.5)),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                    ),
                    onPressed: () async {
                      final fileManager = context.read<FileManagerProvider>();
                      final paths = await InternalFilePickerScreen.show(context, rootPath: fileManager.rootPath);
                      if (paths != null && paths.isNotEmpty) {
                        for (final p in paths) {
                          provider.addCustomShortcut(p);
                        }
                      }
                    },
                  ),
                ),
                const SizedBox(height: 8),
                const Divider(),
                Expanded(
                  child: ReorderableListView.builder(
                    scrollController: scrollController,
                    physics: const BouncingScrollPhysics(),
                    onReorder: (oldIndex, newIndex) => provider.reorderCategory(oldIndex, newIndex),
                    itemCount: order.length,
                    itemBuilder: (context, index) {
                      final label = order[index];
                      final cat = categoriesMap[label];
                      if (cat == null) return const SizedBox.shrink(key: ValueKey('empty'));

                      final icon = cat['icon'] as IconData;
                      final color = cat['color'] as Color;
                      final isEnabled = activeCats.contains(label);
                      final isCustom = cat['isCustom'] == true;

                      return CategoryItemWidget(
                        key: ValueKey(label),
                        label: label,
                        cat: cat,
                        isEnabled: isEnabled,
                        provider: provider,
                        index: index,
                      );
                    },
                  ),
                ),
              ],
            );
          },
        );
          },
        );
      },
    );
  }

  static Widget _buildShapeOption(BuildContext context, ThemeData theme, String currentShape, String shapeKey, IconData icon, String label, void Function(void Function()) setModalState) {
    final isSelected = currentShape == shapeKey;
    return InkWell(
      onTap: () {
        PreferencesService.saveCategoryIconShape(shapeKey);
        context.read<FileManagerProvider>().setCategoryIconShape(shapeKey);
        setModalState(() {});
      },
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: isSelected ? theme.colorScheme.primary : theme.colorScheme.surfaceVariant.withOpacity(0.3),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: isSelected ? theme.colorScheme.primary : theme.colorScheme.onSurface.withOpacity(0.1)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 14, color: isSelected ? theme.colorScheme.onPrimary : theme.colorScheme.onSurface.withOpacity(0.6)),
            const SizedBox(width: 4),
            Text(label, style: TextStyle(fontSize: 12, fontWeight: isSelected ? FontWeight.bold : FontWeight.w500, color: isSelected ? theme.colorScheme.onPrimary : theme.colorScheme.onSurface.withOpacity(0.7))),
          ],
        ),
      ),
    );
  }
}

class CategoryItemWidget extends StatefulWidget {
  final String label;
  final Map<String, dynamic> cat;
  final bool isEnabled;
  final MediaProvider provider;
  final int index;

  const CategoryItemWidget({
    super.key,
    required this.label,
    required this.cat,
    required this.isEnabled,
    required this.provider,
    required this.index,
  });

  @override
  State<CategoryItemWidget> createState() => _CategoryItemWidgetState();
}

class _CategoryItemWidgetState extends State<CategoryItemWidget> {
  bool _isExpanded = false;

  List<String> _getDefaultPaths(String category) {
    switch (category) {
      case '图片':
        return [L10n.of(context).msge86bd662, '/storage/emulated/0/DCIM', '/storage/emulated/0/Pictures'];
      case '视频':
        return [L10n.of(context).msge86bd662, '/storage/emulated/0/DCIM', '/storage/emulated/0/Movies'];
      case '音频':
        return [L10n.of(context).msg16166a01, '/storage/emulated/0/Music'];
      case '文档':
        return ['/storage/emulated/0/Documents', L10n.of(context).msgbb34b7ec];
      case '压缩包':
        return ['/storage/emulated/0/Download', L10n.of(context).msgbb34b7ec];
      case '下载':
        return ['/storage/emulated/0/Download', '/storage/emulated/0/Downloads'];
      case '安装包':
        return ['/storage/emulated/0/Download', L10n.of(context).msgbb34b7ec];
      case '截图':
        return [L10n.of(context).msg26a1f2d9, '/storage/emulated/0/DCIM/Screenshots', '/storage/emulated/0/Pictures/Screenshots'];
      default:
        return [];
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final iconShape = context.watch<FileManagerProvider>().categoryIconShape;
    final isCustom = widget.cat['isCustom'] == true;
    final label = widget.label;
    final color = widget.cat['color'] as Color;
    final icon = widget.cat['icon'] as IconData;

    final isStandardCategory = const [
      '图片',
      '视频',
      '音频',
      '文档',
      '压缩包',
      '下载',
      '安装包',
      '截图',
      '网络',
      '最近',
      'FTP共享',
      'Web共享',
    ].contains(label);

    final customPaths = widget.provider.customCategoryPaths[label] ?? [];

    return Column(
      key: ValueKey(label),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ListTile(
          leading: Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              color: color.withOpacity(0.15),
              shape: iconShape == 'square'
                  ? BoxShape.rectangle
                  : BoxShape.circle,
              borderRadius: iconShape == 'square'
                  ? BorderRadius.circular(6)
                  : null,
            ),
            child: Icon(icon, color: color, size: 22),
          ),
          title: Row(
            children: [
              Expanded(
                child: Text(widget.cat['label'] as String, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15)),
              ),
              if (isStandardCategory) ...[
                IconButton(
                  icon: Icon(
                    _isExpanded ? Icons.keyboard_arrow_up : Icons.keyboard_arrow_down,
                    size: 20,
                    color: theme.colorScheme.primary,
                  ),
                  onPressed: () {
                    setState(() {
                      _isExpanded = !_isExpanded;
                    });
                  },
                  visualDensity: VisualDensity.compact,
                  tooltip: L10n.of(context).msg4f356348,
                ),
              ],
            ],
          ),
          subtitle: isCustom
              ? Text(widget.cat['path'] as String, style: TextStyle(fontSize: 11, color: theme.colorScheme.onSurface.withOpacity(0.5)), maxLines: 1, overflow: TextOverflow.ellipsis)
              : (isStandardCategory && customPaths.isNotEmpty
                  ? Text(L10n.of(context).ui_added_custom_paths(customPaths.length), style: TextStyle(fontSize: 11, color: theme.colorScheme.primary, fontWeight: FontWeight.w500))
                  : null),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (isCustom) ...[
                IconButton(
                  icon: const Icon(Broken.trash, color: Colors.redAccent, size: 20),
                  tooltip: L10n.of(context).msg94733bec,
                  onPressed: () => widget.provider.removeCustomShortcut(label),
                ),
                const SizedBox(width: 4),
              ],
              Switch(
                value: widget.isEnabled,
                activeColor: theme.colorScheme.primary,
                onChanged: (val) => widget.provider.toggleCategory(label),
              ),
              const SizedBox(width: 12),
              ReorderableDragStartListener(
                index: widget.index,
                child: const Icon(Icons.drag_handle, color: Colors.grey, size: 24),
              ),
            ],
          ),
        ),
        if (isStandardCategory && _isExpanded) ...[
          Padding(
            padding: const EdgeInsets.only(left: 72.0, right: 16.0, bottom: 8.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  L10n.of(context).ui_default_scan_locations,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                    color: theme.colorScheme.primary.withOpacity(0.8),
                    letterSpacing: 0.5,
                  ),
                ),
                const SizedBox(height: 4),
                ..._getDefaultPaths(label).map((path) {
                  final isExcluded = widget.provider.excludedDefaultPaths[label]?.contains(path) == true;
                  return Container(
                    margin: const EdgeInsets.symmetric(vertical: 4),
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    decoration: BoxDecoration(
                      color: isExcluded
                          ? theme.colorScheme.error.withOpacity(0.03)
                          : theme.colorScheme.primary.withOpacity(0.05),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                        color: isExcluded
                            ? theme.colorScheme.error.withOpacity(0.1)
                            : theme.colorScheme.primary.withOpacity(0.1),
                      ),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          Icons.folder_shared_outlined,
                          size: 16,
                          color: isExcluded
                              ? theme.colorScheme.error.withOpacity(0.5)
                              : theme.colorScheme.primary,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            path,
                            style: TextStyle(
                              fontSize: 12,
                              color: isExcluded
                                  ? theme.colorScheme.onSurface.withOpacity(0.4)
                                  : theme.colorScheme.onSurface.withOpacity(0.85),
                              decoration: isExcluded ? TextDecoration.lineThrough : null,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (isExcluded)
                          IconButton(
                            icon: const Icon(Icons.add_circle_outline, color: Colors.green, size: 18),
                            tooltip: L10n.of(context).msg5c29ad2f,
                            onPressed: () {
                              widget.provider.includeDefaultCategoryPath(label, path);
                            },
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(),
                            visualDensity: VisualDensity.compact,
                          )
                        else
                          IconButton(
                            icon: const Icon(Broken.trash, color: Colors.redAccent, size: 18),
                            tooltip: L10n.of(context).ui_exclude_location,
                            onPressed: () {
                              widget.provider.excludeDefaultCategoryPath(label, path);
                            },
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(),
                            visualDensity: VisualDensity.compact,
                          ),
                      ],
                    ),
                  );
                }),
                const SizedBox(height: 12),
                Text(
                  L10n.of(context).msg21de5dd7,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                    color: theme.colorScheme.onSurface.withOpacity(0.6),
                    letterSpacing: 0.5,
                  ),
                ),
                const SizedBox(height: 4),
                if (customPaths.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4.0),
                    child: Text(
                      L10n.of(context).msg4bb81f99,
                      style: TextStyle(color: theme.colorScheme.onSurface.withOpacity(0.4), fontSize: 12, fontStyle: FontStyle.italic),
                    ),
                  )
                else
                  ...customPaths.map((path) => Container(
                        margin: const EdgeInsets.symmetric(vertical: 4),
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                        decoration: BoxDecoration(
                          color: theme.colorScheme.surfaceVariant.withOpacity(0.3),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Row(
                          children: [
                            const Icon(Broken.folder, size: 16, color: Colors.grey),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                path,
                                style: const TextStyle(fontSize: 12),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            IconButton(
                              icon: const Icon(Broken.trash, color: Colors.redAccent, size: 18),
                              onPressed: () {
                                widget.provider.removeCustomCategoryPath(label, path);
                              },
                              padding: EdgeInsets.zero,
                              constraints: const BoxConstraints(),
                              visualDensity: VisualDensity.compact,
                            ),
                          ],
                        ),
                      )),
                const SizedBox(height: 8),
                TextButton.icon(
                  onPressed: () async {
                    final fileManager = context.read<FileManagerProvider>();
                    final pickedPaths = await InternalFilePickerScreen.show(
                      context,
                      rootPath: fileManager.rootPath,
                      pickDirectory: true,
                    );
                    if (pickedPaths != null && pickedPaths.isNotEmpty) {
                      for (final p in pickedPaths) {
                        widget.provider.addCustomCategoryPath(label, p);
                      }
                    }
                  },
                  icon: const Icon(Broken.folder_add, size: 16),
                  label: Text(L10n.of(context).ui_add_custom_path, style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                  style: TextButton.styleFrom(
                    foregroundColor: theme.colorScheme.primary,
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                    backgroundColor: theme.colorScheme.primary.withOpacity(0.08),
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
        ],
      ],
    );
  }
}
