import 'dart:math' as math;

import 'lyric_parser.dart';

/// 单个字（grapheme）的时间片：该字从 [startTime] 唱到 [endTime]。
class LyricGrapheme {
  final String char;
  final Duration startTime;
  final Duration endTime;

  const LyricGrapheme(this.char, this.startTime, this.endTime);
}

/// 一行歌词的逐字时间线。
///
/// 由 [buildLineTimeline] 生成：把一行文本切成有序的字，每个字带起止时间。
/// 无论原始歌词是否带逐字时间戳都会生成——无逐字时间戳时按「行首到行尾」均分，
/// 从而让所有歌词都能呈现"扫过"填充效果（思路同 folia 的 graphemeTiming）。
class LyricLineTimeline {
  final List<LyricGrapheme> graphemes;
  final String text;
  final Duration lineStart;

  /// 本行结束时间（通常是下一行起始；末行见 [lineEndForIndex]）。
  final Duration lineEnd;

  /// 本行是否来自带逐字时间戳的歌词（增强 LRC / QRC / KRC）。
  ///
  /// false = 普通 LRC 均分时间线：逐字时间与真实演唱并不对应，UI 层据此
  /// 做「整句变色」而非逐字变色，避免错位感；逐字弹放/特效动画不受影响。
  final bool hasWordTimestamps;

  const LyricLineTimeline({
    required this.graphemes,
    required this.text,
    required this.lineStart,
    required this.lineEnd,
    this.hasWordTimestamps = false,
  });

  bool get isEmpty => graphemes.isEmpty;
  int get length => graphemes.length;

  /// 每字在文本中的 UTF-16 起始偏移，长度 = graphemes.length + 1。
  /// 供 UI 层用 TextPainter 测量每字水平边界时使用。
  List<int> get utf16BoundaryOffsets {
    final offsets = <int>[0];
    var acc = 0;
    for (final g in graphemes) {
      acc += g.char.length; // Dart String.length = UTF-16 代码单元数
      offsets.add(acc);
    }
    return offsets;
  }
}

/// 按 Unicode 码点切分字符（代理对安全：emoji 不会被劈成两半）。
/// 歌词场景足够精细；组合用附加符号（如变音符号）暂不合并，影响可忽略。
List<String> splitLyricGraphemes(String text) {
  if (text.isEmpty) return const [];
  return [for (final r in text.runes) String.fromCharCode(r)];
}

Duration _ms(int v) => Duration(milliseconds: v);

/// 把 [chars] 中从 [from] 起的 [count] 个字，在 [start, end] 区间内按数量均分。
List<LyricGrapheme> _evenGraphemes(
  List<String> chars,
  int from,
  int count,
  Duration start,
  Duration end,
) {
  if (count <= 0) return const [];
  final startMs = start.inMilliseconds;
  final endMs = end.inMilliseconds;
  final dur = math.max(0, endMs - startMs);
  final unit = dur / count;
  final out = <LyricGrapheme>[];
  for (var k = 0; k < count; k++) {
    final s = _ms(startMs + (unit * k).round());
    final e = (k == count - 1) ? end : _ms(startMs + (unit * (k + 1)).round());
    out.add(LyricGrapheme(chars[from + k], s, e));
  }
  return out;
}

/// 为一行歌词构建逐字时间线。
///
/// [lineEnd] 通常是下一行的起始时间（或歌曲末尾的估计值），
/// 用于确定最后一个字/词的结束时间。
LyricLineTimeline buildLineTimeline(LyricLine line, Duration lineEnd) {
  final text = line.text;
  final chars = splitLyricGraphemes(text);
  if (chars.isEmpty) {
    return LyricLineTimeline(
      graphemes: const [],
      text: text,
      lineStart: line.timestamp,
      lineEnd: lineEnd,
      hasWordTimestamps: line.hasWordTimestamps,
    );
  }

  // 无逐字时间戳：整行在 [行首, 行尾] 上均分，得到平滑的整行扫过。
  if (!line.hasWordTimestamps) {
    return LyricLineTimeline(
      graphemes: _evenGraphemes(
        chars,
        0,
        chars.length,
        line.timestamp,
        lineEnd,
      ),
      text: text,
      lineStart: line.timestamp,
      lineEnd: lineEnd,
    );
  }

  // 带逐字时间戳：line.text == words.map(text).join('')，逐词按顺序铺满整行。
  // 每个词内部再把字均分，得到亚词级平滑（对应 folia 的 buildEvenGraphemeTimings 回退）。
  final words = line.words!;
  final graphemes = <LyricGrapheme>[];
  var cursor = 0; // 已消费的字符数（码点）
  for (var w = 0; w < words.length && cursor < chars.length; w++) {
    final word = words[w];
    final wStart = word.timestamp;
    final wEnd = (w + 1 < words.length) ? words[w + 1].timestamp : lineEnd;
    final take = math.min(
      splitLyricGraphemes(word.text).length,
      chars.length - cursor,
    );
    if (take <= 0) continue;
    graphemes.addAll(_evenGraphemes(chars, cursor, take, wStart, wEnd));
    cursor += take;
  }

  // 兜底：若词文本与行文本不完全对齐，剩余字符均分到末尾。
  if (cursor < chars.length) {
    final tailStart = graphemes.isNotEmpty
        ? graphemes.last.endTime
        : line.timestamp;
    graphemes.addAll(
      _evenGraphemes(chars, cursor, chars.length - cursor, tailStart, lineEnd),
    );
  }

  return LyricLineTimeline(
    graphemes: graphemes,
    text: text,
    lineStart: line.timestamp,
    lineEnd: lineEnd,
    hasWordTimestamps: true,
  );
}

/// 依据一组歌词行为每行计算结束时间（即下一行起始；末行给一个估计值）。
Duration lineEndForIndex(
  List<LyricLine> lines,
  int index, {
  Duration lastLineFallback = const Duration(seconds: 8),
}) {
  if (index < 0 || index >= lines.length) return Duration.zero;
  if (index + 1 < lines.length) return lines[index + 1].timestamp;
  return lines[index].timestamp + lastLineFallback;
}

/// 某一时刻填充到哪个字、以及该字内的进度。
///
/// 返回 (index, fraction)：
/// - index == -1 表示尚未开始（无填充）；
/// - index == graphemes.length 表示已全部唱完（整行填满）；
/// - 否则表示正在唱第 [index] 个字，[fraction] ∈ [0,1] 为该字内进度。
({int index, double fraction}) graphemeFillAt(
  LyricLineTimeline timeline,
  Duration t,
) {
  final g = timeline.graphemes;
  if (g.isEmpty) return (index: -1, fraction: 0.0);
  final tMs = t.inMilliseconds;
  if (tMs <= g.first.startTime.inMilliseconds) {
    return (index: -1, fraction: 0.0);
  }
  if (tMs >= g.last.endTime.inMilliseconds) {
    return (index: g.length, fraction: 0.0);
  }
  for (var i = 0; i < g.length; i++) {
    final s = g[i].startTime.inMilliseconds;
    final e = g[i].endTime.inMilliseconds;
    if (tMs < s) {
      // 落在第 i 个字开始前（词间空隙）：填充到第 i 个字左边界
      return (index: i, fraction: 0.0);
    }
    if (tMs <= e) {
      final f = (tMs - s) / math.max(1, e - s);
      return (index: i, fraction: f.clamp(0.0, 1.0));
    }
  }
  return (index: g.length, fraction: 0.0);
}
