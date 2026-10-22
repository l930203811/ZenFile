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

int _clampInt(int v, int lo, int hi) => v < lo ? lo : (v > hi ? hi : v);

/// 逐字歌词：估算末词时长时「每字毫秒」的上下限与缺省值。
const int _kMinCharMs = 90;
const int _kMaxCharMs = 900;
const int _kDefaultCharMs = 260;

/// 行尾留白（毫秒）：本行最后一个字的结束时刻要从 [lineEnd] 往回收这么多。
///
/// ⚠️ 一行的 `lineEnd` 通常是**下一行的起始时间**，末尾那一段是句间静默、
/// 并不是演唱。直接拿它当末字的 `endTime`，会让末字的高亮 / 放大 / 坠落特效
/// 一直挂到下一句开口那一刻才收 —— 表现为「末字唱完了还不恢复原样」「坠落
/// 流星的末字像被下一句顶下去的」。这里按行长取一小段留白把行尾收回来。
int tailGapMsFor(int lineMs) {
  if (lineMs <= 0) return 0;
  return _clampInt((lineMs * 0.12).round(), 180, 900);
}

/// 行内最后一个字真正唱完的时刻（把句间静默从行尾切掉）。
///
/// 行长极短时留白减半，否则末字几乎分不到时间。
Duration _effectiveLineEnd(Duration lineStart, Duration lineEnd) {
  final startMs = lineStart.inMilliseconds;
  final endMs = lineEnd.inMilliseconds;
  final lineMs = endMs - startMs;
  if (lineMs <= 0) return lineEnd;
  var gap = tailGapMsFor(lineMs);
  if (gap * 2 > lineMs) gap = lineMs ~/ 2;
  return _ms(endMs - gap);
}

/// 估算本行**末词**的结束时刻（逐字歌词用）。
///
/// 末词没有「下一个词的时间戳」可当终点，不能拿 [lineEnd]（下一句起点）顶替：
/// 那样末词的时长会被整段句间静默撑开，末字于是要等到下一句开口才「唱完」。
/// 这里用本行前面的词间隔反推「每字时长」（取中位数，避免个别拖长音把整体
/// 拉长），给末词一个自然的尾巴，再夹到 [cap] 之内。
Duration _estimateLastWordEnd(
  List<LyricWord> words,
  int w,
  Duration wStart,
  Duration cap,
) {
  final samples = <int>[];
  for (var k = 0; k + 1 < words.length; k++) {
    final durMs =
        words[k + 1].timestamp.inMilliseconds -
        words[k].timestamp.inMilliseconds;
    final chars = splitLyricGraphemes(words[k].text).length;
    if (durMs > 0 && chars > 0) samples.add((durMs / chars).round());
  }
  var perChar = _kDefaultCharMs;
  if (samples.isNotEmpty) {
    samples.sort();
    perChar = samples[samples.length ~/ 2];
  }
  perChar = _clampInt(perChar, _kMinCharMs, _kMaxCharMs);
  final count = math.max(1, splitLyricGraphemes(words[w].text).length);
  final estMs = wStart.inMilliseconds + perChar * count;
  final capMs = cap.inMilliseconds;
  return _ms(estMs < capMs ? estMs : capMs);
}

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

  // ⚠️ 行尾要先把句间静默切掉：末字的 endTime 不能压在下一句开口上，否则
  // 所有风格都会「末字迟迟不结束」（高亮/放大不复原、坠落流星等下一句才飘）。
  final tailEnd = _effectiveLineEnd(line.timestamp, lineEnd);

  // 无逐字时间戳：整行在 [行首, 有效行尾] 上均分，得到平滑的整行扫过。
  if (!line.hasWordTimestamps) {
    return LyricLineTimeline(
      graphemes: _evenGraphemes(
        chars,
        0,
        chars.length,
        line.timestamp,
        tailEnd,
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
    // 末词没有下一个词可作终点：用本行节奏估一个自然尾巴，而不是拿 lineEnd
    //（下一句起点）顶替——否则末字会被整段句间静默撑到下一句开口才「唱完」。
    final wEnd = (w + 1 < words.length)
        ? words[w + 1].timestamp
        : _estimateLastWordEnd(words, w, wStart, tailEnd);
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
    // 剩余字符落在有效行尾；万一前面已经把 tailStart 推过了行尾，就按每字
    // 一个最小步长往后补，避免出现零时长的字。
    var end = tailEnd;
    if (end.inMilliseconds <= tailStart.inMilliseconds) {
      end = _ms(tailStart.inMilliseconds + 120 * (chars.length - cursor));
    }
    graphemes.addAll(
      _evenGraphemes(chars, cursor, chars.length - cursor, tailStart, end),
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
