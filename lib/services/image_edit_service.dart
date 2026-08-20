import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;

/// 图片编辑相关信息（轻量解码即可获取，无需解码全部像素）。
class ImageEditInfo {
  final int width;
  final int height;
  final String format;

  const ImageEditInfo({
    required this.width,
    required this.height,
    required this.format,
  });

  @override
  String toString() => '$width x $height ($format)';
}

/// 编辑参数。所有字段均为可序列化的基础类型，便于在 isolate 间传递。
class ImageEditParams {
  final int rotateAngle; // 0 / 90 / 180 / 270
  final bool flipHorizontal;
  final bool flipVertical;
  final double brightness; // 1.0 = 不变
  final double contrast; // 1.0 = 不变
  final double saturation; // 1.0 = 不变
  final String filter; // 'none' | 'bw' | 'sepia' | 'vintage' | 'cool' | 'warm'
  final int? targetWidth; // 精确缩放目标宽（null = 保持）
  final int? targetHeight; // 精确缩放目标高（null = 保持）
  final double? cropX; // 裁剪框左上角 X（归一化 0..1）
  final double? cropY;
  final double? cropW;
  final double? cropH;
  final bool stripMetadata; // 重新编码天然剥离 EXIF/GPS/ICC，恒为 true

  const ImageEditParams({
    this.rotateAngle = 0,
    this.flipHorizontal = false,
    this.flipVertical = false,
    this.brightness = 1.0,
    this.contrast = 1.0,
    this.saturation = 1.0,
    this.filter = 'none',
    this.targetWidth,
    this.targetHeight,
    this.cropX,
    this.cropY,
    this.cropW,
    this.cropH,
    this.stripMetadata = true,
  });

  ImageEditParams copyWith({
    int? rotateAngle,
    bool? flipHorizontal,
    bool? flipVertical,
    double? brightness,
    double? contrast,
    double? saturation,
    String? filter,
    int? targetWidth,
    int? targetHeight,
    double? cropX,
    double? cropY,
    double? cropW,
    double? cropH,
    bool? stripMetadata,
  }) {
    return ImageEditParams(
      rotateAngle: rotateAngle ?? this.rotateAngle,
      flipHorizontal: flipHorizontal ?? this.flipHorizontal,
      flipVertical: flipVertical ?? this.flipVertical,
      brightness: brightness ?? this.brightness,
      contrast: contrast ?? this.contrast,
      saturation: saturation ?? this.saturation,
      filter: filter ?? this.filter,
      targetWidth: targetWidth ?? this.targetWidth,
      targetHeight: targetHeight ?? this.targetHeight,
      cropX: cropX ?? this.cropX,
      cropY: cropY ?? this.cropY,
      cropW: cropW ?? this.cropW,
      cropH: cropH ?? this.cropH,
      stripMetadata: stripMetadata ?? this.stripMetadata,
    );
  }

  bool get hasChanges =>
      rotateAngle != 0 ||
      flipHorizontal ||
      flipVertical ||
      brightness != 1.0 ||
      contrast != 1.0 ||
      saturation != 1.0 ||
      filter != 'none' ||
      targetWidth != null ||
      targetHeight != null ||
      cropX != null;
}

/// 在 isolate 中执行的编辑任务。
class _EditTask {
  final Uint8List bytes;
  final ImageEditParams params;
  final bool preview; // 预览时降采样，加快显示
  final bool isPng; // 原图是否为 PNG（保留透明通道）
  final int quality;

  _EditTask(this.bytes, this.params, this.preview, this.isPng, this.quality);
}

/// 通过文件头魔数判断图片格式（避免依赖 image 包内部 Format 枚举命名）。
String _detectFormat(Uint8List bytes) {
  if (bytes.length >= 3 && bytes[0] == 0xFF && bytes[1] == 0xD8 && bytes[2] == 0xFF) {
    return 'JPEG';
  }
  if (bytes.length >= 8 &&
      bytes[0] == 0x89 &&
      bytes[1] == 0x50 &&
      bytes[2] == 0x4E &&
      bytes[3] == 0x47) {
    return 'PNG';
  }
  if (bytes.length >= 6 &&
      bytes[0] == 0x47 &&
      bytes[1] == 0x49 &&
      bytes[2] == 0x46 &&
      bytes[3] == 0x38 &&
      (bytes[4] == 0x37 || bytes[4] == 0x39) &&
      bytes[5] == 0x61) {
    return 'GIF';
  }
  if (bytes.length >= 2 && bytes[0] == 0x42 && bytes[1] == 0x4D) return 'BMP';
  if (bytes.length >= 12 &&
      bytes[0] == 0x52 &&
      bytes[1] == 0x49 &&
      bytes[2] == 0x46 &&
      bytes[3] == 0x46 &&
      bytes[8] == 0x57 &&
      bytes[9] == 0x45 &&
      bytes[10] == 0x42 &&
      bytes[11] == 0x50) {
    return 'WebP';
  }
  return 'Image';
}

/// 轻量读取图片尺寸与格式（仅解码头部，速度快）。
ImageEditInfo _getInfoIsolate(Uint8List bytes) {
  final decoder = img.findDecoderForData(bytes);
  if (decoder == null) {
    throw Exception('unsupported_image');
  }
  final image = decoder.startDecode(bytes);
  if (image == null) {
    throw Exception('unsupported_image');
  }
  return ImageEditInfo(
    width: image.width,
    height: image.height,
    format: _detectFormat(bytes),
  );
}

/// 应用滤镜（像素级处理，放在 isolate 中执行避免阻塞 UI）。
img.Image _applyFilter(img.Image src, String filter) {
  final w = src.width;
  final h = src.height;
  switch (filter) {
    case 'bw':
      for (var y = 0; y < h; y++) {
        for (var x = 0; x < w; x++) {
          final p = src.getPixel(x, y);
          final l = (0.299 * p.r + 0.587 * p.g + 0.114 * p.b).round().clamp(0, 255);
          src.setPixelRgba(x, y, l, l, l, p.a);
        }
      }
      return src;
    case 'sepia':
      for (var y = 0; y < h; y++) {
        for (var x = 0; x < w; x++) {
          final p = src.getPixel(x, y);
          final tr = (0.393 * p.r + 0.769 * p.g + 0.189 * p.b).round().clamp(0, 255);
          final tg = (0.349 * p.r + 0.686 * p.g + 0.168 * p.b).round().clamp(0, 255);
          final tb = (0.272 * p.r + 0.534 * p.g + 0.131 * p.b).round().clamp(0, 255);
          src.setPixelRgba(x, y, tr, tg, tb, p.a);
        }
      }
      return src;
    case 'vintage':
      for (var y = 0; y < h; y++) {
        for (var x = 0; x < w; x++) {
          final p = src.getPixel(x, y);
          final tr = (p.r * 1.15 + 20).round().clamp(0, 255);
          final tg = (p.g * 1.05 + 10).round().clamp(0, 255);
          final tb = (p.b * 0.85).round().clamp(0, 255);
          src.setPixelRgba(x, y, tr, tg, tb, p.a);
        }
      }
      return src;
    case 'cool':
      for (var y = 0; y < h; y++) {
        for (var x = 0; x < w; x++) {
          final p = src.getPixel(x, y);
          final tr = (p.r * 0.9).round().clamp(0, 255);
          final tg = p.g;
          final tb = (p.b * 1.15).round().clamp(0, 255);
          src.setPixelRgba(x, y, tr, tg, tb, p.a);
        }
      }
      return src;
    case 'warm':
      for (var y = 0; y < h; y++) {
        for (var x = 0; x < w; x++) {
          final p = src.getPixel(x, y);
          final tr = (p.r * 1.15).round().clamp(0, 255);
          final tg = p.g;
          final tb = (p.b * 0.85).round().clamp(0, 255);
          src.setPixelRgba(x, y, tr, tg, tb, p.a);
        }
      }
      return src;
    default:
      return src;
  }
}

/// isolate 入口：执行完整编辑管线并编码输出字节。
Uint8List _editImageIsolate(_EditTask task) {
  final p = task.params;
  final src = img.decodeImage(task.bytes);
  if (src == null) {
    throw Exception('unsupported_image');
  }

  var image = src;

  // 1) 裁剪（在原图坐标系）
  if (p.cropX != null && p.cropW != null && p.cropW! > 0 && p.cropH != null && p.cropH! > 0) {
    final x = (p.cropX! * image.width).round().clamp(0, image.width - 1);
    final y = (p.cropY! * image.height).round().clamp(0, image.height - 1);
    final w = (p.cropW! * image.width).round().clamp(1, image.width - x);
    final h = (p.cropH! * image.height).round().clamp(1, image.height - y);
    image = img.copyCrop(image, x: x, y: y, width: w, height: h);
  }

  // 2) 旋转
  if (p.rotateAngle != 0) {
    image = img.copyRotate(image, p.rotateAngle.toDouble());
  }

  // 3) 翻转
  if (p.flipHorizontal) {
    image = img.copyFlip(image, direction: img.FlipDirection.horizontal);
  }
  if (p.flipVertical) {
    image = img.copyFlip(image, direction: img.FlipDirection.vertical);
  }

  // 4) 调色（亮度/对比度/饱和度）
  if (p.brightness != 1.0 || p.contrast != 1.0 || p.saturation != 1.0) {
    image = img.adjustColor(
      image,
      brightness: p.brightness,
      contrast: p.contrast,
      saturation: p.saturation,
    );
  }

  // 5) 滤镜
  if (p.filter != 'none') {
    image = _applyFilter(image, p.filter);
  }

  // 6) 精确缩放
  if (p.targetWidth != null && p.targetWidth! > 0 && p.targetHeight != null && p.targetHeight! > 0) {
    image = img.copyResize(image, width: p.targetWidth!, height: p.targetHeight!);
  }

  // 7) 预览降采样
  if (task.preview) {
    const maxSide = 1280;
    if (image.width > maxSide || image.height > maxSide) {
      final longSide = image.width > image.height ? image.width : image.height;
      final scale = maxSide / longSide;
      image = img.copyResize(
        image,
        width: (image.width * scale).round(),
        height: (image.height * scale).round(),
      );
    }
  }

  // 8) 编码（重新编码天然剥离 EXIF/GPS/ICC 元数据）
  final out = task.isPng
      ? img.encodePng(image)
      : img.encodeJpg(image, quality: task.quality.clamp(1, 100));
  return Uint8List.fromList(out);
}

/// 图片编辑服务：封装纯 Dart `image` 包，重操作均放入 compute isolate。
class ImageEditService {
  const ImageEditService._();

  static const ImageEditService instance = ImageEditService._();

  /// 读取图片尺寸与格式。
  Future<ImageEditInfo> readInfo(Uint8List bytes) =>
      compute(_getInfoIsolate, bytes);

  /// 执行编辑管线并返回编码后的字节。
  /// [preview]=true 时输出会降采样以加快预览显示。
  /// [isPng]=true 时输出 PNG（保留透明通道），否则输出 JPEG（quality 控制体积）。
  Future<Uint8List> edit(
    Uint8List bytes,
    ImageEditParams params, {
    int quality = 90,
    bool preview = false,
    bool isPng = false,
  }) =>
      compute(
        _editImageIsolate,
        _EditTask(bytes, params, preview, isPng, quality),
      );

  /// 仅剥离元数据（重新编码即可），返回干净字节。
  Future<Uint8List> stripMetadata(
    Uint8List bytes, {
    int quality = 90,
    bool isPng = false,
  }) =>
      edit(
        bytes,
        const ImageEditParams(),
        quality: quality,
        isPng: isPng,
      );
}
