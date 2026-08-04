import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:xml/xml.dart' as xml;
import 'remote_client.dart';

class WebDavRemoteClient extends RemoteClient {
  final String host;
  final int port;
  final String username;
  final String password;
  final String protocol;
  final String rootPath;
  
  late HttpClient _httpClient;

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

  @override
  Future<void> downloadFile(String remotePath, String localPath, Function(double progress) onProgress) async {
    final url = Uri.parse(_baseUrl + Uri.encodeFull(remotePath));
    final request = await _httpClient.openUrl('GET', url);
    final auth = _authHeader();
    if (auth.isNotEmpty) {
      request.headers.set('Authorization', auth);
    }
    final response = await request.close();
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
    final url = Uri.parse(_baseUrl + Uri.encodeFull(remotePath));
    final request = await _httpClient.openUrl('GET', url);
    final auth = _authHeader();
    if (auth.isNotEmpty) {
      request.headers.set('Authorization', auth);
    }
    // HTTP Range 请求只下载指定字节范围
    request.headers.set(HttpHeaders.rangeHeader, 'bytes=$startByte-${startByte + length - 1}');
    final response = await request.close();
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
  String? getStreamUrl(String remotePath) {
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

  @override
  Future<int> getFileSize(String remotePath) async {
    // WebDAV uses direct streaming via getStreamUrl, so getFileSize is not
    // critical for streaming. Return -1 to indicate unknown.
    return -1;
  }
}
