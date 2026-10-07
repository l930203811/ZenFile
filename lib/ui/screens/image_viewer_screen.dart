import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'package:auto_size_text/auto_size_text.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:photo_view/photo_view.dart';
import 'package:photo_view/photo_view_gallery.dart';
import 'package:mime/mime.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:flutter_avif/flutter_avif.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';
import '../../providers/media_provider.dart';
import '../../providers/file_manager_provider.dart';
import '../../core/icon_fonts/broken_icons.dart';
import '../../core/utils.dart';
import '../../ui/widgets/file_action_dialogs.dart';
import '../../services/image_edit_service.dart';
import '../../services/preferences_service.dart';
import '../../services/image_metadata_service.dart';
import '../../services/folder_share_service.dart';
import 'image_editor_screen.dart';
import '../navigation/shell_navigator.dart';
import 'package:zenfile/l10n/generated/app_localizations.dart';
import 'package:url_launcher/url_launcher.dart';

final Uint8List _kTransparentImage = Uint8List.fromList([
  0x89,
  0x50,
  0x4E,
  0x47,
  0x0D,
  0x0A,
  0x1A,
  0x0A,
  0x00,
  0x00,
  0x00,
  0x0D,
  0x49,
  0x48,
  0x44,
  0x52,
  0x00,
  0x00,
  0x00,
  0x01,
  0x00,
  0x00,
  0x00,
  0x01,
  0x08,
  0x06,
  0x00,
  0x00,
  0x00,
  0x1F,
  0x15,
  0xC4,
  0x89,
  0x00,
  0x00,
  0x00,
  0x0A,
  0x49,
  0x44,
  0x41,
  0x54,
  0x78,
  0x9C,
  0x63,
  0x00,
  0x01,
  0x00,
  0x00,
  0x05,
  0x00,
  0x01,
  0x0D,
  0x0A,
  0x2D,
  0xB4,
  0x00,
  0x00,
  0x00,
  0x00,
  0x49,
  0x45,
  0x4E,
  0x44,
  0xAE,
  0x42,
  0x60,
  0x82,
]);

class ImageViewerScreen extends StatefulWidget {
  final String imagePath;
  final List<String>? siblingPaths;
  final List<AssetEntity>? siblingAssets;
  final List<dynamic>? siblingItems;
  final String? initialAssetId;

  /// 加密文件的流式解密 URL（CryptStreamServer 的 http://127.0.0.1 地址）。
  /// 非空时直接以 NetworkImage 渲染，跳过本地文件扫描/元信息读取（无本地文件）。
  final String? streamUrl;

  const ImageViewerScreen({
    super.key,
    required this.imagePath,
    this.siblingPaths,
    this.siblingAssets,
    this.siblingItems,
    this.initialAssetId,
    this.streamUrl,
  });

  @override
  State<ImageViewerScreen> createState() => _ImageViewerScreenState();
}

class _ImageViewerScreenState extends State<ImageViewerScreen> {
  late PageController _pageController;
  List<String> _imageList = [];
  final Map<int, File?> _fileCache = {};
  // 远程图片（remote://）按需下载到本地缓存后的 File，key 为页索引。
  final Map<int, File> _remoteCache = {};
  final Set<int> _remoteLoading = {};
  int _currentIndex = 0;
  bool _showUI = true;
  bool _isZoomed = false;
  // 查看态旋转角度（弧度），仅用于预览，不写回文件，瞬时完成。切换图片时重置。
  double _rotation = 0.0;
  // 图片显示模式：0=适应宽度(contained) 1=适应高度 2=原始大小（顶部切换，持久化）
  int _fitMode = 0;
  // 当前图片原始尺寸（按高度适配模式计算缩放用），切换图片时重置
  Size? _imageSize;

  // 顶部信息条
  String? _currentDims;
  String? _currentSizeStr;
  String? _currentFormat;
  String? _currentModified;
  // 右上角拍摄参数（EXIF）：无 EXIF 时为 null，副行不显示。
  ImageMetadata? _currentExif;
  // 拍摄位置（GPS 经纬度坐标文本）：相册 AssetEntity 或 EXIF GPS，无则 null。
  String? _currentLocationText;
  double? _currentLat;
  double? _currentLng;
  final ImageEditService _editService = ImageEditService.instance;

  @override
  void initState() {
    super.initState();
    _findSiblings();
    _pageController = PageController(initialPage: _currentIndex);
    _preloadAdjacent(_currentIndex);
    _refreshMeta();    _fitMode = PreferencesService.getImageFitMode();
    if (_fitMode == 1) {
      _resolveCurrentImageSize();
    }
  }

  Future<void> _findSiblings() async {
    // 流式解密 URL（加密文件）没有本地目录，直接作为单张图片展示
    if (widget.streamUrl != null) {
      _imageList = [widget.imagePath];
      _currentIndex = 0;
      return;
    }

    if (widget.siblingItems != null && widget.siblingItems!.isNotEmpty) {
      _currentIndex = widget.siblingItems!.indexWhere((e) {
        if (e is AssetEntity) return e.id == widget.initialAssetId;
        if (e is FileSystemEntity) return e.path == widget.imagePath;
        return false;
      });
      if (_currentIndex == -1) _currentIndex = 0;
      return;
    }

    if (widget.siblingAssets != null && widget.siblingAssets!.isNotEmpty) {
      _currentIndex = widget.siblingAssets!.indexWhere(
        (e) => e.id == widget.initialAssetId,
      );
      if (_currentIndex == -1) _currentIndex = 0;
      return;
    }

    if (widget.siblingPaths != null && widget.siblingPaths!.isNotEmpty) {
      _imageList = widget.siblingPaths!;
      _currentIndex = _imageList.indexOf(widget.imagePath);
      if (_currentIndex == -1) _currentIndex = 0;
      return;
    }

    // 走到这里说明是「浏览页直接打开图片」——调用方没给兄弟列表，只能自己扫目录。
    // ⚠️ 同步先占位成单张：`_imageList` 若在扫描期间保持为空 ⇒ `itemCount = 0`
    //    ⇒ 什么都不渲染，用户看到的就是「等好几秒才出现图片」。
    final currentPath = widget.imagePath;
    _imageList = [currentPath];
    _currentIndex = 0;

    // 闭包**只能捕获局部量**：写成 `widget.imagePath` 会让闭包隐式捕获 `this`，
    // 而 `this` → `State._element` → 整棵挂载中的 Element 树（含 `_CustomZone`
    // 等不可发送对象），`Isolate.run` 会抛
    // `ArgumentError: Illegal argument in isolate message: object is unsendable`，
    // 旧版又用 `catch (_)` 把它吞成「1 of 1 且不能左右滑动」。
    final dirPath = File(currentPath).parent.path;
    List<String>? sorted;
    try {
      // 列目录 + 逐文件读魔数放入 isolate：DCIM 这类几千文件的目录在主
      // isolate 同步执行会形成 IO 风暴，打开图片时明显卡顿。
      sorted = await Isolate.run(() => _collectImageSiblings(dirPath, currentPath));
    } catch (_) {
      // isolate 不可用（沙盒/权限/平台差异）：交给主 isolate 兜底，
      // 宁可慢一点，也绝不退化成「1 of 1」。
      sorted = null;
    }
    sorted ??= await _collectImageSiblingsOnMain(dirPath, currentPath);

    if (!mounted) return;
    _imageList = sorted;
    // 用归一化路径比较：`a/b` 与 `a\b` 指向同一文件，混用会让 indexOf 失配 ⇒
    // 列表里出现重复项且当前页被错定到第 0 张（又一次退化成「1 of N」）。
    final idx = sorted.indexWhere((e) => _normPath(e) == _normPath(currentPath));
    if (idx == -1) {
      _imageList = [currentPath];
      _currentIndex = 0;
    } else {
      _currentIndex = idx;
    }
    setState(() {});
    // ⚠️ 必须等**新列表这一帧 rebuild 之后**才能跳页：此刻 PageView 还只有占位
    // 的那 1 页，直接 `jumpToPage(_currentIndex)` 会被 clamp 回第 0 页 ——
    // 表现就是「明明扫到了 40 多张，却停在 1 of 42」。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (_pageController.hasClients) {
        if (_currentIndex > 0) _pageController.jumpToPage(_currentIndex);
      } else if (_currentIndex > 0) {
        // 列表先于首帧就绪：用带正确初始页的 controller 替换。
        final old = _pageController;
        _pageController = PageController(initialPage: _currentIndex);
        old.dispose();
      }
    });
  }

  /// 归一化路径，仅用于「是否同一个文件」的比较（不用于读写）。
  static String _normPath(String path) {
    final n = p.normalize(path);
    return Platform.isWindows ? n.toLowerCase() : n;
  }

  /// 去重（按归一化路径）并按归一化路径排序，保证同目录里同一文件只出现一次。
  static List<String> _dedupeSorted(Iterable<String> paths) {
    final seen = <String>{};
    final out = <String>[];
    for (final path in paths) {
      if (seen.add(_normPath(path))) out.add(path);
    }
    out.sort((a, b) => _normPath(a).compareTo(_normPath(b)));
    return out;
  }

  /// 纯函数（供 isolate 执行）：列出 [dirPath] 下的所有图片文件（按名排序），
  /// 并确保 [currentPath] 在结果中。
  static Future<List<String>> _collectImageSiblings(String dirPath, String currentPath) async {
    final images = <String>[];
    for (final f in Directory(dirPath).listSync()) {
      if (f is File && _looksLikeImage(f.path)) images.add(f.path);
    }
    if (File(currentPath).existsSync()) images.add(currentPath);
    return _dedupeSorted(images);
  }

  /// 主 isolate 兜底扫描（isolate 起不来时）：用异步 `list()` 逐条处理，
  /// 每一条都会让出事件循环，不会像 `listSync()` 那样把 UI 顶死。
  static Future<List<String>> _collectImageSiblingsOnMain(String dirPath, String currentPath) async {
    final images = <String>[];
    try {
      await for (final f in Directory(dirPath).list(followLinks: false)) {
        if (f is File && _looksLikeImage(f.path)) images.add(f.path);
      }
    } catch (_) {
      // 目录不可读（受限目录/已卸载）：保持空集，由调用方单张兜底
    }
    if (File(currentPath).existsSync()) {
      images.add(currentPath);
    }
    return _dedupeSorted(images);
  }

  /// 是否为图片文件：**先看扩展名/MIME，只有判不出来时才去读文件头 12 字节**。
  ///
  /// 旧写法把 `_isImageByHeaderSync` 放在 `||` 末尾，而 `lookupMimeType` 对
  /// 已知的非图片类型（`video/mp4`、`application/zip`…）返回的是**非 null 且
  /// 不以 image/ 开头** ⇒ 第一个条件为 false ⇒ 继续求值到第三个条件，
  /// 于是目录里**每一个非图片文件都会被 open/read/close 一次**（包括几百 MB
  /// 的视频）。2000 张的目录累计起来就是肉眼可见的打开延迟。
  static bool _looksLikeImage(String path) {
    final mime = lookupMimeType(path);
    if (mime != null) return mime.startsWith('image/');
    // 扩展名判不出来（无扩展名 / 密文名）时才读魔数。
    if (path.toLowerCase().endsWith('.avif')) return true;
    return _isImageByHeaderSync(path);
  }

  /// 通过文件魔数判断是否为常见图片格式，用于无扩展名或扩展名被加密的图片。
  static bool _isImageByHeaderSync(String path) {
    RandomAccessFile? raf;
    try {
      final file = File(path);
      if (!file.existsSync()) return false;
      // ⚠️ 只读前 12 字节。此前用 readAsBytesSync() 会把整个文件读进内存，
      // 同级目录里若有几百 MB 的视频（加密目录常见），会瞬间 OOM / 卡死主线程，
      // 表现为「打开图片黑屏」。
      raf = file.openSync(mode: FileMode.read);
      final bytes = raf.readSync(12);
      if (bytes.length < 12) return false;
      // JPEG
      if (bytes[0] == 0xFF && bytes[1] == 0xD8 && bytes[2] == 0xFF) return true;
      // PNG
      if (bytes[0] == 0x89 && bytes[1] == 0x50 && bytes[2] == 0x4E && bytes[3] == 0x47) return true;
      // GIF
      if (bytes[0] == 0x47 && bytes[1] == 0x49 && bytes[2] == 0x46 && bytes[3] == 0x38) return true;
      // BMP
      if (bytes[0] == 0x42 && bytes[1] == 0x4D) return true;
      // WebP (RIFF....WEBP)
      if (bytes[0] == 0x52 && bytes[1] == 0x49 && bytes[2] == 0x46 && bytes[3] == 0x46 &&
          bytes[8] == 0x57 && bytes[9] == 0x45 && bytes[10] == 0x42 && bytes[11] == 0x50) {
        return true;
      }
      // HEIC/HEIF (ftyp box 后接 brand)
      final brand = bytes.sublist(4, 12);
      final brandStr = String.fromCharCodes(brand);
      if (brandStr.contains('heic') || brandStr.contains('heix') || brandStr.contains('mif1')) {
        return true;
      }
      return false;
    } catch (_) {
      return false;
    } finally {
      try {
        raf?.closeSync();
      } catch (_) {}
    }
  }

  void _preloadAdjacent(int index) {
    if (widget.siblingItems != null || widget.siblingAssets != null) {
      _loadAssetFile(index);
      _loadAssetFile(index - 1);
      _loadAssetFile(index + 1);
    }
    // 远程图片按需下载（本地路径会被 _loadRemoteFile 自动跳过）。
    _loadRemoteFile(index);
    _loadRemoteFile(index - 1);
    _loadRemoteFile(index + 1);
  }

  /// 取指定页索引对应的文件路径（远程或本地）。
  String? _pathAtIndex(int index) {
    if (widget.siblingItems != null &&
        index >= 0 &&
        index < widget.siblingItems!.length) {
      final item = widget.siblingItems![index];
      if (item is FileSystemEntity) return item.path;
    }
    if (_imageList.isNotEmpty && index >= 0 && index < _imageList.length) {
      return _imageList[index];
    }
    return null;
  }

  /// 远程图片按需下载到本地缓存，完成后刷新显示。
  Future<void> _loadRemoteFile(int index) async {
    final path = _pathAtIndex(index);
    if (path == null || !path.startsWith('remote://')) return;
    if (_remoteCache.containsKey(index) || _remoteLoading.contains(index))
      return;
    _remoteLoading.add(index);
    try {
      final local = await FileManagerProvider.downloadRemoteFileToCache(path);
      if (mounted && local != null) {
        setState(() {
          _remoteCache[index] = File(local);
        });
      }
    } catch (_) {
    } finally {
      _remoteLoading.remove(index);
    }
  }

  Future<void> _loadAssetFile(int index) async {
    final length = widget.siblingItems != null
        ? widget.siblingItems!.length
        : (widget.siblingAssets != null ? widget.siblingAssets!.length : 0);
    if (index < 0 || index >= length) return;
    if (_fileCache.containsKey(index) && _fileCache[index] != null) return;

    if (widget.siblingItems != null) {
      final item = widget.siblingItems![index];
      if (item is AssetEntity) {
        final file = await item.file;
        if (mounted && file != null) {
          setState(() {
            _fileCache[index] = file;
          });
        }
      } else if (item is FileSystemEntity) {
        // 远程路径交由 _loadRemoteFile 处理，这里只缓存本地文件。
        if (!item.path.startsWith('remote://')) {
          setState(() {
            _fileCache[index] = File(item.path);
          });
        }
      }
    } else if (widget.siblingAssets != null) {
      final asset = widget.siblingAssets![index];
      final file = await asset.file;
      if (mounted && file != null) {
        setState(() {
          _fileCache[index] = file;
        });
      }
    }
  }

  /// 切换沉浸式查看：显隐顶部元信息条 / 底部操作按钮，并把「是否显示导航栏」
  /// 上报给壳层 —— 沉浸查看时底部 4-tab 一并收起，唤出操作按钮时再显示。
  void _toggleShellUI() {
    setState(() {
      _showUI = !_showUI;
    });
    ShellNavigator.setChildImmersive(!_showUI);
  }

  @override
  void dispose() {
    // 离开查看器务必复位壳层沉浸态，否则回到首页后底栏会一直藏着。
    ShellNavigator.setChildImmersive(false);
    _pageController.dispose();
    super.dispose();
  }

  /// 获取当前图片的 File 对象
  File? _getCurrentFile() {
    // 流式解密 URL 没有本地文件，所有依赖本地文件的操作应安全降级为 no-op
    if (widget.streamUrl != null) return null;

    if (widget.siblingItems != null &&
        _currentIndex < widget.siblingItems!.length) {
      final item = widget.siblingItems![_currentIndex];
      if (item is AssetEntity) {
        return _fileCache[_currentIndex];
      } else if (item is FileSystemEntity) {
        if (item.path.startsWith('remote://'))
          return _remoteCache[_currentIndex];
        return File(item.path);
      }
    } else if (widget.siblingAssets != null &&
        _currentIndex < widget.siblingAssets!.length) {
      return _fileCache[_currentIndex];
    } else if (_imageList.isNotEmpty && _currentIndex < _imageList.length) {
      final fp = _imageList[_currentIndex];
      if (fp.startsWith('remote://')) return _remoteCache[_currentIndex];
      return File(fp);
    }
    return null;
  }

  /// 获取当前图片对应的相册 [AssetEntity]（仅相册入口有，文件系统/远程为 null）。
  AssetEntity? _getCurrentAsset() {
    if (widget.siblingItems != null &&
        _currentIndex < widget.siblingItems!.length) {
      final item = widget.siblingItems![_currentIndex];
      if (item is AssetEntity) return item;
    } else if (widget.siblingAssets != null &&
        _currentIndex < widget.siblingAssets!.length) {
      return widget.siblingAssets![_currentIndex];
    }
    return null;
  }

  String _humanSize(int bytes) {
    const suffixes = ['B', 'KB', 'MB', 'GB'];
    var s = bytes.toDouble();
    var i = 0;
    while (s >= 1024 && i < suffixes.length - 1) {
      s /= 1024;
      i++;
    }
    return '${s.toStringAsFixed(1)} ${suffixes[i]}';
  }

  /// 刷新当前图片的尺寸/大小/格式，以及右上角 EXIF 拍摄参数副行。
  /// 解析当前页图片的原始尺寸（按高度适配模式需要）。
  /// 仅对本地文件/已缓存远程文件生效；SVG 与流式解密图保持 contained 适配。
  Future<void> _resolveCurrentImageSize() async {
    File? f;
    final path = _pathAtIndex(_currentIndex);
    if (path != null && !path.startsWith('remote://')) {
      f = File(path);
    } else if (_remoteCache[_currentIndex] != null) {
      f = _remoteCache[_currentIndex];
    }
    if (f == null || !f.existsSync()) return;
    try {
      // 优先用文件头解析尺寸（零解码开销，不重复解码正在显示的图）；
      // AVIF 等 image 包不支持的格式回退到下方 provider 完整解码路径。
      ImageEditInfo? info;
      try {
        final header = await _readHeaderBytes(f, 1024 * 1024);
        info = await _editService.readInfo(header);
      } catch (_) {
        info = null;
      }
      final resolved = info;
      if (resolved != null && mounted) {
        setState(() {
          _imageSize = Size(resolved.width.toDouble(), resolved.height.toDouble());
        });
        return;
      }
      final provider = f.path.toLowerCase().endsWith('.avif')
          ? FileAvifImage(f) as ImageProvider
          : FileImage(f) as ImageProvider;
      final completer = Completer<ImageInfo>();
      final listener = ImageStreamListener(
        (info, _) {
          if (!completer.isCompleted) completer.complete(info);
        },
        onError: (e, s) {
          if (!completer.isCompleted) completer.completeError(e);
        },
      );
      final stream = provider.resolve(ImageConfiguration.empty);
      stream.addListener(listener);
      try {
        final info = await completer.future
            .timeout(const Duration(seconds: 3));
        if (mounted) {
          setState(() {
            _imageSize =
                Size(info.image.width.toDouble(), info.image.height.toDouble());
          });
        }
        info.dispose();
      } finally {
        stream.removeListener(listener);
      }
    } catch (_) {}
  }

  /// 只读文件前 [length] 字节（不足则读全部），用于头部解析，避免整文件读入。
  static Future<Uint8List> _readHeaderBytes(File file, int length) async {
    final raf = await file.open(mode: FileMode.read);
    try {
      final size = await raf.length();
      final n = size < length ? size : length;
      return await raf.read(n);
    } finally {
      await raf.close();
    }
  }

  Future<void> _refreshMeta() async {
    final file = _getCurrentFile();
    if (file == null || !file.existsSync()) {
      if (mounted) setState(() => _currentDims = null);
      return;
    }
    try {
      // 只读文件头部（1MB）给解码器取尺寸/格式：此前 readAsBytes() 会把
      // 整张 30MB 原图读进内存，翻页时瞬时分配巨大。极少数把 SOF 写在
      // 1MB 之后的畸形 JPEG 走完整读取回退。
      Uint8List headerBytes;
      try {
        headerBytes = await _readHeaderBytes(file, 1024 * 1024);
      } catch (_) {
        headerBytes = await file.readAsBytes();
      }
      ImageEditInfo info;
      try {
        info = await _editService.readInfo(headerBytes);
      } catch (_) {
        info = await _editService.readInfo(await file.readAsBytes());
      }
      final size = await file.length();
      // 文件修改时间（顶部条显示）
      String? modified;
      try {
        final stat = await file.stat();
        modified = stat.modified
            .toString()
            .replaceFirst('.000', '')
            .split('.')
            .first;
      } catch (_) {
        modified = null;
      }
      // 轻量 EXIF 读取：取设备/快门/ISO/光圈文本字段 + GPS 坐标，不做直方图/网络反编码。
      ImageMetadata? exif;
      try {
        final meta = await ImageMetadataService.instance.readExifOnly(file);
        // readExifOnly 永远非 null；无 EXIF 时 hasExif=false，副行不显示。
        exif = meta.hasExif ? meta : null;
      } catch (_) {
        exif = null;
      }
      // 位置：相册 AssetEntity 优先（零解析），否则回退 EXIF GPS 坐标。
      double? lat, lng;
      final asset = _getCurrentAsset();
      if (asset != null && asset.latitude != null && asset.longitude != null) {
        lat = asset.latitude;
        lng = asset.longitude;
      }
      if (lat == null && exif != null) {
        lat = exif.latitudeNum;
        lng = exif.longitudeNum;
      }
      String? locText;
      if (lat != null && lng != null) {
        locText =
            '${lat.abs().toStringAsFixed(6)}°${lat >= 0 ? 'N' : 'S'}, ${lng.abs().toStringAsFixed(6)}°${lng >= 0 ? 'E' : 'W'}';
      }
      if (!mounted) return;
      setState(() {
        _currentDims = '${info.width} x ${info.height}';
        _currentFormat = info.format;
        _currentSizeStr = _humanSize(size);
        _currentModified = modified;
        _currentExif = exif;
        _currentLocationText = locText;
        _currentLat = lat;
        _currentLng = lng;
      });
    } catch (_) {
      if (mounted) setState(() => _currentDims = null);
    }
  }

  /// 打开图片编辑器（远程图片先下载到缓存）。
  Future<void> _openEditor() async {
    final l10n = L10n.of(context);
    var file = _getCurrentFile();
    if (file == null) return;
    String localPath = file.path;
    if (localPath.startsWith('remote://')) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l10n.editor_downloading)));
      final cached = await FileManagerProvider.downloadRemoteFileToCache(
        localPath,
      );
      if (cached == null) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(l10n.editor_unsupported),
            backgroundColor: Colors.redAccent,
          ),
        );
        return;
      }
      localPath = cached;
    }
    if (!mounted) return;
    final result = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => ImageEditorScreen(imagePath: localPath),
      ),
    );
    if (result == true && mounted) setState(() {});
  }

  /// 顺时针旋转当前图片 90 度并就地保存（覆盖原文件，保留 PNG/JPEG 格式）。
  /// 查看态旋转：仅改变预览角度，不写回文件，瞬时完成、无提示。
  void _rotateImage90() {
    setState(() {
      _rotation += math.pi / 2;
    });
  }

  void _showImageOptions() {
    final l10n = L10n.of(context);
    final file = _getCurrentFile();
    final filePath = file?.path;

    showModalBottomSheet(
      context: context,
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        final theme = Theme.of(ctx);
        final primary = theme.colorScheme.primary;
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        file?.path.split('/').last.split('\\').last ?? 'Image',
                        style: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.bold,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              if (filePath != null && FileUtils.isArchive(filePath)) ...[
                ListTile(
                  leading: Icon(Broken.archive, color: primary, size: 22),
                  title: Text(l10n.ui_extract),
                  onTap: () {
                    Navigator.pop(ctx);
                    _extractArchive();
                  },
                ),
              ],
              ListTile(
                leading: Icon(Broken.document_copy, color: primary, size: 22),
                title: Text(l10n.ui_copy),
                onTap: () {
                  Navigator.pop(ctx);
                  _copyToClipboard();
                },
              ),
              ListTile(
                leading: Icon(Broken.scissor, color: primary, size: 22),
                title: Text(l10n.ui_cut),
                onTap: () {
                  Navigator.pop(ctx);
                  _cutToClipboard();
                },
              ),
              if (filePath != null) ...[
                ListTile(
                  leading: Icon(Broken.folder_open, color: primary, size: 22),
                  title: Text(l10n.msgcd8264f1),
                  onTap: () {
                    Navigator.pop(ctx);
                    _showInLocation();
                  },
                ),
                ListTile(
                  leading: Icon(Broken.edit, color: primary, size: 22),
                  title: Text(l10n.msgc8ce4b36),
                  onTap: () {
                    Navigator.pop(ctx);
                    _renameFile();
                  },
                ),
                ListTile(
                  leading: Icon(Broken.eye, color: primary, size: 22),
                  title: Text(l10n.msg2a4cfb07),
                  onTap: () {
                    Navigator.pop(ctx);
                    _openWith();
                  },
                ),
              ],
              ListTile(
                leading: Icon(Broken.info_circle, color: primary, size: 22),
                title: Text(l10n.ui_properties),
                onTap: () {
                  Navigator.pop(ctx);
                  _showImageInfo();
                },
              ),
              ListTile(
                leading: const Icon(Icons.share_outlined, size: 22),
                title: Text(l10n.ui_share),
                onTap: () {
                  Navigator.pop(ctx);
                  _shareCurrentImage();
                },
              ),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
  }

  void _copyToClipboard() {
    final file = _getCurrentFile();
    if (file == null) return;
    final provider = context.read<FileManagerProvider>();
    provider.setClipboard([file.path], isCut: false);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Copied ${p.basename(file.path)} to clipboard')),
    );
  }

  void _cutToClipboard() {
    final file = _getCurrentFile();
    if (file == null) return;
    final provider = context.read<FileManagerProvider>();
    provider.setClipboard([file.path], isCut: true);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Cut ${p.basename(file.path)} to clipboard')),
    );
  }

  void _showInLocation() {
    final currentPath = _pathAtIndex(_currentIndex);
    if (currentPath == null) return;
    final fmProvider = context.read<FileManagerProvider>();
    // 后台 Browse 已正确加载目录并高亮（showFileInLocation / showRemoteFileInLocation 负责），
    // 唯一缺失的是首页顶层 Tab 仍停留在「分类」页。先置位 navigateToBrowseTab，
    // 由首页 ValueListenableBuilder 在 pop 回首页后完成「切到浏览 Tab」的顶层切换，
    // 本地与远程路径均适用。
    fmProvider.setNavigateToBrowseTab(true);
    // 一次性弹回首页（关闭图片浏览页及可能的上层路由），与全局搜索/最近文件跳转一致
    Navigator.of(context).popUntil((route) => route.isFirst);
    if (currentPath.startsWith('remote://')) {
      fmProvider.showRemoteFileInLocation(currentPath);
    } else {
      fmProvider.showFileInLocation(currentPath);
    }
  }

  Future<void> _renameFile() async {
    final file = _getCurrentFile();
    if (file == null) return;
    final l10n = L10n.of(context);

    final newName = await FileActionDialogs.showRenameDialog(
      context,
      currentName: p.basename(file.path),
      title: l10n.msgc8ce4b36,
      hint: l10n.msgf139c5cf,
      actionText: l10n.msgc8ce4b36,
    );
    if (newName == null) return;
    final trimmed = newName.trim();
    if (trimmed.isEmpty) return;

    try {
      await context.read<FileManagerProvider>().renameFile(
        file.path,
        trimmed,
        context,
      );
      final newPath = p.join(file.parent.path, trimmed);

      if (widget.siblingItems != null &&
          _currentIndex < widget.siblingItems!.length) {
        final item = widget.siblingItems![_currentIndex];
        if (item is FileSystemEntity) {
          widget.siblingItems![_currentIndex] = File(newPath);
        }
      }
      if (_imageList.isNotEmpty && _currentIndex < _imageList.length) {
        _imageList[_currentIndex] = newPath;
      }

      setState(() {});
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(e.toString()),
          backgroundColor: Colors.redAccent,
        ),
      );
    }
  }

  void _openWith() {
    final file = _getCurrentFile();
    if (file == null) return;
    context.read<FileManagerProvider>().showOpenWithSheet(context, file.path);
  }

  void _extractArchive() {
    final file = _getCurrentFile();
    if (file == null) return;
    context.read<FileManagerProvider>().extractArchiveDirectly(
      context,
      file.path,
    );
  }

  Future<void> _shareCurrentImage() async {
    final file = _getCurrentFile();
    if (file != null && file.existsSync()) {
      // 统一走 FolderShareService：JPEG/PNG 图片会弹出「普通分享 / 安全分享」选择
      await FolderShareService.sharePaths(context, [file.path]);
    }
  }

  Future<void> _deleteCurrentImage() async {
    final l10n = L10n.of(context);
    final file = _getCurrentFile();

    // 检查是否为 AssetEntity（相册图片）
    AssetEntity? asset;
    if (widget.siblingItems != null &&
        _currentIndex < widget.siblingItems!.length) {
      final item = widget.siblingItems![_currentIndex];
      if (item is AssetEntity) asset = item;
    } else if (widget.siblingAssets != null &&
        _currentIndex < widget.siblingAssets!.length) {
      asset = widget.siblingAssets![_currentIndex];
    }

    if (file == null && asset == null) return;

    final confirmed = await FileActionDialogs.showDeleteConfirmDialog(
      context,
      title: l10n.ui_delete,
      content: l10n.ui_delete_file_confirm,
    );

    if (confirmed != true) return;

    try {
      // 判断是否为远程路径
      final currentPath = _pathAtIndex(_currentIndex);
      final isRemote =
          currentPath != null && currentPath.startsWith('remote://');

      if (asset != null) {
        // 相册图片通过 PhotoManager 删除
        await PhotoManager.editor.deleteWithIds([asset.id]);
      } else if (file != null && file.existsSync()) {
        await file.delete();
      }
      if (!mounted) return;

      // 本地删除：即时裁剪 provider 列表（无需全量重扫）
      if (!isRemote && currentPath != null) {
        MediaProvider.instance?.pruneDeletedMediaPaths([currentPath]);
      }
      // 远程删除：同步删除远程目录原文件 + 裁剪 provider 列表
      if (isRemote && currentPath != null) {
        await FileManagerProvider.deleteRemotePath(currentPath);
        MediaProvider.instance?.pruneDeletedMediaPaths([currentPath]);
      }

      // 从列表中移除并导航
      final total =
          widget.siblingItems?.length ??
          widget.siblingAssets?.length ??
          _imageList.length;
      if (_imageList.isNotEmpty && _currentIndex < _imageList.length) {
        _imageList.removeAt(_currentIndex);
      }
      // 同步更新 siblingItems，使分类页返回后列表不再残留已删文件
      if (widget.siblingItems != null &&
          _currentIndex < widget.siblingItems!.length) {
        widget.siblingItems!.removeAt(_currentIndex);
      }
      if (total <= 1) {
        Navigator.pop(context);
        return;
      }
      // 调整索引
      final newTotal = total - 1;
      _currentIndex = _currentIndex.clamp(0, newTotal - 1);
      setState(() {});
      // 跳转到新的当前页
      if (_pageController.hasClients) {
        _pageController.jumpToPage(_currentIndex);
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(e.toString()),
          backgroundColor: Colors.redAccent,
        ),
      );
    }
  }

  void _showImageInfo() async {
    final l10n = L10n.of(context);
    final file = _getCurrentFile();
    if (file == null) return;

    String fileName = file.path.split('/').last.split('\\').last;
    String filePath = file.path;
    String sizeStr = '-';
    String modifiedStr = '-';

    try {
      if (file.existsSync()) {
        final stat = await file.stat();
        const suffixes = ['B', 'KB', 'MB', 'GB'];
        var s = stat.size.toDouble();
        var i = 0;
        while (s >= 1024 && i < suffixes.length - 1) {
          s /= 1024;
          i++;
        }
        sizeStr = '${s.toStringAsFixed(1)} ${suffixes[i]}';
        modifiedStr = stat.modified.toString().split('.').first;
      }
    } catch (_) {}

    if (!mounted) return;

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.ui_properties),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              fileName,
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
            ),
            const SizedBox(height: 12),
            _infoRow(l10n.ui_path, filePath),
            const SizedBox(height: 8),
            _infoRow(l10n.ui_size, sizeStr),
            const SizedBox(height: 8),
            _infoRow(l10n.img_dimensions, _currentDims ?? '-'),
            const SizedBox(height: 8),
            _infoRow(l10n.msg1303e638, modifiedStr),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(l10n.ui_close),
          ),
        ],
      ),
    );
  }

  Widget _infoRow(String label, String value) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '$label: ',
          style: TextStyle(
            fontSize: 13,
            color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.6),
          ),
        ),
        Expanded(child: Text(value, style: const TextStyle(fontSize: 13))),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final int totalCount = widget.siblingItems != null
        ? widget.siblingItems!.length
        : (widget.siblingAssets != null
              ? widget.siblingAssets!.length
              : _imageList.length);
    String currentTitle = L10n.of(context).image_fallback_title;
    if (widget.siblingItems != null &&
        _currentIndex < widget.siblingItems!.length) {
      final item = widget.siblingItems![_currentIndex];
      if (item is AssetEntity) {
        currentTitle = item.title ?? L10n.of(context).image_fallback_title;
      } else if (item is FileSystemEntity) {
        currentTitle = item.path.split('/').last.split('\\').last;
      }
    } else if (widget.siblingAssets != null &&
        _currentIndex < widget.siblingAssets!.length) {
      currentTitle = widget.siblingAssets![_currentIndex].title ?? L10n.of(context).image_fallback_title;
    } else if (_imageList.isNotEmpty && _currentIndex < _imageList.length) {
      currentTitle = _imageList[_currentIndex].split('/').last.split('\\').last;
    }

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: const SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: Brightness.light,
      ),
      child: Scaffold(
        backgroundColor: Colors.black,
        extendBodyBehindAppBar: true,
        appBar: _showUI
            ? AppBar(
                backgroundColor: Colors.black.withValues(alpha: 0.55),
                elevation: 0,
                leading: Padding(
                  padding: const EdgeInsets.all(8.0),
                  child: Container(
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.15),
                      shape: BoxShape.circle,
                    ),
                    child: IconButton(
                      icon: const Icon(
                        Icons.arrow_back_ios_new_rounded,
                        color: Colors.white,
                        size: 18,
                      ),
                      onPressed: () => Navigator.pop(context),
                    ),
                  ),
                ),
                title: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      currentTitle,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 17,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 0.3,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${_currentIndex + 1} of $totalCount',
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.7),
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
                centerTitle: false,
                titleSpacing: 0,
                actions: [
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: PopupMenuButton<int>(
                      tooltip: L10n.of(context).ui_image_fit_mode,
                      icon: Icon(
                        _fitMode == 1
                            ? Icons.height_rounded
                            : _fitMode == 2
                                ? Icons.crop_original_rounded
                                : Icons.fit_screen_rounded,
                        color: Colors.white,
                      ),
                      color: const Color(0xFF1E1E2E),
                      onSelected: (m) {
                        setState(() => _fitMode = m);
                        PreferencesService.saveImageFitMode(m);
                        if (m == 1) _resolveCurrentImageSize();
                      },
                      itemBuilder: (_) => [
                        PopupMenuItem(
                          value: 0,
                          child: Text(
                            L10n.of(context).ui_image_fit_width,
                            style: TextStyle(
                              color: _fitMode == 0
                                  ? Theme.of(context).colorScheme.primary
                                  : Colors.white,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ),
                        PopupMenuItem(
                          value: 1,
                          child: Text(
                            L10n.of(context).ui_image_fit_height,
                            style: TextStyle(
                              color: _fitMode == 1
                                  ? Theme.of(context).colorScheme.primary
                                  : Colors.white,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ),
                        PopupMenuItem(
                          value: 2,
                          child: Text(
                            L10n.of(context).ui_image_fit_original,
                            style: TextStyle(
                              color: _fitMode == 2
                                  ? Theme.of(context).colorScheme.primary
                                  : Colors.white,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              )
            : null,
        body: Stack(
          children: [
            Dismissible(
              key: const ValueKey('image_viewer_dismissible'),
              direction: _isZoomed
                  ? DismissDirection.none
                  : DismissDirection.vertical,
              onDismissed: (_) => Navigator.pop(context),
              dismissThresholds: const {
                DismissDirection.down: 0.2,
                DismissDirection.up: 0.2,
              },
              child: GestureDetector(
                onTap: () {
                  _toggleShellUI();
                },
                child: PhotoViewGallery.builder(
                  scrollPhysics: _isZoomed
                      ? const NeverScrollableScrollPhysics()
                      : const BouncingScrollPhysics(),
                  pageController: _pageController,
                  itemCount: totalCount,
                  onPageChanged: (index) {
                    setState(() {
                      _currentIndex = index;
                      _rotation = 0.0; // 切换图片重置查看态旋转
                      _imageSize = null;
                    });
                    if (_fitMode == 1) _resolveCurrentImageSize();
                    _preloadAdjacent(index);
                    _refreshMeta();
                  },
                  scaleStateChangedCallback: (state) {
                    setState(() {
                      _isZoomed = state != PhotoViewScaleState.initial;
                    });
                  },
                  builder: (context, index) {
                    File? imgFile;
                    Uint8List? thumbData;
                    String tagKey = 'img_$index';

                    // 加密图片：直接以 NetworkImage 渲染流式解密 URL
                    if (widget.streamUrl != null) {
                      return PhotoViewGalleryPageOptions.customChild(
                        child: Transform.rotate(
                          angle: _rotation,
                          child: Image(
                            image: NetworkImage(widget.streamUrl!),
                            fit: BoxFit.contain,
                            loadingBuilder: (ctx, child, loading) {
                              if (loading == null) return child;
                              return const Center(
                                child: CircularProgressIndicator(
                                  color: Colors.white70,
                                ),
                              );
                            },
                          ),
                        ),
                        initialScale: PhotoViewComputedScale.contained,
                        minScale: PhotoViewComputedScale.contained,
                        maxScale: PhotoViewComputedScale.covered * 4,
                        heroAttributes: const PhotoViewHeroAttributes(tag: 'crypt_stream'),
                        onTapUp: (context, details, controllerValue) {
                          _toggleShellUI();
                        },
                      );
                    }

                    if (widget.siblingItems != null) {
                      final item = widget.siblingItems![index];
                      if (item is AssetEntity) {
                        tagKey = item.id;
                        imgFile = _fileCache[index];
                        thumbData = ThumbnailCache.getCached(item.id);
                      } else if (item is FileSystemEntity) {
                        tagKey = item.path;
                        if (item.path.startsWith('remote://')) {
                          imgFile = _remoteCache[index];
                          if (imgFile == null) _loadRemoteFile(index);
                        } else {
                          imgFile = File(item.path);
                        }
                      }
                    } else if (widget.siblingAssets != null) {
                      final asset = widget.siblingAssets![index];
                      tagKey = asset.id;
                      imgFile = _fileCache[index];
                      thumbData = ThumbnailCache.getCached(asset.id);
                    } else {
                      final path = _imageList[index];
                      tagKey = path;
                      if (path.startsWith('remote://')) {
                        imgFile = _remoteCache[index];
                        if (imgFile == null) _loadRemoteFile(index);
                      } else {
                        imgFile = File(path);
                      }
                    }

                    // 远程图片下载中：显示加载指示，避免空白。
                    if (imgFile == null &&
                        _pathAtIndex(index)?.startsWith('remote://') == true) {
                      return PhotoViewGalleryPageOptions.customChild(
                        child: const Center(
                          child: CircularProgressIndicator(
                            color: Colors.white70,
                          ),
                        ),
                        heroAttributes: PhotoViewHeroAttributes(tag: tagKey),
                      );
                    }

                    final bool isValidFile =
                        imgFile != null &&
                        imgFile.existsSync() &&
                        imgFile.lengthSync() > 16;
                    final bool isAvif =
                        imgFile != null &&
                        imgFile.path.toLowerCase().endsWith('.avif');
                    final bool isSvg =
                        imgFile != null && FileUtils.isSvg(imgFile.path);

                    if (isSvg) {
                      return PhotoViewGalleryPageOptions.customChild(
                        child: SvgPicture.file(imgFile, fit: BoxFit.contain),
                        initialScale: PhotoViewComputedScale.contained,
                        minScale: PhotoViewComputedScale.contained,
                        maxScale: PhotoViewComputedScale.covered * 4,
                        heroAttributes: PhotoViewHeroAttributes(tag: tagKey),
                      );
                    }

                    final ImageProvider provider = isValidFile
                        ? (isAvif ? FileAvifImage(imgFile) : FileImage(imgFile))
                              as ImageProvider
                        : (thumbData != null
                              ? MemoryImage(thumbData)
                              : MemoryImage(_kTransparentImage));

                    // 显示模式：0=适应宽度(contained) 1=适应高度(屏高/图高) 2=原始大小(1.0)
                    final double? fitScale = _fitMode == 0
                        ? null
                        : (_fitMode == 2
                            ? 1.0
                            : (_imageSize != null && _imageSize!.height > 0
                                ? MediaQuery.sizeOf(context).height /
                                    _imageSize!.height
                                : null));
                    return PhotoViewGalleryPageOptions.customChild(
                      child: Transform.rotate(
                        angle: _rotation,
                        child: Image(image: provider, fit: BoxFit.contain),
                      ),
                      initialScale: fitScale ?? PhotoViewComputedScale.contained,
                      minScale: fitScale ?? PhotoViewComputedScale.contained,
                      maxScale: PhotoViewComputedScale.covered * 4,
                      heroAttributes: PhotoViewHeroAttributes(tag: tagKey),
                      onTapUp: (context, details, controllerValue) {
                        _toggleShellUI();
                      },
                    );
                  },
                ),
              ),
            ),
            if (_showUI) ...[
              // 顶部元信息条（EXIF + 尺寸 / 大小 / 格式）
              Positioned(left: 0, right: 0, top: 0, child: _buildTopMetaBar()),
              // 底部操作按钮栏：分享 · 旋转 · 编辑 · 删除 · 更多（三点）
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: _buildBottomActionBar(),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// 右上角 EXIF 副行：光圈 · 快门 · ISO · 设备，无相关字段时自动跳过。
  String _buildExifSubtitle(ImageMetadata exif) {
    final parts = <String>[];
    if (exif.aperture != null && exif.aperture!.isNotEmpty) {
      // service 返回形如 "F:2.8"，统一为 "f/2.8"。
      final v = exif.aperture!.startsWith('F:')
          ? exif.aperture!.substring(2)
          : exif.aperture!;
      parts.add('f/$v');
    }
    if (exif.shutter != null && exif.shutter!.isNotEmpty) {
      // service 返回形如 "S:1/100" 或 "S:2.0s"，去掉前缀并补 s。
      final v = exif.shutter!.startsWith('S:')
          ? exif.shutter!.substring(2)
          : exif.shutter!;
      parts.add(v.endsWith('s') ? v : '$v');
    }
    if (exif.iso != null && exif.iso!.isNotEmpty) {
      parts.add('ISO${exif.iso}');
    }
    if (exif.device != null && exif.device!.isNotEmpty) {
      parts.add(exif.device!);
    }
    return parts.join('  ·  ');
  }

  /// 点击位置信息，用 geo: URI 唤起系统地图查看拍摄坐标（离线可用，无需 API key）。
  Future<void> _openLocationInMap() async {
    final lat = _currentLat;
    final lng = _currentLng;
    if (lat == null || lng == null) return;
    final q = '${lat.toStringAsFixed(6)},${lng.toStringAsFixed(6)}';
    final uri = Uri.parse('geo:$q?q=$q');
    try {
      if (await canLaunchUrl(uri)) await launchUrl(uri);
    } catch (_) {
      // 无地图 App 时静默忽略。
    }
  }

  /// 顶部元信息条：显示 EXIF 拍摄参数（如有）+ 尺寸 / 大小 / 格式。
  Widget _buildTopMetaBar() {
    final l10n = L10n.of(context);
    final dims = _currentDims ?? '…';
    final size = _currentSizeStr ?? '…';
    final fmt = _currentFormat ?? '…';
    final modified = _currentModified ?? '…';
    final exifSubtitle = _currentExif != null
        ? _buildExifSubtitle(_currentExif!)
        : '';
    // 仅当存在实际拍摄参数字段（光圈/快门/ISO/设备…）才显示标题，
    // 避免「有 EXIF 块但无参数字段」的图片误显示拍摄参数标题。
    final hasExif = exifSubtitle.isNotEmpty;
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Colors.black.withValues(alpha: 0.6), Colors.transparent],
        ),
      ),
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 20),
      child: SafeArea(
        bottom: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 尺寸/大小（左，自适应占满剩余空间） + 格式/时间（右，wrap content，整体右移）。
            // 右侧列内部左对齐，使"格式"和"时间"对齐；整体不 Expanded，靠左侧 Expanded 推到右边，
            // 避免英文 Dimensions/Format/Time 标签过长时挤压左侧尺寸值。
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _infoLine(l10n.img_dimensions, dims),
                      const SizedBox(height: 4),
                      _infoLine(l10n.ui_size, size),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _infoLine(l10n.img_info_format, fmt),
                    const SizedBox(height: 4),
                    _infoLine(l10n.img_info_file_time, modified),
                  ],
                ),
              ],
            ),
            // 拍摄参数最下方：有则显示，无则不显示（切换图片时不突兀）。
            if (hasExif) ...[
              const SizedBox(height: 6),
              _infoLine(l10n.img_info_camera_params, exifSubtitle),
            ],
            // 拍摄位置（GPS）：有则显示，点击用 geo: 唤起地图查看，无则不显示。
            if (_currentLocationText != null) ...[
              const SizedBox(height: 6),
              GestureDetector(
                onTap: _openLocationInMap,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: _infoLine(
                        l10n.img_info_shoot_location,
                        _currentLocationText!,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// 顶部信息条的单行：标签在左、值在右。
  Widget _infoLine(String label, String value) {
    return RichText(
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      text: TextSpan(
        children: [
          TextSpan(
            text: '$label: ',
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.6),
              fontSize: 12,
              fontWeight: FontWeight.w500,
            ),
          ),
          TextSpan(
            text: value,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 12,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }

  /// 底部操作按钮栏：分享 · 旋转 · 编辑 · 删除 · 更多（三点），从左到右。
  Widget _buildBottomActionBar() {
    final l10n = L10n.of(context);
    final items = <Widget>[
      _ActionBarButton(
        icon: Icons.share_outlined,
        label: l10n.ui_share,
        onTap: _shareCurrentImage,
      ),
      _ActionBarButton(
        icon: Icons.rotate_right_rounded,
        label: l10n.img_rotate,
        onTap: _rotateImage90,
      ),
      _ActionBarButton(
        icon: Broken.edit_2,
        label: l10n.menu_edit_image,
        onTap: _openEditor,
      ),
      _ActionBarButton(
        icon: Broken.trash,
        label: l10n.ui_delete,
        color: Colors.redAccent,
        onTap: _deleteCurrentImage,
      ),
      _ActionBarButton(
        icon: Broken.more,
        label: l10n.ui_more,
        onTap: _showImageOptions,
      ),
    ];
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.bottomCenter,
          end: Alignment.topCenter,
          colors: [Colors.black.withValues(alpha: 0.75), Colors.transparent],
        ),
      ),
      padding: const EdgeInsets.fromLTRB(12, 18, 12, 12),
      child: SafeArea(
        top: false,
        child: Row(children: [for (final item in items) Expanded(child: item)]),
      ),
    );
  }
}

/// 底部操作栏单个按钮（图标在上、文字在下）。
class _ActionBarButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final Color? color;

  const _ActionBarButton({
    required this.icon,
    required this.label,
    required this.onTap,
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    final tint = color ?? Colors.white;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: tint, size: 24),
            const SizedBox(height: 4),
            AutoSizeText(
              label,
              minFontSize: 8,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: tint,
                fontSize: 11,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
