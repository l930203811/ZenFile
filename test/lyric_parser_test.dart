import 'package:flutter_test/flutter_test.dart';
import 'package:zenfile/services/lyric_parser.dart';

void main() {
  group('LyricParser word-by-word tests', () {
    test('Enhanced LRC format: [mm:ss.xx]<mm:ss.xx>字<mm:ss.xx>字', () {
      const content = '''
[ti:测试]
[00:01.00]<00:01.00>这<00:01.50>是<00:02.00>歌<00:02.50>词
[00:04.00]<00:04.00>第<00:04.40>二<00:04.80>行
''';
      final lyrics = LyricParser.parse(content);

      // 第一行
      expect(lyrics[0].timestamp, Duration(milliseconds: 1000));
      expect(lyrics[0].text, '这是歌词');
      expect(lyrics[0].hasWordTimestamps, isTrue);
      expect(lyrics[0].words!.length, 4);
      expect(lyrics[0].words![0].text, '这');
      expect(lyrics[0].words![0].timestamp, Duration(milliseconds: 1000));
      expect(lyrics[0].words![1].text, '是');
      expect(lyrics[0].words![1].timestamp, Duration(milliseconds: 1500));
      expect(lyrics[0].words![2].text, '歌');
      expect(lyrics[0].words![2].timestamp, Duration(milliseconds: 2000));
      expect(lyrics[0].words![3].text, '词');
      expect(lyrics[0].words![3].timestamp, Duration(milliseconds: 2500));

      // 第二行
      expect(lyrics[1].text, '第二行');
      expect(lyrics[1].hasWordTimestamps, isTrue);
      expect(lyrics[1].words!.length, 3);
    });

    test('Pure bracket word-by-word: [mm:ss.xx]字[mm:ss.xx]字', () {
      const content = '''
[00:01.00]这[00:01.50]是[00:02.00]歌[00:02.50]词
[00:04.00]第[00:04.40]二[00:04.80]行
''';
      final lyrics = LyricParser.parse(content);

      expect(lyrics[0].text, '这是歌词');
      expect(lyrics[0].hasWordTimestamps, isTrue);
      expect(lyrics[0].words!.length, 4);
      expect(lyrics[0].words![0].text, '这');
      expect(lyrics[0].words![1].text, '是');
      expect(lyrics[0].words![2].text, '歌');
      expect(lyrics[0].words![3].text, '词');

      expect(lyrics[1].text, '第二行');
      expect(lyrics[1].hasWordTimestamps, isTrue);
      expect(lyrics[1].words!.length, 3);
    });

    test('Normal line-by-line LRC should NOT have word timestamps', () {
      const content = '''
[00:01.00]这是第一行歌词
[00:05.00]这是第二行歌词
''';
      final lyrics = LyricParser.parse(content);

      expect(lyrics[0].text, '这是第一行歌词');
      expect(lyrics[0].hasWordTimestamps, isFalse);
      expect(lyrics[0].words, isNull);

      expect(lyrics[1].text, '这是第二行歌词');
      expect(lyrics[1].hasWordTimestamps, isFalse);
    });

    test('No timestamps leak into text', () {
      const content = '''
[00:01.00]<00:01.00>这<00:01.50>是<00:02.00>歌<00:02.50>词
[00:04.00]这[00:04.40]是[00:04.80]歌[00:05.20]词
[00:08.00]普通歌词行
''';
      final lyrics = LyricParser.parse(content);

      // Ensure no timestamp text appears in line.text
      for (final line in lyrics) {
        expect(line.text.contains('['), isFalse, reason: 'text should not contain [');
        expect(line.text.contains(']'), isFalse, reason: 'text should not contain ]');
        expect(line.text.contains('<'), isFalse, reason: 'text should not contain <');
        expect(line.text.contains('>'), isFalse, reason: 'text should not contain >');
      }

      // Ensure no timestamp text appears in word.text
      for (final line in lyrics) {
        if (line.hasWordTimestamps) {
          for (final word in line.words!) {
            expect(word.text.contains('['), isFalse, reason: 'word should not contain [');
            expect(word.text.contains(']'), isFalse, reason: 'word should not contain ]');
            expect(word.text.contains('<'), isFalse, reason: 'word should not contain <');
            expect(word.text.contains('>'), isFalse, reason: 'word should not contain >');
            expect(word.text.contains(':'), isFalse, reason: 'word should not contain :');
            expect(word.text.contains('.'), isFalse, reason: 'word should not contain .');
          }
        }
      }
    });

    test('findCurrentWordIndex returns correct index', () {
      const content = '''
[00:01.00]<00:01.00>这<00:01.50>是<00:02.00>歌<00:02.50>词
''';
      final lyrics = LyricParser.parse(content);
      final line = lyrics[0];

      expect(LyricParser.findCurrentWordIndex(line, Duration(milliseconds: 0)), -1);
      expect(LyricParser.findCurrentWordIndex(line, Duration(milliseconds: 1000)), 0);
      expect(LyricParser.findCurrentWordIndex(line, Duration(milliseconds: 1499)), 0);
      expect(LyricParser.findCurrentWordIndex(line, Duration(milliseconds: 1500)), 1);
      expect(LyricParser.findCurrentWordIndex(line, Duration(milliseconds: 2000)), 2);
      expect(LyricParser.findCurrentWordIndex(line, Duration(milliseconds: 2500)), 3);
      expect(LyricParser.findCurrentWordIndex(line, Duration(milliseconds: 3000)), 3);
    });

    test('No duplicate words: multi-bracket line with Enhanced LRC', () {
      // 多时间戳行 + Enhanced LRC: [00:01.00][00:05.00]<00:01.00>这<00:01.50>是
      const content = '''
[00:01.00][00:05.00]<00:01.00>这<00:01.50>是<00:02.00>歌<00:02.50>词
''';
      final lyrics = LyricParser.parse(content);

      // Enhanced LRC 优先，只生成 1 行（用第一个时间戳）
      expect(lyrics.length, 1);

      // 验证没有叠词
      final line = lyrics[0];
      expect(line.hasWordTimestamps, isTrue);
      final wordTexts = line.words!.map((w) => w.text).toList();
      for (int i = 1; i < wordTexts.length; i++) {
        expect(wordTexts[i], isNot(wordTexts[i - 1]),
            reason: '发现叠词: "$wordTexts" 在位置 $i');
      }
      expect(wordTexts, ['这', '是', '歌', '词']);
    });

    test('No duplicate words: adjacent same timestamps', () {
      // 相邻相同时间戳: [00:01.00]这[00:01.00]是
      const content = '''
[00:01.00]这[00:01.00]是[00:01.00]歌
''';
      final lyrics = LyricParser.parse(content);

      expect(lyrics.length, 1);
      final line = lyrics[0];
      expect(line.hasWordTimestamps, isTrue);
      final wordTexts = line.words!.map((w) => w.text).toList();
      expect(wordTexts, ['这', '是', '歌']);
    });

    test('No duplicate words: space between words', () {
      // 字之间有空格
      const content = '''
[00:01.00]这 [00:01.50]是 [00:02.00]歌
''';
      final lyrics = LyricParser.parse(content);

      expect(lyrics.length, 1);
      final line = lyrics[0];
      expect(line.hasWordTimestamps, isTrue);
      final wordTexts = line.words!.map((w) => w.text).toList();
      // 空格应该被 trim 掉
      expect(wordTexts, ['这', '是', '歌']);
    });

    test('No duplicate words: "我们" should not become "我们们"', () {
      // 模拟用户报告的叠词场景：最后一个字重复
      const content = '''
[00:01.00]<00:01.00>我<00:01.50>们
''';
      final lyrics = LyricParser.parse(content);
      expect(lyrics.length, 1);
      final line = lyrics[0];
      expect(line.text, '我们');
      expect(line.hasWordTimestamps, isTrue);
      final wordTexts = line.words!.map((w) => w.text).toList();
      expect(wordTexts, ['我', '们']);
      // 逐字拼接应等于行文本
      expect(wordTexts.join(), line.text);
    });

    test('No duplicate words: "自己按门铃" should not duplicate chars', () {
      // 模拟用户报告的：自己按门铃 → 自己按按门铃铃
      const content = '''
[00:01.00]<00:01.00>自<00:01.20>己<00:01.40>按<00:01.60>门<00:01.80>铃
''';
      final lyrics = LyricParser.parse(content);
      expect(lyrics.length, 1);
      final line = lyrics[0];
      expect(line.text, '自己按门铃');
      expect(line.hasWordTimestamps, isTrue);
      final wordTexts = line.words!.map((w) => w.text).toList();
      expect(wordTexts, ['自', '己', '按', '门', '铃']);
      expect(wordTexts.join(), line.text);
    });

    test('No duplicate words: pure bracket format single line', () {
      // 纯方括号逐字格式
      const content = '''
[00:01.00]我[00:01.50]们
''';
      final lyrics = LyricParser.parse(content);
      expect(lyrics.length, 1);
      final line = lyrics[0];
      expect(line.text, '我们');
      expect(line.hasWordTimestamps, isTrue);
      final wordTexts = line.words!.map((w) => w.text).toList();
      expect(wordTexts, ['我', '们']);
      expect(wordTexts.join(), line.text);
    });

    test('No duplicate words: Enhanced LRC standard format (line text + word timestamps)', () {
      // 标准 Enhanced LRC 格式: [time]完整行文本<time>字<time>字
      // 行文本和逐字文本都包含，rawText 会有叠词，但 line.text 应从 words 拼接
      const content = '''
[00:01.00]我们<00:01.00>我<00:01.50>们
''';
      final lyrics = LyricParser.parse(content);
      expect(lyrics.length, 1);
      final line = lyrics[0];
      expect(line.text, '我们');
      expect(line.hasWordTimestamps, isTrue);
      final wordTexts = line.words!.map((w) => w.text).toList();
      expect(wordTexts, ['我', '们']);
      expect(wordTexts.join(), line.text);
    });

    test('No duplicate words: pure bracket mixed format (line text + word timestamps)', () {
      // 纯方括号混合格式: [time]完整行文本[time]字[time]字
      // 第一个文本段是完整行文本，后续是逐字
      const content = '''
[00:01.00]我们[00:01.00]我[00:01.50]们
''';
      final lyrics = LyricParser.parse(content);
      expect(lyrics.length, 1);
      final line = lyrics[0];
      expect(line.text, '我们');
      expect(line.hasWordTimestamps, isTrue);
      final wordTexts = line.words!.map((w) => w.text).toList();
      expect(wordTexts, ['我', '们']);
      expect(wordTexts.join(), line.text);
    });

    test('No duplicate words: mixed format with 5 chars', () {
      // 模拟用户报告的"自己按门铃"场景
      const content = '''
[00:01.00]自己按门铃[00:01.00]自[00:01.20]己[00:01.40]按[00:01.60]门[00:01.80]铃
''';
      final lyrics = LyricParser.parse(content);
      expect(lyrics.length, 1);
      final line = lyrics[0];
      expect(line.text, '自己按门铃');
      expect(line.hasWordTimestamps, isTrue);
      final wordTexts = line.words!.map((w) => w.text).toList();
      expect(wordTexts, ['自', '己', '按', '门', '铃']);
      expect(wordTexts.join(), line.text);
    });

    test('Pure bracket word-by-word should NOT be treated as mixed format', () {
      // 标准逐字格式（第一个字就是单字）不应被误判为混合格式
      const content = '''
[00:01.00]这[00:01.50]是[00:02.00]测[00:02.50]试
''';
      final lyrics = LyricParser.parse(content);
      expect(lyrics.length, 1);
      final line = lyrics[0];
      expect(line.text, '这是测试');
      expect(line.hasWordTimestamps, isTrue);
      final wordTexts = line.words!.map((w) => w.text).toList();
      expect(wordTexts, ['这', '是', '测', '试']);
      expect(wordTexts.join(), line.text);
    });

    test('Words with multi-byte characters should work correctly', () {
      // 英文/数字等多字符"字"的逐字格式
      const content = '''
[00:01.00]Hello World<00:01.00>Hello<00:01.50> World
''';
      final lyrics = LyricParser.parse(content);
      expect(lyrics.length, 1);
      final line = lyrics[0];
      expect(line.hasWordTimestamps, isTrue);
      final wordTexts = line.words!.map((w) => w.text).toList();
      expect(wordTexts.join(), line.text);
    });

    test('Verify words text matches line text for Enhanced LRC', () {
      const content = '''
[00:01.00]<00:01.00>这<00:01.50>是<00:02.00>歌<00:02.50>词
[00:04.00]<00:04.00>第<00:04.40>二<00:04.80>行
''';
      final lyrics = LyricParser.parse(content);

      for (final line in lyrics) {
        if (line.hasWordTimestamps) {
          final wordsText = line.words!.map((w) => w.text).join('');
          expect(wordsText, line.text,
              reason: '逐字拼接后的文本应与整行文本一致');
        }
      }
    });
  });
}
