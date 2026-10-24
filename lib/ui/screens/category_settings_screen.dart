import 'package:flutter/material.dart';

import '../../core/icon_fonts/broken_icons.dart';
import '../widgets/persistent_nav_bar_scope.dart';
import '../widgets/quick_categories_grid.dart';
import 'package:zenfile/l10n/generated/app_localizations.dart';
import 'more_settings_screen.dart';

/// 「分类页设置」子页面：只收纳作用于主屏幕（分类页）的设置项。
///
/// 纯 UI 重组（自原主列表 /「常规与行为」分流而来）：本页不持有任何新状态，
/// 入口直接打开「自定义快捷方式」对话框，背后仍是同一份 provider / 偏好存储。
/// （原 selectionActionBarList 的「导航栏设置」入口与「隐藏操作栏文字」开关
/// 分别上移为顶层「导航栏与底栏」入口与 NavBarSettingsSheet 面板项，见
/// more_settings_screen.dart 主列表与 nav_bar_settings_sheet.dart。）
class CategorySettingsScreen extends StatelessWidget {
  const CategorySettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    // 「导航栏常驻其他页面」：开启时本页（全屏路由）也显示与首页同款的底部
    // 4-tab —— 点击经 HomeScreen.pendingTabSwitch 回首页并切换到对应 tab；
    // 开关关闭时原样返回本页，行为与接入前一致。
    return PersistentNavBarScope(
      child: Scaffold(
      appBar: AppBar(
        title: Text(L10n.of(context).ui_settings_category_page),
        leading: IconButton(
          icon: const Icon(Broken.arrow_left),
          onPressed: () => Navigator.pop(context),
        ),
      ),
      body: SafeArea(
        child: ListView(
          physics: const BouncingScrollPhysics(),
          padding: EdgeInsets.only(top: 16, left: 16, right: 16, bottom: MediaQuery.paddingOf(context).bottom + 16),
          children: [
            // 主屏幕自定义：重排 / 显隐分类页快捷分类卡片（原 homeScreenList 全部项）。
            SettingsTile(
              icon: Broken.setting_2,
              title: L10n.of(context).msge7d18d73,
              subtitle: L10n.of(context).msg036fe6a4,
              onTap: () => QuickCategoriesGrid.showCustomizeDialog(context),
            ),
          ],
        ),
      ),
      ),
    );
  }
}
