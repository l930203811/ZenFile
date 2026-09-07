
import 'dart:async';
import 'dart:io';

class RemoteFileItem {
  final String name;
  final String path;
  final bool isDirectory;
  final int size;
  final DateTime modified;

  RemoteFileItem({
    required this.name,
    required this.path,
    required this.isDirectory,
    required this.size,
    required this.modified,
  });

  String get formattedSize {
    if (isDirectory) return '';
    if (size <= 0) return '0 B';
    const suffixes = ['B', 'KB', 'MB', 'GB', 'TB'];
    var i = 0;
    var doubleSize = size.toDouble();
    while (doubleSize >= 1024 && i < suffixes.length - 1) {
      doubleSize /= 1024;
      i++;
    }
    return '${doubleSize.toStringAsFixed(1)} ${suffixes[i]}';
  }
}

abstract class RemoteClient {
  Future<void> connect();
  Future<void> disconnect();
  Future<List<RemoteFileItem>> listDirectory(String path, {bool forceRefresh = false});
  Future<void> createDirectory(String path);
  Future<void> createFile(String path);
  Future<void> delete(String path, bool isDir);
  Future<void> rename(String oldPath, String newPath);
  Future<void> downloadFile(String remotePath, String localPath, Function(double progress) onProgress);

  /// 下载远程文件的指定字节范围到本地文件，用于生成缩略图等只需文件头部的场景。
  /// [startByte] 起始字节偏移（inclusive），[length] 要下载的字节数。
  /// 下载结果写入 localPath（只包含请求范围内的字节）。
  Future<void> downloadRange(String remotePath, String localPath, int startByte, int length);
  Future<void> uploadFile(String localPath, String remotePath, Function(double progress) onProgress);

  /// Returns a URL that can be used for streaming playback, or null if streaming is not supported.
  /// Currently only WebDAV supports this (returns HTTP URL with Basic Auth).
  /// Returns null when the file requires the local proxy (e.g. OpenList 302 redirect mode).
  Future<String?> getStreamUrl(String remotePath);

  /// Returns the file size in bytes, or -1 if unknown.
  /// Used by RemoteStreamingService for progressive streaming support.
  Future<int> getFileSize(String remotePath);

  // 取消令牌：设置为 true 时，进行中的 downloadFile/uploadFile 应尽快退出
  bool _cancelled = false;
  bool get isCancelled => _cancelled;
  void cancel() {
    _cancelled = true;
  }
  void resetCancel() {
    _cancelled = false;
  }

  /// 上传完成后最终化：部分服务端（飞牛 NAS、openlist 等）在传输期间把数据写入
  /// 临时文件（如 `file-<数字>`），传输结束后才重命名为目标文件。
  ///
  /// 默认实现：列出目录，若存在完整临时文件且目标文件不存在，则主动 rename。
  /// 子类可覆盖以实现更精确的检测逻辑（如 FTP 的 [FtpRemoteClient]）。
  ///
  /// 返回值：目标文件是否已最终化（存在、无临时文件、大小达标）。
  Future<bool> finalizeUpload(String remoteDir, String targetName, int expectedSize) async {
    return true; // 默认实现：不做任何检测，视为已最终化
  }

  // ── 按需区间随机读（用于 HttpRangeProxyService 流式播放） ────────────────

  /// 是否支持「从任意偏移读取指定长度」的随机读。
  ///
  /// 为 true 时流式播放走 `HttpRangeProxyService`：播放器请求哪个区间就取哪个
  /// 区间（206 + Content-Range），开播只等首段缓冲、拖动进度条即时响应，
  /// **不需要**先把整个文件下载完。
  ///
  /// 为 false 时退回 `RemoteStreamingService`（整文件顺序下载到 .partial 再供流）。
  ///
  /// 现状：WebDAV（HTTP Range）、FTP（REST）、SFTP（JSch 服务端偏移读）、
  /// SMB（smbj skip，仅更新 readOffset）均支持；SAF 不支持。
  bool get supportsRangeRead => false;

  /// 按播放器给出的**原始 Range 头**取流。
  ///
  /// 默认实现走 [downloadRange]（写入临时文件后以流的形式返回），
  /// HTTP 系协议（WebDAV）会覆盖为原样透传，避免多余的本地落盘。
  ///
  /// [maxChunk] 单次最多取多少字节：播放器常发开放式 Range（`bytes=0-`），
  /// 若照单全收就等于把整个文件下完——这里截断成一个块，播放器读完会自然
  /// 发起下一段请求，从而实现渐进式流式播放。
  Future<RemoteRangeResponse> openRangeResponse(
    String remotePath,
    String? rangeHeader, {
    required String tempDir,
    int maxChunk = 4 * 1024 * 1024,
    int? fileSize,
  }) async {
    final wanted = _parseRangeHeader(rangeHeader);
    final start = wanted.start;
    var total = fileSize ?? -1;
    if (total <= 0) {
      try {
        total = await getFileSize(remotePath).timeout(const Duration(seconds: 8));
      } catch (_) {
        total = -1;
      }
    }

    if (total > 0 && start >= total) {
      return RemoteRangeResponse(
        statusCode: HttpStatus.requestedRangeNotSatisfiable,
        headers: {'content-range': 'bytes */$total'},
        stream: const Stream.empty(),
      );
    }

    int length;
    if (total > 0) {
      final remaining = total - start;
      length = wanted.end != null
          ? (wanted.end! - start + 1).clamp(0, remaining)
          : remaining;
    } else {
      length = wanted.end != null ? (wanted.end! - start + 1) : maxChunk;
    }
    if (length <= 0) length = maxChunk;
    if (length > maxChunk) length = maxChunk;

    final tmp = '$tempDir/r_${DateTime.now().microsecondsSinceEpoch}_$start.bin';
    await downloadRange(remotePath, tmp, start, length);

    // total>0 时返回 206 + Content-Range（真流式、可 seek）；
    // total<=0（getFileSize 失败）时不撒谎成 206，改返回 200 且不加
    // Content-Length —— dart:io 会走分块编码，播放器读完本段会自然发起下
    // 一段 Range 请求，从而渐进播放（虽不可 seek，但至少不会把整文件下完）。
    final headers = <String, String>{};
    int statusCode;
    if (total > 0) {
      headers['content-length'] = '$length';
      headers['content-range'] = 'bytes $start-${start + length - 1}/$total';
      headers['accept-ranges'] = 'bytes';
      statusCode = HttpStatus.partialContent;
    } else {
      statusCode = HttpStatus.ok;
    }
    return RemoteRangeResponse(
      statusCode: statusCode,
      headers: headers,
      stream: File(tmp).openRead(),
      tempFilePath: tmp,
    );
  }
}

/// 解析后的 Range 请求。
class _ParsedRange {
  final int start;
  final int? end; // null = 开放式（到文件尾）
  _ParsedRange(this.start, this.end);
}

/// 解析 `bytes=start-end` / `bytes=start-` / `bytes=-suffixLength`。
_ParsedRange _parseRangeHeader(String? header) {
  if (header == null) return _ParsedRange(0, null);
  final v = header.trim().toLowerCase();
  const prefix = 'bytes=';
  if (!v.startsWith(prefix)) return _ParsedRange(0, null);
  final spec = v.substring(prefix.length).split(',').first.trim();
  final dash = spec.indexOf('-');
  if (dash < 0) return _ParsedRange(0, null);
  final first = int.tryParse(spec.substring(0, dash).trim());
  final second =
      dash + 1 < spec.length ? int.tryParse(spec.substring(dash + 1).trim()) : null;
  if (first == null) {
    // 后缀形式 bytes=-N：只取最后 N 字节
    if (second != null) return _ParsedRange(0, second - 1);
    return _ParsedRange(0, null);
  }
  return _ParsedRange(first, second);
}

/// `RemoteClient.openRangeResponse` 的返回：按需区间取流的结果。
class RemoteRangeResponse {
  final int statusCode;
  final Map<String, String> headers;

  /// 响应体字节流。HTTP 系协议直接透传远端响应流，其余为本地临时文件流。
  final Stream<List<int>> stream;

  /// 需要在使用完毕后删除的临时文件路径（仅非 HTTP 协议存在）。
  final String? tempFilePath;

  RemoteRangeResponse({
    required this.statusCode,
    required this.headers,
    required this.stream,
    this.tempFilePath,
  });
}
