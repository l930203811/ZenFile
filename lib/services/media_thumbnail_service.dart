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

  /// Get the thumbnail cache directory.
  static Future<Directory> getThumbDir() async {
    try {
      final dir = Directory('/storage/emulated/0/Download/ZenFile_Remote/cache/thumbnails/remote');
      if (!dir.existsSync()) dir.createSync(recursive: true);
      return dir;
    } catch (_) {
      final appDir = await getApplicationDocumentsDirectory();
      final dir = Directory(p.join(appDir.path, 'ZenFile_Remote', 'cache', 'thumbnails', 'remote'));
      if (!dir.existsSync()) dir.createSync(recursive: true);
      return dir;
    }
  }

  /// Get the temp download directory.
  static Future<Directory> getTempDir() async {
    try {
      final dir = Directory('/storage/emulated/0/Download/ZenFile_Remote/cache/temp');
      if (!dir.existsSync()) dir.createSync(recursive: true);
      return dir;
    } catch (_) {
      final appDir = await getApplicationDocumentsDirectory();
      final dir = Directory(p.join(appDir.path, 'ZenFile_Remote', 'cache', 'temp'));
      if (!dir.existsSync()) dir.createSync(recursive: true);
      return dir;
    }
  }

  /// Get the cache path for a remote file's thumbnail.
  static String getThumbPath(String remotePath, Directory thumbDir) {
    final thumbName = '${remotePath.replaceAll('/', '_').replaceAll('\\', '_')}_thumb.jpg';
    return p.join(thumbDir.path, thumbName);
  }
}
