import 'package:flutter/material.dart';

/// ── 常驻页面的窗口指标冻结层 ────────────────────────────────────────────
///
/// 修「软键盘弹出 / 收起像幻灯片一样逐帧卡」。
///
/// 根因链条（可在 flutter/material/scaffold.dart 里逐行对上）：
///
///  1. 软键盘 Insets 动画期间，系统**逐帧**下发新的 IME inset；Flutter 侧就
///     表现为 `MediaQueryData.viewInsets.bottom` 每帧变化。
///  2. `ScaffoldState.build` 里：
///     ```dart
///     final EdgeInsets minInsets = MediaQuery.paddingOf(context).copyWith(
///       bottom: _resizeToAvoidBottomInset ? MediaQuery.viewInsetsOf(context).bottom : 0.0);
///     ```
///     而 `_resizeToAvoidBottomInset => widget.resizeToAvoidBottomInset ?? true`
///     —— **默认就是 true**。
///  3. `_ScaffoldLayout.shouldRelayout` 比较的第一项就是
///     `oldDelegate.minInsets != minInsets` ⇒ 每帧为 true ⇒ 整个 Scaffold
///     连同 body 子树**每帧全量重排**。
///
/// 首页用 `IndexedStack` 同时保活 4 个 tab，`RenderStack` 会**布局全部子页**；
/// 其中浏览页（大文件列表）、设置页（75 张卡片）、分类网格都是重排大头，而
/// `RenderParagraph` 在约束变化时会重做文本排版 —— 于是每帧几十毫秒，键盘
/// 动画就被拉成一秒左右的「幻灯片」。
///
/// ⚠️ 只把 `resizeToAvoidBottomInset` 关掉**并不够**：`MediaQueryData.padding`
/// 自身也会被 viewInsets 吸收（`padding = viewPadding - viewInsets`），键盘
/// 动画期间 `padding.bottom` 同样逐帧变化，`minInsets` 依旧不稳定。
///
/// 因此这里直接给常驻页面树喂一份「不含键盘成分」的 `MediaQueryData`：
/// `viewInsets` 清零、`padding` 固定取 `viewPadding`（即无键盘时的安全区）。
/// 常驻树的布局从此与键盘状态**完全无关**，动画期间一帧都不用重排 / 重建。
///
/// 刷新时机：只在窗口几何真的变化时（旋转 / 分屏 / 系统栏显隐 ⇒ `size` 或
/// `viewPadding` 变化）才更新冻结值，键盘 insets 不触发刷新。
///
/// 弹窗为什么不受影响：`showDialog` 默认 `useRootNavigator: true`，挂在
/// **根** Navigator 上；本层位于 HomeScreen（根 Navigator 里的一个 route）
/// 内部，是弹窗的**下层**。弹窗自带的 `AnimatedPadding` 读的是根
/// `MediaQuery`（`WidgetsApp` 建的那份），viewInsets 照常逐帧更新 ⇒ 弹窗
/// 依旧平滑上移，交互不受影响。
class ShellMetricsStable extends StatefulWidget {
  const ShellMetricsStable({super.key, required this.child});

  final Widget child;

  @override
  State<ShellMetricsStable> createState() => _ShellMetricsStableState();
}

class _ShellMetricsStableState extends State<ShellMetricsStable> {
  MediaQueryData? _frozen;

  /// 去掉键盘成分后的窗口指标：`viewInsets` 清零、`padding` 取 `viewPadding`。
  ///
  /// 两者都必须冻结（理由见类注释 ⚠️ 段）：只冻 viewInsets 的话，padding
  /// 仍会被键盘吸收而逐帧变化，`Scaffold` 的 `minInsets` 依旧不稳。
  static MediaQueryData _freeze(MediaQueryData d) =>
      d.copyWith(viewInsets: EdgeInsets.zero, padding: d.viewPadding);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // 这里刻意**整取** MediaQuery（订阅整份数据）：本层自身会跟着每帧重建，
    // 代价只是一个 MediaQuery 包装；而子树拿到的是冻结后的常量，不会再被
    // 键盘 insets 触发 —— 用一层廉价的重建，换掉整棵重树的每帧重排。
    final d = MediaQuery.of(context);
    final f = _frozen;
    if (f == null) {
      // 首帧：直接赋值即可，此时尚未进入 build，无需 setState。
      _frozen = _freeze(d);
    } else if (f.size != d.size || f.viewPadding != d.viewPadding) {
      // 旋转 / 分屏 / 系统栏显隐：按新的窗口几何刷新冻结值。
      setState(() => _frozen = _freeze(d));
    }
  }

  @override
  Widget build(BuildContext context) {
    final f = _frozen;
    // 首帧 _frozen 已在 didChangeDependencies 里赋值，这里只作兜底。
    return f == null ? widget.child : MediaQuery(data: f, child: widget.child);
  }
}
