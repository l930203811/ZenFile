import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import '../../../services/lyric_parser.dart';

/// 同步歌词显示组件：根据播放位置高亮当前行并自动滚动。
/// 支持逐字时间戳格式的卡拉OK歌词显示，带平滑逐字过渡效果。
class LyricsViewWidget extends StatefulWidget {
  final List<LyricLine> lyrics;
  final Duration position;
  final Color accentColor;
  final void Function(Duration)? onSeek;

  const LyricsViewWidget({
    super.key,
    required this.lyrics,
    required this.position,
    required this.accentColor,
    this.onSeek,
  });

  @override
  State<LyricsViewWidget> createState() => _LyricsViewWidgetState();
}

class _LyricsViewWidgetState extends State<LyricsViewWidget>
    with SingleTickerProviderStateMixin {
  final ScrollController _scrollController = ScrollController();
  late List<GlobalKey> _itemKeys;
  int _currentLineIndex = -1;
  bool _isUserScrolling = false;

  /// 逐字过渡动画控制器：驱动每帧重绘以实现颜色渐变
  late final Ticker _ticker;

  @override
  void initState() {
    super.initState();
    _itemKeys = List.generate(widget.lyrics.length, (_) => GlobalKey());
    _updateCurrentIndices();
    _ticker = Ticker(_onTick);
    _ticker.start();
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToCurrentLine(animate: false));
  }

  void _onTick(Duration elapsed) {
    // 持续触发重绘以更新逐字过渡进度
    if (mounted) setState(() {});
  }

  void _updateCurrentIndices() {
    _currentLineIndex = LyricParser.findCurrentLineIndex(widget.lyrics, widget.position);
  }

  @override
  void didUpdateWidget(covariant LyricsViewWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.lyrics.length != widget.lyrics.length || oldWidget.lyrics != widget.lyrics) {
      _itemKeys = List.generate(widget.lyrics.length, (_) => GlobalKey());
      _updateCurrentIndices();
      WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToCurrentLine(animate: false));
    } else {
      final oldLineIndex = _currentLineIndex;
      _updateCurrentIndices();
      if (_currentLineIndex != oldLineIndex) {
        if (!_isUserScrolling) {
          WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToCurrentLine());
        }
      }
    }
  }

  void _scrollToCurrentLine({bool animate = true}) {
    if (!_scrollController.hasClients || _currentLineIndex < 0 || _currentLineIndex >= _itemKeys.length) {
      return;
    }

    final key = _itemKeys[_currentLineIndex];
    final context = key.currentContext;
    if (context == null) {
      _scrollToEstimated(animate: animate);
      return;
    }

    final box = context.findRenderObject() as RenderBox?;
    if (box == null) {
      _scrollToEstimated(animate: animate);
      return;
    }

    final listBox = _scrollController.position.context.storageContext.findRenderObject() as RenderBox?;
    if (listBox == null) return;

    final itemOffset = box.localToGlobal(Offset.zero, ancestor: listBox).dy;
    final itemHeight = box.size.height;
    final viewportHeight = _scrollController.position.viewportDimension;
    final targetOffset = _scrollController.offset + itemOffset - (viewportHeight / 2) + (itemHeight / 2);
    final clampedOffset = targetOffset.clamp(0.0, _scrollController.position.maxScrollExtent);

    if (animate) {
      _scrollController.animateTo(
        clampedOffset,
        duration: const Duration(milliseconds: 450),
        curve: Curves.easeOutCubic,
      );
    } else {
      _scrollController.jumpTo(clampedOffset);
    }
  }

  void _scrollToEstimated({bool animate = true}) {
    if (!_scrollController.hasClients || _currentLineIndex < 0) return;
    const estimatedLineHeight = 56.0;
    final viewportHeight = _scrollController.position.viewportDimension;
    final targetOffset = (_currentLineIndex * estimatedLineHeight) - (viewportHeight / 2) + (estimatedLineHeight / 2);
    final clampedOffset = targetOffset.clamp(0.0, _scrollController.position.maxScrollExtent);
    if (animate) {
      _scrollController.animateTo(
        clampedOffset,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOut,
      );
    } else {
      _scrollController.jumpTo(clampedOffset);
    }
  }

  /// 逐字高亮过渡的固定时长（毫秒）
  /// 使用固定时长确保每个字的动画速度一致，不会因为字间距长而拖慢
  static const int _kWordTransitionDurationMs = 300;

  /// 计算某个字的过渡进度 (0.0 ~ 1.0)
  /// 0.0 = 完全未高亮, 1.0 = 完全高亮
  double _wordTransitionProgress(LyricLine line, int wordIndex, bool isCurrentLine) {
    if (!isCurrentLine || !line.hasWordTimestamps) {
      // 非当前行：已过去的行直接返回1.0，未来行返回0.0
      final lineIndex = widget.lyrics.indexOf(line);
      if (lineIndex < _currentLineIndex) return 1.0;
      return 0.0;
    }

    final words = line.words!;
    final posMs = widget.position.inMilliseconds;
    final currentWordTs = words[wordIndex].timestamp.inMilliseconds;

    if (posMs < currentWordTs) {
      // 还没到这个字
      return 0.0;
    }

    // 使用固定过渡时长，确保每个字的动画速度一致
    // 对于非末尾字：取固定时长和到下一个字的时间中的较小值，避免和下一个字重叠
    int transitionDuration = _kWordTransitionDurationMs;
    if (wordIndex + 1 < words.length) {
      final nextWordTs = words[wordIndex + 1].timestamp.inMilliseconds;
      final gapDuration = nextWordTs - currentWordTs;
      // 如果两个字间隔很短，就用间隔时间的一半作为过渡时长，避免重叠
      if (gapDuration < _kWordTransitionDurationMs) {
        transitionDuration = (gapDuration * 0.6).toInt().clamp(80, _kWordTransitionDurationMs);
      }
    }

    final elapsed = posMs - currentWordTs;
    final progress = elapsed / transitionDuration;
    // 使用 easeInOut 曲线让过渡更自然
    return _easeInOutCubic(progress.clamp(0.0, 1.0));
  }

  /// easeInOutCubic 缓动函数
  double _easeInOutCubic(double t) {
    return t < 0.5
        ? 4 * t * t * t
        : 1 - (-2 * t + 2) * (-2 * t + 2) * (-2 * t + 2) / 2;
  }

  /// 字体放大曲线：t=0 时返回0，t=0.5 时返回1（最大放大），t=1 时返回0
  /// 用于歌词逐字过渡时对该字进行放大动画
  double _scaleCurve(double t) {
    // 4*t*(1-t) 近似 sin(πt)，在 t=0 和 t=1 时为 0，t=0.5 时为 1
    return 4 * t * (1 - t);
  }

  @override
  void dispose() {
    _ticker.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  /// 构建逐字歌词行 - 带平滑颜色过渡
  Widget _buildWordByWordLyric(LyricLine line, bool isCurrent, ThemeData theme, bool isDark) {
    if (!line.hasWordTimestamps) {
      return _buildNormalLyric(line, isCurrent, theme, isDark);
    }

    final words = line.words!;
    final lineIndex = widget.lyrics.indexOf(line);
    final isPast = lineIndex < _currentLineIndex;

    // 颜色定义
    final highlightColor = widget.accentColor;
    final baseColor = theme.colorScheme.onSurface.withValues(alpha: 0.6);
    final pastColor = theme.colorScheme.onSurface.withValues(alpha: 0.3);

    return RichText(
      textAlign: TextAlign.center,
      // 当前行使用 strutStyle 固定行高，防止字号放大导致行高跳动
      strutStyle: isCurrent
          ? const StrutStyle(fontSize: 28, height: 1.5, forceStrutHeight: true)
          : null,
      text: TextSpan(
        children: words.asMap().entries.map((entry) {
          final idx = entry.key;
          final word = entry.value;

          // 计算该字的过渡进度
          final progress = _wordTransitionProgress(line, idx, isCurrent);

          Color textColor;
          FontWeight fontWeight;

          if (isPast) {
            // 已过去的行
            textColor = pastColor;
            fontWeight = FontWeight.w500;
          } else if (isCurrent) {
            // 当前行：根据进度在 baseColor 和 highlightColor 之间插值
            textColor = Color.lerp(baseColor, highlightColor, progress)!;
            // 字重也平滑过渡
            if (progress > 0.7) {
              fontWeight = FontWeight.bold;
            } else if (progress > 0.3) {
              fontWeight = FontWeight.w600;
            } else {
              fontWeight = FontWeight.w500;
            }
          } else {
            // 未来行
            textColor = baseColor;
            fontWeight = FontWeight.w500;
          }

          // 放大效果：正在过渡的字会有一个放大动画
          // progress=0 和 1 时不放大，progress=0.5 时达到最大放大
          final scaleBoost = isCurrent ? 6.0 * _scaleCurve(progress) : 0.0;

          return TextSpan(
            text: word.text,
            style: TextStyle(
              fontSize: (isCurrent ? 22.0 : 16.0) + scaleBoost,
              fontWeight: fontWeight,
              color: textColor,
              height: 1.5,
            ),
          );
        }).toList(),
      ),
    );
  }

  /// 构建普通歌词行
  Widget _buildNormalLyric(LyricLine line, bool isCurrent, ThemeData theme, bool isDark) {
    final isPast = widget.lyrics.indexOf(line) < _currentLineIndex;

    return Text(
      line.text.isEmpty ? '♪' : line.text,
      textAlign: TextAlign.center,
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        fontSize: isCurrent ? 22 : 16,
        fontWeight: isCurrent ? FontWeight.bold : FontWeight.w500,
        color: isCurrent
            ? widget.accentColor
            : isPast
                ? theme.colorScheme.onSurface.withValues(alpha: 0.3)
                : theme.colorScheme.onSurface.withValues(alpha: 0.6),
        height: 1.5,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return LayoutBuilder(
      builder: (context, constraints) {
        final viewportHeight = constraints.maxHeight;
        final topPadding = viewportHeight * 0.4;
        final bottomPadding = viewportHeight * 0.4;

        return NotificationListener<ScrollNotification>(
          onNotification: (notification) {
            if (notification is UserScrollNotification) {
              _isUserScrolling = true;
              Future.delayed(const Duration(seconds: 4), () {
                if (mounted) _isUserScrolling = false;
              });
            }
            return false;
          },
          child: ListView.builder(
            controller: _scrollController,
            padding: EdgeInsets.only(top: topPadding, bottom: bottomPadding, left: 24, right: 24),
            itemCount: widget.lyrics.length,
            itemBuilder: (context, index) {
              final line = widget.lyrics[index];
              final isCurrent = index == _currentLineIndex;

              return GestureDetector(
                key: _itemKeys[index],
                onTap: () {
                  if (widget.onSeek != null) {
                    widget.onSeek!(line.timestamp);
                    setState(() => _isUserScrolling = false);
                  }
                },
                child: AnimatedPadding(
                  duration: const Duration(milliseconds: 300),
                  padding: EdgeInsets.symmetric(vertical: isCurrent ? 14 : 8),
                  child: AnimatedDefaultTextStyle(
                    duration: const Duration(milliseconds: 300),
                    style: TextStyle(
                      fontSize: isCurrent ? 22 : 16,
                      fontWeight: isCurrent ? FontWeight.bold : FontWeight.w500,
                      color: isCurrent
                          ? widget.accentColor
                          : theme.colorScheme.onSurface.withValues(alpha: 0.6),
                      height: 1.5,
                    ),
                    child: line.hasWordTimestamps
                        ? _buildWordByWordLyric(line, isCurrent, theme, isDark)
                        : _buildNormalLyric(line, isCurrent, theme, isDark),
                  ),
                ),
              );
            },
          ),
        );
      },
    );
  }
}
