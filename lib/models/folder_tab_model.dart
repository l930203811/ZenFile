import 'file_item_model.dart';
import '../services/remote/remote_client.dart';
import '../models/network_connection_model.dart';

class FolderTab {
  final String id;
  String currentPath;
  List<FileItemModel> currentFiles;

  /// 本标签页的内容是否已尝试列举过。
  ///
  /// 标签页可以从 SharedPreferences 恢复出来（「记住上次打开文件夹」），此时
  /// [currentFiles] 是空常量列表，但目录从未被列举 —— 与「这是个空目录」是两件事。
  /// 恢复出的标签页靠这个标记决定要不要补一次 `loadDirectory`：
  /// 不补的话切过去就是一片空白，必须手动下拉刷新才有内容。
  /// 由 [FileManagerProvider.loadDirectory] 入口置位（不在此处赋值），
  /// 因此任何加载路径（切换 / 新建 / 前进后退 / 手动刷新）都会自动置位。
  /// **不参与持久化**：重启后所有恢复出来的标签页都是 false，正是需要它的场景。
  bool hasLoaded;
  bool isLoading;
  bool isRestrictedMode;
  bool needsPermission;
  bool useRootMode;
  bool useShizukuMode;
  bool isRootAvailable;
  final Set<String> selectedPaths;
  double scrollOffset;
  final Map<String, double> scrollPositions;
  bool isPinned;

  // ── Remote connection state ──
  bool isRemote;
  RemoteClient? remoteClient;
  NetworkConnectionModel? remoteConnection;

  // ── 远程加密目录（cryptremote://，客户端解密，支持读写）──
  bool isCryptRemote;

  // ── Per-tab navigation history ──
  final List<String> pathHistory;
  int historyIndex;

  FolderTab({
    required this.id,
    required this.currentPath,
    this.currentFiles = const [],
    this.hasLoaded = false,
    this.isLoading = false,
    this.isRestrictedMode = false,
    this.needsPermission = false,
    this.useRootMode = false,
    this.useShizukuMode = false,
    this.isRootAvailable = false,
    Set<String>? selectedPaths,
    this.scrollOffset = 0.0,
    Map<String, double>? scrollPositions,
    this.isPinned = false,
    this.isRemote = false,
    this.remoteClient,
    this.remoteConnection,
    this.isCryptRemote = false,
    List<String>? pathHistory,
    this.historyIndex = -1,
  })  : selectedPaths = selectedPaths ?? {},
        scrollPositions = scrollPositions ?? {},
        pathHistory = pathHistory ?? [];
}
