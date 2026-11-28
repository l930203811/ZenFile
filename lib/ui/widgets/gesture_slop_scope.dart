import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

/// 全局手势 slop 覆盖：把触控容差放宽到 [GestureSlopScope.minTouchSlop]。
///
/// ## 为什么需要它（2026-11-28 第十一轮，关键修复）
///
/// `GestureDetector` / `InkWell` 会把 `MediaQuery.gestureSettings` 灌进它们创建的
/// **每一个**手势识别器，而 `LongPressGestureRecognizer` 的
/// `preAcceptSlopTolerance` 默认就取这个值。
///
/// **含义：长按死线（500ms）到达之前，手指累计移动一旦超过 slop，
/// 识别器就被直接 reject ⇒ 长按永远不触发。**
///
/// 平台上报的 slop 在 Android 上通常是 `ViewConfiguration.getScaledTouchSlop()`
/// 换算过来的 **8 逻辑像素**（比 Flutter 兜底的 `kTouchSlop`=18 还小）。
/// 在华为畅享 e20 这类低端机上，用户「按住」时手指几乎不可能纹丝不动，
/// 于是**所有支持长按的按钮长按全灭**（用户实测反馈），
/// 而普通点击完全正常（点击不靠定时器，抬起即触发）。
///
/// ## 放宽到多少
///
/// 24 逻辑像素：在 360dp 宽的屏上约 6.7%，约等于「按住时手指自然的抖动」。
///
/// * 长按不再因为轻微抖动被否决；
/// * 点击的「抬起前位移容差」同样变宽 ⇒ 顺带减少「点了没反应」；
/// * 代价：滚动/拖拽的启动阈值从 ~8dp 增到 24dp。低端机上本来也容易把
///   点击误判成滚动，这个代价值得。
///
/// ## ⚠️ 为什么必须挂在 `MaterialApp.builder` 里
///
/// `MediaQuery.fromView` 是在 `View` 那一层创建的（**高于整棵 App 树**），
/// 所以只有挂在 `MaterialApp.builder`（App 树之内、Navigator 之外）才能对
/// **全 App** 生效；放在 App 内部任何页面里都覆盖不到其它页面。
class GestureSlopScope extends StatefulWidget {
  const GestureSlopScope({super.key, required this.child});

  final Widget child;

  /// 触控容差下限（逻辑像素）。
  static const double minTouchSlop = 24.0;

  @override
  State<GestureSlopScope> createState() => _GestureSlopScopeState();
}

class _GestureSlopScopeState extends State<GestureSlopScope> {
  @override
  Widget build(BuildContext context) {
    // 只订阅 gestureSettings：键盘 Insets 变化不会重建本组件。
    final DeviceGestureSettings? gs =
        MediaQuery.maybeGestureSettingsOf(context);
    final double platformSlop = gs?.touchSlop ?? kTouchSlop;
    if (platformSlop >= GestureSlopScope.minTouchSlop) {
      // 平台值已经够宽 → 保持平台原值，不额外套一层 MediaQuery。
      return widget.child;
    }
    // ⚠️ **必须每次从父级派生**，不能缓存整份 MediaQueryData。
    //
    // `MediaQueryData` 里除了 gestureSettings，还有键盘 insets / 屏幕尺寸 /
    // 文字缩放等。缓存整份 ⇒ 键盘弹出时后代拿到的还是**旧的 padding**
    // ⇒ 输入框不再避让键盘（正好是用户反馈的软键盘问题之一）。
    //
    // 这里每次都从父级 `copyWith` 出一份新的：新的实例身份会让后代重建，
    // 但这与父级 MediaQuery 通知后代的路径**只有一条**
    // （父 → 本组件 → 后代），后代不会因此多重建一次。
    final MediaQueryData data = MediaQuery.of(context).copyWith(
      gestureSettings: const DeviceGestureSettings(
        touchSlop: GestureSlopScope.minTouchSlop,
      ),
    );
    return MediaQuery(data: data, child: widget.child);
  }
}
