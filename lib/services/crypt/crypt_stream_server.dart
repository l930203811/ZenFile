import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'crypt_mount.dart';
import 'crypt_file.dart';

/// 加密文件流式解密 HTTP 服务器
///
/// 启动本地 HTTP 服务器，当播放器请求加密文件时，服务器流式解密并返回数据，
/// 支持 HTTP Range 请求，实现边解密边播放，无需等待完整解密。
class CryptStreamServer {
  static CryptStreamServer? _instance;
  HttpServer? _server;
  int? _port;
  final Map<String, CryptMountPoint> _mounts = {};
  bool _isInitialized = false;

  CryptStreamServer._();

  /// 获取单例
  static CryptStreamServer get instance {
    _instance ??= CryptStreamServer._();
    return _instance!;
  }

  /// 服务器是否已启动
  bool get isRunning => _server != null;

  /// 获取服务器端口
  int? get port => _port;

  /// 初始化服务器（如果未启动）
  Future<void> ensureInitialized() async {
    if (_isInitialized) return;
    _isInitialized = true;
    await _startServer();
  }

  /// 启动 HTTP 服务器
  Future<void> _startServer() async {
    try {
      _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      _port = _server!.port;
      debugPrint('[ZenFile] Crypt stream server started on port $_port');
      _server!.listen(_handleRequest, onError: (e) {
        debugPrint('[ZenFile] Crypt stream server error: $e');
      });
    } catch (e) {
      debugPrint('[ZenFile] Failed to start crypt stream server: $e');
    }
  }

  /// 注册加密挂载点
  void registerMount(CryptMountPoint mount) {
    _mounts[mount.physicalPath] = mount;
  }

  /// 注册多个加密挂载点
  void registerMounts(List<CryptMountPoint> mounts) {
    for (final mount in mounts) {
      registerMount(mount);
    }
  }

  /// 查找包含指定路径的挂载点
  CryptMountPoint? _findMount(String path) {
    CryptMountPoint? best;
    for (final mount in _mounts.values) {
      if (mount.containsPath(path)) {
        if (best == null || mount.physicalPath.length > best.physicalPath.length) {
          best = mount;
        }
      }
    }
    return best;
  }

  /// 处理 HTTP 请求
  Future<void> _handleRequest(HttpRequest request) async {
    try {
      if (request.method != 'GET') {
        request.response.statusCode = HttpStatus.methodNotAllowed;
        await request.response.close();
        return;
      }

      final uri = request.uri;
      // 兼容带扩展名的路径（如 /decrypt.mp4），让播放器能通过 URL 识别格式
      if (!uri.path.startsWith('/decrypt')) {
        request.response.statusCode = HttpStatus.notFound;
        await request.response.close();
        return;
      }

      final virtualPath = uri.queryParameters['path'];
      if (virtualPath == null || virtualPath.isEmpty) {
        request.response.statusCode = HttpStatus.badRequest;
        await request.response.close();
        return;
      }

      final mount = _findMount(virtualPath);
      if (mount == null) {
        request.response.statusCode = HttpStatus.notFound;
        await request.response.close();
        return;
      }

      // 容错：传入的可能是虚拟路径，也可能本身就是物理路径
      // （例如保险箱导入清单里的真实路径），两种都要能正确定位文件。
      var physicalPath = mount.virtualToPhysical(virtualPath);
      if (!await File(physicalPath).exists() && await File(virtualPath).exists()) {
        physicalPath = virtualPath;
      }
      final physicalFile = File(physicalPath);
      if (!await physicalFile.exists()) {
        request.response.statusCode = HttpStatus.notFound;
        await request.response.close();
        return;
      }

      // 打开加密文件
      final cryptFile = await CryptFile.open(physicalPath, mount.crypt, mode: CryptFileMode.read);
      final decryptedSize = cryptFile.length;

      // 读取文件头用于魔数识别格式。
      // ⚠️ 虚拟文件名可能没有扩展名（如 OpenList 用 base64 + 空后缀加密），
      // 此时仅靠扩展名会返回 octet-stream，播放器无法识别导致无法播放。
      List<int> header = const <int>[];
      if (decryptedSize > 0) {
        try {
          final headerLen = decryptedSize < 16 ? decryptedSize : 16;
          header = await cryptFile.read(0, headerLen);
        } catch (_) {}
      }

      // 解析 Range 请求
      final rangeHeader = request.headers.value(HttpHeaders.rangeHeader);
      int start = 0;
      int end = decryptedSize - 1;
      bool isRangeRequest = false;

      if (rangeHeader != null && rangeHeader.startsWith('bytes=')) {
        final range = rangeHeader.substring(6);
        final parts = range.split('-');
        if (parts.length == 2) {
          isRangeRequest = true;
          if (parts[0].isNotEmpty) {
            start = int.tryParse(parts[0]) ?? 0;
          }
          if (parts[1].isNotEmpty) {
            end = int.tryParse(parts[1]) ?? (decryptedSize - 1);
          }
          if (start >= decryptedSize) {
            request.response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
            request.response.headers.set(HttpHeaders.contentRangeHeader, 'bytes */$decryptedSize');
            await request.response.close();
            await cryptFile.close();
            return;
          }
          if (end >= decryptedSize) {
            end = decryptedSize - 1;
          }
        }
      }

      final contentLength = end - start + 1;

      // 设置响应头
      // 扩展名识别不出格式时（无扩展名），改用文件头魔数识别。
      var mimeType = _guessMimeType(virtualPath);
      if (mimeType == 'application/octet-stream') {
        mimeType = _detectMimeFromHeader(header) ?? mimeType;
      }
      request.response.headers.contentType = ContentType.parse(mimeType);
      request.response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
      request.response.headers.set('Content-Length', contentLength.toString());

      if (isRangeRequest) {
        request.response.statusCode = HttpStatus.partialContent;
        request.response.headers.set(HttpHeaders.contentRangeHeader, 'bytes $start-$end/$decryptedSize');
      } else {
        request.response.statusCode = HttpStatus.ok;
      }

      // 流式解密并写入响应
      const chunkSize = 64 * 1024; // 64KB 块
      var position = start;
      while (position <= end) {
        final readSize = position + chunkSize > end + 1 ? end - position + 1 : chunkSize;
        final data = await cryptFile.read(position, readSize);
        request.response.add(data);
        await request.response.flush();
        position += readSize;
      }

      await cryptFile.close();
      await request.response.close();
    } catch (e) {
      debugPrint('[ZenFile] Crypt stream request error: $e');
      try {
        request.response.statusCode = HttpStatus.internalServerError;
        await request.response.close();
      } catch (_) {}
    }
  }

  /// 根据文件路径猜测 MIME 类型
  String _guessMimeType(String path) {
    final lower = path.toLowerCase();
    if (lower.endsWith('.mp4')) return 'video/mp4';
    if (lower.endsWith('.mkv')) return 'video/x-matroska';
    if (lower.endsWith('.avi')) return 'video/x-msvideo';
    if (lower.endsWith('.mov')) return 'video/quicktime';
    if (lower.endsWith('.flv')) return 'video/x-flv';
    if (lower.endsWith('.wmv')) return 'video/x-ms-wmv';
    if (lower.endsWith('.webm')) return 'video/webm';
    if (lower.endsWith('.m4v')) return 'video/x-m4v';
    if (lower.endsWith('.mp3')) return 'audio/mpeg';
    if (lower.endsWith('.aac')) return 'audio/aac';
    if (lower.endsWith('.wav')) return 'audio/wav';
    if (lower.endsWith('.flac')) return 'audio/flac';
    if (lower.endsWith('.ogg')) return 'audio/ogg';
    if (lower.endsWith('.m4a')) return 'audio/mp4';
    if (lower.endsWith('.wma')) return 'audio/x-ms-wma';
    if (lower.endsWith('.opus')) return 'audio/opus';
    return 'application/octet-stream';
  }

  /// 根据文件头魔数识别音视频格式（用于无扩展名的加密文件）
  ///
  /// 支持：MP4/MOV/M4A、Matroska(WebM/MKV)、AVI、WAV、MP3、FLAC、Ogg/Opus、AAC(ADTS)。
  /// 识别不出时返回 null，由调用方回退。
  String? _detectMimeFromHeader(List<int> b) {
    if (b.length < 4) return null;

    // Matroska / WebM（EBML 头）
    if (b[0] == 0x1A && b[1] == 0x45 && b[2] == 0xDF && b[3] == 0xA3) {
      return 'video/x-matroska';
    }

    // MP4 / MOV / M4A：偏移 4 处是 'ftyp'
    if (b.length >= 12 &&
        b[4] == 0x66 &&
        b[5] == 0x74 &&
        b[6] == 0x79 &&
        b[7] == 0x70) {
      final brand = String.fromCharCodes(b.sublist(8, 12)).toLowerCase();
      // M4A 品牌是纯音频容器
      if (brand.startsWith('m4a') || brand.startsWith('mp4a')) return 'audio/mp4';
      return 'video/mp4';
    }

    // RIFF 容器：AVI / WAVE
    if (b.length >= 12 &&
        b[0] == 0x52 &&
        b[1] == 0x49 &&
        b[2] == 0x46 &&
        b[3] == 0x46) {
      final fmt = String.fromCharCodes(b.sublist(8, 12)).toUpperCase();
      if (fmt.startsWith('AVI')) return 'video/x-msvideo';
      if (fmt.startsWith('WAVE')) return 'audio/wav';
    }

    // MP3：ID3 标签 或 帧同步
    if (b[0] == 0x49 && b[1] == 0x44 && b[2] == 0x33) return 'audio/mpeg';
    if (b[0] == 0xFF && (b[1] & 0xE0) == 0xE0) return 'audio/mpeg';

    // FLAC
    if (b[0] == 0x66 && b[1] == 0x4C && b[2] == 0x61 && b[3] == 0x43) {
      return 'audio/flac';
    }
    // Ogg / Opus
    if (b[0] == 0x4F && b[1] == 0x67 && b[2] == 0x67 && b[3] == 0x53) {
      return 'audio/ogg';
    }
    // AAC（ADTS）
    if (b[0] == 0xFF && (b[1] & 0xF6) == 0xF0) return 'audio/aac';

    return null;
  }

  /// 获取加密文件的流式播放 URL
  String getStreamUrl(String virtualPath) {
    if (_port == null) return virtualPath;
    final encodedPath = Uri.encodeQueryComponent(virtualPath);
    // 把真实扩展名附加到路径上，帮助播放器/图片查看器识别格式
    final ext = _extForPath(virtualPath);
    return 'http://127.0.0.1:$_port/decrypt$ext?path=$encodedPath';
  }

  /// 提取路径扩展名（含点），用于流式 URL 伪装
  String _extForPath(String path) {
    final dotIndex = path.lastIndexOf('.');
    if (dotIndex < 0 || dotIndex == path.length - 1) return '';
    return path.substring(dotIndex);
  }

  /// 关闭服务器
  Future<void> close() async {
    await _server?.close();
    _server = null;
    _port = null;
    _isInitialized = false;
    _mounts.clear();
  }
}
