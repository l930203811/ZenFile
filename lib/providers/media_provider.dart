import 'package:zenfile/l10n/generated/app_localizations.dart';

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:on_audio_query/on_audio_query.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'package:device_info_plus/device_info_plus.dart';
import '../services/preferences_service.dart';
import '../services/network_connections_service.dart';
import '../services/media_thumbnail_service.dart';
import '../models/custom_shortcut_model.dart';
import '../models/file_item_model.dart';
import '../models/network_connection_model.dart';
import '../core/utils.dart';
import '../services/remote/remote_client.dart';
import 'file_manager_provider.dart';

enum MediaSortOrder {
  newest,
  oldest,
  dateWise,
  newestGrouped,
  oldestGrouped,
  sizeLargest,
  sizeSmallest,
}

class ThumbnailCache {
  static final Map<String, Uint8List?> _cache = {};
  static final Map<String, Future<Uint8List?>> _pending = {};
  static String? _cacheDir;

  static Future<void> init() async {
    if (_cacheDir != null) return;
    try {
      final dir = await getTemporaryDirectory();
      final folder = Directory('${dir.path}/nfile_thumbnails');
      if (!await folder.exists()) {
        await folder.create(recursive: true);
      }
      _cacheDir = folder.path;
      try {
        final files = folder.listSync();
        for (final f in files) {
          if (f is File && f.path.endsWith('.thumb')) {
            final key = f.path.split('/').last.split('\\').last.replaceAll('.thumb', '');
            if (!_cache.containsKey(key)) {
              _cache[key] = f.readAsBytesSync();
            }
          }
        }
      } catch (_) {}
    } catch (_) {}
  }

  static Future<Uint8List?> get(AssetEntity asset) async {
    final key = asset.id;
    if (_cache.containsKey(key) && _cache[key] != null) return _cache[key];
    if (_pending.containsKey(key)) return _pending[key];

    final completer = Completer<Uint8List?>();
    _pending[key] = completer.future;

    try {
      await init();
      if (_cacheDir != null) {
        final sanitizedKey = key.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '_');
        final file = File('$_cacheDir/$sanitizedKey.thumb');
        if (await file.exists()) {
          final bytes = await file.readAsBytes();
          if (bytes.isNotEmpty) {
            _cache[key] = bytes;
            _pending.remove(key);
            completer.complete(bytes);
            return bytes;
          }
        }
      }

      final data = await asset.thumbnailDataWithSize(const ThumbnailSize.square(300));
      if (data != null && data.isNotEmpty) {
        _cache[key] = data;
        if (_cacheDir != null) {
          final sanitizedKey = key.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '_');
          final file = File('$_cacheDir/$sanitizedKey.thumb');
          await file.writeAsBytes(data, flush: true);
        }
      }
      _pending.remove(key);
      completer.complete(data);
      return data;
    } catch (e) {
      _pending.remove(key);
      completer.complete(null);
      return null;
    }
  }

  static Uint8List? getCached(String id) => _cache[id];
  static bool hasCached(String id) => _cache.containsKey(id) && _cache[id] != null;

  /// 为远程视频生成缩略图（下载视频到临时文件后提取帧）
  static Future<Uint8List?> getForRemoteVideo(String remotePathStr) async {
    final key = 'remote_vid_${remotePathStr.hashCode}';
    if (_cache.containsKey(key) && _cache[key] != null) return _cache[key];
    if (_pending.containsKey(key)) return _pending[key];

    final completer = Completer<Uint8List?>();
    _pending[key] = completer.future;

    try {
      await init();
      // 检查磁盘缓存
      if (_cacheDir != null) {
        final sanitizedKey = key.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '_');
        final cacheFile = File('$_cacheDir/$sanitizedKey.thumb');
        if (await cacheFile.exists()) {
          final bytes = await cacheFile.readAsBytes();
          if (bytes.isNotEmpty) {
            _cache[key] = bytes;
            _pending.remove(key);
            completer.complete(bytes);
            return bytes;
          }
        }
      }

      // 解析 remote:// 路径
      final uriPart = remotePathStr.substring('remote://'.length);
      final separatorIndex = uriPart.indexOf('|');
      if (separatorIndex < 0) {
        _pending.remove(key);
        completer.complete(null);
        return null;
      }
      final connectionId = uriPart.substring(0, separatorIndex);
      final remoteFilePath = uriPart.substring(separatorIndex + 1);
      final fileName = p.basename(remoteFilePath);

      // 查找连接并创建客户端
      final connections = NetworkConnectionsService.getConnections();
      final conn = connections.where((c) => c.id == connectionId).firstOrNull;
      if (conn == null) {
        _pending.remove(key);
        completer.complete(null);
        return null;
      }

      final remoteClient = FileManagerProvider.createRemoteClient(conn);
      await remoteClient.connect();

      // 下载视频文件头部 2MB 到临时文件（足够 MediaMetadataRetriever 提取帧）
      // 避免下载完整大文件消耗流量与内存
      final tempDir = await getTemporaryDirectory();
      final tempFile = File(p.join(tempDir.path, 'zenfile_thumb_$key'));
      try {
        await remoteClient.downloadRange(remoteFilePath, tempFile.path, 0, 2 * 1024 * 1024);
      } catch (e) {
        // 部分服务器或客户端可能不支持 range 下载，回退到完整下载
        debugPrint('[ThumbnailCache] downloadRange 失败，回退完整下载: $e');
        await remoteClient.downloadFile(remoteFilePath, tempFile.path, (_) {});
      }
      await remoteClient.disconnect();

      // 通过原生 MediaMetadataRetriever 生成远程视频缩略图
      Uint8List? thumbnailBytes;
      try {
        thumbnailBytes = await MediaThumbnailService.generateVideoThumbnail(tempFile.path);
      } catch (e) {
        debugPrint('[ThumbnailCache] 远程视频缩略图生成失败: $e');
      }

      // 清理临时文件
      try { await tempFile.delete(); } catch (_) {}

      if (thumbnailBytes != null && thumbnailBytes.isNotEmpty) {
        _cache[key] = thumbnailBytes;
        // 保存到磁盘缓存
        if (_cacheDir != null) {
          final sanitizedKey = key.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '_');
          final cacheFile = File('$_cacheDir/$sanitizedKey.thumb');
          await cacheFile.writeAsBytes(thumbnailBytes, flush: true);
        }
      }
      _pending.remove(key);
      completer.complete(thumbnailBytes);
      return thumbnailBytes;
    } catch (e) {
      debugPrint('[ThumbnailCache] 远程视频缩略图失败: $e');
      _pending.remove(key);
      completer.complete(null);
      return null;
    }
  }

  static void clear() {
    _cache.clear();
    _pending.clear();
    if (_cacheDir != null) {
      try {
        Directory(_cacheDir!).deleteSync(recursive: true);
      } catch (_) {}
    }
  }
}

class MediaProvider extends ChangeNotifier {
  MediaProvider() {
    final migratedVersion = PreferencesService.getCategoriesMigratedVersion();
    final savedOrder = PreferencesService.getCategoryOrder();
    if (savedOrder != null && savedOrder.isNotEmpty) {
      _categoryOrder = savedOrder;
      bool orderUpdated = false;
      // Migrate old English category names to Chinese
      final migrationMap = {
        'Images': '图片',
        'Videos': '视频',
        'Audio': '音频',
        'Documents': '文档',
        'Archives': '压缩包',
        'Download': '下载',
        'APKs': '安装包',
        'Screenshots': '截图',
      };
      for (int i = 0; i < _categoryOrder.length; i++) {
        final oldLabel = _categoryOrder[i];
        if (migrationMap.containsKey(oldLabel)) {
          _categoryOrder[i] = migrationMap[oldLabel]!;
          orderUpdated = true;
        }
      }
      if (!_categoryOrder.contains('应用')) {
        _categoryOrder.add('应用');
        orderUpdated = true;
      }
      if (!_categoryOrder.contains('设置')) {
        _categoryOrder.add('设置');
        orderUpdated = true;
      }
      if (!_categoryOrder.contains('网络')) {
        _categoryOrder.add('网络');
        orderUpdated = true;
      }
      if (!_categoryOrder.contains('最近')) {
        _categoryOrder.add('最近');
        orderUpdated = true;
      }
      if (!_categoryOrder.contains('FTP共享')) {
        _categoryOrder.add('FTP共享');
        orderUpdated = true;
      }
      if (!_categoryOrder.contains('Web共享')) {
        _categoryOrder.add('Web共享');
        orderUpdated = true;
      }
      if (!_categoryOrder.contains('保险箱')) {
        _categoryOrder.add('保险箱');
        orderUpdated = true;
      }
      if (!_categoryOrder.contains('回收站')) {
        _categoryOrder.add('回收站');
        orderUpdated = true;
      }
      if (!_categoryOrder.contains('系统')) {
        _categoryOrder.insert(0, '系统');
        orderUpdated = true;
      }
      if (!_categoryOrder.contains('存储')) {
        // 确保 '存储' 在 '系统' 后面，'空间' 前面
        final systemIndex = _categoryOrder.indexOf('系统');
        final insertIndex = systemIndex >= 0 ? systemIndex + 1 : 0;
        _categoryOrder.insert(insertIndex, '存储');
        orderUpdated = true;
      }
      if (orderUpdated) {
        PreferencesService.saveCategoryOrder(_categoryOrder);
      }
    }
    final savedActive = PreferencesService.getActiveCategories();
    if (savedActive != null && savedActive.isNotEmpty) {
      _activeCategories = savedActive;
      // Migrate old English active categories to Chinese
      final migrationMap = {
        'Images': '图片',
        'Videos': '视频',
        'Audio': '音频',
        'Documents': '文档',
        'Archives': '压缩包',
        'Download': '下载',
        'APKs': '安装包',
        'Screenshots': '截图',
      };
      bool activeUpdated = false;
      for (int i = 0; i < _activeCategories.length; i++) {
        final oldLabel = _activeCategories[i];
        if (migrationMap.containsKey(oldLabel)) {
          _activeCategories[i] = migrationMap[oldLabel]!;
          activeUpdated = true;
        }
      }
      // 仅在迁移版本低于当前版本时，补全新分类到 active 列表。
      // 已迁移用户不再干预其 active 状态，避免用户主动关闭的分类在重启后被重新启用。
      if (migratedVersion < PreferencesService.kCurrentCategoriesMigratedVersion) {
        if (!_activeCategories.contains('网络')) {
          _activeCategories.add('网络');
          activeUpdated = true;
        }
        if (!_activeCategories.contains('最近')) {
          _activeCategories.add('最近');
          activeUpdated = true;
        }
        if (!_activeCategories.contains('FTP共享')) {
          _activeCategories.add('FTP共享');
          activeUpdated = true;
        }
        if (!_activeCategories.contains('Web共享')) {
          _activeCategories.add('Web共享');
          activeUpdated = true;
        }
        if (!_activeCategories.contains('保险箱')) {
          _activeCategories.add('保险箱');
          activeUpdated = true;
        }
        if (!_activeCategories.contains('回收站')) {
          _activeCategories.add('回收站');
          activeUpdated = true;
        }
        if (!_activeCategories.contains('系统')) {
          _activeCategories.insert(0, '系统');
          activeUpdated = true;
        }
        if (!_activeCategories.contains('存储')) {
          final systemIndex = _activeCategories.indexOf('系统');
          final insertIndex = systemIndex >= 0 ? systemIndex + 1 : 0;
          _activeCategories.insert(insertIndex, '存储');
          activeUpdated = true;
        }
      }
      if (activeUpdated) {
        PreferencesService.saveActiveCategories(_activeCategories);
      }
      // 标记迁移完成（即使本次未补全，也更新版本号以跳过未来的强制补全）
      if (migratedVersion < PreferencesService.kCurrentCategoriesMigratedVersion) {
        PreferencesService.saveCategoriesMigratedVersion(
            PreferencesService.kCurrentCategoriesMigratedVersion);
      }
    }
    final savedCustom = PreferencesService.getCustomShortcuts();
    if (savedCustom != null) {
      _customShortcuts = savedCustom;
    }
    _customCategoryPaths = PreferencesService.getCustomCategoryPaths();
    _excludedDefaultPaths = PreferencesService.getExcludedDefaultPaths();
    _customCategoryLabels = PreferencesService.getCustomCategoryLabels();
  }

  List<AssetEntity> _images = [];
  List<AssetEntity> _videos = [];
  List<SongModel> _audios = [];
  List<FileSystemEntity> _documents = [];
  List<FileSystemEntity> _archives = [];
  List<FileSystemEntity> _downloads = [];
  List<FileSystemEntity> _apks = [];
  List<AssetEntity> _screenshots = [];
  List<FileSystemEntity> _customImages = [];
  List<FileSystemEntity> _customVideos = [];
  List<FileSystemEntity> _customScreenshots = [];
  Map<String, List<String>> _customCategoryPaths = {};
  Map<String, List<String>> get customCategoryPaths => _customCategoryPaths;
  Map<String, List<String>> _excludedDefaultPaths = {};
  Map<String, List<String>> get excludedDefaultPaths => _excludedDefaultPaths;
  Map<String, String> _customCategoryLabels = {};
  Map<String, String> get customCategoryLabels => _customCategoryLabels;
  List<FileItemModel> _recentFiles = [];
  List<CustomShortcutModel> _customShortcuts = [];
  List<AssetPathEntity> _imageAlbums = [];
  List<AssetPathEntity> _videoAlbums = [];

  List<AssetPathEntity> get imageAlbums => _imageAlbums;
  List<AssetPathEntity> get videoAlbums => _videoAlbums;

  List<String> _categoryOrder = [
    '系统',
    '存储',
    '空间',
    '图片',
    '视频',
    '音频',
    '文档',
    '下载',
    '截图',
    '网络',
    'FTP共享',
    'Web共享',
    '应用',
    '压缩包',
    '安装包',
    '设置',
    '最近',
    '保险箱',
    '回收站',
  ];

  List<String> _activeCategories = [
    '系统',
    '存储',
    '空间',
    '图片',
    '视频',
    '音频',
    '文档',
    '下载',
    '截图',
    '网络',
    'FTP共享',
    'Web共享',
    '应用',
    '压缩包',
    '安装包',
    '设置',
    '最近',
    '保险箱',
    '回收站',
  ];


  bool _isLoading = false;
  bool _isLoaded = false;
  MediaSortOrder _sortOrder = MediaSortOrder.newest;

  String? _getItemPath(dynamic item) {
    if (item is FileSystemEntity) return item.path;
    if (item is AssetEntity) {
      final rel = item.relativePath;
      if (rel != null) {
        final cleanRel = rel.endsWith('/') ? rel.substring(0, rel.length - 1) : rel;
        if (cleanRel.startsWith('/storage/emulated/0') || cleanRel.startsWith('/storage/')) {
          return cleanRel;
        }
        if (cleanRel.startsWith('storage/emulated/0') || cleanRel.startsWith('storage/')) {
          return '/$cleanRel';
        }
        return '/storage/emulated/0/$cleanRel';
      }
    }
    return null;
  }

  bool _isPathExcluded(String itemPath, List<String> excludedPaths) {
    for (final excl in excludedPaths) {
      if (itemPath == excl || p.isWithin(excl, itemPath)) {
        return true;
      }
    }
    return false;
  }

  List<dynamic> get images {
    final excluded = _excludedDefaultPaths['图片'] ?? [];
    final excludeGallery = excluded.contains('设备相册（自动）');
    final list = [..._images, ..._customImages].where((item) {
      if (item is AssetEntity && excludeGallery) return false;
      final path = _getItemPath(item);
      if (path != null && _isPathExcluded(path, excluded)) {
        return false;
      }
      return true;
    }).toList();
    _sortDynamicList(list);
    return list;
  }

  List<dynamic> get videos {
    final excluded = _excludedDefaultPaths['视频'] ?? [];
    final excludeGallery = excluded.contains('设备相册（自动）');
    final list = [..._videos, ..._customVideos].where((item) {
      if (item is AssetEntity && excludeGallery) return false;
      final path = _getItemPath(item);
      if (path != null && _isPathExcluded(path, excluded)) {
        return false;
      }
      return true;
    }).toList();
    _sortDynamicList(list);
    return list;
  }

  List<SongModel> get audios {
    final excluded = _excludedDefaultPaths['音频'] ?? [];
    final excludeLibrary = excluded.contains('设备音频库（自动）');
    return _audios.where((song) {
      if (excludeLibrary && song.id < 900000) return false;
      final path = song.data;
      if (_isPathExcluded(path, excluded)) return false;
      return true;
    }).toList();
  }

  List<FileSystemEntity> get documents {
    final excluded = _excludedDefaultPaths['文档'] ?? [];
    final excludeAllScanned = excluded.contains('内部存储（扫描所有文件夹）');
    return _documents.where((file) {
      final docPaths = _customCategoryPaths['文档'] ?? [];
      final isCustom = docPaths.any((dir) => p.isWithin(dir, file.path));
      if (excludeAllScanned && !isCustom) return false;
      if (_isPathExcluded(file.path, excluded)) return false;
      return true;
    }).toList();
  }

  List<FileSystemEntity> get archives {
    final excluded = _excludedDefaultPaths['压缩包'] ?? [];
    final excludeAllScanned = excluded.contains('内部存储（扫描所有文件夹）');
    return _archives.where((file) {
      final archPaths = _customCategoryPaths['压缩包'] ?? [];
      final isCustom = archPaths.any((dir) => p.isWithin(dir, file.path));
      if (excludeAllScanned && !isCustom) return false;
      if (_isPathExcluded(file.path, excluded)) return false;
      return true;
    }).toList();
  }

  List<FileSystemEntity> get downloads {
    final excluded = _excludedDefaultPaths['下载'] ?? [];
    return _downloads.where((file) {
      if (_isPathExcluded(file.path, excluded)) return false;
      return true;
    }).toList();
  }

  List<FileSystemEntity> get apks {
    final excluded = _excludedDefaultPaths['安装包'] ?? [];
    final excludeAllScanned = excluded.contains('内部存储（扫描所有文件夹）');
    return _apks.where((file) {
      final apkPaths = _customCategoryPaths['安装包'] ?? [];
      final isCustom = apkPaths.any((dir) => p.isWithin(dir, file.path));
      if (excludeAllScanned && !isCustom) return false;
      if (_isPathExcluded(file.path, excluded)) return false;
      return true;
    }).toList();
  }

  List<dynamic> get screenshots {
    final excluded = _excludedDefaultPaths['截图'] ?? [];
    final excludeGallery = excluded.contains('设备相册（截图）');
    final list = [..._screenshots, ..._customScreenshots].where((item) {
      if (item is AssetEntity && excludeGallery) return false;
      final path = _getItemPath(item);
      if (path != null && _isPathExcluded(path, excluded)) {
        return false;
      }
      return true;
    }).toList();
    _sortDynamicList(list);
    return list;
  }
  List<FileItemModel> get recentFiles => _recentFiles;

  void _sortDynamicList(List<dynamic> list) {
    int Function(dynamic, dynamic) compare;
    if (_sortOrder == MediaSortOrder.newest ||
        _sortOrder == MediaSortOrder.newestGrouped ||
        _sortOrder == MediaSortOrder.dateWise) {
      compare = (a, b) {
        final aTime = _getDateTime(a);
        final bTime = _getDateTime(b);
        return bTime.compareTo(aTime);
      };
    } else if (_sortOrder == MediaSortOrder.oldest ||
               _sortOrder == MediaSortOrder.oldestGrouped) {
      compare = (a, b) {
        final aTime = _getDateTime(a);
        final bTime = _getDateTime(b);
        return aTime.compareTo(bTime);
      };
    } else if (_sortOrder == MediaSortOrder.sizeLargest ||
               _sortOrder == MediaSortOrder.sizeSmallest) {
      final isSmallest = _sortOrder == MediaSortOrder.sizeSmallest;
      compare = (a, b) {
        final aSize = _getSize(a);
        final bSize = _getSize(b);
        return isSmallest ? aSize.compareTo(bSize) : bSize.compareTo(aSize);
      };
    } else {
      return;
    }
    list.sort(compare);
  }

  DateTime _getDateTime(dynamic item) {
    if (item is AssetEntity) return item.createDateTime;
    if (item is FileSystemEntity) {
      try {
        return File(item.path).lastModifiedSync();
      } catch (_) {}
    }
    return DateTime.fromMillisecondsSinceEpoch(0);
  }

  int _getSize(dynamic item) {
    if (item is AssetEntity) {
      return item.width * item.height;
    }
    if (item is FileSystemEntity) {
      try {
        return File(item.path).lengthSync();
      } catch (_) {}
    }
    return 0;
  }
  List<CustomShortcutModel> get customShortcuts => _customShortcuts;
  List<String> get categoryOrder => _categoryOrder;
  List<String> get activeCategories => _activeCategories;
  bool get isLoading => _isLoading;
  bool get isLoaded => _isLoaded;
  MediaSortOrder get sortOrder => _sortOrder;

  final OnAudioQuery _audioQuery = OnAudioQuery();

  void toggleCategory(String label) {
    if (_activeCategories.contains(label)) {
      if (_activeCategories.length > 1) {
        _activeCategories.remove(label);
      }
    } else {
      _activeCategories.add(label);
    }
    PreferencesService.saveActiveCategories(_activeCategories);
    _saveCache();
    notifyListeners();
  }

  void reorderCategory(int oldIndex, int newIndex) {
    if (newIndex > oldIndex) {
      newIndex -= 1;
    }
    final item = _categoryOrder.removeAt(oldIndex);
    _categoryOrder.insert(newIndex, item);
    PreferencesService.saveCategoryOrder(_categoryOrder);
    _saveCache();
    notifyListeners();
  }

  /// 重命名类别显示标签
  /// oldLabel: 当前显示的标签（可能是原始标签或已自定义的标签）
  /// newLabel: 新的显示标签
  void renameCategory(String oldLabel, String newLabel) {
    // 查找原始键：如果 oldLabel 是已自定义的标签值，找到对应的原始键
    String? originalKey = oldLabel;
    bool foundAsValue = false;
    for (final entry in _customCategoryLabels.entries) {
      if (entry.value == oldLabel) {
        originalKey = entry.key;
        foundAsValue = true;
        break;
      }
    }

    // 如果新标签与原始键相同（即改回默认名），删除自定义标签条目
    // 这样显示时会回退到 l10n 默认翻译
    if (newLabel == originalKey) {
      if (_customCategoryLabels.containsKey(originalKey)) {
        _customCategoryLabels.remove(originalKey);
        PreferencesService.saveCustomCategoryLabels(_customCategoryLabels);
        notifyListeners();
      }
      return;
    }

    // 新旧标签相同且不是改回默认名，无需操作
    if (oldLabel == newLabel && !foundAsValue) return;

    if (foundAsValue) {
      // oldLabel 是已自定义的标签值，更新对应的原始键的值
      _customCategoryLabels[originalKey!] = newLabel;
    } else if (_customCategoryLabels.containsKey(oldLabel)) {
      // oldLabel 是原始键且已有自定义标签，更新值
      _customCategoryLabels[oldLabel] = newLabel;
    } else {
      // oldLabel 是原始键且没有自定义标签，创建新条目
      _customCategoryLabels[oldLabel] = newLabel;
    }

    PreferencesService.saveCustomCategoryLabels(_customCategoryLabels);
    notifyListeners();
  }

  void addCustomShortcut(String path) {
    final label = p.basename(path);
    final id = 'custom_$path';
    if (_categoryOrder.contains(id)) return;

    final isDir = FileSystemEntity.isDirectorySync(path);
    final cs = CustomShortcutModel(id: id, label: label, path: path, isDirectory: isDir);
    _customShortcuts.add(cs);
    _categoryOrder.add(id);
    _activeCategories.add(id);

    PreferencesService.saveCustomShortcuts(_customShortcuts);
    PreferencesService.saveCategoryOrder(_categoryOrder);
    PreferencesService.saveActiveCategories(_activeCategories);
    _saveCache();
    notifyListeners();
  }

  void removeCustomShortcut(String id) {
    _customShortcuts.removeWhere((cs) => cs.id == id);
    _categoryOrder.remove(id);
    _activeCategories.remove(id);

    PreferencesService.saveCustomShortcuts(_customShortcuts);
    PreferencesService.saveCategoryOrder(_categoryOrder);
    PreferencesService.saveActiveCategories(_activeCategories);
    _saveCache();
    notifyListeners();
  }

  int getCategoryItemCount(String category) {
    if (_isLoaded) {
      switch (category) {
        case '图片': return images.length;
        case '视频': return videos.length;
        case '音频': return _audios.length;
        case '文档': return _documents.length;
        case '压缩包': return _archives.length;
        case '下载': return _downloads.length;
        case '安装包': return _apks.length;
        case '截图': return screenshots.length;
        case '应用': return 0;
        case '设置': return 0;
        case '网络': return NetworkConnectionsService.getConnections().length;
        case '最近': return _recentFiles.length;
        case '保险箱': return 0;
      }
    }
    return PreferencesService.getCategoryCount(category);
  }

  Future<void> _loadFromDiskCache() async {
    try {
      final dir = await getTemporaryDirectory();
      final cacheFile = File('${dir.path}/media_meta_cache.json');
      if (await cacheFile.exists()) {
        final jsonStr = await cacheFile.readAsString();
        final map = jsonDecode(jsonStr) as Map<String, dynamic>;

        // 注意: categoryOrder 和 activeCategories 不从磁盘缓存读取，
        // 它们由构造函数从 SharedPreferences 读取作为唯一真相源。
        // 否则缓存中的旧值会覆盖用户自定义的顺序和启用状态，
        // 且强制按默认顺序排序会破坏用户的自定义排列。

        if (map.containsKey('documents')) {
          final docPaths = List<String>.from(map['documents'] ?? []);
          final cachedDocs = <FileSystemEntity>[];
          for (final p in docPaths) {
            final f = File(p);
            if (f.existsSync()) cachedDocs.add(f);
          }
          if (cachedDocs.isNotEmpty && _documents.isEmpty) {
            _documents = cachedDocs;
          }
        }

        if (map.containsKey('archives')) {
          final archPaths = List<String>.from(map['archives'] ?? []);
          final cachedArch = <FileSystemEntity>[];
          for (final p in archPaths) {
            final f = File(p);
            if (f.existsSync()) cachedArch.add(f);
          }
          if (cachedArch.isNotEmpty && _archives.isEmpty) {
            _archives = cachedArch;
          }
        }

        if (map.containsKey('downloads')) {
          final dlPaths = List<String>.from(map['downloads'] ?? []);
          final cachedDl = <FileSystemEntity>[];
          for (final p in dlPaths) {
            final f = File(p);
            if (f.existsSync()) cachedDl.add(f);
          }
          if (cachedDl.isNotEmpty && _downloads.isEmpty) {
            _downloads = cachedDl;
          }
        }

        if (map.containsKey('apks')) {
          final apkPaths = List<String>.from(map['apks'] ?? []);
          final cachedApks = <FileSystemEntity>[];
          for (final p in apkPaths) {
            final f = File(p);
            if (f.existsSync()) cachedApks.add(f);
          }
          if (cachedApks.isNotEmpty && _apks.isEmpty) {
            _apks = cachedApks;
          }
        }

        if (map.containsKey('recentFiles')) {
          final paths = List<Map<String, dynamic>>.from(
            (map['recentFiles'] as List?)?.map((e) => Map<String, dynamic>.from(e as Map)) ?? [],
          );
          final cached = <FileItemModel>[];
          for (final entry in paths) {
            try {
              final path = entry['path'] as String?;
              if (path == null) continue;
              final f = File(path);
              if (!f.existsSync()) continue;
              cached.add(FileItemModel(
                entity: f,
                name: p.basename(path),
                path: path,
                isDirectory: false,
                size: (entry['size'] as num?)?.toInt() ?? 0,
                modified: DateTime.fromMillisecondsSinceEpoch(
                  (entry['modified'] as num?)?.toInt() ?? 0,
                ),
              ));
            } catch (_) {}
          }
          if (cached.isNotEmpty && _recentFiles.isEmpty) {
            _recentFiles = cached;
          }
        }
      }
    } catch (_) {}
  }

  Future<void> _saveCache() async {
    try {
      final dir = await getTemporaryDirectory();
      final cacheFile = File('${dir.path}/media_meta_cache.json');
      final map = {
        'categoryOrder': _categoryOrder,
        'activeCategories': _activeCategories,
        'documents': _documents.map((e) => e.path).toList(),
        'archives': _archives.map((e) => e.path).toList(),
        'downloads': _downloads.map((e) => e.path).toList(),
        'apks': _apks.map((e) => e.path).toList(),
        'recentFiles': _recentFiles.take(30).map((e) => {
          'path': e.path,
          'size': e.size,
          'modified': e.modified.millisecondsSinceEpoch,
        }).toList(),
      };
      await cacheFile.writeAsString(jsonEncode(map), flush: true);
    } catch (_) {}
  }

  Future<void> refreshMediaBackground() async {
    final futures = <Future<void>>[];
    
    bool isStorageGranted = false;
    try {
      isStorageGranted = await Permission.storage.isGranted || await Permission.manageExternalStorage.isGranted;
    } catch (_) {}
    
    PermissionState ps = PermissionState.denied;
    try {
      ps = await PhotoManager.requestPermissionExtend();
    } catch (_) {}

    bool hasAudioPermission = false;
    try {
      hasAudioPermission = await _audioQuery.permissionsStatus();
    } catch (_) {}

    if (ps.isAuth || isStorageGranted) {
      futures.add(_loadImagesAndVideos());
    }
    if (hasAudioPermission || isStorageGranted) {
      futures.add(_loadAudios(hasPermission: hasAudioPermission || isStorageGranted));
    }
    futures.add(_loadDocuments());
    futures.add(_loadArchivesDownloadsAndApks());

    await Future.wait(futures);
    await _scanCustomCategories();
    await _scanRecentFiles();
    await _saveCache();
    _applySort();
    
    PreferencesService.saveCategoryCount('图片', images.length);
    PreferencesService.saveCategoryCount('视频', videos.length);
    PreferencesService.saveCategoryCount('音频', _audios.length);
    PreferencesService.saveCategoryCount('文档', _documents.length);
    PreferencesService.saveCategoryCount('压缩包', _archives.length);
    PreferencesService.saveCategoryCount('下载', _downloads.length);
    PreferencesService.saveCategoryCount('安装包', _apks.length);
    PreferencesService.saveCategoryCount('截图', screenshots.length);

    notifyListeners();
  }

  Future<void> loadMedia({bool forceRefresh = false}) async {
    if (_isLoaded && !forceRefresh) {
      await _scanCustomCategories();
      _applySort();
      notifyListeners();
      return;
    }

    _isLoading = true;
    notifyListeners();

    // Fast initial load from disk cache
    await _loadFromDiskCache();
    // 缓存加载后立即通知，让界面显示缓存数据，避免空状态等待
    notifyListeners();

    bool isStorageGranted = false;
    try {
      isStorageGranted = await Permission.storage.isGranted || await Permission.manageExternalStorage.isGranted;
    } catch (_) {}

    PermissionState ps = PermissionState.denied;
    bool hasAudioPermission = false;

    if (isStorageGranted) {
      ps = PermissionState.authorized;
      hasAudioPermission = true;
    } else {
      if (Platform.isAndroid) {
        try {
          final info = await DeviceInfoPlugin().androidInfo;
          final sdk = info.version.sdkInt;
          if (sdk < 33) {
            final storageStatus = await Permission.storage.request();
            if (storageStatus.isGranted) {
              isStorageGranted = true;
              ps = PermissionState.authorized;
              hasAudioPermission = true;
            }
            await Permission.accessMediaLocation.request();
            PhotoManager.setIgnorePermissionCheck(true);
          } else {
            try {
              ps = await PhotoManager.requestPermissionExtend();
            } catch (_) {}

            try {
              hasAudioPermission = await _audioQuery.permissionsStatus();
              if (!hasAudioPermission) {
                final status = await Permission.audio.request();
                hasAudioPermission = status.isGranted;
              }
            } catch (_) {}
          }
        } catch (_) {}
      } else {
        try {
          ps = await PhotoManager.requestPermissionExtend();
        } catch (_) {}
        hasAudioPermission = true;
      }
    }

    final futures = <Future<void>>[];
    if (ps.isAuth || isStorageGranted) {
      if (isStorageGranted && !ps.isAuth) {
        try {
          PhotoManager.setIgnorePermissionCheck(true);
        } catch (_) {}
      }
      try {
        PhotoManager.clearFileCache();
      } catch (_) {}
      futures.add(_loadImagesAndVideos());
    }
    if (hasAudioPermission || isStorageGranted) {
      futures.add(_loadAudios(hasPermission: hasAudioPermission || isStorageGranted));
    }
    futures.add(_loadDocuments());
    futures.add(_loadArchivesDownloadsAndApks());

    await Future.wait(futures);
    await _scanCustomCategories();

    // Scan recent files after all media is loaded so it can merge from providers
    await _scanRecentFiles();

    await _saveCache();

    _applySort();

    PreferencesService.saveCategoryCount('图片', images.length);
    PreferencesService.saveCategoryCount('视频', videos.length);
    PreferencesService.saveCategoryCount('音频', _audios.length);
    PreferencesService.saveCategoryCount('文档', _documents.length);
    PreferencesService.saveCategoryCount('压缩包', _archives.length);
    PreferencesService.saveCategoryCount('下载', _downloads.length);
    PreferencesService.saveCategoryCount('安装包', _apks.length);
    PreferencesService.saveCategoryCount('截图', screenshots.length);

    _isLoading = false;
    _isLoaded = true;
    notifyListeners();
  }

  Future<void> _loadImagesAndVideos() async {
    try {
      List<AssetPathEntity> albums = await PhotoManager.getAssetPathList(onlyAll: false);
      List<AssetEntity> allScreenshots = [];
      for (final album in albums) {
        if (album.name.toLowerCase().contains('screenshot')) {
          allScreenshots = await album.getAssetListPaged(page: 0, size: 5000);
          break;
        }
      }

      if (albums.isNotEmpty) {
        List<AssetEntity> allMedia = await albums[0].getAssetListPaged(page: 0, size: 10000);
        _images = allMedia.where((e) => e.type == AssetType.image).toList();
        _videos = allMedia.where((e) => e.type == AssetType.video).toList();
        if (allScreenshots.isEmpty) {
          _screenshots = _images.where((e) => (e.title ?? '').toLowerCase().contains('screenshot') || (e.relativePath ?? '').toLowerCase().contains('screenshot')).toList();
        } else {
          _screenshots = allScreenshots;
        }
      }

      // Fetch distinct image albums
      final imgAlbums = await PhotoManager.getAssetPathList(type: RequestType.image);
      final filteredImgAlbums = <AssetPathEntity>[];
      for (final album in imgAlbums) {
        final count = await album.assetCountAsync;
        if (count > 0) {
          filteredImgAlbums.add(album);
        }
      }
      _imageAlbums = filteredImgAlbums;

      // Fetch distinct video albums
      final vidAlbums = await PhotoManager.getAssetPathList(type: RequestType.video);
      final filteredVidAlbums = <AssetPathEntity>[];
      for (final album in vidAlbums) {
        final count = await album.assetCountAsync;
        if (count > 0) {
          filteredVidAlbums.add(album);
        }
      }
      _videoAlbums = filteredVidAlbums;

      // Scan common directories for SVG files (PhotoManager doesn't index SVG)
      try {
        final svgDirs = [
          Directory('/storage/emulated/0/DCIM'),
          Directory('/storage/emulated/0/Pictures'),
          Directory('/storage/emulated/0/Download'),
          Directory('/storage/emulated/0/Pictures/Screenshots'),
        ];
        final svgFiles = <FileSystemEntity>[];
        for (final dir in svgDirs) {
          if (await dir.exists()) {
            await for (final entity in dir.list(recursive: true, followLinks: false)) {
              if (entity is File && entity.path.toLowerCase().endsWith('.svg')) {
                svgFiles.add(entity);
              }
            }
          }
        }
        if (svgFiles.isNotEmpty) {
          _customImages = [...svgFiles, ..._customImages];
        }
      } catch (_) {}
    } catch (_) {}
  }

  Future<void> _loadAudios({bool hasPermission = true}) async {
    try {
      if (!hasPermission) {
        // Double-check with on_audio_query's own permission check
        final hasPerm = await _audioQuery.permissionsStatus();
        if (!hasPerm) {
          debugPrint('_loadAudios: no audio permission');
          _audios = [];
          return;
        }
      }
      _audios = await _audioQuery.querySongs(
        sortType: null,
        orderType: OrderType.ASC_OR_SMALLER,
        uriType: UriType.EXTERNAL,
        ignoreCase: true,
      );
      debugPrint('_loadAudios: loaded ${_audios.length} songs');
    } catch (e) {
      debugPrint('_loadAudios error: $e');
      _audios = [];
    }
  }

  static const List<String> _docExtensions = [
    '.pdf',
    '.doc',
    '.docx',
    '.xls',
    '.xlsx',
    '.ppt',
    '.pptx',
    '.txt',
    '.csv',
    '.odt',
    '.ods',
    '.odp',
    '.rtf',
    '.epub',
  ];

  Future<List<String>> _getUserSearchDirs() async {
    final searchDirs = <String>[];
    try {
      final rootDir = Directory('/storage/emulated/0');
      if (await rootDir.exists()) {
        await for (final entity in rootDir.list(recursive: false)) {
          try {
            if (entity is Directory) {
              final name = p.basename(entity.path);
              if (name != 'Android' && !name.startsWith('.')) {
                searchDirs.add(entity.path);
              }
            }
          } catch (_) {}
        }
      }
    } catch (_) {}
    if (searchDirs.isEmpty) {
      searchDirs.addAll([
        '/storage/emulated/0/Download',
        '/storage/emulated/0/Downloads',
        '/storage/emulated/0/Documents',
        '/storage/emulated/0/Telegram',
        '/storage/emulated/0/WhatsApp/Media',
      ]);
    }
    return searchDirs;
  }

  Future<void> _scanDirectoryRecursively(
    String startPath,
    bool Function(String ext) shouldInclude,
    void Function(File file) onFound,
  ) async {
    final queue = <String>[startPath];
    while (queue.isNotEmpty) {
      final currentPath = queue.removeAt(0);
      final dir = Directory(currentPath);
      try {
        await for (final entity in dir.list(recursive: false)) {
          try {
            if (entity is Directory) {
              final name = p.basename(entity.path);
              if (!name.startsWith('.') && name != 'Android') {
                queue.add(entity.path);
              }
            } else if (entity is File) {
              final ext = p.extension(entity.path).toLowerCase();
              if (shouldInclude(ext)) {
                onFound(entity);
              }
            }
          } catch (_) {}
        }
      } catch (_) {}
    }
  }

  Future<void> _loadDocuments() async {
    final docs = <FileSystemEntity>[];
    final searchDirs = await _getUserSearchDirs();
    final excluded = _excludedDefaultPaths['文档'] ?? [];

    for (final dirPath in searchDirs) {
      if (_isPathExcluded(dirPath, excluded)) continue;
      await _scanDirectoryRecursively(
        dirPath,
        (ext) => _docExtensions.contains(ext),
        (file) => docs.add(file),
      );
    }

    final docPaths = _customCategoryPaths['文档'] ?? [];
    for (final dirPath in docPaths) {
      if (await Directory(dirPath).exists()) {
        await _scanDirectoryRecursively(
          dirPath,
          (ext) => _docExtensions.contains(ext),
          (file) {
            if (!docs.any((d) => d.path == file.path)) {
              docs.add(file);
            }
          },
        );
      }
    }

    _documents = docs;
  }

  static const List<String> _archiveExtensions = ['.zip', '.tar', '.gz', '.bz2', '.rar', '.7z'];
  static const List<String> _apkExtensions = ['.apk', '.xapk', '.apks', '.aab'];

  Future<void> _loadArchivesDownloadsAndApks() async {
    final arch = <FileSystemEntity>[];
    final dl = <FileSystemEntity>[];
    final apkList = <FileSystemEntity>[];

    // For downloads
    final dlDirs = ['/storage/emulated/0/Download', '/storage/emulated/0/Downloads'];
    final customDlPaths = _customCategoryPaths['下载'] ?? [];
    final allDlDirs = {...dlDirs, ...customDlPaths};
    final excludedDl = _excludedDefaultPaths['下载'] ?? [];
    for (final dirPath in allDlDirs) {
      if (_isPathExcluded(dirPath, excludedDl)) continue;
      final dir = Directory(dirPath);
      if (await dir.exists()) {
        try {
          await for (final entity in dir.list(recursive: false)) {
            if (entity is File) {
              if (!dl.any((e) => e.path == entity.path)) {
                dl.add(entity);
              }
            }
          }
        } catch (_) {}
      }
    }

    final searchDirs = await _getUserSearchDirs();
    final excludedArch = _excludedDefaultPaths['压缩包'] ?? [];
    final excludedApk = _excludedDefaultPaths['安装包'] ?? [];

    for (final dirPath in searchDirs) {
      final isArchExcl = _isPathExcluded(dirPath, excludedArch);
      final isApkExcl = _isPathExcluded(dirPath, excludedApk);
      if (isArchExcl && isApkExcl) continue;

      await _scanDirectoryRecursively(
        dirPath,
        (ext) => _archiveExtensions.contains(ext) || _apkExtensions.contains(ext),
        (file) {
          final ext = p.extension(file.path).toLowerCase();
          if (_archiveExtensions.contains(ext) && !isArchExcl) {
            arch.add(file);
          } else if (_apkExtensions.contains(ext) && !isApkExcl) {
            apkList.add(file);
          }
        },
      );
    }

    final archPaths = _customCategoryPaths['压缩包'] ?? [];
    for (final dirPath in archPaths) {
      if (await Directory(dirPath).exists()) {
        await _scanDirectoryRecursively(
          dirPath,
          (ext) => _archiveExtensions.contains(ext),
          (file) {
            if (!arch.any((d) => d.path == file.path)) {
              arch.add(file);
            }
          },
        );
      }
    }

    final apkPaths = _customCategoryPaths['安装包'] ?? [];
    for (final dirPath in apkPaths) {
      if (await Directory(dirPath).exists()) {
        await _scanDirectoryRecursively(
          dirPath,
          (ext) => _apkExtensions.contains(ext),
          (file) {
            if (!apkList.any((d) => d.path == file.path)) {
              apkList.add(file);
            }
          },
        );
      }
    }

    _downloads = dl;
    _archives = arch;
    _apks = apkList;
  }

  Future<void> _scanCustomCategories() async {
    final imagePaths = _customCategoryPaths['图片'] ?? [];
    _customImages = await _scanCustomPaths(imagePaths, (p) => p.toLowerCase().endsWith('.svg') || FileUtils.isImage(p));

    final videoPaths = _customCategoryPaths['视频'] ?? [];
    _customVideos = await _scanCustomPaths(videoPaths, FileUtils.isVideo);

    final screenshotPaths = _customCategoryPaths['截图'] ?? [];
    _customScreenshots = await _scanCustomPaths(screenshotPaths, (p) => p.toLowerCase().endsWith('.svg') || FileUtils.isImage(p));

    final audioPaths = _customCategoryPaths['音频'] ?? [];
    final customAudFiles = await _scanCustomPaths(audioPaths, FileUtils.isAudio);
    _audios.removeWhere((song) => song.id >= 900000);
    final existingAudioPaths = _audios.map((s) => s.data).toSet();
    for (int i = 0; i < customAudFiles.length; i++) {
      final file = customAudFiles[i];
      if (!existingAudioPaths.contains(file.path)) {
        try {
          int fileSize = 0;
          if (!file.path.startsWith('remote://')) {
            try {
              fileSize = file.statSync().size;
            } catch (_) {}
          }
          final fileName = file.path.startsWith('remote://')
              ? file.path.split('|').last.split('/').last
              : p.basename(file.path);
          final songMap = {
            '_id': 900000 + i,
            '_data': file.path,
            'title': fileName.contains('.') ? fileName.substring(0, fileName.lastIndexOf('.')) : fileName,
            'artist': '',
            'album': '',
            'duration': 0,
            'size': fileSize,
            'display_name': fileName,
            'display_name_wo_ext': fileName.contains('.') ? fileName.substring(0, fileName.lastIndexOf('.')) : fileName,
            'is_music': true,
          };
          _audios.add(SongModel(songMap));
        } catch (_) {}
      }
    }

    // Documents custom path scan and merge
    final docPaths = _customCategoryPaths['文档'] ?? [];
    final customDocs = await _scanCustomPaths(docPaths, (ext) => _docExtensions.contains(ext));
    _documents.removeWhere((entity) {
      final isInCustomPath = docPaths.any((dir) => _isPathWithin(dir, entity.path));
      if (isInCustomPath) {
        return !customDocs.any((f) => f.path == entity.path);
      }
      return false;
    });
    for (final doc in customDocs) {
      if (!_documents.any((d) => d.path == doc.path)) {
        _documents.add(doc);
      }
    }

    // Archives custom path scan and merge
    final archPaths = _customCategoryPaths['压缩包'] ?? [];
    final customArch = await _scanCustomPaths(archPaths, (ext) => _archiveExtensions.contains(ext));
    _archives.removeWhere((entity) {
      final isInCustomPath = archPaths.any((dir) => _isPathWithin(dir, entity.path));
      if (isInCustomPath) {
        return !customArch.any((f) => f.path == entity.path);
      }
      return false;
    });
    for (final arc in customArch) {
      if (!_archives.any((a) => a.path == arc.path)) {
        _archives.add(arc);
      }
    }

    // APKs custom path scan and merge
    final apkPaths = _customCategoryPaths['安装包'] ?? [];
    final customApks = await _scanCustomPaths(apkPaths, (ext) => _apkExtensions.contains(ext));
    _apks.removeWhere((entity) {
      final isInCustomPath = apkPaths.any((dir) => _isPathWithin(dir, entity.path));
      if (isInCustomPath) {
        return !customApks.any((f) => f.path == entity.path);
      }
      return false;
    });
    for (final apk in customApks) {
      if (!_apks.any((a) => a.path == apk.path)) {
        _apks.add(apk);
      }
    }

    // Downloads custom path scan and merge
    final customDlPaths = _customCategoryPaths['下载'] ?? [];
    final customDls = <File>[];
    for (final dirPath in customDlPaths) {
      if (dirPath.startsWith('remote://')) {
        // 远程下载路径扫描（非递归）
        try {
          final uriPart = dirPath.substring('remote://'.length);
          final separatorIndex = uriPart.indexOf('|');
          if (separatorIndex < 0) continue;
          final connectionId = uriPart.substring(0, separatorIndex);
          final remoteBasePath = uriPart.substring(separatorIndex + 1);
          final connections = NetworkConnectionsService.getConnections();
          final conn = connections.where((c) => c.id == connectionId).firstOrNull;
          if (conn == null) continue;
          final client = FileManagerProvider.createRemoteClient(conn);
          await client.connect();
          try {
            final items = await client.listDirectory(remoteBasePath);
            for (final item in items) {
              if (!item.isDirectory) {
                customDls.add(File('remote://$connectionId|${item.path}'));
              }
            }
          } finally {
            await client.disconnect();
          }
        } catch (e) {
          debugPrint('[ZenFile] Remote downloads scan error: $e');
        }
      } else {
        final dir = Directory(dirPath);
        if (await dir.exists()) {
          try {
            await for (final entity in dir.list(recursive: false)) {
              if (entity is File) {
                customDls.add(entity);
              }
            }
          } catch (_) {}
        }
      }
    }
    _downloads.removeWhere((entity) {
      final isInCustomPath = customDlPaths.any((dir) => _isPathWithin(dir, entity.path));
      if (isInCustomPath) {
        return !customDls.any((f) => f.path == entity.path);
      }
      return false;
    });
    for (final dl in customDls) {
      if (!_downloads.any((d) => d.path == dl.path)) {
        _downloads.add(dl);
      }
    }
  }

  /// 检查文件路径是否在给定的自定义路径范围内，支持本地路径和 `remote://` 远程路径。
  static bool _isPathWithin(String customPath, String filePath) {
    if (customPath.startsWith('remote://')) {
      // 远程路径前缀匹配
      return filePath.startsWith('$customPath/') || filePath == customPath;
    }
    return p.isWithin(customPath, filePath);
  }

  Future<List<File>> _scanCustomPaths(List<String> paths, bool Function(String path) filter) async {
    final files = <File>[];
    for (final path in paths) {
      if (path.startsWith('remote://')) {
        // 远程服务器路径扫描
        final remoteFiles = await _scanRemotePath(path, filter);
        files.addAll(remoteFiles);
      } else if (await Directory(path).exists()) {
        await _scanDirectoryRecursively(
          path,
          filter,
          (file) => files.add(file),
        );
      }
    }
    return files;
  }

  /// 扫描远程服务器路径，返回以 `remote://{connectionId}|{remotePath}` 为路径的 File 对象列表。
  Future<List<File>> _scanRemotePath(String remotePathStr, bool Function(String path) filter) async {
    final files = <File>[];
    try {
      // 解析 remote://{connectionId}|{path} 格式
      final uriPart = remotePathStr.substring('remote://'.length);
      final separatorIndex = uriPart.indexOf('|');
      if (separatorIndex < 0) return files;
      final connectionId = uriPart.substring(0, separatorIndex);
      final remoteBasePath = uriPart.substring(separatorIndex + 1);

      // 查找连接
      final connections = NetworkConnectionsService.getConnections();
      final conn = connections.where((c) => c.id == connectionId).firstOrNull;
      if (conn == null) return files;

      // 创建远程客户端并连接
      final client = FileManagerProvider.createRemoteClient(conn);
      await client.connect();

      try {
        await _scanRemoteDirectoryRecursively(client, remoteBasePath, filter, (remoteFilePath) {
          files.add(File('remote://$connectionId|$remoteFilePath'));
        });
      } finally {
        await client.disconnect();
      }
    } catch (e) {
      debugPrint('[ZenFile] Remote scan error: $e');
    }
    return files;
  }

  /// 递归扫描远程目录，收集匹配过滤条件的文件。
  Future<void> _scanRemoteDirectoryRecursively(
    RemoteClient client,
    String path,
    bool Function(String path) filter,
    void Function(String remoteFilePath) onFileFound, {
    int depth = 0,
  }) async {
    if (depth > 5) return; // 限制递归深度防止过深扫描
    try {
      final items = await client.listDirectory(path);
      for (final item in items) {
        if (item.isDirectory) {
          await _scanRemoteDirectoryRecursively(client, item.path, filter, onFileFound, depth: depth + 1);
        } else if (filter(item.name)) {
          onFileFound(item.path);
        }
      }
    } catch (e) {
      debugPrint('[ZenFile] Remote dir scan error at $path: $e');
    }
  }

  void addCustomCategoryPath(String category, String path) {
    if (!_customCategoryPaths.containsKey(category)) {
      _customCategoryPaths[category] = [];
    }
    if (!_customCategoryPaths[category]!.contains(path)) {
      _customCategoryPaths[category]!.add(path);
      PreferencesService.saveCustomCategoryPaths(_customCategoryPaths);
      notifyListeners();
      loadMedia(forceRefresh: true);
    }
  }

  void removeCustomCategoryPath(String category, String path) {
    if (_customCategoryPaths.containsKey(category)) {
      _customCategoryPaths[category]!.remove(path);
      PreferencesService.saveCustomCategoryPaths(_customCategoryPaths);
      notifyListeners();
      loadMedia(forceRefresh: true);
    }
  }

  void excludeDefaultCategoryPath(String category, String path) {
    if (!_excludedDefaultPaths.containsKey(category)) {
      _excludedDefaultPaths[category] = [];
    }
    if (!_excludedDefaultPaths[category]!.contains(path)) {
      _excludedDefaultPaths[category]!.add(path);
      PreferencesService.saveExcludedDefaultPaths(_excludedDefaultPaths);
      notifyListeners();
      loadMedia(forceRefresh: true);
    }
  }

  void includeDefaultCategoryPath(String category, String path) {
    if (_excludedDefaultPaths.containsKey(category)) {
      if (_excludedDefaultPaths[category]!.remove(path)) {
        PreferencesService.saveExcludedDefaultPaths(_excludedDefaultPaths);
        notifyListeners();
        loadMedia(forceRefresh: true);
      }
    }
  }

  Future<void> _scanRecentFiles() async {
    final list = <FileSystemEntity>[];
    final seen = <String>{};

    final rootDir = Directory('/storage/emulated/0');
    if (await rootDir.exists()) {
      try {
        final List<String> pathsToScan = [];
        final rootEntities = await rootDir.list(recursive: false).toList();
        for (final entity in rootEntities) {
          if (entity is Directory) {
            final name = p.basename(entity.path);
            if (!name.startsWith('.') && name != 'Android') {
              pathsToScan.add(entity.path);
            }
          }
        }
        pathsToScan.addAll([
          '/storage/emulated/0/Android/media',
          '/storage/emulated/0/Download',
          '/storage/emulated/0/Documents',
        ]);

        await Future.wait(pathsToScan.map((path) async {
          final dir = Directory(path);
          if (!await dir.exists()) return;
          try {
            final entities = await dir.list(recursive: false).toList();
            for (final entity in entities) {
              if (!seen.contains(entity.path)) {
                seen.add(entity.path);
                list.add(entity);
              }
              if (entity is Directory && !p.basename(entity.path).startsWith('.')) {
                try {
                  final sub = await entity.list(recursive: false).toList();
                  for (final s in sub) {
                    if (!seen.contains(s.path)) {
                      seen.add(s.path);
                      list.add(s);
                    }
                  }
                } catch (_) {}
              }
            }
          } catch (_) {}
        }));
      } catch (_) {}
    }

    void addFromList(List<FileSystemEntity> src) {
      for (final e in src) {
        if (!seen.contains(e.path)) {
          seen.add(e.path);
          list.add(e);
        }
      }
    }

    addFromList(_downloads);
    addFromList(_documents);
    addFromList(_archives);
    addFromList(_apks);

    for (final song in _audios) {
      final path = song.data;
      if (!seen.contains(path)) {
        seen.add(path);
        try {
          final f = File(path);
          if (await f.exists()) list.add(f);
        } catch (_) {}
      }
    }

    // Filter: remove parent dirs if a child also exists in the list
    final filteredList = <FileSystemEntity>[];
    for (final entity in list) {
      if (entity is Directory) {
        bool hasChild = list.any((o) => o.path != entity.path && p.isWithin(entity.path, o.path));
        if (hasChild) continue;
      }
      filteredList.add(entity);
    }

    final items = <FileItemModel>[];
    await Future.wait(filteredList.map((f) async {
      try {
        if (f is Directory) return;
        final name = p.basename(f.path);
        if (name.startsWith('.')) return;
        final stat = await f.stat();
        items.add(FileItemModel(
          entity: f,
          name: name,
          path: f.path,
          isDirectory: false,
          size: stat.size,
          modified: stat.modified,
        ));
      } catch (_) {}
    }));

    items.sort((a, b) => b.modified.compareTo(a.modified));
    _recentFiles = items;
  }

  void setSortOrder(MediaSortOrder order) {
    _sortOrder = order;
    _applySort();
    notifyListeners();
  }

  void _applySort() {
    if (_sortOrder == MediaSortOrder.newest ||
        _sortOrder == MediaSortOrder.newestGrouped ||
        _sortOrder == MediaSortOrder.dateWise) {
      _images.sort((a, b) => b.createDateTime.compareTo(a.createDateTime));
      _videos.sort((a, b) => b.createDateTime.compareTo(a.createDateTime));
      _screenshots.sort((a, b) => b.createDateTime.compareTo(a.createDateTime));
      _audios.sort(
          (a, b) => (b.dateAdded ?? 0).compareTo(a.dateAdded ?? 0));
    } else if (_sortOrder == MediaSortOrder.oldest ||
               _sortOrder == MediaSortOrder.oldestGrouped) {
      _images.sort((a, b) => a.createDateTime.compareTo(b.createDateTime));
      _videos.sort((a, b) => a.createDateTime.compareTo(b.createDateTime));
      _screenshots.sort((a, b) => a.createDateTime.compareTo(b.createDateTime));
      _audios.sort(
          (a, b) => (a.dateAdded ?? 0).compareTo(b.dateAdded ?? 0));
    } else if (_sortOrder == MediaSortOrder.sizeLargest ||
               _sortOrder == MediaSortOrder.sizeSmallest) {
      final isSmallest = _sortOrder == MediaSortOrder.sizeSmallest;
      _images.sort((a, b) {
        final aRes = a.width * a.height;
        final bRes = b.width * b.height;
        return isSmallest ? aRes.compareTo(bRes) : bRes.compareTo(aRes);
      });
      _videos.sort((a, b) {
        final aRes = a.width * a.height;
        final bRes = b.width * b.height;
        return isSmallest ? aRes.compareTo(bRes) : bRes.compareTo(aRes);
      });
      _screenshots.sort((a, b) {
        final aRes = a.width * a.height;
        final bRes = b.width * b.height;
        return isSmallest ? aRes.compareTo(bRes) : bRes.compareTo(aRes);
      });
      _audios.sort((a, b) {
        final aSize = a.size;
        final bSize = b.size;
        return isSmallest ? aSize.compareTo(bSize) : bSize.compareTo(aSize);
      });
    }

    int fileSort(FileSystemEntity a, FileSystemEntity b) {
      try {
        final isSmallest = _sortOrder == MediaSortOrder.sizeSmallest;
        final isLargest = _sortOrder == MediaSortOrder.sizeLargest;

        if (isSmallest || isLargest) {
          final aSize = (a as File).lengthSync();
          final bSize = (b as File).lengthSync();
          return isSmallest ? aSize.compareTo(bSize) : bSize.compareTo(aSize);
        }

        final aTime = (a as File).lastModifiedSync();
        final bTime = (b as File).lastModifiedSync();
        return (_sortOrder == MediaSortOrder.oldest || _sortOrder == MediaSortOrder.oldestGrouped)
            ? aTime.compareTo(bTime)
            : bTime.compareTo(aTime);
      } catch (_) {
        return 0;
      }
    }

    _documents.sort(fileSort);
    _archives.sort(fileSort);
    _downloads.sort(fileSort);
    _apks.sort(fileSort);
  }

  Future<void> deleteMediaItems({
    required List<String> filePaths,
    required List<String> assetIds,
  }) async {
    if (assetIds.isNotEmpty) {
      try {
        await PhotoManager.editor.deleteWithIds(assetIds);
      } catch (e) {
        debugPrint('Error deleting assets: $e');
      }
    }
    for (final path in filePaths) {
      try {
        final f = File(path);
        if (f.existsSync()) {
          f.deleteSync();
        }
      } catch (_) {}
    }

    // Local List Optimization - instant updates without full-disk scans
    if (assetIds.isNotEmpty) {
      _images.removeWhere((item) => assetIds.contains(item.id));
      _videos.removeWhere((item) => assetIds.contains(item.id));
      _screenshots.removeWhere((item) => assetIds.contains(item.id));
    }

    if (filePaths.isNotEmpty) {
      // In case any image/video matches by path/title
      _images.removeWhere((item) => filePaths.contains(item.title));
      _videos.removeWhere((item) => filePaths.contains(item.title));
      _screenshots.removeWhere((item) => filePaths.contains(item.title));

      _customImages.removeWhere((item) => filePaths.contains(item.path));
      _customVideos.removeWhere((item) => filePaths.contains(item.path));
      _customScreenshots.removeWhere((item) => filePaths.contains(item.path));

      _audios.removeWhere((item) => filePaths.contains(item.data));
      _documents.removeWhere((item) => filePaths.contains(item.path));
      _archives.removeWhere((item) => filePaths.contains(item.path));
      _downloads.removeWhere((item) => filePaths.contains(item.path));
      _apks.removeWhere((item) => filePaths.contains(item.path));
    }

    // Update Counts and Cache
    PreferencesService.saveCategoryCount('图片', images.length);
    PreferencesService.saveCategoryCount('视频', videos.length);
    PreferencesService.saveCategoryCount('音频', _audios.length);
    PreferencesService.saveCategoryCount('文档', _documents.length);
    PreferencesService.saveCategoryCount('压缩包', _archives.length);
    PreferencesService.saveCategoryCount('下载', _downloads.length);
    PreferencesService.saveCategoryCount('安装包', _apks.length);
    PreferencesService.saveCategoryCount('截图', screenshots.length);

    await _saveCache();
    notifyListeners();
  }
}
