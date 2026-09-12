import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../core/icon_fonts/broken_icons.dart';
import '../../l10n/generated/app_localizations.dart';

/// 扫一扫页面：使用相机实时识别二维码 / 条形码，
/// 检测到内容后弹出结果卡片，支持复制、打开链接（URL）、继续扫描。
class QrScannerScreen extends StatefulWidget {
  const QrScannerScreen({super.key});

  @override
  State<QrScannerScreen> createState() => _QrScannerScreenState();
}

class _QrScannerScreenState extends State<QrScannerScreen>
    with WidgetsBindingObserver {
  late final MobileScannerController _controller;
  bool _torchEnabled = false;
  bool _isFrontCamera = false;
  bool _hasResult = false;
  String? _lastResult;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _controller = MobileScannerController(
      detectionSpeed: DetectionSpeed.normal,
      facing: CameraFacing.back,
      returnImage: false,
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _controller.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    switch (state) {
      case AppLifecycleState.resumed:
        _controller.start();
        break;
      case AppLifecycleState.inactive:
      case AppLifecycleState.paused:
      case AppLifecycleState.detached:
      case AppLifecycleState.hidden:
        _controller.stop();
        break;
    }
  }

  void _onDetect(BarcodeCapture capture) {
    if (_hasResult) return;
    final barcodes = capture.barcodes;
    if (barcodes.isEmpty) return;
    final value = barcodes.first.rawValue;
    if (value == null || value.isEmpty) return;
    if (value == _lastResult) return;
    setState(() {
      _hasResult = true;
      _lastResult = value;
    });
    HapticFeedback.mediumImpact();
    _controller.stop();
    _showResultDialog(value);
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
                color: Theme.of(context).colorScheme.onSurface.withOpacity(0.05),
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
    _controller.start();
  }

  Future<void> _toggleTorch() async {
    await _controller.toggleTorch();
    if (!mounted) return;
    setState(() => _torchEnabled = !_torchEnabled);
  }

  Future<void> _switchCamera() async {
    await _controller.switchCamera();
    if (!mounted) return;
    setState(() => _isFrontCamera = !_isFrontCamera);
  }

  /// 从相册选择图片并识别其中的二维码 / 条形码。
  Future<void> _pickFromGallery() async {
    final l10n = L10n.of(context);
    try {
      final result = await FilePicker.pickFiles(type: FileType.image);
      if (result == null || result.files.isEmpty) return;
      final path = result.files.single.path;
      if (path == null) return;

      // 暂停实时扫描，避免与图片分析冲突
      await _controller.stop();

      final capture = await _controller.analyzeImage(path);
      if (!mounted) return;

      if (capture != null && capture.barcodes.isNotEmpty) {
        final value = capture.barcodes.first.rawValue;
        if (value != null && value.isNotEmpty) {
          HapticFeedback.mediumImpact();
          setState(() {
            _hasResult = true;
            _lastResult = value;
          });
          _showResultDialog(value);
          return;
        }
      }

      // 未识别到条码：提示并恢复实时扫描
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(l10n.scan_no_barcode),
          duration: const Duration(seconds: 2),
        ),
      );
      _controller.start();
    } catch (_) {
      if (!mounted) return;
      _controller.start();
    }
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
      body: Stack(
        children: [
          MobileScanner(
            controller: _controller,
            onDetect: _onDetect,
            errorBuilder: (context, error) {
              return Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.error_outline_rounded, color: Colors.white, size: 48),
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
            },
          ),
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
                  color: Colors.black.withOpacity(0.5),
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
      ),
    );
  }
}
