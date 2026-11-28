import 'dart:async';
import 'dart:collection';
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
import '../services/build_trigger_counter.dart';
import '../services/slow_op.dart';
import '../services/recycle_bin_service.dart';
import '../services/startup_gate.dart';
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

/// 本应用自身的缓存/临时目录：本地递归扫描时应跳过这些目录，避免把远程媒体
/// 下载缓存、解密副本、安装中间产物等再次当成用户文件收录（导致重复条目）。
///
/// 注意：**不可整目录屏蔽 `/storage/emulated/0/ZenFile`** —— 用户数据就在其下：
/// 安装包备份 `ZenFile/Backups/Apps`、保险箱导出 `ZenFile/Backups/safe`、
/// 快传接收 `ZenFile/Receive`。整目录屏蔽会让这些用户文件（尤其安装包）永远
/// 扫不到（表现为「安装包类别里看不到自己备份的 apk」）。此处只精确屏蔽
/// 真正的缓存/中间目录；隐藏缓存目录（`.remote_cache`/`.crypt_tmp`/`.temp_*`）
/// 已由扫描器的「跳过隐藏目录」规则排除，无需在此列出。
const List<String> _kAppCacheExcludeDirs = [
  '/storage/emulated/0/ZenFile/cache',
  '/storage/emulated/0/ZenFile/RemoteDecrypted',
  '/storage/emulated/0/ZenFile/apk_install',
  '/storage/emulated/0/ZenFile/apk_extract',
  '/storage/emulated/0/ZenFile/crash',
];

/// 判断路径是否落在本应用缓存目录下（供 isolate 与主线程扫描共用）。
bool _isUnderAppCacheDir(String path) {
  for (final d in _kAppCacheExcludeDirs) {
    if (path == d || path.startsWith('$d/')) return true;
  }
  return false;
}

/// Windows 系统目录：媒体扫描一律不进入。
/// AppData 单目录可达数十万文件、Windows/Program Files 为系统文件——
/// 不剪枝会让 depth-3 全盘扫描卡死几分钟且产出全是噪音。
const Set<String> _kWindowsScanSkipDirs = {
  'AppData',
  'Application Data',
  'Windows',
  'Program Files',
  'Program Files (x86)',
  'ProgramData',
  r'$Recycle.Bin',
  'System Volume Information',
  'node_modules',
};

/// 是否为应跳过的 Windows 系统目录名（非 Windows 平台恒 false）。
/// 供 isolate 扫描与最近文件扫描的目录剪枝共用。
bool _isWindowsSystemDir(String name) {
  if (!Platform.isWindows) return false;
  return _kWindowsScanSkipDirs.contains(name);
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

  /// true 时仅收集 APK（安装包），不收集文档/压缩包/下载。
  /// 用于 _scanNonMediaInBackground 在 MediaStore 成功后，对 APK 单独补扫
  ///（MediaStore.Files 不索引 APK）。
  final bool onlyApk;

  /// 目录缓存：{dirPath: {'m': mtimeMillis, 'f': [文件路径], 'd': [子目录], 's': {类别: 字节}}}
  /// 仅用于枚举失败时兜底沿用已知文件清单与子目录（不再以 mtime 跳过枚举，
  /// 避免部分 ROM 不更新目录 mtime 导致新文件永不出现）。非媒体类别目录树
  /// 较小，每次扫描都会重新枚举以保证完整性。
  final Map<String, Map<String, dynamic>> dirCache;

  /// 各类别"噪音过滤"开关：从主线程偏好同步读入（isolate 无法直接调静态 getter），
  /// 控制 isolate 内是否按 _kMin* 阈值丢弃小文件/0字节/损坏文件。默认全开。
  final _MediaNoiseFilter noiseFilter;

  /// 各分类「屏蔽文件夹」列表（与类别设置页 UI 对应）。key 为分类名（图片/视频/…
  /// 音频/文档/压缩包/下载/安装包/截图），value 为绝对目录路径列表。
  /// isolate 内据此对整个目录树做剪枝：被屏蔽目录及其子目录不再枚举，
  /// 实现「添加后不再扫描/索引该文件夹下任何文件」。isolate 不可调静态 getter，
  /// 故由主线程把 MediaProvider._excludedFolders 透传入参。
  final Map<String, List<String>> excludedFolders;
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
    this.onlyApk = false,
    this.dirCache = const {},
    this.noiseFilter = const _MediaNoiseFilter(),
    this.excludedFolders = const <String, List<String>>{},
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

String _normalizeMediaPathIsolate(String path) =>
    path.replaceAll(RegExp(r'/+'), '/');

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

@pragma('vm:entry-point')
List<int> _sumFileSizeGroupsInIsolate(List<List<String>> groups) {
  return [for (final paths in groups) _sumFileSizesInIsolate(paths)];
}

@pragma('vm:entry-point')
List<int> _fileSizesInIsolate(List<String> paths) {
  final sizes = List<int>.filled(paths.length, 0);
  for (var i = 0; i < paths.length; i++) {
    try {
      sizes[i] = File(paths[i]).lengthSync();
    } catch (_) {}
  }
  return sizes;
}

@pragma('vm:entry-point')
List<int> _customFileSizesInIsolate(List<String> paths) {
  final sizes = List<int>.filled(paths.length, -1);
  for (var i = 0; i < paths.length; i++) {
    try {
      sizes[i] = File(paths[i]).lengthSync();
    } catch (_) {}
  }
  return sizes;
}

/// 非媒体类别（文档/压缩包/下载/安装包）一次 stat 的判定结果：
/// - [gone]：底层文件已不存在（他应用/电脑删除、或已在别处移除）→ 应剔除。
/// - [empty]：文件**仍存在但字节数为 0**——典型的「未下载完/被中断/被清空的
///   占位文件」，系统索引仍收录它，于是列表里显示为 0 B，点「打开所在位置」
///   跳过去却看不到有内容的文件，删除后刷新又会被索引/缓存带回来。
///   仅登记（由分类 getter 按用户开关过滤），**不当作已删除**处理。
/// - [sizes]：与传入 paths 一一对应的**真实字节数**，-1 表示本次读不到
///   （存储繁忙/无权限），调用方不得据此覆盖索引值。用于纠正「索引报 0
///   但文件实际有内容」的陈旧索引，避免把正常文件误过滤掉。
class _NonMediaPruneResult {
  final List<String> gone;
  final List<String> empty;
  final List<int> sizes;
  const _NonMediaPruneResult(this.gone, this.empty, [this.sizes = const []]);
}

/// 在 isolate 内一次遍历同时完成「存在性」「0 字节」「真实字节数」判定
/// （主线程零 IO）。用 `lengthSync()` 而非 `existsSync()`：一次调用即拿到
/// 字节数，文件缺失时抛异常，再回退 `existsSync` 区分「确实不存在」与
/// 「路径暂不可访问（存储卸载/作用域限制）」——后者与旧实现保持一致（判死），
/// 由黑名单上限与刷新重扫兜底。
@pragma('vm:entry-point')
_NonMediaPruneResult _pruneNonMediaInIsolate(List<String> paths) {
  final gone = <String>[];
  final empty = <String>[];
  final sizes = List<int>.filled(paths.length, -1);
  for (var i = 0; i < paths.length; i++) {
    final p = paths[i];
    if (p.isEmpty) continue;
    try {
      final len = File(p).lengthSync();
      sizes[i] = len;
      if (len <= 0) empty.add(p);
    } catch (_) {
      try {
        if (!File(p).existsSync()) gone.add(p);
      } catch (_) {}
    }
  }
  return _NonMediaPruneResult(gone, empty, sizes);
}

/// 音频条目的裁剪判定（isolate 内零主线程 IO）：同时返回「已不存在」与
/// 「0 字节空条目」。与 [_pruneNonMediaInIsolate] 的差别：MediaStore 的音频路径
/// 在作用域存储 / 存储未挂载时可能整棵子树都不可 stat，此时 existsSync 一律返回
/// false，会把「仍在磁盘上但路径不可直接访问」的音频误判死亡（历史「音频过一会
/// 消失」根因）。故加父目录兜底：**仅当父目录本身可访问、而文件缺失**时才判定为
/// 已删除；父目录都访问不到时保持保留，交由 MediaStore 自身索引过滤。
///
/// 0 字节判定用 `lengthSync()` 的真实字节数，而非 `SongModel.size`——后者在
/// MediaStore 未提供 `_size` 时恒为 0（`int get size => _info["_size"] ?? 0`），
/// 直接拿它过滤会把全部音频误删。
@pragma('vm:entry-point')
_NonMediaPruneResult _pruneAudiosInIsolate(List<String> paths) {
  final gone = <String>[];
  final empty = <String>[];
  for (final p in paths) {
    if (p.isEmpty) continue;
    try {
      if (File(p).lengthSync() <= 0) {
        empty.add(p);
      }
    } catch (_) {
      try {
        final parent = File(p).parent;
        if (parent.existsSync()) gone.add(p);
      } catch (_) {}
    }
  }
  return _NonMediaPruneResult(gone, empty);
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

  /// 上次主动刷新持久化的「索引未收录」补充媒体（浅透传，
  /// 值为 List<dynamic>：路径字符串 / 音频条目 Map）。
  final Map<String, dynamic>? supplementaryMedia;
  const _RestoredCache({
    this.documents = const [],
    this.archives = const [],
    this.downloads = const [],
    this.apks = const [],
    this.recentFiles = const [],
    this.categorySizes = const {},
    this.mediaCounts = const {},
    this.dirCache,
    this.supplementaryMedia,
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
      try {
        sizes['$k'] = (v as num).toInt();
      } catch (_) {}
    });
    final counts = <String, int>{};
    (map['mediaCounts'] as Map?)?.forEach((k, v) {
      try {
        counts['$k'] = (v as num).toInt();
      } catch (_) {}
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
    // 上次主动刷新的补充媒体（浅透传，主线程合并时逐项校验类型）
    Map<String, dynamic>? supplementary;
    final rawSup = map['supplementaryMedia'];
    if (rawSup is Map) {
      supplementary = Map<String, dynamic>.from(rawSup);
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
      supplementaryMedia: supplementary,
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
/// - 截图小于此值视为通知/快捷方式图标噪声，不进「截图」分类。
const int _kMinScreenshotBytes = 5 * 1024; // 5 KB
/// - 文档/下载：0 字节空文件视为损坏/未下载完，不进分类。
const int _kMinDocBytes = 1;
const int _kMinDownloadBytes = 1;

/// - 压缩包/安装包：< 100B 视为损坏/伪装的非压缩包，不进分类。
///   100KB 是常见最小可用 APK/压缩包的 1/100，留足缓冲。
const int _kMinArchiveBytes = 100;
const int _kMinApkBytes = 100 * 1024;

/// 媒体类别"按尺寸过滤小文件"开关（PreferencesService.getMediaNoiseFilter）。
/// 默认 true；用户可在"自定义快捷方式页面 → 媒体类别过滤"独立切换每一类。
/// 设置为 false 后，对应类别不再按尺寸过滤，保留全部原始文件（_kMin* 不再生效）。
class _MediaNoiseFilter {
  final bool images;
  final bool videos;
  final bool screenshots;
  final bool documents;
  final bool archives;
  final bool downloads;
  final bool apks;
  const _MediaNoiseFilter({
    this.images = true,
    this.videos = true,
    this.screenshots = true,
    this.documents = true,
    this.archives = true,
    this.downloads = true,
    this.apks = true,
  });
}

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

  final queue = <_ScanItem>[
    for (final r in params.roots) _ScanItem(r.path, 0, r.maxDepth),
  ];
  final queued = <String>{};
  final newDirCache = <String, Map<String, dynamic>>{};
  int scannedDirs = 0;
  debugPrint('[ZenFile][isolate] scan roots=${params.roots}');

  // 屏蔽文件夹：把各分类的屏蔽目录合并成一个集合，做目录级剪枝——
  // 被屏蔽目录及其所有子目录整体跳过枚举，真正「不再扫描」该文件夹下的任何文件。
  final allExcluded = <String>{
    for (final list in params.excludedFolders.values) ...list,
  };
  bool _dirExcluded(String dir) {
    if (allExcluded.contains(dir)) return true;
    for (final excl in allExcluded) {
      if (p.isWithin(excl, dir)) return true;
    }
    return false;
  }

  while (queue.isNotEmpty) {
    final item = queue.removeAt(0);
    final current = item.path;
    final currentDepth = item.depth;
    final currentCap = item.cap;
    if (!queued.add(current)) continue;
    // 屏蔽文件夹：跳过整棵子树，不枚举其下任何文件/子目录。
    if (_dirExcluded(current)) continue;
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
          // 跳过隐藏目录、Android、Windows 系统目录、以及本应用缓存目录
          // （远程媒体/缩略图缓存，避免缓存图片被当成用户媒体重复收录）。
          if (!name.startsWith('.') &&
              name != 'Android' &&
              !_isWindowsSystemDir(name) &&
              !_isUnderAppCacheDir(entity.path)) {
            dirSubs.add(entity.path);
            if (currentDepth + 1 <= currentCap &&
                !queued.contains(entity.path)) {
              queue.add(_ScanItem(entity.path, currentDepth + 1, currentCap));
            }
          }
        } else if (entity is File) {
          // 跳过本应用缓存目录内的文件（远程下载缓存、缩略图等）。
          if (_isUnderAppCacheDir(entity.path)) continue;
          dirFiles.add(entity.path);
          final lower = entity.path.toLowerCase();
          // effectiveExtensionWithDot：忽略 IM 追加后缀（`app.apk.1` → `.apk`），
          // 否则 QQ 传来的安装包/文档会从分类里漏掉。
          final ext = FileUtils.effectiveExtensionWithDot(lower);
          if (isDownloadDir && !seenDownloads.contains(entity.path)) {
            seenDownloads.add(entity.path);
            int dlSize = 0;
            try {
              dlSize = entity.lengthSync();
            } catch (_) {}
            // 下载过滤：开关开启时跳过 0 字节空文件（未下载完/失败的占位）。
            if (!params.noiseFilter.downloads || dlSize >= _kMinDownloadBytes) {
              downloads.add(entity.path);
              dirAddSize('下载', dlSize);
            }
          }
          if (params.onlyApk) {
            // 仅收集 APK（安装包），不收集其他非媒体类别
            if (params.apkExtensions.contains(ext)) {
              int apkSize = 0;
              try {
                apkSize = entity.lengthSync();
              } catch (_) {}
              // 安装包过滤：开关开启时跳过 < 100KB 的伪 APK（损坏 / 错误下载）。
              if (params.noiseFilter.apks && apkSize < _kMinApkBytes) {
                // skip
              } else if (seenNonMedia.add(entity.path)) {
                apks.add(entity.path);
                dirAddSize('安装包', apkSize);
              }
            }
          } else if (params.skipMediaCategories) {
            // 媒体类别（图/视/截/音）由系统级索引提供，此处跳过，
            // 只处理下方文档/压缩包/安装包分支。
            if (params.docExtensions.contains(ext)) {
              int docSize = 0;
              try {
                docSize = entity.lengthSync();
              } catch (_) {}
              // 文档过滤：开关开启时跳过 0 字节空文件（损坏/未下载完）。
              if (params.noiseFilter.documents && docSize < _kMinDocBytes) {
                // skip
              } else if (seenNonMedia.add(entity.path)) {
                documents.add(entity.path);
                dirAddSize('文档', docSize);
              }
            } else if (params.archiveExtensions.contains(ext)) {
              int archSize = 0;
              try {
                archSize = entity.lengthSync();
              } catch (_) {}
              // 压缩包过滤：开关开启时跳过 < 100B 的损坏/伪装的非压缩包。
              if (params.noiseFilter.archives && archSize < _kMinArchiveBytes) {
                // skip
              } else if (seenNonMedia.add(entity.path)) {
                archives.add(entity.path);
                dirAddSize('压缩包', archSize);
              }
            }
          } else if (params.videoExtensions.contains(ext)) {
            // 过滤掉极小视频片段（如 .ts 流媒体碎片），避免污染「视频」分类。
            // 开关关闭时不过滤（保留原始文件，包括 < 1MB 的短视频/广告片段）。
            int size;
            try {
              size = entity.lengthSync();
            } catch (_) {
              size = 0;
            }
            if (params.noiseFilter.videos && size < _kMinVideoBytes) continue;
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
            // 过滤掉极小图片（如 app 图标、通知图标等噪声），避免污染「图片」分类。
            // 开关关闭时不过滤（保留原始文件，包括 < 30KB 的小图标/截图）。
            int size;
            try {
              size = entity.lengthSync();
            } catch (_) {
              size = 0;
            }
            final isScreenshot =
                lower.contains('screenshot') || lower.contains('截图');
            final minBytes = isScreenshot
                ? _kMinScreenshotBytes
                : _kMinImageBytes;
            final enableFilter = isScreenshot
                ? params.noiseFilter.screenshots
                : params.noiseFilter.images;
            if (enableFilter && size < minBytes) continue;
            if (isScreenshot) {
              screenshots.add(entity.path);
              dirAddSize('截图', size);
            } else {
              images.add(entity.path);
              dirAddSize('图片', size);
            }
          } else if (params.docExtensions.contains(ext)) {
            int docSize = 0;
            try {
              docSize = entity.lengthSync();
            } catch (_) {}
            // 文档过滤：开关开启时跳过 0 字节空文件（损坏/未下载完）。
            if (params.noiseFilter.documents && docSize < _kMinDocBytes) {
              // skip
            } else if (seenNonMedia.add(entity.path)) {
              documents.add(entity.path);
              dirAddSize('文档', docSize);
            }
          } else if (params.archiveExtensions.contains(ext)) {
            int archSize = 0;
            try {
              archSize = entity.lengthSync();
            } catch (_) {}
            // 压缩包过滤：开关开启时跳过 < 100B 的损坏/伪装的非压缩包。
            if (params.noiseFilter.archives && archSize < _kMinArchiveBytes) {
              // skip
            } else if (seenNonMedia.add(entity.path)) {
              archives.add(entity.path);
              dirAddSize('压缩包', archSize);
            }
          } else if (params.apkExtensions.contains(ext)) {
            int apkSize = 0;
            try {
              apkSize = entity.lengthSync();
            } catch (_) {}
            // 安装包过滤：开关开启时跳过 < 100KB 的伪 APK。
            if (params.noiseFilter.apks && apkSize < _kMinApkBytes) {
              // skip
            } else if (seenNonMedia.add(entity.path)) {
              apks.add(entity.path);
              dirAddSize('安装包', apkSize);
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
  debugPrint(
    '[ZenFile][isolate] scan done: scannedDirs=$scannedDirs '
    'docs=${documents.length} arch=${archives.length} dl=${downloads.length} '
    'apk=${apks.length}',
  );
  // 在 isolate 内完成按父目录分组，主线程直接赋值，不再做 O(n) 遍历。
  final imageFolders = _groupPathsByParentDir(images);
  final videoFolders = _groupPathsByParentDir(videos);
  final audioFolders = _groupPathsByParentDir(
    audios
        .map((m) => (m['_data'] as String?) ?? '')
        .where((p) => p.isNotEmpty)
        .toList(),
  );
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

/// 简单 LRU 缓存（LinkedHashMap 迭代序 = 插入序，命中即移到末尾）。
///
/// ThumbnailCache 原为只进不出的 static Map：几千个媒体 × 100~300KB 的
/// 缩略图常驻可达数百 MB。现按「条目数 + 总字节」双上限淘汰最旧条目。
class _LruBytesCache {
  final int maxEntries = 400;
  final int maxBytes = 64 * 1024 * 1024;

  final LinkedHashMap<String, Uint8List?> _map = LinkedHashMap();
  int _bytes = 0;

  int get byteSize => _bytes;

  Uint8List? operator [](String key) {
    if (!_map.containsKey(key)) return null;
    // 命中即移动到末尾（最近使用）
    final value = _map.remove(key);
    _map[key] = value;
    return value;
  }

  bool containsKey(String key) => _map.containsKey(key);

  void operator []=(String key, Uint8List? value) {
    if (_map.containsKey(key)) {
      final old = _map.remove(key);
      _bytes -= old?.length ?? 0;
    }
    _map[key] = value;
    _bytes += value?.length ?? 0;
    _evict();
  }

  void clear() {
    _map.clear();
    _bytes = 0;
  }

  void _evict() {
    while (_map.length > maxEntries || _bytes > maxBytes) {
      if (_map.isEmpty) break;
      final oldestKey = _map.keys.first;
      final oldest = _map.remove(oldestKey);
      _bytes -= oldest?.length ?? 0;
    }
  }
}

class ThumbnailCache {
  static final _LruBytesCache _cache = _LruBytesCache();
  static final Map<String, Future<Uint8List?>> _pending = {};
  static String? _cacheDir;

  /// 释放内存中的缩略图字节（**不动磁盘上的 `.thumb` 文件**）。
  ///
  /// 供系统低内存（`didHaveMemoryPressure`）与 UI 卡顿自愈调用：内存被清空后
  /// 再用到的条目会从磁盘/原生侧重新取，代价只是一次读取，不会丢数据。
  static void clearMemory() => _cache.clear();

  /// 当前内存中的缩略图字节总量（诊断用）。
  static int get memoryBytes => _cache.byteSize;

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
      //
      // ⚠️ 预载**必须有硬上限**（issue #58）：这里原本只受 LRU 的 57 MB 预算
      // 约束，等于「首次用到缩略图时就把磁盘上最多 57 MB 的图一次性读进内存」。
      // 那个时机恰好是启动后第一次滚动分类页，与三份 ANR 报告里「启动后 20 余秒
      // 内存冲到 1.2 GB、主线程卡在 Dart 代码」的形态吻合。现在预载只做**很小
      // 一批热图**，其余条目走 [_get] 的按需回读 —— 少一次启动期 IO 风暴与内存尖峰。
      var preloaded = 0;
      try {
        await for (final f in folder.list()) {
          if (preloaded >= _kPreloadMaxEntries) break;
          if (_cache.byteSize >= _kPreloadMaxBytes) break;
          if (f is File && f.path.endsWith('.thumb')) {
            final key = f.path
                .split('/')
                .last
                .split('\\')
                .last
                .replaceAll('.thumb', '');
            if (!_cache.containsKey(key)) {
              _cache[key] = await f.readAsBytes();
              preloaded++;
            }
          }
        }
      } catch (_) {}
    } catch (_) {}
  }

  /// 预载上限：条目数（够填满首屏 + 一屏滚动即可）。
  static const int _kPreloadMaxEntries = 60;

  /// 预载上限：字节数（约 6 MB，远超它的部分按需回读）。
  static const int _kPreloadMaxBytes = 6 * 1024 * 1024;

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

      final data = await asset.thumbnailDataWithSize(
        const ThumbnailSize.square(300),
      );
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
  static bool hasCached(String id) =>
      _cache.containsKey(id) && _cache[id] != null;

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
        await remoteClient.downloadRange(
          remoteFilePath,
          tempFile.path,
          0,
          2 * 1024 * 1024,
        );
      } catch (e) {
        // 部分服务器或客户端可能不支持 range 下载，回退到完整下载
        debugPrint('[ThumbnailCache] downloadRange 失败，回退完整下载: $e');
        await remoteClient.downloadFile(remoteFilePath, tempFile.path, (_) {});
      }
      await remoteClient.disconnect();

      // 通过原生 MediaMetadataRetriever 生成远程视频缩略图
      Uint8List? thumbnailBytes;
      try {
        thumbnailBytes = await MediaThumbnailService.generateVideoThumbnail(
          tempFile.path,
        );
      } catch (e) {
        debugPrint('[ThumbnailCache] 远程视频缩略图生成失败: $e');
      }

      // 清理临时文件
      try {
        await tempFile.delete();
      } catch (_) {}

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
  /// 单例引用：供 file_manager_provider 等无 context 的地方在文件被删除后
  /// 即时通知媒体列表裁剪（避免分类页残留空白图标）。
  static MediaProvider? instance;

  MediaProvider() {
    instance = this;
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
      // v2.1.7：「设置」入口已从分类页/自定义快捷方式下线，改由底部「我的」页承载。
      // 历史持久化数据里的 '设置' 必须清掉 —— getAllCategoriesMap 已无该定义，
      // 否则自定义快捷方式面板会渲染出一个空行（containsKey 过滤后仍占一个 item）。
      if (_categoryOrder.contains('设置')) {
        _categoryOrder.remove('设置');
        orderUpdated = true;
      }
      // 网络/FTP共享/Web共享 已迁移到传输页（v3.x）：分类页不再显示，
      // 历史持久化里的残留一律清除（无条件，不受迁移版本号限制）。
      if (_categoryOrder.contains('网络')) {
        _categoryOrder.remove('网络');
        orderUpdated = true;
      }
      if (_categoryOrder.contains('FTP共享')) {
        _categoryOrder.remove('FTP共享');
        orderUpdated = true;
      }
      if (_categoryOrder.contains('Web共享')) {
        _categoryOrder.remove('Web共享');
        orderUpdated = true;
      }
      if (!_categoryOrder.contains('最近')) {
        _categoryOrder.add('最近');
        orderUpdated = true;
      }
      if (!_categoryOrder.contains('工具箱')) {
        _categoryOrder.add('工具箱');
        orderUpdated = true;
      }
      if (_categoryOrder.contains('快传')) {
        _categoryOrder.remove('快传');
        orderUpdated = true;
      }
      if (_categoryOrder.contains('保险箱')) {
        _categoryOrder.remove('保险箱');
        orderUpdated = true;
      }
      // 确保「下载」紧跟在「空间」之后，与截图默认顺序一致。
      final spaceIndex = _categoryOrder.indexOf('空间');
      if (spaceIndex >= 0) {
        final downloadIndex = _categoryOrder.indexOf('下载');
        if (downloadIndex < 0) {
          _categoryOrder.insert(spaceIndex + 1, '下载');
          orderUpdated = true;
        } else if (downloadIndex != spaceIndex + 1) {
          _categoryOrder.removeAt(downloadIndex);
          _categoryOrder.insert(spaceIndex + 1, '下载');
          orderUpdated = true;
        }
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
        // 原锚点为「设置」（v2.1.7 已下线），改用「应用」，保持既有顺序。
        final anchorIndex = _categoryOrder.indexOf('应用');
        final insertIndex = anchorIndex >= 0
            ? anchorIndex + 1
            : _categoryOrder.length;
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
      // 网络/FTP共享/Web共享 已迁移到传输页：active 残留一律清除（无条件）
      if (_activeCategories.contains('网络')) {
        _activeCategories.remove('网络');
        activeUpdated = true;
      }
      if (_activeCategories.contains('FTP共享')) {
        _activeCategories.remove('FTP共享');
        activeUpdated = true;
      }
      if (_activeCategories.contains('Web共享')) {
        _activeCategories.remove('Web共享');
        activeUpdated = true;
      }
      if (migratedVersion <
          PreferencesService.kCurrentCategoriesMigratedVersion) {
        if (!_activeCategories.contains('最近')) {
          _activeCategories.add('最近');
          activeUpdated = true;
        }
        if (!_activeCategories.contains('工具箱')) {
          _activeCategories.add('工具箱');
          activeUpdated = true;
        }
        if (_activeCategories.contains('快传')) {
          _activeCategories.remove('快传');
          activeUpdated = true;
        }
        if (_activeCategories.contains('保险箱')) {
          _activeCategories.remove('保险箱');
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
          // 原锚点为「设置」（v2.1.7 已下线），改用「应用」。
          final anchorIndex = _activeCategories.indexOf('应用');
          final insertIndex = anchorIndex >= 0
              ? anchorIndex + 1
              : _activeCategories.length;
          _activeCategories.insert(insertIndex, '备份/恢复');
          activeUpdated = true;
        }
      }
      // 老用户升级时，「快传」与「保险箱」已并入「工具箱」，不再单独保留。
      // v2.1.7：同 _categoryOrder，清除历史 active 列表里的「设置」。
      // 极端情况（用户此前只留「设置」这一项）会清空列表，回落一组核心分类，
      // 避免分类页变成空白页。
      if (_activeCategories.contains('设置')) {
        _activeCategories.remove('设置');
        if (_activeCategories.isEmpty) {
          _activeCategories.addAll(['系统', '存储', '空间', '下载']);
        }
        activeUpdated = true;
      }
      if (_activeCategories.contains('快传')) {
        _activeCategories.remove('快传');
        activeUpdated = true;
      }
      if (_activeCategories.contains('保险箱')) {
        _activeCategories.remove('保险箱');
        activeUpdated = true;
      }
      if (activeUpdated) {
        PreferencesService.saveActiveCategories(_activeCategories);
      }
      // 标记迁移完成（即使本次未补全，也更新版本号以跳过未来的强制补全）
      if (migratedVersion <
          PreferencesService.kCurrentCategoriesMigratedVersion) {
        PreferencesService.saveCategoriesMigratedVersion(
          PreferencesService.kCurrentCategoriesMigratedVersion,
        );
      }
    }
    final savedCustom = PreferencesService.getCustomShortcuts();
    if (savedCustom != null) {
      _customShortcuts = savedCustom;
    }
    _customCategoryPaths = PreferencesService.getCustomCategoryPaths();
    _excludedDefaultPaths = PreferencesService.getExcludedDefaultPaths();
    _excludedFolders = PreferencesService.getExcludedFolders();
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

  /// 本会话「已删除」的媒体路径黑名单（规范化路径）。
  ///
  /// MediaStore / 系统索引在文件被删除后常有滞后：`loadMedia(forceRefresh:)`、
  /// 下拉刷新或后台 onResume 刷新时，`querySongs` / 文件系统扫描仍可能把**已删除**
  /// 的条目带回来（用户反馈：浏览页删除音频后，分类页「音频」一直显示该文件，
  /// 手动刷新也不消失——因为刷新反而把它从滞后的索引里重新拉了回来）。
  /// 这里记录删除路径，在所有音频合并/恢复点统一过滤，直到重新启动重新建库。
  final Set<String> _deletedMediaPaths = <String>{};

  /// 黑名单上限，避免长时间运行无限增长（Set 保持插入序，超出后丢最旧的）。
  static const int _kDeletedMediaPathsCap = 4096;

  /// 本会话「0 字节空音频」路径集合（规范化路径）。
  ///
  /// 与上面的删除黑名单不同：这些文件**确实存在**，只是字节数为 0——典型是
  /// 未下载完/被中断/被清空的空文件，但 MediaStore 仍收录为一条音频，于是分类页
  /// 「音频」里显示 0 B 的条目、点「打开所在位置」看不到内容、删掉刷新又出现。
  /// 由 `pruneDeletedMedia` 在 isolate 内 stat 真实字节数后**整体替换**本集合
  /// （非累加，保证文件被补全后即刻恢复显示），getter 据此过滤。
  final Set<String> _emptyAudioPaths = <String>{};

  bool _isDeletedMediaPath(String path) {
    if (_deletedMediaPaths.isEmpty || path.isEmpty) return false;
    return _deletedMediaPaths.contains(_normalizeMediaPath(path));
  }

  /// 过滤掉本会话已删除的音频（按规范化路径匹配），并打印过滤条数便于排查。
  List<SongModel> _stripDeletedAudios(List<SongModel> input) {
    if (_deletedMediaPaths.isEmpty || input.isEmpty) return input;
    final kept = input.where((s) => !_isDeletedMediaPath(s.data)).toList();
    if (kept.length != input.length) {
      debugPrint(
        '[ZenFile] 过滤本会话已删除音频 ${input.length - kept.length} 条（MediaStore 滞后）',
      );
    }
    return kept;
  }

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
  // ⚠️ 必须可变：磁盘缓存恢复（addAll）与 MediaStore/isolate 扫描都会原地写键，
  // 用 const {} 会在首次加载抛 "Cannot modify unmodifiable map"，把分类大小
  // 统计静默打断（isolate 扫描完成前的所有写入路径全部失效）。
  Map<String, int> _fsCategorySizes = <String, int>{};
  List<FileSystemEntity> _customImages = [];
  List<FileSystemEntity> _customVideos = [];
  List<FileSystemEntity> _customScreenshots = [];
  Map<String, List<String>> _customCategoryPaths = {};
  Map<String, List<String>> get customCategoryPaths => _customCategoryPaths;
  Map<String, List<String>> _excludedDefaultPaths = {};
  Map<String, List<String>> get excludedDefaultPaths => _excludedDefaultPaths;
  Map<String, List<String>> _excludedFolders = {};
  Map<String, List<String>> get excludedFolders => _excludedFolders;
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

  /// 上次用户主动刷新（loadMedia(forceRefresh:true)）的默认路径递归扫描中，
  /// 「系统索引未收录」的补充媒体（图/视/截路径 + 音频合成条目 map）。
  /// 持久化到 meta 缓存（_saveCache），下次启动/回前台在系统索引加载后
  /// 由 _mergeSupplementaryMedia 并集合并回列表——修复「刷新后出现的默认
  /// 路径文件重启后又消失」：这些文件不在 PhotoManager/on_audio_query
  /// 索引内，重启后索引查询替换列表时会被丢弃。只保存索引缺失的差集，
  /// 缓存体积远小于全量路径。幽灵条目由主动刷新的替换语义与
  /// pruneDeletedMedia 存在性裁剪清除。
  Map<String, dynamic>? _supplementaryMedia;

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
  static Map<String, List<String>> _mergeFolderMaps(
    List<Map<String, List<String>>> maps,
  ) {
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

  /// 媒体索引的内存占用概览（诊断用，2026-11-27 新增）。
  ///
  /// ## 为什么需要它
  ///
  /// 真机日志显示这台机器在 **RSS=258MB** 时就会回调 `system-low-memory`，
  /// 而我们「释放前」打出来的三个 Dart 缓存**永远是 0**
  /// （`img=0.0MB thumb=0.0MB tile=0.0MB`）——
  /// 也就是说**系统喊内存紧张时，应用其实什么都没释放**。
  ///
  /// 那 258MB 到底被谁吃掉了？在此之前无法回答，因为：
  /// * `layerCache` / `pictureCache` 实测基本为 0 ⇒ 不是 GPU 侧资源缓存；
  /// * 媒体索引（mtime/size 缓存、视频资产索引、各分类的媒体列表）**条数多但没有可见化**，
  ///   每条都是 Dart 对象（String 路径 + Map/List 槽位），几万到几十万条就能吃掉几十 MB。
  ///
  /// 这里把各索引的**条数**打出来（条数 × 每条的固定开销 ≈ 占用），
  /// 下一份日志就能直接判断「媒体索引是不是那 258MB 的主要来源」。
  ///
  /// 只读、无副作用，正式版也保留（只在低内存/卡顿时被调用）。
  static String memoryFootprint() {
    final provider = _instance;
    if (provider == null) return '媒体索引: 无实例';
    final mediaEntries =
        provider._images.length +
        provider._videos.length +
        provider._audios.length +
        provider._documents.length +
        provider._archives.length +
        provider._downloads.length +
        provider._apks.length +
        provider._screenshots.length;
    return '媒体索引: 条目=$mediaEntries '
        'mtime=${provider._mtimeCache.length} '
        'size=${provider._sizeCache.length} '
        'dir=${provider._dirCache.length} '
        '视频资产=${_videoAssetByPathCache?.length ?? 0}';
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

  static Map<String, List<String>> _groupByParentDir(
    List<FileSystemEntity> files,
  ) {
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

  static Map<String, List<String>> _groupAudiosByParentDir(
    List<SongModel> songs,
  ) {
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
    '下载',
    '图片',
    '视频',
    '音频',
    '文档',
    '截图',
    '工具箱',
    '压缩包',
    '备份/恢复',
    '应用',
    '安装包',
    '最近',
    '回收站',
  ];

  List<String> _activeCategories = [
    '系统',
    '存储',
    '空间',
    '下载',
    '图片',
    '视频',
    '音频',
    '文档',
    '截图',
    '工具箱',
    '压缩包',
    '备份/恢复',
    '应用',
    '安装包',
    '最近',
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
  Future<void>? _customCategoryRefreshFuture;
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

  /// 按类别独立排序设置：key=类别名(图片/视频/音频/文档/压缩包/下载/安装包/截图)，value=排序方式。
  /// 优先于全局 _sortOrder；未设置的类别回退到全局排序。
  final Map<String, MediaSortOrder> _categorySortOrders = {};

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
    final excluded = <String>[
      ...(_excludedDefaultPaths['图片'] ?? const <String>[]),
      ...(_excludedFolders['图片'] ?? const <String>[]),
    ];
    final sortOrder = getSortOrderForCategory('图片');
    final stamp = _stampFor(_images, _customImages, excluded, sortOrder);
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
    _sortDynamicList(list, sortOrder);
    _imagesOut = list;
    _imagesStamp = stamp;
    return list;
  }

  List<dynamic> get videos {
    final excluded = <String>[
      ...(_excludedDefaultPaths['视频'] ?? const <String>[]),
      ...(_excludedFolders['视频'] ?? const <String>[]),
    ];
    final sortOrder = getSortOrderForCategory('视频');
    final stamp = _stampFor(_videos, _customVideos, excluded, sortOrder);
    if (_videosOut != null && _videosStamp == stamp) return _videosOut!;
    final raw = [..._videos, ..._customVideos].where((item) {
      final path = _getItemPath(item);
      if (path != null && _isPathExcluded(path, excluded)) {
        return false;
      }
      return true;
    }).toList();
    final list = _dedupeMediaByPath(raw);
    _sortDynamicList(list, sortOrder);
    _videosOut = list;
    _videosStamp = stamp;
    return list;
  }

  List<SongModel> get audios {
    final excluded = <String>[
      ...(_excludedDefaultPaths['音频'] ?? const <String>[]),
      ...(_excludedFolders['音频'] ?? const <String>[]),
    ];
    // 双保险：黑名单非空时先滤掉本会话已删除路径（_audios 各合并点本已过滤，
    // 这里兜底防止未来新增合并路径漏过滤导致「删了又出现」）。
    final list = _stripDeletedAudios(_audios).where((song) {
      final path = song.data;
      if (_isPathExcluded(path, excluded)) return false;
      // 0 字节空音频兜底（后台 stat 判定，见 _emptyAudioPaths 与
      // _pruneAudiosInIsolate）：不用 SongModel.size——MediaStore 未提供
      // `_size` 时它恒为 0，据此过滤会误删全部音频。
      if (_emptyAudioPaths.isNotEmpty &&
          _emptyAudioPaths.contains(_normalizeMediaPath(path))) {
        return false;
      }
      return true;
    }).toList();
    return list;
  }

  List<SongModel>? _audioIndexSource;
  Map<String, SongModel>? _audioIndex;

  /// O(1) 按路径查找音频条目（供缩略图 widget 逐项查询）。
  ///
  /// 此前 UI 里用 `audios.where((s) => s.data == path).firstOrNull`，
  /// 每个音频 item 都全表扫描，列表页整体是 O(n²)；列表越大滚动越卡。
  /// 索引按 [_audios] 列表引用惰性重建（列表总是整体替换，无原地修改）。
  SongModel? audioByPath(String path) {
    if (!identical(_audioIndexSource, _audios)) {
      _audioIndex = {for (final s in _audios) s.data: s};
      _audioIndexSource = _audios;
    }
    return _audioIndex![path];
  }

  /// 非媒体类别「0 字节占位文件」兜底过滤（文档/压缩包/下载/安装包通用）。
  ///
  /// 为什么需要 getter 兜底：0 字节条目有多条**绕过尺寸过滤**的入口——
  /// MediaStore 索引查询、磁盘缓存恢复（`_restoreCacheInIsolate` 直接信任旧路径）、
  /// 自定义路径扫描，且启动时的并集合并会把缓存里的旧条目原样保留。
  /// 只在下药于各入口会不断漏；在 getter（分类页唯一数据出口）统一拦截最稳。
  ///
  /// 判定零成本：只读索引大小缓存 `_nonMediaSizes`（MediaStore 查询写入真实
  /// 字节数，后台 stat 裁剪为无记录来源补登记 0），**不做同步 stat**，
  /// 不会给列表滚动/分组带来 IO 卡顿。
  /// 用户关闭该类「噪音过滤」开关时不做过滤（保留原始文件，与扫描层一致）。
  bool _isNonMediaEmptyFiltered(String path, String category, int minBytes) {
    if (!PreferencesService.getMediaNoiseFilter(category)) return false;
    final size = _nonMediaSizes[path];
    // size < 0 为「未知/不可读」占位（不参与判定），只过滤已知且过小的条目。
    return size != null && size >= 0 && size < minBytes;
  }

  List<FileSystemEntity> get documents {
    final excluded = <String>[
      ...(_excludedDefaultPaths['文档'] ?? const <String>[]),
      ...(_excludedFolders['文档'] ?? const <String>[]),
    ];
    final excludeAllScanned = excluded.contains('内部存储（扫描所有文件夹）');
    final list = _documents.where((file) {
      final docPaths = _customCategoryPaths['文档'] ?? [];
      final isCustom = docPaths.any((dir) => p.isWithin(dir, file.path));
      if (excludeAllScanned && !isCustom) return false;
      if (_isPathExcluded(file.path, excluded)) return false;
      if (_isNonMediaEmptyFiltered(file.path, '文档', _kMinDocBytes))
        return false;
      return true;
    }).toList();
    return list;
  }

  List<FileSystemEntity> get archives {
    final excluded = <String>[
      ...(_excludedDefaultPaths['压缩包'] ?? const <String>[]),
      ...(_excludedFolders['压缩包'] ?? const <String>[]),
    ];
    final excludeAllScanned = excluded.contains('内部存储（扫描所有文件夹）');
    final list = _archives.where((file) {
      final archPaths = _customCategoryPaths['压缩包'] ?? [];
      final isCustom = archPaths.any((dir) => p.isWithin(dir, file.path));
      if (excludeAllScanned && !isCustom) return false;
      if (_isPathExcluded(file.path, excluded)) return false;
      if (_isNonMediaEmptyFiltered(file.path, '压缩包', _kMinArchiveBytes))
        return false;
      return true;
    }).toList();
    return list;
  }

  List<FileSystemEntity> get downloads {
    final excluded = <String>[
      ...(_excludedDefaultPaths['下载'] ?? const <String>[]),
      ...(_excludedFolders['下载'] ?? const <String>[]),
    ];
    final list = _downloads.where((file) {
      if (_isPathExcluded(file.path, excluded)) return false;
      if (_isNonMediaEmptyFiltered(file.path, '下载', _kMinDownloadBytes))
        return false;
      return true;
    }).toList();
    return list;
  }

  List<FileSystemEntity> get apks {
    final excluded = <String>[
      ...(_excludedDefaultPaths['安装包'] ?? const <String>[]),
      ...(_excludedFolders['安装包'] ?? const <String>[]),
    ];
    final excludeAllScanned = excluded.contains('内部存储（扫描所有文件夹）');
    final list = _apks.where((file) {
      final apkPaths = _customCategoryPaths['安装包'] ?? [];
      final isCustom = apkPaths.any((dir) => p.isWithin(dir, file.path));
      if (excludeAllScanned && !isCustom) return false;
      if (_isPathExcluded(file.path, excluded)) return false;
      if (_isNonMediaEmptyFiltered(file.path, '安装包', _kMinApkBytes))
        return false;
      return true;
    }).toList();
    return list;
  }

  List<dynamic> get screenshots {
    final excluded = <String>[
      ...(_excludedDefaultPaths['截图'] ?? const <String>[]),
      ...(_excludedFolders['截图'] ?? const <String>[]),
    ];
    final sortOrder = getSortOrderForCategory('截图');
    final stamp = _stampFor(
      _screenshots,
      _customScreenshots,
      excluded,
      sortOrder,
    );
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
    _sortDynamicList(list, sortOrder);
    _shotsOut = list;
    _shotsStamp = stamp;
    return list;
  }

  List<FileItemModel> get recentFiles => _recentFiles;

  void _sortDynamicList(List<dynamic> list, [MediaSortOrder? sortOrder]) {
    final effectiveOrder = sortOrder ?? _sortOrder;
    int Function(dynamic, dynamic) compare;
    if (effectiveOrder == MediaSortOrder.newest ||
        effectiveOrder == MediaSortOrder.newestGrouped ||
        effectiveOrder == MediaSortOrder.dateWise) {
      compare = (a, b) {
        final aTime = _getDateTime(a);
        final bTime = _getDateTime(b);
        return bTime.compareTo(aTime);
      };
    } else if (effectiveOrder == MediaSortOrder.oldest ||
        effectiveOrder == MediaSortOrder.oldestGrouped) {
      compare = (a, b) {
        final aTime = _getDateTime(a);
        final bTime = _getDateTime(b);
        return aTime.compareTo(bTime);
      };
    } else if (effectiveOrder == MediaSortOrder.sizeLargest ||
        effectiveOrder == MediaSortOrder.sizeSmallest) {
      final isSmallest = effectiveOrder == MediaSortOrder.sizeSmallest;
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
    if (item is AssetEntity) {
      // AssetEntity.size 是图片尺寸(Size)而非文件大小，
      // 先转 File 再走 FileSystemEntity 的缓存+stat 逻辑。
      final f = _assetToFile(item);
      if (f != null) {
        final cached = _sizeCache[f.path];
        if (cached != null) return cached;
        try {
          final s = f.lengthSync();
          _sizeCache[f.path] = s;
          return s;
        } catch (_) {}
      }
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

  /// getter 缓存戳：源列表身份 + 排序方式 + 排除路径内容。
  /// 列表被重新赋值（加载/删除/刷新）或排序/排除变化 → 戳变化 → 重算。
  /// 包含列表长度：原地 removeWhere 修改列表时对象引用不变，
  /// 但长度会变 → 强制 getter 重新计算，覆盖删除后残留场景。
  int _stampFor(List a, List b, List excluded, [MediaSortOrder? sortOrder]) =>
      Object.hash(
        identityHashCode(a),
        identityHashCode(b),
        Object.hashAll(excluded),
        (sortOrder ?? _sortOrder).index,
        a.length,
        b.length,
      );
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

  /// 获取指定类别的排序方式：优先使用类别独立设置，未设置时回退到全局排序。
  MediaSortOrder getSortOrderForCategory(String category) {
    return _categorySortOrders[category] ?? _sortOrder;
  }

  /// 从持久化存储加载所有类别的独立排序设置（init 时调用）。
  Future<void> loadCategorySortOrders() async {
    const categories = ['图片', '视频', '音频', '文档', '压缩包', '下载', '安装包', '截图'];
    for (final cat in categories) {
      final saved = PreferencesService.getCategorySortOrder(cat);
      if (saved != null) {
        final idx = MediaSortOrder.values.indexWhere((e) => e.name == saved);
        if (idx >= 0) {
          _categorySortOrders[cat] = MediaSortOrder.values[idx];
        }
      }
    }
  }

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

  /// 直接替换完整分类顺序（统一顺序 full_grid_order 拖动后同步写回）。
  void setCategoryOrder(List<String> order) {
    _categoryOrder
      ..clear()
      ..addAll(order);
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
    final cs = CustomShortcutModel(
      id: id,
      label: label,
      path: path,
      isDirectory: isDir,
    );
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

  /// 已过滤条数缓存（分类卡片 / 快捷网格的数量显示）。
  ///
  /// 卡片数量必须与分类页列表**实际显示**的条数一致，否则会出现「卡片显示 12、
  /// 点进去只有 8」的观感问题——0 字节占位文件、本会话已删除的条目都已经不再
  /// 列出，计数也不应把它们算进去。但 `audios/documents/archives/downloads/apks`
  /// 这些 getter 每次调用都要遍历列表并逐项判定排除路径与 0 字节，若在卡片
  /// build 的热路径上逐帧调用会造成掉帧（本项目对 Android 15/16 卡顿敏感）。
  /// 故：所有数据变更经 [notifyListeners] 置脏，UI 首次读取时惰性重算一次，
  /// 其余读取退化为 O(1) map 查询。
  final Map<String, int> _filteredCategoryCounts = <String, int>{};
  bool _filteredCountsDirty = true;

  @override
  void notifyListeners() {
    // 诊断计数（2026-11-27）：见 services/build_trigger_counter.dart 的类注释。
    // 只加一个整数自增，不改变行为；探针用它判断「这一帧是被谁触发重建的」。
    BuildTriggerCounter.mediaNotifications++;
    // 数据变更的唯一收敛点：只置脏（O(1)），重算延后到真正被读取时执行。
    _filteredCountsDirty = true;
    super.notifyListeners();
  }

  /// 惰性重算「过滤后条数」（仅在被读取且已置脏时执行一次）。
  void _refreshFilteredCountsIfDirty() {
    if (!_filteredCountsDirty) return;
    _filteredCountsDirty = false;
    _filteredCategoryCounts['音频'] = audios.length;
    _filteredCategoryCounts['文档'] = documents.length;
    _filteredCategoryCounts['压缩包'] = archives.length;
    _filteredCategoryCounts['下载'] = downloads.length;
    _filteredCategoryCounts['安装包'] = apks.length;
  }

  /// 非媒体四类 + 音频的「过滤后条数」（分类卡片显示用）。
  /// 图片/视频/截图无需经过此处：其 getter 自带结果缓存（`_stampFor`），
  /// 直接调用的成本已经很低。
  int _displayCount(String category) {
    _refreshFilteredCountsIfDirty();
    return _filteredCategoryCounts[category] ?? 0;
  }

  /// 写入非媒体四类的**持久化**计数（供 `_isLoaded` 尚未就绪时回退读取）。
  /// 同样采用过滤后条数，避免冷启动瞬间卡片数量与列表不一致。
  void _saveNonMediaCategoryCounts() {
    PreferencesService.saveCategoryCount('文档', documents.length);
    PreferencesService.saveCategoryCount('压缩包', archives.length);
    PreferencesService.saveCategoryCount('下载', downloads.length);
    PreferencesService.saveCategoryCount('安装包', apks.length);
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
        case '图片':
          return images.length;
        case '视频':
          return videos.length;
        // 音频与非媒体四类改用「过滤后条数」：与分类页列表实际显示一致
        // （0 字节占位、本会话已删除的条目不计入）。
        case '音频':
          return _displayCount('音频');
        case '文档':
          return _displayCount('文档');
        case '压缩包':
          return _displayCount('压缩包');
        case '下载':
          return _displayCount('下载');
        case '安装包':
          return _displayCount('安装包');
        case '截图':
          return screenshots.length;
        case '应用':
          return 0;
        case '设置':
          return 0;
        case '网络':
          return NetworkConnectionsService.getConnections().length;
        case '最近':
          return _recentFiles.length;
        case '保险箱':
          return 0;
      }
    }
    // 兜底：_isLoaded 尚未置 true（系统索引仍在后台刷新）但内存列表已自缓存恢复，
    // 直接返回真实列表长度，避免分类页显示陈旧持久化计数（音频恒0、图视恒数千）。
    switch (category) {
      case '图片':
        return _images.length;
      case '视频':
        return _videos.length;
      case '音频':
        return _displayCount('音频');
      case '文档':
        return _displayCount('文档');
      case '压缩包':
        return _displayCount('压缩包');
      case '下载':
        return _displayCount('下载');
      case '安装包':
        return _displayCount('安装包');
      case '截图':
        return _screenshots.length;
      case '最近':
        return _recentFiles.length;
    }
    return PreferencesService.getCategoryCount(category);
  }

  int _cachedEntitySize(FileSystemEntity entity) {
    if (entity is! File) return 0;
    if (entity.path.startsWith('remote://')) {
      return _remoteFileSizes[entity.path] ?? 0;
    }
    final size = _sizeCache[entity.path] ?? _nonMediaSizes[entity.path];
    return size != null && size >= 0 ? size : 0;
  }

  Future<void> _cacheCustomEntitySizes(List<FileSystemEntity> entities) async {
    final paths = <String>{};
    for (final entity in entities) {
      if (entity is File && !entity.path.startsWith('remote://')) {
        paths.add(entity.path);
      }
    }
    if (paths.isEmpty) return;
    final pathList = paths.toList();
    final sizes = await compute(_customFileSizesInIsolate, pathList);
    for (var i = 0; i < pathList.length; i++) {
      if (sizes[i] >= 0) _sizeCache[pathList[i]] = sizes[i];
    }
  }

  int _sumCachedEntitySize(List<FileSystemEntity> entities) {
    var total = 0;
    for (final entity in entities) {
      total += _cachedEntitySize(entity);
    }
    return total;
  }

  /// 重新计算各媒体分类的总大小并写入缓存。
  /// 仅在扫描完成（saveCategoryCount 批量写入处）调用，避免重复计算。
  /// 分类大小已在 isolate 扫描阶段累计（_fsCategorySizes），
  /// 主线程仅补充自定义路径（通常少量），不再对几十万文件同步 lengthSync 阻塞 UI。
  void _recalcCategorySizes() {
    // 从 isolate 扫描结果初始化（文件中已累计字节数，主线程无同步 stat）。
    _categorySizeCache['图片'] =
        (_fsCategorySizes['图片'] ?? 0) + _sumCachedEntitySize(_customImages);
    _categorySizeCache['视频'] =
        (_fsCategorySizes['视频'] ?? 0) + _sumCachedEntitySize(_customVideos);
    _categorySizeCache['截图'] =
        (_fsCategorySizes['截图'] ?? 0) +
        _sumCachedEntitySize(_customScreenshots);

    // 音频：isolate 已计 base 音频，自定义音频使用 SongModel.size（由 _scanCustomCategories 从 file.stat() 填入，无需 lengthSync）。
    int audioSize = _fsCategorySizes['音频'] ?? 0;
    for (final s in _audios) {
      if (s.id >= 900000) {
        try {
          audioSize += s.size;
        } catch (_) {}
      }
    }
    _categorySizeCache['音频'] = audioSize;

    // 非媒体大小只读取 MediaStore/isolate 已缓存的字节数，主线程不再同步 stat
    // 整个合并列表。自定义路径扫描结束时会补齐缺失的大小缓存。
    _categorySizeCache['文档'] = _sumCachedEntitySize(_documents);
    _categorySizeCache['压缩包'] = _sumCachedEntitySize(_archives);
    _categorySizeCache['安装包'] = _sumCachedEntitySize(_apks);
    _categorySizeCache['下载'] = _sumCachedEntitySize(_downloads);
    // 「最近」分类的 FileItemModel 自带 size 字段（字节）。
    int recentSize = 0;
    for (final r in _recentFiles) {
      try {
        recentSize += r.size;
      } catch (_) {}
    }
    _categorySizeCache['最近'] = recentSize;
    _categorySizeCache['应用'] = 0;
    _categorySizeCache['设置'] = 0;
    _categorySizeCache['网络'] = 0;
    _categorySizeCache['保险箱'] = 0;
    // 缓存到偏好设置，扫描未完成时可回落显示。
    // 防回写 0：媒体类别列表非空但本次计算出 0（统计尚未就绪/缓存损坏）时，
    // 沿用上次持久化的真实大小，避免「显示后再消失」并把 0 污染到持久层。
    final sizesToSave = <String, String>{};
    _categorySizeCache.forEach((k, v) {
      int value = v;
      if (value == 0 && _mediaListLen(k) > 0) {
        final prev = PreferencesService.getCategorySize(k);
        if (prev != null && prev > 0) value = prev;
      }
      sizesToSave[k] = value.toString();
    });
    PreferencesService.saveCategorySizes(sizesToSave);
  }

  /// 返回指定媒体分类的当前列表长度（用于判断「列表非空但大小为 0」是否为异常）。
  /// 扩展覆盖非媒体类别（文档/压缩包/安装包/下载），使 _recalcCategorySizes 防 0 回写
  /// 对这些类别同样生效，避免启动时短暂显示 0。
  int _mediaListLen(String category) {
    switch (category) {
      case '图片':
        return images.length;
      case '视频':
        return videos.length;
      case '截图':
        return screenshots.length;
      // 与分类卡片同源：过滤后条数为 0 时（例如列表里只剩 0 字节占位文件），
      // 应走「保留上次大小」分支，而不是按原始条数误判为「列表非空却大小为 0」。
      case '音频':
        return _displayCount('音频');
      case '文档':
        return _displayCount('文档');
      case '压缩包':
        return _displayCount('压缩包');
      case '安装包':
        return _displayCount('安装包');
      case '下载':
        return _displayCount('下载');
      default:
        return 0;
    }
  }

  /// 获取指定分类的文件总大小（字节）。优先使用扫描后的缓存，
  /// 未就绪时回落到偏好设置，均无数据返回 0。
  int getCategoryTotalSize(String category) {
    final live = _categorySizeCache[category];
    if (_isLoaded && live != null && live > 0) {
      return live;
    }
    // 回落：缓存为 0（损坏或统计尚未就绪）时，优先用上次持久化的真实大小，
    // 杜绝「启动显示大小 → 约 1 秒后归零 → 等待重载才恢复」的闪烁。
    final pref = PreferencesService.getCategorySize(category);
    if (pref != null && pref > 0) return pref;
    if (live != null) return live;
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
    // 骤减保护：本次数量远小于上次成功保存数量（不足一半）时，极可能是部分
    // 结果（fallback 递归扫描目录不全、或 MediaStore 瞬时繁忙只返回少量行），
    // 跳过落盘，防止把完好的大缓存覆盖成「只剩录音机」的残缺缓存——缓存一旦
    // 被污染，冷启动恢复的就是部分结果、叠加 querySongs 空时表现为音乐清零且
    // 刷新救不回（大存储多文件设备复现）。真删歌场景下仅缓存略陈旧，代价远小
    // 于污染。
    if (_lastSavedAudioCount > 0 && songs.length * 2 < _lastSavedAudioCount) {
      debugPrint(
        '[ZenFile] audio cache save skipped: ${songs.length} << '
        '$_lastSavedAudioCount（疑似部分结果，防止覆盖完好缓存）',
      );
      return;
    }
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
        // 缓存恢复同样要过滤本会话已删除的路径，否则从缓存"复活"刚删的音频。
        _audios = _stripDeletedAudios(songs);
        _audioFolders = _groupAudiosByParentDir(_audios);
        _fsCategorySizes['音频'] = _calcAudioSize(_audios);
        // 对齐内存计数：本次会话的「上次保存数量」即磁盘缓存数量，使
        // _saveAudioCache 的骤减保护跨进程生效——恢复全量后若某次保存
        // 试图写入远小于它的部分结果，会被拦截而不污染缓存。
        _lastSavedAudioCount = songs.length;
        debugPrint(
          '[ZenFile] audio index cache restored: ${songs.length}, '
          'size=${_fsCategorySizes['音频']}',
        );
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
      debugPrint(
        '[ZenFile] visual media cache saved: '
        'img=${imgs.length} vid=${vids.length} shot=${shots.length}',
      );
    } catch (e) {
      debugPrint('[ZenFile] _saveVisualCache error: $e');
    }
  }

  /// 在独立 isolate 里读取并解析视觉缓存文件，返回**紧凑**结构。
  ///
  /// ## 为什么必须隔离
  ///
  /// 视觉缓存 `media_visual_cache.json` 在大存储上可达数十 MB（每条媒体一个
  /// 对象）。老实现是在**主 isolate** 上 `jsonDecode(await file.readAsString())`
  /// —— 纯 CPU 解析几十 MB 的 JSON 会把 UI isolate **冻结 1~3 秒**
  /// （真机日志实测过一次 `[stall] UI 线程卡顿 2588ms`）。
  ///
  /// UI isolate 一冻结，指针事件就排在队列里等 ⇒ 用户看到的就是「点按钮没反应、
  /// 再点一次才生效」；**软键盘更惨** —— 它是独立进程，经 InputConnection 与
  /// 应用通信，主线程被占住时连按键都要延迟到第二次才生效。
  ///
  /// ## 为什么只把**路径**送进 isolate
  ///
  /// 若把 JSON 文本传给 `compute`，大字符串会被**深拷贝两份**（发送端 + 接收端），
  /// 峰值内存反而更高。所以让 isolate **自己读文件**，跨边界只走一个路径字符串。
  ///
  /// ## 返回值为什么是「平行数组」
  ///
  /// 返回 `{key: [List<String> paths, List<int> mtimes]}`，而不是原来的几十万
  /// 个 Map —— Map 的深拷贝才是跨 isolate 传输的大头，两个紧凑数组小得多。
  static Map<String, List<Object>> _readVisualCacheInIsolate(String path) {
    final out = <String, List<Object>>{};
    try {
      final raw = File(path).readAsStringSync();
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return out;
      for (final key in const ['images', 'videos', 'screenshots']) {
        final list = decoded[key];
        if (list is! List) continue;
        final paths = <String>[];
        final mtimes = <int>[];
        for (final m in list) {
          try {
            final map = m as Map;
            final p = map['p'] as String?;
            if (p == null || p.isEmpty) continue;
            paths.add(p);
            mtimes.add((map['m'] as int?) ?? 0);
          } catch (_) {}
        }
        if (paths.isNotEmpty) out[key] = <Object>[paths, mtimes];
      }
    } catch (_) {
      // 缓存损坏 / 文件不存在：当作没有缓存，让上层走全量扫描。
    }
    return out;
  }

  /// 从磁盘缓存恢复图片/视频/截图（仅当对应内存列表为空时），并播种 mtime 缓存
  /// 供排序零 stat。返回是否恢复过任意列表。
  Future<bool> _restoreVisualCache() async {
    bool restored = false;
    try {
      final file = await _mediaVisualCacheFile();
      if (!await file.exists()) return false;
      // ⚠️ 主 isolate 不碰这段 JSON（见 [_readVisualCacheInIsolate] 的注释）：
      // 这里只把路径送进 isolate，解析与读盘都在后台完成。
      final cachePath = file.path;
      final data = await compute(_readVisualCacheInIsolate, cachePath);

      void restore(String key, void Function(List<FileSystemEntity>) assign) {
        final entry = data[key];
        if (entry == null || entry.length < 2) return;
        final paths = entry[0];
        final mtimes = entry[1];
        if (paths is! List || mtimes is! List) return;
        final list = <FileSystemEntity>[];
        for (var i = 0; i < paths.length; i++) {
          final path = paths[i];
          if (path is! String || path.isEmpty) continue;
          list.add(File(path));
          final ms = (i < mtimes.length ? mtimes[i] : 0);
          if (ms is int && ms > 0) {
            _mtimeCache[path] = DateTime.fromMillisecondsSinceEpoch(ms);
          }
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
        debugPrint(
          '[ZenFile] visual media cache restored: '
          'img=${_images.length} vid=${_videos.length} shot=${_screenshots.length}',
        );
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
        if (_videoAssetByPathCache != null)
          return _videoAssetByPathCache![lower];
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
          '${(await getTemporaryDirectory()).path}/media_meta_cache.json',
        );
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
        // 恢复上次主动刷新的补充媒体（待系统索引加载后合并，见 loadMedia）
        if (r.supplementaryMedia != null) {
          _supplementaryMedia = r.supplementaryMedia;
        }
        _rebuildFolderGroups();
      }
    } catch (_) {}
  }

  /// 非媒体分类「主路径」：直接查询系统 MediaStore.Files（全量文件索引表）
  /// 填充文档/压缩包/安装包/下载，取代启动递归扫描。
  ///
  /// 参考主流文件管理器：其分类由 ProtocolTypeMediaStore 协议
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
  ///
  /// [unionWithExisting]：非强制（启动/懒加载）场景与内存现有列表（磁盘缓存
  /// 恢复的旧条目）按路径取并集——用户上次主动刷新发现的默认路径文件
  /// （MediaStore 未收录）重启后不丢失；主动刷新传 false 保持替换语义，
  /// 由全量递归扫描清除已删除文件的幽灵条目。
  Future<bool> _loadNonMediaViaMediaStore({
    bool unionWithExisting = false,
  }) async {
    try {
      const channel = MethodChannel('com.sequl.zenfile/media_store');
      // 清空上一次（或刷新前）的索引元数据缓存，避免陈旧路径残留导致误读。
      // union 模式保留旧缓存副本：并集保留的旧条目（磁盘缓存恢复、非本次
      // 查询覆盖）的大小/日期从中回填，分类总大小亦计入。
      final oldDates = unionWithExisting
          ? Map<String, int>.from(_nonMediaDates)
          : null;
      final oldSizes = unionWithExisting
          ? Map<String, int>.from(_nonMediaSizes)
          : null;
      _nonMediaDates.clear();
      _nonMediaSizes.clear();

      // 1) 文档/压缩包：按扩展名一次性查询（取并集避免多次往返）。
      // 注意：APK 不通过 MediaStore 查询（系统不索引 APK），APK 由 onlyApk 补扫。
      final unionExts = <String>{
        ..._docExtensions,
        ..._archiveExtensions,
      }.toList();
      final files = await channel.invokeListMethod<Map<dynamic, dynamic>>(
        'queryFiles',
        <String, dynamic>{'extensions': unionExts, 'pathContains': null},
      );
      if (files == null) return false;

      final docs = <FileSystemEntity>[];
      final arch = <FileSystemEntity>[];
      var docSize = 0;
      var archSize = 0;
      for (final m in files) {
        final path = m["path"] as String?;
        if (path == null) continue;
        final size = (m["size"] as int? ?? 0);
        final modified = (m["modified"] as int? ?? 0);
        final ext = FileUtils.effectiveExtensionWithDot(path);
        final f = File(path);
        _nonMediaDates[path] = modified;
        _nonMediaSizes[path] = size;
        if (_docExtensions.contains(ext)) {
          docs.add(f);
          docSize += size;
        } else if (_archiveExtensions.contains(ext)) {
          arch.add(f);
          archSize += size;
        }
      }
      if (docs.isEmpty && arch.isEmpty) return false;

      // 非强制场景与内存现有列表按路径取并集：保留用户上次主动刷新发现的
      // 默认路径文件（MediaStore 未收录），重启后不丢失；主动刷新直接替换，
      // 由全量递归扫描清除已删除文件的幽灵条目。
      List<FileSystemEntity> mergeWithExisting(
        List<FileSystemEntity> existing,
        List<FileSystemEntity> queried,
        int queriedSize,
        String sizeKey,
      ) {
        if (!unionWithExisting) {
          _fsCategorySizes[sizeKey] = queriedSize;
          return queried;
        }
        final seen = {for (final f in queried) f.path};
        var size = queriedSize;
        final kept = <FileSystemEntity>[];
        for (final f in existing) {
          if (seen.contains(f.path)) continue;
          kept.add(f);
          final s = oldSizes?[f.path];
          if (s != null) {
            _nonMediaSizes[f.path] = s;
            size += s;
          }
          final d = oldDates?[f.path];
          if (d != null) _nonMediaDates[f.path] = d;
        }
        _fsCategorySizes[sizeKey] = size;
        return [...queried, ...kept];
      }

      _documents = mergeWithExisting(_documents, docs, docSize, "文档");
      _archives = mergeWithExisting(_archives, arch, archSize, "压缩包");

      // 2) 下载：路径含 /download/（覆盖 Download/Downloads 及 OEM 变体）。
      final dl = await channel.invokeListMethod<Map<dynamic, dynamic>>(
        'queryFiles',
        <String, dynamic>{
          'extensions': <String>[],
          'pathContains': '/download/',
        },
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
      _downloads = mergeWithExisting(_downloads, downloads, dlSize, '下载');

      debugPrint(
        '[ZenFile] MediaStore non-media query done: '
        'docs=${_documents.length} arch=${_archives.length} dl=${_downloads.length} apk=${_apks.length} '
        'dateCache=${_nonMediaDates.length} sizeCache=${_nonMediaSizes.length}',
      );
      return true;
    } on PlatformException catch (e) {
      debugPrint(
        '[ZenFile] MediaStore non-media query PlatformException, fallback: $e',
      );
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
  Future<void> _scanNonMediaInBackground({
    bool force = false,
    bool includeMedia = false,
  }) async {
    if (_nonMediaScanRunning) return;
    if (_nonMediaScanDone && !force) return;
    _nonMediaScanRunning = true;
    if (force) _nonMediaScanDone = false;
    // 无条件通知：分类页底部提示条可靠出现（无论懒加载触发还是强制刷新）
    notifyListeners();
    try {
      // 主路径：直接查询系统 MediaStore.Files 索引填充非媒体分类（基于其
      // ProtocolTypeMediaStore 协议）。系统已预建索引→瞬时、穷尽、完整，
      // 彻底消除 dart:io 全盘递归在数十万文件下的 I/O 饱和与类别加载不全。
      // 仅当 MediaStore 不可用/无数据时回退到递归扫描（不卡顿场景下等价兜底）。
      final viaMediaStore = await _loadNonMediaViaMediaStore(
        unionWithExisting: !force,
      );
      if (force) {
        // 用户主动刷新（右上角刷新按钮/仪表盘下拉）：对默认路径做一次全量
        // 递归扫描（媒体+非媒体），与 MediaStore/系统索引结果按路径去重合并——
        // 系统索引未收录或收录不全的默认路径文件也能被刷出（此前刷新仅依赖
        // 索引，索引异常时只有自定义路径文件的根因）；自定义路径随后由
        // _scanCustomCategories 统一合并。
        await _runFileSystemScanInIsolate(
          force: force,
          includeMedia: true,
          unionNonMedia: viaMediaStore,
        ).catchError((Object e) {
          debugPrint(
            '[ZenFile] force full recursive scan failed, fallback: $e',
          );
          return _loadMediaFromFileSystem();
        });
        // 刷新发现的媒体同步进视觉/音频索引缓存：下次启动的毫秒级恢复
        // 窗口直接呈现完整列表（含系统索引未收录的默认路径文件）。
        await _saveVisualCache(_images, _videos, _screenshots);
        await _saveAudioCache(_audios);
      } else if (!viaMediaStore) {
        await _runFileSystemScanInIsolate(
          force: force,
          includeMedia: includeMedia,
        ).catchError((Object e) {
          debugPrint(
            '[ZenFile] background non-media scan failed, fallback: $e',
          );
          return _loadMediaFromFileSystem();
        });
      } else {
        // MediaStore 不索引 APK，APK 单独走 onlyApk 补扫；includeMedia 时
        // 一并并集合并文件系统发现的音频/图视（默认路径下系统索引未收录的音乐）。
        await _runFileSystemScanInIsolate(
          force: force,
          onlyApk: true,
          includeMedia: includeMedia,
        ).catchError((Object e) {
          debugPrint('[ZenFile] onlyApk supplementary scan failed: $e');
        });
      }
      await _refreshCustomCategoriesAndDerived();

      _saveNonMediaCategoryCounts();

      _nonMediaScanDone = true;
      notifyListeners();
      // 落盘前等待首次加载完成：进入类别页极快时扫描可能先于 loadMedia
      // 的缓存恢复结束，_saveCache 的 !_isLoaded 守卫会拦住导致扫描结果
      // 与 dirCache 丢失（下次启动又要全量重扫）。
      for (var i = 0; i < 100 && !_isLoaded; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      await _saveCache();
      // 启动（非强制）扫描并集合并了文件系统发现的音频/图视后，将完整结果
      // 落盘：下次启动从缓存恢复即为「系统索引 + 文件系统补充」的完整列表，
      // 彻底消除「过一会只剩录音机、刷新救不回」。与视频/图片的 _saveVisualCache
      // 一致；音频此前仅在 querySongs 全量时落盘，部分设备 querySongs 长期不全
      // 导致缓存永远只有录音机——现由可靠的文件系统枚举兜底补齐并持久化。
      if (includeMedia) {
        await _saveVisualCache(_images, _videos, _screenshots);
        await _saveAudioCache(_audios);
      }
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
        'recentFiles': _recentFiles
            .take(30)
            .map(
              (e) => {
                'path': e.path,
                'size': e.size,
                'modified': e.modified.millisecondsSinceEpoch,
              },
            )
            .toList(),
        // 分类大小与媒体数量：下次启动直接恢复，媒体数量未变时不做全量 stat
        'fsCategorySizes': _fsCategorySizes,
        'mediaCounts': {
          '图片': _images.length,
          '视频': _videos.length,
          '截图': _screenshots.length,
        },
        // 目录增量缓存：非媒体扫描跳过 mtime 未变目录（二次启动毫秒级完成）
        'dirCache': _dirCache,
        // 上次主动刷新发现的「索引未收录」补充媒体（仅差集，见字段注释）：
        // 系统索引不收录这些默认路径文件，重启后由此恢复，防止刷新成果丢失。
        if (_supplementaryMedia != null)
          'supplementaryMedia': _supplementaryMedia,
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
          '${(await getTemporaryDirectory()).path}/media_meta_cache.json',
        );
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
      _storageAccessible = await SlowOp.run('恢复刷新.存储探测', _verifyStorageAccess);
      debugPrint(
        '[ZenFile] refreshMediaBackground storageAccessible=$_storageAccessible '
        '(manageExternalStorage.isGranted=$rawManageGranted)',
      );

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
          now.difference(_lastBackgroundRefresh!) <
              const Duration(seconds: 30)) {
        return;
      }
      _lastBackgroundRefresh = now;

      // 与 loadMedia 一致：先独占式加载音频（querySongs 拿到全量，避免与 PhotoManager
      // fetchAll 并发抢 MediaStore 导致 querySongs 返回空、叠加缓存缺失时音频清零），
      // 再加载视频图片。Windows 桌面端无 MediaStore，跳过（数据源为文件系统扫描）。
      //
      // ⚠️ 每一步都套 [SlowOp]：这一步链是「回前台卡顿」的头号嫌疑，
      // 而帧日志只能看出「主线程被堵了 1.7 秒」说不出是哪一步。
      // 慢步骤会打印 `[慢操作] 恢复刷新.xxx NNNms`，下一份日志直接点名。
      if (!Platform.isWindows) {
        await SlowOp.run('恢复刷新.加载音频', () => _loadAudios(deferRetries: true));
        await SlowOp.run('恢复刷新.加载图视', _loadImagesAndVideos);
        // 回前台索引整表替换后，合并上次主动刷新持久化的补充媒体
        // （随后 pruneDeletedMedia 按存在性裁剪，顺带清掉补充集中已删除的幽灵）。
        await SlowOp.run('恢复刷新.合并补充媒体', _mergeSupplementaryMedia);
      }
      await SlowOp.run('恢复刷新.统计分类大小', _computeMediaCategorySizes);
      // 回前台时清理他应用/浏览页删除后残留的空白图标条目（基于存在性裁剪）。
      await SlowOp.run('恢复刷新.裁剪幽灵条目', pruneDeletedMedia);
      await SlowOp.run('恢复刷新.扫描自定义分类', _refreshCustomCategoriesAndDerived);
      // ⚠️⚠️ **这里原本有一次「全盘遍历」**（2026-11-27 移除）⚠️⚠️
      //
      // 原实现：`await _scanRecentFiles();`
      // 它会遍历 `/storage/emulated/0` 的**每一个一级子目录**并再往下展开一层，
      // 然后对**每一个文件**做一次 stat。真机日志实测（华为畅享 e20）：
      //   `[tap] 掉帧 1724ms (build 0ms, raster 6ms, vsync等待 1717ms, ...)`
      // 即**回前台后 UI 线程被整整占住 1.7 秒**——这段时间里 Android 主线程
      // 不派发 MotionEvent、不处理 IME 按键 ⇒ 用户点任意按钮/输入框都要点两次。
      //
      // 为什么这里**不需要**它：
      // * provider 里的 `_recentFiles` **只被自己消费**（分类页角标计数 +
      //   分类大小 + 落盘 30 条）；真正的「最近」页面
      //   （`all_recent_files_screen.dart`）**有自己独立的一套扫描实现**，
      //   打开时自己扫，不依赖 provider 这一份。
      // * 回前台的目的是「捡回在后台被改动的文件」，
      //   而这正是系统索引（MediaStore）负责的事，已经由上面的
      //   `_loadImagesAndVideos` / `_loadAudios` 完成。
      // ⇒ 全盘遍历从恢复路径上摘掉：角标计数沿用磁盘缓存里的值
      //   （与两次刷新之间的表现一致），「最近」页面打开时照旧自己扫描。
      await SlowOp.run('恢复刷新.落盘缓存', _saveCache);
      // 非媒体类别不再随 onResume 自动扫描（懒加载：进入分类页时才触发）

      PreferencesService.saveCategoryCount('图片', images.length);
      PreferencesService.saveCategoryCount('视频', videos.length);
      PreferencesService.saveCategoryCount('音频', audios.length);
      _saveNonMediaCategoryCounts();
      PreferencesService.saveCategoryCount('截图', screenshots.length);

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
  /// [includeMedia]：同时收集媒体类别（图/视/截/音），供用户主动刷新的
  /// 全量递归扫描使用——扫描结果与系统索引/已有列表按路径去重合并，
  /// 系统索引未收录或收录不全的默认路径文件也能被刷出。
  /// [unionNonMedia]：非媒体结果与已有列表（MediaStore 刚填充的新结果）
  /// 取并集而非替换，保留递归深度之外仅索引可见的深层文件。
  Future<void> _runFileSystemScanInIsolate({
    bool force = false,
    bool onlyApk = false,
    bool includeMedia = false,
    bool unionNonMedia = false,
  }) async {
    final searchDirs = await _getUserSearchDirs();
    debugPrint(
      '[ZenFile] non-media scan start: rootDirs=$searchDirs '
      'storageAccessible=$_storageAccessible',
    );
    if (searchDirs.isEmpty) return;
    // dart:io 存储访问探测失败（MIUI/澎湃误报 manageExternalStorage，或存储瞬时
    // 繁忙导致首列超时）时，不再直接跳过整个扫描——否则表现为「类别加载不出完全
    // / 空白」。仍尝试递归扫描：若目录真不可读，isolate 内 list() 抛异常并由 catch
    // 沿用缓存，mergeGuarded 会保留旧列表，空结果不会清空已显示内容。后续可接
    // MediaStore 兜底以彻底消除 dart:io 不可访问场景。
    if (!_storageAccessible) {
      debugPrint(
        '[ZenFile] 注意: dart:io 存储访问探测失败，仍尝试递归扫描'
        '（不可读目录将沿用缓存，空结果保留上次列表）',
      );
    }
    // 把"媒体类别噪音过滤"开关 prefetch 进 isolate 入参（isolate 静态方法不可
    // 调 PreferencesService），主线程读取一次后透传，isolate 内按开关决定是否
    // 触发 _kMin* 阈值。用户关闭某类后，该类别不再按尺寸过滤，保留全部原始
    // 文件——与"自定义快捷方式页面"中开关的语义一致。
    final noiseFilter = _MediaNoiseFilter(
      images: PreferencesService.getMediaNoiseFilter('图片'),
      videos: PreferencesService.getMediaNoiseFilter('视频'),
      screenshots: PreferencesService.getMediaNoiseFilter('截图'),
      documents: PreferencesService.getMediaNoiseFilter('文档'),
      archives: PreferencesService.getMediaNoiseFilter('压缩包'),
      downloads: PreferencesService.getMediaNoiseFilter('下载'),
      apks: PreferencesService.getMediaNoiseFilter('安装包'),
    );
    final params = _FSScanParams(
      roots: searchDirs,
      imageExtensions: _imageExtensions,
      videoExtensions: _videoExtensions,
      audioExtensions: _audioExtensions,
      docExtensions: _docExtensions,
      archiveExtensions: _archiveExtensions,
      apkExtensions: _apkExtensions,
      downloadDirs: Platform.isWindows
          ? <String>[
              if (Platform.environment['USERPROFILE'] case final home?
                  when home.isNotEmpty)
                '$home\\Downloads',
            ]
          : ['/storage/emulated/0/Download', '/storage/emulated/0/Downloads'],
      skipMediaCategories: !onlyApk && !includeMedia,
      onlyApk: onlyApk,
      dirCache: _dirCache,
      noiseFilter: noiseFilter,
      excludedFolders: _excludedFolders,
    );
    final result = await compute(_scanMediaFileSystemIsolate, params);
    // 整 map 替换前保留媒体大小（由系统索引路径 _computeMediaCategorySizes/_loadAudios
    // 维护，覆盖全量列表更完整；includeMedia 时 isolate 虽也含媒体键，但其仅统计
    // 递归扫描覆盖且通过噪声过滤的子集）。
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
    // - union 模式（MediaStore 刚填充过新结果）：与其取并集（按路径去重），
    //   保留递归深度之外仅索引可见的深层文件。
    // - 新结果不足旧列表一半且非强制刷新：并集兜底，保留旧条目，下次扫描修正。
    // - 强制刷新且扫描健康：直接替换，清除已删除文件的幽灵条目。
    List<FileSystemEntity> mergeGuarded(
      List<FileSystemEntity> oldFiles,
      List<String> newPaths, {
      bool union = false,
    }) {
      final newFiles = newPaths.map((e) => File(e)).toList();
      if (newFiles.isEmpty) {
        // 空结果：保留旧列表，防止瞬时空扫描导致内容消失。
        return oldFiles;
      }
      if (union) {
        final seen = newPaths.toSet();
        return [...newFiles, ...oldFiles.where((f) => !seen.contains(f.path))];
      }
      if (!force &&
          oldFiles.isNotEmpty &&
          newFiles.length < oldFiles.length / 2) {
        final seen = newPaths.toSet();
        return [...newFiles, ...oldFiles.where((f) => !seen.contains(f.path))];
      }
      return newFiles;
    }

    // 文档/压缩包/下载：unionNonMedia 时与 MediaStore 刚填充的新结果取并集；
    // APK（MediaStore 不索引，旧列表为陈旧缓存）保持替换语义以清除幽灵条目。
    _documents = mergeGuarded(
      _documents,
      result.documents,
      union: unionNonMedia,
    );
    _archives = mergeGuarded(_archives, result.archives, union: unionNonMedia);
    _downloads = mergeGuarded(
      _downloads,
      result.downloads,
      union: unionNonMedia,
    );
    _apks = mergeGuarded(_apks, result.apks);
    if (includeMedia) {
      // 媒体并集合并：递归扫描结果并入系统索引/已有列表（按归一化路径去重），
      // 默认路径下未被系统索引收录的媒体文件由此补齐（用户主动刷新场景）。
      // added 收集「索引/已有列表中不存在」的新增路径（差集），供持久化为
      // 补充媒体（_supplementaryMedia），下次启动合并回列表。
      List<FileSystemEntity> unionMedia(
        List<FileSystemEntity> oldFiles,
        List<String> newPaths,
        List<String>? added,
      ) {
        final seen = <String>{
          for (final f in oldFiles) _normalizeMediaPath(f.path),
        };
        final out = List<FileSystemEntity>.from(oldFiles);
        for (final np in newPaths) {
          if (seen.add(_normalizeMediaPath(np))) {
            out.add(File(np));
            added?.add(np);
          }
        }
        return out;
      }

      final supImages = <String>[];
      final supVideos = <String>[];
      final supScreenshots = <String>[];
      _images = unionMedia(_images, result.images, supImages);
      _videos = unionMedia(_videos, result.videos, supVideos);
      _screenshots = unionMedia(
        _screenshots,
        result.screenshots,
        supScreenshots,
      );
      // 音频：不再整体剥离 800000+ 合成条目（与 _mergeSupplementaryMedia 同理：
      // 列表可能整表来自缓存恢复的合成条目，querySongs 失败时是唯一数据源，
      // 剥掉即清零）。按 _data 路径去重并入本次结果；新条目编号从现有 800000+
      // 最大号之后递增，避免 _id 撞号。
      final audioSeen = <String>{
        for (final s in _audios) _normalizeMediaPath(s.data),
      };
      var synthId = 800000;
      for (final s in _audios) {
        if (s.id >= synthId && s.id < 900000) synthId = s.id + 1;
      }
      final supAudios = <Map<String, dynamic>>[];
      for (final m in result.audios) {
        final data = (m['_data'] as String?) ?? '';
        if (data.isEmpty) continue;
        if (!_isDeletedMediaPath(data) &&
            audioSeen.add(_normalizeMediaPath(data))) {
          final map = Map<String, dynamic>.from(m);
          map['_id'] = synthId++;
          _audios.add(SongModel(map));
          supAudios.add(m);
        }
      }
      // 持久化本次刷新发现的「索引未收录」补充媒体。
      // 关键修复：旧逻辑用「差集替换 + 全空则清零」，一旦系统后续索引到这些
      // 文件（或 MediaStore 瞬时就绪），差集为空就把整个补充集清零——这正是
      // 「刷新后图片出现、重启/过一会又消失、只剩系统索引」的根因。
      // 改为并集累计：旧补充集保留（清理已被删除/移走的幽灵路径），并入本次
      // 新发现的差集。即使系统本次就索引到了，旧补充集仍作为兜底保留，不丢失。
      // 扫描未产出任何媒体（很可能存储不可访问/扫描未执行）时，保留旧补充集
      // 不动，避免误清空。
      final scanProduced =
          result.images.isNotEmpty ||
          result.videos.isNotEmpty ||
          result.screenshots.isNotEmpty ||
          result.audios.isNotEmpty;
      if (scanProduced) {
        List<String> renewSup(List<dynamic>? old, List<String> added) {
          final set = <String>{};
          if (old != null) {
            for (final p in old) {
              if (p is! String) continue;
              // 幽灵清理：以磁盘真实存在性为准，而非「本次扫描是否扫到」。
              // 扫描根仅主目录(深度1)+热点目录(深度4)，且会跳过 Android/、
              // 隐藏目录；任何一次扫描瞬态不全/根范围变化都会把仍在磁盘上的
              // 补充路径误判为幽灵而永久清掉（并随 _saveCache 落盘）——
              // 「刷新后文件出现、重启后过一会又消失」的根因之一。
              // 补充路径均来自 isolate 递归扫描（dart:io list 产出），
              // existsSync 判存在语义正确可靠。
              try {
                if (File(p).existsSync()) {
                  set.add(_normalizeMediaPath(p));
                }
              } catch (_) {}
            }
          }
          for (final p in added) {
            set.add(_normalizeMediaPath(p));
          }
          return set.toList();
        }

        List<Map<String, dynamic>> renewSupAudios(
          List<dynamic>? old,
          List<Map<String, dynamic>> added,
        ) {
          final out = <Map<String, dynamic>>[];
          if (old != null) {
            for (final m in old) {
              if (m is! Map) continue;
              final data = m['_data'] as String?;
              if (data == null || data.isEmpty) continue;
              // 与 renewSup 同理：存在性判断，不依赖扫描覆盖范围。
              // 补充音频路径来自 isolate 扫描（dart:io 可访问），
              // existsSync 可靠；MediaStore 作用域存储路径不进补充集。
              try {
                if (File(data).existsSync()) {
                  out.add(Map<String, dynamic>.from(m));
                }
              } catch (_) {}
            }
          }
          out.addAll(added);
          return out;
        }

        final oldSup = _supplementaryMedia;
        _supplementaryMedia = {
          'images': renewSup(oldSup?['images'] as List?, supImages),
          'videos': renewSup(oldSup?['videos'] as List?, supVideos),
          'screenshots': renewSup(
            oldSup?['screenshots'] as List?,
            supScreenshots,
          ),
          'audios': renewSupAudios(oldSup?['audios'] as List?, supAudios),
        };
      }
      debugPrint(
        '[ZenFile] isolate scan media merged: '
        'images=${_images.length} videos=${_videos.length} '
        'shots=${_screenshots.length} audios=${_audios.length} '
        'supplementary(img=${supImages.length} vid=${supVideos.length} '
        'shot=${supScreenshots.length} audio=${supAudios.length})',
      );
    }
    // 分组已在 isolate 内算好，直接赋值，主线程不再做 O(n) 遍历分组。
    // 媒体分组随后由 _rebuildFolderGroups() 从系统索引列表重建（loadMedia 尾部统一调用）。
    // 分类大小已在上方合并（isolate 非媒体值 + 保留的媒体值）。
    debugPrint(
      '[ZenFile] isolate scan (non-media only) done: docs=${_documents.length} arch=${_archives.length} dl=${_downloads.length} apk=${_apks.length}',
    );
  }

  /// 与 main.dart 一致的真实存储访问探测：permission_handler 在 MIUI/澎湃等
  /// ROM 上可能误报 manageExternalStorage 的授权状态（true 时 dart:io 仍读不到、
  /// false 时实际已全部授权），故用一次真实目录枚举确认 dart:io 是否真能访问
  /// 主存储。返回 false 时非媒体递归扫描必然为空，需走 MediaStore 兜底。
  ///
  /// ## 为什么加缓存（2026-11-28）
  ///
  /// 这是一次**真实目录枚举**：`Directory('/storage/emulated/0').list()` 在
  /// Android 上走 FUSE，存储繁忙时单次列举可以耗时 1~3 秒。而本方法在
  /// **启动**（[loadMedia]）与**每次回前台**（[refreshMediaBackground]）各被
  /// 调用一次 —— 等于每回一次前台就先干等一次目录列举，后面的刷新动作全部
  /// 被推迟，用户在这段时间里按键就像「没反应」。
  ///
  /// 存储权限在运行期极少变化（卸载 App / 换卡才会变），故用 2 分钟 TTL 缓存，
  /// 期间直接复用结果；缓存只在**探测成功**后写入，失败不缓存（避免把一次
  /// 偶发的 FUSE 超时固化成「存储不可访问」的错误结论）。
  DateTime? _storageProbeAt;
  bool? _storageProbeResult;

  static const Duration _storageProbeTtl = Duration(minutes: 2);

  Future<bool> _verifyStorageAccess() async {
    final cachedAt = _storageProbeAt;
    final cached = _storageProbeResult;
    if (cached != null &&
        cachedAt != null &&
        DateTime.now().difference(cachedAt) < _storageProbeTtl) {
      return cached;
    }
    var accessible = false;
    try {
      // Windows 桌面端没有存储权限层：用用户主目录做一次真实枚举探测即可
      // （语义与 Android 的 /storage/emulated/0 探测一致——确认 dart:io 可用）。
      final dir = Directory(
        Platform.isWindows
            ? (Platform.environment['USERPROFILE'] ?? r'C:\Users')
            : '/storage/emulated/0',
      );
      await dir
          .list(followLinks: false, recursive: false)
          .first
          .timeout(const Duration(milliseconds: 1500));
      accessible = true;
    } on TimeoutException {
      // ⚠️ **超时 ≠ 不可访问**（2026-11-28 修正）。
      //
      // 「dart:io 读不到主存储」在 Android 上表现为**立刻**抛
      // FileSystemException（作用域存储拦截），而不是慢慢挂着。
      // 列举超时说明的是「存储慢」（FUSE 守护进程忙），**恰恰说明它能访问**。
      //
      // 旧实现把超时也判成 false ⇒ 一次偶发的 FUSE 慢就把
      // `_storageAccessible` 打成 false ⇒ 文档/压缩包/下载/安装包四个分类
      // 全空（走 MediaStore 兜底也补不全），用户看到的是「分类里的文件全没了」。
      // ⇒ 超时按**可访问**处理。
      accessible = true;
    } catch (_) {
      accessible = false;
    }
    // 只缓存「可访问」这一种结论：FUSE 偶发超时导致的 false 不能被固化。
    if (accessible) {
      _storageProbeAt = DateTime.now();
      _storageProbeResult = true;
    } else {
      _storageProbeAt = null;
      _storageProbeResult = null;
    }
    return accessible;
  }

  /// 启动/回前台时合并上次主动刷新持久化的补充媒体（默认路径下系统索引
  /// 未收录的文件，见 _supplementaryMedia）：系统索引加载会整表替换
  /// _images/_videos/_screenshots/_audios，补充媒体由此合并回列表，
  /// 修复「刷新后文件出现、重启后又消失」。按归一化路径去重；
  /// 音频合成条目复用 _id 800000+ 号段（先移除防止撞号）。
  Future<void> _mergeSupplementaryMedia() async {
    final sup = _supplementaryMedia;
    if (sup == null) {
      debugPrint('[ZenFile] supplementary media merge skipped: no cache');
      return;
    }
    try {
      List<String> pathsOf(String key) {
        final raw = sup[key];
        if (raw is! List) return const [];
        return [
          for (final e in raw)
            if (e is String && e.isNotEmpty) e,
        ];
      }

      var merged = 0;
      List<FileSystemEntity> unionPaths(
        List<FileSystemEntity> current,
        List<String> newPaths,
      ) {
        final seen = <String>{
          for (final f in current) _normalizeMediaPath(f.path),
        };
        final out = List<FileSystemEntity>.from(current);
        for (final np in newPaths) {
          if (seen.add(_normalizeMediaPath(np))) {
            out.add(File(np));
            merged++;
          }
        }
        return out;
      }

      final imgBefore = _images.length;
      final vidBefore = _videos.length;
      final shotBefore = _screenshots.length;
      _images = unionPaths(_images, pathsOf('images'));
      final imgAdded = _images.length - imgBefore;
      _videos = unionPaths(_videos, pathsOf('videos'));
      final vidAdded = _videos.length - vidBefore;
      _screenshots = unionPaths(_screenshots, pathsOf('screenshots'));
      final shotAdded = _screenshots.length - shotBefore;

      // 音频：不再整体剥离 800000+ 合成条目。列表可能整表来自磁盘缓存恢复的
      // 合成条目（历史版本 fallback 扫描整体替换后落盘污染所致），此刻 querySongs
      // 瞬时失败时它们是唯一数据源——先剥后并会把它们清零（「启动先显示 700+
      // 随后全部消失」的根因）。改为按归一化路径去重并入；新合成条目编号从
      // 现有 800000+ 最大号之后递增，同样避免 _id 撞号。幽灵条目待 querySongs
      // 成功整表替换或用户显式删除时自然清理。
      final audioSeen = <String>{
        for (final s in _audios) _normalizeMediaPath(s.data),
      };
      var synthId = 800000;
      for (final s in _audios) {
        if (s.id >= synthId && s.id < 900000) synthId = s.id + 1;
      }
      final rawAudios = sup['audios'];
      var audioAdded = 0;
      if (rawAudios is List) {
        for (final m in rawAudios) {
          if (m is! Map) continue;
          final data = m['_data'] as String?;
          if (data == null || data.isEmpty) continue;
          if (!_isDeletedMediaPath(data) &&
              audioSeen.add(_normalizeMediaPath(data))) {
            final map = Map<String, dynamic>.from(m);
            map['_id'] = synthId++;
            _audios.add(SongModel(map));
            audioAdded++;
          }
        }
      }
      debugPrint(
        '[ZenFile] supplementary media merged: '
        'added(img=$imgAdded vid=$vidAdded shot=$shotAdded '
        'audio=$audioAdded mergedTotal=$merged) → '
        'images=${_images.length} videos=${_videos.length} '
        'shots=${_screenshots.length} audios=${_audios.length}',
      );
    } catch (e) {
      debugPrint('[ZenFile] _mergeSupplementaryMedia error: $e');
    }
  }

  Future<void> loadMedia({bool forceRefresh = false}) async {
    try {
      // 防并发：已有扫描在跑时直接返回，避免重复全量扫描叠加导致主线程卡死。
      if (_isLoading) return;

      // 冷启动「解锁瞬间」先让输入法收完再扫（见 [StartupGate]）。
      // 全量索引（MediaStore 拉取 + 缓存反序列化 + 排序）都落在主 isolate 上，
      // 和 IME 收起动画抢帧的结果就是「键盘慢慢缩回去」。
      // 过闸后再查一次 _isLoading：等待期间可能有别的调用先开了扫描。
      await StartupGate.instance.waitIfSettling();
      if (!forceRefresh) {
        await StartupGate.instance.waitForColdStartIdle();
      }
      if (_isLoading) return;

      if (_isLoaded && !forceRefresh) {
        await _refreshCustomCategoriesAndDerived();
        notifyListeners();
        return;
      }

      _isLoading = true;
      notifyListeners();

      // 加载按类别独立排序的持久化设置（仅首次加载，后续设置时即时更新）
      if (_categorySortOrders.isEmpty) {
        await loadCategorySortOrders();
      }

      // Fast initial load from disk cache
      await SlowOp.run('启动加载.磁盘缓存', _loadFromDiskCache);
      // 音频冷启动兜底：磁盘缓存本身不恢复音频，若内存为空先尝试从音频索引
      // 缓存恢复，保证「曾成功加载过的音频」不会因 provider 重建或 MediaStore
      // 瞬时繁忙而永久消失（大存储用户已复现：加载完成后音频计数归零、刷新无效）。
      if (_audios.isEmpty) {
        await SlowOp.run('启动加载.音频缓存', _restoreAudioFromCache);
      }
      // 图片/视频/截图同样从磁盘缓存恢复（此前每次启动都重新分页拉取 PhotoManager，
      // 大存储设备需 ~1 分钟才就绪，且加载完成前列表为空、分类计数显示陈旧持久化值）。
      if (_images.isEmpty || _videos.isEmpty || _screenshots.isEmpty) {
        await SlowOp.run('启动加载.视觉缓存', _restoreVisualCache);
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
      _storageAccessible = await SlowOp.run('启动加载.存储探测', _verifyStorageAccess);
      debugPrint(
        '[ZenFile] loadMedia storageAccessible=$_storageAccessible '
        '(manageExternalStorage.isGranted=$rawManageGranted)',
      );

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
      if (Platform.isWindows) {
        // Windows 桌面端没有 MediaStore / photo_manager / on_audio_query：
        // 图/视/截/音全量由下方 _scanNonMediaInBackground(includeMedia: true)
        // 的 dart:io 递归扫描提供（isolate 内合成 SongModel，见音频合并处）。
        debugPrint('[ZenFile] loadMedia: Windows 端跳过系统媒体索引');
      } else {
        await SlowOp.run('启动加载.音频索引', () => _loadAudios(deferRetries: true));
        // ⚠️ 图视索引**不再阻塞启动路径**（2026-11-28 第十一轮）。
        //
        // 真机实测（华为畅享 e20）：`启动加载.图视索引 3672ms` ——
        // PhotoManager 分页拉全部媒体在这台机器上要 3.6 秒，而这 3.6 秒
        // **全程占着 UI isolate**（分页 await + 逐条 `_assetToFile` +
        // `_mtimeCache` 写入都在主 isolate），期间用户点任何按钮都会被排队
        // ⇒ 正好撞上「点击落在忙窗口 ⇒ 看起来像没反应」。
        //
        // 而此刻**磁盘缓存早已恢复完毕**（上面的 `启动加载.视觉缓存`），
        // 列表里已经有数据，系统索引只是一次「刷新」⇒ 完全可以挪到后台。
        //
        // 挪走之后：启动路径立刻走完 ⇒ App 立刻可交互；
        // 后台拉完后再赋值并 notifyListeners，分类页/首页计数自动刷新。
        if (forceRefresh) {
          await SlowOp.run('启动加载.图视索引', _loadImagesAndVideos);
        } else {
          unawaited(_loadImagesAndVideosInBackground());
        }
      }
      // 非强制（启动）加载：系统索引整表替换列表后，合并上次主动刷新持久化
      // 的补充媒体（索引未收录的默认路径文件），修复「刷新后文件出现、重启
      // 后又消失」。强制刷新走全量递归重扫 + 替换语义（清除幽灵条目），
      // 不合并旧补充集（扫描结束后由差集重建 _supplementaryMedia）。
      if (!forceRefresh) {
        await SlowOp.run('启动加载.补充媒体合并', _mergeSupplementaryMedia);
      }
      // 索引/补充合并完成后按存在性裁剪（isolate 内 stat）：清掉他应用删除后
      // MediaStore 仍返回的陈旧音频条目（分类页「空音频」删掉刷新又复活的根因），
      // 同时兜底图片/视频/非媒体残留。放在大小统计前，避免幽灵条目计入分类体积。
      await SlowOp.run('启动加载.裁剪已删条目', pruneDeletedMedia);
      await SlowOp.run('启动加载.分类大小', _computeMediaCategorySizes);

      // 用户主动刷新（右上角刷新按钮/仪表盘下拉刷新）：媒体系统索引就绪后，
      // 再对默认路径做全量递归扫描（媒体+非媒体，见 _scanNonMediaInBackground
      // 的 force 分支），结果与索引/自定义路径按路径去重合并。放在索引加载
      // 之后串行启动，避免递归扫描的媒体合并与索引列表赋值交错导致结果丢失；
      // 暂存 Future 待尾部 await，确保整个刷新期间 _isLoading 始终为真——
      // 刷新按钮据此保持禁用/置灰，防止狂点刷新重复触发全量扫描。
      Future<void>? pendingForceScan;
      if (forceRefresh) {
        pendingForceScan = _scanNonMediaInBackground(force: true);
      }

      // 启动即后台快速扫描非媒体类别（限定深度的热点目录，毫秒级完成），
      // 让首页分类计数与文档/压缩包/下载/安装包类别在用户进入前就就绪，
      // 消除「每次都要进类别等很久」的体感。_scanNonMediaInBackground 内部
      // 自带并发/重复守卫，不会与懒加载或强制刷新叠加。
      // 强制刷新已由上方 pendingForceScan 覆盖，此处仅在初始（非强制）加载时启动，避免重复扫描。
      if (!forceRefresh) {
        // 启动即后台并集合并文件系统发现的音频/图视（含标准音乐目录），
        // 以可靠的 dart:io 枚举兜底 on_audio_query querySongs 在部分设备上
        // 返回不全（仅录音机）的问题——与视频/图片的索引+补充合并一致。
        unawaited(_scanNonMediaInBackground(includeMedia: true));
      }

      await SlowOp.run('启动加载.自定义分类', _refreshCustomCategoriesAndDerived);
      // ⚠️ 这一步是**全盘遍历**（见 `refreshMediaBackground` 里同名的说明）：
      // 遍历 `/storage/emulated/0` 的每个一级子目录并再展开一层，逐文件 stat。
      // 启动时它发生在首帧之后，用户此时已经可以操作 ⇒ 同样会造成「点一下没反应」。
      // 遍历、stat、组装和排序都在 isolate 中完成，这里只记录耗时。
      await SlowOp.run('启动加载.最近文件全盘遍历', _scanRecentFiles);

      // 强制刷新：等待非媒体重扫真正完成后再翻 _isLoading=false（刷新按钮恢复可点）。
      if (pendingForceScan != null) {
        await pendingForceScan;
      }

      PreferencesService.saveCategoryCount('图片', images.length);
      PreferencesService.saveCategoryCount('视频', videos.length);
      PreferencesService.saveCategoryCount('音频', audios.length);
      PreferencesService.saveCategoryCount('截图', screenshots.length);
      _recalcCategorySizes();

      _isLoading = false;
      _isLoaded = true;
      _loadFailed = false;
      notifyListeners();

      // 强制刷新（刷新按钮/下拉刷新）落盘：loadMedia(forceRefresh) 路径下
      // _isLoaded 直至此处才置 true，而 _scanNonMediaInBackground(force) 内部
      // 的 _saveCache 因 !_isLoaded 守卫被拦截（见 2174 行），导致本次刷新
      // 发现的「系统未索引」补充媒体（图/视/截图/音频）与非媒体类别
      // （文档/压缩包/下载/安装包）改动从未写入磁盘缓存——重启后只剩系统
      // 索引到的内容，复现「刷新后文件出现、重启后又消失」。此处 _isLoaded
      // 已为真，显式落盘即可，且不破坏「首次未加载禁落盘」保护。
      if (forceRefresh) {
        await _saveCache();
      }
    } catch (e) {
      debugPrint('loadMedia error: $e');
      _isLoading = false;
      // 扫描中途异常：标记失败，浏览页显示「加载失败 + 重试」而非无限 shimmer
      _loadFailed = true;
      notifyListeners();
    }
  }

  static const List<String> _imageExtensions = [
    '.jpg',
    '.jpeg',
    '.png',
    '.gif',
    '.webp',
    '.bmp',
    '.svg',
    '.ico',
    '.tiff',
    '.tif',
    '.heic',
    '.heif',
    '.avif',
    '.raw',
  ];
  static const List<String> _videoExtensions = [
    '.mp4',
    '.mkv',
    '.avi',
    '.mov',
    '.wmv',
    '.flv',
    '.webm',
    '.3gp',
    '.ts',
    '.m4v',
    '.rmvb',
    '.rm',
    '.asf',
    '.f4v',
  ];
  static const List<String> _audioExtensions = [
    '.mp3',
    '.wav',
    '.flac',
    '.m4a',
    '.ogg',
    '.wma',
    '.aac',
    '.opus',
    '.amr',
    '.mid',
    '.midi',
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
        await _scanDirectoryRecursively(root.path, (_) => true, (file) async {
          final lower = file.path.toLowerCase();
          final ext = FileUtils.effectiveExtensionWithDot(lower);
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
            audios.add(
              SongModel({
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
              }),
            );
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
        });
      }

      _images = images;
      _videos = videos;
      // 音频改并集合并：此 fallback 的扫描目录范围有限（热点目录不含 Music 等，
      // 主目录仅 depth 1），大存储设备 isolate 扫描失败走此路径时，整体替换会把
      // 系统索引（querySongs）加载的全量音乐冲成「只剩录音机的音频」。与
      // _runFileSystemScanInIsolate 的 includeMedia 成功路径语义一致：先移除上次
      // 递归扫描合成的 800000+ 条目，再按归一化路径去重并入，绝不因部分结果
      // 缩减既有列表；空结果同样不清空（保留已显示音频）。
      if (audios.isNotEmpty) {
        final audioSeen = <String>{
          for (final s in _audios) _normalizeMediaPath(s.data),
        };
        var synthId = 800000;
        for (final s in _audios) {
          if (s.id >= synthId && s.id < 900000) synthId = s.id + 1;
        }
        for (final s in audios) {
          if (!_isDeletedMediaPath(s.data) &&
              audioSeen.add(_normalizeMediaPath(s.data))) {
            final map = Map<String, dynamic>.from(s.getMap);
            map['_id'] = synthId++;
            _audios.add(SongModel(map));
          }
        }
        _fsCategorySizes['音频'] = _calcAudioSize(_audios);
      }
      _screenshots = screenshots;
      // fallback 整表替换同样会清掉补充媒体（上次主动刷新持久化的
      // 索引未收录文件），替换后立即合并回来（幂等，按路径去重）。
      await _mergeSupplementaryMedia();
      _rebuildFolderGroups();
      debugPrint(
        '[ZenFile] _loadMediaFromFileSystem: images=${images.length}, videos=${videos.length}, audios=${audios.length}, screenshots=${screenshots.length}',
      );
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
  /// 系统媒体索引正在加载中（避免启动后台加载与用户手动刷新并发重复拉取）。
  bool _visualIndexLoading = false;

  /// 后台拉取系统媒体索引（**启动路径专用**）。
  ///
  /// ## 为什么要有这个方法（2026-11-28 第十一轮）
  ///
  /// `启动加载.图视索引` 在华为畅享 e20 上要 **3672ms**，且这 3.6 秒全程占着
  /// UI isolate（PhotoManager 分页 + 逐条 `_assetToFile` + `_mtimeCache` 写入
  /// 都在主 isolate）⇒ 期间用户的每一次点击都在排队 ⇒ 正是「点击落在忙窗口
  /// ⇒ 看起来像没反应」的高发时段。
  ///
  /// 而此刻**磁盘缓存早已恢复完毕**（启动序列里先跑 `启动加载.视觉缓存`），
  /// 列表里已经有数据，系统索引只是一次「刷新」⇒ 完全可以挪到后台。
  ///
  /// ## ⚠️ 为什么必须自己 notifyListeners
  ///
  /// 后台化之后，外层 `loadMedia` 已经跑完并不会再有统一的通知时机
  /// ⇒ 如果这里不通知，新拉到的数据要等「下一次刷新」才显示。
  Future<void> _loadImagesAndVideosInBackground() async {
    if (_visualIndexLoading) return;
    _visualIndexLoading = true;
    try {
      await SlowOp.run('后台加载.图视索引', _loadImagesAndVideos);
    } finally {
      _visualIndexLoading = false;
    }
    notifyListeners();
  }

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
              final assets = await album.getAssetListPaged(
                page: page,
                size: 2000,
              );
              for (var i = 0; i < assets.length; i++) {
                final f = _assetToFile(assets[i]);
                if (f != null) screenshotFiles.add(f);
                if ((i + 1) % 250 == 0) {
                  await Future<void>.delayed(Duration.zero);
                }
              }
              if (assets.length < 2000) break;
              await Future<void>.delayed(Duration.zero);
            }
          } catch (_) {}
        }
      }

      final allAlbum = albums.firstWhere(
        (a) => a.isAll,
        orElse: () => albums.first,
      );
      // Set 收集（保持插入序）：防御分页边界重复 / 部分 ROM「全部」相册
      // 与截图相册返回同一 asset 导致的同路径重复收录
      final imgs = <File>{};
      final vids = <File>{};
      final shots = <File>{};
      Future<void> collectBatch(List<AssetEntity> assets) async {
        for (var i = 0; i < assets.length; i++) {
          final a = assets[i];
          final f = _assetToFile(a);
          if (f != null) {
            // 播种 mtime 缓存：MediaStore 索引自带修改时间，排序零 stat
            try {
              _mtimeCache[f.path] = a.modifiedDateTime;
            } catch (_) {}
            if (a.type == AssetType.image) {
              final isShot =
                  screenshotFiles.contains(f) ||
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
          if ((i + 1) % 250 == 0) {
            await Future<void>.delayed(Duration.zero);
          }
        }
      }

      var scannedAssets = 0;
      for (var page = 0; ; page++) {
        final batch = await allAlbum.getAssetListPaged(page: page, size: 2000);
        await collectBatch(batch);
        scannedAssets += batch.length;
        if (batch.length < 2000) break;
        await Future<void>.delayed(Duration.zero);
      }
      if (scannedAssets == 0) {
        // 冷启动 MediaStore 瞬时未就绪：延迟后重试一次（与音频一致）
        await Future<void>.delayed(const Duration(milliseconds: 600));
        for (var page = 0; ; page++) {
          final batch = await allAlbum.getAssetListPaged(
            page: page,
            size: 2000,
          );
          await collectBatch(batch);
          if (batch.length < 2000) break;
          await Future<void>.delayed(Duration.zero);
        }
      }
      // 系统截图相册优先；补上「全部媒体」里按路径/文件名兜底判定到的截图
      for (final f in screenshotFiles) {
        if (!shots.contains(f)) shots.add(f);
      }
      // 屏蔽文件夹：系统媒体索引无法按目录排除，故在结果层面按各自分类剔除
      // 被屏蔽目录下的文件。与文件系统扫描的目录级剪枝共同保证「不再索引」。
      final imgExcl = _excludedFolders['图片'] ?? const <String>[];
      final vidExcl = _excludedFolders['视频'] ?? const <String>[];
      final shotExcl = _excludedFolders['截图'] ?? const <String>[];
      if (imgExcl.isNotEmpty)
        imgs.removeWhere((f) => _isPathExcluded(f.path, imgExcl));
      if (vidExcl.isNotEmpty)
        vids.removeWhere((f) => _isPathExcluded(f.path, vidExcl));
      if (shotExcl.isNotEmpty)
        shots.removeWhere((f) => _isPathExcluded(f.path, shotExcl));
      // 空结果不覆盖旧数据（与音频一致）：系统库瞬时异常时保留上次列表
      if (imgs.isNotEmpty || _images.isEmpty) _images = imgs.toList();
      if (vids.isNotEmpty || _videos.isEmpty) _videos = vids.toList();
      if (shots.isNotEmpty || _screenshots.isEmpty)
        _screenshots = shots.toList();
      debugPrint(
        '[ZenFile] system index: images=${imgs.length} videos=${vids.length} screenshots=${shots.length}',
      );
      // 关键防线：系统索引整表替换后立即合并补充媒体（幂等，按路径去重）。
      // 此前合并只在外层调用方（loadMedia/refreshMediaBackground）做，且晚于
      // 下方 _saveVisualCache——视觉缓存被落盘成「纯索引」列表（不含补充媒体），
      // 重启后 _restoreVisualCache 恢复的即缺失；若外层合并链路任一环节失效
      // （异常被吞/fallback 路径无合并），补充媒体在替换瞬间彻底丢失——正是
      // 「重启后过一会（冷启动索引拉取完成时）文件全部消失」的根因。
      // 移到此处后所有调用点（启动/onResume/刷新）替换即恢复，且视觉缓存
      // 恒含补充媒体。
      await _mergeSupplementaryMedia();
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
          (_fsCategorySizes['图片'] ?? 0) > 0 &&
          (_fsCategorySizes['视频'] ?? 0) > 0 &&
          (_fsCategorySizes['截图'] ?? 0) > 0) {
        return; // 数量未变且已缓存有效大小，沿用（避免重复全量 stat）
      }
      final imgPaths = _images.map((e) => e.path).toList();
      final vidPaths = _videos.map((e) => e.path).toList();
      final shotPaths = _screenshots.map((e) => e.path).toList();
      final results = await compute(_sumFileSizeGroupsInIsolate, [
        imgPaths,
        vidPaths,
        shotPaths,
      ]);
      _fsCategorySizes['图片'] = results[0];
      _fsCategorySizes['视频'] = results[1];
      _fsCategorySizes['截图'] = results[2];
      _lastMediaCounts = cur;
    } catch (e) {
      debugPrint('[ZenFile] _computeMediaCategorySizes error: $e');
    }
  }

  /// 音频时长阈值（用户原话"过滤 60 秒以内的音频"）。
  /// 仅对系统 MediaStore 索引（on_audio_query）返回的真实 duration 起效；
  /// 文件系统补充的合成音频（duration=0）不受此过滤，避免把"未知时长"的
  /// 音频当成音效过滤掉。受用户偏好控制：关闭后整段过滤短路，恢复全部。
  static const int _kMinAudioDurationMs = 60 * 1000; // 60 秒

  /// 后台重试音频索引（**不阻塞**启动/回前台的关键路径）。
  ///
  /// ## 为什么必须有它（2026-11-28）
  ///
  /// 真机日志（华为畅享 e20）：
  /// ```
  /// [慢操作] 启动加载.音频索引 5846ms
  /// [慢操作] 恢复刷新.加载音频 2553ms
  /// ```
  /// 该机 MediaStore 音频表**冷启动时未就绪**，`querySongs` 前几次都返回**空**
  /// （不抛异常），于是重试逻辑被触发：4 次 attempt + 中间
  /// 400+800+1200 = **2.4 秒纯睡眠**，全部压在**回前台**这条路径上 ——
  /// 而回前台正是用户「切回来立刻点按钮」最容易撞上的窗口。
  ///
  /// 现在关键路径只做一次查询；查不到就把整条重试链挪到这里，
  /// 拿到结果后按既有的「合并（绝不缩减）」语义并入 [_audios]。
  /// ⇒ 启动/回前台不再被 2.4 秒卡住，音频列表仍会在稍后补齐。
  Future<void> _loadAudiosRetryInBackground() async {
    try {
      await Future<void>.delayed(const Duration(milliseconds: 400));
      await _loadAudios();
    } catch (e) {
      debugPrint('[ZenFile] _loadAudios 后台重试失败: $e');
    }
  }

  /// 音频：改回系统级索引（MediaStore Audio 表，经 on_audio_query 查询）。
  /// SongModel._data 为完整路径，文件夹分组/播放器/缓存逻辑零改动。
  /// 用户偏好"音频噪音过滤"开启时，duration < 60s 的系统索引音频（音效/通知/
  /// 录音）会被过滤；用户偏好关闭时保留全部。
  ///
  /// ## [deferRetries] 的含义（2026-11-28）
  ///
  /// `true` = **关键路径模式**（启动 / 回前台）：只做**一次**查询，
  /// 拿不到就把整条重试链挪到后台（见 [_loadAudiosRetryInBackground]），
  /// 绝不让 2.4 秒的退避睡眠 + 3 次 MediaStore 查询压在这条路径上。
  /// `false` = 完整重试链（后台那次调用走这条）。
  Future<void> _loadAudios({bool deferRetries = false}) async {
    try {
      bool isStorageGranted = false;
      try {
        isStorageGranted =
            await Permission.storage.isGranted ||
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

      // 用户偏好：是否对音频按时长过滤（默认开）。关闭后保留系统索引返回的
      // 全量音频（含 < 60s 的音效/通知/录音）。文件系统补充的合成音频不应用此过滤。
      final audioFilterEnabled = PreferencesService.getMediaNoiseFilter('音频');

      /// 时长过滤 helper：对系统索引返回的真实音频条目按 duration 阈值过滤。
      /// 文件系统补充的合成条目（duration == 0 或 null）放行，不当作"短音"。
      List<SongModel> applyDurationFilter(List<SongModel> input) {
        if (!audioFilterEnabled) return input;
        return input.where((s) {
          try {
            final d = s.duration;
            // duration 为 null 或 0 表示未知（多来自文件系统补充），保留。
            if (d == null || d <= 0) return true;
            return d >= _kMinAudioDurationMs;
          } catch (_) {
            return true;
          }
        }).toList();
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
          if (deferRetries) {
            // ⚠️ **关键路径不再睡眠/重试**：整条重试链挪到后台。
            // 真机日志（华为畅享 e20）：`启动加载.音频索引 5846ms`、
            // `恢复刷新.加载音频 2553ms` —— 该机 MediaStore 音频表冷启动未就绪，
            // querySongs 前几次都返回**空**，于是旧逻辑跑满 4 次 attempt，
            // 中间 400+800+1200 = **2.4 秒纯睡眠**全压在启动/回前台的路径上。
            unawaited(_loadAudiosRetryInBackground());
            break;
          }
          await Future<void>.delayed(Duration(milliseconds: 400 * attempt));
        }
        try {
          final raw = await _audioQuery.querySongs(
            sortType: null,
            orderType: OrderType.ASC_OR_SMALLER,
            uriType: UriType.EXTERNAL,
            ignoreCase: true,
          );
          // 时长过滤应用在每次 attempt 的结果上，与"best 候选保留更大集合"
          // 配合：先过滤后比大小，避免把"过滤后很小但实际很大"的候选误淘汰。
          final result = applyDurationFilter(raw);
          if (result.isNotEmpty) {
            if (best == null || result.length > best.length) best = result;
            // ⚠️⚠️ **拿到非空结果即停止重试**（2026-11-28 修正）⚠️⚠️
            //
            // 原实现无条件跑满 4 次 attempt，中间的退避睡眠
            // 400 + 800 + 1200 = **2.4 秒**是纯等待，再叠加 4 次 MediaStore
            // 查询。真机日志实测（华为畅享 e20）：
            //   `[慢操作] 启动加载.音频索引 5645ms`
            //   `[慢操作] 恢复刷新.加载音频 2553ms`
            // ⇒ **每次启动、每次回前台都要白等 2.4 秒 + 多打 3 次查询**，
            // 而回前台正是用户「切回来立刻点按钮」最容易撞上的窗口。
            //
            // 为什么现在可以安全地提前退出：
            // 下方赋值处（`songs.length < _audios.length` 分支）**已经**用
            // 「按路径去重的并集合并」处理了「本次拿到的是部分结果」——
            // 即「已显示的保留、新发现的补入」，**绝不缩减既有列表**。
            // ⇒ 提前退出最多让本次少拿到几条，剩下的下一次刷新/回前台会补齐，
            //    代价远小于每次白等 2.4 秒。
            //
            // 「多次重试」的**真正**目的（见上方注释）只在**结果为空**时成立
            // ——MediaStore 瞬时未就绪会返回空列表。那种情况仍会继续重试。
            break;
          }
        } catch (e) {
          debugPrint(
            '[ZenFile] _loadAudios querySongs attempt $attempt 出错: $e',
          );
        }
      }
      songs = best;

      // 屏蔽文件夹：系统音频索引无法按目录排除，按路径剔除被屏蔽目录下的音频。
      final audioExcl = _excludedFolders['音频'] ?? const <String>[];
      if (songs != null && audioExcl.isNotEmpty) {
        songs = songs
            .where((s) => !_isPathExcluded(s.data, audioExcl))
            .toList();
      }

      // 过滤本会话已删除的路径：MediaStore 滞后时 querySongs 仍会返回已删除音频，
      // 不过滤就会让「浏览页删除音频」在分类页反复复活、手动刷新也去不掉。
      if (songs != null) songs = _stripDeletedAudios(songs);

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
          debugPrint(
            '[ZenFile] system index: audios=${songs.length}, '
            'audioFolders=${_audioFolders.length}, emptyData=$emptyData',
          );
          // 落盘：作为「重查失败/provider 重建」时的恢复源，避免音频永久消失。
          await _saveAudioCache(_audios);
        } else {
          // querySongs 返回部分结果（少于现有）：去重并入，绝不缩减既有列表。
          // 部分 ROM/大存储设备 MediaStore 音频表瞬时未就绪或长期只返回子集
          // （如仅录音机），整表替换会把已显示的完整音乐冲成「只剩录音机」，
          // 且一旦内存列表丢失便刷新救不回。改为并集合并：已显示的保留，
          // querySongs 新发现的（按路径去重）补入，与视频/图片的索引+补充
          // 合并语义一致。
          final seen = <String>{
            for (final s in _audios) _normalizeMediaPath(s.data),
          };
          var added = 0;
          for (final s in songs) {
            final d = s.data;
            if (d.isEmpty) continue;
            if (seen.add(_normalizeMediaPath(d))) {
              _audios.add(s);
              added++;
            }
          }
          if (added > 0) {
            _fsCategorySizes['音频'] = _calcAudioSize(_audios);
            _audioFolders = _groupAudiosByParentDir(_audios);
            await _saveAudioCache(_audios);
          }
          debugPrint(
            '[ZenFile] _loadAudios querySongs 部分结果(${songs.length})'
            '少于现有(${_audios.length})，已去重并入 $added 条，保留完整列表',
          );
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
        debugPrint(
          '[ZenFile] _loadAudios 兜底补算音频大小: '
          'count=${_audios.length}, size=${_fsCategorySizes['音频']}',
        );
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
  /// 改为：主目录扫 3 层（兜住散落文件以及「放在二级子目录里」的常见情形），
  /// 其余标准/常见目录按 4 层深扫。覆盖文档/压缩包/安装包/下载的绝大多数真实
  /// 位置（含 ZenFile/Backups/Apps、tencent/MicroMsg/Download 等），扫描量从
  /// 全树降到极小，且始终为限深扫描、不做无界递归。
  Future<List<_ScanRoot>> _getUserSearchDirs() async {
    final roots = <_ScanRoot>[];
    // ===== Windows 桌面端 =====
    // 用户主目录为主根（depth 3）+ 标准用户目录热点（depth 4）+
    // 非系统固定盘符根（depth 3）。系统盘根目录不直接扫描——Windows/Program
    // Files/AppData 等系统目录由 isolate 的 _isWindowsSystemDir 剪枝兜底，
    // 而系统盘的用户数据集中在主目录下，跳过根扫描可省去大量无效枚举。
    if (Platform.isWindows) {
      final home = Platform.environment['USERPROFILE'] ?? '';
      if (home.isNotEmpty && Directory(home).existsSync()) {
        roots.add(_ScanRoot(home, 3));
        for (final name in const [
          'Desktop',
          'Documents',
          'Downloads',
          'Pictures',
          'Music',
          'Videos',
        ]) {
          final d = Directory('$home\\$name');
          if (d.existsSync()) roots.add(_ScanRoot(d.path, 4));
        }
      }
      final homeDrive = home.isEmpty ? '' : home.substring(0, 1).toUpperCase();
      for (var i = 0; i < 26; i++) {
        final letter = String.fromCharCode(65 + i);
        if (letter == homeDrive) continue; // 系统盘已由主根覆盖
        try {
          final root = Directory('$letter:\\');
          if (root.existsSync()) roots.add(_ScanRoot(root.path, 3));
        } catch (_) {}
      }
      return roots;
    }
    try {
      final rootDir = Directory('/storage/emulated/0');
      if (await rootDir.exists()) {
        // 主目录 depth 3 兜底：一级、二级子目录及其下的三级子目录。既覆盖
        // 「音乐文件不在 /Music 等标准目录、用户随手丢在某个应用目录」的场景，
        // 也覆盖「文件放在二级子目录里」的常见情形——例如用户备份的安装包
        // `/storage/emulated/0/ZenFile/Backups/Apps`、微信接收文件
        // `/storage/emulated/0/tencent/MicroMsg/Download` 等；depth 2 时这些均
        // 漏扫（表现为「安装包类别只能看到最外层散落的 apk」）。仍为限深扫描、
        // 不做无界递归，配合下方 4 层热点目录，大存储下扫描量依然可控（增量
        // 仅为「主目录多进一层 list」，IO 主要来自热点目录）。
        roots.add(const _ScanRoot('/storage/emulated/0', 3));
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
          // 本应用自己的备份/接收目录（depth 4）：安装包备份
          // ZenFile/Backups/Apps、保险箱导出 ZenFile/Backups/safe、快传接收
          // ZenFile/Receive 都在其下，用户会期望这些文件出现在对应分类里。
          // 缓存/中间目录已由 _kAppCacheExcludeDirs 剪枝、隐藏目录自动跳过，
          // 因此这棵子树实际很小，深扫成本可忽略。
          '/storage/emulated/0/ZenFile',
          // 标准音乐/录音目录（depth 4）：on_audio_query 的 querySongs 在部分
          // ROM/大存储设备上仅返回 MediaStore 音频表子集（如只剩录音机），
          // 用户音乐库未被索引导致「音频加载后莫名消失、刷新救不回」。文件系统
          // 枚举（dart:io）100% 可靠，补这些标准目录使音频并集合并兜底能扫到
          // 用户音乐——与视频/图片「系统索引 + 文件系统补充合并」一致。
          '/storage/emulated/0/Music',
          '/storage/emulated/0/Recording',
          '/storage/emulated/0/Sounds',
          '/storage/emulated/0/Ringtones',
          // 通用录音目录名（多 OEM 共用），覆盖未列入 /Music 系列的录音/音乐/播客。
          '/storage/emulated/0/Voice Recorder',
          '/storage/emulated/0/VoiceRecorder',
          '/storage/emulated/0/Recordings',
          '/storage/emulated/0/Podcasts',
          '/storage/emulated/0/Audiobooks',
          '/storage/emulated/0/Audio',
          '/storage/emulated/0/Alarm',
          '/storage/emulated/0/Notifications',
          // 常见 OEM 录音/音乐专属目录：澎湃 OS（小米）、ColorOS（OPPO）、
          // MagicOS（荣耀）、EMUI/HarmonyOS（华为）等。路径不存在时 isolate 内
          // list() 抛异常被 catch 兜底，扫描成本几乎 0；存在时直接兜住录音/音乐。
          '/storage/emulated/0/MIUI/sound_recorder',
          '/storage/emulated/0/MIUI/Recorder',
          '/storage/emulated/0/MIUI/Music',
          '/storage/emulated/0/MIUI/ringtone',
          '/storage/emulated/0/ColorOS/Recorder',
          '/storage/emulated/0/ColorOS/Music',
          '/storage/emulated/0/HarmonyOS/Recorder',
          '/storage/emulated/0/Huawei/Music',
          '/storage/emulated/0/Honor/Recorder',
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
    var queueIndex = 0;
    // 周期性让出主线程：大存储设备（如澎湃OS 手机 256G+）下递归枚举会产生
    // 数十万实体，若不在循环里让出事件循环，主 isolate 会被长时间占满，
    // 表现为「打开 app 几秒后卡死 / ANR」。
    var processed = 0;
    while (queueIndex < queue.length) {
      final currentPath = queue[queueIndex++];
      final dir = Directory(currentPath);
      try {
        await for (final entity in dir.list(recursive: false)) {
          if (++processed % 256 == 0) {
            await Future.delayed(Duration.zero);
          }
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
              // 传「有效扩展名（含点，小写）」给 filter，且已忽略 IM 追加后缀
              // （`app.apk.1` → `.apk`），否则自定义路径扫描会漏掉 QQ 传来的文件。
              final ext = FileUtils.effectiveExtensionWithDot(entity.path);
              if (shouldInclude(ext)) {
                await onFound(entity);
              }
            }
          } catch (_) {}
        }
      } catch (_) {}
    }
  }

  static const List<String> _archiveExtensions = [
    '.zip',
    '.tar',
    '.gz',
    '.bz2',
    '.rar',
    '.7z',
  ];

  /// 与 [FileUtils.installPackageExtensions] 共用同一份清单：安装包分类、图标提取、
  /// 安装分发三处必须一致（原先这里漏了 `.apkm`，导致 `.apkm` 能装却不出现在分类里）。
  static const List<String> _apkExtensions = FileUtils.installPackageExtensions;

  Future<void> _refreshCustomCategoriesAndDerived() {
    final pending = _customCategoryRefreshFuture;
    if (pending != null) return pending;
    final future = _runCustomCategoryRefresh();
    _customCategoryRefreshFuture = future;
    return future.whenComplete(() {
      if (identical(_customCategoryRefreshFuture, future)) {
        _customCategoryRefreshFuture = null;
      }
    });
  }

  Future<void> _runCustomCategoryRefresh() async {
    await _scanCustomCategories();
    await _applySort();
    _rebuildFolderGroups();
    _recalcCategorySizes();
  }

  Future<void> _scanCustomCategories() async {
    // ⚠️ kind 供 isolate 版使用（闭包不能跨 isolate 传递）：
    // 0=图片（SVG+图片） / 1=视频 / 2=音频。语义与下面的 filter 完全一致。
    final imagePaths = _customCategoryPaths['图片'] ?? [];
    _customImages = await _scanCustomPaths(
      imagePaths,
      (p) => FileUtils.isSvg(p) || FileUtils.isImage(p),
      kind: 0,
    );

    final videoPaths = _customCategoryPaths['视频'] ?? [];
    _customVideos = await _scanCustomPaths(
      videoPaths,
      FileUtils.isVideo,
      kind: 1,
    );

    final screenshotPaths = _customCategoryPaths['截图'] ?? [];
    _customScreenshots = await _scanCustomPaths(
      screenshotPaths,
      (p) => FileUtils.isSvg(p) || FileUtils.isImage(p),
      kind: 0,
    );

    final audioPaths = _customCategoryPaths['音频'] ?? [];
    final customAudFiles = await _scanCustomPaths(
      audioPaths,
      FileUtils.isAudio,
      kind: 2,
    );
    // 仅当本次自定义路径扫描确实有产出（或本就无自定义路径配置）时，才按
    // 差集剥离旧合成条目（900000+，清掉已删除文件的幽灵）。远程服务器未
    // 连接 / 本地路径瞬时不可读时 _scanCustomPaths 返回空，旧逻辑「先剥后扫」
    // 会把磁盘缓存恢复的自定义音频全部清掉——「启动先显示 700+ 随后全部
    // 消失」的根因之一。扫描为空时保留旧条目，待下次扫描成功再清理幽灵。
    final customAudioPathSet = customAudFiles.map((f) => f.path).toSet();
    if (audioPaths.isEmpty || customAudFiles.isNotEmpty) {
      _audios.removeWhere(
        (song) => song.id >= 900000 && !customAudioPathSet.contains(song.data),
      );
    }
    final existingAudioPaths = _audios.map((s) => s.data).toSet();
    final localAudioPaths = customAudFiles
        .where(
          (f) =>
              !f.path.startsWith('remote://') &&
              !existingAudioPaths.contains(f.path),
        )
        .map((f) => f.path)
        .toList();
    final localAudioSizes = localAudioPaths.isEmpty
        ? const <int>[]
        : await compute(_fileSizesInIsolate, localAudioPaths);
    final audioSizes = <String, int>{
      for (var i = 0; i < localAudioPaths.length; i++)
        localAudioPaths[i]: localAudioSizes[i],
    };
    // 新增条目编号从现有 900000+ 最大号之后递增，避免与保留的旧条目撞号。
    var customAudioId = 900000;
    for (final s in _audios) {
      if (s.id >= customAudioId) customAudioId = s.id + 1;
    }
    for (final file in customAudFiles) {
      if (!existingAudioPaths.contains(file.path)) {
        try {
          final fileSize = audioSizes[file.path] ?? 0;
          final fileName = file.path.startsWith('remote://')
              ? file.path.split('|').last.split('/').last
              : p.basename(file.path);
          final songMap = {
            '_id': customAudioId++,
            '_data': file.path,
            'title': fileName.contains('.')
                ? fileName.substring(0, fileName.lastIndexOf('.'))
                : fileName,
            'artist': '',
            'album': '',
            'duration': 0,
            'size': fileSize,
            'display_name': fileName,
            'display_name_wo_ext': fileName.contains('.')
                ? fileName.substring(0, fileName.lastIndexOf('.'))
                : fileName,
            'is_music': true,
          };
          _audios.add(SongModel(songMap));
        } catch (_) {}
      }
    }

    // Documents custom path scan and merge
    final docPaths = _customCategoryPaths['文档'] ?? [];
    final customDocs = await _scanCustomPaths(
      docPaths,
      (ext) => _docExtensions.contains(ext),
      kind: 3,
    );
    final customDocPaths = customDocs.map((f) => f.path).toSet();
    _documents.removeWhere((entity) {
      final isInCustomPath = docPaths.any(
        (dir) => _isPathWithin(dir, entity.path),
      );
      return isInCustomPath && !customDocPaths.contains(entity.path);
    });
    final docPathsSeen = _documents.map((d) => d.path).toSet();
    for (final doc in customDocs) {
      if (docPathsSeen.add(doc.path)) {
        _documents.add(doc);
      }
    }

    // Archives custom path scan and merge
    final archPaths = _customCategoryPaths['压缩包'] ?? [];
    final customArch = await _scanCustomPaths(
      archPaths,
      (ext) => _archiveExtensions.contains(ext),
      kind: 4,
    );
    final customArchPaths = customArch.map((f) => f.path).toSet();
    _archives.removeWhere((entity) {
      final isInCustomPath = archPaths.any(
        (dir) => _isPathWithin(dir, entity.path),
      );
      return isInCustomPath && !customArchPaths.contains(entity.path);
    });
    final archPathsSeen = _archives.map((a) => a.path).toSet();
    for (final arc in customArch) {
      if (archPathsSeen.add(arc.path)) {
        _archives.add(arc);
      }
    }

    // APKs custom path scan and merge
    final apkPaths = _customCategoryPaths['安装包'] ?? [];
    final customApks = await _scanCustomPaths(
      apkPaths,
      (ext) => _apkExtensions.contains(ext),
      kind: 5,
    );
    final customApkPaths = customApks.map((f) => f.path).toSet();
    _apks.removeWhere((entity) {
      final isInCustomPath = apkPaths.any(
        (dir) => _isPathWithin(dir, entity.path),
      );
      return isInCustomPath && !customApkPaths.contains(entity.path);
    });
    final apkPathsSeen = _apks.map((a) => a.path).toSet();
    for (final apk in customApks) {
      if (apkPathsSeen.add(apk.path)) {
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
    final customDlPathSet = customDls.map((f) => f.path).toSet();
    _downloads.removeWhere((entity) {
      final isInCustomPath = customDlPaths.any(
        (dir) => _isPathWithin(dir, entity.path),
      );
      return isInCustomPath && !customDlPathSet.contains(entity.path);
    });
    final dlPathsSeen = _downloads.map((d) => d.path).toSet();
    for (final dl in customDls) {
      if (dlPathsSeen.add(dl.path)) {
        _downloads.add(dl);
      }
    }

    await _cacheCustomEntitySizes([
      ..._customImages,
      ..._customVideos,
      ..._customScreenshots,
      ...customDocs,
      ...customArch,
      ...customApks,
      ...customDls,
    ]);
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
  String _normalizeMediaPath(String path) =>
      path.replaceAll(RegExp(r'/+'), '/');

  /// 自定义分类路径扫描。
  ///
  /// ## [kind] 的含义（isolate 版用整数代替闭包，闭包不能跨 isolate 传递）
  /// * 0 = 图片（SVG + 图片）
  /// * 1 = 视频
  /// * 2 = 音频
  /// * 3 = 文档
  /// * 4 = 压缩包
  /// * 5 = 安装包
  /// * -1 = 未知（此时**不走 isolate**，退回主 isolate 的旧路径）
  ///
  /// ## 为什么本地路径要挪进 isolate（2026-11-28）
  /// 真机实测（华为畅享 e20）：这段递归遍历在主 isolate 上跑要 **1020ms**
  /// （`[慢操作] 启动加载.自定义分类 1020ms`），而且它用的是
  /// `await for` 遍历目录流 —— **每个文件都是一个微任务，几千个微任务会把
  /// 事件循环饿死**，输入事件排在队列里 ⇒ 表现为「点任意按钮要点两次」。
  /// 挪进 isolate 后主 isolate 只收结果，遍历不再占用事件循环。
  ///
  /// 远程路径（`remote://`）**仍留在主 isolate**：它要走网络客户端，
  /// 而网络客户端不能跨 isolate 传递。
  Future<List<File>> _scanCustomPaths(
    List<String> paths,
    bool Function(String path) filter, {
    int kind = -1,
  }) async {
    final files = <File>[];
    final localPaths = <String>[];
    final remotePaths = <String>[];
    for (final path in paths) {
      if (path.startsWith('remote://')) {
        remotePaths.add(path);
      } else {
        localPaths.add(path);
      }
    }
    if (localPaths.isNotEmpty && kind >= 0) {
      try {
        final found = await compute(_scanCustomLocalPathsInIsolate, (
          paths: localPaths,
          kind: kind,
        ));
        files.addAll(found.map(File.new));
      } catch (_) {
        // isolate 失败时回退主 isolate 扫描，**保证功能不降级**。
        for (final path in localPaths) {
          if (await Directory(path).exists()) {
            await _scanDirectoryRecursively(
              path,
              filter,
              (file) => files.add(file),
            );
          }
        }
      }
    } else {
      for (final path in localPaths) {
        if (await Directory(path).exists()) {
          await _scanDirectoryRecursively(
            path,
            filter,
            (file) => files.add(file),
          );
        }
      }
    }
    for (final path in remotePaths) {
      files.addAll(await _scanRemotePath(path, filter));
    }
    return files;
  }

  /// 扫描远程服务器路径，返回以 `remote://{connectionId}|{remotePath}` 为路径的 File 对象列表。
  Future<List<File>> _scanRemotePath(
    String remotePathStr,
    bool Function(String path) filter,
  ) async {
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
    void Function(String remoteFilePath, int size, DateTime modified)
    onFileFound, {
    int depth = 0,
  }) async {
    if (depth > 5) return; // 限制递归深度防止过深扫描
    try {
      final items = await client.listDirectory(path);
      for (final item in items) {
        if (item.isDirectory) {
          await _scanRemoteDirectoryRecursively(
            client,
            item.path,
            filter,
            connectionId,
            onFileFound,
            depth: depth + 1,
          );
        } else {
          // 与本地 _scanDirectoryRecursively 保持一致：传「扩展名（含点，小写）」给 filter，
          // 这样文档/压缩包/安装包的 `(ext) => _xxExtensions.contains(ext)` 才能正确匹配
          // （此前误传完整文件名导致远程文档等永远扫描不到）。
          // effectiveExtensionWithDot 已忽略 IM 追加后缀（`app.apk.1` → `.apk`）。
          final ext = FileUtils.effectiveExtensionWithDot(item.name);
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

  // --- 分类屏蔽文件夹：添加后该分类不再扫描/索引此文件夹下的文件 ---
  void addExcludedFolder(String category, String path) {
    if (!_excludedFolders.containsKey(category)) {
      _excludedFolders[category] = [];
    }
    if (!_excludedFolders[category]!.contains(path)) {
      _excludedFolders[category]!.add(path);
      PreferencesService.saveExcludedFolders(_excludedFolders);
      notifyListeners();
      loadMedia(forceRefresh: true);
    }
  }

  void removeExcludedFolder(String category, String path) {
    if (_excludedFolders.containsKey(category)) {
      if (_excludedFolders[category]!.remove(path)) {
        PreferencesService.saveExcludedFolders(_excludedFolders);
        notifyListeners();
        loadMedia(forceRefresh: true);
      }
    }
  }

  /// 「最近」列表的全量扫描（**遍历 + stat 全部在 isolate 内完成**）。
  ///
  /// ## 为什么必须挪进 isolate（2026-11-28）
  ///
  /// 真机实测（华为畅享 e20，2026-11-28）：
  /// ```
  /// [慢操作] 启动加载.自定义分类 1020ms
  /// [tap] 主线程阻塞 1724ms / 2981ms
  /// [tap] 点击回调迟到 411ms
  /// [tap] 点击未生效：按下后 800ms 仍无 onTap 回调
  /// ```
  /// 旧实现把「遍历整个存储 + 逐文件 stat」放在**主 isolate** 上：
  /// * 遍历用的是 `await for` 遍历目录流 —— **每个文件都是一个微任务**，
  ///   几千个微任务会把**事件循环饿死**，输入事件排在队列里等；
  /// * stat 更是成百上千次异步 IO，续体全在主 isolate 上跑。
  /// ⇒ 结果就是「主线程被整段占住 1~3 秒」，期间点任何按钮都要点两次。
  ///
  /// 现在：主 isolate 只负责①列出根目录（一次 `list()`，很轻）和②接收结果；
  /// 遍历、stat、模型组装与排序全部交给独立 isolate。
  ///
  /// ## 语义保持不变
  /// * 遍历深度、隐藏目录/隐藏文件过滤、目录去重规则、逐文件 stat ——
  ///   全部照搬旧实现（见 [_scanRecentFilesInIsolate]）。
  Future<void> _scanRecentFiles() async {
    // 「显示隐藏文件」总开关：关闭时（默认）最近列表既不扫隐藏目录也不收录
    // 隐藏文件，与浏览页的可见性保持一致；开启后才把点开头（系统隐藏）的
    // 目录/文件一并纳入。此前这里无条件跳过隐藏目录、却又无条件丢弃点开头
    // 的文件，导致部分系统隐藏条目仍从其它来源（下载/文档/压缩包/音频清单）
    // 漏进「最近」。
    final showHidden = PreferencesService.getShowHiddenFiles();

    // ① 根目录的一级子目录（排除隐藏目录 / Android / Windows 系统目录 /
    //    本应用缓存目录）——一次 `list()`，很轻，留在主 isolate。
    final pathsToScan = <String>[];
    final rootDir = Directory(
      Platform.isWindows
          ? (Platform.environment['USERPROFILE'] ?? '')
          : '/storage/emulated/0',
    );
    if (rootDir.path.isNotEmpty && await rootDir.exists()) {
      try {
        final rootEntities = await rootDir.list(recursive: false).toList();
        for (final entity in rootEntities) {
          if (entity is Directory) {
            final name = p.basename(entity.path);
            final hiddenDir = name.startsWith('.');
            if ((!hiddenDir || showHidden) &&
                name != 'Android' &&
                !_isWindowsSystemDir(name) &&
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
      } catch (_) {}
    }

    // ② 各分类清单里的文件路径：也交给 isolate 一并去重 + stat，
    //    避免主 isolate 再跑一轮 stat。
    final extraPaths = <String>[
      ..._downloads.map((e) => e.path),
      ..._documents.map((e) => e.path),
      ..._archives.map((e) => e.path),
      ..._apks.map((e) => e.path),
      ..._audios.map((s) => s.data).where((p) => p.isNotEmpty),
    ];

    final items = await compute(_scanRecentFilesInIsolate, (
      pathsToScan: pathsToScan,
      extraPaths: extraPaths,
      showHidden: showHidden,
    ));
    _recentFiles = items;
  }

  /// 「最近」列表的遍历 + 逐文件 stat（**在 isolate 内执行**）。
  ///
  /// 语义与旧的主 isolate 实现逐条对齐：
  /// * 遍历每个待扫目录的**直接子项**，并对**子目录再展开一层**；
  /// * `expandedDirs`（已展开过子项的目录）本身不作为条目出现；
  /// * 关闭「显示隐藏文件」时，点开头的文件、以及路径中含隐藏段的条目一律剔除；
  /// * 逐文件 stat 取 size / modified。
  ///
  @pragma('vm:entry-point')
  static Future<List<FileItemModel>> _scanRecentFilesInIsolate(
    ({List<String> pathsToScan, List<String> extraPaths, bool showHidden}) req,
  ) async {
    final seen = <String>{};
    final files = <String>[];

    for (final path in req.pathsToScan) {
      try {
        final dir = Directory(path);
        if (!await dir.exists()) continue;
        final entities = await dir.list(recursive: false).toList();
        for (final entity in entities) {
          if (!seen.add(entity.path)) continue;
          if (entity is Directory) {
            if (req.showHidden || !p.basename(entity.path).startsWith('.')) {
              try {
                final sub = await entity.list(recursive: false).toList();
                for (final s in sub) {
                  if (seen.add(s.path)) files.add(s.path);
                }
              } catch (_) {}
            }
          } else {
            files.add(entity.path);
          }
        }
      } catch (_) {}
    }

    // 各分类清单里的文件（下载/文档/压缩包/安装包/音频）也纳入并去重。
    for (final p in req.extraPaths) {
      if (p.isEmpty) continue;
      if (seen.add(p)) files.add(p);
    }

    // 隐藏文件过滤：点开头，或路径中任意一段以点开头（系统隐藏目录）。
    final visible = <String>[];
    for (final f in files) {
      if (!req.showHidden) {
        final name = p.basename(f);
        if (name.startsWith('.') || _hasHiddenSegment(f)) continue;
      }
      visible.add(f);
    }

    // 逐文件 stat：分批 + 批间让出事件循环（isolate 内也让，I/O 更平滑、
    // 峰值内存更低）。
    final items = <FileItemModel>[];
    const batchSize = 200;
    for (var start = 0; start < visible.length; start += batchSize) {
      final end = start + batchSize < visible.length
          ? start + batchSize
          : visible.length;
      final chunk = visible.sublist(start, end);
      final stats = await Future.wait(
        chunk.map((f) async {
          try {
            final st = await File(f).stat();
            return (size: st.size, ms: st.modified.millisecondsSinceEpoch);
          } catch (_) {
            return (size: -1, ms: 0);
          }
        }),
      );
      for (var i = 0; i < chunk.length; i++) {
        if (stats[i].size < 0) continue; // 文件已消失 / 不可访问
        final path = chunk[i];
        items.add(
          FileItemModel(
            entity: File(path),
            name: p.basename(path),
            path: path,
            isDirectory: false,
            size: stats[i].size,
            modified: DateTime.fromMillisecondsSinceEpoch(stats[i].ms),
          ),
        );
      }
      await Future<void>.delayed(Duration.zero);
    }
    items.sort((a, b) => b.modified.compareTo(a.modified));
    return items;
  }

  /// 自定义分类路径的递归扫描（**在 isolate 内执行**）。
  ///
  /// ## 为什么必须挪进 isolate（2026-11-28）
  /// 真机实测（华为畅享 e20）：这段递归遍历在主 isolate 上要 **1020ms**
  /// （`[慢操作] 启动加载.自定义分类 1020ms`）。它用的是 `await for` 遍历
  /// 目录流 —— **每个文件都是一个微任务**，几千个微任务会把**事件循环饿死**，
  /// 输入事件排在队列里 ⇒ 表现为「点任意按钮要点两次」。
  ///
  /// ## [kind]
  /// * 0 = 图片（SVG + 图片）
  /// * 1 = 视频
  /// * 2 = 音频
  /// * 3 = 文档
  /// * 4 = 压缩包
  /// * 5 = 安装包
  ///
  /// 闭包不能跨 isolate 传递，所以这里用整数种类代替 filter 闭包；
  /// 判定用的仍是同一套 [FileUtils] 函数、同一套扩展名口径
  /// （`effectiveExtensionWithDot`，与旧实现完全一致）。
  @pragma('vm:entry-point')
  static Future<List<String>> _scanCustomLocalPathsInIsolate(
    ({List<String> paths, int kind}) req,
  ) async {
    final out = <String>[];
    for (final start in req.paths) {
      final queue = <String>[start];
      var queueIndex = 0;
      while (queueIndex < queue.length) {
        final current = queue[queueIndex++];
        try {
          await for (final entity in Directory(
            current,
          ).list(recursive: false)) {
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
                // 传「有效扩展名（含点，小写）」，并已忽略 IM 追加后缀
                // （`app.apk.1` → `.apk`），否则自定义路径扫描会漏掉 QQ 传来的文件。
                final ext = FileUtils.effectiveExtensionWithDot(entity.path);
                if (_matchesCustomKind(req.kind, ext)) out.add(entity.path);
              }
            } catch (_) {}
          }
        } catch (_) {}
      }
    }
    return out;
  }

  /// 自定义分类的扩展名判定（**与主 isolate 的旧实现语义完全一致**）。
  ///
  /// kind 语义见 [_scanCustomLocalPathsInIsolate]。
  /// 3/4/5 用的是本类里那三份**静态**扩展名清单 —— 静态常量可以直接在
  /// isolate 里读，不需要跨边界传闭包。
  static bool _matchesCustomKind(int kind, String ext) {
    switch (kind) {
      case 0:
        return FileUtils.isSvg(ext) || FileUtils.isImage(ext);
      case 1:
        return FileUtils.isVideo(ext);
      case 2:
        return FileUtils.isAudio(ext);
      case 3:
        return _docExtensions.contains(ext);
      case 4:
        return _archiveExtensions.contains(ext);
      case 5:
        return _apkExtensions.contains(ext);
      default:
        return true;
    }
  }

  /// 路径中任意一段以点开头（系统隐藏目录）即视为隐藏路径。
  /// 仅用于「最近」列表过滤，跳过分区根（`/`、`C:\`、空段）。
  static bool _hasHiddenSegment(String path) {
    for (final seg in p.split(path)) {
      if (seg == '/' || seg == '\\' || seg.isEmpty) continue;
      if (seg.length > 1 && seg.endsWith(':')) continue;
      if (seg.startsWith('.')) return true;
    }
    return false;
  }

  /// 「显示隐藏文件」开关变化后重建「最近」列表（无需整库重扫）。
  Future<void> refreshRecentFilesForHiddenSetting() async {
    try {
      await _scanRecentFiles();
      notifyListeners();
    } catch (_) {}
  }

  Future<void> setSortOrder(MediaSortOrder order, {String? category}) async {
    if (category != null) {
      _categorySortOrders[category] = order;
      await PreferencesService.saveCategorySortOrder(category, order.name);
      // 清除该类别的 getter 缓存，强制重新排序
      _clearCategoryCache(category);
    } else {
      _sortOrder = order;
      await _applySort();
    }
    notifyListeners();
  }

  /// 清除指定类别的 getter 缓存（排序/排除变化时调用）。
  void _clearCategoryCache(String category) {
    switch (category) {
      case '图片':
        _imagesOut = null;
        _imagesStamp = 0;
        break;
      case '视频':
        _videosOut = null;
        _videosStamp = 0;
        break;
      case '截图':
        _shotsOut = null;
        _shotsStamp = 0;
        break;
    }
  }

  /// 批量预加载排序真正需要的文件元数据，避免比较器同步 stat。
  /// 分批执行且只读取缺失字段：按日期排序不再为了拿 size 遍历全部文件。
  Future<Map<String, ({int size, DateTime modified})>> _preloadStats(
    List<FileSystemEntity> entities, {
    required bool needDate,
    required bool needSize,
  }) async {
    final map = <String, ({int size, DateTime modified})>{};
    if (!needDate && !needSize) return map;
    final pending = <FileSystemEntity>[];
    for (final e in entities) {
      if (e.path.startsWith('remote://')) {
        final modified = _remoteFileModified[e.path];
        final size = _remoteFileSizes[e.path];
        if (modified != null) _mtimeCache[e.path] = modified;
        if (size != null) _sizeCache[e.path] = size;
        map[e.path] = (
          size: size ?? 0,
          modified: modified ?? DateTime.fromMillisecondsSinceEpoch(0),
        );
        continue;
      }
      final indexedDate = _nonMediaDates[e.path];
      final modified =
          _mtimeCache[e.path] ??
          (indexedDate == null
              ? null
              : DateTime.fromMillisecondsSinceEpoch(indexedDate));
      final indexedSize = _sizeCache[e.path] ?? _nonMediaSizes[e.path];
      final size = indexedSize != null && indexedSize >= 0 ? indexedSize : null;
      if ((!needDate || modified != null) && (!needSize || size != null)) {
        if (modified != null) _mtimeCache[e.path] = modified;
        if (size != null) _sizeCache[e.path] = size;
        map[e.path] = (
          size: size ?? 0,
          modified: modified ?? DateTime.fromMillisecondsSinceEpoch(0),
        );
      } else {
        pending.add(e);
      }
    }
    const batch = 200;
    for (var i = 0; i < pending.length; i += batch) {
      final end = i + batch < pending.length ? i + batch : pending.length;
      final chunk = pending.sublist(i, end);
      await Future.wait(
        chunk.map((e) async {
          try {
            final stat = await File(e.path).stat();
            _mtimeCache[e.path] = stat.modified;
            _sizeCache[e.path] = stat.size;
            map[e.path] = (size: stat.size, modified: stat.modified);
          } catch (_) {}
        }),
      );
      await Future<void>.delayed(Duration.zero);
    }
    return map;
  }

  Future<void> _applySort() async {
    final stats = <String, ({int size, DateTime modified})>{};
    bool needsDate(MediaSortOrder order) =>
        order == MediaSortOrder.newest ||
        order == MediaSortOrder.newestGrouped ||
        order == MediaSortOrder.dateWise ||
        order == MediaSortOrder.oldest ||
        order == MediaSortOrder.oldestGrouped;
    bool needsSize(MediaSortOrder order) =>
        order == MediaSortOrder.sizeLargest ||
        order == MediaSortOrder.sizeSmallest;

    Future<void> preloadCategory(
      String category,
      List<FileSystemEntity> list,
    ) async {
      final order = getSortOrderForCategory(category);
      stats.addAll(
        await _preloadStats(
          list,
          needDate: needsDate(order) || needsDate(_sortOrder),
          needSize: needsSize(order) || needsSize(_sortOrder),
        ),
      );
    }

    await preloadCategory('图片', _images);
    await preloadCategory('图片', _customImages);
    await preloadCategory('视频', _videos);
    await preloadCategory('视频', _customVideos);
    await preloadCategory('截图', _screenshots);
    await preloadCategory('截图', _customScreenshots);
    await preloadCategory('文档', _documents);
    await preloadCategory('压缩包', _archives);
    await preloadCategory('下载', _downloads);
    await preloadCategory('安装包', _apks);

    final audioOrder = getSortOrderForCategory('音频');
    if (needsDate(audioOrder) || needsDate(_sortOrder)) {
      final audioPaths = _audios
          .map((a) => a.data)
          .where((p) => p.isNotEmpty)
          .map(File.new)
          .toList();
      stats.addAll(
        await _preloadStats(audioPaths, needDate: true, needSize: false),
      );
    }

    // 装饰排序：每项只取一次排序键（int），比较器退化为 int.compareTo。
    // 旧比较器每次比较做两次字符串哈希 map 查找 + DateTime.compareTo，
    // 数万条 × 8 个列表全在主 isolate，是分类页加载/切排序的卡顿热点。
    // stat 缺失的条目键取 0（按最小/最旧参与排序；旧实现返回 0 视相等，
    // 位置同样不确定，仅 stat 失败的罕见条目受影响）。
    void sortByKey<T>(List<T> list, int Function(T) keyOf, bool ascending) {
      if (list.length < 2) return;
      final keyed = list.map((e) => (e: e, key: keyOf(e))).toList();
      keyed.sort(
        (a, b) => ascending ? a.key.compareTo(b.key) : b.key.compareTo(a.key),
      );
      for (var i = 0; i < list.length; i++) {
        list[i] = keyed[i].e;
      }
    }

    final isOldest =
        _sortOrder == MediaSortOrder.oldest ||
        _sortOrder == MediaSortOrder.oldestGrouped;
    final isSmallest = _sortOrder == MediaSortOrder.sizeSmallest;
    final isSizeSort = isSmallest || _sortOrder == MediaSortOrder.sizeLargest;

    int dateKeyOf(String path) =>
        stats[path]?.modified.millisecondsSinceEpoch ?? 0;
    int sizeKeyOf(String path) => stats[path]?.size ?? 0;

    if (_sortOrder == MediaSortOrder.newest ||
        _sortOrder == MediaSortOrder.newestGrouped ||
        _sortOrder == MediaSortOrder.dateWise ||
        _sortOrder == MediaSortOrder.oldest ||
        _sortOrder == MediaSortOrder.oldestGrouped) {
      sortByKey(_images, (e) => dateKeyOf(e.path), isOldest);
      sortByKey(_videos, (e) => dateKeyOf(e.path), isOldest);
      sortByKey(_screenshots, (e) => dateKeyOf(e.path), isOldest);
      sortByKey(_audios, (a) => dateKeyOf(a.data), isOldest);
    } else if (isSizeSort) {
      sortByKey(_images, (e) => sizeKeyOf(e.path), isSmallest);
      sortByKey(_videos, (e) => sizeKeyOf(e.path), isSmallest);
      sortByKey(_screenshots, (e) => sizeKeyOf(e.path), isSmallest);
      sortByKey(_audios, (a) => a.size, isSmallest);
    }

    int fileKey(FileSystemEntity e) =>
        isSizeSort ? sizeKeyOf(e.path) : dateKeyOf(e.path);
    final fileAscending = isSizeSort ? isSmallest : isOldest;

    sortByKey(_documents, fileKey, fileAscending);
    sortByKey(_archives, fileKey, fileAscending);
    sortByKey(_downloads, fileKey, fileAscending);
    sortByKey(_apks, fileKey, fileAscending);
  }

  Future<void> deleteMediaItems({
    required List<String> filePaths,
    List<String>? assetIds,
    bool? toTrash,
  }) async {
    // 登记本会话删除黑名单：MediaStore/系统索引有滞后，刷新（querySongs）会把
    // 刚删掉的音频重新带回，导致「删了又出现」。与 pruneDeletedMediaPaths 同源
    // 双保险——调用方漏调 prune 也不会复活。
    for (final p in filePaths) {
      if (p.isNotEmpty) _deletedMediaPaths.add(_normalizeMediaPath(p));
    }
    while (_deletedMediaPaths.length > _kDeletedMediaPathsCap) {
      _deletedMediaPaths.remove(_deletedMediaPaths.first);
    }
    for (final path in filePaths) {
      try {
        if (toTrash == true) {
          // 删除确认弹窗勾选「移入回收站」：移入应用回收站目录并登记索引
          // （普通媒体文件均在公共存储，无需 root 提权）。
          await RecycleBinService.moveToTrash(path);
        } else {
          final f = File(path);
          if (await f.exists()) {
            await f.delete();
          }
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
    PreferencesService.saveCategoryCount('音频', audios.length);
    _saveNonMediaCategoryCounts();
    PreferencesService.saveCategoryCount('截图', screenshots.length);
    _recalcCategorySizes();

    await _saveCache();
    notifyListeners();
  }

  // ===================== 删除后残留清理 =====================
  // 别的应用或在浏览页删除文件后，媒体列表（_images/_videos/_screenshots/_audios）
  // 仍持有已删除路径，分类页表现为「空白图标」。以下两法分别覆盖：
  //  - pruneDeletedMediaPaths：已知被删路径的即时移除（浏览页/本应用内删除）。
  //  - pruneDeletedMedia：基于存在性的全量裁剪（他应用删除、MediaStore 未即时更新）。

  /// 按已知删除路径从媒体列表即时移除（无需存在性检查）。
  /// [paths] 为被删除文件的文件系统路径；音频按 SongModel.data 匹配。
  /// 同时处理非媒体四类（文档/压缩包/下载/安装包），防止浏览页删除后分类页残留空白图标。
  void pruneDeletedMediaPaths(List<String> paths) {
    if (paths.isEmpty) return;
    final set = paths.where((p) => p.isNotEmpty).toSet();
    if (set.isEmpty) return;
    // 记录删除路径：MediaStore / 系统索引滞后时，后续刷新会把已删除条目重新带回
    // （音频尤其明显——querySongs 会短暂仍返回已删文件），故在这里登记黑名单，
    // 之后所有音频合并/恢复点都过滤它，保证「删掉就是删掉了」。
    for (final pth in set) {
      _deletedMediaPaths.add(_normalizeMediaPath(pth));
    }
    while (_deletedMediaPaths.length > _kDeletedMediaPathsCap) {
      _deletedMediaPaths.remove(_deletedMediaPaths.first);
    }
    final before =
        _images.length +
        _videos.length +
        _screenshots.length +
        _audios.length +
        _documents.length +
        _archives.length +
        _downloads.length +
        _apks.length;
    _images.removeWhere((e) => set.contains(e.path));
    _videos.removeWhere((e) => set.contains(e.path));
    _screenshots.removeWhere((e) => set.contains(e.path));
    _customImages.removeWhere((e) => set.contains(e.path));
    _customVideos.removeWhere((e) => set.contains(e.path));
    _customScreenshots.removeWhere((e) => set.contains(e.path));
    _audios.removeWhere((e) => set.contains(e.data));
    _audioFolders = _groupAudiosByParentDir(_audios);
    _documents.removeWhere((e) => set.contains(e.path));
    _archives.removeWhere((e) => set.contains(e.path));
    _downloads.removeWhere((e) => set.contains(e.path));
    _apks.removeWhere((e) => set.contains(e.path));
    final after =
        _images.length +
        _videos.length +
        _screenshots.length +
        _audios.length +
        _documents.length +
        _archives.length +
        _downloads.length +
        _apks.length;
    if (before != after) {
      _recalcCategorySizes();
      PreferencesService.saveCategoryCount('图片', images.length);
      PreferencesService.saveCategoryCount('视频', videos.length);
      PreferencesService.saveCategoryCount('音频', audios.length);
      PreferencesService.saveCategoryCount('截图', screenshots.length);
      _saveNonMediaCategoryCounts();
      notifyListeners();
    }
  }

  /// 移除底层文件已不存在的媒体条目（他应用删除后残留的空白图标）。
  /// 存在性检查在 isolate 内完成，避免主线程对海量媒体逐个 existsSync 阻塞 UI。
  /// 同时覆盖非媒体四类（文档/压缩包/下载/安装包）。
  Future<void> pruneDeletedMedia() async {
    try {
      // 图片/视频/截图/非媒体四类：路径均来自本应用可见的文件系统枚举，
      // existsSync 不可达即已删除，直接裁剪。
      final all = <String>{
        ..._images.map((e) => e.path),
        ..._videos.map((e) => e.path),
        ..._screenshots.map((e) => e.path),
        ..._documents.map((e) => e.path),
        ..._archives.map((e) => e.path),
        ..._downloads.map((e) => e.path),
        ..._apks.map((e) => e.path),
      };
      if (all.isNotEmpty) {
        // 一次 stat 同时判定「已不存在」「0 字节占位」「真实字节数」
        // （见 _pruneNonMediaInIsolate），避免对同一批路径做多轮 isolate 遍历。
        final paths = all.toList();
        final res = await compute(_pruneNonMediaInIsolate, paths);
        if (res.gone.isNotEmpty) pruneDeletedMediaPaths(res.gone);
        // 用真实字节数回写索引大小缓存：既让分类 getter 能按 0 字节过滤掉未
        // 下载完的占位文件，也顺带纠正「索引报 0 而文件实际有内容」的陈旧索引
        // （否则会把正常文件误滤）。-1（本次读不到）不回写，保留索引原值。
        if (res.sizes.length == paths.length) {
          for (var i = 0; i < paths.length; i++) {
            final len = res.sizes[i];
            if (len >= 0) _nonMediaSizes[paths[i]] = len;
          }
        }
        if (res.empty.isNotEmpty) {
          debugPrint(
            '[ZenFile] pruneDeletedMedia: 标记 0 字节占位文件 '
            '${res.empty.length} 条（不存在的 ${res.gone.length} 条已剔除）',
          );
        }
      }
      // 音频：MediaStore/querySongs 在部分设备会把已删除文件（多被他应用/电脑删除、
      // 媒体库未重扫）的陈旧条目一直带回来，表现为分类页「空音频」——打开所在目录
      // 没有文件、在列表删掉后刷新又复活。此前因担心作用域存储下 existsSync 误判
      // 而整类跳过裁剪；改为「父目录兜底」策略（父目录可访问而文件缺失才判死，
      // 见 _pruneAudiosInIsolate），误判风险与其它分类一致。
      final audioPaths = <String>{
        for (final s in _audios)
          if (s.data.isNotEmpty) s.data,
      };
      if (audioPaths.isNotEmpty) {
        final audioRes = await compute(
          _pruneAudiosInIsolate,
          audioPaths.toList(),
        );
        if (audioRes.gone.isNotEmpty) {
          debugPrint(
            '[ZenFile] pruneDeletedMedia: 裁剪不存在音频 '
            '${audioRes.gone.length} 条（MediaStore 陈旧条目）',
          );
          pruneDeletedMediaPaths(audioRes.gone);
        }
        // 0 字节空音频（列表显示 0 B、点开无内容、删了刷新又出现）：本次判定
        // 结果**整体替换**（而非累加）——文件被补全/换成有效音频后自动恢复显示，
        // 不会因为一次误判被永久过滤。
        _emptyAudioPaths
          ..clear()
          ..addAll(audioRes.empty);
        if (audioRes.empty.isNotEmpty) {
          debugPrint(
            '[ZenFile] pruneDeletedMedia: 标记 0 字节空音频 '
            '${audioRes.empty.length} 条',
          );
        }
      }
    } catch (e) {
      debugPrint('[ZenFile] pruneDeletedMedia error: $e');
    }
  }
}
