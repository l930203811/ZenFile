import 'package:flutter/material.dart';

import '../../services/preferences_service.dart';
import '../../services/build_trigger_counter.dart';
import '../../services/webdav_debug_log.dart';

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
  static final ValueNotifier<bool> childSelectionMode = ValueNotifier<bool>(
    false,
  );

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
  ///
  /// ## ⚠️ 这里的等待逻辑为什么不能只 `await` 一次（2026-11-28 第十一轮）
  ///
  /// 原实现是：
  /// ```dart
  /// if (navigatorKey.currentState == null) {
  ///   host.activate();
  ///   await WidgetsBinding.instance.endOfFrame;   // 只等一帧
  /// }
  /// final nav = navigatorKey.currentState;
  /// if (nav == null) {
  ///   return Navigator.of(context, rootNavigator: true).push<T>(route);
  /// }
  /// return nav.push<T>(route);
  /// ```
  ///
  /// 问题有三层：
  ///
  /// 1. **只等一帧不够**。`host.activate()` 只是把 `ShellNavigatorLayer` 标脏，
  ///    真正把 `Navigator` 建出来、把 `navigatorKey.currentState` 挂上，要等
  ///    **下一次 build**。而那一帧里如果首页正在做别的事（媒体扫描、分类加载、
  ///    一次 `setState` 连锁），这一帧可能只够把外壳建出来，Navigator 的 state
  ///    还没挂上 ⇒ `nav` 仍是 null。
  /// 2. **退化路径也不可靠**。`Navigator.of(context, rootNavigator: true)` 在
  ///    `context` 已失效（页面刚被重建/替换）时会抛异常，异常被手势回调吞掉 ⇒
  ///    用户看到的就是「点了完全没反应」。
  /// 3. **整个过程没有任何日志** ⇒ 出了问题也看不出到底 push 没 push。
  ///
  /// ⇒ 现在改成：**有界重试**等 Navigator 就绪（最多 5 帧），就绪则走壳内；
  /// 仍未就绪则**强制退化**成全屏 push，并且全程打点。
  /// 目标很简单：**任何一次 push 请求都必须产生一次可见的导航**。
  static Future<T?> push<T>(BuildContext context, Route<T> route) async {
    // 「导航栏常驻」总开关关闭时退化为全屏 push（回到旧行为）。
    if (!PreferencesService.getPersistentTabBar()) {
      BuildTriggerCounter.navigationEvents++;
      WebdavDebugLog.logAlways('[nav] 壳内push → 全屏push（常驻导航栏已关闭）');
      return Navigator.of(context, rootNavigator: true).push<T>(route);
    }
    final host = _host;
    if (host == null) {
      BuildTriggerCounter.navigationEvents++;
      WebdavDebugLog.logAlways('[nav] 壳内push → 全屏push（壳内宿主未挂载）');
      return Navigator.of(context, rootNavigator: true).push<T>(route);
    }
    // 壳内 Navigator 尚未挂载：先激活，再有界地等它把 state 挂上来。
    //
    // ⚠️⚠️ **绝不能无限等 `endOfFrame`**（2026-11-28 第十一轮，**根因修复**）：
    //
    // `SchedulerBinding.endOfFrame` 的 Future **只在 post-frame 回调被执行时
    // 才完成**，而 post-frame 回调**只在真正产出了一帧时**才会跑。框架源码
    // 原文就写着：
    //   "If the device's screen is currently turned off, this may wait a very
    //    long time, since frames are not scheduled while the device's screen
    //    is turned off."
    //
    // 一旦此刻 App 没有产出帧（屏幕关闭 / App 在后台 / `framesEnabled == false`
    // / 调度器正忙），这个 Future 就**永远不会完成** ⇒ `await` 永久挂起 ⇒
    // **`push` 静默消失 ⇒ 用户看到「点了完全没反应」**。
    //
    // 真机日志里那个决定性形状正是如此：
    //   09:23:44.783 `分类卡片 onTap 视频`（回调执行了）
    //   09:23:47.672 `分类卡片 onTap 文档`（3 秒后**还在首页**点分类卡片！）
    // ⇒ 视频页根本没被推上去（`PageRouteBuilder` 默认 `opaque: true`，
    //    若真的推上去了，首页的分类卡片是点不到的）。
    //
    // ⇒ 用「帧数 + 超时」双重保险：`Future.any` 里放一个定时器，
    //    无论帧来不来，120ms 后一定继续往下走（走兑底的全屏 push）。
    for (int i = 0; i < 5 && navigatorKey.currentState == null; i++) {
      if (i == 0) host.activateLayer();
      // endOfFrame 只保证「下一帧画完了」，不保证「Navigator 的 state 已挂上」，
      // 所以这里必须循环 + 每轮重新检查，而不是只 await 一次。
      await Future.any<void>(<Future<void>>[
        WidgetsBinding.instance.endOfFrame,
        // 超时兜底：**这一帧不来也必须继续**，否则整个 push 就消失了。
        Future<void>.delayed(const Duration(milliseconds: 120)),
      ]);
    }
    final nav = navigatorKey.currentState;
    if (nav == null) {
      // 兜底：壳内导航不可用时**也必须**把页面推上去，绝不能「点了没反应」。
      //
      // ⚠️ 等待期间宿主页面可能已被销毁（切 tab / 重建首页）⇒ 此时
      // `Navigator.of(context)` 会抛异常，而异常会被手势回调静默吞掉，
      // 用户看到的就是「点了完全没反应」。所以先做 mounted 守卫。
      if (!context.mounted) {
        WebdavDebugLog.logAlways('[nav] 壳内push → 宿主已销毁，放弃本次导航');
        return null;
      }
      BuildTriggerCounter.navigationEvents++;
      WebdavDebugLog.logAlways('[nav] 壳内push → 全屏push（壳内Navigator未就绪）');
      return Navigator.of(context, rootNavigator: true).push<T>(route);
    }
    BuildTriggerCounter.navigationEvents++;
    WebdavDebugLog.logAlways('[nav] 壳内push 正常 depth=${depth.value}');
    // ⚠️ `nav.push` 返回的 Future 在页面**被弹出**时才完成，
    //    这里绝不能 await（会把调用方挂住几十分钟）。
    return nav.push<T>(route);
  }

  /// 收起壳内全部页面（若已展开）。
  static void popAll() {
    final nav = navigatorKey.currentState;
    if (nav == null || !hasPages) return;
    WebdavDebugLog.logAlways(
      '[nav] popAll请求 depth=${ShellNavigator.depth.value}\n${StackTrace.current}',
    );
    nav.popUntil((r) => r.isFirst);
  }

  /// 返回键：收起一层壳内页面。返回 true 表示本次返回已被消费。
  ///
  /// 用 `maybePop` 而非 `pop`，以尊重页面自身的 `PopScope`（例如媒体分类页
  /// 在多选态下的「先退出多选」逻辑）。
  static Future<bool> popOne() async {
    final nav = navigatorKey.currentState;
    if (nav == null || !nav.canPop()) return false;
    WebdavDebugLog.logAlways(
      '[nav] popOne请求 depth=${ShellNavigator.depth.value}\n${StackTrace.current}',
    );
    return nav.maybePop();
  }

  static void _attach(_ShellNavigatorLayerState host) => _host = host;

  static void _detach(_ShellNavigatorLayerState host) {
    if (identical(_host, host)) _host = null;
  }

  /// 栈内已清空：延迟卸载，避免把退出动画截断。
  static void _scheduleUnmount() {
    Future.delayed(_exitAnimation, () {
      if (depth.value == 0) _host?.deactivateLayer();
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
    return Stack(children: [child, const ShellNavigatorLayer()]);
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
  ///
  /// ⚠️ **方法名不能叫 `activate`**（2026-11-28 第十一轮修正）：
  /// `State.activate()` 是**框架自己的生命周期回调**（Element 被重新激活时调用，
  /// 且标注了 `@mustCallSuper`）。同名覆盖却不调 `super.activate()`，
  /// 会让框架的 `_debugLifecycleState` 状态机错乱 —— 元素被重新插入树时
  /// 可能抛断言、或在错误的生命周期阶段调用 `setState`。
  /// ⇒ 改名为 `activateLayer` / `deactivateLayer`，与框架回调彻底区分。
  void activateLayer() {
    if (!_active && mounted) setState(() => _active = true);
  }

  /// 卸载壳内 Navigator（栈为空时才可调用）。
  ///
  /// 同样因为命名撞车而改名，理由见 [activateLayer]。
  void deactivateLayer() {
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
    WebdavDebugLog.logAlways(
      '[nav] didPush ${route.runtimeType} previous=${previousRoute?.runtimeType}',
    );
    if (previousRoute != null) {
      ShellNavigator.depth.value++;
      // 取证：push 之后立刻记一笔深度。下一份日志里若看到「push 后深度又
      // 立刻掉回 0」，就说明页面被某个 `popAll()`（例如切换 tab）秒收 ⇒
      // 用户看到的就是「点了没反应」。这是本轮日志里最需要的一格证据。
      BuildTriggerCounter.navigationEvents++;
      WebdavDebugLog.logAlways(
        '[nav] 壳内push路由 depth=${ShellNavigator.depth.value}',
      );
    }
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    WebdavDebugLog.logAlways(
      '[nav] didPop ${route.runtimeType} previous=${previousRoute?.runtimeType} depth=${ShellNavigator.depth.value}',
    );
    if (previousRoute != null) _countDown('didPop', route);
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    WebdavDebugLog.logAlways(
      '[nav] didRemove ${route.runtimeType} previous=${previousRoute?.runtimeType} depth=${ShellNavigator.depth.value}',
    );
    if (previousRoute != null) _countDown('didRemove', route);
  }

  void _countDown(String action, Route<dynamic> route) {
    if (ShellNavigator.depth.value > 0) {
      ShellNavigator.depth.value--;
      WebdavDebugLog.logAlways(
        '[nav] $action ${route.runtimeType} depth=${ShellNavigator.depth.value}',
      );
      if (ShellNavigator.depth.value == 0) ShellNavigator._scheduleUnmount();
    }
  }
}
