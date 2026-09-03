import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart' show DragStartBehavior;
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import '../../core/icon_fonts/broken_icons.dart';
import '../../services/image_edit_service.dart';
import '../../services/image_metadata_service.dart';
import 'package:zenfile/l10n/generated/app_localizations.dart';

enum _EditorTab { adjust, draw, filters, resize, rotate, crop, strip }

enum _CropDragMode { none, move, tl, tr, bl, br }

enum _Corner { tl, tr, bl, br }

enum _DrawTool { pen, text, rect, ellipse, line, arrow, mosaic }

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
  bool _previewDirty = false; // 计算中又有新请求，完成后追一次（latest-wins）
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

  // ---- 绘图状态（笔画存入 _params.drawStrokes，撤销/取消/重置自动覆盖） ----
  _DrawTool _drawTool = _DrawTool.pen;
  int _drawColor = 0xFF000000;
  double _drawWidthSlider = 5; // 滑块值 1..20
  double get _drawWidth => _drawWidthSlider / 1000; // 归一化线宽
  bool get _drawTabActive => _tab == _EditorTab.draw;
  // 进行中笔画（归一化 0..1，相对最终显示图）；松手后并入 _params.drawStrokes
  List<Offset>? _draftPoints; // pen/mosaic 点序列
  Offset? _draftStart; // line/rect/ellipse/arrow 起点
  Offset? _draftEnd; // line/rect/ellipse/arrow 当前终点
  // 对象化编辑（rect/ellipse/text）：这些工具画出的内容作为可选中对象存在
  // drawStrokes 中（x/y/w/h/angle 归一化），支持选区框缩放/旋转/移动/二次编辑。
  int _selIndex = -1; // 选中对象在 drawStrokes 中的下标（-1 = 无）
  bool _objWidthPending = false; // 滑块正在修改选中对象，松手时统一入撤销栈并重算
  // 自动隐藏辅助框：默认开启，仅选中对象显示区框/手柄/关闭，其余对象只画图形/文本
  bool _autoHideBoxes = true;
  // 对象唯一 id 序列：文本就地编辑是异步提交（渲染 PNG），期间列表可能
  // 增删导致下标漂移，用 id 寻址编辑目标才不会写错对象。
  int _objIdSeq = 0;
  // 文本就地编辑：-1 = 新建文本，>=0 = 正在编辑的对象 id
  int _textEditTargetId = -1;
  _TextEditDraft? _textEditing; // 非 null = 正在就地输入
  // 文本字体样式（加粗/斜体/下划线），作用于当前输入、新建与选中的文本对象
  bool _textBold = false;
  bool _textItalic = false;
  bool _textUnderline = false;
  bool _objDragActive = false; // 是否正在拖拽对象（移动/缩放旋转）
  bool _objDragIsHandle = false; // 拖拽是否从手柄开始（true=缩放旋转）
  Offset _objDragStartNorm = Offset.zero; // 拖拽起点（归一化）
  Rect _objDragStartRect = Rect.zero; // 拖拽开始时对象矩形（归一化）
  double _objDragStartAngle = 0; // 拖拽开始时对象角度（度）
  Rect? _objDraftRect; // 拖拽中的实时矩形（归一化）
  double _objDraftAngle = 0; // 拖拽中的实时角度（度）
  static const List<int> _paletteColors = [
    0xFF000000, // 黑
    0xFFFFFFFF, // 白
    0xFFD32F2F, // 红
    0xFFF57C00, // 橙
    0xFFFBC02D, // 黄
    0xFF388E3C, // 绿
    0xFF1976D2, // 蓝
    0xFF7B1FA2, // 紫
  ];

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
    // 正在计算时标记待重算（latest-wins），完成后追一次，避免连续操作
    // （如拖拽/缩放对象多次提交）导致预览停在旧图、界面像“冻结”。
    if (_processing) {
      _previewDirty = true;
      return;
    }
    // 「仅清除元数据」且无其它视觉编辑：像素不变，直接显示原图，
    // 避免无谓的重编码（重编码会损失画质并让预览与实际保存不一致）。
    if (_params.stripOnly && !_params.hasVisualChanges) {
      setState(() {
        _previewBytes = _bytes;
        _processing = false;
      });
      return;
    }
    setState(() => _processing = true);
    var paramsForPreview = _cropTabActive
        ? _params.copyWith(cropX: null, cropY: null, cropW: null, cropH: null)
        : _params;
    if (_drawTabActive) {
      // 绘图 tab：矩形/椭圆/文本对象由画布 painter 实时绘制，背景图
      // 只渲染画笔/马赛克/线段/箭头，拖动/缩放对象时不会留下旧位置残影。
      paramsForPreview = paramsForPreview.copyWith(
        drawStrokes: paramsForPreview.drawStrokes.where((s) {
          final t = s['tool'] as String?;
          return t != 'rect' && t != 'ellipse' && t != 'text';
        }).toList(),
      );
    }
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
      if (_previewDirty) {
        _previewDirty = false;
        _recomputePreview();
      }
    } catch (_) {
      if (!mounted) return;
      setState(() => _processing = false);
      if (_previewDirty) {
        _previewDirty = false;
        _recomputePreview();
      }
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
      _selIndex = -1; // 参数已恢复，旧的选中下标可能失效
      _objDraftRect = null;
      _objDragActive = false;
      _disposeTextEdit();
      _widthCtrl.text = (s.params.targetWidth ?? _info?.width ?? 0).toString();
      _heightCtrl.text = (s.params.targetHeight ?? _info?.height ?? 0)
          .toString();
    });
    _recomputePreview();
  }

  /// 撤回：回到上一次修改前的状态。
  void _undoEdit() {
    if (_undoStack.isEmpty) return;
    _restore(_undoStack.removeLast());
  }

  /// 静默关闭就地输入（不提交内容）：controller/focus 一并释放。
  void _disposeTextEdit() {
    _textEditing?.ctrl.dispose();
    _textEditing?.focus.dispose();
    _textEditing = null;
    _textEditTargetId = -1;
  }

  /// 重置：将当前 tab 的参数恢复默认（其它 tab 的修改保留）。
  void _resetTab() {
    _pushUndo();
    switch (_tab) {
      case _EditorTab.adjust:
        _params = _params.copyWith(
          brightness: 1.0,
          contrast: 1.0,
          saturation: 1.0,
        );
      case _EditorTab.filters:
        _params = _params.copyWith(filter: 'none');
      case _EditorTab.resize:
        _params = _params.copyWith(targetWidth: null, targetHeight: null);
        _quality = 90;
        _widthCtrl.text = (_info?.width ?? 0).toString();
        _heightCtrl.text = (_info?.height ?? 0).toString();
      case _EditorTab.rotate:
        _params = _params.copyWith(
          rotateAngle: 0,
          flipHorizontal: false,
          flipVertical: false,
        );
      case _EditorTab.crop:
        _cropRect = Rect.fromLTRB(0, 0, 1, 1);
        _selectedAspect = null;
        _params = _params.copyWith(
          cropX: null,
          cropY: null,
          cropW: null,
          cropH: null,
        );
      case _EditorTab.draw:
        _draftPoints = null;
        _draftStart = null;
        _draftEnd = null;
        _selIndex = -1;
        _objDraftRect = null;
        _objDragActive = false;
        _objWidthPending = false;
        _disposeTextEdit();
        _params = _params.copyWith(drawStrokes: const []);
      case _EditorTab.strip:
        _params = _params.copyWith(stripOnly: false);
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
      final Rect? next =
          (r != null &&
              (r.left > 0.001 ||
                  r.top > 0.001 ||
                  r.right < 0.999 ||
                  r.bottom < 0.999))
          ? r
          : null;
      final Rect? committed = (_params.cropX != null)
          ? Rect.fromLTWH(
              _params.cropX!,
              _params.cropY!,
              _params.cropW!,
              _params.cropH!,
            )
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
        _params = _params.copyWith(
          cropX: null,
          cropY: null,
          cropW: null,
          cropH: null,
        );
      }
    }
  }

  Future<void> _switchTab(_EditorTab tab) async {
    if (tab == _tab) return;
    _commitCropIfNeeded();
    // 切走绘图 tab 时：就地输入的文本先自动保存（等提交完成再记录
    // 新 tab 快照，避免「取消」把刚输入的文字回滚丢掉）；未提交草稿
    // 丢弃；未输入内容的空文本区框一并清理（无视觉内容，无需入撤销栈）
    final leavingDraw = _tab == _EditorTab.draw;
    if (leavingDraw && _textEditing != null) {
      await _commitTextEdit();
      if (!mounted) return;
    }
    if (leavingDraw) {
      _draftPoints = null;
      _draftStart = null;
      _draftEnd = null;
      _selIndex = -1;
      _objDraftRect = null;
      _objDragActive = false;
      _objWidthPending = false;
      _disposeTextEdit();
      _removeEmptyTextObjects();
    }
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
    } else if ((norm.dx - r.right).abs() < thresh &&
        (norm.dy - r.top).abs() < thresh) {
      _dragMode = _CropDragMode.tr;
    } else if ((norm.dx - r.left).abs() < thresh &&
        (norm.dy - r.bottom).abs() < thresh) {
      _dragMode = _CropDragMode.bl;
    } else if ((norm.dx - r.right).abs() < thresh &&
        (norm.dy - r.bottom).abs() < thresh) {
      _dragMode = _CropDragMode.br;
    } else if (norm.dx > r.left &&
        norm.dx < r.right &&
        norm.dy > r.top &&
        norm.dy < r.bottom) {
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
        final left = (r.left + (norm.dx - _dragStartNorm.dx)).clamp(
          0.0,
          1.0 - r.width,
        );
        final top = (r.top + (norm.dy - _dragStartNorm.dy)).clamp(
          0.0,
          1.0 - r.height,
        );
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
  Rect _resizeCorner(
    Rect r,
    Offset norm,
    double ar,
    double wh,
    bool locked,
    double minS,
    _Corner corner,
  ) {
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

  // ---- 绘图手势（归一化坐标相对最终显示图） ----
  Offset _toNorm(Offset local) {
    final disp = _displayRect;
    if (disp.isEmpty || disp.width <= 0 || disp.height <= 0) return Offset.zero;
    return Offset(
      ((local.dx - disp.left) / disp.width).clamp(0.0, 1.0),
      ((local.dy - disp.top) / disp.height).clamp(0.0, 1.0),
    );
  }

  Offset _normToPx(Offset n) => Offset(
    _displayRect.left + n.dx * _displayRect.width,
    _displayRect.top + n.dy * _displayRect.height,
  );

  // ---- 对象化编辑（rect/ellipse/text 为可选中对象） ----
  Rect _objNormRect(Map<String, Object> s) {
    final x = (s['x'] as num).toDouble();
    final y = (s['y'] as num).toDouble();
    final w = (s['w'] as num).toDouble();
    final h = (s['h'] as num).toDouble();
    return Rect.fromLTWH(x, y, w, h);
  }

  double _objAngle(Map<String, Object> s) =>
      (s['angle'] as num?)?.toDouble() ?? 0;

  /// 归一化矩形绕中心顺时针旋转 angle 后的 4 顶点（归一化坐标）。
  List<Offset> _rotatedNormCorners(Rect r, double angle) {
    final c = r.center;
    final a = angle * math.pi / 180;
    final ca = math.cos(a);
    final sa = math.sin(a);
    final corners = [r.topLeft, r.topRight, r.bottomRight, r.bottomLeft];
    return corners.map((p) {
      final dx = p.dx - c.dx;
      final dy = p.dy - c.dy;
      return Offset(c.dx + dx * ca - dy * sa, c.dy + dx * sa + dy * ca);
    }).toList();
  }

  bool _pointInRotatedRect(Offset n, Rect r, double angle) {
    final pts = _rotatedNormCorners(r, angle);
    var neg = false;
    var pos = false;
    for (var i = 0; i < 4; i++) {
      final p1 = pts[i];
      final p2 = pts[(i + 1) % 4];
      final cross =
          (p2.dx - p1.dx) * (n.dy - p1.dy) - (p2.dy - p1.dy) * (n.dx - p1.dx);
      if (cross < 0) {
        neg = true;
      } else if (cross > 0) {
        pos = true;
      }
      if (neg && pos) return false;
    }
    return true;
  }

  bool _isObjectStroke(Map<String, Object> s) {
    final t = s['tool'] as String?;
    return t == 'rect' || t == 'ellipse' || t == 'text';
  }

  /// 命中检测：返回命中的对象下标（后画的在上层），-1 = 无。
  /// 选中对象若处于拖拽中（draft 有效）则按 draft 实时位置检测，
  /// 避免拖动/缩放后再次操作时手柄与对象“跟不上手指”。
  int _hitObject(Offset n) {
    final strokes = _params.drawStrokes;
    for (var i = strokes.length - 1; i >= 0; i--) {
      final s = strokes[i];
      if (!_isObjectStroke(s)) continue;
      final Rect r;
      final double a;
      if (i == _selIndex && _objDraftRect != null) {
        r = _objDraftRect!;
        a = _objDraftAngle;
      } else {
        r = _objNormRect(s);
        a = _objAngle(s);
      }
      if (_pointInRotatedRect(n, r, a)) return i;
    }
    return -1;
  }

  /// 选中对象左上角关闭按钮是否被命中（像素半径 ~26）。
  bool _hitClose(Offset n) {
    if (_selIndex < 0 || _selIndex >= _params.drawStrokes.length) return false;
    final s = _params.drawStrokes[_selIndex];
    final corners = _rotatedNormCorners(
      _objDraftRect ?? _objNormRect(s),
      _objDraftRect != null ? _objDraftAngle : _objAngle(s),
    );
    final c = _normToPx(corners[0]); // 左上角
    return (_normToPx(n) - c).distance < 26;
  }

  /// 选中对象右下角缩放/旋转手柄是否被命中（像素半径 ~30，含框外）。
  /// 手柄中心在框角上、一半在框外，命中区必须外扩，否则小框几乎拖不到。
  bool _hitHandle(Offset n) {
    if (_selIndex < 0 || _selIndex >= _params.drawStrokes.length) return false;
    final s = _params.drawStrokes[_selIndex];
    if (!_isObjectStroke(s)) return false;
    final corners = _rotatedNormCorners(
      _objDraftRect ?? _objNormRect(s),
      _objDraftRect != null ? _objDraftAngle : _objAngle(s),
    );
    final h = _normToPx(corners[2]); // 右下角
    return (_normToPx(n) - h).distance < 30;
  }

  void _snapshotSel() {
    final s = _params.drawStrokes[_selIndex];
    _objDragStartRect = _objNormRect(s);
    _objDragStartAngle = _objAngle(s);
  }

  void _updateObjMove(Offset n) {
    final d = n - _objDragStartNorm;
    final r = _objDragStartRect.shift(d);
    final c = r.center;
    final nc = Offset(c.dx.clamp(0.0, 1.0), c.dy.clamp(0.0, 1.0));
    setState(() {
      _objDraftRect = Rect.fromCenter(
        center: nc,
        width: r.width,
        height: r.height,
      );
      // 移动不改变角度，避免残留上一次缩放旋转的角度
      _objDraftAngle = _objDragStartAngle;
    });
  }

  void _updateObjScaleRotate(Offset n) {
    final c = _objDragStartRect.center;
    final d0 = (_objDragStartNorm - c).distance;
    final d1 = (n - c).distance;
    final scale = d0 <= 1e-4 ? 1.0 : d1 / d0;
    final newW = (_objDragStartRect.width * scale).clamp(0.01, 2.0);
    final newH = (_objDragStartRect.height * scale).clamp(0.01, 2.0);
    final a0 = math.atan2(
      _objDragStartNorm.dy - c.dy,
      _objDragStartNorm.dx - c.dx,
    );
    final a1 = math.atan2(n.dy - c.dy, n.dx - c.dx);
    var dA = (a1 - a0) * 180 / math.pi;
    var newAngle = (_objDragStartAngle + dA) % 360;
    if (newAngle < 0) newAngle += 360;
    setState(() {
      _objDraftRect = Rect.fromCenter(center: c, width: newW, height: newH);
      _objDraftAngle = newAngle;
    });
  }

  /// 拖拽结束：把草稿矩形/角度写回 drawStrokes 并重算预览。
  void _commitObjTransform() {
    final idx = _selIndex;
    final draft = _objDraftRect;
    setState(() {
      _objDragActive = false;
      _objDragIsHandle = false;
      _objDraftRect = null;
    });
    if (idx < 0 || idx >= _params.drawStrokes.length || draft == null) return;
    _pushUndo();
    final strokes = [..._params.drawStrokes];
    final s = Map<String, Object>.from(strokes[idx]);
    s['x'] = draft.left;
    s['y'] = draft.top;
    s['w'] = draft.width;
    s['h'] = draft.height;
    s['angle'] = _objDraftAngle;
    strokes[idx] = s;
    // 对象由 painter 实时绘制，提交后直接按新坐标显示，无需重算背景
    setState(() => _params = _params.copyWith(drawStrokes: strokes));
  }

  void _deleteSelectedObject() => _deleteObjectAt(_selIndex);

  /// 删除指定下标的对象；后续对象下标前移，选中态相应复位。
  void _deleteObjectAt(int idx) {
    if (idx < 0 || idx >= _params.drawStrokes.length) return;
    _pushUndo();
    final strokes = [..._params.drawStrokes]..removeAt(idx);
    setState(() {
      _params = _params.copyWith(drawStrokes: strokes);
      if (_selIndex == idx) {
        _selIndex = -1;
        _objDraftRect = null;
        _objDragActive = false;
      } else if (_selIndex > idx) {
        _selIndex--;
      }
    });
  }

  void _onDrawPanStart(Offset local) {
    final n = _toNorm(local);
    // 1) 选中对象的右下角手柄优先命中（允许在框外 ~30px 内起拖）：
    //    onPanStart 收到的是手势获胜时的位置（已偏离按下点 18px+），
    //    小框场景手指几乎必然在框外，必须先判手柄再判框内。
    if (_hitHandle(n)) {
      setState(() {
        _objDragActive = true;
        _objDragIsHandle = true;
        _objDragStartNorm = n;
        _snapshotSel();
      });
      return;
    }
    // 2) 文本工具：拖到对象上 = 选中并移动（输入中同样可拖）；
    //    空白处无草稿（新文本由「文本」按钮创建）。
    if (_drawTool == _DrawTool.text) {
      final hit = _hitObject(n);
      if (hit >= 0) {
        setState(() {
          _selIndex = hit;
          _objDragActive = true;
          _objDragIsHandle = false;
          _objDragStartNorm = n;
          _snapshotSel();
        });
      }
      return;
    }
    // 3) 形状工具：按下已有对象（rect/ellipse/text）时选中并进入移动/
    //    缩放编辑（点击区框即可编辑），仅在空白处才画新形状——避免把
    //    “点旧对象”误判成“画新形状”。pen/line/arrow/mosaic 仍直接画新。
    final hitObj = _hitObject(n);
    if (hitObj >= 0 && _isObjectStroke(_params.drawStrokes[hitObj])) {
      if (_drawTool == _DrawTool.rect ||
          _drawTool == _DrawTool.ellipse ||
          _drawTool == _DrawTool.text) {
        setState(() {
          _selIndex = hitObj;
          _objDragActive = true;
          _objDragIsHandle = false;
          _objDragStartNorm = n;
          _snapshotSel();
        });
        return;
      }
    }
    _startShapeDraftAt(n);
  }

  /// 未命中对象时按下：按当前工具开始画新形状的草稿。
  void _startShapeDraftAt(Offset n) {
    switch (_drawTool) {
      case _DrawTool.pen:
      case _DrawTool.mosaic:
        setState(() => _draftPoints = [n]);
      case _DrawTool.line:
      case _DrawTool.rect:
      case _DrawTool.ellipse:
      case _DrawTool.arrow:
        setState(() {
          _draftStart = n;
          _draftEnd = n;
        });
      case _DrawTool.text:
        break; // 文本区框由「文本」按钮创建，拖拽不产生草稿
    }
  }

  void _onDrawPanUpdate(Offset local) {
    final n = _toNorm(local);
    if (_objDragActive) {
      if (_objDragIsHandle) {
        _updateObjScaleRotate(n);
      } else {
        _updateObjMove(n);
      }
      return;
    }
    _updateShapeDraft(n);
  }

  /// 草稿跟随手指（pen 采样点 / 形状终点）。
  void _updateShapeDraft(Offset n) {
    switch (_drawTool) {
      case _DrawTool.pen:
      case _DrawTool.mosaic:
        final pts = _draftPoints;
        if (pts == null || pts.isEmpty) return;
        final last = pts.last;
        final d = (n - last).distance;
        if (d < 0.003) return; // 过滤过密采样点
        setState(() => _draftPoints = [...pts, n]);
      case _DrawTool.line:
      case _DrawTool.rect:
      case _DrawTool.ellipse:
      case _DrawTool.arrow:
        setState(() => _draftEnd = n);
      case _DrawTool.text:
        break;
    }
  }

  void _onDrawPanEnd(Offset? local) {
    if (_objDragActive) {
      _commitObjTransform();
      return;
    }
    switch (_drawTool) {
      case _DrawTool.pen:
      case _DrawTool.mosaic:
        final pts = _draftPoints;
        if (pts != null && pts.length >= 2) {
          final flat = <double>[];
          for (final p in pts) {
            flat.add(p.dx);
            flat.add(p.dy);
          }
          _commitDraw({
            'tool': _drawTool == _DrawTool.mosaic ? 'mosaic' : 'pen',
            'color': _drawColor,
            'width': _drawWidth,
            'points': flat,
          });
        }
        setState(() => _draftPoints = null);
      case _DrawTool.line:
      case _DrawTool.rect:
      case _DrawTool.ellipse:
      case _DrawTool.arrow:
        final s = _draftStart;
        final e = _draftEnd;
        if (s != null && e != null && (e - s).distance > 0.006) {
          if (_drawTool == _DrawTool.rect || _drawTool == _DrawTool.ellipse) {
            // 对象化形状：转成 x/y/w/h（归一化，保正宽高）
            final r = Rect.fromPoints(s, e);
            _commitObject({
              'tool': _drawTool == _DrawTool.rect ? 'rect' : 'ellipse',
              'color': _drawColor,
              'width': _drawWidth,
              'x': r.left,
              'y': r.top,
              'w': r.width,
              'h': r.height,
              'angle': 0.0,
            });
          } else {
            _commitDraw({
              'tool': _drawTool == _DrawTool.line ? 'line' : 'arrow',
              'color': _drawColor,
              'width': _drawWidth,
              'points': <double>[s.dx, s.dy, e.dx, e.dy],
            });
          }
        }
        setState(() {
          _draftStart = null;
          _draftEnd = null;
        });
      case _DrawTool.text:
        break;
    }
  }

  /// 提交一个对象化形状（rect/ellipse/text），并自动选中以便继续调整。
  /// 对象内容由画布 painter 直接绘制，无需重算服务端背景。
  void _commitObject(Map<String, Object> obj) {
    _pushUndo();
    setState(() {
      obj['id'] = ++_objIdSeq;
      _params = _params.copyWith(drawStrokes: [..._params.drawStrokes, obj]);
      _selIndex = _params.drawStrokes.length - 1;
    });
  }

  /// 是否为「未输入内容的空文本区框」（无视觉内容，可静默清理）。
  bool _isEmptyTextObject(Map<String, Object> s) =>
      s['tool'] == 'text' && (s['text'] as String? ?? '').isEmpty;

  /// 移除所有空文本区框：切换工具/离开绘图页/在空白处新建文本时调用。
  void _removeEmptyTextObjects() {
    if (!_params.drawStrokes.any(_isEmptyTextObject)) return;
    setState(() {
      _params = _params.copyWith(
        drawStrokes:
            _params.drawStrokes.where((s) => !_isEmptyTextObject(s)).toList(),
      );
      _selIndex = -1;
      _objDraftRect = null;
    });
  }

  /// 点击「文本」工具时：在图片中心创建空文本区框并选中。
  /// 区框右下角手柄可缩放/旋转，左上角关闭按钮删除，长按（或直接拖动）
  /// 移动位置；空文本区框内显示「请输入文本」提示（l10n）。
  /// 矩形/椭圆不预建区框：按住拖拽画出形状，松手后自动选中并显示区框。
  void _createCenterObject() {
    final obj = <String, Object>{
      'tool': 'text',
      'text': '',
      'color': _drawColor,
      'width': 0.06,
      'x': 0.37,
      'y': 0.47,
      'w': 0.26,
      'h': 0.06,
      'angle': 0.0,
      'bold': _textBold,
      'italic': _textItalic,
      'underline': _textUnderline,
    };
    _pushUndo();
    setState(() {
      obj['id'] = ++_objIdSeq;
      // 顺带清掉遗留的空文本区框（清理+新建合并为一次撤销记录）
      final strokes = _params.drawStrokes
          .where((s) => !_isEmptyTextObject(s))
          .toList();
      _params = _params.copyWith(drawStrokes: [...strokes, obj]);
      _selIndex = strokes.length;
      _textEditTargetId = -1;
      // 滑块同步到新文本区框的字号（字号 = 滑块/50）
      _drawWidthSlider = (0.06 * 50).clamp(1, 20).toDouble();
    });
  }

  /// 字体样式开关（bold/italic/underline）：输入中实时生效，提交时写入
  /// 对象；选中文本对象时立即写入对象并重渲染 textPng（保存一致）。
  void _onTextStyleToggle(String key) {
    final next = key == 'bold'
        ? !_textBold
        : key == 'italic'
        ? !_textItalic
        : !_textUnderline;
    setState(() {
      if (key == 'bold') {
        _textBold = next;
      } else if (key == 'italic') {
        _textItalic = next;
      } else {
        _textUnderline = next;
      }
    });
    // 就地输入中：样式随提交统一写入对象，无需立即更新
    if (_textEditing != null) return;
    final idx = _selIndex;
    if (idx < 0 || idx >= _params.drawStrokes.length) return;
    if (_params.drawStrokes[idx]['tool'] != 'text') return;
    _applyTextStyleTo(
      idx,
      _textBold,
      _textItalic,
      _textUnderline,
    );
  }

  /// 把字体样式写入选中文本对象；有内容时重渲染 textPng 并按新宽高比
  /// 调整 w（中心与字号保持不变）。渲染为异步，完成后按 id 重新定位，
  /// 避免期间列表变动写错对象。
  Future<void> _applyTextStyleTo(
    int idx,
    bool bold,
    bool italic,
    bool underline,
  ) async {
    final s = _params.drawStrokes[idx];
    final id = (s['id'] as num?)?.toInt() ?? -1;
    final text = s['text'] as String? ?? '';
    final color = (s['color'] as num?)?.toInt() ?? _drawColor;
    Uint8List? png;
    double? aspect;
    if (text.isNotEmpty) {
      try {
        final r = await _renderTextPng(
          text,
          fontSize: 96,
          color: color,
          maxWidth: 1400,
          bold: bold,
          italic: italic,
          underline: underline,
        );
        png = r.bytes;
        aspect = r.aspect;
      } catch (_) {}
    }
    if (!mounted) return;
    final list = [..._params.drawStrokes];
    final curIdx = id < 0 ? idx : list.indexWhere((e) => (e['id'] as num?)?.toInt() == id);
    if (curIdx < 0) return;
    final cur = Map<String, Object>.from(list[curIdx]);
    cur['bold'] = bold;
    cur['italic'] = italic;
    cur['underline'] = underline;
    if (png != null && aspect != null) {
      cur['textPng'] = png;
      final rect = _objNormRect(cur);
      final h = rect.height;
      final w = (h * aspect).clamp(0.01, 2.0).toDouble();
      cur['h'] = h;
      cur['width'] = h;
      cur['w'] = w;
      cur['x'] = rect.center.dx - w / 2;
      cur['y'] = rect.center.dy - h / 2;
    }
    _pushUndo();
    list[curIdx] = cur;
    setState(() => _params = _params.copyWith(drawStrokes: list));
  }

  /// 下方色板点击：有选中对象 → 改对象颜色；否则改当前绘制颜色。
  /// 对象由画布 painter 实时绘制，无需重算背景；文本对象需同步重渲染
  /// textPng（保存时服务端用它合成，保证颜色一致）。
  Future<void> _onPalettePick(int c) async {
    final idx = _selIndex;
    final strokes = _params.drawStrokes;
    if (idx >= 0 && idx < strokes.length && _isObjectStroke(strokes[idx])) {
      _pushUndo();
      final list = [...strokes];
      final s = Map<String, Object>.from(list[idx]);
      s['color'] = c;
      if (s['tool'] == 'text') {
        final text = s['text'] as String? ?? '';
        if (text.isNotEmpty) {
          try {
            final r = await _renderTextPng(
              text,
              fontSize: 96,
              color: c,
              maxWidth: 1400,
              bold: s['bold'] == true,
              italic: s['italic'] == true,
              underline: s['underline'] == true,
            );
            if (r.bytes != null) s['textPng'] = r.bytes!;
          } catch (_) {}
        }
      }
      list[idx] = s;
      if (!mounted) return;
      setState(() {
        _params = _params.copyWith(drawStrokes: list);
        _drawColor = c;
      });
    } else {
      setState(() => _drawColor = c);
    }
  }

  /// 下方滑块拖动：有选中对象 → 实时改对象粗细（文本=字号）；否则改当前绘制粗细。
  /// 就地输入中的文本对象即选中对象，同样实时生效（画笔绘制实时文字）。
  void _onDrawWidthChanged(double v) {
    final idx = _selIndex;
    final strokes = _params.drawStrokes;
    if (idx >= 0 && idx < strokes.length && _isObjectStroke(strokes[idx])) {
      if (!_objWidthPending) {
        _pushUndo(); // 记录调整前状态
        _objWidthPending = true;
      }
      final list = [...strokes];
      final s = Map<String, Object>.from(list[idx]);
      if (s['tool'] == 'text') {
        // 文本字号：h = 滑块*20/1000（0.02..0.4），w 按原宽高比缩放
        final newH = (v / 1000 * 20).clamp(0.02, 0.4).toDouble();
        final oldH = (s['h'] as num?)?.toDouble() ?? newH;
        final oldW = (s['w'] as num?)?.toDouble() ?? newH;
        final aspect = oldW / oldH;
        s['width'] = newH;
        s['h'] = newH;
        s['w'] = (newH * aspect).clamp(0.01, 2.0);
      } else {
        s['width'] = (v / 1000).toDouble();
      }
      list[idx] = s;
      setState(() {
        _params = _params.copyWith(drawStrokes: list);
        _drawWidthSlider = v;
      });
    } else {
      setState(() => _drawWidthSlider = v);
    }
  }

  /// 滑块松手：正在改选中对象时，文本需重渲染高清 textPng（保存一致），
  /// 其余对象由 painter 实时绘制，无需重算背景。
  Future<void> _onDrawWidthChangedEnd() async {
    final idx = _selIndex;
    if (!_objWidthPending) return;
    _objWidthPending = false;
    if (idx < 0 || idx >= _params.drawStrokes.length) return;
    final s = _params.drawStrokes[idx];
    if (s['tool'] != 'text') return;
    final text = s['text'] as String? ?? '';
    final color = (s['color'] as num?)?.toInt() ?? _drawColor;
    if (text.isEmpty) return;
    try {
      final r = await _renderTextPng(
        text,
        fontSize: 96,
        color: color,
        maxWidth: 1400,
        bold: s['bold'] == true,
        italic: s['italic'] == true,
        underline: s['underline'] == true,
      );
      if (r.bytes == null) return;
      final list = [..._params.drawStrokes];
      final ns = Map<String, Object>.from(list[idx]);
      ns['textPng'] = r.bytes!;
      final h = (s['h'] as num?)?.toDouble() ?? 0.1;
      final w = (h * r.aspect).clamp(0.01, 2.0);
      ns['w'] = w;
      list[idx] = ns;
      if (!mounted) return;
      setState(() => _params = _params.copyWith(drawStrokes: list));
    } catch (_) {}
  }

  /// 点击画布：关闭按钮删除对象；点文本区框内弹键盘就地输入；
  /// 点其它对象仅选中（颜色/粗细/样式用下方面板就地调整）；
  /// 点空白处仅取消选中——不弹输入框（新文本区框由「文本」按钮创建）。
  void _onDrawTapUp(Offset local) {
    final n = _toNorm(local);
    // 正在就地输入文本：
    // - 点关闭按钮 → 放弃输入并删除对象
    // - 点输入中的区框内 → 继续输入（键盘被收起时重新拉起）
    // - 点其它位置 → 提交输入
    if (_textEditing != null) {
      if (_selIndex >= 0 && _hitClose(n)) {
        _cancelTextEdit(deleteTarget: true);
        return;
      }
      final editIdx = _params.drawStrokes.indexWhere(
        (s) => (s['id'] as num?)?.toInt() == _textEditTargetId,
      );
      if (editIdx >= 0 && _hitObject(n) == editIdx) {
        _textEditing!.focus.requestFocus(); // 收起键盘后点框内重新聚焦
        return;
      }
      _commitTextEdit();
      return;
    }
    // 点击选中对象的关闭按钮 → 删除；手柄区域点击 → 保持选中（防误触取消）
    if (_selIndex >= 0 && _hitClose(n)) {
      _deleteSelectedObject();
      return;
    }
    if (_selIndex >= 0 && _hitHandle(n)) {
      return;
    }
    // 点击对象 → 选中；空文本区框（或已选中的文本再点一次）→ 进入输入
    final hit = _hitObject(n);
    if (hit >= 0) {
      final s = _params.drawStrokes[hit];
      final isText = s['tool'] == 'text';
      final emptyText = isText && (s['text'] as String? ?? '').isEmpty;
      if (isText &&
          _drawTool == _DrawTool.text &&
          (emptyText || hit == _selIndex)) {
        _startTextEdit((s['id'] as num?)?.toInt() ?? -1);
        return;
      }
      setState(() {
        _selIndex = hit;
        // 同步下方色板/滑块/样式开关到该对象当前值，便于就地修改
        _drawColor = (s['color'] as num?)?.toInt() ?? _drawColor;
        final w = (s['width'] as num?)?.toDouble();
        if (w != null) {
          // 文本字号以当前区框高度为准（手柄缩放后 width 字段会滞后）
          _drawWidthSlider = isText
              ? (_objNormRect(s).height * 50).clamp(1, 20).toDouble()
              : (w * 1000).clamp(1, 20).toDouble();
        }
        if (isText) {
          _textBold = s['bold'] == true;
          _textItalic = s['italic'] == true;
          _textUnderline = s['underline'] == true;
        }
      });
      return;
    }
    // 点击空白：仅取消选中（文本输入只能通过点击文本区框进入）
    setState(() {
      _selIndex = -1;
      _objDraftRect = null;
    });
  }

  /// 放弃就地输入：关闭键盘并复位编辑态；deleteTarget 时连对象一并删除
  /// （关闭按钮语义 = 移除区框和内容，不入撤销栈的输入草稿直接丢弃）。
  void _cancelTextEdit({bool deleteTarget = false}) {
    final te = _textEditing;
    if (te != null) {
      te.ctrl.dispose();
      te.focus.dispose();
    }
    final targetId = _textEditTargetId;
    setState(() {
      _textEditing = null;
      _textEditTargetId = -1;
    });
    if (deleteTarget) {
      final idx = _params.drawStrokes.indexWhere(
        (s) => (s['id'] as num?)?.toInt() == targetId,
      );
      if (idx >= 0) _deleteObjectAt(idx);
    }
  }

  /// 点击文本区框：就地打开输入（不弹对话框），键盘弹出直接输入。
  /// 沿用该对象的位置/字号/颜色/样式；清空文本提交时删除该对象。
  /// 输入文字由画笔实时绘制在区框内（随区框缩放旋转），真实输入框
  /// 隐藏在角落且不拦截手势——手柄/关闭/移动在输入中均可操作。
  void _startTextEdit(int targetId) {
    if (_textEditing != null) return; // 已在输入中
    if (targetId < 0) return;
    final idx = _params.drawStrokes.indexWhere(
      (s) => (s['id'] as num?)?.toInt() == targetId,
    );
    if (idx < 0) return;
    final s = _params.drawStrokes[idx];
    if (s['tool'] != 'text') return;
    setState(() {
      _selIndex = idx;
      _textEditTargetId = targetId;
      _drawColor = (s['color'] as num?)?.toInt() ?? _drawColor;
      _drawWidthSlider =
          (_objNormRect(s).height * 50).clamp(1, 20).toDouble();
      _textBold = s['bold'] == true;
      _textItalic = s['italic'] == true;
      _textUnderline = s['underline'] == true;
      _textEditing = _TextEditDraft(
        ctrl: TextEditingController(text: s['text'] as String? ?? ''),
        focus: FocusNode(),
      );
    });
  }

  /// 就地输入完成：渲染文字 PNG 并写回目标对象（按 id 寻址规避异步
  /// 渲染期间列表变动）；清空文本提交 → 删除该对象。
  /// 位置/字号取对象当前区框（输入中允许手柄缩放/长按移动/旋转）。
  Future<void> _commitTextEdit() async {
    final te = _textEditing;
    if (te == null) return;
    final text = te.ctrl.text.trim();
    final targetId = _textEditTargetId;
    te.ctrl.dispose();
    te.focus.dispose();
    setState(() {
      _textEditing = null;
      _textEditTargetId = -1;
    });
    if (text.isEmpty) {
      final idx = _params.drawStrokes.indexWhere(
        (s) => (s['id'] as num?)?.toInt() == targetId,
      );
      if (idx >= 0) _deleteObjectAt(idx);
      return;
    }
    try {
      final r = await _renderTextPng(
        text,
        fontSize: 96,
        color: _drawColor,
        maxWidth: 1400,
        bold: _textBold,
        italic: _textItalic,
        underline: _textUnderline,
      );
      if (r.bytes == null) return;
      final idx = _params.drawStrokes.indexWhere(
        (s) => (s['id'] as num?)?.toInt() == targetId && s['tool'] == 'text',
      );
      if (idx < 0) return; // 对象已被删除
      // 更新文本对象：保留中心与角度（输入中可能被移动/旋转过），
      // 字号 = 区框当前高度，宽按文字宽高比自适应，内容/样式刷新
      final old = _params.drawStrokes[idx];
      final oldRect = _objNormRect(old);
      final h = oldRect.height.clamp(0.02, 0.4).toDouble();
      final w = (h * r.aspect).clamp(0.01, 2.0).toDouble();
      _pushUndo();
      if (!mounted) return;
      final list = [..._params.drawStrokes];
      list[idx] = {
        ...old,
        'text': text,
        'textPng': r.bytes!,
        'color': _drawColor,
        'width': h,
        'w': w,
        'h': h,
        'x': oldRect.center.dx - w / 2,
        'y': oldRect.center.dy - h / 2,
        'bold': _textBold,
        'italic': _textItalic,
        'underline': _textUnderline,
      };
      setState(() {
        _params = _params.copyWith(drawStrokes: list);
        _selIndex = idx;
      });
    } catch (_) {}
  }

  /// 就地输入过程中，根据当前文本实时调整对象区框宽度（保持中心与字号），
  /// 使选区框始终贴合文字，避免文字被区框截断或在未保存前溢出显示不全。
  void _relayoutLiveTextBox() {
    if (_textEditing == null) return;
    final id = _textEditTargetId;
    if (id < 0) return;
    final idx = _params.drawStrokes.indexWhere(
      (s) => (s['id'] as num?)?.toInt() == id,
    );
    if (idx < 0) return;
    final s = _params.drawStrokes[idx];
    if (s['tool'] != 'text') return;
    final text = _textEditing!.ctrl.text;
    final rect = _objNormRect(s);
    final h = rect.height.clamp(0.02, 0.4);
    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          fontSize: 100,
          fontWeight: _textBold ? FontWeight.w700 : FontWeight.w400,
          fontStyle: _textItalic ? FontStyle.italic : FontStyle.normal,
          decoration: _textUnderline ? TextDecoration.underline : TextDecoration.none,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    final w = text.isEmpty
        ? h * 4.33
        : (tp.height > 0
            ? (h * (tp.width / tp.height)).clamp(0.01, 2.0)
            : h * 4.33);
    final list = [..._params.drawStrokes];
    final ns = Map<String, Object>.from(list[idx]);
    ns['h'] = h;
    ns['width'] = h;
    ns['w'] = w;
    ns['x'] = rect.center.dx - w / 2;
    ns['y'] = rect.center.dy - h / 2;
    list[idx] = ns;
    setState(() => _params = _params.copyWith(drawStrokes: list));
  }

  /// 把一笔确认的笔画并入参数（压入撤销栈后重算预览）。
  void _commitDraw(Map<String, Object> stroke) {
    _pushUndo();
    setState(() {
      _params = _params.copyWith(drawStrokes: [..._params.drawStrokes, stroke]);
    });
    _recomputePreview();
  }

  /// 用 Flutter 把文本渲染成透明背景 PNG（支持中文/emoji/任意文字与
  /// 加粗/斜体/下划线样式），同时返回文本宽高比用于对象尺寸计算。
  Future<({Uint8List? bytes, double aspect})> _renderTextPng(
    String text, {
    required double fontSize,
    required int color,
    required double maxWidth,
    bool bold = false,
    bool italic = false,
    bool underline = false,
  }) async {
    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          color: Color(color),
          fontSize: fontSize,
          fontWeight: bold ? FontWeight.w700 : FontWeight.w400,
          fontStyle: italic ? FontStyle.italic : FontStyle.normal,
          decoration: underline
              ? TextDecoration.underline
              : TextDecoration.none,
          decorationColor: Color(color),
        ),
      ),
      textDirection: TextDirection.ltr,
      maxLines: 1,
    )..layout(maxWidth: math.max(maxWidth, 100000));
    if (tp.width <= 0 || tp.height <= 0) return (bytes: null, aspect: 1.0);
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    tp.paint(canvas, Offset.zero);
    final picture = recorder.endRecording();
    final uiImage = await picture.toImage(tp.width.ceil(), tp.height.ceil());
    final byteData = await uiImage.toByteData(format: ui.ImageByteFormat.png);
    return (
      bytes: byteData?.buffer.asUint8List(),
      aspect: tp.width / tp.height,
    );
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
    // 文本就地输入中：先自动提交保存为对象，避免保存时丢失
    if (_textEditing != null) {
      await _commitTextEdit();
      if (!mounted) return;
    }
    // 丢弃未输入内容的空文本区框（无视觉内容，不影响撤销栈）
    if (_params.drawStrokes.any(_isEmptyTextObject)) {
      _params = _params.copyWith(
        drawStrokes:
            _params.drawStrokes.where((s) => !_isEmptyTextObject(s)).toList(),
      );
    }
    final l10n = L10n.of(context);
    final navigator = Navigator.of(context);
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const AlertDialog(
        content: Row(
          children: [
            CircularProgressIndicator(),
            SizedBox(width: 16),
            Text('…'),
          ],
        ),
      ),
    );
    try {
      // 检查是否有文件大小限制
      final sizeLimitKB = int.tryParse(_fileSizeLimitCtrl.text) ?? 0;
      Uint8List out;
      if (_params.stripOnly && !_params.hasVisualChanges) {
        // 仅清除元数据：字节级无损剥离（不重编码、不损失画质）
        out = ImageMetadataService.stripMetadataBytes(_bytes!, isPng: _isPng);
      } else if (sizeLimitKB > 0 && !_isPng) {
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
        SnackBar(
          content: Text(
            '${l10n.editor_saved}  (${l10n.editor_output_size(sizeStr)})',
          ),
        ),
      );
      navigator.pop(true);
    } catch (e) {
      if (!mounted) return;
      navigator.pop();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(l10n.editor_save_failed(e.toString())),
          backgroundColor: Colors.redAccent,
        ),
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
        // 绘图页关闭键盘避让：就地输入文本时画布尺寸保持稳定，
        // 辅助框/手柄不因键盘弹出而缩放跳变（键盘临时盖住下方面板）。
        // 其它页（如缩放的输入框）保持默认避让行为。
        resizeToAvoidBottomInset: !_drawTabActive,
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
                  PopupMenuItem(
                    value: false,
                    child: Text(l10n.editor_save_as_copy),
                  ),
                  PopupMenuItem(
                    value: true,
                    child: Text(l10n.editor_overwrite_original),
                  ),
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
                  child: Text(
                    l10n.editor_unsupported,
                    textAlign: TextAlign.center,
                  ),
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
                              const Center(
                                child: CircularProgressIndicator(
                                  color: Colors.white70,
                                ),
                              ),
                            if (_cropTabActive && _cropRect != null)
                              Positioned.fill(
                                child: GestureDetector(
                                  onPanStart: (d) =>
                                      _onCropPanStart(d.localPosition),
                                  onPanUpdate: (d) =>
                                      _onCropPanUpdate(d.localPosition),
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
                            if (_drawTabActive)
                              Positioned.fill(
                                child: GestureDetector(
                                  behavior: HitTestBehavior.opaque,
                                  // down：onPanStart 报告手指按下点而非竞技场
                                  // 获胜点（获胜时手指已移出 18px+，小框的
                                  // 命中检测会全部落空，手柄拖拽失效）
                                  dragStartBehavior: DragStartBehavior.down,
                                  onTapUp: (d) => _onDrawTapUp(d.localPosition),
                                  onPanStart: (d) =>
                                      _onDrawPanStart(d.localPosition),
                                  onPanUpdate: (d) =>
                                      _onDrawPanUpdate(d.localPosition),
                                  onPanEnd: (_) => _onDrawPanEnd(null),
                                  onPanCancel: () {
                                    if (_objDragActive) {
                                      setState(() {
                                        _objDragActive = false;
                                        _objDragIsHandle = false;
                                        _objDraftRect = null;
                                        _draftPoints = null;
                                        _draftStart = null;
                                        _draftEnd = null;
                                      });
                                    }
                                  },
                                  onLongPressStart: (d) {
                                    final n = _toNorm(d.localPosition);
                                    // 长按手柄：同样进入缩放/旋转
                                    if (_hitHandle(n)) {
                                      setState(() {
                                        _objDragActive = true;
                                        _objDragIsHandle = true;
                                        _objDragStartNorm = n;
                                        _snapshotSel();
                                      });
                                      return;
                                    }
                                    final hit = _hitObject(n);
                                    if (hit >= 0) {
                                      setState(() {
                                        _selIndex = hit;
                                        _objDragActive = true;
                                        _objDragIsHandle = false;
                                        _objDragStartNorm = n;
                                        _snapshotSel();
                                      });
                                      return;
                                    }
                                    // 长按空白后拖动：与普通拖动一致地画草稿
                                    // （手势竞技场里长按胜出时 pan 不再回调）
                                    _startShapeDraftAt(n);
                                  },
                                  onLongPressMoveUpdate: (d) {
                                    final n = _toNorm(d.localPosition);
                                    if (_objDragActive) {
                                      if (!_objDragIsHandle) {
                                        _updateObjMove(n);
                                      }
                                      return;
                                    }
                                    _updateShapeDraft(n);
                                  },
                                  // 长按结束与普通拖拽结束同一套提交逻辑
                                  onLongPressEnd: (_) => _onDrawPanEnd(null),
                                  onLongPressCancel: () {
                                    setState(() {
                                      _objDragActive = false;
                                      _objDragIsHandle = false;
                                      _objDraftRect = null;
                                      _draftPoints = null;
                                      _draftStart = null;
                                      _draftEnd = null;
                                    });
                                  },
                                  child: CustomPaint(
                                    painter: _DrawPreviewPainter(
                                      displayRect: _displayRect,
                                      tool: _drawTool,
                                      color: _drawColor,
                                      width: _drawWidth,
                                      points: _draftPoints,
                                      draftStart: _draftStart,
                                      draftEnd: _draftEnd,
                                      strokes: _params.drawStrokes,
                                      selIndex: _selIndex,
                                      objDraftRect: _objDraftRect,
                                      objDraftAngle: _objDraftAngle,
                                      autoHideBoxes: _autoHideBoxes,
                                      textHint: l10n.editor_text_hint,
                                      textEditIdx: _textEditing != null
                                          ? _params.drawStrokes.indexWhere(
                                              (s) =>
                                                  (s['id'] as num?)?.toInt() ==
                                                  _textEditTargetId,
                                            )
                                          : -1,
                                      editText: _textEditing?.ctrl.text,
                                      editColor: _drawColor,
                                      editBold: _textBold,
                                      editItalic: _textItalic,
                                      editUnderline: _textUnderline,
                                    ),
                                  ),
                                ),
                              ),
                            // 隐藏的文本输入框：仅承接键盘输入（焦点/IME），
                            // 1×1 且透明且不拦截手势——实时文字由上方画笔
                            // 绘制在区框内（随区框缩放/旋转），手柄/关闭/
                            // 移动手势在输入中不会被输入框遮挡
                            if (_drawTabActive && _textEditing != null)
                              Positioned(
                                left: 0,
                                top: 0,
                                width: 1,
                                height: 1,
                                child: IgnorePointer(
                                  child: Opacity(
                                    opacity: 0,
                                    child: SizedBox(
                                      width: 1,
                                      height: 1,
                                      child: TextField(
                                        controller: _textEditing!.ctrl,
                                        focusNode: _textEditing!.focus,
                                        autofocus: true,
                                        maxLines: 1,
                                        // 每次输入触发重绘：画笔把实时文字
                                        // 画进区框
                                        onChanged: (_) => _relayoutLiveTextBox(),
                                        onSubmitted: (_) =>
                                            _commitTextEdit(),
                                      ),
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
                                    builder: (ctx, constraints) =>
                                        SingleChildScrollView(
                                          child: ConstrainedBox(
                                            constraints: BoxConstraints(
                                              minHeight: constraints.maxHeight,
                                            ),
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
                Icon(
                  icon,
                  size: 16,
                  color: selected ? scheme.onPrimary : scheme.onSurfaceVariant,
                ),
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
      (_EditorTab.draw, l10n.ui_draw),
      (_EditorTab.filters, l10n.editor_filters),
      (_EditorTab.resize, l10n.editor_resize),
      (_EditorTab.rotate, l10n.editor_rotate_flip),
      (_EditorTab.crop, l10n.editor_crop),
      (_EditorTab.strip, l10n.editor_strip_only),
    ];
    return SizedBox(
      height: 46,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
        child: Row(
          children: tabs
              .map(
                (t) => _pill(
                  t.$2,
                  selected: _tab == t.$1,
                  onTap: () => _switchTab(t.$1),
                ),
              )
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
      case _EditorTab.draw:
        return _buildDrawPanel(l10n);
      case _EditorTab.strip:
        return _buildStripPanel(l10n);
    }
  }

  Widget _sectionTitle(String title) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
    child: Text(
      title,
      style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
    ),
  );

  Widget _buildAdjustPanel(L10n l10n) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      width: double.infinity,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _slider(
            l10n.editor_brightness,
            _params.brightness,
            0.2,
            2.0,
            Icons.wb_sunny_outlined,
            (v) {
              _params = _params.copyWith(brightness: v);
              _schedulePreview();
            },
          ),
          _slider(
            l10n.editor_contrast,
            _params.contrast,
            0.2,
            2.0,
            Icons.contrast,
            (v) {
              _params = _params.copyWith(contrast: v);
              _schedulePreview();
            },
          ),
          _slider(
            l10n.editor_saturation,
            _params.saturation,
            0.0,
            2.0,
            Icons.opacity,
            (v) {
              _params = _params.copyWith(saturation: v);
              _schedulePreview();
            },
          ),
        ],
      ),
    );
  }

  Widget _slider(
    String label,
    double value,
    double min,
    double max,
    IconData icon,
    ValueChanged<double> onChanged,
  ) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                icon,
                size: 16,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
              const SizedBox(width: 8),
              Text(label, style: const TextStyle(fontSize: 13)),
              const Spacer(),
              Text(
                value.toStringAsFixed(2),
                style: TextStyle(
                  fontSize: 13,
                  color: Theme.of(context).colorScheme.primary,
                  fontWeight: FontWeight.w600,
                ),
              ),
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
            return _pill(
              label,
              selected: selected,
              onTap: () {
                _pushUndo();
                setState(() => _params = _params.copyWith(filter: key));
                _schedulePreview();
              },
            );
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
          PopupMenuItem<T>(value: v, child: Text(labelBuilder(v))),
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
            Text(label, style: TextStyle(color: scheme.onSurface)),
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
    if (_widthCtrl.text.isEmpty || _heightCtrl.text.isEmpty)
      _initResizeFields();
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
        if (_widthMMCtrl.text.isEmpty ||
            (_widthMMCtrl.text != mm.toString() &&
                !_widthMMCtrl.selection.isValid)) {
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
                    ButtonSegment(
                      value: false,
                      label: Text(l10n.editor_mode_pixel),
                    ),
                    ButtonSegment(
                      value: true,
                      label: Text(l10n.editor_mode_physical),
                    ),
                  ],
                  selected: {_isPhysicalMode},
                  onSelectionChanged: (v) =>
                      setState(() => _isPhysicalMode = v.first),
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
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
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
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
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
                style: TextStyle(
                  color: Theme.of(context).colorScheme.primary,
                  fontWeight: FontWeight.w600,
                ),
              ),
            const SizedBox(height: 12),
          ],
          // 像素尺寸输入（两种模式都显示）
          _sectionTitle(
            _isPhysicalMode
                ? l10n.editor_pixel_result
                : l10n.editor_exact_dimensions,
          ),
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
                        ? Theme.of(
                            context,
                          ).colorScheme.surfaceContainerHighest.withOpacity(0.3)
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
                        ? Theme.of(
                            context,
                          ).colorScheme.surfaceContainerHighest.withOpacity(0.3)
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
                      .map(
                        (f) => _pill(
                          '${(f * 100).round()}%',
                          selected: (curScale - f).abs() < 0.01,
                          onTap: () => _applyScale(f),
                        ),
                      )
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
          _slider(
            l10n.editor_quality,
            _quality.toDouble(),
            1,
            100,
            Icons.high_quality_outlined,
            (v) {
              setState(() => _quality = v.round());
              _schedulePreview();
            },
          ),
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
    Widget rotateBtn(
      IconData icon,
      String tooltip,
      VoidCallback onTap, {
      bool active = false,
    }) => Column(
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
          rotateBtn(
            Icons.flip,
            l10n.editor_flip,
            _toggleFlipH,
            active: _params.flipHorizontal,
          ),
          rotateBtn(
            Icons.flip_camera_android,
            l10n.editor_flip,
            _toggleFlipV,
            active: _params.flipVertical,
          ),
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
              .map(
                (a) => _pill(
                  a.$1,
                  selected: _selectedAspect == a.$2,
                  onTap: () => _setAspect(a.$2),
                ),
              )
              .toList(),
        ),
      ),
    );
  }

  Widget _buildStripPanel(L10n l10n) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            secondary: Icon(
              Icons.cleaning_services_outlined,
              color: scheme.primary,
              size: 22,
            ),
            title: Text(
              l10n.editor_strip_metadata,
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
            ),
            value: _params.stripOnly,
            onChanged: (v) {
              _pushUndo();
              setState(() => _params = _params.copyWith(stripOnly: v));
            },
          ),
        ],
      ),
    );
  }

  Widget _buildDrawPanel(L10n l10n) {
    final scheme = Theme.of(context).colorScheme;
    // 文本工具或选中文本对象时，显示字体样式开关（加粗/斜体/下划线）
    final selIsText =
        _selIndex >= 0 &&
        _selIndex < _params.drawStrokes.length &&
        _params.drawStrokes[_selIndex]['tool'] == 'text';
    final showTextStyleRow =
        _drawTool == _DrawTool.text ||
        (selIsText && _params.drawStrokes[_selIndex]['tool'] == 'text');
    // 固定高度撑满面板，工具行/色板/滑块用 spaceEvenly 均匀分布，
    // 不再因内容少而在面板底部留下大片空白。
    return SizedBox(
      height: 218,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          // 工具选择（7 种，横向可滚动）
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _drawToolPill(l10n.ui_pen, _DrawTool.pen, Icons.edit_outlined),
                const SizedBox(width: 12),
                _drawToolPill(l10n.ui_text, _DrawTool.text, Icons.text_fields),
                const SizedBox(width: 12),
                _drawToolPill(l10n.ui_rect, _DrawTool.rect, Icons.crop_square),
                const SizedBox(width: 12),
                _drawToolPill(
                  l10n.ui_ellipse,
                  _DrawTool.ellipse,
                  Icons.circle_outlined,
                ),
                const SizedBox(width: 12),
                _drawToolPill(
                  l10n.ui_line,
                  _DrawTool.line,
                  Icons.horizontal_rule,
                ),
                const SizedBox(width: 12),
                _drawToolPill(
                  l10n.ui_arrow,
                  _DrawTool.arrow,
                  Icons.arrow_outward,
                ),
                const SizedBox(width: 12),
                _drawToolPill(l10n.ui_mosaic, _DrawTool.mosaic, Icons.blur_on),
              ],
            ),
          ),
          // 颜色色板（马赛克不适用颜色，仍保留供其他工具使用）
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              for (final c in _paletteColors)
                GestureDetector(
                  onTap: () => _onPalettePick(c),
                  child: Container(
                    margin: const EdgeInsets.symmetric(horizontal: 6),
                    width: 30,
                    height: 30,
                    decoration: BoxDecoration(
                      color: Color(c),
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: _drawColor == c
                            ? scheme.primary
                            : scheme.outline.withAlpha(120),
                        width: _drawColor == c ? 3 : 1,
                      ),
                    ),
                  ),
                ),
            ],
          ),
          // 字体样式：加粗 / 斜体 / 下划线（文本工具或选中文本对象时显示）
          if (showTextStyleRow)
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _textStyleToggle(l10n.editor_font_bold, _textBold, 'bold'),
                const SizedBox(width: 14),
                _textStyleToggle(l10n.editor_font_italic, _textItalic, 'italic'),
                const SizedBox(width: 14),
                _textStyleToggle(
                  l10n.editor_font_underline,
                  _textUnderline,
                  'underline',
                ),
              ],
            ),
          // 线宽 / 文本字号 / 马赛克格子大小（标题随工具切换：字体/线粗）
          Row(
            children: [
              const SizedBox(width: 20),
              Text(
                _drawTool == _DrawTool.text
                    ? l10n.ui_font_size
                    : l10n.ui_line_width,
                style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant),
              ),
              const SizedBox(width: 8),
              Icon(Icons.remove, size: 20, color: scheme.onSurfaceVariant),
              Expanded(
                child: Slider(
                  value: _drawWidthSlider,
                  min: 1,
                  max: 20,
                  onChanged: _onDrawWidthChanged,
                  onChangeEnd: (_) => _onDrawWidthChangedEnd(),
                ),
              ),
              Icon(Icons.add, size: 20, color: scheme.onSurfaceVariant),
              const SizedBox(width: 20),
            ],
          ),
        ],
      ),
    );
  }

  /// 文本样式开关药丸：B=加粗 / I=斜体 / U=下划线。
  Widget _textStyleToggle(String tooltip, bool active, String key) {
    final scheme = Theme.of(context).colorScheme;
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: () => _onTextStyleToggle(key),
        borderRadius: BorderRadius.circular(18),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
          decoration: BoxDecoration(
            color: active ? scheme.primary : scheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(18),
          ),
          child: Text(
            key == 'bold' ? 'B' : key == 'italic' ? 'I' : 'U',
            style: TextStyle(
              fontSize: 15,
              fontWeight: key == 'bold' ? FontWeight.w800 : FontWeight.w500,
              fontStyle:
                  key == 'italic' ? FontStyle.italic : FontStyle.normal,
              decoration:
                  key == 'underline'
                      ? TextDecoration.underline
                      : TextDecoration.none,
              color: active ? scheme.onPrimary : scheme.onSurfaceVariant,
            ),
          ),
        ),
      ),
    );
  }

  /// 绘图工具药丸（画笔 / 文本 / 矩形 / 椭圆 …）。
  Widget _drawToolPill(String label, _DrawTool tool, IconData icon) {
    final scheme = Theme.of(context).colorScheme;
    final selected = _drawTool == tool;
    return InkWell(
      onTap: () {
        // 就地输入中切到其它工具：先自动保存为对象（空文本时提交内部
        // 自会删除对象，此处不再做空区框清理，避免与异步提交竞争删错）
        if (_textEditing != null) {
          if (tool != _DrawTool.text) _commitTextEdit();
        } else if (tool != _DrawTool.text) {
          _removeEmptyTextObjects();
        }
        setState(() {
          _drawTool = tool;
          if (tool != _DrawTool.text) {
            _disposeTextEdit();
          }
        });
        if (tool == _DrawTool.text) {
          // 文本：图片中心创建可交互区框并选中（输入中或已有空区框时
          // 不重复创建）；矩形/椭圆不预建——按住拖拽画形状，松手出区框
          if (_textEditing == null &&
              !_params.drawStrokes.any(_isEmptyTextObject)) {
            _createCenterObject();
          }
        }
      },
      borderRadius: BorderRadius.circular(20),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
        decoration: BoxDecoration(
          color: selected ? scheme.primary : scheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: 18,
              color: selected ? scheme.onPrimary : scheme.onSurfaceVariant,
            ),
            const SizedBox(width: 6),
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
    _disposeTextEdit();
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

/// 文本就地编辑草稿：隐藏输入框的控制器与焦点。
/// 位置/字号取自目标对象当前区框，实时文字由画笔绘制在框内。
class _TextEditDraft {
  final TextEditingController ctrl;
  final FocusNode focus;
  _TextEditDraft({required this.ctrl, required this.focus});
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
    for (final c in [
      rect.topLeft,
      rect.topRight,
      rect.bottomLeft,
      rect.bottomRight,
    ]) {
      canvas.drawRect(
        Rect.fromCenter(center: c, width: hs, height: hs),
        handle,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _CropPainter old) =>
      old.crop != crop || old.displayRect != displayRect;
}

/// 绘图预览画笔：把「进行中」的笔画实时叠加在预览图上（松手后由
/// ImageEditService 合并进 _previewBytes，此画笔只负责草稿显示）。
class _DrawPreviewPainter extends CustomPainter {
  final Rect displayRect;
  final _DrawTool tool;
  final int color;
  final double width; // 归一化线宽
  final List<Offset>? points; // pen/mosaic 折线（归一化）
  final Offset? draftStart; // line/rect/ellipse/arrow 起点（归一化）
  final Offset? draftEnd; // line/rect/ellipse/arrow 终点（归一化）
  final List<Map<String, Object>> strokes; // 对象化形状（rect/ellipse/text）
  final int selIndex; // 选中对象下标
  final Rect? objDraftRect; // 拖拽中实时矩形（归一化）
  final double objDraftAngle; // 拖拽中实时角度（度）
  final bool autoHideBoxes; // 自动隐藏非选中对象的辅助框
  final String? textHint; // 空文本区框内的输入提示（l10n）
  final int textEditIdx; // 正在就地编辑的对象下标（实时文字由画笔绘制）
  final String? editText; // 就地输入中的实时文本（null = 未在输入）
  final int editColor; // 输入中文本颜色（面板可实时切换）
  final bool editBold; // 输入中样式：加粗
  final bool editItalic; // 输入中样式：斜体
  final bool editUnderline; // 输入中样式：下划线

  _DrawPreviewPainter({
    required this.displayRect,
    required this.tool,
    required this.color,
    required this.width,
    this.points,
    this.draftStart,
    this.draftEnd,
    this.strokes = const [],
    this.selIndex = -1,
    this.objDraftRect,
    this.objDraftAngle = 0,
    this.autoHideBoxes = true,
    this.textHint,
    this.textEditIdx = -1,
    this.editText,
    this.editColor = 0xFF000000,
    this.editBold = false,
    this.editItalic = false,
    this.editUnderline = false,
  });

  Offset _toPx(Offset norm, Rect r) =>
      Offset(r.left + norm.dx * r.width, r.top + norm.dy * r.height);

  @override
  void paint(Canvas canvas, Size size) {
    final r = displayRect;
    if (r.isEmpty || r.width <= 0 || r.height <= 0) return;
    // 进行中的草稿只影响草稿自身；无论有无草稿，已提交对象的内容与
    // 选区框都必须绘制（否则松手清空草稿后一切“消失”，只剩越积越多
    // 的隐形对象）
    _paintDraft(canvas, r);
    _paintObjectsContent(canvas);
    _paintObjectBoxes(canvas);
  }

  // ---- 进行中的草稿（pen 折线 / 形状起终点 / 马赛克涂抹点） ----
  void _paintDraft(Canvas canvas, Rect r) {
    final strokeW = (width * r.width).clamp(1.0, 200.0);
    if (tool == _DrawTool.mosaic) {
      // 马赛克：半透明圆点标示涂抹范围（正式渲染在 isolate 里做块状模糊）
      final pts = points;
      if (pts == null || pts.isEmpty) return;
      final paint = Paint()
        ..color = Color(color).withAlpha(70)
        ..style = PaintingStyle.fill;
      for (final p in pts) {
        final px = _toPx(p, r);
        canvas.drawCircle(px, strokeW / 2, paint);
      }
      return;
    }
    if (tool == _DrawTool.pen) {
      final pts = points;
      if (pts == null || pts.isEmpty) return;
      final paint = Paint()
        ..color = Color(color)
        ..strokeWidth = strokeW
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..style = PaintingStyle.stroke;
      final path = Path();
      for (var i = 0; i < pts.length; i++) {
        final p = _toPx(pts[i], r);
        if (i == 0) {
          path.moveTo(p.dx, p.dy);
        } else {
          path.lineTo(p.dx, p.dy);
        }
      }
      canvas.drawPath(path, paint);
      return;
    }
    if (tool == _DrawTool.line ||
        tool == _DrawTool.rect ||
        tool == _DrawTool.ellipse ||
        tool == _DrawTool.arrow) {
      final s = draftStart;
      final e = draftEnd;
      if (s == null || e == null) return; // 无草稿：仅跳过草稿本身
      final sp = _toPx(s, r);
      final ep = _toPx(e, r);
      final paint = Paint()
        ..color = Color(color)
        ..strokeWidth = strokeW
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..style = PaintingStyle.stroke;
      if (tool == _DrawTool.line) {
        canvas.drawLine(sp, ep, paint);
      } else if (tool == _DrawTool.rect) {
        canvas.drawRect(Rect.fromPoints(sp, ep), paint);
      } else if (tool == _DrawTool.ellipse) {
        canvas.drawOval(Rect.fromPoints(sp, ep), paint);
      } else {
        canvas.drawLine(sp, ep, paint);
        _drawArrowHead(canvas, sp, ep, paint);
      }
    }
    // text：无进行中草稿（点击区框就地输入，提交后固化）
  }

  // ---- 对象内容绘制（实时，与服务端保存渲染一致的视觉） ----
  void _paintObjectsContent(Canvas canvas) {
    final d = displayRect;
    if (strokes.isEmpty) return;
    for (var i = 0; i < strokes.length; i++) {
      final s = strokes[i];
      final t = s['tool'] as String?;
      if (t != 'rect' && t != 'ellipse' && t != 'text') continue;
      final Rect nr;
      final double ang;
      if (i == selIndex && objDraftRect != null) {
        nr = objDraftRect!;
        ang = objDraftAngle;
      } else {
        nr = _objRectOf(s);
        ang = _objAngleOf(s);
      }
      final px = Rect.fromLTWH(
        d.left + nr.left * d.width,
        d.top + nr.top * d.height,
        nr.width * d.width,
        nr.height * d.height,
      );
      if (px.width <= 0 || px.height <= 0) continue;
      final colorValue = (s['color'] as num?)?.toInt() ?? 0xFF000000;
      final wn = (s['width'] as num?)?.toDouble() ?? 0.005;
      final strokeW = (wn * d.width).clamp(1.0, 200.0);
      final paint = Paint()
        ..color = Color(colorValue)
        ..strokeWidth = strokeW
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..style = PaintingStyle.stroke;
      canvas.save();
      canvas.translate(px.center.dx, px.center.dy);
      canvas.rotate(ang * math.pi / 180);
      final rect = Rect.fromCenter(
        center: Offset.zero,
        width: px.width,
        height: px.height,
      );
      if (t == 'rect') {
        canvas.drawRect(rect, paint);
      } else if (t == 'ellipse') {
        canvas.drawOval(rect, paint);
      } else {
        // 就地输入中的对象：绘制实时文本与当前样式（随区框缩放旋转）
        final editing = i == textEditIdx;
        final text = editing
            ? (editText ?? '')
            : (s['text'] as String? ?? '');
        final cValue = editing ? editColor : colorValue;
        final bold = editing ? editBold : s['bold'] == true;
        final italic = editing ? editItalic : s['italic'] == true;
        final underline = editing
            ? editUnderline
            : s['underline'] == true;
        if (text.isEmpty) {
          // 空文本区框：内部居中显示输入提示（l10n），随区框缩放
          _paintTextHint(canvas, rect, textHint);
        } else {
          final fontSize = rect.height.clamp(4.0, 2000.0);
          final tp = TextPainter(
            text: TextSpan(
              text: text,
              style: TextStyle(
                color: Color(cValue),
                fontSize: fontSize,
                fontWeight: bold ? FontWeight.w700 : FontWeight.w400,
                fontStyle: italic ? FontStyle.italic : FontStyle.normal,
                decoration: underline
                    ? TextDecoration.underline
                    : TextDecoration.none,
                decorationColor: Color(cValue),
              ),
            ),
            textDirection: TextDirection.ltr,
            maxLines: 1,
          )..layout(maxWidth: 100000);
          // 高度精确缩放到区框高（与服务端保存渲染一致），
          // 按文字实际宽高居中于区框中心
          final scale = tp.height > 0 ? rect.height / tp.height : 1.0;
          canvas.save();
          canvas.scale(scale, scale);
          tp.paint(canvas, Offset(-tp.width / 2, -tp.height / 2));
          canvas.restore();
        }
      }
      canvas.restore();
    }
  }

  // ---- 空文本区框内提示（l10n）----
  void _paintTextHint(Canvas canvas, Rect rect, String? hint) {
    if (hint == null || hint.isEmpty) return;
    final tp = TextPainter(
      text: TextSpan(
        text: hint,
        style: TextStyle(
          color: const Color(0xFF1976D2),
          fontSize: rect.height.clamp(10.0, 64.0) * 0.55,
          fontWeight: FontWeight.w400,
        ),
      ),
      textDirection: TextDirection.ltr,
      maxLines: 1,
      ellipsis: '…',
    )..layout(maxWidth: rect.width);
    tp.paint(
      canvas,
      Offset(rect.center.dx - tp.width / 2, rect.center.dy - tp.height / 2),
    );
  }

  // ---- 对象选区框 ----
  double _objAngleOf(Map<String, Object> s) =>
      (s['angle'] as num?)?.toDouble() ?? 0;

  Rect _objRectOf(Map<String, Object> s) {
    final x = (s['x'] as num).toDouble();
    final y = (s['y'] as num).toDouble();
    final w = (s['w'] as num).toDouble();
    final h = (s['h'] as num).toDouble();
    return Rect.fromLTWH(x, y, w, h);
  }

  List<Offset> _rotCorners(Rect pxRect, double angle) {
    final c = pxRect.center;
    final a = angle * math.pi / 180;
    final ca = math.cos(a);
    final sa = math.sin(a);
    final corners = [
      pxRect.topLeft,
      pxRect.topRight,
      pxRect.bottomRight,
      pxRect.bottomLeft,
    ];
    return corners.map((p) {
      final dx = p.dx - c.dx;
      final dy = p.dy - c.dy;
      return Offset(c.dx + dx * ca - dy * sa, c.dy + dx * sa + dy * ca);
    }).toList();
  }

  void _paintObjectBoxes(Canvas canvas) {
    final d = displayRect;
    if (strokes.isEmpty) return;
    final selColor = const Color(0xFF1976D2);
    // 未选中对象也用清晰可见的中灰描边 + 角点，避免矩形/椭圆“没有区框”
    final idleColor = const Color(0xCC4A4A4A);
    final idleDot = Paint()
      ..color = const Color(0xCC4A4A4A)
      ..style = PaintingStyle.fill;
    for (var i = 0; i < strokes.length; i++) {
      final s = strokes[i];
      final t = s['tool'] as String?;
      if (t != 'rect' && t != 'ellipse' && t != 'text') continue;
      Rect nr;
      double ang;
      if (i == selIndex && objDraftRect != null) {
        nr = objDraftRect!;
        ang = objDraftAngle;
      } else {
        nr = _objRectOf(s);
        ang = _objAngleOf(s);
      }
      final px = Rect.fromLTWH(
        d.left + nr.left * d.width,
        d.top + nr.top * d.height,
        nr.width * d.width,
        nr.height * d.height,
      );
      final corners = _rotCorners(px, ang);
      final selected = i == selIndex;
      // 自动隐藏辅助框：仅选中对象显示区框/手柄/关闭；其余对象只显示
      // 图形/文本本身（不画任何辅助线），避免编辑时辅助框干扰视线。
      if (autoHideBoxes && !selected) continue;
      final border = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = selected ? 2 : 1.5
        ..color = selected ? selColor : idleColor;
      final path = Path()..moveTo(corners[0].dx, corners[0].dy);
      for (var k = 1; k < 4; k++) {
        path.lineTo(corners[k].dx, corners[k].dy);
      }
      path.close();
      canvas.drawPath(path, border);
      // 未选中也画 4 角小点，确保区框完整可辨
      if (!selected) {
        for (final c in corners) {
          canvas.drawCircle(c, 3, idleDot);
        }
        continue;
      }
      // 角点
      final dot = Paint()..color = selColor;
      for (final c in corners) {
        canvas.drawCircle(c, 3, dot);
      }
      // 右下角手柄：缩放 + 旋转
      final handle = corners[2];
      canvas.drawCircle(handle, 15, Paint()..color = selColor);
      canvas.drawCircle(handle, 8, Paint()..color = Colors.white);
      canvas.drawLine(
        handle + const Offset(-4, 4),
        handle + const Offset(4, -4),
        Paint()
          ..color = selColor
          ..strokeWidth = 2
          ..strokeCap = StrokeCap.round,
      );
      // 左上角关闭按钮
      final close = corners[0];
      canvas.drawCircle(close, 12, Paint()..color = const Color(0xFFD32F2F));
      final xp = Paint()
        ..color = Colors.white
        ..strokeWidth = 2
        ..strokeCap = StrokeCap.round;
      canvas.drawLine(
        close + const Offset(-4, -4),
        close + const Offset(4, 4),
        xp,
      );
      canvas.drawLine(
        close + const Offset(4, -4),
        close + const Offset(-4, 4),
        xp,
      );
    }
  }

  void _drawArrowHead(Canvas canvas, Offset s, Offset e, Paint paint) {
    final dir = e - s;
    final len = dir.distance;
    if (len < 2) return;
    final u = Offset(dir.dx / len, dir.dy / len);
    final n = Offset(-u.dy, u.dx);
    final headLen = (paint.strokeWidth * 3).clamp(14.0, 80.0);
    const spread = 0.42;
    final base = Offset(e.dx - u.dx * headLen, e.dy - u.dy * headLen);
    final p1 = Offset(
      base.dx + n.dx * headLen * spread,
      base.dy + n.dy * headLen * spread,
    );
    final p2 = Offset(
      base.dx - n.dx * headLen * spread,
      base.dy - n.dy * headLen * spread,
    );
    final hp = Paint()
      ..color = paint.color
      ..strokeWidth = paint.strokeWidth * 0.8
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;
    canvas.drawLine(e, p1, hp);
    canvas.drawLine(e, p2, hp);
  }

  @override
  bool shouldRepaint(covariant _DrawPreviewPainter old) =>
      old.tool != tool ||
      old.color != color ||
      old.width != width ||
      old.displayRect != displayRect ||
      old.points != points ||
      old.draftStart != draftStart ||
      old.draftEnd != draftEnd ||
      old.strokes != strokes ||
      old.selIndex != selIndex ||
      old.objDraftRect != objDraftRect ||
      old.objDraftAngle != objDraftAngle ||
      old.textHint != textHint ||
      old.textEditIdx != textEditIdx ||
      old.editText != editText ||
      old.editColor != editColor ||
      old.editBold != editBold ||
      old.editItalic != editItalic ||
      old.editUnderline != editUnderline;
}
