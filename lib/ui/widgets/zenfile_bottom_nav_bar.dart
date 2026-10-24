import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/icon_fonts/broken_icons.dart';
import '../../providers/file_manager_provider.dart';
import '../../services/preferences_service.dart';
import 'liquid_bottom_bar.dart';
import 'quick_categories_grid.dart';
import 'package:zenfile/l10n/generated/app_localizations.dart';

/// 首页 IndexedStack 中「设置」tab 的序号（0 分类 / 1 浏览 / 2 传输 / 3 设置）。
///
/// 底栏是 tab 栏的唯一定制渲染方：槽位映射内置「设置」页、以及常驻底栏
/// （[PersistentNavBarScope]）在设置子页上高亮「设置」tab 都要用这个序号。
/// 放这里而非 home_screen，避免页面反向依赖 widget 形成循环 import；
/// home_screen 的 `_settingsTabIndex` 直接引用本常量，两边永不漂移。
const int kZenFileSettingsTabIndex = 3;

/// 首页底部 4-tab（液态胶囊底栏）的**可复用构建**。
///
/// 原本内联在 home_screen 的 `_buildBottomTabs` 里，设置重组后「导航栏常驻
/// 其他页面」（persistentTabBar）需要在设置子页等全屏路由上也渲染同一条栏，
/// 因此提取为公开组件：
///
/// · 组件内聚：槽位解析（内置页 / 最近 / 工具箱 / 自定义快捷方式）、
///   「隐藏导航栏标签」订阅、底栏不透明度订阅、胶囊样式与 SafeArea ——
///   任何宿主拿到的都是与首页完全同款的底栏；
/// · 宿主保留：高亮状态（[currentIndex] / [activeBottomSlot]）与动作
///   （切页 / 打开槽位入口 / 长按替换槽位）经回调委托 —— 槽位页面栈、
///   IndexedStack 切页等状态归宿主所有，组件不做任何导航决定；
/// · 首页复用：HomeScreen 原位传入自己的状态与既有方法，行为零变化。
///
/// [currentIndex] 当前内置 tab 序号（无内置页高亮时配合 [activeBottomSlot]
/// 判定）；[activeBottomSlot] 当前高亮的自定义槽位号，-1 = 无（内置页高亮）。
/// [atTop] 本栏挂在顶栏槽位（导航栏位置=顶部）时不吃底部安全区；
/// [attachedTop] 与浏览页操作栏拼成一整块时顶角收方（仅首页会用到）。
class ZenFileBottomNavBar extends StatelessWidget {
  const ZenFileBottomNavBar({
    super.key,
    required this.currentIndex,
    required this.activeBottomSlot,
    this.atTop = false,
    this.attachedTop = false,
    required this.onSwitchTab,
    required this.onOpenSlotEntry,
    this.onSlotLongPress,
  });

  final int currentIndex;
  final int activeBottomSlot;
  final bool atTop;
  final bool attachedTop;

  /// 点击**内置 tab**（或被槽位承载的内置页）：宿主切换 IndexedStack。
  final ValueChanged<int> onSwitchTab;

  /// 点击**自定义槽位 tab**（最近 / 工具箱 / 分类入口 / 快捷方式等）：
  /// 宿主打开对应入口（壳内页面或切页）。
  final ValueChanged<int> onOpenSlotEntry;

  /// 长按槽位替换入口。null（常驻底栏场景）= 不响应长按 —— 长按替换后的
  /// 配置落盘只刷新首页自身的底栏，跨路由场景会出现首页与常驻栏状态不同步，
  /// 故常驻栏不提供该入口（首页底栏长按仍可用）。
  final ValueChanged<int>? onSlotLongPress;

  @override
  Widget build(BuildContext context) {
    final l10n = L10n.of(context);
    // 「隐藏导航栏标签」：开启时 tab 只渲染图标、不渲染文字标签。
    // （该开关曾随底栏重构为 LiquidBottomBar 而失效 —— itemBuilder 此前未消费
    // 这个状态。用 select 订阅，开关切换即触发底栏重建；内置 tab 与自定义槽位
    // tab 都走 itemBuilder，一处判断全覆盖。）
    final hideNavLabels =
        context.select<FileManagerProvider, bool>((p) => p.hideNavLabels);
    final slot0 = _resolveTabSlot(
      context,
      0,
      defaultIcon: Broken.category,
      defaultLabel: l10n.cat_quick_categories,
      defaultIndex: 0,
    );
    final slot1 = _resolveTabSlot(
      context,
      1,
      defaultIcon: Broken.folder,
      defaultLabel: l10n.ui_file,
      defaultIndex: 1,
    );
    final slot2 = _resolveTabSlot(
      context,
      2,
      defaultIcon: Broken.link,
      defaultLabel: l10n.ui_transfers,
      defaultIndex: 2,
    );
    final slot3 = _resolveTabSlot(
      context,
      3,
      defaultIcon: Broken.clock,
      defaultLabel: l10n.cat_recent,
      defaultIndex: -1,
    );
    // 第 5 槽：默认关闭；开启后未配置时默认「工具箱」。
    final slot4 = _resolveTabSlot(
      context,
      4,
      defaultIcon: Icons.home_repair_service,
      defaultLabel: l10n.cat_toolbox,
      defaultIndex: -1,
    );
    // 只把**开启**的槽位放进 tab 栏：itemCount 随之动态变化，
    // 关闭槽位的配置仍留在存储里（重新选择页面即恢复）。
    final tabData = <List<Object>>[
      if (PreferencesService.getBottomTabSlotEnabled(0)) slot0,
      if (PreferencesService.getBottomTabSlotEnabled(1)) slot1,
      if (PreferencesService.getBottomTabSlotEnabled(2)) slot2,
      if (PreferencesService.getBottomTabSlotEnabled(3)) slot3,
      if (PreferencesService.getBottomTabSlotEnabled(4)) slot4,
    ];
    // 兜底：极端情况下 5 个槽位全被关闭时保留第 1 槽，
    // 避免 itemCount=0 触发 LiquidBottomBar 的 assert 崩溃。
    if (tabData.isEmpty) tabData.add(slot0);

    // ── 液态玻璃底栏 ──────────────────────────────────────────────────
    //
    // 样式与动效参考 Kyant0/AndroidLiquidGlass 的 LiquidBottomTabs
    // （Ghost Downloader v4.4.0 的 assets/licenses/liquid-bottom-bar.txt 标注了
    //  该来源为 2.0.0 catalog，经 BiliTools ui/liquidtabs/ 二次适配）。
    //
    // 与上一版「每个 tab 各自一块底色」的本质区别：**全程只有一块胶囊指示器**，
    // 它在 4 个槽位之间弹簧滑移、按压鼓包、被移动速度横向拉长 / 纵向压扁。
    // 外层的玻璃底板（半透明底 + 模糊 + 描边）已按用户要求去掉（showGlassPlate:
    // false）—— 只留胶囊浮在页面背景上；浏览页操作栏仍是独立玻璃胶囊。
    // 具体参数与本文件的分工说明见 lib/ui/widgets/liquid_bottom_bar.dart。
    //
    // 命中区仍是 itemCount 个等分的**静止**区域（不随指示器移动），避免「胶囊滑到哪才能点哪」。
    // 上滑唤起收藏夹的 GestureDetector 在宿主（首页）外层，命中范围不受影响。
    int selectedSlot = -1;
    for (var i = 0; i < tabData.length; i++) {
      final tab = tabData[i];
      final isSelected = (tab[3] as bool)
          ? activeBottomSlot == (tab[4] as int)
          : activeBottomSlot == -1 && currentIndex == (tab[2] as int);
      if (isSelected) {
        selectedSlot = i;
        break;
      }
    }

    return SafeArea(
      // 只在**真正落在底栏**时吃底部手势条高度；挂到顶栏槽位时改吃状态栏高度。
      // 反过来（挂顶栏却吃 bottom）会踩 extendBody 的坑：body 的 padding.bottom
      // 已被抬升为底栏总高，SafeArea 会把这段高度白垫在胶囊下面 —— 顶部多一条
      // 同色空带（用户反馈的「背景多出一层」）。
      top: atTop,
      bottom: !atTop,
      child: Padding(
        // 顶部 kLiquidNavTopGap 悬浮间距：胶囊像浮在内容之上。
        // 浏览页的操作栏要把这段间距扣掉才能与胶囊「紧贴」（见 DirectoryScreen）。
        padding: const EdgeInsets.fromLTRB(
          16,
          kLiquidNavTopGap,
          16,
          kLiquidNavBottomGap,
        ),
        child: LiquidBottomBar(
          itemCount: tabData.length,
          selectedIndex: selectedSlot,
          // 与上方浏览操作栏拼成整块时，顶角收成方角（两块留白一致、上下紧贴，
          // 拼起来是一个连续容器；仍倒圆会在两侧各露一个三角形缺口）。
          attachedTop: attachedTop,
          // 去掉外层玻璃底板：只保留滑动的胶囊指示器与 tab 内容，
          // 观感是「一枚胶囊在 4 个槽位间滑动」，不再有承载它的那块板。
          showGlassPlate: false,
          // issue #42：底栏不透明度由用户在「导航栏设置」里调节。
          // `showGlassPlate:false` 时可见的正是那块实底胶囊（LiquidBarSurface），
          // 所以这个值必须一路传到它；调到 100% 时连背景模糊一起省掉。
          opacity: context.select<FileManagerProvider, double>(
            (p) => p.navBarOpacityFor(Theme.of(context).brightness),
          ),
          onSelect: (i) {
            final tab = tabData[i];
            if (tab[3] as bool) {
              onOpenSlotEntry(tab[4] as int);
            } else {
              onSwitchTab(tab[2] as int);
            }
          },
          // 任意槽位长按：不进自定义快捷方式页即可替换入口（常驻底栏为 null）。
          onLongPressItem: onSlotLongPress == null
              ? null
              : (i) => onSlotLongPress!(tabData[i][4] as int),
          itemBuilder: (context, i, selected) {
            final tab = tabData[i];
            return _buildTabItem(
              context,
              tab[0] as IconData,
              tab[1] as String,
              selected: selected,
              showLabel: !hideNavLabels,
            );
          },
        ),
      ),
    );
  }

  /// 解析底部导航槽位 0-4 的显示与点击：未自定义返回默认内置页，自定义返回对应入口。
  ///
  /// 返回 `[icon, label, tabIndex, isCustomEntry, slot]`。本组件只负责**解析与
  /// 渲染**，点击动作经 [onSwitchTab] / [onOpenSlotEntry] 委托宿主。
  List<Object> _resolveTabSlot(
    BuildContext context,
    int slot, {
    required IconData defaultIcon,
    required String defaultLabel,
    required int defaultIndex,
  }) {
    final cfg = PreferencesService.getBottomTabSlotConfig(slot);
    if (cfg == null) {
      // v3.4b2：默认第 4 个槽位由「设置」改为「最近」（isCustomEntry 走 onOpenSlotEntry）
      if (slot == 3) {
        return [Broken.clock, L10n.of(context).cat_recent, -1, true, slot];
      }
      // 第 5 槽默认「工具箱」：isCustomEntry=true，点击走 onOpenSlotEntry
      // 推入壳内页面（占槽位高亮），与其它分类入口页一致。
      if (slot == 4) {
        return [
          Icons.home_repair_service,
          L10n.of(context).cat_toolbox,
          -1,
          true,
          slot,
        ];
      }
      return [defaultIcon, defaultLabel, defaultIndex, false, slot];
    }
    final type = cfg['type'];
    final key = cfg['key'];
    if (type == 'builtin') {
      switch (key) {
        case 'tab_categories':
          return [Broken.category, L10n.of(context).cat_quick_categories, 0, false, slot];
        case 'tab_files':
          return [Broken.folder, L10n.of(context).ui_file, 1, false, slot];
        case 'tab_settings':
          return [Broken.setting_2, L10n.of(context).cat_settings, kZenFileSettingsTabIndex, false, slot];
        case 'tab_recent':
          // 最近页走壳内导航（与默认 slot3 一致）
          return [Broken.clock, L10n.of(context).cat_recent, -1, true, slot];
        default:
          return [Broken.link, L10n.of(context).ui_transfers, 2, false, slot];
      }
    }
    // custom_entry：打开自定义快捷方式弹窗（isCustomEntry=true → 点击走 onOpenSlotEntry）
    if (type == 'custom_entry') {
      return [
        Broken.edit_2,
        PreferencesService.getCustomEntryLabel() ??
            L10n.of(context).ui_show_custom_entry,
        -1,
        true,
        slot,
      ];
    }
    // category / shortcut：从分类页全部入口重建显示与动作（与分类页网格同源）
    final map = QuickCategoriesGrid.getAllCategoriesMap(
      context,
      Theme.of(context).brightness == Brightness.dark,
      onSwitchTab,
    );
    final entry = map[key];
    if (entry != null) {
      return [entry['icon'] as IconData, entry['label'] as String, -1, true, slot];
    }
    // 配置失效（快捷方式被删除等）：回退默认内置页
    return [defaultIcon, defaultLabel, defaultIndex, false, slot];
  }

  /// 仅渲染底部槽位的**内容**（图标 + 文字）。
  ///
  /// 点击 / 长按由 [LiquidBottomBar] 统一接管，选中态的「底」由那块滑动的胶囊
  /// 指示器负责，因此这里不再画自己的底色，也不再包 InkWell —— 否则会出现
  /// 「胶囊滑到 A、A 自己又冒出一块底」的双底。
  ///
  /// [showLabel] 为 false（「隐藏导航栏标签」开启）时只渲染图标：
  /// 底栏总高固定（kLiquidBarHeight）且每个槽位内容由 Center 垂直居中，
  /// 去掉文字后图标自动居中，布局不会塌陷。
  Widget _buildTabItem(
    BuildContext context,
    IconData icon,
    String label, {
    required bool selected,
    bool showLabel = true,
  }) {
    final theme = Theme.of(context);
    final idleColor = theme.colorScheme.onSurface.withValues(alpha: 0.55);
    final iconWidget = Icon(
      icon,
      size: 21,
      color: selected ? theme.colorScheme.primary : idleColor,
    );
    if (!showLabel) return iconWidget;
    return Column(
      mainAxisSize: MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        iconWidget,
        const SizedBox(height: 2),
        Text(
          label,
          style: TextStyle(
            fontSize: 10.5,
            height: 1.05,
            fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
            color: selected ? theme.colorScheme.primary : idleColor,
          ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ],
    );
  }
}
