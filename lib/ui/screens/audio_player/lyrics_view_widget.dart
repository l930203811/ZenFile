import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../../../services/lyric_animation_style.dart';
import '../../../services/lyric_parser.dart';
import '../../../services/lyric_timeline.dart';
import '../../../services/preferences_service.dart';
import 'lyric_color_picker_dialog.dart';

/// 歌词视图两侧水平留白。
const double _kHPadding = 24.0;

/// PV 四芒闪点寿命（秒）。
const double _kPvSparkleLife = 0.26;

/// 单行歌词画布的上下留白：给弹放放大的当前字留余量，避免被 CustomPaint 裁剪。
const double _kSingleLineCanvasPad = 8.0;

/// 单行歌词特效层向上穿越的高度：PV 唱字闪点 / ECHO 空心字碎片从槽位
/// 飞出时可越过上方封面卡片显示（Stack clipBehavior: Clip.none + 负 top
/// Positioned 突破 44dp 槽位边界；外层 AnimatedSwitcher / SizeTransition
/// 的默认裁剪已在播放页 _buildSingleLineLyrics 一并放开）。
const double _kSingleLineFxCross = 160.0;

/// 近临界阻尼弹簧曲线：位移从 0 平滑滑到 1，中段带一次极小回弹。
/// 用于 ScrollController.animateTo，越界回弹由滚动物理处理。
class _SpringCurve extends Curve {
  const _SpringCurve();

  @override
  double transform(double t) {
    const zeta = 0.7;
    const omega = 13.0;
    final wd = omega * math.sqrt(1 - zeta * zeta);
    final env = math.exp(-zeta * omega * t);
    final v =
        1 - env * (math.cos(wd * t) + (zeta * omega / wd) * math.sin(wd * t));
    return v.clamp(0.0, 1.2);
  }
}

/// 一套风格的视觉参数（借鉴 folia-major 各歌词动画的观感差异）。
class _StyleProfile {
  final double fontSize;
  final double lineHeight;

  /// 已唱部分的辉光（shadows 模糊半径，0 = 关闭；两层模拟 folia 的
  /// near/far BlurFilter）。
  final double glowNear;
  final double glowFar;

  /// 行间距（dp）。
  final double rowGap;

  /// 字重（PV 用 w800 增强存在感）。
  final FontWeight weight;

  /// 「当前字」放倍数（>1 生效）。
  /// 唱到的字随字内进度做 sin 弹放：字中最大、首尾为 1，无切换硬切。
  /// 普通 LRC 的均分时间线同样生效——所有歌词都走逐字，不再有行放大兜底。
  final double charZoom;

  /// 打字机模式：当前字右侧画一道随节奏闪烁的光标竖线，无辉光、不缩放。
  final bool typewriter;

  const _StyleProfile({
    required this.fontSize,
    required this.lineHeight,
    required this.glowNear,
    required this.glowFar,
    required this.rowGap,
    this.weight = FontWeight.w600,
    this.charZoom = 1.0,
    this.typewriter = false,
  });

  /// 只替换少量字段：混合模式要保留各风格的字重 / 辉光 / 弹放，仅统一字号
  /// 与行高（见 [_LyricsViewWidgetState._profileForLine]）。
  _StyleProfile copyWith({double? fontSize, double? lineHeight}) {
    return _StyleProfile(
      fontSize: fontSize ?? this.fontSize,
      lineHeight: lineHeight ?? this.lineHeight,
      glowNear: glowNear,
      glowFar: glowFar,
      rowGap: rowGap,
      weight: weight,
      charZoom: charZoom,
      typewriter: typewriter,
    );
  }
}

/// 动态歌词显示组件（借鉴 folia「Monet 逐字扫过」观感，纯 Flutter 内置能力实现）。
///
/// 特性：
/// - 逐字/亚词级平滑扫过：整行先画中性色，再按当前进度把已唱部分裁剪成强调色，
///   支持自动换行（多视觉行按行裁剪）。
/// - 距离衰减 tone：当前行全亮 + 强调色，邻近行按距离降低不透明度并缩小。
/// - 弹簧滚动：当前行切换时用弹簧曲线平滑滚到视口中央。
/// - 进度插值：position 流非帧率，[isPlaying] 为真时按墙钟插值，得到丝滑扫过。
/// - 多动画风格（[style]）：classic / typewriter / meteor / pv / echo / mixed。
///   其中 [LyricAnimationStyle.mixed] 是**一个独立风格但无单一形态**：
///   每句歌词随机呈现 [kLyricMixedStylePool] 中的一种内置风格（逐句随机、
///   整首固定），一句一时一面；它不是在多种风格之间整体切换。
class LyricsViewWidget extends StatefulWidget {
  final List<LyricLine> lyrics;
  final Duration position;
  final Color accentColor;
  final LyricAnimationStyle style;

  /// 是否正在播放。为 true 时按墙钟对 position 插值，得到帧级平滑的逐字扫过；
  /// 为 false（暂停）时直接使用 [position]，并停止逐帧重绘以省电。
  final bool isPlaying;
  final void Function(Duration)? onSeek;

  const LyricsViewWidget({
    super.key,
    required this.lyrics,
    required this.position,
    required this.accentColor,
    this.style = LyricAnimationStyle.classic,
    this.isPlaying = true,
    this.onSeek,
  });

  @override
  State<LyricsViewWidget> createState() => _LyricsViewWidgetState();
}

/// 一个字边界在排版坐标系里的位置：[x] 为水平偏移，[line] 为所属视觉行。
class _Boundary {
  final double x;
  final int line;
  const _Boundary(this.x, this.line);
}

/// 第 [i] 个字的右缘（paragraph 坐标，未加 originX）。
///
/// 自动换行时，行末最后一个字的下一个 boundary 属于**下一视觉行**，其 x 是
/// 下一行行首（远小于本字左缘）——直接拿来当右缘会让行末字区间塌缩
/// （x1 <= x0 被跳过、中值算进行首）：表现为换行后第一行最右侧的字不变色、
/// 唱字闪点与飞入定位错位。此时改取所在视觉行的右缘。
double _glyphRightX(
  List<_Boundary> boundaries,
  List<ui.LineMetrics> metrics,
  int i,
) {
  final b = boundaries[i];
  final b2 = boundaries[i + 1];
  if (b2.line == b.line) return b2.x;
  return metrics[b.line].left + metrics[b.line].width;
}

/// 第 [i] 个字的中心 x（paragraph 坐标，未加 originX）。
double _glyphCenterX(
  List<_Boundary> boundaries,
  List<ui.LineMetrics> metrics,
  int i,
) => (boundaries[i].x + _glyphRightX(boundaries, metrics, i)) / 2;

/// 画一枚 PV 四芒闪点（外层柔光 + 主星芒 + 白色星芯）。
///
/// [r] 为当前外缘半径，[alpha] 为整体强度（0~1），[currentColor] 为"当前播放"
/// 色。PV 视图、融合模式的列表视图与单行槽位共用同一套画法，只在调用侧
/// 决定半径生长曲线（观感尺寸不同）。
void _drawPvStar(
  Canvas canvas,
  Offset center,
  double r,
  double alpha,
  Color currentColor,
) {
  canvas.save();
  canvas.translate(center.dx, center.dy);
  canvas.drawCircle(
    Offset.zero,
    r * 0.55,
    Paint()..color = currentColor.withValues(alpha: 0.22 * alpha),
  );
  final wdt = r * 0.20;
  final star = Path()
    ..moveTo(0, -r)
    ..lineTo(wdt, -wdt)
    ..lineTo(r, 0)
    ..lineTo(wdt, wdt)
    ..lineTo(0, r)
    ..lineTo(-wdt, wdt)
    ..lineTo(-r, 0)
    ..lineTo(-wdt, -wdt)
    ..close();
  canvas.drawPath(
    star,
    Paint()..color = currentColor.withValues(alpha: 0.85 * alpha),
  );
  final core = r * 0.42;
  final cw = core * 0.22;
  final coreStar = Path()
    ..moveTo(0, -core)
    ..lineTo(cw, -cw)
    ..lineTo(core, 0)
    ..lineTo(cw, cw)
    ..lineTo(0, core)
    ..lineTo(-cw, cw)
    ..lineTo(-core, 0)
    ..lineTo(-cw, -cw)
    ..close();
  canvas.drawPath(
    coreStar,
    Paint()..color = Colors.white.withValues(alpha: 0.9 * alpha),
  );
  canvas.restore();
}

/// 一行歌词测量后的排版结果（跨帧缓存，避免每帧重新布局）。
class _MeasuredLine {
  final String text;
  final String colorSig;
  final TextPainter base;
  final TextPainter highlight;
  final List<ui.LineMetrics> metrics;

  /// 与 [metrics] 对齐：每个视觉行的上下边界（由 height 累计推导，本 SDK 的
  /// LineMetrics 无 top/bottom 字段）。
  final List<double> lineTops;
  final List<double> lineBottoms;

  /// 每字边界的水平位置，长度 = graphemes.length + 1。
  final List<_Boundary> boundaries;

  /// 文本左缘相对绘制区左缘的偏移：本 SDK 的 TextPainter 对
  /// textAlign:center + layout(maxWidth) 会 shrink-to-fit（paragraph 宽度 =
  /// 文本宽），paint 出来的文本左对齐于 offset——居中需调用方自行加此偏移。
  /// [boundaries] 的 x 与 [metrics] 的 left 同为 paragraph 坐标（0 起）。
  final double originX;

  const _MeasuredLine({
    required this.text,
    required this.colorSig,
    required this.base,
    required this.highlight,
    required this.metrics,
    required this.lineTops,
    required this.lineBottoms,
    required this.boundaries,
    this.originX = 0,
  });
}

// ── PV（文字 PV）动画数据 ────────────────────────────────────────────────

/// 云室径迹粒子。
class _PvParticle {
  Offset pos;
  Offset vel;
  double life;
  double age = 0;
  final double size;

  _PvParticle({
    required this.pos,
    required this.vel,
    required this.life,
    required this.size,
  });
}

/// 唱到一字完成时的四芒闪点。
class _PvSparkle {
  final Offset pos;
  double age = 0;
  _PvSparkle(this.pos);
}

/// 新行字的飞入起点（相对终点的偏移 + 初始旋转）。
class _PvFlyFrom {
  final Offset offset;
  final double rot;
  const _PvFlyFrom(this.offset, this.rot);
}

// ── ECHO（回声碎片）动画数据 ─────────────────────────────────────────────

/// 唱词炸出的空心字碎片。
class _EchoFragment {
  Offset pos;
  Offset vel;
  double rot;
  double rotVel;
  final double scale;
  double age = 0;
  final double life;
  final double phase;
  final String char;

  _EchoFragment({
    required this.pos,
    required this.vel,
    required this.rot,
    required this.rotVel,
    required this.scale,
    required this.life,
    required this.phase,
    required this.char,
  });
}

class _LyricsViewWidgetState extends State<LyricsViewWidget>
    with SingleTickerProviderStateMixin {
  final ScrollController _scrollController = ScrollController();
  late List<GlobalKey> _itemKeys;
  int _currentLineIndex = -1;
  bool _isUserScrolling = false;

  /// 首帧/懒加载居中重试计数：当前行尚未布局（context==null）时先估算
  /// 粗定位，下一帧拿到真实 RenderBox 再精校，避免非开头播放切视图停偏。
  int _scrollRetries = 0;

  /// 逐行时间线（与 lyrics 对齐）。
  late List<LyricLineTimeline> _timelines;

  /// 排版缓存：index -> _MeasuredLine。宽度/主题色/风格变化时清空。
  final Map<int, _MeasuredLine> _measureCache = {};
  double _measureMaxWidth = -1;

  // ── 混合模式：逐句风格计划（一次性排定，整首歌内只读） ─────────────
  List<LyricAnimationStyle> _mixedPlan = const [];
  String _mixedPlanSig = '';

  /// 混合模式当前句的入场动效编号（0=淡入上移 / 1=缩放弹入 / 2=右滑入），
  /// 换行时随机掷一个，使每句进入舞台的方式也各不相同。
  int _mixedEnterKind = 0;

  /// 进度插值状态。
  late Duration _lastPos;
  late DateTime _lastPosWallClock;
  late Duration _lastRenderedPos;

  /// 逐帧重绘，驱动逐字扫过。
  late final Ticker _ticker;

  // ── 最近一次 build 的排版上下文（ticker 里换算屏幕坐标用） ────────────
  double _lastMaxWidth = 300;
  _StyleProfile _lastProfile = const _StyleProfile(
    fontSize: 21,
    lineHeight: 1.42,
    glowNear: 0,
    glowFar: 0,
    rowGap: 8,
  );
  double _lastViewportH = 400;

  // ── PV 动画状态 ───────────────────────────────────────────────────────
  double _pvClock = 0;
  DateTime? _pvLastFrame;

  /// PV 揭示进度（0..1）：0 = 开始逐字飞入，1 = 整句就位。
  double _pvRevealT = 1;
  double _pvRevealStart = 0;

  /// 本行揭示时长（秒）：按行时长自适应——短行快、长行慢。
  double _pvRevealDur = 0.6;

  /// 已飞入就位的字数（按就位时机生成云室径迹）。
  int _pvRevealed = 0;
  int _pvPrevLine = -1;
  int _pvFillIndex = 0;
  final List<_PvParticle> _pvParticles = [];
  final List<_PvSparkle> _pvSparkles = [];
  final math.Random _rng = math.Random(7);

  /// 逐句风格计划专用随机源：不用固定种子，保证每次进场 / 每首歌的
  /// 「每句随机一种」组合都不一样（粒子仍用有种子的 [_rng] 保持稳定）。
  final math.Random _planRng = math.Random();
  List<_PvFlyFrom> _pvFlyFrom = const [];
  final Map<String, TextPainter> _pvGlyphCache = {};
  String _pvGlyphSig = '';
  final Map<String, TextPainter> _pvDimCache = {};
  String _pvDimSig = '';

  // ── 当前字放大（逐字歌词）painter 缓存 ────────────────────────────────
  final Map<String, TextPainter> _zoomGlyphCache = {};
  String _zoomGlyphSig = '';

  /// 逐字重绘风格（meteor / drop~wave）用的字形缓存（见 [_MotionLinePainter]）。
  final _GlyphTextCache _motionGlyphs = _GlyphTextCache();

  /// 当前字的单字 painter（highlight 样式、原字号），按 字符|样式 缓存，
  /// 仅在成为当前字时构建一次，避免每帧 layout。
  TextPainter _zoomGlyphPainter(String ch, _StyleProfile p) {
    final sig =
        '${p.fontSize}|${p.weight}|${_playedColor.toARGB32()}|${_currentColor.toARGB32()}';
    if (_zoomGlyphSig != sig) {
      _zoomGlyphCache.clear();
      _zoomGlyphSig = sig;
    }
    var tp = _zoomGlyphCache[ch];
    if (tp == null) {
      tp = TextPainter(
        text: TextSpan(text: ch, style: _currentTextStyle(p)),
        textDirection: TextDirection.ltr,
      )..layout();
      if (_zoomGlyphCache.length > 200) _zoomGlyphCache.clear();
      _zoomGlyphCache[ch] = tp;
    }
    return tp;
  }

  // ── ECHO 动画状态 ─────────────────────────────────────────────────────
  final List<_EchoFragment> _echoFragments = [];
  int _echoLine = -1;
  int _echoSpawned = 0;
  final Map<String, _EchoPicture> _echoPictures = {};
  String _echoPictureSig = '';

  @override
  void initState() {
    super.initState();
    _itemKeys = List.generate(widget.lyrics.length, (_) => GlobalKey());
    _timelines = _buildTimelines(widget.lyrics);
    _lastPos = widget.position;
    _lastPosWallClock = DateTime.now();
    _lastRenderedPos = widget.position;
    _updateCurrentIndices();
    _ticker = Ticker(_onTick);
    _ticker.start();
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _scrollToCurrentLine(animate: false),
    );
  }

  List<LyricLineTimeline> _buildTimelines(List<LyricLine> lines) {
    return List.generate(
      lines.length,
      (i) => buildLineTimeline(lines[i], lineEndForIndex(lines, i)),
    );
  }

  // ── 混合模式：逐句风格（每句随机一种，整首固定） ────────────────────

  /// 歌词表变化时才重排计划；同一份歌词在整首播放期间复用同一份结果。
  ///
  /// ⚠️ 计划绝不能每次换行/每帧重掷：重掷会改变该句字号与行高，进而让
  /// 测量签名失效（全列表重新排版）+ 滚动目标跳动（表现为「重载到首行」）。
  void _ensureMixedPlan() {
    if (widget.style != LyricAnimationStyle.mixed) {
      if (_mixedPlanSig.isNotEmpty) {
        _mixedPlan = const [];
        _mixedPlanSig = '';
      }
      return;
    }
    final lines = widget.lyrics;
    final sig = lines.isEmpty
        ? '0'
        : '${lines.length}|${lines.first.text}|${lines.last.text}';
    if (sig == _mixedPlanSig) return;
    _mixedPlanSig = sig;
    _mixedPlan = buildMixedStylePlan(lines.length, _planRng);
    // 计划一变行高就可能变 ⇒ 清一次排版缓存（每首歌只此一次）。
    _measureCache.clear();
  }

  /// 第 [index] 句实际采用的风格：仅混合模式逐句不同，其余风格全局一致。
  LyricAnimationStyle _styleForLine(int index) {
    if (widget.style != LyricAnimationStyle.mixed) return widget.style;
    if (index < 0 || index >= _mixedPlan.length) return widget.style;
    return _mixedPlan[index];
  }

  /// 第 [index] 句的排版参数（混合模式下逐句可为不同风格的字号/辉光/字重）。
  ///
  /// ⚠️ 混合模式会把**字号统一到同一档**：此前只有「文字 PV / 沉浸巨幕 / 回声
  /// 碎片」因为自带 `vh/11~vh/13` 的巨字预算而明显偏大，其余风格只有 20~22，
  /// 逐句跳动看着很不齐。舞台一次只显示当前一句，统一放大不会挤压其它行；
  /// 各风格仍保留自己的字重 / 辉光 / 弹放，差异感不丢。
  _StyleProfile _profileForLine(int index) {
    final style = _styleForLine(index);
    final base = _profileForStyle(style, _lastViewportH);
    if (widget.style != LyricAnimationStyle.mixed) return base;
    return base.copyWith(
      fontSize: _mixedUnifiedFontSize(_lastViewportH),
      lineHeight: 1.30,
    );
  }

  /// 混合舞台的统一字号：与「文字 PV」原来的巨字档同量级（vh/11，夹 30~40）。
  double _mixedUnifiedFontSize(double viewportHeight) =>
      (viewportHeight / 11.0).clamp(30.0, 40.0);

  void _onTick(Duration elapsed) {
    if (!mounted || widget.lyrics.isEmpty) return;
    final pos = _interpolatedPosition();
    // 暂停且进度未变时不必重绘；但 PV/ECHO 有未落幕的动画时继续驱动。
    final animating = _animationsActive();
    if (!widget.isPlaying && pos == _lastRenderedPos && !animating) return;
    _lastRenderedPos = pos;

    final now = DateTime.now();
    final dt = _pvLastFrame == null
        ? 0.0
        : (now.difference(_pvLastFrame!).inMicroseconds / 1e6).clamp(0.0, 0.05);
    _pvLastFrame = now;

    // 墙钟秒数：驱动「与播放进程绑定」的一切——PV 呼吸 / 揭示、句级运动的
    // 呼吸与漂浮。只在播放中推进，暂停时这些运动应连同歌词一起静止。
    if (widget.isPlaying) _pvClock += dt;

    if (_currentLineIndex != _pvPrevLine) {
      _onLineSwitched(_pvPrevLine, _currentLineIndex);
      _pvPrevLine = _currentLineIndex;
    }

    switch (widget.style) {
      case LyricAnimationStyle.pv:
        _updatePvRevealT();
        _updatePv(pos, dt);
      case LyricAnimationStyle.echo:
        _updateEcho(pos, dt);
      case LyricAnimationStyle.mixed:
        // 混合模式：当前句抽到哪种风格，就跑哪一套动效——PV 句走完整文字
        // PV（飞入揭示 + 云室径迹 + 唱字四芒闪点），ECHO 句走空心字碎片，
        // 其余风格直接走列表条目自己的绘制器（逐字动效都在绘制层）。
        // 未跑的那一路仍要继续老化时才有可能落幕，否则 _animationsActive()
        // 恒为真 ⇒ 暂停后仍逐帧重绘。
        switch (_styleForLine(_currentLineIndex)) {
          case LyricAnimationStyle.pv:
            _updatePvRevealT();
            _updatePv(pos, dt);
            _ageEchoFragments(dt);
          case LyricAnimationStyle.echo:
            _updateEcho(pos, dt);
            _agePvFx(dt);
          default:
            _agePvFx(dt);
            _ageEchoFragments(dt);
        }
      default:
        break;
    }
    setState(() {});
  }

  bool _animationsActive() =>
      _pvParticles.isNotEmpty ||
      _pvSparkles.isNotEmpty ||
      _pvRevealT < 1 ||
      _echoFragments.isNotEmpty;

  void _updatePvRevealT() {
    if (_pvRevealDur <= 0) {
      _pvRevealT = 1;
      return;
    }
    _pvRevealT = ((_pvClock - _pvRevealStart) / _pvRevealDur).clamp(0.0, 1.0);
  }

  /// 当前是否处于「整句居中的 PV 舞台」：纯 PV 风格，或混合模式下当前句恰好
  /// 抽到 PV（此时舞台直接铺 [_PvPainter]，而不是列表条目）。
  ///
  /// 两种布局的字坐标换算完全不同（前者自己按画布居中算，后者要把列表项的
  /// RenderBox 位置换算上来），所以生成粒子/闪点时必须据此二选一。
  bool _pvCenteredStage() =>
      widget.style == LyricAnimationStyle.pv ||
      (widget.style == LyricAnimationStyle.mixed &&
          _styleForLine(_currentLineIndex) == LyricAnimationStyle.pv);

  /// 播放中按墙钟对 position 插值；并钳制到当前行结束，避免两次 position 流之间过冲。
  Duration _interpolatedPosition() {
    if (!widget.isPlaying) return widget.position;
    final elapsed = DateTime.now().difference(_lastPosWallClock);
    var est = _lastPos + elapsed;
    final clampEnd = _clampEnd();
    if (clampEnd != null && est > clampEnd) est = clampEnd;
    if (est < _lastPos) est = _lastPos;
    return est;
  }

  Duration? _clampEnd() {
    if (_timelines.isEmpty) return null;
    if (_currentLineIndex < 0) return _timelines.first.lineStart;
    if (_currentLineIndex < _timelines.length) {
      return _timelines[_currentLineIndex].lineEnd;
    }
    return null;
  }

  void _updateCurrentIndices() {
    _currentLineIndex = LyricParser.findCurrentLineIndex(
      widget.lyrics,
      widget.position,
    );
  }

  // ── PV / ECHO 帧更新 ──────────────────────────────────────────────────

  void _onLineSwitched(int prev, int cur) {
    // ⚠️ 混合模式下当前句抽到 PV 时也必须走这段：之前只看 widget.style，
    // 混合模式的 PV 句拿不到 _pvFlyFrom / 揭示进度，_PvPainter 里 revealing
    // 恒为 false ⇒ 整句直接就位、没有飞入 —— 这正是「混合模式里文字 PV
    // 效果没呈现出来」的根因。
    if (widget.style == LyricAnimationStyle.pv ||
        (widget.style == LyricAnimationStyle.mixed &&
            _styleForLine(cur) == LyricAnimationStyle.pv)) {
      // 只呈现当前播放行；换行重新走「逐字飞入揭示」。
      _pvFlyFrom = _buildFlyFrom(cur);
      _pvRevealStart = _pvClock;
      _pvRevealT = 0;
      _pvRevealed = 0;
      _pvFillIndex = 0;
      // 揭示时长随本行时长自适应：短行快、长行慢；封顶 1.2s 避免拖沓，
      // 保底 0.35s 保证飞入过程可感知。空行无字可飞，直接整行就位。
      final tl = (cur >= 0 && cur < _timelines.length) ? _timelines[cur] : null;
      if (tl == null || tl.isEmpty) {
        _pvRevealT = 1;
      } else {
        final lineMs = tl.lineEnd.inMilliseconds - tl.lineStart.inMilliseconds;
        _pvRevealDur = (lineMs / 1000.0 * 0.4).clamp(0.35, 1.2);
      }
    }
    if (widget.style == LyricAnimationStyle.echo ||
        widget.style == LyricAnimationStyle.mixed) {
      _echoLine = cur;
      _echoSpawned = 0;
      // ECHO 碎片只归属当前播放行：换行即清空旧行残留碎片。
      _echoFragments.clear();
    }
    // 混合模式：换行时把上一句的全部特效清空并重置唱字基线——
    // 两句风格可能不同（PV 句有粒子、ECHO 句有碎片），残留会跨风格
    // 冻结导致 _animationsActive() 永不归零 ⇒ 暂停仍在逐帧重绘。
    if (widget.style == LyricAnimationStyle.mixed) {
      // 上一句是 PV 但换得快、揭示还没跑完：这里不复位，_pvRevealT 会永远
      // 停在 <1 ⇒ _animationsActive() 恒为真 ⇒ 暂停后仍逐帧重绘。
      if (_styleForLine(cur) != LyricAnimationStyle.pv) {
        _pvRevealT = 1;
        _pvFlyFrom = const [];
      }
      _pvFillIndex = 0;
      _pvSparkles.clear();
      _pvParticles.clear();
      _echoLine = cur;
      _echoSpawned = 0;
      _echoFragments.clear();
      // 换行随机抽一种入场动效（与逐句视觉风格独立），避免句句同一套路。
      _mixedEnterKind = _planRng.nextInt(3);
    }
  }

  List<_PvFlyFrom> _buildFlyFrom(int cur) {
    if (cur < 0 || cur >= _timelines.length || _timelines[cur].isEmpty) {
      return const [];
    }
    final n = _timelines[cur].graphemes.length;
    return List.generate(n, (i) {
      // 位移适度收敛：飞入是「特效 → 歌词」的过渡，幅度太大显得散乱。
      final dx = (_rng.nextDouble() - 0.5) * 140;
      final dy = -90 - _rng.nextDouble() * 130;
      return _PvFlyFrom(Offset(dx, dy), (_rng.nextDouble() - 0.5) * 0.6);
    });
  }

  /// PV 揭示中第 i 个字的本地进度（0 = 未出发，1 = 已就位）。
  /// 字与字错峰飞入：前 62% 时间用于错峰铺开，每字飞行占 38%，
  /// 最后一字正好在 reveal 结束时就位。
  double _pvCharProgress(int i, int n) {
    if (n <= 0) return 1;
    const spread = 0.62;
    const charDur = 0.38;
    final start = (i / n) * spread;
    return ((_pvRevealT - start) / charDur).clamp(0.0, 1.0);
  }

  /// 三次贝塞尔：从散开的起点飞入终点，控制点带上抛弧线。
  Offset _flyPos(double fx, double fy, Offset delta, double t) {
    if (t >= 1) return Offset(fx, fy);
    final p0 = Offset(fx, fy) + delta;
    final p1 = Offset(p0.dx, p0.dy + 90);
    final p2 = Offset(fx, fy - 50);
    final u = 1 - t;
    final x =
        u * u * u * p0.dx +
        3 * u * u * t * p1.dx +
        3 * u * t * t * p2.dx +
        t * t * t * fx;
    final y =
        u * u * u * p0.dy +
        3 * u * u * t * p1.dy +
        3 * u * t * t * p2.dy +
        t * t * t * fy;
    return Offset(x, y);
  }

  void _updatePv(Duration pos, double dt) {
    final idx = _currentLineIndex;
    final timeline = (idx >= 0 && idx < _timelines.length)
        ? _timelines[idx]
        : null;
    if (timeline != null && !timeline.isEmpty) {
      final fill = graphemeFillAt(timeline, pos);
      if (fill.index < _pvFillIndex) _pvFillIndex = fill.index;
      if (fill.index > _pvFillIndex) {
        // 唱到每个新字即在该字位置触发闪点 + 云室径迹（即时反馈，而非
        // 等整行唱完才看到动效）；seek 跳进行中会一次性补齐已扫过的字。
        for (
          var i = _pvFillIndex;
          i < fill.index && i < timeline.graphemes.length;
          i++
        ) {
          _spawnPvSparkle(timeline, i);
          _spawnPvTrail(timeline, i);
        }
        _pvFillIndex = fill.index;
      }
      // 揭示飞入：每有新字就位，在其位置生成一簇云室径迹，让「特效 →
      // 整句歌词」的过渡有清晰的节奏点（就位即放，不等唱到）。
      if (_pvRevealT < 1 && _pvFlyFrom.isNotEmpty) {
        final m = math.min(_pvFlyFrom.length, timeline.graphemes.length);
        var arrived = 0;
        for (var i = 0; i < m; i++) {
          if (_pvCharProgress(i, m) >= 1) arrived = i + 1;
        }
        for (var i = _pvRevealed; i < arrived; i++) {
          _spawnPvTrail(timeline, i);
        }
        if (arrived > _pvRevealed) _pvRevealed = arrived;
      }
    }
    _agePvFx(dt);
  }

  /// PV 粒子/闪点老化（混合模式下切换到的下一句不带 PV 特效时，也要
  /// 让它自己走完寿命，否则会永久驻留 ⇒ 暂停后仍在逐帧重绘）。
  void _agePvFx(double dt) {
    for (final p in _pvParticles) {
      p.pos += p.vel * dt;
      p.age += dt;
    }
    _pvParticles.removeWhere((p) => p.age >= p.life);
    for (final s in _pvSparkles) {
      s.age += dt;
    }
    _pvSparkles.removeWhere((s) => s.age >= _kPvSparkleLife);
  }

  /// 列表视图（非 PV 单句视图）下第 [i] 个字中心在组件坐标系里的位置。
  ///
  /// PV 视图是"整句居中"的独立布局，闪点/径迹可用 measurement 直接推算；
  /// 融合模式走列表，字在滚动列表里的实际位置必须由 RenderBox 换算
  /// （与 ECHO 碎片同源），列表项尚未布局时返回 null。
  Offset? _listGlyphCenter(_MeasuredLine measured, int i) {
    if (_currentLineIndex < 0 || _currentLineIndex >= _itemKeys.length) {
      return null;
    }
    final ctx = _itemKeys[_currentLineIndex].currentContext;
    final box = ctx?.findRenderObject() as RenderBox?;
    final self = context.findRenderObject() as RenderBox?;
    if (box == null || self == null) return null;
    final o = box.localToGlobal(Offset.zero, ancestor: self);
    final b = measured.boundaries[i];
    // 列表项结构与垂直居中量见 _echoGlyphViewportPos 注释。
    const padV = 12.0;
    final top = o.dy + padV + 3 + measured.lineTops[b.line];
    final h = measured.lineBottoms[b.line] - measured.lineTops[b.line];
    final cx =
        o.dx +
        _kHPadding +
        measured.originX +
        _glyphCenterX(measured.boundaries, measured.metrics, i);
    return Offset(cx, top + h / 2);
  }

  void _spawnPvSparkle(LyricLineTimeline timeline, int glyphIndex) {
    if (glyphIndex < 0 || glyphIndex >= timeline.graphemes.length) return;
    final measured = _measureFor(
      _currentLineIndex,
      _lastMaxWidth,
      timeline,
      _profileForLine(_currentLineIndex),
      _styleForLine(_currentLineIndex),
    );
    if (glyphIndex + 1 >= measured.boundaries.length) return;
    if (!_pvCenteredStage()) {
      // 列表视图：字位置必须把列表项的 RenderBox 位置换算上来。
      // （混合模式的 PV 句一旦走上整句居中画布，就走下面的居中分支。）
      final c = _listGlyphCenter(measured, glyphIndex);
      if (c == null) return;
      _pvSparkles.add(_PvSparkle(c));
      if (_pvSparkles.length > 8) _pvSparkles.removeAt(0);
      return;
    }
    final b = measured.boundaries[glyphIndex];
    final originY = math.max(0.0, (_lastViewportH - measured.base.height) / 2);
    // 行末字中心按所在视觉行右缘推算（见 _glyphRightX）。
    final x =
        _kHPadding +
        measured.originX +
        _glyphCenterX(measured.boundaries, measured.metrics, glyphIndex);
    final y =
        originY +
        measured.lineTops[b.line] +
        (measured.lineBottoms[b.line] - measured.lineTops[b.line]) / 2;
    _pvSparkles.add(_PvSparkle(Offset(x, y)));
    if (_pvSparkles.length > 8) _pvSparkles.removeAt(0);
  }

  /// 云室径迹：唱到某字时在其中心生成一小簇上飘粒子（PV 即时反馈）。
  void _spawnPvTrail(LyricLineTimeline timeline, int glyphIndex) {
    if (glyphIndex < 0 || glyphIndex >= timeline.graphemes.length) return;
    final measured = _measureFor(
      _currentLineIndex,
      _lastMaxWidth,
      timeline,
      _profileForLine(_currentLineIndex),
      _styleForLine(_currentLineIndex),
    );
    if (glyphIndex + 1 >= measured.boundaries.length) return;
    double x;
    double y;
    if (!_pvCenteredStage()) {
      final c = _listGlyphCenter(measured, glyphIndex);
      if (c == null) return;
      x = c.dx;
      y = c.dy;
    } else {
      final b = measured.boundaries[glyphIndex];
      final originY = math.max(
        0.0,
        (_lastViewportH - measured.base.height) / 2,
      );
      // 行末字中心按所在视觉行右缘推算（见 _glyphRightX）。
      x =
          _kHPadding +
          measured.originX +
          _glyphCenterX(measured.boundaries, measured.metrics, glyphIndex);
      y =
          originY +
          measured.lineTops[b.line] +
          (measured.lineBottoms[b.line] - measured.lineTops[b.line]) / 2;
    }
    final n = 3 + _rng.nextInt(4);
    for (var k = 0; k < n; k++) {
      if (_pvParticles.length >= 200) break;
      _pvParticles.add(
        _PvParticle(
          pos: Offset(
            x + (_rng.nextDouble() - 0.5) * 10,
            y + (_rng.nextDouble() - 0.5) * 8,
          ),
          vel: Offset(
            (_rng.nextDouble() - 0.5) * 26,
            -18 - _rng.nextDouble() * 30,
          ),
          life: 0.5 + _rng.nextDouble() * 0.5,
          size: 1.2 + _rng.nextDouble() * 1.8,
        ),
      );
    }
  }

  void _updateEcho(Duration pos, double dt) {
    _ageEchoFragments(dt);

    if (!widget.isPlaying) return;
    final idx = _currentLineIndex;
    if (idx < 0 || idx >= _timelines.length) return;
    final timeline = _timelines[idx];
    if (timeline.isEmpty) return;
    final fill = graphemeFillAt(timeline, pos);
    if (idx != _echoLine) {
      _echoLine = idx;
      _echoSpawned = 0;
    }
    if (fill.index < _echoSpawned) _echoSpawned = fill.index;
    if (fill.index <= _echoSpawned) return;
    final measured = _measureFor(
      idx,
      _lastMaxWidth,
      timeline,
      _profileForLine(idx),
      _styleForLine(idx),
    );
    for (
      var i = _echoSpawned;
      i < fill.index && i < timeline.graphemes.length;
      i++
    ) {
      final p = _echoGlyphViewportPos(measured, i);
      if (p == null) continue;
      if (_echoFragments.length >= 28) _echoFragments.removeAt(0);
      _echoFragments.add(
        _EchoFragment(
          char: timeline.graphemes[i].char,
          pos: p,
          vel: Offset(
            (_rng.nextDouble() - 0.5) * 70,
            -50 - _rng.nextDouble() * 70,
          ),
          rot: (_rng.nextDouble() - 0.5) * 0.6,
          rotVel: (_rng.nextDouble() - 0.5) * 1.4,
          scale: 2.0 + _rng.nextDouble() * 1.6,
          life: 2.2 + _rng.nextDouble() * 4.0,
          phase: _rng.nextDouble() * math.pi * 2,
        ),
      );
      _echoSpawned = i + 1;
    }
  }

  /// ECHO 碎片老化（同 [_agePvFx]：混合模式切到不带 ECHO 的下一句时，
  /// 存量碎片必须能自行落幕）。
  void _ageEchoFragments(double dt) {
    for (final f in _echoFragments) {
      f.pos += f.vel * dt;
      f.vel += Offset(math.sin(f.age * 2.2 + f.phase) * 26 * dt, -14 * dt);
      f.rot += f.rotVel * dt;
      f.age += dt;
    }
    _echoFragments.removeWhere((f) => f.age >= f.life);
  }

  /// 由测量结果 + 列表项渲染位置，换算第 i 个字在视口中的坐标。
  Offset? _echoGlyphViewportPos(_MeasuredLine m, int i) {
    final ctx = _itemKeys[_currentLineIndex].currentContext;
    final box = ctx?.findRenderObject() as RenderBox?;
    final self = context.findRenderObject() as RenderBox?;
    if (box == null || self == null) return null;
    final o = box.localToGlobal(Offset.zero, ancestor: self);
    final b = m.boundaries[i];
    // 列表项结构：GestureDetector > AnimatedScale > AnimatedOpacity >
    // Padding(vertical: 12) > CustomPaint(size.height = base.height + 6)，
    // 绘制器内部还有 (6/2) 的垂直居中量。
    const padV = 12.0;
    final top = o.dy + padV + 3 + m.lineTops[b.line];
    final h = m.lineBottoms[b.line] - m.lineTops[b.line];
    return Offset(o.dx + _kHPadding + m.originX + b.x, top + h / 2);
  }

  // ── PV / ECHO 绘制缓存 ────────────────────────────────────────────────

  /// PV 飞入字样式：当前播放色 + 辉光，随 alpha 淡入（揭示特效层）。
  TextStyle _pvGlyphStyle(double alpha) {
    final p = _lastProfile;
    final shadows = p.glowFar > 0
        ? <Shadow>[
            Shadow(
              color: _playedColor.withValues(alpha: 0.5),
              blurRadius: p.glowNear,
            ),
            Shadow(
              color: _playedColor.withValues(alpha: 0.3),
              blurRadius: p.glowFar,
            ),
          ]
        : null;
    return TextStyle(
      fontSize: p.fontSize,
      fontWeight: p.weight,
      color: _currentColor.withValues(alpha: alpha),
      shadows: shadows,
    );
  }

  /// 逐字 painter 缓存（alpha 分桶，避免每帧重建）。
  TextPainter _pvGlyphPainter(String ch, {required double alpha}) {
    final bucket = _alphaBucket(alpha);
    final sig =
        '${_lastProfile.fontSize}|${_lastProfile.weight}|${_playedColor.toARGB32()}|${_currentColor.toARGB32()}';
    if (_pvGlyphSig != sig) {
      _pvGlyphCache.clear();
      _pvGlyphSig = sig;
    }
    final key = '$ch|$bucket';
    var tp = _pvGlyphCache[key];
    if (tp == null) {
      tp = TextPainter(
        text: TextSpan(text: ch, style: _pvGlyphStyle(bucket)),
        textDirection: TextDirection.ltr,
      )..layout();
      if (_pvGlyphCache.length > 400) _pvGlyphCache.clear();
      _pvGlyphCache[key] = tp;
    }
    return tp;
  }

  static double _alphaBucket(double a) {
    const buckets = [1.0, 0.8, 0.6, 0.4, 0.2, 0.1];
    for (final b in buckets) {
      if (a >= b - 0.01) return b;
    }
    return 0.1;
  }

  /// 整行暗色 painter（与 base 同字重/字号，保证裁剪边界对齐）。
  TextPainter _pvDimPainter(String text) {
    final sig =
        '${_lastProfile.fontSize}|${_lastProfile.weight}|${_baseColor.toARGB32()}';
    if (_pvDimSig != sig) {
      _pvDimCache.clear();
      _pvDimSig = sig;
    }
    var tp = _pvDimCache[text];
    if (tp == null) {
      tp = TextPainter(
        text: TextSpan(
          text: text,
          style: TextStyle(
            fontSize: _lastProfile.fontSize,
            fontWeight: _lastProfile.weight,
            color: _baseColor.withValues(alpha: 0.30),
            height: _lastProfile.lineHeight,
          ),
        ),
        textAlign: TextAlign.center,
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: math.max(1.0, _lastMaxWidth));
      _pvDimCache[text] = tp;
    }
    return tp;
  }

  _EchoPicture _echoPictureFor(
    String ch,
    double fontSize,
    Color color,
    double alpha,
  ) {
    final sizeBucket = (fontSize * 2).round() / 2;
    final alphaBucket = _alphaBucket(alpha);
    final key = '$ch|$sizeBucket|$alphaBucket';
    final sig = '${_playedColor.toARGB32()}';
    if (_echoPictureSig != sig) {
      _echoPictures.clear();
      _echoPictureSig = sig;
    }
    final cached = _echoPictures[key];
    if (cached != null) return cached;
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    final tp = TextPainter(
      text: TextSpan(
        text: ch,
        style: TextStyle(
          fontSize: sizeBucket,
          fontWeight: _lastProfile.weight,
          foreground: Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = math.max(1.2, sizeBucket * 0.045)
            ..color = color.withValues(alpha: 0.55 * alphaBucket),
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, Offset.zero);
    final pic = _EchoPicture(recorder.endRecording(), tp.width, tp.height);
    if (_echoPictures.length > 64) _echoPictures.clear();
    _echoPictures[key] = pic;
    return pic;
  }

  @override
  void didUpdateWidget(covariant LyricsViewWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.position != widget.position) {
      _lastPos = widget.position;
      _lastPosWallClock = DateTime.now();
    }
    // 进度是否发生了「跳变」（快进 / 快退 / 点歌词跳转）。正常播放时相邻帧
    // 的位置差只有几十~几百毫秒，只有 seek 才会一次跨过 1s 以上。
    final jumped =
        (widget.position - oldWidget.position).inMilliseconds.abs() > 1200;
    if (oldWidget.lyrics.length != widget.lyrics.length ||
        oldWidget.lyrics != widget.lyrics ||
        oldWidget.style != widget.style) {
      _itemKeys = List.generate(widget.lyrics.length, (_) => GlobalKey());
      _timelines = _buildTimelines(widget.lyrics);
      _measureCache.clear();
      _pvPrevLine = -1;
      _pvRevealT = 1;
      _pvParticles.clear();
      _pvSparkles.clear();
      _echoFragments.clear();
      _echoLine = -1;
      _echoSpawned = 0;
      _scrollRetries = 0;
      _mixedEnterKind = 0;
      _updateCurrentIndices();
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _scrollToCurrentLine(animate: false),
      );
    } else {
      final oldLineIndex = _currentLineIndex;
      _updateCurrentIndices();
      if (_currentLineIndex != oldLineIndex) {
        if (jumped) {
          // ⚠️ 快进/快退必须**无视** _isUserScrolling：用户刚手动翻过歌词
          // （或点波形前就在翻），4s 静默期内否则会把自动居中吞掉——
          // 这正是「快进/快退后当前行不回到屏幕中间」的根因之一。
          _isUserScrolling = false;
          WidgetsBinding.instance.addPostFrameCallback(
            (_) => _scrollToCurrentLine(),
          );
        } else if (!_isUserScrolling) {
          WidgetsBinding.instance.addPostFrameCallback(
            (_) => _scrollToCurrentLine(),
          );
        }
      }
    }
  }

  @override
  void dispose() {
    _ticker.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  // ── 滚动 ──────────────────────────────────────────────────────────────
  void _scrollToCurrentLine({bool animate = true}) {
    if (!_scrollController.hasClients) return;
    final index = _currentLineIndex;
    if (index < 0 || index >= _itemKeys.length) return;

    final viewportHeight = _scrollController.position.viewportDimension;
    final maxScrollExtent = _scrollController.position.maxScrollExtent;
    final box =
        _itemKeys[index].currentContext?.findRenderObject() as RenderBox?;

    double targetOffset;
    if (box == null) {
      // 目标行还没被构建（首帧、懒加载、跨屏快进/快退）。此时**不能**按
      // 固定行高估算：大字号风格（meteor / drop / cube…）单行实际 70~100dp，
      // 按 56dp 估会偏出几百 dp —— 表现就是「快进/快退后当前行不在屏幕中央，
      // 甚至根本看不见」。这里按每行真实排版高度累加，直接算出精确偏移。
      targetOffset = _offsetForUnbuiltLine(index, viewportHeight);
      // 远距离跳转直接落位，不做长距离动画：先滑一段再纠正会更晃。
      _scrollController.jumpTo(targetOffset.clamp(0.0, maxScrollExtent));
      // 落位后目标行已经进入构建范围，再校一次（拿到真实 RenderBox 时用
      // 实测坐标收口，避免 maxScrollExtent 估算偏低导致的边界偏差）。
      if (_scrollRetries < 2) {
        _scrollRetries++;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _scrollToCurrentLine(animate: false);
        });
      }
      return;
    }
    _scrollRetries = 0;

    final listBox =
        _scrollController.position.context.storageContext.findRenderObject()
            as RenderBox?;
    if (listBox == null) return;

    final itemOffset = box.localToGlobal(Offset.zero, ancestor: listBox).dy;
    final itemHeight = box.size.height;
    targetOffset =
        _scrollController.offset +
        itemOffset -
        (viewportHeight / 2) +
        (itemHeight / 2);
    final clampedOffset = targetOffset.clamp(0.0, maxScrollExtent);

    if (!animate) {
      _scrollController.jumpTo(clampedOffset);
      return;
    }
    _scrollController.animateTo(
      clampedOffset,
      duration: const Duration(milliseconds: 520),
      curve: const _SpringCurve(),
    );
  }

  /// 目标行尚未构建时，它的纵向偏移：**逐行累加真实排版高度**。
  ///
  /// 列表结构见 [_buildLineItem]：`Padding(vertical: 当前行 12 / 其它行 rowGap)
  /// > CustomPaint(measured.base.height + 6)`；顶部留白等于 build 里的
  /// `viewportHeight * 0.4`。行高只取决于文字与字号（颜色不影响），测量结果与
  /// item 构建共用 [_measureCache]，行一旦被构建就直接命中缓存。
  double _offsetForUnbuiltLine(int index, double viewportHeight) {
    final maxWidth = _lastMaxWidth;
    // 顶部留白 = build() 里的 topPadding（viewportHeight * 0.4）。
    var y = (_lastViewportH > 0 ? _lastViewportH : viewportHeight) * 0.4;
    for (var i = 0; i < index; i++) {
      y += _lineItemHeight(i, maxWidth);
    }
    return y + _lineItemHeight(index, maxWidth) / 2 - viewportHeight / 2;
  }

  /// 第 [i] 行的实际排版高度（含上下 Padding），用于未构建时的精确落位。
  double _lineItemHeight(int i, double maxWidth) {
    final profile = _profileForLine(i);
    final pad = i == _currentLineIndex ? 12.0 : profile.rowGap;
    final timeline = i < _timelines.length ? _timelines[i] : null;
    double contentHeight;
    if (timeline == null || timeline.isEmpty) {
      // 与 _buildFallbackText 的 Text 高度一致（单行 '♪'）。
      contentHeight = profile.fontSize * profile.lineHeight;
    } else {
      // 走与 item 构建完全相同的测量入口，行高才能和真实布局逐像素一致
      // （内部按 text + 样式签名校验缓存，换风格/换字号不会用到旧高度）。
      final measured = _measureFor(
        i,
        maxWidth,
        timeline,
        profile,
        _styleForLine(i),
      );
      contentHeight = measured.base.height + 6;
    }
    return contentHeight + pad * 2;
  }

  // ── 风格与排版 ────────────────────────────────────────────────────────

  /// 按风格与视口高度解析视觉参数（pv 的巨字随视口自适应）。
  _StyleProfile _profileFor(double viewportHeight) =>
      _profileForStyle(widget.style, viewportHeight);

  _StyleProfile _profileForStyle(
    LyricAnimationStyle style,
    double viewportHeight,
  ) {
    switch (style) {
      case LyricAnimationStyle.typewriter:
        // 打字机：逐字敲出 + 当前字右侧闪烁光标，无辉光、当前字不缩放，
        // 与经典（无辉光但靠当前字弹放放大）在运动形态上明显区分。
        return const _StyleProfile(
          fontSize: 21.0,
          lineHeight: 1.42,
          glowNear: 0.0,
          glowFar: 0.0,
          rowGap: 8.0,
          charZoom: 1.0,
          typewriter: true,
        );
      case LyricAnimationStyle.meteor:
        // 流星坠落：字号与 drop 同档，行距再放宽一档——唱过的字要带着尾迹
        // 往下飞出去，行间没有余量的话流星会直接压在下一行歌词上。
        return const _StyleProfile(
          fontSize: 25.0,
          lineHeight: 1.40,
          glowNear: 10.0,
          glowFar: 26.0,
          rowGap: 18.0,
          weight: FontWeight.w700,
          charZoom: 1.0,
        );
      case LyricAnimationStyle.pv:
        // 文字 PV：单行巨字 + 疏行距，飞入/散聚动画在本文件 _PvPainter。
        final size = (viewportHeight / 11).clamp(30.0, 42.0);
        return _StyleProfile(
          fontSize: size,
          lineHeight: 1.24,
          glowNear: 12.0,
          glowFar: 30.0,
          rowGap: 16.0,
          weight: FontWeight.w800,
        );
      case LyricAnimationStyle.echo:
        return const _StyleProfile(
          fontSize: 21.0,
          lineHeight: 1.42,
          glowNear: 0.0,
          glowFar: 0.0,
          rowGap: 10.0,
          charZoom: 1.14,
        );
      case LyricAnimationStyle.drop:
        // 重力坠落：字号与 PV 同档，行距放宽给下落轨迹与落点光环留位置。
        return const _StyleProfile(
          fontSize: 25.5,
          lineHeight: 1.42,
          glowNear: 10.0,
          glowFar: 26.0,
          rowGap: 14.0,
          weight: FontWeight.w700,
          charZoom: 1.10,
        );
      case LyricAnimationStyle.burst:
        // 左右弹射：最粗 + 强辉光，横向拖影与放射线才看得清。
        return const _StyleProfile(
          fontSize: 25.0,
          lineHeight: 1.38,
          glowNear: 10.0,
          glowFar: 28.0,
          rowGap: 14.0,
          weight: FontWeight.w700,
          charZoom: 1.12,
        );
      case LyricAnimationStyle.cube:
        // 立体旋入：特粗 + 最强辉光（字块翻到侧面会变暗，需要底光撑住）。
        return const _StyleProfile(
          fontSize: 25.5,
          lineHeight: 1.40,
          glowNear: 12.0,
          glowFar: 30.0,
          rowGap: 14.0,
          weight: FontWeight.w800,
          charZoom: 1.10,
        );
      case LyricAnimationStyle.punch:
        // 冲击爆字：放大由绘制层自己做（2.4 倍起缩），这里 charZoom 置 1
        // 避免与爆字缩放叠乘。
        return const _StyleProfile(
          fontSize: 25.0,
          lineHeight: 1.40,
          glowNear: 12.0,
          glowFar: 32.0,
          rowGap: 14.0,
          weight: FontWeight.w800,
          charZoom: 1.0,
        );
      case LyricAnimationStyle.wave:
        // 水波倒影：行距放宽，给下方镜像倒影留出位置。
        return const _StyleProfile(
          fontSize: 25.0,
          lineHeight: 1.44,
          glowNear: 10.0,
          glowFar: 26.0,
          rowGap: 16.0,
          weight: FontWeight.w600,
          charZoom: 1.10,
        );
      case LyricAnimationStyle.classic:
        // 经典扫过：无辉光，靠「当前字弹放 / 当前行整行放大」制造存在感。
        return const _StyleProfile(
          fontSize: 21.0,
          lineHeight: 1.42,
          glowNear: 0.0,
          glowFar: 0.0,
          rowGap: 8.0,
          charZoom: 1.30,
        );
      case LyricAnimationStyle.mixed:
        // 混合模式自身的排版：仅作为「索引越界 / 计划尚未生成」的兜底
        // （正常渲染时每句都会解析成池中的某一种具体风格，见
        // _styleForLine）。中等字号 + 轻辉光 + 温和弹放，位于几种风格
        // 的交集，切风格时不会有断层。
        return const _StyleProfile(
          fontSize: 20.0,
          lineHeight: 1.40,
          glowNear: 8.0,
          glowFar: 20.0,
          rowGap: 10.0,
          charZoom: 1.22,
        );
    }
  }

  // ── 歌词三色（设置页可自定义；null = 用默认配色） ──────────────────────
  Color? get _unplayedOverride => PreferencesService.getLyricColorUnplayed();
  Color? get _currentOverride => PreferencesService.getLyricColorCurrent();
  Color? get _playedOverride => PreferencesService.getLyricColorPlayed();

  /// 未播放（未唱到的歌词），默认白。
  Color get _baseColor => _unplayedOverride ?? kLyricColorUnplayedDefault;

  /// 已播放（已唱过的歌词），默认绿。
  Color get _playedColor => _playedOverride ?? kLyricColorPlayedDefault;

  /// 当前播放（正在演唱的字），默认黄绿。
  Color get _currentColor => _currentOverride ?? kLyricColorCurrentDefault;

  TextStyle _baseTextStyle(_StyleProfile p) => TextStyle(
    fontSize: p.fontSize,
    fontWeight: p.weight,
    color: _baseColor,
    height: p.lineHeight,
  );

  /// 高亮样式：辉光风格用双层 shadows 模拟 folia 的 near/far BlurFilter
  /// （Shadow 是 Skia 原生文字发光，零额外开销；仅在裁剪区内绘制）。
  TextStyle _highlightTextStyle(_StyleProfile p) {
    final shadows = p.glowFar > 0
        ? <Shadow>[
            Shadow(
              color: _playedColor.withValues(alpha: 0.45),
              blurRadius: p.glowNear,
            ),
            Shadow(
              color: _playedColor.withValues(alpha: 0.28),
              blurRadius: p.glowFar,
            ),
          ]
        : null;
    return TextStyle(
      fontSize: p.fontSize,
      fontWeight: p.weight,
      color: _playedColor,
      height: p.lineHeight,
      shadows: shadows,
    );
  }

  /// 当前字样式（弹放放大的那个字）：「当前播放」色 + 与高亮一致的辉光。
  TextStyle _currentTextStyle(_StyleProfile p) {
    final shadows = p.glowFar > 0
        ? <Shadow>[
            Shadow(
              color: _currentColor.withValues(alpha: 0.5),
              blurRadius: p.glowNear,
            ),
            Shadow(
              color: _currentColor.withValues(alpha: 0.3),
              blurRadius: p.glowFar,
            ),
          ]
        : null;
    return TextStyle(
      fontSize: p.fontSize,
      fontWeight: p.weight,
      color: _currentColor,
      height: p.lineHeight,
      shadows: shadows,
    );
  }

  _MeasuredLine _measureFor(
    int i,
    double maxWidth,
    LyricLineTimeline timeline,
    _StyleProfile profile,
    LyricAnimationStyle style,
  ) {
    if ((maxWidth - _measureMaxWidth).abs() > 0.5) {
      _measureCache.clear();
      _measureMaxWidth = maxWidth;
    }
    final colorSig =
        '${_baseColor.toARGB32()}-${_playedColor.toARGB32()}-${_currentColor.toARGB32()}-${style.name}-${profile.fontSize}-${profile.weight}';
    final cached = _measureCache[i];
    if (cached != null &&
        cached.text == timeline.text &&
        cached.colorSig == colorSig) {
      return cached;
    }
    final measured = _measureLine(timeline, maxWidth, colorSig, profile);
    _measureCache[i] = measured;
    return measured;
  }

  _MeasuredLine _measureLine(
    LyricLineTimeline timeline,
    double maxWidth,
    String colorSig,
    _StyleProfile profile,
  ) {
    final base = TextPainter(
      text: TextSpan(text: timeline.text, style: _baseTextStyle(profile)),
      textAlign: TextAlign.center,
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: math.max(1.0, maxWidth));
    final highlight = TextPainter(
      text: TextSpan(text: timeline.text, style: _highlightTextStyle(profile)),
      textAlign: TextAlign.center,
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: math.max(1.0, maxWidth));

    final metrics = base.computeLineMetrics();
    // 本 SDK 的 LineMetrics 无 top/bottom，用 height 累计推导每个视觉行的上下边界。
    final lineTops = <double>[];
    final lineBottoms = <double>[];
    double acc = 0;
    for (final m in metrics) {
      lineTops.add(acc);
      acc += m.height;
      lineBottoms.add(acc);
    }

    final offsets = timeline.utf16BoundaryOffsets;
    final boundaries = <_Boundary>[];
    double lastX = 0;
    var lastLine = 0;
    for (var i = 0; i < offsets.length; i++) {
      final off = offsets[i];
      if (i + 1 < offsets.length) {
        // 第 i 个字：必须用**非零宽** selection——本 SDK 对零宽
        // selection 返回空盒列表（曾致 boundaries 全为 (0,0)：当前字
        // 放大画到句首、扫过高亮失效、PV/ECHO 特效位置全错）。
        final boxes = base.getBoxesForSelection(
          TextSelection(baseOffset: off, extentOffset: offsets[i + 1]),
        );
        if (boxes.isNotEmpty) {
          lastX = boxes.first.left;
          lastLine = _lineIndexForTop(boxes.first.top, lineTops);
        }
      } else if (off > 0) {
        // 末尾哨兵：取最后一个字盒的右缘，供"整行唱完"判满用。
        final boxes = base.getBoxesForSelection(
          TextSelection(baseOffset: offsets[i - 1], extentOffset: off),
        );
        if (boxes.isNotEmpty) {
          lastX = boxes.last.right;
          lastLine = _lineIndexForTop(boxes.last.top, lineTops);
        }
      }
      boundaries.add(_Boundary(lastX, lastLine));
    }

    return _MeasuredLine(
      text: timeline.text,
      colorSig: colorSig,
      base: base,
      highlight: highlight,
      metrics: metrics,
      lineTops: lineTops,
      lineBottoms: lineBottoms,
      boundaries: boundaries,
      // paragraph shrink-to-fit：文本实际宽度 ≤ maxWidth，居中偏移补齐。
      originX: math.max(0.0, (maxWidth - base.width) / 2),
    );
  }

  /// 由视觉行累计 top 反推给定 y 所属行号。
  int _lineIndexForTop(double top, List<double> lineTops) {
    var idx = 0;
    for (var l = 0; l < lineTops.length; l++) {
      if (lineTops[l] <= top + 0.5) {
        idx = l;
      } else {
        break;
      }
    }
    return idx;
  }

  // ── 构建 ──────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    if (widget.style == LyricAnimationStyle.pv) {
      return _buildPvView();
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final maxWidth = math.max(1.0, constraints.maxWidth - _kHPadding * 2);
        final viewportHeight = constraints.maxHeight;
        // 混合模式：进帧先确保逐句风格计划就位（每行据此取自己的字号/辉光）。
        _ensureMixedPlan();
        final profile = _profileFor(viewportHeight);
        _lastMaxWidth = maxWidth;
        _lastProfile = profile;
        _lastViewportH = viewportHeight;

        // 混合模式：文字 PV 舞台——只呈现当前一句（已播/待播完全不渲染），
        // 整句居中，每句带随机入场动效与随机视觉风格，不再走可滚动整列。
        if (widget.style == LyricAnimationStyle.mixed) {
          return _buildMixedStage(constraints, maxWidth, viewportHeight);
        }

        final topPadding = viewportHeight * 0.4;
        final bottomPadding = viewportHeight * 0.4;

        final list = NotificationListener<ScrollNotification>(
          onNotification: (notification) {
            if (notification is UserScrollNotification) {
              _isUserScrolling = true;
              Future.delayed(const Duration(seconds: 4), () {
                if (mounted) _isUserScrolling = false;
              });
            }
            return false;
          },
          child: ShaderMask(
            blendMode: BlendMode.dstIn,
            shaderCallback: (rect) => const LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                Colors.transparent,
                Colors.black,
                Colors.black,
                Colors.transparent,
              ],
              stops: [0.0, 0.10, 0.90, 1.0],
            ).createShader(rect),
            child: ListView.builder(
              controller: _scrollController,
              padding: EdgeInsets.only(
                top: topPadding,
                bottom: bottomPadding,
                left: _kHPadding,
                right: _kHPadding,
              ),
              itemCount: widget.lyrics.length,
              itemBuilder: (context, index) => _buildLineItem(index, maxWidth),
            ),
          ),
        );

        // ECHO：碎片漂移画布铺在歌词列表上层（特效盖住歌词，而非被歌词
        // 盖住）。混合模式已在上面走单句舞台并自带特效层，不会走到这里。
        if (widget.style == LyricAnimationStyle.echo) {
          return Stack(
            children: [
              list,
              Positioned.fill(
                child: IgnorePointer(
                  child: CustomPaint(painter: _EchoPainter(this)),
                ),
              ),
            ],
          );
        }
        return list;
      },
    );
  }

  /// PV 画布视图：替换整个列表，单行巨字 + 飞入 + 崩解散聚 + 闪点。
  Widget _buildPvView() {
    return LayoutBuilder(
      builder: (context, constraints) {
        final maxWidth = math.max(1.0, constraints.maxWidth - _kHPadding * 2);
        final profile = _profileFor(constraints.maxHeight);
        _lastMaxWidth = maxWidth;
        _lastProfile = profile;
        _lastViewportH = constraints.maxHeight;
        return ShaderMask(
          blendMode: BlendMode.dstIn,
          shaderCallback: (rect) => const LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              Colors.transparent,
              Colors.black,
              Colors.black,
              Colors.transparent,
            ],
            stops: [0.0, 0.08, 0.92, 1.0],
          ).createShader(rect),
          child: CustomPaint(size: Size.infinite, painter: _PvPainter(this)),
        );
      },
    );
  }

  /// 混合模式单句舞台：整列只画当前播放句（已播/待播一句都不渲染）。
  ///
  /// 当前句抽到不同风格时走不同的呈现通道：
  /// - **PV**：直接铺 [_PvPainter] 的「整句居中」画布，完整保留逐字飞入揭示、
  ///   暗底裁剪、呼吸、云室径迹与唱字四芒闪点（与单独选「文字 PV」一致）；
  /// - **其它风格**：居中条目（逐字动效由 [_MotionLinePainter] 负责），
  ///   换行时用随机入场动效衔接。
  Widget _buildMixedStage(
    BoxConstraints constraints,
    double maxWidth,
    double viewportHeight,
  ) {
    _lastMaxWidth = maxWidth;
    _lastViewportH = viewportHeight;
    final idx = _currentLineIndex;
    final lineStyle = _styleForLine(idx);
    if (idx >= 0 && idx < widget.lyrics.length) {
      _lastProfile = _profileForLine(idx);
    }

    final Widget body;
    if (idx < 0 || idx >= widget.lyrics.length) {
      body = const SizedBox.shrink();
    } else if (lineStyle == LyricAnimationStyle.pv) {
      // ⚠️ 这里刻意多做一层：早期版本混合舞台一律走列表条目渲染，PV 句只能
      // 拿到「扫过 + 碎片」，飞入/揭示/径迹全都没跑，用户看到的「文字 PV
      // 没呈现」就是这么来的。现在抽到 PV 就整块换成 PV 画布。
      body = Positioned.fill(
        child: CustomPaint(size: Size.infinite, painter: _PvPainter(this)),
      );
    } else {
      body = Center(
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 320),
          switchInCurve: Curves.easeOutCubic,
          transitionBuilder: _mixedEnterTransition,
          child: KeyedSubtree(
            key: ValueKey<int>(idx),
            child: _buildLineItem(idx, maxWidth),
          ),
        ),
      );
    }

    return Stack(
      children: [
        body,
        // 特效层：ECHO 碎片漂移做背景，PV 云室径迹与唱字四芒闪点压在上层。
        // PV 句这块会主动跳过 PV 部分（画布自己已经画过一遍，避免双重描边）。
        Positioned.fill(
          child: IgnorePointer(
            child: CustomPaint(painter: _MixedFxPainter(this)),
          ),
        ),
      ],
    );
  }

  /// 混合模式逐句随机入场动效：0 淡入上移 / 1 缩放弹入 / 2 右滑入。
  Widget _mixedEnterTransition(Widget child, Animation<double> anim) {
    switch (_mixedEnterKind) {
      case 1:
        return FadeTransition(
          opacity: anim,
          child: ScaleTransition(
            scale: Tween(begin: 0.86, end: 1.0).animate(anim),
            child: child,
          ),
        );
      case 2:
        return FadeTransition(
          opacity: anim,
          child: SlideTransition(
            position: Tween(
              begin: const Offset(0.25, 0),
              end: Offset.zero,
            ).animate(anim),
            child: child,
          ),
        );
      default:
        return FadeTransition(
          opacity: anim,
          child: SlideTransition(
            position: Tween(
              begin: const Offset(0, 0.10),
              end: Offset.zero,
            ).animate(anim),
            child: child,
          ),
        );
    }
  }

  static const Duration _toneDuration = Duration(milliseconds: 260);

  /// 构建第 [index] 句歌词。混合模式下每句按计划解析成自己的风格
  /// （字号 / 辉光 / 字重 / 行距），因此本索引 ray 的排版参数逐句独立。
  Widget _buildLineItem(int index, double maxWidth) {
    final line = widget.lyrics[index];
    final lineStyle = _styleForLine(index);
    final profile = _profileForLine(index);
    final timeline = (index >= 0 && index < _timelines.length)
        ? _timelines[index]
        : null;
    final isActive = index == _currentLineIndex;
    final dist = _currentLineIndex < 0 ? index + 1 : index - _currentLineIndex;
    final absDist = dist.abs();

    // 当前行不再整行放大：均分时间线让所有歌词（含普通 LRC）都支持逐字，
    // 存在感由 _SweepPainter 的「当前字弹放」提供；行本身保持 1.0。
    final scale = isActive ? 1.0 : math.max(0.80, 1.0 - 0.07 * absDist);
    double alpha;
    if (isActive) {
      alpha = 1.0;
    } else if (dist < 0) {
      alpha = math.max(0.34, 0.55 - 0.06 * (absDist - 1)); // 已唱：更暗
    } else {
      alpha = math.max(0.40, 0.66 - 0.08 * (absDist - 1)); // 未唱：略亮
    }

    final Widget content;
    if (timeline == null || timeline.isEmpty) {
      content = _buildFallbackText(line, isActive, profile);
    } else {
      final measured = _measureFor(
        index,
        maxWidth,
        timeline,
        profile,
        lineStyle,
      );
      final position = _interpolatedPosition();
      // 取当前唱到的字，交给绘制器做弹放放大：
      // 带词时间戳的歌词用真实逐字时间；普通 LRC 用均分时间线，同样逐字。
      var charZoom = 1.0;
      TextPainter? zoomGlyph;
      if (isActive && profile.charZoom > 1.0) {
        final fill = graphemeFillAt(timeline, position);
        if (fill.index >= 0 && fill.index < timeline.graphemes.length) {
          charZoom = profile.charZoom;
          zoomGlyph = _zoomGlyphPainter(
            timeline.graphemes[fill.index].char,
            profile,
          );
        }
      }
      content = CustomPaint(
        size: Size(maxWidth, measured.base.height + 6),
        // 逐字重绘风格（meteor / drop / burst / cube / punch / wave）由该层接管：
        // 它们在「扫过」之上还有自己的字号语言与逐字动效，只给整行套
        // Transform 是看不出区别的（见 _MotionLinePainter 注释）。
        // 只对当前句启用——逐字绘制比整行裁剪贵，铺满整屏会掉帧。
        painter: isActive && _isMotionStyle(lineStyle)
            ? _MotionLinePainter(
                measured: measured,
                profile: profile,
                style: lineStyle,
                timeline: timeline,
                position: position,
                clock: _pvClock,
                baseColor: _baseColor,
                playedColor: _playedColor,
                currentColor: _currentColor,
                glyphs: _motionGlyphs,
                charZoom: profile.charZoom,
              )
            : _SweepPainter(
                base: measured.base,
                highlight: measured.highlight,
                metrics: measured.metrics,
                lineTops: measured.lineTops,
                lineBottoms: measured.lineBottoms,
                boundaries: measured.boundaries,
                timeline: timeline,
                position: position,
                charZoom: charZoom,
                zoomGlyph: zoomGlyph,
                originX: measured.originX,
                typewriter: profile.typewriter,
                cursorColor: _currentColor,
              ),
      );
    }

    return GestureDetector(
      key: _itemKeys[index],
      onTap: () {
        if (widget.onSeek != null) {
          widget.onSeek!(line.timestamp);
          setState(() => _isUserScrolling = false);
        }
      },
      child: AnimatedScale(
        scale: scale,
        duration: _toneDuration,
        curve: Curves.easeOutCubic,
        child: AnimatedOpacity(
          opacity: alpha,
          duration: _toneDuration,
          child: Padding(
            padding: EdgeInsets.symmetric(
              vertical: isActive ? 12 : profile.rowGap,
            ),
            // 动效全部由绘制层逐字完成（见 _MotionLinePainter）；外层不再
            // 套整句 Transform——那会与逐字相位打架，也曾是「五种风格看起来
            // 几乎一样」的根因。
            child: content,
          ),
        ),
      ),
    );
  }

  Widget _buildFallbackText(
    LyricLine line,
    bool isActive,
    _StyleProfile profile,
  ) {
    return Text(
      line.text.isEmpty ? '♪' : line.text,
      textAlign: TextAlign.center,
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        fontSize: profile.fontSize,
        fontWeight: profile.weight,
        color: isActive ? _currentColor : _baseColor,
        height: profile.lineHeight,
      ),
    );
  }
}

/// 整句变色的淡入系数（0..1）。
///
/// 普通 LRC（无逐字时间戳）整句一起变色：行首起约 90ms 内交叉淡入，
/// 避免硬跳变；带逐字时间戳的歌词按字进度自然过渡，恒返回 1。
double _lineColorRamp(LyricLineTimeline timeline, Duration position) {
  if (timeline.hasWordTimestamps) return 1;
  final startMs = timeline.lineStart.inMilliseconds;
  final endMs = timeline.lineEnd.inMilliseconds;
  if (endMs <= startMs) return 1;
  final span = endMs - startMs;
  final t = ((position.inMilliseconds - startMs) / span).clamp(0.0, 1.0);
  return (t / 0.05).clamp(0.0, 1.0);
}

/// 逐字扫过绘制器：先整行画中性色，再把"已唱部分"裁剪成强调色。
class _SweepPainter extends CustomPainter {
  final TextPainter base;
  final TextPainter highlight;
  final List<ui.LineMetrics> metrics;
  final List<double> lineTops;
  final List<double> lineBottoms;
  final List<_Boundary> boundaries;
  final LyricLineTimeline timeline;
  final Duration position;

  /// 当前字放倍数（>1 且 [zoomGlyph] 非空时绘制放大的当前字）。
  final double charZoom;

  /// 当前字的单字 painter（highlight 样式、原字号）。
  final TextPainter? zoomGlyph;

  /// 文本左缘偏移（paragraph shrink-to-fit 的居中补偿），[boundaries] 的 x
  /// 与绘制坐标之间差此量。
  final double originX;

  /// 打字机模式：在当前字右缘画一道光标竖线。
  final bool typewriter;

  /// 光标颜色（打字机模式）；null 时回退到当前播放色由调用方传入。
  final Color? cursorColor;

  const _SweepPainter({
    required this.base,
    required this.highlight,
    required this.metrics,
    required this.lineTops,
    required this.lineBottoms,
    required this.boundaries,
    required this.timeline,
    required this.position,
    this.charZoom = 1.0,
    this.zoomGlyph,
    this.originX = 0,
    this.typewriter = false,
    this.cursorColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (timeline.isEmpty) return;
    final dy = math.max(0.0, (size.height - base.height) / 2);

    // 1) 整行中性色（未唱部分）
    base.paint(canvas, Offset(originX, dy));

    // 2) 已唱部分裁剪成强调色
    final fill = graphemeFillAt(timeline, position);
    final path = _buildFillPath(fill);
    if (path != null) {
      canvas.save();
      canvas.translate(0, dy);
      canvas.clipPath(path);
      final ramp = _lineColorRamp(timeline, position);
      if (ramp >= 1) {
        highlight.paint(canvas, Offset(originX, 0));
      } else {
        // 整句变色淡入中：用带 alpha 的图层做交叉淡入（淡入结束后走直绘）。
        canvas.saveLayer(
          Rect.fromLTWH(0, 0, size.width, size.height),
          Paint()..color = Colors.white.withValues(alpha: ramp),
        );
        highlight.paint(canvas, Offset(originX, 0));
        canvas.restore();
      }
      canvas.restore();
    }

    // 3) 当前字弹放放大（逐字歌词）：唱到的字按字内进度做 sin 弹放——
    //    字中最亮最大、首尾为 1.0，换字时无缩放硬切。
    //    位置严格锁定该字中心（originX + 字边界中点），不随行宽漂移。
    if (charZoom > 1.0 && zoomGlyph != null) {
      final glyph = zoomGlyph!; // 字段不享受类型提升，取局部变量
      final gi = fill.index;
      if (gi >= 0 && gi + 1 < boundaries.length) {
        final b = boundaries[gi];
        // 行末字右缘取所在视觉行右缘（见 _glyphRightX），否则换行首行
        // 最右的当前字会画进行首。
        final cx = originX + _glyphCenterX(boundaries, metrics, gi);
        final cy =
            lineTops[b.line] + (lineBottoms[b.line] - lineTops[b.line]) / 2;
        final k = math.sin(math.pi * fill.fraction.clamp(0.0, 1.0));
        final z = 1.0 + (charZoom - 1.0) * k;
        canvas.save();
        canvas.translate(0, dy);
        canvas.translate(cx, cy);
        canvas.scale(z);
        canvas.translate(-cx, -cy);
        glyph.paint(
          canvas,
          Offset(cx - glyph.width / 2, cy - glyph.height / 2),
        );
        canvas.restore();
      }
    }

    // 4) 打字机光标：当前字右缘一道竖线，随唱字推进（无辉光、不缩放）。
    if (typewriter && fill.index >= 0 && fill.index < boundaries.length) {
      final bl = boundaries[fill.index].line;
      final cx = originX + _glyphRightX(boundaries, metrics, fill.index);
      final top = dy + lineTops[bl];
      final bottom = dy + lineBottoms[bl];
      final cursor = cursorColor ?? const Color(0xFFFFFFFF);
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(cx + 2, top + 1, 2.2, bottom - top - 2),
          const Radius.circular(1.1),
        ),
        Paint()..color = cursor.withValues(alpha: 0.9),
      );
    }
  }

  /// 依据填充位置构建裁剪路径。
  ///
  /// - 带逐字时间戳：逐字扫过——填充行之前的视觉行整行填满，填充行填到 [x]；
  /// - 普通 LRC（均分时间线）：**整句一起变色**（本行开始即整行填满），
  ///   避免均分时间与真实演唱不匹配的错位感；逐字弹放动画不受影响。
  Path? _buildFillPath(({int index, double fraction}) fill) {
    final total = timeline.graphemes.length;
    // index == -1 才是尚未开始；index == 0 表示正在唱第一个字，
    // 需按字内进度从行首起填（否则首字瞬时整字点亮、无平滑扫过）。
    if (fill.index < 0 || boundaries.isEmpty) return null;

    if (!timeline.hasWordTimestamps) {
      // 整句变色：本行所有视觉行一次性填满。
      final path = Path();
      for (var l = 0; l < metrics.length; l++) {
        final m = metrics[l];
        path.addRect(
          Rect.fromLTRB(
            originX + m.left,
            lineTops[l],
            originX + m.left + m.width,
            lineBottoms[l],
          ),
        );
      }
      return path;
    }

    final full = fill.index >= total || fill.index >= boundaries.length - 1;
    final fillLine = full ? metrics.length : boundaries[fill.index].line;

    final path = Path();
    for (var l = 0; l < metrics.length; l++) {
      final m = metrics[l];
      final left = originX + m.left;
      final right = originX + m.left + m.width;
      final top = lineTops[l];
      final bottom = lineBottoms[l];
      if (l < fillLine) {
        path.addRect(Rect.fromLTRB(left, top, right, bottom));
      } else if (l == fillLine && !full) {
        final x0 = originX + boundaries[fill.index].x;
        // 行末字右缘取所在视觉行右缘：下一个 boundary 属于下一视觉行，
        // 其 x 是下一行行首（会让扫过终点倒退、该字永远填不满）。
        final x1 = originX + _glyphRightX(boundaries, metrics, fill.index);
        final fx = x0 + (x1 - x0) * fill.fraction;
        final clipped = fx.clamp(left, right);
        if (clipped > left) {
          path.addRect(Rect.fromLTRB(left, top, clipped, bottom));
        }
      }
    }
    return path;
  }

  @override
  bool shouldRepaint(covariant _SweepPainter old) =>
      old.position != position ||
      old.base != base ||
      old.highlight != highlight ||
      old.timeline != timeline ||
      old.charZoom != charZoom ||
      old.zoomGlyph != zoomGlyph ||
      old.typewriter != typewriter ||
      old.cursorColor != cursorColor ||
      old.originX != originX;
}

// ── PV 画布 ──────────────────────────────────────────────────────────────

/// 文字 PV 绘制器（借鉴 folia-major Lumiere lyricWindow）：
/// 只呈现**当前播放行**（不画下一行预览、不画旧行崩解）——
/// 中心氛围光 → 逐字飞入揭示（特效层：暗底按视觉行裁到已就位的字，
/// 飞入字用当前播放色 + 辉光弹入）→ 高亮（逐字 / 整句）→ 云室径迹
/// → 四芒闪点。歌词从特效逐渐显示到完整，而非一开始就整句可见。
class _PvPainter extends CustomPainter {
  final _LyricsViewWidgetState state;
  const _PvPainter(this.state);

  @override
  void paint(Canvas canvas, Size size) {
    final w = state.widget;
    final idx = state._currentLineIndex;
    if (idx < 0 || idx >= w.lyrics.length) return;
    final timeline = state._timelines[idx];
    if (timeline.isEmpty) return;
    final measured = state._measureFor(
      idx,
      state._lastMaxWidth,
      timeline,
      state._profileForLine(idx),
      state._styleForLine(idx),
    );
    final tp = measured.base;
    final originY = math.max(0.0, (size.height - tp.height) / 2);
    // 文本左缘 = PV 画布基准 + 居中补偿（paragraph shrink-to-fit）。
    final originX = _kHPadding + measured.originX;
    final center = Offset(size.width / 2, originY + tp.height / 2);

    // 1) 中心氛围光
    final glowR = size.width * 0.55;
    canvas.drawCircle(
      center,
      glowR,
      Paint()
        ..shader = RadialGradient(
          colors: [
            w.accentColor.withValues(alpha: 0.10),
            w.accentColor.withValues(alpha: 0.0),
          ],
        ).createShader(Rect.fromCircle(center: center, radius: glowR)),
    );

    // 2) 当前行文字：揭示动画进行中时只画「已飞入就位」的部分（暗底按
    //    视觉行裁到首个未到达字的左缘）；reveal 完成后进入常态整行暗底。
    final n = timeline.graphemes.length;
    final revealing =
        state._pvRevealT < 1 && state._pvFlyFrom.length == n && n > 0;
    final dim = state._pvDimPainter(timeline.text);
    if (revealing) {
      // 每视觉行已揭示的右边界 = 首个未到达字的左缘（整行都到达则为行右缘）。
      final edges = List<double>.generate(
        measured.metrics.length,
        (l) => originX + measured.metrics[l].left + measured.metrics[l].width,
      );
      for (var i = 0; i < n; i++) {
        if (state._pvCharProgress(i, n) >= 1) continue;
        final l = measured.boundaries[i].line;
        final x = originX + measured.boundaries[i].x;
        if (x < edges[l]) edges[l] = x;
      }
      canvas.save();
      for (var l = 0; l < measured.metrics.length; l++) {
        final left = originX + measured.metrics[l].left;
        if (edges[l] <= left) continue;
        // 注意 +originY：dim 绘制在 (originX, originY)，裁剪带须同坐标系。
        canvas.clipRect(
          Rect.fromLTRB(
            left,
            originY + measured.lineTops[l],
            edges[l],
            originY + measured.lineBottoms[l],
          ),
        );
      }
      dim.paint(canvas, Offset(originX, originY));
      canvas.restore();
    } else {
      // 常态：整行暗底 + 轻微呼吸。
      final breath = math.sin(state._pvClock * 2 * math.pi / 3.4);
      canvas.save();
      canvas.translate(0, breath * 2.0);
      dim.paint(canvas, Offset(originX, originY));
      canvas.restore();
    }

    // 3) 高亮：带逐字时间戳的歌词逐字变色；普通 LRC 整句一起变色
    //    （行首淡入，与列表视图的逐句变色一致）。
    final fill = graphemeFillAt(timeline, state._interpolatedPosition());
    if (!timeline.hasWordTimestamps) {
      final ramp = _lineColorRamp(timeline, state._interpolatedPosition());
      if (ramp > 0) {
        canvas.save();
        if (ramp < 1) {
          canvas.saveLayer(
            Rect.fromLTWH(0, 0, size.width, size.height),
            Paint()..color = Colors.white.withValues(alpha: ramp),
          );
        }
        for (var l = 0; l < measured.metrics.length; l++) {
          canvas.clipRect(
            Rect.fromLTRB(
              originX + measured.metrics[l].left,
              originY + measured.lineTops[l],
              originX + measured.metrics[l].left + measured.metrics[l].width,
              originY + measured.lineBottoms[l],
            ),
          );
        }
        measured.highlight.paint(canvas, Offset(originX, originY));
        canvas.restore();
      }
    } else {
      for (var i = 0; i < timeline.graphemes.length; i++) {
        final sungFull = i < fill.index;
        final sungPart = !sungFull && i == fill.index;
        if (!sungFull && !sungPart) continue;
        final b = measured.boundaries[i];
        final x0 = originX + b.x;
        // 行末字（自动换行首行最右）右缘取所在视觉行右缘，否则该字
        // 的裁剪带塌缩被跳过——「第一行最右侧文字不变色」的根因。
        var x1 =
            originX + _glyphRightX(measured.boundaries, measured.metrics, i);
        if (sungPart) {
          x1 = x0 + (x1 - x0) * fill.fraction;
        }
        if (x1 <= x0) continue;
        final wob = math.sin(state._pvClock * 2 * math.pi / 3.4 + i * 0.55);
        canvas.save();
        canvas.translate(0, wob * 3.0);
        canvas.clipRect(
          Rect.fromLTRB(
            x0,
            originY + measured.lineTops[b.line],
            x1,
            originY + measured.lineBottoms[b.line],
          ),
        );
        measured.highlight.paint(canvas, Offset(originX, originY));
        canvas.restore();
      }
    }

    // 4) 揭示中的飞入字（特效层）：未就位的字按贝塞尔飞入到位，用「当前
    //    播放」色 + 辉光 + 缩放弹入——观感从特效过渡到完整歌词，而不是
    //    一开始就显示整句。
    if (revealing) {
      for (var i = 0; i < n; i++) {
        final t = state._pvCharProgress(i, n);
        if (t <= 0 || t >= 1) continue;
        final b = measured.boundaries[i];
        // 行末字中心取所在视觉行右缘推算（见 _glyphRightX）。
        final fx =
            originX + _glyphCenterX(measured.boundaries, measured.metrics, i);
        final fy =
            originY +
            measured.lineTops[b.line] +
            (measured.lineBottoms[b.line] - measured.lineTops[b.line]) / 2;
        final p = state._flyPos(fx, fy, state._pvFlyFrom[i].offset, t);
        final g = state._pvGlyphPainter(
          timeline.graphemes[i].char,
          alpha: math.min(1.0, t * 2.5),
        );
        canvas.save();
        canvas.translate(p.dx, p.dy);
        canvas.rotate(state._pvFlyFrom[i].rot * (1 - t));
        canvas.scale(1.0 + 0.35 * (1 - t));
        canvas.translate(-g.width / 2, -g.height / 2);
        g.paint(canvas, Offset.zero);
        canvas.restore();
      }
    }

    // 4) 云室径迹
    for (final p in state._pvParticles) {
      final k = p.age / p.life;
      final a = (1 - k) * 0.5;
      if (a <= 0.01) continue;
      canvas.drawCircle(
        p.pos,
        p.size * (1 - 0.5 * k),
        Paint()..color = w.accentColor.withValues(alpha: a),
      );
    }

    // 5) 四芒闪点
    for (final s in state._pvSparkles) {
      final k = s.age / _kPvSparkleLife;
      final r = 9.0 + 16.0 * k;
      final a = (1 - k).clamp(0.0, 1.0);
      if (a <= 0.02) continue;
      _drawPvStar(canvas, s.pos, r, a, state._currentColor);
    }
  }

  @override
  bool shouldRepaint(covariant _PvPainter old) => true;
}

/// 预渲染的空心字碎片（描边文字），按 字符/字号/透明度 分桶缓存。
class _EchoPicture {
  final ui.Picture picture;
  final double width;
  final double height;
  const _EchoPicture(this.picture, this.width, this.height);
}

/// ECHO 背景层：唱词炸出的空心字碎片漂移、旋转、淡出。
class _EchoPainter extends CustomPainter {
  final _LyricsViewWidgetState state;
  const _EchoPainter(this.state);

  @override
  void paint(Canvas canvas, Size size) {
    final frags = state._echoFragments;
    if (frags.isEmpty) return;
    for (final f in frags) {
      final k = f.age / f.life;
      final alpha = (1 - k) * (1 - k);
      if (alpha <= 0.02) continue;
      final pic = state._echoPictureFor(
        f.char,
        state._profileForLine(state._currentLineIndex).fontSize * f.scale,
        state._playedColor,
        alpha * 0.85,
      );
      canvas.save();
      canvas.translate(f.pos.dx, f.pos.dy);
      canvas.rotate(f.rot);
      canvas.scale(1.0 - 0.3 * k);
      canvas.translate(-pic.width / 2, -pic.height / 2);
      canvas.drawPicture(pic.picture);
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(covariant _EchoPainter old) => true;
}

/// 混合模式特效层：当前句抽到哪种风格就画哪一套——ECHO 句的空心字碎片
/// 漂移、PV 句的云室径迹与唱字四芒闪点，其余风格本层为空（不画）。
///
/// 碎片部分直接委托 [_EchoPainter]、闪点复用 [_drawPvStar]，保证与
/// 单一风格的观感完全一致。
class _MixedFxPainter extends CustomPainter {
  final _LyricsViewWidgetState state;
  const _MixedFxPainter(this.state);

  @override
  void paint(Canvas canvas, Size size) {
    _EchoPainter(state).paint(canvas, size);
    // 整句居中的 PV 舞台（纯 PV 风格或混合模式抽到 PV）：[_PvPainter] 自己
    // 已经画过径迹与闪点，这里再画一遍会双重描边 ⇒ 直接跳过。
    if (state._pvCenteredStage()) return;
    for (final p in state._pvParticles) {
      final k = p.age / p.life;
      final a = (1 - k) * 0.5;
      if (a <= 0.01) continue;
      canvas.drawCircle(
        p.pos,
        p.size * (1 - 0.5 * k),
        Paint()..color = state.widget.accentColor.withValues(alpha: a),
      );
    }
    for (final s in state._pvSparkles) {
      final k = s.age / _kPvSparkleLife;
      final r = 8.0 + 13.0 * k;
      final a = (1 - k).clamp(0.0, 1.0);
      if (a <= 0.02) continue;
      _drawPvStar(canvas, s.pos, r, a, state._currentColor);
    }
  }

  @override
  bool shouldRepaint(covariant _MixedFxPainter old) => true;
}

// ── 逐字重绘层（meteor / drop / burst / cube / punch / wave） ────────────

/// 这几种风格由 [_MotionLinePainter] **逐字重绘**，而不是「整行 TextPainter
/// 外加一层 Transform」。列表里只有当前句走它，其它行仍走 [_SweepPainter]。
bool _isMotionStyle(LyricAnimationStyle s) =>
    s == LyricAnimationStyle.meteor ||
    s == LyricAnimationStyle.drop ||
    s == LyricAnimationStyle.burst ||
    s == LyricAnimationStyle.cube ||
    s == LyricAnimationStyle.punch ||
    s == LyricAnimationStyle.wave;

/// easeOutCubic：入场类位移/透明度用它，避免线性加速的机械感。
double _easeOutCubic(double t) {
  final x = t.clamp(0.0, 1.0);
  return 1 - math.pow(1 - x, 3).toDouble();
}

/// easeOutBack：末尾**冲过头再回弹**（弹射 / 立体旋入用）。
///
/// 这正是「有冲击力」的来源：字不是匀速停到位，而是撞过来、弹一下才定住。
double _easeOutBack(double t) {
  final x = (t.clamp(0.0, 1.0) - 1);
  const c1 = 1.70158;
  const c3 = c1 + 1;
  return 1 + c3 * x * x * x + c1 * x * x;
}

/// 逐字 TextPainter 缓存。
///
/// 这些风格每帧都要逐字绘制（一句 20 来个字），每次新建 TextPainter 都要
/// 重新排版，逐帧做必然掉帧 ⇒ 按「字 + 色调 + 透明度桶」缓存。
/// [sig] 是字体/字重/行高签名，变了就整表清空（切换风格 / 混合模式换句）。
class _GlyphTextCache {
  final Map<String, TextPainter> _cache = {};
  String _sig = '';

  TextPainter get({
    required String ch,
    required String variant,
    required String sig,
    required TextStyle Function() build,
  }) {
    if (_sig != sig) {
      _cache.clear();
      _sig = sig;
    }
    final key = '$ch|$variant';
    final hit = _cache[key];
    if (hit != null) return hit;
    final tp = TextPainter(
      text: TextSpan(text: ch, style: build()),
      textDirection: TextDirection.ltr,
    )..layout();
    // 上限兜底：长歌词 + 多档透明度可能攒到几百条，超了就整表重来。
    if (_cache.length > 320) _cache.clear();
    _cache[key] = tp;
    return tp;
  }
}

/// 逐字重绘风格的整句重绘器。
///
/// 设计口径对齐「文字 PV」与「回声碎片」：那两种风格的辨识度来自**逐字绘制
/// + 环境光效 + 空间运动**，而不是给整行套一点位移/缩放。上一版四种风格
/// 就是后者，彼此几乎看不出差别（用户反馈「大体看上去效果几乎一致」），
/// 所以整体重做成「各有明确的运动方向 + 落地/炸开反馈」：
///
/// - `meteor` 流星坠落：整句先一起亮起，唱过的字带流星尾迹逐字往下坠走
/// - `drop`  重力坠落：唱到的字从上方砸落、触地弹跳、压扁回弹 + 冲击光环与碎屑
/// - `burst` 左右弹射：奇偶字分别从左 / 右高速弹入，拖影 + 过冲回弹 + 放射线
/// - `cube`  立体旋入：字块带厚度与投影绕竖轴旋入，唱字持续自转（真 3D 观感）
/// - `punch` 冲击爆字：唱字 2.4 倍猛缩到位 + 双重冲击波环 + 速度线，未唱字退远
/// - `wave`  水波倒影：逐字上下起伏，行下方有镜像倒影随波淡出
///
/// ⚠️ 只用 canvas 变换绘制，**不改字号**（字号变 = 行高变 = 整列表重排）。
class _MotionLinePainter extends CustomPainter {
  final _MeasuredLine measured;
  final _StyleProfile profile;
  final LyricAnimationStyle style;
  final LyricLineTimeline timeline;
  final Duration position;

  /// 墙钟秒（只在播放中推进）：驱动起伏 / 自转 / 摆动。
  final double clock;

  final Color baseColor;
  final Color playedColor;
  final Color currentColor;
  final _GlyphTextCache glyphs;
  final double charZoom;

  const _MotionLinePainter({
    required this.measured,
    required this.profile,
    required this.style,
    required this.timeline,
    required this.position,
    required this.clock,
    required this.baseColor,
    required this.playedColor,
    required this.currentColor,
    required this.glyphs,
    this.charZoom = 1.0,
  });

  /// 本句已走秒数（入场类动效的时基）。
  ///
  /// 不用 [phase]：长句的 phase 走得很慢，逐字入场会被拉成好几秒。
  double get _lineSeconds {
    final ms = (position - timeline.lineStart).inMilliseconds;
    return (ms / 1000.0).clamp(0.0, 600.0);
  }

  double _cx(int i) =>
      measured.originX +
      _glyphCenterX(measured.boundaries, measured.metrics, i);

  double _cy(int i) {
    final b = measured.boundaries[i];
    return (measured.lineTops[b.line] + measured.lineBottoms[b.line]) / 2;
  }

  String get _glyphSig =>
      '${profile.fontSize}|${profile.weight}|${profile.lineHeight}';

  /// 取某字的单字 painter（按色调 + 透明度桶 + 是否带辉光缓存）。
  TextPainter _glyphPainter(
    int i, {
    required Color color,
    required double alpha,
    bool glow = false,
  }) {
    final bucket = _LyricsViewWidgetState._alphaBucket(alpha);
    final key =
        '${color.toARGB32()}|${glow ? 1 : 0}|$bucket|${glow ? profile.glowFar.round() : 0}';
    return glyphs.get(
      ch: timeline.graphemes[i].char,
      variant: key,
      sig: _glyphSig,
      build: () => TextStyle(
        fontSize: profile.fontSize,
        fontWeight: profile.weight,
        height: profile.lineHeight,
        color: color.withValues(alpha: bucket),
        shadows: glow && profile.glowFar > 0
            ? <Shadow>[
                Shadow(
                  color: color.withValues(alpha: 0.45),
                  blurRadius: profile.glowNear,
                ),
                Shadow(
                  color: color.withValues(alpha: 0.26),
                  blurRadius: profile.glowFar,
                ),
              ]
            : null,
      ),
    );
  }

  /// 画一个字：以字心为锚点，可叠加缩放 / 3D 翻转 / 平面旋转 / 拖影 / 压扁。
  ///
  /// [ghosts] > 0 时沿 ([ghostDx], [ghostDy]) 方向叠若干份低透明度复制件，
  /// 作为运动拖影（坠落是竖直向上拖，弹射是水平方向拖）。
  void _drawGlyph(
    Canvas canvas,
    int i, {
    required Color color,
    required double alpha,
    bool glow = false,
    double dx = 0,
    double dy = 0,
    double scale = 1.0,
    double sx = 1.0,
    double sy = 1.0,
    double rotY = 0,
    double rotZ = 0,
    double persp = 0.0015,
    int ghosts = 0,
    double ghostDx = 0,
    double ghostDy = 0,
    double ghostAlpha = 0.24,
  }) {
    if (alpha <= 0.02) return;
    final cx = _cx(i) + dx;
    final cy = _cy(i) + dy;
    for (var k = ghosts; k >= 1; k--) {
      final ga = alpha * ghostAlpha / k;
      if (ga <= 0.02) continue;
      _paintGlyphTp(
        canvas,
        _glyphPainter(i, color: color, alpha: ga),
        cx + ghostDx * k,
        cy + ghostDy * k,
        scale,
        sx,
        sy,
        rotY,
        rotZ,
        persp,
      );
    }
    _paintGlyphTp(
      canvas,
      _glyphPainter(i, color: color, alpha: alpha, glow: glow),
      cx,
      cy,
      scale,
      sx,
      sy,
      rotY,
      rotZ,
      persp,
    );
  }

  void _paintGlyphTp(
    Canvas canvas,
    TextPainter tp,
    double cx,
    double cy,
    double scale,
    double sx,
    double sy,
    double rotY,
    double rotZ,
    double persp,
  ) {
    canvas.save();
    canvas.translate(cx, cy);
    if (rotY != 0) {
      // 透视：翻到接近侧面时字会被压扁，正好是「实体字块转过去」的观感。
      canvas.transform(
        (Matrix4.identity()
              ..setEntry(3, 2, persp)
              ..rotateY(rotY)
              ..rotateZ(rotZ))
            .storage,
      );
    } else if (rotZ != 0) {
      canvas.rotate(rotZ);
    }
    if (scale != 1.0 || sx != 1.0 || sy != 1.0) {
      canvas.scale(scale * sx, scale * sy);
    }
    tp.paint(canvas, Offset(-tp.width / 2, -tp.height / 2));
    canvas.restore();
  }

  /// 已唱 / 当前 / 未唱三档着色（与扫过视图同一套歌词三色）。
  Color _toneOf(int i, ({int index, double fraction}) fill) => i < fill.index
      ? playedColor
      : (i == fill.index ? currentColor : baseColor);

  /// 未唱字的底字透明度。
  ///
  /// ⚠️ 句首之前（`fill.index < 0`，例如整首开头 / seek 到行前）不能沿用
  /// 0.26——那会让整句淡到看不见，正是「切风格后歌词消失」的观感。此时
  /// 抬到 0.45，看起来是「还没开口、但字在那儿」。
  double _alphaOf(int i, ({int index, double fraction}) fill) =>
      i <= fill.index ? 1.0 : (fill.index < 0 ? 0.45 : 0.26);

  @override
  void paint(Canvas canvas, Size size) {
    if (timeline.isEmpty) return;
    final n = timeline.graphemes.length;
    if (n == 0) return;
    final fill = graphemeFillAt(timeline, position);
    final dy = math.max(0.0, (size.height - measured.base.height) / 2);
    canvas.save();
    canvas.translate(0, dy);
    switch (style) {
      case LyricAnimationStyle.meteor:
        _paintMeteor(canvas, size, fill, n);
      case LyricAnimationStyle.drop:
        _paintDrop(canvas, size, fill, n);
      case LyricAnimationStyle.burst:
        _paintBurst(canvas, size, fill, n);
      case LyricAnimationStyle.cube:
        _paintCube(canvas, size, fill, n);
      case LyricAnimationStyle.punch:
        _paintPunch(canvas, size, fill, n);
      case LyricAnimationStyle.wave:
        _paintWave(canvas, size, fill, n);
      default:
        measured.base.paint(canvas, Offset(measured.originX, 0));
    }
    canvas.restore();
  }

  // ── meteor：流星坠落 ──────────────────────────────────────────────────
  //
  // 与 drop 方向相反：drop 是「唱到的字从上面砸下来、落到自己的格位上」，
  // meteor 是「整句先一起亮着，唱过的字再脱离格位、带着流星尾迹往下坠走」。
  //
  // 所以时基完全不同：**每个字的坠落从它的 endTime（唱完那一刻）开始**，
  // 而不是从 fill.index 推。这样同一画面里「正在唱的字」仍然完整地待在
  // 格位上，「唱完的字」已经开始往下掉——用户要的「先显示整句、再逐字坠落」
  // 就是这一条时间差，任何一帧都能同时看到这两态。
  void _paintMeteor(
    Canvas canvas,
    Size size,
    ({int index, double fraction}) fill,
    int n,
  ) {
    final fs = profile.fontSize;
    // 整行一起登场：0.34s 内整句由淡到实、同时上浮到位。这是「先显示当前
    // 播放的整句歌词」的那一拍，与 drop/burst/cube/punch 的逐字错峰入场不同。
    final lineIn = _easeOutCubic((_lineSeconds / 0.34).clamp(0.0, 1.0));
    const fallDur = 0.72; // 单字下坠时长（秒）
    final fallDist = fs * 2.3; // 下坠距离：太短读不出「划落」

    /// 坠落位移：p^1.5 —— 比起纯自由落体（p^2）前段就有明显位移。
    /// 纯重力曲线会让字在 70% 的时间窗里几乎没离开行，只有最后几帧才冲出去，
    /// 随机一帧看过去就像「没动」（与上一批风格翻车的原因同源）。
    double fallOf(double kk) =>
        math.pow(kk.clamp(0.0, 1.0), 1.5).toDouble() * fallDist;

    for (var i = 0; i < n; i++) {
      final g = timeline.graphemes[i];
      final isCurrent = i == fill.index;
      final tone = _toneOf(i, fill);
      // 唱完后的秒数；<= 0 表示还没唱完（含正在唱），字留在格位上。
      final double tFall =
          (position.inMilliseconds - g.endTime.inMilliseconds) / 1000.0;

      // 入场：整句同步（不是逐字），所以这里只跟 lineIn 走。
      var dy = (1 - lineIn) * fs * 0.55;
      // 未唱字给 0.62：整句要「先看得清」，0.26 那档是扫过风格用的。
      var alpha = (i <= fill.index ? 1.0 : 0.62) * (0.42 + 0.58 * lineIn);
      var scale = 1.0;
      var k = 0.0;

      if (tFall > 0) {
        k = (tFall / fallDur).clamp(0.0, 1.0);
        // 余痕：字飞走后，原位留一层很淡的残影。没有它的话，读到句尾时整行
        // 几乎空掉（只剩当前字和后面几个未唱字），用户会以为「歌词丢了」——
        // 这是本项目在别的风格上踩过的老坑。它不参与坠落，只是「唱过的痕迹」。
        _drawGlyph(
          canvas,
          i,
          color: playedColor,
          alpha: 0.14 * (0.42 + 0.58 * lineIn) * math.min(1.0, k * 2.4),
        );
        dy += fallOf(k);
        // 尾段燃尽：不是「到点消失」，而是像流星烧完。
        alpha *= 1 - math.pow(k, 2.6).toDouble();
        scale = 1.0 - 0.16 * (fallOf(k) / fallDist); // 远去缩一点，强化纵深
      } else if (isCurrent) {
        // 正在唱的字：整句里最亮，先给一点「将被甩出去」的势能——随字内
        // 进度轻微上浮 + 放大，p→1 时正好接上坠落的第一帧。
        final p = fill.fraction.clamp(0.0, 1.0);
        dy -= 2.2 * p;
        scale = 1.0 + 0.07 * p;
      }

      // 1) 彗尾：从头部往上拉一道**锥形光带**（由粗到细、由亮到暗）。
      //    流星靠这道光认得出来；只叠几份半透明字副本会糊成一团。
      if (k > 0.02) {
        final tailLen = fs * (0.70 + 1.30 * k); // 越甩越开，尾越长
        final cx0 = _cx(i);
        final cy0 = _cy(i) + dy;
        final tailTop = Offset(cx0, cy0 - tailLen);
        // 外层柔光：一条更宽更淡的描边垫在下面，尾迹才有「发光」的厚度，
        // 否则 1~2dp 的细线在手机上几乎看不见。
        canvas.drawLine(
          tailTop,
          Offset(cx0, cy0),
          Paint()
            ..strokeCap = StrokeCap.round
            ..strokeWidth = fs * 0.30
            ..color = tone.withValues(alpha: alpha * 0.13),
        );
        // 内芯偏白：纯歌词绿拉出来的尾迹像草，不像流星。
        final bright = Color.lerp(tone, Colors.white, 0.60) ?? tone;
        const segs = 3;
        for (var j = 0; j < segs; j++) {
          final a = alpha * (0.50 - 0.11 * j);
          if (a <= 0.02) continue;
          canvas.drawLine(
            Offset(cx0, cy0 - tailLen * (j / segs)),
            Offset(cx0, cy0 - tailLen * ((j + 1) / segs)),
            Paint()
              ..strokeCap = StrokeCap.round
              ..strokeWidth = fs * (0.17 - 0.037 * j)
              ..color = (j == 0 ? bright : tone).withValues(alpha: a),
          );
        }
        // 2) 运动残像：头部上方一份淡字，补出「刚从格位里飞出去」的连续感。
        //    只留一份——多份会与光带互相糊住，反而看不出形状。
        _drawGlyph(
          canvas,
          i,
          color: tone,
          alpha: alpha * 0.3,
          dy: dy - math.max(3.0, fs * 0.22),
          scale: scale * 0.96,
        );
        // 3) 余烬：沿光带向上散开的几粒亮尘（相位固定 ⇒ 暂停即静止）。
        _paintMeteorSparks(canvas, i, cx0, cy0, tailLen, alpha);
        // 4) 点燃的头部：字的下缘一个白热点，像流星正在烧。
        final hot = Color.lerp(tone, Colors.white, 0.85) ?? tone;
        canvas.drawCircle(
          Offset(cx0, cy0 + fs * 0.36),
          math.max(1.0, fs * 0.085 * (1 - k)),
          Paint()..color = hot.withValues(alpha: alpha * 0.55),
        );
      }

      _drawGlyph(
        canvas,
        i,
        color: tone,
        alpha: alpha,
        // 头部带辉光：拖长尾迹的关键是「亮头 + 暗尾」。
        glow: k > 0 ? true : isCurrent,
        dy: dy,
        scale: scale,
      );
    }
  }

  /// 流星余烬：沿彗尾向上散开的亮尘，越靠近尾端越稀越小。
  ///
  /// 相位只跟「字索引 + 序号」有关，不随帧随机 ⇒ 暂停时火花静止，
  /// 播放时也只是随 [clock] 缓慢摆动，不会像噪点一样闪。
  void _paintMeteorSparks(
    Canvas canvas,
    int i,
    double cx,
    double cy,
    double tailLen,
    double alpha,
  ) {
    final fs = profile.fontSize;
    for (var j = 0; j < 3; j++) {
      final t = (j + 1) / 4; // 尾部 25% / 50% / 75% 处
      final ph = i * 1.7 + j * 2.1;
      final lateral = math.sin(ph + clock * 2.4) * fs * (0.14 + 0.22 * t);
      final a = alpha * (0.40 - 0.09 * j);
      if (a <= 0.02) continue;
      canvas.drawCircle(
        Offset(cx + lateral, cy - tailLen * t),
        math.max(0.5, fs * 0.032 * (1 - 0.22 * j)),
        Paint()..color = currentColor.withValues(alpha: a),
      );
    }
  }

  // ── drop：重力坠落 ────────────────────────────────────────────────────
  //
  // 唱到的字**从上方砸下来**（自由落体 + 触地弹跳），落地瞬间压扁再回弹，
  // 同时溅起一圈冲击光环和几粒碎屑；未唱的字悬在上方一点等位，已唱的字
  // 稳稳留在原地。整句读起来像「字被一颗一颗丢到位置上」，重音落在字上。
  void _paintDrop(
    Canvas canvas,
    Size size,
    ({int index, double fraction}) fill,
    int n,
  ) {
    final fs = profile.fontSize;
    final fallDist = fs * 0.95 + 8;
    for (var i = 0; i < n; i++) {
      final isCurrent = i == fill.index;
      final isSung = i < fill.index;
      var dy = 0.0;
      var sx = 1.0;
      var sy = 1.0;
      var alpha = _alphaOf(i, fill);
      var ghosts = 0;
      var ghostDy = 0.0;
      var ghostAlpha = 0.24;
      double p = 0;
      if (isCurrent) {
        p = fill.fraction.clamp(0.0, 1.0);
        // ⚠️ 关键：下落必须铺满**整个字窗**（重力加速 p^2.4），而不是只占前
        // 几十毫秒。否则随机一帧看过去，当前字早已落地 ⇒ 四种风格看起来和
        // 普通扫过没差别（用户反馈「效果几乎一致」的根因）。
        final fall = math.pow(p, 2.4).toDouble();
        dy = -(1 - fall) * fallDist;
        // 最后 12% 落地压扁 → 回弹。
        final squash = math.sin(math.pi * ((p - 0.88) / 0.12).clamp(0.0, 1.0));
        sy = 1 - 0.24 * squash;
        sx = 1 + 0.22 * squash;
        // 下落过程由淡到实：顶端几乎透明 ⇒ 不会糊住上一行歌词。
        alpha = 0.30 + 0.70 * fall;
        if (fall < 0.995) {
          ghosts = 3;
          ghostDy = -(6 + (1 - fall) * 10);
          ghostAlpha = 0.30;
        }
      } else if (!isSung) {
        // 未唱：悬在上方等位，给出「还没掉下来」的线索。
        dy = -fs * 0.18;
      }
      _drawGlyph(
        canvas,
        i,
        color: _toneOf(i, fill),
        alpha: alpha,
        glow: isCurrent || isSung,
        dy: dy,
        sx: sx,
        sy: sy,
        ghosts: ghosts,
        ghostDy: ghostDy,
        ghostAlpha: ghostAlpha,
      );
      if (isCurrent) _paintDropImpact(canvas, i, p);
    }
  }

  /// 坠落落点的冲击光环 + 碎屑。
  void _paintDropImpact(Canvas canvas, int i, double p) {
    final k = ((p - 0.86) / 0.14).clamp(0.0, 1.0);
    if (k <= 0 || k >= 1) return;
    final fs = profile.fontSize;
    final cx = _cx(i);
    final cy = _cy(i) + fs * 0.46;
    final grow = _easeOutCubic(k);
    final rx = fs * (0.30 + 1.35 * grow);
    final a = (1 - k) * 0.55;
    canvas.drawOval(
      Rect.fromCenter(center: Offset(cx, cy), width: rx * 2, height: rx * 0.6),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = math.max(0.7, 2.8 * (1 - k))
        ..color = currentColor.withValues(alpha: a),
    );
    // 碎屑：向左右两侧弹开（固定 4 粒，成本可忽略）。
    for (var j = 0; j < 4; j++) {
      final dir = j.isEven ? -1.0 : 1.0;
      final spread = 0.55 + 0.35 * (j ~/ 2);
      final px = cx + dir * rx * spread;
      final py = cy - 4 - 9 * grow * (1 - k) - (j % 2) * 2;
      canvas.drawCircle(
        Offset(px, py),
        math.max(0.5, 1.7 * (1 - k)),
        Paint()..color = playedColor.withValues(alpha: a * 0.85),
      );
    }
  }

  // ── burst：左右弹射 ────────────────────────────────────────────────────
  //
  // 奇数字从左边、偶数字从右边**高速弹进来**（入场用 easeOutBack ⇒ 撞过头
  // 再回弹），带 3 层横向拖影；唱到的字在整个字窗内持续「被推进来」并炸出
  // 一圈放射光线。与「整句横向推进」的旧幻灯片完全不同：逐字、双向交替。
  void _paintBurst(
    Canvas canvas,
    Size size,
    ({int index, double fraction}) fill,
    int n,
  ) {
    final sec = _lineSeconds;
    final fs = profile.fontSize;
    for (var i = 0; i < n; i++) {
      final dir = i.isEven ? -1.0 : 1.0;
      // 整句入场：逐字错峰弹入，过冲让每个字都「弹一下」才定住。
      final enterT = ((sec - i * 0.03) / 0.44).clamp(0.0, 1.0);
      final enter = _easeOutBack(enterT);
      var dx = dir * (1 - enter) * (fs * 2.4);
      var scale = 1.0 + 0.45 * (1 - enterT);
      var ghosts = enterT < 0.995 ? 3 : 0;
      final isCurrent = i == fill.index;
      var rayK = 0.0;
      if (isCurrent) {
        // 唱到的字：整段字窗都在「从侧面推进来」——p=0 时偏在来向侧且放大，
        // p→1 才落回自己的格位。这样任何一帧都能看到当前字正在弹射。
        final p = fill.fraction.clamp(0.0, 1.0);
        final e = _easeOutCubic((p / 0.92).clamp(0.0, 1.0));
        dx += dir * (1 - e) * (fs * 1.15);
        scale *= 1.0 + 0.45 * (1 - e);
        if (e < 0.995) ghosts = 3;
        rayK = p;
      }
      _drawGlyph(
        canvas,
        i,
        color: _toneOf(i, fill),
        alpha: _alphaOf(i, fill),
        glow: isCurrent,
        dx: dx,
        scale: scale,
        ghosts: ghosts,
        // 拖影留在「来向」一侧，读起来是速度残像。
        ghostDx: dir * 8,
        ghostAlpha: 0.30,
      );
      if (isCurrent) _paintBurstRays(canvas, i, rayK, dir);
    }
  }

  /// 弹射到位瞬间的放射光线。
  void _paintBurstRays(Canvas canvas, int i, double k, double dir) {
    if (k >= 0.99) return;
    final fs = profile.fontSize;
    final cx = _cx(i);
    final cy = _cy(i);
    final len = fs * (0.30 + 0.95 * k);
    final a = (1 - k) * (1 - k) * 0.55;
    final paint = Paint()
      ..strokeCap = StrokeCap.round
      ..strokeWidth = 0.6 + 1.8 * (1 - k)
      ..color = currentColor.withValues(alpha: a);
    final inner = fs * 0.62;
    for (var j = 0; j < 6; j++) {
      final ang = -math.pi / 2 + j * math.pi / 3 + 0.18 * dir;
      final c = math.cos(ang);
      final s = math.sin(ang);
      canvas.drawLine(
        Offset(cx + c * inner, cy + s * inner),
        Offset(cx + c * (inner + len), cy + s * (inner + len)),
        paint,
      );
    }
  }

  // ── cube：立体旋入 ────────────────────────────────────────────────────
  //
  // 每个字是一个**有厚度、有投影的字块**：绕竖轴从侧面旋进来（强透视 +
  // 深色侧面副本模拟挤出厚度 + 右下暗影），落定后轻微呼吸；唱到的字持续
  // 360° 自转，明暗随受光面变化。这是四种里唯一的「真 3D」观感。
  void _paintCube(
    Canvas canvas,
    Size size,
    ({int index, double fraction}) fill,
    int n,
  ) {
    final sec = _lineSeconds;
    for (var i = 0; i < n; i++) {
      final enterT = ((sec - i * 0.035) / 0.52).clamp(0.0, 1.0);
      final enter = _easeOutBack(enterT);
      // 从 -100° 旋入：过冲收尾会短暂越过 0°，像字块「卡」进座位。
      var rotY = -(1 - enter) * 1.75;
      var dy = 0.0;
      final isCurrent = i == fill.index;
      // 常驻倾斜：不能只靠「转到某个角度」才看出立体——随机一帧常常正好
      // 转到正视（rotY≈0），看起来就和普通歌词一样。所以每个字都带一层
      // 缓慢摆动的基础倾角。
      // 相位按字错开 ⇒ 即便某一帧正好不动，整行也是「高低错落的字块墙」，
      // 而不是一排平面字（这是上一版最容易被看成普通歌词的原因）。
      rotY += 0.24 * math.sin(i * 0.9 + clock * 0.55);
      if (isCurrent) {
        // 唱到的字绕竖轴匀速自转（约 3.5s 一圈，太快会看成闪烁）+ 轻微悬浮。
        rotY += 2 * math.pi * (clock * 0.29);
        dy = -1.4 * math.sin(clock * 2.2);
      }
      final color = _toneOf(i, fill);
      final alpha = _alphaOf(i, fill);
      // 受光面：转到侧面时整体压暗（cos 越小越暗）。
      final lit = 0.62 + 0.38 * math.cos(rotY).abs();
      // 1) 投影：右下暗影，立体感主要靠它。
      _drawGlyph(
        canvas,
        i,
        color: Colors.black,
        alpha: alpha * 0.45,
        dx: 3.0,
        dy: dy + 4.0,
        rotY: rotY,
        persp: 0.0045,
      );
      // 2) 厚度：常驻一份「右下挤出」（保证正视时也是实体字块），再叠
      //    旋转朝向带来的侧面偏移。
      final offX = 2.2 - math.sin(rotY) * 5.0;
      final offY = 1.8;
      final sideColor = Color.lerp(color, Colors.black, 0.55) ?? color;
      // 长句降档：每字 4 次绘制（投影 + 3 层厚度 + 正面）在 20 字以上时
      // 逐帧成本偏高，厚度减到 2 层（观感几乎无差）。
      final thick = n > 18 ? 2 : 3;
      for (var k = thick; k >= 1; k--) {
        _drawGlyph(
          canvas,
          i,
          color: sideColor,
          alpha: alpha * 0.55 / k,
          dx: offX * k * 0.7,
          dy: dy + offY * k * 0.7,
          rotY: rotY,
          persp: 0.0045,
        );
      }
      // 3) 正面字。
      _drawGlyph(
        canvas,
        i,
        color: color,
        alpha: alpha * lit,
        glow: isCurrent,
        dy: dy,
        rotY: rotY,
        persp: 0.0045,
        scale: isCurrent
            ? 1.0 +
                  (charZoom - 1.0) *
                      0.4 *
                      math.sin(math.pi * fill.fraction.clamp(0.0, 1.0))
            : 1.0,
      );
    }
  }

  // ── punch：冲击爆字 ────────────────────────────────────────────────────
  //
  // 每个字本身是「一次打击」：唱到的字从 2.4 倍猛地缩到位，同时炸开两圈
  // 冲击波和 8 条速度线；未唱的字缩小退到远景（0.74 + 压暗），当前字因此
  // 永远是最突出的一个。
  void _paintPunch(
    Canvas canvas,
    Size size,
    ({int index, double fraction}) fill,
    int n,
  ) {
    final sec = _lineSeconds;
    for (var i = 0; i < n; i++) {
      final isCurrent = i == fill.index;
      final isSung = i < fill.index;
      var scale = isSung ? 1.0 : 0.74;
      var alpha = isSung ? 1.0 : _alphaOf(i, fill) * 0.85;
      double p = 0;
      if (isCurrent) {
        p = fill.fraction.clamp(0.0, 1.0);
        // 同样铺满整个字窗：当前字从 2.2 倍一路收回到 1.0（不是一闪就没了）。
        final e = _easeOutCubic(p);
        scale = 1.0 + 1.25 * (1 - e);
        alpha = 1.0;
      } else if (!isSung && fill.index < 0) {
        // 句首之前（fill.index == -1）：整行都还没开口，别把字压没了。
        scale = 0.9;
        alpha = 0.45;
      }
      // 整句入场：从 1.3 倍缩回 1（错峰），与逐字爆字叠加但不同步。
      final enterT = ((sec - i * 0.02) / 0.34).clamp(0.0, 1.0);
      scale *= 1.0 + 0.28 * (1 - _easeOutCubic(enterT));
      _drawGlyph(
        canvas,
        i,
        color: _toneOf(i, fill),
        alpha: alpha,
        glow: isCurrent,
        scale: scale,
      );
      if (isCurrent) _paintPunchShock(canvas, i, p);
    }
  }

  /// 爆字瞬间的双重冲击波 + 速度线。
  void _paintPunchShock(Canvas canvas, int i, double p) {
    final k = p.clamp(0.0, 1.0);
    if (k >= 1) return;
    final fs = profile.fontSize;
    final cx = _cx(i);
    final cy = _cy(i);
    for (var r = 0; r < 2; r++) {
      final kk = (k - r * 0.26).clamp(0.0, 1.0);
      if (kk <= 0) continue;
      final rad = fs * (0.45 + 2.5 * _easeOutCubic(kk));
      canvas.drawCircle(
        Offset(cx, cy),
        rad,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = math.max(0.6, 3.2 * (1 - kk))
          ..color = currentColor.withValues(alpha: 0.42 * (1 - kk) * (1 - kk)),
      );
    }
    final a = (1 - k) * (1 - k) * 0.5;
    if (a <= 0.02) return;
    final paint = Paint()
      ..strokeCap = StrokeCap.round
      ..strokeWidth = 0.5 + 2.0 * (1 - k)
      ..color = currentColor.withValues(alpha: a);
    for (var j = 0; j < 8; j++) {
      final ang = j * math.pi / 4 + 0.22;
      final c = math.cos(ang);
      final s = math.sin(ang);
      final r0 = fs * (0.65 + 1.7 * k);
      final r1 = r0 + fs * 0.55 * (1 - k);
      canvas.drawLine(
        Offset(cx + c * r0, cy + s * r0),
        Offset(cx + c * r1, cy + s * r1),
        paint,
      );
    }
  }

  // ── wave：水波倒影 ────────────────────────────────────────────────────
  void _paintWave(
    Canvas canvas,
    Size size,
    ({int index, double fraction}) fill,
    int n,
  ) {
    final top = measured.lineTops.first;
    final bottom = measured.lineBottoms.last;
    final lineH = bottom - top;
    // 每个字的竖直起伏：相位随字索引错开 ⇒ 整句像水面波纹掠过。
    double dyOf(int i) =>
        5.5 * math.sin(clock * 2.0 + i * 0.55) +
        1.6 * math.sin(clock * 1.1 + i * 0.2);
    double tiltOf(int i) => 0.02 * math.sin(clock * 1.6 + i * 0.5);

    // 1) 倒影：整行镜像画在下方，再用竖直渐变把远端吃掉（dstIn 遮罩）。
    // 倒影紧贴行底：gap 同时用于「镜像原点平移」和「遮罩矩形起点」，
    // 两处必须同一个量，否则倒影会被裁掉一半。
    final gap = profile.fontSize * 0.34;
    final mirrorTop = bottom + gap;
    final mirrorH = math.max(6.0, lineH);
    final mirrorRect = Rect.fromLTWH(0, mirrorTop, size.width, mirrorH);
    canvas.saveLayer(mirrorRect, Paint());
    canvas.save();
    canvas.translate(0, 2 * bottom + gap);
    canvas.scale(1.0, -1.0);
    for (var i = 0; i < n; i++) {
      _drawGlyph(
        canvas,
        i,
        color: _toneOf(i, fill),
        alpha: 0.5,
        dy: dyOf(i),
        scale: 0.94,
      );
    }
    canvas.restore();
    canvas.drawRect(
      mirrorRect,
      Paint()
        ..blendMode = BlendMode.dstIn
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Colors.white.withValues(alpha: 0.85),
            Colors.white.withValues(alpha: 0.0),
          ],
        ).createShader(mirrorRect),
    );
    canvas.restore();

    // 2) 水面波光：倒影上缘两道横向细光，暗示水面。
    for (var k = 0; k < 2; k++) {
      final y = mirrorTop + 1.5 + k * 4.0;
      final w = size.width * (0.55 + 0.1 * k);
      final a = (0.10 - 0.03 * k) * (0.7 + 0.3 * math.sin(clock * 1.7 + k));
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH((size.width - w) / 2, y, w, 1.2),
          const Radius.circular(0.6),
        ),
        Paint()..color = playedColor.withValues(alpha: a.clamp(0.0, 1.0)),
      );
    }

    // 3) 正文字：逐字起伏 + 轻微斜摆，唱到的字带辉光。
    for (var i = 0; i < n; i++) {
      _drawGlyph(
        canvas,
        i,
        color: _toneOf(i, fill),
        alpha: _alphaOf(i, fill),
        glow: i == fill.index,
        dy: dyOf(i),
        rotZ: tiltOf(i),
        scale: i == fill.index
            ? 1.0 +
                  (charZoom - 1.0) *
                      math.sin(math.pi * fill.fraction.clamp(0.0, 1.0))
            : 1.0,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _MotionLinePainter old) =>
      old.position != position ||
      old.clock != clock ||
      old.style != style ||
      old.profile.fontSize != profile.fontSize ||
      old.playedColor != playedColor ||
      old.currentColor != currentColor;
}

// ── 单行歌词扫过（播放页 mode 1 复用） ──────────────────────────────────

/// 单行歌词的逐字扫过（播放页「单行显示」模式复用）。
///
/// 与 [LyricsViewWidget] 同一套时间线与裁剪绘制，但只画当前行，
/// 并按 [style] 取辉光参数（字号封顶，适配紧凑单行槽位）。
class SingleLineLyricSweep extends StatefulWidget {
  final List<LyricLine> lyrics;
  final Duration position;
  final Color accentColor;
  final LyricAnimationStyle style;
  final bool isPlaying;

  const SingleLineLyricSweep({
    super.key,
    required this.lyrics,
    required this.position,
    required this.accentColor,
    this.style = LyricAnimationStyle.classic,
    this.isPlaying = true,
  });

  @override
  State<SingleLineLyricSweep> createState() => _SingleLineLyricSweepState();
}

class _SingleLineLyricSweepState extends State<SingleLineLyricSweep>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  late Duration _lastPos;
  late DateTime _lastWall;
  late Duration _lastRendered;
  _MeasuredLine? _measured;
  double _measuredWidth = -1;
  String _measuredSig = '';
  LyricLineTimeline? _timeline;

  // ── 单行槽位的 PV / ECHO 即时特效（唱到每个新字触发） ────────────────
  final math.Random _fxRng = math.Random();
  final List<_PvSparkle> _fxSparkles = [];
  final List<_EchoFragment> _fxFragments = [];
  int _fxCharIndex = -1;
  DateTime? _fxLastFrame;
  final Map<String, _EchoPicture> _fxEchoPictures = {};
  String _fxEchoSig = '';

  // ── 混合模式：逐句风格计划（一次性排定，整首歌内只读） ─────────────
  List<LyricAnimationStyle> _fxPlan = const [];
  String _fxPlanSig = '';

  /// 当前行索引 / 进入时间 / 淡入进度：换行时歌词淡入并轻微上移，
  /// 与 PV「特效 → 整句」的过渡感保持一致（240ms）。
  int _lineIndex = -1;
  DateTime _lineEnteredAt = DateTime.now();
  double _enterT = 1;

  /// 句级运动用的墙钟秒数（呼吸 / 漂浮 / 摆动），只在 tick 真的推进时累加，
  /// 暂停时静止。列表侧的同名物是 `_LyricsViewWidgetState._pvClock`。
  double _fxClock = 0;
  DateTime? _fxFrameAt;

  bool _fxActive() => _fxSparkles.isNotEmpty || _fxFragments.isNotEmpty;

  @override
  void initState() {
    super.initState();
    _lastPos = widget.position;
    _lastWall = DateTime.now();
    _lastRendered = widget.position;
    // ⚠️ 必须在这里初始化：_onTick 里要拿它算帧间隔。此前只在 tick 内部赋值，
    // 首帧读到的是 null ⇒ 空断言抛异常 ⇒ Ticker._tick 里的 scheduleTick 被跳过
    // ⇒ ticker 永久停摆。表现就是单行模式切风格后「瞬间出现又消失 / 直接不
    // 显示歌词」（停摆时 _enterT 可能停在 0，整行一直透明）。
    _fxFrameAt = DateTime.now();
    _ticker = Ticker(_onTick);
    _ticker.start();
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  // ── 混合模式：逐句风格（每句随机一种，整首固定） ────────────────────

  /// 与列表视图 [_LyricsViewWidgetState._ensureMixedPlan] 同策略：
  /// 只在歌词表变化时重排，避免每次换行重掷导致的重排 / 字号跳变。
  void _ensureFxPlan() {
    if (widget.style != LyricAnimationStyle.mixed) {
      if (_fxPlanSig.isNotEmpty) {
        _fxPlan = const [];
        _fxPlanSig = '';
      }
      return;
    }
    final lines = widget.lyrics;
    final sig = lines.isEmpty
        ? '0'
        : '${lines.length}|${lines.first.text}|${lines.last.text}';
    if (sig == _fxPlanSig) return;
    _fxPlanSig = sig;
    _fxPlan = buildMixedStylePlan(lines.length, _fxRng);
    // 逐句字号可能变 ⇒ 强制下一次 measure 重测。
    _measuredSig = '';
  }

  /// 第 [index] 句实际采用的风格（仅混合模式逐句不同）。
  LyricAnimationStyle _styleForLine(int index) {
    if (widget.style != LyricAnimationStyle.mixed) return widget.style;
    if (index < 0 || index >= _fxPlan.length) return widget.style;
    return _fxPlan[index];
  }

  void _onTick(Duration elapsed) {
    if (!mounted || widget.lyrics.isEmpty) return;
    _ensureFxPlan();
    final pos = _interpolatedPosition();
    // 换行淡入：进入新行即开始 240ms 淡入 + 上移。
    final idx = LyricParser.findCurrentLineIndex(widget.lyrics, pos);
    if (idx != _lineIndex) {
      _lineIndex = idx;
      _lineEnteredAt = DateTime.now();
      _enterT = 0;
    } else if (_enterT < 1) {
      final now = DateTime.now();
      final enteredMs = now.difference(_lineEnteredAt).inMilliseconds;
      _enterT = (enteredMs / 240).clamp(0, 1).toDouble();
    }
    // 暂停且进度未变时不必重绘；但 PV/ECHO 有未落幕的特效、或换行淡入
    // 尚未结束时继续驱动。
    if (!widget.isPlaying &&
        pos == _lastRendered &&
        !_fxActive() &&
        _enterT >= 1) {
      return;
    }
    _lastRendered = pos;
    // 句级运动的墙钟：只在播放中推进，暂停时整句连同运动一起静止。
    if (widget.isPlaying) {
      final now = DateTime.now();
      final lastFrame = _fxFrameAt;
      if (lastFrame != null) {
        final stepSec = now.difference(lastFrame).inMicroseconds / 1e6;
        _fxClock += math.min(0.05, math.max(0.0, stepSec));
      }
      _fxFrameAt = now;
    }
    _updateFx(pos);
    setState(() {});
  }

  Duration _interpolatedPosition() {
    if (!widget.isPlaying) return widget.position;
    final elapsed = DateTime.now().difference(_lastWall);
    var est = _lastPos + elapsed;
    final idx = LyricParser.findCurrentLineIndex(
      widget.lyrics,
      widget.position,
    );
    if (idx >= 0 && idx < widget.lyrics.length) {
      final end = lineEndForIndex(widget.lyrics, idx);
      if (est > end) est = end;
    }
    if (est < _lastPos) est = _lastPos;
    return est;
  }

  @override
  void didUpdateWidget(covariant SingleLineLyricSweep oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.position != widget.position) {
      _lastPos = widget.position;
      _lastWall = DateTime.now();
    }
    // 切歌：清掉上一首的特效与基线，避免按旧行索引补放。
    if (oldWidget.lyrics.length != widget.lyrics.length ||
        oldWidget.lyrics != widget.lyrics) {
      _fxCharIndex = -1;
      _fxSparkles.clear();
      _fxFragments.clear();
      // 新歌首行同样走换行淡入。
      _lineIndex = -1;
      _lineEnteredAt = DateTime.now();
      _enterT = 0;
    }
    // 切换风格：清掉旧风格残留特效、强制重测（mixed 与其他风格互切
    // 时特效族与字号都可能变化）。
    if (oldWidget.style != widget.style) {
      _fxCharIndex = -1;
      _fxSparkles.clear();
      _fxFragments.clear();
      _measuredSig = '';
    }
  }

  /// 当前句的风格（混合模式下逐句不同，其余风格恒为 [SingleLineLyricSweep.style]）。
  LyricAnimationStyle get _currentStyle => _styleForLine(_lineIndex);

  _StyleProfile _profile() => _profileFor(_currentStyle);

  _StyleProfile _profileFor(LyricAnimationStyle style) {
    // 单行槽位紧凑（44dp）：按风格给不同的字号 / 辉光 / 弹放参数，
    // 与 LyricsViewWidget 的风格语言保持一致（经典无辉光强放大 /
    // 辉光轻放大 / 巨幕大字 / PV 特粗 + 唱字闪点 / 回声碎片）。
    // ⚠️ 必须按传入的 [style] 分支（而不是 widget.style）：混合模式下每句的
    // 风格由逐句计划给出，这里要的就是那一份，否则所有句都挤到 mixed 兜底。
    switch (style) {
      case LyricAnimationStyle.typewriter:
        return const _StyleProfile(
          fontSize: 16.0,
          lineHeight: 1.3,
          glowNear: 0.0,
          glowFar: 0.0,
          rowGap: 0,
          charZoom: 1.0,
          typewriter: true,
        );
      case LyricAnimationStyle.meteor:
        // 流星坠落：单行槽位矮，字号略收一档给下坠尾迹留余量。
        return const _StyleProfile(
          fontSize: 17.5,
          lineHeight: 1.3,
          glowNear: 8.0,
          glowFar: 18.0,
          rowGap: 0,
          weight: FontWeight.w700,
          charZoom: 1.0,
        );
      case LyricAnimationStyle.pv:
        // PV：特粗字重 + 辉光（弹放交给唱字四芒闪点，见 _SingleLineFxPainter）。
        return const _StyleProfile(
          fontSize: 17.5,
          lineHeight: 1.25,
          glowNear: 9.0,
          glowFar: 22.0,
          rowGap: 0,
          weight: FontWeight.w800,
        );
      case LyricAnimationStyle.echo:
        return const _StyleProfile(
          fontSize: 16.0,
          lineHeight: 1.3,
          glowNear: 0.0,
          glowFar: 0.0,
          rowGap: 0,
          charZoom: 1.14,
        );
      case LyricAnimationStyle.drop:
        return const _StyleProfile(
          fontSize: 17.5,
          lineHeight: 1.3,
          glowNear: 8.0,
          glowFar: 18.0,
          rowGap: 0,
          weight: FontWeight.w700,
          charZoom: 1.06,
        );
      case LyricAnimationStyle.burst:
        return const _StyleProfile(
          fontSize: 17.0,
          lineHeight: 1.3,
          glowNear: 8.0,
          glowFar: 18.0,
          rowGap: 0,
          weight: FontWeight.w700,
          charZoom: 1.06,
        );
      case LyricAnimationStyle.cube:
        return const _StyleProfile(
          fontSize: 17.5,
          lineHeight: 1.28,
          glowNear: 8.0,
          glowFar: 20.0,
          rowGap: 0,
          weight: FontWeight.w700,
          charZoom: 1.05,
        );
      case LyricAnimationStyle.punch:
        return const _StyleProfile(
          fontSize: 17.0,
          lineHeight: 1.3,
          glowNear: 8.0,
          glowFar: 20.0,
          rowGap: 0,
          weight: FontWeight.w700,
          charZoom: 1.0,
        );
      case LyricAnimationStyle.wave:
        return const _StyleProfile(
          fontSize: 17.5,
          lineHeight: 1.3,
          glowNear: 8.0,
          glowFar: 18.0,
          rowGap: 0,
          weight: FontWeight.w600,
          charZoom: 1.10,
        );
      case LyricAnimationStyle.classic:
        return const _StyleProfile(
          fontSize: 15.5,
          lineHeight: 1.3,
          glowNear: 0,
          glowFar: 0,
          rowGap: 0,
          charZoom: 1.30,
        );
      case LyricAnimationStyle.mixed:
        // 混合模式自身的排版：仅作兜底（计划未生成 / 索引越界），
        // 正常渲染时每句都会解析成池中的某一种具体风格。
        return const _StyleProfile(
          fontSize: 16.5,
          lineHeight: 1.3,
          glowNear: 6.0,
          glowFar: 14.0,
          rowGap: 0,
          charZoom: 1.18,
        );
    }
  }

  Color? get _unplayedOverride => PreferencesService.getLyricColorUnplayed();
  Color? get _currentOverride => PreferencesService.getLyricColorCurrent();
  Color? get _playedOverride => PreferencesService.getLyricColorPlayed();

  /// 未播放（未唱到的歌词），默认白。
  Color get _baseColor => _unplayedOverride ?? kLyricColorUnplayedDefault;

  /// 已播放（已唱过的歌词），默认绿。
  Color get _playedColor => _playedOverride ?? kLyricColorPlayedDefault;

  /// 当前播放（正在演唱的字），默认黄绿。
  Color get _currentColor => _currentOverride ?? kLyricColorCurrentDefault;

  TextStyle _baseTextStyle(_StyleProfile p) => TextStyle(
    fontSize: p.fontSize,
    fontWeight: p.weight,
    color: _baseColor.withValues(alpha: 0.45),
    height: p.lineHeight,
  );

  TextStyle _highlightTextStyle(_StyleProfile p) {
    final shadows = p.glowFar > 0
        ? <Shadow>[
            Shadow(
              color: _playedColor.withValues(alpha: 0.5),
              blurRadius: p.glowNear,
            ),
            Shadow(
              color: _playedColor.withValues(alpha: 0.3),
              blurRadius: p.glowFar,
            ),
          ]
        : null;
    return TextStyle(
      fontSize: p.fontSize,
      fontWeight: p.weight,
      color: _playedColor,
      height: p.lineHeight,
      shadows: shadows,
    );
  }

  /// 当前字样式（弹放放大的那个字）：「当前播放」色 + 辉光。
  TextStyle _currentTextStyle(_StyleProfile p) {
    final shadows = p.glowFar > 0
        ? <Shadow>[
            Shadow(
              color: _currentColor.withValues(alpha: 0.5),
              blurRadius: p.glowNear,
            ),
            Shadow(
              color: _currentColor.withValues(alpha: 0.3),
              blurRadius: p.glowFar,
            ),
          ]
        : null;
    return TextStyle(
      fontSize: p.fontSize,
      fontWeight: p.weight,
      color: _currentColor,
      height: p.lineHeight,
      shadows: shadows,
    );
  }

  // ── 当前字 painter 缓存 ─────────────────────────────────────────────
  final Map<String, TextPainter> _zoomGlyphCache = {};
  String _zoomGlyphSig = '';

  /// 逐字重绘风格（meteor / drop~wave）用的字形缓存（见 [_MotionLinePainter]）。
  final _GlyphTextCache _motionGlyphs = _GlyphTextCache();

  TextPainter _zoomGlyphPainter(String ch, _StyleProfile p) {
    final sig =
        '${p.fontSize}|${p.weight}|${_playedColor.toARGB32()}|${_currentColor.toARGB32()}';
    if (_zoomGlyphSig != sig) {
      _zoomGlyphCache.clear();
      _zoomGlyphSig = sig;
    }
    var tp = _zoomGlyphCache[ch];
    if (tp == null) {
      tp = TextPainter(
        text: TextSpan(text: ch, style: _currentTextStyle(p)),
        textDirection: TextDirection.ltr,
      )..layout();
      if (_zoomGlyphCache.length > 100) _zoomGlyphCache.clear();
      _zoomGlyphCache[ch] = tp;
    }
    return tp;
  }

  _MeasuredLine _measure(double maxWidth, LyricAnimationStyle style) {
    final p = _profileFor(style);
    final sig =
        '${_baseColor.toARGB32()}-${_playedColor.toARGB32()}-${_currentColor.toARGB32()}-${style.name}';
    final text = _timeline!.text;
    if (_measured != null &&
        _measuredSig == sig &&
        _measured!.text == text &&
        (_measuredWidth - maxWidth).abs() < 0.5) {
      return _measured!;
    }
    final base = TextPainter(
      text: TextSpan(text: text, style: _baseTextStyle(p)),
      textAlign: TextAlign.center,
      textDirection: TextDirection.ltr,
      maxLines: 1,
      ellipsis: '…',
    )..layout(maxWidth: math.max(1.0, maxWidth));
    final highlight = TextPainter(
      text: TextSpan(text: text, style: _highlightTextStyle(p)),
      textAlign: TextAlign.center,
      textDirection: TextDirection.ltr,
      maxLines: 1,
      ellipsis: '…',
    )..layout(maxWidth: math.max(1.0, maxWidth));

    final metrics = base.computeLineMetrics();
    final lineTops = <double>[0.0];
    final lineBottoms = <double>[metrics.first.height];
    final offsets = _timeline!.utf16BoundaryOffsets;
    final boundaries = <_Boundary>[];
    double lastX = 0;
    for (var i = 0; i < offsets.length; i++) {
      final off = offsets[i];
      // 非零宽 selection（零宽在本 SDK 返回空盒，详见主视图 _measureLine）。
      if (i + 1 < offsets.length) {
        final boxes = base.getBoxesForSelection(
          TextSelection(baseOffset: off, extentOffset: offsets[i + 1]),
        );
        if (boxes.isNotEmpty) lastX = boxes.first.left;
      } else if (off > 0) {
        final boxes = base.getBoxesForSelection(
          TextSelection(baseOffset: offsets[i - 1], extentOffset: off),
        );
        if (boxes.isNotEmpty) lastX = boxes.last.right;
      }
      boundaries.add(_Boundary(lastX, 0));
    }

    final m = _MeasuredLine(
      text: text,
      colorSig: sig,
      base: base,
      highlight: highlight,
      metrics: metrics,
      lineTops: lineTops,
      lineBottoms: lineBottoms,
      boundaries: boundaries,
      originX: math.max(0.0, (maxWidth - base.width) / 2),
    );
    _measured = m;
    _measuredSig = sig;
    _measuredWidth = maxWidth;
    return m;
  }

  // ── PV / ECHO 即时特效（单行槽位） ────────────────────────────────────

  /// 唱到每个新字即在其位置触发特效（PV 四芒闪点 / ECHO 空心字碎片），
  /// seek 跳跃时一次性补齐已扫过的字；暂停时只让存量特效落幕。
  void _updateFx(Duration pos) {
    final now = DateTime.now();
    final dt = _fxLastFrame == null
        ? 0.0
        : (now.difference(_fxLastFrame!).inMicroseconds / 1e6).clamp(0.0, 0.05);
    _fxLastFrame = now;

    for (final s in _fxSparkles) {
      s.age += dt;
    }
    _fxSparkles.removeWhere((s) => s.age >= _kPvSparkleLife);
    for (final f in _fxFragments) {
      f.pos += f.vel * dt;
      f.vel += Offset(math.sin(f.age * 2.2 + f.phase) * 26 * dt, -14 * dt);
      f.rot += f.rotVel * dt;
      f.age += dt;
    }
    _fxFragments.removeWhere((f) => f.age >= f.life);

    final timeline = _timeline;
    if (timeline == null || timeline.isEmpty) return;
    if (!widget.isPlaying) return;
    final fill = graphemeFillAt(timeline, pos);
    if (fill.index < 0) {
      // 本行尚未开口：清掉可能属于上一行的残留特效。
      _fxCharIndex = -1;
      _fxSparkles.clear();
      _fxFragments.clear();
      return;
    }
    // 换行 / seek 回退：重置基线，并清空旧行残留特效——
    // 单行槽位的闪点/碎片只归属当前播放行。
    if (fill.index < _fxCharIndex) {
      _fxCharIndex = fill.index;
      _fxSparkles.clear();
      _fxFragments.clear();
      return;
    }
    if (fill.index == _fxCharIndex) return;
    for (var i = math.max(0, _fxCharIndex); i < fill.index; i++) {
      if (i >= timeline.graphemes.length) break;
      final p = _fxGlyphPos(i);
      if (p == null) continue;
      // 混合模式按当前句抽到的风格只跑对应那一套（见调用的计划排定）。
      final lineStyle = _styleForLine(_lineIndex);
      if (lineStyle == LyricAnimationStyle.pv) {
        if (_fxSparkles.length < 8) _fxSparkles.add(_PvSparkle(p));
      }
      if (lineStyle == LyricAnimationStyle.echo) {
        if (_fxFragments.length >= 28) _fxFragments.removeAt(0);
        _fxFragments.add(
          _EchoFragment(
            char: timeline.graphemes[i].char,
            pos: p,
            vel: Offset(
              (_fxRng.nextDouble() - 0.5) * 50,
              -30 - _fxRng.nextDouble() * 50,
            ),
            rot: (_fxRng.nextDouble() - 0.5) * 0.6,
            rotVel: (_fxRng.nextDouble() - 0.5) * 1.4,
            scale: 1.6 + _fxRng.nextDouble() * 1.2,
            life: 1.6 + _fxRng.nextDouble() * 3.0,
            phase: _fxRng.nextDouble() * math.pi * 2,
          ),
        );
      }
    }
    _fxCharIndex = fill.index;
  }

  /// 第 i 个字在单行 CustomPaint 画布上的中心点（供特效定位）。
  Offset? _fxGlyphPos(int i) {
    final measured = _measured;
    if (measured == null || _timeline == null) return null;
    if (i < 0 || i + 1 >= measured.boundaries.length) return null;
    final b = measured.boundaries[i];
    final b2 = measured.boundaries[i + 1];
    // CustomPaint 高度 = base.height + _kSingleLineCanvasPad，绘制器内
    // dy = (size.height - base.height) / 2 = _kSingleLineCanvasPad / 2。
    final dy = _kSingleLineCanvasPad / 2;
    final cx = measured.originX + (b.x + b2.x) / 2;
    final cy =
        dy +
        measured.lineTops[b.line] +
        (measured.lineBottoms[b.line] - measured.lineTops[b.line]) / 2;
    return Offset(cx, cy);
  }

  /// 空心字碎片渲染（描边文字 Picture，按 字符 / 字号 / 透明度 分桶缓存）。
  _EchoPicture _fxEchoPicture(String ch, double fontSize, double alpha) {
    final sizeBucket = (fontSize * 2).round() / 2;
    final bucket = _LyricsViewWidgetState._alphaBucket(alpha);
    final key = '$ch|$sizeBucket|$bucket';
    final sig = '${_playedColor.toARGB32()}';
    if (_fxEchoSig != sig) {
      _fxEchoPictures.clear();
      _fxEchoSig = sig;
    }
    final cached = _fxEchoPictures[key];
    if (cached != null) return cached;
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    final tp = TextPainter(
      text: TextSpan(
        text: ch,
        style: TextStyle(
          fontSize: sizeBucket,
          fontWeight: _profile().weight,
          foreground: Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = math.max(1.2, sizeBucket * 0.045)
            ..color = _playedColor.withValues(alpha: 0.55 * bucket),
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, Offset.zero);
    final pic = _EchoPicture(recorder.endRecording(), tp.width, tp.height);
    if (_fxEchoPictures.length > 64) _fxEchoPictures.clear();
    _fxEchoPictures[key] = pic;
    return pic;
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final maxWidth = math.max(1.0, constraints.maxWidth - _kHPadding * 2);
        _ensureFxPlan();
        final pos = _interpolatedPosition();
        final idx = LyricParser.findCurrentLineIndex(widget.lyrics, pos);
        LyricLineTimeline? timeline;
        if (idx >= 0 && idx < widget.lyrics.length) {
          timeline = buildLineTimeline(
            widget.lyrics[idx],
            lineEndForIndex(widget.lyrics, idx),
          );
        }
        _timeline = timeline;
        if (timeline == null || timeline.isEmpty) {
          return Center(
            child: Text(
              '♪',
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: _baseColor.withValues(alpha: 0.45),
              ),
            ),
          );
        }
        final lineStyle = _styleForLine(idx);
        final measured = _measure(maxWidth, lineStyle);
        // 当前唱到的字弹放放大（普通 LRC 均分时间线同样逐字生效）。
        final p = _profileFor(lineStyle);
        final fill = graphemeFillAt(timeline, pos);
        var charZoom = 1.0;
        TextPainter? zoomGlyph;
        if (p.charZoom > 1.0 &&
            fill.index >= 0 &&
            fill.index < timeline.graphemes.length) {
          charZoom = p.charZoom;
          zoomGlyph = _zoomGlyphPainter(timeline.graphemes[fill.index].char, p);
        }
        final sweep = CustomPaint(
          // +_kSingleLineCanvasPad：给弹放的当前字留出上下不被裁剪的余量。
          size: Size(maxWidth, measured.base.height + _kSingleLineCanvasPad),
          // 逐字重绘风格在单行槽位同样走逐字重绘（与列表视图同一套实现）。
          // 否则单行模式切到这些风格会退回「整行 + Transform」的旧观感。
          painter: _isMotionStyle(lineStyle)
              ? _MotionLinePainter(
                  measured: measured,
                  profile: p,
                  style: lineStyle,
                  timeline: timeline,
                  position: pos,
                  clock: _fxClock,
                  baseColor: _baseColor,
                  playedColor: _playedColor,
                  currentColor: _currentColor,
                  glyphs: _motionGlyphs,
                  charZoom: p.charZoom,
                )
              : _SweepPainter(
                  base: measured.base,
                  highlight: measured.highlight,
                  metrics: measured.metrics,
                  lineTops: measured.lineTops,
                  lineBottoms: measured.lineBottoms,
                  boundaries: measured.boundaries,
                  timeline: timeline,
                  position: pos,
                  charZoom: charZoom,
                  zoomGlyph: zoomGlyph,
                  originX: measured.originX,
                  typewriter: p.typewriter,
                  cursorColor: _currentColor,
                ),
        );
        // PV / ECHO：唱字即时特效铺在歌词上层（与主视图一致的层级）。
        // 换行淡入 + 轻微上移：从无到有过渡，而非整行硬切。
        Widget textLayer = sweep;
        if (_enterT < 1) {
          // 下限 0.15：换行淡入本身只有 240ms，正常看不出差别；但如果 ticker
          // 因任何原因停摆（例如上一版首帧空断言），_enterT 会永远停在 0，
          // 整行就是全透明的——这里兜一层，绝不让歌词「直接不显示」。
          textLayer = Opacity(
            opacity: math.max(0.15, _enterT),
            child: Transform.translate(
              offset: Offset(0, 6 * (1 - _enterT)),
              child: sweep,
            ),
          );
        }
        if (widget.style != LyricAnimationStyle.pv &&
            widget.style != LyricAnimationStyle.echo &&
            widget.style != LyricAnimationStyle.mixed) {
          return textLayer;
        }
        // 特效层向上突破单行槽位（负 top + Clip.none）：唱字四芒闪点与
        // 空心字碎片可以穿过上方封面卡片显示，而非被裁在 44dp 槽位里。
        return Stack(
          clipBehavior: Clip.none,
          children: [
            textLayer,
            Positioned(
              left: 0,
              right: 0,
              top: -_kSingleLineFxCross,
              height:
                  measured.base.height +
                  _kSingleLineCanvasPad +
                  _kSingleLineFxCross,
              child: IgnorePointer(
                child: CustomPaint(painter: _SingleLineFxPainter(this)),
              ),
            ),
          ],
        );
      },
    );
  }
}

/// 单行歌词的 PV / ECHO 即时特效层（铺在扫过歌词上层）：
/// PV = 唱字四芒闪点；ECHO = 唱字炸出的空心字碎片漂移；
/// 混合模式 = 当前句抽到哪套就画哪套（先碎片后闪点，闪点压在最上层）。
class _SingleLineFxPainter extends CustomPainter {
  final _SingleLineLyricSweepState state;
  const _SingleLineFxPainter(this.state);

  @override
  void paint(Canvas canvas, Size size) {
    // 特效画布向上扩展了 _kSingleLineFxCross（负 top Positioned）：其原点
    // 位于槽位顶上方 cross 处。先把坐标系搬回槽位顶，_fxGlyphPos 等
    // 槽位坐标即可原样使用；越界部分自然画进上方封面卡片区域。
    canvas.translate(0, _kSingleLineFxCross);
    // 混合模式：按当前句抽到的风格决定画哪一套（此处不会是 mixed 本身）。
    final style = state._styleForLine(state._lineIndex);
    if (style == LyricAnimationStyle.echo) {
      for (final f in state._fxFragments) {
        final k = f.age / f.life;
        final alpha = (1 - k) * (1 - k);
        if (alpha <= 0.02) continue;
        final pic = state._fxEchoPicture(
          f.char,
          state._profile().fontSize * f.scale,
          alpha * 0.85,
        );
        canvas.save();
        canvas.translate(f.pos.dx, f.pos.dy);
        canvas.rotate(f.rot);
        canvas.scale(1.0 - 0.3 * k);
        canvas.translate(-pic.width / 2, -pic.height / 2);
        canvas.drawPicture(pic.picture);
        canvas.restore();
      }
    }
    if (style == LyricAnimationStyle.pv) {
      final grow = 9.0;
      final base = 5.0;
      for (final s in state._fxSparkles) {
        final k = s.age / _kPvSparkleLife;
        final r = base + grow * k;
        final a = (1 - k).clamp(0.0, 1.0);
        if (a <= 0.02) continue;
        _drawPvStar(canvas, s.pos, r, a, state._currentColor);
      }
    }
  }

  @override
  bool shouldRepaint(covariant _SingleLineFxPainter old) => true;
}
