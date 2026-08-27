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

/// Fetch [start, start+length) from the remote server via [session.seekClient]
/// (random read) and write it to [tempSeekPath].
///
/// Runs serialized via [session._seekLock] so concurrent HTTP range requests
/// never issue overlapping random reads on the same server session. The data is
/// copied in small blocks (never loaded fully into memory) so seeking near the
/// end of a huge file is safe. The fetched bytes are served directly from this
/// temp file — they are NOT merged into the background-downloaded partial file,
/// which avoids creating sparse-file gaps (zeros) that the player could read.
Future<void> _fetchRangeToFile(
  _StreamSession session,
  int start,
  int length,
  String tempSeekPath,
) async {
  final seekClient = session.seekClient;
  if (seekClient == null || length <= 0) return;
  if (start < 0) return;

  final sc = seekClient; // 非 null 绑定，供闭包内使用（避免闭包内可空收窄失效）
  await session._seekLock.run(() async {
    // 重新检查：后台顺序下载或本会话 seek 缓存可能已覆盖该区间，避免重复远程读取
    if (start < session.downloadedBytes) return;
    if (start >= session._mergedStart && start < session._mergedEnd) return;

    try {
      await sc.downloadRange(session.remotePath, tempSeekPath, start, length);
      final src = File(tempSeekPath);
      if (!await src.exists()) {
        debugPrint('RemoteStreamingService: on-demand range file not created');
      }
    } catch (e) {
      debugPrint('RemoteStreamingService: on-demand range fetch failed: $e');
    }
  });
}

/// Merge the on-demand range bytes in [tempPath] into the session's seek cache
/// file [session.seekCachePath] at the real byte offset [start]. Returns the
/// number of bytes merged (so the caller can remember the cached range).
///
/// Keeping fetched ranges in a persistent per-session cache (instead of a
/// throwaway temp file) is what makes seeking smooth: the next request for the
/// same region — and libmpv routinely re-requests overlapping ranges right
/// after a drag — is served from local disk, not from another remote read.
///
/// The cache file is written in [FileMode.append] so existing bytes are
/// preserved (no truncation) and the write lands at the exact offset.
/// 把 [tempPath] 的内容以 [start] 偏移写入 [targetPath]（不截断已有内容）。
///
/// 关键点：用 append 模式打开后再 [FileRandomAccessFile.setPosition]，可在
/// 任意偏移写入而不破坏其它位置已有字节——这正是把「按需随机读」与「后台分块
/// 下载」各自落盘的数据拼回同一 `.partial` / `.seekcache` 的正确方式（write
/// 模式会清空整文件，append 模式才不会）。
/// 把 [tempPath] 的内容以 [start] 偏移写入 [targetPath]（不截断已有内容）。
///
/// 关键点：用 append 模式打开后再 [FileRandomAccessFile.setPosition]，可在
/// 任意偏移写入而不破坏其它位置已有字节——这正是把「按需随机读」与「后台分块
/// 下载」各自落盘的数据拼回同一 `.partial` / `.seekcache` 的正确方式（write
/// 模式会清空整文件，append 模式才不会）。
///
/// 重要：改为**分块流式拷贝**（64KB/块），不再用 [File.readAsBytes] 一次性把
/// 整段（后台块 16MB、按需 seek 最多 64MB）载入内存。旧实现会把 16~64MB 一次性
/// 读进 RAM 再整体写回，在主 isolate 上造成 100~300ms 的同步阻塞——这正是
/// 退出播放器后整个浏览页（甚至本地浏览页）卡死/崩溃的根因。分块拷贝每次只
/// 处理 64KB，且每个 await 之间事件循环可响应 UI，彻底消除主线程长阻塞。
/// [isCancelled] 允许在拷贝中途（如 dispose 已触发）立即中止，避免无谓的 IO。
/// 把 [tempPath] 的内容按 [start] 偏移写入【已打开的】[raf]。
///
/// 关键修复（v2 回归）：早期实现用 `FileMode.append` 打开目标文件再
/// `setPosition(start)` 写入，但在 Linux/Android（O_APPEND）上，append 模式的
/// 写操作【始终追加到文件末尾】，setPosition 对写无效。于是当 [start] 不是文件
/// 末尾（例如拖动进度条后的随机偏移、或 reseed 跳到播放头）时，数据被写错位置，
/// partial / seekcache 出现错位脏数据，播放器读到乱码 → 「播放一两秒后卡死闪退」。
///
/// 正确做法：由调用方持有【以 `FileMode.write` 打开、会话级持久】的 RandomAccessFile
/// 句柄（write 模式非 O_APPEND，setPosition 对写生效），本函数【自己不开关文件】，
/// 只在给定句柄的精确偏移处写入。无论顺序下载还是随机 seek 写入，落盘偏移都精确
/// 等于 [start]，彻底消除错位。
Future<int> _spliceIntoFile(
  RandomAccessFile raf,
  String tempPath,
  int start, {
  bool Function()? isCancelled,
}) async {
  final temp = File(tempPath);
  if (!await temp.exists()) return 0;
  final length = await temp.length();
  if (length <= 0) return 0;
    var remaining = length;
    try {
      await raf.setPosition(start);
      final inFile = await temp.open(mode: FileMode.read);
      try {
        const block = 64 * 1024;
        while (remaining > 0) {
        if (isCancelled?.call() == true) break;
        final toRead = remaining > block ? block : remaining;
        final data = await inFile.read(toRead);
        if (data.isEmpty) break;
        await raf.writeFrom(data);
        remaining -= data.length;
      }
    } finally {
      await inFile.close();
    }
    return length - remaining;
  } catch (e) {
    debugPrint('RemoteStreamingService: splice error: $e');
    return 0;
  }
}

Future<int> _spliceIntoSeekCache(
  _StreamSession session,
  String tempPath,
  int start,
) async {
  final raf = await session._seekCacheWriteHandle();
  return _spliceIntoFile(
    raf,
    tempPath,
    start,
    isCancelled: () => session.disposed,
  );
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

    // 会话级 seek 缓存覆盖的连续区间 [_mergedStart, _mergedEnd)。
    final seekStart = session._mergedStart;
    final seekEnd = session._mergedEnd;
    final seekCoversStart = seekEnd > 0 && start >= seekStart && start < seekEnd;

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
    //     门控（isPartial=false），不再被后台停滞进度饿死
    //  3) 两者都未覆盖 → 按需远程随机读，并入 seekcache 后再从本地读
    String readFilePath;
    int readFileStart;
    int rangeStart;
    int rangeEnd;
    bool isPartial;

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
      readFilePath = session.partialPath;
      readFileStart = start;
      rangeStart = start;
      rangeEnd = clampedEnd;
      isPartial = true;
    } else if (seekCoversStart) {
      // 后台未覆盖，但 seek 缓存已覆盖：从 seekcache 读真实长度（不门控后台进度）
      readFilePath = session.seekCachePath;
      readFileStart = start;
      rangeStart = start;
      rangeEnd = clampedEnd < seekEnd - 1 ? clampedEnd : seekEnd - 1;
      isPartial = false;
    } else {
      // 需要按需远程随机读取（拖动到尚未下载到的位置）
      const seekChunk = 16 * 1024 * 1024; // 单次预取上限：拖动后 1~2s 内即可恢复播放，
      // 过大（如 64MB）会让拖动后长时间停在“正在缓存”而被误判为“拖动失效”。
      final fetchLen = (fileSize - start).clamp(1, seekChunk);
      final tempSeek = '${session.localPath}.seek.tmp';
      await _fetchRangeToFile(session, start, fetchLen, tempSeek);
      // 将远程读取结果合并进本地 seek 缓存（按偏移写入 .seekcache），之后复用
      final cachedLen = await _spliceIntoSeekCache(session, tempSeek, start);
      try {
        await File(tempSeek).delete();
      } catch (_) {}
      if (cachedLen <= 0) {
        // 远程抓取失败：降级为读 partial 并等待后台下载（不夸大 Content-Length）
        readFilePath = session.partialPath;
        readFileStart = start;
        rangeStart = start;
        rangeEnd = clampedEnd;
        isPartial = true;
      } else {
        // 只记录【本次按需抓取】的精确区间 [start, start+cachedLen)，不取并集。
        // 取并集会把两次不相邻的抓取（如 moov 在文件尾 + 拖动到文件头）合并成
        // 一个大区间，中间的稀疏空洞（全 0）会被 seekCoversStart 误判为命中，
        // 导致 _streamFrom 读到全 0 字节喂给 libmpv → 视频冻结/崩溃。
        // 覆盖式记录虽会令跨区间重复请求重新抓取，但绝不会把空洞当命中，安全。
        session._mergedStart = start;
        session._mergedEnd = start + cachedLen;
        readFilePath = session.seekCachePath;
        readFileStart = start;
        rangeStart = start;
        // 仅声明已真正抓取到的字节，避免 Content-Length 夸大导致播放器空等
        rangeEnd = clampedEnd < session._mergedEnd - 1 ? clampedEnd : session._mergedEnd - 1;
        isPartial = false;
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
    RandomAccessFile? seekRaf;
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
        final seekStart = session._mergedStart;
        final seekEnd = session._mergedEnd;
        final seekCovers = seekEnd > 0 && readOffset >= seekStart && readOffset < seekEnd;

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

        // B) seek 缓存覆盖当前位置 → 从本地 seekcache 读（拖动缓冲 / 初始 16MB 引导缓冲）
        if (seekCovers) {
          seekRaf ??= await File(session.seekCachePath).open(mode: FileMode.read);
          final segEnd = seekEnd.clamp(readOffset, endExclusive);
          final toRead = (segEnd - readOffset).clamp(0, chunkSize).toInt();
          if (toRead > 0) {
            await seekRaf.setPosition(readOffset);
            final data = await seekRaf.read(toRead);
            if (data.isNotEmpty) {
              response.add(data);
              await response.flush();
              readOffset += data.length;
              continue;
            }
          }
          // 本段缓存读完 → 重新评估（切回 partial 或再次按需拉取）
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
            try {
              await seekRaf?.close();
            } catch (_) {}
            partialRaf = null;
            seekRaf = null;
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
          final fetchLen = (endExclusive - readOffset).clamp(1, 16 * 1024 * 1024).toInt();
          final tempSeek = '${session.localPath}.seek.tmp';
          await _fetchRangeToFile(session, readOffset, fetchLen, tempSeek);
          final cachedLen = await _spliceIntoSeekCache(session, tempSeek, readOffset);
          try {
            await File(tempSeek).delete();
          } catch (_) {}
          if (cachedLen > 0) {
            session._mergedStart = readOffset;
            session._mergedEnd = readOffset + cachedLen;
            // 【关键修复】按需拉取成功后立即 continue 回到循环顶部，走 B 分支从
            // seekcache 向播放器供数据。旧实现此处去等 partial（后台顺序下载）推进到
            // readOffset——大文件前跳需要数分钟，30s 超时后 break 关闭连接，播放器
            // seek 失败跳回原位置。seekcache 已有数据，无需等待顺序下载。
            continue;
          }
          // 拉取失败（0 字节）：短暂退避防自旋，再重试或等待下载推进。
          await Future.delayed(const Duration(milliseconds: 200));
          if (readOffset < session.downloadedBytes) continue;
          final grew = await _waitForLocalGrowth(session, readOffset, File(session.partialPath));
          if (!grew) break;
          continue;
        }

        // E) 启动引导：partial 仍为空时，先用独立 seekClient 拉前 32MB 作为初始缓冲，
        //    使播放器立即拿到充足数据，避免等待首个分块下载完成才出画面（否则开局即卡）。
        if (!bootstrapped && downloaded <= 0 && !seekCovers) {
          bootstrapped = true;
          final tempSeek = '${session.localPath}.seek.tmp';
          await _fetchRangeToFile(session, readOffset, 32 * 1024 * 1024, tempSeek);
          final cachedLen = await _spliceIntoSeekCache(session, tempSeek, readOffset);
          try {
            await File(tempSeek).delete();
          } catch (_) {}
          if (cachedLen > 0) {
            session._mergedStart = readOffset;
            session._mergedEnd = readOffset + cachedLen;
            // 引导数据已入 seekcache，立即 continue 走 B 分支供给播放器。
            continue;
          }
          if (readOffset < session.downloadedBytes) continue;
          final grew = await _waitForLocalGrowth(session, readOffset, File(session.partialPath));
          if (!grew) break;
          continue;
        }

        // F) 追平下载头（readOffset == downloaded）：OWL 模型的关键一步——代理按
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
        // 顺序下载短期无进展 → 主动按需随机读补「当前播放所需数据」
        final fetchLen = (endExclusive - readOffset).clamp(1, 16 * 1024 * 1024).toInt();
        final tempSeek = '${session.localPath}.seek.tmp';
        await _fetchRangeToFile(session, readOffset, fetchLen, tempSeek);
        final cachedLen = await _spliceIntoSeekCache(session, tempSeek, readOffset);
        try {
          await File(tempSeek).delete();
        } catch (_) {}
        if (cachedLen > 0) {
          session._mergedStart = readOffset;
          session._mergedEnd = readOffset + cachedLen;
          // 立即 continue 走 B 分支从 seekcache 向播放器供数据（OWL：按需即供）
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
        await seekRaf?.close();
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

  // 会话级持久写句柄：以 FileMode.write 打开（非 O_APPEND），
  // setPosition 对写生效，彻底消除 O_APPEND 下写入偏移被强制到文件末尾
  // 导致的错位（这是「播放一两秒后卡死闪退」v2 回归的根因）。
  RandomAccessFile? _partialRaf;
  RandomAccessFile? _seekCacheRaf;

  Future<RandomAccessFile> _partialWriteHandle() async {
    _partialRaf ??= await File(partialPath).open(mode: FileMode.write);
    return _partialRaf!;
  }

  Future<RandomAccessFile> _seekCacheWriteHandle() async {
    _seekCacheRaf ??= await File(seekCachePath).open(mode: FileMode.write);
    return _seekCacheRaf!;
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

  /// [start, end) of the byte range currently held in [seekCachePath].
  /// -1 means no region is cached yet. Used to short-circuit repeat seeks.
  int _mergedStart = -1;
  int _mergedEnd = -1;

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
        final s = File('$_localPath.seekcache');
        if (await s.exists()) await s.delete();
      }
    } catch (_) {}
    // 关闭会话级持久写句柄，避免文件描述符泄漏
    try {
      await _partialRaf?.close();
    } catch (_) {}
    try {
      await _seekCacheRaf?.close();
    } catch (_) {}
  }
}
