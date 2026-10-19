import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:path/path.dart' as p;
import '../../providers/file_manager_provider.dart';
import '../../providers/media_provider.dart';
import '../../models/file_item_model.dart';
import '../widgets/file_item.dart';
import '../widgets/folder_item.dart';
import '../widgets/file_action_dialogs.dart';
import '../widgets/batch_rename_dialog.dart';
import '../../core/icon_fonts/broken_icons.dart';
import '../../services/folder_share_service.dart';
import '../widgets/directory_tab_bar.dart';
import '../../core/utils.dart';
import '../widgets/selection_action_bar.dart';
import '../widgets/feature_search_index.dart';
import 'package:zenfile/l10n/generated/app_localizations.dart';

class GlobalSearchScreen extends StatefulWidget {
  final String? searchFolderPath;
  const GlobalSearchScreen({super.key, this.searchFolderPath});

  @override
  State<GlobalSearchScreen> createState() => _GlobalSearchScreenState();
}

class _GlobalSearchScreenState extends State<GlobalSearchScreen> {
  final TextEditingController _searchController = TextEditingController();
  String _query = '';
  String? _selectedFilter; // All, Folders, Images, Videos, Audio, Documents
  
  List<FileItemModel> _results = [];
  bool _isSearching = false;
  StreamSubscription<void>? _searchSubscription;
  // 搜索防抖：避免在低端机上每输入一个字符就同步遍历整个媒体库，造成输入卡顿。
  Timer? _searchDebounceTimer;

  /// 搜索结果分片缓冲（见 [_queueResult]）：逐条 setState 会让结果列表在
  /// 一次全盘搜索里被重建上千次，是「文件越多越卡」的主因之一。
  final List<FileItemModel> _pendingResults = <FileItemModel>[];
  Timer? _resultFlushTimer;

  /// 搜索代次：每次新搜索自增，旧搜索的分片解析凭代次自我了断。
  int _searchGeneration = 0;

  /// 媒体索引的「小写文件名」快照（见 [_ensureMediaNameIndex]）。
  List<({String path, String lowerName})>? _mediaNameIndex;

  /// 缓存的 Provider 引用（initState 里赋值）。
  ///
  /// ⚠️ `dispose()` 里**绝不能**再走 `context.read<...>()`：此时 Element 已
  /// defunct（`_widget == null`），provider 找不到祖先会去求值
  /// `context.widget.runtimeType` 抛 `ProviderNotFoundException`，而该求值本身
  /// 先炸成「Null check operator used on a null value」（provider 6.1.5
  /// `provider.dart:377`）—— 2026-09-25 用户取证报告连报 12 次的就是它。
  late final FileManagerProvider _fileManager;

  final Set<String> _selectedPaths = {};
  bool get _isSelectionMode => _selectedPaths.isNotEmpty;

  /// 功能入口清单（设置页 / 左右抽屉），随语言变化在 didChangeDependencies 重建。
  List<FeatureSearchEntry> _featureIndex = const <FeatureSearchEntry>[];

  /// 当前查询命中的功能入口（展示在文件结果之前）。
  List<FeatureSearchEntry> _featureResults = const <FeatureSearchEntry>[];

  int get _totalSelectedSize {
    int total = 0;
    for (final path in _selectedPaths) {
      final item = _results.firstWhere(
        (e) => e.path == path,
        orElse: () => FileItemModel(
          entity: File(path),
          name: '',
          path: path,
          isDirectory: false,
          size: 0,
          modified: DateTime.now(),
        ),
      );
      total += item.size;
    }
    return total;
  }

  String? _searchFolderPath;
  String? _lastActivePath;

  List<String> get _filters => [
    L10n.of(context).ui_all,
    L10n.of(context).ui_folders,
    L10n.of(context).ui_images,
    L10n.of(context).ui_videos,
    L10n.of(context).ui_audio,
    L10n.of(context).ui_documents,
  ];

  @override
  void initState() {
    super.initState();
    final fileProvider = context.read<FileManagerProvider>();
    _fileManager = fileProvider;
    // 默认从「当前所在文件夹」开始搜索（与 ES 一致：在隐私系统/子文件夹内打开搜索即搜该目录），
    // 仅在处于存储根目录时才退化为全设备全局搜索。
    // 修复：vivo 隐私系统文件夹从 /storage/emulated/0 全局递归搜不到（需从当前所在路径才能列目录）。
    final current = fileProvider.currentPath;
    _searchFolderPath = widget.searchFolderPath ??
        (current.isNotEmpty ? current : '/storage/emulated/0');
    _lastActivePath = fileProvider.currentPath;
    fileProvider.addListener(_onFileManagerChanged);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // 初始化默认过滤器为"全部"（需在 didChangeDependencies 中执行，因为依赖 L10n）
    _selectedFilter ??= L10n.of(context).ui_all;
    // 功能入口清单（设置 / 左右抽屉）依赖 L10n，在这里构建并缓存 ——
    // 纯内存匹配不需要每次输入都重建清单。
    _featureIndex = FeatureSearchIndex.build(context);
  }

  @override
  void dispose() {
    _searchDebounceTimer?.cancel();
    _resultFlushTimer?.cancel();
    _searchSubscription?.cancel();
    _searchController.dispose();
    // 用缓存的引用注销监听：此处 context 已失效，不能再 read（会抛 NPE）。
    _fileManager.removeListener(_onFileManagerChanged);
    super.dispose();
  }

  void _onFileManagerChanged() {
    if (!mounted) return;
    final fileProvider = _fileManager;
    final newPath = fileProvider.currentPath;
    if (newPath != _lastActivePath) {
      _lastActivePath = newPath;
      setState(() {
        _searchFolderPath = newPath;
      });
      _executeSearch();
    } else {
      setState(() {});
    }
  }

  void _onSearchChanged(String value) {
    final queryLower = value.trim().toLowerCase();
    setState(() {
      _query = value.trim();
      // 功能入口是纯内存匹配，立即出结果、不参与防抖（否则会先闪一下"无结果"）。
      _featureResults = queryLower.isEmpty
          ? const <FeatureSearchEntry>[]
          : _featureIndex
                .where((entry) => entry.matches(queryLower))
                .toList();
    });
    // 防抖：用户连续输入时只在停顿后才真正执行搜索，避免每个字符都遍历整个媒体库导致输入卡顿。
    _searchDebounceTimer?.cancel();
    // 280ms：键盘弹出动画本身约 250ms，防抖若短于它，全盘扫描会在动画
    // 中途启动，直接把输入法的帧挤掉（用户反馈的「一弹键盘就卡」）。
    _searchDebounceTimer = Timer(const Duration(milliseconds: 280), _executeSearch);
  }

  void _onFilterChanged(String filter) {
    setState(() {
      _selectedFilter = filter;
    });
    _executeSearch();
  }

  void _executeSearch() {
    _searchDebounceTimer?.cancel();
    _searchSubscription?.cancel();
    _cancelResultFlush();
    _clearSelection();
    // 代次：每次新搜索自增。旧搜索里正在分片解析的结果凭代次丢弃，
    // 否则「先输 a 再输 ab」时 a 的结果会在 ab 的列表里冒出来。
    final gen = ++_searchGeneration;
    if (_query.isEmpty) {
      setState(() {
        _results = [];
        _isSearching = false;
      });
      return;
    }

    setState(() {
      _results = [];
      _isSearching = true;
    });

    final Set<String> seenPaths = {};
    final List<FileItemModel> currentBatch = [];
    final mediaProvider = context.read<MediaProvider>();
    final fileProvider = context.read<FileManagerProvider>();

    final qLower = _query.toLowerCase();
    final l10n = L10n.of(context);
    final allFilter = _selectedFilter == l10n.ui_all;
    final docFilter = _selectedFilter == l10n.ui_documents;

    final isGlobal = _searchFolderPath == null ||
        _searchFolderPath == '/storage/emulated/0' ||
        _searchFolderPath == '/';

    final rootPath = isGlobal
        ? (Platform.isAndroid ? '/storage/emulated/0' : fileProvider.currentPath)
        : _searchFolderPath!;

    // 1) 媒体索引（纯内存）匹配。
    //
    // ⚠️ 这里是「打字卡顿」的第一处热点：旧实现对整份索引逐个
    // `p.basename()`（内部 split 出整条路径分段）+ `toLowerCase()`，大存储
    // 设备上索引可达数万条，每敲一个字都要重算一遍。改为在一份**缓存好的
    // 小写文件名快照**上做纯 contains，索引本身变化时（长度变化）才重建。
    if (allFilter || docFilter) {
      // ⚠️ 只取一次：`documents` 是**每次访问都重新过滤 + 新建列表**的 getter
      // （噪音过滤 / 排除目录 / 自定义目录逐条判断）。写在循环条件里会变成
      // O(n²) —— 几万条索引时一次搜索就能把界面按住好几秒。
      final docs = mediaProvider.documents;
      final nameIndex = _ensureMediaNameIndex(docs);
      final matchedDocs = <FileSystemEntity>[];
      for (var i = 0; i < nameIndex.length; i++) {
        final e = nameIndex[i];
        if (!e.lowerName.contains(qLower)) continue;
        if (!isGlobal && !e.path.startsWith(rootPath)) continue;
        if (!seenPaths.add(e.path)) continue;
        matchedDocs.add(docs[i]);
      }
      // 命中项**分片**解析（每片 40 个，片间让出事件循环）。
      // 旧实现用 `Future.wait` 一次性给所有命中项 stat：输一个「a」可能同时
      // 抛出上万个 stat，IO 与主 isolate 一起饱和 —— 键盘动画自然掉帧。
      if (matchedDocs.isNotEmpty) {
        unawaited(_resolveDocsInChunks(matchedDocs, gen));
      }
    }

    if (allFilter || _selectedFilter == l10n.ui_audio) {
      for (final song in mediaProvider.audios) {
        final path = song.data;
        if (!isGlobal && !path.startsWith(rootPath)) continue;
        final name = p.basename(path);
        if (!seenPaths.add(path)) continue;
        if (!name.toLowerCase().contains(qLower)) continue;
        currentBatch.add(FileItemModel(
          entity: File(path),
          name: song.title,
          path: path,
          isDirectory: false,
          size: song.size,
          modified: DateTime.fromMillisecondsSinceEpoch((song.dateModified ?? 0) * 1000),
        ));
      }
    }

    // Update state instantly with cached media results
    if (currentBatch.isNotEmpty) {
      setState(() {
        _results = List.from(currentBatch);
      });
    }

    // 2. 自定义递归搜索，跳过无权限目录继续搜索其他目录
    _searchSubscription = _recursiveSearch(
      rootPath: rootPath,
      qLower: qLower,
      isGlobal: isGlobal,
      rootPathFilter: rootPath,
      seenPaths: seenPaths,
      onResult: _queueResult,
      onDone: () {
        if (mounted) {
          // 收尾时立刻把缓冲区里剩下的结果刷出去，不必等 90ms 的节流窗口。
          _flushResults();
          setState(() {
            _isSearching = false;
          });
        }
      },
      onError: (e) {
        debugPrint('搜索文件系统时出错: $e');
      },
    );
  }

  /// 媒体索引的「小写文件名」快照，避免每次按键都对整份索引做 basename/小写。
  ///
  /// 失效判据只看长度：媒体列表的变化（刷新 / 后台扫到新文件）几乎必然伴随
  /// 数量变化；即便某次数量恰好不变，最坏也只是少显示几条索引结果，
  /// 递归搜索仍会补齐 —— 用完整内容比对换这点精度不值得（那是 O(n) 且要分配）。
  List<({String path, String lowerName})> _ensureMediaNameIndex(
    List<FileSystemEntity> docs,
  ) {
    final cached = _mediaNameIndex;
    if (cached != null && cached.length == docs.length) return cached;
    final built = List<({String path, String lowerName})>.generate(
      docs.length,
      (i) {
        final path = docs[i].path;
        // 只取最后一段，避免 p.basename 内部的整条路径 split。
        final slash = path.lastIndexOf('/');
        final name = slash < 0 ? path : path.substring(slash + 1);
        return (path: path, lowerName: name.toLowerCase());
      },
      growable: false,
    );
    _mediaNameIndex = built;
    return built;
  }

  /// 分片解析媒体索引命中项（每片 40 个，片间让出一拍）。
  ///
  /// 上限 400：命中成千上万时继续 stat 只是把 IO 打满，用户根本翻不到那么远，
  /// 后面的结果交给递归搜索按需补齐。
  Future<void> _resolveDocsInChunks(List<FileSystemEntity> docs, int gen) async {
    const int chunkSize = 40;
    const int maxResolve = 400;
    final total = math.min(docs.length, maxResolve);
    for (var start = 0; start < total; start += chunkSize) {
      if (!mounted || gen != _searchGeneration) return;
      final end = math.min(start + chunkSize, total);
      for (var i = start; i < end; i++) {
        try {
          final item = await FileItemModel.fromEntityAsync(docs[i]);
          if (!mounted || gen != _searchGeneration) return;
          _queueResult(item);
        } catch (_) {}
      }
      await Future<void>.delayed(Duration.zero);
    }
  }

  /// 结果批量回填。
  ///
  /// 旧实现每命中一条就 `setState` 一次：一次全盘搜索动辄上千条命中 ⇒ 结果
  /// 列表被重建上千次，每一次都要重跑整个 `build`（含 AppBar 的
  /// `DirectoryTabBar`、筛选条、空状态判断）。这就是「文件越多越卡」的第二处
  /// 热点。改成先进缓冲区，最多每 90ms 刷一次。
  void _queueResult(FileItemModel item) {
    _pendingResults.add(item);
    _resultFlushTimer ??= Timer(
      const Duration(milliseconds: 90),
      _flushResults,
    );
  }

  void _flushResults() {
    // 只清计时器，不能顺手清缓冲区 —— 下面正要把缓冲区刷进列表。
    _resultFlushTimer?.cancel();
    _resultFlushTimer = null;
    if (!mounted || _pendingResults.isEmpty) return;
    final batch = List<FileItemModel>.of(_pendingResults);
    _pendingResults.clear();
    setState(() {
      _results.addAll(batch);
    });
  }

  void _cancelResultFlush() {
    _resultFlushTimer?.cancel();
    _resultFlushTimer = null;
    _pendingResults.clear();
  }

  /// 自定义递归搜索，跳过无权限目录继续搜索其他目录
  ///
  /// 并发上限 [maxConcurrentDirs]：旧实现完全没有节流 —— 每进一个目录就
  /// `activeTasks++` 并立刻再发 6 个，全盘搜索会瞬间拉起成百上千个
  /// `dir.list()`，IO 队列与主 isolate 一起饱和。表现就是「一边输入一边卡、
  /// 键盘收起也卡」，文件越多越严重。
  StreamSubscription<void> _recursiveSearch({
    required String rootPath,
    required String qLower,
    required bool isGlobal,
    required String rootPathFilter,
    required Set<String> seenPaths,
    required void Function(FileItemModel) onResult,
    required VoidCallback onDone,
    required void Function(dynamic) onError,
  }) {
    var isCancelled = false;
    var running = 0;
    var closed = false;
    const int maxConcurrentDirs = 6;
    final pendingDirs = <String>[];

    // ⚠️ 取消必须落到递归本身。旧实现没有 `onCancel`：搜索词一变只是把订阅
    // 丢掉，旧的递归仍在跑、仍在 setState 把旧结果塞进列表 ⇒ 每按一次键就多
    // 一条全盘遍历，越输越卡，结果还会串。
    final controller = StreamController<void>(
      onCancel: () {
        isCancelled = true;
        pendingDirs.clear();
      },
    );

    void closeIfIdle() {
      if (closed || isCancelled) return;
      if (running == 0 && pendingDirs.isEmpty) {
        closed = true;
        controller.close();
      }
    }

    Future<void> scanDirectory(String dirPath) async {
      // 先把依赖 context 的对象取出来：下面一进 enumerate 就跨过异步边界，
      // 之后再碰 context 会触发 use_build_context_synchronously（且真有失效风险）。
      final fileProvider = context.read<FileManagerProvider>();
      final l10n = L10n.of(context);
      final currentFilter = _selectedFilter;
      try {
        // 受限路径（其它应用的 Android/data、Android/obb）不能走 Dart IO 直列，
        // 统一交给 provider 的多通道枚举（shell → 标准路径 → 变形路径 → 底层路径）。
        List<(String path, bool isDir, FileItemModel? prebuilt)> entries;

        if (fileProvider.isRestrictedPath(dirPath)) {
          // 受限目录（其它应用的 Android/{data,obb}）：走 provider 的多通道枚举。
          // 旧实现要求 root/Shizuku 可用，否则**整个目录直接跳过** ——
          // 「无需授权直访」模式下全局搜索在 Android/data 里恒为空结果（真机反馈）。
          final items = await fileProvider.listRestrictedChildItems(
            dirPath,
            showHidden: fileProvider.showHiddenFiles,
          );
          entries = [for (final it in items) (it.path, it.isDirectory, it)];
        } else {
          final dir = Directory(dirPath);
          if (!await dir.exists()) return;
          final entities = await dir.list(followLinks: false).toList();
          entries = [for (final e in entities) (e.path, e is Directory, null)];
        }
        if (isCancelled) return;

        for (final (path, isDir, prebuilt) in entries) {
          if (isCancelled) return;
          final name = p.basename(path);

          // 检查文件名是否匹配搜索词
          if (name.toLowerCase().contains(qLower)) {
            bool matchFilter = false;
            if (currentFilter == l10n.ui_all) {
              matchFilter = true;
            } else if (currentFilter == l10n.ui_folders && isDir) {
              matchFilter = true;
            } else if (currentFilter == l10n.ui_images && !isDir && _isImage(name)) {
              matchFilter = true;
            } else if (currentFilter == l10n.ui_videos && !isDir && _isVideo(name)) {
              matchFilter = true;
            } else if (currentFilter == l10n.ui_audio && !isDir && _isAudio(name)) {
              matchFilter = true;
            } else if (currentFilter == l10n.ui_documents && !isDir && _isDoc(name)) {
              matchFilter = true;
            }

            if (matchFilter && !seenPaths.contains(path)) {
              seenPaths.add(path);
              try {
                // 受限条目在枚举阶段已构造好（不能再用 Dart IO stat）；
                // 普通条目保持惰性 stat，只在命中搜索词时才解析元数据。
                final item = prebuilt ??
                    await FileItemModel.fromEntityAsync(
                      isDir ? Directory(path) : File(path),
                    );
                if (!isCancelled) {
                  onResult(item);
                }
              } catch (e) {
                debugPrint('解析文件 $path 时出错: $e');
              }
            }
          }

          // 目录入队，由 [pump] 按并发上限逐个展开（不在这里直接递归）。
          if (isDir) pendingDirs.add(path);
        }
      } catch (e) {
        if (!isCancelled) {
          debugPrint('搜索目录 $dirPath 时出错: $e');
          onError(e);
        }
      }
    }

    void pump() {
      if (isCancelled) return;
      while (running < maxConcurrentDirs && pendingDirs.isNotEmpty) {
        final dirPath = pendingDirs.removeAt(0);
        running++;
        // 用 try/finally 保证 running 一定回收：漏减一次就再也不会 close，
        // 界面会永远停在「搜索中」。
        unawaited(() async {
          try {
            await scanDirectory(dirPath);
          } catch (_) {
          } finally {
            running--;
          }
          if (isCancelled) return;
          pump();
          closeIfIdle();
        }());
      }
      closeIfIdle();
    }

    pendingDirs.add(rootPath);
    pump();

    return controller.stream.listen(
      (_) {},
      onDone: () {
        if (!isCancelled) {
          onDone();
        }
      },
      onError: onError,
    );
  }

  // 以下 4 个类型判定统一走 FileUtils.effectiveExtensionWithDot：
  // 它会忽略 IM（QQ / 微信）追加的序号后缀（`a.jpg.1` → `.jpg`），
  // 否则被 IM 传过的文件在搜索结果里会被归到「其他」。

  bool _isImage(String name) {
    final ext = FileUtils.effectiveExtensionWithDot(name);
    return ['.jpg', '.jpeg', '.png', '.gif', '.webp', '.bmp', '.heic', '.avif'].contains(ext);
  }

  bool _isVideo(String name) {
    final ext = FileUtils.effectiveExtensionWithDot(name);
    return ['.mp4', '.mkv', '.avi', '.mov', '.wmv', '.flv', '.webm', '.ts'].contains(ext);
  }

  bool _isAudio(String name) {
    final ext = FileUtils.effectiveExtensionWithDot(name);
    return ['.mp3', '.m4a', '.wav', '.flac', '.aac', '.ogg', '.opus', '.amr'].contains(ext);
  }

  bool _isDoc(String name) {
    final ext = FileUtils.effectiveExtensionWithDot(name);
    return ['.pdf', '.doc', '.docx', '.xls', '.xlsx', '.ppt', '.pptx', '.txt', '.csv'].contains(ext);
  }

  // --- Multi-Selection logic ---
  void _toggleSelection(String path) {
    setState(() {
      if (_selectedPaths.contains(path)) {
        _selectedPaths.remove(path);
      } else {
        _selectedPaths.add(path);
      }
    });
  }

  void _selectAll() {
    setState(() {
      for (final item in _results) {
        _selectedPaths.add(item.path);
      }
    });
  }

  void _clearSelection() {
    setState(() {
      _selectedPaths.clear();
    });
  }

  void _handleCopySelected() {
    if (_selectedPaths.isEmpty) return;
    context.read<FileManagerProvider>().setClipboard(_selectedPaths.toList(), isCut: false);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(L10n.of(context).ui_copied_n_items(_selectedPaths.length))),
    );
    _clearSelection();
  }

  void _handleCutSelected() {
    if (_selectedPaths.isEmpty) return;
    context.read<FileManagerProvider>().setClipboard(_selectedPaths.toList(), isCut: true);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(L10n.of(context).ui_cut_n_items(_selectedPaths.length))),
    );
    _clearSelection();
  }

  Future<void> _handleShareSelected() async {
    if (_selectedPaths.isEmpty) return;
    await FolderShareService.sharePaths(context, _selectedPaths.toList());
    _clearSelection();
  }

  Future<void> _handleRenameSelected() async {
    if (_selectedPaths.isEmpty) return;
    final provider = context.read<FileManagerProvider>();
    await showDialog<void>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.55),
      builder: (context) => BatchRenameDialog(
        provider: provider,
        selectedPaths: _selectedPaths.toList(),
      ),
    );
    _clearSelection();
    _executeSearch();
  }

  Future<void> _handleDeleteSelected() async {
    if (_selectedPaths.isEmpty) return;
    final confirm = await FileActionDialogs.showDeleteConfirmDialog(
      context,
      title: L10n.of(context).msgcd0b9aca,
      content: 'Are you sure you want to delete ${_selectedPaths.length} selected item(s)? This cannot be undone.',
    );

    if (confirm) {
      final provider = context.read<FileManagerProvider>();
      final toDelete = _selectedPaths.toList();
      try {
        for (final path in toDelete) {
          await provider.deleteFile(path);
          setState(() {
            _results.removeWhere((e) => e.path == path);
          });
        }
        _clearSelection();
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(L10n.of(context).msg45326802)));
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(L10n.of(context).e17(e))));
        }
      }
    }
  }

  void _handleAction(BuildContext context, String action, String path) async {
    final provider = context.read<FileManagerProvider>();
    switch (action) {
      case 'show_in_location':
        // 使用与"查看远程缓存目录"相同的导航模式，确保从任何页面
        // 都能正确切换到浏览 Tab 并定位文件
        provider.setNavigateToBrowseTab(true);
        Navigator.of(context).popUntil((route) => route.isFirst);
        scheduleMicrotask(() {
          provider.showFileInLocation(path);
        });
        break;
      case 'properties':
        if (context.mounted) {
          showDialog(
            context: context,
            builder: (ctx) => PropertiesModalDialog(
              selectedPaths: [path],
              provider: provider,
            ),
          );
        }
        break;
      case 'open_with':
        provider.showOpenWithSheet(context, path);
        break;
      case 'share':
        final isMulti = _selectedPaths.isNotEmpty && _selectedPaths.contains(path);
        final paths = isMulti ? _selectedPaths.toList() : [path];
        await FolderShareService.sharePaths(context, paths);
        if (isMulti) {
          _clearSelection();
        }
        break;
      case 'copy':
        provider.copyFile(path);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(L10n.of(context).msg4fb42e6e)));
        break;
      case 'cut':
        provider.cutFile(path);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(L10n.of(context).msge5212c58)));
        break;
      case 'rename':
        final isMulti = _selectedPaths.isNotEmpty && _selectedPaths.contains(path);
        if (isMulti && _selectedPaths.length > 1) {
          await showDialog<void>(
            context: context,
            barrierColor: Colors.black.withValues(alpha: 0.55),
            builder: (context) => BatchRenameDialog(
              provider: provider,
              selectedPaths: _selectedPaths.toList(),
            ),
          );
          _clearSelection();
          _executeSearch();
        } else {
          final currentName = p.basename(path);
          final newName = await FileActionDialogs.showRenameDialog(
            context,
            currentName: currentName,
            title: L10n.of(context).msgc8ce4b36,
            hint: L10n.of(context).msgf139c5cf,
            actionText: L10n.of(context).msgc8ce4b36,
          );
          if (newName != null && newName.isNotEmpty) {
            try {
              await provider.renameFile(path, newName);
            } catch (e) {
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(L10n.of(context).e25(e))));
              }
              return;
            }
            if (isMulti) {
              _clearSelection();
            }
            _executeSearch(); // refresh
          }
        }
        break;
      case 'delete':
        final isMulti = _selectedPaths.isNotEmpty && _selectedPaths.contains(path);
        final confirm = await FileActionDialogs.showDeleteConfirmDialog(
          context,
          title: isMulti ? L10n.of(context).msgcd0b9aca : L10n.of(context).msg53518c22,
          content: isMulti
              ? L10n.of(context).ui_delete_items_confirm(_selectedPaths.length)
              : L10n.of(context).ui_delete_item_confirm,
        );
        if (confirm) {
          try {
            if (isMulti) {
              final toDelete = _selectedPaths.toList();
              for (final p in toDelete) {
                await provider.deleteFile(p);
                setState(() {
                  _results.removeWhere((e) => e.path == p);
                });
              }
              _clearSelection();
            } else {
              await provider.deleteFile(path);
              setState(() {
                _results.removeWhere((e) => e.path == path);
              });
            }
          } catch (e) {
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(L10n.of(context).e17(e))));
            }
          }
        }
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final fileProvider = context.read<FileManagerProvider>();
    final isGlobal = _searchFolderPath == null ||
                     _searchFolderPath == '/storage/emulated/0' ||
                     _searchFolderPath == '/';

    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      appBar: AppBar(
        elevation: 0,
        backgroundColor: theme.colorScheme.surface,
        leading: _isSelectionMode
            ? IconButton(
                icon: const Icon(Broken.close_square),
                onPressed: _clearSelection,
              )
            : IconButton(
                icon: const Icon(Broken.arrow_left),
                onPressed: () => Navigator.pop(context),
              ),
        title: _isSelectionMode
            ? Text(
                L10n.of(context).ui_n_selected(_selectedPaths.length, FileUtils.formatBytes(_totalSelectedSize, 1)),
                style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
              )
            : TextField(
                controller: _searchController,
                autofocus: true,
                onChanged: _onSearchChanged,
                style: theme.textTheme.titleMedium,
                decoration: InputDecoration(
                  hintText: isGlobal ? L10n.of(context).ui_global_search : L10n.of(context).msgf2ef53c0,
                  hintStyle: TextStyle(color: theme.colorScheme.onSurface.withAlpha(102)),
                  border: InputBorder.none,
                  suffixIcon: _query.isNotEmpty
                      ? IconButton(
                          icon: const Icon(Broken.close_square, size: 20),
                          onPressed: () {
                            _searchController.clear();
                            _onSearchChanged('');
                          },
                        )
                      : null,
                ),
              ),
        bottom: (_isSelectionMode || !fileProvider.enableMultipleTabs)
            ? null
            : DirectoryTabBar(provider: fileProvider),
        actions: _isSelectionMode
            ? [
                IconButton(
                  icon: const Icon(Broken.document_copy),
                  tooltip: L10n.of(context).ui_copy_tooltip,
                  onPressed: _handleCopySelected,
                ),
                IconButton(
                  icon: const Icon(Broken.scissor),
                  tooltip: L10n.of(context).ui_cut_tooltip,
                  onPressed: _handleCutSelected,
                ),
                IconButton(
                  icon: const Icon(Broken.edit),
                  tooltip: L10n.of(context).msgc8ce4b36,
                  onPressed: _handleRenameSelected,
                ),
                IconButton(
                  icon: const Icon(Broken.trash, color: Colors.red),
                  tooltip: L10n.of(context).ui_delete_tooltip,
                  onPressed: _handleDeleteSelected,
                ),
                PopupMenuButton<String>(
                  icon: const Icon(Broken.more),
                  tooltip: L10n.of(context).msgfff96ede,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                  position: PopupMenuPosition.under,
                  elevation: 8,
                  onSelected: (action) {
                    if (action == 'select_all') {
                      _selectAll();
                    } else if (action == 'share') {
                      _handleShareSelected();
                    } else if (action == 'properties') {
                      showDialog(
                        context: context,
                        builder: (context) => PropertiesModalDialog(
                          selectedPaths: _selectedPaths.toList(),
                          provider: fileProvider,
                        ),
                      );
                    }
                  },
                  itemBuilder: (context) => [
                    PopupMenuItem<String>(
                      value: 'select_all',
                      child: Row(
                        children: [
                          const Icon(Broken.tick_square, size: 20),
                          const SizedBox(width: 12),
                          Text(L10n.of(context).ui_select_all, style: const TextStyle(fontWeight: FontWeight.w500)),
                        ],
                      ),
                    ),
                    PopupMenuItem<String>(
                      value: 'share',
                      child: Row(
                        children: [
                          const Icon(Icons.share_outlined, size: 20),
                          const SizedBox(width: 12),
                          Text(L10n.of(context).ui_share, style: const TextStyle(fontWeight: FontWeight.w500)),
                        ],
                      ),
                    ),
                    PopupMenuItem<String>(
                      value: 'properties',
                      child: Row(
                        children: [
                          const Icon(Broken.info_circle, size: 20),
                          const SizedBox(width: 12),
                          Text(L10n.of(context).ui_properties, style: const TextStyle(fontWeight: FontWeight.w500)),
                        ],
                      ),
                    ),
                  ],
                ),
              ]
            : null,
      ),
      body: GestureDetector(
        onHorizontalDragEnd: (details) {
          final fileProvider = context.read<FileManagerProvider>();
          if (!fileProvider.enableMultipleTabs || fileProvider.enableSplitScreen || _isSelectionMode) {
            return;
          }
          final velocity = details.primaryVelocity ?? 0.0;
          // Swipe Left (moves right-to-left) -> Next Tab
          if (velocity < -300) {
            if (fileProvider.activeTabIndex < fileProvider.tabs.length - 1) {
              fileProvider.setActiveTab(fileProvider.activeTabIndex + 1);
            } else if (fileProvider.activeTabIndex == fileProvider.tabs.length - 1) {
              fileProvider.addTab(fileProvider.rootPath);
            }
          }
          // Swipe Right (moves left-to-right) -> Previous Tab
          else if (velocity > 300) {
            if (fileProvider.activeTabIndex > 0) {
              fileProvider.setActiveTab(fileProvider.activeTabIndex - 1);
            }
          }
        },
        behavior: HitTestBehavior.translucent,
        child: Column(
        children: [
          // Filter Chips Row (ZenFile style)
          Container(
            height: 56,
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              itemCount: _filters.length,
              itemBuilder: (context, index) {
                final filter = _filters[index];
                final isSelected = filter == _selectedFilter;
                return Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: InkWell(
                    onTap: () => _onFilterChanged(filter),
                    borderRadius: BorderRadius.circular(16),
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 200),
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                      decoration: BoxDecoration(
                        color: isSelected
                            ? theme.colorScheme.primary.withAlpha(38)
                            : theme.colorScheme.surface,
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(
                          color: isSelected
                              ? theme.colorScheme.primary
                              : theme.dividerColor.withAlpha(51),
                          width: 1.5,
                        ),
                      ),
                      child: Row(
                        children: [
                          if (isSelected) ...[
                            Icon(Broken.tick_circle, size: 16, color: theme.colorScheme.primary),
                            const SizedBox(width: 6),
                          ],
                          Text(
                            filter,
                            style: TextStyle(
                              fontWeight: isSelected ? FontWeight.w600 : FontWeight.w500,
                              color: isSelected
                                  ? theme.colorScheme.primary
                                  : theme.colorScheme.onSurface.withAlpha(178),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
          
          // Search Progress Indicator
          if (_isSearching)
            LinearProgressIndicator(
              backgroundColor: theme.colorScheme.primary.withAlpha(25),
              color: theme.colorScheme.primary,
              minHeight: 2,
            )
          else
            const SizedBox(height: 2),
 
          // Results List / Empty State
          Expanded(
            child: _query.isEmpty
                ? _buildEmptyState(
                    theme,
                    Broken.search_normal_1,
                    isGlobal ? L10n.of(context).msg88e45bb8 : L10n.of(context).ui_search_this_folder,
                    isGlobal
                        ? L10n.of(context).ui_global_search_hint
                        : L10n.of(context).ui_search_files_subfolders_in(_searchFolderPath!.split("/").last),
                  )
                : _results.isEmpty && !_isSearching && _featureResults.isEmpty
                    ? _buildNoResultView(theme)
                    : _buildResultList(theme),
          ),
        ],
      ),
    ),
  );
}

  /// 文件无结果时的视图。
  ///
  /// 仍然给出「在设置中搜索」入口 —— 设置项没有做搜索索引（上百个开关），
  /// 有没有匹配由设置页自己的过滤逻辑判定，所以这里不能替它下"无结果"的结论。
  Widget _buildNoResultView(ThemeData theme) {
    final l10n = L10n.of(context);
    return Column(
      children: [
        _buildFeatureTile(
          theme,
          icon: Broken.setting_2,
          title: l10n.ui_search_in_settings,
          subtitle: '\u201C$_query\u201D',
          onTap: _openSettingsSearch,
        ),
        Divider(height: 1, color: theme.dividerColor.withAlpha(51)),
        Expanded(
          child: _buildEmptyState(
            theme,
            Broken.document_filter,
            l10n.ui_no_results,
            l10n.ui_no_match_for(_query),
          ),
        ),
      ],
    );
  }

  /// 搜索结果列表：功能入口（设置 / 左右抽屉）分组在前，文件结果在后。
  Widget _buildResultList(ThemeData theme) {
    // 多选模式下隐藏功能入口，避免与文件批量操作混淆。
    final featureTiles = _isSelectionMode
        ? const <Widget>[]
        : _buildFeatureTiles(theme);
    return ListView.builder(
      physics: const BouncingScrollPhysics(),
      itemCount: featureTiles.length + _results.length,
      itemBuilder: (context, index) {
        if (index < featureTiles.length) {
          return featureTiles[index];
        }
        final item = _results[index - featureTiles.length];
        final isItemSelected = _selectedPaths.contains(item.path);

        if (item.isDirectory) {
          return FolderItem(
            folder: item,
            isSelected: isItemSelected,
            showShowInLocationOption: true,
            onTap: () {
              if (_isSelectionMode) {
                _toggleSelection(item.path);
              } else {
                // 使用与"查看远程缓存目录"相同的导航模式：
                // 设置待导航路径并切换到浏览 Tab，确保从任何页面
                // （抽屉、分类页等）打开搜索后都能正确跳转到浏览页
                final provider = context.read<FileManagerProvider>();
                provider.setPendingBrowseNavigation(item.path, []);
                provider.setNavigateToBrowseTab(true);
                Navigator.of(context).popUntil((route) => route.isFirst);
              }
            },
            onLongPress: () => _toggleSelection(item.path),
            onAction: (action) => _handleAction(context, action, item.path),
          );
        } else {
          return FileItem(
            file: item,
            isSelected: isItemSelected,
            showShowInLocationOption: true,
            onTap: () {
              if (_isSelectionMode) {
                _toggleSelection(item.path);
              } else {
                context.read<FileManagerProvider>().openFile(context, item.path);
              }
            },
            onLongPress: () => _toggleSelection(item.path),
            onAction: (action) => _handleAction(context, action, item.path),
          );
        }
      },
    );
  }

  /// 功能入口结果：分组标题 + 条目。
  ///
  /// 第一条固定是「在设置中搜索 <查询词>」—— 把查询词直接交给设置页自己的过滤
  /// 逻辑，从而覆盖设置页全部二级页条目（无需为上百个开关维护一份索引）。
  List<Widget> _buildFeatureTiles(ThemeData theme) {
    if (_query.isEmpty) return const <Widget>[];
    final l10n = L10n.of(context);
    final widgets = <Widget>[];

    widgets.add(_buildFeatureSectionHeader(theme, l10n.cat_settings));
    widgets.add(
      _buildFeatureTile(
        theme,
        icon: Broken.setting_2,
        title: l10n.ui_search_in_settings,
        subtitle: '“$_query”',
        onTap: _openSettingsSearch,
      ),
    );

    for (final group in FeatureSearchGroup.values) {
      final items =
          _featureResults.where((entry) => entry.group == group).toList();
      if (items.isEmpty) continue;
      widgets.add(
        _buildFeatureSectionHeader(
          theme,
          FeatureSearchIndex.groupTitle(l10n, group),
        ),
      );
      for (final entry in items) {
        widgets.add(
          _buildFeatureTile(
            theme,
            icon: entry.icon,
            title: entry.title,
            subtitle: entry.subtitle,
            onTap: () {
              // 先关闭搜索页回到首页，再由条目自己打开目标页 / 触发动作。
              final navigator = Navigator.of(context);
              entry.onOpen(context, navigator);
            },
          ),
        );
      }
    }
    return widgets;
  }

  /// 把当前查询词交给设置页过滤（切到设置 Tab 并进入搜索态）。
  void _openSettingsSearch() {
    final provider = context.read<FileManagerProvider>();
    Navigator.of(context).popUntil((route) => route.isFirst);
    provider.requestSettingsSearch(_query);
  }

  Widget _buildFeatureSectionHeader(ThemeData theme, String title) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
      child: Text(
        title,
        style: TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w700,
          color: theme.colorScheme.primary,
          letterSpacing: 0.4,
        ),
      ),
    );
  }

  Widget _buildFeatureTile(
    ThemeData theme, {
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
        child: Row(
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: theme.colorScheme.primary.withAlpha(25),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(icon, size: 20, color: theme.colorScheme.primary),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyLarge?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  if (subtitle.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        color: theme.colorScheme.onSurface.withAlpha(128),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            Icon(
              Broken.arrow_right_3,
              size: 16,
              color: theme.colorScheme.onSurface.withAlpha(90),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEmptyState(ThemeData theme, IconData icon, String title, String subtitle) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                color: theme.colorScheme.primary.withAlpha(20),
                shape: BoxShape.circle,
              ),
              child: Icon(icon, size: 64, color: theme.colorScheme.primary),
            ),
            const SizedBox(height: 24),
            Text(
              title,
              style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Text(
              subtitle,
              textAlign: TextAlign.center,
              style: TextStyle(color: theme.colorScheme.onSurface.withAlpha(127), fontSize: 15),
            ),
          ],
        ),
      ),
    );
  }
}
