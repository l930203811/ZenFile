import 'package:zenfile/l10n/generated/app_localizations.dart';

import 'dart:io';
import 'dart:async';
import 'dart:collection';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import '../models/file_item_model.dart';
import '../models/folder_tab_model.dart';
import '../models/file_filter_type.dart';
import '../models/category_filter_type.dart';
import 'media_provider.dart';
import 'package:mime/mime.dart';
import '../ui/screens/image_viewer_screen.dart';
import '../ui/screens/video_player/video_player_screen.dart';
import '../ui/screens/audio_player/audio_player_screen.dart';
import '../ui/screens/text_editor_screen.dart';
import '../ui/screens/document_viewer_screen.dart';
import '../ui/screens/archive_viewer_screen.dart';
import '../ui/screens/database_reader_screen.dart';
import '../services/archive_service.dart';
import '../services/apk_installer_service.dart';
import '../ui/widgets/extract_archive_dialog.dart';
import '../core/utils.dart';
import '../services/preferences_service.dart';
import '../services/app_manager_service.dart';
import '../services/category_sync_service.dart';
import '../models/custom_shortcut_model.dart';
import '../services/root_shizuku_service.dart';
import '../services/recycle_bin_service.dart';
import 'package:on_audio_query/on_audio_query.dart';
import '../ui/widgets/open_with_sheet.dart';
import '../ui/widgets/pick_file_type_sheet.dart';
import '../ui/widgets/conflict_dialog.dart';
import '../ui/widgets/file_action_dialogs.dart';
import '../ui/widgets/file_operation_progress_dialog.dart';
import '../services/background_archive_service.dart';
import '../services/pin_service.dart';
import '../models/network_connection_model.dart';
import '../services/remote/remote_client.dart';
import '../services/remote/ftp_client.dart';
import '../services/remote/sftp_client.dart';
import '../services/remote/webdav_client.dart';
import '../services/remote/lan_client.dart';
import '../services/remote/saf_client.dart';
import '../services/remote_streaming_service.dart';
import '../services/network_connections_service.dart';

enum FileSortType {
  nameAsc,
  nameDesc,
  dateNewest,
  dateOldest,
  sizeLargest,
  sizeSmallest,
  type,
}

class StorageVolume {
  final String name;
  final String path;
  final bool isInternal;
  int totalBytes;
  int usedBytes;

  StorageVolume({
    required this.name,
    required this.path,
    required this.isInternal,
    this.totalBytes = 0,
    this.usedBytes = 0,
  });
}

int _calculateDirectorySizeSync(String path) {
  int totalSize = 0;
  try {
    final dir = Directory(path);
    if (dir.existsSync()) {
      final List<FileSystemEntity> entities = dir.listSync(followLinks: false);
      for (final entity in entities) {
        if (entity is File) {
          try {
            totalSize += entity.lengthSync();
          } catch (_) {}
        } else if (entity is Directory) {
          try {
            totalSize += _calculateDirectorySizeSync(entity.path);
          } catch (_) {}
        }
      }
    }
  } catch (_) {}
  return totalSize;
}

/// 递归统计单个路径的文件数和总字节数（同步实现，供 isolate 调用）。
/// 返回 [fileCount, totalBytes]。
List<int> _countSinglePathSync(String localPath) {
  final entity = FileSystemEntity.typeSync(localPath);
  if (entity == FileSystemEntityType.directory) {
    int count = 0;
    int bytes = 0;
    try {
      for (final item in Directory(localPath).listSync(followLinks: false)) {
        final r = _countSinglePathSync(item.path);
        count += r[0];
        bytes += r[1];
      }
    } catch (_) {}
    return [count, bytes];
  } else if (entity == FileSystemEntityType.file) {
    try {
      return [1, File(localPath).lengthSync()];
    } catch (_) {
      return [1, 0];
    }
  }
  return [0, 0];
}

/// 顶层函数：供 compute() 在独立 isolate 中递归统计多个路径的文件数和总字节数。
/// 避免在主线程执行同步递归遍历导致 UI 卡顿（粘贴前统计进度条分母）。
/// 返回 [fileCount, totalBytes]。
List<int> _countLocalFilesAndBytesIsolate(List<String> paths) {
  int count = 0;
  int bytes = 0;
  for (final path in paths) {
    final r = _countSinglePathSync(path);
    count += r[0];
    bytes += r[1];
  }
  return [count, bytes];
}

/// 远程源目录因剪切/移动等操作发生变化后广播的事件。
/// 全屏 [RemoteExplorerScreen] 订阅此事件，当事件来源连接与自身一致时刷新
/// 当前目录，避免“原文件残留 / 返回后页面丢失”。（远程 tab 由 provider 直接刷新。）
class RemoteSourceChanged {
  final NetworkConnectionModel connection;
  final String dir;
  RemoteSourceChanged(this.connection, this.dir);
}

class FileManagerProvider extends ChangeNotifier {
  // 远程源目录变化广播：剪切/移动远程文件后，通知全屏 RemoteExplorerScreen 刷新，
  // 避免“原文件残留 / 返回后页面丢失”。远程 tab 由 provider 直接刷新。
  final StreamController<RemoteSourceChanged> _remoteSourceChangedController =
      StreamController<RemoteSourceChanged>.broadcast();
  Stream<RemoteSourceChanged> get remoteSourceChangedStream =>
      _remoteSourceChangedController.stream;

  FileManagerProvider() {
    _sortType = PreferencesService.getSortType();
    _isGridView = PreferencesService.getIsGridView();
    _iconScale = PreferencesService.getIconScale();
    _itemPaddingMultiplier = PreferencesService.getItemPaddingMultiplier();
    _showHiddenFiles = PreferencesService.getShowHiddenFiles();
    _showFloatingAddButton = PreferencesService.getShowFloatingAddButton();
    _showRemoteCloudBadge = PreferencesService.getShowRemoteCloudBadge();
    _rememberCategoryFilter = PreferencesService.getRememberCategoryFilter();
    // 仅在「记住过滤」开启时才恢复上次保存的类别过滤；否则每次启动重置为空（不过滤）。
    // 修复：记住过滤关闭时，重启仍加载了上次过滤条件的问题。
    _categoryFilter = _rememberCategoryFilter
        ? PreferencesService.getCategoryFilters()
        : <CategoryFilterType>{};
    _defaultToBrowseScreen = PreferencesService.getDefaultToBrowseScreen();
    _swipeMode = PreferencesService.getSwipeMode();
    _showFolderFileCount = PreferencesService.getShowFolderFileCount();
    _showBottomActionBar = PreferencesService.getShowBottomActionBar();
    _showHomeBrowseNav = PreferencesService.getShowHomeBrowseNav();
    _showMediaPreviews = PreferencesService.getShowMediaPreviews();
    _enableMultipleTabs = PreferencesService.getEnableMultipleTabs();
    _enableSplitScreen = PreferencesService.getEnableSplitScreen();
    _accentColorOption = PreferencesService.getAccentColor();
    _fontFamilyOption = PreferencesService.getFontFamily();
    _customFontPath = PreferencesService.getCustomFontPath();
    _folderIconOption = PreferencesService.getFolderIconStyle();
    _menuIconStyle = PreferencesService.getMenuIconStyle();
    _pinnedFolderShortcuts = PreferencesService.getPinnedFolderShortcuts();
    _hideNavigationBar = PreferencesService.getHideNavigationBar();
    _skipOpenWithDialog = PreferencesService.getSkipOpenWithDialog();
    _showAddressBar = PreferencesService.getShowAddressBar();
    _amoledMode = PreferencesService.getAmoledMode();
    _showRecentFiles = PreferencesService.getShowRecentFiles();
    _enableFolderHighlight = PreferencesService.getEnableFolderHighlight();
    _folderSortTypes = PreferencesService.getFolderSortTypes();
    _enableDragDrop = PreferencesService.getEnableDragDrop();
    _showDragDropDialog = PreferencesService.getShowDragDropDialog();
    _use24HourFormat = PreferencesService.getUse24HourFormat();
    _hideTimeAndDate = PreferencesService.getHideTimeAndDate();
    _showFolderContentsCount = PreferencesService.getShowFolderContentsCount();
    _showFolderSizes = PreferencesService.getShowFolderSizes();
    _adaptiveMultiLineNames = PreferencesService.getAdaptiveMultiLineNames();
    _hideActionMenuButtons = PreferencesService.getHideActionMenuButtons();
    _showActionMenuButtons = PreferencesService.getShowActionMenuButtons();
    _actionMenuDisplayMode = PreferencesService.getActionMenuDisplayMode();
    _activeAppIcon = PreferencesService.getActiveAppIcon();
    // 旧版本可选用 design_* 备用图标；本版本已移除这些别名与对应资源，
    // 若仍持久化 design 值则回退为 default，避免界面状态与实际启动图标不一致。
    if (_activeAppIcon.startsWith('design')) {
      _activeAppIcon = 'default';
      PreferencesService.saveActiveAppIcon('default');
    }
    _hideActionText = PreferencesService.getHideActionText();
    _disableLeftBackGesture = PreferencesService.getDisableLeftBackGesture();
    _rememberLastFolder = PreferencesService.getRememberLastFolder();
    _hideNavLabels = PreferencesService.getHideNavLabels();
    _trailingInfoType = PreferencesService.getTrailingInfoType();
    _categoryIconShape = PreferencesService.getCategoryIconShape();
    _categoriesGridColumns = PreferencesService.getCategoriesGridColumns();
    _favorites = PreferencesService.getFavorites();

    // One-time migration: reset PDF (and other documents) default open action to 'native' if it was set to 'external'
    if (!PreferencesService.getPdfResetDone()) {
      const docExts = ['.pdf', '.doc', '.docx', '.xls', '.xlsx', '.ppt', '.pptx', '.epub', '.odt'];
      for (final ext in docExts) {
        if (PreferencesService.getDefaultOpenAction(ext) == 'external') {
          PreferencesService.saveDefaultOpenAction(ext, 'native');
        }
      }
      PreferencesService.savePdfResetDone();
    }

    // Synchronously load cached storage sizes and pre-populate internal storage volume
    // to prevent any visual delay, shimmer, or refreshing animation on app startup!
    _totalStorageBytes = PreferencesService.getCachedTotalStorage();
    _usedStorageBytes = PreferencesService.getCachedUsedStorage();

    if (_totalStorageBytes > 0) {
      _storageVolumes = [
        StorageVolume(
          name: 'Internal Storage',
          path: '/storage/emulated/0',
          isInternal: true,
          totalBytes: _totalStorageBytes,
          usedBytes: _usedStorageBytes,
        )
      ];
    } else {
      // 全新安装（缓存为空）时也须提供默认卷，避免 storageVolumes.first 崩溃
      _storageVolumes = [
        StorageVolume(
          name: 'Internal Storage',
          path: '/storage/emulated/0',
          isInternal: true,
          totalBytes: 0,
          usedBytes: 0,
        )
      ];
    }
  }

  /// 自定义进度通知器：后台模式下忽略所有非 null 赋值，避免对话框重新弹出。
  /// 设置为 null 始终生效（用于关闭对话框）。
  final _BackgroundAwareProgressNotifier progressNotifier = _BackgroundAwareProgressNotifier();
  bool _isOperationCancelled = false;
  bool _isPasting = false;
  bool get isPasting => _isPasting;
  bool _isDragging = false;
  bool get isDragging => _isDragging;

  void setDragging(bool value) {
    _isDragging = value;
    notifyListeners();
  }

  void cancelOperation() {
    _isOperationCancelled = true;
    // 调用当前活跃客户端的 cancel() 中断进行中的传输
    _activeTransferClient?.cancel();
  }

  /// 设置活跃传输客户端，供 remote_explorer_screen 的上传流程使用，
  /// 使 cancelOperation() 能正确中断 _uploadFromLocalClipboard 中的传输。
  void setActiveTransferClient(RemoteClient? client) {
    _activeTransferClient = client;
  }

  /// 切换到后台运行：关闭进度对话框，传输继续在后台执行。
  /// 设置 backgroundMode = true 后，进度通知器会忽略所有非 null 赋值，
  /// 传输 Future 不受影响，仍在后台运行。设置 null 会正常生效以关闭对话框。
  void runInBackground() {
    progressNotifier.backgroundMode = true;
    progressNotifier.value = null;
  }

  RemoteClient? _activeTransferClient;

  List<CustomShortcutModel> _pinnedFolderShortcuts = [];
  List<CustomShortcutModel> get pinnedFolderShortcuts => _pinnedFolderShortcuts;

  List<Map<String, dynamic>> _favorites = [];
  List<Map<String, dynamic>> get favorites => _favorites;

  void addFavorite(String path, String name, bool isDirectory, {bool isRemote = false, String? connectionId, String? group}) {
    if (_favorites.any((e) => e['path'] == path && (e['isRemote'] ?? false) == isRemote)) return;
    _favorites.add({
      'id': DateTime.now().millisecondsSinceEpoch.toString(),
      'path': path,
      'name': name,
      'isDirectory': isDirectory,
      'isRemote': isRemote,
      'group': group != null && group.trim().isNotEmpty ? group.trim() : null,
      if (isRemote && connectionId != null) 'connectionId': connectionId,
    });
    PreferencesService.saveFavorites(_favorites);
    notifyListeners();
  }

  void removeFavorite(String path) {
    _favorites.removeWhere((e) => e['path'] == path);
    PreferencesService.saveFavorites(_favorites);
    notifyListeners();
  }

  bool isFavorite(String path) {
    return _favorites.any((e) => e['path'] == path);
  }

  /// 编辑已有收藏：按 id（优先）或 原始 path 定位，更新名称 / 路径 / 分组。
  void updateFavorite(Map<String, dynamic> original, {String? name, String? path, String? group}) {
    final id = original['id'] as String?;
    final index = id != null
        ? _favorites.indexWhere((e) => e['id'] == id)
        : _favorites.indexWhere(
            (e) => e['path'] == original['path'] && (e['isRemote'] ?? false) == (original['isRemote'] ?? false),
          );
    if (index < 0) return;
    final updated = Map<String, dynamic>.from(_favorites[index]);
    if (name != null) updated['name'] = name;
    if (path != null) updated['path'] = path;
    if (group != null) {
      final g = group.trim();
      updated['group'] = g.isNotEmpty ? g : null;
    }
    _favorites[index] = updated;
    PreferencesService.saveFavorites(_favorites);
    notifyListeners();
  }

  /// 返回所有非空分组的去重、排序列表（用于分组下拉框）。
  List<String> getFavoriteGroups() {
    final groups = <String>{};
    for (final fav in _favorites) {
      final group = (fav['group'] as String?)?.trim();
      if (group?.isNotEmpty == true) groups.add(group!);
    }
    return groups.toList()..sort();
  }

  /// 重命名分组：将该分组下所有收藏的 group 字段更新为新名称。
  /// 空分组名或新旧同名不做处理。
  void renameFavoriteGroup(String oldGroup, String newGroup) {
    final old = oldGroup.trim();
    final newG = newGroup.trim();
    if (old.isEmpty || newG.isEmpty || old == newG) return;
    var changed = false;
    for (final fav in _favorites) {
      final g = (fav['group'] as String?)?.trim();
      if (g != null && g == old) {
        fav['group'] = newG;
        changed = true;
      }
    }
    if (changed) {
      PreferencesService.saveFavorites(_favorites);
      notifyListeners();
    }
  }

  /// 删除分组：移除该分组下所有收藏（group 字段一致的项），默认分组不参与。
  void deleteFavoriteGroup(String group) {
    final g = group.trim();
    if (g.isEmpty) return;
    final before = _favorites.length;
    _favorites.removeWhere((e) {
      final favGroup = (e['group'] as String?)?.trim();
      return favGroup != null && favGroup == g;
    });
    if (_favorites.length != before) {
      PreferencesService.saveFavorites(_favorites);
      notifyListeners();
    }
  }

  void addPinnedFolderShortcut(String path, String label) {
    if (_pinnedFolderShortcuts.any((e) => e.path == path)) return;
    final shortcut = CustomShortcutModel(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      label: label,
      path: path,
      isDirectory: true,
    );
    _pinnedFolderShortcuts.add(shortcut);
    PreferencesService.savePinnedFolderShortcuts(_pinnedFolderShortcuts);
    notifyListeners();
  }

  void removePinnedFolderShortcut(String id) {
    _pinnedFolderShortcuts.removeWhere((e) => e.id == id);
    PreferencesService.savePinnedFolderShortcuts(_pinnedFolderShortcuts);
    notifyListeners();
  }

  String _accentColorOption = 'blue';
  String get accentColorOption => _accentColorOption;

  void setAccentColorOption(String val) {
    if (_accentColorOption == val) return;
    _accentColorOption = val;
    PreferencesService.saveAccentColor(val);
    notifyListeners();
  }

  String _activeAppIcon = 'default';
  String get activeAppIcon => _activeAppIcon;

  Future<void> setActiveAppIcon(String val) async {
    if (_activeAppIcon == val) return;
    _activeAppIcon = val;
    await PreferencesService.saveActiveAppIcon(val);

    // Custom icons are handled via home screen shortcut (Option B), not via
    // activity-alias, because Android cannot reference a runtime image file
    // from an alias android:icon attribute.
    if (val == 'custom') {
      notifyListeners();
      return;
    }

    // 仅保留默认启动图标别名。旧版本 bundled 的 design_* 备用图标已移除以缩减 APK；
    // 启动时 MainActivity.onCreate 已强制启用 MainActivityDefault。
    await AppManagerService.changeAppIcon('com.sequl.zenfile.MainActivityDefault');
    notifyListeners();
  }

  String _fontFamilyOption = 'default';
  String get fontFamilyOption => _fontFamilyOption;

  void setFontFamilyOption(String val) {
    if (_fontFamilyOption == val) return;
    _fontFamilyOption = val;
    PreferencesService.saveFontFamily(val);
    notifyListeners();
  }

  String? _customFontPath;
  String? get customFontPath => _customFontPath;

  Future<bool> setCustomFontPath(String? path) async {
    if (path != null) {
      final file = File(path);
      if (!file.existsSync()) return false;
      _customFontPath = path;
      await PreferencesService.saveCustomFontPath(path);
      // Dynamically load the font for the running app
      try {
        final loader = FontLoader('CustomFont');
        final bytes = await file.readAsBytes();
        loader.addFont(Future.value(ByteData.sublistView(bytes)));
        await loader.load();
      } catch (e) {
        debugPrint('Error loading custom font: $e');
        return false;
      }
    } else {
      _customFontPath = null;
      await PreferencesService.saveCustomFontPath(null);
    }
    notifyListeners();
    return true;
  }

  bool _disableLeftBackGesture = false;
  bool get disableLeftBackGesture => _disableLeftBackGesture;

  void toggleDisableLeftBackGesture() {
    _disableLeftBackGesture = !_disableLeftBackGesture;
    PreferencesService.saveDisableLeftBackGesture(_disableLeftBackGesture);
    notifyListeners();
  }

  String _folderIconOption = 'broken';
  String get folderIconOption => _folderIconOption;

  void setFolderIconOption(String val) {
    if (_folderIconOption == val) return;
    _folderIconOption = val;
    PreferencesService.saveFolderIconStyle(val);
    notifyListeners();
  }

  String _menuIconStyle = 'hamburger';
  String get menuIconStyle => _menuIconStyle;

  void setMenuIconStyle(String val) {
    if (_menuIconStyle == val) return;
    _menuIconStyle = val;
    PreferencesService.saveMenuIconStyle(val);
    notifyListeners();
  }

  FileSortType _sortType = FileSortType.nameAsc;
  FileSortType get sortType => _sortType;

  Map<String, FileSortType> _folderSortTypes = {};
  Map<String, FileSortType> get folderSortTypes => _folderSortTypes;

  bool isFolderOverrideEnabled(String path) {
    return _folderSortTypes.containsKey(path);
  }

  void setFolderOverrideEnabled(String path, bool enabled) {
    if (enabled) {
      _folderSortTypes[path] = getSortTypeForPath(path);
    } else {
      _folderSortTypes.remove(path);
    }
    PreferencesService.saveFolderSortTypes(_folderSortTypes);
    
    if (_tabs.isNotEmpty && currentPath == path) {
      final folders = currentFiles.where((e) => e.isDirectory).toList();
      final files = currentFiles.where((e) => !e.isDirectory).toList();
      _sortList(folders, path);
      _sortList(files, path);
      activeTab.currentFiles = [...folders, ...files];
    }
    notifyListeners();
  }

  FileSortType getSortTypeForPath(String path) {
    return _folderSortTypes[path] ?? _sortType;
  }

  void setSortType(FileSortType type) {
    final path = currentPath;
    final hasOverride = isFolderOverrideEnabled(path);
    
    if (hasOverride) {
      if (_folderSortTypes[path] == type) return;
      _folderSortTypes[path] = type;
      PreferencesService.saveFolderSortTypes(_folderSortTypes);
    } else {
      if (_sortType == type) return;
      _sortType = type;
      PreferencesService.saveSortType(_sortType);
    }
    
    if (_tabs.isNotEmpty) {
      // 双窗口下对所有已加载的标签重排，确保左右两面板同步生效
      for (final tab in _tabs) {
        if (tab.currentFiles.isEmpty) continue;
        final folders = tab.currentFiles.where((e) => e.isDirectory).toList();
        final files = tab.currentFiles.where((e) => !e.isDirectory).toList();
        _sortList(folders, tab.currentPath);
        _sortList(files, tab.currentPath);
        tab.currentFiles = [...folders, ...files];
      }
    }
    notifyListeners();
  }

  FileFilterType _filterType = FileFilterType.all;
  FileFilterType get filterType => _filterType;

  void setFilterType(FileFilterType type) {
    if (_filterType == type) return;
    _filterType = type;
    loadDirectory(currentPath, showLoading: false);
    notifyListeners();
  }

  bool _hideFoldersInFilter = false;
  bool get hideFoldersInFilter => _hideFoldersInFilter;

  void toggleHideFoldersInFilter() {
    _hideFoldersInFilter = !_hideFoldersInFilter;
    if (_tabs.isNotEmpty) {
      loadDirectory(currentPath, showLoading: false);
    }
    notifyListeners();
  }

  static bool matchesFilterForType(String path, FileFilterType filter) {
    switch (filter) {
      case FileFilterType.all:
        return true;
      case FileFilterType.documents:
        final lower = path.toLowerCase();
        const docExts = ['.pdf', '.doc', '.docx', '.xls', '.xlsx', '.ppt', '.pptx', '.txt', '.csv', '.odt', '.ods', '.odp', '.rtf', '.epub'];
        return docExts.any((ext) => lower.endsWith(ext)) || FileUtils.isTextOrCode(path);
      case FileFilterType.images:
        return FileUtils.isImage(path);
      case FileFilterType.audio:
        return FileUtils.isAudio(path);
      case FileFilterType.videos:
        return FileUtils.isVideo(path);
      case FileFilterType.archives:
        return FileUtils.isArchive(path);
    }
  }

  bool _matchesFilter(String path) {
    return matchesFilterForType(path, _filterType);
  }

  final Map<String, int> _folderMatchingFileCounts = {};

  Future<int> getMatchingFileCount(String folderPath, FileFilterType filter) async {
    final cacheKey = '$folderPath:${filter.name}';
    if (_folderMatchingFileCounts.containsKey(cacheKey)) {
      return _folderMatchingFileCounts[cacheKey]!;
    }

    int count = 0;
    try {
      final dir = Directory(folderPath);
      if (await dir.exists()) {
        final List<FileSystemEntity> entities = await dir.list().toList();
        for (var entity in entities) {
          if (entity is File) {
            if (matchesFilterForType(entity.path, filter)) {
              count++;
            }
          }
        }
      }
    } catch (e) {
      debugPrint('Error counting matching files in $folderPath: $e');
    }

    _folderMatchingFileCounts[cacheKey] = count;
    return count;
  }

  String getFilterTypeName(FileFilterType filter, int count) {
    switch (filter) {
      case FileFilterType.all:
        return '';
      case FileFilterType.documents:
        return count == 1 ? 'document' : 'documents';
      case FileFilterType.images:
        return count == 1 ? 'image' : 'images';
      case FileFilterType.audio:
        return count == 1 ? 'audio' : 'audios';
      case FileFilterType.videos:
        return count == 1 ? 'video' : 'videos';
      case FileFilterType.archives:
        return count == 1 ? 'archive' : 'archives';
    }
  }

  bool _isGridView = false;
  bool get isGridView => _isGridView;

  void setGridView(bool value) {
    if (_isGridView == value) return;
    _isGridView = value;
    PreferencesService.saveIsGridView(_isGridView);
    notifyListeners();
  }

  void toggleViewMode() {
    _isGridView = !_isGridView;
    PreferencesService.saveIsGridView(_isGridView);
    notifyListeners();
  }

  double _iconScale = 1.0;
  double get iconScale => _iconScale;

  void setIconScale(double scale) {
    final clamped = scale.clamp(0.7, 1.5);
    if (_iconScale == clamped) return;
    _iconScale = clamped;
    PreferencesService.saveIconScale(_iconScale);
    notifyListeners();
  }

  double _itemPaddingMultiplier = 1.0;
  double get itemPaddingMultiplier => _itemPaddingMultiplier;

  void setItemPaddingMultiplier(double mult) {
    final clamped = mult.clamp(0.4, 2.0);
    if (_itemPaddingMultiplier == clamped) return;
    _itemPaddingMultiplier = clamped;
    PreferencesService.saveItemPaddingMultiplier(_itemPaddingMultiplier);
    notifyListeners();
  }

  void _sortList(List<FileItemModel> items, String path) {
    final activeSort = getSortTypeForPath(path);
    switch (activeSort) {
      case FileSortType.nameAsc:
        items.sort((a, b) => FileUtils.compareNatural(a.name, b.name));
        break;
      case FileSortType.nameDesc:
        items.sort((a, b) => FileUtils.compareNatural(b.name, a.name));
        break;
      case FileSortType.dateNewest:
        items.sort((a, b) => b.modified.compareTo(a.modified));
        break;
      case FileSortType.dateOldest:
        items.sort((a, b) => a.modified.compareTo(b.modified));
        break;
      case FileSortType.sizeLargest:
        items.sort((a, b) => b.size.compareTo(a.size));
        break;
      case FileSortType.sizeSmallest:
        items.sort((a, b) => a.size.compareTo(b.size));
        break;
      case FileSortType.type:
        items.sort((a, b) {
          final extA = p.extension(a.name).toLowerCase();
          final extB = p.extension(b.name).toLowerCase();
          return extA.compareTo(extB);
        });
        break;
    }

    // Stable-sort pinned files/folders to the top of the list!
    if (items.isNotEmpty) {
      final pinned = <FileItemModel>[];
      final unpinned = <FileItemModel>[];
      for (final item in items) {
        if (PinService.isPinned(item.path)) {
          pinned.add(item);
        } else {
          unpinned.add(item);
        }
      }
      items.clear();
      items.addAll(pinned);
      items.addAll(unpinned);
    }
  }

  bool _showHiddenFiles = false;
  bool get showHiddenFiles => _showHiddenFiles;

  void toggleHiddenFiles() {
    _showHiddenFiles = !_showHiddenFiles;
    PreferencesService.saveShowHiddenFiles(_showHiddenFiles);
    notifyListeners();
    if (_tabs.isNotEmpty && currentPath.isNotEmpty) {
      loadDirectory(currentPath, showLoading: false);
    }
  }

  bool _showFloatingAddButton = false;
  bool get showFloatingAddButton => _showFloatingAddButton;

  void toggleFloatingAddButton() {
    _showFloatingAddButton = !_showFloatingAddButton;
    PreferencesService.saveShowFloatingAddButton(_showFloatingAddButton);
    notifyListeners();
  }

  bool _showRemoteCloudBadge = true;
  bool get showRemoteCloudBadge => _showRemoteCloudBadge;

  /// 实际是否显示远程云徽：用户开关开启 且 单窗口模式。双窗口下云徽会遮挡图标，故强制隐藏。
  bool get effectiveShowRemoteCloudBadge => _showRemoteCloudBadge && !_enableSplitScreen;

  void toggleRemoteCloudBadge() {
    _showRemoteCloudBadge = !_showRemoteCloudBadge;
    PreferencesService.saveShowRemoteCloudBadge(_showRemoteCloudBadge);
    notifyListeners();
  }

  bool _defaultToBrowseScreen = false;
  bool get defaultToBrowseScreen => _defaultToBrowseScreen;

  void toggleDefaultToBrowseScreen() {
    _defaultToBrowseScreen = !_defaultToBrowseScreen;
    PreferencesService.saveDefaultToBrowseScreen(_defaultToBrowseScreen);
    notifyListeners();
  }

  void setDefaultToBrowseScreen(bool val) {
    if (_defaultToBrowseScreen == val) return;
    _defaultToBrowseScreen = val;
    PreferencesService.saveDefaultToBrowseScreen(_defaultToBrowseScreen);
    notifyListeners();
  }

  bool get enableDualFingerSwipe => _swipeMode == 'dual';

  // 滑动切换页面模式：'single' 或 'dual'
  String _swipeMode = 'single';
  String get swipeMode => _swipeMode;
  bool get enableSingleFingerSwipe => _swipeMode == 'single';

  // 地址栏（面包屑）交互抑制页面滑动切换手势：
  // 面包屑区域按下/拖拽期间置为 true，home 的滑动 Listener 据此跳过本次手势追踪，
  // 避免左右滑动面包屑被误判为切换分类页/快捷操作页。
  bool _breadcrumbInteracting = false;
  bool get breadcrumbInteracting => _breadcrumbInteracting;
  void setBreadcrumbInteracting(bool value) {
    // 故意不 notifyListeners：仅 home 的滑动 Listener 直接读取当前值，无需重建整树。
    _breadcrumbInteracting = value;
  }

  // 标签页栏交互抑制页面滑动切换手势：
  // 标签页区域按下/拖拽期间置为 true，home 的滑动 Listener 据此跳过本次手势追踪，
  // 避免左右滑动标签页被误判为切换分类页/快捷操作页。
  bool _tabBarInteracting = false;
  bool get tabBarInteracting => _tabBarInteracting;
  void setTabBarInteracting(bool value) {
    // 故意不 notifyListeners：仅 home 的滑动 Listener 直接读取当前值，无需重建整树。
    _tabBarInteracting = value;
  }

  // 分类页“长按拖动类别排序”抑制页面滑动切换手势：
  // 在自定义对话框的 ReorderableListView 拖拽期间置为 true（onReorderStart→true /
  // onReorderEnd→false），home 的滑动 Listener 据此取消本次手势追踪，
  // 避免长按拖动排序被误判为切换分类页/快捷操作页。
  bool _categoryReorderInteracting = false;
  bool get categoryReorderInteracting => _categoryReorderInteracting;
  void setCategoryReorderInteracting(bool value) {
    // 故意不 notifyListeners：仅 home 的滑动 Listener 直接读取当前值，无需重建整树。
    _categoryReorderInteracting = value;
  }

  void setSwipeMode(String mode) {
    _swipeMode = mode;
    PreferencesService.saveSwipeMode(mode);
    notifyListeners();
  }

  void toggleSingleFingerSwipe() {
    setSwipeMode(_swipeMode == 'single' ? 'dual' : 'single');
  }

  // 临时导航状态：从设置页面跳转到浏览标签
  bool _navigateToBrowseTab = false;
  bool get navigateToBrowseTab => _navigateToBrowseTab;
  final ValueNotifier<bool> _navigateToBrowseTabNotifier = ValueNotifier<bool>(false);
  ValueNotifier<bool> get navigateToBrowseTabNotifier => _navigateToBrowseTabNotifier;

  void setNavigateToBrowseTab(bool value) {
    _navigateToBrowseTab = value;
    // 强制通知：先取反再设值，确保 ValueNotifier 监听器始终被触发
    if (value) {
      _navigateToBrowseTabNotifier.value = false;
    }
    _navigateToBrowseTabNotifier.value = value;
  }

  // 解压后跳转到浏览页并高亮文件
  String? _pendingBrowsePath;
  String? get pendingBrowsePath => _pendingBrowsePath;
  List<String> _pendingHighlightedPaths = [];
  List<String> get pendingHighlightedPaths => _pendingHighlightedPaths;

  void setPendingBrowseNavigation(String targetPath, List<String> highlightedPaths) {
    _pendingBrowsePath = targetPath;
    _pendingHighlightedPaths = highlightedPaths;
    _navigateToBrowseTab = true;
    _navigateToBrowseTabNotifier.value = true;
  }

  void clearPendingBrowseNavigation() {
    _pendingBrowsePath = null;
    _pendingHighlightedPaths = [];
    _navigateToBrowseTab = false;
    _navigateToBrowseTabNotifier.value = false;
  }

  bool _rememberLastFolder = false;
  bool get rememberLastFolder => _rememberLastFolder;

  void toggleRememberLastFolder() {
    _rememberLastFolder = !_rememberLastFolder;
    PreferencesService.saveRememberLastFolder(_rememberLastFolder);
    notifyListeners();
  }

  bool _showFolderFileCount = false;
  bool get showFolderFileCount => _showFolderFileCount;

  void toggleFolderFileCount() {
    _showFolderFileCount = !_showFolderFileCount;
    PreferencesService.saveShowFolderFileCount(_showFolderFileCount);
    notifyListeners();
  }

  bool _use24HourFormat = false;
  bool get use24HourFormat => _use24HourFormat;

  void toggleUse24HourFormat() {
    _use24HourFormat = !_use24HourFormat;
    PreferencesService.saveUse24HourFormat(_use24HourFormat);
    notifyListeners();
  }

  bool _hideTimeAndDate = false;
  bool get hideTimeAndDate => _hideTimeAndDate;

  void toggleHideTimeAndDate() {
    _hideTimeAndDate = !_hideTimeAndDate;
    PreferencesService.saveHideTimeAndDate(_hideTimeAndDate);
    notifyListeners();
  }

  bool _showFolderContentsCount = false;
  bool get showFolderContentsCount => _showFolderContentsCount;

  void toggleFolderContentsCount() {
    _showFolderContentsCount = !_showFolderContentsCount;
    PreferencesService.saveShowFolderContentsCount(_showFolderContentsCount);
    notifyListeners();
  }

  bool _showFolderSizes = false;
  bool get showFolderSizes => _showFolderSizes;

  void toggleShowFolderSizes() {
    _showFolderSizes = !_showFolderSizes;
    PreferencesService.saveShowFolderSizes(_showFolderSizes);
    notifyListeners();
  }

  final Map<String, int> _folderItemCounts = {};

  /// 计算文件夹的直接子项数量。
  /// 本地目录使用 dart:io 枚举；远程目录使用当前 tab 的 [RemoteClient.listDirectory]
  /// 统计，避免在远程路径上误用本地 [Directory] 导致始终返回 0。
  Future<int> getFolderItemCount(String folderPath, {bool isRemote = false}) async {
    final cacheKey = isRemote && activeTab.remoteConnection != null
        ? '${activeTab.remoteConnection!.id}::$folderPath'
        : folderPath;

    if (_folderItemCounts.containsKey(cacheKey)) {
      return _folderItemCounts[cacheKey]!;
    }

    int count = 0;

    if (isRemote && activeTab.remoteClient != null) {
      try {
        final items = await activeTab.remoteClient!.listDirectory(folderPath);
        final showHidden = _showHiddenFiles;
        for (final item in items) {
          final name = item.name;
          if (!showHidden && name.startsWith('.')) {
            continue;
          }
          count++;
        }
      } catch (_) {}
    } else {
      try {
        final dir = Directory(folderPath);
        if (await dir.exists()) {
          final entities = await dir.list().toList();
          final showHidden = _showHiddenFiles;
          for (var entity in entities) {
            final name = p.basename(entity.path);
            if (!showHidden && name.startsWith('.')) {
              continue;
            }
            count++;
          }
        }
      } catch (_) {}
    }

    _folderItemCounts[cacheKey] = count;
    return count;
  }

  final Map<String, int> _folderSizes = {};

  Future<int> getFolderSize(String folderPath) async {
    if (_folderSizes.containsKey(folderPath)) {
      return _folderSizes[folderPath]!;
    }

    // Offload directory size calculation to a background isolate (compute)
    // to prevent blocking the main UI thread during recursive disk reads.
    int totalSize = await compute(_calculateDirectorySizeSync, folderPath);
    _folderSizes[folderPath] = totalSize;
    return totalSize;
  }

  void clearFolderItemCountsCache() {
    _folderItemCounts.clear();
    _folderSizes.clear();
  }

  bool _showBottomActionBar = false;
  bool get showBottomActionBar => _showBottomActionBar;

  void toggleBottomActionBar() {
    _showBottomActionBar = !_showBottomActionBar;
    PreferencesService.saveShowBottomActionBar(_showBottomActionBar);
    notifyListeners();
  }

  void setBottomActionBar(bool value) {
    if (_showBottomActionBar == value) return;
    _showBottomActionBar = value;
    PreferencesService.saveShowBottomActionBar(_showBottomActionBar);
    notifyListeners();
  }

  bool _showHomeBrowseNav = true;
  bool get showHomeBrowseNav => _showHomeBrowseNav;

  void toggleShowHomeBrowseNav() {
    _showHomeBrowseNav = !_showHomeBrowseNav;
    PreferencesService.saveShowHomeBrowseNav(_showHomeBrowseNav);
    notifyListeners();
  }

  bool _hideNavigationBar = false;
  bool get hideNavigationBar => _hideNavigationBar;

  void toggleHideNavigationBar() {
    _hideNavigationBar = !_hideNavigationBar;
    PreferencesService.saveHideNavigationBar(_hideNavigationBar);
    if (_hideNavigationBar) {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.manual, overlays: [SystemUiOverlay.top]);
    } else {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.manual, overlays: SystemUiOverlay.values);
    }
    notifyListeners();
  }

  bool _showMediaPreviews = true;
  bool get showMediaPreviews => _showMediaPreviews;

  void toggleMediaPreviews() {
    _showMediaPreviews = !_showMediaPreviews;
    PreferencesService.saveShowMediaPreviews(_showMediaPreviews);
    notifyListeners();
  }

  bool _skipOpenWithDialog = false;
  bool get skipOpenWithDialog => _skipOpenWithDialog;

  void toggleSkipOpenWithDialog() {
    _skipOpenWithDialog = !_skipOpenWithDialog;
    PreferencesService.saveSkipOpenWithDialog(_skipOpenWithDialog);
    notifyListeners();
  }

  bool _showAddressBar = false;
  bool get showAddressBar => _showAddressBar;

  void toggleShowAddressBar() {
    _showAddressBar = !_showAddressBar;
    PreferencesService.saveShowAddressBar(_showAddressBar);
    notifyListeners();
  }

  bool _amoledMode = false;
  bool get amoledMode => _amoledMode;

  void toggleAmoledMode() {
    _amoledMode = !_amoledMode;
    PreferencesService.saveAmoledMode(_amoledMode);
    notifyListeners();
  }

  void setAmoledMode(bool val) {
    if (_amoledMode == val) return;
    _amoledMode = val;
    PreferencesService.saveAmoledMode(val);
    notifyListeners();
  }

  bool _showRecentFiles = false;
  bool get showRecentFiles => _showRecentFiles;

  void toggleShowRecentFiles() {
    _showRecentFiles = !_showRecentFiles;
    PreferencesService.saveShowRecentFiles(_showRecentFiles);
    notifyListeners();
  }

  bool _enableFolderHighlight = true;
  bool get enableFolderHighlight => _enableFolderHighlight;

  void toggleEnableFolderHighlight() {
    _enableFolderHighlight = !_enableFolderHighlight;
    PreferencesService.saveEnableFolderHighlight(_enableFolderHighlight);
    notifyListeners();
  }

  bool _adaptiveMultiLineNames = false;
  bool get adaptiveMultiLineNames => _adaptiveMultiLineNames;

  void toggleAdaptiveMultiLineNames() {
    _adaptiveMultiLineNames = !_adaptiveMultiLineNames;
    PreferencesService.saveAdaptiveMultiLineNames(_adaptiveMultiLineNames);
    notifyListeners();
  }

  // 兼容旧代码：保留 _hideActionMenuButtons 字段（不再主动使用，但部分代码可能引用）
  bool _hideActionMenuButtons = false;
  // 新设置：是否显示三点操作按钮（默认开启）
  bool _showActionMenuButtons = true;
  bool get showActionMenuButtons => _showActionMenuButtons;
  // 新设置：显示模式 'all' | 'single' | 'dual'
  String _actionMenuDisplayMode = 'all';
  String get actionMenuDisplayMode => _actionMenuDisplayMode;

  /// 计算属性：根据 showActionMenuButtons 和 actionMenuDisplayMode 判断当前是否应隐藏三点按钮。
  /// 兼容旧的 hideActionMenuButtons 调用点（!hideActionMenuButtons 即显示）。
  bool get hideActionMenuButtons {
    if (!_showActionMenuButtons) return true;
    switch (_actionMenuDisplayMode) {
      case 'single':
        return enableSplitScreen; // 单窗口模式才显示 → 双窗口时隐藏
      case 'dual':
        return !enableSplitScreen; // 双窗口模式才显示 → 单窗口时隐藏
      default:
        return false; // 'all' 全部显示
    }
  }

  void setShowActionMenuButtons(bool val) {
    _showActionMenuButtons = val;
    PreferencesService.saveShowActionMenuButtons(val);
    notifyListeners();
  }

  void setActionMenuDisplayMode(String mode) {
    _actionMenuDisplayMode = mode;
    PreferencesService.saveActionMenuDisplayMode(mode);
    notifyListeners();
  }

  void toggleHideActionMenuButtons() {
    _hideActionMenuButtons = !_hideActionMenuButtons;
    PreferencesService.saveHideActionMenuButtons(_hideActionMenuButtons);
    notifyListeners();
  }

  bool _hideActionText = false;
  bool get hideActionText => _hideActionText;

  void toggleHideActionText() {
    _hideActionText = !_hideActionText;
    PreferencesService.saveHideActionText(_hideActionText);
    notifyListeners();
  }

  String _categoryIconShape = 'circle';
  String get categoryIconShape => _categoryIconShape;

  void setCategoryIconShape(String shape) {
    if (_categoryIconShape == shape) return;
    _categoryIconShape = shape;
    PreferencesService.saveCategoryIconShape(shape);
    notifyListeners();
  }

  int _categoriesGridColumns = 4;
  int get categoriesGridColumns => _categoriesGridColumns;

  void setCategoriesGridColumns(int columns) {
    if (_categoriesGridColumns == columns) return;
    _categoriesGridColumns = columns;
    PreferencesService.saveCategoriesGridColumns(columns);
    notifyListeners();
  }

  bool _hideNavLabels = false;
  bool get hideNavLabels => _hideNavLabels;

  void toggleHideNavLabels() {
    _hideNavLabels = !_hideNavLabels;
    PreferencesService.saveHideNavLabels(_hideNavLabels);
    notifyListeners();
  }

  String _trailingInfoType = 'none';
  String get trailingInfoType => _trailingInfoType;

  void setTrailingInfoType(String val) {
    if (_trailingInfoType == val) return;
    _trailingInfoType = val;
    PreferencesService.saveTrailingInfoType(val);
    notifyListeners();
  }

  bool _enableDragDrop = false;
  bool get enableDragDrop => _enableDragDrop;

  void toggleEnableDragDrop() {
    _enableDragDrop = !_enableDragDrop;
    PreferencesService.saveEnableDragDrop(_enableDragDrop);
    notifyListeners();
  }

  bool _showDragDropDialog = true;
  bool get showDragDropDialog => _showDragDropDialog;

  void toggleShowDragDropDialog() {
    _showDragDropDialog = !_showDragDropDialog;
    PreferencesService.saveShowDragDropDialog(_showDragDropDialog);
    notifyListeners();
  }

  bool _enableMultipleTabs = true;
  bool get enableMultipleTabs => _enableMultipleTabs;

  void toggleMultipleTabs() {
    _enableMultipleTabs = !_enableMultipleTabs;
    PreferencesService.saveEnableMultipleTabs(_enableMultipleTabs);
    if (!_enableMultipleTabs) {
      closeOtherTabs();
    }
    notifyListeners();
  }

  bool _enableSplitScreen = false;
  bool get enableSplitScreen => _enableSplitScreen;

  Set<CategoryFilterType> _categoryFilter = {};
  Set<CategoryFilterType> get selectedCategoryFilters => _categoryFilter;
  bool get isCategoryFilterActive => _categoryFilter.isNotEmpty;
  bool isCategoryFilterSelected(CategoryFilterType type) => _categoryFilter.contains(type);

  bool _rememberCategoryFilter = false;
  bool get rememberCategoryFilter => _rememberCategoryFilter;

  /// 多选切换：点击某个类别在集合中增删；点击「全部」清空集合（显示所有）。
  void toggleCategoryFilter(CategoryFilterType type, {bool? remember}) {
    if (type == CategoryFilterType.none) {
      _categoryFilter.clear();
    } else if (_categoryFilter.contains(type)) {
      _categoryFilter.remove(type);
    } else {
      _categoryFilter.add(type);
    }
    if (remember != null) {
      _rememberCategoryFilter = remember;
      PreferencesService.saveRememberCategoryFilter(remember);
    }
    if (_rememberCategoryFilter) {
      PreferencesService.saveCategoryFilters(_categoryFilter);
    }
    notifyListeners();
  }

  void setRememberCategoryFilter(bool val) {
    _rememberCategoryFilter = val;
    PreferencesService.saveRememberCategoryFilter(val);
    if (val) {
      PreferencesService.saveCategoryFilters(_categoryFilter);
    } else {
      // 关闭记住时清除已持久化的过滤条件，避免残留数据下次开启时复用旧条件。
      PreferencesService.saveCategoryFilters({});
    }
    notifyListeners();
  }

  void toggleSplitScreen() {
    _enableSplitScreen = !_enableSplitScreen;
    PreferencesService.saveEnableSplitScreen(_enableSplitScreen);
    
    if (_enableSplitScreen) {
      if (_tabs.length < 2) {
        final homeRight = PreferencesService.getHomeDirectoryRight();
        final rightPath = homeRight ?? (_rootPath.isNotEmpty ? _rootPath : '/');
        final newTab = FolderTab(
          id: DateTime.now().millisecondsSinceEpoch.toString(),
          currentPath: rightPath,
        );
        _tabs.add(newTab);
      }
      loadDirectoryForTab(0, _tabs[0].currentPath, showLoading: false);
      loadDirectoryForTab(1, _tabs[1].currentPath, showLoading: false);
    } else {
      if (_activeTabIndex >= _tabs.length) {
        _activeTabIndex = 0;
      }
    }
    notifyListeners();
  }

  Future<void> loadDirectoryForTab(
    int tabIndex,
    String path, {
    bool showLoading = true,
    bool clearCache = false,
    bool forceRefresh = false,
    bool recordHistory = false,
  }) async {
    if (tabIndex < 0 || tabIndex >= _tabs.length) return;

    // 串行化：防止两个 pane 并发刷新导致 _activeTabIndex 被覆盖、刷新目标错乱。
    while (_loadDirectoryForTabLock != null) {
      try {
        await _loadDirectoryForTabLock!.future;
      } catch (_) {}
    }
    final lock = Completer<void>();
    _loadDirectoryForTabLock = lock;

    try {
      final oldIndex = _activeTabIndex;
      _activeTabIndex = tabIndex;
      try {
        await loadDirectory(
          path,
          showLoading: showLoading,
          clearCache: clearCache,
          forceRefresh: forceRefresh,
          recordHistory: recordHistory,
        );
      } finally {
        // 必须恢复原来的 activeTabIndex，否则异步刷新期间若用户切换了 pane
        // 或发生异常，activeTabIndex 会永久停留在目标 tab，导致地址栏/返回
        // 等全局状态错乱。
        _activeTabIndex = oldIndex;
        notifyListeners();
      }
    } finally {
      lock.complete();
      if (_loadDirectoryForTabLock == lock) {
        _loadDirectoryForTabLock = null;
      }
    }
  }

  // --- Tab Management ---
  List<FolderTab> _tabs = [];
  int _activeTabIndex = 0;
  // loadDirectoryForTab 会临时切换全局 _activeTabIndex，若两个 pane 并发刷新
  // （如同时下拉刷新或后台轮询与手动刷新重叠），_activeTabIndex 会被覆盖，
  // 导致刷新目标错乱。用简单 Future 锁串行化。
  Completer<void>? _loadDirectoryForTabLock;

  /// 记录每个 tab 上哪些远程目录正处于上传后最终化等待中（后台轮询
  /// [scheduleRemoteRefreshAfterUpload] 尚未结束）。
  /// 用于在 [loadDirectory] 中抑制同一路径的可见目录刷新，防止手动刷新 /
  /// 自动刷新把 openlist 本机储存的 staging 中间态暴露给用户（问题2/3 的
  /// 补充防御：即使轮询逻辑之外还有刷新入口，也能保持隐藏）。
  final Map<int, Set<String>> _pendingFinalizePaths = {};

  List<FolderTab> get tabs => _tabs;
  int get activeTabIndex => _activeTabIndex;

  FolderTab get activeTab {
    if (_tabs.isEmpty) {
      _tabs = [FolderTab(id: 'default', currentPath: _rootPath.isNotEmpty ? _rootPath : '/')];
    }
    return _tabs[_activeTabIndex];
  }

  void addTab(String path) {
    final newTab = FolderTab(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      currentPath: path,
    );
    // 在双窗口模式下，如果已有2个或更多tab，替换未激活的tab
    if (enableSplitScreen && _tabs.length >= 2) {
      final inactiveIndex = _activeTabIndex == 0 ? 1 : 0;
      _tabs[inactiveIndex] = newTab;
      _activeTabIndex = inactiveIndex;
    } else {
      _tabs.add(newTab);
      _activeTabIndex = _tabs.length - 1;
    }
    _persistTabs();
    notifyListeners();
    loadDirectory(path);
  }

  /// Open a remote connection in a new (or existing) tab, reusing the
  /// DirectoryScreen UI instead of the old RemoteExplorerScreen.
  Future<void> openRemoteTab(RemoteClient client, NetworkConnectionModel connection) async {
    final newTab = FolderTab(
      id: 'remote_${connection.name}_${DateTime.now().millisecondsSinceEpoch}',
      currentPath: connection.rootPath,
      isRemote: true,
      remoteClient: client,
      remoteConnection: connection,
    );

    if (enableSplitScreen) {
      // 双窗口模式：保持原行为——先移除所有已有远程 tab，再替换未激活的 tab。
      // 双窗口只有两个 pane，远程连接始终占用其中一个 pane，覆盖是预期行为。
      _tabs.removeWhere((t) => t.isRemote);
      if (_tabs.length >= 2) {
        final inactiveIndex = _activeTabIndex == 0 ? 1 : 0;
        _tabs[inactiveIndex] = newTab;
        _activeTabIndex = inactiveIndex;
      } else {
        _tabs.add(newTab);
        _activeTabIndex = _tabs.length - 1;
      }
    } else {
      // 单窗口模式：每个远程客户端都新建独立标签页，不再移除已打开的远程 tab，
      // 避免后打开的远程连接覆盖先打开的远程连接。
      _tabs.add(newTab);
      _activeTabIndex = _tabs.length - 1;
    }
    _persistTabs();
    notifyListeners();

    // For SMB with generic root path, keep "/" to list all shared directories.
    await loadDirectory(newTab.currentPath);
  }

  /// Returns true if [type] represents an SMB/LAN connection.
  /// The SMB label is localized (e.g. '局域网/SMB' in Chinese, 'LAN/SMB' in
  /// English), so we cannot compare against a single hardcoded string.
  /// Instead we check if the type contains 'smb' (case-insensitive), which
  /// matches all current locale variants.
  static bool isSmbType(String type) {
    return type.toLowerCase().contains('smb');
  }

  static const Set<String> _ignoredSmbShareNames = {
    'ipc\$',
    'print\$',
    'admin\$',
    'c\$',
    'd\$',
    'e\$',
    'f\$',
  };

  static const List<String> _defaultSmbShareNames = [
    'Public', 'Shared', 'share', 'Shares', 'files', 'Files', 'data', 'Data',
    'Documents', 'Docs', 'Home', 'home', 'homes', 'Media', 'media', 'NAS', 'nas',
    'Videos', 'Movies', 'Music', 'Download', 'Downloads', 'backup', 'Backup',
    'Multimedia', 'video', 'photo', 'music', 'Recordings', 'storage', 'Storage',
    'archive', 'Archive', 'workspace', 'Workspace', 'sync', 'Sync',
    'Software', 'Games', 'work', 'server', 'fileshare',
    'project', 'projects', 'tmp', 'Temp', 'temp',
    'share1', 'share2', 'data1', 'data2', 'files1', 'files2',
    'Photos', 'Pictures', 'Images', 'TV', 'Movie',
    'Anime', 'anime', 'Cartoons', 'cartoons',
    'Documentaries', 'documentaries', 'Sports', 'sports',
    'Users', 'users', 'Profile',
    'disk', 'Disk', 'cloud', 'Cloud',
    'Volume1', 'volume1', 'Volume', 'volume',
    'Volume2', 'volume2', 'Volume3', 'volume3',
    'everyone', 'guest', 'nobody', 'root',
    'usb', 'USB', 'usb1', 'USB1',
    'external', 'External', 'external1', 'External1',
    'backups', 'film', 'films', 'audio', 'picture', 'image',
    'Web', 'TimeMachineBackup', 'SmartWare',
    'terramaster', 'TerraMaster', 'asustor', 'Asustor',
    'buffalo', 'Buffalo',
    'gongxiang', 'gonggong', 'xiazai', 'yingyin',
    'yinyue', 'tupian', 'wenjian', 'ziyuan',
    'shuju', 'beifen', 'yingshi', 'boke',
    'ruanjian', 'yingpan', 'cangku',
    'jiankang', 'shexiang', 'shebei', 'shequ',
    'bangong', 'bangongwenjian', 'xuexi', 'xuexiziliao',
    'youxi', 'youxianzhuang', 'xiaoshuo', 'xiaoshuowenjian',
    'admin', 'Admin', 'administrator', 'Administrator',
    'Sharing', 'sharing',
  ];

  static String? _pickBrowsableSmbSharePath(List<RemoteFileItem> items) {
    for (final item in items) {
      if (!item.isDirectory) continue;
      final lowerName = item.name.toLowerCase();
      if (_ignoredSmbShareNames.contains(lowerName)) continue;
      if (lowerName.endsWith(r'$')) continue;
      return '/${item.name}';
    }
    return null;
  }

  static Iterable<String> _tokenizeSmbGuessSource(String raw) sync* {
    for (final part in raw.split(RegExp(r'[\\/\s._-]+'))) {
      final token = part.trim();
      if (token.length >= 2) {
        yield token;
      }
    }
  }

  static List<String> _buildSmbShareGuessNames(NetworkConnectionModel? connection) {
    final ordered = <String>[];
    final seen = <String>{};

    void addCandidate(String? value) {
      final candidate = value?.trim();
      if (candidate == null || candidate.isEmpty) return;
      final normalized = candidate.replaceAll('\\', '/').trim();
      if (normalized.isEmpty || normalized == '/') return;
      if (normalized.contains('/')) {
        final firstSegment = normalized
            .split('/')
            .firstWhere((segment) => segment.isNotEmpty, orElse: () => '');
        addCandidate(firstSegment);
        return;
      }
      final lower = normalized.toLowerCase();
      if (_ignoredSmbShareNames.contains(lower)) return;
      if (seen.add(lower)) {
        ordered.add(normalized);
      }
    }

    for (final name in _defaultSmbShareNames) {
      addCandidate(name);
    }

    if (connection != null) {
      addCandidate(connection.rootPath);
      addCandidate(connection.username);

      final host = connection.host.trim();
      if (host.isNotEmpty) {
        addCandidate(host);
        addCandidate(host.split(':').first);
        addCandidate(host.split('.').first);
        for (final token in _tokenizeSmbGuessSource(host)) {
          addCandidate(token);
        }
      }

      final connectionName = connection.name.trim();
      if (connectionName.isNotEmpty) {
        addCandidate(connectionName);
        for (final token in _tokenizeSmbGuessSource(connectionName)) {
          addCandidate(token);
        }
      }
    }

    return ordered;
  }

  static Future<String?> detectSmbShare(RemoteClient client, {NetworkConnectionModel? connection, bool forceRefresh = false}) async {
    try {
      final rootItems = await client.listDirectory('/', forceRefresh: forceRefresh);
      final detectedFromRoot = _pickBrowsableSmbSharePath(rootItems);
      if (detectedFromRoot != null) {
        return detectedFromRoot;
      }
    } catch (e) {
      debugPrint('SMB root share list failed: $e');
    }

    for (final guess in _buildSmbShareGuessNames(connection)) {
      try {
        await client.listDirectory('/$guess');
        return '/$guess';
      } catch (_) {
        // continue to next guess
      }
    }

    return null;
  }

  /// Factory: create the correct RemoteClient subclass for a connection model.
  static RemoteClient createRemoteClient(NetworkConnectionModel conn) {
    if (conn.type == 'FTP') {
      return FtpRemoteClient(host: conn.host, port: conn.port, username: conn.username, password: conn.password);
    }
    if (conn.type == 'SFTP') {
      return SftpRemoteClient(host: conn.host, port: conn.port, username: conn.username, password: conn.password);
    }
    if (conn.type == 'WebDav') {
      return WebDavRemoteClient(
        host: conn.host, port: conn.port, username: conn.username, password: conn.password,
        protocol: conn.protocol, rootPath: conn.rootPath,
      );
    }
    if (isSmbType(conn.type)) {
      return LanClient(host: conn.host, port: conn.port, username: conn.username, password: conn.password);
    }
    if (conn.type == 'saf') {
      return SafRemoteClient(rootUri: conn.rootPath);
    }
    throw ArgumentError('Unsupported connection type: ${conn.type}');
  }

  /// 将 `remote://{connectionId}|{remotePath}` 文件下载到本地缓存并返回本地路径。
  /// 供图片查看器等需要本地 File 的场景调用（远程图片无法直接 File() 读取）。
  /// 已缓存则直接返回。失败返回 null。
  static Future<String?> downloadRemoteFileToCache(String remotePathStr) async {
    try {
      if (!remotePathStr.startsWith('remote://')) return null;
      final uriPart = remotePathStr.substring('remote://'.length);
      final sep = uriPart.indexOf('|');
      if (sep < 0) return null;
      final connectionId = uriPart.substring(0, sep);
      final remotePath = uriPart.substring(sep + 1);
      final conn = NetworkConnectionsService.getConnections()
          .where((c) => c.id == connectionId)
          .firstOrNull;
      if (conn == null) return null;
      final client = createRemoteClient(conn);
      await client.connect();
      try {
        final cacheDir = Directory('/storage/emulated/0/ZenFile/.remote_cache');
        if (!cacheDir.existsSync()) cacheDir.createSync(recursive: true);
        final baseName = p.basename(remotePath);
        final cacheName = '${remotePathStr.hashCode}_$baseName';
        final cachePath = p.join(cacheDir.path, cacheName);
        if (!File(cachePath).existsSync()) {
          await client.downloadFile(remotePath, cachePath, (_) {});
        }
        return cachePath;
      } finally {
        await client.disconnect();
      }
    } catch (e) {
      debugPrint('[ZenFile] downloadRemoteFileToCache error: $e');
      return null;
    }
  }

  /// 解析 `remote://{connId}|{serverPath}`，返回 (connectionId, serverPath) 或 null。
  static List<String>? parseRemotePathParts(String remotePathStr) {
    if (!remotePathStr.startsWith('remote://')) return null;
    final uriPart = remotePathStr.substring('remote://'.length);
    final sep = uriPart.indexOf('|');
    if (sep < 0) return null;
    return [uriPart.substring(0, sep), uriPart.substring(sep + 1)];
  }

  /// 根据 remote:// 路径取对应连接。
  static NetworkConnectionModel? connectionForRemotePath(String remotePathStr) {
    final parts = parseRemotePathParts(remotePathStr);
    if (parts == null) return null;
    return NetworkConnectionsService.getConnections()
        .where((c) => c.id == parts[0])
        .firstOrNull;
  }

  /// 删除 remote:// 远程文件（分类页远程文件菜单用）。
  static Future<bool> deleteRemotePath(String remotePathStr) async {
    try {
      final parts = parseRemotePathParts(remotePathStr);
      if (parts == null) return false;
      final conn = NetworkConnectionsService.getConnections()
          .where((c) => c.id == parts[0])
          .firstOrNull;
      if (conn == null) return false;
      final client = createRemoteClient(conn);
      await client.connect();
      try {
        await client.delete(parts[1], false);
        return true;
      } finally {
        await client.disconnect();
      }
    } catch (e) {
      debugPrint('[ZenFile] deleteRemotePath error: $e');
      return false;
    }
  }

  /// 重命名 remote:// 远程文件（仅改文件名）。
  static Future<bool> renameRemotePath(String remotePathStr, String newName) async {
    try {
      final parts = parseRemotePathParts(remotePathStr);
      if (parts == null) return false;
      final conn = NetworkConnectionsService.getConnections()
          .where((c) => c.id == parts[0])
          .firstOrNull;
      if (conn == null) return false;
      final client = createRemoteClient(conn);
      await client.connect();
      try {
        final parent = _remoteDirname(parts[1]);
        final newPath = parent.endsWith('/') ? '$parent$newName' : '$parent/$newName';
        await client.rename(parts[1], newPath);
        return true;
      } finally {
        await client.disconnect();
      }
    } catch (e) {
      debugPrint('[ZenFile] renameRemotePath error: $e');
      return false;
    }
  }

  /// 将 remote:// 文件加入远程剪贴板（供远程浏览页粘贴）。
  void copyRemotePathToClipboard(String remotePathStr, {required bool isCut}) {
    final parts = parseRemotePathParts(remotePathStr);
    if (parts == null) return;
    final conn = NetworkConnectionsService.getConnections()
        .where((c) => c.id == parts[0])
        .firstOrNull;
    if (conn == null) return;
    final item = RemoteFileItem(
      name: _remoteBasename(parts[1]),
      path: parts[1],
      isDirectory: false,
      size: 0,
      modified: DateTime.now(),
    );
    setRemoteClipboard([item], isCut: isCut, connection: conn);
  }

  /// 批量删除多个 remote:// 文件，返回成功删除的数量。
  static Future<int> deleteRemotePaths(List<String> remotePaths) async {
    int deleted = 0;
    // 按 connectionId 分组，减少重复建连。
    final byConn = <String, List<String>>{};
    for (final rp in remotePaths) {
      final parts = parseRemotePathParts(rp);
      if (parts == null) continue;
      (byConn[parts[0]] ??= []).add(parts[1]);
    }
    for (final entry in byConn.entries) {
      final conn = NetworkConnectionsService.getConnections()
          .where((c) => c.id == entry.key)
          .firstOrNull;
      if (conn == null) continue;
      final client = createRemoteClient(conn);
      try {
        await client.connect();
        for (final serverPath in entry.value) {
          try {
            await client.delete(serverPath, false);
            deleted++;
          } catch (e) {
            debugPrint('[ZenFile] deleteRemotePaths item error: $e');
          }
        }
      } catch (_) {
      } finally {
        try {
          await client.disconnect();
        } catch (_) {}
      }
    }
    return deleted;
  }

  /// 批量重命名多个 remote:// 文件（同一新名时自动加序号）。
  /// 返回成功重命名数量。
  static Future<int> renameRemotePaths(List<String> remotePaths, String baseName) async {
    int renamed = 0;
    // 按 connectionId+parentDir 分组，避免同名。
    final groups = <String, List<String>>{};
    for (final rp in remotePaths) {
      final parts = parseRemotePathParts(rp);
      if (parts == null) continue;
      final parent = _remoteDirname(parts[1]);
      final key = '${parts[0]}|$parent';
      (groups[key] ??= []).add(rp);
    }
    for (final entry in groups.entries) {
      final sep = entry.key.indexOf('|');
      final connId = entry.key.substring(0, sep);
      final parent = entry.key.substring(sep + 1);
      final conn = NetworkConnectionsService.getConnections()
          .where((c) => c.id == connId)
          .firstOrNull;
      if (conn == null) continue;
      final client = createRemoteClient(conn);
      try {
        await client.connect();
        final ext = pathExtension(baseName);
        final nameNoExt = ext.isEmpty ? baseName : baseName.substring(0, baseName.length - ext.length);
        for (int i = 0; i < entry.value.length; i++) {
          final rp = entry.value[i];
          final parts = parseRemotePathParts(rp);
          if (parts == null) continue;
          final newName = entry.value.length == 1
              ? baseName
              : '$nameNoExt (${i + 1})$ext';
          final newPath = parent.endsWith('/') ? '$parent$newName' : '$parent/$newName';
          try {
            await client.rename(parts[1], newPath);
            renamed++;
          } catch (e) {
            debugPrint('[ZenFile] renameRemotePaths item error: $e');
          }
        }
      } catch (_) {
      } finally {
        try {
          await client.disconnect();
        } catch (_) {}
      }
    }
    return renamed;
  }

  /// 取扩展名（含点，小写）。
  static String pathExtension(String name) {
    final dot = name.lastIndexOf('.');
    if (dot < 0) return '';
    return name.substring(dot).toLowerCase();
  }

  void closeTab(int index) {
    if (_tabs.length <= 1) return;
    final removed = _tabs[index];
    if (removed.isRemote) {
      removed.remoteClient?.disconnect();
    }
    _tabs.removeAt(index);
    if (_activeTabIndex >= _tabs.length) {
      _activeTabIndex = _tabs.length - 1;
    } else if (_activeTabIndex == index) {
      if (_activeTabIndex >= _tabs.length) {
        _activeTabIndex = _tabs.length - 1;
      }
    } else if (_activeTabIndex > index) {
      _activeTabIndex--;
    }
    _persistTabs();
    notifyListeners();
  }

  void closeOtherTabs() {
    if (_tabs.length <= 1) return;
    final active = activeTab;
    _tabs = [active];
    _activeTabIndex = 0;
    _persistTabs();
    notifyListeners();
  }

  void duplicateActiveTab() {
    if (_tabs.isEmpty) return;
    final active = activeTab;
    final dup = FolderTab(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      currentPath: active.currentPath,
      currentFiles: List.from(active.currentFiles),
      isRestrictedMode: active.isRestrictedMode,
      needsPermission: active.needsPermission,
      useRootMode: active.useRootMode,
      useShizukuMode: active.useShizukuMode,
      isRootAvailable: active.isRootAvailable,
      scrollPositions: Map.from(active.scrollPositions),
      // 复制的标签页不继承 pinned 状态，否则用户无法通过双击关闭它
      isPinned: false,
      isRemote: active.isRemote,
      remoteClient: active.remoteClient,
      remoteConnection: active.remoteConnection,
      pathHistory: List<String>.from(active.pathHistory),
      historyIndex: active.historyIndex,
    );
    // 双窗口模式下，复制激活 tab 到未激活的 pane（索引 0 或 1），
    // 而不是新增 tab（否则 tabs 数量 > 2，PaneBrowser 看不到新增的 tab）
    if (enableSplitScreen && _tabs.length >= 2) {
      final inactiveIndex = _activeTabIndex == 0 ? 1 : 0;
      // 如果未激活 pane 是被钉住的，不覆盖
      if (_tabs[inactiveIndex].isPinned) {
        _tabs.add(dup);
        _activeTabIndex = _tabs.length - 1;
      } else {
        _tabs[inactiveIndex] = dup;
        _activeTabIndex = inactiveIndex;
      }
    } else {
      _tabs.add(dup);
      _activeTabIndex = _tabs.length - 1;
    }
    _persistTabs();
    notifyListeners();
  }

  void togglePinTab(int index) {
    if (index >= 0 && index < _tabs.length) {
      _tabs[index].isPinned = !_tabs[index].isPinned;
      _persistTabs();
      notifyListeners();
    }
  }

  void duplicateTab(int index) {
    if (index >= 0 && index < _tabs.length) {
      final tab = _tabs[index];
      final dup = FolderTab(
        id: DateTime.now().millisecondsSinceEpoch.toString(),
        currentPath: tab.currentPath,
        currentFiles: List.from(tab.currentFiles),
        isRestrictedMode: tab.isRestrictedMode,
        needsPermission: tab.needsPermission,
        useRootMode: tab.useRootMode,
        useShizukuMode: tab.useShizukuMode,
        isRootAvailable: tab.isRootAvailable,
        scrollPositions: Map.from(tab.scrollPositions),
        isPinned: tab.isPinned,
        pathHistory: List<String>.from(tab.pathHistory),
        historyIndex: tab.historyIndex,
      );
      _tabs.insert(index + 1, dup);
      _activeTabIndex = index + 1;
      _persistTabs();
      notifyListeners();
    }
  }

  void setActiveTab(int index) {
    if (index >= 0 && index < _tabs.length) {
      if (index != _activeTabIndex) {
        clearSelection();
      }
      _activeTabIndex = index;
      _persistTabs();
      notifyListeners();
    }
  }

  void _persistTabs() {
    final list = _tabs.map((t) => {
      'id': t.id,
      'currentPath': t.currentPath,
      'isPinned': t.isPinned,
    }).toList();
    PreferencesService.saveSavedTabs(list);
  }

  // --- Active Tab Delegations ---
  List<FileItemModel> get currentFiles {
    final items = activeTab.currentFiles;
    if (_categoryFilter.isEmpty) return items;
    return items.where((f) => matchesAnyCategory(_categoryFilter, f)).toList();
  }

  /// 返回某标签在界面上应展示的文件列表：在原始列表基础上套用「按类别过滤」。
  /// 文件夹始终保留以便继续导航，仅对文件按已选类别集合筛选。单/双窗口共用
  /// 同一全局 [_categoryFilter]，因此两个面板都会同步过滤，无需重新加载目录。
  List<FileItemModel> getDisplayFilesForTab(FolderTab tab) {
    final items = tab.currentFiles;
    if (_categoryFilter.isEmpty) return items;
    return items.where((f) => matchesAnyCategory(_categoryFilter, f)).toList();
  }
  String get currentPath => activeTab.currentPath;
  bool get isLoading => activeTab.isLoading;
  bool get isRestrictedMode => activeTab.isRestrictedMode;
  bool get needsPermission => activeTab.needsPermission;
  bool get useRootMode => activeTab.useRootMode;
  bool get useShizukuMode => activeTab.useShizukuMode;
  bool get isRootAvailable => activeTab.isRootAvailable;
  Set<String> get selectedPaths => activeTab.selectedPaths;
  bool get isSelectionMode => selectedPaths.isNotEmpty;

  // 路径栏手动编辑态（跨组件共享，供 home_screen 返回键判断是否停留在浏览页）
  bool _isPathEditing = false;
  bool get isPathEditing => _isPathEditing;
  void setPathEditing(bool value) => _isPathEditing = value;
  void exitPathEditing() => _isPathEditing = false;

  // --- Global Clipboard ---
  final List<String> _clipboardPaths = [];
  bool _isCut = false;
  String? _sourceArchiveForCut;
  List<String>? _internalSourcePathsForCut;

  // Remote Clipboard support
  bool _isRemoteClipboard = false;
  final List<RemoteFileItem> _remoteClipboardItems = [];
  NetworkConnectionModel? _remoteClipboardConnection;

  bool get hasClipboard => _clipboardPaths.isNotEmpty || _isRemoteClipboard;
  List<String> get clipboardPaths => _clipboardPaths;
  bool get isCut => _isCut;
  bool get isRemoteClipboard => _isRemoteClipboard;
  List<RemoteFileItem> get remoteClipboardItems => _remoteClipboardItems;
  NetworkConnectionModel? get remoteClipboardConnection => _remoteClipboardConnection;

  void setClipboard(List<String> paths, {required bool isCut, String? sourceArchive, List<String>? internalSourcePaths}) {
    _clipboardPaths.clear();
    _clipboardPaths.addAll(paths);
    _isRemoteClipboard = false;
    _remoteClipboardItems.clear();
    _remoteClipboardConnection = null;
    _isCut = isCut;
    _sourceArchiveForCut = sourceArchive;
    _internalSourcePathsForCut = internalSourcePaths;
    notifyListeners();
  }

  void setRemoteClipboard(List<RemoteFileItem> items, {required bool isCut, required NetworkConnectionModel connection}) {
    _clipboardPaths.clear();
    _isRemoteClipboard = true;
    _remoteClipboardItems.clear();
    _remoteClipboardItems.addAll(items);
    _remoteClipboardConnection = connection;
    _isCut = isCut;
    _sourceArchiveForCut = null;
    _internalSourcePathsForCut = null;
    notifyListeners();
  }

  void clearClipboard() {
    _clipboardPaths.clear();
    _isRemoteClipboard = false;
    _remoteClipboardItems.clear();
    _remoteClipboardConnection = null;
    _isCut = false;
    _sourceArchiveForCut = null;
    _internalSourcePathsForCut = null;
    notifyListeners();
  }

  /// 剪切本地文件到远程后，刷新来源本地目录。
  /// 精确匹配 currentPath == 源目录 的本地 tab 并重新加载，使被移动的
  /// 原文件立即从来源浏览器消失（无需手动刷新）。
  Future<void> refreshLocalSourceAfterCut(List<String> sourcePaths) async {
    if (sourcePaths.isEmpty) return;
    // 剪切完成后即时裁剪媒体列表，防止分类页残留已移走的文件
    MediaProvider.instance?.pruneDeletedMediaPaths(sourcePaths);
    final sourceDir = p.dirname(sourcePaths.first);
    for (int i = 0; i < _tabs.length; i++) {
      if (!_tabs[i].isRemote && _tabs[i].currentPath == sourceDir) {
        try {
          await loadDirectoryForTab(i, sourceDir, showLoading: false, clearCache: true);
        } catch (e) {
          debugPrint('Failed to refresh local source tab: $e');
        }
        break;
      }
    }
  }

  final Set<String> _highlightedPaths = {};
  Set<String> get highlightedPaths => _highlightedPaths;

  final Set<String> _forceHighlightedPaths = {};
  Set<String> get forceHighlightedPaths => _forceHighlightedPaths;

  bool _shouldScrollToHighlight = false;
  bool get shouldScrollToHighlight => _shouldScrollToHighlight;

  void resetScrollToHighlight() {
    _shouldScrollToHighlight = false;
  }

  void setHighlightedPaths(List<String> paths) {
    _highlightedPaths.clear();
    _highlightedPaths.addAll(paths);
    _forceHighlightedPaths.clear();
    _forceHighlightedPaths.addAll(paths);
    _shouldScrollToHighlight = true;
  }

  Future<void> showFileInLocation(String filePath) async {
    final parentPath = p.dirname(filePath);
    await loadDirectory(parentPath);
    _highlightedPaths.clear();
    _highlightedPaths.add(filePath);
    _forceHighlightedPaths.clear();
    _forceHighlightedPaths.add(filePath);
    _shouldScrollToHighlight = true;
    notifyListeners();
    Timer(const Duration(milliseconds: 2000), () {
      _forceHighlightedPaths.remove(filePath);
      if (_highlightedPaths.remove(filePath)) {
        notifyListeners();
      }
    });
  }

  /// 打开 remote:// 文件所在连接的远程标签页，并定位到其父目录（分类页「查看文件所在位置」用）。
  Future<void> showRemoteFileInLocation(String remotePathStr) async {
    final parts = parseRemotePathParts(remotePathStr);
    if (parts == null) return;
    final conn = NetworkConnectionsService.getConnections()
        .where((c) => c.id == parts[0])
        .firstOrNull;
    if (conn == null) return;
    final client = createRemoteClient(conn);
    try {
      await client.connect();
    } catch (e) {
      debugPrint('[ZenFile] showRemoteFileInLocation connect error: $e');
      return;
    }
    await openRemoteTab(client, conn);
    final parent = _remoteDirname(parts[1]);
    if (parent.isNotEmpty && parent != parts[1]) {
      try {
        await loadDirectory(parent);
      } catch (_) {}
    }
    _highlightedPaths.clear();
    _highlightedPaths.add(remotePathStr);
    _forceHighlightedPaths.clear();
    _forceHighlightedPaths.add(remotePathStr);
    _shouldScrollToHighlight = true;
    notifyListeners();
    Timer(const Duration(milliseconds: 2000), () {
      _forceHighlightedPaths.remove(remotePathStr);
      if (_highlightedPaths.remove(remotePathStr)) {
        notifyListeners();
      }
    });
  }

  String _rootPath = '';
  String get rootPath => _rootPath;

  // 路径历史栈已迁移到 FolderTab，双窗口模式下每个 pane 拥有独立的历史，
  // 避免左/右窗口路径混在一起导致“在远程窗口按返回跳到本地路径”的问题。

  /// 是否可“返回上一级目录”。基于当前 tab 的路径判断（而非历史栈）：
  /// - 远程 tab：任意层级（含根）都可返回——子目录回上一级，根目录回本地。
  /// - 本地 tab：只要不在本地存储根目录即可返回上一级。
  bool get canGoBack {
    final tab = activeTab;
    if (tab.isRemote) return true;
    return tab.currentPath.isNotEmpty && tab.currentPath != _rootPath;
  }

  bool get canGoForward {
    final tab = activeTab;
    return tab.historyIndex >= 0 && tab.historyIndex < tab.pathHistory.length - 1;
  }

  /// 返回 [path] 的父目录（不改变原对象）。'/' 与空串保持自身；本地路径不会
  /// 越过存储根目录。
  String _parentOf(String path) {
    if (path.isEmpty || path == '/') return path;
    final parent = p.dirname(path);
    final resolved = parent.isEmpty ? '/' : parent;
    // 本地路径越过根目录（如 /storage/emulated/0 → /storage/emulated）时回到自身
    if (!activeTab.isRemote && resolved.length < _rootPath.length) return path;
    return resolved;
  }

  /// 返回当前 tab 的“根路径”：远程取连接自身的 rootPath（如 SMB/WebDAV 共享
  /// 根可能非 '/'），兜底为 '/'；本地为存储根目录。
  String get _activeTabRoot {
    final tab = activeTab;
    if (!tab.isRemote) return _rootPath;
    final rp = tab.remoteConnection?.rootPath;
    return (rp != null && rp.isNotEmpty) ? rp : '/';
  }

  /// 高亮刚刚离开的目录，2 秒后自动取消高亮（返回/导航时的视觉反馈）。
  void _highlightExited(String exited) {
    if (exited.isEmpty) return;
    _highlightedPaths.add(exited);
    notifyListeners();
    Timer(const Duration(milliseconds: 2000), () {
      if (_highlightedPaths.remove(exited)) notifyListeners();
    });
  }

  void _pushPathToHistory(String path) {
    final tab = activeTab;
    // 如果当前不是历史栈的最后一个，截断后面的历史（用户从中间位置导航到新路径）
    if (tab.historyIndex < tab.pathHistory.length - 1) {
      tab.pathHistory.removeRange(tab.historyIndex + 1, tab.pathHistory.length);
    }
    // 如果路径与当前最后一个不同，才添加
    if (tab.pathHistory.isEmpty || tab.pathHistory.last != path) {
      tab.pathHistory.add(path);
      tab.historyIndex = tab.pathHistory.length - 1;
    }
  }

  /// 返回上一级目录（基于路径，而非历史栈）。
  ///
  /// 返回语义（与用户预期一致）：
  /// - 远程子目录 → 返回远程父目录；
  /// - 远程根目录 → 切换到本地浏览 tab（远程根→本地根）；
  /// - 本地子目录 → 返回本地父目录；
  /// - 本地根目录 → 返回 false（交由上层切到分类页）。
  ///
  /// 返回值：true 表示已执行一次导航；false 表示已无更上层可返回。
  Future<bool> goBack() async {
    final tab = activeTab;
    if (tab.isRemote) {
      // 远程根目录：切换到本地浏览 tab，而非弹出路由跳到分类页。
      if (tab.currentPath == _activeTabRoot) {
        return _switchToLocalTabOrRoot();
      }
      final parent = _parentOf(tab.currentPath);
      if (parent != tab.currentPath) {
        final exited = tab.currentPath;
        await loadDirectory(parent, showLoading: false, recordHistory: false);
        _highlightExited(exited);
        return true;
      }
      // 已是最顶层（如 '/'），回退到本地浏览。
      return _switchToLocalTabOrRoot();
    } else {
      // 本地根目录：无更上层，返回 false 交由上层切分类页。
      if (tab.currentPath.isEmpty || tab.currentPath == _rootPath) {
        return false;
      }
      final parent = _parentOf(tab.currentPath);
      if (parent == tab.currentPath) return false;
      final exited = tab.currentPath;

      await loadDirectory(parent, showLoading: false, recordHistory: false);
      _highlightExited(exited);
      return true;
    }
  }

  /// 在远程根目录按返回时，切换到本地浏览 tab（定位到其当前目录），实现
  /// “远程根目录返回 → 本地根目录”的导航体验。若没有本地 tab 则返回 false
  /// （交由上层按原逻辑处理，例如切换到分类页）。
  Future<bool> _switchToLocalTabOrRoot() async {
    for (int i = 0; i < _tabs.length; i++) {
      if (!_tabs[i].isRemote) {
        _activeTabIndex = i;
        notifyListeners();
        return true;
      }
    }
    return false;
  }

  Future<bool> goForward() async {
    if (!canGoForward) return false;
    final tab = activeTab;
    // 前进历史索引
    tab.historyIndex++;
    final nextPath = tab.pathHistory[tab.historyIndex];
    await loadDirectory(nextPath, showLoading: false, recordHistory: false);
    notifyListeners();
    return true;
  }

  void saveScrollOffset(String path, double offset) {
    if (path.isNotEmpty) {
      activeTab.scrollPositions[path] = offset;
    }
  }

  double getSavedScrollOffset(String path) {
    return activeTab.scrollPositions[path] ?? 0.0;
  }

  List<StorageVolume> _storageVolumes = [];
  List<StorageVolume> get storageVolumes => _storageVolumes;

  int _totalStorageBytes = 0;
  int _usedStorageBytes = 0;
  int _rawTotalStorageBytes = 0;
  int _rawUsedStorageBytes = 0;

  int get totalStorageBytes => _totalStorageBytes;
  int get usedStorageBytes => _usedStorageBytes;
  int get rawTotalStorageBytes => _rawTotalStorageBytes;
  int get rawUsedStorageBytes => _rawUsedStorageBytes;
  double get storageUsedPercentage => _totalStorageBytes == 0 ? 0.0 : (_usedStorageBytes / _totalStorageBytes);
  double get rawStorageUsedPercentage => _rawTotalStorageBytes == 0 ? 0.0 : (_rawUsedStorageBytes / _rawTotalStorageBytes);

  Future<void> updateStorageSpace() async {
    final space = await RootShizukuService.getStorageSpace();
    if (space != null) {
      final rawTotal = space['totalBytes'] ?? 0;
      final rawUsed = space['usedBytes'] ?? 0;

      _rawTotalStorageBytes = rawTotal;
      _rawUsedStorageBytes = rawUsed;

      if (rawTotal > 0) {
        final double rawTotalGb = rawTotal / (1024 * 1024 * 1024);
        double marketingGb = rawTotalGb;

        if (rawTotalGb <= 8) {
          marketingGb = 8.0;
        } else if (rawTotalGb <= 16) {
          marketingGb = 16.0;
        } else if (rawTotalGb <= 32) {
          marketingGb = 32.0;
        } else if (rawTotalGb <= 64) {
          marketingGb = 64.0;
        } else if (rawTotalGb <= 128) {
          marketingGb = 128.0;
        } else if (rawTotalGb <= 256) {
          marketingGb = 256.0;
        } else if (rawTotalGb <= 512) {
          marketingGb = 512.0;
        } else if (rawTotalGb <= 1024) {
          marketingGb = 1024.0;
        } else if (rawTotalGb <= 2048) {
          marketingGb = 2048.0;
        } else {
          marketingGb = rawTotalGb.roundToDouble();
        }

        final int marketingTotalBytes = (marketingGb * 1024 * 1024 * 1024).toInt();
        final int systemReservedBytes = marketingTotalBytes - rawTotal;
        final int adjustedUsedBytes = rawUsed + systemReservedBytes;

        _totalStorageBytes = marketingTotalBytes;
        _usedStorageBytes = adjustedUsedBytes;
        PreferencesService.saveCachedTotalStorage(marketingTotalBytes);
        PreferencesService.saveCachedUsedStorage(adjustedUsedBytes);
      } else {
        _totalStorageBytes = 0;
        _usedStorageBytes = 0;
      }

      // Query/calculate space for all volumes
      for (var vol in _storageVolumes) {
        if (vol.isInternal) {
          vol.totalBytes = _rawTotalStorageBytes;
          vol.usedBytes = _rawUsedStorageBytes;
        } else {
          final volSpace = await RootShizukuService.getStorageSpace(path: vol.path);
          if (volSpace != null) {
            vol.totalBytes = volSpace['totalBytes'] ?? 0;
            vol.usedBytes = volSpace['usedBytes'] ?? 0;
          }
        }
      }

      notifyListeners();
    }
  }

  void setRootPath(String path) {
    // 选择本地根目录即意味着退出远程浏览模式，避免本地路径被误路由到远程客户端
    // （曾导致“返回根目录显示空目录，重启才恢复”的问题）。
    if (_tabs.isNotEmpty) exitRemoteMode();
    _rootPath = path;
    if (_tabs.isNotEmpty) {
      activeTab.currentPath = path;
    }
    notifyListeners();
  }

  /// 获取当前激活 pane 的首页目录路径；null 表示未设置
  String? get homeDirectory {
    return _enableSplitScreen
        ? PreferencesService.getHomeDirectoryRight()
        : PreferencesService.getHomeDirectoryLeft();
  }

  /// 获取指定 pane 的首页目录路径
  String? getHomeDirectoryForPane(int tabIndex) {
    return tabIndex == 0
        ? PreferencesService.getHomeDirectoryLeft()
        : PreferencesService.getHomeDirectoryRight();
  }

  /// 将当前激活 pane 当前目录设为首页
  Future<void> setCurrentAsHome() async {
    final path = currentPath;
    if (_activeTabIndex == 0) {
      await PreferencesService.saveHomeDirectoryLeft(path);
    } else {
      await PreferencesService.saveHomeDirectoryRight(path);
    }
    notifyListeners();
  }

  /// 将指定路径设为当前激活 pane 的首页
  /// 如果传入的是文件路径，则使用其父目录
  Future<void> setAsHomeDirectory(String path) async {
    String dirPath = path;
    try {
      if (File(path).existsSync()) {
        dirPath = p.dirname(path);
      }
    } catch (_) {}
    if (_activeTabIndex == 0) {
      await PreferencesService.saveHomeDirectoryLeft(dirPath);
    } else {
      await PreferencesService.saveHomeDirectoryRight(dirPath);
    }
    notifyListeners();
  }

  /// 跳转到当前激活 pane 的首页目录
  Future<void> goToHome() async {
    final home = homeDirectory;
    if (home != null) {
      await loadDirectory(home);
    }
  }

  Future<void> _detectStorageVolumes() async {
    final volumes = <StorageVolume>[];
    if (Platform.isAndroid) {
      volumes.add(StorageVolume(name: 'Internal Storage', path: '/storage/emulated/0', isInternal: true));

      try {
        final extDirs = await getExternalStorageDirectories();
        if (extDirs != null) {
          for (final dir in extDirs) {
            final path = dir.path;
            if (path.contains('/Android/')) {
              final root = path.substring(0, path.indexOf('/Android/'));
              if (root != '/storage/emulated/0' && root != '/storage/emulated') {
                final name = root.contains('-') ? 'SD Card (${p.basename(root)})' : 'SD Card / USB';
                if (!volumes.any((v) => v.path == root)) {
                  volumes.add(StorageVolume(name: name, path: root, isInternal: false));
                }
              }
            }
          }
        }
      } catch (_) {}

      try {
        final storageDir = Directory('/storage');
        if (storageDir.existsSync()) {
          final list = storageDir.listSync();
          for (final entity in list) {
            if (entity is Directory) {
              final base = p.basename(entity.path);
              if (base != 'emulated' && base != 'self' && base != 'enterprise') {
                if (!volumes.any((v) => v.path == entity.path)) {
                  final name = base.contains('-') ? 'SD Card ($base)' : 'SD Card / USB ($base)';
                  volumes.add(StorageVolume(name: name, path: entity.path, isInternal: false));
                }
              }
            }
          }
        }
      } catch (_) {}
    } else {
      final dir = await getApplicationDocumentsDirectory();
      volumes.add(StorageVolume(name: '文档', path: dir.path, isInternal: true));
    }
    _storageVolumes = volumes;
    await updateStorageSpace();
  }

  Future<void> init() async {
    // 清除应用数据后权限状态可能不一致：若缺少“所有文件管理”权限，
    // 主动请求一次（与首次安装行为一致），避免后续 loadDirectory 因无权限访问而失败。
    if (Platform.isAndroid) {
      try {
        if (!await Permission.manageExternalStorage.isGranted) {
          final status = await Permission.manageExternalStorage.request();
          if (!status.isGranted) {
            debugPrint('[ZenFile] init: 存储权限未授予，目录加载可能受限');
          }
        }
      } catch (e) {
        debugPrint('[ZenFile] init 请求存储权限失败: $e');
      }
    }

    String initialPath = '/';
    if (Platform.isAndroid) {
      initialPath = '/storage/emulated/0';
      if (!Directory(initialPath).existsSync()) {
        final dir = await getExternalStorageDirectory();
        initialPath = dir?.path ?? '/';
      }
      _rootPath = initialPath;
    } else {
      final dir = await getApplicationDocumentsDirectory();
      initialPath = dir.path;
      _rootPath = initialPath;
    }

    try {
    final homeLeft = PreferencesService.getHomeDirectoryLeft();
    final homeRight = PreferencesService.getHomeDirectoryRight();

    final savedTabsData = PreferencesService.getSavedTabs();
    if (savedTabsData.isNotEmpty) {
      final allTabs = savedTabsData.map((data) {
        return FolderTab(
          id: data['id']?.toString() ?? DateTime.now().millisecondsSinceEpoch.toString(),
          currentPath: data['currentPath']?.toString() ?? initialPath,
          isPinned: data['isPinned'] ?? false,
        );
      }).toList();

      if (_rememberLastFolder) {
        _tabs = allTabs;
      } else {
        _tabs = allTabs.where((t) => t.isPinned).toList();
      }

      if (_tabs.isEmpty) {
        _tabs = [
          FolderTab(
            id: DateTime.now().millisecondsSinceEpoch.toString(),
            currentPath: initialPath,
          )
        ];
      }

      if (homeLeft != null && homeLeft.isNotEmpty) {
        if (_tabs.isNotEmpty) {
          _tabs[0] = FolderTab(
            id: _tabs[0].id,
            currentPath: homeLeft,
            isPinned: _tabs[0].isPinned,
          );
        } else {
          _tabs = [FolderTab(id: DateTime.now().millisecondsSinceEpoch.toString(), currentPath: homeLeft)];
        }
      }

      if (_enableSplitScreen) {
        if (_tabs.length < 2) {
          final rightPath = (homeRight != null && homeRight.isNotEmpty) ? homeRight : initialPath;
          _tabs.add(FolderTab(
            id: (DateTime.now().millisecondsSinceEpoch + _tabs.length).toString(),
            currentPath: rightPath,
          ));
        } else if (homeRight != null && homeRight.isNotEmpty) {
          _tabs[1] = FolderTab(
            id: _tabs[1].id,
            currentPath: homeRight,
            isPinned: _tabs[1].isPinned,
          );
        }
      }
      _activeTabIndex = 0;
    } else {
      final leftPath = (homeLeft != null && homeLeft.isNotEmpty) ? homeLeft : initialPath;
      _tabs = [
        FolderTab(
          id: DateTime.now().millisecondsSinceEpoch.toString(),
          currentPath: leftPath,
        )
      ];
      if (_enableSplitScreen) {
        final rightPath = (homeRight != null && homeRight.isNotEmpty) ? homeRight : initialPath;
        _tabs.add(FolderTab(
          id: (DateTime.now().millisecondsSinceEpoch + 1).toString(),
          currentPath: rightPath,
        ));
      }
      _activeTabIndex = 0;
    }

    await _detectStorageVolumes();
    final path0 = _tabs.isNotEmpty ? _tabs[0].currentPath : (homeLeft ?? initialPath);
    // 清除应用数据后权限状态可能不一致（系统显示已授权但实际被拒），
    // 直接 loadDirectory 会抛异常导致闪退。这里做保护：加载失败仅记录，不崩溃。
    try {
      await loadDirectory(path0, showLoading: false);
    } catch (e) {
      debugPrint('[ZenFile] init loadDirectory 失败 (path=$path0): $e');
    }
    if (_enableSplitScreen) {
      final path1 = _tabs.length > 1 ? _tabs[1].currentPath : (homeRight ?? initialPath);
      try {
        await loadDirectoryForTab(1, path1, showLoading: false);
      } catch (e) {
        debugPrint('[ZenFile] init loadDirectoryForTab 失败 (path=$path1): $e');
      }
    }
    } catch (e) {
      // 清除应用数据后各类偏好/存储状态可能不一致，任何异常都绝不让启动闪退：
      // 退化为单个本地 tab，由 loadDirectory 的逐次保护保证后续可用。
      debugPrint('[ZenFile] init 恢复 tab 异常，使用默认本地 tab: $e');
      _tabs = [FolderTab(id: DateTime.now().millisecondsSinceEpoch.toString(), currentPath: initialPath)];
      _activeTabIndex = 0;
    }
  }

  bool isRestrictedPath(String path) {
    // Collapse double slashes to prevent bypasses, e.g. //data -> /data
    String normalized = path.replaceAll(RegExp(r'/+'), '/');
    if (path.startsWith('/') && !normalized.startsWith('/')) {
      normalized = '/$normalized';
    }

    // Normalize /sdcard and /mnt/sdcard to /storage/emulated/0
    if (normalized.startsWith('/sdcard')) {
      normalized = normalized.replaceFirst('/sdcard', '/storage/emulated/0');
    } else if (normalized.startsWith('/mnt/sdcard')) {
      normalized = normalized.replaceFirst('/mnt/sdcard', '/storage/emulated/0');
    }

    final lower = normalized.toLowerCase();
    if (lower.contains('/android/data') || lower.contains('/android/obb')) {
      return true;
    }
    // Only /data (excluding /data/media) is strictly restricted by default
    if (normalized == '/data' || (normalized.startsWith('/data/') && !normalized.startsWith('/data/media'))) {
      return true;
    }
    return false;
  }

  Future<void> enableRootMode() async {
    activeTab.useRootMode = true;
    activeTab.useShizukuMode = false;
    activeTab.needsPermission = false;
    notifyListeners();
    await loadDirectory(currentPath, showLoading: true);
  }

  Future<void> enableShizukuMode() async {
    final granted = await RootShizukuService.requestShizukuPermission();
    if (granted) {
      activeTab.useShizukuMode = true;
      activeTab.useRootMode = false;
      activeTab.needsPermission = false;
      notifyListeners();
      await loadDirectory(currentPath, showLoading: true);
    }
  }

  /// 退出当前激活 tab 的远程浏览模式，复位为本地浏览。
  /// 当显式选择本地存储卷/根目录时调用，避免本地路径被误路由到远程客户端，
  /// 导致 loadDirectory 进入远程分支返回空列表（即“返回根目录显示空目录”问题）。
  void exitRemoteMode() {
    final tab = activeTab;
    if (!tab.isRemote) return;
    try {
      tab.remoteClient?.disconnect();
    } catch (_) {}
    tab.remoteClient = null;
    tab.remoteConnection = null;
    tab.isRemote = false;
    notifyListeners();
  }

  /// 判断给定路径是否属于本地存储卷（而非远程路径）。
  /// 用于在远程 tab 中导航到本地路径时自动退出远程模式。
  bool _isPathOnLocalStorage(String path) {
    final normalized = path.replaceAll(RegExp(r'/+'), '/');
    if (normalized == '/storage/emulated/0' || normalized.startsWith('/storage/emulated/0/')) return true;
    for (final volume in _storageVolumes) {
      final volPath = volume.path.replaceAll(RegExp(r'/+'), '/');
      if (normalized == volPath || normalized.startsWith('$volPath/')) return true;
    }
    return false;
  }

  Future<void> loadDirectory(String path, {bool showLoading = true, bool clearCache = false, bool recordHistory = true, bool forceRefresh = false}) async {
    // ── Remote → Local transition guard ──
    // 当当前 tab 处于远程模式，但请求的路径明显是本地存储路径时（例如从共
    // 享的历史栈退回到本地根目录），自动退出远程模式，避免远程客户端用本地
    // 路径请求返回空列表。
    if (activeTab.isRemote && activeTab.remoteClient != null && _isPathOnLocalStorage(path)) {
      // 传输（含取消后）过程中的重载不应把远程 Tab 翻转为本地，否则会出现
      // “正在浏览远程服务器却莫名变成本地浏览页”的现象。传输结束后再允许翻转。
      if (_isPasting) {
        debugPrint('[ZenFile] loadDirectory 跳过远程→本地翻转（传输中）: $path');
        notifyListeners();
        return;
      }
      final client = activeTab.remoteClient;
      activeTab.remoteClient = null;
      activeTab.remoteConnection = null;
      activeTab.isRemote = false;
      if (client != null) {
        unawaited(client.disconnect().catchError((_) {}));
      }
      notifyListeners();
      // 继续走下方本地分支
    }

    // ── Remote branch ──
    if (activeTab.isRemote && activeTab.remoteClient != null) {
      // 若当前 tab/path 正处于上传后最终化等待中，抑制可见目录刷新。
      // 这样即使手动下拉刷新 / 页面重入等入口调用 loadDirectory，也不会把 openlist
      // 本机储存的 staging 中间态暴露给用户。最终化完成后 scheduleRemoteRefreshAfterUpload
      // 会主动揭示一次。
      if (_pendingFinalizePaths[_activeTabIndex]?.contains(path) == true) {
        debugPrint('[ZenFile] loadDirectory suppressed for pending finalize: tab=$_activeTabIndex path=$path');
        return;
      }
      if (showLoading) {
        activeTab.isLoading = true;
        notifyListeners();
      }
      // 记录新路径到历史栈（用于前进/后退导航）
      if (recordHistory && path.isNotEmpty) {
        _pushPathToHistory(path);
      }
      try {
        activeTab.currentPath = path;
        final remoteItems = await activeTab.remoteClient!.listDirectory(path, forceRefresh: forceRefresh);
        remoteItems.sort((a, b) {
          if (a.isDirectory && !b.isDirectory) return -1;
          if (!a.isDirectory && b.isDirectory) return 1;
          return a.name.toLowerCase().compareTo(b.name.toLowerCase());
        });
        activeTab.currentFiles = remoteItems
            .map((r) => FileItemModel.fromRemoteFileItem(r))
            .toList();
        // 应用置顶逻辑（与本地目录一致）
        final remoteFolders = activeTab.currentFiles.where((e) => e.isDirectory).toList();
        final remoteFiles = activeTab.currentFiles.where((e) => !e.isDirectory).toList();
        _sortList(remoteFolders, path);
        _sortList(remoteFiles, path);
        activeTab.currentFiles = [...remoteFolders, ...remoteFiles];
      } catch (e) {
        debugPrint('Error loading remote directory: $e');
        // 修复A（问题1）：取消/网络抖动/服务端临时错误不应清空已显示的远程目录，
        // 保留上次成功的列表，避免目录瞬间变空（用户可下拉重试）。isLoading 已在
        // 下方统一置 false 并 notifyListeners()，这里不再 currentFiles = []。
      }
      activeTab.isLoading = false;
      _persistTabs();
      notifyListeners();
      return;
    }

    // Normalize legacy sdcard paths to canonical /storage/emulated/0
    String resolvedPath = path.replaceAll(RegExp(r'/+'), '/');
    if (resolvedPath.startsWith('/sdcard')) {
      resolvedPath = resolvedPath.replaceFirst('/sdcard', '/storage/emulated/0');
    } else if (resolvedPath.startsWith('/mnt/sdcard')) {
      resolvedPath = resolvedPath.replaceFirst('/mnt/sdcard', '/storage/emulated/0');
    }
    path = resolvedPath;

    if (clearCache) {
      clearFolderItemCountsCache();
    }
    if (currentPath != path) {
      _highlightedPaths.clear();
    }
    // 记录新路径到历史栈（用于前进/后退导航）
    if (recordHistory && path.isNotEmpty) {
      _pushPathToHistory(path);
    }
    if (_storageVolumes.isEmpty) {
      _detectStorageVolumes();
    }

    if (showLoading) {
      activeTab.isLoading = true;
      notifyListeners();
    }

    activeTab.isRestrictedMode = isRestrictedPath(path);

    if (activeTab.isRestrictedMode) {
      final status = await RootShizukuService.checkStatus();
      activeTab.isRootAvailable = status.isRootAvailable;
      // Shizuku 已授权时优先于 Root：Shizuku 授权是用户明确行为，比 root 检测可靠。
      // 修复 useRootMode 粘性 Bug：原逻辑 BRANCH A 条件为
      // isRootAvailable && (useRootMode || !isShizukuAvailable)，首次进入受限路径时
      // 若 Shizuku 未运行 + root 误判 → useRootMode=true → su 失败 → 空。之后即使
      // Shizuku 已授权，useRootMode 卡 true 永远走 root 失败，需导航到非受限路径才能
      // 重置。调换优先级后，Shizuku 已授权即走 Shizuku，不受 useRootMode 粘性影响。
      if (status.isShizukuAvailable && status.shizukuPermissionGranted) {
        activeTab.useShizukuMode = true;
        activeTab.useRootMode = false;
        activeTab.needsPermission = false;
      } else if (status.isRootAvailable) {
        activeTab.useRootMode = true;
        activeTab.useShizukuMode = false;
        activeTab.needsPermission = false;
      } else {
        activeTab.needsPermission = true;
        activeTab.currentPath = path;
        activeTab.currentFiles = [];
        activeTab.isLoading = false;
        notifyListeners();
        return;
      }

      try {
        activeTab.currentPath = path;
        final items = await RootShizukuService.listFiles(path, useRoot: activeTab.useRootMode, showHiddenFiles: _showHiddenFiles);
        final folders = items.where((e) => e.isDirectory).toList();
        final files = items.where((e) => !e.isDirectory).toList();

        final filteredFiles = _filterType == FileFilterType.all
            ? files
            : files.where((e) => _matchesFilter(e.path)).toList();
        final filteredFolders = (_filterType != FileFilterType.all && _hideFoldersInFilter) ? <FileItemModel>[] : folders;

        _sortList(filteredFolders, path);
        _sortList(filteredFiles, path);
        activeTab.currentFiles = [...filteredFolders, ...filteredFiles];
      } catch (e) {
        debugPrint('Error loading restricted directory: $e');
        activeTab.currentFiles = [];
      }
      activeTab.isLoading = false;
      notifyListeners();
      return;
    }

    activeTab.needsPermission = false;
    activeTab.useRootMode = false;
    activeTab.useShizukuMode = false;

    try {
      final dir = Directory(path);
      if (await dir.exists()) {
        activeTab.currentPath = path;
        final entities = await dir.list().toList();
        
        final folders = <FileItemModel>[];
        final files = <FileItemModel>[];

        final items = await Future.wait(entities.map((e) => FileItemModel.fromEntityAsync(e)));

        for (var item in items) {
          if (!_showHiddenFiles && item.isHidden) {
            continue;
          }
          if (item.isDirectory) {
            folders.add(item);
          } else {
            files.add(item);
          }
        }

        final filteredFiles = _filterType == FileFilterType.all
            ? files
            : files.where((e) => _matchesFilter(e.path)).toList();
        final filteredFolders = (_filterType != FileFilterType.all && _hideFoldersInFilter) ? <FileItemModel>[] : folders;

        _sortList(filteredFolders, path);
        _sortList(filteredFiles, path);

        activeTab.currentFiles = [...filteredFolders, ...filteredFiles];
      }
    } catch (e) {
      debugPrint('Error loading directory: $e. Fallback to restricted mode.');
      // Auto fallback to restricted mode
      activeTab.isRestrictedMode = true;
      final status = await RootShizukuService.checkStatus();
      activeTab.isRootAvailable = status.isRootAvailable;
      // 同主分支：Shizuku 已授权优先于 Root，避免 useRootMode 粘性 Bug。
      if (status.isShizukuAvailable && status.shizukuPermissionGranted) {
        activeTab.useShizukuMode = true;
        activeTab.useRootMode = false;
        activeTab.needsPermission = false;
      } else if (status.isRootAvailable) {
        activeTab.useRootMode = true;
        activeTab.useShizukuMode = false;
        activeTab.needsPermission = false;
      } else {
        activeTab.needsPermission = true;
        activeTab.currentPath = path;
        activeTab.currentFiles = [];
        activeTab.isLoading = false;
        notifyListeners();
        return;
      }

      try {
        activeTab.currentPath = path;
        final items = await RootShizukuService.listFiles(path, useRoot: activeTab.useRootMode, showHiddenFiles: _showHiddenFiles);
        final folders = items.where((e) => e.isDirectory).toList();
        final files = items.where((e) => !e.isDirectory).toList();

        final filteredFiles = _filterType == FileFilterType.all
            ? files
            : files.where((e) => _matchesFilter(e.path)).toList();
        final filteredFolders = (_filterType != FileFilterType.all && _hideFoldersInFilter) ? <FileItemModel>[] : folders;

        _sortList(filteredFolders, path);
        _sortList(filteredFiles, path);
        activeTab.currentFiles = [...filteredFolders, ...filteredFiles];
      } catch (err) {
        debugPrint('Error loading restricted directory fallback: $err');
        activeTab.currentFiles = [];
      }
    }

    activeTab.isLoading = false;
    _persistTabs();
    notifyListeners();
  }

  void toggleSelection(String path) {
    if (selectedPaths.contains(path)) {
      selectedPaths.remove(path);
    } else {
      selectedPaths.add(path);
    }
    notifyListeners();
  }

  void selectAll() {
    selectedPaths.clear();
    selectedPaths.addAll(currentFiles.map((f) => f.path));
    notifyListeners();
  }

  void clearSelection() {
    selectedPaths.clear();
    notifyListeners();
  }

  Future<void> togglePinPath(String path) async {
    await PinService.togglePin(path);
    final folders = currentFiles.where((e) => e.isDirectory).toList();
    final files = currentFiles.where((e) => !e.isDirectory).toList();
    _sortList(folders, currentPath);
    _sortList(files, currentPath);
    activeTab.currentFiles = [...folders, ...files];
    notifyListeners();
  }

  void refreshDirectoryView() {
    final folders = currentFiles.where((e) => e.isDirectory).toList();
    final files = currentFiles.where((e) => !e.isDirectory).toList();
    _sortList(folders, currentPath);
    _sortList(files, currentPath);
    activeTab.currentFiles = [...folders, ...files];
    notifyListeners();
  }

  /// 上传完成后在后台异步轮询刷新远程目录，直到服务端完成临时文件重命名。
  ///
  /// 部分 NAS（如飞牛）在 STOR 期间把真实数据写入 file-<随机> 临时文件，
  /// 关闭数据连接后才重命名/清理，过程可能持续数秒甚至更久。此前的“单次
  /// 刷新”和“uploadFile 内部同步等待”都会导致 UI 卡顿——前者来不及(服务端
  /// 还没重命名），后者阻塞 uploadFile 返回使进度弹窗卡在 100%。
  ///
  /// 这里改为：在 finally 之后的**异步任务**里，每 ~600ms 刷新一次目录，直到
  /// 目录里不再出现 file-<随机> 临时文件（说明服务端已最终化）或达到上限。
  /// 该任务不 await、不阻塞上传流程与进度弹窗，UI 全程可响应。
  ///
  /// **关键**：刷新必须用 [loadDirectoryForTab] 直接针对“目标远程 tab”进行，
  /// 绝对不能调用 [loadDirectory]（它操作的是全局活跃面板 activeTab）。否则
  /// 后台轮询每 600ms 都会去刷新 activeTab——一旦用户切到本地面板，轮询会把
  /// 本地 tab 的 currentPath 写成远程路径、并可能触发远程→本地翻转，导致地址
  /// 栏“始终显示本地路径”且状态被持久化（重启后才恢复）。
  /// 等待 FTP 服务端完成上传最终化（把 file-<随机> 临时文件重命名为目标文件）。
  ///
  /// 上传时客户端把数据写完 socket 后，服务端往往还在刷盘/重命名，此时若立即
  /// 收起进度条，用户会看到“进度 100% 但文件还没出现”。本方法循环轮询直到目标
  /// 文件出现或超时（约 15 秒），让进度条在服务端真正落盘后才消失。
  ///
  /// 非 FTP 客户端无需此等待（其上传为原子操作），直接返回。
  /// 后台异步等待 FTP 服务端把 `file-<随机>` 临时文件最终化为目标文件。
  ///
  /// **不再阻塞调用方**：之前这里是同步等待（最多 45s），导致进度条卡在 100%
  /// 不消失。现在改为后台 fire-and-forget，进度条立即消失，UI 可正常交互。
  /// 最终化后的目录刷新由 [scheduleRemoteRefreshAfterUpload] 的轮询负责。
  void _awaitUploadFinalized(RemoteClient client, String dir, String name, int expectedSize) {
    if (client is! FtpRemoteClient) return;
    unawaited(Future(() async {
      const maxAttempts = 90;
      for (int i = 0; i < maxAttempts; i++) {
        if (_isOperationCancelled) return;
        await Future.delayed(const Duration(milliseconds: 500));
        bool ok = false;
        try {
          ok = await client.finalizeUpload(dir, name, expectedSize);
        } catch (_) {}
        if (ok) return;
      }
    }));
  }

  /// 上传完成后后台等待服务端“最终化”（临时文件→目标文件），**期间不刷新可见
  /// 目录**，最终化完成后再一次性揭示目录。
  ///
  /// **核心修复（问题2 / 问题3）**：旧逻辑每 2s 调用 [loadDirectoryForTab] 刷新**可见
  /// 目录**，会把 openlist 本机储存的 staging 状态（临时文件 + 目标文件 0KB 逐步增长）
  /// 暴露给用户；对 FTP 而言每次刷新都是同一 `_ftpConnect` 单连接的 CWD+LIST，与用户
  /// 手动刷新并发时会竞争同一连接导致 CWD 错乱甚至闪退。
  ///
  /// 新逻辑：轮询 `client.finalizeUpload()`（后台 LIST，不碰可见目录）判断服务端是否
  /// 已最终化；**只有**最终化完成时才做一次 [loadDirectoryForTab] 揭示。这样用户在整个
  /// 上传→落盘期间看到的始终是「旧目录」（或干脆完成后的最终目录），绝不会看到中间态，
  /// 也消除了 FTP 单连接高频 LIST 的并发竞争。
  void scheduleRemoteRefreshAfterUpload(String dir, int? targetTabIndex, {String targetName = '', int expectedSize = 0}) {
    debugPrint('scheduleRemoteRefreshAfterUpload: start for $dir target=$targetTabIndex expectedSize=$expectedSize');
    unawaited(Future(() async {
      const maxAttempts = 120;
      const interval = Duration(milliseconds: 2000);
      int? idx;
      RemoteClient? client;

      void markPending(bool pending) {
        if (idx == null) return;
        if (pending) {
          (_pendingFinalizePaths[idx] ??= {}).add(dir);
        } else {
          _pendingFinalizePaths[idx]?.remove(dir);
          if (_pendingFinalizePaths[idx]?.isEmpty == true) {
            _pendingFinalizePaths.remove(idx);
          }
        }
      }

      try {
        for (int i = 0; i < maxAttempts; i++) {
          // 正在新粘贴 / 操作已取消 → 停止轮询，避免与新的上传/加载相互干扰
          if (_isPasting || _isOperationCancelled) {
            debugPrint('scheduleRemoteRefreshAfterUpload: stop (pasting=$_isPasting, cancelled=$_isOperationCancelled)');
            return;
          }
          // 定位目标远程 tab：优先使用上传目标 tabIndex，否则按 currentPath 匹配
          idx = (targetTabIndex != null &&
                  targetTabIndex >= 0 &&
                  targetTabIndex < _tabs.length &&
                  _tabs[targetTabIndex].isRemote)
              ? targetTabIndex
              : null;
          if (idx == null) {
            for (int t = 0; t < _tabs.length; t++) {
              if (_tabs[t].isRemote && _tabs[t].currentPath == dir) {
                idx = t;
                break;
              }
            }
          }
          if (idx == null) {
            debugPrint('scheduleRemoteRefreshAfterUpload: no remote tab for $dir, stop');
            return;
          }
          final tab = _tabs[idx];
          client = tab.remoteClient;
          if (client == null) {
            debugPrint('scheduleRemoteRefreshAfterUpload: no client for tab$idx, stop');
            return;
          }
          // 标记该 tab/path 正在最终化，抑制同路径的可见目录刷新（补充防御）。
          markPending(true);

          // 首轮立即检测（不延迟），让 WebDAV/SMB/网盘等原子上传立刻完成最终化，
          // 避免额外的揭示延迟；FTP/SFTP 在 openlist 上一般尚未最终化，会进入等待。
          if (i > 0) {
            await Future.delayed(interval);
          }
          try {
            // 只问服务端“是否已最终化”，**不刷新可见目录**（关键修复点）。
            final ok = await client.finalizeUpload(dir, targetName, expectedSize);
            if (ok) {
              // 最终化完成：先取消 pending 标记，再一次性刷新可见目录（否则
              // loadDirectory 的 pending 防御会把这次必要的揭示也跳过）。
              markPending(false);
              try {
                await loadDirectoryForTab(idx, dir, showLoading: false, clearCache: true, forceRefresh: true);
              } catch (e) {
                debugPrint('scheduleRemoteRefreshAfterUpload: final refresh error $e');
              }
              notifyListeners();
              debugPrint('scheduleRemoteRefreshAfterUpload: finalized after $i attempts, stop');
              return;
            }
            debugPrint('scheduleRemoteRefreshAfterUpload: attempt $i not finalized yet');
          } catch (e) {
            // finalizeUpload 内部 LIST 失败（网络抖动/服务器忙）属正常，继续下一轮
            debugPrint('scheduleRemoteRefreshAfterUpload: finalizeUpload error $e');
          }
        }
      // 达到最大轮询次数仍未最终化：做一次尽力刷新，避免 UI 停留在旧状态。
      // 刷新前取消 pending 标记，否则会被 loadDirectory 的防御跳过。
      markPending(false);
      if (idx != null && client != null) {
        try {
          await loadDirectoryForTab(idx, dir, showLoading: false, clearCache: true, forceRefresh: true);
          notifyListeners();
        } catch (_) {}
      }
      debugPrint('scheduleRemoteRefreshAfterUpload: maxAttempts reached');
      } finally {
        markPending(false);
      }
    }));
  }

  void copyFile(String path) {
    if (currIsRemote) {
      if (currentFiles.isEmpty) {
        setClipboard([path], isCut: false);
        return;
      }
      final item = currentFiles.firstWhere(
        (f) => f.path == path,
        orElse: () => currentFiles.first,
      );
      if (item.remoteSource != null && activeTab.remoteConnection != null) {
        setRemoteClipboard([item.remoteSource!], isCut: false, connection: activeTab.remoteConnection!);
        return;
      }
    }
    setClipboard([path], isCut: false);
  }

  void cutFile(String path) {
    if (currIsRemote) {
      if (currentFiles.isEmpty) {
        setClipboard([path], isCut: true);
        return;
      }
      final item = currentFiles.firstWhere(
        (f) => f.path == path,
        orElse: () => currentFiles.first,
      );
      if (item.remoteSource != null && activeTab.remoteConnection != null) {
        setRemoteClipboard([item.remoteSource!], isCut: true, connection: activeTab.remoteConnection!);
        return;
      }
    }
    setClipboard([path], isCut: true);
  }

  void copySelected() {
    if (selectedPaths.isEmpty) return;
    if (currIsRemote) {
      final items = currentFiles
          .where((f) => selectedPaths.contains(f.path))
          .where((f) => f.remoteSource != null)
          .map((f) => f.remoteSource!)
          .toList();
      if (items.isNotEmpty && activeTab.remoteConnection != null) {
        setRemoteClipboard(items, isCut: false, connection: activeTab.remoteConnection!);
        selectedPaths.clear();
        notifyListeners();
        return;
      }
    }
    setClipboard(selectedPaths.toList(), isCut: false);
    selectedPaths.clear();
    notifyListeners();
  }

  void cutSelected() {
    if (selectedPaths.isEmpty) return;
    if (currIsRemote) {
      final items = currentFiles
          .where((f) => selectedPaths.contains(f.path))
          .where((f) => f.remoteSource != null)
          .map((f) => f.remoteSource!)
          .toList();
      if (items.isNotEmpty && activeTab.remoteConnection != null) {
        setRemoteClipboard(items, isCut: true, connection: activeTab.remoteConnection!);
        selectedPaths.clear();
        notifyListeners();
        return;
      }
    }
    setClipboard(selectedPaths.toList(), isCut: true);
    selectedPaths.clear();
    notifyListeners();
  }

  Future<void> deleteSelected() async {
    if (selectedPaths.isEmpty) return;
    // 快照待删路径：finally 中会清空 selectedPaths，需提前保留用于媒体列表裁剪。
    final deletedPaths = List<String>.from(selectedPaths);

    activeTab.isLoading = true;
    notifyListeners();

    try {
      if (activeTab.isRemote && activeTab.remoteClient != null) {
        final client = activeTab.remoteClient!;
        for (final path in selectedPaths) {
          final file = currentFiles.cast<FileItemModel?>().firstWhere(
            (f) => f?.path == path,
            orElse: () => null,
          );
          if (file == null) {
            debugPrint('Cannot delete $path: file not found in current list');
            continue;
          }
          final remotePath = file.remoteSource?.path ?? file.path;
          await client.delete(remotePath, file.isDirectory);
        }
      } else if (RecycleBinService.isEnabled()) {
        for (final path in selectedPaths) {
          await RecycleBinService.moveToTrash(path, useRoot: useRootMode);
        }
      } else {
        for (final path in selectedPaths) {
          if (isRestrictedPath(path)) {
            await RootShizukuService.deleteItem(path, useRoot: useRootMode);
          } else {
            final type = FileSystemEntity.typeSync(path);
            if (type == FileSystemEntityType.directory) {
              await Directory(path).delete(recursive: true);
            } else {
              await File(path).delete();
            }
          }
        }
      }
    } catch (e) {
      debugPrint('Error deleting selected files: $e');
      rethrow;
    } finally {
      // 确保删除失败时也清理 loading 状态，避免 UI 卡死
      selectedPaths.clear();
      activeTab.isLoading = false;
      notifyListeners();
    }

    await loadDirectory(currentPath, showLoading: false, clearCache: true);
    // 本地多选删除后即时通知媒体列表裁剪，避免分类页残留空白图标。
    if (!activeTab.isRemote && activeTab.remoteClient == null) {
      MediaProvider.instance?.pruneDeletedMediaPaths(deletedPaths);
    }
  }

  Future<void> pasteFile(BuildContext context, {bool clearAfterPaste = true}) async {
    await _pasteFileToTab(context, _activeTabIndex, clearAfterPaste: clearAfterPaste);
  }

  Future<void> pasteFileToTab(BuildContext context, int targetTabIndex, {bool clearAfterPaste = true}) async {
    await _pasteFileToTab(context, targetTabIndex, clearAfterPaste: clearAfterPaste);
  }

  /// 显示文件传输进度对话框。设置一个初始 progress 值，避免对话框在首帧因
  /// progressNotifier 为 null 而立即自关闭；传输结束时各 _paste 方法的
  /// finally 会将 progressNotifier 置为 null，对话框随即自动关闭。
  void _showTransferProgressDialog(BuildContext context) {
    progressNotifier.value = FileOperationProgress(
      totalFiles: 1,
      currentFileIndex: 0,
      currentFileName: 'Preparing...',
      percentage: 0.0,
      speedMBs: 0.0,
      eta: Duration.zero,
      totalBytes: 1,
      bytesProcessed: 0,
    );
    unawaited(FileOperationProgressDialog.show(context, this));
  }

  Future<void> _pasteFileToTab(BuildContext context, int targetTabIndex, {bool clearAfterPaste = true}) async {
    if (_clipboardPaths.isEmpty && !_isRemoteClipboard) return;
    if (targetTabIndex < 0 || targetTabIndex >= _tabs.length) return;

    final oldIndex = _activeTabIndex;
    _activeTabIndex = targetTabIndex;

    // 标记本次粘贴的目标 tab 是否为远程，用于最后决定是否恢复 activeTab。
    // 远程上传/粘贴完成后，保持 active 在目标远程 tab，避免双窗口模式下
    // 顶部地址栏显示成源（本地）pane 的路径。
    final bool targetIsRemote = _tabs[targetTabIndex].isRemote;

    // 在清除剪贴板之前保存源目录路径，用于后续刷新
    final String? savedSourcePath = _isCut && _clipboardPaths.isNotEmpty
        ? _clipboardPaths.first
        : null;

    try {
      if (_isRemoteClipboard) {
        // 远程剪贴板粘贴到远程目录：先下载到本地临时目录，再上传到目标远程
        if (currIsRemote && activeTab.remoteClient != null) {
          _showTransferProgressDialog(context);
          await _pasteRemoteToRemote(context, clearAfterPaste);
        } else {
          _showTransferProgressDialog(context);
          await _pasteFromRemoteToLocal(context, clearAfterPaste);
        }
        return;
      }

      // 本地剪贴板粘贴到远程目录
      if (currIsRemote && activeTab.remoteClient != null) {
        _showTransferProgressDialog(context);
        await _pasteLocalToRemote(context, clearAfterPaste);
        return;
      }

      progressNotifier.backgroundMode = false;
      _isOperationCancelled = false;
      _isPasting = true;
      activeTab.isLoading = true;
      _showTransferProgressDialog(context);
      notifyListeners();

    // 仅当「目标本身受限」或「源是非 Android/data|obb 的系统受限路径（如
    // /data）」时才走整项 shell copy/move 的简单链路。源为 Android/{data,obb}
    // （FUSE 受限）且目标为普通目录时必须落入下方精细链路：这里若提前拦截，
    // 会使用导航到普通目录后已被重置为 false 的 useRootMode（走 Shizuku 读
    // 底层路径无权限，或直接异常），导致「复制到本地其它目录报错」，且下方
    // 的受限复制精细修复（statItem 判型 + 逐文件 cp + 进度）永远执行不到。
    final legacyRestrictedPaste = isRestrictedPath(currentPath) ||
        _clipboardPaths.any((sp) => isRestrictedPath(sp) && !_isRestrictedAndroidPath(sp));
    if (legacyRestrictedPaste) {
      // root 优先解析执行模式（不依赖导航后可能被重置的 tab 模式）
      final legacyUseRoot = await _resolveBypassMode() ?? activeTab.useRootMode;
      try {
        for (final srcPath in _clipboardPaths) {
          final name = p.basename(srcPath);
          final destPath = p.join(currentPath, name);
          if (_isCut) {
            await RootShizukuService.moveItem(srcPath, destPath, useRoot: legacyUseRoot);
          } else {
            await RootShizukuService.copyItem(srcPath, destPath, useRoot: legacyUseRoot);
          }
        }
        
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(_isCut ? L10n.of(context).msg05d3c93c : L10n.of(context).msgb7e3a1c2),
              behavior: SnackBarBehavior.floating,
            ),
          );
        }
      } catch (e) {
        debugPrint('Error pasting inside restricted directory: $e');
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(L10n.of(context).e1(e)),
              backgroundColor: Colors.redAccent,
              behavior: SnackBarBehavior.floating,
            ),
          );
        }
      } finally {
        // 清理进度对话框和状态
        progressNotifier.value = null;
        _isPasting = false;
      }
      if (clearAfterPaste) {
        clearClipboard();
      }
      activeTab.isLoading = false;
      await loadDirectory(currentPath, showLoading: false, clearCache: true);
      notifyListeners();
      return;
    }

    try {
      // 1. Calculate total size and gather all files
      int totalBytes = 0;
      final List<Map<String, dynamic>> itemsToProcess = [];

      // 受限源（其它应用的 Android/data|obb 文件）Dart IO 不可见，
      // 改走 Root/Shizuku shell（与浏览层一致的 /data/media/0 底层路径绕过）
      bool? bypassUseRoot;
      if (_clipboardPaths.any(_needsBypass)) {
        bypassUseRoot = await _resolveBypassMode();
        if (bypassUseRoot == null) {
          throw Exception('Restricted source requires ROOT or Shizuku');
        }
      }

      for (final srcPath in _clipboardPaths) {
        var type = FileSystemEntity.typeSync(srcPath);
        final isSameFolder = p.dirname(srcPath) == currentPath;

        if (isSameFolder && _isCut) {
          if (context.mounted) {
            await FileActionDialogs.showWarningDialog(
              context,
              title: L10n.of(context).msga45bac47,
              content: 'Cannot cut and paste a file into the same folder.',
            );
          }
          clearClipboard();
          activeTab.isLoading = false;
          notifyListeners();
          return;
        }

        // 受限源：typeSync 被 FUSE 拦截返回 notFound，经 shell stat 判定
        FileItemModel? restrictedStat;
        if (type == FileSystemEntityType.notFound &&
            bypassUseRoot != null && _needsBypass(srcPath)) {
          restrictedStat = await RootShizukuService.statItem(srcPath, useRoot: bypassUseRoot);
          if (restrictedStat == null) continue; // 源已被外部删除
          type = restrictedStat.isDirectory
              ? FileSystemEntityType.directory
              : FileSystemEntityType.file;
        }

        if (type == FileSystemEntityType.file) {
          final file = File(srcPath);
          final size = restrictedStat?.size ?? file.lengthSync();
          totalBytes += size;

          String destPath = p.join(currentPath, p.basename(srcPath));
          if (isSameFolder && !_isCut) {
            destPath = _getCopyUniquePath(destPath, false);
          }

          itemsToProcess.add({
            'source': file,
            'destPath': destPath,
            'size': size,
            'isDir': false,
            if (restrictedStat != null) 'restricted': true,
          });
        } else if (type == FileSystemEntityType.directory) {
          final dir = Directory(srcPath);

          String topDestPath = p.join(currentPath, p.basename(srcPath));
          if (isSameFolder && !_isCut) {
            topDestPath = _getCopyUniquePath(topDestPath, true);
          }

          itemsToProcess.add({
            'source': dir,
            'destPath': topDestPath,
            'size': 0,
            'isDir': true,
            if (restrictedStat != null) 'restricted': true,
          });

          if (restrictedStat != null) {
            // 受限目录：listSync 被 FUSE 拦截，经 shell listFiles 递归收集
            await _collectRestrictedDir(
              srcPath, topDestPath, itemsToProcess, bypassUseRoot!,
              () => totalBytes, (v) => totalBytes = v,
            );
          } else {
            try {
              final entities = dir.listSync(recursive: true, followLinks: false);
              for (final entity in entities) {
                final relPath = p.relative(entity.path, from: srcPath);
                final destPath = p.join(topDestPath, relPath);

                if (entity is Directory) {
                  itemsToProcess.add({
                    'source': entity,
                    'destPath': destPath,
                    'size': 0,
                    'isDir': true,
                  });
                } else if (entity is File) {
                  final size = entity.lengthSync();
                  totalBytes += size;
                  itemsToProcess.add({
                    'source': entity,
                    'destPath': destPath,
                    'size': size,
                    'isDir': false,
                  });
                }
              }
            } catch (_) {}
          }
        }
      }

      // 2. Initialize progress tracking variables
      int bytesProcessed = 0;
      final stopwatch = Stopwatch()..start();
      final totalFiles = itemsToProcess.length;

      progressNotifier.value = FileOperationProgress(
        totalFiles: totalFiles,
        currentFileIndex: 1,
        currentFileName: 'Starting...',
        percentage: 0.0,
        speedMBs: 0.0,
        eta: Duration.zero,
        totalBytes: totalBytes > 0 ? totalBytes : 1,
        bytesProcessed: 0,
      );

      ConflictResult? cachedResolution;
      final Set<String> skippedPaths = {};
      final List<String> finalTopLevelDestPaths = [];

      // 3. Process items sequentially
      for (int i = 0; i < itemsToProcess.length; i++) {
        if (_isOperationCancelled) {
          throw Exception('Cancelled');
        }

        final item = itemsToProcess[i];
        final source = item['source'];
        String destPath = item['destPath'];
        final int size = item['size'];
        final bool isDir = item['isDir'];

        final fileName = p.basename(source.path);

        // Check if this item is within a skipped directory tree
        bool isSkipped = false;
        for (final skipped in skippedPaths) {
          if (p.isWithin(skipped, destPath) || destPath == skipped) {
            isSkipped = true;
            break;
          }
        }

        if (isSkipped) {
          if (!isDir) {
            totalBytes -= size;
          }
          continue;
        }

        String finalDestPath = destPath;
        bool shouldProcess = true;

        // Check if there is a conflict
        final destExists = FileSystemEntity.typeSync(destPath) != FileSystemEntityType.notFound;
        if (destExists) {
          ConflictDialogResponse? response;
          ConflictResult? resolution = cachedResolution;

          if (resolution == null) {
            if (context.mounted) {
              response = await ConflictDialog.show(
                context,
                fileName: fileName,
                sourceFile: File(source.path),
                destFile: File(destPath),
              );

              if (response != null) {
                resolution = response.result;
                if (response.applyToAll &&
                    (resolution == ConflictResult.overwrite ||
                     resolution == ConflictResult.keepBoth ||
                     resolution == ConflictResult.skip)) {
                  cachedResolution = resolution;
                }
              } else {
                resolution = ConflictResult.cancel;
              }
            } else {
              resolution = ConflictResult.cancel;
            }
          }

          if (resolution == ConflictResult.cancel) {
            throw Exception('Cancelled');
          } else if (resolution == ConflictResult.skip) {
            shouldProcess = false;
            skippedPaths.add(destPath);
          } else if (resolution == ConflictResult.keepBoth) {
            finalDestPath = _getUniquePath(destPath, isDir);
            if (isDir) {
              _updateSubsequentDestPaths(itemsToProcess, i + 1, destPath, finalDestPath);
            }
          } else if (resolution == ConflictResult.rename) {
            final customName = response?.customName ?? fileName;
            finalDestPath = p.join(p.dirname(destPath), customName);
            finalDestPath = _getUniquePath(finalDestPath, isDir);
            if (isDir) {
              _updateSubsequentDestPaths(itemsToProcess, i + 1, destPath, finalDestPath);
            }
          } else if (resolution == ConflictResult.overwrite) {
            // Overwrite: we do nothing to the path. If it's a file, it will overwrite it.
            // If it's a folder, it will merge it.
          }
        }

        if (!shouldProcess) {
          if (!isDir) {
            totalBytes -= size;
          }
          continue;
        }

        final isTopLevel = _clipboardPaths.contains(source.path);
        if (isTopLevel) {
          finalTopLevelDestPaths.add(finalDestPath);
        }

        double basePercent = totalBytes > 0 ? (bytesProcessed / totalBytes) : (i / totalFiles);
        progressNotifier.value = FileOperationProgress(
          totalFiles: totalFiles,
          currentFileIndex: i + 1,
          currentFileName: fileName,
          percentage: basePercent,
          speedMBs: stopwatch.elapsedMilliseconds > 0 
              ? (bytesProcessed / (1024 * 1024)) / (stopwatch.elapsed.inMilliseconds / 1000.0)
              : 0.0,
          eta: Duration.zero,
          totalBytes: totalBytes > 0 ? totalBytes : 1,
          bytesProcessed: bytesProcessed,
        );

        // 受限源（其它应用的 Android/data|obb）：Dart IO 读写均被 FUSE 拦截，
        // 复制/删除改走 Root/Shizuku shell（cp 一条命令，无逐块进度）
        if (item['restricted'] == true && bypassUseRoot != null) {
          final srcPath = source.path as String;
          if (isDir) {
            final destDir = Directory(finalDestPath);
            if (!destDir.existsSync()) {
              await destDir.create(recursive: true);
            }
          } else {
            final parentDir = Directory(p.dirname(finalDestPath));
            if (!parentDir.existsSync()) {
              await parentDir.create(recursive: true);
            }
            await RootShizukuService.copyItem(srcPath, finalDestPath, useRoot: bypassUseRoot);
            bytesProcessed += size;
            final elapsedSeconds = stopwatch.elapsed.inMilliseconds / 1000.0;
            final speed = elapsedSeconds > 0 ? (bytesProcessed / (1024 * 1024)) / elapsedSeconds : 0.0;
            progressNotifier.value = FileOperationProgress(
              totalFiles: totalFiles,
              currentFileIndex: i + 1,
              currentFileName: fileName,
              percentage: totalBytes > 0 ? (bytesProcessed / totalBytes) : (i / totalFiles),
              speedMBs: speed,
              eta: Duration.zero,
              totalBytes: totalBytes > 0 ? totalBytes : 1,
              bytesProcessed: bytesProcessed,
            );
          }
          if (_isCut) {
            await RootShizukuService.deleteItem(srcPath, useRoot: bypassUseRoot);
          }
          continue;
        }

        if (isDir) {
          final destDir = Directory(finalDestPath);
          if (!destDir.existsSync()) {
            await destDir.create(recursive: true);
          }
        } else {
          final parentDir = Directory(p.dirname(finalDestPath));
          if (!parentDir.existsSync()) {
            await parentDir.create(recursive: true);
          }

          final srcFile = source as File;
          final destFile = File(finalDestPath);

          if (_isCut) {
            try {
              if (destFile.existsSync()) {
                await destFile.delete();
              }
              await srcFile.rename(finalDestPath);
              bytesProcessed += size;
            } catch (_) {
              await _copyFileWithProgress(
                srcFile,
                destFile,
                onChunkCopied: (chunkSize) {
                  bytesProcessed += chunkSize;
                  final elapsedSeconds = stopwatch.elapsed.inMilliseconds / 1000.0;
                  final speed = elapsedSeconds > 0 ? (bytesProcessed / (1024 * 1024)) / elapsedSeconds : 0.0;
                  final remainingBytes = totalBytes - bytesProcessed;
                  final etaSeconds = speed > 0 ? (remainingBytes / (1024 * 1024)) / speed : 0.0;

                  progressNotifier.value = FileOperationProgress(
                    totalFiles: totalFiles,
                    currentFileIndex: i + 1,
                    currentFileName: fileName,
                    percentage: totalBytes > 0 ? (bytesProcessed / totalBytes) : (i / totalFiles),
                    speedMBs: speed,
                    eta: Duration(seconds: etaSeconds.round()),
                    totalBytes: totalBytes > 0 ? totalBytes : 1,
                    bytesProcessed: bytesProcessed,
                  );
                },
              );
              // 源文件删除失败不应中断整个剪切流程（避免剪切变复制 + 剪贴板不消失）
              try {
                await srcFile.delete();
              } catch (delErr) {
                debugPrint('Cut source file delete failed (already copied): $delErr');
              }
            }
          } else {
            await _copyFileWithProgress(
              srcFile,
              destFile,
              onChunkCopied: (chunkSize) {
                bytesProcessed += chunkSize;
                final elapsedSeconds = stopwatch.elapsed.inMilliseconds / 1000.0;
                final speed = elapsedSeconds > 0 ? (bytesProcessed / (1024 * 1024)) / elapsedSeconds : 0.0;
                final remainingBytes = totalBytes - bytesProcessed;
                final etaSeconds = speed > 0 ? (remainingBytes / (1024 * 1024)) / speed : 0.0;

                progressNotifier.value = FileOperationProgress(
                  totalFiles: totalFiles,
                  currentFileIndex: i + 1,
                  currentFileName: fileName,
                  percentage: totalBytes > 0 ? (bytesProcessed / totalBytes) : (i / totalFiles),
                  speedMBs: speed,
                  eta: Duration(seconds: etaSeconds.round()),
                  totalBytes: totalBytes > 0 ? totalBytes : 1,
                  bytesProcessed: bytesProcessed,
                );
              },
            );
          }
        }
      }

      if (_isCut) {
        // 源目录删除采用容错策略：单个失败不应中断整个流程，
        // 否则会导致剪切变复制且剪贴板不自动消失。
        final cutSourcePaths = List<String>.from(_clipboardPaths);
        for (final srcPath in _clipboardPaths) {
          final type = FileSystemEntity.typeSync(srcPath);
          if (type == FileSystemEntityType.directory) {
            final dir = Directory(srcPath);
            if (dir.existsSync()) {
              try {
                await dir.delete(recursive: true);
              } catch (delErr) {
                debugPrint('Cut source dir delete failed (already copied): $delErr');
              }
            }
          }
        }
        // 剪切完成后即时裁剪媒体列表，防止分类页残留已移走的文件
        MediaProvider.instance?.pruneDeletedMediaPaths(cutSourcePaths);
      }

      if (_isCut && _sourceArchiveForCut != null && _internalSourcePathsForCut != null) {
        try {
          await ArchiveService.deleteItemsFromArchive(
            archivePath: _sourceArchiveForCut!,
            internalPathsToDelete: _internalSourcePathsForCut!,
          );
        } catch (delErr) {
          debugPrint('Cut archive item delete failed: $delErr');
        }
      }

      if (clearAfterPaste) {
        clearClipboard();
      }
      
      _highlightedPaths.clear();
      _highlightedPaths.addAll(finalTopLevelDestPaths);
      _shouldScrollToHighlight = true;

      Timer(const Duration(milliseconds: 2000), () {
        bool changed = false;
        for (final path in finalTopLevelDestPaths) {
          if (_highlightedPaths.remove(path)) {
            changed = true;
          }
        }
        if (changed) {
          notifyListeners();
        }
      });

    } catch (e) {
      debugPrint('Error pasting file: $e');
    } finally {
      progressNotifier.value = null;
      activeTab.isLoading = false;
      _isPasting = false;
      // 稍等片刻确保文件系统已更新
      await Future.delayed(const Duration(milliseconds: 500));
      await loadDirectory(currentPath, showLoading: false, clearCache: true);
      // 如果是剪切操作，刷新本地源目录
      final sourceDir = savedSourcePath != null ? p.dirname(savedSourcePath) : null;
      if (sourceDir != null && sourceDir != currentPath) {
        for (int i = 0; i < _tabs.length; i++) {
          if (!_tabs[i].isRemote && _tabs[i].currentPath == sourceDir) {
            await loadDirectoryForTab(i, sourceDir, showLoading: false, clearCache: true);
            break;
          }
        }
      }
      notifyListeners();
    }
  } finally {
    // 远程粘贴/上传完成后，保持 activeTab 在目标远程 pane，使顶部地址栏
    // 与当前查看的远程窗口保持一致。本地粘贴则恢复原来的 activeTab。
    if (!targetIsRemote) {
      _activeTabIndex = oldIndex;
    }
  }
}

  Future<void> _pasteFromRemoteToLocal(BuildContext context, bool clearAfterPaste) async {
    final conn = _remoteClipboardConnection;
    if (conn == null) {
      progressNotifier.value = null;
      return;
    }

    // clearClipboard() 会在 finally 中清空 _isCut/_remoteClipboardItems，故先缓存
    // 剪切来源信息，供结束后刷新源目录使用。
    final bool remoteWasCut = _isCut;
    final NetworkConnectionModel? remoteSourceConn = _remoteClipboardConnection;
    final String remoteSourceDir = _remoteClipboardItems.isNotEmpty
        ? p.dirname(_remoteClipboardItems.first.path)
        : '/';

    RemoteClient? client;
    if (conn.type == 'FTP') {
      client = FtpRemoteClient(host: conn.host, port: conn.port, username: conn.username, password: conn.password);
    } else if (conn.type == 'SFTP') {
      client = SftpRemoteClient(host: conn.host, port: conn.port, username: conn.username, password: conn.password);
    } else if (conn.type == 'WebDav') {
      client = WebDavRemoteClient(
        host: conn.host,
        port: conn.port,
        username: conn.username,
        password: conn.password,
        protocol: conn.protocol,
        rootPath: conn.rootPath,
      );
    } else if (isSmbType(conn.type)) {
      client = LanClient(host: conn.host, port: conn.port, username: conn.username, password: conn.password);
    } else if (conn.type == 'saf') {
      client = SafRemoteClient(rootUri: conn.rootPath);
    }

    if (client == null) {
      _isPasting = false;
      return;
    }

    _activeTransferClient = client;
    // 共享客户端可能残留上次取消的标志，传输前重置（与上传路径保持一致）
    client.resetCancel();
    progressNotifier.backgroundMode = false;
    _isOperationCancelled = false;
    _isPasting = true;
    activeTab.isLoading = true;
    progressNotifier.value = FileOperationProgress(
      totalFiles: _remoteClipboardItems.length,
      currentFileIndex: 1,
      currentFileName: 'Connecting...',
      percentage: 0.0,
      speedMBs: 0.0,
      eta: Duration.zero,
      totalBytes: 1,
      bytesProcessed: 0,
    );
    notifyListeners();

    try {
      await client.connect();
    } catch (e) {
      debugPrint('Failed to connect to remote server for paste: $e');
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('连接远程服务器失败：{e}'),
            backgroundColor: Colors.redAccent,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
      activeTab.isLoading = false;
      _isPasting = false;
      notifyListeners();
      return;
    }

    try {
      final totalTopLevel = _remoteClipboardItems.length;

      // Pre-count total files and estimate total bytes for accurate progress
      int totalFileCount = 0;
      int totalBytesAll = 0;
      int topLevelFileBytesSum = 0;
      int topLevelFileCount = 0;
      int directoryFileCount = 0;
      for (final item in _remoteClipboardItems) {
        if (item.isDirectory) {
          final dirCount = await _countRemoteFiles(client, item.path);
          totalFileCount += dirCount;
          directoryFileCount += dirCount;
        } else {
          totalFileCount += 1;
          topLevelFileBytesSum += item.size;
          topLevelFileCount++;
        }
      }
      // Guard against zero
      if (totalFileCount == 0) totalFileCount = totalTopLevel;

      final int averageFileSize = (topLevelFileCount > 0)
          ? (topLevelFileBytesSum / topLevelFileCount).round()
          : 1024 * 1024;
      totalBytesAll = topLevelFileBytesSum + directoryFileCount * averageFileSize;
      if (totalBytesAll <= 0) totalBytesAll = 1;

      progressNotifier.value = FileOperationProgress(
        totalFiles: totalFileCount,
        currentFileIndex: 0,
        currentFileName: 'Starting...',
        percentage: 0.0,
        speedMBs: 0.0,
        eta: Duration.zero,
        totalBytes: totalBytesAll,
        bytesProcessed: 0,
      );

      final targetPath = currentPath;
      int processedFileCount = 0;
      int bytesDone = 0;
      int previousFilesBytes = 0;
      final stopwatch = Stopwatch()..start();

      for (int i = 0; i < _remoteClipboardItems.length; i++) {
        if (_isOperationCancelled) {
          throw Exception('Cancelled');
        }

        final remoteItem = _remoteClipboardItems[i];
        final destPath = p.join(targetPath, remoteItem.name);

        if (remoteItem.isDirectory) {
          // For folders, track progress per-file inside the directory
          final dirStartFileCount = processedFileCount;
          await _downloadRemoteDirectory(
            client,
            remoteItem.path,
            destPath,
            onFileStart: (fileName) {
              processedFileCount++;
              bytesDone = previousFilesBytes + ((processedFileCount - dirStartFileCount) * averageFileSize).round();
              final elapsedSeconds = stopwatch.elapsed.inMilliseconds / 1000.0;
              final speedMBs = elapsedSeconds > 0 && totalBytesAll > 0
                  ? (bytesDone / (1024 * 1024)) / elapsedSeconds
                  : 0.0;
              final remainingBytes = totalBytesAll - bytesDone;
              final etaSeconds = speedMBs > 0 ? (remainingBytes / (1024 * 1024)) / speedMBs : 0.0;

              progressNotifier.value = FileOperationProgress(
                totalFiles: totalFileCount,
                currentFileIndex: processedFileCount,
                currentFileName: fileName,
                percentage: processedFileCount / totalFileCount,
                speedMBs: speedMBs,
                eta: Duration(seconds: etaSeconds.round()),
                totalBytes: totalBytesAll,
                bytesProcessed: bytesDone,
              );
            },
          );
          final dirFileCount = processedFileCount - dirStartFileCount;
          previousFilesBytes += dirFileCount * averageFileSize;
          bytesDone = previousFilesBytes;
        } else {
          // For single files, show byte-level progress within this file
          final fileSize = remoteItem.size > 0 ? remoteItem.size : averageFileSize;

          bytesDone = previousFilesBytes;
          final elapsedSeconds = stopwatch.elapsed.inMilliseconds / 1000.0;
          final speedMBs = elapsedSeconds > 0 && totalBytesAll > 0
              ? (bytesDone / (1024 * 1024)) / elapsedSeconds
              : 0.0;
          progressNotifier.value = FileOperationProgress(
            totalFiles: totalFileCount,
            currentFileIndex: processedFileCount + 1,
            currentFileName: remoteItem.name,
            percentage: processedFileCount / totalFileCount,
            speedMBs: speedMBs,
            eta: Duration.zero,
            totalBytes: totalBytesAll,
            bytesProcessed: bytesDone,
          );

          await client.downloadFile(remoteItem.path, destPath, (prog) {
            bytesDone = previousFilesBytes + (fileSize * prog).round();
            final elapsedSeconds = stopwatch.elapsed.inMilliseconds / 1000.0;
            final speedMBs = elapsedSeconds > 0 && totalBytesAll > 0
                ? (bytesDone / (1024 * 1024)) / elapsedSeconds
                : 0.0;
            final remainingBytes = totalBytesAll - bytesDone;
            final etaSeconds = speedMBs > 0 ? (remainingBytes / (1024 * 1024)) / speedMBs : 0.0;

            final currentProcessed = processedFileCount + prog;
            progressNotifier.value = FileOperationProgress(
              totalFiles: totalFileCount,
              currentFileIndex: processedFileCount + 1,
              currentFileName: remoteItem.name,
              percentage: currentProcessed / totalFileCount,
              speedMBs: speedMBs,
              eta: Duration(seconds: etaSeconds.round()),
              totalBytes: totalBytesAll,
              bytesProcessed: bytesDone,
            );
          });
          previousFilesBytes += fileSize;
          bytesDone = previousFilesBytes;
          processedFileCount++;
        }

        if (_isCut) {
          try {
            await client.delete(remoteItem.path, remoteItem.isDirectory);
          } catch (e) {
            debugPrint('Failed to delete remote item after cut: $e');
          }
        }
      }
      stopwatch.stop();
    } catch (e) {
      debugPrint('Error pasting from remote: $e');
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(e.toString().contains('Cancelled') ? L10n.of(context).msga45bac47 : L10n.of(context).e1(e)),
            backgroundColor: e.toString().contains('Cancelled') ? null : Colors.redAccent,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } finally {
      _activeTransferClient = null;
      try {
        await client.disconnect();
      } catch (_) {}
      progressNotifier.value = null;
      if (clearAfterPaste) {
        clearClipboard();
      }
      activeTab.isLoading = false;
      await loadDirectory(currentPath, showLoading: false, clearCache: true);
      // 剪切操作：刷新远程源目录。clearClipboard() 已清空 _isCut/_remoteClipboardItems，
      // 故使用前面缓存的 remoteWasCut/remoteSourceConn/remoteSourceDir。
      if (remoteWasCut && remoteSourceConn != null) {
        for (int i = 0; i < _tabs.length; i++) {
          if (_tabs[i].isRemote && _tabs[i].currentPath == remoteSourceDir) {
            try {
              final tabClient = createRemoteClient(_tabs[i].remoteConnection!);
              await tabClient.connect();
              _tabs[i].remoteClient = tabClient;
              await loadDirectoryForTab(i, remoteSourceDir, showLoading: false, clearCache: true);
            } catch (e) {
              debugPrint('Failed to refresh remote source tab: $e');
            }
            break;
          }
        }
        // 广播给全屏 RemoteExplorerScreen（非 tab），使其刷新当前目录，
        // 避免“原文件残留 / 返回后页面丢失”。
        _remoteSourceChangedController.add(RemoteSourceChanged(remoteSourceConn, remoteSourceDir));
      }
      notifyListeners();
    }
  }

  Future<void> _pasteLocalToRemote(BuildContext context, bool clearAfterPaste) async {
    final client = activeTab.remoteClient;
    if (client == null) {
      progressNotifier.value = null;
      return;
    }
    // 记录上传目标 tab 索引：上传目标是当前活跃远程 tab，但传输过程中用户可能
    // 切换到其它面板，故此处先捕获，供结束后精准刷新目标 tab（避免污染活跃面板）。
    final int targetTabIndex = activeTabIndex;

    // clearClipboard() 会在 finally 中清空 _isCut/_clipboardPaths，故先缓存
    // 剪切来源信息，供结束后刷新本地源目录使用。
    final bool localWasCut = _isCut;
    final List<String> localSourcePaths = List<String>.from(_clipboardPaths);

    _activeTransferClient = client;
    // 共享客户端（activeTab.remoteClient）可能残留上次取消的标志，传输前重置
    client.resetCancel();
    progressNotifier.backgroundMode = false;
    _isOperationCancelled = false;
    _isPasting = true;
    activeTab.isLoading = true;
    notifyListeners();

    // 记录最后一个上传文件的信息，供 scheduleRemoteRefreshAfterUpload 主动最终化
    String? lastUploadedName;
    int lastUploadedSize = 0;

    try {
      final totalTopLevel = _clipboardPaths.length;

      // 精确统计总文件数和总字节数（递归遍历目录），替代原先「目录内文件用
      // 平均大小估算」的做法，使进度条分母准确。
      // 使用 compute() 将同步递归遍历移至独立 isolate，避免主线程卡顿。
      final stats = await compute(_countLocalFilesAndBytesIsolate, List<String>.from(_clipboardPaths));
      int totalFileCount = stats[0];
      int totalBytesAll = stats[1];
      // 受限源（其它应用的 Android/data|obb 文件）Dart IO 不可见，
      // isolate 统计为 0；经 shell 补充真实计数，并解析上传可用的绕过模式
      bool? bypassUseRoot;
      if (_clipboardPaths.any(_needsBypass)) {
        bypassUseRoot = await _resolveBypassMode();
        if (bypassUseRoot == null) {
          throw Exception('Restricted source requires ROOT or Shizuku');
        }
        for (final path in _clipboardPaths.where(_needsBypass)) {
          final st = await RootShizukuService.statItem(path, useRoot: bypassUseRoot);
          if (st == null) continue;
          if (st.isDirectory) {
            final r = await _countRestrictedFilesAndBytes(path, bypassUseRoot);
            totalFileCount += r[0];
            totalBytesAll += r[1];
          } else {
            totalFileCount += 1;
            totalBytesAll += st.size;
          }
        }
      }
      if (totalFileCount == 0) totalFileCount = totalTopLevel;
      if (totalBytesAll <= 0) totalBytesAll = 1;

      int processedFileCount = 0;
      int bytesDone = 0;
      int previousFilesBytes = 0;
      // 滑动窗口实时速率：避免累计平均速率在文件间停顿时持续衰减。
      final speedTracker = _TransferSpeedTracker(window: const Duration(seconds: 2));
      // 节流：WebDAV/FTP 的 onProgress 每 64KB 调用一次（千兆下每秒约 16000 次），
      // 若每次都 speedTracker.add 会触发 O(n) 的 _evict，2 秒窗口内累积数万样本
      // 导致 O(n²) 性能下降，拖慢事件循环，进度条和速率卡顿不准。
      // bytesDone/percentage 每次 O(1) 更新，speedTracker.add 限制为每 50ms 一次。
      int pendingSpeedDelta = 0;
      DateTime? lastSpeedUpdate;

      // 统一构造进度通知，保证 percentage / bytesProcessed / speed / eta 一致。
      void emitProgress(String fileName, int currentFileSize, double currentFileProg) {
        final newBytesDone = previousFilesBytes + (currentFileSize * currentFileProg).round();
        if (newBytesDone > bytesDone) {
          pendingSpeedDelta += newBytesDone - bytesDone;
          bytesDone = newBytesDone;
          final now = DateTime.now();
          if (lastSpeedUpdate == null ||
              now.difference(lastSpeedUpdate!) >= const Duration(milliseconds: 50)) {
            speedTracker.add(pendingSpeedDelta);
            pendingSpeedDelta = 0;
            lastSpeedUpdate = now;
          }
        }
        final pct = (bytesDone / totalBytesAll).clamp(0.0, 1.0);
        final speedMBs = speedTracker.currentMBs();
        final remainingBytes = totalBytesAll - bytesDone;
        final etaSeconds = speedMBs > 0 ? (remainingBytes / (1024 * 1024)) / speedMBs : 0.0;
        progressNotifier.value = FileOperationProgress(
          totalFiles: totalFileCount,
          currentFileIndex: processedFileCount + 1,
          currentFileName: fileName,
          percentage: pct,
          speedMBs: speedMBs,
          eta: Duration(seconds: etaSeconds.round()),
          totalBytes: totalBytesAll,
          bytesProcessed: bytesDone,
        );
      }

      ConflictResult? cachedResolution;

      for (int i = 0; i < _clipboardPaths.length; i++) {
        if (_isOperationCancelled) throw Exception('Cancelled');

        final srcPath = _clipboardPaths[i];
        final name = p.basename(srcPath);
        String destPath = _buildRemotePath(currentPath, name);
        var isDir = FileSystemEntity.typeSync(srcPath) == FileSystemEntityType.directory;

        // 受限源：typeSync 不可见，经 shell stat 判定（不存在则跳过）
        if (bypassUseRoot != null && _needsBypass(srcPath)) {
          final st = await RootShizukuService.statItem(srcPath, useRoot: bypassUseRoot);
          if (st == null) continue;
          isDir = st.isDirectory;
        }

        // Check conflict with existing remote files
        final destExists = activeTab.currentFiles.any((f) => f.name == name);
        if (destExists) {
          ConflictResult? resolution = cachedResolution;
          if (resolution == null) {
            if (!context.mounted) throw Exception('Cancelled');
            final response = await ConflictDialog.show(
              context,
              fileName: name,
              sourceFile: File(srcPath),
              destFile: File(''), // remote file, no local path
            );
            if (response == null || response.result == ConflictResult.cancel) {
              throw Exception('Cancelled');
            }
            resolution = response.result;
            if (response.applyToAll &&
                (resolution == ConflictResult.overwrite ||
                 resolution == ConflictResult.keepBoth ||
                 resolution == ConflictResult.skip)) {
              cachedResolution = resolution;
            }
          }
          if (resolution == ConflictResult.skip) {
            continue; // skip this file
          } else if (resolution == ConflictResult.keepBoth) {
            // Generate unique name
            String uniqueName = name;
            int counter = 1;
            while (activeTab.currentFiles.any((f) => f.name == uniqueName)) {
              final baseName = p.basenameWithoutExtension(name);
              final ext = p.extension(name);
              uniqueName = '$baseName ($counter)$ext';
              counter++;
            }
            destPath = _buildRemotePath(currentPath, uniqueName);
          }
          // overwrite: do nothing, keep destPath as is
        }

        if (isDir) {
          await _uploadLocalDirectory(
            client,
            srcPath,
            destPath,
            bypassUseRoot: bypassUseRoot,
            onFileStart: (fileName) {
              processedFileCount++;
            },
            onFileProgress: (fileName, fileSize, prog) {
              emitProgress(fileName, fileSize, prog);
              // 文件完成时，把真实大小累加到 previousFilesBytes，
              // 使下一个文件的 bytesDone 基线正确。
              if (prog >= 1.0) {
                previousFilesBytes += fileSize;
              }
            },
          );
        } else {
          // 受限源：先经 shell cp 暂存到 app 外部缓存（app 可读），
          // 上传暂存文件，完成后清理；大小取 shell stat 结果
          String? stagedPath;
          String uploadSrc = srcPath;
          int fileSize;
          if (bypassUseRoot != null && _needsBypass(srcPath)) {
            final st = await RootShizukuService.statItem(srcPath, useRoot: bypassUseRoot);
            if (st == null) continue;
            fileSize = st.size;
            stagedPath = await _stageRestrictedFile(srcPath, bypassUseRoot);
            uploadSrc = stagedPath;
          } else {
            try {
              fileSize = File(srcPath).lengthSync();
            } catch (_) {
              fileSize = 0;
            }
          }

          emitProgress(name, fileSize, 0.0);

          try {
            await client.uploadFile(uploadSrc, destPath, (prog) {
              emitProgress(name, fileSize, prog);
            });
          } catch (e) {
            // 客户端在 cancel() 后可能直接抛异常（如 FTP socket 关闭），
            // 此时统一按“已取消”处理，确保传输立即停止并提示“操作已取消”
            if (client.isCancelled) throw Exception('Cancelled');
            rethrow;
          } finally {
            if (stagedPath != null) {
              try { File(stagedPath).delete(); } catch (_) {}
            }
          }
          previousFilesBytes += fileSize;
          bytesDone = previousFilesBytes;
          processedFileCount++;
          lastUploadedName = p.basename(destPath);
          lastUploadedSize = fileSize;
        }

        if (_isCut) {
          if (bypassUseRoot != null && _needsBypass(srcPath)) {
            // 受限源：Dart delete 不可用，走 shell rm
            try {
              await RootShizukuService.deleteItem(srcPath, useRoot: bypassUseRoot);
            } catch (e) {
              debugPrint('Failed to delete restricted item after cut: $e');
            }
          } else {
            try {
              final type = FileSystemEntity.typeSync(srcPath);
              if (type == FileSystemEntityType.directory) {
                await Directory(srcPath).delete(recursive: true);
              } else {
                await File(srcPath).delete();
              }
            } catch (e) {
              debugPrint('Failed to delete local item after cut: $e');
            }
          }
        }
      }
      // 上传循环结束后，服务端可能还在把临时文件最终化为目标文件。
      // 最终化检测和目录刷新由 scheduleRemoteRefreshAfterUpload 后台轮询负责，
      // 不再调用 _awaitUploadFinalized（避免与 scheduleRemoteRefreshAfterUpload
      // 同时操作 FTP 连接导致竞争和闪退）。
    } catch (e) {
      debugPrint('Error pasting local to remote: $e');
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(e.toString().contains('Cancelled') ? L10n.of(context).msga45bac47 : L10n.of(context).e1(e)),
            backgroundColor: e.toString().contains('Cancelled') ? null : Colors.redAccent,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } finally {
      _activeTransferClient = null;
      progressNotifier.value = null;
      if (clearAfterPaste) clearClipboard();
      // 注意：**不再**在上传结束后立即刷新目标远程 tab（旧逻辑会立刻 LIST 可见
      // 目录，把 openlist 本机储存的 staging 中间态——临时文件 + 目标文件 0KB 增长——
      // 暴露给用户，见问题2/问题3）。最终化完成后的目录揭示统一交给
      // [scheduleRemoteRefreshAfterUpload]（轮询 finalizeUpload，仅最终化成功后
      // 一次性刷新可见目录），避免用户看到中间态，也消除 FTP 单连接高频 LIST 竞争。
      // 剪切操作：刷新本地源目录。clearClipboard() 已清空 _isCut/_clipboardPaths，
      // 故使用前面缓存的 localWasCut/localSourcePaths。
      if (localWasCut && localSourcePaths.isNotEmpty) {
        await refreshLocalSourceAfterCut(localSourcePaths);
      }
      activeTab.isLoading = false;
      _isPasting = false;
      // 重置取消标志：即使传输被取消，也需要 scheduleRemoteRefreshAfterUpload
      // 执行至少一次刷新，清理目录中残留的临时文件显示。
      _isOperationCancelled = false;
      notifyListeners();
      // 上传后服务端可能延迟清理临时文件，延迟再刷一次以保证 UI 干净。
      // 注意：必须在 _isPasting = false 之后启动，否则后台轮询会因 _isPasting
      // 仍为 true 而立即退出，导致 UI 不自动刷新。
      scheduleRemoteRefreshAfterUpload(
        currentPath,
        targetTabIndex,
        targetName: lastUploadedName ?? '',
        expectedSize: lastUploadedSize,
      );
    }
  }

  Future<void> _pasteRemoteToRemote(BuildContext context, bool clearAfterPaste) async {
    final sourceClient = await _createRemoteClient(_remoteClipboardConnection!);
    final targetClient = activeTab.remoteClient;
    if (sourceClient == null || targetClient == null) {
      progressNotifier.value = null;
      return;
    }
    // 记录上传目标 tab 索引（上传目标是当前活跃远程 tab），供结束后精准刷新。
    final int targetTabIndex = activeTabIndex;

    // clearClipboard() 会在 finally 中清空 _isCut/_remoteClipboardItems，故先缓存
    // 剪切来源信息，供结束后刷新源目录使用。
    final bool r2rWasCut = _isCut;
    final NetworkConnectionModel? r2rConn = _remoteClipboardConnection;
    final String r2rSourceDir = _remoteClipboardItems.isNotEmpty
        ? p.dirname(_remoteClipboardItems.first.path)
        : '/';

    // 同一远程服务器下的剪切：直接 rename 移动，避免先下载到本地再上传。
    // 复制（非剪切）仍走 download+upload；跨服务器剪切也必须实际传输。
    final bool sameServerCut = _isCut &&
        _remoteClipboardConnection != null &&
        activeTab.remoteConnection != null &&
        _isSameRemoteConnection(_remoteClipboardConnection!, activeTab.remoteConnection!);

    progressNotifier.backgroundMode = false;
    _isOperationCancelled = false;
    _isPasting = true;
    activeTab.isLoading = true;
    notifyListeners();

    final tempDir = Directory('/storage/emulated/0/ZenFile/.temp_${DateTime.now().millisecondsSinceEpoch}');
    if (!tempDir.existsSync()) tempDir.createSync(recursive: true);

    // 记录最后一个上传文件的信息，供 scheduleRemoteRefreshAfterUpload 主动最终化
    String? lastUploadedName;
    int lastUploadedSize = 0;

    try {
      await sourceClient.connect();
      final totalTopLevel = _remoteClipboardItems.length;

      // 精确统计总文件数和总字节数（递归遍历远程目录），替代原先「目录内文件
      // 用平均大小估算」的做法。远程→远程需要下载+上传，总字节数 ×2。
      int totalFileCount = 0;
      int totalBytesAll = 0;
      if (sameServerCut) {
        // 同服务器移动是服务端元数据操作，不实际传输字节，进度按文件数即可。
        totalFileCount = totalTopLevel;
        totalBytesAll = 1;
      } else {
        for (final item in _remoteClipboardItems) {
          if (item.isDirectory) {
            final r = await _countRemoteFilesAndBytes(sourceClient, item.path);
            totalFileCount += r.fileCount;
            totalBytesAll += r.totalBytes;
          } else {
            totalFileCount += 1;
            totalBytesAll += item.size;
          }
        }
        if (totalFileCount == 0) totalFileCount = totalTopLevel;
        totalBytesAll *= 2; // 下载 + 上传
        if (totalBytesAll <= 0) totalBytesAll = 1;
      }

      int processedFileCount = 0;
      int bytesDone = 0;
      int previousFilesBytes = 0;
      ConflictResult? cachedResolution;
      // 滑动窗口实时速率：避免累计平均速率在文件间停顿时持续衰减。
      final speedTracker = _TransferSpeedTracker(window: const Duration(seconds: 2));
      // 节流：同 _pasteLocalToRemote，避免高频 onProgress 导致 O(n²) 性能问题。
      int pendingSpeedDelta = 0;
      DateTime? lastSpeedUpdate;

      // 统一构造进度通知，保证 percentage / bytesProcessed / speed / eta 一致。
      // 远程→远程总字节数 = 真实字节数 ×2（下载+上传），previousFilesBytes
      // 在下载完成和上传完成时分别累加 fileSize，使 bytesDone 连续递增。
      void emitProgress(String fileName, int currentFileSize, double currentFileProg) {
        final newBytesDone = previousFilesBytes + (currentFileSize * currentFileProg).round();
        if (newBytesDone > bytesDone) {
          pendingSpeedDelta += newBytesDone - bytesDone;
          bytesDone = newBytesDone;
          final now = DateTime.now();
          if (lastSpeedUpdate == null ||
              now.difference(lastSpeedUpdate!) >= const Duration(milliseconds: 50)) {
            speedTracker.add(pendingSpeedDelta);
            pendingSpeedDelta = 0;
            lastSpeedUpdate = now;
          }
        }
        final pct = (bytesDone / totalBytesAll).clamp(0.0, 1.0);
        final speedMBs = speedTracker.currentMBs();
        final remainingBytes = totalBytesAll - bytesDone;
        final etaSeconds = speedMBs > 0 ? (remainingBytes / (1024 * 1024)) / speedMBs : 0.0;
        progressNotifier.value = FileOperationProgress(
          totalFiles: totalFileCount,
          currentFileIndex: processedFileCount + 1,
          currentFileName: fileName,
          percentage: pct,
          speedMBs: speedMBs,
          eta: Duration(seconds: etaSeconds.round()),
          totalBytes: totalBytesAll,
          bytesProcessed: bytesDone,
        );
      }

      // 同服务器移动用文件数进度（元数据操作无实际字节传输，无速率）。
      void emitMoveProgress(String name, int index, int total) {
        final pct = total > 0 ? (index / total).clamp(0.0, 1.0) : 1.0;
        progressNotifier.value = FileOperationProgress(
          totalFiles: total,
          currentFileIndex: index,
          currentFileName: name,
          percentage: pct,
          speedMBs: 0.0,
          eta: Duration.zero,
          totalBytes: total,
          bytesProcessed: index,
        );
      }

      for (int i = 0; i < _remoteClipboardItems.length; i++) {
        if (_isOperationCancelled) throw Exception('Cancelled');

        final remoteItem = _remoteClipboardItems[i];
        final tempPath = p.join(tempDir.path, remoteItem.name);
        String destPath = _buildRemotePath(currentPath, remoteItem.name);

        // Check conflict with existing remote files
        final destExists = activeTab.currentFiles.any((f) => f.name == remoteItem.name);
        ConflictResult? resolution = cachedResolution;
        if (destExists) {
          if (resolution == null) {
            if (!context.mounted) throw Exception('Cancelled');
            final response = await ConflictDialog.show(
              context,
              fileName: remoteItem.name,
              sourceFile: File(''), // remote file
              destFile: File(''), // remote file
            );
            if (response == null || response.result == ConflictResult.cancel) {
              throw Exception('Cancelled');
            }
            resolution = response.result;
            if (response.applyToAll &&
                (resolution == ConflictResult.overwrite ||
                 resolution == ConflictResult.keepBoth ||
                 resolution == ConflictResult.skip)) {
              cachedResolution = resolution;
            }
          }
          if (resolution == ConflictResult.skip) {
            continue;
          } else if (resolution == ConflictResult.keepBoth) {
            String uniqueName = remoteItem.name;
            int counter = 1;
            while (activeTab.currentFiles.any((f) => f.name == uniqueName)) {
              final baseName = p.basenameWithoutExtension(remoteItem.name);
              final ext = p.extension(remoteItem.name);
              uniqueName = '$baseName ($counter)$ext';
              counter++;
            }
            destPath = _buildRemotePath(currentPath, uniqueName);
          }
        }

        // 同服务器剪切：优先服务端 rename 直接移动，避免下载到本地再上传。
        // rename 失败（个别协议/目录不支持）时回退到下方 download+upload 常规流程。
        bool movedInPlace = false;
        if (sameServerCut) {
          try {
            // 覆盖已存在目标：WebDAV 的 MOVE 默认不覆盖，需先删除目标；
            // 其它协议 rename 多数自动覆盖，删除目标亦无副作用。
            if (destExists && resolution == ConflictResult.overwrite) {
              try {
                await targetClient.delete(destPath, remoteItem.isDirectory);
              } catch (_) {}
            }
            await targetClient.rename(remoteItem.path, destPath);
            processedFileCount++;
            emitMoveProgress(remoteItem.name, processedFileCount, totalTopLevel);
            movedInPlace = true;
          } catch (e) {
            debugPrint('Remote in-place move failed, fallback to download+upload: $e');
          }
        }

        if (!movedInPlace) {
          // Step 1: Download from source remote to local temp
          if (remoteItem.isDirectory) {
            await _downloadRemoteDirectory(
              sourceClient,
              remoteItem.path,
              tempPath,
              onFileStart: (fileName) {
                processedFileCount++;
              },
              onFileProgress: (fileName, fileSize, prog) {
                emitProgress(fileName, fileSize, prog);
                if (prog >= 1.0) {
                  previousFilesBytes += fileSize;
                }
              },
            );
            // Step 2: Upload from local temp to target remote
            await _uploadLocalDirectory(
              targetClient,
              tempPath,
              destPath,
              onFileStart: (fileName) {
                processedFileCount++;
              },
              onFileProgress: (fileName, fileSize, prog) {
                emitProgress(fileName, fileSize, prog);
                if (prog >= 1.0) {
                  previousFilesBytes += fileSize;
                }
              },
            );
          } else {
            final fileSize = remoteItem.size > 0 ? remoteItem.size : 0;
            // 下载阶段
            await sourceClient.downloadFile(remoteItem.path, tempPath, (prog) {
              emitProgress(remoteItem.name, fileSize, prog);
            });
            previousFilesBytes += fileSize;
            // 上传阶段
            await targetClient.uploadFile(tempPath, destPath, (prog) {
              emitProgress(remoteItem.name, fileSize, prog);
            });
            previousFilesBytes += fileSize;
            processedFileCount++;
            lastUploadedName = p.basename(destPath);
            lastUploadedSize = fileSize;
          }
        }

        // Step 3: Delete source if cut（rename 路径已移动源文件，无需删除）
        if (_isCut && !movedInPlace) {
          try {
            await sourceClient.delete(remoteItem.path, remoteItem.isDirectory);
          } catch (e) {
            debugPrint('Failed to delete remote source item after cut: $e');
          }
        }
      }

      // 服务端最终化检测和目录刷新由 scheduleRemoteRefreshAfterUpload 轮询负责，
      // 不再调用 _awaitUploadFinalized（避免与轮询同时操作 FTP 连接导致竞争和闪退）。

      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(_isCut ? L10n.of(context).msg05d3c93c : L10n.of(context).msgb7e3a1c2),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } catch (e) {
      debugPrint('Error pasting remote to remote: $e');
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(e.toString().contains('Cancelled') ? L10n.of(context).msga45bac47 : L10n.of(context).e1(e)),
            backgroundColor: e.toString().contains('Cancelled') ? null : Colors.redAccent,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } finally {
      try {
        await sourceClient.disconnect();
      } catch (_) {}
      // Clean up temp directory
      try {
        if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
      } catch (_) {}
      progressNotifier.value = null;
      if (clearAfterPaste) clearClipboard();
      // 精准刷新目标远程 tab，避免污染全局活跃面板。
      await loadDirectoryForTab(targetTabIndex, currentPath, showLoading: false, clearCache: true);
      // 剪切操作：刷新远程源目录。clearClipboard() 已清空 _isCut/_remoteClipboardItems，
      // 故使用前面缓存的 r2rWasCut/r2rConn/r2rSourceDir。
      if (r2rWasCut && r2rConn != null) {
        for (int i = 0; i < _tabs.length; i++) {
          if (_tabs[i].isRemote && _tabs[i].currentPath == r2rSourceDir) {
            try {
              final tabClient = createRemoteClient(_tabs[i].remoteConnection!);
              await tabClient.connect();
              _tabs[i].remoteClient = tabClient;
              await loadDirectoryForTab(i, r2rSourceDir, showLoading: false, clearCache: true);
            } catch (e) {
              debugPrint('Failed to refresh remote source tab: $e');
            }
            break;
          }
        }
        // 广播给全屏 RemoteExplorerScreen（非 tab），使其刷新当前目录，
        // 避免“原文件残留 / 返回后页面丢失”。
        _remoteSourceChangedController.add(RemoteSourceChanged(r2rConn, r2rSourceDir));
      }
      activeTab.isLoading = false;
      _isPasting = false;
      // 重置取消标志：即使传输被取消，也需要 scheduleRemoteRefreshAfterUpload
      // 执行至少一次刷新，清理目录中残留的临时文件显示。
      _isOperationCancelled = false;
      notifyListeners();
      // 同服务器移动走 rename，不产生服务端临时文件，无需 finalize 轮询刷新。
      if (!sameServerCut) {
        // 上传后服务端可能延迟清理临时文件，延迟再刷一次以保证 UI 干净。
        // 注意：必须在 _isPasting = false 之后启动，否则后台轮询会因 _isPasting
        // 仍为 true 而立即退出，导致 UI 不自动刷新。
        scheduleRemoteRefreshAfterUpload(
          currentPath,
          targetTabIndex,
          targetName: lastUploadedName ?? '',
          expectedSize: lastUploadedSize,
        );
      }
    }
  }

  /// 判断两个远程连接是否指向同一服务器（同协议/主机/端口/用户名）。
  /// rootPath 可能不同（同一服务器的不同挂载根）仍视为同服务器，
  /// 因为 rename 移动只需在同一服务器的任意两个路径间进行。
  bool _isSameRemoteConnection(NetworkConnectionModel a, NetworkConnectionModel b) {
    return a.type == b.type &&
        a.host == b.host &&
        a.port == b.port &&
        a.username == b.username;
  }

  Future<RemoteClient?> _createRemoteClient(NetworkConnectionModel conn) async {
    if (conn.type == 'FTP') {
      return FtpRemoteClient(host: conn.host, port: conn.port, username: conn.username, password: conn.password);
    } else if (conn.type == 'SFTP') {
      return SftpRemoteClient(host: conn.host, port: conn.port, username: conn.username, password: conn.password);
    } else if (conn.type == 'WebDav') {
      return WebDavRemoteClient(
        host: conn.host, port: conn.port, username: conn.username, password: conn.password,
        protocol: conn.protocol, rootPath: conn.rootPath,
      );
    } else if (isSmbType(conn.type)) {
      return LanClient(host: conn.host, port: conn.port, username: conn.username, password: conn.password);
    } else if (conn.type == 'saf') {
      return SafRemoteClient(rootUri: conn.rootPath);
    }
    return null;
  }

  /// Recursively counts files in a remote directory (requires listDirectory calls).
  Future<int> _countRemoteFiles(RemoteClient client, String remotePath) async {
    try {
      final items = await client.listDirectory(remotePath);
      int count = 0;
      for (final item in items) {
        if (item.isDirectory) {
          count += await _countRemoteFiles(client, item.path);
        } else {
          count += 1;
        }
      }
      return count;
    } catch (_) {
      return 0;
    }
  }

  /// 递归统计远程目录的真实文件数和总字节数。
  /// 返回 (fileCount, totalBytes)。需要多次 listDirectory 调用，
  /// 但只在传输前执行一次，换取进度条分母的准确性。
  Future<({int fileCount, int totalBytes})> _countRemoteFilesAndBytes(
    RemoteClient client, String remotePath) async {
    try {
      final items = await client.listDirectory(remotePath);
      int count = 0;
      int bytes = 0;
      for (final item in items) {
        if (item.isDirectory) {
          final r = await _countRemoteFilesAndBytes(client, item.path);
          count += r.fileCount;
          bytes += r.totalBytes;
        } else {
          count += 1;
          bytes += item.size;
        }
      }
      return (fileCount: count, totalBytes: bytes);
    } catch (_) {
      return (fileCount: 0, totalBytes: 0);
    }
  }

  /// 递归上传整个本地目录到远程（用于普通复制/粘贴，非分类同步）。
  Future<void> _uploadLocalDirectory(
    RemoteClient client,
    String localDirPath,
    String remoteDirPath, {
    void Function(String fileName)? onFileStart,
    void Function(String fileName, int fileSize, double progress)? onFileProgress,
    bool? bypassUseRoot,
  }) async {
    await client.createDirectory(remoteDirPath);
    // 受限目录：listSync 被 FUSE 拦截，经 shell listFiles 遍历，
    // 文件暂存到 app 缓存后上传
    if (bypassUseRoot != null && _needsBypass(localDirPath)) {
      final children = await RootShizukuService.listFiles(localDirPath, useRoot: bypassUseRoot);
      for (final child in children) {
        if (_isOperationCancelled) throw Exception('Cancelled');
        final remotePath = _buildRemotePath(remoteDirPath, child.name);
        if (child.isDirectory) {
          await _uploadLocalDirectory(client, child.path, remotePath,
              onFileStart: onFileStart, onFileProgress: onFileProgress,
              bypassUseRoot: bypassUseRoot);
        } else {
          String? stagedPath;
          try {
            stagedPath = await _stageRestrictedFile(child.path, bypassUseRoot);
            onFileStart?.call(child.name);
            onFileProgress?.call(child.name, child.size, 0.0);
            await client.uploadFile(stagedPath, remotePath, (prog) {
              onFileProgress?.call(child.name, child.size, prog);
            });
          } finally {
            if (stagedPath != null) {
              try { File(stagedPath).delete(); } catch (_) {}
            }
          }
        }
      }
      return;
    }
    final localDir = Directory(localDirPath);
    final items = localDir.listSync();
    for (final item in items) {
      if (_isOperationCancelled) throw Exception('Cancelled');
      final name = p.basename(item.path);
      final remotePath = _buildRemotePath(remoteDirPath, name);
      if (item is Directory) {
        await _uploadLocalDirectory(client, item.path, remotePath,
            onFileStart: onFileStart, onFileProgress: onFileProgress,
            bypassUseRoot: bypassUseRoot);
      } else if (item is File) {
        int fileSize = 0;
        try { fileSize = item.lengthSync(); } catch (_) {}
        onFileStart?.call(name);
        onFileProgress?.call(name, fileSize, 0.0);
        await client.uploadFile(item.path, remotePath, (prog) {
          onFileProgress?.call(name, fileSize, prog);
        });
      }
    }
  }

  /// 递归统计受限目录的文件数与总字节数（shell listFiles 替代 Dart 遍历），
  /// 用于上传进度分母修正。
  Future<List<int>> _countRestrictedFilesAndBytes(String path, bool useRoot) async {
    int count = 0;
    int bytes = 0;
    final children = await RootShizukuService.listFiles(path, useRoot: useRoot);
    for (final child in children) {
      if (child.isDirectory) {
        final r = await _countRestrictedFilesAndBytes(child.path, useRoot);
        count += r[0];
        bytes += r[1];
      } else {
        count += 1;
        bytes += child.size;
      }
    }
    return [count, bytes];
  }

  /// 递归下载整个远程目录到本地（用于普通复制/粘贴，非分类同步）。
  Future<void> _downloadRemoteDirectory(
    RemoteClient client,
    String remoteDirPath,
    String localDirPath, {
    void Function(String fileName)? onFileStart,
    void Function(String fileName, int fileSize, double progress)? onFileProgress,
  }) async {
    final localDir = Directory(localDirPath);
    if (!localDir.existsSync()) {
      localDir.createSync(recursive: true);
    }
    final List<RemoteFileItem> remoteItems = await client.listDirectory(remoteDirPath);
    for (final item in remoteItems) {
      if (_isOperationCancelled) throw Exception('Cancelled');
      final destPath = p.join(localDirPath, item.name);
      if (item.isDirectory) {
        await _downloadRemoteDirectory(client, item.path, destPath,
            onFileStart: onFileStart, onFileProgress: onFileProgress);
      } else {
        onFileStart?.call(item.name);
        onFileProgress?.call(item.name, item.size, 0.0);
        await client.downloadFile(item.path, destPath, (prog) {
          onFileProgress?.call(item.name, item.size, prog);
        });
      }
    }
  }

  // ===================== 分类同步（文件级 · 本地 ↔ 远程） =====================

  /// 计算一组本地文件路径的最长公共目录前缀（镜像式同步的相对基准）。
  /// 路径以 '/' 分隔（Android 本地路径）。
  static String longestCommonDir(List<String> paths) {
    if (paths.isEmpty) return '';
    if (paths.length == 1) return _localDirname(paths.first);
    final split = paths.map((s) => s.split('/')).toList();
    final first = split.first;
    int common = 0;
    for (int i = 0; i < first.length; i++) {
      final seg = first[i];
      bool ok = true;
      for (int j = 1; j < split.length; j++) {
        if (split[j].length <= i || split[j][i] != seg) {
          ok = false;
          break;
        }
      }
      if (!ok) break;
      common++;
    }
    return first.sublist(0, common).join('/');
  }

  static String _localDirname(String path) {
    final idx = path.lastIndexOf('/');
    if (idx <= 0) return idx == 0 ? '/' : '';
    return path.substring(0, idx);
  }

  static String _localBasename(String path) {
    final idx = path.lastIndexOf('/');
    return idx >= 0 ? path.substring(idx + 1) : path;
  }

  /// 本地文件相对 [base] 的相对路径（以 '/' 分隔）。
  static String _localRelative(String file, String base) {
    if (base.isEmpty) return file;
    final f = file.split('/');
    final b = base.split('/');
    int i = 0;
    while (i < f.length && i < b.length && f[i] == b[i]) {
      i++;
    }
    return f.sublist(i).join('/');
  }

  /// 远程路径的父目录（按 '/' 分隔，规避平台 context 差异）。
  static String _remoteDirname(String remotePath) {
    final idx = remotePath.lastIndexOf('/');
    if (idx <= 0) return '/';
    return remotePath.substring(0, idx);
  }

  static String _remoteBasename(String remotePath) {
    final idx = remotePath.lastIndexOf('/');
    return idx >= 0 ? remotePath.substring(idx + 1) : remotePath;
  }

  /// 拼接远程目录基准与相对路径（rel 以 '/' 分隔）。
  static String _joinRemote(String base, String rel) {
    final b = base.endsWith('/') ? base.substring(0, base.length - 1) : base;
    final r = rel.startsWith('/') ? rel.substring(1) : rel;
    if (r.isEmpty) return b.isEmpty ? '/' : b;
    return '$b/$r';
  }

  int _localFileSize(String path) {
    try {
      return File(path).lengthSync();
    } catch (_) {
      return -1;
    }
  }

  bool _isAlreadyExistsError(Object e) {
    final s = e.toString().toLowerCase();
    return s.contains('405') ||
        s.contains('301') ||
        s.contains('already exist') ||
        s.contains('exists') ||
        s.contains('550');
  }

  /// 幂等地创建远程目录（逐段创建，已存在的段忽略）。
  Future<void> _ensureRemoteDir(RemoteClient client, String serverDirPath) async {
    var clean = serverDirPath;
    if (!clean.startsWith('/')) clean = '/$clean';
    final parts = clean.split('/').where((s) => s.isNotEmpty).toList();
    String cur = '';
    for (final part in parts) {
      cur = cur.isEmpty ? '/$part' : '$cur/$part';
      try {
        await client.createDirectory(cur);
      } catch (e) {
        if (_isAlreadyExistsError(e)) continue;
        rethrow;
      }
    }
  }

  /// 列出远程目录（带缓存，避免重复请求）。
  Future<List<RemoteFileItem>> _listRemoteDirCached(
    RemoteClient client,
    String dir,
    Map<String, List<RemoteFileItem>> cache,
  ) async {
    if (cache.containsKey(dir)) return cache[dir]!;
    try {
      final items = await client.listDirectory(dir);
      cache[dir] = items;
      return items;
    } catch (_) {
      cache[dir] = const <RemoteFileItem>[];
      return const <RemoteFileItem>[];
    }
  }

  /// 查询远程文件大小；不存在返回 null。
  Future<int?> _remoteFileSize(
    RemoteClient client,
    String remoteFilePath,
    Map<String, List<RemoteFileItem>> cache,
  ) async {
    final parent = _remoteDirname(remoteFilePath);
    final name = _remoteBasename(remoteFilePath);
    final items = await _listRemoteDirCached(client, parent, cache);
    for (final it in items) {
      if (!it.isDirectory && it.name == name) return it.size;
    }
    return null;
  }

  /// 同步一个或多个「文件级」单元：仅同步 [CategorySyncPair.localFiles] 中列出的
  /// 实际分类文件（而非整文件夹），并保留其在公共本地基准下的相对结构。
  /// - 幂等：远程/本地已存在且大小一致则跳过传输（修复「二次同步失败」）。
  /// - 剪枝：若某文件曾已同步（有记录）但远程/本地副本已被删除，则撤销其云徽记录。
  Future<CategorySyncResult> syncCategoryPairs({
    required List<CategorySyncPair> pairs,
    SyncDirection direction = SyncDirection.localToRemote,
    required String categoryLabel,
    void Function(String status)? onStatus,
    void Function(String name, int size, double progress)? onProgress,
  }) async {
    await CategorySyncService.init();
    final syncedLocalPaths = <String>[];
    int transferredUnits = 0;
    _isOperationCancelled = false;

    final allRecords = CategorySyncService.getAllRecords();
    final keptRecords = <CategorySyncRecord>[];
    for (final r in allRecords) {
      if (r.category == categoryLabel) keptRecords.add(r);
    }
    final recordByLocal = <String, CategorySyncRecord>{};
    for (final r in keptRecords) {
      recordByLocal[r.localPath] = r;
    }

    void dropRecord(String localPath) {
      keptRecords.removeWhere((r) => r.localPath == localPath);
      recordByLocal.remove(localPath);
    }

    void upsertRecord(CategorySyncRecord rec) {
      keptRecords.removeWhere(
          (r) => r.localPath == rec.localPath && r.toRemote == rec.toRemote);
      keptRecords.add(rec);
      recordByLocal[rec.localPath] = rec;
    }

    Future<void> persist() async {
      final remaining = <CategorySyncRecord>[];
      for (final r in allRecords) {
        if (r.category != categoryLabel) remaining.add(r);
      }
      remaining.addAll(keptRecords);
      await CategorySyncService.saveAllRecords(remaining);
    }

    for (final pair in pairs) {
      final parsed = _parseRemotePath(pair.remoteTargetPath);
      if (parsed == null) {
        onStatus?.call('跳过无效远程路径: ${pair.remoteTargetPath}');
        continue;
      }
      final conn = _connectionById(parsed.connectionId);
      if (conn == null) {
        onStatus?.call('未找到远程连接: ${parsed.connectionId}');
        continue;
      }
      final localFiles =
          pair.localFiles.where((f) => !f.startsWith('remote://')).toList();
      final localDir = pair.localDir;
      if (localDir.isEmpty && localFiles.isEmpty) {
        continue;
      }
      final dirCache = <String, List<RemoteFileItem>>{};
      final client = FileManagerProvider.createRemoteClient(conn);
      try {
        await client.connect();

        if (direction == SyncDirection.localToRemote ||
            direction == SyncDirection.bidirectional) {
          onStatus?.call('同步本地 → 远程');
          for (final localFile in localFiles) {
            if (_isOperationCancelled) throw Exception('Cancelled');
            final name = _localBasename(localFile);
            final rel = _localRelative(localFile, localDir);
            final remoteFilePath = _joinRemote(parsed.remotePath, rel);
            final localSize = _localFileSize(localFile);
            final remoteSize =
                await _remoteFileSize(client, remoteFilePath, dirCache);
            final rec = recordByLocal[localFile];
            // 远程副本已被删除 -> 撤销旧记录，重新上传（不再跳过）。
            // 原逻辑「远程副本被删就丢弃记录且不重传」导致远程目录删文件后
            // 部分类别提示失败、部分提示成功但实际未备份。
            if (rec != null && remoteSize == null) {
              onStatus?.call('远程副本已删除，重新备份: $name');
              dropRecord(localFile);
              // fall-through to upload
            }
            if (remoteSize != null && localSize >= 0 && remoteSize == localSize) {
              // 已存在且一致 -> 保持云徽，跳过传输。
              upsertRecord(CategorySyncRecord(
                category: categoryLabel,
                localPath: localFile,
                remotePath: '${pair.remoteTargetPath}/$rel',
                size: localSize,
                toRemote: true,
              ));
              syncedLocalPaths.add(localFile);
              continue;
            }
            await _ensureRemoteDir(client, _remoteDirname(remoteFilePath));
            onStatus?.call('上传 $name');
            onProgress?.call(name, localSize, 0.0);
            await client.uploadFile(localFile, remoteFilePath, (prog) {
              onProgress?.call(name, localSize, prog);
            });
            upsertRecord(CategorySyncRecord(
              category: categoryLabel,
              localPath: localFile,
              remotePath: '${pair.remoteTargetPath}/$rel',
              size: localSize,
              toRemote: true,
            ));
            syncedLocalPaths.add(localFile);
          }
        }

        if (direction == SyncDirection.remoteToLocal ||
            direction == SyncDirection.bidirectional) {
          onStatus?.call('同步远程 → 本地');
          // 仅下载该类别识别的文件格式（与扫描过滤一致），不同步目录里其它格式文件。
          final categoryFilter = FileUtils.categoryFileFilter(categoryLabel);
          Future<void> downloadDir(String remoteDir, String localDest, String relAcc) async {
            if (_isOperationCancelled) throw Exception('Cancelled');
            final localDirObj = Directory(localDest);
            if (!localDirObj.existsSync()) {
              try {
                localDirObj.createSync(recursive: true);
              } catch (_) {}
            }
            final List<RemoteFileItem> items =
                await _listRemoteDirCached(client, remoteDir, dirCache);
            for (final item in items) {
              if (_isOperationCancelled) throw Exception('Cancelled');
              final destPath = p.join(localDest, item.name);
              final rel = relAcc.isEmpty ? item.name : '$relAcc/${item.name}';
              if (item.isDirectory) {
                await downloadDir(item.path, destPath, rel);
                continue;
              }
              // 跳过非本类别格式的文件（如图片类别不同步视频/文档等）。
              if (!categoryFilter(item.name)) continue;
              final rec = recordByLocal[destPath];
              final localExists = File(destPath).existsSync();
              if (rec != null && !localExists) {
                onStatus?.call('本地已删除，取消云徽: ${item.name}');
                dropRecord(destPath);
                continue;
              }
              final localSize = _localFileSize(destPath);
              if (localExists && localSize >= 0 && item.size == localSize) {
                upsertRecord(CategorySyncRecord(
                  category: categoryLabel,
                  localPath: destPath,
                  remotePath: '${pair.remoteTargetPath}/$rel',
                  size: item.size,
                  toRemote: false,
                ));
                syncedLocalPaths.add(destPath);
                continue;
              }
              onStatus?.call('下载 ${item.name}');
              onProgress?.call(item.name, item.size, 0.0);
              await client.downloadFile(item.path, destPath, (prog) {
                onProgress?.call(item.name, item.size, prog);
              });
              upsertRecord(CategorySyncRecord(
                category: categoryLabel,
                localPath: destPath,
                remotePath: '${pair.remoteTargetPath}/$rel',
                size: item.size,
                toRemote: false,
              ));
              syncedLocalPaths.add(destPath);
            }
          }

          await downloadDir(parsed.remotePath, localDir, '');
        }
        transferredUnits++;
      } catch (e) {
        onStatus?.call('同步失败: $e');
        await persist();
        rethrow;
      } finally {
        try {
          await client.disconnect();
        } catch (_) {}
      }
      await persist();
    }
    return CategorySyncResult(
      syncedLocalPaths: syncedLocalPaths,
      transferredUnits: transferredUnits,
      syncedCount: syncedLocalPaths.length,
    );
  }

  _ParsedRemotePath? _parseRemotePath(String path) {
    if (!path.startsWith('remote://')) return null;
    final uriPart = path.substring('remote://'.length);
    final sep = uriPart.indexOf('|');
    if (sep < 0) return null;
    return _ParsedRemotePath(
      connectionId: uriPart.substring(0, sep),
      remotePath: uriPart.substring(sep + 1),
    );
  }

  NetworkConnectionModel? _connectionById(String id) {
    final conns = NetworkConnectionsService.getConnections();
    for (final c in conns) {
      if (c.id == id) return c;
    }
    return null;
  }

  String _getUniquePath(String destPath, bool isDir) {
    if (isDir) {
      if (!Directory(destPath).existsSync()) return destPath;
      int counter = 1;
      String parent = p.dirname(destPath);
      String base = p.basename(destPath);
      while (true) {
        final candidate = p.join(parent, '$base ($counter)');
        if (!Directory(candidate).existsSync()) {
          return candidate;
        }
        counter++;
      }
    } else {
      if (!File(destPath).existsSync()) return destPath;
      int counter = 1;
      String parent = p.dirname(destPath);
      String ext = p.extension(destPath);
      String base = p.basenameWithoutExtension(destPath);
      while (true) {
        final candidate = p.join(parent, '$base ($counter)$ext');
        if (!File(candidate).existsSync()) {
          return candidate;
        }
        counter++;
      }
    }
  }

  String _getCopyUniquePath(String destPath, bool isDir) {
    String parent = p.dirname(destPath);
    if (isDir) {
      String base = p.basename(destPath);
      String copyBase = '$base (copy)';
      if (!Directory(p.join(parent, copyBase)).existsSync()) {
        return p.join(parent, copyBase);
      }
      int counter = 1;
      while (true) {
        final candidate = p.join(parent, '$copyBase ($counter)');
        if (!Directory(candidate).existsSync()) {
          return candidate;
        }
        counter++;
      }
    } else {
      String ext = p.extension(destPath);
      String base = p.basenameWithoutExtension(destPath);
      String copyBase = '$base (copy)';
      if (!File(p.join(parent, '$copyBase$ext')).existsSync()) {
        return p.join(parent, '$copyBase$ext');
      }
      int counter = 1;
      while (true) {
        final candidate = p.join(parent, '$copyBase ($counter)$ext');
        if (!File(candidate).existsSync()) {
          return candidate;
        }
        counter++;
      }
    }
  }

  void _updateSubsequentDestPaths(List<Map<String, dynamic>> items, int startIndex, String oldParentPath, String newParentPath) {
    for (int j = startIndex; j < items.length; j++) {
      final subDest = items[j]['destPath'] as String;
      if (p.isWithin(oldParentPath, subDest) || subDest == oldParentPath) {
        final relativePart = p.relative(subDest, from: oldParentPath);
        items[j]['destPath'] = p.join(newParentPath, relativePart);
      }
    }
  }

  // ===== Android 受限路径（Android/data|obb）复制/上传绕过支持 =====
  //
  // Android 11+ FUSE 层使 app 进程对其它应用的 /storage/emulated/0/Android/
  // {data,obb} 文件完全不可见（typeSync/existsSync/lengthSync/openRead 均失败，
  // 与是否授予系统 root 权限无关——那是 shell 用户的权限）。浏览层已通过
  // Root/Shizuku 在 /data/media/0 底层路径正常列出这些文件，但复制/上传链路
  // 此前仍走 Dart IO，导致"传输失败：Local file not found"。以下辅助方法
  // 让复制/上传对受限路径统一改走 shell 命令。

  /// 是否位于 FUSE 受限区（其它应用的 Android/data、Android/obb 文件）。
  /// 自身包名目录 app 本身可读写，无需绕过。
  bool _isRestrictedAndroidPath(String path) {
    if (!path.startsWith('/storage/emulated/0/Android/')) return false;
    final sub = path.substring('/storage/emulated/0/Android/'.length);
    if (!sub.startsWith('data/') && !sub.startsWith('obb/')) return false;
    // 自身外部目录（如 Android/data/com.sequl.zenfile/cache）可正常访问
    return !sub.startsWith('data/com.sequl.zenfile') && !sub.startsWith('obb/com.sequl.zenfile');
  }

  /// 受限路径且 Dart IO 不可见（需要走 shell 绕过）。
  bool _needsBypass(String path) =>
      _isRestrictedAndroidPath(path) &&
      FileSystemEntity.typeSync(path) == FileSystemEntityType.notFound;

  /// 解析受限操作可用的执行模式：root 优先（对 FUSE 与底层路径均有完全
  /// 权限）。不依据当前 tab 的 useRootMode——用户从受限目录复制后导航到
  /// 普通目录粘贴时，tab 模式已被重置为 false，会误选 Shizuku（底层路径
  /// 无其它应用文件读权限）。返回 null 表示均不可用。
  Future<bool?> _resolveBypassMode() async {
    final status = await RootShizukuService.checkStatus();
    final rootOk = status.isRootAvailable;
    final shizukuOk = status.isShizukuAvailable && status.shizukuPermissionGranted;
    if (rootOk) return true;
    if (shizukuOk) return false;
    return null;
  }

  /// 将受限源文件经 shell `cp` 暂存到共享存储隐藏目录 `.nfile_temp`
  /// （app 经 FUSE 可读写，root/shell 经 FUSE 路径可写），返回 app 可直接
  /// 读取的暂存路径；供远程上传等只能读 Dart File 的链路使用。调用方
  /// 负责删除。
  ///
  /// 不再暂存到 getExternalStorageDirectories()（app 外部 files 目录）：
  /// 该路径经底层 /data/media/0 写入后文件属主为 root/shell，app 经 FUSE
  /// 读取自身外部目录下的他人属主文件会被拒绝，导致上传报
  /// "Local file not found"。`.nfile_temp` 方案与「直接打开受限文件」
  /// 的暂存实现（已验证可用）完全一致。
  Future<String> _stageRestrictedFile(String srcPath, bool useRoot) async {
    const stageDirPath = '/storage/emulated/0/.nfile_temp';
    final dir = Directory(stageDirPath);
    if (!dir.existsSync()) {
      dir.createSync(recursive: true);
    }
    final stageName = 'zenfile_stage_${DateTime.now().millisecondsSinceEpoch}_${p.basename(srcPath)}';
    final stagedPath = p.join(stageDirPath, stageName);
    await RootShizukuService.copyItem(srcPath, stagedPath, useRoot: useRoot);
    return stagedPath;
  }

  /// 递归收集受限目录的全部子项（shell listFiles 替代 Dart listSync），
  /// 追加到 itemsToProcess 并累加 totalBytes。
  Future<void> _collectRestrictedDir(
    String srcPath,
    String topDestPath,
    List<Map<String, dynamic>> items,
    bool useRoot,
    int Function() getTotal,
    void Function(int) addTotal,
  ) async {
    final children = await RootShizukuService.listFiles(srcPath, useRoot: useRoot);
    for (final child in children) {
      final destPath = p.join(topDestPath, child.name);
      if (child.isDirectory) {
        items.add({'source': child.path, 'destPath': destPath, 'size': 0, 'isDir': true, 'restricted': true});
        await _collectRestrictedDir(child.path, destPath, items, useRoot, getTotal, addTotal);
      } else {
        addTotal(getTotal() + child.size);
        items.add({'source': child.path, 'destPath': destPath, 'size': child.size, 'isDir': false, 'restricted': true});
      }
    }
  }

  Future<void> _copyFileWithProgress(
    File source,
    File destination, {
    required Function(int chunkSize) onChunkCopied,
  }) async {
    final reader = source.openRead();
    final writer = destination.openWrite();

    try {
      await for (final chunk in reader) {
        if (_isOperationCancelled) {
          await writer.close();
          if (await destination.exists()) {
            await destination.delete();
          }
          throw Exception('Cancelled');
        }
        writer.add(chunk);
        onChunkCopied(chunk.length);
      }
    } finally {
      await writer.close();
    }
  }

  Future<void> deleteFile(String path) async {
    // Look up the file to check if it has a remote source
    final file = currentFiles.cast<FileItemModel?>().firstWhere(
      (f) => f?.path == path,
      orElse: () => null,
    );

    // If we're in a remote tab, always delete from the remote server
    // (covers both directly-browsed remote files and cached remote files)
    if (activeTab.isRemote && activeTab.remoteClient != null) {
      if (file == null) {
        debugPrint('Cannot delete $path: file not found in current list');
        return;
      }
      final remoteClient = activeTab.remoteClient!;
      final remotePath = file.remoteSource?.path ?? file.path;
      try {
        await remoteClient.delete(remotePath, file.isDirectory);
        await loadDirectory(currentPath, showLoading: false, clearCache: true);
      } catch (e) {
        debugPrint('Error deleting remote file: $e');
        rethrow;
      }
      return;
    }

    // Local file deletion
    try {
      if (RecycleBinService.isEnabled()) {
        await RecycleBinService.moveToTrash(path, useRoot: useRootMode);
      } else {
        if (isRestrictedPath(path)) {
          await RootShizukuService.deleteItem(path, useRoot: useRootMode);
        } else {
          final type = FileSystemEntity.typeSync(path);
          if (type == FileSystemEntityType.directory) {
            await Directory(path).delete(recursive: true);
          } else {
            await File(path).delete();
          }
        }
      }
      await loadDirectory(currentPath, showLoading: false, clearCache: true);
      // 本地删除后即时通知媒体列表裁剪，避免分类页残留空白图标。
      MediaProvider.instance?.pruneDeletedMediaPaths([path]);
    } catch (e) {
      debugPrint('Error deleting file: $e');
      rethrow;
    }
  }

  Future<void> renameFile(String oldPath, String newName, [BuildContext? context]) async {
    try {
      String finalNewPath;
      if (activeTab.isRemote && activeTab.remoteClient != null) {
        final newPath = '${p.url.dirname(oldPath)}/$newName';
        await activeTab.remoteClient!.rename(oldPath, newPath);
        finalNewPath = newPath;
      } else if (isRestrictedPath(oldPath)) {
        await RootShizukuService.renameItem(oldPath, newName, useRoot: useRootMode);
        finalNewPath = p.join(p.dirname(oldPath), newName);
      } else {
        final newPath = p.join(p.dirname(oldPath), newName);
        finalNewPath = newPath;
        // 冲突处理：目标名已存在且与自身不同，弹出冲突对话框，避免静默覆盖/误删。
        // 与粘贴等其它操作保持一致的交互（覆盖 / 保留两者 / 重命名 / 取消）。
        if (context != null) {
          final targetType = FileSystemEntity.typeSync(newPath);
          if (targetType != FileSystemEntityType.notFound &&
              p.normalize(newPath) != p.normalize(oldPath)) {
            final response = await ConflictDialog.show(
              context,
              fileName: newName,
              sourceFile: File(oldPath),
              destFile: File(newPath),
            );
            if (response == null ||
                response.result == ConflictResult.cancel ||
                response.result == ConflictResult.skip) {
              return; // 用户取消，不执行重命名
            }
            if (response.result == ConflictResult.keepBoth) {
              finalNewPath = _getUniquePath(newPath, targetType == FileSystemEntityType.directory);
            } else if (response.result == ConflictResult.rename &&
                response.customName != null &&
                response.customName!.isNotEmpty) {
              finalNewPath = p.join(p.dirname(oldPath), response.customName!);
            }
            // ConflictResult.overwrite：保持 finalNewPath = newPath，直接覆盖
          }
        }
        final type = FileSystemEntity.typeSync(oldPath);
        if (type == FileSystemEntityType.directory) {
          await _renameWithFallback(Directory(oldPath), finalNewPath);
        } else {
          await _renameWithFallback(File(oldPath), finalNewPath);
        }
      }
      // 刷新被重命名文件所在目录对应的 tab（而非全局 activeTab），
      // 避免双窗口下刷新错面板导致列表/缩略图仍显示旧内容（如旧截图）。
      await _refreshTabForPath(p.dirname(oldPath));
      // 清理新旧路径的缩略图缓存，确保重命名后缩略图立即以真实内容刷新。
      _evictImageCache(oldPath);
      _evictImageCache(finalNewPath);
    } catch (e) {
      debugPrint('Error renaming file: $e');
      rethrow;
    }
  }

  /// 刷新包含指定目录路径的本地 tab（优先匹配）；找不到对应 tab 时回退到 activeTab。
  /// 用于重命名/删除等操作后精准刷新目标面板，而不是盲目刷新全局 activeTab。
  Future<void> _refreshTabForPath(String dirPath) async {
    final normalized = p.normalize(dirPath);
    for (int i = 0; i < _tabs.length; i++) {
      if (!_tabs[i].isRemote && p.normalize(_tabs[i].currentPath) == normalized) {
        await loadDirectoryForTab(i, _tabs[i].currentPath, showLoading: false, clearCache: true, recordHistory: false);
        return;
      }
    }
    await loadDirectory(currentPath, showLoading: false, clearCache: true);
  }

  /// 从 Flutter 全局图片缓存中剔除指定路径的缩略图，强制下次重新解码，
  /// 避免重命名/覆盖后列表仍显示旧的缩略图（如旧截图）。
  void _evictImageCache(String path) {
    try {
      PaintingBinding.instance.imageCache.evict(FileImage(File(path)));
    } catch (_) {}
  }

  /// 重命名实体，若 rename() 失败（跨文件系统/路径过长/权限等），
  /// 回退到 复制 + 删除 以确保操作成功（与系统文件管理器行为一致）。
  Future<void> _renameWithFallback(FileSystemEntity entity, String newPath) async {
    try {
      await entity.rename(newPath);
    } catch (e) {
      debugPrint('rename() failed, falling back to copy+delete: $e');
      // 回退到复制 + 删除
      if (entity is File) {
        final srcFile = entity;
        final parentDir = Directory(p.dirname(newPath));
        if (!parentDir.existsSync()) {
          await parentDir.create(recursive: true);
        }
        await srcFile.copy(newPath);
        try {
          await srcFile.delete();
        } catch (delErr) {
          debugPrint('Source delete after copy failed (rename fallback): $delErr');
        }
      } else if (entity is Directory) {
        final srcDir = entity;
        final destDir = Directory(newPath);
        if (!destDir.existsSync()) {
          await destDir.create(recursive: true);
        }
        await _copyDirectory(srcDir, destDir);
        try {
          await srcDir.delete(recursive: true);
        } catch (delErr) {
          debugPrint('Source dir delete after copy failed (rename fallback): $delErr');
        }
      }
    }
  }

  bool get currIsRemote => activeTab.isRemote && activeTab.remoteClient != null;

  /// Build a remote path joining current [dir] with [name] using '/' separator.
  String _buildRemotePath(String dir, String name) {
    final base = dir.endsWith('/') ? dir : '$dir/';
    return '$base$name';
  }

  Future<String?> createFolder(String name) async {
    try {
      String finalName = name;
      final targetPath = currIsRemote ? _buildRemotePath(currentPath, name) : p.join(currentPath, name);
      if (FileSystemEntity.typeSync(targetPath) != FileSystemEntityType.notFound) {
        final uniquePath = _getUniquePath(targetPath, true);
        finalName = p.basename(uniquePath);
      }
      if (currIsRemote && activeTab.remoteClient != null) {
        final remotePath = _buildRemotePath(currentPath, finalName);
        await activeTab.remoteClient!.createDirectory(remotePath);
      } else if (isRestrictedPath(currentPath)) {
        await RootShizukuService.createFolder(currentPath, finalName, useRoot: useRootMode);
      } else {
        final newPath = p.join(currentPath, finalName);
        await Directory(newPath).create();
      }
      await loadDirectory(currentPath, showLoading: false, clearCache: true);
      return finalName;
    } catch (e) {
      debugPrint('创建文件夹出错：{e}');
      return null;
    }
  }

  Future<String?> createFile(String name) async {
    try {
      String finalName = name;
      final targetPath = currIsRemote ? _buildRemotePath(currentPath, name) : p.join(currentPath, name);
      if (!currIsRemote && FileSystemEntity.typeSync(targetPath) != FileSystemEntityType.notFound) {
        final uniquePath = _getUniquePath(targetPath, false);
        finalName = p.basename(uniquePath);
      }
      if (currIsRemote && activeTab.remoteClient != null) {
        final remotePath = _buildRemotePath(currentPath, finalName);
        await activeTab.remoteClient!.createFile(remotePath);
      } else if (isRestrictedPath(currentPath)) {
        await RootShizukuService.createFile(currentPath, finalName, useRoot: useRootMode);
      } else {
        final newPath = p.join(currentPath, finalName);
        await File(newPath).create();
      }
      await loadDirectory(currentPath, showLoading: false, clearCache: true);
      return finalName;
    } catch (e) {
      debugPrint('Error creating file: $e');
      return null;
    }
  }

  Future<void> updateFileInList(String filePath) async {
    try {
      final file = File(filePath);
      if (await file.exists()) {
        final stat = await file.stat();
        bool updated = false;
        for (var tab in _tabs) {
          final index = tab.currentFiles.indexWhere((item) => item.path == filePath);
          if (index != -1) {
            final oldItem = tab.currentFiles[index];
            tab.currentFiles[index] = FileItemModel(
              entity: oldItem.entity,
              name: oldItem.name,
              path: oldItem.path,
              isDirectory: oldItem.isDirectory,
              size: stat.size,
              modified: stat.modified,
            );
            updated = true;
          }
        }
        if (updated) {
          notifyListeners();
        }
      }
    } catch (e) {
      debugPrint('Error updating file in list: $e');
    }
  }

  Future<void> createArchive({
    required String archiveName,
    required String format,
    required int compressionLevel,
    String? password,
    int? splitSizeMB,
    required bool deleteSource,
    required bool separateArchives,
    List<String>? targetPaths,
    BuildContext? context,
  }) async {
    final paths = targetPaths ?? (selectedPaths.isNotEmpty ? selectedPaths.toList() : [currentPath]);

    // Check size limit for TAR.LZ4 and TAR.ZSTD
    if (format == 'tar.lz4' || format == 'tar.zst') {
      final totalSize = await _calculateTotalSize(paths);
      if (totalSize > 600 * 1024 * 1024) {
        if (context != null && context.mounted) {
          await FileActionDialogs.showWarningDialog(
            context,
            title: '压缩超出限制',
            content: 'TAR.ZSTD and TAR.LZ4 formats are highly memory-intensive and optimized for files under 600MB. Please use the ZIP or TAR format for larger files.',
          );
        }
        selectedPaths.clear();
        notifyListeners();
        return;
      }
    }

    selectedPaths.clear();
    notifyListeners();

    if (context != null && context.mounted) {
      var destinationPath = p.join(currentPath, '$archiveName.$format');
      // 如果目标路径已存在，自动重命名（快手.zip → 快手(1).zip → 快手(2).zip）
      int counter = 1;
      while (File(destinationPath).existsSync()) {
        destinationPath = p.join(currentPath, '$archiveName($counter).$format');
        counter++;
      }
      // 保存当前路径用于完成后刷新，避免依赖可能失效的 context
      final targetDir = currentPath;
      await BackgroundArchiveService.instance.startCompression(
        context: context,
        sourcePaths: paths,
        destinationPath: destinationPath,
        format: format,
        level: compressionLevel,
        deleteSource: deleteSource,
        targetRefreshDir: targetDir,
        onComplete: () {
          loadDirectory(targetDir, showLoading: false, clearCache: true);
        },
        provider: this,
      );
      // startCompression 启动 Isolate 后立即返回（不等待压缩完成），
      // 压缩进度由 BackgroundOperationProgressDialog 显示。
      // 不设置 activeTab.isLoading = true，否则会在压缩期间一直显示 loading 遮罩，
      // 叠加在进度弹窗后面造成"卡住"观感；目录刷新由 _onOperationComplete 负责。
    } else {
      try {
        await ArchiveService.createArchive(
          sourcePaths: paths,
          destinationDir: currentPath,
          archiveName: archiveName,
          format: format,
          compressionLevel: compressionLevel,
          password: password,
          splitSizeMB: splitSizeMB,
          deleteSource: deleteSource,
          separateArchives: separateArchives,
        );
      } catch (e) {
        debugPrint('Error creating archive: $e');
      }

      selectedPaths.clear();
      await loadDirectory(currentPath, showLoading: false, clearCache: true);
    }
  }

  Future<int> _calculateTotalSize(List<String> paths) async {
    int total = 0;
    for (final path in paths) {
      try {
        final type = FileSystemEntity.typeSync(path);
        if (type == FileSystemEntityType.file) {
          total += File(path).lengthSync();
        } else if (type == FileSystemEntityType.directory) {
          final dir = Directory(path);
          await for (final entity in dir.list(recursive: true, followLinks: false)) {
            if (entity is File) {
              total += entity.lengthSync();
            }
          }
        }
      } catch (e) {
        debugPrint('Error calculating size for $path: $e');
      }
    }
    return total;
  }

  Future<void> extractArchiveDirectly(BuildContext context, String path) async {
    // 默认解压到压缩包所在位置（ExtractArchiveDialog 会根据 archivePath 自动取 dirname，此处兜底传入压缩包目录）
    final archiveDir = p.dirname(path);
    final res = await ExtractArchiveDialog.show(
      context,
      archiveName: p.basename(path),
      archiveDir: archiveDir,
      archivePath: path,
    );
    if (res != null && context.mounted) {
      await BackgroundArchiveService.instance.startExtraction(
        context: context,
        archivePath: path,
        destinationDir: res.destinationDir,
        password: res.password,
      );
    }
  }

  bool hasNativeViewer(String path) {
    final mimeType = lookupMimeType(path) ?? '';
    final ext = p.extension(path).toLowerCase();
    const docExts = ['.pdf', '.doc', '.docx', '.xls', '.xlsx', '.ppt', '.pptx', '.epub', '.odt'];
    
    if (FileUtils.isArchive(path)) return true;
    if (mimeType.startsWith('image/')) return true;
    if (mimeType.startsWith('video/')) return true;
    if (mimeType.startsWith('audio/')) return true;
    if (FileUtils.isTextOrCode(path)) return true;
    if (const ['.db', '.sqlite', '.sqlite3', '.db3'].contains(ext)) return true;
    if (docExts.contains(ext)) return true;
    if (ApkInstallerService.isApk(path)) return true;
    // Fallback: any other file can be viewed as text/code in our built-in editor
    return true;
  }

  Future<void> openFileNatively(BuildContext context, String path, {bool showTypePickerForUnknown = false}) async {
    final opened = await _tryOpenBuiltInDirectly(context, path);
    if (opened) return;

    if (showTypePickerForUnknown) {
      await _pickAndOpenBuiltInType(context, path, saveDefault: false);
      return;
    }

    // 未知格式：先让用户选择「本应用打开」还是「外部系统选择器」
    final result = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => OpenWithSheet(
        fileName: p.basename(path),
        fileExtension: p.extension(path).toLowerCase(),
      ),
    );

    if (result == null || !context.mounted) return;

    final isAlways = result.startsWith('always_');
    final selectedType = result.substring(isAlways ? 'always_'.length : 'just_once_'.length);
    final ext = p.extension(path).toLowerCase();

    if (selectedType == 'external') {
      // 使用外部系统选择器打开（系统「打开方式...」）
      if (isAlways) {
        await PreferencesService.saveDefaultOpenAction(ext, 'external');
      }
      await openWithSystemChooser(path);
      return;
    }

    // selectedType == 'native'：在应用内选择具体文件类型后，用内置查看器/播放器打开
    await _pickAndOpenBuiltInType(context, path, saveDefault: isAlways);
  }

  /// 尝试按文件实际类型直接用内置查看器/播放器打开。
  /// 返回是否成功打开（true = 已处理；false = 未知格式，需要让用户选择类型）。
  Future<bool> _tryOpenBuiltInDirectly(BuildContext context, String path) async {
    final mimeType = lookupMimeType(path) ?? '';
    final ext = p.extension(path).toLowerCase();
    const docExts = ['.pdf', '.doc', '.docx', '.xls', '.xlsx', '.ppt', '.pptx', '.epub', '.odt'];

    if (FileUtils.isArchive(path)) {
      if (!context.mounted) return true;
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => ArchiveViewerScreen(archivePath: path),
        ),
      );
      return true;
    }

    if (mimeType.startsWith('image/')) {
      if (!context.mounted) return true;
      Navigator.push(context, MaterialPageRoute(builder: (_) => ImageViewerScreen(imagePath: path)));
      return true;
    }

    if (mimeType.startsWith('video/')) {
      if (!context.mounted) return true;
      final folderVideoFiles = activeTab.currentFiles
          .where((f) => !f.isDirectory && (lookupMimeType(f.path)?.startsWith('video/') == true || FileUtils.isVideo(f.path)))
          .map((f) => f.path)
          .toList();
      int initialIndex = folderVideoFiles.indexOf(path);
      if (initialIndex == -1) initialIndex = 0;

      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => VideoPlayerScreen(
            videoPath: path,
            playlist: folderVideoFiles.isNotEmpty ? folderVideoFiles : [path],
            initialIndex: initialIndex,
            isRemote: activeTab.isRemote,
          ),
        ),
      );
      return true;
    }

    if (mimeType.startsWith('audio/')) {
      if (!context.mounted) return true;
      final folderAudioFiles = activeTab.currentFiles
          .where((f) => !f.isDirectory && (lookupMimeType(f.path)?.startsWith('audio/') == true))
          .toList();

      List<SongModel>? allSongs;
      int initialIndex = 0;

      if (folderAudioFiles.isNotEmpty && folderAudioFiles.any((f) => f.path == path)) {
        allSongs = [];
        for (int i = 0; i < folderAudioFiles.length; i++) {
          final file = folderAudioFiles[i];
          final songMap = {
            '_id': i,
            '_data': file.path,
            'title': p.basenameWithoutExtension(file.path),
            'artist': L10n.of(context).msg5e32276d,
            'album': L10n.of(context).msg497ec49d,
            'duration': 0,
            'size': file.size,
            'display_name': p.basename(file.path),
            'display_name_wo_ext': p.basenameWithoutExtension(file.path),
            'is_music': true,
          };
          allSongs.add(SongModel(songMap));
          if (file.path == path) {
            initialIndex = i;
          }
        }
      }

      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => AudioPlayerScreen(
            audioPath: path,
            title: p.basename(path),
            allSongs: allSongs,
            initialIndex: initialIndex,
            isRemote: activeTab.isRemote,
          ),
        ),
      );
      return true;
    }

    if (FileUtils.isTextOrCode(path)) {
      if (!context.mounted) return true;
      Navigator.push(context, MaterialPageRoute(builder: (_) => TextEditorScreen(filePath: path)));
      return true;
    }

    if (const ['.db', '.sqlite', '.sqlite3', '.db3'].contains(ext)) {
      if (!context.mounted) return true;
      Navigator.push(context, MaterialPageRoute(builder: (_) => DatabaseReaderScreen(filePath: path)));
      return true;
    }

    if (docExts.contains(ext)) {
      if (!context.mounted) return true;
      Navigator.push(context, MaterialPageRoute(builder: (_) => DocumentViewerScreen(filePath: path)));
      return true;
    }

    if (ApkInstallerService.isApk(path)) {
      if (!context.mounted) return true;
      await ApkInstallerService.installApk(context, path);
      return true;
    }

    return false;
  }

  /// 弹出文件类型选择器，按用户选定的 text/audio/video/image 类型打开。
  /// [saveDefault] 为 true 时把具体类型存为默认动作。
  Future<void> _pickAndOpenBuiltInType(BuildContext context, String path, {bool saveDefault = false}) async {
    final ext = p.extension(path).toLowerCase();

    final builtInType = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => PickFileTypeSheet(
        fileName: p.basename(path),
        fileExtension: ext,
      ),
    );

    if (builtInType == null || !context.mounted) return;

    if (saveDefault) {
      await PreferencesService.saveDefaultOpenAction(ext, builtInType);
    }

    await _openBuiltInByType(context, path, builtInType);
  }

  /// 显示「本应用打开 / 外部系统选择器」BottomSheet，并执行对应打开流程。
  /// 用于三点菜单 / 长按菜单 / 分类页的「打开方式...」入口。
  Future<void> showOpenWithSheet(BuildContext context, String path) async {
    final ext = p.extension(path).toLowerCase();

    final result = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => OpenWithSheet(
        fileName: p.basename(path),
        fileExtension: ext,
      ),
    );

    if (result == null || !context.mounted) return;

    final isAlways = result.startsWith('always_');
    final selectedType = result.substring(isAlways ? 'always_'.length : 'just_once_'.length);

    if (selectedType == 'external') {
      if (isAlways) {
        await PreferencesService.saveDefaultOpenAction(ext, 'external');
      }
      await openWithSystemChooser(path);
      return;
    }

    // selectedType == 'native'
    final opened = await _tryOpenBuiltInDirectly(context, path);
    if (opened) {
      if (isAlways) {
        await PreferencesService.saveDefaultOpenAction(ext, 'native');
      }
      return;
    }

    await _pickAndOpenBuiltInType(context, path, saveDefault: isAlways);
  }

  /// 按指定内置类型（text/audio/video/image）以应用内查看器/播放器打开文件
  Future<void> _openBuiltInByType(BuildContext context, String path, String type) async {
    switch (type) {
      case 'text':
        Navigator.push(context, MaterialPageRoute(builder: (_) => TextEditorScreen(filePath: path)));
        break;
      case 'image':
        Navigator.push(context, MaterialPageRoute(builder: (_) => ImageViewerScreen(imagePath: path)));
        break;
      case 'video':
        // 远程标签页且文件未在本地缓存：启动流式播放
        if (activeTab.isRemote && activeTab.remoteClient != null && !File(path).existsSync()) {
          final streamUrl = await _setupRemoteMediaStream(path);
          if (streamUrl != null && context.mounted) {
            Navigator.push(context, MaterialPageRoute(builder: (_) => VideoPlayerScreen(videoPath: streamUrl, isRemote: true)));
            break;
          }
          // 流式失败，回退：下载到本地缓存后播放
          if (context.mounted) {
            final localPath = await _downloadRemoteFileToCache(path);
            if (localPath != null) {
              Navigator.push(context, MaterialPageRoute(builder: (_) => VideoPlayerScreen(
                videoPath: localPath, playlist: [localPath], initialIndex: 0, isRemote: true,
              )));
              break;
            }
          }
        }
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => VideoPlayerScreen(
              videoPath: path,
              playlist: [path],
              initialIndex: 0,
              isRemote: activeTab.isRemote,
            ),
          ),
        );
        break;
      case 'audio':
        // 远程标签页且文件未在本地缓存：启动流式播放
        if (activeTab.isRemote && activeTab.remoteClient != null && !File(path).existsSync()) {
          final streamUrl = await _setupRemoteMediaStream(path);
          if (streamUrl != null && context.mounted) {
            Navigator.push(context, MaterialPageRoute(builder: (_) => AudioPlayerScreen(
              audioPath: streamUrl, title: p.basenameWithoutExtension(path), isRemote: true,
            )));
            break;
          }
          // 流式失败，回退：下载到本地缓存后播放
          if (context.mounted) {
            final localPath = await _downloadRemoteFileToCache(path);
            if (localPath != null) {
              Navigator.push(context, MaterialPageRoute(builder: (_) => AudioPlayerScreen(
                audioPath: localPath, title: p.basenameWithoutExtension(path), isRemote: true,
              )));
              break;
            }
          }
        }
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => AudioPlayerScreen(
              audioPath: path,
              title: p.basename(path),
              isRemote: activeTab.isRemote,
            ),
          ),
        );
        break;
      default:
        // 兜底：以文本方式打开
        Navigator.push(context, MaterialPageRoute(builder: (_) => TextEditorScreen(filePath: path)));
    }
  }

  /// 通过系统选择器（Intent.createChooser）打开文件或 URL
  /// 支持本地文件路径和 HTTP(S) URL（远程流式播放）
  static const _platformChannel = MethodChannel('com.sequl.zenfile/root_shizuku');

  /// 为远程文件启动流式播放，返回播放 URL。
  /// WebDAV 优先走直连 HTTP 流式（libmpv 原生 Range 请求，流畅不卡顿），
  /// FTP/SFTP 等走本地代理服务器（边下载边推流）。
  /// 失败时返回 null，调用方应回退到下载模式。
  Future<String?> _setupRemoteMediaStream(String remotePath) async {
    try {
      final conn = activeTab.remoteConnection;
      if (conn == null) return null;

      // 优先尝试 WebDAV 直连流式 URL（libmpv 原生 HTTP Range 请求，与正常扩展名文件一致）
      final directClient = createRemoteClient(conn);
      try {
        final streamUrl = directClient.getStreamUrl(remotePath);
        if (streamUrl != null) {
          debugPrint('_setupRemoteMediaStream: 使用直连流式 URL');
          return streamUrl;
        }
      } finally {
        // getStreamUrl 不需要 connect，但创建了 client 需要断开以防泄漏
        try { await directClient.disconnect(); } catch (_) {}
      }

      // 非 HTTP 流协议（FTP/SFTP 等）：通过本地代理服务器
      final fileItem = currentFiles.where((f) => f.path == remotePath).firstOrNull;
      final knownSize = (fileItem != null && fileItem.size > 0) ? fileItem.size : null;

      final downloadClient = createRemoteClient(conn);
      await downloadClient.connect();
      final seekClient = createRemoteClient(conn);
      await seekClient.connect();

      final proxyUrl = await RemoteStreamingService.instance.startStreaming(
        downloadClient, remotePath, p.basename(remotePath),
        fileSize: knownSize,
        seekClient: seekClient,
      );
      return proxyUrl;
    } catch (e) {
      debugPrint('_setupRemoteMediaStream 失败: $e');
      return null;
    }
  }

  /// 下载远程文件到本地缓存，返回本地路径。
  /// 失败时返回 null。
  Future<String?> _downloadRemoteFileToCache(String remotePath) async {
    try {
      final remoteClient = activeTab.remoteClient;
      if (remoteClient == null) return null;
      final cacheDir = Directory('/storage/emulated/0/ZenFile');
      if (!cacheDir.existsSync()) cacheDir.createSync(recursive: true);
      final cachePath = p.join(cacheDir.path, p.basename(remotePath));
      if (!File(cachePath).existsSync()) {
        await remoteClient.downloadFile(remotePath, cachePath, (progress) {});
      }
      return cachePath;
    } catch (e) {
      debugPrint('_downloadRemoteFileToCache 失败: $e');
      return null;
    }
  }

  /// 把远程文件完整下载到本地缓存目录并返回本地路径。
  /// 与「exists 就跳过」不同：先删除可能残留的半截/损坏文件，下载后校验
  /// 「文件存在 + 非空 + 大小与远程一致（若可获取）」，不一致则删除重试一次；
  /// 仍失败抛出明确异常——绝不再把坏文件交给系统安装器/压缩包查看器（会导致解析出错）。
  /// [client] 已连接的远程客户端；[remotePath] 远程路径；[fileName] 缓存文件名。
  Future<String> _downloadRemoteFileVerified(
    RemoteClient client,
    String remotePath,
    String fileName,
  ) async {
    final cacheDir = Directory('/storage/emulated/0/ZenFile');
    if (!cacheDir.existsSync()) cacheDir.createSync(recursive: true);
    final cachePath = p.join(cacheDir.path, fileName);

    // 清除可能的残留损坏文件（旧版本的半截下载会让 exists 判断误以为已就绪）
    if (File(cachePath).existsSync()) {
      try {
        await File(cachePath).delete();
      } catch (_) {}
    }

    int? remoteSize;
    try {
      remoteSize = await client.getFileSize(remotePath).timeout(const Duration(seconds: 5));
    } catch (_) {
      remoteSize = null;
    }

    for (int attempt = 0; attempt < 2; attempt++) {
      try {
        await client.downloadFile(remotePath, cachePath, (progress) {});
      } catch (e) {
        debugPrint('远程文件下载失败(尝试${attempt + 1}): $e');
      }
      final f = File(cachePath);
      if (await f.exists()) {
        final sz = await f.length();
        final ok = sz > 0 && (remoteSize == null || remoteSize <= 0 || sz == remoteSize);
        if (ok) return cachePath;
      }
      // 校验失败：删除后重试
      try {
        await File(cachePath).delete();
      } catch (_) {}
    }

    final finalSize = File(cachePath).existsSync() ? await File(cachePath).length() : 0;
    throw Exception('远程文件下载不完整（本地 ${finalSize} 字节'
        '${remoteSize != null && remoteSize! > 0 ? ' / 远程 $remoteSize 字节' : ''}），无法打开');
  }

  Future<void> openWithSystemChooser(String path, {String? mimeType}) async {
    try {
      final mime = mimeType ?? lookupMimeType(path) ?? '*/*';
      await _platformChannel.invokeMethod('openWithChooser', {
        'path': path,
        'mimeType': mime,
      });
    } catch (e) {
      debugPrint('openWithSystemChooser 失败: $e');
    }
  }

  Future<void> openFile(BuildContext context, String path, {bool forceNative = false, bool isRemoteStream = false}) async {
    _highlightedPaths.clear();
    _highlightedPaths.add(path);
    notifyListeners();
    Timer(const Duration(milliseconds: 2000), () {
      if (_highlightedPaths.remove(path)) {
        notifyListeners();
      }
    });

    final ext = p.extension(path).toLowerCase();
    
    String targetPath = path;

    // Remote streaming URL (WebDAV HTTP URL): open directly with isRemote flag
    if (isRemoteStream) {
      final streamExt = p.extension(path).toLowerCase();
      final streamMime = lookupMimeType(streamExt) ?? '';
      if (streamMime.startsWith('video/')) {
        Navigator.push(context, MaterialPageRoute(builder: (_) => VideoPlayerScreen(videoPath: path, isRemote: true)));
      } else if (streamMime.startsWith('audio/')) {
        Navigator.push(context, MaterialPageRoute(builder: (_) => AudioPlayerScreen(audioPath: path, title: p.basenameWithoutExtension(path), isRemote: true)));
      } else {
        await openFileNatively(context, targetPath);
      }
      return;
    }

    // 在远程处理前，提取用于 hasNativeViewer 检查的真实路径（remote:// 需解析出实际文件路径）
    String checkPath = path;
    if (path.startsWith('remote://')) {
      final uriPart = path.substring('remote://'.length);
      final sepIdx = uriPart.indexOf('|');
      if (sepIdx >= 0) checkPath = uriPart.substring(sepIdx + 1);
    }
    final checkExt = p.extension(checkPath).toLowerCase();

    String? openAction;
    if (forceNative) {
      openAction = 'native';
    } else {
      final defaultAction = PreferencesService.getDefaultOpenAction(checkExt);
      if (defaultAction == 'external') {
        openAction = 'external';
      }
    }

    // 处理 remote:// 格式的远程路径（来自自定义快捷方式扫描的媒体文件）
    if (path.startsWith('remote://')) {
      try {
        final uriPart = path.substring('remote://'.length);
        final separatorIndex = uriPart.indexOf('|');
        if (separatorIndex < 0) return;
        final connectionId = uriPart.substring(0, separatorIndex);
        final remotePath = uriPart.substring(separatorIndex + 1);
        final fileName = p.basename(remotePath);
        final fileExt = p.extension(fileName).toLowerCase();
        final fileMime = lookupMimeType(fileExt) ?? '';
        final isVideoFile = fileMime.startsWith('video/');
        final isAudioFile = fileMime.startsWith('audio/');

        final connections = NetworkConnectionsService.getConnections();
        final conn = connections.where((c) => c.id == connectionId).firstOrNull;
        if (conn == null) {
          debugPrint('远程连接未找到: $connectionId');
          return;
        }

        final remoteClient = createRemoteClient(conn);
        await remoteClient.connect();

        // 媒体文件：无论选择"打开"还是"打开方式..."都采用流式播放
        // "打开" → 本应用内置播放器；"打开方式..." → 系统选择器（VLC 等也可流式播放）
        if (isVideoFile || isAudioFile) {
          // 优先尝试直接流式 URL（WebDAV 支持 HTTP 流）
          final streamUrl = remoteClient.getStreamUrl(remotePath);
          if (streamUrl != null) {
            if (openAction == 'external') {
              // 系统选择器打开流式 URL
              await openWithSystemChooser(streamUrl, mimeType: fileMime);
              await remoteClient.disconnect();
              return;
            }
            // WebDAV 流式播放：保持连接直到播放完成（由 GC 清理）
            if (isVideoFile) {
              Navigator.push(context, MaterialPageRoute(builder: (_) => VideoPlayerScreen(videoPath: streamUrl, isRemote: true)));
            } else {
              Navigator.push(context, MaterialPageRoute(builder: (_) => AudioPlayerScreen(audioPath: streamUrl, title: p.basenameWithoutExtension(fileName), isRemote: true)));
            }
            return;
          }

          // 非 HTTP 流协议（FTP/SFTP 等）：通过本地代理服务器
          RemoteClient? seekClient;
          try {
            // 独立连接用于按需随机读取（拖动进度条），与后台顺序下载分开会话，
            // 避免 smbj 单会话并发不安全；代理 dispose 时会断开这两个独立连接，
            // 不影响远程浏览页/标签页的会话。
            seekClient = createRemoteClient(conn);
            await seekClient.connect();
            // 取文件大小以支持可 seek 流式（进度条/拖动进度条所需）。
            int? fileSize;
            try {
              final size = await remoteClient.getFileSize(remotePath)
                  .timeout(const Duration(seconds: 5));
              if (size > 0) fileSize = size;
            } catch (_) {
              fileSize = null;
            }
            final proxyUrl = await RemoteStreamingService.instance.startStreaming(
              remoteClient, remotePath, fileName,
              fileSize: fileSize,
              seekClient: seekClient,
            );
            if (openAction == 'external') {
              // 系统选择器打开代理 URL（VLC 等可流式播放）
              await openWithSystemChooser(proxyUrl, mimeType: fileMime);
              return;
            }
            if (isVideoFile) {
              Navigator.push(context, MaterialPageRoute(builder: (_) => VideoPlayerScreen(videoPath: proxyUrl, isRemote: true)));
            } else {
              Navigator.push(context, MaterialPageRoute(builder: (_) => AudioPlayerScreen(audioPath: proxyUrl, title: p.basenameWithoutExtension(fileName), isRemote: true)));
            }
            return;
          } catch (e) {
            debugPrint('远程流式代理启动失败，回退到下载模式: $e');
            if (seekClient != null) { try { await seekClient.disconnect(); } catch (_) {} }
          }
        }

        // 非媒体文件（MIME 未知）：remote:// 路径无法被系统安装器/压缩包查看器
        // 直接读取，必须先完整下载到本地缓存并校验，再从本地打开。
        if (!isVideoFile && !isAudioFile) {
          try {
            final localPath = await _downloadRemoteFileVerified(
              remoteClient,
              remotePath,
              fileName,
            );
            targetPath = localPath;
            await remoteClient.disconnect();
            if (openAction == 'external') {
              await openWithSystemChooser(
                targetPath,
                mimeType: lookupMimeType(fileExt) ?? '*/*',
              );
            } else {
              await openFileNatively(context, targetPath, showTypePickerForUnknown: true);
            }
            return;
          } catch (e) {
            await remoteClient.disconnect();
            if (context.mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text('打开失败：$e')),
              );
            }
            return;
          }
        }
        await remoteClient.disconnect();
      } catch (e) {
        debugPrint('远程路径文件打开失败: $e');
      }
    }

    // 远程文件：使用流式播放代理服务器实现边缓存边播放
    if (activeTab.isRemote && activeTab.remoteClient != null) {
      try {
        final fileMime = lookupMimeType(ext) ?? '';
        final isVideoFile = fileMime.startsWith('video/');
        final isAudioFile = fileMime.startsWith('audio/');
        final remoteClient = activeTab.remoteClient!;

        // 媒体文件：无论选择"打开"还是"打开方式..."都采用流式播放
        if (isVideoFile || isAudioFile) {
          // 优先尝试直接流式 URL（WebDAV 支持 HTTP 流）
          final streamUrl = remoteClient.getStreamUrl(path);
          if (streamUrl != null) {
            if (openAction == 'external') {
              // 系统选择器打开流式 URL
              await openWithSystemChooser(streamUrl, mimeType: fileMime);
              return;
            }
            // 直接流式播放 — 无需下载
            if (isVideoFile) {
              Navigator.push(context, MaterialPageRoute(builder: (_) => VideoPlayerScreen(videoPath: streamUrl, isRemote: true)));
            } else {
              Navigator.push(context, MaterialPageRoute(builder: (_) => AudioPlayerScreen(audioPath: streamUrl, title: p.basenameWithoutExtension(path), isRemote: true)));
            }
            return;
          }

          // 非 HTTP 流协议（FTP/SFTP 等）：通过本地代理服务器实现边缓存边播放
          RemoteClient? downloadClient;
          RemoteClient? seekClient;
          try {
            // 从当前文件列表获取文件大小，避免 getFileSize 网络调用（可耗 10-15s）
            final fileItem = currentFiles.where((f) => f.path == path).firstOrNull;
            final knownSize = (fileItem != null && fileItem.size > 0) ? fileItem.size : null;
            // 使用独立连接（download + seek 各一）做流式传输，避免播放器关闭时
            // 代理 dispose 断开当前标签页（activeTab）的浏览会话，导致返回后
            // 远程文件列表变空。
            final conn = activeTab.remoteConnection!;
            downloadClient = createRemoteClient(conn);
            await downloadClient.connect();
            seekClient = createRemoteClient(conn);
            await seekClient.connect();
            final proxyUrl = await RemoteStreamingService.instance.startStreaming(
              downloadClient, path, p.basename(path),
              fileSize: knownSize,
              seekClient: seekClient,
            );
            if (openAction == 'external') {
              // 系统选择器打开代理 URL
              await openWithSystemChooser(proxyUrl, mimeType: fileMime);
              return;
            }
            if (isVideoFile) {
              Navigator.push(context, MaterialPageRoute(builder: (_) => VideoPlayerScreen(videoPath: proxyUrl, isRemote: true)));
            } else {
              Navigator.push(context, MaterialPageRoute(builder: (_) => AudioPlayerScreen(audioPath: proxyUrl, title: p.basenameWithoutExtension(path), isRemote: true)));
            }
            return;
          } catch (e) {
            debugPrint('流式代理启动失败，回退到下载模式: $e');
            // 回退前断开已建立的独立连接，避免连接泄漏
            if (downloadClient != null) { try { await downloadClient.disconnect(); } catch (_) {} }
            if (seekClient != null) { try { await seekClient.disconnect(); } catch (_) {} }
          }
        }

        // 非媒体文件（MIME 未知）：先弹「打开方式」让用户选择本应用/外部，
        // 选择完成后再决定流式播放、下载后打开或调用系统选择器。
        // 这样选择「本应用的视频/音频」时可以直接走流式播放，避免先把整个
        // 文件下载到 /storage/emulated/0/ZenFile。
        if (!isVideoFile && !isAudioFile) {
          try {
            final fileName = p.basename(path);
            final fileExt = p.extension(path).toLowerCase();

            // 1) 先弹出「打开方式」（ZenFile 内置 / 外部系统选择器）
            final result = await showModalBottomSheet<String>(
              context: context,
              backgroundColor: Theme.of(context).scaffoldBackgroundColor,
              shape: const RoundedRectangleBorder(
                borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
              ),
              builder: (ctx) => OpenWithSheet(
                fileName: fileName,
                fileExtension: fileExt,
              ),
            );

            if (result == null || !context.mounted) return;

            final isAlways = result.startsWith('always_');
            final selectedType = result.substring(isAlways ? 'always_'.length : 'just_once_'.length);

            if (selectedType == 'external') {
              // 外部应用必须先把文件拿到本地，再交给系统选择器
              if (isAlways) {
                await PreferencesService.saveDefaultOpenAction(fileExt, 'external');
              }
              final localPath = await _downloadRemoteFileVerified(
                remoteClient,
                path,
                fileName,
              );
              if (context.mounted) {
                await openWithSystemChooser(
                  localPath,
                  mimeType: fileMime.isEmpty ? '*/*' : fileMime,
                );
              }
              return;
            }

            // selectedType == 'native'：本应用打开，再让用户选具体类型
            if (isAlways) {
              await PreferencesService.saveDefaultOpenAction(fileExt, 'native');
            }

            final builtInType = await showModalBottomSheet<String>(
              context: context,
              backgroundColor: Theme.of(context).scaffoldBackgroundColor,
              shape: const RoundedRectangleBorder(
                borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
              ),
              builder: (ctx) => PickFileTypeSheet(
                fileName: fileName,
                fileExtension: fileExt,
              ),
            );

            if (builtInType == null || !context.mounted) return;

            if (isAlways) {
              await PreferencesService.saveDefaultOpenAction(fileExt, builtInType);
            }

            // 视频/音频直接流式播放，不下载到本地缓存；其它类型下载后用内置查看器打开
            if (builtInType == 'video' || builtInType == 'audio') {
              await _openBuiltInByType(context, path, builtInType);
              return;
            }

            final localPath = await _downloadRemoteFileVerified(
              remoteClient,
              path,
              fileName,
            );
            if (context.mounted) {
              await _openBuiltInByType(context, localPath, builtInType);
            }
            return;
          } catch (e) {
            debugPrint('远程非媒体文件下载/打开失败: $e');
            if (context.mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text('打开失败：$e')),
              );
            }
            return;
          }
        }
      } catch (e) {
        debugPrint('下载远程文件失败: $e');
      }
    }

    if (isRestrictedPath(path) && !FileUtils.isTextOrCode(path)) {
      try {
        final tempDir = Directory('/storage/emulated/0/.nfile_temp');
        if (!tempDir.existsSync()) {
          tempDir.createSync(recursive: true);
        }
        final tempPath = p.join(tempDir.path, 'temp_restricted_${DateTime.now().millisecondsSinceEpoch}_${p.basename(path)}');
        await RootShizukuService.copyItem(path, tempPath, useRoot: activeTab.useRootMode);
        if (File(tempPath).existsSync()) {
          targetPath = tempPath;
        }
      } catch (e) {
        debugPrint('Error creating temporary copy for restricted file: $e');
      }
    }

    // 默认/弹窗选择了"使用外部系统选择器打开" → 调用系统选择器
    if (openAction == 'external') {
      await openWithSystemChooser(targetPath);
      return;
    }

    // forceNative：来自「打开方式...」选择「本应用打开」，强制用内置查看器打开
    if (forceNative) {
      await openFileNatively(context, targetPath, showTypePickerForUnknown: true);
      return;
    }

    // Universal default action check
    if (hasNativeViewer(targetPath)) {
      final defaultAction = PreferencesService.getDefaultOpenAction(ext);
      if (defaultAction == 'native') {
        await openFileNatively(context, targetPath);
        return;
      } else if (defaultAction == 'external') {
        await openWithSystemChooser(targetPath);
        return;
      } else if (const ['text', 'audio', 'video', 'image'].contains(defaultAction)) {
        // 已保存的具体内置类型：直接以该类型用应用内查看器打开
        await _openBuiltInByType(context, targetPath, defaultAction!);
        return;
      }
    }

    // 默认：使用内置查看器打开
    await openFileNatively(context, targetPath);
  }

  Future<void> moveItem(BuildContext context, String sourcePath, String destFolderPath, {bool showToast = true}) async {
    final name = p.basename(sourcePath);
    final destPath = p.join(destFolderPath, name);

    if (sourcePath == destPath || destFolderPath.startsWith(sourcePath + p.separator)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('无法将文件夹移动到自身或相同位置')),
      );
      return;
    }

    // Ensure destination parent directory exists recursively
    final destDir = Directory(destFolderPath);
    if (!destDir.existsSync()) {
      await destDir.create(recursive: true);
    }

    activeTab.isLoading = true;
    notifyListeners();

    try {
      final isDir = FileSystemEntity.isDirectorySync(sourcePath);
      if (isRestrictedPath(sourcePath) || isRestrictedPath(destFolderPath)) {
        await RootShizukuService.moveItem(sourcePath, destPath, useRoot: activeTab.useRootMode);
      } else {
        if (isDir) {
          final sourceDir = Directory(sourcePath);
          final destDir = Directory(destPath);
          if (!destDir.existsSync()) {
            await destDir.create(recursive: true);
          }
          try {
            await sourceDir.rename(destPath);
          } catch (e) {
            await _copyDirectory(sourceDir, destDir);
            await sourceDir.delete(recursive: true);
          }
        } else {
          final sourceFile = File(sourcePath);
          final destFile = File(destPath);
          try {
            if (destFile.existsSync()) {
              await destFile.delete();
            }
            await sourceFile.rename(destPath);
          } catch (e) {
            await sourceFile.copy(destPath);
            await sourceFile.delete();
          }
        }
      }
      
      // 移动成功后即时裁剪媒体列表，防止分类页残留已移走的文件
      MediaProvider.instance?.pruneDeletedMediaPaths([sourcePath]);

      if (showToast) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('成功移动 $name')),
        );
      }
    } catch (e) {
      debugPrint('Error moving item: $e');
      if (showToast) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('移动项目失败：{e}')),
        );
      }
    }

    // 稍等片刻确保文件系统已更新
    await Future.delayed(const Duration(milliseconds: 500));

    // 刷新目标目录所在的tab
    for (int i = 0; i < _tabs.length; i++) {
      if (_tabs[i].currentPath == destFolderPath) {
        await loadDirectoryForTab(i, destFolderPath, showLoading: false, clearCache: true);
        break;
      }
    }
    // 刷新源目录（如果源目录是当前打开的其他tab）
    final sourceDir = p.dirname(sourcePath);
    if (sourceDir != destFolderPath) {
      for (int i = 0; i < _tabs.length; i++) {
        if (_tabs[i].currentPath == sourceDir) {
          await loadDirectoryForTab(i, sourceDir, showLoading: false, clearCache: true);
          break;
        }
      }
    }
  }

  Future<void> _copyDirectory(Directory source, Directory destination) async {
    await for (var entity in source.list(recursive: false)) {
      if (entity is Directory) {
        final newDirectory = Directory(p.join(destination.absolute.path, p.basename(entity.path)));
        await newDirectory.create();
        await _copyDirectory(entity.absolute, newDirectory);
      } else if (entity is File) {
        await entity.copy(p.join(destination.path, p.basename(entity.path)));
      }
    }
  }

  Future<void> copyItem(BuildContext context, String sourcePath, String destFolderPath, {bool showToast = true}) async {
    final name = p.basename(sourcePath);
    final destPath = p.join(destFolderPath, name);

    if (sourcePath == destPath || destFolderPath.startsWith(sourcePath + p.separator)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('无法将文件夹复制到自身或相同位置')),
      );
      return;
    }

    // Ensure destination parent directory exists recursively
    final destDir = Directory(destFolderPath);
    if (!destDir.existsSync()) {
      await destDir.create(recursive: true);
    }

    activeTab.isLoading = true;
    notifyListeners();

    try {
      final isDir = FileSystemEntity.isDirectorySync(sourcePath);
      if (isRestrictedPath(sourcePath) || isRestrictedPath(destFolderPath)) {
        await RootShizukuService.copyItem(sourcePath, destPath, useRoot: activeTab.useRootMode);
      } else {
        if (isDir) {
          final sourceDir = Directory(sourcePath);
          final destDir = Directory(destPath);
          if (!destDir.existsSync()) {
            await destDir.create(recursive: true);
          }
          await _copyDirectory(sourceDir, destDir);
        } else {
          final sourceFile = File(sourcePath);
          final destFile = File(destPath);
          if (destFile.existsSync()) {
            await destFile.delete();
          }
          await sourceFile.copy(destPath);
        }
      }
      
      if (showToast) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('成功复制 $name')),
        );
      }
    } catch (e) {
      debugPrint('Error copying item: $e');
      if (showToast) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('复制项目失败：{e}')),
        );
      }
    }

    // 稍等片刻确保文件系统已更新
    await Future.delayed(const Duration(milliseconds: 500));

    // 刷新目标目录所在的tab
    for (int i = 0; i < _tabs.length; i++) {
      if (_tabs[i].currentPath == destFolderPath) {
        await loadDirectoryForTab(i, destFolderPath, showLoading: false, clearCache: true);
        break;
      }
    }
  }

  @override
  void dispose() {
    _remoteSourceChangedController.close();
    _navigateToBrowseTabNotifier.dispose();
    super.dispose();
  }

}


/// 后台模式感知的进度通知器。
///
/// 当 [backgroundMode] 为 true（用户点击"后台"后），所有非 null 的进度赋值
/// 都会被忽略，避免进度对话框重新弹出。设置 null 始终生效以关闭对话框。
/// 新传输开始时需将 [backgroundMode] 重置为 false。
class _BackgroundAwareProgressNotifier extends ValueNotifier<FileOperationProgress?> {
  bool backgroundMode = false;

  _BackgroundAwareProgressNotifier() : super(null);

  @override
  set value(FileOperationProgress? newValue) {
    // 后台模式下忽略非 null 赋值；null 始终生效（用于关闭对话框）
    if (backgroundMode && newValue != null) return;
    super.value = newValue;
  }
}


class FileOperationProgress {
  final int totalFiles;
  final int currentFileIndex;
  final String currentFileName;
  final double percentage; // 0.0 to 1.0
  final double speedMBs; // MB/s
  final Duration eta;
  final int totalBytes;
  final int bytesProcessed;

  FileOperationProgress({
    required this.totalFiles,
    required this.currentFileIndex,
    required this.currentFileName,
    required this.percentage,
    required this.speedMBs,
    required this.eta,
    required this.totalBytes,
    required this.bytesProcessed,
  });
}

/// 实时传输速率计算器：基于滑动窗口统计最近一段时间内的字节增量，
/// 输出当前瞬时速率（MB/s），避免原先「累计平均速率」在文件间停顿时
/// 持续衰减、无法反映当前链路实际吞吐的问题。
///
/// 用法：
///   final speed = _TransferSpeedTracker(window: const Duration(seconds: 2));
///   speed.add(bytesDelta);   // 每次有字节完成时调用
///   speed.currentMBs();      // 取当前瞬时速率
class _TransferSpeedTracker {
  _TransferSpeedTracker({this.window = const Duration(seconds: 2)});

  final Duration window;
  /// Queue 替代 List：removeFirst() 是 O(1)，避免 removeAt(0) 的 O(n) 开销。
  final Queue<_Sample> _samples = Queue();
  int _totalBytes = 0;
  /// 窗口内有效字节累计，替代 currentMBs() 中的 O(n) fold 遍历。
  int _windowBytes = 0;

  void add(int bytesDelta) {
    if (bytesDelta <= 0) return;
    final now = DateTime.now();
    _samples.addLast(_Sample(now, bytesDelta));
    _totalBytes += bytesDelta;
    _windowBytes += bytesDelta;
    _evict(now);
  }

  /// 当前瞬时速率（MB/s）。窗口内无样本时返回 0。
  double currentMBs() {
    final now = DateTime.now();
    _evict(now);
    if (_windowBytes <= 0) return 0.0;
    final windowSeconds = window.inMilliseconds / 1000.0;
    if (windowSeconds <= 0) return 0.0;
    return (_windowBytes / (1024 * 1024)) / windowSeconds;
  }

  /// 累计已传输字节数（用于 ETA 的剩余字节计算）。
  int get totalBytes => _totalBytes;

  void _evict(DateTime now) {
    final cutoff = now.subtract(window);
    while (_samples.isNotEmpty && _samples.first.time.isBefore(cutoff)) {
      final removed = _samples.removeFirst();
      _windowBytes -= removed.bytes;
    }
  }
}

class _Sample {
  final DateTime time;
  final int bytes;
  _Sample(this.time, this.bytes);
}

// ===================== 分类同步辅助类型（顶层，供 FileManagerProvider 与 UI 共用） =====================

class _ParsedRemotePath {
  final String connectionId;
  final String remotePath;
  _ParsedRemotePath({required this.connectionId, required this.remotePath});
}

/// 分类同步方向。
enum SyncDirection { localToRemote, remoteToLocal, bidirectional }

/// 一个同步单元：把本地目录 [localDir] 与远程目标目录 [remoteTargetPath] 互相同步。
/// [remoteTargetPath] 形如 `remote://{connectionId}|{serverPath}`。
class CategorySyncPair {
  /// 本地基准目录（相对路径基准 / 远程→本地下载落地目录）。
  final String localDir;
  /// 需要同步的实际本地分类文件路径列表（仅这些文件，而非整文件夹）。
  final List<String> localFiles;
  /// 远程基准路径，形如 `remote://{connectionId}|{serverPath}`。
  final String remoteTargetPath;
  const CategorySyncPair({
    required this.localDir,
    required this.localFiles,
    required this.remoteTargetPath,
  });
}

/// 同步结果。
class CategorySyncResult {
  /// 本次同步覆盖（含跳过未变）的本地文件路径列表（用于云徽刷新）。
  final List<String> syncedLocalPaths;
  final int transferredUnits;
  final int syncedCount;
  const CategorySyncResult({
    this.syncedLocalPaths = const [],
    this.transferredUnits = 0,
    this.syncedCount = 0,
  });
}
