import 'package:flutter/material.dart';

import '../../services/preferences_service.dart';

/// 壳内页面导航（试点：媒体分类页 / 最近页）。
///
/// 目的：从「分类页」进入的内容型页面不再覆盖底部 4-tab —— 页面只占据
/// HomeScreen 的 body 区域，外层 Scaffold 的 `bottomNavigationBar`
/// （4-tab / 工具按钮行）保持可见。
///
/// 设计约束（对既有代码零影响）：
/// - 该 Navigator 是 HomeScreen body 里 Stack 的**兄弟层**，不是任何 tab 页的
///   祖先，因此其它 `Navigator.push` 仍然落在根 Navigator（全屏），行为不变。
/// - 懒挂载：首次 [push] 时才构建，避免启动期多出一个 Navigator 影响焦点树；
///   栈内清空后延迟卸载（等退出动画走完）。
class ShellNavigator {
  ShellNavigator._();

  /// 壳内 Navigator 的 key（由 [ShellNavigatorLayer] 挂载）。
  static final GlobalKey<NavigatorState> navigatorKey =
      GlobalKey<NavigatorState>();

  /// 壳内已推入的页面数（不含透明基底）。0 = 未使用。
  static final ValueNotifier<int> depth = ValueNotifier<int>(0);

  /// 壳内顶层页面**自身**的多选态（例：媒体分类页的局部选择集）。
  ///
  /// 为 true 时 HomeScreen 会把整条导航栏（4-tab / 工具按钮行）收起，让页面
  /// 自身的多选操作栏落到屏幕最底部 —— 与浏览页 / 最近页（走全局
  /// `provider.isSelectionMode`）的既有表现保持一致，避免「操作栏叠在
  /// 4-tab 上方」两条栏并存。
  static final ValueNotifier<bool> childSelectionMode =
      ValueNotifier<bool>(false);

  /// 上报 / 复位壳内页面的多选态（页面 `dispose()` 里务必复位）。
  static void setChildSelectionMode(bool value) {
    if (childSelectionMode.value != value) childSelectionMode.value = value;
  }

  /// 壳内顶层页面是否处于「沉浸态」。
  ///
  /// 例：视频播放页控制条被自动隐藏（含锁定状态）、图片查看器隐藏了操作按钮。
  /// 为 true 时 HomeScreen 把**整条导航栏**收起 —— 页面铺满整个屏幕（视频 / 图片
  /// 真正全屏）；控制条 / 操作按钮被唤出时再置回 false，导航栏随之显示。
  static final ValueNotifier<bool> childImmersive = ValueNotifier<bool>(false);

  /// 上报 / 复位壳内页面的沉浸态（页面 `dispose()` 里务必复位）。
  static void setChildImmersive(bool value) {
    if (childImmersive.value != value) childImmersive.value = value;
  }

  /// 「导航栏应否收起」的合并视图：多选态或沉浸态任一为真都收起。
  ///
  /// 用 `Listenable.merge` 而非 `ValueListenableBuilder<bool>`：后者只能订阅单个
  /// `ValueNotifier`，而这里有两个来源都要能触发 `_buildNav*` 重建。
  ///
  /// 也并入 [depth]：底栏要按「壳内是否有页面」决定顶角是否与页面操作栏拼接，
  /// 壳内页面推入 / 退出时必须重算一次形状。
  static final Listenable navBarHidden = Listenable.merge([
    childSelectionMode,
    childImmersive,
    depth,
  ]);

  /// 退出动画时长（略大于默认 300ms），用于延迟卸载。
  static const Duration _exitAnimation = Duration(milliseconds: 340);

  static _ShellNavigatorLayerState? _host;

  /// 壳内是否有页面（供返回键 / 切 tab 判断）。
  static bool get hasPages => depth.value > 0;

  /// 在**壳内**推入页面（保留底部导航栏）。
  ///
  /// 宿主不可用时退化为普通全屏 push，保证任何调用点都不会因此失效。
  static Future<T?> push<T>(BuildContext context, Route<T> route) async {
    // 「导航栏常驻」总开关关闭时退化为全屏 push（回到旧行为）。
    if (!PreferencesService.getPersistentTabBar()) {
      return Navigator.of(context, rootNavigator: true).push<T>(route);
    }
    final host = _host;
    if (host == null) {
      return Navigator.of(context, rootNavigator: true).push<T>(route);
    }
    if (navigatorKey.currentState == null) {
      host.activate();
      // 等一帧，让壳内 Navigator 挂载后再 push（否则拿不到它的 state）。
      await WidgetsBinding.instance.endOfFrame;
    }
    final nav = navigatorKey.currentState;
    if (nav == null) {
      return Navigator.of(context, rootNavigator: true).push<T>(route);
    }
    return nav.push<T>(route);
  }

  /// 收起壳内全部页面（若已展开）。
  static void popAll() {
    navigatorKey.currentState?.popUntil((r) => r.isFirst);
  }

  /// 返回键：收起一层壳内页面。返回 true 表示本次返回已被消费。
  ///
  /// 用 `maybePop` 而非 `pop`，以尊重页面自身的 `PopScope`（例如媒体分类页
  /// 在多选态下的「先退出多选」逻辑）。
  static Future<bool> popOne() async {
    final nav = navigatorKey.currentState;
    if (nav == null || !nav.canPop()) return false;
    return nav.maybePop();
  }

  static void _attach(_ShellNavigatorLayerState host) => _host = host;

  static void _detach(_ShellNavigatorLayerState host) {
    if (identical(_host, host)) _host = null;
  }

  /// 栈内已清空：延迟卸载，避免把退出动画截断。
  static void _scheduleUnmount() {
    Future.delayed(_exitAnimation, () {
      if (depth.value == 0) _host?.deactivate();
    });
  }
}

/// 让 HomeScreen 的 body 变为「内容 + 壳内导航层」的叠层容器。
///
/// 单独抽出来是为了让 home_screen 的改动保持最小（只包一层，不重排缩进）。
class ShellBody extends StatelessWidget {
  const ShellBody({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [child, const ShellNavigatorLayer()],
    );
  }
}

/// 叠在内容之上的壳内导航层；未激活时不占位、不参与命中测试。
class ShellNavigatorLayer extends StatefulWidget {
  const ShellNavigatorLayer({super.key});

  @override
  State<ShellNavigatorLayer> createState() => _ShellNavigatorLayerState();
}

class _ShellNavigatorLayerState extends State<ShellNavigatorLayer> {
  static final NavigatorObserver _observer = _ShellDepthObserver();

  bool _active = false;

  @override
  void initState() {
    super.initState();
    ShellNavigator._attach(this);
  }

  @override
  void dispose() {
    ShellNavigator._detach(this);
    super.dispose();
  }

  /// 挂载壳内 Navigator（幂等）。
  void activate() {
    if (!_active && mounted) setState(() => _active = true);
  }

  /// 卸载壳内 Navigator（栈为空时才可调用）。
  void deactivate() {
    if (_active && mounted) setState(() => _active = false);
  }

  @override
  Widget build(BuildContext context) {
    if (!_active) return const SizedBox.shrink();
    return ValueListenableBuilder<int>(
      valueListenable: ShellNavigator.depth,
      builder: (context, depth, _) {
        return IgnorePointer(
          // 只剩透明基底时不吃手势，让下面的首页内容照常交互
          // （ModalBarrier 即使无颜色也会以 HitTestBehavior.opaque 吸收点击）。
          ignoring: depth == 0,
          child: Navigator(
            key: ShellNavigator.navigatorKey,
            observers: [_observer],
            onGenerateInitialRoutes: (navigator, initialRoute) =>
                <Route<dynamic>>[_transparentBaseRoute()],
            onGenerateRoute: (settings) => _transparentBaseRoute(),
          ),
        );
      },
    );
  }

  /// 透明基底：不绘制内容，仅让 Navigator 有初始路由。
  Route<void> _transparentBaseRoute() {
    return PageRouteBuilder<void>(
      opaque: false,
      barrierColor: null,
      barrierDismissible: false,
      transitionDuration: Duration.zero,
      reverseTransitionDuration: Duration.zero,
      pageBuilder: (_, __, ___) => const SizedBox.shrink(),
    );
  }
}

/// 维护 [ShellNavigator.depth]：只统计壳内真正推入的页面（不含透明基底）。
class _ShellDepthObserver extends NavigatorObserver {
  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (previousRoute != null) ShellNavigator.depth.value++;
  }

  void _countDown() {
    if (ShellNavigator.depth.value > 0) {
      ShellNavigator.depth.value--;
      if (ShellNavigator.depth.value == 0) ShellNavigator._scheduleUnmount();
    }
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (previousRoute != null) _countDown();
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (previousRoute != null) _countDown();
  }
}
