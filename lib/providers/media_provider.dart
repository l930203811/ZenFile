
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:on_audio_query/on_audio_query.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import '../services/preferences_service.dart';
import '../services/network_connections_service.dart';
import '../services/media_thumbnail_service.dart';
import '../models/custom_shortcut_model.dart';
import '../models/file_item_model.dart';
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

/// 传给 isolate 的扫描参数（所有字段均可跨 isolate 结构化克隆）。
class _FSScanParams {
  final List<String> rootDirs;
  final List<String> imageExtensions;
  final List<String> videoExtensions;
  final List<String> audioExtensions;
  final List<String> docExtensions;
  final List<String> archiveExtensions;
  final List<String> apkExtensions;
  final List<String> downloadDirs;
  const _FSScanParams({
    required this.rootDirs,
    required this.imageExtensions,
    required this.videoExtensions,
    required this.audioExtensions,
    required this.docExtensions,
    required this.archiveExtensions,
    required this.apkExtensions,
    required this.downloadDirs,
  });
}

/// isolate 返回的扫描结果（仅含可跨 isolate 传递的路径/Map 数据）。
class _FSScanResult {
  final List<String> images;
  final List<String> videos;
  final List<String> screenshots;
  final List<Map<String, dynamic>> audios;
  final List<String> documents;
  final List<String> archives;
  final List<String> downloads;
  final List<String> apks;
  // 按父目录分组的路径（分类页「文件夹」视图用）。在 isolate 内一次性算好，
  // 避免主线程对几十万文件再做 O(n) 遍历分组。
  final Map<String, List<String>> imageFolders;
  final Map<String, List<String>> videoFolders;
  final Map<String, List<String>> audioFolders;
  const _FSScanResult({
    this.images = const [],
    this.videos = const [],
    this.screenshots = const [],
    this.audios = const [],
    this.documents = const [],
    this.archives = const [],
    this.downloads = const [],
    this.apks = const [],
    this.imageFolders = const {},
    this.videoFolders = const {},
    this.audioFolders = const {},
  });
}

/// 在 isolate 内按父目录对路径列表分组（供分类页文件夹视图），纯字符串运算。
Map<String, List<String>> _groupPathsByParentDir(List<String> paths) {
  final map = <String, List<String>>{};
  for (final p in paths) {
    final dir = p.replaceAll(RegExp(r'/+'), '/');
    final idx = dir.lastIndexOf('/');
    final parent = idx > 0 ? dir.substring(0, idx) : dir;
    (map[parent] ??= []).add(p);
  }
  return map;
}

String _normalizeMediaPathIsolate(String path) => path.replaceAll(RegExp(r'/+'), '/');

/// 分类页递归扫描时按尺寸过滤噪声小文件（移除系统级索引后改为全存储递归扫描，
/// 会扫到大量 app 图标、通知图标、.ts 流媒体小片段等噪声）：
/// - 图片小于此值视为图标/缩略图噪声，不进「图片」分类。
const int _kMinImageBytes = 30 * 1024; // 30 KB
/// - 视频小于此值视为流媒体小片段/广告碎片（如 .ts 碎片），不进「视频」分类。
const int _kMinVideoBytes = 1024 * 1024; // 1 MB

/// 在独立 isolate 中递归遍历 [params.rootDirs]，按扩展名一次性收集所有类别。
/// 与 1.1.22 系统级索引（MediaStore 独立进程）等价：扫描完全不占用 UI 主线程。
/// 此函数不依赖任何类实例/闭包，也不调用 platform channel，可在 isolate 安全运行。
@pragma('vm:entry-point')
Future<_FSScanResult> _scanMediaFileSystemIsolate(_FSScanParams params) async {
  final images = <String>[];
  final videos = <String>[];
  final screenshots = <String>[];
  final audios = <Map<String, dynamic>>[];
  final documents = <String>[];
  final archives = <String>[];
  final downloads = <String>[];
  final apks = <String>[];
  final seenAudios = <String>{};
  final seenDownloads = <String>{};
  final queue = <String>[...params.rootDirs];
  while (queue.isNotEmpty) {
    final current = queue.removeAt(0);
    final isDownloadDir = params.downloadDirs.contains(current);
    try {
      await for (final entity in Directory(current).list(recursive: false)) {
        if (entity is Directory) {
          final name = p.basename(entity.path);
          if (!name.startsWith('.') && name != 'Android') {
            queue.add(entity.path);
          }
        } else if (entity is File) {
          final lower = entity.path.toLowerCase();
          final ext = p.extension(lower);
          if (isDownloadDir && !seenDownloads.contains(entity.path)) {
            seenDownloads.add(entity.path);
            downloads.add(entity.path);
          }
          if (params.videoExtensions.contains(ext)) {
            // 过滤掉极小视频片段（如 .ts 流媒体碎片），避免污染「视频」分类
            int size;
            try {
              size = entity.lengthSync();
            } catch (_) {
              size = 0;
            }
            if (size < _kMinVideoBytes) continue;
            videos.add(entity.path);
          } else if (params.audioExtensions.contains(ext)) {
            final norm = _normalizeMediaPathIsolate(entity.path);
            if (!seenAudios.contains(norm)) {
              seenAudios.add(norm);
              int size = 0;
              try {
                size = (await entity.stat()).size;
              } catch (_) {}
              final nameNoExt = p.basenameWithoutExtension(entity.path);
              audios.add({
                '_id': 800000 + seenAudios.length,
                '_data': entity.path,
                'title': nameNoExt,
                'artist': '',
                'album': '',
                'duration': 0,
                'size': size,
                'display_name': p.basename(entity.path),
                'display_name_wo_ext': nameNoExt,
                'is_music': true,
              });
            }
          } else if (params.imageExtensions.contains(ext)) {
            // 过滤掉极小图片（如 app 图标、通知图标等噪声），避免污染「图片」分类
            int size;
            try {
              size = entity.lengthSync();
            } catch (_) {
              size = 0;
            }
            if (size < _kMinImageBytes) continue;
            if (lower.contains('screenshot') || lower.contains('截图')) {
              screenshots.add(entity.path);
            } else {
              images.add(entity.path);
            }
          } else if (params.docExtensions.contains(ext)) {
            documents.add(entity.path);
          } else if (params.archiveExtensions.contains(ext)) {
            archives.add(entity.path);
          } else if (params.apkExtensions.contains(ext)) {
            apks.add(entity.path);
          }
        }
      }
    } catch (_) {}
  }
  // 在 isolate 内完成按父目录分组，主线程直接赋值，不再做 O(n) 遍历。
  final imageFolders = _groupPathsByParentDir(images);
  final videoFolders = _groupPathsByParentDir(videos);
  final audioFolders = _groupPathsByParentDir(
      audios.map((m) => (m['_data'] as String?) ?? '').where((p) => p.isNotEmpty).toList());
  return _FSScanResult(
    images: images,
    videos: videos,
    screenshots: screenshots,
    audios: audios,
    documents: documents,
    archives: archives,
    downloads: downloads,
    apks: apks,
    imageFolders: imageFolders,
    videoFolders: videoFolders,
    audioFolders: audioFolders,
  );
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
      // 异步遍历缓存目录，避免 listSync/readAsBytesSync 阻塞主线程。
      // 缓存文件较多时（数百张缩略图），同步读取会明显卡顿。
      try {
        await for (final f in folder.list()) {
          if (f is File && f.path.endsWith('.thumb')) {
            final key = f.path.split('/').last.split('\\').last.replaceAll('.thumb', '');
            if (!_cache.containsKey(key)) {
              _cache[key] = await f.readAsBytes();
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
      if (!_categoryOrder.contains('备份/恢复')) {
        final settingsIndex = _categoryOrder.indexOf('设置');
        final insertIndex = settingsIndex >= 0 ? settingsIndex + 1 : _categoryOrder.length;
        _categoryOrder.insert(insertIndex, '备份/恢复');
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
        if (!_activeCategories.contains('备份/恢复')) {
          final settingsIndex = _activeCategories.indexOf('设置');
          final insertIndex = settingsIndex >= 0 ? settingsIndex + 1 : _activeCategories.length;
          _activeCategories.insert(insertIndex, '备份/恢复');
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

  List<FileSystemEntity> _images = [];
  List<FileSystemEntity> _videos = [];
  List<SongModel> _audios = [];
  List<FileSystemEntity> _documents = [];
  List<FileSystemEntity> _archives = [];
  List<FileSystemEntity> _downloads = [];
  List<FileSystemEntity> _apks = [];
  List<FileSystemEntity> _screenshots = [];
  /// 各分类文件总大小缓存（字节），扫描完成后统一计算，避免 UI 构建时重复 stat。
  final Map<String, int> _categorySizeCache = {};
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

  /// 分类页统一采用文件系统扫描后，不再依赖 PhotoManager 的相册列表，
  /// 保持空列表以兼容旧调用，界面会隐藏文件夹模式入口。
  List<AssetPathEntity> get imageAlbums => _imageAlbums;
  List<AssetPathEntity> get videoAlbums => _videoAlbums;

  // ===== 按父目录分组（分类页「文件夹」视图用）=====
  // 键为父目录绝对路径，值为该目录下的媒体文件路径。仅存路径（不持有 File/SongModel
  // 对象），分组在扫描 isolate 内一次性算好，主线程直接赋值，不再做 O(n) 遍历。
  Map<String, List<String>> _imageFolders = {};
  Map<String, List<String>> _videoFolders = {};
  Map<String, List<String>> _audioFolders = {};

  Map<String, List<String>> get imageFolders => _imageFolders;
  Map<String, List<String>> get videoFolders => _videoFolders;
  Map<String, List<String>> get audioFolders => _audioFolders;

  /// 根据当前扁平列表重算按父目录的分组（仅存路径），供分类页文件夹视图使用。
  /// 合并了本地扫描结果（_images/_videos/_audios）与自定义扫描路径（_customImages/_customVideos/_customScreenshots），
  /// 确保远程自定义路径（remote://{connId}|{path}）的媒体文件也能按父目录分组显示在「文件夹」视图中。
  void _rebuildFolderGroups() {
    _imageFolders = _mergeFolderMaps([
      _groupByParentDir(_images),
      _groupByParentDir(_customImages),
    ]);
    _videoFolders = _mergeFolderMaps([
      _groupByParentDir(_videos),
      _groupByParentDir(_customVideos),
    ]);
    _audioFolders = _groupAudiosByParentDir(_audios);
    // 把 _screenshots / _customScreenshots 的分组并入图片文件夹（screenshots 没有独立 folder tabs，
    // 但在文件列表中本就会和普通图片一起出现，保持一致性）。
    final screenshotsFolders = _mergeFolderMaps([
      _groupByParentDir(_screenshots),
      _groupByParentDir(_customScreenshots),
    ]);
    _imageFolders = _mergeFolderMaps([_imageFolders, screenshotsFolders]);
  }

  /// 合并多个分组 Map（相同父目录下的文件路径列表拼接并去重）。
  static Map<String, List<String>> _mergeFolderMaps(List<Map<String, List<String>>> maps) {
    final result = <String, List<String>>{};
    for (final map in maps) {
      map.forEach((dir, paths) {
        if (paths.isEmpty) return;
        final list = result.putIfAbsent(dir, () => <String>[]);
        for (final p in paths) {
          if (!list.contains(p)) list.add(p);
        }
      });
    }
    return result;
  }

  /// 判断路径是否来自远程（自定义扫描路径中的 remote://）。
  static bool isRemotePath(String path) => path.startsWith('remote://');

  /// 统一的「父目录」提取 helper。
  /// 保证：分组生成（_groupByParentDir / _groupAudiosByParentDir）、
  /// folderPath 下钻过滤（media_category_screen 中按 folderPath 筛选）、
  /// 以及 remote:// 前缀的非本地路径在任何平台下都能得到一致的 key。
  /// 规则：取最后一个 '/' 之前的部分（包含路径前缀），结果与 POSIX 保持一致，
  /// 不依赖 Dart VM 平台分隔符，避免 Windows 下对 remote:// 字符串误判。
  static String parentOfPath(String filePath) {
    if (filePath.isEmpty) return filePath;
    final normalized = filePath.replaceAll('\\', '/');
    final lastSlash = normalized.lastIndexOf('/');
    if (lastSlash <= 0) {
      // 根级（remote://connId|/ 或 /）返回自身（兼容根的识别）
      return normalized;
    }
    return normalized.substring(0, lastSlash);
  }

  static Map<String, List<String>> _groupByParentDir(List<FileSystemEntity> files) {
    final map = <String, List<String>>{};
    for (final f in files) {
      final dir = parentOfPath(f.path);
      (map[dir] ??= []).add(f.path);
    }
    return map;
  }

  static Map<String, List<String>> _groupAudiosByParentDir(List<SongModel> songs) {
    final map = <String, List<String>>{};
    for (final s in songs) {
      final data = s.data;
      if (data.isNotEmpty) {
        final dir = parentOfPath(data);
        (map[dir] ??= []).add(data);
      }
    }
    return map;
  }

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
    '备份/恢复',
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
    '备份/恢复',
    '最近',
    '保险箱',
    '回收站',
  ];


  bool _isLoading = false;
  bool _isLoaded = false;
  // 后台刷新防抖：避免 home_screen 在每次 onResume 都触发一次全量扫描，
  // 多个扫描并发跑在主线程会把 UI 撑爆（表现为「打开 app 几秒后卡死」）。
  DateTime? _lastBackgroundRefresh;
  MediaSortOrder _sortOrder = MediaSortOrder.newest;

  String? _getItemPath(dynamic item) {
    if (item is FileSystemEntity) return item.path;
    if (item is SongModel) return item.data;
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

  /// 媒体去重：按路径去重，避免自定义目录与文件系统全扫结果重复。
  List<dynamic> _dedupeMediaByPath(List<dynamic> raw) {
    final seen = <String>{};
    final list = <dynamic>[];
    for (final item in raw) {
      final pth = _normalizeMediaPath(_getItemPath(item) ?? '');
      if (pth.isEmpty || seen.contains(pth)) continue;
      seen.add(pth);
      list.add(item);
    }
    return list;
  }

  List<dynamic> get images {
    final excluded = _excludedDefaultPaths['图片'] ?? [];
    final list = [..._images, ..._customImages].where((item) {
      final path = _getItemPath(item);
      if (path != null && _isPathExcluded(path, excluded)) {
        return false;
      }
      return true;
    }).toList();
    _sortDynamicList(_dedupeMediaByPath(list));
    return list;
  }

  List<dynamic> get videos {
    final excluded = _excludedDefaultPaths['视频'] ?? [];
    final list = [..._videos, ..._customVideos].where((item) {
      final path = _getItemPath(item);
      if (path != null && _isPathExcluded(path, excluded)) {
        return false;
      }
      return true;
    }).toList();
    _sortDynamicList(_dedupeMediaByPath(list));
    return list;
  }

  List<SongModel> get audios {
    final excluded = _excludedDefaultPaths['音频'] ?? [];
    return _audios.where((song) {
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
    final list = [..._screenshots, ..._customScreenshots].where((item) {
      final path = _getItemPath(item);
      if (path != null && _isPathExcluded(path, excluded)) {
        return false;
      }
      return true;
    }).toList();
    _sortDynamicList(_dedupeMediaByPath(list));
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
    if (item is SongModel) {
      final f = File(item.data);
      if (f.existsSync()) {
        try {
          return f.lastModifiedSync();
        } catch (_) {}
      }
    }
    if (item is FileSystemEntity) {
      try {
        return File(item.path).lastModifiedSync();
      } catch (_) {}
    }
    return DateTime.fromMillisecondsSinceEpoch(0);
  }

  int _getSize(dynamic item) {
    if (item is FileSystemEntity) {
      try {
        return File(item.path).lengthSync();
      } catch (_) {}
    }
    if (item is SongModel) {
      try {
        return item.size;
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
    // 网络连接在独立存储（NetworkConnectionsService）中，不参与媒体扫描，
    // 其数量与 _isLoaded 无关，必须始终返回真实已保存的连接数，
    // 否则扫描完成前会回落到从未写入的 cat_count_网络 偏好（恒为 0）。
    if (category == '网络') {
      return NetworkConnectionsService.getConnections().length;
    }
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

  /// 对 FileSystemEntity 列表递归统计文件字节总和（非文件项跳过）。
  static int _sumEntitySize(List<FileSystemEntity> entities) {
    int total = 0;
    for (final e in entities) {
      try {
        if (e is File) {
          total += e.lengthSync();
        } else if (e is Directory) {
          // 分类页条目以单个文件为主，目录单独分类时按 0 处理，
          // 避免主线程对大目录做递归 stat 阻塞 UI。
        }
      } catch (_) {}
    }
    return total;
  }

  /// 重新计算各媒体分类的总大小并写入缓存。
  /// 仅在扫描完成（saveCategoryCount 批量写入处）调用，避免重复计算。
  void _recalcCategorySizes() {
    try {
      _categorySizeCache['图片'] = _sumEntitySize(images.whereType<FileSystemEntity>().toList());
    } catch (_) { _categorySizeCache['图片'] = 0; }
    try {
      _categorySizeCache['视频'] = _sumEntitySize(videos.whereType<FileSystemEntity>().toList());
    } catch (_) { _categorySizeCache['视频'] = 0; }
    // SongModel.size 在部分 ROM 返回时长或 0，不可靠；改用 .data 路径的 File.lengthSync()。
    int audioSize = 0;
    for (final s in _audios) {
      try {
        final path = s.data;
        if (path.isNotEmpty) {
          audioSize += File(path).lengthSync();
        }
      } catch (_) {}
    }
    _categorySizeCache['音频'] = audioSize;
    _categorySizeCache['文档'] = _sumEntitySize(_documents);
    _categorySizeCache['压缩包'] = _sumEntitySize(_archives);
    _categorySizeCache['下载'] = _sumEntitySize(_downloads);
    _categorySizeCache['安装包'] = _sumEntitySize(_apks);
    try {
      _categorySizeCache['截图'] = _sumEntitySize(screenshots.whereType<FileSystemEntity>().toList());
    } catch (_) { _categorySizeCache['截图'] = 0; }
    // 「最近」分类的 FileItemModel 自带 size 字段（字节）。
    int recentSize = 0;
    for (final r in _recentFiles) {
      try { recentSize += r.size; } catch (_) {}
    }
    _categorySizeCache['最近'] = recentSize;
    _categorySizeCache['应用'] = 0;
    _categorySizeCache['设置'] = 0;
    _categorySizeCache['网络'] = 0;
    _categorySizeCache['保险箱'] = 0;
    // 缓存到偏好设置，扫描未完成时可回落显示。
    PreferencesService.saveCategorySizes(Map<String, String>.from(
      _categorySizeCache.map((k, v) => MapEntry(k, v.toString())),
    ));
  }

  /// 获取指定分类的文件总大小（字节）。优先使用扫描后的缓存，
  /// 未就绪时回落到偏好设置，均无数据返回 0。
  int getCategoryTotalSize(String category) {
    if (_categorySizeCache.containsKey(category) && _isLoaded) {
      return _categorySizeCache[category] ?? 0;
    }
    final pref = PreferencesService.getCategorySize(category);
    if (pref != null) return pref;
    return 0;
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
            if (await f.exists()) cachedDocs.add(f);
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
            if (await f.exists()) cachedArch.add(f);
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
            if (await f.exists()) cachedDl.add(f);
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
            if (await f.exists()) cachedApks.add(f);
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
              if (!await f.exists()) continue;
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

        // 恢复文件系统扫描到的媒体文件缓存，避免每次启动都重新全量扫描
        if (map.containsKey('fsImages')) {
          final paths = List<String>.from(map['fsImages'] ?? []);
          final cached = <FileSystemEntity>[];
          for (final path in paths) {
            final f = File(path);
            if (await f.exists()) cached.add(f);
          }
          if (cached.isNotEmpty && _images.isEmpty) {
            _images = cached;
          }
        }

        if (map.containsKey('fsVideos')) {
          final paths = List<String>.from(map['fsVideos'] ?? []);
          final cached = <FileSystemEntity>[];
          for (final path in paths) {
            final f = File(path);
            if (await f.exists()) cached.add(f);
          }
          if (cached.isNotEmpty && _videos.isEmpty) {
            _videos = cached;
          }
        }

        if (map.containsKey('fsScreenshots')) {
          final paths = List<String>.from(map['fsScreenshots'] ?? []);
          final cached = <FileSystemEntity>[];
          for (final path in paths) {
            final f = File(path);
            if (await f.exists()) cached.add(f);
          }
          if (cached.isNotEmpty && _screenshots.isEmpty) {
            _screenshots = cached;
          }
        }

        if (map.containsKey('fsAudios')) {
          final audioEntries = List<Map<String, dynamic>>.from(
            (map['fsAudios'] as List?)?.map((e) => Map<String, dynamic>.from(e as Map)) ?? [],
          );
          final cached = <SongModel>[];
          for (final entry in audioEntries) {
            try {
              final path = entry['data'] as String?;
              if (path == null) continue;
              final f = File(path);
              if (!await f.exists()) continue;
              cached.add(SongModel({
                '_id': entry['id'] ?? 800000 + cached.length,
                '_data': path,
                'title': entry['title'] ?? p.basenameWithoutExtension(path),
                'artist': entry['artist'] ?? '',
                'album': entry['album'] ?? '',
                'duration': entry['duration'] ?? 0,
                'size': entry['size'] ?? 0,
                'display_name': entry['display_name'] ?? p.basename(path),
                'display_name_wo_ext': entry['display_name_wo_ext'] ?? p.basenameWithoutExtension(path),
                'is_music': entry['is_music'] ?? true,
              }));
            } catch (_) {}
          }
          if (cached.isNotEmpty && _audios.isEmpty) {
            _audios = cached;
          }
        }
        // 缓存恢复完成后按父目录重算分组，供分类页文件夹视图使用
        _rebuildFolderGroups();
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
        // 文件系统扫描结果缓存：分类页不再依赖系统索引，缓存完整结果以加速下次启动
        'fsImages': _images.map((e) => e.path).toList(),
        'fsVideos': _videos.map((e) => e.path).toList(),
        'fsScreenshots': _screenshots.map((e) => e.path).toList(),
        'fsAudios': _audios.map((s) => {
          'id': s.id,
          'data': s.data,
          'title': s.title,
          'artist': s.artist,
          'album': s.album,
          'duration': s.duration,
          'size': s.size,
          'display_name': s.displayName,
          'display_name_wo_ext': s.displayNameWOExt,
          'is_music': s.isMusic,
        }).toList(),
      };
      // 把 CPU 密集的 jsonEncode 移到独立 isolate：海量媒体（数十万文件）序列化
      // 可达数 MB，主线程直接 encode 会阻塞数秒导致键盘/输入卡顿。compute 返回
      // 字符串后仅做文件写入（IO 异步，不占主线程）。
      final json = await compute(jsonEncode, map);
      await cacheFile.writeAsString(json, flush: true);
    } catch (_) {}
  }

  Future<void> refreshMediaBackground() async {
    try {
      bool isStorageGranted = false;
      try {
        isStorageGranted = await Permission.manageExternalStorage.isGranted;
      } catch (_) {}

      if (!isStorageGranted) return;

      // 防并发：若已有扫描在跑，直接跳过，避免多个全量扫描堆叠把主线程撑爆。
      if (_isLoading) return;
      // 节流：与上一次刷新间隔不足 30s 时跳过，避免在 onResume 频繁触发时
      // 反复全量扫描导致 UI 卡死（「打开 app 几秒后卡死」的根因之一）。
      final now = DateTime.now();
      if (_lastBackgroundRefresh != null &&
          now.difference(_lastBackgroundRefresh!) < const Duration(seconds: 30)) {
        return;
      }
      _lastBackgroundRefresh = now;

      final futures = <Future<void>>[];
      futures.add(_runFileSystemScanInIsolate());

      await Future.wait(futures);
      await _scanCustomCategories();
      await _scanRecentFiles();
      await _saveCache();
      await _applySort();
      _rebuildFolderGroups();

      PreferencesService.saveCategoryCount('图片', images.length);
      PreferencesService.saveCategoryCount('视频', videos.length);
      PreferencesService.saveCategoryCount('音频', _audios.length);
      PreferencesService.saveCategoryCount('文档', _documents.length);
      PreferencesService.saveCategoryCount('压缩包', _archives.length);
      PreferencesService.saveCategoryCount('下载', _downloads.length);
      PreferencesService.saveCategoryCount('安装包', _apks.length);
      PreferencesService.saveCategoryCount('截图', screenshots.length);
      _recalcCategorySizes();

      notifyListeners();
    } catch (e) {
      debugPrint('refreshMediaBackground error: $e');
    }
  }

  /// 在独立 isolate 中完成主存储递归扫描，避免主线程被百万级文件枚举占满
  /// （这是 1.1.22 用系统索引不卡、1.1.23 用主线程递归扫描导致键盘幻灯片式卡顿
  /// 与输入约 0.5s 延迟的根因。扫描结果回到主线程后再重建 File / SongModel）。
  Future<void> _runFileSystemScanInIsolate() async {
    final searchDirs = await _getUserSearchDirs();
    if (searchDirs.isEmpty) return;
    final params = _FSScanParams(
      rootDirs: searchDirs,
      imageExtensions: _imageExtensions,
      videoExtensions: _videoExtensions,
      audioExtensions: _audioExtensions,
      docExtensions: _docExtensions,
      archiveExtensions: _archiveExtensions,
      apkExtensions: _apkExtensions,
      downloadDirs: [
        '/storage/emulated/0/Download',
        '/storage/emulated/0/Downloads',
      ],
    );
    final result = await compute(_scanMediaFileSystemIsolate, params);
    _images = result.images.map((e) => File(e)).toList();
    _videos = result.videos.map((e) => File(e)).toList();
    _screenshots = result.screenshots.map((e) => File(e)).toList();
    _audios = result.audios.map((m) => SongModel(m)).toList();
    _documents = result.documents.map((e) => File(e)).toList();
    _archives = result.archives.map((e) => File(e)).toList();
    _downloads = result.downloads.map((e) => File(e)).toList();
    _apks = result.apks.map((e) => File(e)).toList();
    // 分组已在 isolate 内算好，直接赋值，主线程不再做 O(n) 遍历分组。
    _imageFolders = result.imageFolders;
    _videoFolders = result.videoFolders;
    _audioFolders = result.audioFolders;
    debugPrint('[ZenFile] isolate scan done: images=${_images.length} videos=${_videos.length} audios=${_audios.length} docs=${_documents.length} arch=${_archives.length} dl=${_downloads.length} apk=${_apks.length}');
  }

  Future<void> loadMedia({bool forceRefresh = false}) async {
    try {
      // 防并发：已有扫描在跑时直接返回，避免重复全量扫描叠加导致主线程卡死。
      if (_isLoading) return;

      if (_isLoaded && !forceRefresh) {
        await _scanCustomCategories();
        await _applySort();
        _rebuildFolderGroups();
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
        isStorageGranted = await Permission.manageExternalStorage.isGranted;
      } catch (_) {}

      if (!isStorageGranted) {
        _isLoading = false;
        notifyListeners();
        return;
      }

      final futures = <Future<void>>[];
      futures.add(_runFileSystemScanInIsolate());

      await Future.wait(futures);
      await _scanCustomCategories();

      // Scan recent files after all media is loaded so it can merge from providers
      await _scanRecentFiles();

      await _saveCache();

      await _applySort();
      _rebuildFolderGroups();

      PreferencesService.saveCategoryCount('图片', images.length);
      PreferencesService.saveCategoryCount('视频', videos.length);
      PreferencesService.saveCategoryCount('音频', _audios.length);
      PreferencesService.saveCategoryCount('文档', _documents.length);
      PreferencesService.saveCategoryCount('压缩包', _archives.length);
      PreferencesService.saveCategoryCount('下载', _downloads.length);
      PreferencesService.saveCategoryCount('安装包', _apks.length);
      PreferencesService.saveCategoryCount('截图', screenshots.length);
      _recalcCategorySizes();

      _isLoading = false;
      _isLoaded = true;
      notifyListeners();
    } catch (e) {
      debugPrint('loadMedia error: $e');
      _isLoading = false;
      notifyListeners();
    }
  }

  static const List<String> _imageExtensions = [
    '.jpg', '.jpeg', '.png', '.gif', '.webp', '.bmp', '.svg', '.ico',
    '.tiff', '.tif', '.heic', '.heif', '.avif', '.raw',
  ];
  static const List<String> _videoExtensions = [
    '.mp4', '.mkv', '.avi', '.mov', '.wmv', '.flv', '.webm', '.3gp',
    '.ts', '.m4v', '.rmvb', '.rm', '.asf', '.f4v',
  ];
  static const List<String> _audioExtensions = [
    '.mp3', '.wav', '.flac', '.m4a', '.ogg', '.wma', '.aac', '.opus',
    '.amr', '.mid', '.midi',
  ];

  /// 从文件系统扫描图片、视频、音频、截图（与 Web 共享页面一致的扫描方式）。
  /// 完全不再依赖 PhotoManager / on_audio_query 的系统媒体库索引。
  Future<void> _loadMediaFromFileSystem() async {
    try {
      final images = <FileSystemEntity>[];
      final videos = <FileSystemEntity>[];
      final audios = <SongModel>[];
      final screenshots = <FileSystemEntity>[];
      final seenAudios = <String>{};

      final searchDirs = await _getUserSearchDirs();
      for (final dir in searchDirs) {
        await _scanDirectoryRecursively(
          dir,
          (_) => true,
          (file) async {
            final lower = file.path.toLowerCase();
            final ext = p.extension(lower);
            if (_videoExtensions.contains(ext)) {
              // 过滤掉极小视频片段（与 isolate 扫描一致）
              int fileSize = 0;
              try {
                fileSize = (await file.stat()).size;
              } catch (_) {}
              if (fileSize < _kMinVideoBytes) return;
              videos.add(file);
            } else if (_audioExtensions.contains(ext)) {
              final norm = _normalizeMediaPath(file.path);
              if (seenAudios.contains(norm)) return;
              seenAudios.add(norm);
              int fileSize = 0;
              // 用异步 stat() 取代同步 statSync()，避免逐个文件阻塞主线程
              try {
                fileSize = (await file.stat()).size;
              } catch (_) {}
              final fileName = p.basename(file.path);
              final nameNoExt = p.basenameWithoutExtension(file.path);
              audios.add(SongModel({
                '_id': 800000 + seenAudios.length,
                '_data': file.path,
                'title': nameNoExt,
                'artist': '',
                'album': '',
                'duration': 0,
                'size': fileSize,
                'display_name': fileName,
                'display_name_wo_ext': nameNoExt,
                'is_music': true,
              }));
            } else if (_imageExtensions.contains(ext)) {
              // 过滤掉极小图片（与 isolate 扫描一致）
              int fileSize = 0;
              try {
                fileSize = (await file.stat()).size;
              } catch (_) {}
              if (fileSize < _kMinImageBytes) return;
              if (lower.contains('screenshot') || lower.contains('截图')) {
                screenshots.add(file);
              } else {
                images.add(file);
              }
            }
          },
        );
      }

      _images = images;
      _videos = videos;
      _audios = audios;
      _screenshots = screenshots;
      _rebuildFolderGroups();
      debugPrint('[ZenFile] _loadMediaFromFileSystem: images=${images.length}, videos=${videos.length}, audios=${audios.length}, screenshots=${screenshots.length}');
    } catch (e) {
      debugPrint('[ZenFile] _loadMediaFromFileSystem error: $e');
    }
  }

  Future<void> _loadImagesAndVideos() async {
    await _loadMediaFromFileSystem();
  }

  Future<void> _loadAudios() async {
    // 音频已与图片、视频在 _loadMediaFromFileSystem 中一并扫描完成，
    // 此处无需单独调用系统音频库，避免重复扫描。
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
        // 直接以主目录 /storage/emulated/0 为扫描根。
        // _scanDirectoryRecursively 在递归时自动跳过 Android 与隐藏目录，
        // 同时能够扫到主目录下的直接文件（图片/视频/音频等），
        // 解决「文件放在主目录下时所有类别都扫描不出来」的问题。
        searchDirs.add(rootDir.path);
        return searchDirs;
      }
    } catch (_) {}

    // 退回：主目录不可用时，扫描常见媒体目录
    searchDirs.addAll([
      '/storage/emulated/0/Download',
      '/storage/emulated/0/Downloads',
      '/storage/emulated/0/Documents',
      '/storage/emulated/0/Telegram',
      '/storage/emulated/0/WhatsApp/Media',
    ]);
    return searchDirs;
  }

  Future<void> _scanDirectoryRecursively(
    String startPath,
    bool Function(String ext) shouldInclude,
    FutureOr<void> Function(File file) onFound,
  ) async {
    final queue = <String>[startPath];
    // 周期性让出主线程：大存储设备（如澎湃OS 手机 256G+）下递归枚举会产生
    // 数十万实体，若不在循环里让出事件循环，主 isolate 会被长时间占满，
    // 表现为「打开 app 几秒后卡死 / ANR」。
    var processed = 0;
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
                await onFound(entity);
                if (++processed % 256 == 0) {
                  await Future.delayed(Duration.zero);
                }
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
              fileSize = (await file.stat()).size;
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
            var effectivePath = remoteBasePath;
            // For SMB keep "/" to scan all shared directories.
            final items = await client.listDirectory(effectivePath);
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

  /// 归一化路径用于去重比较（合并连续斜杠）。
  String _normalizeMediaPath(String path) => path.replaceAll(RegExp(r'/+'), '/');

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
        var effectivePath = remoteBasePath;
        // For SMB keep "/" to scan all shared directories.

        await _scanRemoteDirectoryRecursively(client, effectivePath, filter, (remoteFilePath) {
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

  Future<void> setSortOrder(MediaSortOrder order) async {
    _sortOrder = order;
    await _applySort();
    notifyListeners();
  }

  /// 批量预加载文件 stat（size + modified），避免排序比较器中 O(N·logN) 次同步 stat。
  /// 在排序前一次性异步获取所有文件的 stat，存入临时 Map 供比较器读取。
  static Future<Map<String, ({int size, DateTime modified})>> _preloadStats(
    List<FileSystemEntity> entities,
  ) async {
    final map = <String, ({int size, DateTime modified})>{};
    await Future.wait(entities.map((e) async {
      try {
        final stat = await File(e.path).stat();
        map[e.path] = (size: stat.size, modified: stat.modified);
      } catch (_) {}
    }));
    return map;
  }

  Future<void> _applySort() async {
    // 预加载所有需要排序的文件 stat，避免比较器中同步 IO
    final stats = <String, ({int size, DateTime modified})>{};
    final allLists = [_images, _videos, _screenshots, _documents, _archives, _downloads, _apks];
    for (final list in allLists) {
      final s = await _preloadStats(list);
      stats.addAll(s);
    }
    // 音频的 data 路径也需要 stat（按日期排序时）
    final audioPaths = _audios.map((a) => a.data).where((p) => p.isNotEmpty).toList();
    final audioStats = await _preloadStats(audioPaths.map((p) => File(p)).toList());
    stats.addAll(audioStats);

    int mediaSortByDate(FileSystemEntity a, FileSystemEntity b) {
      final aTime = stats[a.path]?.modified;
      final bTime = stats[b.path]?.modified;
      if (aTime == null || bTime == null) return 0;
      return (_sortOrder == MediaSortOrder.oldest || _sortOrder == MediaSortOrder.oldestGrouped)
          ? aTime.compareTo(bTime)
          : bTime.compareTo(aTime);
    }

    int mediaSortBySize(FileSystemEntity a, FileSystemEntity b) {
      final aSize = stats[a.path]?.size;
      final bSize = stats[b.path]?.size;
      if (aSize == null || bSize == null) return 0;
      final isSmallest = _sortOrder == MediaSortOrder.sizeSmallest;
      return isSmallest ? aSize.compareTo(bSize) : bSize.compareTo(aSize);
    }

    int audioSortByDate(SongModel a, SongModel b) {
      final aTime = stats[a.data]?.modified;
      final bTime = stats[b.data]?.modified;
      if (aTime == null || bTime == null) return 0;
      return (_sortOrder == MediaSortOrder.oldest || _sortOrder == MediaSortOrder.oldestGrouped)
          ? aTime.compareTo(bTime)
          : bTime.compareTo(aTime);
    }

    int audioSortBySize(SongModel a, SongModel b) {
      final isSmallest = _sortOrder == MediaSortOrder.sizeSmallest;
      final aSize = a.size;
      final bSize = b.size;
      return isSmallest ? aSize.compareTo(bSize) : bSize.compareTo(aSize);
    }

    if (_sortOrder == MediaSortOrder.newest ||
        _sortOrder == MediaSortOrder.newestGrouped ||
        _sortOrder == MediaSortOrder.dateWise ||
        _sortOrder == MediaSortOrder.oldest ||
        _sortOrder == MediaSortOrder.oldestGrouped) {
      _images.sort(mediaSortByDate);
      _videos.sort(mediaSortByDate);
      _screenshots.sort(mediaSortByDate);
      _audios.sort(audioSortByDate);
    } else if (_sortOrder == MediaSortOrder.sizeLargest ||
               _sortOrder == MediaSortOrder.sizeSmallest) {
      _images.sort(mediaSortBySize);
      _videos.sort(mediaSortBySize);
      _screenshots.sort(mediaSortBySize);
      _audios.sort(audioSortBySize);
    }

    int fileSort(FileSystemEntity a, FileSystemEntity b) {
      final isSmallest = _sortOrder == MediaSortOrder.sizeSmallest;
      final isLargest = _sortOrder == MediaSortOrder.sizeLargest;

      if (isSmallest || isLargest) {
        final aSize = stats[a.path]?.size;
        final bSize = stats[b.path]?.size;
        if (aSize == null || bSize == null) return 0;
        return isSmallest ? aSize.compareTo(bSize) : bSize.compareTo(aSize);
      }

      final aTime = stats[a.path]?.modified;
      final bTime = stats[b.path]?.modified;
      if (aTime == null || bTime == null) return 0;
      return (_sortOrder == MediaSortOrder.oldest || _sortOrder == MediaSortOrder.oldestGrouped)
          ? aTime.compareTo(bTime)
          : bTime.compareTo(aTime);
    }

    _documents.sort(fileSort);
    _archives.sort(fileSort);
    _downloads.sort(fileSort);
    _apks.sort(fileSort);
  }

  Future<void> deleteMediaItems({
    required List<String> filePaths,
    List<String>? assetIds,
  }) async {
    for (final path in filePaths) {
      try {
        final f = File(path);
        if (await f.exists()) {
          await f.delete();
        }
      } catch (_) {}
    }

    // Local List Optimization - instant updates without full-disk scans
    if (filePaths.isNotEmpty) {
      _images.removeWhere((item) => filePaths.contains(item.path));
      _videos.removeWhere((item) => filePaths.contains(item.path));
      _screenshots.removeWhere((item) => filePaths.contains(item.path));

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
    _recalcCategorySizes();

    await _saveCache();
    notifyListeners();
  }
}
