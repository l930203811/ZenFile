import 'file_item_model.dart';
import '../services/remote/remote_client.dart';
import '../models/network_connection_model.dart';

class FolderTab {
  final String id;
  String currentPath;
  List<FileItemModel> currentFiles;
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

  FolderTab({
    required this.id,
    required this.currentPath,
    this.currentFiles = const [],
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
  }) : selectedPaths = selectedPaths ?? {},
       scrollPositions = scrollPositions ?? {};
}
