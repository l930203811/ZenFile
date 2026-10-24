import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../providers/file_manager_provider.dart';
import '../screens/home_screen.dart';
import 'zenfile_bottom_nav_bar.dart';

/// 「导航栏常驻其他页面」（persistentTabBar）的**作用域包装**。
///
/// 背景：底栏重构为 LiquidBottomBar 后，该开关只剩 provider 读写、没有任何
/// UI 消费点。设置重组（v2.2/v2.3）新增的子页面（通用 / 分类页 / 浏览页设置
/// 及各分组子页）都是全屏 MaterialPageRoute，盖住 HomeScreen 后底栏不可见；
/// 本组件让这些页面在开关开启时也显示与首页同款的底部 4-tab。
///
/// 行为：
/// · `persistentTabBar == false`（或导航栏总开关关闭）：原样返回 child，
///   页面与接入前完全一致（零开销、零包裹）；
/// · `true`：给 child 套一层 `Scaffold(bottomNavigationBar: ZenFileBottomNavBar)`，
///   底栏样式与首页同源（同一组件、同一订阅），backgroundColor 取
///   `scaffoldBackgroundColor` 与各子页 Scaffold 默认背景一致，
///   深色 / AMOLED 下自动跟随主题。
///
/// 订阅用 `context.select`：在「导航栏设置」面板或自定义快捷方式页切换开关
/// （provider.notifyListeners）的当帧，本组件即重建、底栏即时出现 / 收起，
/// 无需重进页面。
///
/// 跨路由 tab 点击：本组件渲染的底栏在首页之外的**全屏路由**里，点击无法直接
/// 操作 HomeScreen 的 IndexedStack —— 经静态通知器 `HomeScreen.pendingTabSwitch`
/// 转交：宿主监听后回到首页根路由（popUntil）再执行既有的切页 / 槽位打开逻辑。
///
/// 键盘：外层 Scaffold 关掉 `resizeToAvoidBottomInset`（child 里的子页 Scaffold
/// 自己会按 viewInsets 收缩；两层都开会导致内容被收缩两次）。
class PersistentNavBarScope extends StatelessWidget {
  const PersistentNavBarScope({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    // 「导航栏常驻」总开关 + 「显示导航栏」总开关：后者关闭时首页本就无 4-tab，
    // 常驻栏不应单独出现（否则「关掉导航栏」在子页上形同虚设）。
    final persistent = context.select<FileManagerProvider, bool>(
      (p) => p.persistentTabBar,
    );
    final navEnabled = context.select<FileManagerProvider, bool>(
      (p) => p.bottomNavBarEnabled,
    );
    if (!persistent || !navEnabled) return child;
    return Scaffold(
      // 与各子页 Scaffold 的默认背景一致（子页均未显式设 backgroundColor，
      // 落到主题的 scaffoldBackgroundColor；AMOLED 开启时它本身就是纯黑）。
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      resizeToAvoidBottomInset: false,
      bottomNavigationBar: ZenFileBottomNavBar(
        // 高亮语义：这些页面都属于「设置」分区 —— 高亮设置 tab
        // （activeBottomSlot=-1 → presence 判定走 currentIndex）。
        currentIndex: kZenFileSettingsTabIndex,
        activeBottomSlot: -1,
        onSwitchTab: HomeScreen.requestCrossRouteTabSwitch,
        onOpenSlotEntry: HomeScreen.requestCrossRouteSlotEntry,
        // 长按替换槽位只在首页底栏提供（见 ZenFileBottomNavBar.onSlotLongPress）。
      ),
      body: child,
    );
  }
}
