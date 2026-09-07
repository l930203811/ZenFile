import 'dart:io';

import 'package:mime/mime.dart';

import 'remote/webdav_client.dart';
import 'webdav_debug_log.dart';

/// HTTP **按需 Range** 反代服务（专供 WebDAV / OpenList 302 模式流式播放）。
///
/// ## 为什么需要它（而不是复用 RemoteStreamingService）
///
/// `RemoteStreamingService` 的实现是「把整个远程文件**顺序**下载到 .partial，
/// 播放器从这个不断增长的本地文件里读」。当播放器请求尚未下载到的偏移时
/// （典型场景：MP4 的 moov 索引在**文件尾部**，播放器开播前要先请求
/// `Range: bytes=<尾部>-`），代理只能干等顺序下载追上来 —— 对非 faststart
/// 的 MP4 就等于「必须等整个文件下载完才能开播」。实测日志：
///   01:17:41 代理启动(10.7MB) → 01:17:46 播放器请求尾部 → 01:19:10 才开播(89s)
///   → 01:19:27 下载完成。
///
/// 而 OpenList 302 解析出的网盘直链**本身支持 Range**（探测已验证返回 206），
/// 所以正确做法是：播放器要哪个区间，就向远端取哪个区间，原样透传 206。
/// 这样开播只等首段缓冲，拖动进度条也是即时取对应区间。
///
/// ## 与 RemoteStreamingService 的分工
/// - 本服务：**HTTP 系**远端（WebDAV/OpenList），支持真·Range 随机读。
/// - RemoteStreamingService：SFTP/FTP/SMB 等，`downloadRange(pos>0)` 不可靠
///   （见该文件注释），只能顺序下载。
/// 两者互不干扰，本服务不改变其它协议的行为。
class HttpRangeProxyService {
  HttpRangeProxyService._();

  static final HttpRangeProxyService instance = HttpRangeProxyService._();

  final Map<int, _RangeSession> _sessions = {};

  /// 启动一个针对 [remotePath] 的反代，返回形如
  /// `http://127.0.0.1:<port>/stream.mp4` 的本地 URL。
  Future<String> start(
    WebDavRemoteClient client,
    String remotePath, {
    String? fileName,
  }) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final name = fileName ?? remotePath.split('/').where((s) => s.isNotEmpty).last;
    final ext = _ext(name);
    _sessions[server.port] = _RangeSession(
      client: client,
      remotePath: remotePath,
      fileName: name,
      server: server,
    );
    server.listen(
      (request) => _handle(server.port, request),
      onError: (e) => WebdavDebugLog.log('Range代理 server error: $e'),
    );
    final url = 'http://127.0.0.1:${server.port}/stream$ext';
    WebdavDebugLog.log(
        'Range代理启动 url=$url remotePath=$remotePath fileName=$name');
    return url;
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
      await session.server.close(force: true);
    } catch (_) {}
  }

  Future<void> _handle(int port, HttpRequest request) async {
    final response = request.response;
    final session = _sessions[port];
    if (session == null) {
      response.statusCode = HttpStatus.notFound;
      await response.close();
      return;
    }

    final range = request.headers.value(HttpHeaders.rangeHeader);
    WebdavDebugLog.log(
        'Range代理收到 ${request.method} ${request.uri.path} range=$range');
    HttpClientResponse? upstream;
    try {
      upstream = await session.client
          .openRangeResponse(session.remotePath, rangeHeader: range);

      response.statusCode = upstream.statusCode;
      // 只透传与实体相关的头；绝不能透传 Connection / Transfer-Encoding 等
      // 逐跳头（dart:io 会自行处理分块编码）。
      for (final name in const [
        'content-type',
        'content-length',
        'content-range',
        'accept-ranges',
        'etag',
        'last-modified',
      ]) {
        final value = upstream.headers.value(name);
        if (value != null && value.isNotEmpty) {
          response.headers.set(name, value);
        }
      }
      if (response.headers.value('content-type') == null) {
        final mime = lookupMimeType(session.fileName) ??
            'application/octet-stream';
        response.headers.set('content-type', mime);
      }
      // 206 说明远端确实支持随机读，据此告知播放器可 seek。
      if (upstream.statusCode == 206) {
        response.headers.set('accept-ranges', 'bytes');
      }

      final status = upstream.statusCode;
      if (request.method == 'HEAD') {
        await upstream.drain();
        await response.close();
      } else {
        await response.addStream(upstream);
        await response.close();
      }
      WebdavDebugLog.log('Range代理响应 $status range=$range');
    } catch (e) {
      WebdavDebugLog.log('Range代理【异常】: $e');
      try {
        await upstream?.drain();
      } catch (_) {}
      try {
        response.statusCode = HttpStatus.internalServerError;
        await response.close();
      } catch (_) {}
    }
  }

  String _ext(String name) {
    final dot = name.lastIndexOf('.');
    if (dot <= 0 || dot == name.length - 1) return '';
    return name.substring(dot);
  }
}

class _RangeSession {
  final WebDavRemoteClient client;
  final String remotePath;
  final String fileName;
  final HttpServer server;

  _RangeSession({
    required this.client,
    required this.remotePath,
    required this.fileName,
    required this.server,
  });
}
