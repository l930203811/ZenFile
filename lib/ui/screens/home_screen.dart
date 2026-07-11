import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../../providers/file_manager_provider.dart';
import '../../providers/media_provider.dart';
import '../../core/icon_fonts/broken_icons.dart';
import '../widgets/quick_categories_grid.dart';
import '../widgets/zenfile_drawer.dart';
import '../widgets/zenfile_end_drawer.dart';
import '../widgets/sort_modal.dart';
import 'directory_screen.dart';
import 'package:zenfile/l10n/generated/app_localizations.dart';

class HomeScreen extends StatefulWidget {
  final VoidCallback toggleTheme;
  const HomeScreen({super.key, required this.toggleTheme});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver, SingleTickerProviderStateMixin {
  int _currentIndex = 0;
  DateTime? _lastBackPressTime;
  late AnimationController _refreshIconController;
  bool _isRefreshing = false;
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();
  // 双指滑动检测
  final Map<int, Offset> _activePointers = {};
  Offset? _dualFingerStartCenter;
  // 单指滑动追踪（用 Listener 而非 GestureDetector，避免手势竞技场冲突）
  Offset? _singleFingerStart;
  Offset? _singleFingerLast;
  DateTime? _singleFingerLastTime;
  static const double _dualFingerSwipeThreshold = 30.0;

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
      context.read<MediaProvider>().loadMedia();
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // 检查是否需要从设置页面跳转到浏览标签
    final fileManager = context.read<FileManagerProvider>();
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
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  void _switchTab(int index) {
    if (_currentIndex == index) return;
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    setState(() => _currentIndex = index);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      context.read<MediaProvider>().refreshMediaBackground();
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
          const SnackBar(
            content: Text('仪表盘刷新成功'),
            behavior: SnackBarBehavior.floating,
            duration: Duration(seconds: 1),
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
    final canPopHomeScreen = _currentIndex == 1 && !provider.isSelectionMode && provider.canGoBack;

    return PopScope(
      canPop: canPopHomeScreen,
      onPopInvoked: (didPop) {
        if (didPop) return;
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
        // 浏览页有选中状态时，清除选中而非切换页面
        if (_currentIndex == 1 && provider.isSelectionMode) {
          provider.clearSelection();
          return;
        }
        if (_currentIndex == 1) {
          if (!provider.canGoBack) {
            _switchTab(0);
            context.read<MediaProvider>().refreshMediaBackground();
          }
        } else {
          _handleBackPress(context);
        }
      },
      child: Scaffold(
        key: _scaffoldKey,
        drawer: ZenFileDrawer(
          toggleTheme: widget.toggleTheme,
          onNavigateTab: (index) => _switchTab(index),
          width: MediaQuery.of(context).size.width * 0.75,
        ),
        endDrawer: Drawer(
          width: MediaQuery.of(context).size.width * 0.75,
          backgroundColor: Theme.of(context).scaffoldBackgroundColor,
          shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.only(topLeft: Radius.circular(28), bottomLeft: Radius.circular(28)),
          ),
          child: ZenFileEndDrawer(
            toggleTheme: widget.toggleTheme,
            onRefresh: () {
              _scaffoldKey.currentState?.closeEndDrawer();
              _switchTab(0);
              _handleRefresh();
            },
            onCustomize: () {
              _scaffoldKey.currentState?.closeEndDrawer();
              _switchTab(0);
              Future.delayed(const Duration(milliseconds: 300), () {
                QuickCategoriesGrid.showCustomizeDialog(context, (index) => setState(() => _currentIndex = index));
              });
            },
            onShowSortModal: () {
              _scaffoldKey.currentState?.closeEndDrawer();
              _switchTab(1);
              Future.delayed(const Duration(milliseconds: 300), () {
                final provider = context.read<FileManagerProvider>();
                SortModal.show(context, provider);
              });
            },
            onNavigateToBrowse: () => _switchTab(1),
            searchFolderPath: context.read<FileManagerProvider>().rootPath,
            provider: context.read<FileManagerProvider>(),
          ),
        ),
        body: Consumer<FileManagerProvider>(
          builder: (context, provider, _) {
            return Listener(
              onPointerDown: (event) {
                _activePointers[event.pointer] = event.position;
                if (_activePointers.length == 1) {
                  // 单指开始追踪
                  _singleFingerStart = event.position;
                  _singleFingerLast = event.position;
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
                      // 向左滑动：分类页→浏览页，浏览页→快捷操作页面
                      if (_currentIndex == 0) _switchTab(1);
                      else if (_currentIndex == 1) _scaffoldKey.currentState?.openEndDrawer();
                    } else if (deltaX > _dualFingerSwipeThreshold) {
                      // 向右滑动：快捷操作页面关闭、浏览页→分类页、分类页→抽屉
                      if (_currentIndex == 0) {
                        _scaffoldKey.currentState?.openDrawer();
                      } else if (_currentIndex == 1) {
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
                  // 拖拽操作期间不处理滑动
                  if (fileProvider.isDragging) {
                    // 拖拽中，不处理滑动
                  } else if (fileProvider.enableSingleFingerSwipe) {
                    final screenWidth = MediaQuery.of(context).size.width;
                    final startX = _singleFingerStart!.dx;
                    // 屏幕边缘 48px 留给系统返回手势，不处理
                    if (startX >= 48.0 && startX <= screenWidth - 48.0) {
                      final endPos = _activePointers.values.first;
                      final dx = endPos.dx - _singleFingerStart!.dx;
                      final dy = endPos.dy - _singleFingerStart!.dy;
                      // 垂直滑动主导时不触发左右切换（避免上下滚动误触）
                      if (dy.abs() > dx.abs()) {
                        // 上下滑动，不处理
                      } else {
                        // 最小滑动距离 80px，避免拖拽操作误触
                        if (dx.abs() < 80.0) {
                          // 滑动距离太小，不处理
                        } else {
                          final dt = DateTime.now().difference(_singleFingerLastTime!).inMilliseconds;
                          final velocity = dt > 0 ? (dx / dt) * 1000 : 0.0; // px/s
                          if (velocity < -300) {
                            // 向左滑动：分类页→浏览页，浏览页→快捷操作页面
                            if (_currentIndex == 0) _switchTab(1);
                            else if (_currentIndex == 1) _scaffoldKey.currentState?.openEndDrawer();
                          } else if (velocity > 300) {
                            // 向右滑动：快捷操作页面关闭、浏览页→分类页、分类页→抽屉
                            if (_currentIndex == 0) {
                              _scaffoldKey.currentState?.openDrawer();
                            } else if (_currentIndex == 1) {
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
                }
              },
          child: Consumer<FileManagerProvider>(
            builder: (context, provider, _) {
              return ValueListenableBuilder<bool>(
                valueListenable: provider.navigateToBrowseTabNotifier,
                builder: (context, shouldNavigate, __) {
                  if (shouldNavigate && _currentIndex != 1) {
                    // 使用 microtask 确保在当前 build 完成后立即切换
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
                        onEndDrawerCustomize: () {
                          _switchTab(0);
                          Future.delayed(const Duration(milliseconds: 300), () {
                            QuickCategoriesGrid.showCustomizeDialog(context, (index) => setState(() => _currentIndex = index));
                          });
                        },
                        onRefresh: () => _handleRefresh(),
                      ),
                    ],
                  );
                },
              );
            },
          ),
        );
      },
    ),
  ),
    );
  }

  Widget _buildHomeTab() {
    final theme = Theme.of(context);
    final fileManager = context.watch<FileManagerProvider>();
    final showBottomNav = fileManager.showBottomActionBar;

    Widget buildTopNavRow() {
      return Row(
        children: [
          // 抽屉按钮（靠左）
          IconButton(
            icon: Icon(Broken.sidebar_left, color: theme.colorScheme.primary),
            onPressed: () => _scaffoldKey.currentState?.openDrawer(),
          ),
          const Spacer(),
          // 分类页按钮
          IconButton(
            onPressed: () {
              _switchTab(0);
              context.read<MediaProvider>().refreshMediaBackground();
            },
            tooltip: L10n.of(context).msg6e0f9cef,
            icon: Icon(Broken.category, color: theme.colorScheme.primary),
          ),
          const SizedBox(width: 32),
          // 浏览页按钮
          IconButton(
            onPressed: () => _switchTab(1),
            tooltip: L10n.of(context).ui_browse,
            icon: Icon(Broken.folder, color: theme.colorScheme.primary),
          ),
          const Spacer(),
          // 快捷操作按钮（靠右）
          IconButton(
            icon: Icon(Broken.more_circle, color: theme.colorScheme.primary),
            tooltip: L10n.of(context).msge8b8e9b3,
            onPressed: () => _scaffoldKey.currentState?.openEndDrawer(),
          ),
        ],
      );
    }

    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: showBottomNav
          ? AppBar(
              automaticallyImplyLeading: false,
              surfaceTintColor: Colors.transparent,
              scrolledUnderElevation: 0,
              toolbarHeight: MediaQuery.of(context).padding.top,
            )
          : AppBar(
              automaticallyImplyLeading: false,
              surfaceTintColor: Colors.transparent,
              scrolledUnderElevation: 0,
              titleSpacing: 0,
              centerTitle: true,
              title: buildTopNavRow(),
            ),
      body: Column(
        children: [
          // 可滚动内容区域
          Expanded(
            child: SingleChildScrollView(
              physics: const BouncingScrollPhysics(),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  QuickCategoriesGrid(
                    onNavigateTab: (index) => _switchTab(index),
                    showTitle: false,
                  ),
                  const SizedBox(height: 24),
                ],
              ),
            ),
          ),
        ],
      ),
      // 底部导航栏开启时，四个按钮与顶部布局一致
      bottomNavigationBar: showBottomNav
          ? PreferredSize(
              preferredSize: Size.fromHeight(kToolbarHeight + MediaQuery.of(context).padding.bottom),
              child: Material(
                color: theme.appBarTheme.backgroundColor ?? theme.colorScheme.surface,
                elevation: 8,
                child: SafeArea(
                  top: false,
                  child: SizedBox(
                    height: kToolbarHeight,
                    child: Row(
                      children: [
                        // 抽屉按钮（靠左）
                        IconButton(
                          icon: Icon(Broken.sidebar_left, color: theme.colorScheme.primary),
                          onPressed: () => _scaffoldKey.currentState?.openDrawer(),
                        ),
                        const Spacer(),
                        // 分类页按钮
                        IconButton(
                          onPressed: () {
                            _switchTab(0);
                            context.read<MediaProvider>().refreshMediaBackground();
                          },
                          tooltip: L10n.of(context).msg6e0f9cef,
                          icon: Icon(Broken.category, color: theme.colorScheme.primary),
                        ),
                        const SizedBox(width: 32),
                        // 浏览页按钮
                        IconButton(
                          onPressed: () => _switchTab(1),
                          tooltip: L10n.of(context).ui_browse,
                          icon: Icon(Broken.folder, color: theme.colorScheme.primary),
                        ),
                        const Spacer(),
                        // 快捷操作按钮（靠右）
                        IconButton(
                          icon: Icon(Broken.more_circle, color: theme.colorScheme.primary),
                          tooltip: L10n.of(context).msge8b8e9b3,
                          onPressed: () => _scaffoldKey.currentState?.openEndDrawer(),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            )
          : null,
    );
  }
}

