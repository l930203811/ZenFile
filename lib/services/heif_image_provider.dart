// HEIC/HEIF 的安全解码入口（issue #61）。
//
// Flutter engine 在 Android 上遇到 Skia 不认识的格式（相机 HEIC/HEIF）会走
// `AndroidImageGenerator`：Java `ImageDecoder` 整幅全尺寸解码，**无视**
// Dart 侧的 cacheWidth / ResizeImage；一旦 Java 抛异常（内存不足、10-bit HDR、
// 数据损坏），engine 在 android_image_generator.cc:117 用
// `FML_CHECK(fml::jni::CheckException(env))` 断言失败 → SIGABRT。
// 这是 native abort，Dart 的 try/catch / errorBuilder / ImageCache 全部兜不住。
//
// 因此 HEIF 一律不交给 engine：先经原生桥降采样解成普通 JPEG，再由 Skia 解码。
// 原生桥内部 catch Throwable，失败只返回 null（UI 走 errorBuilder 显示格式图标）。

import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:flutter/services.dart';

class HeifDecodeResult {
  const HeifDecodeResult(this.bytes, this.width, this.height);
  final Uint8List bytes;
  final int width;
  final int height;
}

class HeifDecoder {
  static const MethodChannel _channel =
      MethodChannel('com.sequl.zenfile/heif_decoder');

  // 同一张图在列表 / 网格 / 查看器会以不同 targetSide 各请求一次；缓存少量
  // 最近结果，避免滚动时反复跨通道解码。真正的大缓存交给 Flutter imageCache。
  static final Map<String, HeifDecodeResult> _cache = {};
  static const int _kCacheLimit = 12;

  static Future<HeifDecodeResult?> decode(String path, int targetSide) async {
    if (!Platform.isAndroid) return null;
    final side = targetSide.clamp(64, 4096);
    final key = '$path|$side';
    final hit = _cache.remove(key);
    if (hit != null) {
      _cache[key] = hit; // 命中即刷新 LRU 位置
      return hit;
    }
    try {
      // 用 dynamic 承接：StandardMessageCodec 解出来的是 Map<Object?, Object?>，
      // 直接声明 Map<dynamic, dynamic> 在部分版本上会触发类型转换失败。
      final dynamic reply = await _channel.invokeMethod<dynamic>(
        'decode',
        <String, dynamic>{'path': path, 'side': side},
      );
      if (reply is! Map) return null;
      final bytes = reply['bytes'];
      if (bytes is! Uint8List || bytes.isEmpty) return null;
      final w = reply['width'];
      final h = reply['height'];
      final result = HeifDecodeResult(
        bytes,
        w is int ? w : 0,
        h is int ? h : 0,
      );
      // 满时淘汰最旧一条而非全清：来回滚动时全清会导致反复跨通道重解码。
      if (_cache.length >= _kCacheLimit) {
        _cache.remove(_cache.keys.first);
      }
      _cache[key] = result;
      return result;
    } catch (_) {
      // 通道不存在（桌面端 / 旧版原生壳）、解码失败：一律降级，不抛给 UI。
      return null;
    }
  }

  /// 已解码过的 HEIF 的原始尺寸；未解码过返回 null。
  /// 「适应高度」模式靠它拿尺寸，避免为了读尺寸再整幅解码。
  static ui.Size? cachedSourceSize(String path) {
    for (final entry in _cache.entries) {
      if (entry.key.startsWith('$path|') && entry.value.width > 0) {
        return ui.Size(
          entry.value.width.toDouble(),
          entry.value.height.toDouble(),
        );
      }
    }
    return null;
  }
}

/// 供 `Image(image: ...)` 使用的 HEIF provider。
///
/// key 只由路径 + 目标边长构成，保证 Flutter imageCache 能复用同一张图的解码结果。
class HeifImage extends ImageProvider<HeifImage> {
  const HeifImage(this.file, {this.targetSide = 2048});

  final File file;
  final int targetSide;

  @override
  Future<HeifImage> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture<HeifImage>(this);

  @override
  ImageStreamCompleter loadImage(
    HeifImage key,
    ImageDecoderCallback decode,
  ) {
    return OneFrameImageStreamCompleter(
      _imageInfo(key, decode),
      informationCollector: () => <DiagnosticsNode>[
        ErrorDescription('Path: ${file.path}'),
      ],
    );
  }

  Future<ImageInfo> _imageInfo(
    HeifImage key,
    ImageDecoderCallback decode,
  ) async {
    final result = await HeifDecoder.decode(file.path, targetSide);
    if (result == null) {
      // 让下次进入页面能重试，而不是把失败结果永久留在 imageCache 里。
      PaintingBinding.instance.imageCache.evict(key);
      throw StateError('HEIF decode failed: ${file.path}');
    }
    final buffer = await ui.ImmutableBuffer.fromUint8List(result.bytes);
    final codec = await decode(buffer);
    final frame = await codec.getNextFrame();
    return ImageInfo(image: frame.image, scale: 1.0);
  }

  @override
  bool operator ==(Object other) =>
      other is HeifImage &&
      other.file.path == file.path &&
      other.targetSide == targetSide;

  @override
  int get hashCode => Object.hash(file.path, targetSide);
}

/// 同步判断文件是否为 HEIF 家族（含加密条目那种没有扩展名的文件）。
///
/// 只读前 16 字节；结果按路径缓存，列表滚动时不会反复开文件。
bool isHeifFile(File file) {
  final key = file.path;
  final cached = _heifFlagCache.remove(key);
  if (cached != null) {
    _heifFlagCache[key] = cached; // 命中即刷新 LRU 位置
    return cached;
  }
  final value = _detectHeifSync(file);
  // 满时淘汰最旧一条而非整体 clear：大目录滚动时 1024 条很快写满，
  // 全清会让后续滚动反复同步开文件探测（build 路径上的同步 IO 卡顿源）。
  if (_heifFlagCache.length >= 1024) {
    _heifFlagCache.remove(_heifFlagCache.keys.first);
  }
  _heifFlagCache[key] = value;
  return value;
}

final Map<String, bool> _heifFlagCache = <String, bool>{};

bool _detectHeifSync(File file) {
  final lower = file.path.toLowerCase();
  // AVIF 同为 ftyp 容器，但已有 flutter_avif 独立解码，别抢走。
  if (lower.endsWith('.avif') || lower.endsWith('.avis')) return false;
  if (lower.endsWith('.heic') ||
      lower.endsWith('.heif') ||
      lower.endsWith('.heix') ||
      lower.endsWith('.hevc')) {
    return true;
  }
  // 常见非 HEIF 图片格式直接短路：否则每张 .jpg/.png 缩略图都要在 build
  // 路径上同步 open+read 一次（SD 卡上单次可达数 ms，滚动卡顿源）。
  // 魔数探测只留给无扩展名 / 未知扩展名（如加密条目）的文件。
  if (lower.endsWith('.jpg') ||
      lower.endsWith('.jpeg') ||
      lower.endsWith('.png') ||
      lower.endsWith('.gif') ||
      lower.endsWith('.webp') ||
      lower.endsWith('.bmp') ||
      lower.endsWith('.svg') ||
      lower.endsWith('.ico') ||
      lower.endsWith('.tif') ||
      lower.endsWith('.tiff')) {
    return false;
  }
  RandomAccessFile? raf;
  try {
    raf = file.openSync(mode: FileMode.read);
    final head = raf.readSync(16);
    if (head.length < 12) return false;
    // ISO BMFF: ....ftyp<major brand>；AVIF 的 major brand 是 'avif'，不在下表。
    if (head[4] != 0x66 || // f
        head[5] != 0x74 || // t
        head[6] != 0x79 || // y
        head[7] != 0x70) { // p
      return false;
    }
    final brand = String.fromCharCodes(head.sublist(8, 12));
    return const <String>{
      'heic',
      'heix',
      'hevc',
      'hevx',
      'heim',
      'heis',
      'hevm',
      'hevs',
      'mif1',
      'msf1',
    }.contains(brand);
  } catch (_) {
    return false;
  } finally {
    try {
      raf?.closeSync();
    } catch (_) {}
  }
}

/// 统一的图片 provider 工厂。
///
/// 非 HEIF 走 `ResizeImage.resizeIfNeeded` —— 与 `Image.file(cacheWidth: …)`
/// 的行为完全一致，普通图片零行为变化；HEIF 走 [HeifImage] 安全解码。
/// 桌面端没有原生桥，全部按原逻辑走 Skia（不会触发 engine 的 abort）。
ImageProvider imageProviderForFile(
  File file, {
  int? cacheWidth,
  int? cacheHeight,
}) {
  if (Platform.isAndroid && isHeifFile(file)) {
    final side = (cacheWidth ?? cacheHeight ?? 2048).clamp(64, 4096);
    return HeifImage(file, targetSide: side);
  }
  // cacheWidth 与 cacheHeight **同时**给出时，ResizeImage 默认 policy=exact
  // 会把位图硬拉成给定的宽×高（BoxFit.fill 类行为、比例失真）——查看器全屏
  // 解码用的正是「两边都 = 上限」的调用方式，非方形图会被压扁/拉伸（issue #77
  // 的失真根因）。改用 fit：在给定边长盒内**保比例**缩放。只传单边的调用方
  // （列表缩略图）行为不变。
  if (cacheWidth != null && cacheHeight != null) {
    return ResizeImage(
      FileImage(file),
      width: cacheWidth,
      height: cacheHeight,
      policy: ResizeImagePolicy.fit,
    );
  }
  return ResizeImage.resizeIfNeeded(cacheWidth, cacheHeight, FileImage(file));
}
