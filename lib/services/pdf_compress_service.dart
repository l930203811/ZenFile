import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

/// PDF 压缩结果。
class PdfCompressResult {
  final bool success;
  final String? outputPath;
  final int originalSizeBytes;
  final int compressedSizeBytes;
  final String? error;

  const PdfCompressResult({
    required this.success,
    this.outputPath,
    this.originalSizeBytes = 0,
    this.compressedSizeBytes = 0,
    this.error,
  });

  double get compressionRatio =>
      originalSizeBytes > 0 ? (compressedSizeBytes / originalSizeBytes) * 100 : 0;

  String get savedPercent =>
      originalSizeBytes > 0 ? '${((1 - compressedSizeBytes / originalSizeBytes) * 100).toStringAsFixed(1)}%' : '0%';
}

/// PDF 压缩服务：通过降质内嵌图片来压缩 PDF 文件，输出仍为 .pdf 格式。
///
/// 实现原理：
/// 1. 解析 PDF 文件中的 JPEG 内嵌图片
/// 2. 对图片进行降质（降低 JPEG quality）和/或降分辨率
/// 3. 重新写入 PDF，保持文本和矢量内容不变
///
/// 注意：这是一个基础实现。完整 PDF 压缩需要 pdf 包（纯 Dart）或
/// qpdf/ghostscript（native）。当前版本使用图片降质策略。
class PdfCompressService {
  /// 压缩质量：1-100，越低文件越小但图片质量越差
  final int quality;

  /// 最大图片长边（像素），超过则缩小。0 = 不缩放
  final int maxImageDimension;

  const PdfCompressService({
    this.quality = 60,
    this.maxImageDimension = 1200,
  });

  /// 压缩 PDF 文件。
  /// [inputPath] 输入 PDF 路径
  /// [outputPath] 输出 PDF 路径（默认在原文件名后加 _compressed）
  static Future<PdfCompressResult> compress(
    String inputPath, {
    String? outputPath,
    int quality = 60,
    int maxImageDimension = 1200,
  }) async {
    return compute(_compressIsolate, _PdfCompressTask(
      inputPath: inputPath,
      outputPath: outputPath,
      quality: quality,
      maxImageDimension: maxImageDimension,
    ));
  }

  static PdfCompressResult _compressIsolate(_PdfCompressTask task) {
    try {
      final inputFile = File(task.inputPath);
      if (!inputFile.existsSync()) {
        return const PdfCompressResult(success: false, error: '文件不存在');
      }

      final originalSize = inputFile.lengthSync();
      final outPath = task.outputPath ??
          p.join(
            inputFile.parent.path,
            '${p.basenameWithoutExtension(task.inputPath)}_compressed.pdf',
          );

      // 基础 PDF 压缩：读取 PDF，尝试提取并降质 JPEG 图片，然后重新生成
      // 注意：这是简化实现，适用于 JPEG 内嵌图片的 PDF
      final bytes = inputFile.readAsBytesSync();
      final compressed = _recompressPdfImages(bytes, task.quality, task.maxImageDimension);

      if (compressed != null) {
        File(outPath).writeAsBytesSync(compressed);
        final compressedSize = compressed.length;
        return PdfCompressResult(
          success: true,
          outputPath: outPath,
          originalSizeBytes: originalSize,
          compressedSizeBytes: compressedSize,
        );
      }

      // 如果无法压缩（PDF 不含可处理图片），复制原文件
      inputFile.copySync(outPath);
      return PdfCompressResult(
        success: true,
        outputPath: outPath,
        originalSizeBytes: originalSize,
        compressedSizeBytes: originalSize,
      );
    } catch (e) {
      return PdfCompressResult(success: false, error: e.toString());
    }
  }

  /// 尝试重新压缩 PDF 中的 JPEG 图片。
  /// 返回新 PDF 字节，如果无法处理则返回 null。
  static Uint8List? _recompressPdfImages(Uint8List pdfBytes, int quality, int maxDim) {
    // PDF 中的 JPEG 图片通常以 DCTDecode 滤镜嵌入
    // 扫描 PDF 二进制数据寻找 JPEG 标记（FFD8 ... FFD9）
    final result = Uint8List.fromList(pdfBytes);
    var modified = false;
    var offset = 0;

    while (offset < result.length - 1) {
      // 查找 JPEG 起始标记 FFD8
      if (result[offset] == 0xFF && result[offset + 1] == 0xD8) {
        // 查找 JPEG 结束标记 FFD9
        var endOffset = offset + 2;
        while (endOffset < result.length - 1) {
          if (result[endOffset] == 0xFF && result[endOffset + 1] == 0xD9) {
            endOffset += 2;
            break;
          }
          endOffset++;
        }

        if (endOffset > offset + 100) {
          // 提取 JPEG 数据
          final jpegData = result.sublist(offset, endOffset);
          try {
            // 解码、降质、重新编码
            final decoded = img.decodeJpg(jpegData);
            if (decoded != null) {
              var processed = decoded;
              // 缩放
              if (maxDim > 0 && (decoded.width > maxDim || decoded.height > maxDim)) {
                if (decoded.width > decoded.height) {
                  processed = img.copyResize(decoded, width: maxDim);
                } else {
                  processed = img.copyResize(decoded, height: maxDim);
                }
              }
              // 重新编码为 JPEG
              final reencoded = img.encodeJpg(processed, quality: quality);
              if (reencoded.length < jpegData.length * 0.9) {
                // 替换原始数据
                final newBytes = Uint8List(result.length - jpegData.length + reencoded.length);
                newBytes.setRange(0, offset, result);
                newBytes.setRange(offset, offset + reencoded.length, reencoded);
                newBytes.setRange(
                  offset + reencoded.length,
                  newBytes.length,
                  result.sublist(endOffset),
                );
                // 由于长度变化，需要更新偏移并重新扫描
                // 简化处理：直接返回，不处理多个图片
                return newBytes;
              }
            }
          } catch (_) {
            // 解码失败，跳过
          }
        }
        offset = endOffset;
      } else {
        offset++;
      }
    }

    return modified ? result : null;
  }
}

/// PDF 压缩任务参数（用于 isolate）。
class _PdfCompressTask {
  final String inputPath;
  final String? outputPath;
  final int quality;
  final int maxImageDimension;

  const _PdfCompressTask({
    required this.inputPath,
    this.outputPath,
    required this.quality,
    required this.maxImageDimension,
  });
}
