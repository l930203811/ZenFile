import 'package:flutter/material.dart';

/// 给 [base] 文本主题整体套用本地字体族（Outfit / JetBrains Mono / Montserrat）。
///
/// 此前这三款字体经 google_fonts **运行时联网下载**，弱网首次启动会阻塞或
/// 闪烁；现改为 pubspec 声明的本地 assets（见 pubspec.yaml fonts 段），
/// 字重文件（400/500/600/700）已按需打包。
TextTheme _localFontTextTheme(TextTheme base, String fontFamily) {
  return base.copyWith(
    displayLarge: base.displayLarge?.copyWith(fontFamily: fontFamily),
    displayMedium: base.displayMedium?.copyWith(fontFamily: fontFamily),
    displaySmall: base.displaySmall?.copyWith(fontFamily: fontFamily),
    headlineLarge: base.headlineLarge?.copyWith(fontFamily: fontFamily),
    headlineMedium: base.headlineMedium?.copyWith(fontFamily: fontFamily),
    headlineSmall: base.headlineSmall?.copyWith(fontFamily: fontFamily),
    titleLarge: base.titleLarge?.copyWith(fontFamily: fontFamily),
    titleMedium: base.titleMedium?.copyWith(fontFamily: fontFamily),
    titleSmall: base.titleSmall?.copyWith(fontFamily: fontFamily),
    bodyLarge: base.bodyLarge?.copyWith(fontFamily: fontFamily),
    bodyMedium: base.bodyMedium?.copyWith(fontFamily: fontFamily),
    bodySmall: base.bodySmall?.copyWith(fontFamily: fontFamily),
    labelLarge: base.labelLarge?.copyWith(fontFamily: fontFamily),
    labelMedium: base.labelMedium?.copyWith(fontFamily: fontFamily),
    labelSmall: base.labelSmall?.copyWith(fontFamily: fontFamily),
  );
}

class AppTheme {
  static const Color seedColor = Color(0xFF369FE7);
  
  static ThemeData getAppTheme({
    required bool light,
    bool pitchBlack = false,
    Color? seed,
    ColorScheme? customScheme,
    String fontFamily = 'default',
  }) {
    final rawColor = seed ?? seedColor;
    final brightness = light ? Brightness.light : Brightness.dark;

    ColorScheme colorScheme;
    if (customScheme != null) {
      colorScheme = customScheme.copyWith(brightness: brightness);
    } else {
      final baseScheme = ColorScheme.fromSeed(
        seedColor: rawColor,
        brightness: brightness,
        contrastLevel: 0.05,
        dynamicSchemeVariant: DynamicSchemeVariant.fidelity,
      );
      colorScheme = baseScheme.copyWith(
        primary: rawColor,
      );
    }

    // AMOLED 纯黑模式：覆盖 surface 系列颜色为纯黑/近纯黑，
    // 使 NavigationBar、Drawer、Surface 等所有使用 colorScheme.surface 的组件真正变黑。
    if (pitchBlack && !light) {
      colorScheme = colorScheme.copyWith(
        surface: Colors.black,
        surfaceContainerLowest: Colors.black,
        surfaceContainerLow: const Color(0xFF080808),
        surfaceContainer: const Color(0xFF101010),
        surfaceContainerHigh: const Color(0xFF1A1A1A),
        surfaceContainerHighest: const Color(0xFF242424),
      );
    }

    final effectivePrimary = colorScheme.primary;
    final mainColorMultiplier = pitchBlack ? 0.1 : 0.8;
    final pitchGrey = pitchBlack ? const Color.fromARGB(255, 14, 14, 14) : const Color.fromARGB(255, 35, 35, 35);
    final pitchBlackColor = pitchBlack ? const Color.fromARGB(255, 0, 0, 0) : null;

    int getColorAlpha(int a) => (a * mainColorMultiplier).round();
    Color getMainColorWithAlpha(int a) => effectivePrimary.withAlpha(getColorAlpha(a));

    final cardColor = Color.alphaBlend(
      getMainColorWithAlpha(35),
      light ? const Color.fromARGB(255, 255, 255, 255) : pitchGrey,
    );

    // Map font keys to actual font families/themes
    TextTheme? textTheme;
    String? effectiveFontFamily;

    final baseTextTheme = ThemeData(brightness: brightness).textTheme;

    switch (fontFamily) {
      case 'nothing':
        effectiveFontFamily = 'NType82';
        textTheme = const TextTheme(
          displayLarge: TextStyle(fontFamily: 'Ndot57'),
          displayMedium: TextStyle(fontFamily: 'Ndot57'),
          displaySmall: TextStyle(fontFamily: 'Ndot57'),
          headlineLarge: TextStyle(fontFamily: 'Ndot57', fontWeight: FontWeight.bold),
          headlineMedium: TextStyle(fontFamily: 'Ndot57', fontWeight: FontWeight.bold),
          headlineSmall: TextStyle(fontFamily: 'Ndot57', fontWeight: FontWeight.bold),
          titleLarge: TextStyle(fontFamily: 'Ndot57', fontWeight: FontWeight.bold),
          titleMedium: TextStyle(fontFamily: 'Ndot57', fontWeight: FontWeight.bold),
          titleSmall: TextStyle(fontFamily: 'Ndot57', fontWeight: FontWeight.bold),
          bodyLarge: TextStyle(fontFamily: 'NType82'),
          bodyMedium: TextStyle(fontFamily: 'NType82'),
          bodySmall: TextStyle(fontFamily: 'NType82'),
          labelLarge: TextStyle(fontFamily: 'NType82', fontWeight: FontWeight.bold),
          labelMedium: TextStyle(fontFamily: 'NType82'),
          labelSmall: TextStyle(fontFamily: 'NType82'),
        );
        break;
      case 'outfit':
        effectiveFontFamily = 'Outfit';
        textTheme = _localFontTextTheme(baseTextTheme, 'Outfit');
        break;
      case 'jetbrains':
        effectiveFontFamily = 'JetBrains Mono';
        textTheme = _localFontTextTheme(baseTextTheme, 'JetBrains Mono');
        break;
      case 'montserrat':
        effectiveFontFamily = 'Montserrat';
        textTheme = _localFontTextTheme(baseTextTheme, 'Montserrat');
        break;
      case 'custom':
        effectiveFontFamily = 'CustomFont';
        break;
      case 'default':
      default:
        effectiveFontFamily = 'LexendDeca';
        break;
    }

    return ThemeData(
      brightness: brightness,
      useMaterial3: true,
      colorScheme: colorScheme,
      fontFamily: effectiveFontFamily,
      textTheme: textTheme,
      fontFamilyFallback: const ['sans-serif', 'Roboto'],
      scaffoldBackgroundColor: pitchBlackColor ?? (light ? lightPageBackground(colorScheme) : null),
      splashColor: Colors.transparent,
      highlightColor: light ? Colors.black.withAlpha(20) : Colors.white.withAlpha(pitchBlackColor == null ? 10 : 25),
      disabledColor: light ? const Color.fromARGB(200, 160, 160, 160) : const Color.fromARGB(200, 60, 60, 60),
      applyElevationOverlayColor: false,
      appBarTheme: AppBarTheme(
        elevation: 0,
        scrolledUnderElevation: 0,
        surfaceTintColor: Colors.transparent,
        backgroundColor: pitchBlackColor ?? (light ? lightBarBackground(colorScheme) : null),
        actionsIconTheme: IconThemeData(
          color: light ? const Color.fromARGB(200, 40, 40, 40) : const Color.fromARGB(200, 233, 233, 233),
        ),
        iconTheme: IconThemeData(
          color: light ? const Color.fromARGB(200, 40, 40, 40) : const Color.fromARGB(200, 233, 233, 233),
        ),
        titleTextStyle: TextStyle(
          color: light ? Colors.black.withAlpha(160) : Colors.white.withAlpha(210),
          fontSize: 20,
          fontWeight: FontWeight.w600,
          fontFamily: effectiveFontFamily,
        ),
      ),
      secondaryHeaderColor: light ? const Color.fromARGB(200, 240, 240, 240) : const Color.fromARGB(222, 10, 10, 10),
      iconTheme: IconThemeData(
        color: light ? const Color.fromARGB(200, 40, 40, 40) : const Color.fromARGB(200, 233, 233, 233),
      ),
      shadowColor: light ? const Color.fromARGB(180, 100, 100, 100) : const Color.fromARGB(222, 10, 10, 10),
      dividerTheme: const DividerThemeData(
        thickness: 4,
        indent: 0.0,
        endIndent: 0.0,
      ),
      cardColor: cardColor,
      cardTheme: CardThemeData(
        elevation: 12.0,
        color: Color.alphaBlend(
          getMainColorWithAlpha(45),
          light ? const Color.fromARGB(255, 255, 255, 255) : pitchGrey,
        ),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14.0 * 1.5),
        ),
      ),
      dialogTheme: DialogThemeData(
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24.0 * 1.5)),
        backgroundColor: light
            ? Color.alphaBlend(getMainColorWithAlpha(60), Colors.white)
            : Color.alphaBlend(getMainColorWithAlpha(20), pitchBlackColor ?? const Color.fromARGB(255, 12, 12, 12)),
      ),
      popupMenuTheme: PopupMenuThemeData(
        surfaceTintColor: Colors.transparent,
        elevation: 12.0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16.0 * 1.5),
        ),
        color: light ? Color.alphaBlend(cardColor.withAlpha(180), Colors.white) : Color.alphaBlend(cardColor.withAlpha(180), Colors.black),
      ),
    );
  }

  static ThemeData get lightTheme => getAppTheme(light: true);
  static ThemeData get darkTheme => getAppTheme(light: false);

  /// 浅色模式的「**栏位**」底色：顶部栏、底部 4-tab 导航、浏览页底部操作栏共用。
  ///
  /// 主题色 12% 混白。抽成公开方法是为了让玻璃层（`liquid_glass_panel.dart`）
  /// 能拿到**与顶部栏逐位相同**的颜色 —— 4-tab 此前用的是纯白，纯白叠纯白
  /// 既不跟随主题色，也比页面更亮，三条带子（顶栏 / 页面 / 底栏）的层次就糊了。
  ///
  /// 仅浅色模式有意义；深色 / AMOLED 走 `scaffoldBackgroundColor` 分支。
  static Color lightBarBackground(ColorScheme scheme) =>
      Color.alphaBlend(scheme.primary.withAlpha(30), Colors.white);

  /// 浅色模式的「**页面**」底色（scaffoldBackgroundColor）：主题色 4% 混白。
  ///
  /// 必须比 [lightBarBackground] **淡一档**：页面更浅、栏位更深，导航栏与顶栏
  /// 才能从页面里「浮」出来，而不是和页面浑融为一体（用户要求：分类页 / 浏览页
  /// 跟随主题色，但要浅一点）。
  static Color lightPageBackground(ColorScheme scheme) =>
      Color.alphaBlend(scheme.primary.withAlpha(10), Colors.white);

  /// 页面级 Scaffold 背景色（含 AMOLED 纯黑模式）。
  ///
  /// **不要再按 `brightness == dark` 自己返回纯黑**：AMOLED 是独立开关
  /// （`FileManagerProvider.amoledMode` → `getAppTheme(pitchBlack: ...)`），
  /// 只有开关打开时 `scaffoldBackgroundColor` 才是纯黑；关掉时深色主题的
  /// 背景是深灰。过去这里无条件返回纯黑，浏览页因此比分类 / 传输 / 设置页
  /// 更黑，两层 Scaffold 隔着底栏接缝露出一圈色差。
  /// 开关状态已经写进 theme，这里直接返回它 —— 内外层、任意页面同源。
  static Color getAmoledScaffoldBackground(ThemeData theme) =>
      theme.scaffoldBackgroundColor;

  /// AMOLED 纯黑模式下的卡片/容器背景（纯黑背景上的微层次）。
  static Color getAmoledSurface(ThemeData theme) {
    if (theme.brightness == Brightness.dark) {
      return const Color(0xFF0A0A0A);
    }
    return theme.colorScheme.surface;
  }
}
