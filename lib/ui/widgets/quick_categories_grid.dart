import 'dart:math';
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

import '../screens/network_category_screen.dart';
import '../screens/all_recent_files_screen.dart';
import '../screens/ftp_server_screen.dart';
import '../screens/web_sharing_screen.dart';
import '../screens/storage_analyzer/storage_analyzer_screen.dart';
import '../screens/vault_lock_screen.dart';
import '../screens/recycle_bin_screen.dart';
import '../../services/recycle_bin_service.dart';
import '../../services/remote/remote_client.dart';

class QuickCategoriesGrid extends StatefulWidget {
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
        'pageBuilder': () => MediaCategoryScreen(mediaType: MediaType.images, onNavigateTab: onNavigateTab),
      },
      '视频': {
        'label': l10n.cat_videos,
        'icon': Broken.video,
        'color': isDark ? Colors.redAccent : const Color(0xFFD32F2F),
        'count': '${mediaProvider.getCategoryItemCount("视频")}',
        'isCustom': false,
        'pageBuilder': () => MediaCategoryScreen(mediaType: MediaType.videos, onNavigateTab: onNavigateTab),
      },
      '音频': {
        'label': l10n.cat_audios,
        'icon': Broken.music,
        'color': isDark ? Colors.orangeAccent : const Color(0xFFE65100),
        'count': '${mediaProvider.getCategoryItemCount("音频")}',
        'isCustom': false,
        'pageBuilder': () => MediaCategoryScreen(mediaType: MediaType.audios, onNavigateTab: onNavigateTab),
      },
      '文档': {
        'label': l10n.cat_documents,
        'icon': Broken.document,
        'color': isDark ? Colors.blueAccent : const Color(0xFF1976D2),
        'count': '${mediaProvider.getCategoryItemCount("文档")}',
        'isCustom': false,
        'pageBuilder': () => MediaCategoryScreen(mediaType: MediaType.documents, onNavigateTab: onNavigateTab),
      },
      '压缩包': {
        'label': l10n.msgc806d0fa,
        'icon': Broken.archive,
        'color': isDark ? Colors.tealAccent : const Color(0xFF00796B),
        'count': '${mediaProvider.getCategoryItemCount("压缩包")}',
        'isCustom': false,
        'pageBuilder': () => MediaCategoryScreen(mediaType: MediaType.archives, onNavigateTab: onNavigateTab),
      },
      '下载': {
        'label': l10n.cat_downloads,
        'icon': Broken.document_download,
        'color': isDark ? Colors.greenAccent : const Color(0xFF2E7D32),
        'count': '${mediaProvider.getCategoryItemCount("下载")}',
        'isCustom': false,
        'pageBuilder': () => MediaCategoryScreen(mediaType: MediaType.downloads, onNavigateTab: onNavigateTab),
      },
      '安装包': {
        'label': l10n.msg03070d08,
        'icon': Broken.box,
        'color': isDark ? Colors.amber : const Color(0xFFF57C00),
        'count': '${mediaProvider.getCategoryItemCount("安装包")}',
        'isCustom': false,
        'pageBuilder': () => MediaCategoryScreen(mediaType: MediaType.apks, onNavigateTab: onNavigateTab),
      },
      '截图': {
        'label': l10n.cat_screenshots,
        'icon': Broken.mobile,
        'color': isDark ? Colors.pinkAccent : const Color(0xFFC2185B),
        'count': '${mediaProvider.getCategoryItemCount("截图")}',
        'isCustom': false,
        'pageBuilder': () => MediaCategoryScreen(mediaType: MediaType.screenshots, onNavigateTab: onNavigateTab),
      },
      '最近': {
        'label': l10n.cat_recent,
        'icon': Broken.clock,
        'color': isDark ? Colors.indigoAccent : const Color(0xFF3F51B5),
        'count': '${mediaProvider.getCategoryItemCount("最近")}',
        'isCustom': false,
        'pageBuilder': () => AllRecentFilesScreen(onNavigateTab: onNavigateTab),
      },
      '网络': {
        'label': l10n.cat_network,
        'icon': Broken.wifi,
        'color': isDark ? Colors.cyanAccent : const Color(0xFF00BCD4),
        'count': '${mediaProvider.getCategoryItemCount("网络")}',
        'isCustom': false,
        'pageBuilder': () => NetworkCategoryScreen(onNavigateTab: onNavigateTab),
      },
      'FTP共享': {
        'label': l10n.ftp,
        'icon': Icons.swap_horizontal_circle_rounded,
        'color': isDark ? Colors.orangeAccent : const Color(0xFFF57C00),
        'count': l10n.cat_service,
        'isCustom': false,
        'pageBuilder': () => const FtpServerScreen(),
      },
      'Web共享': {
        'label': l10n.web,
        'icon': Icons.language_rounded,
        'color': isDark ? Colors.deepPurpleAccent : const Color(0xFF7B1FA2),
        'count': l10n.cat_service,
        'isCustom': false,
        'pageBuilder': () => const WebSharingScreen(),
      },
      '应用': {
        'label': l10n.cat_apps,
        'icon': Broken.mobile,
        'color': isDark ? Colors.lightGreenAccent : const Color(0xFF4CAF50),
        'count': l10n.cat_manage,
        'isCustom': false,
        'pageBuilder': () => const AppManagerScreen(),
      },
      '设置': {
        'label': l10n.cat_settings,
        'icon': Broken.setting_2,
        'color': isDark ? Colors.blueGrey.shade300 : Colors.blueGrey,
        'count': l10n.cat_config,
        'isCustom': false,
        'pageBuilder': () => const MoreSettingsScreen(),
      },
      '存储': {
        'label': l10n.cat_storage,
        'icon': Broken.driver,
        'color': isDark ? Colors.cyanAccent : const Color(0xFF00ACC1),
        'count': l10n.cat_analyze,
        'isCustom': false,
        'pageBuilder': () => const StorageAnalyzerScreen(),
      },
      '保险箱': {
        'label': l10n.cat_vault,
        'icon': Broken.security_safe,
        'color': isDark ? Colors.yellowAccent : const Color(0xFFFFB300),
        'count': l10n.cat_vault_desc,
        'isCustom': false,
        'pageBuilder': () => const VaultLockScreen(),
      },
      '回收站': {
        'label': l10n.ui_recycle_bin,
        'icon': Broken.trash,
        'color': isDark ? Colors.blueGrey.shade300 : Colors.blueGrey,
        'count': '${RecycleBinService.getTrashItems().length}',
        'isCustom': false,
        'pageBuilder': () => const RecycleBinScreen(),
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

    // 为所有有 pageBuilder 但无 action 的项生成 action（兼容抽屉等旧调用方）
    for (final entry in map.entries) {
      final cat = entry.value;
      if (cat['action'] == null && cat['pageBuilder'] != null) {
        final pageBuilder = cat['pageBuilder'] as Widget Function();
        cat['action'] = () => Navigator.push(context, MaterialPageRoute(builder: (_) => pageBuilder()));
      }
    }

    return map;
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
  State<QuickCategoriesGrid> createState() => _QuickCategoriesGridState();
}

class _QuickCategoriesGridState extends State<QuickCategoriesGrid> {
  /// 从图标位置扩散进入目标页面
  void _navigateWithExpand({
    required GlobalKey iconKey,
    required Color color,
    required Widget targetPage,
  }) {
    final renderBox = iconKey.currentContext?.findRenderObject() as RenderBox?;
    if (renderBox == null) {
      Navigator.push(context, MaterialPageRoute(builder: (_) => targetPage));
      return;
    }

    final iconPos = renderBox.localToGlobal(Offset.zero);
    final iconSize = renderBox.size;
    final center = Offset(
      iconPos.dx + iconSize.width / 2,
      iconPos.dy + iconSize.height / 2,
    );

    final screenSize = MediaQuery.of(context).size;
    final dx = max(center.dx, screenSize.width - center.dx);
    final dy = max(center.dy, screenSize.height - center.dy);
    final radius = sqrt(dx * dx + dy * dy);

    Navigator.push(
      context,
      _RadialExpandRoute(
        center: center,
        maxRadius: radius,
        color: color,
        child: targetPage,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final mediaProvider = context.watch<MediaProvider>();
    final fileManagerProvider = context.watch<FileManagerProvider>();

    final allCategoriesMap = QuickCategoriesGrid.getAllCategoriesMap(context, isDark, widget.onNavigateTab);

    final activeList = mediaProvider.categoryOrder
        .where((label) => mediaProvider.activeCategories.contains(label) && allCategoriesMap.containsKey(label))
        .map((label) => allCategoriesMap[label]!)
        .toList();

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (widget.showTitle)
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  L10n.of(context).cat_quick_categories,
                  style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold, fontSize: 18),
                ),
                InkWell(
                  onTap: () => QuickCategoriesGrid.showCustomizeDialog(context, widget.onNavigateTab),
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
                  final pageBuilder = cat['pageBuilder'] as Widget Function()?;
                  final action = cat['action'] as VoidCallback?;
                  final shape = fileManagerProvider.categoryIconShape;
                  final isSquare = shape == 'square';
                  final iconKey = GlobalKey();

                  return Column(
                    key: ValueKey(label),
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Material(
                        key: iconKey,
                        color: color.withOpacity(0.15),
                        shape: isSquare ? RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)) : const CircleBorder(),
                        child: InkWell(
                          onTap: () {
                            if (pageBuilder != null) {
                              _navigateWithExpand(
                                iconKey: iconKey,
                                color: color,
                                targetPage: pageBuilder(),
                              );
                            } else {
                              action?.call();
                            }
                          },
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

/// 从图标中心扩散的圆形遮罩动画路由
class _RadialExpandRoute extends PageRouteBuilder<void> {
  final Offset center;
  final double maxRadius;
  final Color color;
  final Widget child;

  _RadialExpandRoute({
    required this.center,
    required this.maxRadius,
    required this.color,
    required this.child,
  }) : super(
    transitionDuration: const Duration(milliseconds: 400),
    reverseTransitionDuration: const Duration(milliseconds: 350),
    pageBuilder: (context, animation, secondaryAnimation) => child,
    transitionsBuilder: (context, animation, secondaryAnimation, page) {
      return _RadialTransition(
        center: center,
        maxRadius: maxRadius,
        color: color,
        animation: animation,
        child: page,
      );
    },
  );
}

class _RadialTransition extends StatelessWidget {
  final Offset center;
  final double maxRadius;
  final Color color;
  final Animation<double> animation;
  final Widget child;

  const _RadialTransition({
    required this.center,
    required this.maxRadius,
    required this.color,
    required this.animation,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: animation,
      builder: (context, _) {
        // 动画完成后直接显示目标页面，避免彩色蒙层遮挡内容
        if (animation.value >= 1.0) {
          return child;
        }
        // 进入时圆形从0扩展到maxRadius，退出时反向
        final radius = animation.value * maxRadius;
        return Stack(
          children: [
            // 底层：扩散的彩色圆形
            ClipPath(
              clipper: _CircleClipper(center: center, radius: radius),
              child: ColoredBox(
                color: color.withOpacity(0.15 * animation.value),
                child: child,
              ),
            ),
          ],
        );
      },
    );
  }
}

class _CircleClipper extends CustomClipper<Path> {
  final Offset center;
  final double radius;

  _CircleClipper({required this.center, required this.radius});

  @override
  Path getClip(Size size) {
    return Path()
      ..addOval(Rect.fromCircle(center: center, radius: radius));
  }

  @override
  bool shouldReclip(covariant _CircleClipper oldDelegate) {
    return oldDelegate.radius != radius;
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

  /// 支持远程服务器自定义路径的分类
  static const _remotePathCategories = [
    '图片',
    '视频',
    '音频',
    '文档',
    '压缩包',
    '下载',
    '安装包',
    '截图',
  ];

  /// 显示远程服务器目录选择器，返回 `remote://{connectionId}|{path}` 格式的路径。
  Future<String?> _showRemotePathPicker(BuildContext context) async {
    final theme = Theme.of(context);
    final connections = NetworkConnectionsService.getConnections();

    if (connections.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(L10n.of(context).ui_no_remote_connections),
          backgroundColor: Colors.orangeAccent,
        ),
      );
      return null;
    }

    // Step 1: 选择远程连接
    final NetworkConnectionModel? selectedConn = await showModalBottomSheet<NetworkConnectionModel>(
      context: context,
      isScrollControlled: true,
      backgroundColor: theme.scaffoldBackgroundColor,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (ctx) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: 12),
              Container(width: 40, height: 4, decoration: BoxDecoration(color: Colors.grey.withOpacity(0.3), borderRadius: BorderRadius.circular(2))),
              const SizedBox(height: 16),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20.0),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(L10n.of(context).ui_select_remote_server, style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold)),
                    TextButton(onPressed: () => Navigator.pop(ctx), child: Text(L10n.of(context).ui_cancel)),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              ...connections.map((conn) {
                IconData iconData;
                if (FileManagerProvider.isSmbType(conn.type)) {
                  iconData = Icons.computer_rounded;
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
                    decoration: BoxDecoration(color: theme.colorScheme.primary.withOpacity(0.1), shape: BoxShape.circle),
                    child: Icon(iconData, color: theme.colorScheme.primary, size: 20),
                  ),
                  title: Text(conn.name, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15)),
                  subtitle: Text('${conn.type} · ${conn.host}', style: TextStyle(fontSize: 12, color: theme.colorScheme.onSurface.withOpacity(0.5)), maxLines: 1, overflow: TextOverflow.ellipsis),
                  trailing: const Icon(Icons.chevron_right_rounded),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  onTap: () => Navigator.pop(ctx, conn),
                );
              }),
              const SizedBox(height: 16),
            ],
          ),
        );
      },
    );

    if (selectedConn == null) return null;

    // Step 2: 浏览远程目录选择文件夹
    return showDialog<String?>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        return _RemoteDirectoryPickerDialog(connection: selectedConn);
      },
    );
  }

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
      '最近',
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
                  ...customPaths.map((path) {
                        final isRemote = path.startsWith('remote://');
                        String displayPath;
                        IconData pathIcon;
                        if (isRemote) {
                          final uriPart = path.substring('remote://'.length);
                          final separatorIndex = uriPart.indexOf('|');
                          final connId = separatorIndex > 0 ? uriPart.substring(0, separatorIndex) : '';
                          final remotePath = separatorIndex > 0 ? uriPart.substring(separatorIndex + 1) : '/';
                          final conn = NetworkConnectionsService.getConnections()
                              .where((c) => c.id == connId)
                              .firstOrNull;
                          displayPath = '${conn?.name ?? connId}:$remotePath';
                          pathIcon = Broken.wifi;
                        } else {
                          displayPath = path;
                          pathIcon = Broken.folder;
                        }
                        return Container(
                        margin: const EdgeInsets.symmetric(vertical: 4),
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                        decoration: BoxDecoration(
                          color: theme.colorScheme.surfaceVariant.withOpacity(0.3),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Row(
                          children: [
                            Icon(pathIcon, size: 16, color: isRemote ? theme.colorScheme.primary : Colors.grey),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                displayPath,
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
                      );
                      }),
                const SizedBox(height: 8),
                Row(
                  children: [
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
                    if (_remotePathCategories.contains(label)) ...[
                      const SizedBox(width: 8),
                      TextButton.icon(
                        onPressed: () async {
                          final remotePath = await _showRemotePathPicker(context);
                          if (remotePath != null) {
                            widget.provider.addCustomCategoryPath(label, remotePath);
                          }
                        },
                        icon: const Icon(Broken.wifi, size: 16),
                        label: Text(L10n.of(context).ui_add_remote_path, style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                        style: TextButton.styleFrom(
                          foregroundColor: theme.colorScheme.primary,
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                          backgroundColor: theme.colorScheme.primary.withOpacity(0.08),
                        ),
                      ),
                    ],
                  ],
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

/// 远程目录选择对话框，连接远程服务器并让用户选择一个目录。
/// 返回 `remote://{connectionId}|{path}` 格式的路径字符串。
class _RemoteDirectoryPickerDialog extends StatefulWidget {
  final NetworkConnectionModel connection;

  const _RemoteDirectoryPickerDialog({required this.connection});

  @override
  State<_RemoteDirectoryPickerDialog> createState() => _RemoteDirectoryPickerDialogState();
}

class _RemoteDirectoryPickerDialogState extends State<_RemoteDirectoryPickerDialog> {
  RemoteClient? _client;
  bool _isConnecting = true;
  bool _isLoading = false;
  String _errorMsg = '';
  String _currentPath = '/';
  List<RemoteFileItem> _items = [];

  @override
  void initState() {
    super.initState();
    _currentPath = widget.connection.rootPath;
    _connectAndList();
  }

  @override
  void dispose() {
    _client?.disconnect();
    super.dispose();
  }

  Future<void> _connectAndList() async {
    setState(() {
      _isConnecting = true;
      _errorMsg = '';
    });
    try {
      _client?.disconnect();
      _client = FileManagerProvider.createRemoteClient(widget.connection);
      await _client!.connect();
      await _listDir(_currentPath);
    } catch (e) {
      if (mounted) {
        setState(() {
          _isConnecting = false;
          _errorMsg = e.toString();
        });
      }
    }
  }

  Future<void> _listDir(String path) async {
    setState(() {
      _isLoading = true;
      _errorMsg = '';
    });
    try {
      final items = await _client!.listDirectory(path);
      items.sort((a, b) {
        if (a.isDirectory != b.isDirectory) return a.isDirectory ? -1 : 1;
        return a.name.toLowerCase().compareTo(b.name.toLowerCase());
      });
      if (mounted) {
        setState(() {
          _items = items.where((i) => i.isDirectory).toList();
          _isLoading = false;
          _isConnecting = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoading = false;
          _isConnecting = false;
          _errorMsg = e.toString();
        });
      }
    }
  }

  void _selectCurrent() {
    final remotePath = 'remote://${widget.connection.id}|$_currentPath';
    Navigator.of(context).pop(remotePath);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = L10n.of(context);

    return AlertDialog(
      titlePadding: const EdgeInsets.fromLTRB(24, 16, 16, 0),
      contentPadding: const EdgeInsets.fromLTRB(0, 8, 0, 0),
      title: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(l10n.ui_select_remote_server, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                const SizedBox(height: 2),
                Text(
                  '${widget.connection.name} · $_currentPath',
                  style: TextStyle(fontSize: 12, color: theme.colorScheme.onSurface.withOpacity(0.5)),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.close, size: 22),
            onPressed: () => Navigator.of(context).pop(),
          ),
        ],
      ),
      content: SizedBox(
        width: double.maxFinite,
        height: MediaQuery.of(context).size.height * 0.5,
        child: _isConnecting
            ? const Center(child: CircularProgressIndicator())
            : _errorMsg.isNotEmpty
                ? Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.error_outline, size: 48, color: theme.colorScheme.error),
                        const SizedBox(height: 12),
                        Text(_errorMsg, textAlign: TextAlign.center, style: TextStyle(fontSize: 13, color: theme.colorScheme.onSurface.withOpacity(0.6))),
                        const SizedBox(height: 16),
                        TextButton(onPressed: _connectAndList, child: Text(l10n.ui_retry)),
                      ],
                    ),
                  )
                : Column(
                    children: [
                      // 面包屑导航
                      if (_currentPath != '/' && _currentPath != widget.connection.rootPath)
                        Material(
                          color: theme.colorScheme.primary.withOpacity(0.05),
                          child: InkWell(
                            onTap: () {
                              final parts = _currentPath.split('/').where((s) => s.isNotEmpty).toList();
                              if (parts.isNotEmpty) {
                                parts.removeLast();
                                _currentPath = '/${parts.join('/')}';
                                if (_currentPath.isEmpty) _currentPath = '/';
                                _listDir(_currentPath);
                              }
                            },
                            child: Container(
                              width: double.infinity,
                              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                              child: Row(
                                children: [
                                  Icon(Icons.arrow_upward, size: 16, color: theme.colorScheme.primary),
                                  const SizedBox(width: 8),
                                  Text(l10n.msg1f4c1042, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: theme.colorScheme.primary)),
                                ],
                              ),
                            ),
                          ),
                        ),
                      if (_isLoading)
                        const Expanded(child: Center(child: CircularProgressIndicator()))
                      else
                        Expanded(
                          child: _items.isEmpty
                              ? Center(
                                  child: Text(l10n.ui_no_subfolders, style: TextStyle(color: theme.colorScheme.onSurface.withOpacity(0.4), fontSize: 13)),
                                )
                              : ListView.builder(
                                  shrinkWrap: true,
                                  itemCount: _items.length,
                                  itemBuilder: (ctx, index) {
                                    final item = _items[index];
                                    return ListTile(
                                      leading: Icon(Icons.folder, color: theme.colorScheme.primary.withOpacity(0.7), size: 24),
                                      title: Text(item.name, style: const TextStyle(fontSize: 14), maxLines: 1, overflow: TextOverflow.ellipsis),
                                      trailing: const Icon(Icons.chevron_right, size: 20),
                                      dense: true,
                                      onTap: () {
                                        _currentPath = item.path;
                                        _listDir(_currentPath);
                                      },
                                    );
                                  },
                                ),
                        ),
                    ],
                  ),
      ),
      actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: Text(l10n.ui_cancel)),
        FilledButton.icon(
          onPressed: _isConnecting || _errorMsg.isNotEmpty ? null : _selectCurrent,
          icon: const Icon(Icons.check, size: 18),
          label: Text(l10n.ui_select_this_folder),
        ),
      ],
    );
  }
}
