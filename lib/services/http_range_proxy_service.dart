import 'dart:async';
import 'dart:io';

import 'package:mime/mime.dart';

import 'remote/remote_client.dart';
import 'webdav_debug_log.dart';

/// 通用 **按需 Range** 反代服务（远程文件流式播放）。
///
/// ## 两条数据路径
///
/// 1. **HTTP 透传**（WebDAV / OpenList 302，
///    [RemoteClient.rangeViaPassthrough] == true）：Range 头原样发往远端、
///    206 响应与实体流原样回传，零落盘，由 libmpv 原生处理 Range/重连。
/// 2. **块缓存反代**（FTP / SFTP / SMB）：每个播放会话维护固定大小
///    （[_blockSize]）的块文件缓存（LRU [_maxBlocks]）。播放器的开放式
///    Range（`bytes=N-`）被响应为【到文件尾的长流】，代理从 N 起逐块供给：
///    命中缓存立即写出、未命中则经会话级互斥锁串行 `downloadRange` 拉一块
///    （FTP 每块都要重连登录、SFTP/SMB 会话非线程安全，故远端读必须串行）。
///
/// ## 为什么必须有块缓存（实测日志结论）
/// libmpv/ffmpeg 解复用 MP4 时存在大量 KB 级小步 seek（实测中位步长仅
/// ~2.7KB，SMB 甚至 52 字节）：旧实现对每个开放式请求都截断成固定 4MB 响应、
/// 同步整段落盘且**不缓存**，导致 74 秒播放产生 259 次 FTP 重连、偏移仅推进
/// 104MB 却传输约 1GB（约 9.9 倍重复数据），表现为「播几秒卡几秒」。
/// 块缓存后：ffmpeg 在长连接上持续顺序读（顺序拉块即预读），小步 seek 重连
/// 时目标位置几乎总在缓存窗口内 → 本地毫秒响应、零远程往返、零重复传输，
/// 对齐 WebDAV 直连体验；尾部 moov 与进度条拖动则按需拉取对应块（约 1 块、
/// 亚秒级），保持 2 秒级开播与即时拖动。
///
/// 不支持随机读的协议（`supportsRangeRead == false`）继续走
/// RemoteStreamingService，两者互不干扰。
class HttpRangeProxyService {
  HttpRangeProxyService._();

  static final HttpRangeProxyService instance = HttpRangeProxyService._();

  /// 单块大小。FTP 实测 4MB 区间随机读 p50≈149ms（含重连登录），2MB 兼顾
  /// 缓存粒度与重连摊薄（有效吞吐 ≈ 10MB/s+，远超视频码率）。
  static const int _blockSize = 2 * 1024 * 1024;

  /// 会话块缓存上限（块数）。64 × 2MB = 128MB，覆盖 libmpv
  /// demuxer-max-bytes=300M 的主要工作集，避免尾部 moov 与开头互踢。
  static const int _maxBlocks = 64;

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
    final dir = _ensureTempDir(server.port);
    _sessions[server.port] = _RangeSession(
      client: client,
      remotePath: remotePath,
      fileName: name,
      fileSize: fileSize,
      server: server,
      tempDir: dir,
    );
    server.listen(
      (request) => _handle(server.port, request),
      onError: (e) => WebdavDebugLog.log('Range代理 server error: $e'),
    );
    final url = 'http://127.0.0.1:${server.port}/stream$ext';
    WebdavDebugLog.log('Range代理启动 url=$url remotePath=$remotePath '
        'fileName=$name fileSize=$fileSize client=${client.runtimeType} '
        'passthrough=${client.rangeViaPassthrough}');
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
    final sw = Stopwatch()..start();
    session.active++;
    try {
      if (session.client.rangeViaPassthrough) {
        await _servePassthrough(session, request, range);
      } else {
        await _serveBlockCache(session, request, range, sw);
      }
    } catch (e) {
      WebdavDebugLog.log('Range代理【异常】${sw.elapsedMilliseconds}ms: $e');
      try {
        response.statusCode = HttpStatus.internalServerError;
        await response.close();
      } catch (_) {}
    } finally {
      session.active--;
      session.notifyIdle();
    }
  }

  /// 路径 1：HTTP 透传（WebDAV/OpenList）。
  Future<void> _servePassthrough(
    _RangeSession session,
    HttpRequest request,
    String? range,
  ) async {
    final response = request.response;
    final sw = Stopwatch()..start();
    final upstream = await session.client.openRangeResponse(
      session.remotePath,
      range,
      tempDir: session.tempDir,
      fileSize: session.fileSize,
    );
    response.statusCode = upstream.statusCode;
    upstream.headers.forEach((name, value) {
      response.headers.set(name, value);
    });
    if (response.headers.value('content-type') == null) {
      response.headers
          .set('content-type', lookupMimeType(session.fileName) ?? 'application/octet-stream');
    }
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
    WebdavDebugLog.log('Range代理透传完成 ${sw.elapsedMilliseconds}ms status=$status range=$range');
  }

  /// 路径 2：块缓存反代（FTP/SFTP/SMB）。
  Future<void> _serveBlockCache(
    _RangeSession session,
    HttpRequest request,
    String? rangeHeader,
    Stopwatch sw,
  ) async {
    final response = request.response;
    final total = session.fileSize ?? -1;
    final wanted = _parseRange(rangeHeader, total);

    if (wanted == null) {
      response.statusCode = HttpStatus.badRequest;
      await response.close();
      return;
    }
    var start = wanted.start;
    // 后缀形式 bytes=-N：取最后 N 字节
    if (wanted.suffixBytes != null && total > 0) {
      start = total - wanted.suffixBytes!;
      if (start < 0) start = 0;
    }
    if (total > 0 && start >= total) {
      response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
      response.headers.set(HttpHeaders.contentRangeHeader, 'bytes */$total');
      await response.close();
      return;
    }

    // 客户端断开（seek 后 ffmpeg 关闭旧连接）→ 置位，供给循环尽快退出，
    // 不再抢占远端读取锁。
    var cancelled = false;
    final cancelCompleter = Completer<void>();
    void onCancel() {
      if (!cancelled) {
        cancelled = true;
        if (!cancelCompleter.isCompleted) cancelCompleter.complete();
      }
    }

    final reqSub = request.listen((_) {},
        onDone: onCancel, onError: (_) => onCancel(), cancelOnError: true);
    unawaited(response.done.then((_) => onCancel()).catchError((_) => onCancel()));

    // 响应区间终点：固定区间按请求；开放式且总大小已知 → 到文件尾（长流）；
    // 总大小未知 → 持续供给到远端 EOF（chunked 200，不可 seek）。
    final int? last;
    if (wanted.end != null) {
      last = total > 0 ? wanted.end!.clamp(0, total - 1) : wanted.end;
    } else if (total > 0) {
      last = total - 1;
    } else {
      last = null;
    }

    response.headers
        .set('content-type', lookupMimeType(session.fileName) ?? 'application/octet-stream');
    response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
    if (total > 0) {
      response.statusCode = HttpStatus.partialContent;
      response.headers
          .set(HttpHeaders.contentRangeHeader, 'bytes $start-$last/$total');
      response.headers
          .set(HttpHeaders.contentLengthHeader, '${last! - start + 1}');
    } else {
      response.statusCode = HttpStatus.ok;
    }
    if (request.method == 'HEAD') {
      // HEAD：只回头部，不供给实体。
      try {
        await reqSub.cancel();
      } catch (_) {}
      await response.close();
      return;
    }
    try {
      await response.flush();
    } catch (_) {
      try {
        await reqSub.cancel();
      } catch (_) {}
      return;
    }

    var pos = start;
    var blocksHit = 0;
    var blocksFetched = 0;
    var bytesSent = 0;
    RandomAccessFile? raf;
    int? rafBlockStart;
    var pendingFlush = 0;

    Future<void> closeRaf() async {
      final r = raf;
      raf = null;
      rafBlockStart = null;
      if (r != null) {
        try {
          await r.close();
        } catch (_) {}
      }
    }

    try {
      while (!cancelled && !session.closing) {
        if (last != null && pos > last) break;

        final blockStart = (pos ~/ _blockSize) * _blockSize;
        final wasReady = session.isBlockReady(blockStart);
        await session.ensureBlock(
          blockStart,
          total,
          cancelled: () => cancelled || session.closing,
        );
        if (cancelled || session.closing) break;
        if (wasReady) {
          blocksHit++;
        } else {
          blocksFetched++;
        }

        final path = session.blockPath(blockStart);
        final f = File(path);
        if (!f.existsSync()) {
          // 块文件缺失（被淘汰/清理）：下一轮重新拉取
          continue;
        }
        final blockLen = f.lengthSync();
        if (blockLen <= 0) break;

        final inOffset = pos - blockStart;
        if (inOffset >= blockLen) {
          if (total <= 0) break; // 大小未知模式：块短即 EOF
          // total>0 时块短于预期属异常，避免死循环
          break;
        }
        var segEnd = blockStart + blockLen - 1;
        if (last != null && last < segEnd) segEnd = last;

        if (rafBlockStart != blockStart) {
          await closeRaf();
          raf = await f.open(mode: FileMode.read);
          rafBlockStart = blockStart;
        }
        final raf2 = raf!;
        var readPos = inOffset;
        while (readPos < blockLen && (last == null || blockStart + readPos <= last)) {
          if (cancelled || session.closing) break;
          var want = segEnd - (blockStart + readPos) + 1;
          if (want <= 0) break;
          if (want > 256 * 1024) want = 256 * 1024;
          await raf2.setPosition(readPos);
          final data = await raf2.read(want);
          if (data.isEmpty) break;
          response.add(data);
          readPos += data.length;
          pos += data.length;
          bytesSent += data.length;
          pendingFlush += data.length;
          // 首字节立即 flush；之后每 1MB flush 一次，平衡延迟与系统调用。
          if (bytesSent <= _blockSize || pendingFlush >= 1024 * 1024) {
            await response.flush();
            pendingFlush = 0;
          }
        }
        if (cancelled || session.closing) break;

        // 大小未知：短于整块的最后一块即 EOF。
        if (total <= 0 && blockLen < _blockSize) break;
      }
    } catch (e) {
      WebdavDebugLog.log('Range块供给异常 ${sw.elapsedMilliseconds}ms: $e');
    } finally {
      if (pendingFlush > 0) {
        try {
          await response.flush();
        } catch (_) {}
      }
      await closeRaf();
      try {
        await reqSub.cancel();
      } catch (_) {}
      try {
        await response.close();
      } catch (_) {}
    }
    WebdavDebugLog.log(
        'Range代理完成 ${sw.elapsedMilliseconds}ms range=$rangeHeader '
        '发送=${(bytesSent / 1024 / 1024).toStringAsFixed(1)}MB '
        '命中块=$blocksHit 新拉块=$blocksFetched');
  }

  /// 解析 `bytes=start-end` / `bytes=start-` / `bytes=-suffix`。
  _RangeReq? _parseRange(String? header, int total) {
    if (header == null) return _RangeReq(0, null, null);
    final v = header.trim().toLowerCase();
    const prefix = 'bytes=';
    if (!v.startsWith(prefix)) return _RangeReq(0, null, null);
    final spec = v.substring(prefix.length).split(',').first.trim();
    final dash = spec.indexOf('-');
    if (dash < 0) return _RangeReq(0, null, null);
    final first = int.tryParse(spec.substring(0, dash).trim());
    final secondRaw = dash + 1 < spec.length ? spec.substring(dash + 1).trim() : '';
    final second = secondRaw.isEmpty ? null : int.tryParse(secondRaw);
    if (first == null) {
      if (second != null && second > 0) {
        return _RangeReq(0, null, second); // bytes=-N
      }
      return _RangeReq(0, null, null);
    }
    return _RangeReq(first, second, null);
  }

  String _ensureTempDir(int port) {
    final base = Directory('/storage/emulated/0/ZenFile/cache/range');
    if (!base.existsSync()) base.createSync(recursive: true);
    // 首个会话启动时清理崩溃/强杀遗留的旧会话目录与旧格式临时文件
    //（正常 stop 会删除自己的目录）。
    if (_sessions.isEmpty) {
      try {
        for (final e in base.listSync()) {
          if (e is Directory && e.path.contains('/s_')) {
            try {
              e.deleteSync(recursive: true);
            } catch (_) {}
          } else if (e is File) {
            final baseName = e.uri.pathSegments.last;
            // 旧实现（每请求落盘）遗留的 r_<ts>_<start>.bin
            if (baseName.startsWith('r_') && baseName.endsWith('.bin')) {
              try {
                e.deleteSync();
              } catch (_) {}
            }
          }
        }
      } catch (_) {}
    }
    final dir = Directory('${base.path}/s_$port');
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return dir.path;
  }

  String _ext(String name) {
    final dot = name.lastIndexOf('.');
    if (dot <= 0 || dot == name.length - 1) return '';
    return name.substring(dot);
  }
}

/// 简单串行互斥锁（远端读会话非线程安全，且 FTP 需避免并发连接）。
class _Mutex {
  Future<void>? _chain;

  Future<T> run<T>(Future<T> Function() fn) {
    final previous = _chain;
    final completer = Completer<T>();
    _chain = completer.future.then((_) {});
    () async {
      if (previous != null) {
        try {
          await previous;
        } catch (_) {}
      }
      try {
        completer.complete(await fn());
      } catch (e, st) {
        completer.completeError(e, st);
      }
    }();
    return completer.future;
  }
}

class _RangeReq {
  final int start;
  final int? end; // null = 开放式（到文件尾）
  final int? suffixBytes; // bytes=-N
  _RangeReq(this.start, this.end, this.suffixBytes);
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

  _RangeSession({
    required this.client,
    required this.remotePath,
    required this.fileName,
    required this.fileSize,
    required this.server,
    required this.tempDir,
  });

  // ── 块缓存 ──────────────────────────────────────────────────────────────
  final _Mutex _fetchLock = _Mutex();
  final Set<int> _blockReady = <int>{};
  final Map<int, Completer<void>> _blockFetching = {};
  final List<int> _blockLru = [];

  String blockPath(int blockStart) => '$tempDir/b_$blockStart.bin';

  bool isBlockReady(int blockStart) => _blockReady.contains(blockStart);

  /// 确保块可用：命中立即返回；在途则等待同一 Completer；否则持锁拉取。
  Future<void> ensureBlock(
    int blockStart,
    int total, {
    required bool Function() cancelled,
  }) async {
    if (_blockReady.contains(blockStart)) {
      _touch(blockStart);
      return;
    }
    final existing = _blockFetching[blockStart];
    if (existing != null) {
      await existing.future;
      if (_blockReady.contains(blockStart)) _touch(blockStart);
      return;
    }
    final completer = Completer<void>();
    _blockFetching[blockStart] = completer;
    try {
      await _fetchLock.run(() async {
        // 双检：可能在等锁期间已被其他请求拉取
        if (_blockReady.contains(blockStart)) return;
        if (closing || cancelled()) return;

        var len = HttpRangeProxyService._blockSize;
        if (total > 0) {
          final remain = total - blockStart;
          if (remain <= 0) {
            _blockReady.add(blockStart);
            return;
          }
          if (remain < len) len = remain;
        }
        final tmp = '${blockPath(blockStart)}.tmp';
        final sw = Stopwatch()..start();
        await client.downloadRange(remotePath, tmp, blockStart, len);
        sw.stop();
        final f = File(tmp);
        if (!f.existsSync()) {
          throw Exception('block fetch produced no file @$blockStart');
        }
        final dst = blockPath(blockStart);
        try {
          File(dst).deleteSync();
        } catch (_) {}
        f.renameSync(dst);
        _blockReady.add(blockStart);
        _touch(blockStart);
        WebdavDebugLog.log(
            'Range块拉取 ${sw.elapsedMilliseconds}ms start=$blockStart len=$len '
            '实际=${File(dst).lengthSync()}');
      });
      if (!completer.isCompleted) completer.complete();
    } catch (e, st) {
      if (!completer.isCompleted) completer.completeError(e, st);
      rethrow;
    } finally {
      _blockFetching.remove(blockStart);
    }
  }

  /// LRU 触达与淘汰（队首最旧）。
  void _touch(int blockStart) {
    _blockLru.remove(blockStart);
    _blockLru.add(blockStart);
    while (_blockLru.length > HttpRangeProxyService._maxBlocks) {
      final old = _blockLru.removeAt(0);
      _blockReady.remove(old);
      // 正在拉取中的块不删文件（极端情况下刚发起又被淘汰）
      if (_blockFetching.containsKey(old)) continue;
      try {
        File(blockPath(old)).deleteSync();
      } catch (_) {}
    }
  }

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
    try {
      final dir = Directory(tempDir);
      if (dir.existsSync()) {
        dir.deleteSync(recursive: true);
      }
    } catch (_) {}
  }
}
