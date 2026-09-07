import 'dart:async';
import 'dart:io';

import 'package:mime/mime.dart';

import 'remote/remote_client.dart';
import 'webdav_debug_log.dart';

/// 通用 **按需 Range** 反代服务（远程文件流式播放）。
///
/// ## 为什么需要它（而不是复用 RemoteStreamingService）
///
/// `RemoteStreamingService` 的实现是「把整个远程文件**顺序**下载到 .partial，
/// 播放器从这个不断增长的本地文件里读」。当播放器请求尚未下载到的偏移时
/// （典型场景：MP4 的 moov 索引在**文件尾部**，播放器开播前要先请求
/// `Range: bytes=<尾部>-`），代理只能干等顺序下载追上来 —— 对非 faststart
/// 的 MP4 就等于「必须等整个文件下载完才能开播」。实测日志：
///   01:17:41 代理启动(10.7MB) → 01:17:46 播放器请求尾部 → 01:19:10 才开播(89s)
/// 改成 Range 反代后同一视频 **2.1 秒**开播。
///
/// ## 工作方式
/// 播放器请求哪个字节区间，就通过 `RemoteClient.openRangeResponse` 向远端取
/// 哪个区间，并以 206 + Content-Range 原样回给播放器：
///   - **HTTP 系（WebDAV/OpenList）**：透传 Range 头与远端响应，零落盘；
///   - **FTP / SFTP / SMB**：走各自协议的偏移随机读（REST / JSch offset /
///     smbj skip），分片取回后流式返回，用完即删临时文件。
/// 单次取流有上限（默认 4MB），播放器开放式请求 `bytes=0-` 会被截断成一段，
/// 读完自然再请求下一段 —— 因此不会退化成整文件下载。
///
/// 不支持随机读的协议（`supportsRangeRead == false`）请继续用
/// RemoteStreamingService，两者互不干扰。
class HttpRangeProxyService {
  HttpRangeProxyService._();

  static final HttpRangeProxyService instance = HttpRangeProxyService._();

  final Map<int, _RangeSession> _sessions = {};

  /// 启动针对 [remotePath] 的反代，返回 `http://127.0.0.1:<port>/stream<ext>`。
  Future<String> start(
    RemoteClient client,
    String remotePath, {
    String? fileName,
    int? fileSize,
  }) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final name = fileName ?? remotePath.split('/').where((s) => s.isNotEmpty).last;
    final ext = _ext(name);
    _sessions[server.port] = _RangeSession(
      client: client,
      remotePath: remotePath,
      fileName: name,
      fileSize: fileSize,
      server: server,
      tempDir: _ensureTempDir(),
    );
    server.listen(
      (request) => _handle(server.port, request),
      onError: (e) => WebdavDebugLog.log('Range代理 server error: $e'),
    );
    final url = 'http://127.0.0.1:${server.port}/stream$ext';
    WebdavDebugLog.log('Range代理启动 url=$url remotePath=$remotePath '
        'fileName=$name fileSize=$fileSize client=${client.runtimeType}');
    return url;
  }

  /// 客户端支持随机读时才启动；否则返回 null 交由调用方走顺序下载代理。
  static Future<String?> startIfSupported(
    RemoteClient client,
    String remotePath, {
    String? fileName,
    int? fileSize,
  }) async {
    if (!client.supportsRangeRead) return null;
    try {
      return await instance.start(
        client,
        remotePath,
        fileName: fileName,
        fileSize: fileSize,
      );
    } catch (e) {
      WebdavDebugLog.log('Range代理启动失败,回退顺序下载代理: $e');
      return null;
    }
  }

  bool isOurs(String url) {
    try {
      return _sessions.containsKey(Uri.parse(url).port);
    } catch (_) {
      return false;
    }
  }

  Future<void> stop(String url) async {
    try {
      final port = Uri.parse(url).port;
      final session = _sessions.remove(port);
      if (session == null) return;
      WebdavDebugLog.log('Range代理停止 url=$url');
      session.closing = true;
      // 等正在进行的请求返回，避免播放器收到「Connection refused」误报。
      try {
        await session.drain().timeout(const Duration(seconds: 3));
      } catch (_) {}
      await session.server.close(force: true);
      session.clearTemp();
    } catch (_) {}
  }

  Future<void> _handle(int port, HttpRequest request) async {
    final response = request.response;
    final session = _sessions[port];
    if (session == null || session.closing) {
      response.statusCode = HttpStatus.serviceUnavailable;
      await response.close();
      return;
    }

    final range = request.headers.value(HttpHeaders.rangeHeader);
    WebdavDebugLog.log(
        'Range代理收到 ${request.method} ${request.uri.path} range=$range');
    RemoteRangeResponse? upstream;
    session.active++;
    try {
      upstream = await session.client.openRangeResponse(
        session.remotePath,
        range,
        tempDir: session.tempDir,
        fileSize: session.fileSize,
      );

      response.statusCode = upstream.statusCode;
      // 只写实体头；绝不透传 Connection / Transfer-Encoding 等逐跳头
      // （dart:io 会自行处理分块编码）。
      upstream.headers.forEach((name, value) {
        response.headers.set(name, value);
      });
      if (response.headers.value('content-type') == null) {
        response.headers
            .set('content-type', lookupMimeType(session.fileName) ?? 'application/octet-stream');
      }
      // 206 说明远端确实支持随机读，据此告知播放器可 seek。
      if (upstream.statusCode == HttpStatus.partialContent) {
        response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
      }

      final status = upstream.statusCode;
      if (request.method == 'HEAD') {
        await upstream.stream.drain();
        await response.close();
      } else {
        await response.addStream(upstream.stream);
        await response.close();
      }
      WebdavDebugLog.log('Range代理响应 $status range=$range');
    } catch (e) {
      WebdavDebugLog.log('Range代理【异常】: $e');
      try {
        await upstream?.stream.drain();
      } catch (_) {}
      try {
        response.statusCode = HttpStatus.internalServerError;
        await response.close();
      } catch (_) {}
    } finally {
      session.active--;
      session.notifyIdle();
      final tmp = upstream?.tempFilePath;
      if (tmp != null) {
        session.tempFiles.add(tmp);
        try {
          await File(tmp).delete();
        } catch (_) {}
        session.tempFiles.remove(tmp);
      }
    }
  }

  static String _ensureTempDir() {
    final dir = Directory('/storage/emulated/0/ZenFile/cache/range');
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return dir.path;
  }

  String _ext(String name) {
    final dot = name.lastIndexOf('.');
    if (dot <= 0 || dot == name.length - 1) return '';
    return name.substring(dot);
  }
}

class _RangeSession {
  final RemoteClient client;
  final String remotePath;
  final String fileName;
  final int? fileSize;
  final HttpServer server;
  final String tempDir;

  bool closing = false;
  int active = 0;
  Completer<void>? _idleWaiter;
  final List<String> tempFiles = [];

  _RangeSession({
    required this.client,
    required this.remotePath,
    required this.fileName,
    required this.fileSize,
    required this.server,
    required this.tempDir,
  });

  Future<void> drain() {
    if (active <= 0) return Future.value();
    _idleWaiter ??= Completer<void>();
    return _idleWaiter!.future;
  }

  void notifyIdle() {
    if (active <= 0 && _idleWaiter != null && !_idleWaiter!.isCompleted) {
      _idleWaiter!.complete();
    }
  }

  void clearTemp() {
    for (final f in tempFiles) {
      try {
        File(f).deleteSync();
      } catch (_) {}
    }
    tempFiles.clear();
  }
}
