import 'dart:ui' as ui;

import 'package:flutter/material.dart';

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

    return ClipRRect(
      borderRadius: borderRadius,
      child: BackdropFilter(
        filter: ui.ImageFilter.blur(
          sigmaX: blurSigma,
          sigmaY: blurSigma,
          tileMode: TileMode.mirror,
        ),
        child: DecoratedBox(
          decoration: BoxDecoration(
            // 浅色压到近白、深色压到近黑 —— 对应上游 #FAFAFA@40% / #121212@40%。
            // 两块面板底下铺的都是 `theme.scaffoldBackgroundColor`（浏览页内部
            // Scaffold 与外层 Scaffold 同源），所以叠出来的结果严格一致：
            // 深色未开 AMOLED 时略深于背景，开了 AMOLED 时与纯黑背景融为一体。
            color: (isDark ? Colors.black : Colors.white).withValues(
              alpha: isDark ? 0.42 : 0.58,
            ),
            borderRadius: borderRadius,
            border: Border(
              top: side(topBorderOpacity),
              bottom: side(bottomBorderOpacity),
              left: side(1),
              right: side(1),
            ),
            gradient: highlightOpacity <= 0.001
                ? null
                : LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Colors.white.withValues(
                        alpha: (isDark ? 0.06 : 0.28) * highlightOpacity,
                      ),
                      Colors.white.withValues(alpha: 0),
                    ],
                  ),
          ),
          child: child ?? const SizedBox.expand(),
        ),
      ),
    );
  }
}
