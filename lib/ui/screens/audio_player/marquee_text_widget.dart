import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

/// 单行文本过长时向左循环滚动（跑马灯）组件。
/// - 文本宽度未超过可用宽度时，按原样式静态显示（不滚动）。
/// - 文本超宽时，以“文本 + 间距 + 文本”无缝循环向左滚动。
/// - 速度由 [speed]（逻辑像素/秒）精确控制，用 Ticker 按累计时间计算位移，
///   避免 AnimationController.duration 被重复赋值导致速度异常。
class MarqueeText extends StatefulWidget {
  final String text;
  final TextStyle? style;
  final TextAlign textAlign;

  /// 两次文本之间的间距（逻辑像素），也是循环滚动周期的间隔。
  final double gap;

  /// 滚动速度（逻辑像素/秒），越大越快。
  final double speed;

  /// 是否处于激活状态（如正在播放）。为 false 时配合 [scrollWhenPaused] 停止滚动。
  final bool active;

  /// 非激活（暂停）时是否仍然滚动。
  final bool scrollWhenPaused;

  const MarqueeText({
    super.key,
    required this.text,
    this.style,
    this.textAlign = TextAlign.center,
    this.gap = 60,
    this.speed = 5,
    this.active = true,
    this.scrollWhenPaused = true,
  });

  @override
  State<MarqueeText> createState() => _MarqueeTextState();
}

class _MarqueeTextState extends State<MarqueeText>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  Duration _elapsed = Duration.zero;
  bool _overflow = false;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_onTick)..start();
  }

  void _onTick(Duration elapsed) {
    if (!_overflow) return;
    _elapsed = elapsed;
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final maxWidth = constraints.maxWidth;
        final tp = TextPainter(
          text: TextSpan(text: widget.text, style: widget.style),
          maxLines: 1,
          textDirection: Directionality.of(context),
        )..layout();
        final textWidth = tp.width;
        final textHeight = tp.height;
        _overflow = textWidth > maxWidth;

        // 未超宽：静态显示，与普通 Text 行为一致
        if (!_overflow) {
          return Text(
            widget.text,
            style: widget.style,
            textAlign: widget.textAlign,
            maxLines: 1,
            overflow: TextOverflow.visible,
          );
        }

        // 超宽但当前不滚动：停靠在开头（左对齐裁剪）
        final shouldScroll = widget.scrollWhenPaused || widget.active;
        if (!shouldScroll) {
          return SizedBox(
            height: textHeight,
            child: ClipRect(
              child: Align(
                alignment: Alignment.center,
                child: Text(
                  widget.text,
                  style: widget.style,
                  maxLines: 1,
                  overflow: TextOverflow.clip,
                ),
              ),
            ),
          );
        }

        // 向左循环滚动：按恒定速度（px/s）计算当前位移
        final total = textWidth + widget.gap;
        final cycleSec = total / widget.speed;
        final phase = (_elapsed.inMicroseconds / 1000000) % cycleSec;
        final offset = -phase * widget.speed;

        return SizedBox(
          height: textHeight,
          child: ClipRect(
            child: Align(
              alignment: Alignment.centerLeft,
              child: Transform.translate(
                offset: Offset(offset, 0),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      widget.text,
                      style: widget.style,
                      maxLines: 1,
                      overflow: TextOverflow.visible,
                    ),
                    SizedBox(width: widget.gap),
                    Text(
                      widget.text,
                      style: widget.style,
                      maxLines: 1,
                      overflow: TextOverflow.visible,
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
