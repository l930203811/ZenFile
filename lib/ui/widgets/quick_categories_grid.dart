import 'dart:math';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/icon_fonts/broken_icons.dart';
import '../../providers/media_provider.dart';
import '../../providers/file_manager_provider.dart';
import '../../services/preferences_service.dart';
import '../screens/media_category_screen.dart';
import '../screens/internal_file_picker_screen.dart';
import '../screens/storage_analyzer/app_manager_screen.dart';
import '../../models/media_type.dart';
import 'package:zenfile/l10n/generated/app_localizations.dart';
import '../../core/utils.dart';

import '../screens/all_recent_files_screen.dart';
import '../screens/storage_analyzer/storage_analyzer_screen.dart';
import '../screens/toolbox_screen.dart';
import '../screens/recycle_bin_screen.dart';
import '../screens/backup_settings_screen.dart';
import '../../services/recycle_bin_service.dart';

class QuickCategoriesGrid extends StatefulWidget {
  final Function(int) onNavigateTab;
  final bool showTitle;

  /// ⚠️ 这个网格**自己不负责滚动，也不允许自己决定卡片行高以外的事**。
  ///
  /// 踩过的坑（v2.1.7）：网格的 build 顶层是 `Padding > Column`，`Column` 会给
  /// 非 flex 子项 **无界高度**（maxHeight = ∞）。所以：
  /// ① 在网格内部塞 `SingleChildScrollView`，它拿到的可视区高度会等于内容高度
  ///    ⇒ **永远滚不动**，超出部分被 Column 裁掉（表现为「2 列/加更多快捷方式后
  ///    底部卡片看不到、也拉不上来」）；
  /// ② 想靠「把可用高度传进来反推行高」来消灭空白，会在列数变化时把行高算歪。
  ///
  /// 结论：滚动和「顶部呼吸位」一律交给**高度有界的外层**（见
  /// `home_screen._buildHomeTab` 的 `SingleChildScrollView`），本组件只按列数
  /// 输出固定比例的卡片行高。
  const QuickCategoriesGrid({
    super.key,
    required this.onNavigateTab,
    this.showTitle = true,
  });

  static Map<String, Map<String, dynamic>> getAllCategoriesMap(
    BuildContext context,
    bool isDark,
    Function(int) onNavigateTab,
  ) {
    final mediaProvider = Provider.of<MediaProvider>(context, listen: false);
    final fileManager = Provider.of<FileManagerProvider>(
      context,
      listen: false,
    );
    final l10n = L10n.of(context);

    // 辅助：对有扫描数据的分类组合「大小 (数量)」文本，两者均为 0 时返回 0。
    String formatSizeCount(String categoryKey) {
      final size = mediaProvider.getCategoryTotalSize(categoryKey);
      final count = mediaProvider.getCategoryItemCount(categoryKey);
      // 若大小未缓存到、且 count 为 0，退化为仅显示数量（首次启动未扫描时不误导用户）。
      if (size <= 0) return '$count';
      return '${FileUtils.formatBytes(size, 1)} ($count)';
    }

    // 「存储」分类：汇总首个内部卷的 已用/总量（参考图片：118 GB / 128 GB）
    String storageCountText = l10n.msg21cefa9b; // 默认回退文案
    try {
      if (fileManager.storageVolumes.isNotEmpty) {
        final v = fileManager.storageVolumes.firstWhere(
          (vol) => vol.isInternal,
          orElse: () => fileManager.storageVolumes.first,
        );
        final total = v.totalBytes;
        final used = v.usedBytes;
        if (total > 0) {
          storageCountText =
              '${FileUtils.formatBytes(used, 1)} / ${FileUtils.formatBytes(total, 1)}';
        }
      }
    } catch (_) {}

    // 背景统一主题主色；图标本身采用不同色相的颜色来区分各类别
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final categoryColor = theme.colorScheme.primary; // 背景色（统一）
    // 图标颜色：统一饱和度和亮度，色相各异，保证视觉和谐
    Color iconColor(double hue) => HSLColor.fromAHSL(
      1.0,
      hue,
      isDark ? 0.6 : 0.5,
      isDark ? 0.6 : 0.55,
    ).toColor();

    final map = <String, Map<String, dynamic>>{
      '系统': {
        'label': l10n.cat_system,
        'icon': Broken.cpu,
        'color': categoryColor,
        'iconColor': iconColor(0), // 红
        'count': l10n.cat_manage,
        'isCustom': false,
        'action': () {
          fileManager.setRootPath('/');
          fileManager.loadDirectory('/');
          onNavigateTab(1);
        },
      },
      '存储': {
        'label': l10n.cat_storage_volume,
        'icon': Broken.folder_open,
        'color': categoryColor,
        'iconColor': iconColor(210), // 蓝
        'count': storageCountText,
        'isCustom': false,
        'action': () {
          final internalVolume = fileManager.storageVolumes.isNotEmpty
              ? fileManager.storageVolumes.firstWhere(
                  (v) => v.isInternal,
                  orElse: () => fileManager.storageVolumes.first,
                )
              : StorageVolume(
                  name: 'Internal Storage',
                  path: '/storage/emulated/0',
                  isInternal: true,
                );
          fileManager.loadDirectory(internalVolume.path);
          onNavigateTab(1);
        },
      },
      '图片': {
        'label': l10n.cat_images,
        'icon': Broken.camera,
        'color': categoryColor,
        'iconColor': iconColor(270), // 紫
        'count': formatSizeCount('图片'),
        'isCustom': false,
        'pageBuilder': () => MediaCategoryScreen(
          mediaType: MediaType.images,
          onNavigateTab: onNavigateTab,
        ),
      },
      '视频': {
        'label': l10n.cat_videos,
        'icon': Broken.video,
        'color': categoryColor,
        'iconColor': iconColor(330), // 玫红
        'count': formatSizeCount('视频'),
        'isCustom': false,
        'pageBuilder': () => MediaCategoryScreen(
          mediaType: MediaType.videos,
          onNavigateTab: onNavigateTab,
        ),
      },
      '音频': {
        'label': l10n.cat_audios,
        'icon': Broken.music,
        'color': categoryColor,
        'iconColor': iconColor(30), // 橙
        'count': formatSizeCount('音频'),
        'isCustom': false,
        'pageBuilder': () => MediaCategoryScreen(
          mediaType: MediaType.audios,
          onNavigateTab: onNavigateTab,
        ),
      },
      '文档': {
        'label': l10n.cat_documents,
        'icon': Broken.document,
        'color': categoryColor,
        'iconColor': iconColor(200), // 青蓝
        'count': formatSizeCount('文档'),
        'isCustom': false,
        'pageBuilder': () => MediaCategoryScreen(
          mediaType: MediaType.documents,
          onNavigateTab: onNavigateTab,
        ),
      },
      '压缩包': {
        'label': l10n.msgc806d0fa,
        'icon': Broken.box,
        'color': categoryColor,
        'iconColor': iconColor(170), // 青绿
        'count': formatSizeCount('压缩包'),
        'isCustom': false,
        'pageBuilder': () => MediaCategoryScreen(
          mediaType: MediaType.archives,
          onNavigateTab: onNavigateTab,
        ),
      },
      '下载': {
        'label': l10n.cat_downloads,
        'icon': Broken.document_download,
        'color': categoryColor,
        'iconColor': iconColor(120), // 绿
        'count': formatSizeCount('下载'),
        'isCustom': false,
        'pageBuilder': () => MediaCategoryScreen(
          mediaType: MediaType.downloads,
          onNavigateTab: onNavigateTab,
        ),
      },
      '安装包': {
        'label': l10n.msg03070d08,
        'icon': Icons.android_rounded,
        'color': categoryColor,
        'iconColor': iconColor(140), // 安卓绿
        'count': formatSizeCount('安装包'),
        'isCustom': false,
        'pageBuilder': () => MediaCategoryScreen(
          mediaType: MediaType.apks,
          onNavigateTab: onNavigateTab,
        ),
      },
      '截图': {
        'label': l10n.cat_screenshots,
        'icon': Broken.image,
        'color': categoryColor,
        'iconColor': iconColor(300), // 品红
        'count': formatSizeCount('截图'),
        'isCustom': false,
        'pageBuilder': () => MediaCategoryScreen(
          mediaType: MediaType.screenshots,
          onNavigateTab: onNavigateTab,
        ),
      },
      '最近': {
        'label': l10n.cat_recent,
        'icon': Broken.clock,
        'color': categoryColor,
        'iconColor': iconColor(240), // 靛蓝
        'count': formatSizeCount('最近'),
        'isCustom': false,
        'pageBuilder': () => AllRecentFilesScreen(onNavigateTab: onNavigateTab),
      },
      '工具箱': {
        'label': l10n.cat_toolbox,
        'icon': Icons.home_repair_service,
        'color': categoryColor,
        'iconColor': iconColor(70), // 橙黄
        'count': l10n.cat_toolbox_desc,
        'isCustom': false,
        'pageBuilder': () => const ToolboxScreen(),
      },
      '应用': {
        'label': l10n.cat_apps,
        'icon': Broken.mobile,
        'color': categoryColor,
        'iconColor': iconColor(140), // 草绿
        'count': l10n.cat_manage,
        'isCustom': false,
        'pageBuilder': () => const AppManagerScreen(),
      },
      // 注意：「设置」不再是分类页卡片（v2.1.7 起移到首页底部「我的」页），
      // 不要在此恢复 '设置' 定义 —— 否则它会重新出现在分类页与自定义面板里。
      '备份/恢复': {
        'label': l10n.cat_backup_restore,
        'icon': Broken.save_2,
        'color': categoryColor,
        'iconColor': iconColor(160), // 绿青
        'count': l10n.cat_backup_restore_desc,
        'isCustom': false,
        'pageBuilder': () => const BackupSettingsScreen(),
      },
      '空间': {
        'label': l10n.cat_storage,
        'icon': Broken.chart_square,
        'color': categoryColor,
        'iconColor': iconColor(220), // 天蓝
        'count': l10n.cat_analyze,
        'isCustom': false,
        'pageBuilder': () => const StorageAnalyzerScreen(),
      },
      '回收站': {
        'label': l10n.ui_recycle_bin,
        'icon': Broken.trash,
        'color': categoryColor,
        'iconColor': isDark
            ? Colors.blueGrey.shade300
            : Colors.blueGrey, // 蓝灰（中性）
        'count': '${RecycleBinService.getTrashItems().length}',
        'isCustom': false,
        'pageBuilder': () => const RecycleBinScreen(),
      },
    };

    for (final cs in mediaProvider.customShortcuts) {
      map[cs.id] = {
        'label': cs.label,
        'icon': cs.isDirectory ? Broken.folder : Broken.document,
        'color': categoryColor,
        'iconColor': iconColor(150), // 薄荷绿
        'count': cs.isDirectory
            ? L10n.of(context).msg1f4c1042
            : L10n.of(context).ui_file,
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
        cat['action'] = () => Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => pageBuilder()),
        );
      }
    }

    // 应用自定义标签
    for (final entry in map.entries) {
      final key = entry.key;
      if (mediaProvider.customCategoryLabels.containsKey(key)) {
        entry.value['label'] = mediaProvider.customCategoryLabels[key];
      }
    }

    return map;
  }

  static void showCustomizeDialog(
    BuildContext context, [
    Function(int)? onNavigateTab,
    String? expandLabelKey,
  ]) {
    final theme = Theme.of(context);
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: theme.scaffoldBackgroundColor,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (context) {
        return _CustomizeCategoriesSheet(
          onNavigateTab:
              onNavigateTab ??
              (index) {
                Navigator.popUntil(context, (route) => route.isFirst);
              },
          initialExpandLabelKey: expandLabelKey,
        );
      },
    );
  }

  /// 底部导航槽位选择器（长按底部 tab 或自定义快捷方式页配置区调用）：
  /// 候选 = 传输 / 设置（可恢复默认） + 分类页全部入口（内置 + 自定义快捷方式）。
  /// 返回选中配置；null = 取消；{'type':'reset'} = 恢复默认内置页。
  static Future<Map<String, String>?> showBottomTabPicker(
    BuildContext context, {
    required int slot,
    Map<String, String>? current,
  }) {
    final theme = Theme.of(context);
    return showModalBottomSheet<Map<String, String>>(
      context: context,
      isScrollControlled: true,
      backgroundColor: theme.scaffoldBackgroundColor,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (sheetContext) {
        final l10n = L10n.of(sheetContext);
        final isDark = Theme.of(sheetContext).brightness == Brightness.dark;
        final allMap = getAllCategoriesMap(sheetContext, isDark, (index) {});
        // 候选：内置 分类/文件/传输/设置 + 分类页全部入口（内置 category / 自定义 shortcut）
        final options = <Map<String, dynamic>>[
          {
            'type': 'builtin',
            'key': 'tab_categories',
            'label': l10n.cat_quick_categories,
            'icon': Broken.category,
          },
          {
            'type': 'builtin',
            'key': 'tab_files',
            'label': l10n.ui_file,
            'icon': Broken.folder,
          },
          {
            'type': 'builtin',
            'key': 'tab_transfers',
            'label': l10n.ui_transfers,
            'icon': Broken.send_2,
          },
          {
            'type': 'builtin',
            'key': 'tab_settings',
            'label': l10n.cat_settings,
            'icon': Broken.setting_2,
          },
          {
            'type': 'custom_entry',
            'key': 'custom_entry',
            'label':
                PreferencesService.getCustomEntryLabel() ??
                l10n.ui_show_custom_entry,
            'icon': Broken.edit_2,
          },
          ...allMap.entries.map((e) => {
                'type': (e.value['isCustom'] == true) ? 'shortcut' : 'category',
                'key': e.key,
                'label': e.value['label'] as String,
                'icon': e.value['icon'] as IconData,
              }),
        ];
        final currentType = current?['type'];
        final currentKey = current?['key'];
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: 12),
              Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.grey.withOpacity(0.3),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(height: 16),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Text(
                  l10n.ui_pick_bottom_tab,
                  style: theme.textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Text(
                  l10n.ui_bottom_tab_slot(slot + 1),
                  style: TextStyle(
                    fontSize: 12,
                    color: theme.colorScheme.onSurface.withOpacity(0.5),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    for (final opt in options)
                      ListTile(
                        dense: true,
                        leading: Icon(
                          opt['icon'] as IconData,
                          size: 20,
                          color: theme.colorScheme.primary,
                        ),
                        title: Text(
                          opt['label'] as String,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        trailing:
                            (currentType == opt['type'] &&
                                    currentKey == opt['key'])
                                ? Icon(
                                    Broken.check,
                                    size: 18,
                                    color: theme.colorScheme.primary,
                                  )
                                : null,
                        onTap: () => Navigator.pop(sheetContext, {
                          'type': opt['type'] as String,
                          'key': opt['key'] as String,
                        }),
                      ),
                    if (current != null)
                      ListTile(
                        dense: true,
                        leading: Icon(
                          Broken.refresh,
                          size: 20,
                          color: theme.colorScheme.onSurface.withOpacity(0.6),
                        ),
                        title: Text(
                          l10n.ui_restore_default,
                          style: TextStyle(
                            color: theme.colorScheme.onSurface.withOpacity(0.7),
                          ),
                        ),
                        onTap: () => Navigator.pop(
                          sheetContext,
                          {'type': 'reset', 'key': ''},
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
  }

  @override
  State<QuickCategoriesGrid> createState() => _QuickCategoriesGridState();
}

class _QuickCategoriesGridState extends State<QuickCategoriesGrid> {
  // 拖拽排序状态
  bool _isDragging = false;
  int _draggingIndex = -1;
  int _targetIndex = -1;
  Offset _dragOffset = Offset.zero;
  OverlayEntry? _overlayEntry;
  OverlayEntry? _menuOverlayEntry;
  final GlobalKey _gridKey = GlobalKey();
  // 长按菜单→拖拽切换用
  Offset? _longPressOrigin;

  // 获取活跃分类的标签列表（用于拖拽排序更新）
  List<String> _getActiveCategoryLabels(
    MediaProvider mediaProvider,
    Map<String, Map<String, dynamic>> allCategoriesMap,
  ) {
    return mediaProvider.categoryOrder
        .where(
          (label) =>
              mediaProvider.activeCategories.contains(label) &&
              allCategoriesMap.containsKey(label),
        )
        .toList();
  }

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

  /// 开始拖拽排序
  void _startDrag(
    int index,
    Offset localPosition,
    Widget dragWidget,
    Color color,
  ) {
    _isDragging = true;
    _draggingIndex = index;
    _targetIndex = index;
    _dragOffset = localPosition;

    _overlayEntry = OverlayEntry(
      builder: (context) => Positioned(
        left: _dragOffset.dx - 32,
        top: _dragOffset.dy - 32,
        child: Material(
          elevation: 6,
          borderRadius: BorderRadius.circular(8),
          color: color.withOpacity(0.3),
          child: Container(
            width: 64,
            height: 64,
            alignment: Alignment.center,
            child: dragWidget,
          ),
        ),
      ),
    );
    Overlay.of(context).insert(_overlayEntry!);
    setState(() {});
  }

  /// 更新拖拽位置
  void _updateDrag(Offset globalPosition) {
    _dragOffset = globalPosition;
    _overlayEntry?.markNeedsBuild();

    final gridRenderBox =
        _gridKey.currentContext?.findRenderObject() as RenderBox?;
    if (gridRenderBox == null) return;

    final localPosition = gridRenderBox.globalToLocal(globalPosition);
    final columns = PreferencesService.getCategoriesGridColumns();
    final screenWidth = gridRenderBox.size.width;
    final itemWidth = (screenWidth - (columns - 1) * 2) / columns;
    final childAspectRatio = columns == 4
        ? 0.78
        : (columns == 3 ? 1.0 : 1.30);
    final itemHeight = itemWidth / childAspectRatio;

    double colFraction = localPosition.dx / (itemWidth + 2);
    double rowFraction = localPosition.dy / (itemHeight + 2);

    int adjustedCol = colFraction.round();
    int adjustedRow = rowFraction.round();

    int newIndex = adjustedRow * columns + adjustedCol;

    final visible = _visibleOrderOf(
      PreferencesService.resolveFullOrder(
        context.read<MediaProvider>().categoryOrder,
      ),
    );

    if (newIndex >= 0 && newIndex != _targetIndex) {
      // 统一模型：网格显示的是「分类 + 系统入口」的可见序列，
      // 拖拽目标限制在可见序列内（0..len-1）。
      _targetIndex = newIndex.clamp(0, visible.length - 1);
      setState(() {});
    }
  }

  /// 结束拖拽排序：可见序列重排 → 合并回完整顺序 → 双写
  /// （full_grid_order 权威，categoryOrder 同步分类部分）
  void _endDrag() {
    _overlayEntry?.remove();
    _overlayEntry = null;

    if (_isDragging &&
        _draggingIndex != _targetIndex &&
        _targetIndex >= 0) {
      final mediaProvider = context.read<MediaProvider>();
      final fullOrder =
          PreferencesService.resolveFullOrder(mediaProvider.categoryOrder);
      final visible = _visibleOrderOf(fullOrder);
      if (_draggingIndex >= 0 &&
          _draggingIndex < visible.length &&
          _targetIndex <= visible.length) {
        final newVisible = [...visible];
        final item = newVisible.removeAt(_draggingIndex);
        newVisible.insert(_targetIndex.clamp(0, newVisible.length), item);
        final merged = _mergeVisibleIntoFull(fullOrder, newVisible);
        PreferencesService.saveFullGridOrder(merged);
        final newCatOrder = merged
            .where((e) => !PreferencesService.isSysEntryKey(e))
            .toList();
        if (!_sameList(newCatOrder, mediaProvider.categoryOrder)) {
          mediaProvider.setCategoryOrder(newCatOrder);
        }
      }
    }

    _isDragging = false;
    _draggingIndex = -1;
    _targetIndex = -1;
    setState(() {});
  }

  /// 从完整顺序解析分类页可见顺序（过滤未激活分类与隐藏系统入口）。
  List<String> _visibleOrderOf(List<String> fullOrder) {
    final mediaProvider = context.read<MediaProvider>();
    final allCategoriesMap = QuickCategoriesGrid.getAllCategoriesMap(
      context,
      Theme.of(context).brightness == Brightness.dark,
      widget.onNavigateTab,
    );
    return fullOrder
        .where((k) {
          if (k == PreferencesService.sysCustomKey) {
            return PreferencesService.getCustomEntryVisible();
          }
          if (k == PreferencesService.sysTransfersKey) {
            return PreferencesService.getTransfersEntryVisible();
          }
          if (k == PreferencesService.sysSettingsKey) {
            return PreferencesService.getSettingsEntryVisible();
          }
          return mediaProvider.activeCategories.contains(k) &&
              allCategoriesMap.containsKey(k);
        })
        .toList();
  }

  /// 可见序列重排后合并回完整顺序：隐藏项保持原相对位置，可见项按新顺序。
  List<String> _mergeVisibleIntoFull(
    List<String> fullOrder,
    List<String> newVisible,
  ) {
    final visibleSet = newVisible.toSet();
    final hidden =
        fullOrder.where((e) => !visibleSet.contains(e)).toList();
    final result = <String>[];
    String? prev;
    var hi = 0;
    for (final v in newVisible) {
      if (prev != null) {
        final vIdx = fullOrder.indexOf(v);
        final pIdx = fullOrder.indexOf(prev);
        while (hi < hidden.length) {
          final hIdx = fullOrder.indexOf(hidden[hi]);
          if (hIdx > pIdx && hIdx < vIdx) {
            result.add(hidden[hi]);
            hi++;
          } else {
            break;
          }
        }
      }
      result.add(v);
      prev = v;
    }
    result.addAll(hidden.sublist(hi));
    return result;
  }

  bool _sameList(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  /// 长按类别图标弹出上下文菜单（类似 Android 桌面图标长按效果）
  /// 使用 Listener 而非 GestureDetector，避免拖拽手势被截断
  // 注意：此方法 100% 复刻 v1.1.32 历史版本（用户确认长按可显示菜单）。
  // 后续的"靠左对齐"优化（iconKey 定位/menuTop 翻转等）曾引发菜单消失/背景透明
  // 等一系列回归问题，已全部回退，勿再改动此结构。
  void _showCategoryContextMenu({
    required Offset position,
    required String labelKey,
    required Color color,
  }) {
    _closeMenuOverlay();
    final mediaProvider = context.read<MediaProvider>();
    final isEnabled = mediaProvider.activeCategories.contains(labelKey);
    final l10n = L10n.of(context);
    final theme = Theme.of(context);

    // 菜单定位：靠左对齐，基于图标位置不容许溢出
    final screenWidth = MediaQuery.of(context).size.width;
    const menuMinWidth = 180.0;
    const edgeMargin = 16.0;
    // 菜单左边缘与图标左边缘对齐（图标宽64，中心 ~32）
    final double menuLeft =
        (position.dx - 32).clamp(edgeMargin, screenWidth - menuMinWidth - edgeMargin);

    _menuOverlayEntry = OverlayEntry(
      builder: (overlayCtx) {
        return _CategoryMenuOverlayWidget(
          menuLeft: menuLeft,
          menuTop: position.dy,
          labelKey: labelKey,
          color: color,
          isEnabled: isEnabled,
          theme: theme,
          l10n: l10n,
          getCategoryIndex: () => _getCategoryIndex(labelKey),
          getCategoryIcon: () => _getCategoryIcon(labelKey),
          onDragStart: (dragPos) {
            _startDrag(
              _getCategoryIndex(labelKey),
              dragPos,
              Icon(_getCategoryIcon(labelKey), color: color, size: 28),
              color,
            );
          },
          onDragUpdate: (pos) => _updateDrag(pos),
          onDragEnd: () {
            _endDrag();
            _closeMenuOverlay();
          },
          onDismiss: _closeMenuOverlay,
          onMenuAction: (action) {
            _closeMenuOverlay();
            _handleMenuAction(action, labelKey);
          },
          buildMenuItem: (icon, label, colorParam, onTap) =>
              _buildMenuItem(icon: icon, label: label, color: colorParam, onTap: onTap),
        );
      },
    );

    Overlay.of(context).insert(_menuOverlayEntry!);
  }

  void _closeMenuOverlay() {
    _menuOverlayEntry?.remove();
    _menuOverlayEntry = null;
  }

  /// 系统入口卡片长按菜单（自定义/传输/设置，复用分类卡片的 Overlay 菜单结构）。
  void _showSystemEntryMenu({
    required Offset position,
    required String entryKey,
    required Color color,
  }) {
    _closeMenuOverlay();
    final bool isEnabled;
    final IconData menuIcon;
    if (entryKey == PreferencesService.sysCustomKey) {
      isEnabled = PreferencesService.getCustomEntryVisible();
      menuIcon = Broken.edit_2;
    } else if (entryKey == PreferencesService.sysTransfersKey) {
      isEnabled = PreferencesService.getTransfersEntryVisible();
      menuIcon = Broken.send_2;
    } else {
      isEnabled = PreferencesService.getSettingsEntryVisible();
      menuIcon = Broken.setting_2;
    }
    // 仅自定义入口保留「自定义快捷方式」菜单项
    final showCustomizeItem = entryKey == PreferencesService.sysCustomKey;
    final l10n = L10n.of(context);
    final theme = Theme.of(context);

    final screenWidth = MediaQuery.of(context).size.width;
    const menuMinWidth = 180.0;
    const edgeMargin = 16.0;
    final menuLeft =
        (position.dx - 32).clamp(edgeMargin, screenWidth - menuMinWidth - edgeMargin);

    _menuOverlayEntry = OverlayEntry(
      builder: (overlayCtx) {
        return _CategoryMenuOverlayWidget(
          menuLeft: menuLeft,
          menuTop: position.dy,
          labelKey: entryKey,
          color: color,
          isEnabled: isEnabled,
          theme: theme,
          l10n: l10n,
          showCustomizeItem: showCustomizeItem,
          getCategoryIndex: () => -1,
          getCategoryIcon: () => menuIcon,
          onDragStart: (dragPos) {
            _startDrag(
              -1,
              dragPos,
              Icon(menuIcon, color: color, size: 28),
              color,
            );
          },
          onDragUpdate: (pos) => _updateDrag(pos),
          onDragEnd: () {
            _endDrag();
            _closeMenuOverlay();
          },
          onDismiss: _closeMenuOverlay,
          onMenuAction: (action) {
            _closeMenuOverlay();
            switch (action) {
              case 'rename':
                _showRenameDialogForSysEntry(context, entryKey);
              case 'toggle':
                if (entryKey == PreferencesService.sysCustomKey) {
                  PreferencesService.saveCustomEntryVisible(
                    !PreferencesService.getCustomEntryVisible(),
                  );
                } else if (entryKey == PreferencesService.sysTransfersKey) {
                  PreferencesService.saveTransfersEntryVisible(
                    !PreferencesService.getTransfersEntryVisible(),
                  );
                } else {
                  PreferencesService.saveSettingsEntryVisible(
                    !PreferencesService.getSettingsEntryVisible(),
                  );
                }
              case 'customize':
                QuickCategoriesGrid.showCustomizeDialog(
                  context,
                  widget.onNavigateTab,
                );
            }
            setState(() {});
          },
          buildMenuItem: (icon, label, colorParam, onTap) =>
              _buildMenuItem(icon: icon, label: label, color: colorParam, onTap: onTap),
        );
      },
    );
    Overlay.of(context).insert(_menuOverlayEntry!);
  }

  /// 网格内重命名系统入口显示名（与配置区弹窗同构）。
  Future<void> _showRenameDialogForSysEntry(
    BuildContext context,
    String entryKey,
  ) async {
    final theme = Theme.of(context);
    final String initial;
    final String fallback;
    if (entryKey == PreferencesService.sysCustomKey) {
      fallback = L10n.of(context).ui_show_custom_entry;
      initial = PreferencesService.getCustomEntryLabel() ?? fallback;
    } else if (entryKey == PreferencesService.sysTransfersKey) {
      fallback = L10n.of(context).ui_transfers;
      initial = PreferencesService.getTransfersEntryLabel() ?? fallback;
    } else {
      fallback = L10n.of(context).cat_settings;
      initial = PreferencesService.getSettingsEntryLabel() ?? fallback;
    }
    final controller = TextEditingController(text: initial);
    await showDialog<void>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          backgroundColor: theme.scaffoldBackgroundColor,
          title: Text(
            L10n.of(dialogContext).msgc8ce4b36,
            style: theme.textTheme.titleLarge?.copyWith(
              fontWeight: FontWeight.bold,
            ),
          ),
          content: TextField(
            controller: controller,
            autofocus: true,
            decoration: InputDecoration(
              hintText: L10n.of(dialogContext).msgf139c5cf,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide(
                  color: theme.colorScheme.onSurface.withOpacity(0.1),
                ),
              ),
            ),
            onSubmitted: (_) => Navigator.of(dialogContext).pop(),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: Text(L10n.of(dialogContext).ui_cancel),
            ),
            TextButton(
              onPressed: () {
                final newLabel = controller.text.trim();
                if (newLabel.isNotEmpty) {
                  if (entryKey == PreferencesService.sysCustomKey) {
                    PreferencesService.saveCustomEntryLabel(newLabel);
                  } else if (entryKey ==
                      PreferencesService.sysTransfersKey) {
                    PreferencesService.saveTransfersEntryLabel(newLabel);
                  } else {
                    PreferencesService.saveSettingsEntryLabel(newLabel);
                  }
                }
                Navigator.of(dialogContext).pop();
                if (mounted) setState(() {});
              },
              child: Text(
                L10n.of(dialogContext).ui_done,
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  color: theme.colorScheme.primary,
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  int _getCategoryIndex(String labelKey) {
    final provider = context.read<MediaProvider>();
    final allCategoriesMap = QuickCategoriesGrid.getAllCategoriesMap(
      context,
      Theme.of(context).brightness == Brightness.dark,
      widget.onNavigateTab,
    );
    final activeLabels = _getActiveCategoryLabels(provider, allCategoriesMap);
    return activeLabels.indexOf(labelKey);
  }

  IconData _getCategoryIcon(String labelKey) {
    final allCategoriesMap = QuickCategoriesGrid.getAllCategoriesMap(
      context,
      Theme.of(context).brightness == Brightness.dark,
      widget.onNavigateTab,
    );
    final cat = allCategoriesMap[labelKey];
    if (cat == null) return Icons.folder;
    return cat['icon'] as IconData;
  }

  Widget _buildMenuItem({
    required IconData icon,
    required String label,
    required Color color,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      child: Container(
        height: 44,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        alignment: Alignment.centerLeft,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            SizedBox(
              width: 24,
              child: Align(
                alignment: Alignment.centerLeft,
                child: Icon(icon, size: 20, color: color),
              ),
            ),
            const SizedBox(width: 12),
            Text(
              label,
              style: const TextStyle(fontSize: 14),
              textAlign: TextAlign.start,
            ),
          ],
        ),
      ),
    );
  }

  void _handleMenuAction(String action, String labelKey) {
    switch (action) {
      case 'rename':
        _showRenameDialogForGrid(labelKey);
      case 'customize':
        QuickCategoriesGrid.showCustomizeDialog(context, widget.onNavigateTab);
      case 'toggle':
        context.read<MediaProvider>().toggleCategory(labelKey);
    }
  }

  Future<void> _showRenameDialogForGrid(String labelKey) async {
    final allCategoriesMap = QuickCategoriesGrid.getAllCategoriesMap(
      context,
      Theme.of(context).brightness == Brightness.dark,
      widget.onNavigateTab,
    );
    final cat = allCategoriesMap[labelKey];
    if (cat == null) return;
    final currentLabel = cat['label'] as String;
    final theme = Theme.of(context);
    final TextEditingController controller = TextEditingController(
      text: currentLabel,
    );

    await showDialog<void>(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          backgroundColor: theme.scaffoldBackgroundColor,
          title: Text(
            L10n.of(context).msgc8ce4b36,
            style: theme.textTheme.titleLarge?.copyWith(
              fontWeight: FontWeight.bold,
            ),
          ),
          content: TextField(
            controller: controller,
            autofocus: true,
            decoration: InputDecoration(
              hintText: L10n.of(context).msgf139c5cf,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide(
                  color: theme.colorScheme.onSurface.withOpacity(0.1),
                ),
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: Text(L10n.of(context).ui_cancel),
            ),
            TextButton(
              onPressed: () {
                final newLabel = controller.text.trim();
                if (newLabel.isNotEmpty) {
                  context.read<MediaProvider>().renameCategory(
                    labelKey,
                    newLabel,
                  );
                }
                Navigator.of(ctx).pop();
              },
              child: Text(
                L10n.of(context).ui_done,
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  color: theme.colorScheme.primary,
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final mediaProvider = context.watch<MediaProvider>();

    final allCategoriesMap = QuickCategoriesGrid.getAllCategoriesMap(
      context,
      isDark,
      widget.onNavigateTab,
    );

    final columns = PreferencesService.getCategoriesGridColumns();
    // 统一完整顺序（full_grid_order：分类 + 系统入口一条链），
    // 分类页网格显示其过滤视图（激活分类 + 可见系统入口），
    // 配置区与网格任一拖拽都会双向同步。
    final fullOrder =
        PreferencesService.resolveFullOrder(mediaProvider.categoryOrder);
    final visibleOrder = _visibleOrderOf(fullOrder);
    final itemCount = visibleOrder.length;

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
                  style: theme.textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.bold,
                    fontSize: 18,
                  ),
                ),
                InkWell(
                  onTap: () => QuickCategoriesGrid.showCustomizeDialog(
                    context,
                    widget.onNavigateTab,
                  ),
                  borderRadius: BorderRadius.circular(16),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8.0,
                      vertical: 4.0,
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Broken.edit_2,
                          size: 16,
                          color: theme.colorScheme.primary,
                        ),
                        const SizedBox(width: 4),
                        Text(
                          L10n.of(context).msgf1d4ff50,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.primary,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            )
          else
            const SizedBox.shrink(),
          if (visibleOrder.isEmpty)
            Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 24.0),
                child: Text(
                  L10n.of(context).msg490ac572,
                  style: TextStyle(
                    color: theme.colorScheme.onSurface.withOpacity(0.5),
                  ),
                ),
              ),
            )
          else
            Listener(
              onPointerMove: _isDragging
                  ? (event) => _updateDrag(event.position)
                  : null,
              onPointerUp: _isDragging ? (event) => _endDrag() : null,
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 300),
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    const spacing = 2.0;
                    final gridItemW =
                        (constraints.maxWidth - (columns - 1) * spacing) /
                            columns;
                    final iconSize =
                        gridItemW *
                        (columns == 4 ? 0.46 : (columns == 3 ? 0.40 : 0.30));
                    // 行高按列数固定（与设计一致），这里不做任何压缩/拉伸：
                    // 卡片尺寸在任何列数下都可预期，放不下时由外层滚动视图负责。
                    final ratio = columns == 4
                        ? 0.78
                        : (columns == 3 ? 1.0 : 1.30);
                    final grid = GridView.builder(
                  key: _gridKey,
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  // ⚠️ 这里**必须显式给 padding（哪怕是 zero），绝不能省成默认的 null**：
                  // `ScrollView`（GridView/ListView 同源）在 `padding == null` 时会自动
                  // 把 `MediaQuery.padding` 的**纵向分量**（= 状态栏高度，本机 28dp）
                  // 当作 SliverPadding 加到首尾 —— 见 flutter 源码
                  // `widgets/scroll_view.dart:900-930`（"Automatically pad sliver with
                  // padding from MediaQuery"）。现象：卡片与搜索栏之间凭空多出一大段
                  // 空白（28dp），而且上拉能把它顶上去 —— 因为它是**内容里的空白**，
                  // 不是布局偏移。顶部呼吸位统一由外层
                  // `home_screen._buildHomeTab` 的 SingleChildScrollView 提供。
                  padding: EdgeInsets.zero,
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: columns,
                    crossAxisSpacing: spacing,
                    mainAxisSpacing: spacing,
                    childAspectRatio: ratio,
                  ),
                  itemCount: itemCount,
                  itemBuilder: (context, index) {
                    final key = visibleOrder[index];
                    // 系统入口卡片（自定义/传输/设置）：与分类卡片一致，
                    // 支持长按菜单（重命名/显示开关）与长按拖拽排序。
                    if (PreferencesService.isSysEntryKey(key)) {
                      return _buildSysEntryCard(theme, iconSize, key);
                    }
                    final cat = allCategoriesMap[key];
                    if (cat == null) {
                      return const SizedBox.shrink(key: ValueKey('empty2'));
                    }
                    final labelKey = key;
                    final label = cat['label'] as String;
                    final icon = cat['icon'] as IconData;
                    final color = cat['color'] as Color;
                    final iconColor = (cat['iconColor'] ?? color) as Color;
                    final count = cat['count'] as String;
                    final pageBuilder =
                        cat['pageBuilder'] as Widget Function()?;
                    final action = cat['action'] as VoidCallback?;
                    final showLabels =
                        PreferencesService.getShowCategoryLabels();
                    final iconKey = GlobalKey();

                    final isBeingDragged =
                        _isDragging && _draggingIndex == index;
                    final isTarget =
                        _isDragging &&
                        _targetIndex == index &&
                        _draggingIndex != index;

                    // 与面包屑一致的可靠方案：长按类别图标开始交互（长按菜单或拖动排序）时，
                    // 置位 categoryReorderInteracting，使 home 的左右滑动切页检测在本次手势期间被抑制，
                    // 避免长按拖动排序被误判为切换分类页/快捷操作页。注意：仅在「长按」开始时置位，
                    // 普通快速横滑（未触发长按）仍可正常切页。
                    final fm = context.read<FileManagerProvider>();
                    return GestureDetector(
                      onLongPressStart: (details) {
                        fm.setCategoryReorderInteracting(true);
                        _longPressOrigin = details.globalPosition;
                        _showCategoryContextMenu(
                          position: details.globalPosition,
                          labelKey: labelKey,
                          color: color,
                        );
                      },
                      onLongPressMoveUpdate: (details) {
                        if (_isDragging) {
                          _updateDrag(details.globalPosition);
                          return;
                        }
                        if (_menuOverlayEntry == null) return;
                        final origin = _longPressOrigin;
                        if (origin == null) return;
                        final distance =
                            (details.globalPosition - origin).distance;
                        if (distance > 10.0) {
                          _closeMenuOverlay();
                          _startDrag(
                            index,
                            details.globalPosition,
                            Icon(
                              _getCategoryIcon(labelKey),
                              color: color,
                              size: 28,
                            ),
                            color,
                          );
                        }
                      },
                      onLongPressEnd: (_) {
                        if (_isDragging) {
                          _endDrag();
                        }
                        fm.setCategoryReorderInteracting(false);
                        _longPressOrigin = null;
                      },
                      child: Opacity(
                        opacity: isBeingDragged ? 0.3 : (isTarget ? 0.6 : 1.0),
                        child: Container(
                          key: ValueKey(labelKey),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 8,
                          ),
                          decoration: BoxDecoration(
                            color: theme.colorScheme.primary.withOpacity(0.05),
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(
                              color: theme.colorScheme.primary.withOpacity(0.22),
                              width: 1,
                            ),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withOpacity(0.06),
                                blurRadius: 8,
                                offset: const Offset(0, 2),
                              ),
                            ],
                          ),
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                            Material(
                              color: Colors.transparent,
                              child: InkWell(
                                key: iconKey,
                                onTap: () {
                                  if (!_isDragging) {
                                    if (pageBuilder != null) {
                                      _navigateWithExpand(
                                        iconKey: iconKey,
                                        color: color,
                                        targetPage: pageBuilder(),
                                      );
                                    } else {
                                      action?.call();
                                    }
                                  }
                                },
                                customBorder: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                splashColor: color.withOpacity(0.25),
                                highlightColor: color.withOpacity(0.15),
                                child: Column(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    Icon(
                                      icon,
                                      color: iconColor,
                                      size: iconSize,
                                    ),
                                    if (showLabels) ...[
                                      const SizedBox(height: 4),
                                      Text(
                                        label,
                                        style: theme.textTheme.titleMedium
                                            ?.copyWith(
                                          fontWeight: FontWeight.w700,
                                          fontSize: 14,
                                        ),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                      const SizedBox(height: 1),
                                    ],
                                    FittedBox(
                                      fit: BoxFit.scaleDown,
                                      alignment: Alignment.center,
                                      child: Text(
                                        count,
                                        style: theme.textTheme.bodySmall
                                            ?.copyWith(
                                          color: theme.textTheme.bodySmall
                                              ?.color
                                              ?.withOpacity(0.7),
                                          fontSize: 11,
                                          fontWeight: FontWeight.w500,
                                          letterSpacing: -0.2,
                                          height: 1.1,
                                        ),
                                        maxLines: 1,
                                        textAlign: TextAlign.center,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ],
                        ),
                        ),
                      ),
                    );
                  },
                    );
                    // 直接返回：本组件不在内部滚动（见类顶部注释），
                    // 否则可视区高度=内容高度 ⇒ 永远滚不动。
                    return grid;
                  },
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// 分类页网格末尾的「自定义」入口卡片：点击打开自定义快捷方式对话框。
  /// 系统入口卡片（自定义/传输/设置）：与分类卡片一致，
  /// 支持长按菜单（重命名/显示开关，自定义额外含自定义快捷方式）与长按拖拽排序。
  Widget _buildSysEntryCard(ThemeData theme, double iconSize, String key) {
    final fm = context.read<FileManagerProvider>();
    final color = theme.colorScheme.primary;
    final IconData icon;
    final String label;
    final VoidCallback onTap;
    if (key == PreferencesService.sysCustomKey) {
      icon = Broken.edit_2;
      label = PreferencesService.getCustomEntryLabel() ??
          L10n.of(context).msgf1d4ff50;
      onTap = () => QuickCategoriesGrid.showCustomizeDialog(
        context,
        widget.onNavigateTab,
      );
    } else if (key == PreferencesService.sysTransfersKey) {
      icon = Broken.send_2;
      label = PreferencesService.getTransfersEntryLabel() ??
          L10n.of(context).ui_transfers;
      onTap = () => widget.onNavigateTab.call(2);
    } else {
      icon = Broken.setting_2;
      label = PreferencesService.getSettingsEntryLabel() ??
          L10n.of(context).cat_settings;
      onTap = () => widget.onNavigateTab.call(3);
    }
    return GestureDetector(
      onLongPressStart: (details) {
        fm.setCategoryReorderInteracting(true);
        _longPressOrigin = details.globalPosition;
        _showSystemEntryMenu(
          position: details.globalPosition,
          entryKey: key,
          color: color,
        );
      },
      onLongPressMoveUpdate: (details) {
        if (_isDragging) {
          _updateDrag(details.globalPosition);
          return;
        }
        if (_menuOverlayEntry == null) return;
        final origin = _longPressOrigin;
        if (origin == null) return;
        if ((details.globalPosition - origin).distance > 10.0) {
          _closeMenuOverlay();
          _startDrag(
            -1,
            details.globalPosition,
            Icon(icon, color: color, size: 28),
            color,
          );
        }
      },
      onLongPressEnd: (_) {
        if (_isDragging) {
          _endDrag();
        }
        fm.setCategoryReorderInteracting(false);
        _longPressOrigin = null;
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
        decoration: BoxDecoration(
          color: theme.colorScheme.primary.withOpacity(0.05),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: theme.colorScheme.primary.withOpacity(0.22),
            width: 1,
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.06),
              blurRadius: 8,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: onTap,
            splashColor: theme.colorScheme.primary.withOpacity(0.25),
            highlightColor: theme.colorScheme.primary.withOpacity(0.15),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(icon, color: theme.colorScheme.primary, size: iconSize),
                const SizedBox(height: 4),
                Text(
                  label,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                    fontSize: 14,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 类别长按弹出菜单的 Overlay 组件，支持菜单点击和拖拽排序的连续手势。
/// 使用 Listener（原始指针事件）而非 GestureDetector，确保拖拽时指针事件不会
/// 因 overlay 移除而中断。
// 注意：此组件 100% 复刻 v1.1.32 历史版本（用户确认长按可显示菜单、有背景）。
// 后续优化（_pointerDownReceived 防护/stretch 对齐/显式背景色等）曾引发菜单消失/
// 背景透明等回归，已全部回退，勿再改动此结构。
class _CategoryMenuOverlayWidget extends StatefulWidget {
  final double menuLeft;
  final double menuTop;
  final String labelKey;
  final Color color;
  final bool isEnabled;
  final ThemeData theme;
  final dynamic l10n; // L10n 类型
  final int Function() getCategoryIndex;
  final IconData Function() getCategoryIcon;
  final void Function(Offset dragPos) onDragStart;
  final void Function(Offset pos) onDragUpdate;
  final VoidCallback onDragEnd;
  final VoidCallback onDismiss;
  final void Function(String action) onMenuAction;
  final Widget Function(IconData icon, String label, Color color, VoidCallback onTap) buildMenuItem;
  /// 是否显示「自定义快捷方式」菜单项（仅自定义入口显示）
  final bool showCustomizeItem;

  const _CategoryMenuOverlayWidget({
    required this.menuLeft,
    required this.menuTop,
    required this.labelKey,
    required this.color,
    required this.isEnabled,
    required this.theme,
    required this.l10n,
    required this.getCategoryIndex,
    required this.getCategoryIcon,
    required this.onDragStart,
    required this.onDragUpdate,
    required this.onDragEnd,
    required this.onDismiss,
    required this.onMenuAction,
    required this.buildMenuItem,
    this.showCustomizeItem = true,
  });

  @override
  State<_CategoryMenuOverlayWidget> createState() => _CategoryMenuOverlayWidgetState();
}

class _CategoryMenuOverlayWidgetState extends State<_CategoryMenuOverlayWidget> {
  bool _menuVisible = true;
  bool _dragActive = false;
  Offset _pointerDownPos = Offset.zero;

  static const double _dragThreshold = 8.0;

  void _onPointerDown(PointerDownEvent event) {
    _pointerDownPos = event.position;
    _dragActive = false;
  }

  void _onPointerMove(PointerMoveEvent event) {
    if (!_dragActive) {
      final distance = (event.position - _pointerDownPos).distance;
      if (distance > _dragThreshold) {
        _dragActive = true;
        setState(() => _menuVisible = false);
        widget.onDragStart(event.position);
      }
    } else {
      widget.onDragUpdate(event.position);
    }
  }

  void _onPointerUp(PointerUpEvent event) {
    if (!_dragActive) {
      // 未拖拽，视为点击空白处关闭菜单
      widget.onDismiss();
    } else {
      widget.onDragEnd();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: _onPointerDown,
      onPointerMove: _onPointerMove,
      onPointerUp: _onPointerUp,
      child: Stack(
        children: [
          // 全屏透明背景，接收指针事件
          Positioned.fill(child: Container(color: Colors.transparent)),
          // 菜单内容（拖拽激活后隐藏）
          if (_menuVisible)
            Positioned(
              left: widget.menuLeft,
              top: widget.menuTop,
              child: Material(
                color: Colors.transparent,
                child: Container(
                  constraints: const BoxConstraints(minWidth: 180),
                  decoration: BoxDecoration(
                    color: widget.theme.cardColor,
                    borderRadius: BorderRadius.circular(12),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withOpacity(0.2),
                        blurRadius: 8,
                        offset: const Offset(0, 4),
                      ),
                    ],
                  ),
child: IntrinsicWidth(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                      widget.buildMenuItem(
                        Icons.edit,
                        widget.l10n.msgc8ce4b36,
                        widget.color,
                        () => widget.onMenuAction('rename'),
                      ),
                      const Divider(height: 1),
                      widget.buildMenuItem(
                        widget.isEnabled ? Icons.visibility_off : Icons.visibility,
                        widget.isEnabled ? widget.l10n.ui_close_category : widget.l10n.ui_open_category,
                        widget.color,
                        () => widget.onMenuAction('toggle'),
                      ),
                      if (widget.showCustomizeItem) ...[
                        const Divider(height: 1),
                        widget.buildMenuItem(
                          Icons.shortcut,
                          widget.l10n.msge7d18d73,
                          widget.color,
                          () => widget.onMenuAction('customize'),
                        ),
                      ],
                    ],
                  ),
                  ),
                ),
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
    return Path()..addOval(Rect.fromCircle(center: center, radius: radius));
  }

  @override
  bool shouldReclip(covariant _CircleClipper oldDelegate) {
    return oldDelegate.radius != radius;
  }
}

class _CustomizeCategoriesSheet extends StatefulWidget {
  final Function(int) onNavigateTab;
  final String? initialExpandLabelKey;

  const _CustomizeCategoriesSheet({
    required this.onNavigateTab,
    this.initialExpandLabelKey,
  });

  @override
  State<_CustomizeCategoriesSheet> createState() =>
      _CustomizeCategoriesSheetState();
}

class _CustomizeCategoriesSheetState extends State<_CustomizeCategoriesSheet> {
  final Map<String, GlobalKey> _itemKeys = {};
  bool _hasScrolledToTarget = false;

  GlobalKey _getItemKey(String label) {
    return _itemKeys.putIfAbsent(label, () => GlobalKey());
  }

  void _scrollToTargetItem(
    ScrollController scrollController,
    List<String> order,
  ) {
    if (_hasScrolledToTarget) return;
    final targetLabel = widget.initialExpandLabelKey;
    if (targetLabel == null) return;
    final targetIndex = order.indexOf(targetLabel);
    if (targetIndex < 0) return;

    final key = _itemKeys[targetLabel];
    if (key?.currentContext != null) {
      _hasScrolledToTarget = true;
      Scrollable.ensureVisible(
        key!.currentContext!,
        alignment: 0.4, // 滚动到接近屏幕中间位置
        duration: const Duration(milliseconds: 350),
        curve: Curves.easeInOut,
      );
    } else {
      // 目标 item 尚未渲染，估算位置并滚动
      final estimatedOffset = targetIndex * 80.0;
      final maxScroll = scrollController.position.maxScrollExtent;
      final targetOffset = (estimatedOffset - 200).clamp(0.0, maxScroll);
      scrollController.animateTo(
        targetOffset,
        duration: const Duration(milliseconds: 350),
        curve: Curves.easeInOut,
      );
      // 延迟后再次尝试精确滚动
      Future.delayed(const Duration(milliseconds: 400), () {
        if (!mounted || _hasScrolledToTarget) return;
        final key2 = _itemKeys[targetLabel];
        if (key2 != null && key2.currentContext != null) {
          _hasScrolledToTarget = true;
          Scrollable.ensureVisible(
            key2.currentContext!,
            alignment: 0.4,
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeInOut,
          );
        }
      });
    }
  }

  /// 系统入口开关行（传输/设置）：与分类项样式一致，可开关、可重命名。
  /// 配置区列表项：系统入口（自定义/传输/设置），与分类项样式一致，
  /// 可开关、可重命名，作为 ReorderableListView 的一项参与拖动排序。
  Widget _buildSysEntryListItem(
    BuildContext context,
    String key,
    StateSetter setModalState,
  ) {
    final theme = Theme.of(context);
    final IconData icon;
    final String label;
    final bool visible;
    if (key == PreferencesService.sysCustomKey) {
      icon = Broken.edit_2;
      label = PreferencesService.getCustomEntryLabel() ??
          L10n.of(context).ui_show_custom_entry;
      visible = PreferencesService.getCustomEntryVisible();
    } else if (key == PreferencesService.sysTransfersKey) {
      icon = Broken.send_2;
      label = PreferencesService.getTransfersEntryLabel() ??
          L10n.of(context).ui_transfers;
      visible = PreferencesService.getTransfersEntryVisible();
    } else {
      icon = Broken.setting_2;
      label = PreferencesService.getSettingsEntryLabel() ??
          L10n.of(context).cat_settings;
      visible = PreferencesService.getSettingsEntryVisible();
    }
    return Container(
      key: ValueKey(key),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 与分类项（CategoryItemWidget）完全同构的布局：
          // 不设 dense / 不覆盖 contentPadding，保证标题与开关间距一致
          ListTile(
            leading: Container(
              width: 42,
              height: 42,
              decoration: BoxDecoration(
                color: theme.colorScheme.primary.withOpacity(0.15),
                shape: BoxShape.rectangle,
                borderRadius: BorderRadius.circular(6),
              ),
              child: Icon(icon, color: theme.colorScheme.primary, size: 22),
            ),
            title: Text(
              label,
              style: const TextStyle(
                fontWeight: FontWeight.w600,
                fontSize: 15,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  icon: const Icon(Icons.edit, color: Colors.grey, size: 20),
                  tooltip: L10n.of(context).msgc8ce4b36,
                  onPressed: () => _showSystemEntryRenameDialog(
                    context,
                    key,
                    setModalState,
                  ),
                ),
                const SizedBox(width: 4),
                Switch(
                  value: visible,
                  activeColor: theme.colorScheme.primary,
                  onChanged: (v) {
                    if (key == PreferencesService.sysCustomKey) {
                      PreferencesService.saveCustomEntryVisible(v);
                    } else if (key == PreferencesService.sysTransfersKey) {
                      PreferencesService.saveTransfersEntryVisible(v);
                    } else {
                      PreferencesService.saveSettingsEntryVisible(v);
                    }
                    setModalState(() {});
                    // 同步触发分类页网格重建：关闭后对应卡片即时从分类页隐藏
                    context.read<MediaProvider>().notifyListeners();
                  },
                ),
                const SizedBox(width: 12),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 系统入口重命名弹窗：显示名存入 prefs（空 = 恢复 l10n 默认）。
  Future<void> _showSystemEntryRenameDialog(
    BuildContext context,
    String entryKey,
    StateSetter setModalState,
  ) async {
    final theme = Theme.of(context);
    final String initial;
    final String fallback;
    if (entryKey == PreferencesService.sysCustomKey) {
      fallback = L10n.of(context).ui_show_custom_entry;
      initial =
          PreferencesService.getCustomEntryLabel() ?? fallback;
    } else if (entryKey == PreferencesService.sysTransfersKey) {
      fallback = L10n.of(context).ui_transfers;
      initial = PreferencesService.getTransfersEntryLabel() ?? fallback;
    } else {
      fallback = L10n.of(context).cat_settings;
      initial = PreferencesService.getSettingsEntryLabel() ?? fallback;
    }
    final controller = TextEditingController(text: initial);
    await showDialog<void>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          backgroundColor: theme.scaffoldBackgroundColor,
          title: Text(
            L10n.of(dialogContext).msgc8ce4b36,
            style: theme.textTheme.titleLarge?.copyWith(
              fontWeight: FontWeight.bold,
            ),
          ),
          content: TextField(
            controller: controller,
            autofocus: true,
            decoration: InputDecoration(
              hintText: L10n.of(dialogContext).msgf139c5cf,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide(
                  color: theme.colorScheme.onSurface.withOpacity(0.1),
                ),
              ),
            ),
            onSubmitted: (_) => Navigator.of(dialogContext).pop(),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: Text(L10n.of(dialogContext).ui_cancel),
            ),
            TextButton(
              onPressed: () {
                final newLabel = controller.text.trim();
                if (newLabel.isNotEmpty) {
                  if (entryKey == PreferencesService.sysCustomKey) {
                    PreferencesService.saveCustomEntryLabel(newLabel);
                  } else if (entryKey ==
                      PreferencesService.sysTransfersKey) {
                    PreferencesService.saveTransfersEntryLabel(newLabel);
                  } else {
                    PreferencesService.saveSettingsEntryLabel(newLabel);
                  }
                }
                Navigator.of(dialogContext).pop();
                setModalState(() {});
                // 分类页网格同步刷新显示名
                context.read<MediaProvider>().notifyListeners();
              },
              child: Text(
                L10n.of(dialogContext).ui_done,
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  color: theme.colorScheme.primary,
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  /// 底部导航槽位 2/3 配置行：显示当前入口，点击弹出选择器。
  Widget _buildBottomSlotRow(
    BuildContext context,
    int slot,
    StateSetter setModalState,
  ) {
    final theme = Theme.of(context);
    final cfg = PreferencesService.getBottomTabSlotConfig(slot);
    final label = _bottomSlotLabel(context, slot, cfg);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20.0, vertical: 3.0),
      child: Material(
        color: theme.colorScheme.surfaceVariant.withOpacity(0.3),
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: () async {
            final picked = await QuickCategoriesGrid.showBottomTabPicker(
              context,
              slot: slot,
              current: cfg,
            );
            if (picked == null) return;
            if (picked['type'] == 'reset') {
              await PreferencesService.saveBottomTabSlotConfig(slot, null);
            } else {
              await PreferencesService.saveBottomTabSlotConfig(slot, picked);
            }
            if (mounted) setModalState(() {});
            // 触发 HomeScreen 重建：底部 4-tab 即时刷新为新入口
            // （HomeScreen watch FileManagerProvider，MediaProvider 不触发其重建）
            context.read<FileManagerProvider>().notifyListeners();
          },
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    L10n.of(context).ui_bottom_tab_slot(slot + 1),
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                Expanded(
                  flex: 2,
                  child: Text(
                    label,
                    textAlign: TextAlign.end,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13,
                      color: theme.colorScheme.primary,
                    ),
                  ),
                ),
                Icon(
                  Icons.chevron_right,
                  size: 18,
                  color: theme.colorScheme.onSurface.withOpacity(0.4),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 槽位当前显示名：默认内置页 / 分类页入口 / 快捷方式名。
  String _bottomSlotLabel(
    BuildContext context,
    int slot,
    Map<String, String>? cfg,
  ) {
    final l10n = L10n.of(context);
    if (cfg == null) {
      switch (slot) {
        case 0:
          return l10n.cat_quick_categories;
        case 1:
          return l10n.ui_file;
        case 3:
          return l10n.cat_settings;
        default:
          return l10n.ui_transfers;
      }
    }
    if (cfg['type'] == 'builtin') {
      switch (cfg['key']) {
        case 'tab_categories':
          return l10n.cat_quick_categories;
        case 'tab_files':
          return l10n.ui_file;
        case 'tab_settings':
          return l10n.cat_settings;
        default:
          return l10n.ui_transfers;
      }
    }
    if (cfg['type'] == 'custom_entry') {
      return PreferencesService.getCustomEntryLabel() ??
          l10n.ui_show_custom_entry;
    }
    final map = QuickCategoriesGrid.getAllCategoriesMap(
      context,
      Theme.of(context).brightness == Brightness.dark,
      (index) {},
    );
    final entry = map[cfg['key']];
    if (entry != null) return entry['label'] as String;
    return slot == 3 ? l10n.cat_settings : l10n.ui_transfers;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return Consumer<FileManagerProvider>(
      builder: (context, fileManager, _) {
        return Consumer<MediaProvider>(
          builder: (context, provider, child) {
            return DraggableScrollableSheet(
              initialChildSize: 0.7,
              minChildSize: 0.4,
              maxChildSize: 0.95,
              expand: false,
              builder: (context, scrollController) {
                // 统一完整顺序：配置区列表与分类页网格共用一条链，
                // 任一侧拖动都会写回 full_grid_order 并同步 categoryOrder。
                final fullOrder = PreferencesService.resolveFullOrder(
                  provider.categoryOrder,
                );
                // 在首次渲染完成后触发滚动
                if (!_hasScrolledToTarget &&
                    widget.initialExpandLabelKey != null) {
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    _scrollToTargetItem(scrollController, fullOrder);
                  });
                }

                return StatefulBuilder(
                  builder: (context, setModalState) {
                    final gridColumns = fileManager.categoriesGridColumns;
                    final activeCats = provider.activeCategories;
                    final categoriesMap =
                        QuickCategoriesGrid.getAllCategoriesMap(
                          context,
                          isDark,
                          widget.onNavigateTab,
                        );

                    return Column(
                      children: [
                        const SizedBox(height: 12),
                        Container(
                          width: 40,
                          height: 4,
                          decoration: BoxDecoration(
                            color: Colors.grey.withOpacity(0.3),
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                        const SizedBox(height: 16),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 20.0),
                          child: Center(
                            child: Text(
                              L10n.of(context).msge7d18d73,
                              style: theme.textTheme.titleLarge?.copyWith(
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                        ),
                        // 以下全部内容（列数 / 底部导航栏开关 / 槽位配置 / 显示自定义入口 /
                        // 添加按钮 / 分类列表）统一放进 ReorderableListView 的 header 里
                        // 随列表一起滚动。绝不能把它们当成 Column 的固定子项：固定子项会把
                        // Expanded 列表的视口挤到 0，导致下方开关既看不到也拉不上来。
                        Expanded(
                          child: ReorderableListView.builder(
                            scrollController: scrollController,
                            physics: const BouncingScrollPhysics(),
                            padding: EdgeInsets.only(
                              bottom:
                                  MediaQuery.of(context).padding.bottom + 16,
                            ),
                            onReorder: (oldIndex, newIndex) {
                              if (newIndex > oldIndex) newIndex -= 1;
                              final fullOrder = PreferencesService
                                  .resolveFullOrder(provider.categoryOrder);
                              if (oldIndex < 0 ||
                                  oldIndex >= fullOrder.length) {
                                setModalState(() {});
                                return;
                              }
                              final item = fullOrder.removeAt(oldIndex);
                              fullOrder.insert(
                                newIndex.clamp(0, fullOrder.length),
                                item,
                              );
                              PreferencesService.saveFullGridOrder(fullOrder);
                              // 同步分类顺序（分类部分写回 provider）
                              final newCatOrder = fullOrder
                                  .where((e) =>
                                      !PreferencesService.isSysEntryKey(e))
                                  .toList();
                              provider.setCategoryOrder(newCatOrder);
                              setModalState(() {});
                            },
                            itemCount: fullOrder.length,
                            itemBuilder: (context, index) {
                              final key = fullOrder[index];
                              // 系统入口行（自定义/传输/设置）：与分类项同构，
                              // 可开关、可重命名、可拖动排序（拖拽即双向同步）
                              if (PreferencesService.isSysEntryKey(key)) {
                                return _buildSysEntryListItem(
                                  context,
                                  key,
                                  setModalState,
                                );
                              }
                              final cat = categoriesMap[key];
                              if (cat == null)
                                return const SizedBox.shrink(
                                  key: ValueKey('empty'),
                                );

                              final isEnabled = activeCats.contains(key);

                              return Container(
                                key: _getItemKey(key),
                                child: CategoryItemWidget(
                                  key: ValueKey(key),
                                  label: key,
                                  cat: cat,
                                  isEnabled: isEnabled,
                                  provider: provider,
                                  index: index,
                                ),
                              );
                            },
                            header: Column(
                              children: [
                        Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 20.0,
                            vertical: 8.0,
                          ),
                          child: Row(
                            children: [
                              Expanded(
                                child: Text(
                                  L10n.of(context).ui_columns_per_row,
                                  style: theme.textTheme.titleLarge?.copyWith(
                                    fontWeight: FontWeight.bold,
                                    fontSize: 16,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 16),
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 12),
                                decoration: BoxDecoration(
                                  color: theme.colorScheme.surfaceVariant.withOpacity(0.3),
                                  borderRadius: BorderRadius.circular(8),
                                  border: Border.all(
                                    color: theme.colorScheme.onSurface.withOpacity(0.1),
                                  ),
                                ),
                                child: DropdownButton<int>(
                                  value: gridColumns,
                                  isDense: true,
                                  underline: const SizedBox(),
                                  icon: const Icon(Icons.arrow_drop_down),
                                  borderRadius: BorderRadius.circular(8),
                                  style: TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.w600,
                                    color: theme.colorScheme.onSurface.withOpacity(0.8),
                                  ),
                                  items: [
                                    DropdownMenuItem(
                                      value: 2,
                                      child: Text(L10n.of(context).ui_2columns),
                                    ),
                                    DropdownMenuItem(
                                      value: 3,
                                      child: Text(L10n.of(context).ui_3columns),
                                    ),
                                    DropdownMenuItem(
                                      value: 4,
                                      child: Text(L10n.of(context).ui_4columns),
                                    ),
                                  ],
                                  onChanged: (val) {
                                    if (val != null) {
                                      context.read<FileManagerProvider>().setCategoriesGridColumns(val);
                                      setModalState(() {});
                                    }
                                  },
                                ),
                              ),
                            ],
                          ),
                        ),
                        // ===== 底部导航栏 =====
                        Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 20.0,
                            vertical: 4.0,
                          ),
                          child: Row(
                            children: [
                              Expanded(
                                child: Text(
                                  L10n.of(context).ui_bottom_tab_bar,
                                  style: theme.textTheme.titleLarge?.copyWith(
                                    fontWeight: FontWeight.bold,
                                    fontSize: 16,
                                  ),
                                ),
                              ),
                              // 总开关：关闭时底部 4-tab 折叠隐藏
                              Switch(
                                value: context
                                    .watch<FileManagerProvider>()
                                    .bottomNavBarEnabled,
                                onChanged: (v) {
                                  context
                                      .read<FileManagerProvider>()
                                      .setBottomNavBarEnabled(v);
                                  setModalState(() {});
                                },
                              ),
                            ],
                          ),
                        ),
                        Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 20.0,
                            vertical: 2.0,
                          ),
                          child: Text(
                            L10n.of(context).ui_bottom_tab_custom_hint,
                            style: TextStyle(
                              fontSize: 13,
                              color: theme.colorScheme.onSurface
                                  .withOpacity(0.6),
                            ),
                          ),
                        ),
                        // 槽位配置区：开关关闭时整体折叠隐藏
                        if (PreferencesService.getBottomNavBarEnabled()) ...[
                          Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 20.0,
                              vertical: 2.0,
                            ),
                            child: Text(
                              L10n.of(context).ui_long_press_switch,
                              style: TextStyle(
                                fontSize: 11,
                                color: theme.colorScheme.onSurface
                                    .withOpacity(0.5),
                              ),
                            ),
                          ),
                          _buildBottomSlotRow(context, 0, setModalState),
                          _buildBottomSlotRow(context, 1, setModalState),
                          _buildBottomSlotRow(context, 2, setModalState),
                          _buildBottomSlotRow(context, 3, setModalState),
                        ],
                        const SizedBox(height: 8),
                        Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 20.0,
                            vertical: 4.0,
                          ),
                          child: Align(
                            alignment: Alignment.centerLeft,
                            child: Text(
                              L10n.of(context).msg445a43cb,
                              style: TextStyle(
                                color: theme.colorScheme.onSurface.withOpacity(
                                  0.6,
                                ),
                                fontSize: 13,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 8),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 20.0),
                          child: OutlinedButton.icon(
                            icon: const Icon(Broken.add, size: 20),
                            label: Text(
                              L10n.of(context).msg944d5ecd,
                              style: TextStyle(fontWeight: FontWeight.bold),
                            ),
                            style: OutlinedButton.styleFrom(
                              minimumSize: const Size.fromHeight(46),
                              foregroundColor: theme.colorScheme.primary,
                              side: BorderSide(
                                color: theme.colorScheme.primary.withOpacity(
                                  0.5,
                                ),
                              ),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(16),
                              ),
                            ),
                            onPressed: () async {
                              final paths = await InternalFilePickerScreen.show(
                                context,
                                rootPath: fileManager.rootPath,
                              );
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
                              ],
                            ),
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
      },
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
  Future<void> _showRenameDialog(BuildContext context) async {
    final theme = Theme.of(context);
    final currentLabel = widget.cat['label'] as String;
    final TextEditingController controller = TextEditingController(
      text: currentLabel,
    );

    await showDialog<void>(
      context: context,
      builder: (context) {
        return AlertDialog(
          backgroundColor: theme.scaffoldBackgroundColor,
          title: Text(
            L10n.of(context).msgc8ce4b36,
            style: theme.textTheme.titleLarge?.copyWith(
              fontWeight: FontWeight.bold,
            ),
          ),
          content: TextField(
            controller: controller,
            autofocus: true,
            decoration: InputDecoration(
              hintText: L10n.of(context).msgf139c5cf,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide(
                  color: theme.colorScheme.onSurface.withOpacity(0.1),
                ),
              ),
            ),
            onSubmitted: (_) {
              Navigator.of(context).pop();
            },
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text(L10n.of(context).ui_cancel),
            ),
            TextButton(
              onPressed: () {
                final newLabel = controller.text.trim();
                if (newLabel.isNotEmpty) {
                  widget.provider.renameCategory(widget.label, newLabel);
                }
                Navigator.of(context).pop();
              },
              child: Text(
                L10n.of(context).ui_done,
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  color: theme.colorScheme.primary,
                ),
              ),
            ),
          ],
        );
      },
    );
  }

@override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
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
              shape: BoxShape.rectangle,
              borderRadius: BorderRadius.circular(6),
            ),
            child: Icon(icon, color: color, size: 22),
          ),
          title: Row(
            children: [
              Expanded(
                child: Text(
                  widget.cat['label'] as String,
                  style: const TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 15,
                  ),
                ),
              ),
            ],
          ),
          subtitle: isCustom
              ? Text(
                  widget.cat['path'] as String,
                  style: TextStyle(
                    fontSize: 11,
                    color: theme.colorScheme.onSurface.withOpacity(0.5),
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                )
              : (isStandardCategory && customPaths.isNotEmpty
                    ? Text(
                        L10n.of(
                          context,
                        ).ui_added_custom_paths(customPaths.length),
                        style: TextStyle(
                          fontSize: 11,
                          color: theme.colorScheme.primary,
                          fontWeight: FontWeight.w500,
                        ),
                      )
                    : null),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (isCustom) ...[
                IconButton(
                  icon: const Icon(
                    Broken.trash,
                    color: Colors.redAccent,
                    size: 20,
                  ),
                  tooltip: L10n.of(context).msg94733bec,
                  onPressed: () => widget.provider.removeCustomShortcut(label),
                ),
                const SizedBox(width: 4),
              ],
              IconButton(
                icon: const Icon(Icons.edit, color: Colors.grey, size: 20),
                tooltip: L10n.of(context).msgc8ce4b36,
                onPressed: () => _showRenameDialog(context),
              ),
              const SizedBox(width: 4),
              Switch(
                value: widget.isEnabled,
                activeColor: theme.colorScheme.primary,
                onChanged: (val) => widget.provider.toggleCategory(label),
              ),
              const SizedBox(width: 12),
            ],
          ),
        ),
      ],
    );
  }
}