import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';

/// ── 液态按压反馈（Liquid Pressable）────────────────────────────────────
///
/// 与 `LiquidBottomBar` 同源的物理参数：按下时用弹簧把内容轻微放大（鼓包），
/// 松开时回弹；选中状态从 false 变 true 时额外播一次「弹起」。
///
/// 刻意用 [Listener] 而不是 [GestureDetector]：Listener 不参与手势竞技场，
/// 只是旁听指针事件，因此不会和子级已有的 InkWell / Draggable / 横向滚动抢手势 ——
/// 这是把它套在面包屑（同时支持点按、长按拖放、横向滚动）上的前提。
///
/// 视觉样式**不做任何修改**，只加缩放，因此可直接套在既有按钮外层使用。
class LiquidPressable extends StatefulWidget {
  const LiquidPressable({
    super.key,
    required this.child,
    this.pressScale = 1.06,
    this.popScale = 1.09,
    this.selected = false,
  });

  final Widget child;

  /// 按住时的放大倍数。小控件（面包屑 / 标签页）取 1.05~1.08，
  /// 再大就会和相邻元素挤在一起。
  final double pressScale;

  /// 选中时的「弹起」峰值倍数。
  final double popScale;

  /// 是否处于选中态。从 false 翻到 true 时播一次弹起动画。
  final bool selected;

  @override
  State<LiquidPressable> createState() => _LiquidPressableState();
}

class _LiquidPressableState extends State<LiquidPressable>
    with TickerProviderStateMixin {
  /// 0..1 的按压进度（弹簧驱动，会轻微过冲）。
  late final AnimationController _press = AnimationController.unbounded(
    vsync: this,
    value: 0,
  );

  /// 0..1 的弹起进度（一次性播放）。
  late final AnimationController _pop = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 260),
  );

  /// 弹起曲线：先快速冲到峰值，再用更长的时间回落 —— 峰值尖锐、收尾柔和，
  /// 与底栏「压下去弹回来」的手感一致。
  late final Animation<double> _popValue = TweenSequence<double>([
    TweenSequenceItem(
      tween: Tween<double>(
        begin: 0,
        end: 1,
      ).chain(CurveTween(curve: Curves.easeOutCubic)),
      weight: 35,
    ),
    TweenSequenceItem(
      tween: Tween<double>(
        begin: 1,
        end: 0,
      ).chain(CurveTween(curve: Curves.easeInOutCubic)),
      weight: 65,
    ),
  ]).animate(_pop);

  /// 指针按下位置与是否已因「移动过多」取消按压（滚动列表时不要一直鼓着）。
  Offset? _downAt;
  bool _cancelled = false;

  static SpringDescription get _pressSpring => SpringDescription(
    mass: 1,
    stiffness: 1400,
    // dampingRatio ≈ 0.78：按下瞬间略微过冲，松手回弹一次即停。
    damping: 2 * 0.78 * math.sqrt(1400),
  );

  @override
  void didUpdateWidget(covariant LiquidPressable oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!oldWidget.selected && widget.selected) {
      _pop.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _press.dispose();
    _pop.dispose();
    super.dispose();
  }

  void _animatePress(double target) {
    _press.animateWith(
      SpringSimulation(_pressSpring, _press.value, target, _press.velocity),
    );
  }

  void _onDown(PointerDownEvent event) {
    _downAt = event.position;
    _cancelled = false;
    _animatePress(1);
  }

  void _onMove(PointerMoveEvent event) {
    final start = _downAt;
    if (start == null || _cancelled) return;
    // 超过 12dp 视为滑动（滚动 / 拖拽），取消按压，避免整排在滚动时被放大。
    if ((event.position - start).distance > 12) {
      _cancelled = true;
      _animatePress(0);
    }
  }

  void _onUp(PointerEvent event) {
    _downAt = null;
    _animatePress(0);
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerDown: _onDown,
      onPointerMove: _onMove,
      onPointerUp: _onUp,
      onPointerCancel: _onUp,
      child: AnimatedBuilder(
        animation: Listenable.merge([_press, _popValue]),
        builder: (context, child) {
          final press = _press.value.clamp(0.0, 1.3);
          final pop = _popValue.value.clamp(0.0, 1.0);
          final scale =
              1 + (widget.pressScale - 1) * press + (widget.popScale - 1) * pop;
          return Transform.scale(scale: scale, child: child);
        },
        child: widget.child,
      ),
    );
  }
}
