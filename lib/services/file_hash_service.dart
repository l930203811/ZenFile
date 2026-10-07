import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;

/// 文件哈希计算结果（十六进制字符串）。
class FileHashResult {
  final String md5;
  final String sha1;
  final String sha256;

  const FileHashResult(this.md5, this.sha1, this.sha256);
}

/// 进度回调：已读取字节数 / 文件总字节数。
typedef HashProgressCallback = void Function(int processed, int total);

/// 文件 MD5 / SHA-1 / SHA-256 计算服务。
///
/// 采用流式分块读取，避免大文件把整文件读进内存；磁盘只扫一遍，同一批
/// 数据块同时喂给三条 digest 管线。
class FileHashService {
  FileHashService._();

  /// 计算本地文件 [filePath] 的 MD5、SHA-1 与 SHA-256。
  /// 文件不存在时抛出 [FileSystemException]。
  ///
  /// [onProgress] 按「百分比每变化 1%」节流回调一次，避免大文件刷爆 UI。
  static Future<FileHashResult> compute(
    String filePath, {
    HashProgressCallback? onProgress,
  }) async {
    final file = File(filePath);
    if (!file.existsSync()) {
      throw FileSystemException('File not found', filePath);
    }
    final total = file.lengthSync();

    late crypto.Digest md5Digest;
    late crypto.Digest sha1Digest;
    late crypto.Digest sha256Digest;

    final md5Sink = crypto.md5.startChunkedConversion(
      ChunkedConversionSink<crypto.Digest>.withCallback(
        (digests) => md5Digest = digests.single,
      ),
    );
    final sha1Sink = crypto.sha1.startChunkedConversion(
      ChunkedConversionSink<crypto.Digest>.withCallback(
        (digests) => sha1Digest = digests.single,
      ),
    );
    final sha256Sink = crypto.sha256.startChunkedConversion(
      ChunkedConversionSink<crypto.Digest>.withCallback(
        (digests) => sha256Digest = digests.single,
      ),
    );

    var processed = 0;
    var lastPercent = -1;
    await for (final chunk in file.openRead()) {
      md5Sink.add(chunk);
      sha1Sink.add(chunk);
      sha256Sink.add(chunk);
      processed += chunk.length;
      if (onProgress != null && total > 0) {
        final percent = (processed * 100 / total).floor();
        if (percent != lastPercent) {
          lastPercent = percent;
          onProgress(processed, total);
        }
      }
    }
    md5Sink.close();
    sha1Sink.close();
    sha256Sink.close();

    return FileHashResult(
      md5Digest.toString(),
      sha1Digest.toString(),
      sha256Digest.toString(),
    );
  }
}