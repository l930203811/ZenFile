import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import '../../core/icon_fonts/broken_icons.dart';
import '../../services/image_edit_service.dart';
import 'package:zenfile/l10n/generated/app_localizations.dart';

enum _EditorTab { adjust, filters, resize, rotate, crop }

enum _CropDragMode { none, move, tl, tr, bl, br }

class ImageEditorScreen extends StatefulWidget {
  final String imagePath; // 本地文件路径

  const ImageEditorScreen({super.key, required this.imagePath});

  @override
  State<ImageEditorScreen> createState() => _ImageEditorScreenState();
}

class _ImageEditorScreenState extends State<ImageEditorScreen> {
  final ImageEditService _service = ImageEditService.instance;

  Uint8List? _bytes;
  ImageEditInfo? _info;
  bool _loading = true;
  bool _unsupported = false;

  ImageEditParams _params = const ImageEditParams();
  Uint8List? _previewBytes;
  bool _processing = false;

  _EditorTab _tab = _EditorTab.adjust;
  bool get _cropTabActive => _tab == _EditorTab.crop;

  // 裁剪交互（归一化 0..1，相对原图）
  Rect? _cropRect;
  _CropDragMode _dragMode = _CropDragMode.none;
  Offset _dragStartNorm = Offset.zero;
  Rect _dragStartRect = Rect.zero;

  // 预览显示区域（用于手势坐标映射）
  Rect _displayRect = Rect.zero;

  int _quality = 90;
  bool get _isPng => _info?.format == 'PNG';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final file = File(widget.imagePath);
      final bytes = await file.readAsBytes();
      final info = await _service.readInfo(bytes);
      if (!mounted) return;
      setState(() {
        _bytes = bytes;
        _info = info;
        _loading = false;
        _cropRect = Rect.fromLTRB(0, 0, 1, 1);
      });
      _recomputePreview();
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _unsupported = true;
      });
    }
  }

  Future<void> _recomputePreview() async {
    if (_bytes == null || _info == null) return;
    if (_processing) return;
    setState(() => _processing = true);
    final paramsForPreview = _cropTabActive
        ? _params.copyWith(cropX: null, cropY: null, cropW: null, cropH: null)
        : _params;
    try {
      final out = await _service.edit(
        _bytes!,
        paramsForPreview,
        quality: _quality,
        preview: true,
        isPng: _isPng,
      );
      if (!mounted) return;
      setState(() {
        _previewBytes = out;
        _processing = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _processing = false);
    }
  }

  void _schedulePreview() {
    _recomputePreview();
  }

  void _commitCropIfNeeded() {
    if (_cropTabActive) {
      // 退出裁剪页时把裁剪框写入参数
      final r = _cropRect;
      if (r != null && (r.left > 0.001 || r.top > 0.001 || r.right < 0.999 || r.bottom < 0.999)) {
        _params = _params.copyWith(
          cropX: r.left,
          cropY: r.top,
          cropW: r.right - r.left,
          cropH: r.bottom - r.top,
        );
      } else {
        _params = _params.copyWith(cropX: null, cropY: null, cropW: null, cropH: null);
      }
    }
  }

  void _switchTab(_EditorTab tab) {
    if (tab == _tab) return;
    _commitCropIfNeeded();
    if (tab == _EditorTab.crop && _cropRect == null) {
      _cropRect = Rect.fromLTRB(0, 0, 1, 1);
    }
    setState(() => _tab = tab);
    _recomputePreview();
  }

  Rect _computeDisplayRect(Size area) {
    if (_info == null || area.isEmpty) return Rect.zero;
    final ar = _info!.width / _info!.height;
    double w, h;
    if (area.width / area.height > ar) {
      h = area.height;
      w = h * ar;
    } else {
      w = area.width;
      h = w / ar;
    }
    return Rect.fromLTWH((area.width - w) / 2, (area.height - h) / 2, w, h);
  }

  // ---- 裁剪手势 ----
  void _onCropPanStart(Offset local) {
    final disp = _displayRect;
    if (disp.isEmpty || _cropRect == null) return;
    final norm = Offset(
      ((local.dx - disp.left) / disp.width).clamp(0.0, 1.0),
      ((local.dy - disp.top) / disp.height).clamp(0.0, 1.0),
    );
    const thresh = 0.06;
    final r = _cropRect!;
    if ((norm.dx - r.left).abs() < thresh && (norm.dy - r.top).abs() < thresh) {
      _dragMode = _CropDragMode.tl;
    } else if ((norm.dx - r.right).abs() < thresh && (norm.dy - r.top).abs() < thresh) {
      _dragMode = _CropDragMode.tr;
    } else if ((norm.dx - r.left).abs() < thresh && (norm.dy - r.bottom).abs() < thresh) {
      _dragMode = _CropDragMode.bl;
    } else if ((norm.dx - r.right).abs() < thresh && (norm.dy - r.bottom).abs() < thresh) {
      _dragMode = _CropDragMode.br;
    } else if (norm.dx > r.left && norm.dx < r.right && norm.dy > r.top && norm.dy < r.bottom) {
      _dragMode = _CropDragMode.move;
    } else {
      _dragMode = _CropDragMode.none;
    }
    _dragStartNorm = norm;
    _dragStartRect = r;
  }

  void _onCropPanUpdate(Offset local) {
    if (_dragMode == _CropDragMode.none || _cropRect == null) return;
    final disp = _displayRect;
    final norm = Offset(
      ((local.dx - disp.left) / disp.width).clamp(0.0, 1.0),
      ((local.dy - disp.top) / disp.height).clamp(0.0, 1.0),
    );
    final d = norm - _dragStartNorm;
    const minS = 0.05;
    Rect r = _dragStartRect;
    switch (_dragMode) {
      case _CropDragMode.move:
        double left = (r.left + d.dx).clamp(0.0, 1.0 - r.width);
        double top = (r.top + d.dy).clamp(0.0, 1.0 - r.height);
        r = Rect.fromLTWH(left, top, r.width, r.height);
      case _CropDragMode.tl:
        final left = (r.left + d.dx).clamp(0.0, r.right - minS);
        final top = (r.top + d.dy).clamp(0.0, r.bottom - minS);
        r = Rect.fromLTRB(left, top, r.right, r.bottom);
      case _CropDragMode.tr:
        final right = (r.right + d.dx).clamp(r.left + minS, 1.0);
        final top = (r.top + d.dy).clamp(0.0, r.bottom - minS);
        r = Rect.fromLTRB(r.left, top, right, r.bottom);
      case _CropDragMode.bl:
        final left = (r.left + d.dx).clamp(0.0, r.right - minS);
        final bottom = (r.bottom + d.dy).clamp(r.top + minS, 1.0);
        r = Rect.fromLTRB(left, r.top, r.right, bottom);
      case _CropDragMode.br:
        final right = (r.right + d.dx).clamp(r.left + minS, 1.0);
        final bottom = (r.bottom + d.dy).clamp(r.top + minS, 1.0);
        r = Rect.fromLTRB(r.left, r.top, right, bottom);
      case _CropDragMode.none:
        break;
    }
    setState(() => _cropRect = r);
  }

  void _setAspect(double? ratio) {
    if (_cropRect == null) return;
    Rect r;
    if (ratio == null) {
      r = Rect.fromLTRB(0, 0, 1, 1);
    } else {
      double w, h;
      if (ratio >= 1) {
        w = 1;
        h = 1 / ratio;
      } else {
        h = 1;
        w = ratio;
      }
      r = Rect.fromLTWH((1 - w) / 2, (1 - h) / 2, w, h);
    }
    setState(() => _cropRect = r);
  }

  void _clearCrop() {
    setState(() {
      _cropRect = Rect.fromLTRB(0, 0, 1, 1);
      _params = _params.copyWith(cropX: null, cropY: null, cropW: null, cropH: null);
    });
    _recomputePreview();
  }

  // ---- 缩放 ----
  final TextEditingController _widthCtrl = TextEditingController();
  final TextEditingController _heightCtrl = TextEditingController();
  bool _lockRatio = false;

  void _initResizeFields() {
    _widthCtrl.text = (_params.targetWidth ?? _info?.width ?? 0).toString();
    _heightCtrl.text = (_params.targetHeight ?? _info?.height ?? 0).toString();
  }

  void _onWidthChanged(String v) {
    final w = int.tryParse(v);
    if (w == null || w <= 0 || _info == null) return;
    if (_lockRatio) {
      final ratio = _info!.height / _info!.width;
      final h = (w * ratio).round();
      _heightCtrl.text = h.toString();
      _params = _params.copyWith(targetWidth: w, targetHeight: h);
    } else {
      _params = _params.copyWith(targetWidth: w);
    }
    _recomputePreview();
  }

  void _onHeightChanged(String v) {
    final h = int.tryParse(v);
    if (h == null || h <= 0 || _info == null) return;
    if (_lockRatio) {
      final ratio = _info!.width / _info!.height;
      final w = (h * ratio).round();
      _widthCtrl.text = w.toString();
      _params = _params.copyWith(targetWidth: w, targetHeight: h);
    } else {
      _params = _params.copyWith(targetHeight: h);
    }
    _recomputePreview();
  }

  void _applyScale(double factor) {
    if (_info == null) return;
    final w = (_info!.width * factor).round();
    final h = (_info!.height * factor).round();
    _widthCtrl.text = w.toString();
    _heightCtrl.text = h.toString();
    _params = _params.copyWith(targetWidth: w, targetHeight: h);
    _recomputePreview();
  }

  void _applySize(int w, int h) {
    _widthCtrl.text = w.toString();
    _heightCtrl.text = h.toString();
    _params = _params.copyWith(targetWidth: w, targetHeight: h);
    _recomputePreview();
  }

  // ---- 旋转/翻转 ----
  void _rotate(int delta) {
    var a = (_params.rotateAngle + delta) % 360;
    if (a < 0) a += 360;
    _params = _params.copyWith(rotateAngle: a);
    _recomputePreview();
  }

  void _toggleFlipH() => setState(() {
        _params = _params.copyWith(flipHorizontal: !_params.flipHorizontal);
        _schedulePreview();
      });

  void _toggleFlipV() => setState(() {
        _params = _params.copyWith(flipVertical: !_params.flipVertical);
        _schedulePreview();
      });

  // ---- 滤镜 ----
  final List<Map<String, String>> _filters = const [
    {'key': 'none', 'labelKey': 'editor_filter_original'},
    {'key': 'bw', 'labelKey': 'editor_filter_bw'},
    {'key': 'sepia', 'labelKey': 'editor_filter_sepia'},
    {'key': 'vintage', 'labelKey': 'editor_filter_vintage'},
    {'key': 'cool', 'labelKey': 'editor_filter_cool'},
    {'key': 'warm', 'labelKey': 'editor_filter_warm'},
  ];

  // ---- 证件照常见尺寸预设 ----
  static const List<_IdPreset> _idPresets = [
    _IdPreset('editor_passport_413_531', 413, 531),
    _IdPreset('editor_preset_1inch', 295, 413),
    _IdPreset('editor_preset_2inch', 413, 579),
    _IdPreset('editor_preset_small_1inch', 260, 378),
    _IdPreset('editor_preset_large_1inch', 390, 567),
    _IdPreset('editor_preset_us_visa', 600, 600),
  ];

  String _idPresetLabel(String key, L10n l10n) {
    switch (key) {
      case 'editor_passport_413_531':
        return l10n.editor_passport_413_531;
      case 'editor_preset_1inch':
        return l10n.editor_preset_1inch;
      case 'editor_preset_2inch':
        return l10n.editor_preset_2inch;
      case 'editor_preset_small_1inch':
        return l10n.editor_preset_small_1inch;
      case 'editor_preset_large_1inch':
        return l10n.editor_preset_large_1inch;
      case 'editor_preset_us_visa':
        return l10n.editor_preset_us_visa;
      default:
        return key;
    }
  }

  // ---- 保存 ----
  Future<void> _save({required bool overwrite}) async {
    if (_bytes == null || _info == null) return;
    _commitCropIfNeeded();
    final l10n = L10n.of(context);
    final navigator = Navigator.of(context);
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const AlertDialog(
        content: Row(children: [
          CircularProgressIndicator(),
          SizedBox(width: 16),
          Text('…'),
        ]),
      ),
    );
    try {
      final out = await _service.edit(
        _bytes!,
        _params,
        quality: _quality,
        preview: false,
        isPng: _isPng,
      );
      final dir = File(widget.imagePath).parent.path;
      final base = p.basenameWithoutExtension(widget.imagePath);
      final ext = _isPng ? 'png' : 'jpg';
      String outPath;
      if (overwrite) {
        outPath = widget.imagePath;
      } else {
        outPath = p.join(dir, '${base}_edited.$ext');
        int i = 1;
        while (File(outPath).existsSync()) {
          outPath = p.join(dir, '${base}_edited_$i.$ext');
          i++;
        }
      }
      await File(outPath).writeAsBytes(out);
      if (!mounted) return;
      navigator.pop();
      final sizeStr = _humanSize(out.length);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${l10n.editor_saved}  (${l10n.editor_output_size(sizeStr)})')),
      );
      navigator.pop(true);
    } catch (e) {
      if (!mounted) return;
      navigator.pop();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.editor_save_failed(e.toString())), backgroundColor: Colors.redAccent),
      );
    }
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

  /// 是否存在未保存的编辑（含当前裁剪 tab 中已拖动但未提交的裁剪框）。
  bool get _hasUnsavedEdits {
    if (_params.hasChanges) return true;
    final r = _cropRect;
    if (r != null && (r.left > 0.001 || r.top > 0.001 || r.right < 0.999 || r.bottom < 0.999)) {
      return true;
    }
    return false;
  }

  /// 返回键拦截：有未保存编辑时弹确认对话框。
  Future<void> _confirmExit() async {
    final l10n = L10n.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.editor_exit_confirm_title),
        content: Text(l10n.editor_exit_confirm_message),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(l10n.ui_cancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(l10n.editor_exit_discard),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) {
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = L10n.of(context);
    final theme = Theme.of(context);
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        if (_hasUnsavedEdits) {
          _confirmExit();
        } else {
          Navigator.of(context).pop();
        }
      },
      child: Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: theme.colorScheme.surface,
        foregroundColor: theme.colorScheme.onSurface,
        title: Text(l10n.edit_image),
        actions: [
          IconButton(
            icon: const Icon(Broken.undo),
            tooltip: l10n.editor_reset,
            onPressed: () {
              setState(() {
                _params = const ImageEditParams();
                _cropRect = Rect.fromLTRB(0, 0, 1, 1);
                _quality = 90;
                _widthCtrl.clear();
                _heightCtrl.clear();
              });
              _recomputePreview();
            },
          ),
          PopupMenuButton<bool>(
            icon: const Icon(Icons.save_outlined),
            tooltip: l10n.editor_save_as_copy,
            onSelected: (overwrite) => _save(overwrite: overwrite),
            itemBuilder: (_) => [
              PopupMenuItem(value: false, child: Text(l10n.editor_save_as_copy)),
              PopupMenuItem(value: true, child: Text(l10n.editor_overwrite_original)),
            ],
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _unsupported
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(l10n.editor_unsupported, textAlign: TextAlign.center),
                  ),
                )
              : Column(
                  children: [
                    Expanded(
                      child: LayoutBuilder(
                        builder: (ctx, constraints) {
                          _displayRect = _computeDisplayRect(constraints.biggest);
                          return Stack(
                            children: [
                              Center(
                                child: _previewBytes == null
                                    ? const SizedBox.shrink()
                                    : Image.memory(
                                        _previewBytes!,
                                        fit: BoxFit.contain,
                                        gaplessPlayback: true,
                                      ),
                              ),
                              if (_processing)
                                const Center(child: CircularProgressIndicator(color: Colors.white70)),
                              if (_cropTabActive && _cropRect != null)
                                Positioned.fill(
                                  child: GestureDetector(
                                    onPanStart: (d) => _onCropPanStart(d.localPosition),
                                    onPanUpdate: (d) => _onCropPanUpdate(d.localPosition),
                                    onPanEnd: (_) => setState(() => _dragMode = _CropDragMode.none),
                                    child: CustomPaint(
                                      painter: _CropPainter(
                                        displayRect: _displayRect,
                                        crop: _cropRect!,
                                      ),
                                    ),
                                  ),
                                ),
                            ],
                          );
                        },
                      ),
                    ),
                    ClipRRect(
                      borderRadius: const BorderRadius.only(
                        topLeft: Radius.circular(16),
                        topRight: Radius.circular(16),
                      ),
                      child: Container(
                        color: Theme.of(context).colorScheme.surface,
                        child: SafeArea(
                          top: false,
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              _buildTabBar(l10n),
                              AnimatedSwitcher(
                                duration: const Duration(milliseconds: 150),
                                child: _buildPanel(l10n),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
      ),
    );
  }

  Widget _buildTabBar(L10n l10n) {
    final tabs = [
      (_EditorTab.adjust, l10n.editor_adjust),
      (_EditorTab.filters, l10n.editor_filters),
      (_EditorTab.resize, l10n.editor_resize),
      (_EditorTab.rotate, l10n.editor_rotate_flip),
      (_EditorTab.crop, l10n.editor_crop),
    ];
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: tabs.map((t) {
            final selected = _tab == t.$1;
            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: ChoiceChip(
                label: Text(t.$2),
                selected: selected,
                onSelected: (_) => _switchTab(t.$1),
              ),
            );
          }).toList(),
        ),
      ),
    );
  }

  Widget _buildPanel(L10n l10n) {
    switch (_tab) {
      case _EditorTab.adjust:
        return _buildAdjustPanel(l10n);
      case _EditorTab.filters:
        return _buildFiltersPanel(l10n);
      case _EditorTab.resize:
        return _buildResizePanel(l10n);
      case _EditorTab.rotate:
        return _buildRotatePanel(l10n);
      case _EditorTab.crop:
        return _buildCropPanel(l10n);
    }
  }

  Widget _sectionTitle(String title) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
        child: Text(title, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
      );

  Widget _buildAdjustPanel(L10n l10n) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _slider(l10n.editor_brightness, _params.brightness, 0.2, 2.0, (v) {
            _params = _params.copyWith(brightness: v);
            _schedulePreview();
          }),
          _slider(l10n.editor_contrast, _params.contrast, 0.2, 2.0, (v) {
            _params = _params.copyWith(contrast: v);
            _schedulePreview();
          }),
          _slider(l10n.editor_saturation, _params.saturation, 0.0, 2.0, (v) {
            _params = _params.copyWith(saturation: v);
            _schedulePreview();
          }),
        ],
      ),
    );
  }

  Widget _slider(String label, double value, double min, double max, ValueChanged<double> onChanged) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(label),
            Text(value.toStringAsFixed(2)),
          ],
        ),
        Slider(
          value: value,
          min: min,
          max: max,
          onChanged: onChanged,
        ),
      ],
    );
  }

  Widget _buildFiltersPanel(L10n l10n) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 20),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: _filters.map((f) {
          final key = f['key']!;
          final label = _filterLabel(f['labelKey']!, l10n);
          final selected = _params.filter == key;
          return ChoiceChip(
            label: Text(label),
            selected: selected,
            onSelected: (_) {
              _params = _params.copyWith(filter: key);
              _schedulePreview();
            },
          );
        }).toList(),
      ),
    );
  }

  String _filterLabel(String key, L10n l10n) {
    switch (key) {
      case 'editor_filter_original':
        return l10n.editor_filter_original;
      case 'editor_filter_bw':
        return l10n.editor_filter_bw;
      case 'editor_filter_sepia':
        return l10n.editor_filter_sepia;
      case 'editor_filter_vintage':
        return l10n.editor_filter_vintage;
      case 'editor_filter_cool':
        return l10n.editor_filter_cool;
      case 'editor_filter_warm':
        return l10n.editor_filter_warm;
      default:
        return key;
    }
  }

  Widget _buildMenuButton<T>({
    required String label,
    required List<T> values,
    required String Function(T) labelBuilder,
    required ValueChanged<T> onSelected,
  }) {
    final scheme = Theme.of(context).colorScheme;
    return PopupMenuButton<T>(
      onSelected: onSelected,
      itemBuilder: (context) => [
        for (final v in values)
          PopupMenuItem<T>(
            value: v,
            child: Text(labelBuilder(v)),
          ),
      ],
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          border: Border.all(color: scheme.outline.withAlpha(100)),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              label,
              style: TextStyle(color: scheme.onSurface),
            ),
            const SizedBox(width: 4),
            Icon(Icons.arrow_drop_down, color: scheme.onSurface, size: 20),
          ],
        ),
      ),
    );
  }

  Widget _buildResizePanel(L10n l10n) {
    if (_info == null) return const SizedBox.shrink();
    if (_widthCtrl.text.isEmpty || _heightCtrl.text.isEmpty) _initResizeFields();
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _sectionTitle(l10n.editor_exact_dimensions),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _widthCtrl,
                  keyboardType: TextInputType.number,
                  decoration: InputDecoration(labelText: l10n.editor_width),
                  onChanged: _onWidthChanged,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: TextField(
                  controller: _heightCtrl,
                  keyboardType: TextInputType.number,
                  decoration: InputDecoration(labelText: l10n.editor_height),
                  onChanged: _onHeightChanged,
                ),
              ),
            ],
          ),
          Row(
            children: [
              ChoiceChip(
                label: Text(l10n.editor_lock_ratio),
                selected: _lockRatio,
                onSelected: (v) => setState(() => _lockRatio = v),
              ),
            ],
          ),
          const SizedBox(height: 8),
          _buildMenuButton<_IdPreset>(
            label: l10n.editor_id_presets,
            values: _idPresets,
            labelBuilder: (p) => '${_idPresetLabel(p.key, l10n)} ${p.w}×${p.h}',
            onSelected: (p) => _applySize(p.w, p.h),
          ),
          const SizedBox(height: 12),
          _buildMenuButton<double>(
            label: l10n.editor_scale,
            values: const [0.5, 0.75, 1.0, 1.25, 1.5, 2.0],
            labelBuilder: (f) => '${(f * 100).round()}%',
            onSelected: _applyScale,
          ),
          const SizedBox(height: 12),
          _slider(l10n.editor_quality, _quality.toDouble(), 1, 100, (v) {
            setState(() => _quality = v.round());
            _schedulePreview();
          }),
        ],
      ),
    );
  }

  Widget _buildRotatePanel(L10n l10n) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 20),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          IconButton.filled(
            icon: const Icon(Icons.rotate_left),
            tooltip: '90°',
            onPressed: () => _rotate(-90),
          ),
          IconButton.filled(
            icon: const Icon(Icons.rotate_right),
            tooltip: '90°',
            onPressed: () => _rotate(90),
          ),
          IconButton.filled(
            icon: const Icon(Icons.flip),
            tooltip: l10n.editor_flip,
            onPressed: _toggleFlipH,
          ),
          IconButton.filled(
            icon: const Icon(Icons.flip_camera_android),
            tooltip: l10n.editor_flip,
            onPressed: _toggleFlipV,
          ),
        ],
      ),
    );
  }

  Widget _buildCropPanel(L10n l10n) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _sectionTitle(l10n.editor_aspect_free),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              ChoiceChip(label: Text(l10n.editor_aspect_free), selected: false, onSelected: (_) => _setAspect(null)),
              ChoiceChip(label: Text(l10n.editor_aspect_square), selected: false, onSelected: (_) => _setAspect(1)),
              ChoiceChip(label: Text(l10n.editor_aspect_4_3), selected: false, onSelected: (_) => _setAspect(4 / 3)),
              ChoiceChip(label: Text(l10n.editor_aspect_3_4), selected: false, onSelected: (_) => _setAspect(3 / 4)),
              ChoiceChip(label: Text(l10n.editor_passport_413_531), selected: false, onSelected: (_) => _setAspect(413 / 531)),
            ],
          ),
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              icon: const Icon(Icons.crop_free),
              label: Text(l10n.editor_reset),
              onPressed: _clearCrop,
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              l10n.editor_crop,
              style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurface.withOpacity(0.6)),
            ),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _widthCtrl.dispose();
    _heightCtrl.dispose();
    super.dispose();
  }
}

// ---- 证件照常见尺寸预设 ----
class _IdPreset {
  final String key;
  final int w;
  final int h;
  const _IdPreset(this.key, this.w, this.h);
}

class _CropPainter extends CustomPainter {
  final Rect displayRect;
  final Rect crop; // 归一化 0..1

  _CropPainter({required this.displayRect, required this.crop});

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Rect.fromLTWH(
      displayRect.left + crop.left * displayRect.width,
      displayRect.top + crop.top * displayRect.height,
      crop.width * displayRect.width,
      crop.height * displayRect.height,
    );
    // 在透明层上画外部暗化遮罩，再用 clear 在遮罩上挖出透明裁剪区
    final fullRect = Rect.fromLTWH(0, 0, size.width, size.height);
    canvas.saveLayer(fullRect, Paint());
    final paint = Paint()..color = Colors.black.withOpacity(0.55);
    canvas.drawRect(fullRect, paint);
    final clear = Paint()..blendMode = BlendMode.clear;
    canvas.drawRect(rect, clear);
    canvas.restore();

    // 边框
    final border = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;
    canvas.drawRect(rect, border);

    // 三分线
    final line = Paint()
      ..color = Colors.white.withOpacity(0.4)
      ..strokeWidth = 1;
    for (var i = 1; i <= 2; i++) {
      final x1 = rect.left + rect.width * i / 3;
      final y1 = rect.top + rect.height * i / 3;
      canvas.drawLine(Offset(x1, rect.top), Offset(x1, rect.bottom), line);
      canvas.drawLine(Offset(rect.left, y1), Offset(rect.right, y1), line);
    }

    // 角手柄
    final handle = Paint()..color = Colors.white;
    const hs = 10.0;
    for (final c in [rect.topLeft, rect.topRight, rect.bottomLeft, rect.bottomRight]) {
      canvas.drawRect(Rect.fromCenter(center: c, width: hs, height: hs), handle);
    }
  }

  @override
  bool shouldRepaint(covariant _CropPainter old) => old.crop != crop || old.displayRect != displayRect;
}
