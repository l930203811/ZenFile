import 'dart:math';
import 'package:flutter/material.dart';

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

  const AudioWaveformWidget({
    super.key,
    required this.position,
    required this.duration,
    required this.isPlaying,
    required this.accentColor,
    required this.onSeek,
    this.onSeekStart,
    this.onSeekCancel,
  });

  @override
  State<AudioWaveformWidget> createState() => _AudioWaveformWidgetState();
}

class _AudioWaveformWidgetState extends State<AudioWaveformWidget>
    with SingleTickerProviderStateMixin {
  late AnimationController _animController;
  final int _barCount = 56;
  late List<double> _normalizedHeights;
  double? _dragPercentage;
  double? _pendingPositionPercentage;
  DateTime? _pendingSetTime;

  /// 正在按压 / 拖动波形条的指针 id（只跟踪第一个按下的指针，避免多指互相打断）。
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
    _animController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    );
    if (widget.isPlaying) {
      _animController.repeat();
    }
    _generateStaticWaveform();
  }

  @override
  void didUpdateWidget(AudioWaveformWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isPlaying && !oldWidget.isPlaying) {
      _animController.repeat();
    } else if (!widget.isPlaying && oldWidget.isPlaying) {
      _animController.stop();
    }
  }

  void _generateStaticWaveform() {
    final rand = Random(42); // deterministic random for beautiful fixed peaks
    _normalizedHeights = List.generate(_barCount, (i) {
      // smooth envelope across the width
      double x = (i / (_barCount - 1)) * 2 - 1;
      double envelope = exp(-x * x * 2.5);
      return (envelope * 0.6 + rand.nextDouble() * 0.4).clamp(0.08, 1.0);
    });
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
    _animController.dispose();
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

    final decorationBehind = BoxDecoration(
      color: theme.colorScheme.onSurface.withValues(alpha: 0.15),
      borderRadius: BorderRadius.circular(5),
    );

    final decorationFront = BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(5),
      boxShadow: [
        BoxShadow(
          color: widget.accentColor.withValues(alpha: 0.5),
          blurRadius: 10,
          spreadRadius: 1,
        ),
      ],
    );

    final activeColors = [
      Color.alphaBlend(widget.accentColor.withAlpha(220), theme.colorScheme.onSurface),
      Color.alphaBlend(widget.accentColor.withAlpha(180), theme.colorScheme.onSurface),
      Colors.transparent,
      Colors.transparent,
    ];

    return LayoutBuilder(
      builder: (context, constraints) {
        final barWidth = (constraints.maxWidth / _barCount) * 0.55;
        const maxBarHeight = 54.0;
        const minBarHeight = 4.0;

        return AnimatedBuilder(
          animation: _animController,
          builder: (context, _) {
            // 播放时“鼓点节奏”跳动：以低频鼓点包络为主驱动，整体随鼓点起伏
            // （≈1.3Hz，接近 70~80 BPM 的节拍），高频仅做轻微细节扰动，
            // 避免之前的高频快速闪烁；暂停时回落到静态波形。
            final t = _animController.value;
            final drum = sin(t * 2 * pi * 1.9); // 低频鼓点，-1..1
            final barHeights = List<double>.generate(_barCount, (i) {
              final base = _normalizedHeights[i];
              if (widget.isPlaying) {
                final x = i / _barCount;
                // 高频细节微扰（不抢鼓点主节奏）
                final detail = 0.16 * sin(t * 2 * pi * (3.0 + x * 4.0) + i * 0.6);
                // 鼓点驱动：低频柱（左侧）跟随鼓点更明显
                final kick = (1.0 - x * 0.35) * drum;
                final level = (0.72 * kick + detail).clamp(-1.0, 1.0);
                return (base * (1 + 0.6 * level)).clamp(0.0, 1.0);
              }
              return base;
            });

            final behindBars = Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: List.generate(_barCount, (i) {
                double h = barHeights[i] * maxBarHeight;
                h = h.clamp(minBarHeight, maxBarHeight);
                return SizedBox(
                  width: barWidth,
                  height: h,
                  child: DecoratedBox(decoration: decorationBehind),
                );
              }),
            );

            final frontBars = Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: List.generate(_barCount, (i) {
                double h = barHeights[i] * maxBarHeight;
                h = h.clamp(minBarHeight, maxBarHeight);
                return SizedBox(
                  width: barWidth,
                  height: h,
                  child: DecoratedBox(decoration: decorationFront),
                );
              }),
            );

            final shaderMaskedFront = ShaderMask(
              blendMode: BlendMode.srcIn,
              shaderCallback: (bounds) {
                return LinearGradient(
                  stops: [0.0, percentage, percentage + 0.005, 1.0],
                  colors: activeColors,
                ).createShader(bounds);
              },
              child: frontBars,
            );

            return MouseRegion(
              cursor: SystemMouseCursors.click,
              child: Listener(
                behavior: HitTestBehavior.opaque,
                onPointerDown: (e) {
                  // 已有手指在处理就忽略额外指针，避免多指互相打断。
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
                  height: maxBarHeight + 16,
                  child: Center(
                    child: Stack(
                      alignment: Alignment.center,
                      children: [
                        behindBars,
                        shaderMaskedFront,
                      ],
                    ),
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }
}
