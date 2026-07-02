import 'package:flutter/material.dart';
import '../../../services/lyric_parser.dart';

/// 同步歌词显示组件：根据播放位置高亮当前行并自动滚动。
/// 支持逐字时间戳格式的卡拉OK歌词显示。
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

class _LyricsViewWidgetState extends State<LyricsViewWidget> {
  final ScrollController _scrollController = ScrollController();
  late List<GlobalKey> _itemKeys;
  int _currentLineIndex = -1;
  int _currentWordIndex = -1;
  bool _isUserScrolling = false;

  @override
  void initState() {
    super.initState();
    _itemKeys = List.generate(widget.lyrics.length, (_) => GlobalKey());
    _updateCurrentIndices();
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToCurrentLine(animate: false));
  }

  void _updateCurrentIndices() {
    _currentLineIndex = LyricParser.findCurrentLineIndex(widget.lyrics, widget.position);
    _currentWordIndex = -1;
    if (_currentLineIndex >= 0 && _currentLineIndex < widget.lyrics.length) {
      _currentWordIndex = LyricParser.findCurrentWordIndex(
        widget.lyrics[_currentLineIndex],
        widget.position,
      );
    }
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

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  /// 构建逐字歌词行
  Widget _buildWordByWordLyric(LyricLine line, bool isCurrent, ThemeData theme, bool isDark) {
    if (!line.hasWordTimestamps) {
      return _buildNormalLyric(line, isCurrent, theme, isDark);
    }

    final words = line.words!;
    final isPast = widget.lyrics.indexOf(line) < _currentLineIndex;
    final currentWordIdx = isCurrent ? _currentWordIndex : -1;

    return RichText(
      textAlign: TextAlign.center,
      text: TextSpan(
        children: words.asMap().entries.map((entry) {
          final idx = entry.key;
          final word = entry.value;
          final isHighlighted = isCurrent && idx <= currentWordIdx;
          final isCurrentWord = isCurrent && idx == currentWordIdx;

          Color textColor;
          if (isPast) {
            textColor = theme.colorScheme.onSurface.withValues(alpha: 0.3);
          } else if (isHighlighted) {
            textColor = widget.accentColor;
          } else {
            textColor = theme.colorScheme.onSurface.withValues(alpha: 0.6);
          }

          return TextSpan(
            text: word.text,
            style: TextStyle(
              fontSize: isCurrent ? 22 : 16,
              fontWeight: isCurrentWord ? FontWeight.bold : (isHighlighted ? FontWeight.w600 : FontWeight.w500),
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
