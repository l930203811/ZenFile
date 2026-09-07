import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:xml/xml.dart' as xml;
import 'remote_client.dart';

/// `getStreamUrl` 重定向探测的结果。
class _StreamTarget {
  /// 是否发生过重定向（OpenList「302 重定向」模式）。
  final bool isRedirect;

  /// 跟随重定向后的最终网盘直链；仅当该直链支持 Range(206) 时非空。
  final String? finalUrl;

  _StreamTarget.direct()
      : isRedirect = false,
        finalUrl = null;

  _StreamTarget.redirect(this.finalUrl) : isRedirect = true;
}

class WebDavRemoteClient extends RemoteClient {
  final String host;
  final int port;
  final String username;
  final String password;
  final String protocol;
  final String rootPath;
  
  late HttpClient _httpClient;

  /// 是否支持直接流式播放（无 302 重定向）。
  /// 在 connect() 时通过 HEAD 请求检测一次：
  /// - 普通 WebDAV 服务器 / OpenList 本机代理模式：无 302，支持直连（性能好）
  /// - OpenList 302 重定向模式：有 302，返回 null 让视频播放器走本地代理服务
  ///   （302 重定向到网盘直链后，media_kit 无法正常播放：防盗链/有效期/Range 不支持等）
  bool _supportsDirectStreaming = true;

  /// 当前正在进行的上传请求（PUT），用于在取消时立即中断底层 socket。
  /// 若不中断，request.add 的数据会在后台继续发送，导致取消后仍传输十几秒，
  /// 且挂起的连接会污染连接池，使后续 DELETE 复用坏连接而失败。
  HttpClientRequest? _activeUploadRequest;

  WebDavRemoteClient({
    required this.host,
    required this.port,
    required this.username,
    required this.password,
    this.protocol = 'http',
    this.rootPath = '/',
  }) {
    _httpClient = HttpClient();
    _httpClient.connectionTimeout = const Duration(seconds: 15);
  }

  String get _baseUrl {
    var sanitizedHost = host.trim();
    if (sanitizedHost.startsWith('http://')) {
      sanitizedHost = sanitizedHost.substring(7);
    } else if (sanitizedHost.startsWith('https://')) {
      sanitizedHost = sanitizedHost.substring(8);
    }
    if (sanitizedHost.contains('/')) {
      final parts = sanitizedHost.split('/');
      sanitizedHost = parts.first;
    }
    return '$protocol://$sanitizedHost:$port';
  }

  String _authHeader() {
    if (username.isEmpty && password.isEmpty) return '';
    final bytes = utf8.encode('$username:$password');
    final base64Str = base64.encode(bytes);
    return 'Basic $base64Str';
  }

  @override
  Future<void> connect() async {
    var normalizedRoot = rootPath;
    if (!normalizedRoot.startsWith('/')) {
      normalizedRoot = '/$normalizedRoot';
    }
    if (!normalizedRoot.endsWith('/')) {
      normalizedRoot = '$normalizedRoot/';
    }
    final url = Uri.parse('$_baseUrl$normalizedRoot');
    final request = await _httpClient.openUrl('PROPFIND', url);
    request.headers.set('Depth', '0');
    final auth = _authHeader();
    if (auth.isNotEmpty) {
      request.headers.set('Authorization', auth);
    }
    final response = await request.close();
    if (response.statusCode >= 400) {
      throw Exception('Failed to connect to WebDAV: ${response.statusCode}');
    }
    await response.drain();

    // 检测是否支持直接流式播放（无 302 重定向）
    // 使用单独的 HttpClient（followRedirects: false）发送 HEAD 请求，
    // 避免影响主 _httpClient 的连接池。
    try {
      final detectClient = HttpClient();
      detectClient.connectionTimeout = const Duration(seconds: 5);
      final detectUrl = Uri.parse('$_baseUrl$normalizedRoot');
      final detectRequest = await detectClient.openUrl('HEAD', detectUrl);
      // followRedirects 是 HttpClientRequest 的属性，不是 HttpClient 的属性
      detectRequest.followRedirects = false;
      final auth = _authHeader();
      if (auth.isNotEmpty) {
        detectRequest.headers.set('Authorization', auth);
      }
      final detectResponse = await detectRequest.close();
      // 301/302/303/307/308 重定向：不支持直连，走代理服务
      if (detectResponse.statusCode >= 300 && detectResponse.statusCode < 400) {
        _supportsDirectStreaming = false;
        debugPrint('[WebDAV] Detected ${detectResponse.statusCode} redirect, will use streaming proxy instead of direct URL');
      } else {
        _supportsDirectStreaming = true;
        debugPrint('[WebDAV] No redirect detected, direct streaming supported');
      }
      await detectResponse.drain();
      detectClient.close();
    } catch (e) {
      // HEAD 请求失败（服务器不支持 HEAD / 超时等），默认支持直连（保持原有行为）
      _supportsDirectStreaming = true;
      debugPrint('[WebDAV] Redirect detection failed, default to direct streaming: $e');
    }
  }

  @override
  Future<void> disconnect() async {
    _httpClient.close();
  }

  @override
  void cancel() {
    super.cancel();
    // 立即中断正在进行的 PUT 请求：否则请求体仍会在后台发送，取消后上传仍持续
    // 十几秒；且挂起的连接会污染 HttpClient 连接池，导致后续 DELETE 复用该坏
    // 连接而失败（表现就是“残留的部分文件无法删除”）。
    try {
      _activeUploadRequest?.abort();
    } catch (_) {}
  }

  @override
  void resetCancel() {
    super.resetCancel();
    _activeUploadRequest = null;
  }

  @override
  Future<List<RemoteFileItem>> listDirectory(String path, {bool forceRefresh = false}) async {
    var normalizedPath = path;
    if (!normalizedPath.startsWith('/')) {
      normalizedPath = '/$normalizedPath';
    }
    if (!normalizedPath.endsWith('/') && normalizedPath != '/') {
      normalizedPath = '$normalizedPath/';
    }

    final url = Uri.parse(_baseUrl + Uri.encodeFull(normalizedPath));
    print('[WebDAV DEBUG] PROPFIND URL: $url');
    final request = await _httpClient.openUrl('PROPFIND', url);
    request.headers.set('Depth', '1');
    final auth = _authHeader();
    if (auth.isNotEmpty) {
      request.headers.set('Authorization', auth);
    }
    
    final response = await request.close();
    print('[WebDAV DEBUG] Response status: ${response.statusCode}');
    if (response.statusCode >= 400) {
      throw Exception('WebDAV list error: ${response.statusCode}');
    }

    final body = await response.transform(utf8.decoder).join();
    print('[WebDAV DEBUG] Response body length: ${body.length}');
    print('[WebDAV DEBUG] Response body: $body');
    final document = xml.XmlDocument.parse(body);
    
    // Find response tags under any namespace prefix case-insensitively
    final responses = document.descendants
        .whereType<xml.XmlElement>()
        .where((element) => element.name.local.toLowerCase() == 'response');

    final list = <RemoteFileItem>[];

    for (final element in responses) {
      final hrefElement = element.children
          .whereType<xml.XmlElement>()
          .where((el) => el.name.local.toLowerCase() == 'href')
          .firstOrNull;
      if (hrefElement == null) continue;
      
      var href = Uri.decodeFull(hrefElement.innerText);
      if (href.startsWith('http://') || href.startsWith('https://')) {
        final uri = Uri.parse(href);
        href = uri.path;
      }
      
      if (href == normalizedPath || href == normalizedPath.substring(0, normalizedPath.length - 1)) {
        continue;
      }

      final propstats = element.children
          .whereType<xml.XmlElement>()
          .where((el) => el.name.local.toLowerCase() == 'propstat');
      
      var isCollection = false;
      var size = 0;
      var modified = DateTime.now();

      for (final propstat in propstats) {
        final resourcetype = propstat.descendants
            .whereType<xml.XmlElement>()
            .where((el) => el.name.local.toLowerCase() == 'resourcetype')
            .firstOrNull;
        if (resourcetype != null) {
          isCollection = resourcetype.descendants
              .whereType<xml.XmlElement>()
              .where((el) => el.name.local.toLowerCase() == 'collection')
              .isNotEmpty;
        }

        final getcontentlength = propstat.descendants
            .whereType<xml.XmlElement>()
            .where((el) => el.name.local.toLowerCase() == 'getcontentlength')
            .firstOrNull;
        if (getcontentlength != null) {
          size = int.tryParse(getcontentlength.innerText) ?? 0;
        }

        final getlastmodified = propstat.descendants
            .whereType<xml.XmlElement>()
            .where((el) => el.name.local.toLowerCase() == 'getlastmodified')
            .firstOrNull;
        if (getlastmodified != null) {
          try {
            modified = HttpDate.parse(getlastmodified.innerText);
          } catch (_) {}
        }
      }

      final name = href.endsWith('/') 
          ? href.substring(0, href.length - 1).split('/').last 
          : href.split('/').last;

      if (name.isEmpty) continue;

      list.add(RemoteFileItem(
        name: name,
        path: href,
        isDirectory: isCollection,
        size: size,
        modified: modified,
      ));
    }
    return list;
  }

  @override
  Future<void> createDirectory(String path) async {
    var normalizedPath = path;
    if (!normalizedPath.startsWith('/')) {
      normalizedPath = '/$normalizedPath';
    }
    final url = Uri.parse(_baseUrl + Uri.encodeFull(normalizedPath));
    final request = await _httpClient.openUrl('MKCOL', url);
    final auth = _authHeader();
    if (auth.isNotEmpty) {
      request.headers.set('Authorization', auth);
    }
    final response = await request.close();
    // 405 Method Not Allowed / 301 已存在：视为创建成功（幂等），避免二次同步报错。
    if (response.statusCode == 405 || response.statusCode == 301) {
      await response.drain();
      return;
    }
    if (response.statusCode >= 400) {
      throw Exception('WebDAV folder create error: ${response.statusCode}');
    }
    await response.drain();
  }

  @override
  Future<void> createFile(String path) async {
    var normalizedPath = path;
    if (!normalizedPath.startsWith('/')) {
      normalizedPath = '/$normalizedPath';
    }
    final url = Uri.parse(_baseUrl + Uri.encodeFull(normalizedPath));
    final request = await _httpClient.openUrl('PUT', url);
    final auth = _authHeader();
    if (auth.isNotEmpty) {
      request.headers.set('Authorization', auth);
    }
    request.contentLength = 0;
    final response = await request.close();
    if (response.statusCode >= 400) {
      throw Exception('WebDAV createFile error: ${response.statusCode}');
    }
    await response.drain();
  }

  @override
  Future<void> delete(String path, bool isDir) async {
    // WebDAV 删除偶尔会因网络抖动或服务器锁文件失败，增加重试逻辑
    const maxRetries = 3;
    Exception? lastError;
    for (int attempt = 0; attempt < maxRetries; attempt++) {
      HttpClientRequest? request;
      HttpClientResponse? response;
      try {
        final url = Uri.parse(_baseUrl + Uri.encodeFull(path));
        request = await _httpClient.openUrl('DELETE', url);
        final auth = _authHeader();
        if (auth.isNotEmpty) {
          request.headers.set('Authorization', auth);
        }
        response = await request.close().timeout(const Duration(seconds: 30));
        // 404 表示文件/目录不存在，不重试直接抛出
        if (response.statusCode == 404) {
          await response.drain();
          throw Exception('WebDAV delete error: 404 (not found): $path');
        }
        if (response.statusCode >= 400) {
          throw Exception('WebDAV delete error: ${response.statusCode}');
        }
        await response.drain();
        return; // 成功则直接返回
      } on TimeoutException {
        // 确保响应体被消费，避免连接泄漏
        try {
          if (response != null) await response.drain();
        } catch (_) {}
        lastError = Exception('WebDAV delete timed out');
        if (attempt < maxRetries - 1) {
          await Future.delayed(Duration(milliseconds: 500 * (attempt + 1)));
        }
      } on Exception catch (e) {
        // 确保响应体被消费，避免连接泄漏
        try {
          if (response != null) await response.drain();
        } catch (_) {}
        lastError = e;
        // 如果是"文件不存在"类错误，不重试直接抛出
        final msg = e.toString().toLowerCase();
        if (msg.contains('not found') ||
            msg.contains('does not exist') ||
            msg.contains('404')) {
          rethrow;
        }
        // 其他错误（网络抖动、服务器锁文件等）延迟后重试
        if (attempt < maxRetries - 1) {
          await Future.delayed(Duration(milliseconds: 500 * (attempt + 1)));
        }
      }
    }
    // 所有重试都失败，抛出最后一个错误
    throw Exception(
        'WebDAV delete failed after $maxRetries attempts: $lastError');
  }

  @override
  Future<void> rename(String oldPath, String newPath) async {
    final url = Uri.parse(_baseUrl + Uri.encodeFull(oldPath));
    final request = await _httpClient.openUrl('MOVE', url);
    final auth = _authHeader();
    if (auth.isNotEmpty) {
      request.headers.set('Authorization', auth);
    }
    request.headers.set('Destination', _baseUrl + Uri.encodeFull(newPath));
    final response = await request.close();
    if (response.statusCode >= 400) {
      throw Exception('WebDAV rename error: ${response.statusCode}');
    }
    await response.drain();
  }

  /// 发送 GET 请求，遇到 301/302/307/308 时**手动**跟随重定向，并在跳转后
  /// 【保留 Range 头】。
  ///
  /// 原因：dart:io 的 HttpClient 在自动跟随**跨域**重定向时会丢弃 Range 等自定义头，
  /// OpenList「302 重定向」模式下网盘文件 GET 会 302 到云盘直链，于是拖动进度条
  /// 的随机读退化成整文件重新下载（大视频表现为卡死/极慢）。这里手动跟随可在云盘
  /// 直链上重新带上 Range，让 206 随机读正常工作。跨域跳转不再携带 Authorization
  /// （避免向第三方云盘直链泄露凭据，且与 HttpClient 默认行为一致）。
  Future<HttpClientResponse> _followRedirectGet(String urlStr, {String? range}) async {
    var url = Uri.parse(urlStr);
    String? auth = _authHeader();
    for (int i = 0; i <= 3; i++) {
      final request = await _httpClient.openUrl('GET', url);
      // 必须关闭自动跟随，否则本函数的手动跟随逻辑永远不会触发：
      // HttpClientRequest.followRedirects 默认 true（继承自 _httpClient），
      // dart:io 会在 request.close() 内部直接跟完 302 再返回最终响应，
      // 于是下面拿到的 status 已是 200，看不到 3xx；更严重的是 dart:io
      // 自动跟随【跨域】重定向时会丢弃 Range 头，导致 downloadRange 拿到
      // 整文件 200 而非 206，OpenList 302 模式下拖动进度条会退化成整文件重下
      // （表现为播放失败/卡死）。
      request.followRedirects = false;
      request.maxRedirects = 0;
      if (auth != null && auth.isNotEmpty) {
        request.headers.set('Authorization', auth);
      }
      if (range != null) {
        request.headers.set(HttpHeaders.rangeHeader, range);
      }
      final response = await request.close();
      final status = response.statusCode;
      if (status >= 300 && status < 400) {
        final location = response.headers.value(HttpHeaders.locationHeader);
        try { await response.drain(); } catch (_) {}
        if (location == null) return response;
        // 跨域跳转：不再携带 Authorization；Range 下一轮会重新设置
        auth = null;
        url = url.resolve(location);
        continue;
      }
      return response;
    }
    throw Exception('WebDAV: too many redirects for $urlStr');
  }

  @override
  Future<void> downloadFile(String remotePath, String localPath, Function(double progress) onProgress) async {
    final response = await _followRedirectGet(_baseUrl + Uri.encodeFull(remotePath));
    if (response.statusCode >= 400) {
      throw Exception('WebDAV download error: ${response.statusCode}');
    }

    final totalSize = response.contentLength;
    final file = File(localPath);
    final sink = file.openWrite();
    int downloaded = 0;

    try {
      await for (final chunk in response) {
        if (isCancelled) break;
        sink.add(chunk);
        downloaded += chunk.length;
        if (totalSize > 0) {
          onProgress(downloaded / totalSize);
        }
      }
    } finally {
      await sink.flush();
      await sink.close();
    }
    if (isCancelled) {
      // 取消下载：删除本地未完成的半截文件，避免留下虚假文件。
      try { await file.delete(); } catch (_) {}
      throw Exception('Cancelled');
    }
  }

  @override
  Future<void> downloadRange(String remotePath, String localPath, int startByte, int length) async {
    final response = await _followRedirectGet(
      _baseUrl + Uri.encodeFull(remotePath),
      range: 'bytes=$startByte-${startByte + length - 1}',
    );
    // 206 = Partial Content（range 请求成功）；200 = 服务器忽略 Range 返回完整内容
    if (response.statusCode != 206 && response.statusCode != 200) {
      throw Exception('WebDAV downloadRange error: ${response.statusCode}');
    }

    final file = File(localPath);
    final sink = file.openWrite();
    int downloaded = 0;
    try {
      await for (final chunk in response) {
        if (downloaded + chunk.length > length) {
          // 防止服务器返回超出请求范围的数据
          sink.add(chunk.sublist(0, length - downloaded));
          break;
        }
        sink.add(chunk);
        downloaded += chunk.length;
        if (downloaded >= length) break;
      }
    } finally {
      await sink.flush();
      await sink.close();
    }
  }

  @override
  Future<void> uploadFile(
    String localPath,
    String remotePath,
    Function(double progress) onProgress,
  ) async {
    final localFile = File(localPath);
    if (!localFile.existsSync()) throw Exception('Local file not found: $localPath');

    final totalSize = await localFile.length();

    var normalizedPath = remotePath;
    if (!normalizedPath.startsWith('/')) normalizedPath = '/$normalizedPath';

    final url = Uri.parse(_baseUrl + Uri.encodeFull(normalizedPath));
    final request = await _httpClient.openUrl('PUT', url);
    _activeUploadRequest = request;
    final auth = _authHeader();
    if (auth.isNotEmpty) {
      request.headers.set('Authorization', auth);
    }
    request.headers.contentLength = totalSize;
    request.headers.contentType = ContentType.binary;

    int uploaded = 0;
    int sinceFlush = 0;
    onProgress(0.0);

    try {
      await for (final chunk in localFile.openRead()) {
        if (isCancelled) {
          // 立即中断底层 socket，停止上传，避免"取消后仍传输十几秒"与挂起连接。
          try {
            request.abort();
          } catch (_) {}
          // 取消上传：删除服务端尚未完成的半截目标文件，避免留下残缺文件。
          try { await delete(remotePath, false); } catch (_) {}
          throw Exception('Cancelled');
        }
        request.add(chunk);
        uploaded += chunk.length;
        sinceFlush += chunk.length;
        // 每 512KB flush 一次，确保数据从 Dart IOSink 内部缓冲区真正发送到
        // 网络 socket。不 flush 时 add() 只写入内存缓冲区，uploaded 以本地
        // SSD 读取速率增长（约 800MB/s），远快于网络发送（约 110MB/s），
        // 导致进度条过早完成、实时速率虚高约 2-7 倍。
        if (sinceFlush >= 512 * 1024) {
          await request.flush();
          sinceFlush = 0;
        }
        if (totalSize > 0) {
          // 限制到 0.95：flush 只保证数据从 Dart 层移到 OS socket 层，
          // TCP 发送缓冲区中仍有部分未真正发出。预留 5% 直到 response
          // 返回才报 100%，避免进度条过早完成。
          onProgress((uploaded / totalSize).clamp(0.0, 0.95));
        }
      }

      await request.flush();
      final response = await request.close();
      await response.drain();

      if (response.statusCode >= 400) {
        throw Exception('WebDAV upload error: ${response.statusCode}');
      }
      onProgress(1.0);
    } finally {
      _activeUploadRequest = null;
    }
  }

  @override
  Future<String?> getStreamUrl(String remotePath) async {
    // 已通过连接期探测确定走代理（个别 OpenList 302 配置根目录也重定向）
    if (!_supportsDirectStreaming) return null;

    // OpenList「302 重定向」模式：目录列表(PROPFIND / 根目录 HEAD)正常返回 200，
    // 但【实际文件】GET 时 302 跳转到网盘直链。连接期只对根目录做了探测，会漏判
    // 这种「仅文件重定向」，所以这里对单个文件做重定向探测（见 _resolveStreamTarget）：
    //   · 无重定向（普通 WebDAV / OpenList 本机代理）→ 走下面的直连 URL；
    //   · 有重定向且直链支持 Range → 返回解析后的网盘直链，真流式播放；
    //   · 有重定向但直链不支持 Range / 解析失败 → 返回 null 走本地代理。
    try {
      final startUrl = Uri.parse(_baseUrl + Uri.encodeFull(remotePath));
      final auth = _authHeader();
      final target = await _resolveStreamTarget(startUrl, auth.isEmpty ? null : auth);
      if (target.isRedirect) {
        final directUrl = target.finalUrl;
        if (directUrl != null && directUrl.isNotEmpty) {
          debugPrint('[WebDAV] 302 已解析为网盘直链，交给播放器直接流式播放');
          return directUrl;
        }
        debugPrint('[WebDAV] 302 直链不支持 Range，走本地代理');
        return null;
      }
    } catch (e) {
      debugPrint('[WebDAV] 单文件重定向探测失败，改走本地代理: $e');
      return null;
    }

    // WebDAV supports HTTP streaming: construct URL with Basic Auth embedded
    var normalizedPath = remotePath;
    if (!normalizedPath.startsWith('/')) normalizedPath = '/$normalizedPath';
    final url = '$_baseUrl${Uri.encodeFull(normalizedPath)}';
    final auth = _authHeader();
    if (auth.isEmpty) return url;
    // Embed credentials in URL for media_kit (format: http://user:pass@host:port/path)
    final sanitizedHost = host.trim();
    final cleanHost = sanitizedHost
        .replaceFirst('http://', '')
        .replaceFirst('https://', '')
        .split('/').first;
    // media_kit / libmpv supports HTTP Basic Auth via URL credentials
    return '$protocol://$username:$password@$cleanHost:$port${Uri.encodeFull(normalizedPath)}';
  }

  /// 对单个文件做重定向探测，并在发生重定向时**自己把重定向跟到底**。
  ///
  /// 为什么要自己跟到底（而不是把会跳转的 OpenList URL 交给 media_kit）：
  /// FFmpeg/mpv 跟随跨域 302 时会丢弃 Range 头、还可能把 WebDAV 的
  /// Authorization 带去网盘直链被拒，播放器只能整文件缓冲 —— 表现为
  ///「302 模式下要等视频下载完才能播」。这里解析出最终直链后直接给播放器，
  /// media_kit 对直链发 Range 请求，即可实现真正的边下边播 + 拖动。
  ///
  /// 返回：
  /// - `_StreamTarget.direct()`：无重定向（普通 WebDAV / OpenList 本机代理）；
  /// - `_StreamTarget.redirect(url)`：发生重定向且最终直链支持 Range(206)；
  /// - `_StreamTarget.redirect(null)`：重定向但直链不可用 → 调用方走本地代理。
  Future<_StreamTarget> _resolveStreamTarget(Uri start, String? auth) async {
    final client = HttpClient();
    // OpenList 需先向网盘申请临时直链才返回 302，耗时可能数秒，放宽到 15s。
    client.connectionTimeout = const Duration(seconds: 15);
    var sawRedirect = false;
    try {
      var url = start;
      var curAuth = auth;
      for (int i = 0; i <= 5; i++) {
        final req = await client.openUrl('GET', url);
        // 必须关闭自动跟随：否则看不到 3xx，且跨域自动跳转会丢 Range。
        req.followRedirects = false;
        req.maxRedirects = 0;
        if (curAuth != null && curAuth.isNotEmpty) {
          req.headers.set('Authorization', curAuth);
        }
        req.headers.set(HttpHeaders.rangeHeader, 'bytes=0-0');
        final resp = await req.close();
        final status = resp.statusCode;
        final location = resp.headers.value(HttpHeaders.locationHeader);

        if (status >= 300 && status < 400) {
          try { await resp.drain(); } catch (_) {}
          if (location == null) return _StreamTarget.redirect(null);
          sawRedirect = true;
          // 跨域跳转：不再携带 Authorization，避免把 WebDAV 凭据泄露给网盘直链
          curAuth = null;
          url = url.resolve(location);
          continue;
        }

        if (status >= 200 && status < 300) {
          // 206 = 直链支持 Range（可拖动/真流式）；200 = 服务器忽略 Range，
          // 播放器只能整文件缓冲，不如交给本地代理。
          // 注意：200 时响应体是【整个文件】，绝不能 drain，否则会把整文件下下来。
          final rangeOk = status == 206;
          if (rangeOk) {
            try { await resp.drain(); } catch (_) {}
          }
          if (!sawRedirect) return _StreamTarget.direct();
          return _StreamTarget.redirect(rangeOk ? url.toString() : null);
        }

        // 其他状态码（4xx/5xx 等）：探测失败，走本地代理
        try { await resp.drain(); } catch (_) {}
        return _StreamTarget.redirect(null);
      }
      return _StreamTarget.redirect(null);
    } finally {
      client.close(force: true);
    }
  }

  @override
  Future<int> getFileSize(String remotePath) async {
    // 之前固定返回 -1，导致本地代理(RemoteStreamingService)只能用 chunked 200
    // （Accept-Ranges: none）响应：进度条不走、拖动进度条卡在"正在缓存"。
    // 这里改为通过 PROPFIND(Depth:0) 读取真实 getcontentlength。
    // 用 PROPFIND 而非 HEAD：OpenList 302 模式下文件的 GET/HEAD 会跳转到网盘直链，
    // 而 PROPFIND 由 OpenList 自身应答（207），既能拿到真实大小又不会触发重定向。
    var normalizedPath = remotePath;
    if (!normalizedPath.startsWith('/')) normalizedPath = '/$normalizedPath';
    try {
      final url = Uri.parse(_baseUrl + Uri.encodeFull(normalizedPath));
      final request = await _httpClient.openUrl('PROPFIND', url);
      request.headers.set('Depth', '0');
      final auth = _authHeader();
      if (auth.isNotEmpty) {
        request.headers.set('Authorization', auth);
      }
      final response = await request.close();
      if (response.statusCode >= 400) return -1;
      final body = await response.transform(utf8.decoder).join();
      final document = xml.XmlDocument.parse(body);
      final sizeText = document.descendants
          .whereType<xml.XmlElement>()
          .where((el) => el.name.local.toLowerCase() == 'getcontentlength')
          .map((el) => el.innerText.trim())
          .firstWhere((t) => t.isNotEmpty, orElse: () => '');
      await response.drain();
      if (sizeText.isNotEmpty) {
        return int.tryParse(sizeText) ?? -1;
      }
    } catch (e) {
      debugPrint('[WebDAV] getFileSize 失败: $e');
    }
    return -1;
  }
}
