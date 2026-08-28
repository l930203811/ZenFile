import 'dart:io';
import 'dart:typed_data';

import 'package:exif/exif.dart';
import 'package:image/image.dart' as img;

/// 图片 EXIF/元数据封装，用于图片查看器属性页。
class ImageMetadata {
  final String? make;
  final String? model;
  final String? device;
  final String? shutter;
  final String? iso;
  final String? ev;
  final String? aperture;
  final String? focalLength;
  final String? flash;
  final String? latitude;
  final String? longitude;
  final double? latitudeNum;
  final double? longitudeNum;
  final String? locationAddress;
  final List<int>? histogramR;
  final List<int>? histogramG;
  final List<int>? histogramB;
  final bool hasExif;

  const ImageMetadata({
    this.make,
    this.model,
    this.device,
    this.shutter,
    this.iso,
    this.ev,
    this.aperture,
    this.focalLength,
    this.flash,
    this.latitude,
    this.longitude,
    this.latitudeNum,
    this.longitudeNum,
    this.locationAddress,
    this.histogramR,
    this.histogramG,
    this.histogramB,
    this.hasExif = false,
  });

  static const empty = ImageMetadata();
}

/// 读取图片 EXIF、计算直方图、反编码 GPS 地址。
class ImageMetadataService {
  const ImageMetadataService._();
  static const instance = ImageMetadataService._();

  /// 读取 EXIF 文本字段（设备/快门/ISO/光圈/焦距/曝光补偿/闪光灯）+ GPS 坐标，
  /// 不解码整图、不计算直方图、不做网络地理反编码——专为图片查看器右上角实时副行设计，
  /// 避免无谓的全图解码与地理反编码开销。
  Future<ImageMetadata> readExifOnly(File file) async {
    final exifData = await readExifFromFile(file);
    if (exifData.isEmpty) return const ImageMetadata();

    final make = _string(exifData['Image Make']);
    final model = _string(exifData['Image Model']);
    final device = _combineDevice(make, model);
    final shutter = _formatShutter(_rational(exifData['EXIF ExposureTime']));
    final iso = _string(exifData['EXIF ISOSpeedRatings'] ?? exifData['EXIF PhotographicSensitivity']);
    final ev = _formatEv(_rational(exifData['EXIF ExposureBiasValue']));
    final aperture = _formatAperture(_rational(exifData['EXIF FNumber']));
    final focalLength = _formatFocal(
      _rational(exifData['EXIF FocalLength']),
      _rational(exifData['EXIF FocalLengthIn35mmFilm']),
    );
    final flash = _formatFlash(_int(exifData['EXIF Flash']));

    // 轻量 GPS 解析：仅取经纬度坐标（不做网络反编码，保持查看器副行实时性）。
    final latRef = _string(exifData['GPS GPSLatitudeRef']);
    final lngRef = _string(exifData['GPS GPSLongitudeRef']);
    final latList = _rationalList(exifData['GPS GPSLatitude']);
    final lngList = _rationalList(exifData['GPS GPSLongitude']);
    final latNum = latList != null ? _dmsToDecimal(latList, latRef) : null;
    final lngNum = lngList != null ? _dmsToDecimal(lngList, lngRef) : null;

    return ImageMetadata(
      make: make,
      model: model,
      device: device,
      shutter: shutter,
      iso: iso,
      ev: ev,
      aperture: aperture,
      focalLength: focalLength,
      flash: flash,
      latitudeNum: latNum,
      longitudeNum: lngNum,
      latitude: latNum != null ? _formatCoordinate(latNum, latRef ?? 'N', true) : null,
      longitude: lngNum != null ? _formatCoordinate(lngNum, lngRef ?? 'E', false) : null,
      hasExif: true,
    );
  }

  Future<ImageMetadata> read(File file, Uint8List? bytes) async {
    final exifData = await readExifFromFile(file);
    if (exifData.isEmpty) {
      final hist = bytes != null ? _computeHistogram(bytes) : null;
      return ImageMetadata(
        histogramR: hist?.$1,
        histogramG: hist?.$2,
        histogramB: hist?.$3,
      );
    }

    final make = _string(exifData['Image Make']);
    final model = _string(exifData['Image Model']);
    final device = _combineDevice(make, model);
    final shutter = _formatShutter(_rational(exifData['EXIF ExposureTime']));
    final iso = _string(exifData['EXIF ISOSpeedRatings'] ?? exifData['EXIF PhotographicSensitivity']);
    final ev = _formatEv(_rational(exifData['EXIF ExposureBiasValue']));
    final aperture = _formatAperture(_rational(exifData['EXIF FNumber']));
    final focalLength = _formatFocal(
      _rational(exifData['EXIF FocalLength']),
      _rational(exifData['EXIF FocalLengthIn35mmFilm']),
    );
    final flash = _formatFlash(_int(exifData['EXIF Flash']));

    final latRef = _string(exifData['GPS GPSLatitudeRef']);
    final lngRef = _string(exifData['GPS GPSLongitudeRef']);
    final latList = _rationalList(exifData['GPS GPSLatitude']);
    final lngList = _rationalList(exifData['GPS GPSLongitude']);
    final lat = latList != null ? _dmsToDecimal(latList, latRef) : null;
    final lng = lngList != null ? _dmsToDecimal(lngList, lngRef) : null;

    final hist = bytes != null ? _computeHistogram(bytes) : null;

    return ImageMetadata(
      make: make,
      model: model,
      device: device,
      shutter: shutter,
      iso: iso,
      ev: ev,
      aperture: aperture,
      focalLength: focalLength,
      flash: flash,
      latitude: lat != null ? _formatCoordinate(lat, latRef ?? 'N', true) : null,
      longitude: lng != null ? _formatCoordinate(lng, lngRef ?? 'E', false) : null,
      latitudeNum: lat,
      longitudeNum: lng,
      histogramR: hist?.$1,
      histogramG: hist?.$2,
      histogramB: hist?.$3,
      hasExif: true,
    );
  }

  static String? _string(IfdTag? tag) {
    if (tag == null) return null;
    final s = tag.printable;
    if (s.isEmpty || s == 'null') return null;
    return s.trim();
  }

  static double? _rational(IfdTag? tag) {
    if (tag == null) return null;
    try {
      final list = tag.values.toList();
      if (list.isNotEmpty) {
        final first = list.first;
        if (first is Ratio) {
          return first.numerator / first.denominator;
        }
      }
      final printable = tag.printable;
      if (printable.contains('/')) {
        final parts = printable.split('/');
        if (parts.length == 2) {
          return double.parse(parts[0]) / double.parse(parts[1]);
        }
      }
      return double.tryParse(printable);
    } catch (_) {
      return null;
    }
  }

  static int? _int(IfdTag? tag) {
    if (tag == null) return null;
    return int.tryParse(tag.printable);
  }

  static List<Ratio>? _rationalList(IfdTag? tag) {
    if (tag == null) return null;
    try {
      final list = tag.values.toList();
      final ratios = list.whereType<Ratio>().toList();
      return ratios.isNotEmpty ? ratios : null;
    } catch (_) {
      return null;
    }
  }

  static String _combineDevice(String? make, String? model) {
    final parts = <String>[];
    if (make != null && make.isNotEmpty) parts.add(make);
    if (model != null && model.isNotEmpty) parts.add(model);
    return parts.join(', ');
  }

  static String? _formatShutter(double? r) {
    if (r == null || r <= 0) return null;
    if (r >= 1) return 'S:${r.toStringAsFixed(1)}s';
    final den = (1 / r).round();
    return 'S:1/$den';
  }

  static String? _formatEv(double? r) {
    if (r == null) return null;
    return 'EV:${r.toStringAsFixed(r.truncateToDouble() == r ? 0 : 1)}';
  }

  static String? _formatAperture(double? r) {
    if (r == null || r <= 0) return null;
    return 'F:${r.toStringAsFixed(r.truncateToDouble() == r ? 1 : 1)}';
  }

  static String? _formatFocal(double? focal, double? focal35) {
    if (focal == null || focal <= 0) return null;
    if (focal35 != null && focal35 > 0) {
      return '${focal.round()} mm (${focal35.round()} mm 等效)';
    }
    return '${focal.round()} mm';
  }

  static String? _formatFlash(int? value) {
    if (value == null) return null;
    // EXIF Flash 低字节：0=未闪光，1=闪光，5=闪光，未检出回光，7=闪光，强制，9=闪光，强制，无回光...
    final fired = value & 1 == 1;
    return fired ? '⚡' : null;
  }

  static double? _dmsToDecimal(List<Ratio> dms, String? ref) {
    if (dms.length < 3) return null;
    var deg = dms[0].numerator / dms[0].denominator;
    var min = dms[1].numerator / dms[1].denominator;
    var sec = dms[2].numerator / dms[2].denominator;
    var decimal = deg + min / 60 + sec / 3600;
    if (ref == 'S' || ref == 'W') decimal = -decimal;
    return decimal;
  }

  static String _formatCoordinate(double value, String ref, bool isLat) {
    final direction = isLat ? (value >= 0 ? 'N' : 'S') : (value >= 0 ? 'E' : 'W');
    return '${value.abs().toStringAsFixed(6)}° $direction';
  }

  /// 计算 RGB 通道直方图（256 级，未归一化）。
  static (List<int>, List<int>, List<int>)? _computeHistogram(Uint8List bytes) {
    try {
      final decoded = img.decodeImage(bytes);
      if (decoded == null) return null;
      final r = List<int>.filled(256, 0);
      final g = List<int>.filled(256, 0);
      final b = List<int>.filled(256, 0);
      for (var y = 0; y < decoded.height; y++) {
        for (var x = 0; x < decoded.width; x++) {
          final p = decoded.getPixel(x, y);
          r[p.r.toInt().clamp(0, 255)]++;
          g[p.g.toInt().clamp(0, 255)]++;
          b[p.b.toInt().clamp(0, 255)]++;
        }
      }
      return (r, g, b);
    } catch (_) {
      return null;
    }
  }

  /// 字节级剥离图片元数据（EXIF/GPS/ICC 等），**不重新编码、无损**。
  /// 区别于 ImageEditService.stripMetadata 的「重新编码」方案：本方法直接在原始字节上
  /// 删除元数据段，画质不受影响，且能确定地移除拍摄地点与相机参数。
  /// - JPEG：删除 APP1(Exif+GPS)、APP2(ICC)、COM 段
  /// - PNG：删除 tEXt / zTXt / iTXt 文本块
  /// 不支持的格式（如 WebP/GIF）原样返回。
  static Uint8List stripMetadataBytes(Uint8List src, {bool isPng = false}) {
    return isPng ? _stripPngMetadata(src) : _stripJpegMetadata(src);
  }

  static Uint8List _stripJpegMetadata(Uint8List src) {
    // 校验 JPEG SOI 标记 (FF D8)
    if (src.length < 2 || src[0] != 0xFF || src[1] != 0xD8) return src;
    final out = BytesBuilder();
    out.addByte(0xFF);
    out.addByte(0xD8);
    var i = 2;
    while (i + 1 < src.length) {
      if (src[i] != 0xFF) {
        // 已到熵编码数据区或结构异常：原样复制剩余字节
        out.add(src.sublist(i));
        break;
      }
      final marker = src[i + 1];
      if (marker == 0xD9) {
        // EOI：文件结束
        out.addByte(0xFF);
        out.addByte(0xD9);
        break;
      }
      if (marker == 0xDA) {
        // SOS：其后为压缩数据，原样复制剩余字节
        out.add(src.sublist(i));
        break;
      }
      if (i + 4 > src.length) {
        out.add(src.sublist(i));
        break;
      }
      final segLen = (src[i + 2] << 8) | src[i + 3];
      final segEnd = i + 2 + segLen;
      if (segEnd > src.length) {
        out.add(src.sublist(i));
        break;
      }
      // 跳过：APP1(Exif/GPS)=0xE1、APP2(ICC)=0xE2、COM=0xFE
      final skip = marker == 0xE1 || marker == 0xE2 || marker == 0xFE;
      if (!skip) out.add(src.sublist(i, segEnd));
      i = segEnd;
    }
    return out.toBytes();
  }

  static Uint8List _stripPngMetadata(Uint8List src) {
    const sig = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];
    if (src.length < 8) return src;
    for (var k = 0; k < 8; k++) {
      if (src[k] != sig[k]) return src;
    }
    final out = BytesBuilder();
    out.add(src.sublist(0, 8));
    var i = 8;
    const skipTypes = {'tEXt', 'zTXt', 'iTXt'};
    while (i + 8 <= src.length) {
      final len =
          (src[i] << 24) | (src[i + 1] << 16) | (src[i + 2] << 8) | src[i + 3];
      final type = String.fromCharCodes(src.sublist(i + 4, i + 8));
      final chunkEnd = i + 12 + len;
      if (chunkEnd > src.length) {
        out.add(src.sublist(i));
        break;
      }
      if (!skipTypes.contains(type)) out.add(src.sublist(i, chunkEnd));
      i = chunkEnd;
    }
    return out.toBytes();
  }
}
