import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/icon_fonts/broken_icons.dart';
import '../../providers/file_manager_provider.dart';
import 'package:zenfile/l10n/generated/app_localizations.dart';

/// 统一的「导航栏」设置面板：设置页与「自定义快捷方式」页共用同一份实现。
///
/// 两个入口天然双向同步 —— 它们只读写 [FileManagerProvider] 上同一对字段
/// （并各自落盘到 `PreferencesService`）：
///   * [FileManagerProvider.bottomNavBarEnabled] —— 显示 / 隐藏（原「显示导航栏」开关）
///   * [FileManagerProvider.showBottomActionBar] —— 位置：true=底部 / false=顶部
///     （字段名是历史遗留：它同时决定「4-tab 导航栏」与「工具按钮行」谁在上谁在下，
///     见 `home_screen.dart` 的 `_buildNavTopBar` / `_buildNavBottomBar`）
///
/// 面板内用 [Consumer] 订阅 provider，所以开关与位置会随外部改动实时刷新
/// （例如用户在自定义页改完再回到这里，打开就是最新值）。
class NavBarSettingsSheet {
  const NavBarSettingsSheet._();

  static Future<void> show(BuildContext context) {
    final theme = Theme.of(context);
    return showModalBottomSheet<void>(
      context: context,
      // 面板内容比默认上限（屏幕 9/16）略高，且德语/俄语等长文案 + 系统大字号下
      // 会更高，所以让它按内容自适应高度（内部再套一层滚动兜底）。
      isScrollControlled: true,
      backgroundColor: theme.scaffoldBackgroundColor,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (_) => const _NavBarSettingsSheetBody(),
    );
  }
}

class _NavBarSettingsSheetBody extends StatelessWidget {
  const _NavBarSettingsSheetBody();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = L10n.of(context);
    return SafeArea(
      child: SingleChildScrollView(
        child: Consumer<FileManagerProvider>(
          builder: (context, fileManager, _) {
            return Padding(
              padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Center(
                    child: Container(
                      width: 36,
                      height: 4,
                      decoration: BoxDecoration(
                        color: theme.colorScheme.onSurface.withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                  const SizedBox(height: 20),
                  // 标题 + 总开关同一行：标题即 [ui_bottom_tab_bar]（「导航栏」），
                  // 开关与「自定义快捷方式」页的开关是同一个状态。
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          l10n.ui_bottom_tab_bar,
                          style: const TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                            fontFamily: 'LexendDeca',
                          ),
                        ),
                      ),
                      Switch(
                        value: fileManager.bottomNavBarEnabled,
                        activeColor: theme.colorScheme.primary,
                        onChanged: (v) => fileManager.setBottomNavBarEnabled(v),
                      ),
                    ],
                  ),
                  Text(
                    l10n.msg309e2a28,
                    style: TextStyle(
                      fontSize: 13,
                      color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
                    ),
                  ),
                  const SizedBox(height: 12),
                  // 「导航栏常驻」：开启时从分类页 / 抽屉进入的页面也保留底部
                  // 4-tab（只占 body 区域）；关闭则恢复整页全屏。
                  // 与「自定义快捷方式」页里的同名开关共用同一份 provider 状态。
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          l10n.ui_persistent_tab_bar,
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color:
                                theme.colorScheme.onSurface.withValues(alpha: 0.75),
                          ),
                        ),
                      ),
                      Switch(
                        value: fileManager.persistentTabBar,
                        activeColor: theme.colorScheme.primary,
                        onChanged: (v) => fileManager.setPersistentTabBar(v),
                      ),
                    ],
                  ),
                  const SizedBox(height: 20),
                  Text(
                    l10n.ui_show_bottom_action_bar,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: theme.colorScheme.onSurface.withValues(alpha: 0.75),
                    ),
                  ),
                  const SizedBox(height: 8),
                  // 位置两选。刻意在「导航栏已隐藏」时**不禁用**：隐不隐藏与摆哪儿是
                  // 两件独立的事，允许先设好位置再打开开关，少一次来回。
                  _NavBarPositionTile(
                    icon: Broken.arrow_square_up,
                    title: l10n.msge34c23ff,
                    subtitle: l10n.msg3341e3ed,
                    selected: !fileManager.showBottomActionBar,
                    onTap: () => fileManager.setBottomActionBar(false),
                  ),
                  const SizedBox(height: 8),
                  _NavBarPositionTile(
                    icon: Broken.arrow_square_down,
                    title: l10n.msg8c414b06,
                    subtitle: l10n.msg5d2c8e7f,
                    selected: fileManager.showBottomActionBar,
                    onTap: () => fileManager.setBottomActionBar(true),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

/// 「导航栏位置」下拉选择器（顶部 | 底部），供「自定义快捷方式」页行内使用。
///
/// 样式刻意与同页「每行显示」等行**完全一致**（同样的圆角 8 容器 + 背景 +
/// 描边 + 下拉箭头），使整个设置列表的控件风格统一；此前用的是分段按钮，
/// 与相邻行的下拉框外观不一致。
///
/// 与 [NavBarSettingsSheet] 读写同一份 provider 状态，所以它、上面的「导航栏」
/// 开关、以及设置页那边的面板三者永远一致（双向同步）；这里用 `context.watch`
/// 订阅，切换后本控件自身就会刷新。
class NavBarPositionDropdown extends StatelessWidget {
  const NavBarPositionDropdown({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = L10n.of(context);
    final fileManager = context.watch<FileManagerProvider>();
    final isBottom = fileManager.showBottomActionBar;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceVariant.withValues(alpha: 0.3),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: theme.colorScheme.onSurface.withValues(alpha: 0.1),
        ),
      ),
      child: DropdownButton<bool>(
        value: isBottom,
        isDense: true,
        underline: const SizedBox(),
        icon: const Icon(Icons.arrow_drop_down),
        borderRadius: BorderRadius.circular(8),
        style: TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w600,
          color: theme.colorScheme.onSurface.withValues(alpha: 0.8),
        ),
        items: [
          DropdownMenuItem(
            value: false,
            child: Text(l10n.msge34c23ff),
          ),
          DropdownMenuItem(
            value: true,
            child: Text(l10n.msg8c414b06),
          ),
        ],
        onChanged: (val) {
          if (val != null) fileManager.setBottomActionBar(val);
        },
      ),
    );
  }
}

/// 位置选项卡片。样式与 `more_settings_screen.dart` 里的 `_buildSelectionTile`
/// 保持一致（那边是顶层私有函数、被多个对话框复用，故这里不抽公共组件，
/// 免得动到其它调用点）。
class _NavBarPositionTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final bool selected;
  final VoidCallback onTap;

  const _NavBarPositionTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          color: selected
              ? theme.colorScheme.primary.withValues(alpha: 0.08)
              : theme.colorScheme.surface.withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: selected
                ? theme.colorScheme.primary.withValues(alpha: 0.4)
                : theme.colorScheme.outline.withValues(alpha: 0.1),
            width: selected ? 1.5 : 1,
          ),
        ),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: selected
                    ? theme.colorScheme.primary.withValues(alpha: 0.15)
                    : theme.colorScheme.onSurface.withValues(alpha: 0.05),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(
                icon,
                size: 20,
                color: selected
                    ? theme.colorScheme.primary
                    : theme.colorScheme.onSurface.withValues(alpha: 0.5),
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: selected
                          ? theme.colorScheme.primary
                          : theme.colorScheme.onSurface,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: TextStyle(
                      fontSize: 11.5,
                      color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
                    ),
                  ),
                ],
              ),
            ),
            if (selected)
              Icon(
                Broken.tick_circle,
                size: 22,
                color: theme.colorScheme.primary,
              ),
          ],
        ),
      ),
    );
  }
}
