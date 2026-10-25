import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:path/path.dart' as p;
import '../../providers/file_manager_provider.dart';
import '../../core/icon_fonts/broken_icons.dart';
import 'liquid_bottom_bar.dart' show LiquidSpring;
import 'liquid_pressable.dart';
import 'package:zenfile/l10n/generated/app_localizations.dart';

class DirectoryTabBar extends StatefulWidget implements PreferredSizeWidget {
  final FileManagerProvider provider;
  final ScrollController? scrollController;

  const DirectoryTabBar({super.key, required this.provider, this.scrollController});

  @override
  State<DirectoryTabBar> createState() => _DirectoryTabBarState();

  @override
  Size get preferredSize => const Size.fromHeight(32);
}

class _DirectoryTabBarState extends State<DirectoryTabBar>
    with SingleTickerProviderStateMixin {
  /// 上一次构建时的标签页数量，用于感知「新建标签页」。
  /// 新建时列表自动滚到最右：新标签页露出，旧标签页被往左挤出可视区。
  int? _lastTabCount;

  /// 标签之间的横向间距（每个标签右侧留白）。
  /// 指示器宽度要把它扣掉，否则胶囊会比标签宽 4dp、压到相邻标签上。
  static const double _tabGap = 4;

  /// 滚动内容里的 Stack（指示器与标签行的共同锚点，用来取相对坐标）。
  final GlobalKey _stackKey = GlobalKey();

  /// 每个标签页的 GlobalKey，按 `tab.id` 复用（标签可增删、下标会变，
  /// 用下标做 key 会把测量结果错位到别的标签上）。
  final Map<String, GlobalKey> _itemKeys = <String, GlobalKey>{};

  // ── 指示器动效（与 4-tab 底栏同一套弹簧参数）─────────────────────────
  // 位移 / 宽度两条弹簧各自独立：标签宽度不一样（60~120dp），
  // 只动 left 会让胶囊在宽窄标签之间「拉伸」，观感发黏。
  late final LiquidSpring _indLeft =
      LiquidSpring(stiffness: 1000, dampingRatio: 1, initial: 0);
  late final LiquidSpring _indWidth =
      LiquidSpring(stiffness: 1000, dampingRatio: 1, initial: 0);

  /// 按压鼓包（0..1）：和底栏一样，按住时指示器轻微放大。
  late final LiquidSpring _press =
      LiquidSpring(stiffness: 1000, dampingRatio: 1, initial: 0);

  late final Ticker _ticker = createTicker(_onTick);
  Duration? _lastTick;

  /// 是否已经量过一次（量之前不画胶囊，避免首帧在所有标签左侧闪一个空块）。
  bool _indicatorMeasured = false;

  /// 上一次的目标值：只有目标真的变了才重新发弹簧，否则每帧重建
  /// （build → post-frame → animateTo）会把弹簧速度清零，动画变成指数逼近。
  double? _targetLeft;
  double? _targetWidth;

  void _ensureTicking() {
    if (!_ticker.isActive) {
      _lastTick = null;
      _ticker.start();
    }
  }

  void _onTick(Duration elapsed) {
    final last = _lastTick;
    _lastTick = elapsed;
    final dt = last == null
        ? 1 / 60
        : ((elapsed - last).inMicroseconds / 1000000).clamp(0.0, 0.05);
    var busy = false;
    busy = _indLeft.step(dt) || busy;
    busy = _indWidth.step(dt) || busy;
    busy = _press.step(dt) || busy;
    setState(() {});
    if (!busy) {
      _ticker.stop();
      _lastTick = null;
    }
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  /// 量出当前激活标签在**滚动内容坐标**里的位置，并驱动指示器滑过去。
  ///
  /// 只做相对测量（相对 [__stackKey]），因此完全不用关心横向滚动偏移：
  /// 滚动时标签与指示器同处一个被平移的子树里，天然同步。
  void _syncIndicator() {
    if (!mounted) return;
    final provider = widget.provider;
    final tabs = provider.tabs;
    final index = provider.activeTabIndex;
    if (index < 0 || index >= tabs.length) return;
    final itemContext = _itemKeys[tabs[index].id]?.currentContext;
    final stackBox = _stackKey.currentContext?.findRenderObject();
    if (itemContext == null || stackBox is! RenderBox) return;
    final box = itemContext.findRenderObject();
    if (box is! RenderBox || !box.hasSize) return;

    final origin = box.localToGlobal(Offset.zero, ancestor: stackBox);
    final left = origin.dx;
    final width = math.max(0.0, box.size.width - _tabGap);

    if (!_indicatorMeasured) {
      _indicatorMeasured = true;
      _indLeft.snapTo(left);
      _indWidth.snapTo(width);
      _targetLeft = left;
      _targetWidth = width;
      setState(() {});
      return;
    }
    var started = false;
    if (_targetLeft == null || (_targetLeft! - left).abs() > 0.5) {
      _targetLeft = left;
      _indLeft.animateTo(left);
      started = true;
    }
    if (_targetWidth == null || (_targetWidth! - width).abs() > 0.5) {
      _targetWidth = width;
      _indWidth.animateTo(width);
      started = true;
    }
    if (started) _ensureTicking();
  }

  void _maybeScrollToEndOnNewTab(int currentCount) {
    final controller = widget.scrollController;
    if (controller == null || !controller.hasClients) return;
    final prev = _lastTabCount;
    if (prev != null && currentCount > prev) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !controller.hasClients) return;
        controller.animateTo(
          controller.position.maxScrollExtent,
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOut,
        );
      });
    }
    _lastTabCount = currentCount;
  }

  @override
  Widget build(BuildContext context) {
    _maybeScrollToEndOnNewTab(widget.provider.tabs.length);
    final theme = Theme.of(context);
    final tabs = widget.provider.tabs;
    // 标签关闭后清掉残留 key，避免 Map 随使用时长无限增长。
    if (_itemKeys.length > tabs.length) {
      final live = tabs.map((t) => t.id).toSet();
      _itemKeys.removeWhere((id, _) => !live.contains(id));
    }
    // 每帧结束后量一次激活标签的位置（位置只随标签增删 / 文字变化而变，
    // 滚动不影响内容坐标），这样切标签、改目录、新建标签都能自动跟上。
    WidgetsBinding.instance.addPostFrameCallback((_) => _syncIndicator());

    // 无背景色 Container —— 让标签页栏直接浮在 Scaffold 背景上，
    // 与上方 AppBar 视觉融合为一整块顶部区域（与分类页一致）。
    //
    // 结构说明（与 4-tab 底栏同源动效）：
    //   SingleChildScrollView > Stack[ 滑动胶囊指示器, Row(标签) ]
    // 指示器与标签行同处**滚动内容坐标**：横向滚动时胶囊自然跟着标签走，
    // 不需要每帧拿 scrollOffset 反算位置（那会在快速滑动时抖动）。
    return SizedBox(
      height: 32,
      child: Row(
        children: [
          Expanded(
            child: Listener(
              onPointerDown: (_) {
                widget.provider.setTabBarInteracting(true);
                _press.animateTo(1);
                _ensureTicking();
              },
              onPointerUp: (_) {
                widget.provider.setTabBarInteracting(false);
                _press.animateTo(0);
                _ensureTicking();
              },
              onPointerCancel: (_) {
                widget.provider.setTabBarInteracting(false);
                _press.animateTo(0);
                _ensureTicking();
              },
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                controller: widget.scrollController,
                physics: const BouncingScrollPhysics(),
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                child: Stack(
                  key: _stackKey,
                  clipBehavior: Clip.none,
                  children: [
                    if (_indicatorMeasured)
                      Positioned(
                        left: _indLeft.value,
                        top: 0,
                        bottom: 0,
                        width: math.max(0.0, _indWidth.value),
                        child: IgnorePointer(child: _buildIndicator(theme)),
                      ),
                    Row(
                      children: [
                        for (var i = 0; i < tabs.length; i++)
                          _buildTabItem(context, theme, i),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
          // 新建标签页 / 复制标签页：**两个入口合并成一个加号菜单**。
          //
          // 「复制标签页」原先是底部操作栏里的独立按钮，但它和「新建标签页」
          // 是同一类动作（再开一个标签），分在两处反而要找。合并后加号就地弹出
          // 两个选项；腾出来的操作栏槽位给了双窗口的「互换左右窗口」。
          PopupMenuButton<String>(
            constraints: const BoxConstraints(),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            icon: const Icon(Broken.add, size: 20),
            tooltip: L10n.of(context).msgb52d4a73,
            shape: const RoundedRectangleBorder(
              borderRadius: BorderRadius.all(Radius.circular(16)),
            ),
            // 就地向下展开：菜单锚在这个加号正下方，而不是飘到屏幕边缘。
            position: PopupMenuPosition.under,
            elevation: 8,
            onSelected: (value) {
              final provider = widget.provider;
              if (value == 'duplicate') {
                provider.duplicateActiveTab();
              } else {
                provider.addTab(provider.rootPath);
              }
            },
            itemBuilder: (context) => [
              PopupMenuItem<String>(
                value: 'new',
                child: Row(
                  children: [
                    const Icon(Broken.add, size: 20),
                    const SizedBox(width: 12),
                    Text(
                      L10n.of(context).msgb52d4a73,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                  ],
                ),
              ),
              PopupMenuItem<String>(
                value: 'duplicate',
                child: Row(
                  children: [
                    const Icon(Broken.copy, size: 20),
                    const SizedBox(width: 12),
                    Text(
                      L10n.of(context).msg4e9c344a,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                  ],
                ),
              ),
            ],
          ),
          // 关闭标签页菜单：「关闭当前 / 关闭所有」合并成一个按钮（与旁边加号
          // 的新建 / 复制同款就地弹出样式）。
          //
          // 「关闭当前」关的是**当前激活**的标签页，走与长按标签菜单同一个
          // provider.closeTab；只剩 1 个标签或当前标签被 pin 住时该选项不出现
          // （与长按菜单的 canClose 判定一致，pin 的语义是「关不掉」）。
          // 「关闭所有」**不再二次弹窗确认**：closeAllTabs 本身是「重置回本地
          // 根目录标签」（单窗口留 1 个、双窗口新建 2 个）而不是「全关成空」，
          // 误触代价低，不值得再拦一道对话框。
          PopupMenuButton<String>(
            constraints: const BoxConstraints(),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            icon: const Icon(Broken.close_circle, size: 18),
            tooltip: L10n.of(context).ui_close_tab,
            shape: const RoundedRectangleBorder(
              borderRadius: BorderRadius.all(Radius.circular(16)),
            ),
            // 就地向下展开：菜单锚在这个按钮正下方，而不是飘到屏幕边缘。
            position: PopupMenuPosition.under,
            elevation: 8,
            onSelected: (value) {
              final provider = widget.provider;
              if (value == 'current') {
                provider.closeTab(provider.activeTabIndex);
              } else {
                provider.closeAllTabs();
              }
            },
            itemBuilder: (context) {
              final provider = widget.provider;
              final tabs = provider.tabs;
              final canCloseCurrent = tabs.length > 1 &&
                  !tabs[provider.activeTabIndex].isPinned;
              return [
                if (canCloseCurrent)
                  PopupMenuItem<String>(
                    value: 'current',
                    child: Row(
                      children: [
                        const Icon(
                          Broken.close_circle,
                          size: 20,
                          color: Colors.redAccent,
                        ),
                        const SizedBox(width: 12),
                        Text(
                          L10n.of(context).ui_close_current_tab,
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                      ],
                    ),
                  ),
                PopupMenuItem<String>(
                  value: 'all',
                  child: Row(
                    children: [
                      const Icon(
                        Broken.trash,
                        size: 20,
                        color: Colors.redAccent,
                      ),
                      const SizedBox(width: 12),
                      Text(
                        L10n.of(context).ui_close_all_tabs,
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                    ],
                  ),
                ),
              ];
            },
          ),
        ],
      ),
    );
  }

  /// 单个标签页。
  ///
  /// 关键点：外层的 [Container] 挂了按 `tab.id` 复用的 [GlobalKey] ——
  /// 指示器靠它量出每个标签在滚动内容里的位置。**不能**把 key 挂到
  /// [LiquidPressable] 里面：按压 / 选中弹起会施加 `Transform.scale`，
  /// 量出来的矩形会随缩放抖动，指示器就会跟着一起抖。
  Widget _buildTabItem(BuildContext context, ThemeData theme, int index) {
    final provider = widget.provider;
    final tabs = provider.tabs;
    final tab = tabs[index];
    final activeIndex = provider.activeTabIndex;
    final isRoot = tab.currentPath == provider.rootPath;
    // 双窗口多标签：标签页栏同时承载两个 pane 的标签页，三层语义必须拉开：
    //   1. 焦点 pane  → 滑动胶囊 + primary 文字/图标 + primary 描边（最强）；
    //   2. 另一 pane  → 无胶囊 + **灰文字** + 极淡 secondary 描边（第二档，
    //      只表示「这个标签正占用着另一个窗口」，不再用主色抢焦点）；
    //   3. 其余标签   → 灰文字 + 中性淡底 + 几乎无感的描边（第三档）。
    // 旧实现给副 pane 用了 `theme.colorScheme.primary` 的文字 + 加粗，和焦点
    // pane 完全一致，只有边框颜色不同（secondary@60% 甚至更亮更粗）⇒ 两者的
    // 视觉权重几乎相同，根本分不出哪个窗口是当前的（用户反馈的「容易混淆」）。
    final isSplitMulti = provider.isSplitMultiTabActive;
    final pane0 = provider.paneTabIndex(0);
    final pane1 = provider.paneTabIndex(1);
    final bool inFocusPane = isSplitMulti && index == activeIndex;
    final bool inOtherPane =
        isSplitMulti && !inFocusPane && (index == pane0 || index == pane1);
    // 「激活态」统一判定：
    // - 双窗口多标签 → 焦点 pane 的标签（inFocusPane）；
    // - 单窗口 → index == activeIndex。
    final bool isActiveTab = isSplitMulti ? inFocusPane : index == activeIndex;
    // 远程标签页固定显示“已保存的远程客户端名称”，方便区分是哪个远程客户端。
    final bool useRemoteName = tab.isRemote && tab.remoteConnection != null;
    final title = useRemoteName
        ? tab.remoteConnection!.name
        : (isRoot ? L10n.of(context).msgfefea1b3 : p.basename(tab.currentPath));

    return Container(
      key: _itemKeys.putIfAbsent(tab.id, () => GlobalKey()),
      margin: const EdgeInsets.only(right: _tabGap),
      // 与底部 4-tab 同源的按压弹簧：按住微鼓、松开回弹；
      // 被选中的标签额外弹一下。样式（底色 / 描边 / 圆角）保持原样。
      child: LiquidPressable(
        selected: isActiveTab,
        pressScale: 1.06,
        popScale: 1.10,
        child: Material(
          // 选中底色由外层**滑动胶囊**提供（与 4-tab 指示器同款中性玻璃），
          // 这一格必须透明：自带底色会把胶囊盖住，切换时胶囊就被「跳」过去
          // 而不是滑过去 —— 那正是与底栏不一致的观感来源。
          // 未选中的标签保留一层很淡的底色（18%），否则整条栏只剩文字、
          // 看不出「一格一格」的轮廓；这个透明度也不会遮住滑过的胶囊。
          // 副窗口标签的底色再压到 10%：比普通标签更淡，且带 secondary 色相，
          // 既能和「没在双窗口里显示」的标签区分，又不会和焦点 pane 抢戏。
          color: isActiveTab
              ? Colors.transparent
              : (inOtherPane
                    ? theme.colorScheme.secondaryContainer.withValues(
                        alpha: 0.10,
                      )
                    : theme.colorScheme.surfaceContainerHighest.withValues(
                        alpha: 0.18,
                      )),
          borderRadius: BorderRadius.circular(10),
          child: InkWell(
            onTap: () => provider.setActiveTab(index),
            onDoubleTap: () {
              if (tabs.length > 1 && !tab.isPinned) {
                provider.closeTab(index);
              }
            },
            // 长按菜单的锚点取自 [_itemKeys]（挂在外层 Container 上，是真正的
            // RenderBox）。⚠️ 绝不能再用 `context.findRenderObject()`：
            // `itemBuilder` 拿到的 context 是 sliver 自己的 element，它的
            // renderObject 是 `RenderSliver`，`as RenderBox` 会直接抛
            // `_TypeError` ⇒ 长按毫无反应（「长按不出菜单」的根因）。
            onLongPress: () => _showTabMenu(context, provider, index),
            borderRadius: BorderRadius.circular(10),
            child: Container(
              constraints: const BoxConstraints(minWidth: 60, maxWidth: 120),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  // 副窗口只留一圈很淡的 secondary 描边：够看出「被另一个
                  // 窗口占用」，但远弱于焦点 pane 的 primary@40%。
                  color: isActiveTab
                      ? theme.colorScheme.primary.withValues(alpha: 0.4)
                      : (inOtherPane
                            ? theme.colorScheme.secondary.withValues(
                                alpha: 0.22,
                              )
                            : theme.dividerColor.withValues(alpha: 0.05)),
                  width: 1.2,
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _buildTabIcon(
                    context: context,
                    isRemote: tab.isRemote,
                    isPinned: tab.isPinned,
                    isRoot: isRoot,
                    isSelected: isActiveTab,
                    // 副窗口标签整体压暗：图标不再吃主色，避免和焦点 pane 抢眼。
                    dimmed: inOtherPane,
                    size: 14,
                  ),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text(
                      title.isEmpty ? '/' : title,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: isActiveTab
                            ? FontWeight.bold
                            : FontWeight.w500,
                        // 只有焦点 pane 用主色；副窗口用半透明灰（比普通
                        // 未选中标签的 0.8 更淡），视觉上明确「它不在当前窗口」。
                        color: isActiveTab
                            ? theme.colorScheme.primary
                            : (inOtherPane
                                  ? theme.colorScheme.onSurface.withValues(
                                      alpha: 0.55,
                                    )
                                  : theme.colorScheme.onSurface.withValues(
                                      alpha: 0.8,
                                    )),
                      ),
                      overflow: TextOverflow.ellipsis,
                      maxLines: 1,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 滑动胶囊指示器 —— 与 4-tab 底栏同一套配方：中性玻璃底（`onSurface` 10%）
  /// + 0.5px 细描边，不做主色填充（主色只出现在图标 / 文字上）。
  ///
  /// 按压时轻微鼓包（+8%），与底栏 `kLiquidPressScale` 的观感对齐；底栏用的是
  /// 1.39 倍，因为它的胶囊本来就贴满整格，这里格子更小，放大会顶到相邻标签。
  Widget _buildIndicator(ThemeData theme) {
    final scheme = theme.colorScheme;
    final scale = 1 + 0.08 * _press.value.clamp(0.0, 1.0);
    return Transform.scale(
      scale: scale,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: scheme.onSurface.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: scheme.onSurface.withValues(alpha: 0.06),
            width: 0.5,
          ),
        ),
      ),
    );
  }

  /// 标签按钮左侧图标：
  /// - 远程标签 → 云图标（Broken.cloud），**直接替换**文件夹图标，方便一眼辨别远程/本地浏览页。
  /// - 钉住标签 → 图钉图标；根目录 → 房子图标；其余 → 文件夹图标。
  Widget _buildTabIcon({
    required BuildContext context,
    required bool isRemote,
    required bool isPinned,
    required bool isRoot,
    required bool isSelected,
    bool dimmed = false,
    double size = 14,
  }) {
    final theme = Theme.of(context);
    final Color baseColor;
    if (dimmed) {
      // 副窗口标签：统一压到「看得见但不抢眼」的强度。图钉仍留一点橙色，
      // 否则会被误认成普通文件夹标签（形状能看出，颜色保留一点语义更稳）。
      baseColor = isPinned
          ? Colors.orange.withValues(alpha: 0.45)
          : theme.colorScheme.onSurface.withValues(alpha: 0.45);
    } else if (isPinned) {
      baseColor = Colors.orange;
    } else if (isSelected) {
      baseColor = theme.colorScheme.primary;
    } else {
      baseColor = theme.colorScheme.onSurface.withValues(alpha: 0.6);
    }
    if (isPinned) {
      return Icon(Icons.push_pin_rounded, size: size, color: baseColor);
    }
    // 远程浏览页标签：用云图标直接替换文件夹图标
    if (isRemote) {
      return Icon(Broken.cloud, size: size, color: baseColor);
    }
    final IconData base = isRoot ? Broken.home_1 : Broken.folder;
    return Icon(base, size: size, color: baseColor);
  }

  /// 长按标签页 → 「关闭标签页」菜单。
  ///
  /// ⚠️ 必须是**从标签页栏向下弹出**（紧贴被长按的那个标签下方），不是屏幕底部
  /// 的 `showModalBottomSheet`：后者离手指上百 dp，用户点完还得低头找面板，
  /// 也无法建立「这个菜单属于这一页」的指向感。
  ///
  /// 用 `showGeneralDialog` 而不是裸 `OverlayEntry`：它自带遮罩、点击外部关闭、
  /// 返回键关闭，且能自定义过渡方向（这里是从上往下滑入 + 淡入）。
  void _showTabMenu(BuildContext context, FileManagerProvider provider, int index) {
    final tab = provider.tabs[index];
    final canClose = provider.tabs.length > 1 && !tab.isPinned;
    final theme = Theme.of(context);
    final l10n = L10n.of(context);
    final title = (tab.isRemote && tab.remoteConnection != null)
        ? tab.remoteConnection!.name
        : (tab.currentPath == provider.rootPath
            ? l10n.msgfefea1b3
            : p.basename(tab.currentPath));

    // 锚点：被长按标签自己的矩形（[_itemKeys] 挂在外层 Container 上，是真正的
    // RenderBox；且没有按压缩放的 Transform 干扰）。纵向取「标签底边 + 6dp」，
    // 菜单就贴着标签栏往下展开，横向以标签中心对齐，越界回夹。
    const double menuWidth = 244;
    const double margin = 12;
    final screen = MediaQuery.sizeOf(context);
    final safeTop = MediaQuery.paddingOf(context).top;
    double left = margin;
    double top = kToolbarHeight + 40;
    final itemBox = _itemKeys[tab.id]?.currentContext?.findRenderObject();
    if (itemBox is RenderBox && itemBox.hasSize) {
      final origin = itemBox.localToGlobal(Offset.zero);
      left = origin.dx + itemBox.size.width / 2 - menuWidth / 2;
      top = origin.dy + itemBox.size.height + 6;
    }
    if (left + menuWidth > screen.width - margin) {
      left = screen.width - menuWidth - margin;
    }
    if (left < margin) left = margin;
    // 极端情况（横屏 / 分屏）兜底：菜单不能掉出屏幕。
    top = top.clamp(safeTop + 8, math.max(safeTop + 8, screen.height - 200));

    showGeneralDialog<void>(
      context: context,
      barrierDismissible: true,
      barrierLabel: l10n.ui_close_tab,
      barrierColor: Colors.black.withValues(alpha: 0.16),
      transitionDuration: const Duration(milliseconds: 180),
      pageBuilder: (dialogContext, _, _) {
        return Stack(
          children: [
            Positioned(
              left: left,
              top: top,
              width: menuWidth,
              child: Material(
                color: Colors.transparent,
                child: Container(
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surface,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(
                      color: theme.dividerColor.withValues(alpha: 0.08),
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(
                          alpha: theme.brightness == Brightness.dark ? 0.5 : 0.16,
                        ),
                        blurRadius: 22,
                        offset: const Offset(0, 8),
                      ),
                    ],
                  ),
                  padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          _buildTabIcon(
                            context: dialogContext,
                            isRemote: tab.isRemote,
                            isPinned: tab.isPinned,
                            isRoot: tab.currentPath == provider.rootPath,
                            isSelected: true,
                            size: 16,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              title.isEmpty ? '/' : title,
                              style: theme.textTheme.titleSmall
                                  ?.copyWith(fontWeight: FontWeight.bold),
                              overflow: TextOverflow.ellipsis,
                              maxLines: 1,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      // 小字说明：把「双击直接关」这个隐藏操作明确写出来，
                      // 免得用户每次都长按走菜单。
                      Text(
                        l10n.ui_close_tab_hint,
                        style: TextStyle(
                          fontSize: 11,
                          height: 1.3,
                          color: theme.colorScheme.onSurface
                              .withValues(alpha: 0.55),
                        ),
                      ),
                      if (canClose) ...[
                        const SizedBox(height: 10),
                        SizedBox(
                          width: double.infinity,
                          child: OutlinedButton.icon(
                            onPressed: () {
                              Navigator.pop(dialogContext);
                              provider.closeTab(index);
                            },
                            icon: const Icon(Broken.close_circle, size: 17),
                            label: Text(
                              l10n.ui_close_tab,
                              style:
                                  const TextStyle(fontWeight: FontWeight.bold),
                            ),
                            style: OutlinedButton.styleFrom(
                              foregroundColor: Colors.redAccent,
                              side: BorderSide(
                                color: Colors.redAccent.withValues(alpha: 0.3),
                              ),
                              padding: const EdgeInsets.symmetric(vertical: 10),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ],
        );
      },
      transitionBuilder: (dialogContext, animation, _, child) {
        final curved = CurvedAnimation(
          parent: animation,
          curve: Curves.easeOutCubic,
          reverseCurve: Curves.easeInCubic,
        );
        // 向下弹出：从锚点上方一点点滑到最终位置（配合淡入，观感是「翻下来」）。
        // ⚠️ SlideTransition 的位移是**按子节点尺寸的比例**，而这里的子节点是全屏
        // Stack ⇒ 0.018 ≈ 800dp 屏上的 14dp，小距离才像「从标签栏掉下来」，
        // 写成 0.14 会滑上百 dp，看起来像整页在下坠。
        return FadeTransition(
          opacity: curved,
          child: SlideTransition(
            position: Tween<Offset>(
              begin: const Offset(0, -0.018),
              end: Offset.zero,
            ).animate(curved),
            child: child,
          ),
        );
      },
    );
  }
}
