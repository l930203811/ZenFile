import 'dart:math' as math;

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
  final bool stripOnly; // 「仅清除元数据」开关：true 时保存走字节级无损剥离（不重编码）
  // 绘图笔画。每个元素为 Map，字段全部为可跨 isolate 传递的基础类型：
  //   - 'tool'  : String 'pen' | 'arrow'
  //   - 'color' : int ARGB
  //   - 'width' : double 归一化线宽（相对最终图宽）
  //   - 'points': List<num> 扁平归一化坐标 [x0,y0, x1,y1, ...]（0..1，相对最终图）
  final List<Map<String, Object>> drawStrokes;

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
    this.stripOnly = false,
    this.drawStrokes = const [],
  });

  /// copyWith 哨兵：区分「未传参（保留旧值）」与「显式传 null（清除）」。
  /// cropX/cropY/cropW/cropH/targetWidth/targetHeight 需要支持置回 null
  /// （清除裁剪 / 恢复原始尺寸），普通 `?? this.x` 做不到。
  static const _kUnset = Object();

  ImageEditParams copyWith({
    int? rotateAngle,
    bool? flipHorizontal,
    bool? flipVertical,
    double? brightness,
    double? contrast,
    double? saturation,
    String? filter,
    Object? targetWidth = _kUnset,
    Object? targetHeight = _kUnset,
    Object? cropX = _kUnset,
    Object? cropY = _kUnset,
    Object? cropW = _kUnset,
    Object? cropH = _kUnset,
    bool? stripMetadata,
    bool? stripOnly,
    List<Map<String, Object>>? drawStrokes,
  }) {
    return ImageEditParams(
      rotateAngle: rotateAngle ?? this.rotateAngle,
      flipHorizontal: flipHorizontal ?? this.flipHorizontal,
      flipVertical: flipVertical ?? this.flipVertical,
      brightness: brightness ?? this.brightness,
      contrast: contrast ?? this.contrast,
      saturation: saturation ?? this.saturation,
      filter: filter ?? this.filter,
      targetWidth: targetWidth == _kUnset
          ? this.targetWidth
          : targetWidth as int?,
      targetHeight: targetHeight == _kUnset
          ? this.targetHeight
          : targetHeight as int?,
      cropX: cropX == _kUnset ? this.cropX : cropX as double?,
      cropY: cropY == _kUnset ? this.cropY : cropY as double?,
      cropW: cropW == _kUnset ? this.cropW : cropW as double?,
      cropH: cropH == _kUnset ? this.cropH : cropH as double?,
      stripMetadata: stripMetadata ?? this.stripMetadata,
      stripOnly: stripOnly ?? this.stripOnly,
      drawStrokes: drawStrokes ?? this.drawStrokes,
    );
  }

  /// 是否有实际的视觉编辑（调色/滤镜/裁剪/缩放/旋转/翻转）。「仅清除元数据」
  /// 不改变像素，不计入其中。
  bool get hasVisualChanges =>
      rotateAngle != 0 ||
      flipHorizontal ||
      flipVertical ||
      brightness != 1.0 ||
      contrast != 1.0 ||
      saturation != 1.0 ||
      filter != 'none' ||
      targetWidth != null ||
      targetHeight != null ||
      cropX != null ||
      drawStrokes.isNotEmpty;

  bool get hasChanges => hasVisualChanges || stripOnly;
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
  if (bytes.length >= 3 &&
      bytes[0] == 0xFF &&
      bytes[1] == 0xD8 &&
      bytes[2] == 0xFF) {
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
          final l = (0.299 * p.r + 0.587 * p.g + 0.114 * p.b).round().clamp(
            0,
            255,
          );
          src.setPixelRgba(x, y, l, l, l, p.a);
        }
      }
      return src;
    case 'sepia':
      for (var y = 0; y < h; y++) {
        for (var x = 0; x < w; x++) {
          final p = src.getPixel(x, y);
          final tr = (0.393 * p.r + 0.769 * p.g + 0.189 * p.b).round().clamp(
            0,
            255,
          );
          final tg = (0.349 * p.r + 0.686 * p.g + 0.168 * p.b).round().clamp(
            0,
            255,
          );
          final tb = (0.272 * p.r + 0.534 * p.g + 0.131 * p.b).round().clamp(
            0,
            255,
          );
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

/// 将绘图笔画（归一化坐标，0..1 相对最终图）绘制到图像上。
/// 支持工具：'pen'（折线+圆头）、'line'（直线）、'rect'（矩形）、
/// 'ellipse'（椭圆）、'arrow'（线段+箭头）、'mosaic'（马赛克涂抹）、
/// 'text'（文本 PNG 合成）。
img.Image _applyDrawStrokes(
  img.Image image,
  List<Map<String, Object>> strokes,
) {
  if (strokes.isEmpty) return image;
  final w = image.width;
  final h = image.height;
  if (w <= 0 || h <= 0) return image;
  for (final s in strokes) {
    final tool = s['tool'] as String? ?? 'pen';
    if (tool == 'text') {
      _applyTextStroke(image, s);
      continue;
    }
    if (tool == 'mosaic') {
      _applyMosaicStroke(image, s);
      continue;
    }
    final colorValue = (s['color'] as num).toInt();
    final width = (s['width'] as num).toDouble();
    final color = img.ColorRgba8(
      (colorValue >> 16) & 0xFF,
      (colorValue >> 8) & 0xFF,
      colorValue & 0xFF,
      (colorValue >> 24) & 0xFF,
    );
    final thickness = (width * w).clamp(1.0, 200.0);
    if (tool == 'rect' || tool == 'ellipse') {
      // 对象化形状：x/y/w/h/angle（归一化，angle 度，绕中心顺时针）
      final x = (s['x'] as num).toDouble();
      final y = (s['y'] as num).toDouble();
      final ow = (s['w'] as num).toDouble();
      final oh = (s['h'] as num).toDouble();
      final angle = (s['angle'] as num?)?.toDouble() ?? 0;
      if (ow <= 0 || oh <= 0) continue;
      if (tool == 'rect') {
        _drawObjectRect(image, x, y, ow, oh, angle, color, thickness);
      } else {
        _drawObjectEllipse(image, x, y, ow, oh, angle, color, thickness);
      }
      continue;
    }
    final pts = (s['points'] as List).cast<num>();
    if (pts.length < 4) continue;
    switch (tool) {
      case 'line':
        _drawSegment(
          image,
          pts[0] * w,
          pts[1] * h,
          pts[2] * w,
          pts[3] * h,
          color,
          thickness,
        );
      case 'rect':
        _drawRectStroke(image, pts, color, thickness);
      case 'ellipse':
        _drawEllipseStroke(image, pts, color, thickness);
      case 'arrow':
        _drawArrowStroke(image, pts, color, thickness);
      default:
        _drawPenStroke(image, pts, color, thickness);
    }
  }
  return image;
}

double _normX(num v, int w) => ((v).clamp(0.0, 1.0) * w).toDouble();
double _normY(num v, int h) => ((v).clamp(0.0, 1.0) * h).toDouble();

void _drawSegment(
  img.Image image,
  num x1,
  num y1,
  num x2,
  num y2,
  img.Color color,
  num thickness,
) {
  final w = image.width - 1;
  final h = image.height - 1;
  img.drawLine(
    image,
    x1: x1.round().clamp(0, w),
    y1: y1.round().clamp(0, h),
    x2: x2.round().clamp(0, w),
    y2: y2.round().clamp(0, h),
    color: color,
    thickness: thickness,
    antialias: true,
  );
}

/// 画笔：每点画圆头 + 相邻点连线，形成平滑折线。
void _drawPenStroke(
  img.Image image,
  List<num> pts,
  img.Color color,
  num thickness,
) {
  final w = image.width;
  final h = image.height;
  final radius = (thickness / 2).round().clamp(1, 100);
  final n = pts.length ~/ 2;
  for (var i = 0; i < n; i++) {
    final x = _normX(pts[i * 2], w).round().clamp(0, w - 1);
    final y = _normY(pts[i * 2 + 1], h).round().clamp(0, h - 1);
    img.fillCircle(
      image,
      x: x,
      y: y,
      radius: radius,
      color: color,
      antialias: true,
    );
    if (i > 0) {
      final px = _normX(pts[(i - 1) * 2], w).round().clamp(0, w - 1);
      final py = _normY(pts[(i - 1) * 2 + 1], h).round().clamp(0, h - 1);
      _drawSegment(image, px, py, x, y, color, thickness);
    }
  }
}

/// 对象化矩形：x/y/w/h 归一化 + angle(度, 绕中心顺时针)，画 4 条旋转边。
void _drawObjectRect(
  img.Image image,
  double x,
  double y,
  double ow,
  double oh,
  double angle,
  img.Color color,
  num thickness,
) {
  final W = image.width.toDouble();
  final H = image.height.toDouble();
  final cx = (x + ow / 2) * W;
  final cy = (y + oh / 2) * H;
  final rw = ow * W / 2;
  final rh = oh * H / 2;
  final a = angle * math.pi / 180;
  final ca = math.cos(a);
  final sa = math.sin(a);
  final corners = <List<double>>[
    [cx - rw, cy - rh],
    [cx + rw, cy - rh],
    [cx + rw, cy + rh],
    [cx - rw, cy + rh],
  ];
  final pts = <List<double>>[];
  for (final c in corners) {
    final dx = c[0] - cx;
    final dy = c[1] - cy;
    pts.add([cx + dx * ca - dy * sa, cy + dx * sa + dy * ca]);
  }
  for (var i = 0; i < 4; i++) {
    final p1 = pts[i];
    final p2 = pts[(i + 1) % 4];
    _drawSegment(image, p1[0], p1[1], p2[0], p2[1], color, thickness);
  }
}

/// 对象化椭圆：x/y/w/h 归一化 + angle(度, 绕中心顺时针)，多边形逼近 + 旋转。
void _drawObjectEllipse(
  img.Image image,
  double x,
  double y,
  double ow,
  double oh,
  double angle,
  img.Color color,
  num thickness,
) {
  final W = image.width.toDouble();
  final H = image.height.toDouble();
  final cx = (x + ow / 2) * W;
  final cy = (y + oh / 2) * H;
  final rx = ow * W / 2;
  final ry = oh * H / 2;
  final a = angle * math.pi / 180;
  final ca = math.cos(a);
  final sa = math.sin(a);
  const seg = 64;
  double prevX = 0;
  double prevY = 0;
  var first = true;
  for (var i = 0; i <= seg; i++) {
    final t = 2 * math.pi * i / seg;
    final ex = cx + rx * math.cos(t);
    final ey = cy + ry * math.sin(t);
    final dx = ex - cx;
    final dy = ey - cy;
    final nx = cx + dx * ca - dy * sa;
    final ny = cy + dx * sa + dy * ca;
    if (!first) {
      _drawSegment(image, prevX, prevY, nx, ny, color, thickness);
    }
    prevX = nx;
    prevY = ny;
    first = false;
  }
}

/// 矩形（对角两点）。
void _drawRectStroke(
  img.Image image,
  List<num> pts,
  img.Color color,
  num thickness,
) {
  final w = image.width;
  final h = image.height;
  final x0 = _normX(pts[0], w).round().clamp(0, w - 1);
  final y0 = _normY(pts[1], h).round().clamp(0, h - 1);
  final x1 = _normX(pts[2], w).round().clamp(0, w - 1);
  final y1 = _normY(pts[3], h).round().clamp(0, h - 1);
  img.drawRect(
    image,
    x1: x0,
    y1: y0,
    x2: x1,
    y2: y1,
    color: color,
    thickness: thickness.round().clamp(1, 200),
  );
}

/// 椭圆（对角两点为外接矩形），用多边形逼近绘制。
void _drawEllipseStroke(
  img.Image image,
  List<num> pts,
  img.Color color,
  num thickness,
) {
  final w = image.width;
  final h = image.height;
  final x1 = _normX(pts[0], w);
  final y1 = _normY(pts[1], h);
  final x2 = _normX(pts[2], w);
  final y2 = _normY(pts[3], h);
  final cx = (x1 + x2) / 2;
  final cy = (y1 + y2) / 2;
  final rx = ((x2 - x1).abs() / 2).clamp(1.0, w.toDouble());
  final ry = ((y2 - y1).abs() / 2).clamp(1.0, h.toDouble());
  const seg = 64;
  var prevX = cx + rx;
  var prevY = cy;
  for (var i = 1; i <= seg; i++) {
    final t = 2 * math.pi * i / seg;
    final nx = cx + rx * math.cos(t);
    final ny = cy + ry * math.sin(t);
    _drawSegment(image, prevX, prevY, nx, ny, color, thickness);
    prevX = nx;
    prevY = ny;
  }
}

/// 箭头：线段 + 头部两条等分短线。
void _drawArrowStroke(
  img.Image image,
  List<num> pts,
  img.Color color,
  num thickness,
) {
  final w = image.width;
  final h = image.height;
  final x1 = _normX(pts[0], w).round().clamp(0, w - 1);
  final y1 = _normY(pts[1], h).round().clamp(0, h - 1);
  final x2 = _normX(pts[2], w).round().clamp(0, w - 1);
  final y2 = _normY(pts[3], h).round().clamp(0, h - 1);
  _drawSegment(image, x1, y1, x2, y2, color, thickness);
  final dx = x2 - x1;
  final dy = y2 - y1;
  final len = math.sqrt(dx * dx + dy * dy);
  if (len > 1) {
    final ux = dx / len;
    final uy = dy / len;
    final px = -uy;
    final py = ux;
    final headLen = (thickness * 3).clamp(10.0, 80.0);
    const spread = 0.42;
    final baseX = x2 - ux * headLen;
    final baseY = y2 - uy * headLen;
    final hx1 = (baseX + px * headLen * spread).round();
    final hy1 = (baseY + py * headLen * spread).round();
    final hx2 = (baseX - px * headLen * spread).round();
    final hy2 = (baseY - py * headLen * spread).round();
    final headThickness = (thickness * 0.8).clamp(1.0, 200.0);
    _drawSegment(image, x2, y2, hx1, hy1, color, headThickness);
    _drawSegment(image, x2, y2, hx2, hy2, color, headThickness);
  }
}

/// 马赛克涂抹：对每个采样点所在方格取平均色填充，形成明显的块状模糊。
/// 方格大小 = 归一化宽度 * 8（更明显的块），同一格只处理一次。
void _applyMosaicStroke(img.Image image, Map<String, Object> s) {
  final w = image.width;
  final h = image.height;
  final widthNorm = (s['width'] as num).toDouble();
  final cell = (widthNorm * w * 8).clamp(16.0, 200.0).round();
  final pts = (s['points'] as List).cast<num>();
  final n = pts.length ~/ 2;
  final visited = <int>{};
  for (var i = 0; i < n; i++) {
    final cx = _normX(pts[i * 2], w).round().clamp(0, w - 1);
    final cy = _normY(pts[i * 2 + 1], h).round().clamp(0, h - 1);
    final x0 = (cx - cell ~/ 2).clamp(0, w - 1).toInt();
    final y0 = (cy - cell ~/ 2).clamp(0, h - 1).toInt();
    final x1 = (cx + cell ~/ 2).clamp(0, w - 1).toInt();
    final y1 = (cy + cell ~/ 2).clamp(0, h - 1).toInt();
    if (!visited.add(x0 * 100000 + y0)) continue;
    var rs = 0, gs = 0, bs = 0;
    var cnt = 0;
    for (var y = y0; y <= y1; y++) {
      for (var x = x0; x <= x1; x++) {
        final px = image.getPixel(x, y);
        rs += px.r.toInt();
        gs += px.g.toInt();
        bs += px.b.toInt();
        cnt++;
      }
    }
    if (cnt == 0) continue;
    final r = rs ~/ cnt;
    final g = gs ~/ cnt;
    final b = bs ~/ cnt;
    for (var y = y0; y <= y1; y++) {
      for (var x = x0; x <= x1; x++) {
        image.setPixelRgba(x, y, r, g, b, 255);
      }
    }
  }
}

/// 顺时针旋转图像（视觉方向：angle>0 为顺时针，屏幕坐标 y 向下），
/// 与选区框的旋转公式保持一致。透明背景，最近邻采样。
img.Image _rotateImageCw(img.Image src, double deg) {
  if (deg == 0) return src;
  final a = deg * math.pi / 180;
  final ca = math.cos(a);
  final sa = math.sin(a);
  final nw = (src.width * ca.abs() + src.height * sa.abs()).ceil();
  final nh = (src.width * sa.abs() + src.height * ca.abs()).ceil();
  if (nw <= 0 || nh <= 0) return src;
  final out = img.Image(width: nw, height: nh, numChannels: src.numChannels);
  final cx = src.width / 2;
  final cy = src.height / 2;
  final ocx = nw / 2;
  final ocy = nh / 2;
  for (var y = 0; y < nh; y++) {
    for (var x = 0; x < nw; x++) {
      final dx = x - ocx;
      final dy = y - ocy;
      final sx = (cx + dx * ca + dy * sa).floor();
      final sy = (cy - dx * sa + dy * ca).floor();
      if (sx >= 0 && sy >= 0 && sx < src.width && sy < src.height) {
        out.setPixel(x, y, src.getPixel(sx, sy));
      } else {
        out.setPixelRgba(x, y, 0, 0, 0, 0);
      }
    }
  }
  return out;
}

/// 文本：把 UI 端渲染好的文本 PNG 按对象参数（x/y/w/h/angle 归一化，
/// 绕中心顺时针旋转）合成到图上，越界部分安全裁剪。
void _applyTextStroke(img.Image image, Map<String, Object> s) {
  final pngBytes = s['textPng'];
  if (pngBytes is! Uint8List || pngBytes.isEmpty) return;
  var textImg = img.decodeImage(pngBytes);
  if (textImg == null) return;
  final W = image.width;
  final H = image.height;
  var x = (s['x'] as num).toDouble();
  var y = (s['y'] as num).toDouble();
  var ow = (s['w'] as num?)?.toDouble() ?? 0;
  var oh = (s['h'] as num?)?.toDouble() ?? 0;
  final angle = (s['angle'] as num?)?.toDouble() ?? 0;
  if (ow <= 0 || oh <= 0) {
    // 兼容旧数据：只有 x/y/h
    oh = (s['h'] as num?)?.toDouble() ?? 0.05;
    ow = textImg.width * oh * H / textImg.height / W;
  }
  if (ow <= 0 || oh <= 0) return;
  final dstWpx = (ow * W).round().clamp(1, W * 2);
  final dstHpx = (oh * H).round().clamp(1, H * 2);
  // 旋转文本
  var rot = textImg;
  if (angle != 0) rot = _rotateImageCw(textImg, angle);
  // 旋转后的包围盒尺寸
  final a = angle * math.pi / 180;
  final ca = math.cos(a);
  final sa = math.sin(a);
  final boxW = (dstWpx * ca.abs() + dstHpx * sa.abs()).round().clamp(1, W * 2);
  final boxH = (dstWpx * sa.abs() + dstHpx * ca.abs()).round().clamp(1, H * 2);
  final scaled = img.copyResize(
    rot,
    width: boxW,
    height: boxH,
    interpolation: img.Interpolation.linear,
  );
  // 中心对齐放置
  final cx = (x * W + dstWpx / 2).round();
  final cy = (y * H + dstHpx / 2).round();
  var sx = cx - boxW ~/ 2;
  var sy = cy - boxH ~/ 2;
  // 安全裁剪到目标图边界
  final ox = (-sx).clamp(0, scaled.width - 1);
  final oy = (-sy).clamp(0, scaled.height - 1);
  final dstX = sx.clamp(0, W - 1);
  final dstY = sy.clamp(0, H - 1);
  final dstW = (boxW - (dstX - sx)).clamp(1, W - dstX);
  final dstH = (boxH - (dstY - sy)).clamp(1, H - dstY);
  if (dstW <= 0 || dstH <= 0) return;
  img.compositeImage(
    image,
    scaled,
    dstX: dstX,
    dstY: dstY,
    dstW: dstW,
    dstH: dstH,
    srcX: ox,
    srcY: oy,
    srcW: dstW,
    srcH: dstH,
  );
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
  if (p.cropX != null &&
      p.cropW != null &&
      p.cropW! > 0 &&
      p.cropH != null &&
      p.cropH! > 0) {
    final x = (p.cropX! * image.width).round().clamp(0, image.width - 1);
    final y = (p.cropY! * image.height).round().clamp(0, image.height - 1);
    final w = (p.cropW! * image.width).round().clamp(1, image.width - x);
    final h = (p.cropH! * image.height).round().clamp(1, image.height - y);
    image = img.copyCrop(image, x: x, y: y, width: w, height: h);
  }

  // 2) 旋转
  if (p.rotateAngle != 0) {
    image = img.copyRotate(image, angle: p.rotateAngle.toDouble());
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
  if (p.targetWidth != null &&
      p.targetWidth! > 0 &&
      p.targetHeight != null &&
      p.targetHeight! > 0) {
    image = img.copyResize(
      image,
      width: p.targetWidth!,
      height: p.targetHeight!,
    );
  }

  // 6.5) 绘图笔画（叠加在最终尺寸上）
  if (p.drawStrokes.isNotEmpty) {
    image = _applyDrawStrokes(image, p.drawStrokes);
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
  }) => compute(
    _editImageIsolate,
    _EditTask(bytes, params, preview, isPng, quality),
  );

  /// 仅剥离元数据（重新编码即可），返回干净字节。
  Future<Uint8List> stripMetadata(
    Uint8List bytes, {
    int quality = 90,
    bool isPng = false,
  }) => edit(bytes, const ImageEditParams(), quality: quality, isPng: isPng);

  /// 智能编码：自动调整 JPEG 质量以满足目标文件大小限制（KB）。
  /// 使用二分查找在 quality [10..95] 范围内找到不超过 targetSizeKB 的最佳质量。
  /// 返回编码后的字节和实际使用的 quality。
  Future<Uint8List> encodeWithSizeLimit(
    Uint8List bytes,
    ImageEditParams params, {
    int targetSizeKB = 50,
    bool isPng = false,
  }) async {
    if (targetSizeKB <= 0 || isPng) {
      // 无大小限制或 PNG（PNG 不支持质量调节），直接按默认质量编码
      return edit(bytes, params, quality: 90, isPng: isPng);
    }

    final targetBytes = targetSizeKB * 1024;
    int lo = 10, hi = 95;
    Uint8List? bestResult;

    // 二分查找最佳质量
    while (lo <= hi) {
      final mid = (lo + hi) ~/ 2;
      final encoded = await edit(bytes, params, quality: mid, isPng: false);
      if (encoded.length <= targetBytes) {
        bestResult = encoded;
        lo = mid + 1; // 尝试更高质量
      } else {
        hi = mid - 1; // 需要更低质量
      }
    }

    // 如果最低质量仍超限，返回最低质量的结果（已是最小）
    bestResult ??= await edit(bytes, params, quality: 10, isPng: false);
    return bestResult;
  }

  /// DPI + 物理尺寸 → 像素尺寸转换。
  /// [cm] 厘米, [inch] 英寸, [dpi] 分辨率。
  /// 印度政府常用：3.5 x 2.5cm @ 200DPI → 276 x 197px
  static int pixelsFromPhysical(double physicalMM, int dpi) {
    return ((physicalMM / 25.4) * dpi).round();
  }

  /// 常用政府/机构预设尺寸模板。
  static const List<Map<String, dynamic>> presetSizes = [
    {'label': '印度政府证件照 (276×197)', 'widthMM': 35, 'heightMM': 25, 'dpi': 200},
    {'label': '印度护照 (35×45)', 'widthMM': 35, 'heightMM': 45, 'dpi': 200},
    {'label': '美国护照 (51×51)', 'widthMM': 51, 'heightMM': 51, 'dpi': 300},
    {'label': 'A4 @ 200DPI', 'widthMM': 210, 'heightMM': 297, 'dpi': 200},
    {'label': 'A4 @ 300DPI', 'widthMM': 210, 'heightMM': 297, 'dpi': 300},
  ];
}
