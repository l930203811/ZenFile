import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/scheduler.dart';

import '../../core/theme.dart';
import 'liquid_glass_panel.dart';

/// ── 液态玻璃底栏（Liquid Glass Bottom Bar）─────────────────────────────
///
/// 样式与动效参考 Kyant0/AndroidLiquidGlass 的 `LiquidBottomTabs`
/// （Ghost Downloader v4.4.0 的 `assets/licenses/liquid-bottom-bar.txt`
///  明确标注该来源为 2.0.0 catalog，经 BiliTools `ui/liquidtabs/` 二次适配）。
///
/// 与「每个 tab 各自一块底色」的实现有本质区别 —— 全程**只有一块**胶囊指示器：
///   · 它在各 tab 之间做弹簧位移（stiffness 1000、临界阻尼 ⇒ 跟手且不过冲）；
///   · 按压时整块放大到 [kLiquidPressScale]（液态「鼓包」）；
///   · 位移速度换算成「横向拉伸 + 纵向压扁」，停下来后自动归零
///     （这是「液态」的核心：静态截图看不出来，只有动起来才有）；
///   · 拖动时整条胶囊横向平移最多 [kLiquidEdgeDrift] dp（轻微视差）。
///
/// 刻意**没有沿用**上游那几项依赖 RuntimeShader 的玻璃效果（lens 折射 /
/// chromatic aberration / 高光跟随指针）：Flutter 侧没有等价 shader，
/// 硬凑只会得到一层灰雾。这里用「背景模糊 + 半透明 + 细描边 + 顶部微高光」
/// 近似玻璃质感，保证观感一致且不掉帧。

/// 底栏总高（上游 64dp）。
const double kLiquidBarHeight = 64;

/// 4-tab 槽位的**顶部留白**：胶囊与小屏底部安全区之间，只留这条缝。
///
/// 全项目只此一份定义 —— 浏览页要把操作栏顶到 4-tab 上方「紧贴」（零间距），
/// 就得把这段留白从操作栏的底部占位里扣掉；两边各写一个 6 迟早会对不齐。
const double kLiquidNavTopGap = 6;

/// 4-tab 槽位的**底部留白**（胶囊与系统手势条之间）。
const double kLiquidNavBottomGap = 10;

/// 胶囊内容行高：64 − 上下各 4dp。
const double kLiquidInnerHeight = 56;

/// 容器内左右留白，同时也是指示器的初始偏移。
const double kLiquidInset = 4;

/// 按压时指示器的放大倍数（上游 78/56）。
const double kLiquidPressScale = 78 / 56;

/// 按压时图标 / 文字的放大倍数（上游 lerp(1, 1.2, pressProgress)）。
const double kLiquidIconPressScale = 1.2;

/// 拖动时整条胶囊的最大横向偏移（dp）。
const double kLiquidEdgeDrift = 4;

/// 单个弹簧通道。Compose 的 `spring(dampingRatio, stiffness)` 与 Flutter 的
/// [SpringDescription] 换算关系（mass 恒为 1）：
///   damping = 2 * dampingRatio * sqrt(stiffness)
///
/// 公开而非私有：标签页栏（`directory_tab_bar.dart`）的滑动胶囊复用它 ——
/// 两处动效必须是同一套物理参数，否则「切换标签页」和「切换 4-tab」的手感
/// 对不上，用户一眼就能看出是两套动画。
class LiquidSpring {
  LiquidSpring({
    required this.stiffness,
    required this.dampingRatio,
    required double initial,
  }) : _value = initial;

  final double stiffness;
  final double dampingRatio;

  double _value;
  double _velocity = 0;
  Simulation? _sim;
  double _t = 0;

  double get value => _value;

  /// 当前速度（单位 / 秒）。静止时为 0。
  double get velocity => _velocity;

  bool get isAnimating => _sim != null;

  void snapTo(double v) {
    _sim = null;
    _value = v;
    _velocity = 0;
  }

  void animateTo(double target, {double velocity = 0}) {
    if (_sim == null && (_value - target).abs() < 0.0005 && velocity == 0) {
      _value = target;
      _velocity = 0;
      return;
    }
    final description = SpringDescription(
      mass: 1,
      stiffness: stiffness,
      damping: 2 * dampingRatio * math.sqrt(stiffness),
    );
    _sim = SpringSimulation(description, _value, target, velocity)
      ..tolerance = const Tolerance(distance: 0.0004, velocity: 0.0004);
    _t = 0;
  }

  /// 推进一帧，返回是否仍在运动。
  bool step(double dt) {
    final sim = _sim;
    if (sim == null) {
      _velocity = 0;
      return false;
    }
    _t += dt;
    _value = sim.x(_t);
    _velocity = sim.dx(_t);
    if (sim.isDone(_t)) {
      _value = sim.x(_t);
      _velocity = 0;
      _sim = null;
      return false;
    }
    return true;
  }
}

/// 栏位「实底」表面 —— 4-tab 胶囊与浏览页底部操作栏**共用同一份实现**。
///
/// 两条栏在浏览页上下紧贴、左右等宽，是**一个整体**：底色只要差一档，接缝处
/// 就会露馅（深色模式下尤其明显 —— 玻璃层带 6% 白雾，比实底亮一档，看起来像
/// 「一条黑栏上面浮着一块灰玻璃」）。所以配色收敛到这一处：
/// 深色 `black@42%`（与顶栏同源的实心黑）、浅色 `AppTheme.lightBarBackground@90%`
/// （主题色 12% 混白），**无高光**。
///
/// [blurSigma] > 0 时额外加背景模糊：浏览操作栏正压在文件列表上（extendBody），
/// 不模糊的话深色模式下白字会以 58% 灰透出来；4-tab 那一段底下没有内容，传 0。
///
/// [topBorderOpacity] / [bottomBorderOpacity] 用于拼接态：接缝那一侧不画描边
/// （两条 0.6px 相邻会合成约 1.2px 的亮线，像一道裂缝）。
class LiquidBarSurface extends StatelessWidget {
  const LiquidBarSurface({
    super.key,
    required this.borderRadius,
    this.topBorderOpacity = 1,
    this.bottomBorderOpacity = 1,
    this.blurSigma = 0,
    this.opacity,
    this.blurEnabled = true,
    this.child,
  });

  /// 面板外形。拼成整块时用「只圆上角」，独立时用完整胶囊。
  final BorderRadius borderRadius;

  final double topBorderOpacity;
  final double bottomBorderOpacity;

  /// 背景模糊半径（dp）。0 = 不模糊（4-tab 走这一档）。
  final double blurSigma;

  /// 底色层的**有效不透明度**（issue #42：允许调透明度 / 完全关闭）。
  ///
  /// `null` = 沿用原配方（深色 `black@42%` / 浅色 `lightBarBackground@90%`），
  /// 即未自定义时观感不变。取值 1.0 时跳过背景模糊 —— 不透明面板背后再模糊
  /// 既看不见、又白付 BackdropFilter 的逐帧重算代价。
  final double? opacity;

  /// 是否允许背景模糊（issue #42 性能降级开关，语义同 [LiquidGlassPanel.blurEnabled]）。
  final bool blurEnabled;

  /// 面板内容。省略时面板填满父级约束（用作纯背景层）。
  final Widget? child;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isDark = scheme.brightness == Brightness.dark;

    final Color surfaceColor;
    if (opacity == null) {
      surfaceColor = isDark
          ? Colors.black.withValues(alpha: 0.42)
          : AppTheme.lightBarBackground(scheme).withValues(alpha: 0.9);
    } else {
      final base = isDark ? Colors.black : AppTheme.lightBarBackground(scheme);
      surfaceColor = base.withValues(alpha: opacity!.clamp(0.0, 1.0));
    }
    final effectiveBlur =
        (!blurEnabled || (opacity != null && opacity! >= 0.999)) ? 0.0 : blurSigma;

    BorderSide side(double opacity) {
      if (opacity <= 0.001) return BorderSide.none;
      return BorderSide(
        color: scheme.onSurface.withValues(alpha: 0.08 * opacity),
        width: kLiquidGlassBorderWidth,
      );
    }

    final surface = DecoratedBox(
      decoration: BoxDecoration(
        color: surfaceColor,
        borderRadius: borderRadius,
        border: Border(
          top: side(topBorderOpacity),
          bottom: side(bottomBorderOpacity),
          left: side(1),
          right: side(1),
        ),
      ),
      child: child ?? const SizedBox.expand(),
    );

    // 实底时整层跳过 BackdropFilter（理由同 LiquidGlassPanel）。
    if (effectiveBlur <= 0) {
      return ClipRRect(borderRadius: borderRadius, child: surface);
    }
    // 模糊只能作用在自己背后：先裁形状再 BackdropFilter，否则圆角外会带出一圈毛边。
    return ClipRRect(
      borderRadius: borderRadius,
      child: BackdropFilter(
        filter: ui.ImageFilter.blur(
          sigmaX: effectiveBlur,
          sigmaY: effectiveBlur,
          tileMode: TileMode.mirror,
        ),
        child: surface,
      ),
    );
  }
}

/// 液态玻璃底栏。内容由 [itemBuilder] 提供，本组件只负责容器、指示器与动效。
class LiquidBottomBar extends StatefulWidget {
  const LiquidBottomBar({
    super.key,
    required this.itemCount,
    required this.selectedIndex,
    required this.onSelect,
    required this.itemBuilder,
    this.onLongPressItem,
    this.height = kLiquidBarHeight,
    this.attachedTop = false,
    this.showGlassPlate = true,
    this.opacity,
  }) : assert(itemCount > 0);

  final int itemCount;
  final int selectedIndex;
  final ValueChanged<int> onSelect;

  /// 逐项内容构建器。`selected` 由底栏统一判定（含 -1 表示无选中）。
  final Widget Function(BuildContext context, int index, bool selected)
  itemBuilder;

  final ValueChanged<int>? onLongPressItem;
  final double height;

  /// 是否与上方元素「拼成一整块」（浏览页的操作栏）。
  ///
  /// 为 true 时顶角改成方角：两块都留 16dp 左右边距、上下紧贴，拼起来就是一个
  /// 连续的容器 —— 若顶角仍然倒圆，会在两侧各露出一个三角形缺口，反而更零碎。
  final bool attachedTop;

  /// 是否绘制外层玻璃底板（半透明底 + 背景模糊 + 顶部高光）。
  ///
  /// false 时画「实底胶囊」：主题色底 + 描边，**无模糊、无高光**（首页 4-tab
  /// 现走这一形态 —— 背景色跟随主题、与顶部栏一致，但少了模糊层）。
  /// 浏览页操作栏仍是独立玻璃胶囊（含模糊），与本组件各自成型。
  final bool showGlassPlate;

  /// 底板不透明度（issue #42）。`null` = 沿用原玻璃配方。
  ///
  /// 注意必须传给**底板**（[LiquidBarSurface]）：`showGlassPlate: false` 时
  /// 用户看到的正是那块实底胶囊，透明度调节要落在它身上才有意义。
  final double? opacity;

  @override
  State<LiquidBottomBar> createState() => _LiquidBottomBarState();
}

class _LiquidBottomBarState extends State<LiquidBottomBar>
    with SingleTickerProviderStateMixin {
  /// 位置：以「第几个 tab」为单位，0..itemCount-1。
  late LiquidSpring _position;
  late LiquidSpring _press;
  late LiquidSpring _drift;

  /// 指示器的显隐（0 = 完全隐藏，1 = 完全显示）。
  ///
  /// [selectedIndex] 为 -1 表示「当前页面不属于底栏任何一个 tab」（设置页 / 全局
  /// 搜索页 / 各类壳内页面）。此时必须把胶囊整体淡出：只把位置停在原处会让它变成
  /// 一块没有文字的「幽灵阴影」，看起来像是某个 tab 仍然选中。
  late LiquidSpring _presence;

  late final Ticker _ticker = createTicker(_onTick);
  Duration? _lastTick;
  bool _pointerDown = false;
  double _dragStartValue = 0;
  double _dragDx = 0;
  double _tabWidth = 1;

  @override
  void initState() {
    super.initState();
    final maxIndex = math.max(0, widget.itemCount - 1);
    _position = LiquidSpring(
      stiffness: 1000,
      dampingRatio: 1,
      initial: widget.selectedIndex.clamp(0, maxIndex).toDouble(),
    );
    _press = LiquidSpring(stiffness: 1000, dampingRatio: 1, initial: 0);
    _drift = LiquidSpring(stiffness: 300, dampingRatio: 0.5, initial: 0);
    _presence = LiquidSpring(
      stiffness: 700,
      dampingRatio: 1,
      initial: widget.selectedIndex >= 0 ? 1 : 0,
    );
  }

  @override
  void didUpdateWidget(covariant LiquidBottomBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    final hasSelection = widget.selectedIndex >= 0;
    if (widget.itemCount != oldWidget.itemCount) {
      final maxIndex = math.max(0, widget.itemCount - 1);
      _position.snapTo(widget.selectedIndex.clamp(0, maxIndex).toDouble());
      _presence.snapTo(hasSelection ? 1 : 0);
    } else if (widget.selectedIndex != oldWidget.selectedIndex) {
      if (hasSelection) {
        // 从「无选中」回到某个 tab：先把位置直接对准目标再淡入，
        // 否则会从上一个页面停留的旧位置滑过来，看着像走错门。
        if (_presence.value < 0.01) {
          _position.snapTo(widget.selectedIndex.toDouble());
        } else {
          _position.animateTo(widget.selectedIndex.toDouble());
        }
      }
      // 无选中时就地淡出，位置保持不变 —— 下次回到同一 tab 时不必再滑动。
      _presence.animateTo(hasSelection ? 1 : 0);
      _ensureTicking();
    }
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  void _ensureTicking() {
    if (!_ticker.isActive) {
      _lastTick = null;
      _ticker.start();
    }
  }

  void _onTick(Duration elapsed) {
    final last = _lastTick;
    _lastTick = elapsed;
    // 首帧没有上一帧时间戳；同时把 dt 夹到 50ms 以内，避免掉帧时弹簧直接跳过头。
    final dt = last == null
        ? 1 / 60
        : ((elapsed - last).inMicroseconds / 1000000).clamp(0.0, 0.05);

    var busy = false;
    busy = _position.step(dt) || busy;
    busy = _press.step(dt) || busy;
    busy = _drift.step(dt) || busy;
    busy = _presence.step(dt) || busy;

    setState(() {});

    if (!busy && !_pointerDown) {
      _ticker.stop();
      _lastTick = null;
    }
  }

  void _handleTap(int index) {
    _position.animateTo(index.toDouble());
    _ensureTicking();
    widget.onSelect(index);
  }

  void _handlePointerDown(PointerDownEvent event) {
    _pointerDown = true;
    _press.animateTo(1);
    _ensureTicking();
  }

  void _handlePointerUp(PointerEvent event) {
    _pointerDown = false;
    _press.animateTo(0);
    _ensureTicking();
  }

  void _handleDragStart(DragStartDetails details) {
    _dragStartValue = _position.value;
    _dragDx = 0;
  }

  void _handleDragUpdate(DragUpdateDetails details) {
    _dragDx += details.delta.dx;
    final maxIndex = (widget.itemCount - 1).toDouble();
    final target = (_dragStartValue + _dragDx / _tabWidth).clamp(0.0, maxIndex);
    // 每一帧都重新指定目标 ⇒ 指示器带弹簧阻尼地「追」手指，跟手但不硬贴。
    _position.animateTo(target);
    _drift.snapTo(_dragDx);
    _ensureTicking();
  }

  void _handleDragEnd(DragEndDetails details) {
    final maxIndex = widget.itemCount - 1;
    final index = _position.value.round().clamp(0, maxIndex);
    _position.animateTo(index.toDouble());
    _drift.animateTo(0);
    _ensureTicking();
    if (index != widget.selectedIndex) widget.onSelect(index);
  }

  void _handleDragCancel() {
    final maxIndex = widget.itemCount - 1;
    final index = _position.value.round().clamp(0, maxIndex);
    _position.animateTo(index.toDouble());
    _drift.animateTo(0);
    _ensureTicking();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final height = widget.height;
        final inner = height - kLiquidInset * 2;
        // 上游：(maxWidth - 左右各 4dp) / tabsCount。
        _tabWidth = math.max(
          1,
          (width - kLiquidInset * 2) / widget.itemCount,
        );

        // 整条胶囊的视差位移：dx 先归一化到 ±1，再过 EaseOut 映射到 ±4dp。
        final fraction = (_drift.value / (_tabWidth * 0.75)).clamp(-1.0, 1.0);
        final eased =
            fraction.sign * Curves.easeOutCubic.transform(fraction.abs());
        final panelOffset = kLiquidEdgeDrift * eased;
        // 顶角形状：attachedTop = 与上方操作栏拼成整块（顶角方角），否则独立悬浮
        // （四角都是胶囊圆角）。用 TweenAnimationBuilder 而非直接取布尔值 ——
        // 操作栏会随列表滚动折叠 / 展开，形状若一步切换，顶角会「啪」地跳一下。
        const fade = Duration(milliseconds: 200);
        return TweenAnimationBuilder<double>(
          tween: Tween<double>(begin: 0, end: widget.attachedTop ? 1 : 0),
          duration: fade,
          curve: Curves.easeOutCubic,
          builder: (context, attached, _) {
            final radius = height / 2;
            final shape = BorderRadius.vertical(
              // attached 0 → 圆角；1 → 顶角收成直角，与操作栏无缝相接。
              top: Radius.circular(radius * (1 - attached)),
              bottom: Radius.circular(radius),
            );

            return Listener(
              onPointerDown: _handlePointerDown,
              onPointerUp: _handlePointerUp,
              onPointerCancel: _handlePointerUp,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onHorizontalDragStart: _handleDragStart,
                onHorizontalDragUpdate: _handleDragUpdate,
                onHorizontalDragEnd: _handleDragEnd,
                onHorizontalDragCancel: _handleDragCancel,
                child: SizedBox(
                  height: height,
                  child: Transform.translate(
                    // 与操作栏拼接时把视差收掉（×1-attached）：两块上下紧贴，
                    // 底栏若还横向漂移几 dp，边缘就会与操作栏错开，露出半截描边。
                    offset: Offset(panelOffset * (1 - attached), 0),
                    // 整体按胶囊形状裁切：指示器按压时会被放大到 1.39 倍、高于内容行，
                    // 不裁切会在胶囊外露出一圈淡色「光晕」。裁掉后观感是「鼓到贴边」。
                    child: ClipRRect(
                      borderRadius: shape,
                      child: Stack(
                        children: [
                          // 不要在这层套 RepaintBoundary：BackdropFilter 需要拿到祖先
                          // 合成层里的真实背景，多插一层可能采不到而退化成「只有半透明底、没有模糊」。
                          Positioned.fill(
                            child: _buildGlassContainer(shape, attached),
                          ),
                          Positioned.fill(child: _buildIndicator(inner)),
                          Positioned.fill(
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: kLiquidInset,
                              ),
                              child: _buildItems(),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }

  /// 玻璃底板：与浏览页操作栏共用 [LiquidGlassPanel]。
  ///
  /// [LiquidBottomBar.showGlassPlate] 为 false 时改走 [_buildCapsuleOutline]
  /// （实底胶囊，无模糊无高光）；为 true 时是完整玻璃面板。
  ///
  /// 抽成公共组件的直接原因：这两条栏在浏览页上下紧贴、左右等宽，是**一个整体**。
  /// 只要两边各写一份配色，接缝处就会出现色差（曾出现操作栏 `getAmoledSurface`
  /// 的黑 + 底栏半透明玻璃的黑叠在一起，看起来像「一块底板 + 一块胶囊」）。
  ///
  /// `attached`（0..1）控制顶边描边与顶部高光：与操作栏拼接时接缝处不该有第二条
  /// 描边（两条 0.6px 会合成约 1.2px 亮线），整块面板也只该在操作栏顶部受一次光。
  Widget _buildGlassContainer(BorderRadius shape, double attached) {
    if (!widget.showGlassPlate) return _buildCapsuleOutline(shape, attached);
    return LiquidGlassPanel(
      borderRadius: shape,
      topBorderOpacity: 1 - attached,
      highlightOpacity: 1 - attached,
      surfaceOpacity: widget.opacity,
    );
  }

  /// 胶囊底色 + 描边（**无模糊、无顶部高光**），配方见 [LiquidBarSurface]。
  ///
  /// 与浏览页操作栏共用同一个组件，拼成「底部控制台」时两段底色逐位相同；
  /// 拼接态（[attached] → 1）收掉顶边描边，避免接缝处合成亮线。
  Widget _buildCapsuleOutline(BorderRadius shape, double attached) {
    return LiquidBarSurface(
      borderRadius: shape,
      topBorderOpacity: 1 - attached,
      // issue #42：不透明度调节必须落在用户实际看到的那块底板上 ——
      // 首页 4-tab 走 showGlassPlate:false，看的正是这里。
      opacity: widget.opacity,
    );
  }

  /// 唯一的滑动胶囊指示器。液态观感全部来自这里的三个量：位置 / 鼓包 / 速度变形。
  Widget _buildIndicator(double inner) {
    final presence = _presence.value.clamp(0.0, 1.0);
    // 无选中：整块不画（不留任何阴影）。门槛取 0.001 是为了让弹簧收尾那一帧彻底消失。
    if (presence <= 0.001) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    final maxIndex = (widget.itemCount - 1).toDouble();
    final position = _position.value.clamp(0.0, maxIndex);
    final press = _press.value.clamp(0.0, 1.5);

    // 速度归一化：上游除以 (端点数-1) 再把「每 10 单位」当作 1 ⇒ 除以 10。
    final span = math.max(1, widget.itemCount - 1);
    final v = (_position.velocity / span) / 10;

    // 基础放大（按压鼓包）；两轴弹簧系数不同，X 略过冲，肉眼即为「弹性」。
    final base = 1 + (kLiquidPressScale - 1) * press;
    // 快速移动时横向拉长、纵向压扁；反向移动则相反。
    final scaleX = base / (1 - (v * 0.75).clamp(-0.2, 0.2));
    final scaleY = base * (1 - (v * 0.25).clamp(-0.2, 0.2));
    // 淡入 / 淡出时轻微缩放：出现时像「充气」，退出时像「泄气」，比纯透明度更贴合液态。
    final appear = 0.88 + 0.12 * presence;

    final left = kLiquidInset + position * _tabWidth;
    return Stack(
      children: [
        Positioned(
          left: left,
          top: kLiquidInset,
          width: _tabWidth,
          height: inner,
          child: Opacity(
            opacity: presence,
            child: Transform.scale(
              scaleX: scaleX * appear,
              scaleY: scaleY * appear,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  // 中性玻璃，不是主色：主色只出现在图标 / 文字上。
                  color: scheme.onSurface.withValues(alpha: 0.10),
                  borderRadius: BorderRadius.circular(inner / 2),
                  border: Border.all(
                    color: scheme.onSurface.withValues(alpha: 0.06),
                    width: 0.5,
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildItems() {
    final press = _press.value.clamp(0.0, 1.5);
    final scale = 1 + (kLiquidIconPressScale - 1) * press;
    return Transform.scale(
      scale: scale,
      child: Row(
        children: [
          for (var i = 0; i < widget.itemCount; i++)
            Expanded(
              child: Semantics(
                button: true,
                selected: i == widget.selectedIndex,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => _handleTap(i),
                  onLongPress: widget.onLongPressItem == null
                      ? null
                      : () => widget.onLongPressItem!(i),
                  child: Center(
                    child: widget.itemBuilder(
                      context,
                      i,
                      i == widget.selectedIndex,
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
