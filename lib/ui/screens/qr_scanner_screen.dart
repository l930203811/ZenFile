import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';
import 'package:image/image.dart' as img;
import 'package:permission_handler/permission_handler.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:zxing2/qrcode.dart';
// zxing2 0.2.4 未从公共库导出 PlanarYUVLuminanceSource，只能按内部路径导入。
// ignore: implementation_imports
import 'package:zxing2/src/planar_yuv_luminance_source.dart';

import '../../core/icon_fonts/broken_icons.dart';
import '../../l10n/generated/app_localizations.dart';

/// 实时帧解码参数（传给后台 isolate）。
class _FrameDecodeJob {
  const _FrameDecodeJob(this.bytes, this.width, this.height, this.stride);

  final Uint8List bytes;
  final int width;
  final int height;
  final int stride;
}

/// 在后台 isolate 用 zxing2 解码 YUV 亮度平面（纯 Dart 解码是 CPU 密集操作，
/// 放在 UI isolate 会造成预览卡顿）。返回识别到的文本，未识别返回 null。
String? _decodeFrameIsolate(_FrameDecodeJob job) {
  try {
    // zxing2 0.2.4 的 PlanarYUV 用位置参数，数据需 Int8List 视图；
    // dataWidth 用 bytesPerRow（YUV 行含对齐 padding），crop 到真实 width×height。
    final yuv = Int8List.sublistView(job.bytes);
    final source = PlanarYUVLuminanceSource(
      yuv,
      job.stride,
      job.height,
      0,
      0,
      job.width,
      job.height,
      false,
    );
    final bitmap = BinaryBitmap(HybridBinarizer(source));
    final result = QRCodeReader().decode(bitmap);
    return result.text;
  } on NotFoundException {
    return null;
  } catch (_) {
    return null;
  }
}

/// 相册图片解码同样放后台 isolate（大图解码 + 扫描耗时）。
String? _decodeImageIsolate(List<int> bytes) {
  try {
    final image = img.decodeImage(Uint8List.fromList(bytes));
    if (image == null) return null;
    final rgb = image.convert(numChannels: 4);
    final source = RGBLuminanceSource(
      image.width,
      image.height,
      rgb.getBytes(order: img.ChannelOrder.bgra).buffer.asInt32List(),
    );
    final bitmap = BinaryBitmap(HybridBinarizer(source));
    final result = QRCodeReader().decode(bitmap);
    return result.text;
  } catch (_) {
    return null;
  }
}

/// 扫一扫页面：使用相机实时识别二维码 / 条形码，
/// 检测到内容后弹出结果卡片，支持复制、打开链接（URL）、继续扫描。
///
/// 解码引擎为 zxing2（ZXing 的纯 Dart 移植，Apache-2.0）+ camera（系统 CameraX），
/// 完全开源，不含 Google ML Kit 等闭源二进制（issue #40）。
class QrScannerScreen extends StatefulWidget {
  const QrScannerScreen({super.key});

  @override
  State<QrScannerScreen> createState() => _QrScannerScreenState();
}

class _QrScannerScreenState extends State<QrScannerScreen>
    with WidgetsBindingObserver {
  List<CameraDescription> _cameras = const [];
  CameraController? _controller;
  bool _torchEnabled = false;
  bool _hasResult = false;
  bool _decoding = false;
  int _cameraIndex = 0;
  String? _lastResult;
  String? _initError;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initCamera();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _controller?.stopImageStream();
    _controller?.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;
    if (state == AppLifecycleState.resumed) {
      if (!controller.value.isStreamingImages) _startStream();
    } else if (!controller.value.isStreamingImages) {
      controller.stopImageStream();
    }
  }

  Future<void> _initCamera() async {
    try {
      final status = await Permission.camera.request();
      if (!status.isGranted) {
        if (mounted) setState(() => _initError = 'permission');
        return;
      }
      _cameras = await availableCameras();
      if (_cameras.isEmpty) {
        if (mounted) setState(() => _initError = 'none');
        return;
      }
      // 优先后置摄像头
      _cameraIndex = _cameras.indexWhere(
        (c) => c.lensDirection == CameraLensDirection.back,
      );
      if (_cameraIndex < 0) _cameraIndex = 0;
      await _setupController(_cameraIndex);
    } catch (_) {
      if (mounted) setState(() => _initError = 'error');
    }
  }

  Future<void> _setupController(int index) async {
    final previous = _controller;
    await previous?.stopImageStream();
    previous?.dispose();

    final controller = CameraController(
      _cameras[index],
      ResolutionPreset.medium,
      enableAudio: false,
      imageFormatGroup: ImageFormatGroup.yuv420,
    );
    _controller = controller;
    try {
      await controller.initialize();
      if (!mounted) return;
      setState(() {
        _cameraIndex = index;
        _initError = null;
      });
      if (!_hasResult) _startStream();
    } catch (_) {
      if (mounted) setState(() => _initError = 'error');
    }
  }

  void _startStream() {
    final controller = _controller;
    if (controller == null ||
        !controller.value.isInitialized ||
        controller.value.isStreamingImages ||
        _decoding) {
      return;
    }
    controller.startImageStream(_onFrame);
  }

  /// 相机每帧回调：节流 + 后台解码，避免 CPU 堆积。
  void _onFrame(CameraImage image) {
    if (_hasResult || _decoding || image.planes.isEmpty) return;
    _decoding = true;
    final plane = image.planes.first;
    final job = _FrameDecodeJob(
      plane.bytes,
      image.width,
      image.height,
      plane.bytesPerRow,
    );
    Isolate.run(() => _decodeFrameIsolate(job)).then((value) {
      _decoding = false;
      if (!mounted) return;
      if (value != null && value.isNotEmpty && value != _lastResult) {
        HapticFeedback.mediumImpact();
        setState(() {
          _hasResult = true;
          _lastResult = value;
        });
        _controller?.stopImageStream();
        _showResultDialog(value);
      }
    }).catchError((_) {
      _decoding = false;
    });
  }

  bool _isUrl(String value) {
    final uri = Uri.tryParse(value);
    return uri != null && (uri.isScheme('http') || uri.isScheme('https'));
  }

  Future<void> _openUrl(String value) async {
    final uri = Uri.tryParse(value);
    if (uri == null) return;
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  Future<void> _copyToClipboard(String value) async {
    await Clipboard.setData(ClipboardData(text: value));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(L10n.of(context).scan_copied),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  void _showResultDialog(String value) {
    final l10n = L10n.of(context);
    final isUrl = _isUrl(value);
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: Row(
          children: [
            const Icon(Broken.scan, size: 22),
            const SizedBox(width: 8),
            Expanded(child: Text(l10n.scan_result_title)),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.05),
                borderRadius: BorderRadius.circular(10),
              ),
              child: SelectableText(
                value,
                style: const TextStyle(fontSize: 14, height: 1.4),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              _resumeScanning();
            },
            child: Text(l10n.scan_continue),
          ),
          TextButton(
            onPressed: () => _copyToClipboard(value),
            child: Text(l10n.scan_copy),
          ),
          if (isUrl)
            FilledButton(
              onPressed: () => _openUrl(value),
              child: Text(l10n.scan_open_link),
            ),
        ],
      ),
    );
  }

  void _resumeScanning() {
    setState(() {
      _hasResult = false;
      _lastResult = null;
    });
    _startStream();
  }

  Future<void> _toggleTorch() async {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;
    try {
      final next = !_torchEnabled;
      await controller.setFlashMode(next ? FlashMode.torch : FlashMode.off);
      if (!mounted) return;
      setState(() => _torchEnabled = next);
    } catch (_) {}
  }

  Future<void> _switchCamera() async {
    if (_cameras.length < 2) return;
    final next = (_cameraIndex + 1) % _cameras.length;
    await _setupController(next);
  }

  /// 从相册选择图片并识别其中的二维码 / 条形码（zxing2 后台解码）。
  Future<void> _pickFromGallery() async {
    final l10n = L10n.of(context);
    try {
      final result = await FilePicker.pickFiles(type: FileType.image);
      if (result == null || result.files.isEmpty) return;
      final path = result.files.single.path;
      if (path == null) return;

      // 暂停实时扫描，避免与图片分析冲突
      await _controller?.stopImageStream();

      final bytes = await File(path).readAsBytes();
      final value = await Isolate.run(() => _decodeImageIsolate(bytes));
      if (!mounted) return;

      if (value != null && value.isNotEmpty) {
        HapticFeedback.mediumImpact();
        setState(() {
          _hasResult = true;
          _lastResult = value;
        });
        _showResultDialog(value);
        return;
      }

      // 未识别到条码：提示并恢复实时扫描
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(l10n.scan_no_barcode),
          duration: const Duration(seconds: 2),
        ),
      );
      _resumeScanning();
    } catch (_) {
      if (!mounted) return;
      _resumeScanning();
    }
  }

  Widget _buildPreview(ThemeData theme, L10n l10n) {
    final controller = _controller;
    if (_initError != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline_rounded,
                  color: Colors.white, size: 48),
              const SizedBox(height: 12),
              Text(
                l10n.scan_camera_error,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white, fontSize: 14),
              ),
            ],
          ),
        ),
      );
    }
    if (controller == null || !controller.value.isInitialized) {
      return const Center(
        child: CircularProgressIndicator(color: Colors.white),
      );
    }
    return Stack(
      fit: StackFit.expand,
      children: [
        CameraPreview(controller),
        // 扫描框遮罩
        Center(
          child: Container(
            width: 240,
            height: 240,
            decoration: BoxDecoration(
              border: Border.all(color: theme.colorScheme.primary, width: 2.5),
              borderRadius: BorderRadius.circular(16),
            ),
          ),
        ),
        // 底部提示
        Positioned(
          bottom: 40,
          left: 0,
          right: 0,
          child: Center(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Text(
                l10n.scan_hint,
                style: const TextStyle(color: Colors.white, fontSize: 13),
              ),
            ),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = L10n.of(context);
    final theme = Theme.of(context);

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(l10n.toolbox_scan),
        actions: [
          IconButton(
            tooltip: l10n.scan_torch,
            icon: Icon(
              _torchEnabled ? Icons.flash_on_rounded : Icons.flash_off_rounded,
              color: _torchEnabled ? Colors.amber : Colors.white,
            ),
            onPressed: _toggleTorch,
          ),
          IconButton(
            tooltip: l10n.scan_switch_camera,
            icon: const Icon(Icons.flip_camera_ios_rounded, color: Colors.white),
            onPressed: _switchCamera,
          ),
          IconButton(
            tooltip: l10n.scan_from_gallery,
            icon: const Icon(Icons.photo_library_rounded, color: Colors.white),
            onPressed: _pickFromGallery,
          ),
        ],
      ),
      body: _buildPreview(theme, l10n),
    );
  }
}
