import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import '../../models/network_connection_model.dart';
import '../network_connections_service.dart';
import '../webdav_debug_log.dart';
import '../remote/remote_client.dart';
import 'crypt_config.dart';
import 'crypt_mount.dart';
import 'crypt_file.dart';
import 'remote_crypt_file.dart';

/// 加密文件流式解密 HTTP 服务器
///
/// 启动本地 HTTP 服务器，当播放器请求加密文件时，服务器流式解密并返回数据，
/// 支持 HTTP Range 请求，实现边解密边播放，无需等待完整解密。
class CryptStreamServer {
  static CryptStreamServer? _instance;
  HttpServer? _server;
  int? _port;
  final Map<String, CryptMountPoint> _mounts = {};
  /// 远程加密挂载点（客户端解密），键为虚拟根 `cryptremote://{connId}|{base}`
  final Map<String, CryptMountPoint> _remoteMounts = {};
  bool _isInitialized = false;

  CryptStreamServer._();

  /// 获取单例
  static CryptStreamServer get instance {
    _instance ??= CryptStreamServer._();
    return _instance!;
  }

  // ── 测试注入点（生产为 null，走下面默认实现）──────────────────────────
  //
  // 远程加密流式链路高度依赖真机（后端 + 网络），难以在 CI 里验证。
  // 这里允许单元测试替换「按连接构造 RemoteClient」与「按 connId 查连接」两步，
  // 从而用一个伪造的 RemoteClient 端到端验证 HTTP 流式解密（见
  // test/crypt/crypt_stream_server_test.dart）。

  /// 按连接模型构造远程客户端。默认 [NetworkConnectionsService.buildRemoteClient]。
  static Future<RemoteClient> Function(NetworkConnectionModel conn)?
      remoteClientFactoryForTest;

  /// 按连接 id 查找连接模型。默认遍历 [NetworkConnectionsService.getConnections]。
  static NetworkConnectionModel? Function(String connId)?
      connectionResolverForTest;

  /// 诊断日志：同时写 logcat 与设备上的 `ZenFile/webdav_debug.log`。
  ///
  /// 远程加密播放问题绝大多数只能靠日志定位，而很多环境（云电脑）无法用 adb，
  /// 因此这里统一走 [WebdavDebugLog]（release 包同样落盘）。
  static void _log(String msg) {
    debugPrint('[ZenFile] $msg');
    WebdavDebugLog.log(msg);
  }

  /// 服务器是否已启动
  bool get isRunning => _server != null;

  /// 获取服务器端口
  int? get port => _port;

  /// 初始化服务器（如果未启动）
  ///
  /// 注意：判断条件是「已初始化 **且** 端口真的拿到了」。旧写法只看 `_isInitialized`，
  /// 一旦 `_startServer` 绑定失败（端口被占/沙箱限制），标记已被置位而 `_port` 仍为 null，
  /// 后续 [getStreamUrl] 会原样返回 `cryptremote://…`，播放器拿到非 http 地址会静默失败
  /// （打开播放器但不产生任何网络请求），表现为「能进播放页但没有速率/不下载」。
  Future<void> ensureInitialized() async {
    if (_isInitialized && _server != null && _port != null) return;
    _isInitialized = true;
    await _startServer();
  }

  /// 启动 HTTP 服务器
  Future<void> _startServer() async {
    try {
      _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      _port = _server!.port;
      _log('Crypt stream server started on port $_port');
      _server!.listen(_handleRequest, onError: (e) {
        _log('Crypt stream server error: $e');
      });
      // 定期回收空闲的远程加密连接（>2 分钟未使用），避免连接泄漏。
      _idleTimer ??= Timer.periodic(const Duration(seconds: 60), (_) {
        final now = DateTime.now();
        final stale = <String>[];
        for (final e in _remoteConnCache.entries) {
          if (now.difference(e.value.lastUsed).inSeconds > 120) {
            stale.add(e.key);
          }
        }
        for (final k in stale) {
          _disposeRemoteClient(k);
        }
      });
    } catch (e) {
      _log('Failed to start crypt stream server: $e');
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

  /// 注册远程加密挂载点（客户端解密）
  void registerRemoteMount(CryptMountPoint mount) {
    _remoteMounts[mount.remoteVirtualRoot] = mount;
  }

  /// 注册多个远程加密挂载点
  void registerRemoteMounts(List<CryptMountPoint> mounts) {
    for (final mount in mounts) {
      registerRemoteMount(mount);
    }
  }

  /// 查找包含指定路径的**远程**挂载点（供 provider 判断是否已注册）
  CryptMountPoint? findRemoteMount(String path) {
    CryptMountPoint? best;
    for (final mount in _remoteMounts.values) {
      if (mount.containsPath(path)) {
        if (best == null || mount.physicalPath.length > best.physicalPath.length) {
          best = mount;
        }
      }
    }
    return best;
  }

  /// 按连接 id 在已保存连接中查找（默认实现，测试可整体替换）。
  NetworkConnectionModel? _lookupConnection(String connId) {
    try {
      for (final c in NetworkConnectionsService.getConnections()) {
        if (c.id == connId) return c;
      }
    } catch (e) {
      _log('查找远程连接失败: $e');
    }
    return null;
  }

  /// 远程加密连接缓存：按连接 id 缓存已连接的 [RemoteClient]。
  ///
  /// 关键修复：媒体播放器（media_kit 等）会为一个文件发起**数十个** Range 请求，
  /// 旧实现每次请求都 buildRemoteClient→connect→disconnect，导致连接风暴、服务端
  /// 限流/超时、播放卡死。现改为复用长连接：同一连接的客户端只连接一次，空闲超时才断开。
  final Map<String, _CachedRemoteClient> _remoteConnCache = {};
  Timer? _idleTimer;

  /// 获取（或复用）已连接的远程客户端。
  Future<RemoteClient> _acquireRemoteClient(NetworkConnectionModel conn) async {
    final cached = _remoteConnCache[conn.id];
    if (cached != null) {
      cached.lastUsed = DateTime.now();
      return cached.client;
    }
    final client = remoteClientFactoryForTest != null
        ? await remoteClientFactoryForTest!(conn)
        : NetworkConnectionsService.buildRemoteClient(conn);
    await client.connect();
    _remoteConnCache[conn.id] = _CachedRemoteClient(client);
    return client;
  }

  /// 丢弃某个连接的缓存客户端（强制下次重新连接，用于连接失效后的重试）。
  void _disposeRemoteClient(String connId) {
    final cached = _remoteConnCache.remove(connId);
    if (cached != null) {
      try {
        cached.client.disconnect();
      } catch (_) {}
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

      _log('流式请求到达: ${uri.path} path=$virtualPath');

      // 远程加密文件（客户端解密）：密文在后端，需先建远程连接再按块拉取解密。
      if (virtualPath.startsWith('cryptremote://')) {
        await _handleRemoteRequest(request, virtualPath);
        return;
      }

      final mount = _findMount(virtualPath);
      if (mount == null) {
        request.response.statusCode = HttpStatus.notFound;
        await request.response.close();
        return;
      }

      // 解析真实物理路径（含目录扫描兜底，兼容文件名编码/加密后缀配置不一致）。
      final physicalPath = await mount.resolvePhysicalPath(virtualPath);
      final physicalFile = File(physicalPath);
      if (!await physicalFile.exists()) {
        request.response.statusCode = HttpStatus.notFound;
        await request.response.close();
        return;
      }

      // ⚠️ 位于加密挂载点目录内、但文件头没有 RCLONE magic 的文件是**已解密的明文**。
      // 若仍走 CryptFile 解密，等于把明文再解一次 → 数据错乱 → 播放器无法播放。
      final isEncrypted = await _fileHasCryptMagic(physicalPath);

      CryptFile? cryptFile;
      final int decryptedSize;
      if (isEncrypted) {
        cryptFile = await CryptFile.open(physicalPath, mount.crypt, mode: CryptFileMode.read);
        decryptedSize = cryptFile.length;
      } else {
        decryptedSize = await physicalFile.length();
      }

      // 读取文件头用于魔数识别格式。
      // ⚠️ 虚拟文件名可能没有扩展名（如 OpenList 用 base64 + 空后缀加密），
      // 此时仅靠扩展名会返回 octet-stream，播放器无法识别导致无法播放。
      List<int> header = const <int>[];
      if (decryptedSize > 0) {
        try {
          final headerLen = decryptedSize < 16 ? decryptedSize : 16;
          header = isEncrypted
              ? await cryptFile!.read(0, headerLen)
              : await _readPlainBytes(physicalPath, 0, headerLen);
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
            await cryptFile?.close();
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
        final data = isEncrypted
            ? await cryptFile!.read(position, readSize)
            : await _readPlainBytes(physicalPath, position, readSize);
        request.response.add(data);
        await request.response.flush();
        position += readSize;
      }

      await cryptFile?.close();
      await request.response.close();
    } catch (e) {
      _log('Crypt stream request error: $e');
      try {
        request.response.statusCode = HttpStatus.internalServerError;
        await request.response.close();
      } catch (_) {}
    }
  }

  /// 处理**远程加密文件**的流式解密请求（客户端解密）。
  ///
  /// 流程：解析虚拟路径 → 找远程挂载点 → 用连接 id 建 [RemoteClient] 并连接 →
  /// [RemoteCryptFile] 按块拉取密文并本地解密 → 按 Range 流式写响应。
  /// 与本地分支的区别仅在于「密文来源」：本地读 `File`，远程读 [RemoteClient]。
  Future<void> _handleRemoteRequest(HttpRequest request, String virtualPath) async {
    RemoteClient? client;
    RemoteCryptFile? cryptFile;
    try {
      _log('远程加密流请求: $virtualPath （已注册挂载点 ${_remoteMounts.length} 个）');
      final mount = findRemoteMount(virtualPath);
      final connId = mount?.remoteConnId;
      if (mount == null || connId == null) {
        _log('远程加密流失败：未找到挂载点 $virtualPath'
            '（已注册 ${_remoteMounts.length} 个：${_remoteMounts.keys.join(', ')}）');
        request.response.statusCode = HttpStatus.notFound;
        await request.response.close();
        return;
      }

      final serverPath = mount.virtualToRemoteServerPath(virtualPath);
      NetworkConnectionModel? conn = connectionResolverForTest?.call(connId);
      conn ??= _lookupConnection(connId);
      if (conn == null) {
        _log('远程加密流失败：连接 $connId 不在已保存连接列表中');
        request.response.statusCode = HttpStatus.notFound;
        await request.response.close();
        return;
      }

      // 复用长连接（避免每个 Range 请求重建连接导致媒体播放超时）。
      client = await _acquireRemoteClient(conn);
      // 打开失败后强制重连一次再试，覆盖「连接被服务端回收」等情况。
      try {
        cryptFile = await RemoteCryptFile.open(serverPath, mount.crypt, client);
      } catch (e) {
        _log('远程加密打开失败，尝试重连: $e');
        _disposeRemoteClient(connId);
        client = await _acquireRemoteClient(conn);
        cryptFile = await RemoteCryptFile.open(serverPath, mount.crypt, client);
      }
      final decryptedSize = cryptFile.length;
      _log('远程加密流：serverPath=$serverPath 解密大小=$decryptedSize');
      if (decryptedSize <= 0) {
        _log('远程加密流失败：解密大小为 0（连接/密码/路径是否匹配？）');
        request.response.statusCode = HttpStatus.notFound;
        await request.response.close();
        await cryptFile.close();
        return;
      }

      // 读文件头用于魔数识别格式（密文名可能没有扩展名）。
      // ⚠️ 只有当扩展名识别不出格式时才读：URL 已带真实扩展名（如 /decrypt.mp4）
      // 时无需再多一次远程往返。
      var mimeType = _guessMimeType(virtualPath);
      List<int> header = const <int>[];
      if (mimeType == 'application/octet-stream') {
        try {
          final headerLen = decryptedSize < 16 ? decryptedSize : 16;
          header = await cryptFile.read(0, headerLen);
        } catch (_) {}
        mimeType = _detectMimeFromHeader(header) ?? mimeType;
      }
      // 解析 Range 请求
      final rangeHeader = request.headers.value(HttpHeaders.rangeHeader);
      int start = 0;
      int end = decryptedSize - 1;
      var isRangeRequest = false;
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
            request.response.headers
                .set(HttpHeaders.contentRangeHeader, 'bytes */$decryptedSize');
            await request.response.close();
            await cryptFile.close();
            // ⚠️ 这里**不能** `client.disconnect()`：client 是 [_remoteConnCache] 里共享的
            // 长连接，断开后缓存里留着一个已断线的实例，后续 Range 请求会全部失败。
            // 复用连接由 _idleTimer 按空闲时间统一回收。
            return;
          }
          if (end >= decryptedSize) end = decryptedSize - 1;
        }
      }
      final contentLength = end - start + 1;

      request.response.headers.contentType = ContentType.parse(mimeType);
      request.response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
      request.response.headers.set('Content-Length', contentLength.toString());
      if (isRangeRequest) {
        request.response.statusCode = HttpStatus.partialContent;
        request.response.headers.set(
            HttpHeaders.contentRangeHeader, 'bytes $start-$end/$decryptedSize');
      } else {
        request.response.statusCode = HttpStatus.ok;
      }

      // 远程每块都要一次网络往返，块太小会把带宽全耗在往返延迟上：
      // 64KB/次时播放大文件实测「进了播放页但速率几乎不动」，放大到 1MB。
      const chunkSize = 1024 * 1024;
      var position = start;
      while (position <= end) {
        final readSize =
            position + chunkSize > end + 1 ? end - position + 1 : chunkSize;
        final data = await cryptFile.read(position, readSize);
        if (data.isEmpty) break;
        request.response.add(data);
        await request.response.flush();
        position += data.length;
      }

      await cryptFile.close();
      await request.response.close();
    } catch (e, st) {
      _log('Remote crypt stream error: $e\n$st');
      // 远程拉取类异常多半是连接失效，丢弃缓存客户端，下次请求重新建立。
      try {
        final m = findRemoteMount(virtualPath);
        if (m?.remoteConnId != null) _disposeRemoteClient(m!.remoteConnId!);
      } catch (_) {}
      try {
        await cryptFile?.close();
      } catch (_) {}
      try {
        request.response.statusCode = HttpStatus.internalServerError;
        await request.response.close();
      } catch (_) {}
    }
  }

  /// 判断文件头是否带 rclone crypt 的 magic（`RCLONE\x00\x00`）
  Future<bool> _fileHasCryptMagic(String path) async {
    RandomAccessFile? raf;
    try {
      final file = File(path);
      if (!await file.exists()) return false;
      final length = await file.length();
      if (length < fileMagicSize) return false;
      raf = await file.open(mode: FileMode.read);
      final head = await raf.read(fileMagicSize);
      if (head.length < fileMagicSize) return false;
      for (var i = 0; i < fileMagicSize; i++) {
        if (head[i] != fileHeaderMagicBytes[i]) return false;
      }
      return true;
    } catch (_) {
      return false;
    } finally {
      try {
        await raf?.close();
      } catch (_) {}
    }
  }

  /// 读取明文文件的指定区间（用于已解密、无需再解密的文件）
  Future<List<int>> _readPlainBytes(String path, int start, int length) async {
    final raf = await File(path).open(mode: FileMode.read);
    try {
      await raf.setPosition(start);
      return await raf.read(length);
    } finally {
      await raf.close();
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
    // 远程加密路径：密文名是 base32 无后缀，必须用密码解出真实文件名再取扩展名，
    // 否则播放器/查看器拿不到格式（octet-stream）而无法播放。
    if (path.startsWith('cryptremote://')) {
      final mount = findRemoteMount(path);
      if (mount != null) {
        try {
          final serverPath = mount.virtualToRemoteServerPath(path);
          final cipherName = p.basename(serverPath);
          final realName = mount.crypt.decryptFileName(cipherName);
          final dot = realName.lastIndexOf('.');
          if (dot > 0) return realName.substring(dot);
        } catch (_) {}
      }
      return '';
    }
    final dotIndex = path.lastIndexOf('.');
    if (dotIndex < 0 || dotIndex == path.length - 1) return '';
    return path.substring(dotIndex);
  }

  /// 关闭服务器
  Future<void> close() async {
    _idleTimer?.cancel();
    _idleTimer = null;
    for (final cached in _remoteConnCache.values) {
      try {
        cached.client.disconnect();
      } catch (_) {}
    }
    _remoteConnCache.clear();
    await _server?.close();
    _server = null;
    _port = null;
    _isInitialized = false;
    _mounts.clear();
    _remoteMounts.clear();
  }
}

/// 远程加密连接缓存条目：记录客户端与最后使用时间，用于空闲回收。
class _CachedRemoteClient {
  final RemoteClient client;
  DateTime lastUsed;
  _CachedRemoteClient(this.client) : lastUsed = DateTime.now();
}
