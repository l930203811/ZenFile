import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import '../core/utils.dart';
import 'remote/remote_client.dart';

/// Service for generating media thumbnails from local file paths.
/// Uses Android's [MediaMetadataRetriever] via platform channel.
class MediaThumbnailService {
  static const _channel = MethodChannel('com.sequl.zenfile/root_shizuku');

  /// Generate a thumbnail from a video file path.
  /// Returns JPEG-encoded bytes, or null if generation failed.
  static Future<Uint8List?> generateVideoThumbnail(String filePath) async {
    try {
      final result = await _runBoundedNativeThumb(() => _channel.invokeMethod(
        'generateMediaThumbnail',
        {
          'filePath': filePath,
          'isVideo': true,
        },
      ));
      if (result is Uint8List) return result;
      if (result is List<int>) return Uint8List.fromList(result);
      return null;
    } catch (e) {
      return null;
    }
  }

  /// Generate a thumbnail from an audio file path (embedded artwork).
  /// Returns JPEG-encoded bytes, or null if no artwork found.
  static Future<Uint8List?> generateAudioThumbnail(String filePath) async {
    try {
      final result = await _runBoundedNativeThumb(() => _channel.invokeMethod(
        'generateMediaThumbnail',
        {
          'filePath': filePath,
          'isVideo': false,
        },
      ));
      if (result is Uint8List) return result;
      if (result is List<int>) return Uint8List.fromList(result);
      return null;
    } catch (e) {
      return null;
    }
  }

  /// 原生缩略图解码的**并发上限**。
  ///
  /// 原生侧已经是固定 3 线程（`MainActivity.thumbnailExecutor`），但 Dart 侧若
  /// 一次性发起几十个请求，每个都会占住一个 MethodChannel 的 pending 回调，
  /// Dart 侧还会排几十个 Future。滚动一个大目录时这很常见。
  ///
  /// 放在本类而不是 [MediaProvider] 那边，是因为**所有**走原生解码的路径都经过
  /// 这里（分类页视频瓦片、文件列表回退、远程视频缩略图），一处收口最不容易漏。
  static const int _kMaxNativeThumbConcurrency = 4;
  static int _nativeThumbRunning = 0;
  static final List<Completer<void>> _nativeThumbWaiters = <Completer<void>>[];

  /// 把原生缩略图解码的并发压在 [_kMaxNativeThumbConcurrency] 以内。
  static Future<T> _runBoundedNativeThumb<T>(Future<T> Function() task) async {
    while (_nativeThumbRunning >= _kMaxNativeThumbConcurrency) {
      final c = Completer<void>();
      _nativeThumbWaiters.add(c);
      await c.future;
    }
    _nativeThumbRunning++;
    try {
      return await task();
    } finally {
      _nativeThumbRunning--;
      if (_nativeThumbWaiters.isNotEmpty) {
        _nativeThumbWaiters.removeAt(0).complete();
      }
    }
  }

  /// Generate a thumbnail from a media file path, auto-detecting type.
  static Future<Uint8List?> generateThumbnail(String filePath) async {
    // effectiveExtensionWithDot：忽略 IM 追加后缀（`clip.mp4.1` → `.mp4`），
    // 否则 QQ 传来的视频/音频拿不到缩略图。
    final ext = FileUtils.effectiveExtensionWithDot(filePath);
    final videoExts = ['.mp4', '.mkv', '.avi', '.mov', '.wmv', '.flv', '.webm', '.m4v', '.3gp', '.ts', '.mpeg', '.mpg'];
    final audioExts = ['.mp3', '.aac', '.wav', '.flac', '.m4a', '.ogg', '.opus', '.wma', '.amr', '.aiff'];

    if (videoExts.contains(ext)) {
      return generateVideoThumbnail(filePath);
    } else if (audioExts.contains(ext)) {
      return generateAudioThumbnail(filePath);
    }
    return null;
  }

  // ---- 远程缩略图队列（FIFO + 小并发）+ 全局带宽限制 ----

  /// 超过此大小的远程图片不自动下载缩略图（列表显示占位图标，点击预览时
  /// 才完整下载）。避免超大原图（如 10-30MB 照片）占住下载队列，把整屏
  /// 缩略图全部拖到超时/卡住——这是「开了缩略图却显示不出来」的主要根因。
  static const int kRemoteThumbMaxBytes = 8 * 1024 * 1024; // 8MB

  /// 远程视频缩略图的头部探测字节数。
  ///
  /// faststart 编码的 MP4/MOV 把 moov 元数据放在文件开头，首帧关键帧通常也
  /// 在前几 MB 内；此前固定只取 2MB，导致「moov 稍大 / 首帧靠后」的视频
  /// 拿不到首帧（用户反馈：大部分远程视频不显示缩略图）。提高到 8MB 可覆盖
  /// 绝大多数 faststart 视频，同时仍远小于整文件，带宽代价可控。
  static const int kVideoHeaderBytes = 8 * 1024 * 1024; // 8MB

  /// 远程视频完整下载兜底的大小上限。
  ///
  /// 头部拿不到首帧（moov 在文件尾部的非 faststart 视频）时，仅对不超过此
  /// 大小的文件做完整下载重试；更大的文件放弃，避免为一张缩略图下载整部
  /// 电影、长时间占用下载队列与带宽。
  static const int kVideoFullDownloadMaxBytes = 300 * 1024 * 1024; // 300MB

  /// 远程缩略图任务队列（FIFO）。任务按加入顺序出队，但最多同时执行
  /// [_remoteMaxConcurrent] 个（而不是严格串行）：小缩略图不会被前面一个大
  /// 文件堵死；总带宽仍受全局令牌桶限制（约 5MB/s），不会打满网络。
  static final _remoteTaskQueue = <Future<void> Function()>[];
  static int _remoteActiveCount = 0;
  static const int _remoteMaxConcurrent = 3;

  /// 是否有媒体正在播放。为 true 时暂停新的远程缩略图任务（并跳过视频的
  /// 完整下载兜底），把带宽让给播放流——「边播边下缩略图」是远程视频卡顿的
  /// 主要诱因之一。用引用计数避免多播放器叠加时被提前复位。
  static bool _playbackActive = false;
  static int _playbackRefCount = 0;

  /// 播放开始前调用：暂停远程缩略图队列，释放带宽给播放流。
  static void beginPlayback() {
    _playbackRefCount++;
    _playbackActive = true;
  }

  /// 播放结束后调用：引用计数归零时恢复远程缩略图队列。
  static void endPlayback() {
    if (_playbackRefCount > 0) _playbackRefCount--;
    if (_playbackRefCount == 0) {
      _playbackActive = false;
      _drainRemoteQueue();
    }
  }

  /// 将远程缩略图任务加入全局 FIFO 队列并限并发执行。
  ///
  /// [bytes]：本任务预计下载的字节数（用于带宽限速，约 5MB/s）。传入 >0 时，
  /// 任务开始前先从全局带宽令牌桶取令牌，令牌不足则等待，从而把「同时下载」
  /// 变成「小并发 + 全局限速」。
  static Future<T> withRemoteThrottle<T>(
    Future<T> Function() task, {
    int bytes = 0,
  }) {
    final completer = Completer<T>();
    _remoteTaskQueue.add(() async {
      try {
        if (bytes > 0) await _acquireBandwidth(bytes);
        final result = await task();
        completer.complete(result);
      } catch (e, st) {
        completer.completeError(e, st);
      }
    });
    _drainRemoteQueue();
    return completer.future;
  }

  static void _drainRemoteQueue() {
    while (!_playbackActive &&
        _remoteActiveCount < _remoteMaxConcurrent &&
        _remoteTaskQueue.isNotEmpty) {
      final next = _remoteTaskQueue.removeAt(0);
      _remoteActiveCount++;
      unawaited(() async {
        try {
          await next();
        } catch (_) {
          // 错误已通过 completer 转发给调用方，这里只是防止 worker 中断
        }
        _remoteActiveCount--;
        _drainRemoteQueue();
      }());
    }
  }

  // ---- 全局带宽令牌桶（约 5MB/s）----
  static const double _bandwidthBytesPerSec = 5 * 1024 * 1024; // 5MB/s
  static double _bandwidthTokens = 0;
  static DateTime _bandwidthLastRefill = DateTime.now();
  static const double _bandwidthMaxTokens = 5 * 1024 * 1024; // 桶容量 = 1 秒量

  /// 获取 [bytes] 字节的带宽令牌；令牌按 5MB/s 速率补充，不足则等待。
  ///
  /// 注意：令牌桶容量（[_bandwidthMaxTokens]）只有 1 秒量（约 5MB），而单次
  /// 请求可能远超该值（图片上限 8MB、视频头部 8MB）。旧实现要求一次性凑齐
  /// [bytes] 个令牌，但令牌桶封顶 5MB 永远凑不齐，导致 >5MB 的缩略图任务
  /// 死循环、永久占用并发槽，把整个缩略图队列拖死（用户反馈：照片缩略图
  /// 不全、大部分视频无缩略图）。这里改为「按桶容量分批取」，令牌随补随取，
  /// 总速率仍被约束在 5MB/s。
  static Future<void> _acquireBandwidth(int bytes) async {
    double remaining = bytes.toDouble();
    while (remaining > 0) {
      final now = DateTime.now();
      final elapsedMs = now.difference(_bandwidthLastRefill).inMilliseconds;
      _bandwidthLastRefill = now;
      _bandwidthTokens = math.min(
        _bandwidthMaxTokens,
        _bandwidthTokens + elapsedMs / 1000 * _bandwidthBytesPerSec,
      );
      if (_bandwidthTokens <= 0) {
        await Future.delayed(const Duration(milliseconds: 100));
        continue;
      }
      final take = math.min(_bandwidthTokens, remaining);
      _bandwidthTokens -= take;
      remaining -= take;
    }
  }

  /// 远程缩略图统一下载入口：FIFO 小并发 + 按文件大小限速（约 5MB/s）。
  ///
  /// [useRange] 为 true 时只取头部 [rangeBytes]（视频/音频缩略图只需文件头），
  /// range 失败回退完整下载；false 时（图片）完整下载。下载过程受全局
  /// 队列（最多 3 并发）与带宽令牌桶双重约束，避免目录浏览时多文件同时
  /// 下载占满带宽导致卡顿。
  static Future<void> downloadThumbnailFile({
    required RemoteClient client,
    required String remotePath,
    required String localPath,
    required int fileSize,
    bool useRange = false,
    int rangeBytes = 2 * 1024 * 1024,
  }) async {
    await withRemoteThrottle(() async {
      if (useRange) {
        try {
          await client.downloadRange(remotePath, localPath, 0, rangeBytes);
        } catch (e) {
          // 部分服务器/客户端不支持 range 下载，回退到完整下载
          debugPrint('downloadRange 失败，回退完整下载: $e');
          await client.downloadFile(remotePath, localPath, (_) {});
        }
      } else {
        await client.downloadFile(remotePath, localPath, (_) {});
      }
    }, bytes: useRange ? math.min(fileSize, rangeBytes) : fileSize);
  }

  /// 生成远程视频缩略图（统一入口，供列表 / 网格 / 紧凑三种视图复用，避免
  /// 三处各自维护一份逻辑导致行为漂移）。
  ///
  /// 策略：
  /// 1. 先下载文件头部 [kVideoHeaderBytes]（约 8MB，覆盖 faststart 视频的
  ///    moov 与首帧关键帧），用原生 MediaMetadataRetriever 提取首帧；
  /// 2. 头部拿不到首帧（通常是 moov 在文件尾部的非 faststart 视频）且文件
  ///    不超过 [kVideoFullDownloadMaxBytes] 时，完整下载重试一次；
  /// 3. 播放器正在播放（[beginPlayback] 已调用）或文件过大时放弃完整下载，
  ///    避免与播放流抢带宽、也避免为一张缩略图下载整部电影。
  ///
  /// 返回 JPEG 缩略图字节；失败返回 null（由调用方回退到占位图标）。
  static Future<Uint8List?> generateRemoteVideoThumbnail({
    required RemoteClient client,
    required String remotePath,
    required int fileSize,
    required String ext,
  }) async {
    final tempDir = await getTempDir();
    final headerPath = p.join(tempDir.path, uniqueTempName(ext));
    try {
      // 头部探测（受全局队列 + 带宽令牌桶约束）
      await downloadThumbnailFile(
        client: client,
        remotePath: remotePath,
        localPath: headerPath,
        fileSize: fileSize,
        useRange: true,
        rangeBytes: kVideoHeaderBytes,
      );
      var bytes = await generateVideoThumbnail(headerPath);
      if (bytes != null && bytes.length > 20) {
        return bytes;
      }

      // 头部拿不到首帧：通常是 moov 在尾部的非 faststart 视频。
      if (_playbackActive || fileSize > kVideoFullDownloadMaxBytes) {
        return null;
      }
      try {
        // 完整下载兜底（只受并发上限约束；带宽由调用方通过队列间接控制）。
        await withRemoteThrottle(() async {
          await client.downloadFile(remotePath, headerPath, (_) {});
        });
        bytes = await generateVideoThumbnail(headerPath);
        if (bytes != null && bytes.length > 20) {
          return bytes;
        }
      } catch (_) {}
      return null;
    } finally {
      try {
        final f = File(headerPath);
        if (f.existsSync()) await f.delete();
      } catch (_) {}
    }
  }

  /// 将已下载的远程图片压缩为最长边 [maxDim] 的 JPEG 缩略图并写入 [thumbPath]。
  ///
  /// 返回缩略图字节（供 UI 直接显示）。解码失败（HEIC/损坏/超大图）或原图
  /// 过小时回退为原图直存，保证功能不降级。相比「原图直接当缩略图缓存」，
  /// 缓存体积可减小 90%+，二次打开目录时读取与解码都更快。
  static Future<Uint8List> makeImageThumbBytes(
    String srcPath,
    String thumbPath, {
    int maxDim = 512,
  }) async {
    final srcFile = File(srcPath);
    try {
      final srcBytes = await srcFile.readAsBytes();
      // 超大原图（>30MB）不做内存解码，避免 OOM，直接原样缓存
      if (srcBytes.length > 30 * 1024 * 1024) {
        await srcFile.copy(thumbPath);
        return srcBytes;
      }
      // 解码/缩放/编码放入独立 isolate：`image` 包是纯 Dart 实现，一张
      // 10~30MB 的 JPEG 在主 isolate 解码会卡 UI 数秒甚至 ANR。
      final outBytes = await Isolate.run(() => _encodeThumbnail(srcBytes, maxDim));
      if (outBytes != null) {
        await File(thumbPath).writeAsBytes(outBytes, flush: true);
        return outBytes;
      }
    } catch (e) {
      debugPrint('图片缩略图解码失败，回退原图直存: $e');
    }
    // 回退：原图直接作为缩略图缓存
    await srcFile.copy(thumbPath);
    return await srcFile.readAsBytes();
  }

  /// 纯函数：解码并缩放图片（供 isolate 执行）。解码失败返回 null，
  /// 由调用方回退原图直存。
  static Uint8List? _encodeThumbnail(Uint8List srcBytes, int maxDim) {
    final decoded = img.decodeImage(srcBytes);
    if (decoded == null) return null;
    final resized = img.copyResize(decoded, width: maxDim);
    return Uint8List.fromList(img.encodeJpg(resized, quality: 85));
  }

  /// 远程缩略图缓存基目录。
  /// 以 `.nomedia` 开头（且内含 `.nomedia` 标记文件），双重保险：
  /// 避免被 MediaStore 媒体库及其他文件管理器索引到缓存的远程缩略图。
  static const String _remoteThumbBasePath = '/storage/emulated/0/ZenFile/.nomedia';

  /// Get the thumbnail cache directory.
  ///
  /// 目录已迁移至 [_remoteThumbBasePath]/thumbnails/remote，并在基目录写入
  /// `.nomedia` 标记文件，确保其他应用不会扫描或索引这些缩略图。
  static Future<Directory> getThumbDir() async {
    try {
      final dir = Directory('$_remoteThumbBasePath/thumbnails/remote');
      if (!dir.existsSync()) dir.createSync(recursive: true);
      _ensureNoMediaMarker();
      return dir;
    } catch (_) {
      final appDir = await getApplicationDocumentsDirectory();
      final base = p.join(appDir.path, 'ZenFile', '.nomedia');
      final dir = Directory(p.join(base, 'thumbnails', 'remote'));
      if (!dir.existsSync()) dir.createSync(recursive: true);
      _ensureNoMediaMarker(base: base);
      return dir;
    }
  }

  /// 在基目录写入 `.nomedia` 标记文件（空文件即可）。
  ///
  /// 这是 Android 官方阻止 MediaStore 扫描的标准做法：标记文件所在目录及其
  /// 所有子目录都不会被媒体库索引。Android 也会跳过以点（.）开头的目录，
  /// 这里 `.nomedia` 目录名 + 标记文件双重保险。
  static void _ensureNoMediaMarker({String? base}) {
    try {
      final marker = File(p.join(base ?? _remoteThumbBasePath, '.nomedia'));
      if (!marker.existsSync()) marker.createSync();
    } catch (_) {}
  }

  /// Get the temp download directory.
  static Future<Directory> getTempDir() async {
    try {
      final dir = Directory('/storage/emulated/0/ZenFile/cache/temp');
      if (!dir.existsSync()) dir.createSync(recursive: true);
      return dir;
    } catch (_) {
      final appDir = await getApplicationDocumentsDirectory();
      final dir = Directory(p.join(appDir.path, 'ZenFile', 'cache', 'temp'));
      if (!dir.existsSync()) dir.createSync(recursive: true);
      return dir;
    }
  }

  /// Get the cache path for a remote file's thumbnail.
  static String getThumbPath(String remotePath, Directory thumbDir) {
    final thumbName = '${remotePath.replaceAll('/', '_').replaceAll('\\', '_')}_thumb.jpg';
    return p.join(thumbDir.path, thumbName);
  }

  /// 远程缩略图磁盘缓存文件名（全局唯一，不碰撞）。
  ///
  /// 命名规则：`{connectionId_}{safePathKey}_{modified.millisecondsSinceEpoch}_{size}_thumb.jpg`
  /// - [connectionId]：远程连接标识。不同远程连接即使服务端路径/修改时间/大小完全相同，
  ///   也能通过连接 id 区分，避免「同名文件串图」（例如两个 WebDAV 服务器都有 movie.mp4）。
  ///   [connectionId] 为 null 或空时回退为仅 path 前缀，保持向后兼容（旧缓存仍可命中）。
  /// - path 不再做 `/`→`_` 扁平化（`a/b.mp4` 与 `a_b.mp4` 会映射同一键而串图），
  ///   改用 base64url 编码（双射、无碰撞），超长时截断并以 hashCode 兜底区分。
  /// - [modified] + [size]：同名文件被删除重建后内容已变，靠这两项区分，避免复用旧缩略图。
  static String remoteThumbName(String? connectionId, String path, DateTime modified, int size) {
    final conn = (connectionId == null || connectionId.isEmpty) ? '' : '${connectionId}_';
    return '${conn}${_safePathKey(path)}_${modified.millisecondsSinceEpoch}_${size}_thumb.jpg';
  }

  /// 将远程路径编码为「安全且不碰撞」的文件名片段。
  static String _safePathKey(String path) {
    final encoded = base64Url.encode(utf8.encode(path));
    // 超长路径截断（文件名长度限制），截断后用 hashCode 兜底区分可能碰撞的尾部。
    if (encoded.length <= 80) return encoded;
    return '${encoded.substring(0, 80)}_${path.hashCode.toRadixString(36)}';
  }

  static int _tempSeq = 0;

  /// 生成唯一的远程临时文件名（时间戳 + 全局递增序号）。
  ///
  /// 避免并发缩略图任务在同一毫秒生成相同文件名、互相覆盖导致串图
  /// （旧实现 `remote_temp_${DateTime.now().millisecondsSinceEpoch}$ext`
  /// 在限流并发下存在碰撞风险）。
  static String uniqueTempName(String ext) {
    final seq = _tempSeq++;
    return 'remote_temp_${DateTime.now().millisecondsSinceEpoch}_$seq$ext';
  }
}
