import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:mime/mime.dart';
import 'package:path/path.dart' as p;
import 'remote/remote_client.dart';

/// A lightweight local HTTP proxy that enables true streaming playback
/// for remote media files (FTP, SFTP, etc.) by bridging the remote client's
/// download with an HTTP server that media_kit can consume.
///
/// Usage:
///   final url = await RemoteStreamingService.instance.startStreaming(client, remotePath, fileName);
///   // Pass [url] to media_kit Player.open(Media(url))
///   // When done, call stopStreaming(url) to release resources
class RemoteStreamingService {
  static final instance = RemoteStreamingService._();
  RemoteStreamingService._();

  final Map<int, _StreamSession> _sessions = {};

  /// Start streaming a remote file. Returns a local HTTP URL for media_kit.
  /// The download starts immediately in the background. When the HTTP handler
  /// receives a request, it waits for the download to complete and then serves
  /// the file with full Range request support for seeking.
  Future<String> startStreaming(RemoteClient client, String remotePath, String fileName) async {
    // Clean up stale sessions
    _cleanupStale();

    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final session = _StreamSession(
      client: client,
      remotePath: remotePath,
      fileName: fileName,
      server: server,
    );
    _sessions[server.port] = session;

    // Start download immediately in the background
    session.startDownload();

    server.listen((request) => _handleRequest(session, request), onError: (e) {
      debugPrint('RemoteStreamingService: Server error: $e');
    });

    // Include file extension in URL so MIME type detection works correctly
    final ext = p.extension(fileName);
    return 'http://127.0.0.1:${server.port}/stream$ext';
  }

  /// Stop streaming and release resources for the given URL.
  Future<void> stopStreaming(String url) async {
    try {
      final uri = Uri.parse(url);
      final port = uri.port;
      final session = _sessions.remove(port);
      if (session != null) {
        await session.dispose();
      }
    } catch (e) {
      debugPrint('RemoteStreamingService: Error stopping stream: $e');
    }
  }

  /// Check if a URL is a local streaming proxy URL.
  bool isStreamingUrl(String url) {
    try {
      final uri = Uri.parse(url);
      return uri.host == '127.0.0.1' && _sessions.containsKey(uri.port);
    } catch (_) {
      return false;
    }
  }

  void _cleanupStale() {
    final stalePorts = <int>[];
    _sessions.forEach((port, session) {
      if (session.isStale) stalePorts.add(port);
    });
    for (final port in stalePorts) {
      final session = _sessions.remove(port);
      session?.dispose();
    }
  }

  Future<void> _handleRequest(_StreamSession session, HttpRequest request) async {
    final response = request.response;

    try {
      // Wait for the background download to complete
      await session.waitForDownload();

      final file = File(session.localPath);
      if (!await file.exists()) {
        response.statusCode = HttpStatus.notFound;
        await response.close();
        return;
      }

      final fileSize = await file.length();
      final rangeHeader = request.headers.value(HttpHeaders.rangeHeader);
      final mimeType = lookupMimeType(session.fileName) ?? 'application/octet-stream';

      if (rangeHeader != null && fileSize > 0) {
        // Parse Range header: "bytes=start-end"
        final match = RegExp(r'bytes=(\d+)-(\d*)').firstMatch(rangeHeader);
        if (match != null) {
          final start = int.parse(match.group(1)!);
          final end = match.group(2) != null ? int.parse(match.group(2)!) : fileSize - 1;

          if (start >= fileSize) {
            response.statusCode = 416; // Range Not Satisfiable
            response.headers.set(HttpHeaders.contentRangeHeader, 'bytes */$fileSize');
            await response.close();
            return;
          }

          final clampedEnd = end.clamp(0, fileSize - 1);
          final contentLength = clampedEnd - start + 1;

          response.statusCode = 206; // Partial Content
          response.headers.set(HttpHeaders.contentRangeHeader, 'bytes $start-$clampedEnd/$fileSize');
          response.headers.set(HttpHeaders.contentLengthHeader, contentLength.toString());
          response.headers.set(HttpHeaders.contentTypeHeader, mimeType);
          response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');

          await file.openRead(start, clampedEnd + 1).pipe(response);
        } else {
          // Invalid range format, serve full file
          await _serveFullFile(response, file, fileSize, mimeType);
        }
      } else {
        // Full file request
        await _serveFullFile(response, file, fileSize, mimeType);
      }
    } catch (e) {
      debugPrint('RemoteStreamingService: Error handling request: $e');
      try {
        response.statusCode = HttpStatus.internalServerError;
      } catch (_) {}
      try {
        await response.close();
      } catch (_) {}
    }
  }

  Future<void> _serveFullFile(HttpResponse response, File file, int fileSize, String mimeType) async {
    response.statusCode = HttpStatus.ok;
    response.headers.set(HttpHeaders.contentLengthHeader, fileSize.toString());
    response.headers.set(HttpHeaders.contentTypeHeader, mimeType);
    response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');

    await file.openRead().pipe(response);
  }
}

class _StreamSession {
  final RemoteClient client;
  final String remotePath;
  final String fileName;
  final HttpServer server;
  final DateTime createdAt;

  String? _localPath;
  Future<void>? _downloadFuture;
  bool _disposed = false;

  _StreamSession({
    required this.client,
    required this.remotePath,
    required this.fileName,
    required this.server,
  }) : createdAt = DateTime.now();

  String get localPath {
    _localPath ??= _getLocalTempPath();
    return _localPath!;
  }

  bool get isStale => DateTime.now().difference(createdAt) > const Duration(hours: 2);

  /// Start the download immediately in the background.
  void startDownload() {
    if (_downloadFuture != null) return;
    _downloadFuture = _doDownload();
  }

  /// Wait for the download to complete.
  Future<void> waitForDownload() async {
    if (_downloadFuture != null) return _downloadFuture;
    // If download hasn't started yet, start it now
    startDownload();
    return _downloadFuture;
  }

  Future<void> _doDownload() async {
    final partialPath = '$localPath.partial';
    try {
      await client.downloadFile(remotePath, partialPath, (_) {});
      // Download complete, rename to final path
      final partial = File(partialPath);
      if (await partial.exists()) {
        await partial.rename(localPath);
      }
    } catch (e) {
      debugPrint('RemoteStreamingService: Download failed: $e');
      // Clean up partial file
      try {
        await File(partialPath).delete();
      } catch (_) {}
      rethrow;
    }
  }

  String _getLocalTempPath() {
    try {
      final dir = Directory('/storage/emulated/0/Download/ZenFile_Remote/cache/streaming');
      if (!dir.existsSync()) dir.createSync(recursive: true);
      final ext = p.extension(fileName);
      final safeName = fileName.replaceAll(RegExp(r'[^\w.\-]'), '_');
      return p.join(dir.path, '${DateTime.now().millisecondsSinceEpoch}_$safeName$ext');
    } catch (_) {
      final ext = p.extension(fileName);
      return p.join(Directory.systemTemp.path, 'zenfile_stream_${DateTime.now().millisecondsSinceEpoch}$ext');
    }
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    try {
      await server.close(force: true);
    } catch (_) {}
    // Clean up temp files
    try {
      if (_localPath != null) {
        final file = File(_localPath!);
        if (await file.exists()) await file.delete();
        final partial = File('$_localPath.partial');
        if (await partial.exists()) await partial.delete();
      }
    } catch (_) {}
  }
}
