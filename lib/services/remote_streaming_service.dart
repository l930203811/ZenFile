import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:mime/mime.dart';
import 'package:path/path.dart' as p;
import 'remote/remote_client.dart';

/// Progressive streaming proxy for remote media files (FTP/SFTP/SMB).
///
/// Design:
/// * HTTP response headers are sent **immediately** via `response.flush()`
///   after being set. This is critical — Dart's HttpResponse buffers headers
///   until the first `add()` call, which causes media_kit to time out
///   waiting for the HTTP response when the download is slow to start.
/// * Data is pushed to the response as it arrives from the downloader.
/// * Download progress is tracked via periodic file-length polling (100ms).
///   The progress callback is also used as a wake-up signal to immediately
///   re-check file length, giving faster updates than the timer alone.
/// * For known file size: responds 206 + Content-Range + Content-Length.
///   media_kit can seek by issuing a new request with a different Range.
/// * For unknown file size: responds 200 + chunked, no seek support.
class RemoteStreamingService {
  static final instance = RemoteStreamingService._();
  RemoteStreamingService._();

  final Map<int, _StreamSession> _sessions = {};

  Future<String> startStreaming(
    RemoteClient client,
    String remotePath,
    String fileName, {
    int? fileSize,
  }) async {
    _cleanupStale();

    // 重复保护：如果同一文件已有活跃会话，复用它而非创建新下载
    // 这避免了用户重新点击播放时启动重复下载
    for (final entry in _sessions.entries) {
      final session = entry.value;
      if (session.remotePath == remotePath && !session.disposed) {
        debugPrint('RemoteStreamingService: reusing existing session for $remotePath (port ${entry.key})');
        final ext = p.extension(fileName);
        return 'http://127.0.0.1:${entry.key}/stream$ext';
      }
    }

    debugPrint('RemoteStreamingService: startStreaming remotePath=$remotePath fileName=$fileName knownSize=$fileSize');
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final session = _StreamSession(
      client: client,
      remotePath: remotePath,
      fileName: fileName,
      server: server,
      knownFileSize: fileSize,
    );
    _sessions[server.port] = session;

    session.startDownload();

    server.listen((request) => _handleRequest(session, request), onError: (e) {
      debugPrint('RemoteStreamingService: Server error: $e');
    });

    final ext = p.extension(fileName);
    return 'http://127.0.0.1:${server.port}/stream$ext';
  }

  Future<void> stopStreaming(String url) async {
    try {
      final uri = Uri.parse(url);
      final session = _sessions.remove(uri.port);
      if (session != null) await session.dispose();
    } catch (e) {
      debugPrint('RemoteStreamingService: stopStreaming error: $e');
    }
  }

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
      _sessions.remove(port)?.dispose();
    }
  }

  Future<void> _handleRequest(_StreamSession session, HttpRequest request) async {
    final response = request.response;
    try {
      final mimeType = lookupMimeType(session.fileName) ?? 'application/octet-stream';
      final rangeHeader = request.headers.value(HttpHeaders.rangeHeader);
      debugPrint('RemoteStreamingService: request ${request.method} ${request.uri.path} range=$rangeHeader');

      // 立即决定 fileSize，不等待 getFileSize（可耗 10-15s）。
      // 优先用 knownFileSize（来自文件列表元数据），否则用 -1 走 chunked 200。
      // 这样 HTTP 响应头立即发送，media_kit 不会因等待而超时。
      int fileSize = session.knownFileSize ?? -1;
      // 如果 knownFileSize 未知，尝试 1s 内获取（不阻塞太久）
      if (fileSize <= 0) {
        try {
          fileSize = await session.waitForSize().timeout(const Duration(seconds: 1));
          debugPrint('RemoteStreamingService: got fileSize=$fileSize within 1s');
        } catch (_) {
          fileSize = -1;
          debugPrint('RemoteStreamingService: fileSize not ready in 1s, using chunked 200');
        }
      } else {
        debugPrint('RemoteStreamingService: using knownFileSize=$fileSize');
      }

      if (fileSize > 0) {
        debugPrint('RemoteStreamingService: serving 206 (seekable) fileSize=$fileSize');
        await _serveProgressive(session, response, fileSize, mimeType, rangeHeader);
      } else {
        debugPrint('RemoteStreamingService: serving chunked 200 (unknown size)');
        await _serveProgressiveUnknown(session, response, mimeType);
      }
    } catch (e) {
      debugPrint('RemoteStreamingService: request error: $e');
      try {
        response.statusCode = HttpStatus.internalServerError;
      } catch (_) {}
      try {
        await response.close();
      } catch (_) {}
    }
  }

  /// Serve with known file size: respond 206 immediately, stream bytes
  /// progressively from [start]. Does NOT wait for the whole range — bytes
  /// are pushed as they arrive from the downloader.
  Future<void> _serveProgressive(
    _StreamSession session,
    HttpResponse response,
    int fileSize,
    String mimeType,
    String? rangeHeader,
  ) async {
    int start = 0;
    int end = fileSize - 1;

    if (rangeHeader != null) {
      final m = RegExp(r'bytes=(\d+)-(\d*)').firstMatch(rangeHeader);
      if (m != null) {
        start = int.parse(m.group(1)!);
        if (m.group(2) != null && m.group(2)!.isNotEmpty) {
          end = int.parse(m.group(2)!);
        }
      }
    }

    if (start >= fileSize) {
      response.statusCode = 416;
      response.headers.set(HttpHeaders.contentRangeHeader, 'bytes */$fileSize');
      await response.close();
      return;
    }

    final clampedEnd = end.clamp(0, fileSize - 1);
    final contentLength = clampedEnd - start + 1;

    // Set response headers
    response.statusCode = 206;
    response.headers.set(HttpHeaders.contentRangeHeader, 'bytes $start-$clampedEnd/$fileSize');
    response.headers.set(HttpHeaders.contentLengthHeader, contentLength.toString());
    response.headers.set(HttpHeaders.contentTypeHeader, mimeType);
    response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');

    // CRITICAL: Flush headers immediately so media_kit receives the HTTP
    // response without waiting for download data to arrive. Without this,
    // Dart buffers the headers until the first response.add() call, which
    // may take a long time if the download is slow to start (e.g., FTP
    // negotiating data connection). media_kit would time out waiting.
    try {
      await response.flush();
    } catch (e) {
      debugPrint('RemoteStreamingService: flush headers failed: $e');
    }

    // Stream bytes as they arrive
    await _streamFrom(session, response, start, clampedEnd + 1);
  }

  /// Serve with unknown file size: chunked transfer, no seek.
  Future<void> _serveProgressiveUnknown(
    _StreamSession session,
    HttpResponse response,
    String mimeType,
  ) async {
    response.statusCode = HttpStatus.ok;
    response.headers.set(HttpHeaders.contentTypeHeader, mimeType);
    response.headers.set(HttpHeaders.acceptRangesHeader, 'none');
    response.headers.set(HttpHeaders.transferEncodingHeader, 'chunked');

    // CRITICAL: Flush headers immediately (see _serveProgressive for details)
    try {
      await response.flush();
    } catch (e) {
      debugPrint('RemoteStreamingService: flush headers (unknown) failed: $e');
    }

    await _streamFrom(session, response, 0, -1);
  }

  /// Stream bytes [start, endExclusive) to the response as they arrive.
  /// When [endExclusive] is -1, stream until download completes.
  ///
  /// Key behaviors:
  /// - Waits for the partial file to be created (up to 60s) before opening.
  /// - Opens the file ONCE and keeps the handle cached.
  /// - Reads only up to [session.downloadedBytes] (actual file length on disk).
  /// - Flushes the HTTP response after every write for immediate delivery.
  Future<void> _streamFrom(
    _StreamSession session,
    HttpResponse response,
    int start,
    int endExclusive,
  ) async {
    const chunkSize = 256 * 1024; // 256KB read chunks
    final target = endExclusive < 0 ? 0x7FFFFFFFFFFFFFFF : endExclusive;

    // Wait for the partial file to exist and have at least 1 byte.
    // The download might still be in getFileSize() phase, so the file
    // may not be created yet. Wait up to 60s for it to appear.
    File readFile = File(session.partialPath);
    bool fileReady = false;
    for (int i = 0; i < 300; i++) { // 300 * 200ms = 60s max
      if (session.disposed || session.downloadFailed) break;
      if (await readFile.exists()) {
        final len = readFile.lengthSync();
        if (len > 0) {
          fileReady = true;
          break;
        }
        // File exists but empty — download just started, data not yet
        // flushed to disk by IOSink. Wait a bit more.
      }
      // Also check the final path (download may have completed already)
      final finalFile = File(session.localPath);
      if (await finalFile.exists() && finalFile.lengthSync() > 0) {
        readFile = finalFile;
        fileReady = true;
        break;
      }
      await Future.delayed(const Duration(milliseconds: 200));
    }

    if (!fileReady) {
      if (session.downloadFailed) {
        debugPrint('RemoteStreamingService: download failed, cannot stream');
      } else {
        debugPrint('RemoteStreamingService: partial file never appeared');
      }
      try {
        await response.close();
      } catch (_) {}
      return;
    }

    // Open the file and keep the handle for the entire stream.
    // Declared `late` because the open happens in a try block; if it fails we
    // return early, so all subsequent accesses are guaranteed to be assigned.
    late RandomAccessFile raf;
    try {
      raf = await readFile.open(mode: FileMode.read);
      await raf.setPosition(start);
    } catch (e) {
      debugPrint('RemoteStreamingService: failed to open partial file: $e');
      try {
        await response.close();
      } catch (_) {}
      return;
    }

    int readOffset = start;
    bool hasRetried = false;
    int idleCount = 0;

    try {
      while (readOffset < target) {
        if (session.disposed || session.downloadFailed) break;

        // downloadedBytes reflects actual file length on disk.
        final downloaded = session.downloadedBytes;
        if (downloaded <= readOffset) {
          if (session.downloadComplete) {
            // Download done but file might have been renamed to final path
            if (readOffset == start) {
              // We never sent any data — try reading from final path
              final finalFile = File(session.localPath);
              if (await finalFile.exists()) {
                try {
                  await raf.close();
                } catch (_) {}
                raf = await finalFile.open(mode: FileMode.read);
                await raf.setPosition(readOffset);
                final len = await finalFile.length();
                if (len > readOffset) {
                  // File has data — continue reading
                  idleCount = 0;
                  continue;
                }
              }
            }
            break;
          }
          // Wait for new data with a short timeout
          await session.waitForMoreBytes(readOffset + 1).timeout(
            const Duration(seconds: 5),
            onTimeout: () {},
          );
          idleCount++;
          // If idle for too long (60s = 12 * 5s), give up
          if (idleCount > 12) {
            debugPrint('RemoteStreamingService: idle timeout at $readOffset');
            break;
          }
          continue;
        }

        idleCount = 0; // Reset idle counter on new data

        final available = downloaded.clamp(0, target);
        final toRead = (available - readOffset).clamp(0, chunkSize).toInt();
        if (toRead <= 0) {
          if (session.downloadComplete) break;
          continue;
        }

        try {
          await raf.setPosition(readOffset);
          final data = await raf.read(toRead);
          if (data.isEmpty) {
            if (session.downloadComplete) break;
            await Future.delayed(const Duration(milliseconds: 10));
            continue;
          }
          response.add(data);
          // Flush immediately so media_kit receives data without delay.
          await response.flush();
          readOffset += data.length;
          hasRetried = false;
        } catch (e) {
          debugPrint('RemoteStreamingService: read error at $readOffset: $e');
          if (hasRetried) break;
          hasRetried = true;
          try {
            await raf.close();
          } catch (_) {}
          try {
            // Try reopening from partial or final path
            File reopenFile = File(session.partialPath);
            if (!await reopenFile.exists()) {
              reopenFile = File(session.localPath);
            }
            if (await reopenFile.exists()) {
              raf = await reopenFile.open(mode: FileMode.read);
              await raf.setPosition(readOffset);
              continue;
            }
          } catch (_) {}
          break;
        }
      }
    } finally {
      try {
        await raf.close();
      } catch (_) {}
      try {
        await response.close();
      } catch (_) {}
    }
  }
}

class _StreamSession {
  final RemoteClient client;
  final String remotePath;
  final String fileName;
  final HttpServer server;
  final DateTime createdAt;
  final int? knownFileSize;

  String? _localPath;
  Future<void>? _downloadFuture;
  bool _disposed = false;
  Timer? _lengthPollTimer;

  int _totalBytes = -1;
  bool _downloadComplete = false;
  bool _downloadFailed = false;
  final Completer<int> _sizeCompleter = Completer<int>();

  // Tracks how many bytes are actually readable from the partial file.
  // Updated by the file-length poller (100ms) AND by the progress callback
  // (which triggers an immediate file-length sync). Only counts bytes that
  // have been flushed to disk by the client's IOSink.
  int _downloadedBytes = 0;
  Completer<void>? _progressSignal;

  _StreamSession({
    required this.client,
    required this.remotePath,
    required this.fileName,
    required this.server,
    this.knownFileSize,
  }) : createdAt = DateTime.now();

  String get localPath {
    _localPath ??= _getLocalTempPath();
    return _localPath!;
  }

  String get partialPath => '$localPath.partial';

  bool get downloadComplete => _downloadComplete;
  bool get downloadFailed => _downloadFailed;
  bool get disposed => _disposed;
  int get downloadedBytes => _downloadedBytes;

  bool get isStale => DateTime.now().difference(createdAt) > const Duration(hours: 2);

  void startDownload() {
    if (_downloadFuture != null) return;

    // Poll the actual file length on disk every 100ms. This is the source
    // of truth for _downloadedBytes — it only counts bytes that have been
    // flushed to the OS by the client's IOSink, so the streaming reader
    // never tries to read bytes that aren't yet on disk.
    _lengthPollTimer = Timer.periodic(const Duration(milliseconds: 100), (_) {
      _syncFileLength();
    });

    // Catch errors to prevent unhandled async exceptions from crashing the
    // app. Errors are already handled in _doDownload (sets _downloadFailed,
    // logs message, deletes partial file).
    _downloadFuture = _doDownload().catchError((e) {
      debugPrint('RemoteStreamingService: download async error: $e');
    });
  }

  void _syncFileLength() {
    try {
      final f = File(partialPath);
      if (f.existsSync()) {
        final actualLen = f.lengthSync();
        if (actualLen != _downloadedBytes) {
          _downloadedBytes = actualLen;
          _notifyProgress();
        }
      }
      // Also check the final path (in case download completed and renamed)
      final finalFile = File(localPath);
      if (finalFile.existsSync()) {
        final actualLen = finalFile.lengthSync();
        if (actualLen > _downloadedBytes) {
          _downloadedBytes = actualLen;
          _notifyProgress();
        }
      }
    } catch (_) {}
  }

  Future<int> waitForSize() => _sizeCompleter.future;

  /// Wait until at least [byteOffset] bytes have been flushed to disk.
  Future<void> waitForByte(int byteOffset) async {
    if (_downloadedBytes >= byteOffset) return;
    while (!_downloadComplete && !_downloadFailed && !_disposed) {
      if (_downloadedBytes >= byteOffset) return;
      await _waitForSignal();
    }
    if (_downloadFailed) throw Exception('Download failed');
  }

  /// Wait until more bytes beyond [currentOffset] are available on disk.
  Future<void> waitForMoreBytes(int currentOffset) async {
    if (_downloadedBytes > currentOffset) return;
    if (_downloadComplete || _downloadFailed || _disposed) return;
    await _waitForSignal();
  }

  Future<void> _waitForSignal() async {
    final signal = _progressSignal ??= Completer<void>();
    await signal.future.timeout(const Duration(seconds: 5), onTimeout: () {});
  }

  void _notifyProgress() {
    final s = _progressSignal;
    if (s != null && !s.isCompleted) {
      s.complete();
    }
    _progressSignal = Completer<void>();
  }

  Future<void> _doDownload() async {
    try {
      // Skip getFileSize entirely to avoid blocking the download.
      // getFileSize can take 10-15s (SFTP stat, FTP SIZE, SMB native call),
      // and client.downloadFile may ALSO query size internally.
      // Instead, rely on knownFileSize (from file list metadata) or -1.
      // The HTTP handler uses waitForSize().timeout(2s) — if size is unknown
      // by then, it falls back to chunked 200 (no seek, but plays immediately).
      // downloadFile's internal stat/getFileSize also has a 2s timeout, so
      // data starts flowing ASAP.
      if (knownFileSize != null && knownFileSize! > 0) {
        _totalBytes = knownFileSize!;
        debugPrint('RemoteStreamingService: using knownFileSize=$_totalBytes');
      } else {
        _totalBytes = -1;
        debugPrint('RemoteStreamingService: unknown size, will use chunked 200');
      }
      if (!_sizeCompleter.isCompleted) {
        _sizeCompleter.complete(_totalBytes);
      }

      // Ensure parent directory exists
      final partial = File(partialPath);
      if (!await partial.parent.exists()) {
        await partial.parent.create(recursive: true);
      }
      // If a stale partial file exists from a previous run, remove it
      if (await partial.exists()) {
        await partial.delete();
      }

      // Download to partial file. The client manages its own file handle
      // and writes directly to partialPath.
      // The progress callback is used as a wake-up signal to immediately
      // re-check file length (via _syncFileLength), giving faster updates
      // than the 100ms timer alone.
      await client.downloadFile(remotePath, partialPath, (progress) {
        // Immediately sync file length on progress update — this detects
        // new data faster than waiting for the 100ms timer.
        _syncFileLength();
        _notifyProgress();
      });

      // Stop polling — we'll do a final sync below
      _lengthPollTimer?.cancel();
      _lengthPollTimer = null;

      // Final sync: update _downloadedBytes and _totalBytes
      if (await partial.exists()) {
        _downloadedBytes = await partial.length();
        if (_totalBytes <= 0) {
          _totalBytes = _downloadedBytes;
        } else {
          _downloadedBytes = _totalBytes;
        }
      }
      _downloadComplete = true;
      debugPrint('RemoteStreamingService: download complete, totalBytes=$_totalBytes downloaded=$_downloadedBytes');
      _notifyProgress();
    } catch (e) {
      _lengthPollTimer?.cancel();
      _lengthPollTimer = null;
      _downloadFailed = true;
      debugPrint('RemoteStreamingService: download failed: $e');
      if (!_sizeCompleter.isCompleted) {
        _sizeCompleter.complete(-1);
      }
      _notifyProgress();
      // Do NOT rethrow — the error is already handled (flags set, partial
      // file deleted, logged). Rethrowing causes an unhandled async
      // exception since startDownload() does not await this future.
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
    _lengthPollTimer?.cancel();
    _lengthPollTimer = null;
    _notifyProgress();
    // 关闭 HTTP 服务器，停止向 media_kit 推送数据
    try {
      await server.close(force: true);
    } catch (_) {}
    // 尝试取消下载：调用 client.disconnect() 中断底层连接
    // 这是关键修复：之前 dispose 不取消下载，导致退出播放器后
    // SFTP/FTP/SMB 下载在后台继续运行，占用网络带宽和 CPU
    try {
      await client.disconnect();
    } catch (e) {
      debugPrint('RemoteStreamingService: dispose disconnect error: $e');
    }
    // 等待下载 Future 结束（disconnect 会中断网络读取，使其快速失败）
    if (_downloadFuture != null) {
      try {
        await _downloadFuture!.timeout(const Duration(seconds: 3));
      } catch (_) {}
    }
    // 删除本地缓存文件
    try {
      if (_localPath != null) {
        final f = File(_localPath!);
        if (await f.exists()) await f.delete();
        final p = File('$_localPath.partial');
        if (await p.exists()) await p.delete();
      }
    } catch (_) {}
  }
}
