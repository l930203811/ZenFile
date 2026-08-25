import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import '../../core/icon_fonts/broken_icons.dart';
import '../../services/image_edit_service.dart';
import 'package:zenfile/l10n/generated/app_localizations.dart';

enum _EditorTab { adjust, filters, resize, rotate, crop }

enum _CropDragMode { none, move, tl, tr, bl, br }

enum _Corner { tl, tr, bl, br }

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
  // 已保存标志：保存成功后退出不再弹确认框
  bool _saved = false;

  /// 是否有未保存的编辑：参数有变化（含已提交的裁剪/缩放/滤镜等），或
  /// 裁剪 tab 中已拖动尚未提交的裁剪框。未做任何修改/已保存返回 false。
  bool get _hasUnsavedEdits =>
      !_saved &&
      (_params.hasChanges ||
          (_cropTabActive &&
              _cropRect != null &&
              (_cropRect!.left > 0.001 ||
                  _cropRect!.top > 0.001 ||
                  _cropRect!.right < 0.999 ||
                  _cropRect!.bottom < 0.999)));

  _EditorTab _tab = _EditorTab.adjust;
  bool get _cropTabActive => _tab == _EditorTab.crop;

  // 顶栏「撤回」：参数快照栈（ImageEditParams 不可变，直接存引用）
  final List<_EditSnapshot> _undoStack = [];
  static const int _maxUndo = 100;
  // 进入当前 tab 时的编辑状态：顶栏「取消」恢复到该状态（仅撤销本 tab 的改动）
  _EditSnapshot _tabEntry = const _EditSnapshot(ImageEditParams(), 90);
  // 裁剪比例当前选中项（null = 自由）
  double? _selectedAspect;

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

  // ---- 顶栏操作：撤回 / 重置 / 取消 / 确定（对所有 tab 生效） ----

  /// 撤回压栈：在每次修改参数前调用，保存修改前的完整状态。
  /// 同时复位已保存标志——保存后又产生新修改时，退出需重新确认。
  void _pushUndo() {
    _saved = false;
    _undoStack.add(_EditSnapshot(_params, _quality));
    if (_undoStack.length > _maxUndo) _undoStack.removeAt(0);
  }

  /// 恢复到某个状态（撤回/取消共用）：同步参数、质量、裁剪框与尺寸输入框。
  void _restore(_EditSnapshot s) {
    setState(() {
      _params = s.params;
      _quality = s.quality;
      if (s.params.cropX != null) {
        _cropRect = Rect.fromLTWH(
          s.params.cropX!,
          s.params.cropY!,
          s.params.cropW!,
          s.params.cropH!,
        );
      } else {
        _cropRect = Rect.fromLTRB(0, 0, 1, 1);
      }
      _selectedAspect = null; // 恢复后比例选中态交还「自由」
      _widthCtrl.text = (s.params.targetWidth ?? _info?.width ?? 0).toString();
      _heightCtrl.text = (s.params.targetHeight ?? _info?.height ?? 0).toString();
    });
    _recomputePreview();
  }

  /// 撤回：回到上一次修改前的状态。
  void _undoEdit() {
    if (_undoStack.isEmpty) return;
    _restore(_undoStack.removeLast());
  }

  /// 重置：将当前 tab 的参数恢复默认（其它 tab 的修改保留）。
  void _resetTab() {
    _pushUndo();
    switch (_tab) {
      case _EditorTab.adjust:
        _params = _params.copyWith(brightness: 1.0, contrast: 1.0, saturation: 1.0);
      case _EditorTab.filters:
        _params = _params.copyWith(filter: 'none');
      case _EditorTab.resize:
        _params = _params.copyWith(targetWidth: null, targetHeight: null);
        _quality = 90;
        _widthCtrl.text = (_info?.width ?? 0).toString();
        _heightCtrl.text = (_info?.height ?? 0).toString();
      case _EditorTab.rotate:
        _params = _params.copyWith(rotateAngle: 0, flipHorizontal: false, flipVertical: false);
      case _EditorTab.crop:
        _cropRect = Rect.fromLTRB(0, 0, 1, 1);
        _selectedAspect = null;
        _params = _params.copyWith(cropX: null, cropY: null, cropW: null, cropH: null);
    }
    setState(() {});
    _recomputePreview();
  }

  /// 取消：撤销进入当前 tab 以来的所有改动（恢复到进入时快照）。
  void _cancelTab() {
    _restore(_tabEntry);
  }

  /// 确定：完成当前 tab——裁剪页提交裁剪框，其余页接受当前参数，
  /// 均回到「调整」主页。
  void _confirmTab() {
    if (_tab == _EditorTab.crop) {
      _confirmCrop();
    } else if (_tab != _EditorTab.adjust) {
      _switchTab(_EditorTab.adjust);
    }
  }

  void _commitCropIfNeeded() {
    if (_cropTabActive) {
      // 退出裁剪页时把裁剪框写入参数（仅在裁剪参数实际变化时压入撤回栈）
      final r = _cropRect;
      final Rect? next = (r != null &&
              (r.left > 0.001 || r.top > 0.001 || r.right < 0.999 || r.bottom < 0.999))
          ? r
          : null;
      final Rect? committed = (_params.cropX != null)
          ? Rect.fromLTWH(_params.cropX!, _params.cropY!, _params.cropW!, _params.cropH!)
          : null;
      if (next != committed) _pushUndo();
      if (next != null) {
        _params = _params.copyWith(
          cropX: next.left,
          cropY: next.top,
          cropW: next.right - next.left,
          cropH: next.bottom - next.top,
        );
      } else {
        _params = _params.copyWith(cropX: null, cropY: null, cropW: null, cropH: null);
      }
    }
  }

  void _switchTab(_EditorTab tab) {
    if (tab == _tab) return;
    _commitCropIfNeeded();
    // 记录进入新 tab 时的状态：顶栏「取消」据此撤销本 tab 的改动
    _tabEntry = _EditSnapshot(_params, _quality);
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
    const minS = 0.05;
    final r = _dragStartRect;
    // 已选比例时锁定宽高比（与 _setAspect 同一套换算规则）
    final ar = (_info?.width ?? 1) / (_info?.height ?? 1);
    final locked = _selectedAspect != null;
    final wh = locked ? (_selectedAspect! / ar) : 1.0; // 归一化宽/高

    Rect result;
    switch (_dragMode) {
      case _CropDragMode.move:
        final left = (r.left + (norm.dx - _dragStartNorm.dx)).clamp(0.0, 1.0 - r.width);
        final top = (r.top + (norm.dy - _dragStartNorm.dy)).clamp(0.0, 1.0 - r.height);
        result = Rect.fromLTWH(left, top, r.width, r.height);
      case _CropDragMode.tl:
        result = _resizeCorner(r, norm, ar, wh, locked, minS, _Corner.tl);
      case _CropDragMode.tr:
        result = _resizeCorner(r, norm, ar, wh, locked, minS, _Corner.tr);
      case _CropDragMode.bl:
        result = _resizeCorner(r, norm, ar, wh, locked, minS, _Corner.bl);
      case _CropDragMode.br:
        result = _resizeCorner(r, norm, ar, wh, locked, minS, _Corner.br);
      case _CropDragMode.none:
        return;
    }
    setState(() => _cropRect = result);
  }

  /// 以对角为锚点调整裁剪框（拖角时保持比例）。
  /// [corners] 指定被拖动的手柄，对侧顶点作为不动的锚点。
  Rect _resizeCorner(Rect r, Offset norm, double ar, double wh, bool locked, double minS, _Corner corner) {
    // 锚点（对侧顶点，固定不动）
    double ax, ay;
    switch (corner) {
      case _Corner.tl: // 拖左上，锚在右下
        ax = r.right;
        ay = r.bottom;
      case _Corner.tr: // 拖右上，锚在左下
        ax = r.left;
        ay = r.bottom;
      case _Corner.bl: // 拖左下，锚在右上
        ax = r.right;
        ay = r.top;
      case _Corner.br: // 拖右下，锚在左上
        ax = r.left;
        ay = r.top;
    }
    // 拖点相对锚点的尺寸（取绝对值）
    double nw = (norm.dx - ax).abs();
    double nh = (norm.dy - ay).abs();
    if (locked) {
      // 期望 nw/nh = wh；以能贴合拖拽方向为主导维度，避免两个维度互相打架。
      if (wh <= 1) {
        nh = nw / wh; // 宽<=高：以宽主导
      } else {
        nw = nh * wh; // 宽>高：以高主导
      }
    }
    // 钳制：锚在左/上侧时上限=1，锚在右/下侧时上限=锚点值
    final maxW = (ax == 0.0) ? 1.0 : ax;
    final maxH = (ay == 0.0) ? 1.0 : ay;
    nw = nw.clamp(minS, maxW);
    if (locked) {
      // 若主导维度被钳制，另一个维度按比例重新修正，保证比例不破
      if (wh <= 1) {
        if (nh > maxH) {
          nh = maxH;
          nw = nh * wh;
        }
      } else {
        if (nw > maxW) {
          nw = maxW;
          nh = nw / wh;
        }
      }
    }
    nh = nh.clamp(minS, maxH);

    switch (corner) {
      case _Corner.tl:
        return Rect.fromLTRB(ax - nw, ay - nh, ax, ay);
      case _Corner.tr:
        return Rect.fromLTRB(ax, ay - nh, ax + nw, ay);
      case _Corner.bl:
        return Rect.fromLTRB(ax - nw, ay, ax, ay + nh);
      case _Corner.br:
        return Rect.fromLTRB(ax, ay, ax + nw, ay + nh);
    }
  }

  void _setAspect(double? ratio) {
    if (_cropRect == null || _info == null) return;
    if (ratio == null) {
      setState(() {
        _cropRect = Rect.fromLTRB(0, 0, 1, 1);
        _selectedAspect = null;
      });
      return;
    }
    // 归一化裁剪框的「宽/高」并不等于输出像素的「宽/高」：
    // 归一化坐标 x 对应原图宽度、y 对应原图高度，因此输出像素比例 =
    // (crop.w * 原图宽) / (crop.h * 原图高)。要让输出比例等于 ratio，需令
    // crop.w / crop.h = ratio / 原图宽高比。
    final ar = _info!.width / _info!.height; // 原图宽高比
    final wh = ratio / ar; // 归一化坐标下的「宽/高」
    double w, h;
    if (wh <= 1) {
      w = wh;
      h = 1;
    } else {
      h = 1 / wh;
      w = 1;
    }
    final r = Rect.fromLTWH((1 - w) / 2, (1 - h) / 2, w, h);
    setState(() {
      _cropRect = r;
      _selectedAspect = ratio;
    });
  }

  // ---- 缩放 ----
  final TextEditingController _widthCtrl = TextEditingController();
  final TextEditingController _heightCtrl = TextEditingController();
  bool _lockRatio = true;

  void _initResizeFields() {
    _widthCtrl.text = (_params.targetWidth ?? _info?.width ?? 0).toString();
    _heightCtrl.text = (_params.targetHeight ?? _info?.height ?? 0).toString();
  }

  void _onWidthChanged(String v) {
    final w = int.tryParse(v);
    if (w == null || w <= 0 || _info == null) return;
    _pushUndo();
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
    _pushUndo();
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
    _pushUndo();
    final w = (_info!.width * factor).round();
    final h = (_info!.height * factor).round();
    _widthCtrl.text = w.toString();
    _heightCtrl.text = h.toString();
    _params = _params.copyWith(targetWidth: w, targetHeight: h);
    _recomputePreview();
  }

  void _applySize(int w, int h) {
    _pushUndo();
    _widthCtrl.text = w.toString();
    _heightCtrl.text = h.toString();
    _params = _params.copyWith(targetWidth: w, targetHeight: h);
    _recomputePreview();
  }

  // ---- 旋转/翻转 ----
  void _rotate(int delta) {
    _pushUndo();
    setState(() {
      var a = (_params.rotateAngle + delta) % 360;
      if (a < 0) a += 360;
      _params = _params.copyWith(rotateAngle: a);
    });
    _recomputePreview();
  }

  void _toggleFlipH() {
    _pushUndo();
    setState(() {
      _params = _params.copyWith(flipHorizontal: !_params.flipHorizontal);
      _schedulePreview();
    });
  }

  void _toggleFlipV() {
    _pushUndo();
    setState(() {
      _params = _params.copyWith(flipVertical: !_params.flipVertical);
      _schedulePreview();
    });
  }

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
      // 检查是否有文件大小限制
      final sizeLimitKB = int.tryParse(_fileSizeLimitCtrl.text) ?? 0;
      Uint8List out;
      if (sizeLimitKB > 0 && !_isPng) {
        // 使用智能编码：自动调整质量以满足大小限制
        out = await _service.encodeWithSizeLimit(
          _bytes!,
          _params,
          targetSizeKB: sizeLimitKB,
        );
      } else {
        out = await _service.edit(
          _bytes!,
          _params,
          quality: _quality,
          preview: false,
          isPng: _isPng,
        );
      }
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
      _saved = true; // 已保存：后续退出（含返回键）不再弹确认框
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

  /// 返回键拦截：有未保存修改（含裁剪 tab 未提交的裁剪框）时弹确认
  /// 对话框；未做任何修改或已保存则直接退出，不弹窗。
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
        // 未做任何修改或已保存：直接退出，不弹窗；
        // 有未保存修改才弹确认框，防止误触丢失编辑中的调整。
        if (!_hasUnsavedEdits) {
          Navigator.of(context).pop();
          return;
        }
        _confirmExit();
      },
      child: Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: theme.colorScheme.surface,
        foregroundColor: theme.colorScheme.onSurface,
        // 六个按钮均匀铺满顶栏：退出 / 重置 / 取消 / 确定 / 撤回 / 三点菜单
        automaticallyImplyLeading: false,
        titleSpacing: 0,
        title: Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            // 退出：maybePop 经 PopScope 拦截，有未保存修改仍弹确认框
            IconButton(
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.arrow_back),
              onPressed: () => Navigator.of(context).maybePop(),
            ),
            IconButton(
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.restart_alt),
              tooltip: l10n.editor_reset,
              onPressed: _resetTab,
            ),
            IconButton(
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.close),
              tooltip: l10n.ui_cancel,
              onPressed: _cancelTab,
            ),
            IconButton(
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.check),
              tooltip: l10n.ui_confirm,
              onPressed: _confirmTab,
            ),
            IconButton(
              visualDensity: VisualDensity.compact,
              icon: const Icon(Broken.undo),
              tooltip: l10n.editor_undo,
              onPressed: _undoStack.isEmpty ? null : _undoEdit,
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
                                    onPanEnd: (_) => setState(() {
                                      _dragMode = _CropDragMode.none;
                                      // 手动拖动裁剪框后脱离预设比例，回到「自由」
                                      _selectedAspect = null;
                                    }),
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
                              // 面板固定高度（偏低，为图片预览区腾空间）+
                              // 垂直居中 + 可滚动：各 tab 内容自然高度差异大，
                              // 固定高度保证切换时图片预览区尺寸稳定；内容少时
                              // 垂直居中不显空旷，内容超出（缩放页/小屏）可滚动。
                              SizedBox(
                                height: 220,
                                child: AnimatedSwitcher(
                                  duration: const Duration(milliseconds: 150),
                                  child: KeyedSubtree(
                                    key: ValueKey(_tab),
                                    child: LayoutBuilder(
                                      builder: (ctx, constraints) => SingleChildScrollView(
                                        child: ConstrainedBox(
                                          constraints: BoxConstraints(minHeight: constraints.maxHeight),
                                          child: Container(
                                            alignment: Alignment.center,
                                            width: double.infinity,
                                            child: _buildPanel(l10n),
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
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

  /// 通用药丸按钮：tab 栏 / 滤镜 / 裁剪比例 / 缩放比例共用同一视觉。
  Widget _pill(
    String label, {
    required bool selected,
    required VoidCallback onTap,
    IconData? icon,
  }) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(24),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: ShapeDecoration(
            color: selected ? scheme.primary : Colors.transparent,
            shape: StadiumBorder(
              side: BorderSide(
                color: selected ? scheme.primary : scheme.outline.withAlpha(80),
              ),
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (icon != null) ...[
                Icon(icon, size: 16, color: selected ? scheme.onPrimary : scheme.onSurfaceVariant),
                const SizedBox(width: 6),
              ],
              Text(
                label,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                  color: selected ? scheme.onPrimary : scheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
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
    return SizedBox(
      height: 46,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
        child: Row(
          children: tabs
              .map((t) => _pill(t.$2, selected: _tab == t.$1, onTap: () => _switchTab(t.$1)))
              .toList(),
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
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      width: double.infinity,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _slider(l10n.editor_brightness, _params.brightness, 0.2, 2.0,
            Icons.wb_sunny_outlined, (v) {
            _params = _params.copyWith(brightness: v);
            _schedulePreview();
          }),
          _slider(l10n.editor_contrast, _params.contrast, 0.2, 2.0,
            Icons.contrast, (v) {
            _params = _params.copyWith(contrast: v);
            _schedulePreview();
          }),
          _slider(l10n.editor_saturation, _params.saturation, 0.0, 2.0,
            Icons.opacity, (v) {
            _params = _params.copyWith(saturation: v);
            _schedulePreview();
          }),
        ],
      ),
    );
  }

  Widget _slider(String label, double value, double min, double max, IconData icon,
      ValueChanged<double> onChanged) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 16, color: Theme.of(context).colorScheme.onSurfaceVariant),
              const SizedBox(width: 8),
              Text(label, style: const TextStyle(fontSize: 13)),
              const Spacer(),
              Text(value.toStringAsFixed(2),
                  style: TextStyle(
                    fontSize: 13,
                    color: Theme.of(context).colorScheme.primary,
                    fontWeight: FontWeight.w600,
                  )),
            ],
          ),
          SizedBox(
            height: 36,
            child: SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 3,
                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 8),
                overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
              ),
              child: Slider(
                value: value,
                min: min,
                max: max,
                // 拖动起始时压入撤回栈：一次拖动 = 一步撤回（而非逐帧）
                onChangeStart: (_) => _pushUndo(),
                onChanged: onChanged,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFiltersPanel(L10n l10n) {
    return SizedBox(
      height: 46,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Row(
          children: _filters.map((f) {
            final key = f['key']!;
            final label = _filterLabel(f['labelKey']!, l10n);
            final selected = _params.filter == key;
            return _pill(label, selected: selected, onTap: () {
              _pushUndo();
              setState(() => _params = _params.copyWith(filter: key));
              _schedulePreview();
            });
          }).toList(),
        ),
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

  // --- DPI 模式相关状态 ---
  final TextEditingController _widthMMCtrl = TextEditingController();
  final TextEditingController _heightMMCtrl = TextEditingController();
  final TextEditingController _dpiCtrl = TextEditingController(text: '200');
  final TextEditingController _fileSizeLimitCtrl = TextEditingController();
  bool _isPhysicalMode = false;

  Widget _buildResizePanel(L10n l10n) {
    if (_info == null) return const SizedBox.shrink();
    if (_widthCtrl.text.isEmpty || _heightCtrl.text.isEmpty) _initResizeFields();
    const scales = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0];
    final curScale = (_params.targetWidth != null && _info!.width > 0)
        ? _params.targetWidth! / _info!.width
        : 1.0;

    // 同步物理尺寸输入框
    if (_isPhysicalMode) {
      final dpi = int.tryParse(_dpiCtrl.text) ?? 200;
      if (_widthCtrl.text.isNotEmpty) {
        final px = int.tryParse(_widthCtrl.text) ?? 0;
        final mm = (px / dpi * 25.4).round();
        if (_widthMMCtrl.text.isEmpty || (_widthMMCtrl.text != mm.toString() && !_widthMMCtrl.selection.isValid)) {
          // 仅在用户未编辑物理宽度框时同步
        }
      }
    }

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 模式切换：像素 / 物理尺寸
          Row(
            children: [
              Expanded(
                child: SegmentedButton<bool>(
                  segments: [
                    ButtonSegment(value: false, label: Text(l10n.editor_mode_pixel)),
                    ButtonSegment(value: true, label: Text(l10n.editor_mode_physical)),
                  ],
                  selected: {_isPhysicalMode},
                  onSelectionChanged: (v) => setState(() => _isPhysicalMode = v.first),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          if (_isPhysicalMode) ...[
            // 物理尺寸输入模式（DPI + cm/mm → 自动算像素）
            _sectionTitle(l10n.editor_physical_title),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _widthMMCtrl,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    decoration: InputDecoration(
                      labelText: l10n.editor_width_mm,
                      isDense: true,
                      border: const OutlineInputBorder(),
                    ),
                    onChanged: _onPhysicalWidthChanged,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    controller: _heightMMCtrl,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    decoration: InputDecoration(
                      labelText: l10n.editor_height_mm,
                      isDense: true,
                      border: const OutlineInputBorder(),
                    ),
                    onChanged: _onPhysicalHeightChanged,
                  ),
                ),
                const SizedBox(width: 8),
                SizedBox(
                  width: 80,
                  child: TextField(
                    controller: _dpiCtrl,
                    keyboardType: TextInputType.number,
                    decoration: InputDecoration(
                      labelText: l10n.editor_dpi,
                      isDense: true,
                      border: const OutlineInputBorder(),
                    ),
                    onChanged: (_) => _syncPhysicalToPixels(),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            // 预设模板
            Wrap(
              spacing: 6,
              runSpacing: 4,
              children: [
                _presetChip(l10n.editor_preset_id_photo, 35, 25, 200),
                _presetChip(l10n.editor_preset_passport, 35, 45, 200),
                _presetChip(l10n.editor_preset_us_visa_mm, 51, 51, 300),
              ],
            ),
            const SizedBox(height: 8),
            // 转换后的像素预览
            if (_widthCtrl.text.isNotEmpty && _heightCtrl.text.isNotEmpty)
              Text(
                l10n.editor_pixel_auto(
                  int.tryParse(_widthCtrl.text) ?? 0,
                  int.tryParse(_heightCtrl.text) ?? 0,
                ),
                style: TextStyle(color: Theme.of(context).colorScheme.primary, fontWeight: FontWeight.w600),
              ),
            const SizedBox(height: 12),
          ],
          // 像素尺寸输入（两种模式都显示）
          _sectionTitle(_isPhysicalMode ? l10n.editor_pixel_result : l10n.editor_exact_dimensions),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _widthCtrl,
                  keyboardType: TextInputType.number,
                  readOnly: _isPhysicalMode,
                  decoration: InputDecoration(
                    labelText: l10n.editor_width_px,
                    isDense: true,
                    border: const OutlineInputBorder(),
                    filled: _isPhysicalMode,
                    fillColor: _isPhysicalMode
                        ? Theme.of(context).colorScheme.surfaceContainerHighest.withOpacity(0.3)
                        : null,
                  ),
                  onChanged: _isPhysicalMode ? null : _onWidthChanged,
                ),
              ),
              if (!_isPhysicalMode)
                IconButton(
                  icon: Icon(_lockRatio ? Icons.link : Icons.link_off),
                  tooltip: l10n.editor_lock_ratio,
                  color: _lockRatio
                      ? Theme.of(context).colorScheme.primary
                      : Theme.of(context).colorScheme.onSurfaceVariant,
                  onPressed: () => setState(() => _lockRatio = !_lockRatio),
                )
              else
                const SizedBox(width: 48),
              Expanded(
                child: TextField(
                  controller: _heightCtrl,
                  keyboardType: TextInputType.number,
                  readOnly: _isPhysicalMode,
                  decoration: InputDecoration(
                    labelText: l10n.editor_height_px,
                    isDense: true,
                    border: const OutlineInputBorder(),
                    filled: _isPhysicalMode,
                    fillColor: _isPhysicalMode
                        ? Theme.of(context).colorScheme.surfaceContainerHighest.withOpacity(0.3)
                        : null,
                  ),
                  onChanged: _isPhysicalMode ? null : _onHeightChanged,
                ),
              ),
            ],
          ),
          if (!_isPhysicalMode) ...[
            const SizedBox(height: 8),
            SizedBox(
              height: 44,
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: Row(
                  children: scales
                      .map((f) => _pill('${(f * 100).round()}%',
                          selected: (curScale - f).abs() < 0.01,
                          onTap: () => _applyScale(f)))
                      .toList(),
                ),
              ),
            ),
          ],
          const SizedBox(height: 8),
          // 文件大小限制
          _sectionTitle(l10n.editor_file_size_limit_title),
          TextField(
            controller: _fileSizeLimitCtrl,
            keyboardType: TextInputType.number,
            decoration: InputDecoration(
              labelText: l10n.editor_file_size_limit_label,
              isDense: true,
              border: const OutlineInputBorder(),
              suffixText: 'KB',
            ),
            onChanged: (_) => _schedulePreview(),
          ),
          const SizedBox(height: 8),
          _slider(l10n.editor_quality, _quality.toDouble(), 1, 100,
              Icons.high_quality_outlined, (v) {
            setState(() => _quality = v.round());
            _schedulePreview();
          }),
        ],
      ),
    );
  }

  Widget _presetChip(String label, int mmW, int mmH, int dpi) {
    return ActionChip(
      label: Text(label, style: const TextStyle(fontSize: 11)),
      onPressed: () {
        _dpiCtrl.text = dpi.toString();
        _widthMMCtrl.text = mmW.toString();
        _heightMMCtrl.text = mmH.toString();
        _syncPhysicalToPixels();
      },
    );
  }

  void _onPhysicalWidthChanged(String v) => _syncPhysicalToPixels();
  void _onPhysicalHeightChanged(String v) => _syncPhysicalToPixels();

  void _syncPhysicalToPixels() {
    if (!_isPhysicalMode || _info == null) return;
    final dpi = int.tryParse(_dpiCtrl.text) ?? 200;
    final mmW = double.tryParse(_widthMMCtrl.text) ?? 0;
    final mmH = double.tryParse(_heightMMCtrl.text) ?? 0;
    if (mmW <= 0 || mmH <= 0) return;
    final pxW = ((mmW / 25.4) * dpi).round();
    final pxH = ((mmH / 25.4) * dpi).round();
    _widthCtrl.text = pxW.toString();
    _heightCtrl.text = pxH.toString();
    _pushUndo();
    _params = _params.copyWith(targetWidth: pxW, targetHeight: pxH);
    _schedulePreview();
  }

  Widget _buildRotatePanel(L10n l10n) {
    final scheme = Theme.of(context).colorScheme;
    Widget rotateBtn(IconData icon, String tooltip, VoidCallback onTap, {bool active = false}) =>
        Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton.filledTonal(
              style: IconButton.styleFrom(
                backgroundColor: active ? scheme.primary : null,
                foregroundColor: active ? scheme.onPrimary : null,
              ),
              icon: Icon(icon),
              tooltip: tooltip,
              onPressed: onTap,
            ),
          ],
        );
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          rotateBtn(Icons.rotate_left, '90°', () => _rotate(-90)),
          rotateBtn(Icons.rotate_right, '90°', () => _rotate(90)),
          rotateBtn(Icons.flip, l10n.editor_flip, _toggleFlipH,
              active: _params.flipHorizontal),
          rotateBtn(Icons.flip_camera_android, l10n.editor_flip, _toggleFlipV,
              active: _params.flipVertical),
        ],
      ),
    );
  }

  Widget _buildCropPanel(L10n l10n) {
    // 比例药丸（重置/取消/确定已移至顶栏，对所有 tab 生效）
    final aspects = <(String, double?)>[
      (l10n.editor_aspect_free, null),
      (l10n.editor_aspect_square, 1.0),
      (l10n.editor_aspect_4_3, 4 / 3),
      (l10n.editor_aspect_3_4, 3 / 4),
      (l10n.editor_passport_413_531, 413 / 531),
    ];
    return SizedBox(
      height: 46,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
        child: Row(
          children: aspects
              .map((a) => _pill(
                    a.$1,
                    selected: _selectedAspect == a.$2,
                    onTap: () => _setAspect(a.$2),
                  ))
              .toList(),
        ),
      ),
    );
  }

  void _confirmCrop() {
    // 完成裁剪：把当前裁剪框写入参数并退出裁剪页
    _switchTab(_EditorTab.adjust);
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

/// 编辑状态快照（撤回栈/取消恢复共用）：参数 + 质量。
class _EditSnapshot {
  final ImageEditParams params;
  final int quality;
  const _EditSnapshot(this.params, this.quality);
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
