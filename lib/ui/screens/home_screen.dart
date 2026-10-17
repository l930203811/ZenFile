import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:permission_handler/permission_handler.dart';
import '../../providers/file_manager_provider.dart';
import '../../providers/media_provider.dart';
import '../../core/icon_fonts/broken_icons.dart';
import '../widgets/quick_categories_grid.dart';
import '../widgets/liquid_bottom_bar.dart';
import '../widgets/liquid_pressable.dart';
import 'all_recent_files_screen.dart';
import '../../services/preferences_service.dart';
import '../widgets/zenfile_drawer.dart';
import '../widgets/favorites_sheet.dart';
import '../widgets/sort_modal.dart';
import 'directory_screen.dart';
import 'transfers_screen.dart';
import 'more_settings_screen.dart';
import 'global_search_screen.dart';
import '../navigation/shell_navigator.dart';
import 'package:zenfile/l10n/generated/app_localizations.dart';

class HomeScreen extends StatefulWidget {
  final VoidCallback toggleTheme;
  const HomeScreen({super.key, required this.toggleTheme});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver, SingleTickerProviderStateMixin {
  int _currentIndex = 0;
  // 当前高亮的「自定义底部槽位」（承载页面的槽位，如最近页 / 分类入口页）；-1 = 无。
  // 内置 tab 的高亮由 _currentIndex 决定；两者互斥 —— 只要 _activeBottomSlot != -1，
  // 内置 tab 一律不高亮（见 _buildTabItem），避免同时出现两个高亮 tab。
  int _activeBottomSlot = -1;
  // 由底部槽位打开的壳内页面栈（存槽位号）：打开时入栈、返回时出栈，高亮始终等于栈顶
  // 槽位。用于「从槽位 A 的页面里再打开槽位 B 的页面」时把高亮让给 B，B 退出后再还给 A。
  final List<int> _slotPageStack = <int>[];
  DateTime? _lastBackPressTime;
  late AnimationController _refreshIconController;
  bool _isRefreshing = false;
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();
  // 缓存屏幕宽度，仅在尺寸真正变化时更新；build 不再读取 MediaQuery，
  // 避免键盘弹起时 viewInsets 逐帧变化触发整个 home_screen 重建。
  double _screenW = 0;
  // 双指滑动检测
  final Map<int, Offset> _activePointers = {};
  Offset? _dualFingerStartCenter;
  // 单指滑动追踪（用 Listener 而非 GestureDetector，避免手势竞技场冲突）
  Offset? _singleFingerStart;
  Offset? _singleFingerLast;
  DateTime? _singleFingerStartTime;
  DateTime? _singleFingerLastTime;
  // 本次手势期间是否真的发生过「文件长按拖拽」。v1.1.41 用 fileDragInteracting
  // 在 down 阶段就掐断追踪，而该标志在任一文件项按下时即置位，导致落在文件上的
  // 正常滑动永远不触发切页（浏览页绝大部分面积都被文件项覆盖）。改为只在拖拽
  // 真正开始后才抑制，既保留防误触又恢复灵敏度。
  bool _dragStartedDuringGesture = false;
  // 内嵌设置页（第 4 页）是否处于搜索态。嵌套 PopScope 的 onPopInvoked 会被**全部**
  // 调用，设置页在搜索中处理返回（退出搜索）的同时，本页也会被调用一次 —— 这里据此
  // 让行，否则会在退出搜索时又弹出「再按一次退出」的提示。
  bool _settingsSearching = false;
  // 内嵌设置页是否已首次显示（惰性构建）。IndexedStack 会构建并布局**全部**子页，
  // 而设置页有 75 个卡片、build 里还 watch 了 FileManagerProvider —— 若一进 App 就
  // 建出来，分类页首帧和之后每次 provider 刷新都要白算一遍。首次切到第 4 页才创建。
  bool _settingsTabBuilt = false;
  // 全局搜索「在设置中搜索」注入的查询词与请求序号：序号变化即要求设置页重新进入
  // 搜索态（用户可能在设置页手动退出过搜索，再点同一条结果也要能重新过滤）。
  String? _settingsTabQuery;
  int _settingsTabQueryId = 0;
  // 功能入口请求监听是否已注册（didChangeDependencies 可能被多次调用）。
  bool _featureRequestListenersAttached = false;
  // provider 引用：dispose 时要用它移除监听（那时不宜再用 context.read）。
  FileManagerProvider? _fmRef;
  static const double _dualFingerSwipeThreshold = 30.0;
  // 单指切页阈值：最小水平位移 / 免速度门槛的长位移 / 最小速度 / 边缘保护
  static const double _swipeMinDistance = 64.0;
  static const double _swipeLongDistance = 110.0;
  static const double _swipeMinVelocity = 260.0;
  static const double _swipeEdgeGuard = 36.0;
  // 底部导航第 1/2 个（分类/浏览）固定为滑动轴心；第 2/3 槽位可被自定义快捷方式页中的
  // 任意入口替换（长按槽位或该页配置区选择）。滑动切页仅保留 左抽屉→分类→浏览→右抽屉：
  // 左滑 分类→浏览、浏览→右抽屉；右滑 浏览→分类、分类→左抽屉；自定义槽位点击进入
  // （push 页面），不参与滑动。
  static const int _settingsTabIndex = 3;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refreshIconController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 1),
    );
    _currentIndex = context.read<FileManagerProvider>().defaultToBrowseScreen ? 1 : 0;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      try {
        Permission.manageExternalStorage.isGranted.then((hasFullPermission) {
          if (hasFullPermission) {
            context.read<MediaProvider>().loadMedia();
          }
        });
      } catch (_) {}
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // 缓存屏幕宽度但不订阅 MediaQuery：build 内只用 _screenW，键盘 Insets 逐帧
    // 变化不会让本 widget 重建。旋转等真实尺寸变化会重新触发本方法更新。
    _screenW = MediaQuery.of(context).size.width;
    final fileManager = context.read<FileManagerProvider>();
    // 全局搜索功能入口请求（在设置中搜索 / 刷新 / 排序 / 主题 / 自定义快捷方式）：
    // 注册一次即可，通过 provider 通道把请求转成首页已有的实现。
    _fmRef = fileManager;
    if (!_featureRequestListenersAttached) {
      _featureRequestListenersAttached = true;
      fileManager.settingsSearchRequestNotifier
          .addListener(_onSettingsSearchRequested);
      fileManager.quickActionRequestNotifier
          .addListener(_onQuickActionRequested);
    }
    // 检查是否需要从设置页面跳转到浏览标签
    if (fileManager.navigateToBrowseTab) {
      fileManager.setNavigateToBrowseTab(false);
      if (_currentIndex != 1) {
        _switchTab(1);
      }
    }
  }

  @override
  void dispose() {
    _refreshIconController.dispose();
    _fmRef?.settingsSearchRequestNotifier
        .removeListener(_onSettingsSearchRequested);
    _fmRef?.quickActionRequestNotifier
        .removeListener(_onQuickActionRequested);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  void _switchTab(int index) {
    // 壳内有页面（媒体分类页 / 最近页等）时，先收起它们再切页，
    // 避免「底栏已切 tab、内容区还停在壳内页面」的错位。
    if (ShellNavigator.hasPages) ShellNavigator.popAll();
    // 边界保护：IndexedStack 共 4 页（分类/文件/传输/设置），越界 index 直接忽略，
    // 避免 IndexedStack index 越界崩溃。
    if (index < 0 || index > _settingsTabIndex) return;
    // 标记设置页已激活：让 IndexedStack 在该槽位换成真正的设置页（惰性构建）。
    if (index == _settingsTabIndex) _settingsTabBuilt = true;
    if (_currentIndex == index) {
      // 同一内置页：仍要清掉「自定义槽位页面」的残留高亮（壳内页面已在上方 popAll 收起），
      // 否则会出现内置 tab 与自定义槽位同时高亮。
      if (_activeBottomSlot != -1 || _slotPageStack.isNotEmpty) {
        _slotPageStack.clear();
        setState(() => _activeBottomSlot = -1);
      }
      return;
    }
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    // 切到内置页：清空「槽位页面栈」与自定义槽位高亮，高亮交还内置 tab。
    _slotPageStack.clear();
    _activeBottomSlot = -1;
    setState(() => _currentIndex = index);
  }

  /// 全局搜索「在设置中搜索」：切到设置页并把查询词交给它过滤显示。
  void _onSettingsSearchRequested() {
    if (!mounted) return;
    final provider = context.read<FileManagerProvider>();
    final query = provider.pendingSettingsQuery;
    if (query == null || query.isEmpty) return;
    setState(() {
      _settingsTabQuery = query;
      _settingsTabQueryId = provider.settingsSearchRequestId;
    });
    _switchTab(_settingsTabIndex);
  }

  /// 全局搜索命中「刷新 / 排序 / 深色模式 / 自定义快捷方式」这类依赖当前浏览页
  /// 状态的入口时，复用本页已有实现执行（避免在搜索页里复制一份逻辑）。
  void _onQuickActionRequested() {
    if (!mounted) return;
    final provider = _fmRef;
    if (provider == null) return;
    switch (provider.pendingQuickAction) {
      case 'refresh':
        _handleRefresh();
        break;
      case 'sort':
        _switchTab(1);
        Future.delayed(const Duration(milliseconds: 300), () {
          if (!mounted) return;
          SortModal.show(context, provider);
        });
        break;
      case 'customize':
        _switchTab(0);
        Future.delayed(const Duration(milliseconds: 300), () {
          if (!mounted) return;
          QuickCategoriesGrid.showCustomizeDialog(
            context,
            (index) => _switchTab(index),
          );
        });
        break;
      case 'toggle_theme':
        widget.toggleTheme();
        break;
      default:
        break;
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      try {
        Permission.manageExternalStorage.isGranted.then((hasFullPermission) {
          if (hasFullPermission) {
            try {
              context.read<MediaProvider>().refreshMediaBackground();
            } catch (_) {}
          }
        });
      } catch (_) {}
      // 回到前台时顺手给当前远程会话做一次体检：切后台期间底层 socket 常被
      // 系统/服务器回收（Dart 侧仍以为自己连着），不体检的话用户回来第一次
      // 操作必然失败、只能退出连接重进。fire-and-forget，内部自带超时。
      try {
        unawaited(context.read<FileManagerProvider>().checkActiveRemoteSession());
      } catch (_) {}
    }
  }

  Future<void> _handleRefresh() async {
    if (_isRefreshing) return;
    setState(() {
      _isRefreshing = true;
    });
    _refreshIconController.repeat();
    try {
      await Future.wait([
        context.read<FileManagerProvider>().updateStorageSpace(),
        context.read<MediaProvider>().loadMedia(forceRefresh: true),
      ]);
    } catch (_) {
    } finally {
      if (mounted) {
        _refreshIconController.stop();
        setState(() {
          _isRefreshing = false;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(L10n.of(context).msge109d1ea),
            behavior: SnackBarBehavior.floating,
            duration: const Duration(seconds: 1),
          ),
        );
      }
    }
  }

  void _handleBackPress(BuildContext context) {
    final now = DateTime.now();
    if (_lastBackPressTime != null &&
        now.difference(_lastBackPressTime!) < const Duration(seconds: 2)) {
      _lastBackPressTime = null;
      SystemNavigator.pop();
    } else {
      _lastBackPressTime = now;
      ScaffoldMessenger.of(context).clearSnackBars();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(L10n.of(context).msg05cea075, style: TextStyle(fontSize: 14)),
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 2),
          margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<FileManagerProvider>();
    // 浏览页内的返回（返回上一级 / 远程根→本地根）由内部 directory_screen /
    // pane_browser 的 PopScope 与 provider.goBack 处理；home 层绝不在此弹出
    // 路由，否则会直接跳到分类页。分类页等非浏览 tab 的返回仍走下方 onPopInvoked。
    return PopScope(
      // 编辑路径态下禁止路由返回，交由下方 onPopInvoked 取消编辑并停留在浏览页
      canPop: false,
      onPopInvoked: (didPop) {
        if (didPop) return;
        // 壳内页面（媒体分类页 / 最近页等）优先：返回键先收起一层壳内页面，
        // 而不是直接切标签页或退出应用。
        if (ShellNavigator.hasPages) {
          ShellNavigator.popOne();
          return;
        }
        // 抽屉打开时优先关闭抽屉
        if (_scaffoldKey.currentState?.isDrawerOpen ?? false) {
          _scaffoldKey.currentState?.closeDrawer();
          return;
        }
        // 右侧菜单打开时优先关闭
        if (_scaffoldKey.currentState?.isEndDrawerOpen ?? false) {
          _scaffoldKey.currentState?.closeEndDrawer();
          return;
        }
        // 内嵌设置页搜索中：返回键只用于退出搜索（由设置页自己的 PopScope 处理），
        // 本层必须让行，否则会同时弹出「再按一次退出」。
        if (_currentIndex == _settingsTabIndex && _settingsSearching) return;
        // 浏览页路径栏处于编辑态时，返回键仅退出编辑并停留在浏览页（不切换标签页/不导航）
        if (_currentIndex == 1 && provider.isPathEditing) {
          provider.exitPathEditing();
          return;
        }
        // 浏览页有选中状态时，清除选中而非切换页面
        if (_currentIndex == 1 && provider.isSelectionMode) {
          provider.clearSelection();
          return;
        }
        if (_currentIndex == 1) {
          // 浏览页的返回（返回上一级 / 远程根→本地根 / 本地根→分类页）由内部
          // directory_screen 的 PopScope 与 provider.goBack 统一处理。home 层
          // 在此不再切换标签页或弹出路由，避免双 PopScope 叠加导致返回键跳到
          // 分类页。抽屉/编辑态/选中态已在上方单独处理。
          return;
        } else {
          _handleBackPress(context);
        }
      },
      child: Scaffold(
        key: _scaffoldKey,
        // 键盘弹起时不再逐帧重排背后的重界面（文件列表/抽屉），避免"幻灯片式"
        // 慢弹与输入延迟。对话框(AlertDialog)自带 AnimatedPadding+viewInsets 会上移，
        // 底部弹窗同理，交互不受影响。
        resizeToAvoidBottomInset: false,
        drawer: ZenFileDrawer(
          toggleTheme: widget.toggleTheme,
          onNavigateTab: (index) => _switchTab(index),
          width: _screenW * 0.675,
          // 左抽屉「收藏夹」一项：先收起抽屉，等关闭动画走完再弹底部面板。
          onOpenFavorites: _openFavoritesFromDrawer,
        ),
        // 右侧抽屉（endDrawer）已下线：收藏夹改为底部半屏面板。入口为
        // 左抽屉「收藏夹」一项 / 底部导航栏上滑（导航栏开启时）/
        // 浏览页底部操作栏上滑，统一走 FavoritesSheet.show。
        // 订阅「导航栏该不该藏」的两个来源：
        //  1) childSelectionMode —— 媒体分类页等进入多选，让页面自身操作栏贴底
        //     （而不是叠在 4-tab 上方）；
        //  2) childImmersive     —— 视频控制条 / 图片操作按钮被隐藏的沉浸态，
        //     整条收起把屏幕让给内容，控制条唤出时再显示。
        bottomNavigationBar: ListenableBuilder(
          // 除「该不该收起」外，还要盯住浏览操作栏的折叠状态：它决定底栏顶角
          // 是方角（与操作栏拼成整块）还是圆角（操作栏已折叠，独立悬浮）。
          listenable: Listenable.merge([
            ShellNavigator.navBarHidden,
            DirectoryScreen.browseBarExpanded,
          ]),
          builder: (_, __) =>
              _buildNavBottomBar(provider.showBottomActionBar),
        ),
        body: ShellBody(
          child: Consumer<FileManagerProvider>(
          builder: (context, provider, _) {
            return Listener(
              onPointerDown: (event) {
                final fileProvider = context.read<FileManagerProvider>();
                // 地址栏（面包屑）或分类网格的交互不触发页面左右滑动切换：
                // 起点落在面包屑/类别图标上时，内层 Listener 已先置位对应标志，
                // 此处跳过本次手势追踪（仅登记指针以便 up 时正常清理）。
                // 注意：此处刻意不拦截 fileDragInteracting。该标志在任一文件项
                // 按下时即置位，若在此 return，落在文件上的滑动（浏览页绝大部分
                // 面积）将永远拿不到起始点，表现为「左右滑动切页失效/极不灵敏」。
                // 真正的拖拽抑制下移到 move/up 阶段按「拖拽是否真的开始」判定。
                if (fileProvider.breadcrumbInteracting || fileProvider.categoryReorderInteracting || fileProvider.tabBarInteracting) {
                  _activePointers[event.pointer] = event.position;
                  return;
                }
                _activePointers[event.pointer] = event.position;
                if (_activePointers.length == 1) {
                  // 单指开始追踪
                  _dragStartedDuringGesture = false;
                  _singleFingerStart = event.position;
                  _singleFingerLast = event.position;
                  _singleFingerStartTime = DateTime.now();
                  _singleFingerLastTime = DateTime.now();
                } else if (_activePointers.length == 2) {
                  // 双指开始追踪
                  _singleFingerStart = null;
                  _singleFingerLast = null;
                  final positions = _activePointers.values.toList();
                  _dualFingerStartCenter = Offset(
                    (positions[0].dx + positions[1].dx) / 2,
                    (positions[0].dy + positions[1].dy) / 2,
                  );
                }
              },
              onPointerMove: (event) {
                if (_activePointers.containsKey(event.pointer)) {
                  _activePointers[event.pointer] = event.position;
                }
                final fp = context.read<FileManagerProvider>();
                // 分类页拖拽排序期间：放弃本次单指滑动追踪，避免误触切页
                if (fp.categoryReorderInteracting) {
                  _singleFingerStart = null;
                  _singleFingerLast = null;
                  return;
                }
                // 文件长按拖拽「真正开始」后：放弃本次滑动追踪。仅凭
                // fileDragInteracting 不够——它在任一文件项按下时就置位，
                // 会把正常滑动一并误杀（v1.1.41 切页迟钝的根因）。
                if (fp.isDragging) {
                  _dragStartedDuringGesture = true;
                  _singleFingerStart = null;
                  _singleFingerLast = null;
                  return;
                }
                if (_activePointers.length == 1 && _singleFingerLast != null) {
                  _singleFingerLast = event.position;
                  _singleFingerLastTime = DateTime.now();
                }
              },
              onPointerUp: (event) {
                // 双指滑动处理
                if (_activePointers.length == 2 && _dualFingerStartCenter != null) {
                  final fileProvider = context.read<FileManagerProvider>();
                  if (fileProvider.enableDualFingerSwipe) {
                    final positions = _activePointers.values.toList();
                    final endCenter = Offset(
                      (positions[0].dx + positions[1].dx) / 2,
                      (positions[0].dy + positions[1].dy) / 2,
                    );
                    final deltaX = endCenter.dx - _dualFingerStartCenter!.dx;
                    if (deltaX < -_dualFingerSwipeThreshold) {
                      // 向左滑动：分类→浏览（滑动仅三态：左抽屉→分类→浏览，传输/设置
                      // 等自定义槽位不参与滑动）。浏览页再左滑不动作 —— 右侧抽屉已下线，
                      // 收藏夹改由「底部导航栏 / 浏览页底部操作栏」上滑唤起。
                      if (_currentIndex < 1) {
                        _switchTab(_currentIndex + 1);
                      }
                    } else if (deltaX > _dualFingerSwipeThreshold) {
                      // 向右滑动：分类页开左抽屉，浏览页切回分类
                      if (_currentIndex == 0) {
                        _scaffoldKey.currentState?.openDrawer();
                      } else {
                        if (!fileProvider.isSelectionMode) {
                          _switchTab(0);
                          context.read<MediaProvider>().refreshMediaBackground();
                        }
                      }
                    }
                  }
                }
                // 单指滑动处理（Listener 级别，不进入手势竞技场）
                if (_activePointers.length == 1 && _singleFingerStart != null) {
                  final fileProvider = context.read<FileManagerProvider>();
                  // 本次手势真的拖拽过文件 / 正在拖拽 / 分类排序拖拽：不切页
                  if (_dragStartedDuringGesture || fileProvider.isDragging || fileProvider.categoryReorderInteracting) {
                    _singleFingerStart = null;
                    _singleFingerLast = null;
                  } else if (fileProvider.enableSingleFingerSwipe) {
                    final screenWidth = MediaQuery.of(context).size.width;
                    final startX = _singleFingerStart!.dx;
                    // 屏幕边缘留给系统返回手势，不处理
                    if (startX >= _swipeEdgeGuard && startX <= screenWidth - _swipeEdgeGuard) {
                      final endPos = _singleFingerLast ?? event.position;
                      final dx = endPos.dx - _singleFingerStart!.dx;
                      final dy = endPos.dy - _singleFingerStart!.dy;
                      // 明显竖向滚动不切页；给 1.2 倍斜向容差，避免斜划被吞掉
                      final horizontalDominant = dy.abs() <= dx.abs() * 1.2;
                      // 最小水平位移 64px（v1.1.41 为 80px，偏迟钝）
                      if (horizontalDominant && dx.abs() >= _swipeMinDistance) {
                        // 速度按「整段手势时长」计算。v1.1.41 用的是「最后一次
                        // move 到抬手」的间隔，抬手前稍作停顿速度就趋近 0，
                        // 导致明明滑了很远也不切页——这是迟钝的第二大来源。
                        final startT = _singleFingerStartTime ?? DateTime.now();
                        final lastT = _singleFingerLastTime ?? DateTime.now();
                        final totalMs = lastT.difference(startT).inMilliseconds;
                        final velocity = totalMs > 0 ? (dx / totalMs) * 1000 : 0.0; // px/s
                        // 快速轻扫 或 慢速长划（位移够大即忽略速度门槛）
                        if (velocity.abs() >= _swipeMinVelocity || dx.abs() >= _swipeLongDistance) {
                          if (dx < 0) {
                            // 向左滑动：分类→浏览（滑动仅三态：左抽屉→分类→浏览，传输/
                            // 设置等自定义槽位不参与滑动）。浏览页再左滑不动作。
                            if (_currentIndex < 1) {
                              _switchTab(_currentIndex + 1);
                            }
                          } else {
                            // 向右滑动：分类页开左抽屉，浏览页切回分类
                            if (_currentIndex == 0) {
                              _scaffoldKey.currentState?.openDrawer();
                            } else {
                              if (!fileProvider.isSelectionMode) {
                                _switchTab(0);
                                context.read<MediaProvider>().refreshMediaBackground();
                              }
                            }
                          }
                        }
                      }
                    }
                  }
                }
                _activePointers.remove(event.pointer);
                if (_activePointers.length < 2) {
                  _dualFingerStartCenter = null;
                }
                if (_activePointers.isEmpty) {
                  _singleFingerStart = null;
                  _singleFingerLast = null;
                  _singleFingerStartTime = null;
                  _dragStartedDuringGesture = false;
                  // 分类拖拽排序结束：恢复左右滑动切页能力。
                  // 必须在 home 手势处理完（含切页判定）后才清，否则会与 onReorderEnd
                  // 竞争，导致抬起瞬间标志已 false 而被误判为「非拖拽」触发切页。
                  context.read<FileManagerProvider>().setCategoryReorderInteracting(false);
                }
              },
              onPointerCancel: (event) {
                _activePointers.remove(event.pointer);
                if (_activePointers.length < 2) {
                  _dualFingerStartCenter = null;
                }
                if (_activePointers.isEmpty) {
                  _singleFingerStart = null;
                  _singleFingerLast = null;
                  _singleFingerStartTime = null;
                  _dragStartedDuringGesture = false;
                  // 分类拖拽排序结束：恢复左右滑动切页能力。
                  // 必须在 home 手势处理完（含切页判定）后才清，否则会与 onReorderEnd
                  // 竞争，导致抬起瞬间标志已 false 而被误判为「非拖拽」触发切页。
                  context.read<FileManagerProvider>().setCategoryReorderInteracting(false);
                }
              },
          child: Column(
            children: [
              ListenableBuilder(
                listenable: ShellNavigator.navBarHidden,
                builder: (_, __) =>
                    _buildNavTopBar(provider.showBottomActionBar),
              ),
              Expanded(
                child: Consumer<FileManagerProvider>(
            builder: (context, provider, _) {
              return ValueListenableBuilder<bool>(
                valueListenable: provider.navigateToBrowseTabNotifier,
                builder: (context, shouldNavigate, __) {
                  if (shouldNavigate) {
                    // 使用 microtask 确保在当前 build 完成后立即切换。
                    // 注意：无论当前是否已在浏览标签都执行——若已在该标签，
                    // _switchTab(1) 为 no-op，但仍会消费 pending 导航（加载目录 + 高亮），
                    // 使“分类页/最近页/浏览页”任意入口的定位行为完全一致。
                    scheduleMicrotask(() {
                      if (mounted) {
                        _switchTab(1);
                        provider.setNavigateToBrowseTab(false);
                        // 消费 pending 浏览导航
                        if (provider.pendingBrowsePath != null) {
                          provider.loadDirectory(provider.pendingBrowsePath!);
                          provider.setHighlightedPaths(provider.pendingHighlightedPaths);
                          provider.clearPendingBrowseNavigation();
                        }
                      }
                    });
                  }
                  return IndexedStack(
                    index: _currentIndex,
                    children: [
                      _buildHomeTab(),
                      DirectoryScreen(
                        toggleTheme: widget.toggleTheme,
                        onNavigateTab: (index) => _switchTab(index),
                        onOpenDrawer: () => _scaffoldKey.currentState?.openDrawer(),
                        onRefresh: () => _handleRefresh(),
                        // IndexedStack 会构建全部子页，浏览页的 PopScope 也会注册到
                        // 本页同一个 route 上并被返回键触发；必须告诉它「现在是不是
                        // 当前显示页」，否则在分类页按返回时它会把壳内页面的返回当作
                        // 浏览页后退，走到 _switchTab(0) → ShellNavigator.popAll()，
                        // 直接清空壳内栈（从查看器返回却跳回分类页）。
                        isActive: _currentIndex == 1,
                      ),
                      TransfersScreen(onNavigateTab: (index) => _switchTab(index)),
                      // 第 4 页「设置」：内嵌渲染（不再 push 全屏路由）。
                      // embedded=true 才会隐藏返回箭头并关掉 Scaffold/AppBar 的 primary
                      // 状态栏占位；onSearchActiveChanged 供返回键去重（见 _settingsSearching）。
                      // 未首次进入时用占位：避免一启动就构建/布局这 75 个卡片（惰性构建）。
                      if (!_settingsTabBuilt)
                        const SizedBox.shrink()
                      else
                        MoreSettingsScreen(
                          embedded: true,
                          // 由全局搜索「在设置中搜索」注入的查询词与请求序号。
                          initialQuery: _settingsTabQuery,
                          searchRequestId: _settingsTabQueryId,
                          onSearchActiveChanged: (v) => _settingsSearching = v,
                        ),
                    ],
                  );
                },
              );
            },
          ),
        ),
      ],
      ),
        );
      },
    ),
      ),
  ),
    );
  }

  /// 顶栏：位置=底部时显示工具按钮行（左抽屉 / 全局搜索 / 常用功能 5 项 / 设置），
  /// 位置=顶部时显示 4-tab 导航。
  ///
  /// 「导航栏」总开关只隐藏 **4-tab 那条** —— 工具按钮行永远保留，它是抽屉 /
  /// 搜索 / 刷新等操作的唯一入口。原实现只按底栏判开关，于是「位置=顶部 + 关闭
  /// 导航栏」会把底栏的工具按钮行藏掉、4-tab 反而留在顶部。
  Widget _buildNavTopBar(bool bottomTabs) {
    if (bottomTabs) return _buildTopBarRow();
    // 多选操作栏覆盖 4-tab：选择模式（长按多选）时隐藏顶栏 4-tab，
    // 与底栏行为保持一致；壳内页面（媒体分类页等）的局部多选态同理。
    if (ShellNavigator.childSelectionMode.value ||
        ShellNavigator.childImmersive.value ||
        context.select<FileManagerProvider, bool>((p) => p.isSelectionMode)) {
      return SizedBox(height: MediaQuery.of(context).padding.top);
    }
    // 4-tab 在顶栏：关闭时整条收起，只留状态栏高度的空白，
    // 免得下面的内容被状态栏压住。
    if (!context.select<FileManagerProvider, bool>((p) => p.bottomNavBarEnabled)) {
      return SizedBox(height: MediaQuery.of(context).padding.top);
    }
    return _buildBottomTabs();
  }

  /// 底栏：与顶部栏按「导航栏位置」设置互换。
  /// 导航栏开启且 4-tab 落在底栏时，整条栏支持**上滑**唤起收藏夹面板
  /// （对齐 MT / NP 管理器书签的手势）。
  ///
  /// 导航栏关闭时**不再补那条「贴底透明上滑热区」**：它正好落在系统手势导航的
  /// 底部边缘识别区里，上滑会被系统抢走（真机实测：收藏夹弹不出来，还会误触系统
  /// 手势）。收藏夹入口因此改为：
  ///   · 分类页 → 只保留左抽屉「收藏夹」一项；
  ///   · 浏览页 → 底部操作栏上滑（见 DirectoryScreen._buildCollapsibleBrowseActionBar）。
  /// 这里只留「系统手势条高度」的空白，避免浏览操作栏被系统手势条压住。
  Widget _buildNavBottomBar(bool bottomTabs) {
    final navEnabled =
        context.select<FileManagerProvider, bool>((p) => p.bottomNavBarEnabled);
    // 多选操作栏覆盖 4-tab：任一页面进入选择模式（长按多选）时隐藏整条底栏
    // （4-tab 或工具按钮行），让页面自身 bottomNavigationBar 的多选操作栏落到
    // 屏幕最底部，而不是悬在导航栏上方。
    final selecting =
        context.select<FileManagerProvider, bool>((p) => p.isSelectionMode);
    if (selecting ||
        ShellNavigator.childSelectionMode.value ||
        ShellNavigator.childImmersive.value) {
      return SizedBox(height: MediaQuery.of(context).padding.bottom);
    }
    // 位置=顶部：4-tab 在顶栏，底栏固定是工具按钮行。它不受总开关影响，
    // 否则「关掉导航栏」会把工具按钮行一起藏掉（它没有第二入口）。
    if (!bottomTabs) {
      final bar = _buildTopBarRow();
      if (!navEnabled) return bar;
      return GestureDetector(
        behavior: HitTestBehavior.translucent,
        onVerticalDragEnd: _handleSwipeUpForFavorites,
        child: bar,
      );
    }
    if (!navEnabled) {
      return SizedBox(height: MediaQuery.of(context).padding.bottom);
    }
    // 浏览页的操作栏与 4-tab 拼成一整块「底部控制台」：两者都留 16dp 左右边距、
    // 上下零间距，操作栏只圆上角、底栏只圆下角，拼起来轮廓连续。
    // 判定与浏览页自身显示操作栏的条件保持一致（同一开关 + 当前就是文件页 +
    // 没有壳内页面盖在上面）。
    final attachedTop = _currentIndex == 1 &&
        !ShellNavigator.hasPages &&
        // 操作栏被列表滚动折叠后，它上方已经没有东西可以拼了 —— 此时必须回到
        // 「顶角圆 + 6dp 悬浮间距」，否则底栏会变成一只平顶胶囊贴在列表下沿。
        DirectoryScreen.browseBarExpanded.value &&
        context.select<FileManagerProvider, bool>(
          (p) => p.showFloatingAddButton,
        );
    final tabBar = _buildBottomTabs(attachedTop: attachedTop);
    // 这里**不再**给 4-tab 槽位铺任何底色。
    //
    // 曾经为了消掉「胶囊左右多出一块更亮的底板」，在浏览页把槽位涂成纯黑去迁就
    // DirectoryScreen；代价是浏览页的 4-tab 比其他 tab 页更黑（深色模式下一眼可见），
    // 反而更像两套底栏。根因在背景色本身，不在槽位：DirectoryScreen 曾按
    // `brightness == dark` 无条件取纯黑，而外层 Scaffold 用的是
    // `theme.scaffoldBackgroundColor`（未开 AMOLED 时是深灰）。
    // 现在浏览页背景改回 `scaffoldBackgroundColor`（AMOLED 开关打开时它本身就是
    // 纯黑，见 AppTheme.getAmoledScaffoldBackground），内外层同色：
    //   · 4-tab 在**任何** tab 页都落在同一个底色上；
    //   · 操作栏的玻璃层底下也是它，两块半透明玻璃叠同一个底色 → 结果完全一致。
    return GestureDetector(
      // translucent：不拦截子级命中测试，图标 / 标签仍可正常点按。
      behavior: HitTestBehavior.translucent,
      onVerticalDragEnd: _handleSwipeUpForFavorites,
      child: tabBar,
    );
  }

  /// 底部导航栏上滑唤起收藏夹：
  /// 只认「向上」的快速滑动 —— 向下滑、慢速拖都不触发，避免和点按、横向切页抢手势。
  void _handleSwipeUpForFavorites(DragEndDetails details) {
    final velocity = details.primaryVelocity ?? 0;
    if (velocity < -260) _openFavoritesSheet();
  }

  /// 从左抽屉打开收藏夹：先收起抽屉，等关闭动画走完再弹面板，
  /// 否则抽屉收起与面板弹出两段动画会叠在一起。
  void _openFavoritesFromDrawer() {
    _scaffoldKey.currentState?.closeDrawer();
    Future.delayed(const Duration(milliseconds: 220), () {
      if (!mounted) return;
      _openFavoritesSheet();
    });
  }

  /// 弹出收藏夹面板（左抽屉「收藏夹」一项 / 底部导航栏上滑手势共用）。
  void _openFavoritesSheet() {
    if (!mounted) return;
    FavoritesSheet.show(
      context,
      provider: context.read<FileManagerProvider>(),
      onNavigateToBrowse: () => _switchTab(1),
    );
  }

  /// 顶部图标行：左抽屉 / 全局搜索 / 常用功能 5 项(刷新/排序/主题/单双窗口) / 设置。
  /// 全部只显示图标（紧凑按钮），文案以 tooltip 呈现。
  Widget _buildTopBarRow() {
    final theme = Theme.of(context);
    return Material(
      color: theme.appBarTheme.backgroundColor ?? theme.colorScheme.surface,
      elevation: 0,
      child: SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              height: 48,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  IconButton(
                    icon: Icon(Broken.sidebar_left, color: theme.colorScheme.primary),
                    onPressed: () => _scaffoldKey.currentState?.openDrawer(),
                  ),
                  // 全局搜索：图标样式，点击进入全局搜索页
                  IconButton(
                    icon: Icon(Broken.search_normal, color: theme.colorScheme.primary),
                    tooltip: L10n.of(context).ui_global_search_hint,
                    onPressed: () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(builder: (_) => const GlobalSearchScreen()),
                      );
                    },
                  ),
                  // 常用功能：刷新
                  IconButton(
                    icon: Icon(Broken.refresh, color: theme.colorScheme.primary),
                    tooltip: L10n.of(context).msg354c1c9a,
                    onPressed: () {
                      _switchTab(0);
                      _handleRefresh();
                    },
                  ),
                  // 常用功能：排序
                  IconButton(
                    icon: Icon(Broken.filter_edit, color: theme.colorScheme.primary),
                    tooltip: L10n.of(context).msg97301f64,
                    onPressed: () {
                      _switchTab(1);
                      Future.delayed(const Duration(milliseconds: 300), () {
                        final provider = context.read<FileManagerProvider>();
                        SortModal.show(context, provider);
                      });
                    },
                  ),
                  // 常用功能：切换主题
                  IconButton(
                    icon: Icon(
                      Theme.of(context).brightness == Brightness.dark
                          ? Broken.sun_1
                          : Broken.moon,
                      color: theme.colorScheme.primary,
                    ),
                    tooltip: Theme.of(context).brightness == Brightness.dark
                        ? L10n.of(context).msg8755e992
                        : L10n.of(context).ui_dark_mode,
                    onPressed: widget.toggleTheme,
                  ),
                  // 常用功能：单/双窗口
                  IconButton(
                    icon: Icon(
                      context
                              .read<FileManagerProvider>()
                              .enableSplitScreen
                          ? Broken.grid_1
                          : Broken.grid_2,
                      color: theme.colorScheme.primary,
                    ),
                    tooltip: context.read<FileManagerProvider>().enableSplitScreen
                        ? L10n.of(context).ui_single_window
                        : L10n.of(context).ui_dual_window,
                    onPressed: () {
                      // 切换单/双窗口前先跳到文件浏览页，方便用户直接看到布局
                      // 变化（参考排序按钮：_switchTab(1) 切到浏览页）。
                      _switchTab(1);
                      context.read<FileManagerProvider>().toggleSplitScreen();
                    },
                  ),
                  // 设置：顶栏最右一格（原收藏夹的位置）。收藏夹已移出顶栏，
                  // 改由左抽屉「收藏夹」一项 + 上滑手势唤起（导航栏开启时滑底栏，
                  // 导航栏关闭时滑浏览页底部操作栏）。
                  IconButton(
                    icon: Icon(Broken.setting_2, color: theme.colorScheme.primary),
                    tooltip: L10n.of(context).ui_personalize_settings,
                    onPressed: () => _switchTab(_settingsTabIndex),
                  ),
                  // 顶栏图标统一套一层「液态按压」：按住轻微鼓包、松开回弹，
                  // 与底部 4-tab 用同一套弹簧参数，避免这里成为全页唯一“死”的按钮组。
                ].map((w) => LiquidPressable(pressScale: 1.12, child: w)).toList(),
              ),
            ),
            Divider(height: 0.5, thickness: 0.5, color: theme.dividerColor.withValues(alpha: 0.08)),
          ],
        ),
      ),
    );
  }

  /// 底部导航 4 个槽位全部可自定义（默认 分类/文件/传输/最近），可被自定义快捷方式页
  /// 中的任意入口替换（长按槽位或在该页配置区选择），替换后点击打开对应入口（push 页面）。
  /// 滑动切页与底部 tab 解耦：IndexedStack 第 0/1 页恒为分类页/浏览页（滑动轴心），
  /// 滑动链路固定为 左抽屉→分类页→浏览页，即使底部 tab 被替换也始终可达。
  Widget _buildBottomTabs({bool attachedTop = false}) {
    final l10n = L10n.of(context);
    final slot0 = _resolveTabSlot(
      0,
      defaultIcon: Broken.category,
      defaultLabel: l10n.cat_quick_categories,
      defaultIndex: 0,
    );
    final slot1 = _resolveTabSlot(
      1,
      defaultIcon: Broken.folder,
      defaultLabel: l10n.ui_file,
      defaultIndex: 1,
    );
    final slot2 = _resolveTabSlot(
      2,
      defaultIcon: Broken.link,
      defaultLabel: l10n.ui_transfers,
      defaultIndex: 2,
    );
    final slot3 = _resolveTabSlot(
      3,
      defaultIcon: Broken.clock,
      defaultLabel: l10n.cat_recent,
      defaultIndex: -1,
    );
    final tabData = <List<Object>>[slot0, slot1, slot2, slot3];

    // ── 液态玻璃底栏 ──────────────────────────────────────────────────
    //
    // 样式与动效参考 Kyant0/AndroidLiquidGlass 的 LiquidBottomTabs
    // （Ghost Downloader v4.4.0 的 assets/licenses/liquid-bottom-bar.txt 标注了
    //  该来源为 2.0.0 catalog，经 BiliTools ui/liquidtabs/ 二次适配）。
    //
    // 与上一版「每个 tab 各自一块底色」的本质区别：**全程只有一块胶囊指示器**，
    // 它在 4 个槽位之间弹簧滑移、按压鼓包、被移动速度横向拉长 / 纵向压扁；
    // 外面再套一层玻璃容器（背景模糊 + 半透明 + 细描边 + 顶部微高光）。
    // 具体参数与本文件的分工说明见 lib/ui/widgets/liquid_bottom_bar.dart。
    //
    // 命中区仍是 4 个等分的**静止**区域（不随指示器移动），避免「胶囊滑到哪才能点哪」。
    // 上滑唤起收藏夹的 GestureDetector 在外层，命中范围不受影响。
    int selectedSlot = -1;
    for (var i = 0; i < tabData.length; i++) {
      final tab = tabData[i];
      final isSelected = (tab[3] as bool)
          ? _activeBottomSlot == (tab[4] as int)
          : _activeBottomSlot == -1 && _currentIndex == (tab[2] as int);
      if (isSelected) {
        selectedSlot = i;
        break;
      }
    }

    return SafeArea(
      top: false,
      child: Padding(
        // attachedTop：与浏览页操作栏拼接，顶部不再留空隙（6dp → 0）；
        // 其余页面仍保留 6dp，让胶囊像浮在内容之上。
        padding: EdgeInsets.fromLTRB(16, attachedTop ? 0 : 6, 16, 10),
        child: LiquidBottomBar(
          itemCount: tabData.length,
          selectedIndex: selectedSlot,
          attachedTop: attachedTop,
          onSelect: (i) {
            final tab = tabData[i];
            if (tab[3] as bool) {
              _openBottomTabEntry(tab[4] as int);
            } else {
              _switchTab(tab[2] as int);
            }
          },
          // 任意槽位长按：不进自定义快捷方式页即可替换入口。
          onLongPressItem: (i) => _showBottomTabPicker(tabData[i][4] as int),
          itemBuilder: (context, i, selected) {
            final tab = tabData[i];
            return _buildTabItem(
              tab[0] as IconData,
              tab[1] as String,
              selected: selected,
            );
          },
        ),
      ),
    );
  }

  /// 解析底部导航槽位 0-3 的显示与点击：未自定义返回默认内置页，自定义返回对应入口。
  List<Object> _resolveTabSlot(
    int slot, {
    required IconData defaultIcon,
    required String defaultLabel,
    required int defaultIndex,
  }) {
    final cfg = PreferencesService.getBottomTabSlotConfig(slot);
    if (cfg == null) {
      // v3.4b2：默认第 4 个槽位由「设置」改为「最近」（isCustomEntry 走 _openBottomTabEntry）
      if (slot == 3) {
        return [Broken.clock, L10n.of(context).cat_recent, -1, true, slot];
      }
      return [defaultIcon, defaultLabel, defaultIndex, false, slot];
    }
    final type = cfg['type'];
    final key = cfg['key'];
    if (type == 'builtin') {
      switch (key) {
        case 'tab_categories':
          return [Broken.category, L10n.of(context).cat_quick_categories, 0, false, slot];
        case 'tab_files':
          return [Broken.folder, L10n.of(context).ui_file, 1, false, slot];
        case 'tab_settings':
          return [Broken.setting_2, L10n.of(context).cat_settings, _settingsTabIndex, false, slot];
        case 'tab_recent':
          // 最近页走壳内导航（与默认 slot3 一致）
          return [Broken.clock, L10n.of(context).cat_recent, -1, true, slot];
        default:
          return [Broken.link, L10n.of(context).ui_transfers, 2, false, slot];
      }
    }
    // custom_entry：打开自定义快捷方式弹窗（isCustomEntry=true → 点击走 _openBottomTabEntry）
    if (type == 'custom_entry') {
      return [
        Broken.edit_2,
        PreferencesService.getCustomEntryLabel() ??
            L10n.of(context).ui_show_custom_entry,
        -1,
        true,
        slot,
      ];
    }
    // category / shortcut：从分类页全部入口重建显示与动作（与分类页网格同源）
    final map = QuickCategoriesGrid.getAllCategoriesMap(
      context,
      Theme.of(context).brightness == Brightness.dark,
      (i) => _switchTab(i),
    );
    final entry = map[key];
    if (entry != null) {
      return [entry['icon'] as IconData, entry['label'] as String, -1, true, slot];
    }
    // 配置失效（快捷方式被删除等）：回退默认内置页
    return [defaultIcon, defaultLabel, defaultIndex, false, slot];
  }

  /// 仅渲染底部槽位的**内容**（图标 + 文字）。
  ///
  /// 点击 / 长按由 [LiquidBottomBar] 统一接管，选中态的「底」由那块滑动的胶囊
  /// 指示器负责，因此这里不再画自己的底色，也不再包 InkWell —— 否则会出现
  /// 「胶囊滑到 A、A 自己又冒出一块底」的双底。
  Widget _buildTabItem(IconData icon, String label, {required bool selected}) {
    final theme = Theme.of(context);
    final idleColor = theme.colorScheme.onSurface.withValues(alpha: 0.55);
    return Column(
      mainAxisSize: MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(
          icon,
          size: 21,
          color: selected ? theme.colorScheme.primary : idleColor,
        ),
        const SizedBox(height: 2),
        Text(
          label,
          style: TextStyle(
            fontSize: 10.5,
            height: 1.05,
            fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
            color: selected ? theme.colorScheme.primary : idleColor,
          ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ],
    );
  }

  /// 打开由底部槽位承载的**页面**（最近页 / 分类·快捷入口页）。
  ///
  /// 先高亮该槽位并入栈；页面退出后出栈，把高亮还给栈顶槽位（栈空则清除）。
  /// 用栈是为了保证任意时刻只有一个槽位高亮：从槽位 A 的页面里再打开槽位 B 的页面时，
  /// A 让位给 B；B 退出后高亮回到 A。
  void _pushSlotPage(int slot, Widget Function() builder) {
    setState(() {
      _slotPageStack.add(slot);
      _activeBottomSlot = slot;
    });
    ShellNavigator.push<void>(
      context,
      MaterialPageRoute<void>(builder: (_) => builder()),
    ).then((_) {
      if (!mounted) return;
      setState(() {
        _slotPageStack.remove(slot);
        _activeBottomSlot = _slotPageStack.isEmpty ? -1 : _slotPageStack.last;
      });
    });
  }

  /// 打开被自定义的底部槽位：内置页切 IndexedStack；快捷入口执行与分类页网格一致的 action。
  void _openBottomTabEntry(int slot) {
    final cfg = PreferencesService.getBottomTabSlotConfig(slot);
    if (cfg == null) {
      // 默认槽位：第 4 槽默认「最近」（v3.4b2 起替换设置）
      if (slot == 3) {
        // 「最近」页走壳内导航：保留底部 4-tab（与分类页入口一致）。
        _pushSlotPage(
          slot,
          () => AllRecentFilesScreen(onNavigateTab: (i) => _switchTab(i)),
        );
      }
      return;
    }
    final type = cfg['type'];
    final key = cfg['key'];
    if (type == 'builtin') {
      // 内置页：切 IndexedStack 即可，高亮由 _currentIndex 决定（不占用槽位高亮）。
      switch (key) {
        case 'tab_categories':
          _switchTab(0);
          return;
        case 'tab_files':
          _switchTab(1);
          return;
        case 'tab_settings':
          _settingsTabBuilt = true;
          _switchTab(_settingsTabIndex);
          return;
        case 'tab_recent':
          // 最近页走壳内导航（与默认 slot3 一致）。
          _pushSlotPage(
            slot,
            () => AllRecentFilesScreen(onNavigateTab: (i) => _switchTab(i)),
          );
          return;
        default:
          _switchTab(2);
          return;
      }
    }
    if (type == 'custom_entry') {
      _switchTab(0);
      Future.delayed(const Duration(milliseconds: 300), () {
        QuickCategoriesGrid.showCustomizeDialog(context, (index) {
          if (!mounted) return;
          _switchTab(index);
        });
      });
      return;
    }
    final map = QuickCategoriesGrid.getAllCategoriesMap(
      context,
      Theme.of(context).brightness == Brightness.dark,
      (i) => _switchTab(i),
    );
    final entry = map[key];
    if (entry == null) return;
    // 页面型入口（图片 / 视频 / 压缩包等分类）：打开壳内页面并高亮本槽位。
    final pageBuilder = entry['pageBuilder'];
    if (pageBuilder is Widget Function()) {
      _pushSlotPage(slot, pageBuilder);
      return;
    }
    // 动作型入口（系统 / 存储跳浏览页、文件 / 文件夹快捷方式）：不占用槽位高亮，
    // 最终高亮由 action 自身的 _switchTab / openFile 决定，避免与内置 tab 双高亮。
    final action = entry['action'] as VoidCallback?;
    if (action != null) action();
  }

  /// 底部槽位长按选择器：不进自定义快捷方式页即可替换任意槽位。
  Future<void> _showBottomTabPicker(int slot) async {
    final current = PreferencesService.getBottomTabSlotConfig(slot);
    final cfg = await QuickCategoriesGrid.showBottomTabPicker(
      context,
      slot: slot,
      current: current,
    );
    if (cfg == null) return;
    if (cfg['type'] == 'reset') {
      await PreferencesService.saveBottomTabSlotConfig(slot, null);
    } else {
      await PreferencesService.saveBottomTabSlotConfig(slot, cfg);
    }
    if (mounted) setState(() {});
  }

  /// 分类页（快捷操作页）：分类网格 + 自定义快捷方式，顶部/底部由 HomeScreen 统一提供。
  ///
  /// ⚠️ 这里的 `SingleChildScrollView` 是分类页**唯一**的滚动层，而且必须放在
  /// **高度有界**的位置（`LayoutBuilder` 的 `constraints.maxHeight`）。
  /// 踩过的坑：`QuickCategoriesGrid` 顶层是 `Padding > Column`，若把滚动视图塞进
  /// 它内部（Column 的普通子项），它会拿到 maxHeight=∞ ⇒ 可视区高度等于内容高度
  /// ⇒ **永远滚不动**，超出部分被裁掉（表现为「每行 2 列 / 加了更多自定义快捷方式后
  /// 底部卡片看不到、也拉不上来」）。所以滚动与「顶部呼吸位」都由本方法负责，
  /// 网格只按列数输出固定比例的卡片行高。
  ///
  /// 三点约定：
  /// ① 不用 `initialScrollOffset` 去「凑」位置——从 0 开始，顶部只留 4dp 呼吸位，
  ///    卡片紧贴顶部栏（换列数/加减快捷方式都不会再跑偏）；
  /// ② `ClampingScrollPhysics`：安卓原生手感，不回弹就不会把内容画到可视区之外；
  /// ③ 内容不足一屏时没有任何可滚动区间 ⇒ 完全拖不动，不会把卡片拉下来。
  Widget _buildHomeTab() {
    return LayoutBuilder(
      builder: (context, constraints) {
        final grid = QuickCategoriesGrid(
          onNavigateTab: (index) => _switchTab(index),
          showTitle: false,
        );
        // 高度无界（极端嵌套场景）时不套滚动，避免不必要的布局约束冲突。
        if (!constraints.hasBoundedHeight) return grid;
        return SizedBox(
          height: constraints.maxHeight,
          child: SingleChildScrollView(
            physics: const ClampingScrollPhysics(),
            padding: const EdgeInsets.only(top: 4, bottom: 4),
            child: grid,
          ),
        );
      },
    );
  }
}

