
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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

/// 本应用自身的缓存/缩略图目录前缀：本地递归扫描时应跳过这些目录，
/// 避免把远程媒体下载缓存、远程缩略图缓存等再次当成用户媒体收录（导致「同一图片显示两张」）。
const List<String> _kAppCacheExcludeDirs = [
  '/storage/emulated/0/ZenFile',
];

/// 判断路径是否落在本应用缓存目录下（供 isolate 与主线程扫描共用）。
bool _isUnderAppCacheDir(String path) {
  for (final d in _kAppCacheExcludeDirs) {
    if (path == d || path.startsWith('$d/')) return true;
  }
  return false;
}

/// 传给 isolate 的扫描参数（所有字段均可跨 isolate 结构化克隆）。
/// 扫描根：路径 + 允许的最大递归深度。
/// depth 0 = 仅扫描该目录自身（不进入子目录）；depth 4 = 进入至多 4 层子目录。
/// 用于把「对整棵内部存储的全量递归」改为「限定深度的热点目录快速扫描」，
/// 将非媒体类别（文档/压缩包/下载/安装包）的加载从数十秒降到毫秒级，
/// 从根本上消除「打开应用后要等很久才显示」以及「扫描常在切换/后台时被
/// 丢弃导致时有时无」的问题。
class _ScanRoot {
  final String path;
  final int maxDepth;
  const _ScanRoot(this.path, this.maxDepth);
}

/// 扫描队列元素：携带当前递归深度与所属根的 cap，超出 cap 不再入队子目录。
class _ScanItem {
  final String path;
  final int depth;
  final int cap;
  const _ScanItem(this.path, this.depth, this.cap);
}

class _FSScanParams {
  final List<_ScanRoot> roots;
  final List<String> imageExtensions;
  final List<String> videoExtensions;
  final List<String> audioExtensions;
  final List<String> docExtensions;
  final List<String> archiveExtensions;
  final List<String> apkExtensions;
  final List<String> downloadDirs;
  /// true 时跳过图片/视频/截图/音频的收集（这些类别改由系统级索引
  /// PhotoManager/on_audio_query 提供），isolate 只扫文档/压缩包/下载/安装包。
  /// 避免对大存储设备全盘递归扫描造成 I/O 饱和导致整机卡顿（红米K60Pro反馈）。
  final bool skipMediaCategories;
  /// 目录缓存：{dirPath: {'m': mtimeMillis, 'f': [文件路径], 'd': [子目录], 's': {类别: 字节}}}
  /// 仅用于枚举失败时兜底沿用已知文件清单与子目录（不再以 mtime 跳过枚举，
  /// 避免部分 ROM 不更新目录 mtime 导致新文件永不出现）。非媒体类别目录树
  /// 较小，每次扫描都会重新枚举以保证完整性。
  final Map<String, Map<String, dynamic>> dirCache;
  const _FSScanParams({
    required this.roots,
    required this.imageExtensions,
    required this.videoExtensions,
    required this.audioExtensions,
    required this.docExtensions,
    required this.archiveExtensions,
    required this.apkExtensions,
    required this.downloadDirs,
    this.skipMediaCategories = false,
    this.dirCache = const {},
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
  // 各分类文件字节总和（key 与分类名一致：图片/视频/截图/音频/文档/压缩包/下载/安装包）。
  // 在 isolate 内对每个文件 stat 累计，主线程直接取用，避免对几十万文件同步 lengthSync 阻塞 UI。
  final Map<String, int> categorySizes;
  // 更新后的目录缓存（枚举失败时兜底沿用，不再以 mtime 跳过枚举）。
  final Map<String, Map<String, dynamic>> dirCache;
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
    this.categorySizes = const {},
    this.dirCache = const {},
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

/// 在 isolate 内对一组路径求字节总和（供媒体分类大小统计，
/// 系统索引无文件大小属性，stat 放后台 isolate 避免阻塞 UI）。
@pragma('vm:entry-point')
int _sumFileSizesInIsolate(List<String> paths) {
  int total = 0;
  for (final path in paths) {
    try {
      total += File(path).lengthSync();
    } catch (_) {}
  }
  return total;
}

/// 磁盘缓存恢复结果（isolate 内完成 decode + exists 过滤，主 isolate 零 IO）。
class _RestoredCache {
  final List<String> documents;
  final List<String> archives;
  final List<String> downloads;
  final List<String> apks;
  final List<Map<String, dynamic>> recentFiles;
  final Map<String, int> categorySizes;
  final Map<String, int> mediaCounts;
  final Map<String, Map<String, dynamic>>? dirCache;
  const _RestoredCache({
    this.documents = const [],
    this.archives = const [],
    this.downloads = const [],
    this.apks = const [],
    this.recentFiles = const [],
    this.categorySizes = const {},
    this.mediaCounts = const {},
    this.dirCache,
  });
}

/// 在 isolate 内恢复磁盘缓存：jsonDecode（数 MB JSON 主线程解码可阻塞数秒）
/// 与逐文件 existsSync（几万次 stat 会淹没主 isolate 事件循环导致整机卡顿，
/// 红米K60Pro反馈的卡顿根因之一）全部移出主线程。
/// 媒体类别（图/视/截/音）不再从缓存恢复——系统级索引本身毫秒级且权威。
@pragma('vm:entry-point')
_RestoredCache _restoreCacheInIsolate(String jsonStr) {
  try {
    final map = jsonDecode(jsonStr) as Map<String, dynamic>;
    // 直接信任缓存路径，不做逐文件 existsSync：数万次 stat 是二次启动
    // 「进入类别仍需等待」的主因。已删除文件必然改变父目录 mtime，
    // 进入类别触发的增量扫描会自动发现并清除（dirCache 机制）。
    List<String> filterExisting(String key) {
      return List<String>.from(map[key] ?? []);
    }

    final recent = <Map<String, dynamic>>[];
    for (final e in (map['recentFiles'] as List?) ?? []) {
      try {
        final entry = Map<String, dynamic>.from(e as Map);
        final path = entry['path'] as String?;
        if (path == null) continue;
        if (!File(path).existsSync()) continue;
        recent.add(entry);
      } catch (_) {}
    }

    final sizes = <String, int>{};
    (map['fsCategorySizes'] as Map?)?.forEach((k, v) {
      try { sizes['$k'] = (v as num).toInt(); } catch (_) {}
    });
    final counts = <String, int>{};
    (map['mediaCounts'] as Map?)?.forEach((k, v) {
      try { counts['$k'] = (v as num).toInt(); } catch (_) {}
    });
    // 目录增量缓存（直接透传，结构见 _FSScanParams.dirCache）
    Map<String, Map<String, dynamic>>? dirCache;
    final rawDc = map['dirCache'];
    if (rawDc is Map) {
      dirCache = {};
      rawDc.forEach((k, v) {
        if (v is Map) dirCache!['$k'] = Map<String, dynamic>.from(v);
      });
    }

    return _RestoredCache(
      documents: filterExisting('documents'),
      archives: filterExisting('archives'),
      downloads: filterExisting('downloads'),
      apks: filterExisting('apks'),
      recentFiles: recent,
      categorySizes: sizes,
      mediaCounts: counts,
      dirCache: dirCache,
    );
  } catch (_) {
    return const _RestoredCache();
  }
}

/// 在独立 isolate 内读取并解码音频索引缓存：数万首歌的 JSON 可达数十 MB，
/// 主线程 jsonDecode 会瞬时占满内存甚至 OOM（大存储设备启动即崩/卡），且大字符串
/// 跨 isolate 传输也会拖累 UI。这里把「读文件 + 解码」整体移出主线程，主线程只拿到
/// 最终 List，避免与视频图片的后台重载争用资源。返回 null 表示文件缺失/损坏。
@pragma('vm:entry-point')
List<Map<dynamic, dynamic>>? _readAudioCacheIsolate(String path) {
  try {
    final f = File(path);
    if (!f.existsSync()) return null;
    final src = f.readAsStringSync();
    final decoded = jsonDecode(src);
    if (decoded is! List) return null;
    return decoded.cast<Map<dynamic, dynamic>>();
  } catch (_) {
    return null;
  }
}

/// 分类页递归扫描时按尺寸过滤噪声小文件（移除系统级索引后改为全存储递归扫描，
/// 会扫到大量 app 图标、通知图标、.ts 流媒体小片段等噪声）：
/// - 图片小于此值视为图标/缩略图噪声，不进「图片」分类。
const int _kMinImageBytes = 30 * 1024; // 30 KB
/// - 视频小于此值视为流媒体小片段/广告碎片（如 .ts 碎片），不进「视频」分类。
const int _kMinVideoBytes = 1024 * 1024; // 1 MB

/// 在独立 isolate 中递归遍历 [params.roots]，按扩展名一次性收集所有类别。
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
  // 跨根去重：热点目录与主目录浅层根会重叠枚举同一目录/文件，
  // 用 seenNonMedia 防止文档/压缩包/安装包列表出现重复路径。
  final seenNonMedia = <String>{};
  // 各分类字节总和：在 isolate 内对每个文件 stat，主线程不再逐个 lengthSync。
  final sizes = <String, int>{};
  void addSize(String key, int v) {
    if (v > 0) sizes[key] = (sizes[key] ?? 0) + v;
  }

  final queue = <_ScanItem>[for (final r in params.roots) _ScanItem(r.path, 0, r.maxDepth)];
  final queued = <String>{};
  final newDirCache = <String, Map<String, dynamic>>{};
  int scannedDirs = 0;
  debugPrint('[ZenFile][isolate] scan roots=${params.roots}');

  while (queue.isNotEmpty) {
    final item = queue.removeAt(0);
    final current = item.path;
    final currentDepth = item.depth;
    final currentCap = item.cap;
    if (!queued.add(current)) continue;
    final isDownloadDir = params.downloadDirs.contains(current);

    // 目录可达性探测已移除：原实现对每个目录做 statSync（×3 重试）只为在存储
    // 繁忙时沿用缓存，但「基于 mtime 跳过枚举」早已取消，statSync 纯属浪费——
    // 大存储设备数万目录的同步 stat 会饱和存储 I/O，造成整机卡顿（红米/澎湃
    // 「打开 app 卡死/卡顿」的主因之一）。现改为直接 list()，不可读目录由下方
    // catch 沿用缓存清单兜底，无需提前探测。
    final cached = params.dirCache[current];

    // 已移除基于目录 mtime 的「增量跳过枚举」优化：部分 ROM（FUSE/sdcardfs/
    // MTP）在文件增删时不会更新目录 mtime，导致跳过的目录永远沿用旧清单、
    // 新增文件永不出现（「加载不全」的根因）。现改为每个目录每次都重新枚举
    // 以保证新文件可见；非媒体类别（文档/压缩包/下载/安装包）目录树远小于
    // 媒体目录，全量枚举成本可控，且枚举异常时会沿用缓存清单兜底。

    // ===== 全量枚举 =====
    final dirFiles = <String>[];
    final dirSubs = <String>[];
    final dirSizes = <String, int>{};
    void dirAddSize(String key, int v) {
      if (v > 0) dirSizes[key] = (dirSizes[key] ?? 0) + v;
    }
    try {
      await for (final entity in Directory(current).list(recursive: false)) {
        if (entity is Directory) {
          final name = p.basename(entity.path);
          // 跳过隐藏目录、Android、以及本应用缓存目录（远程媒体/缩略图缓存，
          // 避免缓存图片被当成用户媒体重复收录）。
          if (!name.startsWith('.') &&
              name != 'Android' &&
              !_isUnderAppCacheDir(entity.path)) {
            dirSubs.add(entity.path);
            if (currentDepth + 1 <= currentCap && !queued.contains(entity.path)) {
              queue.add(_ScanItem(entity.path, currentDepth + 1, currentCap));
            }
          }
        } else if (entity is File) {
          // 跳过本应用缓存目录内的文件（远程下载缓存、缩略图等）。
          if (_isUnderAppCacheDir(entity.path)) continue;
          dirFiles.add(entity.path);
          final lower = entity.path.toLowerCase();
          final ext = p.extension(lower);
          if (isDownloadDir && !seenDownloads.contains(entity.path)) {
            seenDownloads.add(entity.path);
            downloads.add(entity.path);
            try {
              dirAddSize('下载', entity.lengthSync());
            } catch (_) {}
          }
          if (params.skipMediaCategories) {
            // 媒体类别（图/视/截/音）由系统级索引提供，此处跳过，
            // 只处理下方文档/压缩包/安装包分支。
          } else if (params.videoExtensions.contains(ext)) {
            // 过滤掉极小视频片段（如 .ts 流媒体碎片），避免污染「视频」分类
            int size;
            try {
              size = entity.lengthSync();
            } catch (_) {
              size = 0;
            }
            if (size < _kMinVideoBytes) continue;
            videos.add(entity.path);
            dirAddSize('视频', size);
          } else if (params.audioExtensions.contains(ext)) {
            final norm = _normalizeMediaPathIsolate(entity.path);
            if (!seenAudios.contains(norm)) {
              seenAudios.add(norm);
              int size = 0;
              try {
                size = (await entity.stat()).size;
              } catch (_) {}
              dirAddSize('音频', size);
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
              dirAddSize('截图', size);
            } else {
              images.add(entity.path);
              dirAddSize('图片', size);
            }
          } else if (params.docExtensions.contains(ext)) {
            if (seenNonMedia.add(entity.path)) {
              documents.add(entity.path);
              try {
                dirAddSize('文档', entity.lengthSync());
              } catch (_) {}
            }
          } else if (params.archiveExtensions.contains(ext)) {
            if (seenNonMedia.add(entity.path)) {
              archives.add(entity.path);
              try {
                dirAddSize('压缩包', entity.lengthSync());
              } catch (_) {}
            }
          } else if (params.apkExtensions.contains(ext)) {
            if (seenNonMedia.add(entity.path)) {
              apks.add(entity.path);
              try {
                dirAddSize('安装包', entity.lengthSync());
              } catch (_) {}
            }
          }
        }
      }
    } catch (_) {
      // 枚举异常（权限不足/存储瞬时繁忙/符号链接环）：沿用缓存清单与子目录，
      // 避免把该目录文件与整棵子树「写成空」导致内容消失/不全；同时继续遍历
      // 缓存中的子目录，保证子树在本次扫描中不被整体丢弃。
      if (cached != null) {
        dirFiles.addAll(List<String>.from(cached['f'] ?? const []));
        for (final d in List<String>.from(cached['d'] ?? const [])) {
          if (currentDepth + 1 <= currentCap && !queued.contains(d)) {
            queue.add(_ScanItem(d, currentDepth + 1, currentCap));
          }
        }
      }
    }
    dirSizes.forEach(addSize);
    newDirCache[current] = {
      'm': DateTime.now().millisecondsSinceEpoch,
      'f': dirFiles,
      'd': dirSubs,
      's': dirSizes,
    };
    // I/O 让步：每全量扫描 32 个目录暂停几 ms，把存储带宽让给系统与
    // 前台渲染。后台 isolate 虽不占 CPU，但 I/O 带宽整机共享，
    // 不让步会造成整机卡顿（红米K60Pro「仍然卡」的原因之一）。
    if (++scannedDirs % 32 == 0) {
      await Future<void>.delayed(const Duration(milliseconds: 3));
    }
  }
  debugPrint('[ZenFile][isolate] scan done: scannedDirs=$scannedDirs '
      'docs=${documents.length} arch=${archives.length} dl=${downloads.length} '
      'apk=${apks.length}');
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
    categorySizes: sizes,
    dirCache: newDirCache,
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
  /// [modified] 与 [size] 用于区分同名文件被删除重建后的不同版本，
  /// 避免旧缩略图被错误复用；若调用方无元数据可传 null。
  static Future<Uint8List?> getForRemoteVideo(
    String remotePathStr, {
    DateTime? modified,
    int? size,
  }) async {
    final metaTag = (modified != null && size != null)
        ? '_${modified.millisecondsSinceEpoch}_$size'
        : '';
    final key = 'remote_vid_${remotePathStr.hashCode}$metaTag';
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
    _instance = this;
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
  /// 远程文件元数据缓存：remote:// 路径无法被本地 stat，扫描远程服务器时把
  /// 服务端返回的 size/modified 暂存于此，供分类页 UI 显示真实大小与日期。
  /// key = remote://{connectionId}|{remotePath}
  final Map<String, int> _remoteFileSizes = {};
  final Map<String, DateTime> _remoteFileModified = {};
  /// isolate 扫描阶段累计的各分类字节数原始值（key 与分类名一致）。
  /// 主线程 [_recalcCategorySizes] 从该值 + 自定义路径补充重建缓存，避免对
  /// 几十万文件同步 lengthSync 阻塞 UI（安卓 15/16 键盘/输入卡顿根因之一）。
  Map<String, int> _fsCategorySizes = const {};
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

  // ===== 非媒体类别索引元数据缓存（分类页零 I/O 读取用）=====
  // 经系统 MediaStore.Files 索引查询得到的「修改时间(毫秒)」与「字节数」，按完整路径缓存。
  // 分类页「按日期」分组与列表 tile 不再对文档/压缩包/下载/安装包海量条目逐个 statSync，
  // 彻底消除与音频崩溃同源的主线程 O(n) 同步 I/O 冻结（大存储/多文件设备必崩）。
  // 仅在 MediaStore 主路径命中时填充；回退递归扫描（极少触发）则不填充→沿用原 statSync。
  Map<String, int> _nonMediaDates = {};
  Map<String, int> _nonMediaSizes = {};

  Map<String, int> get nonMediaDates => _nonMediaDates;
  Map<String, int> get nonMediaSizes => _nonMediaSizes;

  /// 根据当前扁平列表重算按父目录的分组（仅存路径），供分类页文件夹视图使用。
  /// 合并了本地扫描结果（_images/_videos/_audios）与自定义扫描路径（_customImages/_customVideos/_customScreenshots），
  /// 确保远程自定义路径（remote://{connId}|{path}）的媒体文件也能按父目录分组显示在「文件夹」视图中。
  /// 本地与远程文件夹在此保持各自独立的 key（本地用真实路径、远程用 remote://...），
  /// 分类页再按 [_ScopeFilter]（remote:// 前缀）分别显示，避免互相吸收导致远程文件夹/文件消失。
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
    // 用 Set 去重，避免对几十万路径逐项 contains 造成 O(n²) 主线程耗时。
    final seen = <String, Set<String>>{};
    for (final map in maps) {
      map.forEach((dir, paths) {
        if (paths.isEmpty) return;
        final list = result.putIfAbsent(dir, () => <String>[]);
        final s = seen.putIfAbsent(dir, () => <String>{});
        for (final p in paths) {
          if (s.add(p)) list.add(p);
        }
      });
    }
    return result;
  }

  /// 判断路径是否来自远程（自定义扫描路径中的 remote://）。
  static bool isRemotePath(String path) => path.startsWith('remote://');

  /// 取远程文件在扫描时缓存的大小（字节），未缓存返回 0。
  static int getCachedRemoteFileSize(String path) {
    final provider = _instance;
    if (provider == null) return 0;
    return provider._remoteFileSizes[path] ?? 0;
  }

  /// 取远程文件在扫描时缓存的修改时间，未缓存返回 null。
  static DateTime? getCachedRemoteFileModified(String path) {
    final provider = _instance;
    return provider?._remoteFileModified[path];
  }

  static MediaProvider? _instance;

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

  /// 该设备 on_audio_query 偶发返回歌曲 data 为空时，无法按真实目录分组，
  /// 统一归入此虚拟文件夹，确保分类页「文件夹」视图不为空白。
  static const String unknownAudioFolder = '未分类音频';

  static Map<String, List<String>> _groupAudiosByParentDir(List<SongModel> songs) {
    final map = <String, List<String>>{};
    for (final s in songs) {
      final data = s.data;
      if (data.isNotEmpty) {
        final dir = parentOfPath(data);
        (map[dir] ??= []).add(data);
      } else {
        // data 为空：归入「未分类音频」虚拟文件夹（见 [unknownAudioFolder]）。
        (map[unknownAudioFolder] ??= []).add(unknownAudioFolder);
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
  // 最近一次媒体扫描是否失败（isolate 扫描异常且主线程回退扫描也未执行成功，
  // 或存储权限缺失）。失败时分类浏览页显示「加载失败 + 重试」而非无限 shimmer，
  // 避免出现「类别显示缓存数量但无法打开浏览」的静默失败（红米K60Pro反馈）。
  bool _loadFailed = false;
  // 系统音频库查询（MediaStore Audio 表）
  final OnAudioQuery _audioQuery = OnAudioQuery();
  // 上次持久化的媒体数量（图片/视频/截图）。数量未变时分类大小直接沿用
  // 持久化值，避免每次启动对几万文件做全量 stat（I/O 饱和导致整机卡顿）。
  Map<String, int>? _lastMediaCounts;
  // 非媒体类别（文档/压缩包/下载/安装包）的 isolate 递归扫描已后台化：
  // _nonMediaScanDone=false 期间分类页对空列表显示 shimmer 而非空状态。
  bool _nonMediaScanDone = false;
  bool _nonMediaScanRunning = false;
  // dart:io 能否真正访问主存储（MANAGE_EXTERNAL_STORAGE 实际生效）。
  // 部分 ROM（MIUI/澎湃）上 permission_handler 的 isGranted 会误报（true 时
  // 实际 dart:io 仍读不到、false 时实际已全部授权），故在 loadMedia 用一次
  // 真实目录枚举二次确认。false 时非媒体递归扫描必然为空，需走 MediaStore 兜底。
  bool _storageAccessible = true;
  // 目录增量缓存（供 isolate 扫描跳过 mtime 未变的目录，见 _FSScanParams.dirCache）
  Map<String, Map<String, dynamic>> _dirCache = {};
  // 文件 mtime/size 缓存：系统索引加载时从 AssetEntity 播种（零 stat），
  // 其余路径首查 stat 一次后缓存。供排序比较器读取，杜绝主线程反复同步 stat。
  final Map<String, DateTime> _mtimeCache = {};
  final Map<String, int> _sizeCache = {};
  // getter 记忆化：图片/视频/截图 getter 的 过滤+去重+排序 结果缓存，
  // 源列表身份/排序方式/排除路径变化才重算（此前每次 build 都 O(N logN) 重排）。
  List<dynamic>? _imagesOut;
  int _imagesStamp = 0;
  List<dynamic>? _videosOut;
  int _videosStamp = 0;
  List<dynamic>? _shotsOut;
  int _shotsStamp = 0;
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

  /// 本地文件同步到远程后，远程自定义路径里会出现同名镜像文件，与本地扫描结果重复。
  /// 现在本地 / 远程通过顶部分类页的 [_ScopeFilter]（remote:// 前缀）严格分离显示，
  /// 不再需要在 provider 内做跨域去重（那样会把远程页的文件/文件夹整体吸收掉）。
  /// 文件级去重由 [_dedupeMediaByPath] 按完整路径保证，本地与远程各自独立。

  List<dynamic> get images {
    final excluded = _excludedDefaultPaths['图片'] ?? const [];
    final stamp = _stampFor(_images, _customImages, excluded);
    if (_imagesOut != null && _imagesStamp == stamp) return _imagesOut!;
    final raw = [..._images, ..._customImages].where((item) {
      final path = _getItemPath(item);
      if (path != null && _isPathExcluded(path, excluded)) {
        return false;
      }
      return true;
    }).toList();
    // 修复：此前 _dedupeMediaByPath 的返回值被丢弃，同路径文件
    // （系统索引 + 自定义分类双收录）会在列表中重复显示
    final list = _dedupeMediaByPath(raw);
    _sortDynamicList(list);
    _imagesOut = list;
    _imagesStamp = stamp;
    return list;
  }

  List<dynamic> get videos {
    final excluded = _excludedDefaultPaths['视频'] ?? const [];
    final stamp = _stampFor(_videos, _customVideos, excluded);
    if (_videosOut != null && _videosStamp == stamp) return _videosOut!;
    final raw = [..._videos, ..._customVideos].where((item) {
      final path = _getItemPath(item);
      if (path != null && _isPathExcluded(path, excluded)) {
        return false;
      }
      return true;
    }).toList();
    final list = _dedupeMediaByPath(raw);
    _sortDynamicList(list);
    _videosOut = list;
    _videosStamp = stamp;
    return list;
  }

  List<SongModel> get audios {
    final excluded = _excludedDefaultPaths['音频'] ?? [];
    final list = _audios.where((song) {
      final path = song.data;
      if (_isPathExcluded(path, excluded)) return false;
      return true;
    }).toList();
    return list;
  }

  List<FileSystemEntity> get documents {
    final excluded = _excludedDefaultPaths['文档'] ?? [];
    final excludeAllScanned = excluded.contains('内部存储（扫描所有文件夹）');
    final list = _documents.where((file) {
      final docPaths = _customCategoryPaths['文档'] ?? [];
      final isCustom = docPaths.any((dir) => p.isWithin(dir, file.path));
      if (excludeAllScanned && !isCustom) return false;
      if (_isPathExcluded(file.path, excluded)) return false;
      return true;
    }).toList();
    return list;
  }

  List<FileSystemEntity> get archives {
    final excluded = _excludedDefaultPaths['压缩包'] ?? [];
    final excludeAllScanned = excluded.contains('内部存储（扫描所有文件夹）');
    final list = _archives.where((file) {
      final archPaths = _customCategoryPaths['压缩包'] ?? [];
      final isCustom = archPaths.any((dir) => p.isWithin(dir, file.path));
      if (excludeAllScanned && !isCustom) return false;
      if (_isPathExcluded(file.path, excluded)) return false;
      return true;
    }).toList();
    return list;
  }

  List<FileSystemEntity> get downloads {
    final excluded = _excludedDefaultPaths['下载'] ?? [];
    final list = _downloads.where((file) {
      if (_isPathExcluded(file.path, excluded)) return false;
      return true;
    }).toList();
    return list;
  }

  List<FileSystemEntity> get apks {
    final excluded = _excludedDefaultPaths['安装包'] ?? [];
    final excludeAllScanned = excluded.contains('内部存储（扫描所有文件夹）');
    final list = _apks.where((file) {
      final apkPaths = _customCategoryPaths['安装包'] ?? [];
      final isCustom = apkPaths.any((dir) => p.isWithin(dir, file.path));
      if (excludeAllScanned && !isCustom) return false;
      if (_isPathExcluded(file.path, excluded)) return false;
      return true;
    }).toList();
    return list;
  }

  List<dynamic> get screenshots {
    final excluded = _excludedDefaultPaths['截图'] ?? const [];
    final stamp = _stampFor(_screenshots, _customScreenshots, excluded);
    if (_shotsOut != null && _shotsStamp == stamp) return _shotsOut!;
    final raw = [..._screenshots, ..._customScreenshots].where((item) {
      final path = _getItemPath(item);
      if (path != null && _isPathExcluded(path, excluded)) {
        return false;
      }
      return true;
    }).toList();
    // 修复：截图「实际 1 张显示 2 张同路径」——系统索引截图相册与
    // 「全部媒体」循环双收录/自定义分类双收录时，去重结果此前被丢弃
    final list = _dedupeMediaByPath(raw);
    _sortDynamicList(list);
    _shotsOut = list;
    _shotsStamp = stamp;
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
    String? path;
    if (item is SongModel) {
      path = item.data;
    } else if (item is FileSystemEntity) {
      path = item.path;
    }
    if (path == null) return DateTime.fromMillisecondsSinceEpoch(0);
    // 缓存优先：系统索引加载时已播种，未命中才 stat 一次并缓存。
    // 此前每次排序比较都 lastModifiedSync，O(N logN) 次主线程同步 stat
    // 是大存储设备「图片加载一部分后卡死」的直接根因。
    final cached = _mtimeCache[path];
    if (cached != null) return cached;
    try {
      final m = File(path).lastModifiedSync();
      _mtimeCache[path] = m;
      return m;
    } catch (_) {
      return DateTime.fromMillisecondsSinceEpoch(0);
    }
  }

  int _getSize(dynamic item) {
    if (item is SongModel) {
      try {
        return item.size;
      } catch (_) {}
      return 0;
    }
    if (item is FileSystemEntity) {
      final cached = _sizeCache[item.path];
      if (cached != null) return cached;
      try {
        final s = File(item.path).lengthSync();
        _sizeCache[item.path] = s;
        return s;
      } catch (_) {}
    }
    return 0;
  }

  /// getter 缓存戳：源列表身份 + 排序方式 + 排除路径列表身份。
  /// 列表被重新赋值（加载/删除/刷新）或排序/排除变化 → 戳变化 → 重算。
  int _stampFor(List a, List b, List excluded) =>
      Object.hash(identityHashCode(a), identityHashCode(b),
          identityHashCode(excluded), _sortOrder.index);
  List<CustomShortcutModel> get customShortcuts => _customShortcuts;
  List<String> get categoryOrder => _categoryOrder;
  List<String> get activeCategories => _activeCategories;
  bool get isLoading => _isLoading;
  bool get isLoaded => _isLoaded;
  bool get loadFailed => _loadFailed;
  /// 非媒体类别（文档/压缩包/下载/安装包）后台递归扫描是否已完成。
  /// 未完成期间分类页对这几个类别的空列表显示 shimmer 而非空状态。
  bool get nonMediaScanDone => _nonMediaScanDone;
  bool get nonMediaScanning => _nonMediaScanRunning;
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
    // 兜底：_isLoaded 尚未置 true（系统索引仍在后台刷新）但内存列表已自缓存恢复，
    // 直接返回真实列表长度，避免分类页显示陈旧持久化计数（音频恒0、图视恒数千）。
    switch (category) {
      case '图片': return _images.length;
      case '视频': return _videos.length;
      case '音频': return _audios.length;
      case '文档': return _documents.length;
      case '压缩包': return _archives.length;
      case '下载': return _downloads.length;
      case '安装包': return _apks.length;
      case '截图': return _screenshots.length;
      case '最近': return _recentFiles.length;
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
  /// 分类大小已在 isolate 扫描阶段累计（_fsCategorySizes），
  /// 主线程仅补充自定义路径（通常少量），不再对几十万文件同步 lengthSync 阻塞 UI。
  void _recalcCategorySizes() {
    // 从 isolate 扫描结果初始化（文件中已累计字节数，主线程无同步 stat）。
    _categorySizeCache['图片'] = (_fsCategorySizes['图片'] ?? 0) + _sumEntitySize(_customImages);
    _categorySizeCache['视频'] = (_fsCategorySizes['视频'] ?? 0) + _sumEntitySize(_customVideos);
    _categorySizeCache['截图'] = (_fsCategorySizes['截图'] ?? 0) + _sumEntitySize(_customScreenshots);

    // 音频：isolate 已计 base 音频，自定义音频使用 SongModel.size（由 _scanCustomCategories 从 file.stat() 填入，无需 lengthSync）。
    int audioSize = _fsCategorySizes['音频'] ?? 0;
    for (final s in _audios) {
      if (s.id >= 900000) {
        try { audioSize += s.size; } catch (_) {}
      }
    }
    _categorySizeCache['音频'] = audioSize;

    // 文档/压缩包/安装包：isolate 已计 base，自定义路径文件通常少量，直接用 _sumEntitySize 重算。
    if (_customCategoryPaths['文档']?.isNotEmpty ?? false) {
      _categorySizeCache['文档'] = _sumEntitySize(_documents);
    } else {
      _categorySizeCache['文档'] = _fsCategorySizes['文档'] ?? 0;
    }
    if (_customCategoryPaths['压缩包']?.isNotEmpty ?? false) {
      _categorySizeCache['压缩包'] = _sumEntitySize(_archives);
    } else {
      _categorySizeCache['压缩包'] = _fsCategorySizes['压缩包'] ?? 0;
    }
    if (_customCategoryPaths['安装包']?.isNotEmpty ?? false) {
      _categorySizeCache['安装包'] = _sumEntitySize(_apks);
    } else {
      _categorySizeCache['安装包'] = _fsCategorySizes['安装包'] ?? 0;
    }

    _categorySizeCache['下载'] = _fsCategorySizes['下载'] ?? 0;
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

  /// 元数据缓存文件位置。改用 ApplicationSupport（持久目录）：
  /// 临时目录会被系统在存储紧张时清理，缓存一旦丢失每次启动都要
  /// 重新全盘扫描——「打开应用后仍需等待一段时间才能显示部分类别」
  /// 的根因之一。读取时回退旧临时目录位置以兼容升级用户。
  Future<File> _metaCacheFile() async {
    final dir = await getApplicationSupportDirectory();
    return File('${dir.path}/media_meta_cache.json');
  }

  // ===================== 音频索引磁盘缓存（兜底，防永久消失） =====================
  // 系统音频走 MediaStore（on_audio_query），本身没有磁盘缓存兜底。当 provider 因
  // 内存压力被重建、或冷启动 MediaStore 瞬时繁忙导致 querySongs 偶发返回空列表时，
  // 内存中的 _audios 会被清空且刷新也救不回（大存储用户已复现：所有类别加载完成后
  // 音频计数归零、刷新无效）。故把成功加载的音频序列化落盘，作为「重查失败/重建」
  // 时的恢复源——只要曾成功加载过一次，就不会再永久消失。
  int _lastSavedAudioCount = -1;

  Future<File> _audioCacheFile() async {
    final dir = await getApplicationSupportDirectory();
    return File('${dir.path}/audio_index_cache.json');
  }

  /// 计算音频列表总字节数（含缓存恢复的音频），用于分类页总大小展示。
  /// 独立于 _loadAudios 内部代码，便于缓存恢复、部分结果保留等多路径复用。
  int _calcAudioSize(List<SongModel> songs) {
    int size = 0;
    for (final s in songs) {
      try {
        size += s.size;
      } catch (_) {}
    }
    return size;
  }

  Future<void> _saveAudioCache(List<SongModel> songs) async {
    if (songs.isEmpty || songs.length == _lastSavedAudioCount) return;
    try {
      final file = await _audioCacheFile();
      final list = <Map<dynamic, dynamic>>[];
      for (final s in songs) {
        try {
          list.add(s.getMap);
        } catch (_) {}
      }
      if (list.isEmpty) return;
      // 原子写入：先写临时文件再 rename 替换，避免数万首歌的大 JSON 在写入途中
      // 被系统杀进程（大存储设备后台重载耗时久、更易被杀）截断/损坏——
      // 损坏的缓存会让下次启动 jsonDecode 抛错、音频还原失败，叠加媒体库争抢
      // 时 querySongs 也返回空，最终音频被清零（仅大存储多文件设备复现）。
      final tmp = File('${file.parent.path}/.audio_index_cache.tmp');
      await tmp.writeAsString(jsonEncode(list));
      await tmp.rename(file.path);
      _lastSavedAudioCount = songs.length;
      debugPrint('[ZenFile] audio index cache saved: ${list.length}');
    } catch (e) {
      debugPrint('[ZenFile] _saveAudioCache error: $e');
    }
  }

  /// 从磁盘缓存恢复音频（仅当内存中 _audios 为空时调用）。返回是否恢复成功。
  /// 解码在隔离线程完成（_readAudioCacheIsolate），避免数万首歌的大 JSON 在主线程
  /// OOM/卡顿；文件缺失或损坏时返回 false，交由后续 _loadAudios 的 querySongs 兜底。
  Future<bool> _restoreAudioFromCache() async {
    if (_audios.isNotEmpty) return false;
    try {
      final file = await _audioCacheFile();
      if (!await file.exists()) return false;
      final decoded = await compute(_readAudioCacheIsolate, file.path);
      if (decoded == null) return false;
      final songs = <SongModel>[];
      for (final m in decoded) {
        try {
          songs.add(SongModel(Map<dynamic, dynamic>.from(m)));
        } catch (_) {}
      }
      if (songs.isNotEmpty) {
        _audios = songs;
        _audioFolders = _groupAudiosByParentDir(_audios);
        _fsCategorySizes['音频'] = _calcAudioSize(_audios);
        debugPrint('[ZenFile] audio index cache restored: ${songs.length}, '
            'size=${_fsCategorySizes['音频']}');
        return true;
      }
    } catch (e) {
      debugPrint('[ZenFile] _restoreAudioFromCache error: $e');
    }
    return false;
  }

  // ===================== 图片/视频/截图 磁盘缓存 =====================
  // 图片/视频此前每次启动都从 PhotoManager 重新分页拉取系统媒体库，大存储
  // 多文件设备（上万媒体）下需 ~1 分钟才能就绪，加载完成前列表为空、分类计数
  // 显示陈旧持久化值（音频恒0、图视恒数千）。这里把成功加载的图片/视频/截图
  // 路径（含 mtime）落盘，启动即从缓存恢复——毫秒级呈现、计数准确，且与音频
  // 缓存解耦：视频图片后台刷新不再阻塞/清空音频。
  Future<File> _mediaVisualCacheFile() async {
    final dir = await getApplicationSupportDirectory();
    return File('${dir.path}/media_visual_cache.json');
  }

  /// 把最新的图片/视频/截图路径（含 mtime）落盘，作为下次启动的毫秒级恢复源。
  /// 三列表全空时跳过写入，避免用空缓存覆盖上次完好数据。
  Future<void> _saveVisualCache(
    List<FileSystemEntity> imgs,
    List<FileSystemEntity> vids,
    List<FileSystemEntity> shots,
  ) async {
    if (imgs.isEmpty && vids.isEmpty && shots.isEmpty) return;
    try {
      final file = await _mediaVisualCacheFile();
      final toEntry = (FileSystemEntity e) => <String, dynamic>{
            'p': e.path,
            'm': _mtimeCache[e.path]?.millisecondsSinceEpoch ?? 0,
          };
      final map = <String, dynamic>{
        'images': imgs.map(toEntry).toList(),
        'videos': vids.map(toEntry).toList(),
        'screenshots': shots.map(toEntry).toList(),
      };
      // jsonEncode 在海量媒体（数十万路径）下可达数 MB，移到独立 isolate 编码，
      // 主线程仅做文件写入（IO 异步），避免阻塞键盘/输入（与 _saveCache 一致）。
      final json = await compute(jsonEncode, map);
      await file.writeAsString(json, flush: true);
      debugPrint('[ZenFile] visual media cache saved: '
          'img=${imgs.length} vid=${vids.length} shot=${shots.length}');
    } catch (e) {
      debugPrint('[ZenFile] _saveVisualCache error: $e');
    }
  }

  /// 从磁盘缓存恢复图片/视频/截图（仅当对应内存列表为空时），并播种 mtime 缓存
  /// 供排序零 stat。返回是否恢复过任意列表。
  Future<bool> _restoreVisualCache() async {
    bool restored = false;
    try {
      final file = await _mediaVisualCacheFile();
      if (!await file.exists()) return false;
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map) return false;
      void restore(String key, void Function(List<FileSystemEntity>) assign) {
        final raw = decoded[key];
        if (raw is! List) return;
        final list = <FileSystemEntity>[];
        for (final m in raw) {
          try {
            final map = m as Map;
            final path = map['p'] as String?;
            final ms = (map['m'] as int?) ?? 0;
            if (path == null || path.isEmpty) continue;
            list.add(File(path));
            if (ms > 0) {
              _mtimeCache[path] = DateTime.fromMillisecondsSinceEpoch(ms);
            }
          } catch (_) {}
        }
        if (list.isNotEmpty) {
          assign(list);
          restored = true;
        }
      }

      if (_images.isEmpty) {
        restore('images', (l) => _images = l);
      }
      if (_videos.isEmpty) {
        restore('videos', (l) => _videos = l);
      }
      if (_screenshots.isEmpty) {
        restore('screenshots', (l) => _screenshots = l);
      }
      if (restored) {
        debugPrint('[ZenFile] visual media cache restored: '
            'img=${_images.length} vid=${_videos.length} shot=${_screenshots.length}');
      }
    } catch (e) {
      debugPrint('[ZenFile] _restoreVisualCache error: $e');
    }
    return restored;
  }

  // ===================== 视频缩略图共享查询 + 并发限制 =====================
  // 每个视频瓦片原先各自 PhotoManager.getAssetListRange(0,1000) 再逐 asset 匹配，
  // 大存储（上万视频）下等于上万次并发 native 媒体查询打满设备线程，导致输入事件
  // 被丢弃、播放启动卡住、整屏卡死（用户反馈「必须等缩略图加载完才能打开/播放视频」）。
  // 改为：视频 AssetEntity 全局只取一次（分页覆盖全部，含超 1000 的视频）并共享，
  // 瓦片按路径直接命中；原生缩略图解码再经并发信号量限速，避免风暴。
  static Map<String, AssetEntity>? _videoAssetByPathCache;
  static bool _videoAssetCacheLoading = false;

  /// 全局只取一次视频 AssetEntity 并按「文件系统路径（小写）」建立共享索引。
  /// 成功匹配即返回对应 AssetEntity（用于缩略图），未命中返回 null（走原生生成兜底）。
  static Future<AssetEntity?> getVideoAssetByPath(String path) async {
    final lower = path.toLowerCase();
    if (_videoAssetByPathCache != null) return _videoAssetByPathCache![lower];
    if (_videoAssetCacheLoading) {
      // 首次构建缓存期间，等待其就绪后命中（避免重复拉取上万次）
      for (var i = 0; i < 60; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        if (_videoAssetByPathCache != null) return _videoAssetByPathCache![lower];
      }
      return _videoAssetByPathCache?[lower];
    }
    _videoAssetCacheLoading = true;
    try {
      final map = <String, AssetEntity>{};
      for (var start = 0; ; start += 500) {
        final batch = await PhotoManager.getAssetListRange(
          start: start,
          end: start + 500,
          type: RequestType.video,
        );
        for (final a in batch) {
          // 用与媒体列表一致的路径构造（relativePath + DISPLAY_NAME），
          // 避免逐 asset 调 originFile 的 native 开销，且能与瓦片路径精确匹配。
          final f = _assetToFile(a);
          if (f != null) map[f.path.toLowerCase()] = a;
        }
        if (batch.length < 500) break;
      }
      _videoAssetByPathCache = map;
      debugPrint('[ZenFile] video asset map built: ${map.length}');
      return map[lower];
    } catch (e) {
      debugPrint('[ZenFile] getVideoAssetByPath error: $e');
      return null;
    } finally {
      _videoAssetCacheLoading = false;
    }
  }

  /// 缩略图原生解码并发上限：避免上万视频同时发起 native 解码打满设备线程、
  /// 丢弃输入事件并卡住播放启动。
  static const int _kMaxThumbConcurrency = 6;
  static int _thumbRunning = 0;
  static final List<Completer<void>> _thumbWaiters = [];

  static Future<T> runBoundedThumb<T>(Future<T> Function() task) async {
    while (_thumbRunning >= _kMaxThumbConcurrency) {
      final c = Completer<void>();
      _thumbWaiters.add(c);
      await c.future;
    }
    _thumbRunning++;
    try {
      return await task();
    } finally {
      _thumbRunning--;
      if (_thumbWaiters.isNotEmpty) {
        _thumbWaiters.removeAt(0).complete();
      }
    }
  }

  Future<void> _loadFromDiskCache() async {
    try {
      var cacheFile = await _metaCacheFile();
      if (!await cacheFile.exists()) {
        // 兼容旧版：迁移前缓存位于临时目录
        final legacy = File(
            '${(await getTemporaryDirectory()).path}/media_meta_cache.json');
        if (await legacy.exists()) cacheFile = legacy;
      }
      if (await cacheFile.exists()) {
        final jsonStr = await cacheFile.readAsString();
        // decode + 逐文件 exists 全部在 isolate 内完成：大存储设备缓存条目可达
        // 数万，主 isolate 逐个 await exists() 会让 IO 回调淹没事件循环，
        // 表现为启动后持续卡顿（键盘/滑动掉帧）——红米K60Pro 反馈的卡顿根因之一。
        // 媒体（图/视/截/音）不再从缓存恢复：系统级索引毫秒级且权威。
        final r = await compute(_restoreCacheInIsolate, jsonStr);

        if (_documents.isEmpty && r.documents.isNotEmpty) {
          _documents = r.documents.map((e) => File(e)).toList();
        }
        if (_archives.isEmpty && r.archives.isNotEmpty) {
          _archives = r.archives.map((e) => File(e)).toList();
        }
        if (_downloads.isEmpty && r.downloads.isNotEmpty) {
          _downloads = r.downloads.map((e) => File(e)).toList();
        }
        if (_apks.isEmpty && r.apks.isNotEmpty) {
          _apks = r.apks.map((e) => File(e)).toList();
        }
        if (_recentFiles.isEmpty && r.recentFiles.isNotEmpty) {
          _recentFiles = r.recentFiles.map((entry) {
            final path = entry['path'] as String;
            return FileItemModel(
              entity: File(path),
              name: p.basename(path),
              path: path,
              isDirectory: false,
              size: (entry['size'] as num?)?.toInt() ?? 0,
              modified: DateTime.fromMillisecondsSinceEpoch(
                (entry['modified'] as num?)?.toInt() ?? 0,
              ),
            );
          }).toList();
        }
        // 恢复分类大小与媒体数量记录（供 _computeMediaCategorySizes 判断
        // 数量未变时直接沿用，避免每次启动全量 stat）
        _fsCategorySizes.addAll(r.categorySizes);
        _lastMediaCounts = Map<String, int>.from(r.mediaCounts);
        // 恢复目录增量缓存（非媒体扫描跳过 mtime 未变目录）
        final dc = r.dirCache;
        if (dc != null) {
          _dirCache = Map<String, Map<String, dynamic>>.from(dc);
        }
        _rebuildFolderGroups();
      }
    } catch (_) {}
  }

  /// 非媒体分类「主路径」：直接查询系统 MediaStore.Files（全量文件索引表）
  /// 填充文档/压缩包/安装包/下载，取代启动递归扫描。
  ///
  /// 参考猫头鹰文件(Skyjos File Explorer)：其分类由 ProtocolTypeMediaStore 协议
  /// 经 MediaStore.Files 按 media_type 查询得到，故在大存储多文件设备上不卡顿、
  /// 分类永远完整。ZenFile 此前用 dart:io 全盘递归（_runFileSystemScanInIsolate），
  /// 在数十万文件下会造成 I/O 饱和与整机卡顿、类别加载不全。
  ///
  /// 实现：原生 MethodChannel `com.sequl.zenfile/media_store` 调 ContentResolver
  /// 查询外部卷 Files 表，按扩展名（文档/压缩包/安装包）与路径关键字（下载）取
  /// path/size/modified，系统已预建索引→瞬时、穷尽、完整。
  ///
  /// 返回 true 表示成功取到数据；返回 false（通道不可用/无数据/异常）时调用方
  /// 应回退到递归扫描（_runFileSystemScanInIsolate）。
  Future<bool> _loadNonMediaViaMediaStore() async {
    try {
      const channel = MethodChannel('com.sequl.zenfile/media_store');
      // 清空上一次（或刷新前）的索引元数据缓存，避免陈旧路径残留导致误读。
      _nonMediaDates.clear();
      _nonMediaSizes.clear();

      // 1) 文档/压缩包/安装包：按扩展名一次性查询（取并集避免多次往返）。
      final unionExts = <String>{
        ..._docExtensions,
        ..._archiveExtensions,
        ..._apkExtensions,
      }.toList();
      final files = await channel.invokeListMethod<Map<dynamic, dynamic>>(
        'queryFiles',
        <String, dynamic>{'extensions': unionExts, 'pathContains': null},
      );
      if (files == null) return false;

      final docs = <FileSystemEntity>[];
      final arch = <FileSystemEntity>[];
      final apks = <FileSystemEntity>[];
      var docSize = 0;
      var archSize = 0;
      var apkSize = 0;
      for (final m in files) {
        final path = m['path'] as String?;
        if (path == null) continue;
        final size = (m['size'] as int? ?? 0);
        final modified = (m['modified'] as int? ?? 0);
        final ext = p.extension(path).toLowerCase();
        final f = File(path);
        // 缓存系统索引已提供的修改时间(ms)与字节数，供分类页零 I/O 读取。
        _nonMediaDates[path] = modified;
        _nonMediaSizes[path] = size;
        if (_docExtensions.contains(ext)) {
          docs.add(f);
          docSize += size;
        } else if (_archiveExtensions.contains(ext)) {
          arch.add(f);
          archSize += size;
        } else if (_apkExtensions.contains(ext)) {
          apks.add(f);
          apkSize += size;
        }
      }
      // MediaStore 未返回任何非媒体文件：可能索引/权限异常，回退递归扫描。
      if (docs.isEmpty && arch.isEmpty && apks.isEmpty) return false;

      _documents = docs;
      _archives = arch;
      _apks = apks;
      // 直接写入累计字节数，避免后续 _recalcCategorySizes 对海量文件重 stat。
      _fsCategorySizes['文档'] = docSize;
      _fsCategorySizes['压缩包'] = archSize;
      _fsCategorySizes['安装包'] = apkSize;

      // 2) 下载：路径含 /download/（覆盖 Download/Downloads 及 OEM 变体）。
      final dl = await channel.invokeListMethod<Map<dynamic, dynamic>>(
        'queryFiles',
        <String, dynamic>{'extensions': <String>[], 'pathContains': '/download/'},
      );
      final downloads = <FileSystemEntity>[];
      var dlSize = 0;
      for (final m in (dl ?? const <Map<dynamic, dynamic>>[])) {
        final path = m['path'] as String?;
        if (path == null) continue;
        final size = (m['size'] as int? ?? 0);
        final modified = (m['modified'] as int? ?? 0);
        downloads.add(File(path));
        _nonMediaDates[path] = modified;
        _nonMediaSizes[path] = size;
        dlSize += size;
      }
      _downloads = downloads;
      _fsCategorySizes['下载'] = dlSize;

      debugPrint('[ZenFile] MediaStore non-media query done: '
          'docs=${docs.length} arch=${arch.length} dl=${downloads.length} apk=${apks.length} '
          'dateCache=${_nonMediaDates.length} sizeCache=${_nonMediaSizes.length}');
      return true;
    } on PlatformException catch (e) {
      debugPrint('[ZenFile] MediaStore non-media query PlatformException, fallback: $e');
      return false;
    } catch (e) {
      debugPrint('[ZenFile] MediaStore non-media query failed, fallback: $e');
      return false;
    }
  }

  /// 后台执行非媒体类别（文档/压缩包/下载/安装包）的 isolate 递归扫描。
  /// 不阻塞 loadMedia 快路径（媒体已由系统索引提供、_isLoaded 已置 true）；
  /// 完成后合并自定义分类、排序并二次 notifyListeners 更新列表与首页计数。
  /// [force]：强制重扫（右上角刷新/仪表盘下拉刷新），直接采用本次扫描
  /// 结果替换旧列表（绕过并集兜底，清除已删除文件的幽灵条目）。
  Future<void> _scanNonMediaInBackground({bool force = false}) async {
    if (_nonMediaScanRunning) return;
    if (_nonMediaScanDone && !force) return;
    _nonMediaScanRunning = true;
    if (force) _nonMediaScanDone = false;
    // 无条件通知：分类页底部提示条可靠出现（无论懒加载触发还是强制刷新）
    notifyListeners();
    try {
      // 主路径：直接查询系统 MediaStore.Files 索引填充非媒体分类（参考猫头鹰文件
      // 的 ProtocolTypeMediaStore 协议）。系统已预建索引→瞬时、穷尽、完整，
      // 彻底消除 dart:io 全盘递归在数十万文件下的 I/O 饱和与类别加载不全。
      // 仅当 MediaStore 不可用/无数据时回退到递归扫描（不卡顿场景下等价兜底）。
      final viaMediaStore = await _loadNonMediaViaMediaStore();
      if (!viaMediaStore) {
        // MediaStore 索引不可用/无数据：回退 dart:io 递归扫描。
        await _runFileSystemScanInIsolate(force: force).catchError((Object e) {
          debugPrint('[ZenFile] background non-media scan failed, fallback: $e');
          return _loadMediaFromFileSystem();
        });
      }
      await _scanCustomCategories();
      await _applySort();
      _rebuildFolderGroups();

      PreferencesService.saveCategoryCount('文档', _documents.length);
      PreferencesService.saveCategoryCount('压缩包', _archives.length);
      PreferencesService.saveCategoryCount('下载', _downloads.length);
      PreferencesService.saveCategoryCount('安装包', _apks.length);
      _recalcCategorySizes();

      _nonMediaScanDone = true;
      notifyListeners();
      // 落盘前等待首次加载完成：进入类别页极快时扫描可能先于 loadMedia
      // 的缓存恢复结束，_saveCache 的 !_isLoaded 守卫会拦住导致扫描结果
      // 与 dirCache 丢失（下次启动又要全量重扫）。
      for (var i = 0; i < 100 && !_isLoaded; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      await _saveCache();
    } catch (e) {
      debugPrint('[ZenFile] _scanNonMediaInBackground error: $e');
      _nonMediaScanDone = true; // 失败也置完成，避免分类页永远 shimmer
      notifyListeners();
    } finally {
      _nonMediaScanRunning = false;
    }
  }

  Future<void> _saveCache() async {
    // 首次加载未完成前禁止落盘：此时列表可能仍是空/半恢复状态，
    // 保存会把上次的完整持久缓存覆盖成空（各类用户操作触发的即时
    // 保存同样受此保护）。
    if (!_isLoaded) return;
    // 「非空→空」保护：非媒体扫描已完成，但文档/压缩包/下载/安装包四类
    // 全部为空时，说明本次扫描极可能遇到存储瞬时异常（而非用户真删光）。
    // 此时禁止用空列表覆盖磁盘上的完好缓存，避免「重启后非媒体类别
    // 莫名全部消失、每次都要等待重扫」。
    if (_nonMediaScanDone &&
        _documents.isEmpty &&
        _archives.isEmpty &&
        _downloads.isEmpty &&
        _apks.isEmpty) {
      return;
    }
    try {
      final cacheFile = await _metaCacheFile();
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
        // 分类大小与媒体数量：下次启动直接恢复，媒体数量未变时不做全量 stat
        'fsCategorySizes': _fsCategorySizes,
        'mediaCounts': {
          '图片': _images.length,
          '视频': _videos.length,
          '截图': _screenshots.length,
        },
        // 目录增量缓存：非媒体扫描跳过 mtime 未变目录（二次启动毫秒级完成）
        'dirCache': _dirCache,
        // 注：媒体（图/视/截/音）路径不再缓存——系统级索引毫秒级提供，
        // 且数万条路径的序列化/恢复本身就是启动卡顿源。
      };
      // 把 CPU 密集的 jsonEncode 移到独立 isolate：海量媒体（数十万文件）序列化
      // 可达数 MB，主线程直接 encode 会阻塞数秒导致键盘/输入卡顿。compute 返回
      // 字符串后仅做文件写入（IO 异步，不占主线程）。
      final json = await compute(jsonEncode, map);
      await cacheFile.writeAsString(json, flush: true);
      // 清理旧版临时目录缓存（已被 ApplicationSupport 取代）
      try {
        final legacy = File(
            '${(await getTemporaryDirectory()).path}/media_meta_cache.json');
        if (await legacy.exists()) await legacy.delete();
      } catch (_) {}
    } catch (_) {}
  }

  /// 非媒体类别懒加载入口：进入对应分类页（文档/压缩包/下载/安装包）时
  /// 由 UI 调用。启动/onResume 不再自动扫描默认目录，避免后台全盘遍历
  /// 占用系统资源（与系统媒体扫描争抢 I/O 造成整机卡顿）。
  /// 已扫描过或正在扫描时为空操作；扫描期间已加载内容可正常操作。
  void ensureNonMediaScanned() {
    if (_nonMediaScanDone || _nonMediaScanRunning) return;
    unawaited(_scanNonMediaInBackground());
  }

  /// 强制重扫非媒体类别（供刷新入口调用，清除幽灵条目）。
  void forceRefreshNonMedia() {
    if (_nonMediaScanRunning) return;
    unawaited(_scanNonMediaInBackground(force: true));
  }

  Future<void> refreshMediaBackground() async {
    try {
      bool rawManageGranted = false;
      try {
        rawManageGranted = await Permission.manageExternalStorage.isGranted;
      } catch (_) {}
      // 媒体（图/视/音）走 PhotoManager 独立权限，刷新不依赖 dart:io 可访问性；
      // 此处仅更新 _storageAccessible 标志供非媒体扫描参考，不因此整体 return。
      _storageAccessible = await _verifyStorageAccess();
      debugPrint('[ZenFile] refreshMediaBackground storageAccessible=$_storageAccessible '
          '(manageExternalStorage.isGranted=$rawManageGranted)');

      // 防并发：若已有扫描在跑，直接跳过，避免多个全量扫描堆叠把主线程撑爆。
      if (_isLoading) return;
      // 关键守卫：首次加载（含磁盘缓存恢复）未完成前禁止后台刷新——
      // 冷启动 resumed 事件会先于 loadMedia 的缓存恢复到达，此时刷新会把
      // 空列表 + 空 dirCache 写入持久缓存，覆盖掉上次的完整缓存，
      // 表现为「重启应用后文档/压缩包/安装包等类别莫名消失，每次都要等待重扫」。
      if (!_isLoaded) return;
      // 节流：与上一次刷新间隔不足 30s 时跳过，避免在 onResume 频繁触发时
      // 反复全量扫描导致 UI 卡死（「打开 app 几秒后卡死」的根因之一）。
      final now = DateTime.now();
      if (_lastBackgroundRefresh != null &&
          now.difference(_lastBackgroundRefresh!) < const Duration(seconds: 30)) {
        return;
      }
      _lastBackgroundRefresh = now;

      // 与 loadMedia 一致：先独占式加载音频（querySongs 拿到全量，避免与 PhotoManager
      // fetchAll 并发抢 MediaStore 导致 querySongs 返回空、叠加缓存缺失时音频清零），
      // 再加载视频图片。
      await _loadAudios();
      await _loadImagesAndVideos().then((_) => _computeMediaCategorySizes());
      await _scanCustomCategories();
      await _scanRecentFiles();
      await _saveCache();
      await _applySort();
      _rebuildFolderGroups();
      // 非媒体类别不再随 onResume 自动扫描（懒加载：进入分类页时才触发）

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

  /// 在独立 isolate 中完成主存储递归扫描，避免主线程被百万级文件枚举占满。
  /// 图片/视频/截图/音频已改回系统级索引（PhotoManager/on_audio_query，
  /// 与 NFile 1.1.22 一致——递归扫描媒体会在大存储设备上造成 I/O 饱和、
  /// 与系统媒体扫描争抢存储导致整机卡顿，红米K60Pro反馈），
  /// isolate 仅扫描无系统索引的类别：文档/压缩包/下载/安装包。
  Future<void> _runFileSystemScanInIsolate({bool force = false}) async {
    final searchDirs = await _getUserSearchDirs();
    debugPrint('[ZenFile] non-media scan start: rootDirs=$searchDirs '
        'storageAccessible=$_storageAccessible');
    if (searchDirs.isEmpty) return;
    // dart:io 存储访问探测失败（MIUI/澎湃误报 manageExternalStorage，或存储瞬时
    // 繁忙导致首列超时）时，不再直接跳过整个扫描——否则表现为「类别加载不出完全
    // / 空白」。仍尝试递归扫描：若目录真不可读，isolate 内 list() 抛异常并由 catch
    // 沿用缓存，mergeGuarded 会保留旧列表，空结果不会清空已显示内容。后续可接
    // MediaStore 兜底以彻底消除 dart:io 不可访问场景。
    if (!_storageAccessible) {
      debugPrint('[ZenFile] 注意: dart:io 存储访问探测失败，仍尝试递归扫描'
          '（不可读目录将沿用缓存，空结果保留上次列表）');
    }
    final params = _FSScanParams(
      roots: searchDirs,
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
      skipMediaCategories: true,
      dirCache: _dirCache,
    );
    final result = await compute(_scanMediaFileSystemIsolate, params);
    // isolate 跳过了媒体收集，其 categorySizes 不含媒体键；
    // 整 map 替换前保留媒体大小（由系统索引路径 _computeMediaCategorySizes/_loadAudios 维护）。
    final newSizes = Map<String, int>.from(result.categorySizes);
    for (final k in const ['图片', '视频', '截图', '音频']) {
      final v = _fsCategorySizes[k];
      if (v != null) newSizes[k] = v;
    }
    _fsCategorySizes = newSizes;
    // 更新目录缓存（枚举失败时兜底用，不再以 mtime 跳过枚举）
    _dirCache = result.dirCache;
    // 合并保护：isolate 扫描可能因存储瞬时异常返回偏少/空结果，直接覆盖会
    // 让已显示的条目「莫名全部消失」。
    // - 新结果为空：极可能是存储瞬时异常，保留旧列表（绝不因空扫描清空）；
    //   同时 _saveCache 的非空保护会拦截空结果落盘，避免磁盘缓存被覆盖成空。
    // - 新结果不足旧列表一半且非强制刷新：并集兜底，保留旧条目，下次扫描修正。
    // - 强制刷新且扫描健康：直接替换，清除已删除文件的幽灵条目。
    List<FileSystemEntity> mergeGuarded(
        List<FileSystemEntity> oldFiles, List<String> newPaths) {
      final newFiles = newPaths.map((e) => File(e)).toList();
      if (newFiles.isEmpty) {
        // 空结果：保留旧列表，防止瞬时空扫描导致内容消失。
        return oldFiles;
      }
      if (!force && oldFiles.isNotEmpty && newFiles.length < oldFiles.length / 2) {
        final seen = newPaths.toSet();
        return [...newFiles, ...oldFiles.where((f) => !seen.contains(f.path))];
      }
      return newFiles;
    }
    _documents = mergeGuarded(_documents, result.documents);
    _archives = mergeGuarded(_archives, result.archives);
    _downloads = mergeGuarded(_downloads, result.downloads);
    _apks = mergeGuarded(_apks, result.apks);
    // 分组已在 isolate 内算好，直接赋值，主线程不再做 O(n) 遍历分组。
    // 媒体分组随后由 _rebuildFolderGroups() 从系统索引列表重建（loadMedia 尾部统一调用）。
    // 分类大小已在上方合并（isolate 非媒体值 + 保留的媒体值）。
    debugPrint('[ZenFile] isolate scan (non-media only) done: docs=${_documents.length} arch=${_archives.length} dl=${_downloads.length} apk=${_apks.length}');
  }

  /// 与 main.dart 一致的真实存储访问探测：permission_handler 在 MIUI/澎湃等
  /// ROM 上可能误报 manageExternalStorage 的授权状态（true 时 dart:io 仍读不到、
  /// false 时实际已全部授权），故用一次真实目录枚举确认 dart:io 是否真能访问
  /// 主存储。返回 false 时非媒体递归扫描必然为空，需走 MediaStore 兜底。
  Future<bool> _verifyStorageAccess() async {
    try {
      final dir = Directory('/storage/emulated/0');
      await dir
          .list(followLinks: false, recursive: false)
          .first
          .timeout(const Duration(seconds: 3));
      return true;
    } catch (_) {
      return false;
    }
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

      // 用户主动刷新（右上角刷新按钮/仪表盘下拉刷新/onResume）：强制重扫非媒体。
      // 暂存该 Future，待媒体快路径加载完成后再 await，确保整个刷新（含非媒体
      // 后台扫描）期间 _isLoading 始终为真——刷新按钮据此保持禁用/置灰，既防止
      // 用户狂点刷新重复触发全量扫描，也避免重扫过程并发重建导致闪退。
      Future<void>? pendingForceScan;
      if (forceRefresh) {
        pendingForceScan = _scanNonMediaInBackground(force: true);
      }

      // Fast initial load from disk cache
      await _loadFromDiskCache();
      // 音频冷启动兜底：磁盘缓存本身不恢复音频，若内存为空先尝试从音频索引
      // 缓存恢复，保证「曾成功加载过的音频」不会因 provider 重建或 MediaStore
      // 瞬时繁忙而永久消失（大存储用户已复现：加载完成后音频计数归零、刷新无效）。
      if (_audios.isEmpty) {
        await _restoreAudioFromCache();
      }
      // 图片/视频/截图同样从磁盘缓存恢复（此前每次启动都重新分页拉取 PhotoManager，
      // 大存储设备需 ~1 分钟才就绪，且加载完成前列表为空、分类计数显示陈旧持久化值）。
      if (_images.isEmpty || _videos.isEmpty || _screenshots.isEmpty) {
        await _restoreVisualCache();
      }
      // 缓存加载后立即通知，让界面显示缓存数据，避免空状态等待
      notifyListeners();
      // 关键：缓存恢复后立即把 _isLoaded 置 true，使分类计数/列表立刻反映真实
      // （缓存）数据，不再显示陈旧持久化计数（音频恒0、图视恒数千），也消除「须等
      // 视频图片后台重载完成才显示」的 ~1 分钟空窗。下方系统索引刷新仍在后台执行，
      // 完成后 notifyListeners 刷新即可。仅非强制刷新时提前置位，强制刷新保持原行为。
      if (!forceRefresh) {
        _isLoaded = true;
      }

      // 存储可访问性判断：permission_handler 的 isGranted 在部分 ROM 上会误报，
      // 故用真实目录枚举二次确认 dart:io 能否真正访问主存储。媒体（图/视/音）
      // 走 PhotoManager 独立权限，不依赖此判断；此标志仅决定非媒体 dart:io
      // 递归扫描是否可用。不再因权限误判整体 return，避免媒体也跟着加载失败。
      bool rawManageGranted = false;
      try {
        rawManageGranted = await Permission.manageExternalStorage.isGranted;
      } catch (_) {}
      _storageAccessible = await _verifyStorageAccess();
      debugPrint('[ZenFile] loadMedia storageAccessible=$_storageAccessible '
          '(manageExternalStorage.isGranted=$rawManageGranted)');

      // ===== 快路径（毫秒级）：媒体走系统级索引（MediaStore），与 NFile 一致 =====
      // 非媒体（文档/压缩包/下载/安装包）的全盘递归遍历改到后台执行，
      // 不再阻塞 _isLoaded——256GB 设备目录树遍历可达 30s+，期间 I/O 饱和
      // 是「改回系统索引后启动仍卡」的主因（红米K60Pro反馈）。
      // 串行而非并行：大存储多文件设备上，PhotoManager 的 fetchAll（分页猛拉数万
      // 媒体）与 on_audio_query 的 querySongs 并发抢 MediaStore，会使 querySongs 在
      // 媒体库繁忙时返回空/部分结果，且此刻若音频缓存恰好缺失或损坏（见
      // _saveAudioCache 原子写入说明），_audios 便无可靠来源而清零——表现为「视频
      // 图片加载完成后音频被清空」（仅大存储设备复现）。改为先独占式加载音频
      // （querySongs 拿到全量），再加载视频图片，彻底消除争抢。
      await _loadAudios();
      await _loadImagesAndVideos().then((_) => _computeMediaCategorySizes());

      // 启动即后台快速扫描非媒体类别（限定深度的热点目录，毫秒级完成），
      // 让首页分类计数与文档/压缩包/下载/安装包类别在用户进入前就就绪，
      // 消除「每次都要进类别等很久」的体感。_scanNonMediaInBackground 内部
      // 自带并发/重复守卫，不会与懒加载或强制刷新叠加。
      // 强制刷新已由上方 pendingForceScan 覆盖，此处仅在初始（非强制）加载时启动，避免重复扫描。
      if (!forceRefresh) {
        unawaited(_scanNonMediaInBackground());
      }

      await _scanCustomCategories();
      await _scanRecentFiles();

      await _applySort();
      _rebuildFolderGroups();

      // 强制刷新：等待非媒体重扫真正完成后再翻 _isLoading=false（刷新按钮恢复可点）。
      if (pendingForceScan != null) {
        await pendingForceScan;
      }

      PreferencesService.saveCategoryCount('图片', images.length);
      PreferencesService.saveCategoryCount('视频', videos.length);
      PreferencesService.saveCategoryCount('音频', _audios.length);
      PreferencesService.saveCategoryCount('截图', screenshots.length);
      _recalcCategorySizes();

      _isLoading = false;
      _isLoaded = true;
      _loadFailed = false;
      notifyListeners();
    } catch (e) {
      debugPrint('loadMedia error: $e');
      _isLoading = false;
      // 扫描中途异常：标记失败，浏览页显示「加载失败 + 重试」而非无限 shimmer
      _loadFailed = true;
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
      for (final root in searchDirs) {
        await _scanDirectoryRecursively(
          root.path,
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
      // 仅当本次递归扫描确实找到音频时才覆盖；若扫描被打断/过滤为空，
      // 不得用空列表清空已通过系统索引加载的 _audios（会导致音频莫名消失）。
      if (audios.isNotEmpty) {
        _audios = audios;
      }
      _screenshots = screenshots;
      _rebuildFolderGroups();
      debugPrint('[ZenFile] _loadMediaFromFileSystem: images=${images.length}, videos=${videos.length}, audios=${audios.length}, screenshots=${screenshots.length}');
    } catch (e) {
      debugPrint('[ZenFile] _loadMediaFromFileSystem error: $e');
    }
  }

  /// 把系统索引 AssetEntity 解析为本地 File（纯内存拼接，无文件 IO）。
  /// Android 的 relativePath 形如 `DCIM/Camera/`（带尾斜杠），
  /// title 即 DISPLAY_NAME（含扩展名，见 photo_manager entity.dart 文档）。
  static File? _assetToFile(AssetEntity a) {
    final rel = a.relativePath;
    final title = a.title;
    if (title == null || title.isEmpty) return null;
    final cleanRel = (rel ?? '').endsWith('/')
        ? (rel!.length > 1 ? rel.substring(0, rel.length - 1) : '')
        : (rel ?? '');
    String dir;
    if (cleanRel.startsWith('/storage/')) {
      dir = cleanRel;
    } else if (cleanRel.startsWith('storage/')) {
      dir = '/$cleanRel';
    } else if (cleanRel.isEmpty) {
      dir = '/storage/emulated/0';
    } else {
      dir = '/storage/emulated/0/$cleanRel';
    }
    return File('$dir/$title');
  }

  /// 图片/视频/截图：改回系统级索引（MediaStore，经 PhotoManager 查询，
  /// 与 NFile 原实现一致）。列表元素仍为 File（路径来自索引的
  /// relativePath + DISPLAY_NAME 拼接），下游（分类页/缩略图/文件夹分组）零改动。
  /// 注：photo_manager 3.9.0 的 AssetEntity 无文件字节大小属性（size 是宽高维度），
  /// 分类大小由 [_computeMediaCategorySizes] 在 isolate 内 stat 完成。
  Future<void> _loadImagesAndVideos() async {
    try {
      // NFile 权限策略：主流程已确保 MANAGE_EXTERNAL_STORAGE；
      // Android 13+ 无 READ_MEDIA_* 运行时权限时，跳过 photo_manager
      // 内置权限校验直接读 MediaStore（文件管理器的合法用法）。
      try {
        if (await Permission.manageExternalStorage.isGranted) {
          await PhotoManager.setIgnorePermissionCheck(true);
        }
      } catch (_) {}

      final albums = await PhotoManager.getAssetPathList(onlyAll: false);
      if (albums.isEmpty) return;

      // 截图：名字含 screenshot 的系统相册（小米/澎湃OS 为 DCIM/Screenshots）
      // 循环分页取全：单页上限会截断超量相册（「截图显示不全」）
      final screenshotFiles = <File>{};
      for (final album in albums) {
        if (album.name.toLowerCase().contains('screenshot')) {
          try {
            for (var page = 0; ; page++) {
              final assets = await album.getAssetListPaged(page: page, size: 2000);
              for (final a in assets) {
                final f = _assetToFile(a);
                if (f != null) screenshotFiles.add(f);
              }
              if (assets.length < 2000) break;
            }
          } catch (_) {}
        }
      }

      final allAlbum = albums.firstWhere((a) => a.isAll, orElse: () => albums.first);
      // 循环分页加载全部媒体：此前单页 10000 上限，大存储用户媒体数
      // 超过 1 万时被静默截断——「图片/视频显示内容不全」的根因。
      Future<List<AssetEntity>> fetchAll() async {
        final out = <AssetEntity>[];
        for (var page = 0; ; page++) {
          final batch = await allAlbum.getAssetListPaged(page: page, size: 2000);
          out.addAll(batch);
          if (batch.length < 2000) break;
        }
        return out;
      }

      var allMedia = await fetchAll();
      if (allMedia.isEmpty) {
        // 冷启动 MediaStore 瞬时未就绪：延迟后重试一次（与音频一致）
        await Future<void>.delayed(const Duration(milliseconds: 600));
        allMedia = await fetchAll();
      }
      // Set 收集（保持插入序）：防御分页边界重复 / 部分 ROM「全部」相册
      // 与截图相册返回同一 asset 导致的同路径重复收录
      final imgs = <File>{};
      final vids = <File>{};
      final shots = <File>{};
      for (final a in allMedia) {
        final f = _assetToFile(a);
        if (f == null) continue;
        // 播种 mtime 缓存：MediaStore 索引自带修改时间，排序零 stat
        // （此前转 File 时丢弃日期，导致排序时对几万文件逐个 lastModifiedSync）
        try {
          _mtimeCache[f.path] = a.modifiedDateTime;
        } catch (_) {}
        if (a.type == AssetType.image) {
          final isShot = screenshotFiles.contains(f) ||
              (a.relativePath ?? '').toLowerCase().contains('screenshot') ||
              (a.title ?? '').toLowerCase().contains('screenshot');
          if (isShot) {
            shots.add(f);
          } else {
            imgs.add(f);
          }
        } else if (a.type == AssetType.video) {
          vids.add(f);
        }
      }
      // 系统截图相册优先；补上「全部媒体」里按路径/文件名兜底判定到的截图
      for (final f in screenshotFiles) {
        if (!shots.contains(f)) shots.add(f);
      }
      // 空结果不覆盖旧数据（与音频一致）：系统库瞬时异常时保留上次列表
      if (imgs.isNotEmpty || _images.isEmpty) _images = imgs.toList();
      if (vids.isNotEmpty || _videos.isEmpty) _videos = vids.toList();
      if (shots.isNotEmpty || _screenshots.isEmpty) _screenshots = shots.toList();
      debugPrint('[ZenFile] system index: images=${imgs.length} videos=${vids.length} screenshots=${shots.length}');
      // 落盘：作为下次启动的毫秒级恢复源，避免「每次启动都要重新分页拉取
      // PhotoManager、大存储设备等待 ~1 分钟才显示图视」的体感。空结果不覆盖
      // （上方已用「非空或原为空才赋值」守卫，系统库瞬时异常时 _images 等保留旧值）。
      await _saveVisualCache(_images, _videos, _screenshots);
    } catch (e) {
      debugPrint('[ZenFile] _loadImagesAndVideos (system index) error: $e');
    }
  }

  /// 在 isolate 内对系统索引返回的媒体路径 stat 出各分类字节总和。
  /// 媒体数量与上次持久化值一致时直接沿用持久化大小（零 IO）——
  /// 对几万个文件全量 stat 会造成 I/O 饱和、与系统媒体扫描争抢存储，
  /// 是「改回系统索引后仍卡顿」的根因之一（红米K60Pro反馈）。
  Future<void> _computeMediaCategorySizes() async {
    try {
      final cur = <String, int>{
        '图片': _images.length,
        '视频': _videos.length,
        '截图': _screenshots.length,
      };
      final last = _lastMediaCounts;
      if (last != null &&
          last['图片'] == cur['图片'] &&
          last['视频'] == cur['视频'] &&
          last['截图'] == cur['截图'] &&
          _fsCategorySizes.containsKey('图片') &&
          _fsCategorySizes.containsKey('视频') &&
          _fsCategorySizes.containsKey('截图')) {
        return; // 数量未变，沿用持久化大小
      }
      final imgPaths = _images.map((e) => e.path).toList();
      final vidPaths = _videos.map((e) => e.path).toList();
      final shotPaths = _screenshots.map((e) => e.path).toList();
      final results = await Future.wait([
        compute(_sumFileSizesInIsolate, imgPaths),
        compute(_sumFileSizesInIsolate, vidPaths),
        compute(_sumFileSizesInIsolate, shotPaths),
      ]);
      _fsCategorySizes['图片'] = results[0];
      _fsCategorySizes['视频'] = results[1];
      _fsCategorySizes['截图'] = results[2];
      _lastMediaCounts = cur;
    } catch (e) {
      debugPrint('[ZenFile] _computeMediaCategorySizes error: $e');
    }
  }

  /// 音频：改回系统级索引（MediaStore Audio 表，经 on_audio_query 查询）。
  /// SongModel._data 为完整路径，文件夹分组/播放器/缓存逻辑零改动。
  Future<void> _loadAudios() async {
    try {
      bool isStorageGranted = false;
      try {
        isStorageGranted = await Permission.storage.isGranted ||
            await Permission.manageExternalStorage.isGranted;
      } catch (_) {}

      if (!isStorageGranted) {
        final hasPerm = await _audioQuery.permissionsStatus();
        if (!hasPerm) {
          // 不盲目清空：若已加载到音频则保留，避免 onResume/刷新重扫时把
          // 已显示的音频清掉导致「加载出来后莫名消失」。音频走 MediaStore，
          // 权限判断偶发误报不应清空既有结果。
          debugPrint('[ZenFile] _loadAudios 无音频读取权限，保留现有 ${_audios.length} 条');
          return;
        }
      }

      // 大存储 / 多文件设备上，冷启动的 MediaStore 音频表可能瞬时未就绪，
      // querySongs 偶发返回空列表（不抛异常）。这里做多次重试（指数退避），
      // 拿到非空结果即采用；重试后仍为空时：若此前已有数据则保留旧数据，
      // 避免「音频页面时灵时不灵，点进去有时是空白」。视频/图片走 PhotoManager
      // 不受影响，故仅音频需要此兜底。
      List<SongModel>? songs;
      const maxAttempts = 4;
      // 多试几次保留「最大」集合：大存储设备 MediaStore 瞬时未就绪时 querySongs
      // 可能先返回部分结果（甚至空集），若拿到部分结果就 break 会把已显示的音频
      // 冲掉→「音频数量变少/消失」。故累计各次非空结果、保留最多者，不提前退出。
      List<SongModel>? best;
      for (int attempt = 0; attempt < maxAttempts; attempt++) {
        if (attempt > 0) {
          await Future<void>.delayed(Duration(milliseconds: 400 * attempt));
        }
        try {
          final result = await _audioQuery.querySongs(
            sortType: null,
            orderType: OrderType.ASC_OR_SMALLER,
            uriType: UriType.EXTERNAL,
            ignoreCase: true,
          );
          if (result.isNotEmpty) {
            if (best == null || result.length > best.length) best = result;
          }
        } catch (e) {
          debugPrint('[ZenFile] _loadAudios querySongs attempt $attempt 出错: $e');
        }
      }
      songs = best;

      if (songs != null && songs.isNotEmpty) {
        // 仅在结果不比现有更少时覆盖：后台刷新（onResume）若拿到部分结果
        // （MediaStore 重索引中），不得用更少的结果把已显示的音频冲掉导致「消失」。
        if (_audios.isEmpty || songs.length >= _audios.length) {
          _audios = songs;
          int audioSize = 0;
          for (final s in songs) {
            try {
              audioSize += s.size;
            } catch (_) {}
          }
          _fsCategorySizes['音频'] = audioSize;
          // 紧跟 _audios 重建音频文件夹分组，确保分类页「文件夹」视图与全部项目
          // 始终同源（避免 _audios 已就绪但 _audioFolders 仍为空导致文件夹视图空白）。
          _audioFolders = _groupAudiosByParentDir(_audios);
          final emptyData = songs.where((s) => s.data.isEmpty).length;
          debugPrint('[ZenFile] system index: audios=${songs.length}, '
              'audioFolders=${_audioFolders.length}, emptyData=$emptyData');
          // 落盘：作为「重查失败/provider 重建」时的恢复源，避免音频永久消失。
          await _saveAudioCache(_audios);
        } else {
          debugPrint('[ZenFile] _loadAudios 新结果(${songs.length})少于现有'
              '(${_audios.length})，保留现有音频，避免被部分结果冲掉');
        }
      } else if (_audios.isEmpty) {
        // 多次重试仍为空：尝试从磁盘缓存恢复（曾成功加载过则不会就此消失）。
        final restored = await _restoreAudioFromCache();
        if (!restored) {
          debugPrint('[ZenFile] system index: audios 多次重试仍为空且无缓存');
        }
      }
      // 兜底：无论音频来自 querySongs 还是缓存恢复，只要 _audios 非空就确保
      // _fsCategorySizes['音频'] 已计算。大存储设备 querySongs 可能返回空/部分结果，
      // 而缓存恢复分支只填充 _audios 未补大小——会导致分类页音频「有数量无大小」。
      if (_audios.isNotEmpty && (_fsCategorySizes['音频'] ?? 0) == 0) {
        _fsCategorySizes['音频'] = _calcAudioSize(_audios);
        debugPrint('[ZenFile] _loadAudios 兜底补算音频大小: '
            'count=${_audios.length}, size=${_fsCategorySizes['音频']}');
      }
      // 若 songs 为空但 _audios 已有数据，则保留旧数据（不覆盖）
    } catch (e) {
      // 查询失败保留旧数据：系统媒体库瞬时繁忙（onResume 后台刷新时常见）
      // 直接清空会导致「音频加载出来后莫名消失」
      debugPrint('[ZenFile] _loadAudios (system index) error: $e');
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

  /// 返回非媒体扫描的「热点根 + 每根最大深度」。
  /// 不再对整棵 /storage/emulated/0 做无深度限制的全量递归（那是「打开应用后
  /// 要等很久才显示」的主因，且在切换/后台时扫描常被丢弃导致「时有时无」）。
  /// 改为：主目录仅扫 1 层（兜住散落的松散文件），其余标准/常见目录按 4 层深扫。
  /// 覆盖文档/压缩包/安装包/下载的绝大多数真实位置，扫描量从全树降到极小。
  Future<List<_ScanRoot>> _getUserSearchDirs() async {
    final roots = <_ScanRoot>[];
    try {
      final rootDir = Directory('/storage/emulated/0');
      if (await rootDir.exists()) {
        // 主目录浅层兜底：直接文件 + 一级子目录（depth 1）。
        roots.add(const _ScanRoot('/storage/emulated/0', 1));
        // 热点深扫（depth 4）：文档/压缩包/安装包/下载绝大多数位于这些标准目录。
        const hotspots = [
          '/storage/emulated/0/Download',
          '/storage/emulated/0/Downloads',
          '/storage/emulated/0/Documents',
          '/storage/emulated/0/DCIM',
          '/storage/emulated/0/Pictures',
          '/storage/emulated/0/Movies',
          '/storage/emulated/0/Telegram',
          '/storage/emulated/0/WhatsApp',
          '/storage/emulated/0/MIUI',
          '/storage/emulated/0/cloud',
          '/storage/emulated/0/BaiduNetdisk',
          '/storage/emulated/0/QuarkDownloads',
          '/storage/emulated/0/apk',
          '/storage/emulated/0/APK',
        ];
        for (final h in hotspots) {
          roots.add(_ScanRoot(h, 4));
        }
        return roots;
      }
    } catch (_) {}

    // 退回：主目录不可用时，仅扫描常见媒体/文档目录。
    return const [
      _ScanRoot('/storage/emulated/0/Download', 4),
      _ScanRoot('/storage/emulated/0/Downloads', 4),
      _ScanRoot('/storage/emulated/0/Documents', 4),
      _ScanRoot('/storage/emulated/0/Telegram', 4),
      _ScanRoot('/storage/emulated/0/WhatsApp', 4),
    ];
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
              // 跳过隐藏目录、Android、本应用缓存目录（避免远程媒体/缩略图缓存被重复收录）。
              if (!name.startsWith('.') &&
                  name != 'Android' &&
                  !_isUnderAppCacheDir(entity.path)) {
                queue.add(entity.path);
              }
            } else if (entity is File) {
              if (_isUnderAppCacheDir(entity.path)) continue;
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

    for (final root in searchDirs) {
      final dirPath = root.path;
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

    for (final root in searchDirs) {
      final dirPath = root.path;
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
        // 远程下载路径递归扫描（与图片/文档等一致，支持子目录）。
        try {
          final remoteFiles = await _scanRemotePath(dirPath, (_) => true);
          customDls.addAll(remoteFiles);
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

        await _scanRemoteDirectoryRecursively(
          client,
          effectivePath,
          filter,
          connectionId,
          (remoteFilePath, size, modified) {
            final encodedPath = 'remote://$connectionId|$remoteFilePath';
            files.add(File(encodedPath));
            _remoteFileSizes[encodedPath] = size;
            _remoteFileModified[encodedPath] = modified;
          },
        );
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
    String connectionId,
    void Function(String remoteFilePath, int size, DateTime modified) onFileFound, {
    int depth = 0,
  }) async {
    if (depth > 5) return; // 限制递归深度防止过深扫描
    try {
      final items = await client.listDirectory(path);
      for (final item in items) {
        if (item.isDirectory) {
          await _scanRemoteDirectoryRecursively(
              client, item.path, filter, connectionId, onFileFound,
              depth: depth + 1);
        } else {
          // 与本地 _scanDirectoryRecursively 保持一致：传「扩展名（含点，小写）」给 filter，
          // 这样文档/压缩包/安装包的 `(ext) => _xxExtensions.contains(ext)` 才能正确匹配
          // （此前误传完整文件名导致远程文档等永远扫描不到）。
          final ext = p.extension(item.name).toLowerCase();
          if (filter(ext)) {
            onFileFound(item.path, item.size, item.modified);
          }
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
            // 跳过隐藏目录、Android、本应用缓存目录（ZenFile），
            // 避免远程媒体/缩略图缓存进入「最近」。
            if (!name.startsWith('.') &&
                name != 'Android' &&
                !_isUnderAppCacheDir(entity.path)) {
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
  /// 分批执行（每批 200）且跳过已缓存路径——此前 Future.wait 对几万文件
  /// 一次性并发 stat，IO 回调瞬间淹没事件循环，启动后 UI 直接卡死。
  Future<Map<String, ({int size, DateTime modified})>> _preloadStats(
    List<FileSystemEntity> entities,
  ) async {
    final map = <String, ({int size, DateTime modified})>{};
    final pending = <FileSystemEntity>[];
    for (final e in entities) {
      if (_mtimeCache.containsKey(e.path)) {
        map[e.path] = (size: _sizeCache[e.path] ?? 0, modified: _mtimeCache[e.path]!);
      } else {
        pending.add(e);
      }
    }
    const batch = 200;
    for (var i = 0; i < pending.length; i += batch) {
      final chunk = pending.skip(i).take(batch).toList();
      await Future.wait(chunk.map((e) async {
        try {
          final stat = await File(e.path).stat();
          map[e.path] = (size: stat.size, modified: stat.modified);
        } catch (_) {}
      }));
      // 批间让出事件循环，保持 UI 响应
      await Future<void>.delayed(Duration.zero);
    }
    // 回填缓存：getter 排序（_getDateTime/_getSize）此后零 stat
    map.forEach((path, v) {
      _mtimeCache[path] = v.modified;
      _sizeCache[path] = v.size;
    });
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
