import 'package:flutter_test/flutter_test.dart';
import 'package:zenfile/services/lyric_parser.dart';
import 'package:zenfile/services/lyric_timeline.dart';

void main() {
  // 一行的 lineEnd 通常是**下一行的起始时间**，末尾那段是句间静默、不是演唱。
  // 末字的 endTime 若顶到 lineEnd，所有风格都会「末字迟迟不结束」：经典扫过
  // 的末字一直保持高亮放大直到下一句开口，坠落流星的末字则被下一句顶下去。
  group('行尾留白：末字必须在本句内唱完', () {
    test('普通 LRC（整行均分）', () {
      final lines = LyricParser.parse(
        '[00:01.00]第一句短歌词\n'
        '[00:04.00]第二句明显更长的歌词内容\n'
        '[00:09.00]第三句',
      );
      for (var i = 0; i < lines.length; i++) {
        final tl = buildLineTimeline(lines[i], lineEndForIndex(lines, i));
        expect(tl.graphemes.isNotEmpty, isTrue);
        final last = tl.graphemes.last;
        expect(
          last.endTime.inMilliseconds,
          lessThan(tl.lineEnd.inMilliseconds),
          reason: '第 $i 行末字 endTime 顶到了行尾（= 下一句开口）',
        );
        expect(
          last.endTime.inMilliseconds,
          greaterThan(last.startTime.inMilliseconds),
          reason: '第 $i 行末字没有可唱的时间',
        );
      }
    });

    test('逐字歌词（末词没有下一个词可作终点）', () {
      final lines = LyricParser.parse(
        '[00:04.00]这[00:04.30]是[00:04.60]末[00:04.90]字\n'
        '[00:12.00]下一句',
      );
      final tl = buildLineTimeline(lines[0], lineEndForIndex(lines, 0));
      expect(tl.hasWordTimestamps, isTrue);
      final last = tl.graphemes.last;
      // 下一句 8 秒后才来；末字应当在自己唱完（约 5.2s）时就结束，
      // 而不是被句间静默一路撑到 12s。
      expect(last.endTime.inMilliseconds, lessThan(6000));
      expect(last.endTime.inMilliseconds, lessThan(tl.lineEnd.inMilliseconds));
      expect(
        last.endTime.inMilliseconds,
        greaterThan(last.startTime.inMilliseconds),
      );
    });

    test('行长极短时末字仍有可唱时间', () {
      final line = LyricLine(
        timestamp: Duration(milliseconds: 1000),
        text: '短句',
      );
      final tl = buildLineTimeline(line, const Duration(milliseconds: 1200));
      final last = tl.graphemes.last;
      expect(last.endTime.inMilliseconds, lessThanOrEqualTo(1200));
      expect(
        last.endTime.inMilliseconds,
        greaterThan(last.startTime.inMilliseconds),
      );
    });

    test('末字唱完后填充状态推进到「整行已唱完」', () {
      final lines = LyricParser.parse(
        '[00:01.00]第一句短歌词\n'
        '[00:04.00]第二句明显更长的歌词内容\n'
        '[00:09.00]第三句',
      );
      final tl = buildLineTimeline(lines[1], lineEndForIndex(lines, 1));
      final lastEnd = tl.graphemes.last.endTime.inMilliseconds;
      final lineEndMs = tl.lineEnd.inMilliseconds;
      expect(lastEnd, lessThan(lineEndMs));

      // 末字唱完之后、下一句开口之前：这一整行都应当处于「已唱完」，
      // 末字不再停留在「正在唱」的高亮/放大状态。
      final probe = lastEnd + ((lineEndMs - lastEnd) ~/ 2);
      final fill = graphemeFillAt(tl, Duration(milliseconds: probe));
      expect(fill.index, tl.graphemes.length);
    });
  });
}
