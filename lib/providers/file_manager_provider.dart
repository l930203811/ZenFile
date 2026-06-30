import 'package:zenfile/l10n/generated/app_localizations.dart';

import 'dart:io';
import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import '../models/file_item_model.dart';
import '../models/folder_tab_model.dart';
import '../models/file_filter_type.dart';
import 'package:mime/mime.dart';
import 'package:open_filex/open_filex.dart';
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
import '../models/custom_shortcut_model.dart';
import '../services/root_shizuku_service.dart';
import '../services/recycle_bin_service.dart';
import 'package:on_audio_query/on_audio_query.dart';
import '../ui/widgets/open_with_sheet.dart';
import '../ui/widgets/conflict_dialog.dart';
import '../ui/widgets/file_action_dialogs.dart';
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
import '../services/remote/saf_client.dart';

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

class FileManagerProvider extends ChangeNotifier {
  FileManagerProvider() {
    _sortType = PreferencesService.getSortType();
    _isGridView = PreferencesService.getIsGridView();
    _iconScale = PreferencesService.getIconScale();
    _itemPaddingMultiplier = PreferencesService.getItemPaddingMultiplier();
    _showHiddenFiles = PreferencesService.getShowHiddenFiles();
    _showFloatingAddButton = PreferencesService.getShowFloatingAddButton();
    _defaultToBrowseScreen = PreferencesService.getDefaultToBrowseScreen();
    _enableDualFingerSwipe = false; // deprecated, use _swipeMode
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
    _activeAppIcon = PreferencesService.getActiveAppIcon();
    _hideActionText = PreferencesService.getHideActionText();
    _disableLeftBackGesture = PreferencesService.getDisableLeftBackGesture();
    _rememberLastFolder = PreferencesService.getRememberLastFolder();
    _hideNavLabels = PreferencesService.getHideNavLabels();
    _trailingInfoType = PreferencesService.getTrailingInfoType();
    _categoryIconShape = PreferencesService.getCategoryIconShape();

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
      _storageVolumes = [];
    }
  }

  final ValueNotifier<FileOperationProgress?> progressNotifier = ValueNotifier<FileOperationProgress?>(null);
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
  }

  List<CustomShortcutModel> _pinnedFolderShortcuts = [];
  List<CustomShortcutModel> get pinnedFolderShortcuts => _pinnedFolderShortcuts;

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

    String alias = 'com.sequl.zenfile.MainActivityDefault';
    switch (val) {
      case 'design1':
        alias = 'com.sequl.zenfile.MainActivityDesign1';
      case 'design2':
        alias = 'com.sequl.zenfile.MainActivityDesign2';
      case 'design3':
        alias = 'com.sequl.zenfile.MainActivityDesign3';
      case 'design4':
        alias = 'com.sequl.zenfile.MainActivityDesign4';
      case 'design5':
        alias = 'com.sequl.zenfile.MainActivityDesign5';
      case 'design6':
        alias = 'com.sequl.zenfile.MainActivityDesign6';
      case 'design7':
        alias = 'com.sequl.zenfile.MainActivityDesign7';
      case 'design8':
        alias = 'com.sequl.zenfile.MainActivityDesign8';
      case 'design9':
        alias = 'com.sequl.zenfile.MainActivityDesign9';
      case 'design10':
        alias = 'com.sequl.zenfile.MainActivityDesign10';
    }

    await AppManagerService.changeAppIcon(alias);
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
      final folders = currentFiles.where((e) => e.isDirectory).toList();
      final files = currentFiles.where((e) => !e.isDirectory).toList();
      _sortList(folders, path);
      _sortList(files, path);
      activeTab.currentFiles = [...folders, ...files];
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

  bool _enableDualFingerSwipe = false; // deprecated, use swipeMode
  bool get enableDualFingerSwipe => _swipeMode == 'dual';

  // 滑动切换页面模式：'single' 或 'dual'
  String _swipeMode = 'single';
  String get swipeMode => _swipeMode;
  bool get enableSingleFingerSwipe => _swipeMode == 'single';

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

  Future<int> getFolderItemCount(String folderPath) async {
    if (_folderItemCounts.containsKey(folderPath)) {
      return _folderItemCounts[folderPath]!;
    }

    int count = 0;
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

    _folderItemCounts[folderPath] = count;
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

  bool _skipOpenWithDialog = true;
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

  bool _hideActionMenuButtons = false;
  bool get hideActionMenuButtons => _hideActionMenuButtons;

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

  void toggleSplitScreen() {
    _enableSplitScreen = !_enableSplitScreen;
    PreferencesService.saveEnableSplitScreen(_enableSplitScreen);
    
    if (_enableSplitScreen) {
      if (_tabs.length < 2) {
        final initialPath = _rootPath.isNotEmpty ? _rootPath : '/';
        final newTab = FolderTab(
          id: DateTime.now().millisecondsSinceEpoch.toString(),
          currentPath: initialPath,
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

  Future<void> loadDirectoryForTab(int tabIndex, String path, {bool showLoading = true, bool clearCache = false}) async {
    if (tabIndex >= 0 && tabIndex < _tabs.length) {
      final oldIndex = _activeTabIndex;
      _activeTabIndex = tabIndex;
      await loadDirectory(path, showLoading: showLoading, clearCache: clearCache);
      _activeTabIndex = oldIndex;
      notifyListeners();
    }
  }

  // --- Tab Management ---
  List<FolderTab> _tabs = [];
  int _activeTabIndex = 0;

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
  void openRemoteTab(RemoteClient client, NetworkConnectionModel connection) {
    // Close any existing remote tabs first to avoid stale state
    _tabs.removeWhere((t) => t.isRemote);

    final newTab = FolderTab(
      id: 'remote_${connection.name}_${DateTime.now().millisecondsSinceEpoch}',
      currentPath: connection.rootPath,
      isRemote: true,
      remoteClient: client,
      remoteConnection: connection,
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
    loadDirectory(connection.rootPath);
  }

  /// Factory: create the correct RemoteClient subclass for a connection model.
  static RemoteClient createRemoteClient(NetworkConnectionModel conn) {
    switch (conn.type) {
      case 'FTP':
        return FtpRemoteClient(host: conn.host, port: conn.port, username: conn.username, password: conn.password);
      case 'SFTP':
        return SftpRemoteClient(host: conn.host, port: conn.port, username: conn.username, password: conn.password);
      case 'WebDav':
        return WebDavRemoteClient(
          host: conn.host, port: conn.port, username: conn.username, password: conn.password,
          protocol: conn.protocol, rootPath: conn.rootPath,
        );
      case '局域网/SMB':
        return LanClient(host: conn.host, port: conn.port, username: conn.username, password: conn.password);
      case 'saf':
        return SafRemoteClient(rootUri: conn.rootPath);
      default:
        throw ArgumentError('Unsupported connection type: ${conn.type}');
    }
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
      isPinned: active.isPinned,
      isRemote: active.isRemote,
      remoteClient: active.remoteClient,
      remoteConnection: active.remoteConnection,
    );
    _tabs.add(dup);
    _activeTabIndex = _tabs.length - 1;
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
  List<FileItemModel> get currentFiles => activeTab.currentFiles;
  String get currentPath => activeTab.currentPath;
  bool get isLoading => activeTab.isLoading;
  bool get isRestrictedMode => activeTab.isRestrictedMode;
  bool get needsPermission => activeTab.needsPermission;
  bool get useRootMode => activeTab.useRootMode;
  bool get useShizukuMode => activeTab.useShizukuMode;
  bool get isRootAvailable => activeTab.isRootAvailable;
  Set<String> get selectedPaths => activeTab.selectedPaths;
  bool get isSelectionMode => selectedPaths.isNotEmpty;

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

  String _rootPath = '';
  String get rootPath => _rootPath;

  // 路径历史栈，用于支持前进/后退导航
  final List<String> _pathHistory = [];
  int _historyIndex = -1;

  bool get canGoBack {
    final path = currentPath;
    if (path.isEmpty || _rootPath.isEmpty) return false;
    if (path == _rootPath || path == '/' || p.dirname(path) == path) {
      return false;
    }
    return true;
  }

  bool get canGoForward => _historyIndex >= 0 && _historyIndex < _pathHistory.length - 1;

  void _pushPathToHistory(String path) {
    // 如果当前不是历史栈的最后一个，截断后面的历史
    if (_historyIndex < _pathHistory.length - 1) {
      _pathHistory.removeRange(_historyIndex + 1, _pathHistory.length);
    }
    // 如果路径与当前最后一个不同，才添加
    if (_pathHistory.isEmpty || _pathHistory.last != path) {
      _pathHistory.add(path);
      _historyIndex = _pathHistory.length - 1;
    }
  }

  Future<bool> goBack() async {
    if (!canGoBack) return false;
    final exitedPath = currentPath;
    final parent = p.dirname(currentPath);
    _pushPathToHistory(exitedPath);
    // 回退历史索引，使 goForward 可以返回到 exitedPath
    if (_historyIndex > 0) {
      _historyIndex--;
    }
    await loadDirectory(parent, showLoading: false, recordHistory: false);
    _highlightedPaths.clear();
    _highlightedPaths.add(exitedPath);
    notifyListeners();
    Timer(const Duration(milliseconds: 2000), () {
      if (_highlightedPaths.remove(exitedPath)) {
        notifyListeners();
      }
    });
    return true;
  }

  Future<bool> goForward() async {
    if (!canGoForward) return false;
    _historyIndex++;
    final nextPath = _pathHistory[_historyIndex];
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
    _rootPath = path;
    if (_tabs.isNotEmpty) {
      activeTab.currentPath = path;
    }
    notifyListeners();
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
    
    // Initialize primary default tab
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
        // Keep only pinned tabs
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

      if (_enableSplitScreen && _tabs.length < 2) {
        while (_tabs.length < 2) {
          _tabs.add(FolderTab(
            id: (DateTime.now().millisecondsSinceEpoch + _tabs.length).toString(),
            currentPath: initialPath,
          ));
        }
      }
      _activeTabIndex = 0;
    } else {
      _tabs = [
        FolderTab(
          id: DateTime.now().millisecondsSinceEpoch.toString(),
          currentPath: initialPath,
        )
      ];
      if (_enableSplitScreen) {
        _tabs.add(FolderTab(
          id: (DateTime.now().millisecondsSinceEpoch + 1).toString(),
          currentPath: initialPath,
        ));
      }
      _activeTabIndex = 0;
    }

    await _detectStorageVolumes();
    final path0 = _tabs.isNotEmpty ? _tabs[0].currentPath : initialPath;
    await loadDirectory(path0, showLoading: false);
    if (_enableSplitScreen) {
      final path1 = _tabs.length > 1 ? _tabs[1].currentPath : initialPath;
      await loadDirectoryForTab(1, path1, showLoading: false);
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

  Future<void> loadDirectory(String path, {bool showLoading = true, bool clearCache = false, bool recordHistory = true}) async {
    // ── Remote branch ──
    if (activeTab.isRemote && activeTab.remoteClient != null) {
      if (showLoading) {
        activeTab.isLoading = true;
        notifyListeners();
      }
      try {
        activeTab.currentPath = path;
        final remoteItems = await activeTab.remoteClient!.listDirectory(path);
        remoteItems.sort((a, b) {
          if (a.isDirectory && !b.isDirectory) return -1;
          if (!a.isDirectory && b.isDirectory) return 1;
          return a.name.toLowerCase().compareTo(b.name.toLowerCase());
        });
        activeTab.currentFiles = remoteItems
            .map((r) => FileItemModel.fromRemoteFileItem(r))
            .toList();
      } catch (e) {
        debugPrint('Error loading remote directory: $e');
        activeTab.currentFiles = [];
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
    // 记录路径到历史栈
    if (recordHistory && currentPath.isNotEmpty && currentPath != path) {
      _pushPathToHistory(currentPath);
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
      if (status.isRootAvailable && (activeTab.useRootMode || !status.isShizukuAvailable)) {
        activeTab.useRootMode = true;
        activeTab.useShizukuMode = false;
        activeTab.needsPermission = false;
      } else if (status.isShizukuAvailable && status.shizukuPermissionGranted) {
        activeTab.useShizukuMode = true;
        activeTab.useRootMode = false;
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
      if (status.isRootAvailable && (activeTab.useRootMode || !status.isShizukuAvailable)) {
        activeTab.useRootMode = true;
        activeTab.useShizukuMode = false;
        activeTab.needsPermission = false;
      } else if (status.isShizukuAvailable && status.shizukuPermissionGranted) {
        activeTab.useShizukuMode = true;
        activeTab.useRootMode = false;
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

  void copyFile(String path) {
    if (currIsRemote) {
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

    activeTab.isLoading = true;
    notifyListeners();

    try {
      if (activeTab.isRemote && activeTab.remoteClient != null) {
        final client = activeTab.remoteClient!;
        for (final path in selectedPaths) {
          final file = currentFiles.firstWhere((f) => f.path == path, orElse: () => currentFiles.first);
          final remotePath = file.remoteSource?.path ?? path;
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
    }

    selectedPaths.clear();
    activeTab.isLoading = false;
    await loadDirectory(currentPath, showLoading: false, clearCache: true);
  }

  Future<void> pasteFile(BuildContext context, {bool clearAfterPaste = true}) async {
    await _pasteFileToTab(context, _activeTabIndex, clearAfterPaste: clearAfterPaste);
  }

  Future<void> pasteFileToTab(BuildContext context, int targetTabIndex, {bool clearAfterPaste = true}) async {
    await _pasteFileToTab(context, targetTabIndex, clearAfterPaste: clearAfterPaste);
  }

  Future<void> _pasteFileToTab(BuildContext context, int targetTabIndex, {bool clearAfterPaste = true}) async {
    if (_clipboardPaths.isEmpty && !_isRemoteClipboard) return;
    if (targetTabIndex < 0 || targetTabIndex >= _tabs.length) return;

    final oldIndex = _activeTabIndex;
    _activeTabIndex = targetTabIndex;

    // 在清除剪贴板之前保存源目录路径，用于后续刷新
    final String? savedSourcePath = _isCut && _clipboardPaths.isNotEmpty
        ? _clipboardPaths.first
        : null;

    try {
      if (_isRemoteClipboard) {
        // 远程剪贴板粘贴到远程目录：先下载到本地临时目录，再上传到目标远程
        if (currIsRemote && activeTab.remoteClient != null) {
          await _pasteRemoteToRemote(context, clearAfterPaste);
        } else {
          await _pasteFromRemoteToLocal(context, clearAfterPaste);
        }
        return;
      }

      // 本地剪贴板粘贴到远程目录
      if (currIsRemote && activeTab.remoteClient != null) {
        await _pasteLocalToRemote(context, clearAfterPaste);
        return;
      }

      _isOperationCancelled = false;
      activeTab.isLoading = true;
      notifyListeners();

    final useRootMode = activeTab.useRootMode;
    if (isRestrictedPath(currentPath) || _clipboardPaths.any((p) => isRestrictedPath(p))) {
      try {
        for (final srcPath in _clipboardPaths) {
          final name = p.basename(srcPath);
          final destPath = p.join(currentPath, name);
          if (_isCut) {
            await RootShizukuService.moveItem(srcPath, destPath, useRoot: useRootMode);
          } else {
            await RootShizukuService.copyItem(srcPath, destPath, useRoot: useRootMode);
          }
        }
        
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(_isCut ? '成功移动项目' : '成功复制项目'),
              behavior: SnackBarBehavior.floating,
            ),
          );
        }
      } catch (e) {
        debugPrint('Error pasting inside restricted directory: $e');
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('传输失败：{e}'),
              backgroundColor: Colors.redAccent,
              behavior: SnackBarBehavior.floating,
            ),
          );
        }
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

      for (final srcPath in _clipboardPaths) {
        final type = FileSystemEntity.typeSync(srcPath);
        final isSameFolder = p.dirname(srcPath) == currentPath;

        if (isSameFolder && _isCut) {
          if (context.mounted) {
            await FileActionDialogs.showWarningDialog(
              context,
              title: '操作已取消',
              content: 'Cannot cut and paste a file into the same folder.',
            );
          }
          clearClipboard();
          activeTab.isLoading = false;
          notifyListeners();
          return;
        }

        if (type == FileSystemEntityType.file) {
          final file = File(srcPath);
          final size = file.lengthSync();
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
          });

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
              await srcFile.delete();
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
        for (final srcPath in _clipboardPaths) {
          final type = FileSystemEntity.typeSync(srcPath);
          if (type == FileSystemEntityType.directory) {
            final dir = Directory(srcPath);
            if (dir.existsSync()) {
              await dir.delete(recursive: true);
            }
          }
        }
      }

      if (_isCut && _sourceArchiveForCut != null && _internalSourcePathsForCut != null) {
        await ArchiveService.deleteItemsFromArchive(
          archivePath: _sourceArchiveForCut!,
          internalPathsToDelete: _internalSourcePathsForCut!,
        );
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
    _activeTabIndex = oldIndex;
  }
}

  Future<void> _pasteFromRemoteToLocal(BuildContext context, bool clearAfterPaste) async {
    final conn = _remoteClipboardConnection;
    if (conn == null) {
      return;
    }

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
    } else if (conn.type == '局域网/SMB') {
      client = LanClient(host: conn.host, port: conn.port, username: conn.username, password: conn.password);
    } else if (conn.type == 'saf') {
      client = SafRemoteClient(rootUri: conn.rootPath);
    }

    if (client == null) {
      _isPasting = false;
      return;
    }

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
      final totalFiles = _remoteClipboardItems.length;

      // 计算总字节数用于精确进度跟踪
      int totalBytes = 0;
      for (final item in _remoteClipboardItems) {
        if (!item.isDirectory && item.size > 0) {
          totalBytes += item.size;
        }
      }
      final useByteProgress = totalBytes > 0;

      progressNotifier.value = FileOperationProgress(
        totalFiles: totalFiles,
        currentFileIndex: 1,
        currentFileName: 'Connecting...',
        percentage: 0.0,
        speedMBs: 0.0,
        eta: Duration.zero,
        totalBytes: useByteProgress ? totalBytes : totalFiles,
        bytesProcessed: 0,
      );

      final targetPath = currentPath;
      int bytesProcessedTotal = 0;
      final stopwatch = Stopwatch()..start();

      for (int i = 0; i < _remoteClipboardItems.length; i++) {
        if (_isOperationCancelled) {
          throw Exception('Cancelled');
        }

        final remoteItem = _remoteClipboardItems[i];
        final destPath = p.join(targetPath, remoteItem.name);

        if (useByteProgress) {
          final itemSize = remoteItem.size > 0 ? remoteItem.size : 0;
          progressNotifier.value = FileOperationProgress(
            totalFiles: totalFiles,
            currentFileIndex: i + 1,
            currentFileName: remoteItem.name,
            percentage: totalBytes > 0 ? bytesProcessedTotal / totalBytes : (i / totalFiles),
            speedMBs: 0.0,
            eta: Duration.zero,
            totalBytes: totalBytes,
            bytesProcessed: bytesProcessedTotal,
          );
        } else {
          progressNotifier.value = FileOperationProgress(
            totalFiles: totalFiles,
            currentFileIndex: i + 1,
            currentFileName: remoteItem.name,
            percentage: (i / totalFiles),
            speedMBs: 0.0,
            eta: Duration.zero,
            totalBytes: totalFiles,
            bytesProcessed: i,
          );
        }

        if (remoteItem.isDirectory) {
          await _downloadRemoteDirectory(client, remoteItem.path, destPath);
        } else {
          await client.downloadFile(remoteItem.path, destPath, (prog) {
            if (useByteProgress && remoteItem.size > 0) {
              final currentBytes = (prog * remoteItem.size).toInt();
              final totalProcessed = bytesProcessedTotal + currentBytes;
              final elapsedSeconds = stopwatch.elapsed.inMilliseconds / 1000.0;
              final speed = elapsedSeconds > 0 ? (totalProcessed / (1024 * 1024)) / elapsedSeconds : 0.0;
              final remainingBytes = totalBytes - totalProcessed;
              final etaSeconds = speed > 0 ? (remainingBytes / (1024 * 1024)) / speed : 0.0;

              progressNotifier.value = FileOperationProgress(
                totalFiles: totalFiles,
                currentFileIndex: i + 1,
                currentFileName: remoteItem.name,
                percentage: totalBytes > 0 ? totalProcessed / totalBytes : 0.0,
                speedMBs: speed,
                eta: Duration(seconds: etaSeconds.round()),
                totalBytes: totalBytes,
                bytesProcessed: totalProcessed,
              );
            } else {
              progressNotifier.value = FileOperationProgress(
                totalFiles: totalFiles,
                currentFileIndex: i + 1,
                currentFileName: remoteItem.name,
                percentage: (i + prog) / totalFiles,
                speedMBs: 0.0,
                eta: Duration.zero,
                totalBytes: totalFiles,
                bytesProcessed: i,
              );
            }
          });
          // 下载完成后累加字节数
          if (remoteItem.size > 0) {
            bytesProcessedTotal += remoteItem.size;
          }
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
            content: Text(e.toString().contains('Cancelled') ? '操作已取消' : '传输失败：{e}'),
            backgroundColor: e.toString().contains('Cancelled') ? null : Colors.redAccent,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } finally {
      try {
        await client.disconnect();
      } catch (_) {}
      progressNotifier.value = null;
      if (clearAfterPaste) {
        clearClipboard();
      }
      activeTab.isLoading = false;
      await loadDirectory(currentPath, showLoading: false, clearCache: true);
      // 如果是剪切操作，刷新远程源目录所在的tab
      if (_isCut && _remoteClipboardItems.isNotEmpty) {
        final sourceDir = p.dirname(_remoteClipboardItems.first.path);
        for (int i = 0; i < _tabs.length; i++) {
          if (_tabs[i].isRemote && _tabs[i].currentPath == sourceDir) {
            try {
              final tabClient = createRemoteClient(_tabs[i].remoteConnection!);
              await tabClient.connect();
              _tabs[i].remoteClient = tabClient;
              await loadDirectoryForTab(i, sourceDir, showLoading: false, clearCache: true);
            } catch (e) {
              debugPrint('Failed to refresh remote source tab: $e');
            }
            break;
          }
        }
      }
      notifyListeners();
    }
  }

  Future<void> _pasteLocalToRemote(BuildContext context, bool clearAfterPaste) async {
    final client = activeTab.remoteClient;
    if (client == null) return;

    _isOperationCancelled = false;
    _isPasting = true;
    activeTab.isLoading = true;
    notifyListeners();

    try {
      final totalFiles = _clipboardPaths.length;
      ConflictResult? cachedResolution;
      for (int i = 0; i < _clipboardPaths.length; i++) {
        if (_isOperationCancelled) throw Exception('Cancelled');

        final srcPath = _clipboardPaths[i];
        final name = p.basename(srcPath);
        String destPath = _buildRemotePath(currentPath, name);
        final isDir = FileSystemEntity.typeSync(srcPath) == FileSystemEntityType.directory;

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

        progressNotifier.value = FileOperationProgress(
          totalFiles: totalFiles,
          currentFileIndex: i + 1,
          currentFileName: name,
          percentage: i / totalFiles,
          speedMBs: 0.0,
          eta: Duration.zero,
          totalBytes: totalFiles,
          bytesProcessed: i,
        );

        if (isDir) {
          await _uploadLocalDirectory(client, srcPath, destPath);
        } else {
          await client.uploadFile(srcPath, destPath, (prog) {
            progressNotifier.value = FileOperationProgress(
              totalFiles: totalFiles,
              currentFileIndex: i + 1,
              currentFileName: name,
              percentage: (i + prog) / totalFiles,
              speedMBs: 0.0,
              eta: Duration.zero,
              totalBytes: totalFiles,
              bytesProcessed: i,
            );
          });
        }

        if (_isCut) {
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
    } catch (e) {
      debugPrint('Error pasting local to remote: $e');
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(e.toString().contains('Cancelled') ? '操作已取消' : '传输失败：{e}'),
            backgroundColor: e.toString().contains('Cancelled') ? null : Colors.redAccent,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } finally {
      progressNotifier.value = null;
      if (clearAfterPaste) clearClipboard();
      await loadDirectory(currentPath, showLoading: false, clearCache: true);
      // 如果是剪切操作，刷新本地源目录
      if (_isCut && _clipboardPaths.isNotEmpty) {
        final sourceDir = p.dirname(_clipboardPaths.first);
        for (int i = 0; i < _tabs.length; i++) {
          if (!_tabs[i].isRemote && _tabs[i].currentPath == sourceDir) {
            await loadDirectoryForTab(i, sourceDir, showLoading: false, clearCache: true);
            break;
          }
        }
      }
      activeTab.isLoading = false;
      _isPasting = false;
      notifyListeners();
    }
  }

  Future<void> _pasteRemoteToRemote(BuildContext context, bool clearAfterPaste) async {
    final sourceClient = await _createRemoteClient(_remoteClipboardConnection!);
    final targetClient = activeTab.remoteClient;
    if (sourceClient == null || targetClient == null) return;

    _isOperationCancelled = false;
    _isPasting = true;
    activeTab.isLoading = true;
    notifyListeners();

    final tempDir = Directory('/storage/emulated/0/Download/ZenFile_Remote/.temp_${DateTime.now().millisecondsSinceEpoch}');
    if (!tempDir.existsSync()) tempDir.createSync(recursive: true);

    try {
      await sourceClient.connect();
      final totalFiles = _remoteClipboardItems.length;
      ConflictResult? cachedResolution;

      for (int i = 0; i < _remoteClipboardItems.length; i++) {
        if (_isOperationCancelled) throw Exception('Cancelled');

        final remoteItem = _remoteClipboardItems[i];
        final tempPath = p.join(tempDir.path, remoteItem.name);
        String destPath = _buildRemotePath(currentPath, remoteItem.name);

        // Check conflict with existing remote files
        final destExists = activeTab.currentFiles.any((f) => f.name == remoteItem.name);
        if (destExists) {
          ConflictResult? resolution = cachedResolution;
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

        progressNotifier.value = FileOperationProgress(
          totalFiles: totalFiles,
          currentFileIndex: i + 1,
          currentFileName: remoteItem.name,
          percentage: i / totalFiles,
          speedMBs: 0.0,
          eta: Duration.zero,
          totalBytes: totalFiles,
          bytesProcessed: i,
        );

        // Step 1: Download from source remote to local temp
        if (remoteItem.isDirectory) {
          await _downloadRemoteDirectory(sourceClient, remoteItem.path, tempPath);
          // Step 2: Upload from local temp to target remote
          await _uploadLocalDirectory(targetClient, tempPath, destPath);
        } else {
          await sourceClient.downloadFile(remoteItem.path, tempPath, (prog) {
            progressNotifier.value = FileOperationProgress(
              totalFiles: totalFiles,
              currentFileIndex: i + 1,
              currentFileName: remoteItem.name,
              percentage: (i + prog * 0.5) / totalFiles, // download is 50% of the operation
              speedMBs: 0.0,
              eta: Duration.zero,
              totalBytes: totalFiles,
              bytesProcessed: i,
            );
          });
          await targetClient.uploadFile(tempPath, destPath, (prog) {
            progressNotifier.value = FileOperationProgress(
              totalFiles: totalFiles,
              currentFileIndex: i + 1,
              currentFileName: remoteItem.name,
              percentage: (i + 0.5 + prog * 0.5) / totalFiles, // upload is the other 50%
              speedMBs: 0.0,
              eta: Duration.zero,
              totalBytes: totalFiles,
              bytesProcessed: i,
            );
          });
        }

        // Step 3: Delete source if cut
        if (_isCut) {
          try {
            await sourceClient.delete(remoteItem.path, remoteItem.isDirectory);
          } catch (e) {
            debugPrint('Failed to delete remote source item after cut: $e');
          }
        }
      }

      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(_isCut ? '成功移动项目' : '成功复制项目'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } catch (e) {
      debugPrint('Error pasting remote to remote: $e');
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(e.toString().contains('Cancelled') ? '操作已取消' : '传输失败：{e}'),
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
      await loadDirectory(currentPath, showLoading: false, clearCache: true);
      // Refresh source tab if cut
      if (_isCut && _remoteClipboardItems.isNotEmpty) {
        final sourceDir = p.dirname(_remoteClipboardItems.first.path);
        for (int i = 0; i < _tabs.length; i++) {
          if (_tabs[i].isRemote && _tabs[i].currentPath == sourceDir) {
            try {
              final tabClient = createRemoteClient(_tabs[i].remoteConnection!);
              await tabClient.connect();
              _tabs[i].remoteClient = tabClient;
              await loadDirectoryForTab(i, sourceDir, showLoading: false, clearCache: true);
            } catch (e) {
              debugPrint('Failed to refresh remote source tab: $e');
            }
            break;
          }
        }
      }
      activeTab.isLoading = false;
      _isPasting = false;
      notifyListeners();
    }
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
    } else if (conn.type == '局域网/SMB') {
      return LanClient(host: conn.host, port: conn.port, username: conn.username, password: conn.password);
    } else if (conn.type == 'saf') {
      return SafRemoteClient(rootUri: conn.rootPath);
    }
    return null;
  }

  Future<void> _uploadLocalDirectory(RemoteClient client, String localDirPath, String remoteDirPath) async {
    await client.createDirectory(remoteDirPath);
    final localDir = Directory(localDirPath);
    final items = localDir.listSync();
    for (final item in items) {
      if (_isOperationCancelled) throw Exception('Cancelled');
      final name = p.basename(item.path);
      final remotePath = _buildRemotePath(remoteDirPath, name);
      if (item is Directory) {
        await _uploadLocalDirectory(client, item.path, remotePath);
      } else if (item is File) {
        await client.uploadFile(item.path, remotePath, (_) {});
      }
    }
  }

  Future<void> _downloadRemoteDirectory(RemoteClient client, String remoteDirPath, String localDirPath) async {
    final localDir = Directory(localDirPath);
    if (!localDir.existsSync()) {
      localDir.createSync(recursive: true);
    }

    final List<RemoteFileItem> remoteItems = await client.listDirectory(remoteDirPath);
    for (final item in remoteItems) {
      if (_isOperationCancelled) {
        throw Exception('Cancelled');
      }
      final destPath = p.join(localDirPath, item.name);
      if (item.isDirectory) {
        await _downloadRemoteDirectory(client, item.path, destPath);
      } else {
        await client.downloadFile(item.path, destPath, (prog) {});
      }
    }
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
    final hasRemoteSource = file?.remoteSource != null;

    // If the file has a remote source, delete from the remote server
    if (hasRemoteSource && activeTab.isRemote && activeTab.remoteClient != null) {
      final remoteClient = activeTab.remoteClient!;
      final remotePath = file!.remoteSource!.path;
      try {
        await remoteClient.delete(remotePath, file.isDirectory);
        await loadDirectory(currentPath, showLoading: false, clearCache: true);
      } catch (e) {
        debugPrint('Error deleting remote file: $e');
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
    } catch (e) {
      debugPrint('Error deleting file: $e');
    }
  }

  Future<void> renameFile(String oldPath, String newName) async {
    try {
      if (activeTab.isRemote && activeTab.remoteClient != null) {
        final newPath = '${p.url.dirname(oldPath)}/$newName';
        await activeTab.remoteClient!.rename(oldPath, newPath);
      } else if (isRestrictedPath(oldPath)) {
        await RootShizukuService.renameItem(oldPath, newName, useRoot: useRootMode);
      } else {
        final newPath = p.join(p.dirname(oldPath), newName);
        final type = FileSystemEntity.typeSync(oldPath);
        if (type == FileSystemEntityType.directory) {
          await Directory(oldPath).rename(newPath);
        } else {
          await File(oldPath).rename(newPath);
        }
      }
      await loadDirectory(currentPath, showLoading: false, clearCache: true);
    } catch (e) {
      debugPrint('Error renaming file: $e');
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

    activeTab.isLoading = true;
    notifyListeners();

    if (context != null && context.mounted) {
      selectedPaths.clear();
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
    // 默认解压到当前浏览目录
    final currentDir = currentPath;
    final res = await ExtractArchiveDialog.show(
      context,
      archiveName: p.basename(path),
      currentDir: currentDir,
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

  Future<void> openFileNatively(BuildContext context, String path) async {
    final mimeType = lookupMimeType(path) ?? '';
    final ext = p.extension(path).toLowerCase();
    const docExts = ['.pdf', '.doc', '.docx', '.xls', '.xlsx', '.ppt', '.pptx', '.epub', '.odt'];

    if (FileUtils.isArchive(path)) {
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => ArchiveViewerScreen(archivePath: path),
        ),
      );
      return;
    }

    if (mimeType.startsWith('image/')) {
      Navigator.push(context, MaterialPageRoute(builder: (_) => ImageViewerScreen(imagePath: path)));
    } else if (mimeType.startsWith('video/')) {
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
    } else if (mimeType.startsWith('audio/')) {
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
            'artist': '未知艺术家',
            'album': '本地文件夹',
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
    } else if (FileUtils.isTextOrCode(path)) {
      Navigator.push(context, MaterialPageRoute(builder: (_) => TextEditorScreen(filePath: path)));
    } else if (const ['.db', '.sqlite', '.sqlite3', '.db3'].contains(ext)) {
      Navigator.push(context, MaterialPageRoute(builder: (_) => DatabaseReaderScreen(filePath: path)));
    } else if (docExts.contains(ext)) {
      Navigator.push(context, MaterialPageRoute(builder: (_) => DocumentViewerScreen(filePath: path)));
    } else if (ApkInstallerService.isApk(path)) {
      await ApkInstallerService.installApk(context, path);
    } else {
      // 未知格式，弹出打开方式选择
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

      if (result == null) return;

      if (result.startsWith('always_')) {
        final selectedType = result.substring('always_'.length);
        await PreferencesService.saveDefaultOpenAction(ext, selectedType);
        if (selectedType == 'native') {
          await OpenFilex.open(path);
        } else {
          await OpenFilex.open(path);
        }
      } else if (result.startsWith('just_once_')) {
        await OpenFilex.open(path);
      }
    }
  }

  Future<void> openFile(BuildContext context, String path, {bool showOpenWithPopup = false, bool forceOpenWith = false, bool isRemoteStream = false}) async {
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

        if (isVideoFile || isAudioFile) {
          // 优先尝试直接流式 URL（WebDAV 支持 HTTP 流）
          final streamUrl = remoteClient.getStreamUrl(remotePath);
          if (streamUrl != null) {
            // WebDAV 流式播放：保持连接直到播放完成（由 GC 清理）
            if (isVideoFile) {
              Navigator.push(context, MaterialPageRoute(builder: (_) => VideoPlayerScreen(videoPath: streamUrl, isRemote: true)));
            } else {
              Navigator.push(context, MaterialPageRoute(builder: (_) => AudioPlayerScreen(audioPath: streamUrl, title: p.basenameWithoutExtension(fileName), isRemote: true)));
            }
            return;
          }

          // 非 HTTP 流协议（FTP/SFTP 等）：通过本地代理服务器
          try {
            final proxyUrl = await RemoteStreamingService.instance.startStreaming(remoteClient, remotePath, fileName);
            // 代理服务器持有客户端引用，不 disconnect
            if (isVideoFile) {
              Navigator.push(context, MaterialPageRoute(builder: (_) => VideoPlayerScreen(videoPath: proxyUrl, isRemote: true)));
            } else {
              Navigator.push(context, MaterialPageRoute(builder: (_) => AudioPlayerScreen(audioPath: proxyUrl, title: p.basenameWithoutExtension(fileName), isRemote: true)));
            }
            return;
          } catch (e) {
            debugPrint('远程流式代理启动失败，回退到下载模式: $e');
          }
        }

        // 非媒体文件或流式失败：完整下载后打开
        final cacheDir = Directory('/storage/emulated/0/Download/ZenFile_Remote');
        if (!cacheDir.existsSync()) cacheDir.createSync(recursive: true);
        final cachePath = p.join(cacheDir.path, fileName);
        if (!File(cachePath).existsSync()) {
          await remoteClient.downloadFile(remotePath, cachePath, (progress) {});
        }
        targetPath = cachePath;
        // 下载完成后断开连接
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

        if (isVideoFile || isAudioFile) {
          // 优先尝试直接流式 URL（WebDAV 支持 HTTP 流）
          final streamUrl = remoteClient.getStreamUrl(path);
          if (streamUrl != null) {
            // 直接流式播放 — 无需下载
            if (isVideoFile) {
              Navigator.push(context, MaterialPageRoute(builder: (_) => VideoPlayerScreen(videoPath: streamUrl, isRemote: true)));
            } else {
              Navigator.push(context, MaterialPageRoute(builder: (_) => AudioPlayerScreen(audioPath: streamUrl, title: p.basenameWithoutExtension(path), isRemote: true)));
            }
            return;
          }

          // 非 HTTP 流协议（FTP/SFTP 等）：通过本地代理服务器实现边缓存边播放
          try {
            final proxyUrl = await RemoteStreamingService.instance.startStreaming(remoteClient, path, p.basename(path));
            if (isVideoFile) {
              Navigator.push(context, MaterialPageRoute(builder: (_) => VideoPlayerScreen(videoPath: proxyUrl, isRemote: true)));
            } else {
              Navigator.push(context, MaterialPageRoute(builder: (_) => AudioPlayerScreen(audioPath: proxyUrl, title: p.basenameWithoutExtension(path), isRemote: true)));
            }
            return;
          } catch (e) {
            debugPrint('流式代理启动失败，回退到下载模式: $e');
          }
        }

        // 非媒体文件或流式失败：完整下载后打开
        final cacheDir = Directory('/storage/emulated/0/Download/ZenFile_Remote');
        if (!cacheDir.existsSync()) cacheDir.createSync(recursive: true);
        final cachePath = p.join(cacheDir.path, p.basename(path));
        if (!File(cachePath).existsSync()) {
          await remoteClient.downloadFile(path, cachePath, (progress) {});
        }
        targetPath = cachePath;
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

    if (forceOpenWith) {
      await OpenFilex.open(targetPath);
      return;
    }

    // Universal default action check
    if (hasNativeViewer(targetPath)) {
      final defaultAction = PreferencesService.getDefaultOpenAction(ext);
      if (defaultAction == 'native') {
        await openFileNatively(context, targetPath);
        return;
      } else if (defaultAction == 'external') {
        await OpenFilex.open(targetPath);
        return;
      }
    }

    if (showOpenWithPopup && !_skipOpenWithDialog && hasNativeViewer(targetPath)) {
      if (!context.mounted) return;
      
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

      if (result == null) return;

      if (result.startsWith('always_')) {
        final selectedType = result.substring('always_'.length);
        await PreferencesService.saveDefaultOpenAction(ext, selectedType);
        if (selectedType == 'native') {
          await openFileNatively(context, targetPath);
        } else {
          await OpenFilex.open(targetPath);
        }
      } else if (result.startsWith('just_once_')) {
        final selectedType = result.substring('just_once_'.length);
        if (selectedType == 'native') {
          await openFileNatively(context, targetPath);
        } else {
          await OpenFilex.open(targetPath);
        }
      }
      return;
    }

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
    _navigateToBrowseTabNotifier.dispose();
    super.dispose();
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
