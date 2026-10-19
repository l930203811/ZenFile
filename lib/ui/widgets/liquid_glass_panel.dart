import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../core/theme.dart';

/// ── 液态玻璃面板 ──────────────────────────────────────────────────────
///
/// 玻璃层的**唯一实现**：底栏（`liquid_bottom_bar.dart`）与浏览页操作栏
/// （`directory_screen.dart` 的 `_buildBrowseActionBar`）都走这里。
///
/// 抽出来的动机很具体：这两条栏在浏览页是**上下紧贴、左右等宽**的一个整体，
/// 若各自维护一份配色，只要有一处调整（比如操作栏用 `getAmoledSurface`、
/// 底栏用半透明玻璃）就会在接缝处露出一条色差，看起来像「一块底板 + 一块胶囊」。
/// 共用同一套参数后，两者的底色、模糊、描边、顶部高光天然一致。
///
/// 与上游 Kyant0/AndroidLiquidGlass 的对应关系：上游 `#FAFAFA@40%` / `#121212@40%`
/// 的半透明底 + 8dp 模糊 + 细描边，这里用 Flutter 的
/// `ClipRRect + BackdropFilter + DecoratedBox` 近似；上游的 lens 折射、
/// chromatic aberration 依赖 RuntimeShader，Flutter 无等价实现，刻意不做。
///
/// 浅色模式的底色不照搬上游的纯白：改用 `AppTheme.lightBarBackground`
/// （主题色 12% 混白，与顶部栏逐位相同），页面则用更淡的
/// `AppTheme.lightPageBackground`（4%）—— 栏位深一档、页面浅一档，
/// 三者都跟随主题色但层次分明。深色模式维持黑雾方案，**不受影响**。

/// 玻璃层的背景模糊半径（dp）。
const double kLiquidGlassBlurSigma = 8;

/// 玻璃层描边宽度（逻辑像素）。0.6 在 3x 屏上约 2 物理像素，比 1.0 轻。
const double kLiquidGlassBorderWidth = 0.6;

class LiquidGlassPanel extends StatelessWidget {
  const LiquidGlassPanel({
    super.key,
    required this.borderRadius,
    this.child,
    this.topBorderOpacity = 1,
    this.bottomBorderOpacity = 1,
    this.highlightOpacity = 1,
    this.blurSigma = kLiquidGlassBlurSigma,
  });

  /// 面板外形。底栏用胶囊 / 上圆下方，操作栏用「只圆上角」。
  final BorderRadius borderRadius;

  /// 面板内容。省略时面板本身填满由父级给出的约束（用作纯背景层）。
  final Widget? child;

  /// 上 / 下描边的可见度（0 = 不画）。
  ///
  /// 两块面板拼接时必须把**接缝那一侧**收掉：两条 0.6px 的描边相邻会合成一条
  /// 约 1.2px 的亮线，在一体化的底部控制台上看起来就是一道裂缝。
  final double topBorderOpacity;
  final double bottomBorderOpacity;

  /// 顶部微高光的可见度（0 = 不画）。同样是拼接侧要收掉 —— 一整块面板只该有
  /// 一次受光，不该在中间再亮一次。
  ///
  /// **只影响面板最上面 16% 的亮度**：面板主体的亮度由常驻薄雾 `_sheen`
  /// 决定，与本参数无关。这一点是硬约束 —— 一旦主体亮度也跟着它变，拼接态
  /// （4-tab 传 0）就会整块暗下去，与其他 tab 页差一整档。
  final double highlightOpacity;

  final double blurSigma;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isDark = scheme.brightness == Brightness.dark;

    BorderSide side(double opacity) {
      if (opacity <= 0.001) return BorderSide.none;
      return BorderSide(
        color: scheme.onSurface.withValues(alpha: 0.08 * opacity),
        width: kLiquidGlassBorderWidth,
      );
    }

    // ⚠️ 底色与受光**必须分成两个 DecoratedBox**，不能塞进同一个 BoxDecoration。
    //
    // 依据 flutter/painting/box_decoration.dart 的 `_getBackgroundPaint`（407-422 行）：
    // 只要 `gradient != null`，paint 就会被赋予 shader，而 shader 会**整体取代**
    // `paint.color` —— 同装饰里同时给 color 和 gradient，底色根本不会被画出来，
    // 只有渐变层生效。曾在这里踩过：浅色高光渐变中段是 white@0 ⇒ 整块面板几乎全透明，
    // 4-tab 直接透出页面色（实测有效不透明度仅 1.2%），表现为「底栏和页面浑融为一体」。
    return ClipRRect(
      borderRadius: borderRadius,
      child: BackdropFilter(
        filter: ui.ImageFilter.blur(
          sigmaX: blurSigma,
          sigmaY: blurSigma,
          tileMode: TileMode.mirror,
        ),
        // ① 底色层：**不带 gradient**，唯一决定面板主体的颜色与描边。
        child: DecoratedBox(
          decoration: BoxDecoration(
            // 浅色不用纯白：跟随主题的「栏位」底色 —— 与顶部栏逐位相同
            // （AppTheme.lightBarBackground）。此前是 white@58% 叠在近白的页面
            // 上，结果就是一块纯白：既不跟随主题色，也比页面更亮，顶栏 / 页面 /
            // 底栏三条带子的层次全糊在一起。
            // 深色维持黑雾（叠在深灰页面上得到略暗的玻璃）。
            color: isDark
                ? Colors.black.withValues(alpha: 0.42)
                : AppTheme.lightBarBackground(scheme).withValues(alpha: 0.9),
            borderRadius: borderRadius,
            border: Border(
              top: side(topBorderOpacity),
              bottom: side(bottomBorderOpacity),
              left: side(1),
              right: side(1),
            ),
          ),
          // ② 受光层：只有渐变，叠在底色之上。两个成分分开调——
          //    · 薄雾 sheen：**常驻**、覆盖整个面板，决定「面板主体比页面亮一档」；
          //    · 顶部高光 glow：只作用于面板最上面 16%，纯粹是受光感，拼接态可整条关掉。
          // 关掉高光只影响顶部那 16%，主体亮度两态严格相同（曾把两者合成一条全高
          // 渐变，接缝处整条关掉后连主体亮度一起被抽走，浏览页 4-tab 比页面还暗）。
          //
          // 浅色模式薄雾为 0：栏位本身已是「主题色混白」，比页面（更淡的同色系）
          // 深一档，层次已经出来了；再叠白只会把主题色洗淡，又糊成一片白。
          child: DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: borderRadius,
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                stops: const [0, 0.16, 1],
                colors: [
                  Colors.white.withValues(
                    alpha: _sheen(isDark) + _glow(isDark) * highlightOpacity,
                  ),
                  Colors.white.withValues(alpha: _sheen(isDark)),
                  Colors.white.withValues(alpha: _sheen(isDark)),
                ],
              ),
            ),
            child: child ?? const SizedBox.expand(),
          ),
        ),
      ),
    );
  }

  /// 面板主体的常驻薄雾：拼接态与独立态**必须**共用同一个值，
  /// 否则两块面板（或同一面板的两种形态）会出现一整档色差。
  /// 深色取 0.06：black@42% 叠 #101318 得 ≈#090B0E，再叠 0.06 白 ≈#181A1C ——
  /// 比页面略亮一档，正是分类页那块「浮起来的玻璃」的观感。
  /// 浅色取 0：主题色混白本身就是更深的一档，见 [build] 里 color 的注释。
  static double _sheen(bool isDark) => isDark ? 0.06 : 0.0;

  /// 顶部受光强度：只叠在面板最上面 16% 的高度里，不影响主体亮度。
  static double _glow(bool isDark) => isDark ? 0.04 : 0.16;
}
