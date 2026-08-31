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
///
/// On-demand seek: when a Range request targets a position beyond the bytes
/// already on disk, the proxy uses a dedicated [seekClient] to fetch just that
/// byte range from the server (random read). The fetched bytes are merged into
/// a per-session seek cache file (`.seekcache`) at the correct offset, so the
/// same (or overlapping) region is served from local disk on the next request
/// instead of being re-fetched from the remote server. This is what makes
/// dragging the progress bar smooth: without the cache, every 8 MB step of
/// forward playback after a seek would trigger another remote random read
/// (and, for FTP, another full login handshake), which shows up as stutter.
/// [seekClient] is a separate connection from the background downloader so the
/// two never contend on the same (non-thread-safe) server session.
class _Mutex {
  Future<void>? _chain;

  Future<T> run<T>(Future<T> Function() fn) {
    final previous = _chain;
    final completer = Completer<T>();
    _chain = completer.future;
    Future<T> runIt() async {
      if (previous != null) {
        try {
          await previous;
        } catch (_) {
          // 上一个任务失败不影响后续
        }
      }
      return await fn();
    }

    runIt().then(completer.complete).catchError(completer.completeError);
    return completer.future;
  }
}

/// 抓取 [start, start+length) 到 [outPath]，返回实际落盘字节数。
///
/// 经 [session._seekLock] 串行化，避免同一服务器会话上并发随机读互相干扰。
///
/// 注意这里**不做「已被 seek 缓存覆盖」的跳过判断**：后台填充会先登记整段
/// 目标区间、再逐块拉取，若沿用旧的 `_seekCovers` 判断，第 2 块及以后会被
/// 误判为「已缓存」而直接返回，区域将永远填不满。
Future<int> _fetchRangeChunk(
  _StreamSession session,
  int start,
  int length,
  String outPath,
) async {
  final seekClient = session.seekClient;
  if (seekClient == null || length <= 0) return 0;
  if (start < 0) return 0;

  final sc = seekClient; // 非 null 绑定，供闭包内使用
  await session._seekLock.run(() async {
    if (session._disposed) return;
    try {
      await sc.downloadRange(session.remotePath, outPath, start, length);
    } catch (e) {
      debugPrint('RemoteStreamingService: fill chunk fetch failed: $e');
    }
  });
  try {
    final f = File(outPath);
    return f.existsSync() ? f.lengthSync() : 0;
  } catch (_) {
    return 0;
  }
}

/// 等待 [path] 的文件长度达到 [minLen]（或超时），返回实际长度。
///
/// 轮询间隔 30ms：这是「首字节延迟」的直接来源之一，间隔越短首字节越早发出。
Future<int> _waitForFileLength(String path, int minLen, Duration timeout) async {
  final deadline = DateTime.now().add(timeout);
  while (true) {
    var n = 0;
    try {
      final f = File(path);
      n = f.existsSync() ? f.lengthSync() : 0;
    } catch (_) {}
    if (n >= minLen) return n;
    if (DateTime.now().isAfter(deadline)) return n;
    await Future.delayed(const Duration(milliseconds: 30));
  }
}

/// 确保 [start] 起的按需区域正在后台填充，并**只等首个小块落盘**，返回已落盘字节数。
///
/// 这是「首字节秒回」的核心。旧实现 await 一整段（最多 24MB）远程读取完成后
/// 才设置并 flush 206 响应头——对 SFTP/SMB/FTP 意味着拖动后数秒收不到任何字节，
/// libmpv 超时即判定 seek 失败、进度条跳回原点。现在首块（默认 512KB）落盘就
/// 立刻响应，其余字节由 _streamRange 分支 B 按磁盘真实长度 tail-follow 持续供给。
Future<int> _ensureRegionFilling(
  _StreamSession session,
  int start,
  int targetLen, {
  int headBytes = 512 * 1024,
  Duration timeout = const Duration(seconds: 4),
}) async {
  unawaited(session._startRegionFill(start, targetLen));
  final head = headBytes < targetLen ? headBytes : targetLen;
  return _waitForFileLength(session._seekRegionPath(start), head, timeout);
}

class RemoteStreamingService {
  static final instance = RemoteStreamingService._();
  RemoteStreamingService._();

  final Map<int, _StreamSession> _sessions = {};

  Future<String> startStreaming(
    RemoteClient client,
    String remotePath,
    String fileName, {
    int? fileSize,
    RemoteClient? seekClient,
  }) async {
    _cleanupStale();

    // 重复保护：如果同一文件已有活跃会话，复用它而非创建新下载
    // 这避免了用户重新点击播放时启动重复下载
    for (final entry in _sessions.entries) {
      final session = entry.value;
      if (session.remotePath == remotePath && !session.disposed) {
        debugPrint('RemoteStreamingService: reusing existing session for $remotePath (port ${entry.key})');
        // 本次调用传入的 client/seekClient 不会被使用，立即断开以免泄漏连接
        try {
          await client.disconnect();
        } catch (_) {}
        if (seekClient != null) {
          try {
            await seekClient.disconnect();
          } catch (_) {}
        }
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
      seekClient: seekClient,
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

    // 注意：此处不再触发 reseed（后台下载跳到播放头）。
    // reseed 会把数据写到 partial 的远端偏移，中间留下稀疏空洞（全 0），
    // 而 _syncFileLength 用「文件长度」当可读水位 → 空洞把 downloadedBytes
    // 瞬间撑大 → 顺序读取的 _streamFrom 读到空洞区全 0 字节喂给 libmpv
    // → 视频冻结、音频缓冲耗尽后崩溃。所有 seek（moov 元数据 / 拖动）改由
    // 按需 seekClient → seekCache 提供，partial 保持严格顺序连续。

    if (start >= fileSize) {
      response.statusCode = 416;
      response.headers.set(HttpHeaders.contentRangeHeader, 'bytes */$fileSize');
      await response.close();
      return;
    }

    final clampedEnd = end.clamp(0, fileSize - 1);

    // 本地可用字节（后台顺序下载已落盘的部分）；下载完成后等于 fileSize。
    final partialAvail = session.downloadedBytes;

    // 会话级 seek 缓存是否覆盖 start（多段区域，见 _StreamSession._seekRegions）。
    final seekCoversStart = session._seekCovers(start);

    // 选择数据源（核心修复：拖动后卡顿的根因）
    // ------------------------------------------------------------------
    // 旧实现：inCache 分支仍用 isPartial=true 读取 seekcache，导致
    // `_streamFrom` 用「后台下载进度 downloadedBytes」来门控本地已缓存数据。
    // 一旦后台下载停滞（或拖动位置领先下载头），明明 seekcache 里已有该段
    // 数据，代理却按停滞的 downloadedBytes 把输出「饿死」，表现为
    // 「播放几帧 → 正在缓存 → 播放几帧 → 正在缓存」的循环，即使网速已停。
    // 新逻辑：
    //  1) 后台下载已覆盖 start → 读 partial（按 downloadedBytes 门控，渐进流式）
    //  2) 后台未覆盖，但 seek 缓存已覆盖 → 读 seekcache，按文件【真实长度】
    //     门控（不跟随后台停滞的下载进度），不再被后台进度饿死
    //  3) 两者都未覆盖 → 按需远程随机读，并入 seekcache 后再从本地读
    int rangeStart;
    int rangeEnd;

    // 数据源选择（修复「顺序播放也被迫走按需远程读」的卡顿回归）：
    //  · start 落在后台顺序下载已落盘区间内（含播放头） → 读 partial，跟随后台下载
    //    推进。这是最流畅的主路径，与 WebDAV 直连的「连续流式读取」等价：partial
    //    就是本地预读缓冲，libmpv 从本地不断增长的 partial 顺序读取，零远程往返、
    //    零连接开销。背景顺序下载即「预读缓冲」，libmpv 的大缓存（demuxer-max-bytes
    //    等）叠加本地 partial 缓冲，可完全吸收代理喂流的脉冲式抖动。
    //  · 拖动到尚未下载到的位置（start 领先 partialAvail） → 经独立 seekClient 做
    //    真实服务端偏移随机读（SFTP JSch get(offset)/FTP REST/SMB smbj skip 均已
    //    支持），结果并入本地 .seekcache，后续重叠请求从本地读，避免重复远程读。
    //  仅当 start 领先已下载区间时才走按需远程读；顺序播放/已下载区间一律跟随
    //  partial，杜绝每 16MB 发起一次按需抓取而与后台下载争抢带宽的卡顿。
    if (start <= partialAvail) {
      // 顺序播放/已下载区间：读 partial，跟随后台下载推进（最流畅路径）
      rangeStart = start;
      rangeEnd = clampedEnd;
    } else if (seekCoversStart) {
      // 后台未覆盖，但某段 seek 缓存已覆盖：从对应缓存文件读真实长度（不门控后台进度）
      final region = session._regionFor(start)!;
      rangeStart = start;
      rangeEnd = clampedEnd < region.end - 1 ? clampedEnd : region.end - 1;
    } else {
      // 需要按需远程随机读取（拖动到尚未下载到的位置）。
      //
      // 关键改动（首字节秒回）：旧实现在这里 await 一整段（最多 24MB）远程读取
      // 完成后，才去设置并 flush 206 响应头——对 SFTP/SMB/FTP 意味着拖动后数秒
      // 收不到任何字节，libmpv 超时即判定 seek 失败、进度条跳回原点。
      // 现在：后台分块填充直写区域文件（边下边播），这里只等首个小块落盘即响应，
      // 首字节延迟由「整个 24MB」降为「首个 2MB 分块」。
      const seekFill = 24 * 1024 * 1024; // 后台填充目标：足够覆盖后续连续播放
      final fetchLen = (fileSize - start).clamp(1, seekFill);
      final avail = await _ensureRegionFilling(session, start, fetchLen);
      if (avail <= 0) {
        // 首个分块都没拿到：降级为读 partial 并等待后台下载（不夸大 Content-Length）
        rangeStart = start;
        rangeEnd = clampedEnd;
      } else {
        rangeStart = start;
        // 仅声明已真正落盘的字节。夸大 Content-Length 会让播放器空等，或在
        // 数据不足时提前截断响应——被截断的响应正是 libmpv 判定 seek 失败、
        // 进度条跳回原点的直接原因。
        rangeEnd = clampedEnd < start + avail - 1 ? clampedEnd : start + avail - 1;
      }
    }

    final contentLength = rangeEnd - rangeStart + 1;

    // Set response headers
    response.statusCode = 206;
    response.headers.set(HttpHeaders.contentRangeHeader, 'bytes $rangeStart-$rangeEnd/$fileSize');
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

    // 连续服务整个请求区间：在「后台顺序 partial」与「按需 seek 缓存」之间按字节
    // 动态切换数据源。彻底消除旧逻辑「从 seek 缓存服务一段后直接 break、HTTP 连接
    // 提前关闭」导致的「播放 1~2 秒后画面卡死、音频继续十几秒后崩溃」。
    await _streamRange(session, response, start, rangeEnd + 1, fileSize);
  }

  /// 连续服务整个请求区间 [rangeStart, endExclusive)，在「后台顺序下载的 partial」
  /// 与「按需随机读取的 seek 缓存」之间按字节位置动态切换数据源，彻底消除旧实现
  /// 「从 seek 缓存服务 16MB 后直接 break、HTTP 连接提前关闭」导致的「播放 1~2 秒
  /// 后画面卡死、音频继续十几秒后崩溃」。
  ///
  /// 设计要点：
  ///  - 当前位置已被后台 partial 覆盖 → 从 partial 读，并跟随后台下载进度
  ///    （未覆盖时等待本地落盘增长，不提前断开）。
  ///  - 当前位置尚未被 partial 覆盖 → 先确认 seek 缓存是否覆盖；未覆盖则按需经
  ///    seekClient 拉取下一段并并入 seek 缓存，再从 seek 缓存读。
  ///  - 拉取失败（seekClient 异常/返回 0 字节）时回落等待后台下载推进；后台推进后
  ///    自然切回 partial 分支，数据流永不无故中断。
  Future<void> _streamRange(
    _StreamSession session,
    HttpResponse response,
    int rangeStart,
    int endExclusive,
    int fileSize,
  ) async {
    const chunkSize = 4 * 1024 * 1024; // 4MB 读块
    int readOffset = rangeStart;
    RandomAccessFile? partialRaf;
    bool bootstrapped = false;
    try {
      while (readOffset < endExclusive) {
        if (session.disposed || session.downloadFailed) break;

        // 修复C（问题2）：用磁盘真实已落盘字节作可读水位，而非可能过期的
        // session.downloadedBytes（100ms 轮询延迟）。数据一落盘立即可读，消除
        // 「播放头紧跟下载头时因门控过期而周期性落入等待分支」的饥饿卡顿。
        int realLen = 0;
        try {
          final pf = File(session.partialPath);
          realLen = pf.existsSync() ? pf.lengthSync() : 0;
        } catch (_) {
          realLen = 0;
        }
        final downloaded = realLen > 0 ? realLen : session.downloadedBytes;
        final region = session._regionFor(readOffset);
        final seekCovers = region != null;

        // A) 后台顺序下载已覆盖当前位置 → 从 partial 读，跟随后台下载推进（主路径）
        // 优化：内循环连续读多个 chunk，每 4MB 批量 flush 一次。旧实现每 1MB 就
        // flush 并回到外循环顶部重新 stat 文件，频繁的 flush 和 stat 产生背压
        // 导致数据脉冲式供给（播放器周期性饥饿卡顿）。批量 flush 让数据更平滑
        // 地喂给播放器，贴合 WebDAV 直连的连续流式体验。
        if (readOffset < downloaded) {
          partialRaf ??= await File(session.partialPath).open(mode: FileMode.read);
          var raf = partialRaf; // 非null局部引用（??= 已提升类型），供内循环使用
          int pendingFlush = 0;
          const flushEvery = 4 * 1024 * 1024; // 每累积 4MB flush 一次
          while (readOffset < downloaded && readOffset < endExclusive) {
            final avail = downloaded.clamp(0, endExclusive);
            final toRead = (avail - readOffset).clamp(0, chunkSize).toInt();
            if (toRead <= 0) break;
            await raf.setPosition(readOffset);
            final data = await raf.read(toRead);
            if (data.isNotEmpty) {
              response.add(data);
              readOffset += data.length;
              pendingFlush += data.length;
              if (pendingFlush >= flushEvery) {
                await response.flush();
                pendingFlush = 0;
              }
              continue;
            }
            // 读到空数据但门控说有数据：读句柄可能指向被下载客户端「删除重建」
            // 的旧 inode（孤儿文件永远读到空）。关闭重开句柄指向新文件，
            // 并用真实延时让出事件循环，避免快速自旋。
            if (pendingFlush > 0) {
              await response.flush();
              pendingFlush = 0;
            }
            try {
              await raf.close();
            } catch (_) {}
            partialRaf = null;
            await Future.delayed(const Duration(milliseconds: 50));
            break;
          }
          // flush 残余未刷出的数据
          if (pendingFlush > 0) {
            await response.flush();
          }
          continue;
        }

        // B) 某段 seek 缓存覆盖当前位置 → 从对应缓存文件读（拖动缓冲 / 初始引导缓冲）。
        //    多段缓存使前进后再后退也能命中本地数据，不再重复远程抓取。
        if (seekCovers) {
          // ① 区域文件是【从 region.start 开始】的独立文件：其第 0 字节对应绝对
          //    偏移 region.start，故读位置必须是 (readOffset - region.start)。
          //    直接用绝对偏移会在（远小于该偏移的）区域文件上读到空数据，使
          //    seek 缓存形同虚设——拖动后必然穿透到下面的分支重新远程抓取。
          // ② 区域可能仍在后台填充，故上界取【磁盘真实已落盘长度】而非声明长度；
          //    数据未到时短暂等待、保持连续供给，而不是穿透下去造成断流。
          final availEnd = session._regionAvailableEnd(region);
          final segEnd = availEnd < region.end ? availEnd : region.end;
          final capped = segEnd < endExclusive ? segEnd : endExclusive;
          final toRead = (capped - readOffset).clamp(0, chunkSize).toInt();
          if (toRead > 0) {
            final raf = await session._seekRafFor(region.path);
            await raf.setPosition(readOffset - region.start);
            final data = await raf.read(toRead);
            if (data.isNotEmpty) {
              response.add(data);
              await response.flush();
              readOffset += data.length;
              continue;
            }
          }
          // 本段已读完、但后台填充仍在进行 → 等下一批落盘，保持连续供给。
          // 填充结束（或失败）后 _regionFilling 会移除该路径，届时自然落到下面分支。
          if (session._regionFilling[region.path] == true) {
            await Future.delayed(const Duration(milliseconds: 30));
            continue;
          }
          // 本段缓存读完且不再填充 → 重新评估（切回 partial 或再次按需拉取）
        }

        // C) 下载已完成且文件完整落盘 → 直接顺序服务剩余部分，不再轮询等待。
        //    v3 后数据一直留在 partialPath（不重命名），必须回退检查 partial，
        //    否则只查 localPath 会误判无数据而提前断流。
        if (session.downloadComplete) {
          File finalFile = File(session.localPath);
          bool srcOk = false;
          try {
            srcOk = finalFile.existsSync() && finalFile.lengthSync() > readOffset;
          } catch (_) {}
          if (!srcOk) {
            finalFile = File(session.partialPath);
            try {
              srcOk = finalFile.existsSync() && finalFile.lengthSync() > readOffset;
            } catch (_) {}
          }
          if (srcOk) {
            try {
              await partialRaf?.close();
            } catch (_) {}
            partialRaf = null;
            final raf = await finalFile.open(mode: FileMode.read);
            try {
              await raf.setPosition(readOffset);
              while (readOffset < endExclusive) {
                final toRead = (endExclusive - readOffset).clamp(0, chunkSize).toInt();
                final data = await raf.read(toRead);
                if (data.isEmpty) break;
                response.add(data);
                await response.flush();
                readOffset += data.length;
              }
            } finally {
              await raf.close();
            }
            break;
          }
          break;
        }

        // D) 真实「随机跳转」领先下载头（拖动到尚未下载到的位置）→ 按需经独立 seekClient 拉取
        final aheadBy = readOffset - downloaded;
        if (aheadBy > 1024 * 1024 && !seekCovers) {
          final fetchLen = (endExclusive - readOffset).clamp(1, 24 * 1024 * 1024).toInt();
          // 后台分块填充 + 只等首块落盘，不再 await 整段 24MB。旧实现在这里阻塞
          // 整段抓取，正是「拖动后卡在缓冲 / 拖动失效跳回原点」的直接原因。
          final avail = await _ensureRegionFilling(session, readOffset, fetchLen);
          if (avail > 0) {
            // 【关键修复】首块落盘后立即回到循环顶部，走 B 分支从 seek 缓存向播放器
            // 供数据。旧实现此处去等 partial（后台顺序下载）推进到 readOffset——
            // 大文件前跳需要数分钟，30s 超时后 break 关闭连接，播放器 seek 失败
            // 跳回原位置。现在区域已登记，由 B 分支 tail-follow 持续供给。
            continue;
          }
          // 拉取失败（0 字节）：短暂退避防自旋，再重试或等待下载推进。
          await Future.delayed(const Duration(milliseconds: 200));
          if (readOffset < session.downloadedBytes) continue;
          final grew = await _waitForLocalGrowth(session, readOffset, File(session.partialPath));
          if (!grew) break;
          continue;
        }

        // E) 启动引导：partial 仍为空时，先用独立 seekClient 拉前一段作为初始缓冲，
        //    使播放器立即拿到数据，避免等待首个分块下载完成才出画面（否则开局即卡）。
        //    注意：**只等首块落盘就开始供数**，剩余字节交给后台填充 + B 分支
        //    tail-follow 续供，不再阻塞等满 16MB（旧实现是起播慢的主因之一）。
        if (!bootstrapped && downloaded <= 0 && !seekCovers) {
          bootstrapped = true;
          final avail = await _ensureRegionFilling(session, readOffset, 16 * 1024 * 1024);
          if (avail > 0) {
            // 引导数据首块已落盘，立即 continue 走 B 分支供给播放器。
            continue;
          }
          if (readOffset < session.downloadedBytes) continue;
          final grew = await _waitForLocalGrowth(session, readOffset, File(session.partialPath));
          if (!grew) break;
          continue;
        }

        // F) 追平下载头（readOffset == downloaded）：代理按
        //    播放需求即时拉取，而非死等整文件顺序下载推进。
        //  ① 先给后台顺序下载 60ms 推进机会：快网/局域网下顺序下载速度通常远快于
        //     播放消费，几乎总能即时推进，此时走 A 分支读 partial（零额外开销、与
        //     旧行为一致），不引入无谓的随机读 JNI 往返。
        //  ② 若 60ms 内磁盘 partial 无新字节（慢速远程 / 顺序下载跟不上播放消费），
        //     立即经独立 seekClient 做真实服务端偏移随机读，拉「当前播放位置之后」一段
        //     直供播放器，而非干等——速度 = 原生随机读带宽(≈链路带宽)，彻底消除
        //     「缓冲耗尽 → 卡顿 → 缓冲 → 播放几帧」的循环。顺序下载仍后台跑作兜底。
        await Future.delayed(const Duration(milliseconds: 60));
        int lenNow = 0;
        try {
          final partialFile = File(session.partialPath);
          lenNow = partialFile.existsSync() ? partialFile.lengthSync() : 0;
        } catch (_) {
          lenNow = 0;
        }
        if (lenNow > readOffset) {
          // 顺序下载已推进，回到循环顶部走 A 分支从 partial 读
          session._syncFileLength();
          continue;
        }
        // 顺序下载短期无进展 → 主动按需随机读补「当前播放所需数据」。
        // 后台分块填充 + 只等首块落盘：旧实现每次补数据都阻塞一整段 24MB，期间
        // 一个字节都不发给播放器，这正是「播放中周期卡顿」的直接来源。
        final fetchLen = (endExclusive - readOffset).clamp(1, 24 * 1024 * 1024).toInt();
        final avail = await _ensureRegionFilling(session, readOffset, fetchLen);
        if (avail > 0) {
          // 立即 continue 走 B 分支从 seekcache 向播放器供数据（按需即供）
          continue;
        }
        // 按需拉取也失败（极端弱网）：短暂退避后重试，或退化为等待顺序下载推进。
        await Future.delayed(const Duration(milliseconds: 200));
        if (readOffset < session.downloadedBytes) continue;
        final grew = await _waitForLocalGrowth(session, readOffset, File(session.partialPath));
        if (!grew) break;
        continue;
      }
    } finally {
      try {
        await partialRaf?.close();
      } catch (_) {}
      try {
        await response.close();
      } catch (_) {}
    }
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

    await _streamFrom(session, response, session.partialPath, 0, -1, true);
  }

  /// Stream bytes [fileStart, endExclusive) from [filePath] to the response as
  /// they arrive. When [endExclusive] is -1, stream until download completes.
  ///
  /// [isPartial] indicates the source is the background-downloaded partial file
  /// (whose available length grows over time via [session.downloadedBytes]);
  /// when false, [filePath] is a complete on-demand seek temp file whose full
  /// length is available immediately.
  Future<void> _streamFrom(
    _StreamSession session,
    HttpResponse response,
    String filePath,
    int fileStart,
    int endExclusive,
    bool isPartial,
  ) async {
    const chunkSize = 256 * 1024; // 256KB read chunks
    final target = endExclusive < 0 ? 0x7FFFFFFFFFFFFFFF : endExclusive;

    // Wait for the source file to exist and have at least 1 byte.
    File readFile = File(filePath);
    bool fileReady = false;
    for (int i = 0; i < 300; i++) { // 300 * 200ms = 60s max
      if (session.disposed || session.downloadFailed) break;
      if (await readFile.exists()) {
        final len = readFile.lengthSync();
        if (len > 0) {
          fileReady = true;
          break;
        }
      }
      if (isPartial) {
        // 后台下载可能已完成并重命名为最终路径
        final finalFile = File(session.localPath);
        if (await finalFile.exists() && finalFile.lengthSync() > 0) {
          readFile = finalFile;
          fileReady = true;
          break;
        }
      }
      await Future.delayed(const Duration(milliseconds: 200));
    }

    if (!fileReady) {
      if (session.downloadFailed) {
        debugPrint('RemoteStreamingService: download failed, cannot stream');
      } else {
        debugPrint('RemoteStreamingService: source file never appeared');
      }
      try {
        await response.close();
      } catch (_) {}
      return;
    }

    late RandomAccessFile raf;
    try {
      raf = await readFile.open(mode: FileMode.read);
      await raf.setPosition(fileStart);
    } catch (e) {
      debugPrint('RemoteStreamingService: failed to open source file: $e');
      try {
        await response.close();
      } catch (_) {}
      return;
    }

    int readOffset = fileStart;
    bool hasRetried = false;

    try {
      while (readOffset < target) {
        if (session.disposed || session.downloadFailed) break;

        // 已可读取的字节数：partial 取自后台下载进度；seek 缓存文件取其实际长度
        final downloaded = isPartial
            ? session.downloadedBytes
            : readFile.lengthSync();
        if (downloaded <= readOffset) {
          if (isPartial && session.downloadComplete) {
            if (readOffset == fileStart) {
              final finalFile = File(session.localPath);
              if (await finalFile.exists()) {
                try {
                  await raf.close();
                } catch (_) {}
                raf = await finalFile.open(mode: FileMode.read);
                await raf.setPosition(readOffset);
                final len = await finalFile.length();
                if (len > readOffset) {
                  continue;
                }
              }
            }
            break;
          }
          if (!isPartial) break; // 临时 seek 文件已完整，无更多数据
          // 顺序下载尚未覆盖该位置：直接轮询本地文件长度（而非依赖进度信号），
          // 直到有新数据或下载失败/完成。放宽超时（30s）避免瞬时下载抖动就切断流——
          // 旧实现仅 ~2.4s（idleCount>12）就断开，任何下载突发停顿都会表现为
          // “播放几帧→暂停→播放几帧”的卡顿。WebDAV 直连服务器由 libmpv 原生处理
          // Range 因而流畅，代理必须更宽容地等待本地落盘字节。
          final grew = await _waitForLocalGrowth(session, readOffset, readFile);
          if (!grew) break;
          continue;
        }

        final available = downloaded.clamp(0, target);
        final toRead = (available - readOffset).clamp(0, chunkSize).toInt();
        if (toRead <= 0) {
          if (isPartial && session.downloadComplete) break;
          if (!isPartial) break;
          continue;
        }

        try {
          await raf.setPosition(readOffset);
          final data = await raf.read(toRead);
          if (data.isEmpty) {
            if (isPartial && session.downloadComplete) break;
            if (!isPartial) break;
            await Future.delayed(const Duration(milliseconds: 10));
            continue;
          }
          response.add(data);
          await response.flush();
          readOffset += data.length;
          hasRetried = false;
        } catch (e) {
          debugPrint('RemoteStreamingService: read error at $readOffset: $e');
          if (hasRetried) break;
          hasRetried = true;
          if (!isPartial) break;
          try {
            await raf.close();
          } catch (_) {}
          File reopenFile = File(session.partialPath);
          if (!await reopenFile.exists()) {
            reopenFile = File(session.localPath);
          }
          if (await reopenFile.exists()) {
            raf = await reopenFile.open(mode: FileMode.read);
            await raf.setPosition(readOffset);
            continue;
          }
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

  /// 轮询本地 partial 文件长度，直到 [readOffset] 之后出现新数据，或下载
  /// 失败/完成/超时（30s）。返回 true 表示有新数据可读，false 表示应结束流。
  ///
  /// 设计：直接读本地磁盘文件长度（而非依赖进度回调信号），给后台顺序下载
  /// 更宽容的等待窗口。旧实现仅 ~2.4s（idleCount>12）就断开流，任何下载
  /// 瞬时停顿都会表现为「播放几帧→暂停→播放几帧」。WebDAV 由 libmpv 直连
  /// 服务器原生处理 Range 因而流畅，本代理必须同样宽容地等待本地落盘字节。
  Future<bool> _waitForLocalGrowth(
    _StreamSession session,
    int readOffset,
    File readFile,
  ) async {
    const timeout = Duration(seconds: 30);
    final sw = Stopwatch()..start();
    while (sw.elapsed < timeout) {
      if (session.disposed || session.downloadFailed) return false;
      // 下载可能已完成。注意 v3 后数据一直留在 partialPath（本服务不重命名），
      // 必须同时检查 partial 与最终路径，否则会误判「无数据」提前断流。
      if (session.downloadComplete) {
        session._syncFileLength();
        try {
          final finalFile = File(session.localPath);
          if (finalFile.existsSync() && finalFile.lengthSync() > readOffset) {
            return true;
          }
          final partial = File(session.partialPath);
          if (partial.existsSync() && partial.lengthSync() > readOffset) {
            return true;
          }
        } catch (_) {}
        return false;
      }
      // 直接查本地磁盘：partial 已落盘字节数（比 100ms 轮询更即时）。
      // lengthSync 对瞬时不存在的文件会抛 FileSystemException（SMB 客户端
      // 启动时可能删除重建目标文件），必须容错，否则异常穿透断流。
      int len = 0;
      try {
        len = readFile.existsSync() ? readFile.lengthSync() : 0;
      } catch (_) {}
      if (len > readOffset) {
        // ★ 崩溃根因修复（ANR 死循环）★
        // 旧实现此处【同步立即 return true】：外层 _streamRange 的 while 循环
        // 「A 分支门控值 downloadedBytes 过期 → 落到 F → 本函数立即 true →
        // 再循环」全程只产生【微任务】，不含任何真实异步等待（计时器/IO 事件）。
        // Dart 事件循环规则是「微任务队列非空则永不处理事件队列」，于是
        // 100ms 的 _lengthPollTimer 永远得不到执行 → downloadedBytes 永远
        // 停留在旧值 → 死循环永不退出 → 主 isolate 被微任务榨干：UI 彻底
        // 冻结（画面卡住）、音频靠 libmpv 原生缓冲继续放十几秒、随后系统
        // ANR 杀进程（闪退）。内置播放与第三方播放器共用本代理，故都崩。
        // 修复：① 立即用磁盘真实长度刷新 downloadedBytes（A 分支马上可推进）；
        // ② 用真实计时器（Duration.zero 也走 Timer/事件队列）让出事件循环，
        //    彻底杜绝微任务垄断。
        session._syncFileLength();
        await Future.delayed(Duration.zero);
        return true;
      }
      // 修复C（问题2）：用「进度信号」替代纯轮询——后台下载每落盘一批
      // （_syncFileLength → _notifyProgress 完成 _progressSignal），本等待立即被
      // 唤醒，无需等下一个轮询周期，让播放头更紧密跟随后台下载，消除周期性饥饿。
      final signal = session._progressSignal;
      final woke = await Future.any<bool>([
        Future.delayed(const Duration(milliseconds: 100), () => false),
        if (signal != null)
          signal.future.then((_) => true)
        else
          Future<bool>.value(false),
      ]);
      if (woke) {
        // 被下载进度唤醒，立即回到循环顶部重新评估真实磁盘水位。
        continue;
      }
      // 否则 100ms 已耗尽，进入下一轮（重新查磁盘长度）。
    }
    // 30s 内本地仍无新字节（下载可能已停但状态未更新）——保守结束流，避免
    // 把播放器永远吊在「正在缓存」。播放器会按需再发 Range 请求重试。
    return false;
  }
}

class _SeekRegion {
  final int start;
  final int end;
  final String path;
  _SeekRegion(this.start, this.end, this.path);
}

class _StreamSession {
  final RemoteClient client;
  final RemoteClient? seekClient;
  final String remotePath;
  final String fileName;
  final HttpServer server;
  final DateTime createdAt;
  final int? knownFileSize;

  String? _localPath;
  Future<void>? _downloadFuture;
  bool _disposed = false;
  Timer? _lengthPollTimer;
  final _seekLock = _Mutex();

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

  /// 按需 seek 缓存区域文件（每段独立，[start] 作为唯一标识）。
  String _seekRegionPath(int start) => '$localPath.seekcache.$start';

  /// 是否存在覆盖 [off] 的 seek 缓存段。
  bool _seekCovers(int off) =>
      _seekRegions.any((r) => off >= r.start && off < r.end);

  /// 返回覆盖 [off] 的 seek 缓存段（列表中第一段命中者）。
  _SeekRegion? _regionFor(int off) {
    for (final r in _seekRegions) {
      if (off >= r.start && off < r.end) return r;
    }
    return null;
  }

  /// 记录一段新抓取的按需区域 [start, start+cachedLen)。先淘汰被其完全包含的旧段，
  /// 再追加；超过 [_maxSeekRegions] 时删除最旧段的文件。
  void _recordSeekRegion(int start, int cachedLen) {
    if (cachedLen <= 0) return;
    final end = start + cachedLen;
    _seekRegions.removeWhere((r) => r.start >= start && r.end <= end);
    _seekRegions.add(_SeekRegion(start, end, _seekRegionPath(start)));
    while (_seekRegions.length > _maxSeekRegions) {
      final removed = _seekRegions.removeAt(0);
      try {
        File(removed.path).delete();
      } catch (_) {}
    }
  }

  /// 取（或缓存）某段 seek 缓存文件的读句柄。
  Future<RandomAccessFile> _seekRafFor(String path) async {
    var raf = _seekRafCache[path];
    if (raf == null) {
      raf = await File(path).open(mode: FileMode.read);
      _seekRafCache[path] = raf;
    }
    return raf;
  }

  // ── 按需区域的后台填充（边下边播）────────────────────────────────────────
  //
  // 背景：旧实现在响应任何字节之前，先 await 一整段（最多 24MB）远程随机读，
  // 完成后才设置 206 响应头并 flush。对 SFTP/SMB/FTP 而言，拖动后要等数秒才
  // 等到第一个字节，libmpv 超时判定 seek 失败 → 进度条跳回原点。
  //
  // 新实现：远程读取放到后台【分块】填充，直接顺序写入该区域的缓存文件；请求
  // 路径只等首个小块落盘就立刻回 206 并开始供数，剩余字节由 _streamRange 分支
  // B 按磁盘真实长度 tail-follow 持续供给（与后台顺序下载的 partial 同理）。

  /// 后台填充的单块大小。分块的意义：每块之间会释放 [_seekLock]，使用户中途
  /// 再次拖动产生的新随机读可以插队，而不会被一次长填充整体阻塞。
  static const int _fillChunkBytes = 2 * 1024 * 1024;

  /// 正在后台填充的区域文件路径，防止同一区域被并发重复填充（并发 append 写坏文件）。
  final Map<String, bool> _regionFilling = {};

  /// 区域 [r] 当前【真实已落盘】的绝对结束偏移（exclusive）。
  /// 区域文件自 [r.start] 起顺序写入，故「已落盘字节数 = 文件长度」。
  int _regionAvailableEnd(_SeekRegion r) {
    try {
      final f = File(r.path);
      return r.start + (f.existsSync() ? f.lengthSync() : 0);
    } catch (_) {
      return r.start;
    }
  }

  /// 确保存在覆盖 [start, start+targetLen) 的区域声明。
  /// 若已有同起点区域但声明过短，则就地延长——**绝不删除文件**，已落盘字节保留。
  void _ensureRegionDeclared(int start, int targetLen) {
    final end = start + targetLen;
    final existing = _regionFor(start);
    if (existing != null && existing.start == start) {
      if (existing.end >= end) return;
      _seekRegions.remove(existing);
      _seekRegions.add(_SeekRegion(start, end, existing.path));
      return;
    }
    _recordSeekRegion(start, targetLen);
  }

  /// 启动（或复用）[start] 起、长度 [targetLen] 的后台分块填充。幂等。
  Future<void> _startRegionFill(int start, int targetLen) async {
    final path = _seekRegionPath(start);
    if (_regionFilling[path] == true) return;

    final existing = _regionFor(start);
    if (existing != null && _regionAvailableEnd(existing) >= start + targetLen) {
      return; // 已填满
    }

    _regionFilling[path] = true;
    // 立即登记整段目标区间。注意「声明长度」会大于「已落盘长度」，这是安全的：
    // 分支 B 一律按磁盘真实长度（_regionAvailableEnd）门控，读不到就等待填充推进。
    _ensureRegionDeclared(start, targetLen);

    final tmp = '$path.filltmp';
    try {
      var off = start;
      final end = start + targetLen;
      while (off < end) {
        if (_disposed || _downloadFailed) break;
        // 区域被淘汰（被更新的拖动顶掉）→ 停止填充，避免写到已删除的文件
        if (_regionFor(start)?.path != path) break;
        // 后台顺序下载已追平此处 → partial 是更好的数据源，无需继续填充
        if (off < downloadedBytes) break;
        final want = _fillChunkBytes < (end - off) ? _fillChunkBytes : (end - off);
        final got = await _fetchRangeChunk(this, off, want, tmp);
        if (got <= 0) break;
        final appended = await _appendFileToFile(tmp, path);
        if (appended <= 0) break;
        off += appended;
      }
    } catch (e) {
      debugPrint('RemoteStreamingService: region fill error: $e');
    } finally {
      try {
        final f = File(tmp);
        if (f.existsSync()) f.deleteSync();
      } catch (_) {}
      _regionFilling.remove(path);
    }
  }

  /// 把 [srcPath] 的内容以 256KB 分块追加到 [dstPath] 末尾，返回追加字节数。
  /// 分块而非一次性 readAsBytes，避免大块数据一次性进内存阻塞事件循环。
  Future<int> _appendFileToFile(String srcPath, String dstPath) async {
    try {
      final src = File(srcPath);
      if (!await src.exists()) return 0;
      final total = await src.length();
      if (total <= 0) return 0;
      final out = await File(dstPath).open(mode: FileMode.append);
      final input = await src.open(mode: FileMode.read);
      var written = 0;
      try {
        const block = 256 * 1024;
        while (written < total) {
          final toRead = (total - written) < block ? (total - written) : block;
          final data = await input.read(toRead);
          if (data.isEmpty) break;
          await out.writeFrom(data);
          written += data.length;
        }
      } finally {
        await input.close();
        await out.flush();
        await out.close();
      }
      return written;
    } catch (e) {
      debugPrint('RemoteStreamingService: append fill chunk failed: $e');
      return 0;
    }
  }

  _StreamSession({
    required this.client,
    required this.remotePath,
    required this.fileName,
    required this.server,
    this.knownFileSize,
    this.seekClient,
  }) : createdAt = DateTime.now();

  String get localPath {
    _localPath ??= _getLocalTempPath();
    return _localPath!;
  }

  String get partialPath => '$localPath.partial';

  /// Per-session seek cache file. On-demand random reads (from dragging the
  /// progress bar) are written here at their real byte offset, so subsequent
  /// requests for the same/overlapping region are served from local disk
  /// instead of triggering another remote read. Kept separate from the
  /// background `.partial` file to avoid sparse-file gaps and writer races.
  String get seekCachePath => '$localPath.seekcache';

  /// 多段按需 seek 缓存区域（MRU，最多 [_maxSeekRegions] 段）。每次拖动抓取一段
  /// 远程字节，存入独立文件（[seekCachePath].[start]），使前进后再后退也能命中
  /// 本地数据、不再重复远程抓取。每段是完整独立文件，彻底避免单文件任意偏移写入
  /// 可能产生的稀疏空洞（v2 O_APPEND 错位回归的根因）。
  final List<_SeekRegion> _seekRegions = [];
  static const int _maxSeekRegions = 4;
  /// 按路径缓存的 seek 缓存读句柄，避免每段每次读都重新 open。
  final Map<String, RandomAccessFile> _seekRafCache = {};

  // reseed 机制已移除：后台下载严格从 0 顺序写入 partial，绝不乱序偏移写入，
  // 避免 partial 出现稀疏空洞导致 _streamFrom 读取全 0 字节喂给播放器崩溃。
  // 所有 seek（moov / 拖动）由按需 seekClient → seekCache 提供。

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
    // 修复C（问题2）：轮询间隔 100ms→50ms，降低水位感知延迟，代价极小。
    _lengthPollTimer = Timer.periodic(const Duration(milliseconds: 50), (_) {
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
    // 跳过大文件 stat：直接用 knownFileSize（来自文件列表元数据）或 -1。
    // 未知大小时不阻塞，改为逐块下载时通过「实际返回量 < 请求量」探测 EOF。
    if (knownFileSize != null && knownFileSize! > 0) {
      _totalBytes = knownFileSize!;
      debugPrint('RemoteStreamingService: using knownFileSize=$_totalBytes');
    } else {
      _totalBytes = -1;
      debugPrint('RemoteStreamingService: unknown size, will detect EOF per chunk');
    }
    if (!_sizeCompleter.isCompleted) {
      _sizeCompleter.complete(_totalBytes);
    }

    // 准备 .partial 文件
    final partial = File(partialPath);
    if (!await partial.parent.exists()) {
      await partial.parent.create(recursive: true);
    }
    if (await partial.exists()) {
      await partial.delete();
    }

    // 预创建空 .partial 文件：避免 _streamRange 在 downloadFile 落盘前打开读
    // 句柄时因文件不存在而抛异常（进而提前关闭 HTTP 响应 → 卡顿）。
    try {
      await partial.create();
    } catch (_) {}

    // 关键修复（v3）：改用 client.downloadFile() 把整个远程文件顺序下载到
    // partialPath，再由代理从「不断增长的 partial 文件」流式服务给播放器。
    //
    // 为何不用旧的分块 downloadRange 循环：
    // 旧实现逐块调用 client.downloadRange(remotePath, temp, pos, length)，而
    // downloadRange 在三个客户端上【第二块（pos>0）必然失败】——
    //   · 原生 SFTP（JSch）：downloadRange 用 ch.get(remotePath) 从文件头读 +
    //     InputStream.skip(startByte) 跳转偏移，但 JSch 的 SFTP 输入流 skip
    //     不可靠（常一次跳不足或返回 0），pos>0 区间取到错误/0 字节；
    //   · smbj / FTP 在共享会话上并发区间读易异常。
    // 于是第二块 actual<=0 → 重试 3 次 → downloadFailed=true → _streamRange
    // 断流 → 画面播几秒后冻结、音频缓冲耗尽崩溃。WebDAV 直连不经代理故正常。
    //
    // downloadFile() 是 App 内「保存远程文件」共用的可靠通道：SFTP 原生走 JSch
    // get 顺序流式落盘、FTP 走 raw socket 32KB 块刷盘、SMB 走原生顺序写，均
    // 「边下边落盘」——partial 文件长度即真实已下载字节，代理从此只读增长的
    // partial，彻底绕开 downloadRange(pos>0) 的脆弱性。
    try {
      // 进度回调节流：existsSync+lengthSync 是【同步 IO】，而 FTP 下载每 64KB
      // chunk 回调一次（20MB/s ≈ 320 次/s），逐次 stat 会同步阻塞主 isolate
      // 数百 ms/s，下载/推流/UI 同挤一个事件循环互相争抢 → 播放器数据供给
      // 脉冲化卡顿（WebDAV 直连无此层故同带宽流畅）。≥100ms 节流后同步开销
      // 降为 10 次/s，事件循环延迟消除；_notifyProgress 轻量仍每次发送。
      var lastStat = DateTime.fromMillisecondsSinceEpoch(0);
      await client.downloadFile(
        remotePath,
        partialPath,
        (progress) {
          final now = DateTime.now();
          if (now.difference(lastStat).inMilliseconds >= 100) {
            lastStat = now;
            _syncFileLength();
          }
          _notifyProgress();
        },
      );
      if (_disposed) return;
      _downloadComplete = true;
      _syncFileLength();
      _notifyProgress();
      debugPrint('RemoteStreamingService: download complete, totalBytes=$_totalBytes downloaded=$_downloadedBytes');
    } catch (e) {
      if (_disposed) return;
      debugPrint('RemoteStreamingService: downloadFile failed: $e');
      _downloadFailed = true;
      _syncFileLength();
      _notifyProgress();
    }
  }

  String _getLocalTempPath() {
    try {
      final dir = Directory('/storage/emulated/0/ZenFile/cache/streaming');
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
    // 尝试取消下载：先 cancel() 置取消标志（原生通道据此提前结束传输），
    // 再 disconnect() 中断底层连接。这是关键修复：之前 dispose 不取消下载，
    // 导致退出播放器后 SFTP/FTP/SMB 下载在后台继续运行，占用网络带宽和 CPU。
    try {
      client.cancel();
    } catch (e) {
      debugPrint('RemoteStreamingService: dispose cancel error: $e');
    }
    try {
      await client.disconnect();
    } catch (e) {
      debugPrint('RemoteStreamingService: dispose disconnect error: $e');
    }
    // 断开独立的 seek 连接（用于按需随机读取）。注意：这里断开的是流式代理
    // 自己持有的独立连接，不会影响到远程浏览页（explorer）自身的会话。
    final sc = seekClient;
    if (sc != null) {
      try {
        await sc.disconnect();
      } catch (e) {
        debugPrint('RemoteStreamingService: dispose seekClient disconnect error: $e');
      }
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
        // 删除全部按需 seek 缓存段文件（每段独立）
        for (final r in _seekRegions) {
          try {
            await File(r.path).delete();
          } catch (_) {}
          // 后台填充的临时分块文件。正常由填充自身的 finally 清理，
          // 会话销毁时这里再做一次兜底，避免残留。
          try {
            final t = File('${r.path}.filltmp');
            if (await t.exists()) await t.delete();
          } catch (_) {}
        }
      }
    } catch (_) {}
    // 关闭 seek 缓存段的读句柄，避免文件描述符泄漏
    for (final raf in _seekRafCache.values) {
      try {
        await raf.close();
      } catch (_) {}
    }
  }
}
