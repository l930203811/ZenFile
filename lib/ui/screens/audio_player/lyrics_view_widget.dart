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
}

/// 动态歌词显示组件（借鉴 folia「Monet 逐字扫过」观感，纯 Flutter 内置能力实现）。
///
/// 特性：
/// - 逐字/亚词级平滑扫过：整行先画中性色，再按当前进度把已唱部分裁剪成强调色，
///   支持自动换行（多视觉行按行裁剪）。
/// - 距离衰减 tone：当前行全亮 + 强调色，邻近行按距离降低不透明度并缩小。
/// - 弹簧滚动：当前行切换时用弹簧曲线平滑滚到视口中央。
/// - 进度插值：position 流非帧率，[isPlaying] 为真时按墙钟插值，得到丝滑扫过。
/// - 多动画风格（[style]）：classic / glow / immersive / pv / echo / mixed。
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
  _StyleProfile _profileForLine(int index) =>
      _profileForStyle(_styleForLine(index), _lastViewportH);

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

    if (_currentLineIndex != _pvPrevLine) {
      _onLineSwitched(_pvPrevLine, _currentLineIndex);
      _pvPrevLine = _currentLineIndex;
    }

    switch (widget.style) {
      case LyricAnimationStyle.pv:
        _pvClock += dt;
        final revealT = (_pvClock - _pvRevealStart) / _pvRevealDur;
        _pvRevealT = revealT.clamp(0.0, 1.0);
        _updatePv(pos, dt);
      case LyricAnimationStyle.echo:
        _updateEcho(pos, dt);
      case LyricAnimationStyle.mixed:
        // 混合模式：当前句抽到哪种风格，就跑哪一套动效——PV 句走唱字
        // 闪点 + 云室径迹，ECHO 句走空心字碎片，其余风格只保留自身观感。
        // 未跑的那一路仍要继续老化时才有可能落幕，否则 _animationsActive()
        // 恒为真 ⇒ 暂停后仍逐帧重绘。
        _pvClock += dt;
        switch (_styleForLine(_currentLineIndex)) {
          case LyricAnimationStyle.pv:
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
    if (widget.style == LyricAnimationStyle.pv) {
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
    if (widget.style != LyricAnimationStyle.pv) {
      // 列表视图（含混合模式的 PV 句）走列表，字位置必须按列表项换算；
      // 只有纯 PV 风格才是「整句居中」的独立布局，可直接用 measurement。
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
    if (widget.style != LyricAnimationStyle.pv) {
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
      if (_currentLineIndex != oldLineIndex && !_isUserScrolling) {
        WidgetsBinding.instance.addPostFrameCallback(
          (_) => _scrollToCurrentLine(),
        );
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
    if (!_scrollController.hasClients ||
        _currentLineIndex < 0 ||
        _currentLineIndex >= _itemKeys.length) {
      return;
    }
    final context = _itemKeys[_currentLineIndex].currentContext;
    final box = context?.findRenderObject() as RenderBox?;
    if (context == null || box == null) {
      // 首帧或懒加载：当前行尚未渲染出 RenderBox，先用固定行高估算粗定位，
      // 下一帧列表把该行构建出来后再用真实坐标精校；重试有限次，避免死循环。
      _scrollToEstimated(animate: false);
      if (_scrollRetries < 4) {
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
    final viewportHeight = _scrollController.position.viewportDimension;
    final targetOffset =
        _scrollController.offset +
        itemOffset -
        (viewportHeight / 2) +
        (itemHeight / 2);
    final clampedOffset = targetOffset.clamp(
      0.0,
      _scrollController.position.maxScrollExtent,
    );

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

  void _scrollToEstimated({bool animate = true}) {
    if (!_scrollController.hasClients || _currentLineIndex < 0) return;
    const estimatedLineHeight = 56.0;
    final viewportHeight = _scrollController.position.viewportDimension;
    final targetOffset =
        (_currentLineIndex * estimatedLineHeight) -
        (viewportHeight / 2) +
        (estimatedLineHeight / 2);
    final clampedOffset = targetOffset.clamp(
      0.0,
      _scrollController.position.maxScrollExtent,
    );
    if (animate) {
      _scrollController.animateTo(
        clampedOffset,
        duration: const Duration(milliseconds: 320),
        curve: Curves.easeOutCubic,
      );
    } else {
      _scrollController.jumpTo(clampedOffset);
    }
  }

  // ── 风格与排版 ────────────────────────────────────────────────────────

  /// 按风格与视口高度解析视觉参数（immersive / pv 的巨字随视口自适应）。
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
      case LyricAnimationStyle.immersive:
        // 巨字：随视口高度伸缩并封顶，模拟 folia Lattice 的 24~64px 预算策略。
        final size = (viewportHeight / 13).clamp(26.0, 44.0);
        return _StyleProfile(
          fontSize: size,
          lineHeight: 1.28,
          glowNear: 14.0,
          glowFar: 34.0,
          rowGap: 10.0,
          charZoom: 1.08,
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

  /// 混合模式单句舞台：整列只画当前播放句并居中（已播/待播不渲染），
  /// 换行时用随机入场动效淡入，视觉风格仍由 [_mixedPlan] 逐句决定。
  Widget _buildMixedStage(
    BoxConstraints constraints,
    double maxWidth,
    double viewportHeight,
  ) {
    _lastMaxWidth = maxWidth;
    _lastViewportH = viewportHeight;
    final idx = _currentLineIndex;
    if (idx >= 0 && idx < widget.lyrics.length) {
      _lastProfile = _profileForStyle(_styleForLine(idx), viewportHeight);
    }

    Widget body = const SizedBox.shrink();
    if (idx >= 0 && idx < widget.lyrics.length) {
      body = KeyedSubtree(
        key: ValueKey<int>(idx),
        child: _buildLineItem(idx, maxWidth),
      );
    }

    final stage = Center(
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 320),
        switchInCurve: Curves.easeOutCubic,
        transitionBuilder: _mixedEnterTransition,
        child: body,
      ),
    );

    return Stack(
      children: [
        stage,
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
    final profile = _profileForStyle(lineStyle, _lastViewportH);
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
        painter: _SweepPainter(
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

  bool _fxActive() => _fxSparkles.isNotEmpty || _fxFragments.isNotEmpty;

  @override
  void initState() {
    super.initState();
    _lastPos = widget.position;
    _lastWall = DateTime.now();
    _lastRendered = widget.position;
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
    switch (widget.style) {
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
      case LyricAnimationStyle.immersive:
        return const _StyleProfile(
          fontSize: 18.5,
          lineHeight: 1.25,
          glowNear: 10.0,
          glowFar: 24.0,
          rowGap: 0,
          charZoom: 1.08,
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
          painter: _SweepPainter(
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
          textLayer = Opacity(
            opacity: _enterT,
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
