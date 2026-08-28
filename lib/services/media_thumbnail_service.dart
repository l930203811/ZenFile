import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Service for generating media thumbnails from local file paths.
/// Uses Android's [MediaMetadataRetriever] via platform channel.
class MediaThumbnailService {
  static const _channel = MethodChannel('com.sequl.zenfile/root_shizuku');

  /// Generate a thumbnail from a video file path.
  /// Returns JPEG-encoded bytes, or null if generation failed.
  static Future<Uint8List?> generateVideoThumbnail(String filePath) async {
    try {
      final result = await _channel.invokeMethod('generateMediaThumbnail', {
        'filePath': filePath,
        'isVideo': true,
      });
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
      final result = await _channel.invokeMethod('generateMediaThumbnail', {
        'filePath': filePath,
        'isVideo': false,
      });
      if (result is Uint8List) return result;
      if (result is List<int>) return Uint8List.fromList(result);
      return null;
    } catch (e) {
      return null;
    }
  }

  /// Generate a thumbnail from a media file path, auto-detecting type.
  static Future<Uint8List?> generateThumbnail(String filePath) async {
    final ext = p.extension(filePath).toLowerCase();
    final videoExts = ['.mp4', '.mkv', '.avi', '.mov', '.wmv', '.flv', '.webm', '.m4v', '.3gp', '.ts', '.mpeg', '.mpg'];
    final audioExts = ['.mp3', '.aac', '.wav', '.flac', '.m4a', '.ogg', '.opus', '.wma', '.amr', '.aiff'];

    if (videoExts.contains(ext)) {
      return generateVideoThumbnail(filePath);
    } else if (audioExts.contains(ext)) {
      return generateAudioThumbnail(filePath);
    }
    return null;
  }

  // ---- 远程缩略图并发限流 ----
  static int _activeRemoteJobs = 0;
  static const int _maxRemoteJobs = 3;

  /// 远程缩略图任务的并发限流：同时最多 [_maxRemoteJobs] 个下载/生成任务，
  /// 避免一屏多个远程媒体同时下载造成带宽竞争、超时失败
  /// （这是“少部分远程缩略图不显示”的诱因之一）。
  static Future<T> withRemoteThrottle<T>(Future<T> Function() task) async {
    while (_activeRemoteJobs >= _maxRemoteJobs) {
      await Future.delayed(const Duration(milliseconds: 150));
    }
    _activeRemoteJobs++;
    try {
      return await task();
    } finally {
      _activeRemoteJobs--;
    }
  }

  /// Get the thumbnail cache directory.
  static Future<Directory> getThumbDir() async {
    try {
      final dir = Directory('/storage/emulated/0/ZenFile/cache/thumbnails/remote');
      if (!dir.existsSync()) dir.createSync(recursive: true);
      return dir;
    } catch (_) {
      final appDir = await getApplicationDocumentsDirectory();
      final dir = Directory(p.join(appDir.path, 'ZenFile', 'cache', 'thumbnails', 'remote'));
      if (!dir.existsSync()) dir.createSync(recursive: true);
      return dir;
    }
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
