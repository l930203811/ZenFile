import 'dart:io';
import 'package:path/path.dart' as path_helper;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:on_audio_query/on_audio_query.dart';
import 'package:intl/intl.dart';
import 'package:audio_service/audio_service.dart';
import '../../providers/media_provider.dart';
import '../../providers/file_manager_provider.dart';
import '../../services/remote/remote_client.dart';
import '../../services/preferences_service.dart';
import '../../services/category_sync_service.dart';
import '../../services/remote_guard_service.dart';
import '../../services/audio_background_handler.dart';
import '../../core/utils.dart';
import '../../services/app_manager_service.dart';
import '../../services/media_thumbnail_service.dart';
import 'image_viewer_screen.dart';
import 'video_player/video_player_screen.dart';
import 'audio_player/audio_player_screen.dart';
import '../../core/icon_fonts/broken_icons.dart';
import 'package:share_plus/share_plus.dart';
import 'package:flutter_svg/flutter_svg.dart';
import '../widgets/file_action_dialogs.dart';
import '../widgets/batch_rename_dialog.dart';
import '../widgets/archive_type_icon.dart';
import '../widgets/file_type_icon.dart';
import '../widgets/remote_path_picker.dart';
import 'internal_file_picker_screen.dart';
import 'package:zenfile/l10n/generated/app_localizations.dart';

enum MediaType { images, videos, audios, documents, archives, downloads, apks, screenshots }

/// 媒体分类页右上角「查看与排序」菜单动作
enum _ViewMenuAction {
  sortNewest,
  sortOldest,
  sortDateWise,
  sortNewestGrouped,
  sortOldestGrouped,
  sortSizeLargest,
  sortSizeSmallest,
  viewList,
  viewGrid,
  togglePlayerController,
  toggleShowRemoteFiles,
}

/// 分类页右上角同步菜单动作
/// 分类页「备份」菜单动作（仅本地→远程备份，无方向选择）。
enum _SyncMenuAction {
  toggleAuto,
  backupNow,
}

/// 分类页「本地 / 远程」内容过滤范围
enum _ScopeFilter { local, remote }

class MediaCategoryScreen extends StatefulWidget {
  final MediaType mediaType;
  final AssetPathEntity? album;
  final Function(int)? onNavigateTab;
  /// 文件夹视图下钻：非 null 时只显示该父目录下的媒体文件（扁平列表）。
  final String? folderPath;

  const MediaCategoryScreen({super.key, required this.mediaType, this.album, this.onNavigateTab, this.folderPath});

  @override
  State<MediaCategoryScreen> createState() => _MediaCategoryScreenState();
}

class _MediaCategoryScreenState extends State<MediaCategoryScreen>
    with SingleTickerProviderStateMixin {
  late AnimationController _shimmerController;

  // Helper: check if artist string is effectively empty (null, empty, or "unknown" from plugin)
  static bool _isUnknownArtist(String? artist) => FileUtils.isUnknownArtist(artist);

  /// 文件夹显示名：根目录显示「内部存储」，其余显示目录名。
  static String _folderDisplayName(String dir) {
    if (dir == '/storage/emulated/0') return '内部存储';
    return path_helper.basename(dir);
  }

  /// 从媒体条目（File 或 SongModel）提取文件路径，用于文件夹封面。
  static String? _sampleItemPath(dynamic item) {
    if (item is String) return item;
    if (item is FileSystemEntity) return item.path;
    if (item is SongModel) return item.data;
    return null;
  }

  Set<String> _selectedFilePaths = {};
  Set<String> _selectedAssetIds = {};

  bool get _isSelectionMode => _selectedFilePaths.isNotEmpty || _selectedAssetIds.isNotEmpty;

  bool _showFoldersMode = false;
  List<AssetEntity> _albumAssets = [];
  bool _loadingAlbum = false;

  // 当前类别的视图模式：true=网格视图, false=列表视图
  late bool _isGridView;

  // 是否显示「继续播放」音频/视频控制器（保护隐私）
  late bool _showResumeAudio;
  late bool _showResumeVideo;

  // 当前类别是否开启「自动同步」（即同步菜单中显示三个方向按钮）
  bool _autoSyncEnabled = false;

  // 当前类别是否显示远程文件（false 时仅显示本地并隐藏本地/远程切换按钮）
  late bool _showRemoteFiles;

  /// 防止自动同步在每次重建时重复触发。
  bool _autoSyncTriggered = false;

  /// 上次扫描到的本地文件数量，用于检测新增文件时触发自动备份。
  int _previousFileCount = 0;

  /// 当前「本地 / 远程」过滤范围。默认显示本地内容。
  _ScopeFilter _scopeFilter = _ScopeFilter.local;

  /// 同步菜单的 GlobalKey，用于在切换自动同步开关后让菜单保持展开。
  final GlobalKey<PopupMenuButtonState<_SyncMenuAction>> _syncMenuKey =
      GlobalKey<PopupMenuButtonState<_SyncMenuAction>>();

  /// 支持添加自定义远程目录的类别 → 中文标签。
  static const Map<MediaType, String> _categoryLabels = {
    MediaType.images: '图片',
    MediaType.videos: '视频',
    MediaType.audios: '音频',
    MediaType.documents: '文档',
    MediaType.archives: '压缩包',
    MediaType.downloads: '下载',
    MediaType.apks: '安装包',
    MediaType.screenshots: '截图',
  };

  String get _categoryLabel => _categoryLabels[widget.mediaType]!;

  /// 该类别是否支持远程同步（即支持添加自定义远程目录）。
  bool get _supportsRemoteSync => _categoryLabels.containsKey(widget.mediaType);

  /// 该类别是否支持「全部项目 / 文件夹」二级切换（仅图片/视频/音频有文件夹视图）。
  bool get _supportsFolderView =>
      widget.mediaType == MediaType.images ||
      widget.mediaType == MediaType.videos ||
      widget.mediaType == MediaType.audios;

  /// 是否应在该路径上显示云徽（远程路径，或已同步到远程的本地路径）。
  bool _showCloudBadge(String path) =>
      path.startsWith('remote://') || CategorySyncService.isSyncedLocalPath(path);

  /// 判断某个媒体文件是否归属指定的文件夹磁贴。
  /// 本地文件按父目录精确匹配；远程文件（remote://）若其所在文件夹的 basename
  /// 与本地文件夹磁贴的 basename 一致，则视为同一逻辑文件夹（配合 provider 的文件夹合并，
  /// 下钻时不漏掉远程独有文件）。
  bool _belongsToFolder(String itemPath, String folderPath) {
    if (MediaProvider.parentOfPath(itemPath) == folderPath) return true;
    if (itemPath.startsWith('remote://')) {
      final itemFolderName = path_helper.basename(MediaProvider.parentOfPath(itemPath));
      final folderName = path_helper.basename(folderPath);
      if (itemFolderName.isNotEmpty && itemFolderName == folderName) return true;
    }
    return false;
  }

  /// 根据当前 [_scopeFilter] 过滤媒体列表。
  /// 当 [_showRemoteFiles] 关闭时，强制仅返回本地文件。
  List<T> _filterByScope<T>(List<T> source, String Function(T) pathOf) {
    if (!_showRemoteFiles) {
      return source.where((item) => !MediaProvider.isRemotePath(pathOf(item))).toList();
    }
    switch (_scopeFilter) {
      case _ScopeFilter.local:
        return source.where((item) => !MediaProvider.isRemotePath(pathOf(item))).toList();
      case _ScopeFilter.remote:
        return source.where((item) => MediaProvider.isRemotePath(pathOf(item))).toList();
    }
  }

  Future<void> _loadAutoSync() async {
    final enabled = await CategorySyncService.isAutoSyncEnabled(_categoryLabel);
    if (mounted) {
      setState(() {
        _autoSyncEnabled = enabled;
      });
    }
    // 记录初始文件数量，后续扫描后对比以检测新增文件
    final provider = Provider.of<MediaProvider>(context, listen: false);
    _previousFileCount = _currentLocalFileCount(provider);
  }

  /// 获取当前类别的本地文件数量（用于新增文件检测）。
  int _currentLocalFileCount(MediaProvider provider) {
    final paths = provider.customCategoryPaths[_categoryLabel] ?? [];
    final remotePaths = paths.where((p) => p.startsWith('remote://')).toList();
    if (remotePaths.isEmpty) return 0;
    // 仅统计本地路径下的分类文件数
    return _collectCategoryFiles().length;
  }

  /// 打开类别界面时自动执行一次本地→远程备份（无需手动点击）。
  /// 若未开启自动备份，则仅在首次进入时记录文件数量基线。
  Future<void> _maybeAutoSync() async {
    if (!mounted) return;
    final provider = Provider.of<MediaProvider>(context, listen: false);
    final customPaths = provider.customCategoryPaths[_categoryLabel] ?? [];
    final remotePaths = customPaths.where((p) => p.startsWith('remote://')).toList();
    if (remotePaths.isEmpty) return;
    final pairs = await _buildSyncPairs(remotePaths);
    if (pairs.isEmpty) return;
    await _runBackup(pairs, auto: true);
  }

  /// 手动「立即备份」：执行一次本地→远程备份。未添加远程路径时提示用户。
  Future<void> _runSyncNow() async {
    final provider = Provider.of<MediaProvider>(context, listen: false);
    final customPaths = provider.customCategoryPaths[_categoryLabel] ?? [];
    final remotePaths = customPaths.where((p) => p.startsWith('remote://')).toList();
    if (remotePaths.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(L10n.of(context).ui_no_remote_path)),
        );
      }
      return;
    }
    final pairs = await _buildSyncPairs(remotePaths);
    if (pairs.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(L10n.of(context).ui_no_remote_path)),
        );
      }
      return;
    }
    await _runBackup(pairs);
  }

  /// 添加本地扫描路径到当前分类。
  Future<void> _addLocalPath() async {
    final fileManager = Provider.of<FileManagerProvider>(context, listen: false);
    final provider = Provider.of<MediaProvider>(context, listen: false);
    final pickedPaths = await InternalFilePickerScreen.show(
      context,
      rootPath: fileManager.rootPath,
      pickDirectory: true,
    );
    if (pickedPaths != null && pickedPaths.isNotEmpty) {
      for (final p in pickedPaths) {
        provider.addCustomCategoryPath(_categoryLabel, p);
      }
    }
  }

  /// 添加远程扫描路径到当前分类。
  Future<void> _addRemotePath() async {
    final provider = Provider.of<MediaProvider>(context, listen: false);
    final remotePath = await showRemotePathPicker(context);
    if (remotePath != null) {
      provider.addCustomCategoryPath(_categoryLabel, remotePath);
    }
  }

  /// 统一的同步菜单项：左侧固定 24px 图标槽 + 12px 间距 + 文本，
  /// 保证「立即同步」与方向/开关项的标题左对齐，不再突兀。
  PopupMenuEntry<_SyncMenuAction> _syncMenuItem(
    _SyncMenuAction value,
    IconData? icon,
    String label,
  ) {
    final theme = Theme.of(context);
    return PopupMenuItem<_SyncMenuAction>(
      value: value,
      child: Row(
        children: [
          SizedBox(
            width: 24,
            child: icon == null
                ? const SizedBox.shrink()
                : Icon(icon, size: 18, color: theme.colorScheme.onSurfaceVariant),
          ),
          const SizedBox(width: 12),
          Text(label),
        ],
      ),
    );
  }

  /// 切换自动同步开关 / 选择方向后，让菜单保持展开（避免再次点击同步按钮）。
  void _reopenSyncMenu() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _syncMenuKey.currentState?.showButtonMenu();
    });
  }

  /// 根据当前类别构造「文件级」同步单元列表：仅同步实际分类文件，而非整文件夹。
  /// 本地源绝不包含 remote:// 路径，防止把自定义远程扫描路径里的文件再次同步回远程造成循环/重复。
  Future<List<CategorySyncPair>> _buildSyncPairs(List<String> remotePaths) async {
    final provider = Provider.of<MediaProvider>(context, listen: false);
    // 本地源只取实际分类文件，绝不包含 remote://。
    List<String> localFiles;
    String localDir;
    if (widget.folderPath != null) {
      // 下钻到某个文件夹后执行备份：该文件夹必须是本地路径。
      if (widget.folderPath!.startsWith('remote://')) return [];
      localFiles = _collectCategoryFiles(widget.folderPath);
      // 以主存储根为镜像基准，保留下钻文件夹名（如 DCIM）在远程结构中。
      localDir = _mirrorRoot(localFiles, fallback: widget.folderPath!);
    } else {
      final customPaths = provider.customCategoryPaths[_categoryLabel] ?? [];
      final localCustom = customPaths
          .where((p) => !p.startsWith('remote://') && p.isNotEmpty)
          .toList();
      if (localCustom.isNotEmpty) {
        // 有自定义本地扫描路径：只收集这些路径下的分类文件。
        localFiles = [];
        for (final dir in localCustom) {
          localFiles.addAll(_collectCategoryFiles(dir));
        }
        localDir = _mirrorRoot(localFiles, fallback: localCustom.first);
      } else {
        localFiles = _collectCategoryFiles();
        localDir = _mirrorRoot(localFiles, fallback: '/storage/emulated/0');
      }
    }
    // 仅本地→远程备份：本地无文件则无可备份。
    if (localFiles.isEmpty) return [];

    final pairs = <CategorySyncPair>[];
    for (final remotePath in remotePaths) {
      // 根视图直接用远程基准，镜像保留本地相对结构（DCIM/Pictures 等顶层目录）。
      final remoteBase = (widget.folderPath != null)
          ? _appendSegment(remotePath, path_helper.basename(widget.folderPath!))
          : remotePath;
      pairs.add(CategorySyncPair(
        localDir: localDir,
        localFiles: localFiles,
        remoteTargetPath: remoteBase,
      ));
    }
    return pairs;
  }

  /// 计算镜像基准目录：优先用主存储根 `/storage/emulated/0`，
  /// 使 DCIM/Pictures 等顶层目录在远程结构中保留；不在主存储下的文件回退到最长公共目录。
  String _mirrorRoot(List<String> files, {required String fallback}) {
    if (files.isEmpty) return fallback;
    if (files.every((f) => f.startsWith('/storage/emulated/0/') || f == '/storage/emulated/0')) {
      return '/storage/emulated/0';
    }
    return FileManagerProvider.longestCommonDir(files);
  }

  /// 收集当前类别的本地文件路径（排除 remote://）。可限定在某文件夹 [scopeDir] 下。
  List<String> _collectCategoryFiles([String? scopeDir]) {
    final provider = Provider.of<MediaProvider>(context, listen: false);
    final List<String> paths = [];
    switch (widget.mediaType) {
      case MediaType.images:
        paths.addAll(provider.images.map((f) => f.path));
        break;
      case MediaType.videos:
        paths.addAll(provider.videos.map((f) => f.path));
        break;
      case MediaType.audios:
        paths.addAll(provider.audios
            .where((s) => !s.data.startsWith('remote://'))
            .map((s) => s.data));
        break;
      case MediaType.screenshots:
        paths.addAll(provider.screenshots.map((f) => f.path));
        break;
      case MediaType.documents:
        paths.addAll(provider.documents.map((f) => f.path));
        break;
      case MediaType.archives:
        paths.addAll(provider.archives.map((f) => f.path));
        break;
      case MediaType.downloads:
        paths.addAll(provider.downloads.map((f) => f.path));
        break;
      case MediaType.apks:
        paths.addAll(provider.apks.map((f) => f.path));
        break;
    }
    var result = paths
        .where((p) => !p.startsWith('remote://') && p.isNotEmpty)
        .toList();
    if (scopeDir != null && scopeDir.isNotEmpty) {
      final prefix = scopeDir.endsWith('/') ? scopeDir : '$scopeDir/';
      result = result.where((p) => p == scopeDir || p.startsWith(prefix)).toList();
    }
    return result;
  }

  /// 在 remote://{connId}|{serverPath} 的 serverPath 末尾追加一段目录名。
  String _appendSegment(String remotePath, String name) {
    final sep = remotePath.indexOf('|');
    if (sep < 0) return remotePath;
    final prefix = remotePath.substring(0, sep + 1);
    final serverPath = remotePath.substring(sep + 1);
    final base = serverPath.endsWith('/') ? serverPath : '$serverPath/';
    return '$prefix$base$name';
  }

  /// 执行本地→远程备份。手动调用时显示进度对话框；[auto]=true 时静默执行（用于打开界面自动备份），
  /// 完成后记录已备份路径以显示云徽。
  Future<void> _runBackup(List<CategorySyncPair> pairs, {bool auto = false}) async {
    final fm = Provider.of<FileManagerProvider>(context, listen: false);
    if (auto) {
      try {
        await fm.syncCategoryPairs(
          pairs: pairs,
          categoryLabel: _categoryLabel,
          onStatus: (_) {},
        );
        if (mounted) {
          setState(() {}); // 刷新云徽显示（记录已由 provider 持久化）
          // 立即触发媒体重扫，使本地/远程新增文件即时显示，无需等待后台扫描。
          Provider.of<MediaProvider>(context, listen: false).loadMedia(forceRefresh: true);
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(L10n.of(context).ui_sync_done)),
          );
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(L10n.of(context).ui_backup_failed(e.toString()))),
          );
        }
      }
      return;
    }
    final statusNotifier = ValueNotifier<String>(L10n.of(context).ui_syncing);
    if (mounted) {
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => AlertDialog(
          title: Text(L10n.of(ctx).ui_backup),
          content: ValueListenableBuilder<String>(
            valueListenable: statusNotifier,
            builder: (c, status, _) => Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SizedBox(height: 8),
                const CircularProgressIndicator(),
                const SizedBox(height: 12),
                Text(status),
              ],
            ),
          ),
        ),
      );
    }
    try {
      await fm.syncCategoryPairs(
        pairs: pairs,
        categoryLabel: _categoryLabel,
        onStatus: (s) => statusNotifier.value = s,
      );
      if (mounted) {
        Navigator.of(context).pop();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(L10n.of(context).ui_sync_done)),
        );
        setState(() {}); // 刷新云徽显示（记录已由 provider 持久化）
        // 立即触发媒体重扫，使本地/远程新增文件即时显示，无需等待后台扫描。
        Provider.of<MediaProvider>(context, listen: false).loadMedia(forceRefresh: true);
      }
    } catch (e) {
      if (mounted) {
        Navigator.of(context).pop();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(L10n.of(context).ui_backup_failed(e.toString()))),
        );
      }
    }
  }

  @override
  void initState() {
    super.initState();
    _shimmerController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    )..repeat();

    if (widget.album == null &&
        widget.folderPath == null &&
        (widget.mediaType == MediaType.images ||
            widget.mediaType == MediaType.videos ||
            widget.mediaType == MediaType.audios)) {
      // 按类别独立记忆文件夹/全部项目查看模式；视频/音频默认文件夹查看，图片默认全部项目
      final defaultFolders = widget.mediaType == MediaType.videos ||
          widget.mediaType == MediaType.audios;
      _showFoldersMode = PreferencesService.getPreferFoldersInMedia(
        widget.mediaType.name,
        defaultValue: defaultFolders,
      );
    }

    // 按类别初始化视图模式：图片/截图默认网格，其余默认列表
    final defaultGrid = widget.mediaType == MediaType.images ||
        widget.mediaType == MediaType.screenshots;
    _isGridView = PreferencesService.getMediaCategoryGridView(
      widget.mediaType.name,
      defaultValue: defaultGrid,
    );

    // 加载播放器控制器显示状态，默认显示
    _showResumeAudio = PreferencesService.getShowResumeAudio();
    _showResumeVideo = PreferencesService.getShowResumeVideo();

    // 加载当前类别「显示远程文件」开关，默认开启（保持既有行为）
    _showRemoteFiles = PreferencesService.getShowRemoteFilesInCategory(widget.mediaType.name);

    // 预加载分类同步缓存（云徽判定需在首帧前就绪）
    CategorySyncService.init();
    // 若是通过「远程文件夹」下钻进入的，则默认处于远程范围，否则默认本地范围。
    // 否则新页面 _scopeFilter 会回落到默认的 local，把远程文件夹里的文件按本地范围过滤掉 → 下钻后空白。
    if (widget.folderPath != null && MediaProvider.isRemotePath(widget.folderPath!)) {
      // 远程保护开启且未解锁时：验证 PIN 通过后才进入远程范围（首帧后再弹验证页）
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        if (!mounted) return;
        if (await RemoteGuardService.guard(context) && mounted) {
          setState(() => _scopeFilter = _ScopeFilter.remote);
        }
      });
    }
    // 加载该类别的「自动同步」开关
    _loadAutoSync();

    if (widget.album != null) {
      _loadAlbumAssets();
    } else {
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

    // 已移除「进入非媒体类别即触发默认目录递归扫描」逻辑：启动预扫描
    // （MediaStore 索引，毫秒级）已覆盖，进类别不再触发全盘递归。
  }

  Future<void> _loadAlbumAssets() async {
    setState(() => _loadingAlbum = true);
    try {
      final count = await widget.album!.assetCountAsync;
      final assets = await widget.album!.getAssetListPaged(page: 0, size: count);
      if (mounted) {
        setState(() {
          _albumAssets = assets;
          _loadingAlbum = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loadingAlbum = false);
    }
  }

  @override
  void dispose() {
    _shimmerController.dispose();
    super.dispose();
  }

  String get _title {
    if (widget.album != null) {
      return widget.album!.name;
    }
    if (widget.folderPath != null) {
      return _folderDisplayName(widget.folderPath!);
    }
    switch (widget.mediaType) {
      case MediaType.images:
        return L10n.of(context).cat_images;
      case MediaType.videos:
        return L10n.of(context).cat_videos;
      case MediaType.audios:
        return L10n.of(context).cat_audios;
      case MediaType.documents:
        return L10n.of(context).cat_documents;
      case MediaType.archives:
        return L10n.of(context).msgc806d0fa;
      case MediaType.downloads:
        return L10n.of(context).cat_downloads;
      case MediaType.apks:
        return L10n.of(context).msg03070d08;
      case MediaType.screenshots:
        return L10n.of(context).cat_screenshots;
    }
  }

  /// 当前类别是否属于「无系统索引、需全盘递归扫描」的非媒体类别。
  bool get _isNonMediaScanType =>
      widget.mediaType == MediaType.documents ||
      widget.mediaType == MediaType.archives ||
      widget.mediaType == MediaType.downloads ||
      widget.mediaType == MediaType.apks;

  /// 非媒体类别对应的 provider 列表（供后台扫描期间判断是否为空）。
  List _nonMediaListFor(MediaProvider provider) {
    switch (widget.mediaType) {
      case MediaType.documents:
        return provider.documents;
      case MediaType.archives:
        return provider.archives;
      case MediaType.downloads:
        return provider.downloads;
      case MediaType.apks:
        return provider.apks;
      default:
        return const [];
    }
  }

  IconData get _emptyIcon {
    switch (widget.mediaType) {
      case MediaType.images:
        return Broken.image;
      case MediaType.videos:
        return Broken.video;
      case MediaType.audios:
        return Broken.music;
      case MediaType.documents:
        return Broken.document;
      case MediaType.archives:
        return Broken.box;
      case MediaType.downloads:
        return Broken.document_download;
      case MediaType.apks:
        return Broken.box;
      case MediaType.screenshots:
        return Broken.mobile;
    }
  }

  void _toggleSelection(String? filePath, String? assetId) {
    setState(() {
      if (filePath != null && filePath.isNotEmpty) {
        if (_selectedFilePaths.contains(filePath)) {
          _selectedFilePaths.remove(filePath);
        } else {
          _selectedFilePaths.add(filePath);
        }
      }
      if (assetId != null && assetId.isNotEmpty) {
        if (_selectedAssetIds.contains(assetId)) {
          _selectedAssetIds.remove(assetId);
        } else {
          _selectedAssetIds.add(assetId);
        }
      }
    });
  }

  void _selectAll(MediaProvider provider) {
    final filePaths = <String>{};
    final assetIds = <String>{};
    final isLocal = _scopeFilter == _ScopeFilter.local;

    if (widget.mediaType == MediaType.images) {
      for (final e in provider.images) {
        if (e is FileSystemEntity) {
          final isRemote = e.path.startsWith('remote://');
          if (isLocal ? !isRemote : isRemote) filePaths.add(e.path);
        }
      }
    } else if (widget.mediaType == MediaType.videos) {
      for (final e in provider.videos) {
        if (e is FileSystemEntity) {
          final isRemote = e.path.startsWith('remote://');
          if (isLocal ? !isRemote : isRemote) filePaths.add(e.path);
        }
      }
    } else if (widget.mediaType == MediaType.screenshots) {
      for (final e in provider.screenshots) {
        if (e is FileSystemEntity) {
          final isRemote = e.path.startsWith('remote://');
          if (isLocal ? !isRemote : isRemote) filePaths.add(e.path);
        }
      }
    } else if (widget.mediaType == MediaType.audios) {
      filePaths.addAll(provider.audios.map((e) => e.data));
    } else if (widget.mediaType == MediaType.archives) {
      for (final e in provider.archives) {
        final isRemote = e.path.startsWith('remote://');
        if (isLocal ? !isRemote : isRemote) filePaths.add(e.path);
      }
    } else if (widget.mediaType == MediaType.downloads) {
      for (final e in provider.downloads) {
        final isRemote = e.path.startsWith('remote://');
        if (isLocal ? !isRemote : isRemote) filePaths.add(e.path);
      }
    } else if (widget.mediaType == MediaType.apks) {
      for (final e in provider.apks) {
        final isRemote = e.path.startsWith('remote://');
        if (isLocal ? !isRemote : isRemote) filePaths.add(e.path);
      }
    } else if (widget.mediaType == MediaType.documents) {
      for (final e in provider.documents) {
        final isRemote = e.path.startsWith('remote://');
        if (isLocal ? !isRemote : isRemote) filePaths.add(e.path);
      }
    }

    setState(() {
      _selectedFilePaths = filePaths;
      _selectedAssetIds = assetIds;
    });
  }

  void _clearSelection() {
    setState(() {
      _selectedFilePaths.clear();
      _selectedAssetIds.clear();
    });
  }

  Future<void> _handleCopyCut(bool isCut) async {
    final fm = context.read<FileManagerProvider>();
    // 区分远程与本地选中项。
    final remoteSelected = _selectedFilePaths.where((p) => p.startsWith('remote://')).toList();
    final localSelected = _selectedFilePaths.where((p) => !p.startsWith('remote://')).toList();
    final paths = localSelected.toList();
    if (_selectedAssetIds.isNotEmpty) {
      final provider = context.read<MediaProvider>();
      final allAssets = [...provider.images, ...provider.videos, ...provider.screenshots];
      for (final id in _selectedAssetIds) {
        final match = allAssets.where((a) => a.id == id).firstOrNull;
        if (match != null) {
          final f = await match.file;
          if (f != null) paths.add(f.path);
        }
      }
    }

    // 远程文件加入远程剪贴板（供远程浏览页粘贴）。
    if (remoteSelected.isNotEmpty) {
      final byConn = <String, List<String>>{};
      for (final rp in remoteSelected) {
        final parts = FileManagerProvider.parseRemotePathParts(rp);
        if (parts == null) continue;
        (byConn[parts[0]] ??= []).add(rp);
      }
      if (byConn.length == 1) {
        final conn = FileManagerProvider.connectionForRemotePath(remoteSelected.first);
        if (conn != null) {
          final items = remoteSelected.map((rp) {
            final parts = FileManagerProvider.parseRemotePathParts(rp)!;
            final serverName = parts[1].split('/').last;
            return RemoteFileItem(
              name: serverName,
              path: parts[1],
              isDirectory: false,
              size: 0,
              modified: DateTime.now(),
            );
          }).toList();
          fm.setRemoteClipboard(items, isCut: isCut, connection: conn);
        }
      }
    }

    if (paths.isNotEmpty) {
      fm.setClipboard(paths, isCut: isCut);
    }
    if ((paths.isNotEmpty || remoteSelected.isNotEmpty) && mounted) {
      final total = paths.length + remoteSelected.length;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(isCut ? L10n.of(context).ui_cut_count(total) : L10n.of(context).ui_copied_count(total))),
      );
      _clearSelection();
    }
  }

  Future<void> _handleDelete() async {
    final count = _selectedFilePaths.length + _selectedAssetIds.length;
    if (count == 0) return;

    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(L10n.of(context).msg631cd220),
        content: Text(L10n.of(context).count1(count)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(L10n.of(context).ui_cancel)),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(L10n.of(context).ui_delete),
          ),
        ],
      ),
    );

    if (confirm == true && mounted) {
      final mediaProvider = context.read<MediaProvider>();
      final filePaths = _selectedFilePaths.where((p) => !p.startsWith('remote://')).toList();
      final remotePaths = _selectedFilePaths.where((p) => p.startsWith('remote://')).toList();
      final assetIds = _selectedAssetIds.toList();

      if (_selectedAssetIds.isNotEmpty) {
        final allAssets = [...mediaProvider.images, ...mediaProvider.videos, ...mediaProvider.screenshots];
        for (final id in assetIds) {
          final match = allAssets.where((a) => a.id == id).firstOrNull;
          if (match != null) {
            final f = await match.file;
            if (f != null) filePaths.add(f.path);
          }
        }
      }

      // 远程文件走远程删除。
      if (remotePaths.isNotEmpty) {
        await FileManagerProvider.deleteRemotePaths(remotePaths);
      }
      if (filePaths.isNotEmpty || assetIds.isNotEmpty) {
        await mediaProvider.deleteMediaItems(filePaths: filePaths, assetIds: assetIds);
      }
      // 本地删除后即时裁剪列表（无需全量重扫），远程删除后强制重扫自定义远程路径
      if (filePaths.isNotEmpty) {
        mediaProvider.pruneDeletedMediaPaths(filePaths);
      }
      if (remotePaths.isNotEmpty) {
        await mediaProvider.loadMedia(forceRefresh: true);
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(L10n.of(context).count2(count))));
        _clearSelection();
      }
    }
  }

  Future<void> _handlePaste() async {
    final fm = context.read<FileManagerProvider>();
    if (!fm.hasClipboard) return;

    String destDir = '/storage/emulated/0/Download';
    if (widget.mediaType == MediaType.documents) destDir = '/storage/emulated/0/Documents';
    if (widget.mediaType == MediaType.archives) destDir = '/storage/emulated/0/Download';
    if (widget.mediaType == MediaType.apks) destDir = '/storage/emulated/0/Download';

    final dir = Directory(destDir);
    if (!dir.existsSync()) dir.createSync(recursive: true);

    int pastedCount = 0;
    for (final src in fm.clipboardPaths) {
      try {
        final f = File(src);
        if (f.existsSync()) {
          final target = '${dir.path}/${src.split('/').last}';
          if (fm.isCut) {
            f.renameSync(target);
          } else {
            f.copySync(target);
          }
          pastedCount++;
        }
      } catch (_) {}
    }

    fm.clearClipboard();
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(L10n.of(context).pastedcountdestdir(pastedCount, destDir))));
    await context.read<MediaProvider>().loadMedia(forceRefresh: true);
  }

  Future<void> _handleShare() async {
    final count = _selectedFilePaths.length + _selectedAssetIds.length;
    if (count == 0) return;

    final filePaths = _selectedFilePaths.toList();
    if (_selectedAssetIds.isNotEmpty) {
      final mediaProvider = context.read<MediaProvider>();
      final allAssets = [...mediaProvider.images, ...mediaProvider.videos, ...mediaProvider.screenshots];
      for (final id in _selectedAssetIds) {
        final match = allAssets.where((a) => a.id == id).firstOrNull;
        if (match != null) {
          final f = await match.file;
          if (f != null) filePaths.add(f.path);
        }
      }
    }

    final filesToShare = <XFile>[];
    for (final path in filePaths) {
      if (FileSystemEntity.isFileSync(path)) {
        filesToShare.add(XFile(path));
      }
    }

    if (filesToShare.isNotEmpty) {
      try {
        await Share.shareXFiles(filesToShare);
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(L10n.of(context).e10(e))),
          );
        }
      }
    } else {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(L10n.of(context).msgfadbb0bc)),
        );
      }
    }
  }

  Future<void> _handleBatchRename() async {
    final count = _selectedFilePaths.length + _selectedAssetIds.length;
    if (count == 0) return;

    final mediaProvider = context.read<MediaProvider>();
    final filePaths = _selectedFilePaths.toList();
    final assetIds = _selectedAssetIds.toList();

    if (assetIds.isNotEmpty) {
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => const Center(
          child: CircularProgressIndicator(),
        ),
      );

      try {
        final allAssets = [...mediaProvider.images, ...mediaProvider.videos, ...mediaProvider.screenshots];
        for (final id in assetIds) {
          final match = allAssets.where((a) => a.id == id).firstOrNull;
          if (match != null) {
            final f = await match.file;
            if (f != null) filePaths.add(f.path);
          }
        }
      } catch (e) {
        debugPrint('Error resolving assets: $e');
      } finally {
        if (mounted) {
          Navigator.pop(context);
        }
      }
    }

    if (filePaths.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(L10n.of(context).msg3ad97542)),
        );
      }
      return;
    }

    if (filePaths.length == 1) {
      if (mounted) {
        final filePath = filePaths.first;
        final currentName = path_helper.basename(filePath);
        final newName = await FileActionDialogs.showRenameDialog(
          context,
          currentName: currentName,
          title: L10n.of(context).msgc8ce4b36,
          hint: L10n.of(context).msgf139c5cf,
          actionText: L10n.of(context).msgc8ce4b36,
        );
        if (newName != null && newName.isNotEmpty && mounted) {
          if (filePath.startsWith('remote://')) {
            final ok = await FileManagerProvider.renameRemotePath(filePath, newName);
            if (!ok && mounted) {
              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('重命名失败')));
              return;
            }
          } else {
            try {
              await context.read<FileManagerProvider>().renameFile(filePath, newName);
            } catch (e) {
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('重命名失败: $e')));
              }
              return;
            }
          }
          _clearSelection();
          await context.read<MediaProvider>().loadMedia(forceRefresh: true);
        }
      }
      return;
    }

    if (!mounted) return;

    // 远程文件批量重命名（本地仍走 BatchRenameDialog）。
    if (filePaths.every((p) => p.startsWith('remote://'))) {
      final baseName = await FileActionDialogs.showRenameDialog(
        context,
        currentName: path_helper.basename(filePaths.first),
        title: L10n.of(context).msgc8ce4b36,
        hint: L10n.of(context).msgf139c5cf,
        actionText: L10n.of(context).msgc8ce4b36,
      );
      if (baseName != null && baseName.isNotEmpty && mounted) {
        await FileManagerProvider.renameRemotePaths(filePaths, baseName);
        _clearSelection();
        await context.read<MediaProvider>().loadMedia(forceRefresh: true);
      }
      return;
    }

    await showDialog<void>(
      context: context,
      barrierColor: Colors.black.withOpacity(0.55),
      builder: (ctx) => BatchRenameDialog(
        provider: context.read<FileManagerProvider>(),
        selectedPaths: filePaths,
      ),
    );

    if (mounted) {
      _clearSelection();
      await context.read<MediaProvider>().loadMedia(forceRefresh: true);
    }
  }

  Widget _buildCopyableRow(String label, String value, BuildContext ctx) {
    if (value.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(ctx);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8.0),
      child: InkWell(
        onTap: () {
          Clipboard.setData(ClipboardData(text: value));
          ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(content: Text('Copied $label to clipboard'), duration: const Duration(seconds: 1)));
        },
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.all(6.0),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                flex: 3,
                child: Text(label, style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: theme.colorScheme.primary)),
              ),
              Expanded(
                flex: 7,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(child: Text(value, style: const TextStyle(fontSize: 13), softWrap: true)),
                    const SizedBox(width: 4),
                    Icon(Broken.document_copy, size: 14, color: theme.colorScheme.onSurface.withOpacity(0.4)),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _showPropertiesDialog({String? singleFilePath, String? singleAssetId, String? explicitName}) async {
    final filePaths = singleFilePath != null ? [singleFilePath] : _selectedFilePaths.toList();
    final assetIds = singleAssetId != null ? [singleAssetId] : _selectedAssetIds.toList();

    int totalBytes = 0;
    int count = filePaths.length + assetIds.length;
    DateTime? lastMod;
    String nameDisplay = explicitName ?? '';
    String fullPath = '';
    String mimeType = '';
    String dimensionsOrDuration = '';
    String permissionsStr = '';

    if (assetIds.isNotEmpty) {
      final provider = context.read<MediaProvider>();
      final allAssets = [...provider.images, ...provider.videos, ...provider.screenshots];
      for (final id in assetIds) {
        final match = allAssets.where((a) => a.id == id).firstOrNull;
        if (match != null) {
          final f = await match.file;
          if (f != null) {
            if (count == 1) fullPath = f.path;
            if (count == 1 && nameDisplay.isEmpty) nameDisplay = f.path.split('/').last;
            try {
              final FileStat st = f.statSync();
              totalBytes += st.size;
              if (count == 1) {
                lastMod = st.modified;
                permissionsStr = '${(st.mode & 0x100) != 0 ? "R" : ""}${(st.mode & 0x80) != 0 ? "/W" : ""}';
              }
            } catch (_) {}
            if (count == 1) {
              if (match.type == AssetType.image) {
                dimensionsOrDuration = '${match.width} x ${match.height}';
                mimeType = match.mimeType ?? 'image/${f.path.split('.').last}';
              } else if (match.type == AssetType.video) {
                final d = Duration(seconds: match.duration);
                dimensionsOrDuration = '${match.width} x ${match.height} • ${d.inMinutes}:${(d.inSeconds % 60).toString().padLeft(2, "0")}';
                mimeType = match.mimeType ?? 'video/${f.path.split('.').last}';
              }
            }
          }
        }
      }
    }

    for (final p in filePaths) {
      if (count == 1 && nameDisplay.isEmpty) nameDisplay = p.split('/').last;
      if (count == 1) fullPath = p;
      try {
        int size = 0;
        DateTime? modified;
        String permissions = '';
        if (MediaProvider.isRemotePath(p)) {
          size = MediaProvider.getCachedRemoteFileSize(p);
          modified = MediaProvider.getCachedRemoteFileModified(p);
        } else {
          final f = File(p);
          if (f.existsSync()) {
            final FileStat st = f.statSync();
            size = st.size;
            modified = st.modified;
            permissions = '${(st.mode & 0x100) != 0 ? "R" : ""}${(st.mode & 0x80) != 0 ? "/W" : ""}';
          }
        }
        totalBytes += size;
        if (count == 1) {
          lastMod = modified;
          permissionsStr = permissions;
          final ext = path_helper.extension(p).toLowerCase();
          if (widget.mediaType == MediaType.audios) {
            mimeType = 'audio/$ext';
          } else if (widget.mediaType == MediaType.apks) {
            mimeType = 'application/vnd.android.package-archive';
          } else if (widget.mediaType == MediaType.archives) {
            mimeType = 'archive/$ext';
          } else {
            mimeType = 'file/$ext';
          }
        }
      } catch (_) {}
    }

    if (!mounted) return;
    final theme = Theme.of(context);
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Row(
          children: [
            Icon(Broken.info_circle, color: theme.colorScheme.primary),
            const SizedBox(width: 10),
            Text(L10n.of(context).ui_properties, style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
          ],
        ),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (count == 1) ...[
                _buildCopyableRow(L10n.of(context).ui_name, nameDisplay, ctx),
                _buildCopyableRow(L10n.of(context).ui_path, fullPath, ctx),
                _buildCopyableRow(L10n.of(context).ui_size, '${FileUtils.formatBytes(totalBytes, 2)} ($totalBytes bytes)', ctx),
                if (lastMod != null) _buildCopyableRow(L10n.of(context).msg1303e638, FileUtils.formatDate(lastMod), ctx),
                if (mimeType.isNotEmpty && mimeType != 'file/') _buildCopyableRow(L10n.of(context).ui_type, mimeType, ctx),
                if (dimensionsOrDuration.isNotEmpty) _buildCopyableRow(L10n.of(context).msg5bab3781, dimensionsOrDuration, ctx),
                if (permissionsStr.isNotEmpty) _buildCopyableRow(L10n.of(context).ui_permissions, permissionsStr, ctx),
              ] else ...[
                _buildCopyableRow(L10n.of(context).msg880a18f3, '$count ${L10n.of(context).items}', ctx),
                _buildCopyableRow(L10n.of(context).msgea9ecb93, '${FileUtils.formatBytes(totalBytes, 2)} ($totalBytes bytes)', ctx),
              ],
            ],
          ),
        ),
        actions: [
          FilledButton(onPressed: () => Navigator.pop(ctx), child: Text(L10n.of(context).ui_done)),
        ],
      ),
    );
  }

  void _showSingleItemOptions({required String name, String? filePath, String? assetId}) {
    final theme = Theme.of(context);
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      backgroundColor: theme.scaffoldBackgroundColor,
      builder: (ctx) {
        return SafeArea(
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
              GestureDetector(
                onLongPress: (filePath != null)
                    ? () {
                        try {
                          HapticFeedback.mediumImpact();
                        } catch (_) {}
                        Navigator.pop(ctx);
                        context.read<FileManagerProvider>().showOpenWithSheet(context, filePath);
                      }
                    : null,
                child: Container(
                  width: double.infinity,
                  alignment: Alignment.center,
                  padding: const EdgeInsets.symmetric(vertical: 16.0, horizontal: 24.0),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
                      ),
                      if (filePath != null) ...[
                        const SizedBox(height: 4),
                        Text(
                          L10n.of(context).msg5556baa3,
                          style: TextStyle(fontSize: 11, color: theme.colorScheme.onSurface.withOpacity(0.4)),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              const Divider(height: 1),
              if (filePath != null && FileUtils.isArchive(filePath))
                ListTile(
                  leading: Icon(Broken.archive, color: theme.colorScheme.primary),
                  title: Text(L10n.of(context).ui_extract),
                  onTap: () {
                    Navigator.pop(ctx);
                    context.read<FileManagerProvider>().extractArchiveDirectly(context, filePath);
                  },
                ),
              ListTile(
                leading: Icon(Broken.document_copy, color: theme.colorScheme.primary),
                title: Text(L10n.of(context).ui_copy),
                onTap: () async {
                  Navigator.pop(ctx);
                  if (filePath != null && filePath.startsWith('remote://')) {
                    context.read<FileManagerProvider>().copyRemotePathToClipboard(filePath, isCut: false);
                    if (mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Copied $name to clipboard')));
                    }
                    return;
                  }
                  String? target = filePath;
                  if (assetId != null) {
                    final provider = context.read<MediaProvider>();
                    final allAssets = [...provider.images, ...provider.videos, ...provider.screenshots];
                    final match = allAssets.where((a) => a.id == assetId).firstOrNull;
                    if (match != null) {
                      final f = await match.file;
                      target = f?.path;
                    }
                  }
                  if (target != null && mounted) {
                    context.read<FileManagerProvider>().setClipboard([target], isCut: false);
                    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Copied $name to clipboard')));
                  }
                },
              ),
              ListTile(
                leading: Icon(Broken.scissor, color: theme.colorScheme.primary),
                title: Text(L10n.of(context).ui_cut),
                onTap: () async {
                  Navigator.pop(ctx);
                  if (filePath != null && filePath.startsWith('remote://')) {
                    context.read<FileManagerProvider>().copyRemotePathToClipboard(filePath, isCut: true);
                    if (mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Cut $name to clipboard')));
                    }
                    return;
                  }
                  String? target = filePath;
                  if (assetId != null) {
                    final provider = context.read<MediaProvider>();
                    final allAssets = [...provider.images, ...provider.videos, ...provider.screenshots];
                    final match = allAssets.where((a) => a.id == assetId).firstOrNull;
                    if (match != null) {
                      final f = await match.file;
                      target = f?.path;
                    }
                  }
                  if (target != null && mounted) {
                    context.read<FileManagerProvider>().setClipboard([target], isCut: true);
                    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Cut $name to clipboard')));
                  }
                },
              ),
              ListTile(
                leading: const Icon(Broken.trash, color: Colors.red),
                title: Text(L10n.of(context).ui_delete, style: TextStyle(color: Colors.red)),
                onTap: () async {
                  Navigator.pop(ctx);
                  if (filePath != null && filePath.startsWith('remote://')) {
                    final ok = await FileManagerProvider.deleteRemotePath(filePath);
                    if (ok && mounted) {
                      await context.read<MediaProvider>().loadMedia(forceRefresh: true);
                      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(L10n.of(context).name(name))));
                    } else if (mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('删除失败')));
                    }
                    return;
                  }
                  final confirm = await showDialog<bool>(
                    context: context,
                    builder: (c) => AlertDialog(
                      title: Text(L10n.of(context).msg631cd220),
                      content: Text(L10n.of(context).ui_permanently_delete_name(name)),
                      actions: [
                        TextButton(onPressed: () => Navigator.pop(c, false), child: Text(L10n.of(context).ui_cancel)),
                        FilledButton(
                          style: FilledButton.styleFrom(backgroundColor: Colors.red),
                          onPressed: () => Navigator.pop(c, true),
                          child: Text(L10n.of(context).ui_delete),
                        ),
                      ],
                    ),
                  );
                  if (confirm == true && mounted) {
                    final mediaProvider = context.read<MediaProvider>();
                    List<String> files = [];
                    if (filePath != null) files.add(filePath);
                    if (assetId != null) {
                      final allAssets = [...mediaProvider.images, ...mediaProvider.videos, ...mediaProvider.screenshots];
                      final match = allAssets.where((a) => a.id == assetId).firstOrNull;
                      if (match != null) {
                        final f = await match.file;
                        if (f != null) files.add(f.path);
                      }
                    }
                    await mediaProvider.deleteMediaItems(filePaths: files, assetIds: assetId != null ? [assetId] : []);
                    // 即时裁剪 provider 列表，使已删文件预览图立即从网格消失
                    if (files.isNotEmpty) {
                      mediaProvider.pruneDeletedMediaPaths(files);
                    }
                    if (mounted) {
                      setState(() {});
                      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(L10n.of(context).name(name))));
                    }
                  }
                },
              ),
              if (filePath != null)
                ListTile(
                  leading: Icon(Broken.edit, color: theme.colorScheme.primary),
                  title: Text(L10n.of(context).msgc8ce4b36),
                  onTap: () async {
                    Navigator.pop(ctx);
                    if (filePath.startsWith('remote://')) {
                      final currentName = path_helper.basename(filePath);
                      final newName = await FileActionDialogs.showRenameDialog(
                        context,
                        currentName: currentName,
                        title: L10n.of(context).msgc8ce4b36,
                        hint: L10n.of(context).msgf139c5cf,
                        actionText: L10n.of(context).msgc8ce4b36,
                      );
                      if (newName != null && newName.isNotEmpty && mounted) {
                        final ok = await FileManagerProvider.renameRemotePath(filePath, newName);
                        if (ok && mounted) {
                          await context.read<MediaProvider>().loadMedia(forceRefresh: true);
                        } else if (mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('重命名失败')));
                        }
                      }
                      return;
                    }
                    final currentName = path_helper.basename(filePath);
                    final newName = await FileActionDialogs.showRenameDialog(
                      context,
                      currentName: currentName,
                      title: L10n.of(context).msgc8ce4b36,
                      hint: L10n.of(context).msgf139c5cf,
                      actionText: L10n.of(context).msgc8ce4b36,
                    );
                    if (newName != null && newName.isNotEmpty && mounted) {
                      try {
                        await context.read<FileManagerProvider>().renameFile(filePath, newName);
                      } catch (e) {
                        if (mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('重命名失败: $e')));
                        }
                        return;
                      }
                      context.read<MediaProvider>().loadMedia(forceRefresh: true);
                    }
                  },
                ),
              if (filePath != null)
                ListTile(
                  leading: Icon(Broken.folder_open, color: theme.colorScheme.primary),
                  title: Text(L10n.of(context).msgcd8264f1),
                  onTap: () {
                    if (filePath != null && filePath.startsWith('remote://')) {
                      context.read<FileManagerProvider>().showRemoteFileInLocation(filePath);
                    } else if (filePath != null) {
                      context.read<FileManagerProvider>().showFileInLocation(filePath);
                    }
                    Navigator.pop(ctx);
                    Navigator.popUntil(context, (route) => route.isFirst);
                    widget.onNavigateTab?.call(1);
                  },
                ),
              if (filePath != null)
                ListTile(
                  leading: Icon(Broken.eye, color: theme.colorScheme.primary),
                  title: Text(L10n.of(context).msg2a4cfb07),
                  onTap: () {
                    Navigator.pop(ctx);
                    context.read<FileManagerProvider>().showOpenWithSheet(context, filePath);
                  },
                ),
              ListTile(
                leading: Icon(Broken.info_circle, color: theme.colorScheme.primary),
                title: Text(L10n.of(context).ui_properties),
                onTap: () {
                  Navigator.pop(ctx);
                  _showPropertiesDialog(singleFilePath: filePath, singleAssetId: assetId, explicitName: name);
                },
              ),
              ListTile(
                leading: Icon(Icons.share_outlined, color: theme.colorScheme.primary),
                title: Text(L10n.of(context).ui_share),
                onTap: () async {
                  Navigator.pop(ctx);
                  String? target = filePath;
                  if (assetId != null) {
                    final provider = context.read<MediaProvider>();
                    final allAssets = [...provider.images, ...provider.videos, ...provider.screenshots];
                    final match = allAssets.where((a) => a.id == assetId).firstOrNull;
                    if (match != null) {
                      final f = await match.file;
                      target = f?.path;
                    }
                  }
                  if (target != null && FileSystemEntity.isFileSync(target)) {
                    try {
                      await Share.shareXFiles([XFile(target)]);
                    } catch (e) {
                      if (mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text(L10n.of(context).e10(e))),
                        );
                      }
                    }
                  } else {
                    if (mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text(L10n.of(context).msg8bf52387)),
                      );
                    }
                  }
                },
              ),
            ],
          ),
        ),
      );
    },
  );
}

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final fm = context.watch<FileManagerProvider>();
    final canPaste = (widget.mediaType == MediaType.downloads || widget.mediaType == MediaType.documents || widget.mediaType == MediaType.archives || widget.mediaType == MediaType.apks) && fm.hasClipboard;

    // 多选模式下按返回键仅清除选中，而不是退出类别预览页
    return PopScope(
      canPop: !_isSelectionMode,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _isSelectionMode) {
          _clearSelection();
        }
      },
      child: Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      appBar: AppBar(
        title: Text(_isSelectionMode ? L10n.of(context).ui_selected_count(_selectedFilePaths.length + _selectedAssetIds.length) : _title),
        leading: _isSelectionMode
            ? IconButton(icon: const Icon(Broken.close_square), onPressed: _clearSelection)
            : null,
        actions: [
          if (_isSelectionMode)
            Consumer<MediaProvider>(
              builder: (context, provider, child) => IconButton(
                icon: const Icon(Broken.task_square),
                tooltip: L10n.of(context).ui_select_all,
                onPressed: () => _selectAll(provider),
              ),
            )
          else ...[
            if (canPaste)
              IconButton(
                icon: const Icon(Broken.clipboard),
                tooltip: L10n.of(context).msg419be096,
                onPressed: _handlePaste,
              ),
            // 查看与排序综合菜单：排序选项 + 列表/网格视图 + 播放器控制器显隐
            Consumer<MediaProvider>(
              builder: (context, provider, child) {
                final showPlayerController = widget.mediaType == MediaType.audios
                    ? _showResumeAudio
                    : widget.mediaType == MediaType.videos
                        ? _showResumeVideo
                        : null;

                return PopupMenuButton<_ViewMenuAction>(
                  icon: const Icon(Icons.sort),
                  tooltip: L10n.of(context).ui_sort_options,
                  onSelected: (action) async {
                    switch (action) {
                      case _ViewMenuAction.sortNewest:
                        provider.setSortOrder(MediaSortOrder.newest);
                        break;
                      case _ViewMenuAction.sortOldest:
                        provider.setSortOrder(MediaSortOrder.oldest);
                        break;
                      case _ViewMenuAction.sortDateWise:
                        provider.setSortOrder(MediaSortOrder.dateWise);
                        break;
                      case _ViewMenuAction.sortNewestGrouped:
                        provider.setSortOrder(MediaSortOrder.newestGrouped);
                        break;
                      case _ViewMenuAction.sortOldestGrouped:
                        provider.setSortOrder(MediaSortOrder.oldestGrouped);
                        break;
                      case _ViewMenuAction.sortSizeLargest:
                        provider.setSortOrder(MediaSortOrder.sizeLargest);
                        break;
                      case _ViewMenuAction.sortSizeSmallest:
                        provider.setSortOrder(MediaSortOrder.sizeSmallest);
                        break;
                      case _ViewMenuAction.viewList:
                        setState(() => _isGridView = false);
                        await PreferencesService.saveMediaCategoryGridView(
                            widget.mediaType.name, false);
                        break;
                      case _ViewMenuAction.viewGrid:
                        setState(() => _isGridView = true);
                        await PreferencesService.saveMediaCategoryGridView(
                            widget.mediaType.name, true);
                        break;
                      case _ViewMenuAction.togglePlayerController:
                        if (widget.mediaType == MediaType.audios) {
                          final newValue = !_showResumeAudio;
                          await PreferencesService.saveShowResumeAudio(newValue);
                          setState(() => _showResumeAudio = newValue);
                        } else if (widget.mediaType == MediaType.videos) {
                          final newValue = !_showResumeVideo;
                          await PreferencesService.saveShowResumeVideo(newValue);
                          setState(() => _showResumeVideo = newValue);
                        }
                        break;
                      case _ViewMenuAction.toggleShowRemoteFiles:
                        final newValue = !_showRemoteFiles;
                        await PreferencesService.saveShowRemoteFilesInCategory(
                            widget.mediaType.name, newValue);
                        setState(() {
                          _showRemoteFiles = newValue;
                          // 关闭远程显示时自动切回本地范围，避免列表被远程过滤器清空
                          if (!newValue) _scopeFilter = _ScopeFilter.local;
                        });
                        break;
                    }
                  },
                  itemBuilder: (context) => [
                    CheckedPopupMenuItem(
                      value: _ViewMenuAction.sortNewest,
                      checked: provider.sortOrder == MediaSortOrder.newest,
                      child: Text(L10n.of(context).msg5093bc80),
                    ),
                    CheckedPopupMenuItem(
                      value: _ViewMenuAction.sortOldest,
                      checked: provider.sortOrder == MediaSortOrder.oldest,
                      child: Text(L10n.of(context).ui_oldest_first),
                    ),
                    CheckedPopupMenuItem(
                      value: _ViewMenuAction.sortDateWise,
                      checked: provider.sortOrder == MediaSortOrder.dateWise,
                      child: Text(L10n.of(context).msgbc74b5a8),
                    ),
                    CheckedPopupMenuItem(
                      value: _ViewMenuAction.sortNewestGrouped,
                      checked: provider.sortOrder == MediaSortOrder.newestGrouped,
                      child: Text(L10n.of(context).msgef7ae768),
                    ),
                    CheckedPopupMenuItem(
                      value: _ViewMenuAction.sortOldestGrouped,
                      checked: provider.sortOrder == MediaSortOrder.oldestGrouped,
                      child: Text(L10n.of(context).msgb8140039),
                    ),
                    CheckedPopupMenuItem(
                      value: _ViewMenuAction.sortSizeLargest,
                      checked: provider.sortOrder == MediaSortOrder.sizeLargest,
                      child: Text(L10n.of(context).msg2e2a26bb),
                    ),
                    CheckedPopupMenuItem(
                      value: _ViewMenuAction.sortSizeSmallest,
                      checked: provider.sortOrder == MediaSortOrder.sizeSmallest,
                      child: Text(L10n.of(context).ui_size_small),
                    ),
                    const PopupMenuDivider(),
                    CheckedPopupMenuItem(
                      value: _ViewMenuAction.viewList,
                      checked: !_isGridView,
                      child: Row(
                        children: [
                          const Icon(Broken.row_vertical, size: 18),
                          const SizedBox(width: 8),
                          Text(L10n.of(context).msg829cb1dd),
                        ],
                      ),
                    ),
                    CheckedPopupMenuItem(
                      value: _ViewMenuAction.viewGrid,
                      checked: _isGridView,
                      child: Row(
                        children: [
                          const Icon(Broken.element_3, size: 18),
                          const SizedBox(width: 8),
                          Text(L10n.of(context).ui_grid_view),
                        ],
                      ),
                    ),
                    if (showPlayerController != null) ...[
                      const PopupMenuDivider(),
                      CheckedPopupMenuItem(
                        value: _ViewMenuAction.togglePlayerController,
                        checked: showPlayerController,
                        child: Row(
                          children: [
                            Icon(
                              showPlayerController
                                  ? Icons.toggle_on
                                  : Icons.toggle_off,
                              size: 18,
                            ),
                            const SizedBox(width: 8),
                            Text(
                              showPlayerController
                                  ? L10n.of(context).ui_hide_player_controller
                                  : L10n.of(context).ui_show_player_controller,
                            ),
                          ],
                        ),
                      ),
                    ],
                    if (_supportsRemoteSync) ...[
                      const PopupMenuDivider(),
                      CheckedPopupMenuItem(
                        value: _ViewMenuAction.toggleShowRemoteFiles,
                        checked: _showRemoteFiles,
                        child: Row(
                          children: [
                            Icon(
                              _showRemoteFiles
                                  ? Icons.toggle_on
                                  : Icons.toggle_off,
                              size: 18,
                            ),
                            const SizedBox(width: 8),
                            Text(
                              _showRemoteFiles
                                  ? L10n.of(context).ui_hide_remote_files
                                  : L10n.of(context).ui_show_remote_files,
                            ),
                          ],
                        ),
                      ),
                    ],
                  ],
                );
              },
            ),
            Consumer<MediaProvider>(
              builder: (context, provider, child) {
                final refreshing = provider.isLoading;
                return IconButton(
                  icon: const Icon(Icons.refresh),
                  // 刷新进行中禁用并置灰，避免狂点刷新重复触发全量扫描/并发重建导致闪退
                  onPressed: refreshing
                      ? null
                      : () async {
                          await provider.loadMedia(forceRefresh: true);
                          if (mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text(L10n.of(context).ui_refresh_done),
                                duration: const Duration(seconds: 2),
                              ),
                            );
                          }
                        },
                  tooltip: L10n.of(context).ui_refresh,
                );
              },
            ),
            if (_supportsRemoteSync)
              _buildBackupButton(theme),
            // 检测新增文件并触发自动备份（进入类别且媒体加载完成后执行一次）
            if (_autoSyncEnabled)
              Consumer<MediaProvider>(
                builder: (context, provider, child) {
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    if (!mounted) return;
                    // 守卫：防止每次重建重复触发自动备份
                    if (_autoSyncTriggered) return;
                    final currentCount = _collectCategoryFiles().length;
                    if (provider.isLoaded && currentCount > 0) {
                      _autoSyncTriggered = true;
                      _previousFileCount = currentCount;
                      _maybeAutoSync();
                    }
                  });
                  return const SizedBox.shrink();
                },
              ),
          ],
        ],
      ),
      body: Column(
        children: [
          if (widget.album == null &&
              widget.folderPath == null &&
              _supportsRemoteSync &&
              _showRemoteFiles)
            Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _buildScopeToggle(theme),
                if (_supportsFolderView) _buildFoldersToggle(theme),
              ],
            ),
          if (widget.album == null &&
              widget.mediaType == MediaType.audios &&
              _showResumeAudio)
            _buildResumePlayerButton(theme),
          if (widget.album == null &&
              widget.mediaType == MediaType.videos &&
              _showResumeVideo)
            _buildResumeVideoButton(theme),
          Expanded(
            child: Consumer<MediaProvider>(
              builder: (context, provider, child) {
                if (widget.album == null && _showFoldersMode && widget.folderPath == null) {
                  final folders = widget.mediaType == MediaType.images
                      ? provider.imageFolders
                      : widget.mediaType == MediaType.videos
                          ? provider.videoFolders
                          : provider.audioFolders;
                  if (folders.isEmpty) {
                    // 系统索引仍在查询（冷启动 MediaStore 慢）→ 显示 shimmer；
                    // 不能在加载中就把文件夹模式切回文件视图，否则数据到达后
                    // 仍停留在空文件列表（「音频点进去时灵时不灵」的表现之一）
                    if (!provider.isLoaded) {
                      return _buildShimmerLoading(theme);
                    }
                    // 已加载完成却没有可分组文件夹 → 自动切回文件视图
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      if (mounted && _showFoldersMode) {
                        setState(() => _showFoldersMode = false);
                      }
                    });
                  } else {
                    final entries = folders.entries
                        .where((e) => e.value.isNotEmpty)
                        .where((e) {
                          final isRemote = e.key.startsWith('remote://');
                          return _scopeFilter == _ScopeFilter.remote ? isRemote : !isRemote;
                        })
                        .toList();
                    entries.sort((a, b) {
                      final cmp = b.value.length.compareTo(a.value.length);
                      if (cmp != 0) return cmp;
                      return path_helper.basename(a.key).compareTo(path_helper.basename(b.key));
                    });
                    return GridView.builder(
                      padding: const EdgeInsets.all(12),
                      physics: const BouncingScrollPhysics(),
                      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: 2,
                        crossAxisSpacing: 12,
                        mainAxisSpacing: 12,
                        childAspectRatio: 0.95,
                      ),
                      itemCount: entries.length,
                      itemBuilder: (context, index) {
                        final entry = entries[index];
                        final dir = entry.key;
                        final items = entry.value;
                        final samplePath = _sampleItemPath(items.first);
                        return _MediaFolderTile(
                          folderPath: dir,
                          count: items.length,
                          mediaType: widget.mediaType,
                          samplePath: samplePath,
                          onTap: () {
                            Navigator.push(
                              context,
                              _slideRoute(MediaCategoryScreen(
                                mediaType: widget.mediaType,
                                folderPath: dir,
                                onNavigateTab: widget.onNavigateTab,
                              )),
                            );
                          },
                        );
                      },
                    );
                  }
                }

                if (widget.album != null) {
                  if (_loadingAlbum) {
                    return _buildShimmerLoading(theme);
                  }
                  final displayAssets = List<AssetEntity>.from(_albumAssets);
                  if (provider.sortOrder == MediaSortOrder.newest ||
                      provider.sortOrder == MediaSortOrder.newestGrouped ||
                      provider.sortOrder == MediaSortOrder.dateWise) {
                    displayAssets.sort((a, b) => b.createDateTime.compareTo(a.createDateTime));
                  } else if (provider.sortOrder == MediaSortOrder.oldest ||
                             provider.sortOrder == MediaSortOrder.oldestGrouped) {
                    displayAssets.sort((a, b) => a.createDateTime.compareTo(b.createDateTime));
                  } else if (provider.sortOrder == MediaSortOrder.sizeLargest ||
                             provider.sortOrder == MediaSortOrder.sizeSmallest) {
                    final isSmallest = provider.sortOrder == MediaSortOrder.sizeSmallest;
                    displayAssets.sort((a, b) {
                      final aRes = a.width * a.height;
                      final bRes = b.width * b.height;
                      return isSmallest ? aRes.compareTo(bRes) : bRes.compareTo(aRes);
                    });
                  }

                  final isDateWise = provider.sortOrder == MediaSortOrder.dateWise;
                  final isGrouped = provider.sortOrder == MediaSortOrder.newestGrouped ||
                      provider.sortOrder == MediaSortOrder.oldestGrouped ||
                      provider.sortOrder == MediaSortOrder.dateWise;

                  if (widget.mediaType == MediaType.images) {
                    return _buildImageGrid(displayAssets, theme, isDateWise, isGrouped, _isGridView);
                  } else {
                    return _buildVideoGrid(displayAssets, theme, isDateWise, isGrouped, _isGridView);
                  }
                }

                final isDateWise = provider.sortOrder == MediaSortOrder.dateWise;
                final isGrouped = provider.sortOrder == MediaSortOrder.newestGrouped ||
                    provider.sortOrder == MediaSortOrder.oldestGrouped ||
                    provider.sortOrder == MediaSortOrder.dateWise;

                // 优先显示已加载的数据（缓存或实时），只有数据为空且未完成加载时才显示 shimmer
                Widget? content;
                switch (widget.mediaType) {
                  case MediaType.images:
                    // 打开某个文件夹时，截图也归属该文件夹（扫描时截图按父目录合并进了图片文件夹分组，
                    // 因此文件夹列表里能看到「截图」夹）。但 provider.images 已把截图排除到 provider.screenshots，
                    // 若此处仅按 provider.images 过滤，点进「截图」夹会是空的。故下钻时把同目录的截图一并纳入。
                    final list = widget.folderPath != null
                        ? <dynamic>[
                            ...provider.images.where((f) => _belongsToFolder(f.path, widget.folderPath!)),
                            ...provider.screenshots.where((f) => _belongsToFolder(f.path, widget.folderPath!)),
                          ]
                        : provider.images;
                    final filtered = _filterByScope(list, (dynamic f) => (f as FileSystemEntity).path);
                    content = filtered.isNotEmpty ? _buildImageGrid(filtered, theme, isDateWise, isGrouped, _isGridView) : null;
                    break;
                  case MediaType.videos:
                    final list = widget.folderPath != null
                        ? provider.videos.where((f) => _belongsToFolder(f.path, widget.folderPath!)).toList()
                        : provider.videos;
                    final filtered = _filterByScope(list, (dynamic f) => (f as FileSystemEntity).path);
                    content = filtered.isNotEmpty ? _buildVideoGrid(filtered, theme, isDateWise, isGrouped, _isGridView) : null;
                    break;
                  case MediaType.audios:
                    final list = widget.folderPath != null
                        ? provider.audios.where((s) {
                            if (s.data.isNotEmpty) {
                              return _belongsToFolder(s.data, widget.folderPath!);
                            }
                            // data 为空（该设备 on_audio_query 特例）：归入「未分类音频」虚拟文件夹
                            return widget.folderPath == MediaProvider.unknownAudioFolder;
                          }).toList()
                        : provider.audios;
                    final filtered = _filterByScope(list, (s) => s.data);
                    content = filtered.isNotEmpty ? _buildAudioList(filtered, theme, isDateWise, isGrouped, _isGridView) : null;
                    break;
                  case MediaType.screenshots:
                    final filtered = _filterByScope(provider.screenshots, (dynamic f) => (f as FileSystemEntity).path);
                    content = filtered.isNotEmpty ? _buildImageGrid(filtered, theme, isDateWise, isGrouped, _isGridView) : null;
                    break;
                  case MediaType.archives:
                    final filtered = _filterByScope(provider.archives, (f) => f.path);
                    content = filtered.isNotEmpty ? _buildGenericFileList(filtered, theme, isDateWise, isGrouped, _isGridView) : null;
                    break;
                  case MediaType.downloads:
                    final filtered = _filterByScope(provider.downloads, (f) => f.path);
                    content = filtered.isNotEmpty ? _buildGenericFileList(filtered, theme, isDateWise, isGrouped, _isGridView) : null;
                    break;
                  case MediaType.apks:
                    final filtered = _filterByScope(provider.apks, (f) => f.path);
                    content = filtered.isNotEmpty ? _buildGenericFileList(filtered, theme, isDateWise, isGrouped, _isGridView) : null;
                    break;
                  default:
                    final filtered = _filterByScope(provider.documents, (f) => f.path);
                    content = filtered.isNotEmpty ? _buildDocumentList(filtered, theme, isDateWise, isGrouped, _isGridView) : null;
                }

                if (content != null) {
                  return content;
                }

                // 数据为空时，根据加载状态决定显示 shimmer / 加载失败 / 空状态
                if (!provider.isLoaded) {
                  if (provider.isLoading) {
                    return _buildShimmerLoading(theme);
                  }
                  // 扫描失败或权限缺失（此前为无限 shimmer，表现为
                  // 「类别显示缓存数量但无法打开浏览」的静默失败）→ 显示失败原因与重试入口
                  return _buildLoadFailedState(theme);
                }

                // 非媒体类别（文档/压缩包/下载/安装包）的全盘递归扫描已后台化，
                // 扫描未完成且列表为空（无磁盘缓存可用）时显示 shimmer 而非空状态
                if (_isNonMediaScanType && !provider.nonMediaScanDone && _nonMediaListFor(provider).isEmpty) {
                  return _buildShimmerLoading(theme);
                }

                // 数据为空且已完成加载 → 显示空状态提示（原逻辑会走到这里）
                return _buildEmptyState(theme);
              },
            ),
          ),
        ],
      ),
      bottomNavigationBar: _isSelectionMode ? _buildBottomActionBar(theme) : _buildScanBanner(theme),
      ),
    );
  }

  /// 非媒体类别扫描期间底部提示条：告知正在扫描默认目录、已加载内容可
  /// 正常操作。非模态设计（不遮挡列表交互），扫描完成自动消失。
  Widget? _buildScanBanner(ThemeData theme) {
    if (!_isNonMediaScanType) return null;
    return Consumer<MediaProvider>(
      builder: (context, provider, _) {
        // 正在扫描 或 尚未完成（含缓存恢复阶段）都显示提示条
        if (provider.nonMediaScanDone && !provider.nonMediaScanning) {
          return const SizedBox.shrink();
        }
        return SafeArea(
          top: false,
          child: Material(
            color: theme.colorScheme.surfaceContainerHighest.withOpacity(0.5),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Row(
                children: [
                  SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      valueColor: AlwaysStoppedAnimation<Color>(
                        theme.colorScheme.primary,
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      L10n.of(context).ui_scanning_category,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildBottomActionBar(ThemeData theme) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 8),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.08), blurRadius: 10, offset: const Offset(0, -2))],
      ),
      child: SafeArea(
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          physics: const BouncingScrollPhysics(),
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _buildActionItem(theme, icon: Broken.document_copy, label: L10n.of(context).ui_copy, onTap: () => _handleCopyCut(false)),
              _buildActionItem(theme, icon: Broken.scissor, label: L10n.of(context).ui_cut, onTap: () => _handleCopyCut(true)),
              _buildActionItem(theme, icon: Broken.edit, label: L10n.of(context).msgc8ce4b36, onTap: _handleBatchRename),
              _buildActionItem(theme, icon: Broken.trash, label: L10n.of(context).ui_delete, color: Colors.red, onTap: _handleDelete),
              _buildActionItem(theme, icon: Icons.share_outlined, label: L10n.of(context).ui_share, onTap: _handleShare),
              _buildActionItem(theme, icon: Broken.info_circle, label: L10n.of(context).ui_info, onTap: () => _showPropertiesDialog()),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildActionItem(ThemeData theme, {required IconData icon, required String label, required VoidCallback onTap, Color? color}) {
    final c = color ?? theme.colorScheme.primary;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: c, size: 24),
            const SizedBox(height: 4),
            Text(label, style: TextStyle(color: c, fontSize: 12, fontWeight: FontWeight.w600)),
          ],
        ),
      ),
    );
  }

  Widget _buildShimmerLoading(ThemeData theme) {
    final isDark = theme.brightness == Brightness.dark;
    final baseColor = isDark ? const Color(0xFF1E1E2E) : const Color(0xFFE0E0E0);
    final highlightColor = isDark ? const Color(0xFF2A2A3E) : const Color(0xFFF5F5F5);

    return AnimatedBuilder(
      animation: _shimmerController,
      builder: (context, child) {
        // 列表视图：保持与实际列表一致的视觉占位，避免启动时闪烁网格背景
        if (!_isGridView) {
          return ListView.builder(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            itemCount: 18,
            itemBuilder: (context, index) {
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Row(
                  children: [
                    // 缩略图占位（固定 40x40，与列表图标一致）
                    ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: ShaderMask(
                        shaderCallback: (rect) => LinearGradient(
                          colors: [baseColor, highlightColor, baseColor],
                          stops: [0.0, _shimmerController.value, 1.0],
                        ).createShader(rect),
                        child: const SizedBox(width: 40, height: 40),
                      ),
                    ),
                    const SizedBox(width: 12),
                    // 标题 + 副标题占位
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          ClipRRect(
                            borderRadius: BorderRadius.circular(4),
                            child: ShaderMask(
                              shaderCallback: (rect) => LinearGradient(
                                colors: [baseColor, highlightColor, baseColor],
                                stops: [0.0, _shimmerController.value, 1.0],
                              ).createShader(rect),
                              child: const SizedBox(height: 12, width: double.infinity),
                            ),
                          ),
                          const SizedBox(height: 6),
                          ClipRRect(
                            borderRadius: BorderRadius.circular(4),
                            child: ShaderMask(
                              shaderCallback: (rect) => LinearGradient(
                                colors: [baseColor, highlightColor, baseColor],
                                stops: [0.0, _shimmerController.value, 1.0],
                              ).createShader(rect),
                              child: SizedBox(height: 10, width: MediaQuery.of(context).size.width * 0.4),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              );
            },
          );
        }
        // 网格视图：3 列方块占位
        return GridView.builder(
          padding: const EdgeInsets.all(8),
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 3, crossAxisSpacing: 6, mainAxisSpacing: 6),
          itemCount: 24,
          itemBuilder: (context, index) {
            return ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: ShaderMask(
                shaderCallback: (rect) => LinearGradient(
                  colors: [baseColor, highlightColor, baseColor],
                  stops: [0.0, _shimmerController.value, 1.0],
                ).createShader(rect),
                child: Container(color: baseColor),
              ),
            );
          },
        );
      },
    );
  }

  DateTime _getItemDateTime(dynamic item) {
    if (item is AssetEntity) {
      return item.createDateTime;
    } else if (item is SongModel) {
      // 直接读取 MediaStore 已索引的修改时间（秒级），避免对全量音频逐个
      // 同步 statSync 文件系统——大存储/多文件设备上分组构建会同步打满主线程
      // 导致 ANR/闪退（「音频类别来回切换+频繁刷新即崩」的根因）。
      final secs = item.dateModified ?? item.dateAdded ?? 0;
      return DateTime.fromMillisecondsSinceEpoch(secs * 1000);
    } else if (item is FileSystemEntity) {
      return _fileModifiedOf(item);
    }
    return DateTime.fromMillisecondsSinceEpoch(0);
  }

  /// 音频条目显示用修改时间：优先 MediaStore 的 dateModified，其次 dateAdded，
  /// 均为 0/空时返回 null（由调用方显示「未知」）。零文件系统 I/O。
  DateTime? _songModified(SongModel s) {
    final secs = s.dateModified ?? s.dateAdded ?? 0;
    if (secs <= 0) return null;
    return DateTime.fromMillisecondsSinceEpoch(secs * 1000);
  }

  /// 取文件/目录大小：优先使用系统 MediaStore 索引缓存的字节数（零 I/O），
  /// 其次 remote:// 缓存，最后回退同步 statSync（仅极少触发的递归扫描兜底路径）。
  int _fileSizeOf(FileSystemEntity entity) {
    final p = entity.path;
    if (MediaProvider.isRemotePath(p)) {
      return MediaProvider.getCachedRemoteFileSize(p);
    }
    // 命中系统索引缓存（含 0 字节文件）→ 零 I/O，避免对海量文件逐个 statSync。
    final cached = Provider.of<MediaProvider>(context, listen: false)
        .nonMediaSizes[p];
    if (cached != null) return cached;
    try {
      return entity.statSync().size;
    } catch (_) {
      return 0;
    }
  }

  /// 取文件/目录修改时间：优先使用系统 MediaStore 索引缓存的修改时间(ms)（零 I/O），
  /// 其次 remote:// 缓存，最后回退同步 statSync。避免大存储/多文件设备「按日期」
  /// 分组时 O(n) 同步 I/O 打满主线程（与音频崩溃同源）。
  DateTime _fileModifiedOf(FileSystemEntity entity) {
    final p = entity.path;
    if (MediaProvider.isRemotePath(p)) {
      return MediaProvider.getCachedRemoteFileModified(p) ?? DateTime.now();
    }
    final cached = Provider.of<MediaProvider>(context, listen: false)
        .nonMediaDates[p];
    if (cached != null && cached > 0) {
      return DateTime.fromMillisecondsSinceEpoch(cached);
    }
    try {
      return entity.statSync().modified;
    } catch (_) {
      return DateTime.now();
    }
  }

  Map<String, List<T>> _groupByMonth<T>(List<T> items, DateTime Function(T) getDate) {
    final groups = <String, List<T>>{};
    for (final item in items) {
      final date = getDate(item);
      final monthKey = DateFormat('MMMM yyyy').format(date);
      groups.putIfAbsent(monthKey, () => []).add(item);
    }
    return groups;
  }

  Widget _buildGroupedView<T>({
    required List<T> items,
    required ThemeData theme,
    required bool isGrid,
    required bool isDateWise,
    required Widget Function(T item, bool isDateWise) itemTileBuilder,
  }) {
    if (items.isEmpty) return _buildEmptyState(theme);

    final grouped = _groupByMonth(items, _getItemDateTime);
    final entries = grouped.entries.toList();

    return CustomScrollView(
      physics: const BouncingScrollPhysics(),
      slivers: [
        for (final entry in entries) ...[
          // Month Header
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.only(left: 16, right: 16, top: 16, bottom: 8),
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.primaryContainer.withOpacity(0.35),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(
                        color: theme.colorScheme.primary.withOpacity(0.15),
                      ),
                    ),
                    child: Text(
                      entry.key,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        color: theme.colorScheme.primary,
                        letterSpacing: 0.5,
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Divider(
                      color: theme.colorScheme.outlineVariant.withOpacity(0.3),
                      thickness: 1,
                    ),
                  ),
                ],
              ),
            ),
          ),
          // Group Items (Grid or List)
          if (isGrid)
            SliverPadding(
              padding: const EdgeInsets.symmetric(horizontal: 6),
              sliver: SliverGrid(
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 3,
                  crossAxisSpacing: 6,
                  mainAxisSpacing: 6,
                ),
                delegate: SliverChildBuilderDelegate(
                  (context, index) {
                    final item = entry.value[index];
                    return itemTileBuilder(item, isDateWise);
                  },
                  childCount: entry.value.length,
                ),
              ),
            )
          else
            SliverList(
              delegate: SliverChildBuilderDelegate(
                (context, index) {
                  final item = entry.value[index];
                  return itemTileBuilder(item, isDateWise);
                },
                childCount: entry.value.length,
              ),
            ),
          // Spacing / line after month of files
          SliverToBoxAdapter(
            child: entry.key == entries.last.key
                ? const SizedBox(height: 16)
                : Column(
                    children: [
                      const SizedBox(height: 12),
                      Divider(
                        color: theme.colorScheme.outlineVariant.withOpacity(0.15),
                        thickness: 1.5,
                        indent: 16,
                        endIndent: 16,
                      ),
                      const SizedBox(height: 8),
                    ],
                  ),
          ),
        ],
      ],
    );
  }

  /// 图片缩略图组件：本地路径直接显示，远程路径按需下载到缓存后显示。
  /// 解决此前远程图片用 `Image.file(File(remote://...))` 导致缩略图不显示的问题。
  Widget _RemoteAwareImageTile({
    required String path,
    required List<dynamic> images,
    required bool isSelectionMode,
    required VoidCallback onToggle,
  }) {
    if (!path.startsWith('remote://')) {
      // 本地图片：沿用原先直接 File 读取
      return GestureDetector(
        onTap: () {
          if (isSelectionMode) {
            onToggle();
          } else {
            Navigator.push(context, _slideRoute(ImageViewerScreen(
              imagePath: path,
              siblingItems: images,
            )));
          }
        },
        onLongPress: onToggle,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(10),
          child: path.toLowerCase().endsWith('.svg')
              ? SvgPicture.file(
                  File(path),
                  fit: BoxFit.cover,
                  width: double.infinity,
                  height: double.infinity,
                  placeholderBuilder: (context) => Container(
                    color: Colors.grey.withOpacity(0.1),
                    child: const Center(child: Icon(Broken.image, size: 24, color: Colors.grey)),
                  ),
                )
              : Image.file(
                  File(path),
                  fit: BoxFit.cover,
                  width: double.infinity,
                  height: double.infinity,
                  errorBuilder: (context, error, stackTrace) => Container(
                    color: Colors.grey.withOpacity(0.1),
                    child: const Center(child: Icon(Broken.image, size: 24, color: Colors.grey)),
                  ),
                ),
        ),
      );
    }
    // 远程图片：按需下载到缓存后显示
    return _RemoteImageThumb(
      path: path,
      onTap: () {
        if (isSelectionMode) {
          onToggle();
        } else {
          Navigator.push(context, _slideRoute(ImageViewerScreen(
            imagePath: path,
            siblingItems: images,
          )));
        }
      },
      onLongPress: onToggle,
    );
  }

  Widget _buildImageTile(
    dynamic item,
    ThemeData theme,
    bool isSelected,
    bool showDate,
    String dateStr,
    List<dynamic> images,
  ) {
    final isAsset = item is AssetEntity;
    final id = isAsset ? item.id : item.path;
    final path = isAsset ? '' : item.path;
    final title = isAsset ? (item.title ?? 'Image_$id') : path_helper.basename(path);
    // 本地媒体缩略图开关：控制本地和远程缩略图总开关
    final showMediaPreviews = context.select<FileManagerProvider, bool>((p) => p.showMediaPreviews);
    final showRemoteThumb = PreferencesService.getRemoteMediaThumbnailPreview();
    final isRemote = path.startsWith('remote://');
    final showThumb = showMediaPreviews && (!isRemote || showRemoteThumb);

    return Stack(
      key: ValueKey(id),
      fit: StackFit.expand,
      children: [
        if (isAsset && showThumb)
          _CachedImageTile(
            asset: item,
            onTap: () async {
              if (_isSelectionMode) {
                _toggleSelection(null, item.id);
              } else {
                final file = await item.file;
                if (file != null && mounted) {
                  Navigator.push(context, _slideRoute(ImageViewerScreen(
                    imagePath: file.path,
                    siblingItems: images,
                    initialAssetId: item.id,
                  )));
                }
              }
            },
            onLongPress: () => _toggleSelection(null, item.id),
          )
        else if (!isAsset && showThumb)
          _RemoteAwareImageTile(
            path: path,
            images: images,
            isSelectionMode: _isSelectionMode,
            onToggle: () => _toggleSelection(path, null),
          )
        else
          GestureDetector(
            onTap: () async {
              if (_isSelectionMode) {
                if (isAsset) {
                  _toggleSelection(null, item.id);
                } else {
                  _toggleSelection(path, null);
                }
                return;
              }
              if (isAsset) {
                final f = await item.file;
                if (f != null && mounted) {
                  Navigator.push(context, _slideRoute(ImageViewerScreen(
                    imagePath: f.path,
                    siblingItems: images,
                    initialAssetId: item.id,
                  )));
                }
              } else if (path.isNotEmpty) {
                Navigator.push(context, _slideRoute(ImageViewerScreen(
                  imagePath: path,
                  siblingItems: images,
                )));
              }
            },
            onLongPress: () => isAsset ? _toggleSelection(null, item.id) : _toggleSelection(path, null),
            child: Container(
              color: theme.colorScheme.primaryContainer.withOpacity(0.3),
              child: Center(child: Icon(Broken.image, size: 32, color: theme.colorScheme.onPrimaryContainer.withOpacity(0.6))),
            ),
          ),
        if (showDate)
          Positioned(
            bottom: 4,
            left: 4,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
              decoration: BoxDecoration(color: Colors.black.withOpacity(0.6), borderRadius: BorderRadius.circular(4)),
              child: Text(
                dateStr.split(',').first,
                style: const TextStyle(color: Colors.white, fontSize: 9, fontWeight: FontWeight.w600),
              ),
            ),
          ),
        if (_showCloudBadge(path))
          Positioned(
            top: 4,
            left: 4,
            child: Container(
              padding: const EdgeInsets.all(3),
              decoration: BoxDecoration(
                color: Colors.black.withOpacity(0.5),
                shape: BoxShape.circle,
              ),
              child: const Icon(Broken.cloud, color: Colors.white, size: 12),
            ),
          ),
        if (_isSelectionMode || isSelected)
          Positioned(
            top: 6,
            right: 6,
            child: Icon(
              isSelected ? Broken.tick_square : Icons.check_box_outline_blank,
              color: isSelected ? theme.colorScheme.primary : Colors.white.withOpacity(0.8),
              size: 24,
            ),
          )
        else
          Positioned(
            top: 4,
            right: 4,
            child: InkWell(
              onTap: () async {
                if (isAsset) {
                  final f = await item.file;
                  if (f != null) {
                    _showSingleItemOptions(name: title, filePath: f.path, assetId: item.id);
                  }
                } else {
                  _showSingleItemOptions(name: title, filePath: path);
                }
              },
              child: Container(
                padding: const EdgeInsets.all(4),
                decoration: BoxDecoration(color: Colors.black.withOpacity(0.5), shape: BoxShape.circle),
                child: const Icon(Broken.more, color: Colors.white, size: 18),
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildImageGrid(List<dynamic> images, ThemeData theme, bool isDateWise, bool isGrouped, bool isGridView) {
    if (images.isEmpty) return _buildEmptyState(theme);
    if (isGrouped) {
      return _buildGroupedView<dynamic>(
        items: images,
        theme: theme,
        isGrid: isGridView,
        isDateWise: isDateWise,
        itemTileBuilder: (item, showDate) {
          final isSelected = item is AssetEntity
              ? _selectedAssetIds.contains(item.id)
              : _selectedFilePaths.contains(item.path);
          DateTime date = DateTime.fromMillisecondsSinceEpoch(0);
          if (item is AssetEntity) {
            date = item.createDateTime;
          } else if (item is FileSystemEntity) {
            date = _fileModifiedOf(item);
          }
          final dateStr = FileUtils.formatDate(date);
          return _SelectedFrame(
            selected: isSelected,
            isList: !isGridView,
            theme: theme,
            child: isGridView
                ? _buildImageTile(item, theme, isSelected, showDate, dateStr, images)
                : _buildImageListTile(item, theme, isSelected, showDate, dateStr, images),
          );
        },
      );
    }
    if (isGridView) {
      return GridView.builder(
        padding: const EdgeInsets.all(6),
        physics: const BouncingScrollPhysics(),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 3, crossAxisSpacing: 6, mainAxisSpacing: 6),
        itemCount: images.length,
        itemBuilder: (context, index) {
          final item = images[index];
          final isSelected = item is AssetEntity
              ? _selectedAssetIds.contains(item.id)
              : _selectedFilePaths.contains(item.path);
          DateTime date = DateTime.fromMillisecondsSinceEpoch(0);
          if (item is AssetEntity) {
            date = item.createDateTime;
          } else if (item is FileSystemEntity) {
            date = _fileModifiedOf(item);
          }
          final dateStr = FileUtils.formatDate(date);
          return _SelectedFrame(
            selected: isSelected,
            isList: false,
            theme: theme,
            child: _buildImageTile(item, theme, isSelected, isDateWise, dateStr, images),
          );
        },
      );
    }
    return ListView.builder(
      physics: const BouncingScrollPhysics(),
      itemCount: images.length,
      itemBuilder: (context, index) {
        final item = images[index];
        final isSelected = item is AssetEntity
            ? _selectedAssetIds.contains(item.id)
            : _selectedFilePaths.contains(item.path);
        DateTime date = DateTime.fromMillisecondsSinceEpoch(0);
        if (item is AssetEntity) {
          date = item.createDateTime;
        } else if (item is FileSystemEntity) {
          date = _fileModifiedOf(item);
        }
        final dateStr = FileUtils.formatDate(date);
        return _SelectedFrame(
          selected: isSelected,
          isList: true,
          theme: theme,
          child: _buildImageListTile(item, theme, isSelected, isDateWise, dateStr, images),
        );
      },
    );
  }

  /// 图片的列表视图 tile：缩略图 + 标题 + 日期
  Widget _buildImageListTile(
    dynamic item,
    ThemeData theme,
    bool isSelected,
    bool showDate,
    String dateStr,
    List<dynamic> images,
  ) {
    final isAsset = item is AssetEntity;
    final id = isAsset ? item.id : item.path;
    final path = isAsset ? '' : item.path;
    final title = isAsset ? (item.title ?? 'Image_$id') : path_helper.basename(path);

    return ListTile(
      key: ValueKey(id),
      onTap: () async {
        if (_isSelectionMode) {
          _toggleSelection(isAsset ? null : path, isAsset ? id : null);
        } else {
          if (isAsset) {
            final file = await item.file;
            if (file != null && mounted) {
              Navigator.push(context, _slideRoute(ImageViewerScreen(
                imagePath: file.path,
                siblingItems: images,
                initialAssetId: item.id,
              )));
            }
          } else {
            Navigator.push(context, _slideRoute(ImageViewerScreen(
              imagePath: path,
              siblingItems: images,
            )));
          }
        }
      },
      onLongPress: () => _toggleSelection(isAsset ? null : path, isAsset ? id : null),
      leading: Stack(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: SizedBox(
              width: 40,
              height: 40,
              child: isAsset
                  ? _CachedImageTile(
                      asset: item,
                      onTap: () {},
                      onLongPress: () {},
                    )
                  : path.toLowerCase().endsWith('.svg')
                      ? SvgPicture.file(File(path), fit: BoxFit.cover,
                          placeholderBuilder: (context) => Container(
                            color: Colors.grey.withOpacity(0.1),
                            child: const Center(child: Icon(Broken.image, size: 20, color: Colors.grey)),
                          ),
                        )
                      : Image.file(File(path), fit: BoxFit.cover,
                          errorBuilder: (context, error, stackTrace) => Container(
                            color: Colors.grey.withOpacity(0.1),
                            child: const Center(child: Icon(Broken.image, size: 20, color: Colors.grey)),
                          ),
                        ),
            ),
          ),
          if (_showCloudBadge(path))
            Positioned(
              top: 0,
              left: 0,
              child: Container(
                padding: const EdgeInsets.all(2),
                decoration: BoxDecoration(
                  color: Colors.black.withOpacity(0.55),
                  borderRadius: const BorderRadius.only(bottomRight: Radius.circular(6), topLeft: Radius.circular(8)),
                ),
                child: const Icon(Broken.cloud, color: Colors.white, size: 10),
              ),
            ),
          if (_isSelectionMode || isSelected)
            Positioned(
              bottom: 0,
              right: 0,
              child: Icon(
                isSelected ? Broken.tick_square : Icons.check_box_outline_blank,
                color: isSelected ? theme.colorScheme.primary : Colors.white.withOpacity(0.8),
                size: 20,
              ),
            ),
        ],
      ),
      title: Row(
        children: [
          Expanded(child: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis)),
        ],
      ),
      subtitle: showDate ? Text(dateStr, style: TextStyle(fontSize: 12, color: theme.colorScheme.onSurface.withOpacity(0.5))) : null,
      trailing: _isSelectionMode
          ? null
          : IconButton(
              icon: const Icon(Broken.more),
              onPressed: () async {
                if (isAsset) {
                  final f = await item.file;
                  if (f != null) {
                    _showSingleItemOptions(name: title, filePath: f.path, assetId: item.id);
                  }
                } else {
                  _showSingleItemOptions(name: title, filePath: path);
                }
              },
            ),
    );
  }

  Widget _RemoteVideoTile({
    required String remotePath,
    required VoidCallback onTap,
    required VoidCallback onLongPress,
  }) {
    return _RemoteVideoTileWidget(
      remotePath: remotePath,
      onTap: onTap,
      onLongPress: onLongPress,
    );
  }

  Widget _buildVideoTile(
    dynamic item,
    ThemeData theme,
    bool isSelected,
    bool showDate,
    String dateStr,
    List<dynamic> videoList,
  ) {
    final isAsset = item is AssetEntity;
    final id = isAsset ? item.id : item.path;
    final path = isAsset ? '' : item.path;
    final title = isAsset ? (item.title ?? 'Video_$id') : path_helper.basename(path);
    // 本地媒体缩略图开关：控制本地和远程缩略图总开关
    final showMediaPreviews = context.select<FileManagerProvider, bool>((p) => p.showMediaPreviews);
    // 远程媒体缩略图开关：仅控制远程文件缩略图
    final showRemoteThumb = PreferencesService.getRemoteMediaThumbnailPreview();
    // 是否为远程文件
    final isRemote = path.startsWith('remote://');
    // 缩略图总开关开启 且（本地文件 或 远程开关开启）才显示缩略图
    final showThumb = showMediaPreviews && (!isRemote || showRemoteThumb);

    return Stack(
      key: ValueKey(id),
      fit: StackFit.expand,
      children: [
        if (isAsset && showThumb)
          _CachedVideoTile(
            asset: item,
            onTap: () async {
              if (_isSelectionMode) {
                _toggleSelection(null, item.id);
              } else {
                final file = await item.file;
                if (file != null && mounted) {
                  Navigator.push(
                    context,
                    _slideRoute(
                      VideoPlayerScreen(
                        videoPath: file.path,
                        playlist: videoList,
                        initialIndex: videoList.indexOf(item),
                      ),
                    ),
                  ).then((_) {
                    if (mounted) setState(() {});
                  });
                }
              }
            },
            onLongPress: () => _toggleSelection(null, item.id),
          )
        else if (isRemote && showThumb)
          _RemoteVideoTile(
            remotePath: path,
            onTap: () {
              if (_isSelectionMode) {
                _toggleSelection(path, null);
              } else {
                Navigator.push(
                  context,
                  _slideRoute(
                    VideoPlayerScreen(
                      videoPath: path,
                      playlist: videoList,
                      initialIndex: videoList.indexOf(item),
                    ),
                  ),
                ).then((_) {
                  if (mounted) setState(() {});
                });
              }
            },
            onLongPress: () => _toggleSelection(path, null),
          )
        else
          GestureDetector(
            onTap: () {
              if (_isSelectionMode) {
                _toggleSelection(path, null);
              } else {
                Navigator.push(
                  context,
                  _slideRoute(
                    VideoPlayerScreen(
                      videoPath: path,
                      playlist: videoList,
                      initialIndex: videoList.indexOf(item),
                    ),
                  ),
                ).then((_) {
                  if (mounted) setState(() {});
                });
              }
            },
            onLongPress: () => _toggleSelection(path, null),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: _LocalVideoTile(filePath: path, title: title, theme: theme),
            ),
          ),
        if (showDate)
          Positioned(
            bottom: 4,
            left: 4,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
              decoration: BoxDecoration(color: Colors.black.withOpacity(0.6), borderRadius: BorderRadius.circular(4)),
              child: Text(
                dateStr.split(',').first,
                style: const TextStyle(color: Colors.white, fontSize: 9, fontWeight: FontWeight.w600),
              ),
            ),
          ),
        if (_showCloudBadge(path))
          Positioned(
            top: 4,
            left: 4,
            child: Container(
              padding: const EdgeInsets.all(3),
              decoration: BoxDecoration(
                color: Colors.black.withOpacity(0.5),
                shape: BoxShape.circle,
              ),
              child: const Icon(Broken.cloud, color: Colors.white, size: 12),
            ),
          ),
        if (_isSelectionMode || isSelected)
          Positioned(
            top: 6,
            right: 6,
            child: Icon(
              isSelected ? Broken.tick_square : Icons.check_box_outline_blank,
              color: isSelected ? theme.colorScheme.primary : Colors.white.withOpacity(0.8),
              size: 24,
            ),
          )
        else
          Positioned(
            top: 4,
            right: 4,
            child: InkWell(
              onTap: () async {
                if (isAsset) {
                  final f = await item.file;
                  if (f != null) {
                    _showSingleItemOptions(name: title, filePath: f.path, assetId: item.id);
                  }
                } else {
                  _showSingleItemOptions(name: title, filePath: path);
                }
              },
              child: Container(
                padding: const EdgeInsets.all(4),
                decoration: BoxDecoration(color: Colors.black.withOpacity(0.5), shape: BoxShape.circle),
                child: const Icon(Broken.more, color: Colors.white, size: 18),
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildVideoGrid(List<dynamic> videos, ThemeData theme, bool isDateWise, bool isGrouped, bool isGridView) {
    if (videos.isEmpty) return _buildEmptyState(theme);
    if (isGrouped) {
      return _buildGroupedView<dynamic>(
        items: videos,
        theme: theme,
        isGrid: isGridView,
        isDateWise: isDateWise,
        itemTileBuilder: (item, showDate) {
          final isSelected = item is AssetEntity
              ? _selectedAssetIds.contains(item.id)
              : _selectedFilePaths.contains(item.path);
          DateTime date = DateTime.fromMillisecondsSinceEpoch(0);
          if (item is AssetEntity) {
            date = item.createDateTime;
          } else if (item is FileSystemEntity) {
            date = _fileModifiedOf(item);
          }
          final dateStr = FileUtils.formatDate(date);
          return _SelectedFrame(
            selected: isSelected,
            isList: !isGridView,
            theme: theme,
            child: isGridView
                ? _buildVideoTile(item, theme, isSelected, showDate, dateStr, videos)
                : _buildVideoListTile(item, theme, isSelected, showDate, dateStr, videos),
          );
        },
      );
    }
    if (isGridView) {
      return GridView.builder(
        padding: const EdgeInsets.all(6),
        physics: const BouncingScrollPhysics(),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 3, crossAxisSpacing: 6, mainAxisSpacing: 6),
        itemCount: videos.length,
        itemBuilder: (context, index) {
          final item = videos[index];
          final isSelected = item is AssetEntity
              ? _selectedAssetIds.contains(item.id)
              : _selectedFilePaths.contains(item.path);
          DateTime date = DateTime.fromMillisecondsSinceEpoch(0);
          if (item is AssetEntity) {
            date = item.createDateTime;
          } else if (item is FileSystemEntity) {
            date = _fileModifiedOf(item);
          }
          final dateStr = FileUtils.formatDate(date);
          return _SelectedFrame(
            selected: isSelected,
            isList: false,
            theme: theme,
            child: _buildVideoTile(item, theme, isSelected, isDateWise, dateStr, videos),
          );
        },
      );
    }
    return ListView.builder(
      physics: const BouncingScrollPhysics(),
      itemCount: videos.length,
      itemBuilder: (context, index) {
        final item = videos[index];
        final isSelected = item is AssetEntity
            ? _selectedAssetIds.contains(item.id)
            : _selectedFilePaths.contains(item.path);
        DateTime date = DateTime.fromMillisecondsSinceEpoch(0);
        if (item is AssetEntity) {
          date = item.createDateTime;
        } else if (item is FileSystemEntity) {
          date = _fileModifiedOf(item);
        }
        final dateStr = FileUtils.formatDate(date);
        return _SelectedFrame(
          selected: isSelected,
          isList: true,
          theme: theme,
          child: _buildVideoListTile(item, theme, isSelected, isDateWise, dateStr, videos),
        );
      },
    );
  }

  /// 视频的列表视图 tile：缩略图 + 标题 + 日期
  Widget _buildVideoListTile(
    dynamic item,
    ThemeData theme,
    bool isSelected,
    bool showDate,
    String dateStr,
    List<dynamic> videoList,
  ) {
    final isAsset = item is AssetEntity;
    final id = isAsset ? item.id : item.path;
    final path = isAsset ? '' : item.path;
    final title = isAsset ? (item.title ?? 'Video_$id') : path_helper.basename(path);
    // 本地媒体缩略图开关：控制本地和远程缩略图总开关
    final showMediaPreviews = context.select<FileManagerProvider, bool>((p) => p.showMediaPreviews);
    // 远程媒体缩略图开关：仅控制远程文件缩略图
    final showRemoteThumb = PreferencesService.getRemoteMediaThumbnailPreview();
    final isRemote = path.startsWith('remote://');
    final showThumb = showMediaPreviews && (!isRemote || showRemoteThumb);

    return ListTile(
      key: ValueKey(id),
      onTap: () async {
        if (_isSelectionMode) {
          _toggleSelection(isAsset ? null : path, isAsset ? id : null);
        } else {
          if (isAsset) {
            final file = await item.file;
            if (file != null && mounted) {
              Navigator.push(context, _slideRoute(VideoPlayerScreen(
                videoPath: file.path,
                playlist: videoList,
                initialIndex: videoList.indexOf(item),
              ))).then((_) {
                if (mounted) setState(() {});
              });
            }
          } else {
            Navigator.push(context, _slideRoute(VideoPlayerScreen(
              videoPath: path,
              playlist: videoList,
              initialIndex: videoList.indexOf(item),
            ))).then((_) {
              if (mounted) setState(() {});
            });
          }
        }
      },
      onLongPress: () => _toggleSelection(isAsset ? null : path, isAsset ? id : null),
      leading: Stack(
        children: [
          // 缩略图受开关控制：本地开关关闭时不显示任何缩略图；
          // 本地开关开启时，远程文件还需远程开关开启
          if (isAsset && showThumb)
            _VideoListThumbnail(asset: item, size: 40)
          else if (isRemote && showThumb)
            _VideoListThumbnail(remotePath: path, size: 40)
          else if (!isRemote && showThumb)
            _VideoListThumbnail(filePath: path, size: 40)
          else
            Icon(Broken.video, size: 40, color: theme.colorScheme.primary.withOpacity(0.6)),
          if (_showCloudBadge(path))
            Positioned(
              top: 0,
              left: 0,
              child: Container(
                padding: const EdgeInsets.all(2),
                decoration: BoxDecoration(
                  color: Colors.black.withOpacity(0.55),
                  borderRadius: const BorderRadius.only(bottomRight: Radius.circular(6), topLeft: Radius.circular(8)),
                ),
                child: const Icon(Broken.cloud, color: Colors.white, size: 10),
              ),
            ),
          if (_isSelectionMode || isSelected)
            Positioned(
              bottom: 0,
              right: 0,
              child: Icon(
                isSelected ? Broken.tick_square : Icons.check_box_outline_blank,
                color: isSelected ? theme.colorScheme.primary : Colors.white.withOpacity(0.8),
                size: 20,
              ),
            ),
        ],
      ),
      title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: showDate ? Text(dateStr, style: TextStyle(fontSize: 12, color: theme.colorScheme.onSurface.withOpacity(0.5))) : null,
      trailing: _isSelectionMode
          ? null
          : IconButton(
              icon: const Icon(Broken.more),
              onPressed: () async {
                if (isAsset) {
                  final f = await item.file;
                  if (f != null) {
                    _showSingleItemOptions(name: title, filePath: f.path, assetId: item.id);
                  }
                } else {
                  _showSingleItemOptions(name: title, filePath: path);
                }
              },
            ),
    );
  }

  Widget _buildAudioTile(
    SongModel audio,
    ThemeData theme,
    bool isSelected,
    bool showDate,
    String dateStr,
    int index,
    List<SongModel> audios,
  ) {
    final path = audio.data;
    // 本地媒体缩略图开关：控制本地音频封面显示
    final showMediaPreviews = context.select<FileManagerProvider, bool>((p) => p.showMediaPreviews);
    return ListTile(
      key: ValueKey(path),
      onTap: () {
        if (_isSelectionMode) {
          _toggleSelection(path, null);
        } else {
          Navigator.push(
            context,
            PageRouteBuilder(
              pageBuilder: (context, animation, secondaryAnimation) => AudioPlayerScreen(
                audioPath: path,
                title: audio.title,
                artist: _isUnknownArtist(audio.artist) ? L10n.of(context).msg5e32276d : audio.artist!,
                allSongs: audios,
                initialIndex: index,
              ),
              transitionsBuilder: (context, animation, secondaryAnimation, child) => SlideTransition(
                position: Tween<Offset>(begin: const Offset(0, 1), end: Offset.zero).animate(CurvedAnimation(parent: animation, curve: Curves.easeOutCubic)),
                child: child,
              ),
              transitionDuration: const Duration(milliseconds: 400),
            ),
          ).then((_) {
            // 返回类别页时刷新按钮状态，确保显示最新的 lastPlayed
            if (mounted) setState(() {});
          });
        }
      },
      onLongPress: () => _toggleSelection(path, null),
      leading: Stack(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(borderRadius: BorderRadius.circular(10), color: theme.colorScheme.primaryContainer),
            child: showMediaPreviews
                ? QueryArtworkWidget(
                    id: audio.id,
                    type: ArtworkType.AUDIO,
                    artworkBorder: BorderRadius.circular(10),
                    artworkFit: BoxFit.cover,
                    artworkWidth: 40,
                    artworkHeight: 40,
                    nullArtworkWidget: Icon(Icons.music_note, size: 22, color: theme.colorScheme.onPrimaryContainer),
                  )
                : Icon(Icons.music_note, size: 22, color: theme.colorScheme.onPrimaryContainer),
          ),
          if (_showCloudBadge(path))
            Positioned(
              top: 0,
              left: 0,
              child: Container(
                padding: const EdgeInsets.all(2),
                decoration: BoxDecoration(
                  color: Colors.black.withOpacity(0.55),
                  borderRadius: const BorderRadius.only(bottomRight: Radius.circular(6), topLeft: Radius.circular(10)),
                ),
                child: const Icon(Broken.cloud, color: Colors.white, size: 10),
              ),
            ),
          if (_isSelectionMode || isSelected)
            Positioned(
              bottom: 0,
              right: 0,
              child: Container(
                decoration: BoxDecoration(color: theme.colorScheme.surface, shape: BoxShape.circle),
                child: Icon(isSelected ? Broken.tick_square : Icons.check_box_outline_blank, color: isSelected ? theme.colorScheme.primary : Colors.grey, size: 20),
              ),
            ),
          if (_showCloudBadge(path))
            Positioned(
              top: 0,
              left: 0,
              child: Container(
                padding: const EdgeInsets.all(2),
                decoration: BoxDecoration(color: Colors.black.withOpacity(0.55), shape: BoxShape.circle),
                child: const Icon(Broken.cloud, color: Colors.white, size: 10),
              ),
            ),
        ],
      ),
      title: Text(audio.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
      subtitle: Text(
        showDate
            ? '${_isUnknownArtist(audio.artist) ? L10n.of(context).msg5e32276d : audio.artist!} \u2022 $dateStr'
            : _isUnknownArtist(audio.artist) ? L10n.of(context).msg5e32276d : audio.artist!,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(color: theme.colorScheme.onSurface.withOpacity(0.55), fontSize: 11),
      ),
      trailing: _isSelectionMode
          ? null
          : IconButton(
              icon: const Icon(Broken.more),
              onPressed: () => _showSingleItemOptions(name: audio.title, filePath: path),
            ),
    );
  }

  Widget _buildAudioList(List<SongModel> audios, ThemeData theme, bool isDateWise, bool isGrouped, bool isGridView) {
    if (audios.isEmpty) return _buildEmptyState(theme);
    if (isGrouped) {
      return _buildGroupedView<SongModel>(
        items: audios,
        theme: theme,
        isGrid: isGridView,
        isDateWise: isDateWise,
        itemTileBuilder: (audio, showDate) {
          final path = audio.data;
          final isSelected = _selectedFilePaths.contains(path);
          final modified = _songModified(audio);
          final dateStr = modified != null ? FileUtils.formatDate(modified) : L10n.of(context).msg424a0110;
          final index = audios.indexOf(audio);
          return _SelectedFrame(
            selected: isSelected,
            isList: !isGridView,
            theme: theme,
            child: isGridView
                ? _buildAudioGridTile(audio, theme, isSelected, showDate, dateStr, index, audios)
                : _buildAudioTile(audio, theme, isSelected, showDate, dateStr, index, audios),
          );
        },
      );
    }
    if (isGridView) {
      return GridView.builder(
        padding: const EdgeInsets.all(6),
        physics: const BouncingScrollPhysics(),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 3, crossAxisSpacing: 6, mainAxisSpacing: 6),
        itemCount: audios.length,
        itemBuilder: (context, index) {
          final audio = audios[index];
          final path = audio.data;
          final isSelected = _selectedFilePaths.contains(path);
          final modified = _songModified(audio);
          final dateStr = modified != null ? FileUtils.formatDate(modified) : L10n.of(context).msg424a0110;
          return _SelectedFrame(
            selected: isSelected,
            isList: false,
            theme: theme,
            child: _buildAudioGridTile(audio, theme, isSelected, isDateWise, dateStr, index, audios),
          );
        },
      );
    }
    return ListView.builder(
      physics: const BouncingScrollPhysics(),
      itemCount: audios.length,
      itemBuilder: (context, index) {
        final audio = audios[index];
        final path = audio.data;
        final isSelected = _selectedFilePaths.contains(path);
        final modified = _songModified(audio);
        final dateStr = modified != null ? FileUtils.formatDate(modified) : L10n.of(context).msg424a0110;
        return _SelectedFrame(
          selected: isSelected,
          isList: true,
          theme: theme,
          child: _buildAudioTile(audio, theme, isSelected, isDateWise, dateStr, index, audios),
        );
      },
    );
  }

  /// 音频的网格视图 tile：图标 + 标题 + 艺术家
  Widget _buildAudioGridTile(
    SongModel audio,
    ThemeData theme,
    bool isSelected,
    bool showDate,
    String dateStr,
    int index,
    List<SongModel> audios,
  ) {
    final path = audio.data;
    final title = audio.title;
    final artist = _isUnknownArtist(audio.artist) ? L10n.of(context).msg5e32276d : audio.artist!;

    return GestureDetector(
      key: ValueKey(path),
      onTap: () {
        if (_isSelectionMode) {
          _toggleSelection(path, null);
        } else {
          Navigator.push(
            context,
            PageRouteBuilder(
              pageBuilder: (context, animation, secondaryAnimation) => AudioPlayerScreen(
                audioPath: path,
                title: title,
                artist: _isUnknownArtist(audio.artist) ? L10n.of(context).msg5e32276d : audio.artist!,
                allSongs: audios,
                initialIndex: index,
              ),
              transitionsBuilder: (context, animation, secondaryAnimation, child) => SlideTransition(
                position: Tween<Offset>(begin: const Offset(0, 1), end: Offset.zero).animate(CurvedAnimation(parent: animation, curve: Curves.easeOutCubic)),
                child: child,
              ),
              transitionDuration: const Duration(milliseconds: 400),
            ),
          ).then((_) {
            if (mounted) setState(() {});
          });
        }
      },
      onLongPress: () => _toggleSelection(path, null),
      child: Stack(
        fit: StackFit.expand,
        children: [
          Container(
            decoration: BoxDecoration(
              color: theme.colorScheme.primaryContainer.withOpacity(0.2),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Broken.music, size: 32, color: theme.colorScheme.primary),
                const SizedBox(height: 8),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  child: Text(title, maxLines: 2, overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w500),
                  ),
                ),
                const SizedBox(height: 4),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  child: Text(artist, maxLines: 1, overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 10, color: theme.colorScheme.onSurface.withOpacity(0.5)),
                  ),
                ),
              ],
            ),
          ),
          if (showDate)
            Positioned(
              bottom: 4,
              left: 4,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                decoration: BoxDecoration(color: Colors.black.withOpacity(0.6), borderRadius: BorderRadius.circular(4)),
                child: Text(
                  dateStr.split(',').first,
                  style: const TextStyle(color: Colors.white, fontSize: 9, fontWeight: FontWeight.w600),
                ),
              ),
            ),
          if (_isSelectionMode || isSelected)
            Positioned(
              top: 6,
              right: 6,
              child: Icon(
                isSelected ? Broken.tick_square : Icons.check_box_outline_blank,
                color: isSelected ? theme.colorScheme.primary : Colors.white.withOpacity(0.8),
                size: 24,
              ),
            )
          else
            Positioned(
              top: 4,
              right: 4,
              child: InkWell(
                onTap: () => _showSingleItemOptions(name: title, filePath: path),
                child: Container(
                  padding: const EdgeInsets.all(4),
                  decoration: BoxDecoration(color: Colors.black.withOpacity(0.5), shape: BoxShape.circle),
                  child: const Icon(Broken.more, color: Colors.white, size: 18),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildDocumentTile(
    FileSystemEntity doc,
    ThemeData theme,
    bool isSelected,
    bool showDate,
    int size,
    DateTime modified,
  ) {
    final path = doc.path;
    final name = path.split('/').last;
    final ext = name.contains('.') ? name.substring(name.lastIndexOf('.')).toLowerCase() : '';
    final icon = _docIcon(ext);
    final color = _docColor(ext);

    return ListTile(
      key: ValueKey(path),
      onTap: () {
        if (_isSelectionMode) {
          _toggleSelection(path, null);
        } else {
          context.read<FileManagerProvider>().openFile(context, path);
        }
      },
      onLongPress: () => _toggleSelection(path, null),
      leading: Stack(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(color: color.withOpacity(0.15), borderRadius: BorderRadius.circular(10)),
            child: Center(
              child: FileTypeIcon(
                icon: icon,
                label: FileUtils.getDocumentTypeLabel(path),
                color: color,
                iconScale: 1.0,
              ),
            ),
          ),
          if (_isSelectionMode || isSelected)
            Positioned(
              bottom: 0,
              right: 0,
              child: Container(
                decoration: BoxDecoration(color: theme.colorScheme.surface, shape: BoxShape.circle),
                child: Icon(isSelected ? Broken.tick_square : Icons.check_box_outline_blank, color: isSelected ? theme.colorScheme.primary : Colors.grey, size: 20),
              ),
            ),
          if (_showCloudBadge(path))
            Positioned(
              top: 0,
              left: 0,
              child: Container(
                padding: const EdgeInsets.all(2),
                decoration: BoxDecoration(color: Colors.black.withOpacity(0.55), shape: BoxShape.circle),
                child: const Icon(Broken.cloud, color: Colors.white, size: 10),
              ),
            ),
        ],
      ),
      title: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w500)),
      subtitle: Text(
        showDate
            ? '${FileUtils.formatBytes(size, 1)} • ${FileUtils.formatDate(modified)}'
            : FileUtils.formatBytes(size, 1),
        style: TextStyle(color: theme.colorScheme.onSurface.withOpacity(0.6), fontSize: 11),
      ),
      trailing: _isSelectionMode
          ? null
          : IconButton(
              icon: const Icon(Broken.more),
              onPressed: () => _showSingleItemOptions(name: name, filePath: path),
            ),
    );
  }

  Widget _buildDocumentList(List<FileSystemEntity> documents, ThemeData theme, bool isDateWise, bool isGrouped, bool isGridView) {
    if (documents.isEmpty) return _buildEmptyState(theme);
    if (isGrouped) {
      return _buildGroupedView<FileSystemEntity>(
        items: documents,
        theme: theme,
        isGrid: isGridView,
        isDateWise: isDateWise,
        itemTileBuilder: (doc, showDate) {
          final isSelected = _selectedFilePaths.contains(doc.path);
          final size = _fileSizeOf(doc);
          final modified = _fileModifiedOf(doc);
          return _SelectedFrame(
            selected: isSelected,
            isList: !isGridView,
            theme: theme,
            child: isGridView
                ? _buildDocumentGridTile(doc, theme, isSelected, showDate, size, modified)
                : _buildDocumentTile(doc, theme, isSelected, showDate, size, modified),
          );
        },
      );
    }
    if (isGridView) {
      return GridView.builder(
        padding: const EdgeInsets.all(6),
        physics: const BouncingScrollPhysics(),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 3, crossAxisSpacing: 6, mainAxisSpacing: 6),
        itemCount: documents.length,
        itemBuilder: (context, index) {
          final doc = documents[index];
          final isSelected = _selectedFilePaths.contains(doc.path);
          final size = _fileSizeOf(doc);
          final modified = _fileModifiedOf(doc);
          return _SelectedFrame(
            selected: isSelected,
            isList: false,
            theme: theme,
            child: _buildDocumentGridTile(doc, theme, isSelected, isDateWise, size, modified),
          );
        },
      );
    }
    return ListView.builder(
      physics: const BouncingScrollPhysics(),
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: documents.length,
      itemBuilder: (context, index) {
        final doc = documents[index];
        final isSelected = _selectedFilePaths.contains(doc.path);
        final size = _fileSizeOf(doc);
        final modified = _fileModifiedOf(doc);
        return _SelectedFrame(
          selected: isSelected,
          isList: true,
          theme: theme,
          child: _buildDocumentTile(doc, theme, isSelected, isDateWise, size, modified),
        );
      },
    );
  }

  /// 文档的网格视图 tile：图标 + 文件名 + 大小
  Widget _buildDocumentGridTile(
    FileSystemEntity doc,
    ThemeData theme,
    bool isSelected,
    bool showDate,
    int size,
    DateTime modified,
  ) {
    final path = doc.path;
    final name = path.split('/').last;
    final ext = name.contains('.') ? name.substring(name.lastIndexOf('.')).toLowerCase() : '';
    final icon = _docIcon(ext);
    final color = _docColor(ext);
    final dateStr = FileUtils.formatDate(modified);

    return GestureDetector(
      key: ValueKey(path),
      onTap: () {
        if (_isSelectionMode) {
          _toggleSelection(path, null);
        } else {
          context.read<FileManagerProvider>().openFile(context, path);
        }
      },
      onLongPress: () => _toggleSelection(path, null),
      child: Stack(
        fit: StackFit.expand,
        children: [
          Container(
            decoration: BoxDecoration(
              color: color.withOpacity(0.1),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: color.withOpacity(0.15)),
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(color: color.withOpacity(0.15), borderRadius: BorderRadius.circular(10)),
                  child: Center(
                    child: FileTypeIcon(
                      icon: icon,
                      label: FileUtils.getDocumentTypeLabel(path),
                      color: color,
                      iconScale: 1.0,
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  child: Text(name, maxLines: 2, overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w500),
                  ),
                ),
                const SizedBox(height: 2),
                Text(FileUtils.formatBytes(size, 2), style: TextStyle(fontSize: 10, color: theme.colorScheme.onSurface.withOpacity(0.5))),
                if (showDate)
                  Text(dateStr.split(',').first, style: TextStyle(fontSize: 9, color: theme.colorScheme.onSurface.withOpacity(0.4))),
              ],
            ),
          ),
          if (_isSelectionMode || isSelected)
            Positioned(
              top: 6,
              right: 6,
              child: Icon(
                isSelected ? Broken.tick_square : Icons.check_box_outline_blank,
                color: isSelected ? theme.colorScheme.primary : Colors.white.withOpacity(0.8),
                size: 24,
              ),
            )
          else
            Positioned(
              top: 4,
              right: 4,
              child: InkWell(
                onTap: () => _showSingleItemOptions(name: name, filePath: path),
                child: Container(
                  padding: const EdgeInsets.all(4),
                  decoration: BoxDecoration(color: Colors.black.withOpacity(0.5), shape: BoxShape.circle),
                  child: const Icon(Broken.more, color: Colors.white, size: 18),
                ),
              ),
            ),
          if (_showCloudBadge(path))
            Positioned(
              top: 4,
              left: 4,
              child: Container(
                padding: const EdgeInsets.all(3),
                decoration: BoxDecoration(color: Colors.black.withOpacity(0.5), shape: BoxShape.circle),
                child: const Icon(Broken.cloud, color: Colors.white, size: 12),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildGenericFileTile(
    FileSystemEntity file,
    ThemeData theme,
    bool isSelected,
    bool showDate,
    int size,
    DateTime modified,
  ) {
    final path = file.path;
    final name = path.split('/').last;
    final iconColor = FileUtils.getColorForFile(name, context);
    final isApk = name.toLowerCase().endsWith('.apk') || name.toLowerCase().endsWith('.xapk') || name.toLowerCase().endsWith('.apks') || name.toLowerCase().endsWith('.apkm');

    return ListTile(
      key: ValueKey(path),
      onTap: () {
        if (_isSelectionMode) {
          _toggleSelection(path, null);
        } else {
          context.read<FileManagerProvider>().openFile(context, path);
        }
      },
      onLongPress: () => _toggleSelection(path, null),
      leading: Stack(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(color: iconColor.withOpacity(0.15), borderRadius: BorderRadius.circular(10)),
            child: isApk
                ? _ApkThumbnail(path: path, iconColor: iconColor)
                : path.toLowerCase().endsWith('.svg')
                    ? ClipRRect(
                        borderRadius: BorderRadius.circular(10),
                        child: SvgPicture.file(
                          File(path),
                          fit: BoxFit.cover,
                          placeholderBuilder: (context) => Icon(FileUtils.getIconForFile(name), color: iconColor, size: 22),
                        ),
                      )
                    : FileUtils.isArchive(path)
                        ? ArchiveTypeIcon(
                            label: FileUtils.getArchiveTypeLabel(path),
                            color: iconColor,
                            iconScale: 1.0,
                          )
                        : FileUtils.isDocument(path)
                            ? Center(
                                child: FileTypeIcon(
                                  icon: FileUtils.getIconForFile(name),
                                  label: FileUtils.getDocumentTypeLabel(path),
                                  color: iconColor,
                                  iconScale: 1.0,
                                ),
                              )
                            : Icon(FileUtils.getIconForFile(name), color: iconColor, size: 22),
          ),
          if (_isSelectionMode || isSelected)
            Positioned(
              bottom: 0,
              right: 0,
              child: Container(
                decoration: BoxDecoration(color: theme.colorScheme.surface, shape: BoxShape.circle),
                child: Icon(isSelected ? Broken.tick_square : Icons.check_box_outline_blank, color: isSelected ? theme.colorScheme.primary : Colors.grey, size: 20),
              ),
            ),
          if (_showCloudBadge(path))
            Positioned(
              top: 0,
              left: 0,
              child: Container(
                padding: const EdgeInsets.all(2),
                decoration: BoxDecoration(color: Colors.black.withOpacity(0.55), shape: BoxShape.circle),
                child: const Icon(Broken.cloud, color: Colors.white, size: 10),
              ),
            ),
        ],
      ),
      title: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w500)),
      subtitle: Text(
        showDate
            ? '${FileUtils.formatBytes(size, 1)} • ${FileUtils.formatDate(modified)}'
            : FileUtils.formatBytes(size, 1),
        style: TextStyle(color: theme.colorScheme.onSurface.withOpacity(0.6), fontSize: 11),
      ),
      trailing: _isSelectionMode
          ? null
          : IconButton(
              icon: const Icon(Broken.more),
              onPressed: () => _showSingleItemOptions(name: name, filePath: path),
            ),
    );
  }

  Widget _buildGenericFileList(List<FileSystemEntity> files, ThemeData theme, bool isDateWise, bool isGrouped, bool isGridView) {
    if (files.isEmpty) return _buildEmptyState(theme);
    if (isGrouped) {
      return _buildGroupedView<FileSystemEntity>(
        items: files,
        theme: theme,
        isGrid: isGridView,
        isDateWise: isDateWise,
        itemTileBuilder: (file, showDate) {
          final isSelected = _selectedFilePaths.contains(file.path);
          final size = _fileSizeOf(file);
          final modified = _fileModifiedOf(file);
          return _SelectedFrame(
            selected: isSelected,
            isList: !isGridView,
            theme: theme,
            child: isGridView
                ? _buildGenericFileGridTile(file, theme, isSelected, showDate, size, modified)
                : _buildGenericFileTile(file, theme, isSelected, showDate, size, modified),
          );
        },
      );
    }
    if (isGridView) {
      return GridView.builder(
        padding: const EdgeInsets.all(6),
        physics: const BouncingScrollPhysics(),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 3, crossAxisSpacing: 6, mainAxisSpacing: 6),
        itemCount: files.length,
        itemBuilder: (context, index) {
          final file = files[index];
          final isSelected = _selectedFilePaths.contains(file.path);
          final size = _fileSizeOf(file);
          final modified = _fileModifiedOf(file);
          return _SelectedFrame(
            selected: isSelected,
            isList: false,
            theme: theme,
            child: _buildGenericFileGridTile(file, theme, isSelected, isDateWise, size, modified),
          );
        },
      );
    }
    return ListView.builder(
      physics: const BouncingScrollPhysics(),
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: files.length,
      itemBuilder: (context, index) {
          final file = files[index];
          final isSelected = _selectedFilePaths.contains(file.path);
          final size = _fileSizeOf(file);
          final modified = _fileModifiedOf(file);
          return _SelectedFrame(
            selected: isSelected,
            isList: true,
            theme: theme,
            child: _buildGenericFileTile(file, theme, isSelected, isDateWise, size, modified),
          );
      },
    );
  }

  /// 通用文件（压缩包/下载/安装包）的网格视图 tile：图标 + 文件名 + 大小
  Widget _buildGenericFileGridTile(
    FileSystemEntity file,
    ThemeData theme,
    bool isSelected,
    bool showDate,
    int size,
    DateTime modified,
  ) {
    final path = file.path;
    final name = path.split('/').last;
    final iconColor = FileUtils.getColorForFile(name, context);
    final isApk = name.toLowerCase().endsWith('.apk') || name.toLowerCase().endsWith('.xapk') || name.toLowerCase().endsWith('.apks') || name.toLowerCase().endsWith('.apkm');
    final dateStr = FileUtils.formatDate(modified);

    return GestureDetector(
      key: ValueKey(path),
      onTap: () {
        if (_isSelectionMode) {
          _toggleSelection(path, null);
        } else {
          context.read<FileManagerProvider>().openFile(context, path);
        }
      },
      onLongPress: () => _toggleSelection(path, null),
      child: Stack(
        fit: StackFit.expand,
        children: [
          Container(
            decoration: BoxDecoration(
              color: iconColor.withOpacity(0.1),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: iconColor.withOpacity(0.15)),
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(color: iconColor.withOpacity(0.15), borderRadius: BorderRadius.circular(10)),
                  child: Center(
                    child: isApk
                        ? _ApkThumbnail(path: path, iconColor: iconColor)
                        : FileUtils.isArchive(path)
                            ? ArchiveTypeIcon(
                                label: FileUtils.getArchiveTypeLabel(path),
                                color: iconColor,
                                iconScale: 1.0,
                              )
                            : Icon(FileUtils.getIconForFile(name), color: iconColor, size: 22),
                  ),
                ),
                const SizedBox(height: 8),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  child: Text(name, maxLines: 2, overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w500),
                  ),
                ),
                const SizedBox(height: 2),
                Text(FileUtils.formatBytes(size, 2), style: TextStyle(fontSize: 10, color: theme.colorScheme.onSurface.withOpacity(0.5))),
                if (showDate)
                  Text(dateStr.split(',').first, style: TextStyle(fontSize: 9, color: theme.colorScheme.onSurface.withOpacity(0.4))),
              ],
            ),
          ),
          if (_isSelectionMode || isSelected)
            Positioned(
              top: 6,
              right: 6,
              child: Icon(
                isSelected ? Broken.tick_square : Icons.check_box_outline_blank,
                color: isSelected ? theme.colorScheme.primary : Colors.white.withOpacity(0.8),
                size: 24,
              ),
            )
          else
            Positioned(
              top: 4,
              right: 4,
              child: InkWell(
                onTap: () => _showSingleItemOptions(name: name, filePath: path),
                child: Container(
                  padding: const EdgeInsets.all(4),
                  decoration: BoxDecoration(color: Colors.black.withOpacity(0.5), shape: BoxShape.circle),
                  child: const Icon(Broken.more, color: Colors.white, size: 18),
                ),
              ),
            ),
          if (_showCloudBadge(path))
            Positioned(
              top: 4,
              left: 4,
              child: Container(
                padding: const EdgeInsets.all(3),
                decoration: BoxDecoration(color: Colors.black.withOpacity(0.5), shape: BoxShape.circle),
                child: const Icon(Broken.cloud, color: Colors.white, size: 12),
              ),
            ),
        ],
      ),
    );
  }

  IconData _docIcon(String ext) {
    switch (ext) {
      case '.pdf': return Broken.document;
      case '.doc': case '.docx': case '.xls': case '.xlsx': return Broken.document_text;
      case '.ppt': case '.pptx': return Broken.presention_chart;
      case '.txt': return Icons.description;
      default: return Broken.document;
    }
  }

  Color _docColor(String ext) {
    switch (ext) {
      case '.pdf': return Colors.redAccent;
      case '.doc': case '.docx': return Colors.blueAccent;
      case '.xls': case '.xlsx': return Colors.green;
      case '.ppt': case '.pptx': return Colors.orangeAccent;
      case '.txt': return Colors.blue.shade700;
      default: return Colors.teal;
    }
  }

  Widget _buildEmptyState(ThemeData theme) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(_emptyIcon, size: 72, color: theme.colorScheme.onSurface.withOpacity(0.2)),
          const SizedBox(height: 16),
          Text(L10n.of(context).ui_not_found_title(_title.toLowerCase()), style: TextStyle(color: theme.colorScheme.onSurface.withOpacity(0.5), fontSize: 16)),
        ],
      ),
    );
  }

  /// 媒体扫描失败/权限缺失时的占位视图：说明 + 重试按钮。
  /// 替代此前「未加载完成 → 无限 shimmer」的静默失败表现。
  Widget _buildLoadFailedState(ThemeData theme) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Broken.info_circle, size: 72, color: theme.colorScheme.onSurface.withOpacity(0.2)),
          const SizedBox(height: 16),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Text(
              L10n.of(context).ui_media_load_failed,
              textAlign: TextAlign.center,
              style: TextStyle(color: theme.colorScheme.onSurface.withOpacity(0.5), fontSize: 16),
            ),
          ),
          const SizedBox(height: 20),
          ElevatedButton.icon(
            onPressed: () async {
              // 重试前先确认/补授「所有文件访问」权限（部分 ROM 会静默回收），
              // 再强制全量重新扫描。provider 提前捕获，避免 async gap 后使用 context。
              final mediaProvider = context.read<MediaProvider>();
              try {
                final granted = await Permission.manageExternalStorage.isGranted;
                if (!granted) {
                  await Permission.manageExternalStorage.request();
                }
              } catch (_) {}
              await mediaProvider.loadMedia(forceRefresh: true);
            },
            icon: const Icon(Broken.refresh, size: 18),
            label: Text(L10n.of(context).ui_retry),
          ),
        ],
      ),
    );
  }

  PageRoute _slideRoute(Widget page) {
    return PageRouteBuilder(
      pageBuilder: (context, animation, secondaryAnimation) => page,
      transitionsBuilder: (context, animation, secondaryAnimation, child) => FadeTransition(opacity: animation, child: child),
      transitionDuration: const Duration(milliseconds: 250),
    );
  }

  Widget _buildScopeToggle(ThemeData theme) {
    final isLocal = _scopeFilter == _ScopeFilter.local;
    final outlineColor = theme.colorScheme.outline.withOpacity(0.5);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Row(
        children: [
          // 本地按钮 + 添加本地路径
          Flexible(
            flex: 1,
            child: Container(
              height: 40,
              decoration: BoxDecoration(
                color: isLocal ? theme.colorScheme.primary : theme.colorScheme.surfaceContainerHighest.withOpacity(0.4),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: isLocal ? theme.colorScheme.primary : outlineColor,
                  width: isLocal ? 1.5 : 1,
                ),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: InkWell(
                      onTap: () => setState(() => _scopeFilter = _ScopeFilter.local),
                      borderRadius: BorderRadius.circular(12),
                      child: Container(
                        alignment: Alignment.center,
                        decoration: const BoxDecoration(
                          borderRadius: BorderRadius.horizontal(left: Radius.circular(12)),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Broken.folder_open,
                              size: 16,
                              color: isLocal ? theme.colorScheme.onPrimary : theme.colorScheme.onSurfaceVariant,
                            ),
                            const SizedBox(width: 6),
                            Text(
                              L10n.of(context).ui_local,
                              style: TextStyle(
                                color: isLocal ? theme.colorScheme.onPrimary : theme.colorScheme.onSurfaceVariant,
                                fontSize: 13,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  _buildAddButton(
                    icon: Broken.add_square,
                    color: isLocal ? theme.colorScheme.onPrimary : theme.colorScheme.onSurfaceVariant,
                    onTap: _addLocalPath,
                    tooltip: L10n.of(context).ui_add_custom_path,
                  ),
                ],
              ),
            ),
          ),
          // 远程按钮 + 添加远程路径
          Flexible(
            flex: 1,
            child: Container(
              height: 40,
              decoration: BoxDecoration(
                color: !isLocal ? theme.colorScheme.primary : theme.colorScheme.surfaceContainerHighest.withOpacity(0.4),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: !isLocal ? theme.colorScheme.primary : outlineColor,
                  width: !isLocal ? 1.5 : 1,
                ),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: InkWell(
                      // 远程保护开启且未解锁时，先验证 PIN 再切换到远程范围
                      onTap: () async {
                        if (_scopeFilter == _ScopeFilter.remote) return;
                        if (!await RemoteGuardService.guard(context)) return;
                        if (mounted) {
                          setState(() => _scopeFilter = _ScopeFilter.remote);
                        }
                      },
                      borderRadius: BorderRadius.circular(12),
                      child: Container(
                        alignment: Alignment.center,
                        decoration: const BoxDecoration(
                          borderRadius: BorderRadius.horizontal(left: Radius.circular(12)),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Broken.cloud,
                              size: 16,
                              color: !isLocal ? theme.colorScheme.onPrimary : theme.colorScheme.onSurfaceVariant,
                            ),
                            const SizedBox(width: 6),
                            Text(
                              L10n.of(context).ui_remote,
                              style: TextStyle(
                                color: !isLocal ? theme.colorScheme.onPrimary : theme.colorScheme.onSurfaceVariant,
                                fontSize: 13,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  _buildAddButton(
                    icon: Broken.add_square,
                    color: !isLocal ? theme.colorScheme.onPrimary : theme.colorScheme.onSurfaceVariant,
                    onTap: _addRemotePath,
                    tooltip: L10n.of(context).ui_add_remote_path,
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 作用域切换条右侧的「+」小按钮，用于快速添加本地/远程扫描路径。
  Widget _buildAddButton({
    required IconData icon,
    required Color color,
    required VoidCallback onTap,
    required String tooltip,
  }) {
    return Tooltip(
      message: tooltip,
      child: SizedBox(
        width: 34,
        height: 40,
        child: Material(
          color: Colors.transparent,
          borderRadius: const BorderRadius.horizontal(right: Radius.circular(12)),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            borderRadius: const BorderRadius.horizontal(right: Radius.circular(12)),
            child: Center(
              child: Icon(icon, size: 16, color: color),
            ),
          ),
        ),
      ),
    );
  }

  /// 备份按钮（本地 → 远程）：仅图标，位于 AppBar 右上角。
  /// 弹出菜单显示在右上角（offset 不偏移，自然右对齐）。
  Widget _buildBackupButton(ThemeData theme) {
    return PopupMenuButton<_SyncMenuAction>(
      key: _syncMenuKey,
      icon: const Icon(Icons.backup_outlined),
      tooltip: L10n.of(context).ui_backup,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
      onSelected: (action) async {
        if (action == _SyncMenuAction.toggleAuto) {
          final newValue = !_autoSyncEnabled;
          await CategorySyncService.setAutoSyncEnabled(_categoryLabel, newValue);
          if (mounted) setState(() => _autoSyncEnabled = newValue);
          _reopenSyncMenu();
          return;
        }
        if (action == _SyncMenuAction.backupNow) {
          await _runSyncNow();
        }
      },
      itemBuilder: (context) => [
        _syncMenuItem(
          _SyncMenuAction.toggleAuto,
          _autoSyncEnabled ? Icons.toggle_on : Icons.toggle_off,
          L10n.of(context).ui_auto_backup,
        ),
        const PopupMenuDivider(),
        _syncMenuItem(
          _SyncMenuAction.backupNow,
          Icons.backup_outlined,
          L10n.of(context).ui_backup_now,
        ),
      ],
    );
  }

  Widget _buildFoldersToggle(ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      child: Container(
        height: 30,
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest.withOpacity(0.25),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          children: [
            Expanded(
              child: InkWell(
                onTap: () {
                  setState(() => _showFoldersMode = false);
                  PreferencesService.savePreferFoldersInMedia(widget.mediaType.name, false);
                },
                borderRadius: BorderRadius.circular(8),
                child: Container(
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: !_showFoldersMode ? theme.colorScheme.secondaryContainer : Colors.transparent,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    L10n.of(context).msgb19671d6,
                    style: TextStyle(
                      color: !_showFoldersMode ? theme.colorScheme.onSecondaryContainer : theme.colorScheme.onSurfaceVariant,
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ),
            ),
            Expanded(
              child: InkWell(
                onTap: () {
                  setState(() => _showFoldersMode = true);
                  PreferencesService.savePreferFoldersInMedia(widget.mediaType.name, true);
                },
                borderRadius: BorderRadius.circular(8),
                child: Container(
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: _showFoldersMode ? theme.colorScheme.secondaryContainer : Colors.transparent,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    L10n.of(context).msg1f4c1042,
                    style: TextStyle(
                      color: _showFoldersMode ? theme.colorScheme.onSecondaryContainer : theme.colorScheme.onSurfaceVariant,
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildResumePlayerButton(ThemeData theme) {
    final handler = getAudioHandler();
    final lastPlayed = PreferencesService.getLastPlayedAudio();

    String formatDuration(Duration d) {
      final h = d.inHours;
      final m = d.inMinutes % 60;
      final s = d.inSeconds % 60;
      if (h > 0) {
        return '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
      }
      return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: StreamBuilder<PlaybackState>(
        stream: handler.playbackState,
        builder: (context, playingSnapshot) {
          final isPlaying = playingSnapshot.data?.playing ?? false;
          return StreamBuilder<MediaItem?>(
            stream: handler.mediaItem,
            builder: (context, itemSnapshot) {
              // 优先使用后台播放器的当前曲目，确保切歌后按钮立即同步
              final activeItem = handler.hasActivePlayer
                  ? (itemSnapshot.data ?? handler.currentMediaItem)
                  : null;
              final Map<String, String>? info;
              if (activeItem != null) {
                info = {
                  'path': activeItem.id,
                  'title': activeItem.title,
                  'artist': activeItem.artist ?? '',
                };
              } else if (lastPlayed != null) {
                info = lastPlayed;
              } else {
                return const SizedBox.shrink();
              }

              // 检查文件是否还存在
              final file = File(info['path']!);
              if (!file.existsSync()) return const SizedBox.shrink();

              final path = info['path']!;
              final title = info['title']!;
              final artist = info['artist']!;
              final isCurrentTrack = handler.isPlayingPath(path);
              // 仅在后台播放器活跃时使用流中的 position/duration，否则用 0 避免残留旧值
              final position = handler.hasActivePlayer
                  ? (playingSnapshot.data?.updatePosition ?? Duration.zero)
                  : Duration.zero;
              final duration = handler.hasActivePlayer
                  ? (itemSnapshot.data?.duration ?? Duration.zero)
                  : Duration.zero;
              final savedMs = PreferencesService.getPlaybackPosition(path);
              final savedPosition = savedMs != null ? Duration(milliseconds: savedMs) : Duration.zero;

              String subtitle;
              if (isCurrentTrack && isPlaying && duration > Duration.zero) {
                subtitle = '${formatDuration(position)} / ${formatDuration(duration)}';
              } else if (isCurrentTrack && !isPlaying && duration > Duration.zero) {
                subtitle = '${formatDuration(position)} / ${formatDuration(duration)} · ${L10n.of(context).ui_resume_playback}';
              } else if (savedPosition.inSeconds > 0) {
                subtitle = '${L10n.of(context).ui_resume_playback} · ${formatDuration(savedPosition)}';
              } else {
                subtitle = _isUnknownArtist(artist) ? L10n.of(context).msg5e32276d : artist;
              }

              final progress = duration.inMilliseconds > 0
                  ? (position.inMilliseconds / duration.inMilliseconds).clamp(0.0, 1.0)
                  : 0.0;

              return Stack(
                children: [
                  Positioned.fill(
                    child: CustomPaint(
                      painter: _RoundedRectProgressPainter(
                        progress: progress,
                        strokeWidth: 3,
                        radius: 16,
                        color: theme.colorScheme.primary,
                        backgroundColor: theme.colorScheme.onSurface.withOpacity(0.1),
                      ),
                    ),
                  ),
                  Material(
                    color: theme.colorScheme.primaryContainer.withOpacity(0.5),
                    borderRadius: BorderRadius.circular(13),
                    clipBehavior: Clip.antiAlias,
                    child: InkWell(
                      borderRadius: BorderRadius.circular(13),
                      onTap: () => _openAudioPlayerFromResume(path, title, artist),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                        child: Row(
                          children: [
                            SizedBox(
                              width: 40,
                              height: 40,
                              child: Material(
                                color: theme.colorScheme.primary,
                                shape: const CircleBorder(),
                                child: InkWell(
                                  customBorder: const CircleBorder(),
                                  onTap: () => _toggleResumePlayback(path, title, artist),
                                  child: Icon(
                                    isCurrentTrack && isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
                                    color: theme.colorScheme.onPrimary,
                                    size: 24,
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(
                                    isCurrentTrack && isPlaying ? L10n.of(context).ui_now_playing : L10n.of(context).ui_resume_playback,
                                    style: TextStyle(
                                      fontSize: 12,
                                      fontWeight: FontWeight.bold,
                                      color: theme.colorScheme.primary,
                                    ),
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    title,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontSize: 14,
                                      fontWeight: FontWeight.w600,
                                      color: theme.colorScheme.onSurface,
                                    ),
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    subtitle,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: theme.colorScheme.onSurface.withOpacity(0.6),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            Icon(
                              Icons.chevron_right_rounded,
                              color: theme.colorScheme.onSurface.withOpacity(0.4),
                              size: 24,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              );
            },
          );
        },
      ),
    );
  }

  Widget _buildResumeVideoButton(ThemeData theme) {
    final lastPlayed = PreferencesService.getLastPlayedVideo();
    if (lastPlayed == null) return const SizedBox.shrink();

    final path = lastPlayed['path']!;
    final title = lastPlayed['title'] ?? '';
    final file = File(path);
    if (!file.existsSync()) return const SizedBox.shrink();

    final savedMs = PreferencesService.getVideoPlaybackPosition(path);
    final savedPosition = savedMs != null ? Duration(milliseconds: savedMs) : Duration.zero;

    String formatDuration(Duration d) {
      final h = d.inHours;
      final m = d.inMinutes % 60;
      final s = d.inSeconds % 60;
      if (h > 0) {
        return '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
      }
      return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
    }

    final subtitle = savedPosition.inSeconds > 0
        ? '${L10n.of(context).ui_resume_playback} · ${formatDuration(savedPosition)}'
        : title;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Material(
        color: theme.colorScheme.primaryContainer.withOpacity(0.5),
        borderRadius: BorderRadius.circular(13),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          borderRadius: BorderRadius.circular(13),
          onTap: () => _openVideoPlayerFromResume(path),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
            child: Row(
              children: [
                SizedBox(
                  width: 40,
                  height: 40,
                  child: Material(
                    color: theme.colorScheme.primary,
                    shape: const CircleBorder(),
                    child: InkWell(
                      customBorder: const CircleBorder(),
                      onTap: () => _openVideoPlayerFromResume(path),
                      child: Icon(
                        Icons.play_arrow_rounded,
                        color: theme.colorScheme.onPrimary,
                        size: 24,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        L10n.of(context).ui_resume_playback,
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                          color: theme.colorScheme.primary,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: theme.colorScheme.onSurface,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12,
                          color: theme.colorScheme.onSurface.withOpacity(0.6),
                        ),
                      ),
                    ],
                  ),
                ),
                Icon(
                  Icons.chevron_right_rounded,
                  color: theme.colorScheme.onSurface.withOpacity(0.4),
                  size: 24,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _openVideoPlayerFromResume(String path) {
    Navigator.push(
      context,
      PageRouteBuilder(
        pageBuilder: (context, animation, secondaryAnimation) => VideoPlayerScreen(
          videoPath: path,
        ),
        transitionsBuilder: (context, animation, secondaryAnimation, child) => SlideTransition(
          position: Tween<Offset>(begin: const Offset(0, 1), end: Offset.zero).animate(CurvedAnimation(parent: animation, curve: Curves.easeOutCubic)),
          child: child,
        ),
        transitionDuration: const Duration(milliseconds: 400),
      ),
    ).then((_) {
      if (mounted) setState(() {});
    });
  }

  void _openAudioPlayerFromResume(String path, String title, String artist) {
    final handler = getAudioHandler();
    final isSamePlaying = handler.isPlayingPath(path) && handler.hasActivePlayer;

    if (!isSamePlaying && handler.hasActivePlayer) {
      // 正在播放其他歌曲，先停止后台播放器，避免与新播放器同时出声
      handler.stop();
    }

    final provider = context.read<MediaProvider>();
    final audios = provider.audios;
    final index = audios.indexWhere((s) => s.data == path);

    Navigator.push(
      context,
      PageRouteBuilder(
        pageBuilder: (context, animation, secondaryAnimation) => AudioPlayerScreen(
          audioPath: path,
          title: title,
          artist: artist,
          allSongs: index >= 0 ? audios : null,
          initialIndex: index >= 0 ? index : 0,
          existingPlayer: isSamePlaying ? handler.currentPlayer : null,
        ),
        transitionsBuilder: (context, animation, secondaryAnimation, child) => SlideTransition(
          position: Tween<Offset>(begin: const Offset(0, 1), end: Offset.zero).animate(CurvedAnimation(parent: animation, curve: Curves.easeOutCubic)),
          child: child,
        ),
        transitionDuration: const Duration(milliseconds: 400),
      ),
    ).then((_) {
      // 返回类别页时刷新按钮状态，确保显示最新的 lastPlayed
      if (mounted) setState(() {});
    });
  }

  Future<void> _toggleResumePlayback(String path, String title, String artist) async {
    final handler = getAudioHandler();
    final isCurrentTrack = handler.isPlayingPath(path);

    if (!handler.hasActivePlayer || !isCurrentTrack) {
      // 没有播放器或播放的不是当前歌曲：打开播放器并开始播放
      _openAudioPlayerFromResume(path, title, artist);
      return;
    }

    if (handler.playbackState.value.playing) {
      await handler.pause();
    } else {
      await handler.play();
    }
  }
}

class _RoundedRectProgressPainter extends CustomPainter {
  final double progress;
  final double strokeWidth;
  final double radius;
  final Color color;
  final Color backgroundColor;

  _RoundedRectProgressPainter({
    required this.progress,
    required this.strokeWidth,
    required this.radius,
    required this.color,
    required this.backgroundColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Rect.fromLTWH(
      strokeWidth / 2,
      strokeWidth / 2,
      size.width - strokeWidth,
      size.height - strokeWidth,
    );
    final rrect = RRect.fromRectAndRadius(rect, Radius.circular(radius));

    final bgPaint = Paint()
      ..color = backgroundColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round;

    final fgPaint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round;

    final path = Path()..addRRect(rrect);

    // 绘制背景轨道
    canvas.drawPath(path, bgPaint);

    // 根据进度绘制前景
    if (progress > 0) {
      final metrics = path.computeMetrics().first;
      final drawLength = metrics.length * progress;
      final extractedPath = metrics.extractPath(0, drawLength);
      canvas.drawPath(extractedPath, fgPaint);
    }
  }

  @override
  bool shouldRepaint(covariant _RoundedRectProgressPainter oldDelegate) {
    return oldDelegate.progress != progress ||
        oldDelegate.strokeWidth != strokeWidth ||
        oldDelegate.radius != radius ||
        oldDelegate.color != color ||
        oldDelegate.backgroundColor != backgroundColor;
  }
}

class _ThumbnailShimmerPlaceholder extends StatefulWidget {
  const _ThumbnailShimmerPlaceholder({super.key});

  @override
  State<_ThumbnailShimmerPlaceholder> createState() => _ThumbnailShimmerPlaceholderState();
}

class _ThumbnailShimmerPlaceholderState extends State<_ThumbnailShimmerPlaceholder> with SingleTickerProviderStateMixin {
  late AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this, duration: const Duration(milliseconds: 1200))..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final baseColor = isDark ? const Color(0xFF1E1E2E) : const Color(0xFFE0E0E0);
    final highlightColor = isDark ? const Color(0xFF2A2A3E) : const Color(0xFFF5F5F5);

    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) => ShaderMask(
        shaderCallback: (rect) => LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [baseColor, highlightColor, baseColor],
          stops: [0.0, _controller.value, 1.0],
        ).createShader(rect),
        child: Container(color: baseColor),
      ),
    );
  }
}

/// 远程图片缩略图：按需下载到本地缓存后显示，避免 `Image.file(remote://...)` 失败。
class _RemoteImageThumb extends StatefulWidget {
  final String path;
  final VoidCallback onTap;
  final VoidCallback onLongPress;
  const _RemoteImageThumb({required this.path, required this.onTap, required this.onLongPress});

  @override
  State<_RemoteImageThumb> createState() => _RemoteImageThumbState();
}

class _RemoteImageThumbState extends State<_RemoteImageThumb> {
  File? _cached;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final local = await FileManagerProvider.downloadRemoteFileToCache(widget.path);
    if (mounted) {
      setState(() {
        _cached = local == null ? null : File(local);
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: widget.onTap,
      onLongPress: widget.onLongPress,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: _loading
            ? Container(
                color: Colors.grey.withOpacity(0.1),
                child: const Center(
                  child: SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2, color: Colors.grey),
                  ),
                ),
              )
            : (_cached != null && _cached!.existsSync()
                ? (widget.path.toLowerCase().endsWith('.svg')
                    ? SvgPicture.file(_cached!, fit: BoxFit.cover, width: double.infinity, height: double.infinity)
                    : Image.file(_cached!, fit: BoxFit.cover, width: double.infinity, height: double.infinity,
                        errorBuilder: (c, e, s) => Container(
                          color: Colors.grey.withOpacity(0.1),
                          child: const Center(child: Icon(Broken.image, size: 24, color: Colors.grey)),
                        )))
                : Container(
                    color: Colors.grey.withOpacity(0.1),
                    child: const Center(child: Icon(Broken.image, size: 24, color: Colors.grey)),
                  )),
      ),
    );
  }
}

class _CachedImageTile extends StatefulWidget {
  final AssetEntity asset;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  const _CachedImageTile({required this.asset, required this.onTap, required this.onLongPress});

  @override
  State<_CachedImageTile> createState() => _CachedImageTileState();
}

class _CachedImageTileState extends State<_CachedImageTile> {
  Uint8List? _thumbnail;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _loadThumbnail();
  }

  Future<void> _loadThumbnail() async {
    if (ThumbnailCache.hasCached(widget.asset.id)) {
      if (mounted) {
        setState(() {
          _thumbnail = ThumbnailCache.getCached(widget.asset.id);
          _loaded = true;
        });
      }
      return;
    }
    final data = await ThumbnailCache.get(widget.asset);
    if (mounted) {
      setState(() {
        _thumbnail = data;
        _loaded = true;
      });
    }
  }

  @override
  void didUpdateWidget(covariant _CachedImageTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.asset.id != widget.asset.id) {
      _loaded = false;
      _thumbnail = null;
      _loadThumbnail();
    }
  }

  @override
  Widget build(BuildContext context) {
    final title = widget.asset.title ?? '';
    final isSvg = title.toLowerCase().endsWith('.svg');
    return GestureDetector(
      onTap: widget.onTap,
      onLongPress: widget.onLongPress,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 300),
          child: isSvg
              ? FutureBuilder<File?>(
                  future: widget.asset.file,
                  builder: (context, snapshot) {
                    if (snapshot.hasData && snapshot.data != null) {
                      return SvgPicture.file(
                        snapshot.data!,
                        key: const ValueKey('svg'),
                        fit: BoxFit.cover,
                        width: double.infinity,
                        height: double.infinity,
                        placeholderBuilder: (context) => const _ThumbnailShimmerPlaceholder(key: ValueKey('shimmer')),
                      );
                    }
                    return const _ThumbnailShimmerPlaceholder(key: ValueKey('shimmer'));
                  },
                )
              : _loaded && _thumbnail != null
                  ? Image.memory(
                      _thumbnail!,
                      key: const ValueKey('img'),
                      fit: BoxFit.cover,
                      width: double.infinity,
                      height: double.infinity,
                      gaplessPlayback: true,
                      errorBuilder: (context, error, stackTrace) => Container(
                        color: Colors.grey.withOpacity(0.1),
                        child: const Center(child: Icon(Broken.image, size: 24, color: Colors.grey)),
                      ),
                    )
                  : const _ThumbnailShimmerPlaceholder(key: ValueKey('shimmer')),
        ),
      ),
    );
  }
}

/// 远程视频缩略图瓦片，通过 ThumbnailCache 加载远程视频缩略图。
class _RemoteVideoTileWidget extends StatefulWidget {
  final String remotePath;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  const _RemoteVideoTileWidget({
    required this.remotePath,
    required this.onTap,
    required this.onLongPress,
  });

  @override
  State<_RemoteVideoTileWidget> createState() => _RemoteVideoTileWidgetState();
}

class _RemoteVideoTileWidgetState extends State<_RemoteVideoTileWidget> {
  Uint8List? _thumbnail;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _loadThumbnail();
  }

  Future<void> _loadThumbnail() async {
    final data = await ThumbnailCache.getForRemoteVideo(widget.remotePath);
    if (mounted) {
      setState(() {
        _thumbnail = data;
        _loaded = true;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: widget.onTap,
      onLongPress: widget.onLongPress,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: Stack(
          fit: StackFit.expand,
          children: [
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 300),
              child: _loaded && _thumbnail != null
                  ? Image.memory(
                      _thumbnail!,
                      key: const ValueKey('remote_vid'),
                      fit: BoxFit.cover,
                      width: double.infinity,
                      height: double.infinity,
                      gaplessPlayback: true,
                      errorBuilder: (context, error, stackTrace) => Container(
                        color: Colors.grey.withOpacity(0.1),
                        child: const Center(child: Icon(Broken.video, size: 24, color: Colors.grey)),
                      ),
                    )
                  : const _ThumbnailShimmerPlaceholder(key: ValueKey('shimmer')),
            ),
            Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [Colors.transparent, Colors.black.withOpacity(0.5)],
                  ),
                ),
              ),
            ),
            Center(
              child: Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(color: Colors.black.withOpacity(0.5), shape: BoxShape.circle),
                child: const Icon(Icons.play_arrow, color: Colors.white, size: 22),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 视频列表视图缩略图组件（支持本地 asset 和远程视频）
/// 在列表模式下复用网格视图的缩略图加载逻辑，以小尺寸方形渲染
class _VideoListThumbnail extends StatefulWidget {
  final AssetEntity? asset;
  final String? remotePath;
  final String? filePath;
  final double size;

  const _VideoListThumbnail({
    this.asset,
    this.remotePath,
    this.filePath,
    this.size = 40,
  });

  @override
  State<_VideoListThumbnail> createState() => _VideoListThumbnailState();
}

class _VideoListThumbnailState extends State<_VideoListThumbnail> {
  Uint8List? _thumbnail;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _loadThumbnail();
  }

  Future<void> _loadThumbnail() async {
    try {
      if (widget.asset != null) {
        if (ThumbnailCache.hasCached(widget.asset!.id)) {
          if (mounted) {
            setState(() {
              _thumbnail = ThumbnailCache.getCached(widget.asset!.id);
              _loaded = true;
            });
          }
          return;
        }
        final data = await ThumbnailCache.get(widget.asset!);
        if (mounted) {
          setState(() {
            _thumbnail = data;
            _loaded = true;
          });
        }
      } else if (widget.remotePath != null) {
        final data = await ThumbnailCache.getForRemoteVideo(widget.remotePath!);
        if (mounted) {
          setState(() {
            _thumbnail = data;
            _loaded = true;
          });
        }
      } else if (widget.filePath != null && widget.filePath!.isNotEmpty) {
        // 本地视频文件：复用原生 MediaMetadataRetriever 生成首帧缩略图
        final data = await MediaThumbnailService.generateVideoThumbnail(widget.filePath!);
        if (mounted) {
          setState(() {
            _thumbnail = data;
            _loaded = true;
          });
        }
      } else {
        if (mounted) setState(() => _loaded = true);
      }
    } catch (_) {
      if (mounted) setState(() => _loaded = true);
    }
  }

  @override
  void didUpdateWidget(covariant _VideoListThumbnail oldWidget) {
    super.didUpdateWidget(oldWidget);
    final newAssetId = widget.asset?.id;
    final oldAssetId = oldWidget.asset?.id;
    final newRemote = widget.remotePath;
    final oldRemote = oldWidget.remotePath;
    final newFile = widget.filePath;
    final oldFile = oldWidget.filePath;
    if (newAssetId != oldAssetId || newRemote != oldRemote || newFile != oldFile) {
      _loaded = false;
      _thumbnail = null;
      _loadThumbnail();
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: SizedBox(
        width: widget.size,
        height: widget.size,
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (_thumbnail != null)
              Image.memory(
                _thumbnail!,
                fit: BoxFit.cover,
                width: double.infinity,
                height: double.infinity,
                gaplessPlayback: true,
                errorBuilder: (context, error, stackTrace) => Container(
                  color: theme.colorScheme.primaryContainer.withOpacity(0.3),
                  child: Center(child: Icon(Broken.video, size: 20, color: theme.colorScheme.onPrimaryContainer.withOpacity(0.6))),
                ),
              )
            else if (_loaded)
              Container(
                color: theme.colorScheme.primaryContainer.withOpacity(0.3),
                child: Center(child: Icon(Broken.video, size: 20, color: theme.colorScheme.onPrimaryContainer.withOpacity(0.6))),
              )
            else
              Container(
                color: theme.colorScheme.primaryContainer.withOpacity(0.3),
                child: const Center(child: SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 1.5))),
              ),
            // 播放图标遮罩
            Center(
              child: Container(
                padding: const EdgeInsets.all(2),
                decoration: BoxDecoration(
                  color: Colors.black.withOpacity(0.5),
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.play_arrow, color: Colors.white, size: 12),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CachedVideoTile extends StatefulWidget {
  final AssetEntity asset;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  const _CachedVideoTile({required this.asset, required this.onTap, required this.onLongPress});

  @override
  State<_CachedVideoTile> createState() => _CachedVideoTileState();
}

class _CachedVideoTileState extends State<_CachedVideoTile> {
  Uint8List? _thumbnail;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _loadThumbnail();
  }

  Future<void> _loadThumbnail() async {
    if (ThumbnailCache.hasCached(widget.asset.id)) {
      if (mounted) {
        setState(() {
          _thumbnail = ThumbnailCache.getCached(widget.asset.id);
          _loaded = true;
        });
      }
      return;
    }
    final data = await ThumbnailCache.get(widget.asset);
    if (mounted) {
      setState(() {
        _thumbnail = data;
        _loaded = true;
      });
    }
  }

  String _formatDuration(int seconds) {
    final d = Duration(seconds: seconds);
    final m = d.inMinutes;
    final s = d.inSeconds % 60;
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }

  @override
  void didUpdateWidget(covariant _CachedVideoTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.asset.id != widget.asset.id) {
      _loaded = false;
      _thumbnail = null;
      _loadThumbnail();
    }
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: widget.onTap,
      onLongPress: widget.onLongPress,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: Stack(
          fit: StackFit.expand,
          children: [
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 300),
              child: _loaded && _thumbnail != null
                  ? Image.memory(
                      _thumbnail!,
                      key: const ValueKey('vid'),
                      fit: BoxFit.cover,
                      width: double.infinity,
                      height: double.infinity,
                      gaplessPlayback: true,
                      errorBuilder: (context, error, stackTrace) => Container(
                        color: Colors.grey.withOpacity(0.1),
                        child: const Center(child: Icon(Broken.video, size: 24, color: Colors.grey)),
                      ),
                    )
                  : const _ThumbnailShimmerPlaceholder(key: ValueKey('shimmer')),
            ),
            Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Colors.transparent, Colors.black.withOpacity(0.5)]),
                ),
              ),
            ),
            Center(
              child: Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(color: Colors.black.withOpacity(0.5), shape: BoxShape.circle),
                child: const Icon(Icons.play_arrow, color: Colors.white, size: 22),
              ),
            ),
            Positioned(
              bottom: 4,
              right: 6,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                decoration: BoxDecoration(color: Colors.black.withOpacity(0.7), borderRadius: BorderRadius.circular(4)),
                child: Text(
                  _formatDuration(widget.asset.duration),
                  style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.bold),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 本地视频文件（FileSystemEntity）缩略图：通过原生 MediaMetadataRetriever 生成首帧，
/// 与 Web 共享 / 文件网格一致的视频缩略图方案。带内存缓存与占位回退。
class _LocalVideoTile extends StatefulWidget {
  final String filePath;
  final String title;
  final ThemeData theme;

  const _LocalVideoTile({required this.filePath, required this.title, required this.theme});

  @override
  State<_LocalVideoTile> createState() => _LocalVideoTileState();
}

class _LocalVideoTileState extends State<_LocalVideoTile> {
  Uint8List? _thumb;

  // 内存缓存，避免滚动复用/重建时重复调用原生缩略图生成。
  static final Map<String, Uint8List> _memCache = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final cached = _memCache[widget.filePath];
    if (cached != null) {
      if (mounted) setState(() {
        _thumb = cached;
      });
      return;
    }
    try {
      final bytes = await MediaThumbnailService.generateVideoThumbnail(widget.filePath);
      if (bytes != null && bytes.isNotEmpty) {
        _memCache[widget.filePath] = bytes;
        if (mounted) setState(() {
          _thumb = bytes;
        });
        return;
      }
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    if (_thumb != null) {
      return Stack(
        fit: StackFit.expand,
        children: [
          Image.memory(
            _thumb!,
            fit: BoxFit.cover,
            width: double.infinity,
            height: double.infinity,
            gaplessPlayback: true,
            errorBuilder: (context, error, stackTrace) => Container(
              color: Colors.grey.withOpacity(0.1),
              child: const Center(child: Icon(Broken.video, size: 24, color: Colors.grey)),
            ),
          ),
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Colors.transparent, Colors.black.withOpacity(0.5)],
                ),
              ),
            ),
          ),
          Center(
            child: Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(color: Colors.black.withOpacity(0.5), shape: BoxShape.circle),
              child: const Icon(Icons.play_arrow, color: Colors.white, size: 22),
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: Container(
              color: Colors.black.withOpacity(0.55),
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
              child: Text(
                widget.title,
                style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.w500),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
        ],
      );
    }

    // 回退：未生成到缩略图时显示占位图标 + 文件名（与旧版一致）。
    return Container(
      color: widget.theme.colorScheme.surfaceVariant,
      padding: const EdgeInsets.all(8),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Broken.video, size: 28, color: widget.theme.colorScheme.primary),
          const SizedBox(height: 6),
          Text(
            widget.title,
            style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w500),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}

/// 选中项高亮：主色边框 + 浅色底色，应用于各分类网格/列表 tile，使选中状态更醒目。
class _SelectedFrame extends StatelessWidget {
  final bool selected;
  final bool isList;
  final ThemeData theme;
  final Widget child;

  const _SelectedFrame({
    required this.selected,
    required this.isList,
    required this.theme,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    if (!selected) return child;
    final primary = theme.colorScheme.primary;
    if (isList) {
      return Container(
        margin: const EdgeInsets.symmetric(vertical: 2, horizontal: 4),
        decoration: BoxDecoration(
          color: primary.withOpacity(0.14),
          border: Border.all(color: primary, width: 2),
          borderRadius: BorderRadius.circular(10),
        ),
        child: child,
      );
    }
    return Stack(
      fit: StackFit.expand,
      children: [
        child,
        Positioned.fill(
          child: IgnorePointer(
            child: Container(
              decoration: BoxDecoration(
                border: Border.all(color: primary, width: 3),
                borderRadius: BorderRadius.circular(10),
                color: primary.withOpacity(0.16),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class FolderGridItem extends StatefulWidget {
  final AssetPathEntity album;
  final VoidCallback onTap;

  const FolderGridItem({super.key, required this.album, required this.onTap});

  @override
  State<FolderGridItem> createState() => _FolderGridItemState();
}

class _FolderGridItemState extends State<FolderGridItem> {
  AssetEntity? _firstAsset;
  int _count = 0;

  @override
  void initState() {
    super.initState();
    _loadDetails();
  }

  Future<void> _loadDetails() async {
    try {
      final count = await widget.album.assetCountAsync;
      if (count > 0) {
        final assets = await widget.album.getAssetListPaged(page: 0, size: 1);
        if (assets.isNotEmpty && mounted) {
          setState(() {
            _firstAsset = assets.first;
            _count = count;
          });
          return;
        }
      }
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    
    return GestureDetector(
      onTap: widget.onTap,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(20),
        child: Container(
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHighest.withOpacity(0.3),
            border: Border.all(color: theme.colorScheme.outlineVariant.withOpacity(0.4)),
          ),
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (_firstAsset != null)
                _CachedImageTile(
                  asset: _firstAsset!,
                  onTap: widget.onTap,
                  onLongPress: () {},
                )
              else
                Container(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: [theme.colorScheme.surfaceContainerHighest, theme.colorScheme.surface],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
                  ),
                  child: Icon(Broken.folder_2, color: theme.colorScheme.primary.withOpacity(0.5), size: 40),
                ),
              // Gradient Overlay
              Positioned.fill(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: [Colors.transparent, Colors.black.withOpacity(0.85)],
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      stops: const [0.4, 1.0],
                    ),
                  ),
                ),
              ),
              // Content
              Positioned(
                bottom: 12,
                left: 12,
                right: 12,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      widget.album.name,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 14,
                        fontWeight: FontWeight.bold,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '$_count ${L10n.of(context).items}',
                      style: TextStyle(
                        color: Colors.white.withOpacity(0.75),
                        fontSize: 11,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 分类页「文件夹」视图的文件夹封面缩略图（按媒体类型渲染）。
class _MediaFolderCover extends StatelessWidget {
  final MediaType mediaType;
  final String samplePath;

  const _MediaFolderCover({required this.mediaType, required this.samplePath});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (mediaType == MediaType.audios) {
      // 音频无封面，显示音乐图标
      return Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [theme.colorScheme.surfaceContainerHighest, theme.colorScheme.surface],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
        ),
        child: Center(
          child: Icon(Broken.music, color: theme.colorScheme.primary.withOpacity(0.5), size: 40),
        ),
      );
    }
    if (mediaType == MediaType.videos) {
      return FutureBuilder<Uint8List?>(
        future: MediaThumbnailService.generateVideoThumbnail(samplePath),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.done && snapshot.data != null) {
            return Image.memory(snapshot.data!, fit: BoxFit.cover);
          }
          return Container(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [theme.colorScheme.surfaceContainerHighest, theme.colorScheme.surface],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
            ),
            child: Center(
              child: Icon(Broken.video, color: theme.colorScheme.primary.withOpacity(0.5), size: 40),
            ),
          );
        },
      );
    }
    // 图片：直接读取本地文件
    if (samplePath.toLowerCase().endsWith('.svg')) {
      return SvgPicture.file(
        File(samplePath),
        fit: BoxFit.cover,
        placeholderBuilder: (context) => Container(color: Colors.grey.withOpacity(0.1)),
      );
    }
    return Image.file(
      File(samplePath),
      fit: BoxFit.cover,
      errorBuilder: (context, error, stackTrace) => Container(
        color: Colors.grey.withOpacity(0.1),
        child: Center(
          child: Icon(Broken.image, color: theme.colorScheme.primary.withOpacity(0.5), size: 40),
        ),
      ),
    );
  }
}

/// 分类页「文件夹」视图的文件夹卡片：封面 + 文件夹名 + 数量。
class _MediaFolderTile extends StatelessWidget {
  final String folderPath;
  final int count;
  final MediaType mediaType;
  final String? samplePath;
  final VoidCallback onTap;

  const _MediaFolderTile({
    required this.folderPath,
    required this.count,
    required this.mediaType,
    this.samplePath,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final name = _MediaCategoryScreenState._folderDisplayName(folderPath);
    return GestureDetector(
      onTap: onTap,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(20),
        child: Container(
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHighest.withOpacity(0.3),
            border: Border.all(color: theme.colorScheme.outlineVariant.withOpacity(0.4)),
          ),
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (samplePath != null)
                _MediaFolderCover(mediaType: mediaType, samplePath: samplePath!)
              else
                Container(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: [theme.colorScheme.surfaceContainerHighest, theme.colorScheme.surface],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
                  ),
                  child: Icon(Broken.folder_2, color: theme.colorScheme.primary.withOpacity(0.5), size: 40),
                ),
              Positioned.fill(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: [Colors.transparent, Colors.black.withOpacity(0.85)],
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      stops: const [0.4, 1.0],
                    ),
                  ),
                ),
              ),
              if (folderPath.startsWith('remote://') || CategorySyncService.hasSyncedFileUnder(folderPath))
                Positioned(
                  top: 8,
                  right: 8,
                  child: Container(
                    padding: const EdgeInsets.all(5),
                    decoration: BoxDecoration(
                      color: Colors.black.withOpacity(0.45),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(
                      Broken.cloud,
                      color: Colors.white,
                      size: 14,
                    ),
                  ),
                ),
              Positioned(
                bottom: 12,
                left: 12,
                right: 12,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        Expanded(
                          child: Text(
                            name,
                            style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.bold),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '$count ${L10n.of(context).items}',
                      style: TextStyle(color: Colors.white.withOpacity(0.75), fontSize: 11, fontWeight: FontWeight.w500),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ApkThumbnail extends StatefulWidget {
  final String path;
  final Color iconColor;

  const _ApkThumbnail({
    required this.path,
    required this.iconColor,
  });

  @override
  State<_ApkThumbnail> createState() => _ApkThumbnailState();
}

class _ApkThumbnailState extends State<_ApkThumbnail> {
  static final Map<String, Uint8List?> _apkIconCache = {};
  Uint8List? _apkIcon;

  @override
  void initState() {
    super.initState();
    _loadApkIcon();
  }

  Future<void> _loadApkIcon() async {
    final path = widget.path;
    if (_apkIconCache.containsKey(path)) {
      final cachedIcon = _apkIconCache[path];
      if (mounted && cachedIcon != null) {
        setState(() {
          _apkIcon = cachedIcon;
        });
      }
      return;
    }
    try {
      final iconBytes = await AppManagerService.getApkIcon(path);
      _apkIconCache[path] = iconBytes;
      if (mounted && iconBytes != null) {
        setState(() {
          _apkIcon = iconBytes;
        });
      }
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    if (_apkIcon != null) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: Image.memory(
          _apkIcon!,
          fit: BoxFit.cover,
          width: 44,
          height: 44,
          errorBuilder: (context, error, stackTrace) => Icon(Broken.mobile, color: widget.iconColor, size: 22),
        ),
      );
    }
    return Icon(Broken.mobile, color: widget.iconColor, size: 22);
  }
}
