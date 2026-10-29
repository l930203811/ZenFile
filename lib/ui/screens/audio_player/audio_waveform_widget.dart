import 'package:flutter/material.dart';
import '../../../services/audio_visualizer_service.dart';
import 'audio_spectrum_engine.dart';

/// 播放页可视化组件：**频谱区在上 + 细进度条在下**。
///
/// * 频谱区（高 [_zoneHeight]）：visualizer 可用且播放中 → 真实频谱
///   （audioMotion 风格：对数频率刻度、底部锚定的音量渐变柱、悬浮峰值帽、
///   底部倒影）。**伪波形已移除**——无频谱数据（未播放/机型不支持/会话
///   不可用）时频谱区留空，保持布局高度稳定。频谱区**纯展示**，不承载手势。
/// * 进度条（高 20，细条 5px）：唯一承载 seek 手势（点击/拖动），
///   快按/慢按/长按/拖动走同一条 Listener 路径（见 [_seekPointerId] 注释）；
///   其下两侧分别显示当前进度与总时长。
class AudioWaveformWidget extends StatefulWidget {
  final Duration position;
  final Duration duration;
  final bool isPlaying;
  final Color accentColor;
  final ValueChanged<Duration> onSeek;
  final VoidCallback? onSeekStart;

  /// 拖动/点击被取消（既没落成 tap 也没落成 pan）时回调。
  ///
  /// 必须提供：调用方用 [onSeekStart] 把「正在拖动」标志置真、在 onSeek 里
  /// 复位；一旦手势被取消，onSeek 永不触发，标志会**永久卡在真**，进度流被
  /// 全部丢弃 ⇒ 歌词/进度条从此不再更新。之前只处理了 tap 取消，pan 取消
  /// （手指滑出控件又被父级接管）没有出口。
  final VoidCallback? onSeekCancel;

  /// 频谱可视化数据源（Android Visualizer 的 FFT，见 AudioVisualizerService）。
  final AudioVisualizerService? visualizer;

  /// 是否显示频谱可视化（播放页三点菜单开关）。false 时频谱区不渲染
  /// （布局收起），数据源照常存在但不消费。
  final bool showSpectrum;

  /// 紧凑模式（横屏等矮视口）：频谱区/进度条整体收缩，保证右列
  /// 「标题 + 收藏 + 波形 + 播控」在横屏高度内放得下，不再溢出屏幕。
  final bool compact;

  const AudioWaveformWidget({
    super.key,
    required this.position,
    required this.duration,
    required this.isPlaying,
    required this.accentColor,
    required this.onSeek,
    this.onSeekStart,
    this.onSeekCancel,
    this.visualizer,
    this.showSpectrum = true,
    this.compact = false,
  });

  @override
  State<AudioWaveformWidget> createState() => _AudioWaveformWidgetState();
}

class _AudioWaveformWidgetState extends State<AudioWaveformWidget>
    with TickerProviderStateMixin {
  /// 频谱渲染节拍（~30fps）。只在播放 + 提供了 visualizer 时运转。
  late final AnimationController _specController;

  /// 频谱分桶 / 平滑引擎（visualizer 非空时创建，见 AudioSpectrumEngine）。
  AudioSpectrumEngine? _spectrum;
  final int _barCount = 56;
  double? _dragPercentage;
  double? _pendingPositionPercentage;
  DateTime? _pendingSetTime;

  // ── 布局几何（[AudioWaveformWidget.compact] 时整体收缩）──────────
  /// 频谱区总高：柱体向上生长到 [_baselineFromTop]，其下为倒影区。
  double get _zoneHeight => widget.compact ? 56 : 92;
  double get _barMax => widget.compact ? 34 : 60;
  double get _baselineFromTop => widget.compact ? 42 : 74;
  double get _trackHeight => widget.compact ? 12 : 16;

  /// 正在按压 / 拖动进度条的指针 id（只跟踪第一个按下的指针，避免多指互相打断）。
  ///
  /// 这里用 Listener 而不是 GestureDetector：后者若同时挂 tap 与 pan，两者会进
  /// 手势竞技场互相竞争 —— 慢点 / 长按时手指微动超过 touch slop，pan 抢占导致
  /// tap 被 cancel，而 cancel 回调会把共享的拖动值清空，抬起时无值可提交
  /// ⇒ 表现为「必须快按，慢按或长按进度条会弹回原点」。Listener 不参与竞技场，
  /// 快按 / 慢按 / 长按 / 拖动走同一条路径，行为一致。
  int? _seekPointerId;

  @override
  void initState() {
    super.initState();
    _specController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 33),
    );
    if (widget.visualizer != null) {
      _spectrum = AudioSpectrumEngine(barCount: _barCount);
    }
    if (widget.isPlaying) {
      _specController.repeat();
    }
  }

  @override
  void didUpdateWidget(AudioWaveformWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isPlaying && !oldWidget.isPlaying) {
      _specController.repeat();
    } else if (!widget.isPlaying && oldWidget.isPlaying) {
      _specController.stop();
    }
  }

  void _updateDragPercentage(Offset localPosition, double width) {
    if (width <= 0) return;
    setState(() {
      _dragPercentage = (localPosition.dx / width).clamp(0.0, 1.0);
      _pendingPositionPercentage = null;
    });
  }

  void _finalizeSeek(double safeDur) {
    if (_dragPercentage != null) {
      final targetMs = safeDur * _dragPercentage!;
      widget.onSeek(Duration(milliseconds: targetMs.toInt()));
      setState(() {
        _pendingPositionPercentage = _dragPercentage;
        _pendingSetTime = DateTime.now();
        _dragPercentage = null;
      });
    } else {
      // 没有落到有效拖动值时也必须给调用方一个出口，否则它那边置真的
      // 「正在拖动」标志会永久卡住，进度流被整段丢弃（见下方注释里的旧坑）。
      widget.onSeekCancel?.call();
    }
  }

  @override
  void dispose() {
    _specController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final safeDur = widget.duration.inMilliseconds > 0
        ? widget.duration.inMilliseconds.toDouble()
        : 1.0;

    if (_pendingPositionPercentage != null) {
      final targetMs = safeDur * _pendingPositionPercentage!;
      final diff = (widget.position.inMilliseconds - targetMs).abs();
      final elapsed = _pendingSetTime != null
          ? DateTime.now().difference(_pendingSetTime!).inMilliseconds
          : 1000;

      if (diff < 1200 || elapsed > 800) {
        _pendingPositionPercentage = null;
        _pendingSetTime = null;
      }
    }

    final percentage = _dragPercentage ??
        _pendingPositionPercentage ??
        (widget.position.inMilliseconds / safeDur).clamp(0.0, 1.0);

    final accent = widget.accentColor;

    // 进度条填充：水平强调色渐变。
    final trackFill = LinearGradient(
      colors: [accent, Color.lerp(accent, Colors.white, 0.35)!],
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        return AnimatedBuilder(
          animation: _specController,
          builder: (context, _) {
            final viz = widget.visualizer;
            final spectrumMode = widget.showSpectrum &&
                viz != null &&
                viz.available &&
                widget.isPlaying &&
                viz.fft.value != null;

            // ── 频谱区 ────────────────────────────────────────────
            // 伪波形已移除：无频谱数据（未播放/机型不支持/会话不可用）时
            // 频谱区留空，布局高度保持稳定。
            // 渲染 = 单个 CustomPainter：经典 LED 分段柱 + 按高度
            // 绿→黄→红渐变（见 _SpectrumPainter）。
            final Widget zone;
            if (spectrumMode) {
              final mag = viz.fft.value!;
              if (mag.length >= 4) {
                _spectrum!.update(
                    mag, viz.analysisFftSize, viz.analysisSampleRate);
              }
              zone = SizedBox(
                height: _zoneHeight,
                width: double.infinity,
                child: CustomPaint(
                  painter: _SpectrumPainter(
                    display: _spectrum!.display,
                    peaks: _spectrum!.peaks,
                    barCount: _barCount,
                    baseline: _baselineFromTop,
                    maxBar: _barMax,
                  ),
                ),
              );
            } else {
              // 开关关闭 → 整块收起（用户明确不要频谱）；只是暂时没数据
              // （未播放/挂载中）→ 保留高度，布局稳定不跳动。
              zone = widget.showSpectrum
                  ? SizedBox(height: _zoneHeight)
                  : const SizedBox.shrink();
            }

            // ── 进度条（唯一手势承载）──────────────────────────────
            final track = MouseRegion(
              cursor: SystemMouseCursors.click,
              child: Listener(
                behavior: HitTestBehavior.opaque,
                onPointerDown: (e) {
                  if (_seekPointerId != null) return;
                  _seekPointerId = e.pointer;
                  widget.onSeekStart?.call();
                  _updateDragPercentage(e.localPosition, constraints.maxWidth);
                },
                onPointerMove: (e) {
                  if (_seekPointerId != e.pointer) return;
                  _updateDragPercentage(e.localPosition, constraints.maxWidth);
                },
                onPointerUp: (e) {
                  if (_seekPointerId != e.pointer) return;
                  _seekPointerId = null;
                  _finalizeSeek(safeDur);
                },
                onPointerCancel: (e) {
                  if (_seekPointerId != e.pointer) return;
                  _seekPointerId = null;
                  setState(() {
                    _dragPercentage = null;
                  });
                  widget.onSeekCancel?.call();
                },
                child: SizedBox(
                  height: _trackHeight,
                  child: Center(
                    child: SizedBox(
                      height: 5,
                      width: constraints.maxWidth,
                      child: Stack(
                        clipBehavior: Clip.none,
                        children: [
                          // 轨道底
                          Positioned.fill(
                            child: DecoratedBox(
                              decoration: BoxDecoration(
                                color: theme.colorScheme.onSurface
                                    .withValues(alpha: 0.15),
                                borderRadius: BorderRadius.circular(3),
                              ),
                            ),
                          ),
                          // 已播放填充
                          Positioned.fill(
                            child: FractionallySizedBox(
                              widthFactor: percentage,
                              alignment: Alignment.centerLeft,
                              child: DecoratedBox(
                                decoration: BoxDecoration(
                                  gradient: trackFill,
                                  borderRadius: BorderRadius.circular(3),
                                ),
                              ),
                            ),
                          ),
                          // 拖动把手
                          Align(
                            alignment:
                                Alignment(percentage * 2 - 1, 0),
                            child: Container(
                              width: widget.compact ? 9 : 11,
                              height: widget.compact ? 9 : 11,
                              decoration: BoxDecoration(
                                color: Colors.white,
                                shape: BoxShape.circle,
                                border: Border.all(
                                  color: accent,
                                  width: 2,
                                ),
                                boxShadow: [
                                  BoxShadow(
                                    color: Colors.black
                                        .withValues(alpha: 0.25),
                                    blurRadius: 4,
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            );

            // ── 时间标注：当前进度在左、总时长在右 ────────────────
            // 拖动中即时显示拖动目标时间（松手后由 position 流接管）。
            String fmt(double ms) {
              final d = Duration(milliseconds: ms.round());
              final h = d.inHours;
              final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
              final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
              return h > 0 ? '$h:$m:$s' : '$m:$s';
            }

            final shownMs = _dragPercentage != null
                ? safeDur * _dragPercentage!
                : widget.position.inMilliseconds.toDouble();
            final timeStyle = theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onSurface.withValues(alpha: 0.55),
              fontFeatures: const [FontFeature.tabularFigures()],
            );
            final timeRow = Padding(
              padding: const EdgeInsets.only(top: 0),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(fmt(shownMs), style: timeStyle),
                  Text(fmt(safeDur), style: timeStyle),
                ],
              ),
            );

            return Column(
              children: [
                zone,
                // 进度条紧贴倒影区（去掉原 10px 间隔），时间行紧随其后。
                track,
                timeRow,
              ],
            );
          },
        );
      },
    );
  }
}

/// 经典 **LED 分段式频谱画笔**（VU 表配色，用户指定样式）。
///
/// * 每根柱由 5px 节距的 LED 小段堆叠（段高 3.5px + 1.5px 缝）；
/// * 颜色按**高度位置**渐变：底部绿 → 中部黄 → 顶部红 —— 短柱整体绿、
///   高柱爬升到黄/红，与经典电平表一致（画布级垂直渐变着色器实现）；
/// * 峰值帽 = 峰值高度处 2px 横条，从同一着色器取色（高处帽自然偏红）；
/// * 倒影 = 整幅内容绕基线垂直镜像 + 25% 不透明度。
class _SpectrumPainter extends CustomPainter {
  _SpectrumPainter({
    required this.display,
    required this.peaks,
    required this.barCount,
    required this.baseline,
    required this.maxBar,
  });

  /// 各柱当前显示高度（0..1），由 [AudioSpectrumEngine] 逐帧推进。
  final List<double> display;

  /// 各柱峰值帽高度（0..1）。
  final List<double> peaks;

  final int barCount;

  /// 基线（柱体底部）在画布内的 y 坐标；其下为倒影区。
  final double baseline;

  /// 柱体最大高度（px）。
  final double maxBar;

  /// VU 表配色的 3 个色标（底绿 → 中黄 → 顶红，等价 4 段渐变）。
  static const List<Color> _vuColors = [
    Color(0xFF33D433), // 绿（低音量）
    Color(0xFFEED500), // 黄（中等音量）
    Color(0xFFE4390E), // 红（高音量）
  ];

  @override
  void paint(Canvas canvas, Size size) {
    final unit = size.width / barCount;
    final barWidth = unit * 0.9;
    final barInset = (unit - barWidth) / 2;

    // 高度渐变着色器：颜色只随 y（高度位置）变化，铺满整个频谱区——
    // 所有柱子共享同一个「底绿顶红」渐变，短柱整体绿、高柱爬黄升红。
    final shader = const LinearGradient(
      begin: Alignment.bottomCenter,
      end: Alignment.topCenter,
      colors: _vuColors,
      stops: [0.0, 0.6, 1.0],
    ).createShader(Rect.fromLTWH(0, 0, size.width, baseline));
    final paint = Paint()..shader = shader;

    // LED 分段几何：节距 5px = 段高 3.5px + 缝 1.5px。
    const segPitch = 5.0;
    const segHeight = 3.5;

    void drawBars() {
      for (var i = 0; i < barCount; i++) {
        final x = i * unit + barInset;
        final h = display[i].clamp(0.0, 1.0) * maxBar;
        // 点亮的 LED 段：自底向上逐段堆叠，段底不高于柱高。
        if (h >= 1) {
          var yLo = 0.0; // 段底部相对基线的高度
          while (yLo + 0.5 < h) {
            canvas.drawRect(
              Rect.fromLTWH(x, baseline - yLo - segHeight, barWidth, segHeight),
              paint,
            );
            yLo += segPitch;
          }
        }
        // 峰值帽：峰值高度上方 2px 横条（同着色器取色，高位帽自然偏红）。
        final peakH = peaks[i].clamp(0.0, 1.0) * maxBar;
        if (peakH >= 1) {
          canvas.drawRect(
            Rect.fromLTWH(x, baseline - peakH - 2, barWidth, 2),
            paint,
          );
        }
      }
    }

    drawBars();

    // 倒影：整幅内容绕基线垂直镜像 + 恒定透明度（对齐 audioMotion 的
    // reflex drawImage 镜像做法；水平渐变在垂直翻转下取色不变）。
    final reflectH = size.height - baseline;
    if (reflectH > 2) {
      canvas.save();
      canvas.clipRect(
          Rect.fromLTWH(0, baseline, size.width, reflectH));
      canvas.saveLayer(
        Rect.fromLTWH(0, baseline, size.width, reflectH),
        Paint()..color = const Color(0x40FFFFFF), // 25% 不透明度
      );
      canvas.translate(0, baseline);
      canvas.scale(1, -1);
      canvas.translate(0, -baseline);
      drawBars();
      canvas.restore();
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(_SpectrumPainter oldDelegate) => true;
}
