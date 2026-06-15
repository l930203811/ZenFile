import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../../providers/file_manager_provider.dart';
import '../../providers/media_provider.dart';
import '../../core/icon_fonts/broken_icons.dart';
import '../../core/utils.dart';
import '../widgets/quick_categories_grid.dart';
import '../widgets/zenfile_drawer.dart';
import 'directory_screen.dart';
import 'storage_analyzer/storage_analyzer_screen.dart';
import 'package:zenfile/l10n/generated/app_localizations.dart';

class HomeScreen extends StatefulWidget {
  final VoidCallback toggleTheme;
  const HomeScreen({super.key, required this.toggleTheme});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver, SingleTickerProviderStateMixin {
  int _currentIndex = 0;
  DateTime? _lastBrowseTapTime;
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
            content: Text('L10n.of(context).msge109d1ea'),
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
          content: const Text('L10n.of(context).msg05cea075', style: TextStyle(fontSize: 14)),
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 2),
          margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ),
      );
    }
  }

  void _showExitConfirmationDialog(BuildContext context) {
    showGeneralDialog(
      context: context,
      barrierDismissible: true,
      barrierLabel: '退出确认',
      barrierColor: Colors.black.withOpacity(0.5),
      transitionDuration: const Duration(milliseconds: 300),
      pageBuilder: (context, anim1, anim2) {
        return const SizedBox.shrink();
      },
      transitionBuilder: (context, anim1, anim2, child) {
        final theme = Theme.of(context);
        return ScaleTransition(
          scale: CurvedAnimation(parent: anim1, curve: Curves.easeOutBack),
          child: FadeTransition(
            opacity: anim1,
            child: PopScope(
              canPop: false,
              onPopInvoked: (didPop) {
                if (didPop) return;
                SystemNavigator.pop();
              },
              child: AlertDialog(
                backgroundColor: theme.colorScheme.surface,
                elevation: 10,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
                title: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: theme.colorScheme.errorContainer.withOpacity(0.2),
                        shape: BoxShape.circle,
                      ),
                      child: Icon(
                        Broken.logout,
                        color: theme.colorScheme.error,
                        size: 32,
                      ),
                    ),
                    const SizedBox(height: 16),
                    Text(
                      'L10n.of(context).msg7498c202',
                      style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold),
                    ),
                  ],
                ),
                content: const Text(
                  'L10n.of(context).msg03247b17',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 15, height: 1.4),
                ),
                actionsAlignment: MainAxisAlignment.spaceEvenly,
                actionsPadding: const EdgeInsets.only(bottom: 20, left: 16, right: 16),
                actions: [
                  OutlinedButton(
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                    ),
                    onPressed: () => Navigator.pop(context),
                    child: const Text('取消', style: TextStyle(fontWeight: FontWeight.bold)),
                  ),
                  ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: theme.colorScheme.error,
                      foregroundColor: theme.colorScheme.onError,
                      padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 12),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                      elevation: 0,
                    ),
                    onPressed: () => SystemNavigator.pop(),
                    child: const Text('退出', style: TextStyle(fontWeight: FontWeight.bold)),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
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
                      if (_currentIndex == 0) _switchTab(1);
                    } else if (deltaX > _dualFingerSwipeThreshold) {
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
                            if (_currentIndex == 0) _switchTab(1);
                          } else if (velocity > 300) {
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
    return SafeArea(
      child: Column(
        children: [
          // 固定顶部按钮栏（紧凑）
          Padding(
            padding: const EdgeInsets.only(left: 4.0, right: 8.0, top: 2.0, bottom: 2.0),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                // 左侧：抽屉菜单按钮 + 分类按钮 + 浏览按钮
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Builder(
                      builder: (context) => IconButton(
                        icon: Icon(Broken.sidebar_left, color: theme.colorScheme.primary),
                        onPressed: () => Scaffold.of(context).openDrawer(),
                      ),
                    ),
                    // 分类按钮（点击切换到首页）
                    IconButton(
                      onPressed: () {
                        _switchTab(0);
                        context.read<MediaProvider>().refreshMediaBackground();
                      },
                      tooltip: 'L10n.of(context).msg6e0f9cef',
                      icon: Icon(
                        Broken.category,
                        color: theme.colorScheme.primary,
                      ),
                    ),
                    // 浏览按钮（点击切换到浏览页）
                    IconButton(
                      onPressed: () {
                        _switchTab(1);
                      },
                      tooltip: '浏览',
                      icon: Icon(
                        Broken.folder,
                        color: theme.colorScheme.primary,
                      ),
                    ),
                  ],
                ),
                // 右侧：刷新、主题切换、自定义按钮
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      onPressed: _handleRefresh,
                      tooltip: 'L10n.of(context).msg354c1c9a',
                      icon: RotationTransition(
                        turns: _refreshIconController,
                        child: Icon(Broken.refresh, color: theme.colorScheme.primary),
                      ),
                    ),
                    IconButton(
                      onPressed: widget.toggleTheme,
                      icon: Icon(
                        theme.brightness == Brightness.dark ? Broken.sun_1 : Broken.moon,
                        color: theme.colorScheme.primary,
                      ),
                    ),
                    IconButton(
                      onPressed: () => QuickCategoriesGrid.showCustomizeDialog(context, (index) => setState(() => _currentIndex = index)),
                      tooltip: 'L10n.of(context).msg19021d08',
                      icon: Icon(Broken.edit_2, color: theme.colorScheme.primary),
                    ),
                  ],
                ),
              ],
            ),
          ),
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
    );
  }

  /// 首页存储分析区域
  Widget _buildStorageAnalysisSection() {
    final theme = Theme.of(context);
    final provider = context.watch<FileManagerProvider>();
    final total = provider.totalStorageBytes > 0 ? provider.totalStorageBytes : 128 * 1024 * 1024 * 1024;
    final used = provider.usedStorageBytes > 0 ? provider.usedStorageBytes : 0;
    final free = total - used;
    final usedPercent = total > 0 ? (used / total) * 100 : 0.0;
    final freeStr = FileUtils.formatBytes(free, 1);
    final totalStr = FileUtils.formatBytes(total, 1);
    final accentColor = usedPercent > 90 ? Colors.redAccent : theme.colorScheme.primary;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16.0),
      child: GestureDetector(
        onTap: () {
          Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => const StorageAnalyzerScreen()),
          );
        },
        onLongPress: () {
          Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => const StorageAnalyzerScreen()),
          );
        },
        child: Container(
          height: 80,
          padding: const EdgeInsets.symmetric(horizontal: 14.0, vertical: 6.0),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [accentColor.withOpacity(0.7), accentColor.withOpacity(0.5)],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            borderRadius: BorderRadius.circular(16),
            boxShadow: [
              BoxShadow(
                color: accentColor.withOpacity(0.15),
                blurRadius: 8,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Row(
            children: [
              // 左侧图标
              Container(
                padding: const EdgeInsets.all(4),
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.15),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(Broken.driver_2, color: Colors.white, size: 16),
              ),
              const SizedBox(width: 10),
              // 中间信息
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      '${FileUtils.formatBytes(used, 1)} 已用',
                      style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 12),
                    ),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        Expanded(
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(3),
                            child: LinearProgressIndicator(
                              value: total > 0 ? used / total : 0,
                              minHeight: 4,
                              backgroundColor: Colors.white.withOpacity(0.2),
                              valueColor: const AlwaysStoppedAnimation<Color>(Colors.white),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text('$freeStr 可用', style: TextStyle(color: Colors.white.withOpacity(0.8), fontSize: 9)),
                        const SizedBox(width: 4),
                        Text('/ $totalStr', style: TextStyle(color: Colors.white.withOpacity(0.5), fontSize: 9)),
                      ],
                    ),
                  ],
                ),
              ),
              // 右侧详情按钮
              GestureDetector(
                onTap: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const StorageAnalyzerScreen()),
                  );
                },
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.2),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text('详情', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 11)),
                      const SizedBox(width: 2),
                      Icon(Broken.arrow_right_3, color: Colors.white, size: 11),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

