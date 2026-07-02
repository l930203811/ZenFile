import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'preferences_service.dart';

/// 单个歌词字/词
class LyricWord {
  final Duration timestamp;
  final String text;

  LyricWord({required this.timestamp, required this.text});

  @override
  String toString() => 'LyricWord(${timestamp.inMilliseconds}ms: "$text")';
}

/// 单行歌词
class LyricLine {
  final Duration timestamp;
  final String text;
  final List<LyricWord>? words;

  LyricLine({
    required this.timestamp,
    required this.text,
    this.words,
  });

  bool get hasWordTimestamps => words != null && words!.isNotEmpty;

  @override
  String toString() => 'LyricLine(${timestamp.inMilliseconds}ms: $text)';
}

/// 时间戳匹配信息
class _TimestampMatch {
  final int start;
  final int end;
  final Duration duration;

  _TimestampMatch(this.start, this.end, this.duration);
}

/// LRC 歌词解析器
/// 支持:
/// - 传统格式: [00:12.34]歌词文本
/// - 多时间戳: [00:12.34][01:23.45]重复歌词
/// - 逐字时间戳(卡拉OK): [00:12.34]这[00:12.56]是[00:12.78]歌词
/// - Enhanced LRC: [00:12.34]<00:12.34>这<00:12.56>是<00:12.78>歌词
/// - 元数据标签: [ti:], [ar:], [al:], [by:], [offset:]
class LyricParser {
  /// 方括号时间戳: [mm:ss.xx] 或 [mm:ss.xxx]
  static final _bracketTimeRegex =
      RegExp(r'\[(\d{1,3}):(\d{1,2})(?:[.:](\d{1,3}))?\]');

  /// 尖括号时间戳: <mm:ss.xx> (Enhanced LRC 逐字格式)
  static final _angleTimeRegex =
      RegExp(r'<(\d{1,3}):(\d{1,2})(?:[.:](\d{1,3}))?>');

  /// 解析时间戳字符串为 Duration
  static Duration _parseTimeStr(String minutes, String seconds, String? fraction) {
    final mins = int.parse(minutes);
    final secs = int.parse(seconds);
    final fracStr = fraction ?? '0';

    int frac;
    if (fracStr.length == 2) {
      frac = int.parse(fracStr) * 10; // 转为毫秒
    } else if (fracStr.length == 3) {
      frac = int.parse(fracStr);
    } else {
      frac = int.tryParse(fracStr) ?? 0;
    }

    return Duration(minutes: mins, seconds: secs, milliseconds: frac);
  }

  /// 在原始行中查找所有方括号时间戳
  static List<_TimestampMatch> _findAllBracketTimestamps(String line) {
    final result = <_TimestampMatch>[];
    for (final m in _bracketTimeRegex.allMatches(line)) {
      final dur = _parseTimeStr(m.group(1)!, m.group(2)!, m.group(3));
      result.add(_TimestampMatch(m.start, m.end, dur));
    }
    return result;
  }

  /// 在原始行中查找所有尖括号时间戳
  static List<_TimestampMatch> _findAllAngleTimestamps(String line) {
    final result = <_TimestampMatch>[];
    for (final m in _angleTimeRegex.allMatches(line)) {
      final dur = _parseTimeStr(m.group(1)!, m.group(2)!, m.group(3));
      result.add(_TimestampMatch(m.start, m.end, dur));
    }
    return result;
  }

  /// 清理文本中的所有时间戳残留（安全网）
  static final _cleanupBracketRegex = RegExp(r'\[[^\]]*\]');
  static final _cleanupAngleRegex = RegExp(r'<[^>]*>');
  static String _cleanText(String text) {
    return text
        .replaceAll(_cleanupBracketRegex, '')
        .replaceAll(_cleanupAngleRegex, '')
        .trim();
  }

  /// 解析 LRC 文件内容，返回按时间排序的歌词行列表。
  static List<LyricLine> parse(String content) {
    final lines = <LyricLine>[];
    int offsetMs = 0;

    for (final rawLine in content.split('\n')) {
      final line = rawLine.trim();
      if (line.isEmpty) continue;

      // 检查 offset 元数据
      final offsetMatch = RegExp(r'\[offset:\s*(-?\d+)\]').firstMatch(line);
      if (offsetMatch != null) {
        offsetMs = int.tryParse(offsetMatch.group(1)!) ?? 0;
        continue;
      }

      // 跳过其他元数据标签
      if (RegExp(r'^\[(ti|ar|al|by|length|re|ve):').hasMatch(line)) {
        continue;
      }

      // 查找方括号时间戳
      final bracketTimes = _findAllBracketTimestamps(line);
      if (bracketTimes.isEmpty) continue;

      // 查找尖括号时间戳（Enhanced LRC 逐字格式）
      final angleTimes = _findAllAngleTimestamps(line);

      // 纯文本：移除所有时间戳标签（双重清理确保无残留）
      final rawText = _cleanText(line);

      if (rawText.isEmpty) continue;

      // 判断是否是逐字格式
      // Enhanced LRC (有尖括号) 一定是逐字
      // 纯方括号格式需要区分: 逐字 vs 多时间戳行
      //   逐字: [00:01.00]这[00:01.50]是[00:02.00]歌 (时间戳分散在文字中)
      //   多时间戳行: [00:01.00][00:05.00]这是歌词 (时间戳连续在行首)
      bool isWordByWord = false;
      if (angleTimes.isNotEmpty) {
        isWordByWord = true;
      } else if (bracketTimes.length > 1) {
        // 检查相邻方括号时间戳之间是否有文字
        // 如果所有相邻时间戳之间都没有文字，则是多时间戳行（非逐字）
        // 如果有文字，则是逐字格式
        bool hasTextBetweenTimestamps = false;
        for (int i = 0; i < bracketTimes.length - 1; i++) {
          final textBetween = line
              .substring(bracketTimes[i].end, bracketTimes[i + 1].start)
              .trim();
          if (textBetween.isNotEmpty) {
            hasTextBetweenTimestamps = true;
            break;
          }
        }
        isWordByWord = hasTextBetweenTimestamps;
      }

      List<LyricWord>? words;

      if (isWordByWord) {
        if (angleTimes.isNotEmpty) {
          // Enhanced LRC 格式:
          //   标准格式: [mm:ss.xx]行文本<mm:ss.xx>字<mm:ss.xx>字
          //   紧凑格式: [mm:ss.xx]<mm:ss.xx>字<mm:ss.xx>字
          // 从尖括号后提取逐字文本
          words = <LyricWord>[];

          final allTimes = <_TimestampMatch>[
            ...bracketTimes,
            ...angleTimes,
          ]..sort((a, b) => a.start.compareTo(b.start));

          for (int i = 0; i < angleTimes.length; i++) {
            final ts = angleTimes[i];
            int textStart = ts.end;
            int textEnd = line.length;
            for (final t in allTimes) {
              if (t.start > textStart) {
                textEnd = t.start;
                break;
              }
            }
            final wordText = _cleanText(line.substring(textStart, textEnd));
            if (wordText.isNotEmpty) {
              words.add(LyricWord(
                timestamp: Duration(
                  milliseconds: ts.duration.inMilliseconds + offsetMs,
                ),
                text: wordText,
              ));
            }
          }
        } else {
          // 纯方括号逐字格式:
          //   标准逐字: [mm:ss.xx]字[mm:ss.xx]字[mm:ss.xx]字
          //   行文本+逐字混合: [mm:ss.xx]行文本[mm:ss.xx]字[mm:ss.xx]字
          // 对于混合格式：第一个时间戳后如果是完整行文本（长度 > 单字且后续时间戳之间都是单字），
          // 则跳过第一个文本段，从第二个时间戳开始提取逐字。
          words = <LyricWord>[];

          final wordTexts = <String>[];
          for (int i = 0; i < bracketTimes.length; i++) {
            final ts = bracketTimes[i];
            int textStart = ts.end;
            int textEnd = line.length;
            if (i + 1 < bracketTimes.length) {
              textEnd = bracketTimes[i + 1].start;
            }
            final wordText = _cleanText(line.substring(textStart, textEnd));
            wordTexts.add(wordText);
          }

          // 检测是否为"行文本+逐字"混合格式：
          // 第一个文本段长度 > 1，且后续所有文本段长度都 <= 1（或数量上明显是逐字结构）
          bool isMixedFormat = false;
          if (wordTexts.length >= 3 && wordTexts.first.length > 1) {
            final restAllSingleChar = wordTexts
                .skip(1)
                .every((w) => w.length <= 2); // 允许2字符（如英文单词、数字）
            final firstEqualsRestJoined =
                wordTexts.first == wordTexts.skip(1).join('');
            isMixedFormat = restAllSingleChar || firstEqualsRestJoined;
          }

          final startIdx = isMixedFormat ? 1 : 0;
          for (int i = startIdx; i < bracketTimes.length; i++) {
            final wordText = wordTexts[i];
            if (wordText.isNotEmpty) {
              words.add(LyricWord(
                timestamp: Duration(
                  milliseconds: bracketTimes[i].duration.inMilliseconds + offsetMs,
                ),
                text: wordText,
              ));
            }
          }
        }
      }

      // 逐字格式的行文本：从 words 拼接，避免 Enhanced LRC 标准格式
      // 中"行文本+逐字文本"被同时包含在 rawText 里导致叠词
      final lineText = isWordByWord && words != null && words.isNotEmpty
          ? words.map((w) => w.text).join('')
          : rawText;

      // 多时间戳行: 为每个时间戳创建一个 LyricLine（相同文本，不同时间）
      // 逐字格式: 只用第一个时间戳作为行时间戳
      if (isWordByWord) {
        final lyricLine = LyricLine(
          timestamp: Duration(
            milliseconds: bracketTimes.first.duration.inMilliseconds + offsetMs,
          ),
          text: lineText,
          words: words != null && words.isNotEmpty ? words : null,
        );
        _logParsedLine(line, bracketTimes, angleTimes, lineText, lyricLine);
        lines.add(lyricLine);
      } else {
        // 多时间戳行: 每个时间戳生成一行
        for (final ts in bracketTimes) {
          final lyricLine = LyricLine(
            timestamp: Duration(
              milliseconds: ts.duration.inMilliseconds + offsetMs,
            ),
            text: rawText,
            words: null,
          );
          _logParsedLine(line, bracketTimes, angleTimes, rawText, lyricLine);
          lines.add(lyricLine);
        }
      }
    }

    lines.sort((a, b) => a.timestamp.compareTo(b.timestamp));
    if (kDebugMode) {
      final wordByWordCount = lines.where((l) => l.hasWordTimestamps).length;
      debugPrint('[LrcParse] total=${lines.length} wordByWordLines=$wordByWordCount');
    }
    return lines;
  }

  /// 调试日志输出
  static void _logParsedLine(String line, List<_TimestampMatch> bracketTimes,
      List<_TimestampMatch> angleTimes, String rawText, LyricLine lyricLine) {
    if (!kDebugMode) return;
    final displayLine = line.length > 80 ? '${line.substring(0, 80)}...' : line;
    debugPrint('[LrcParse] line="$displayLine"');
    debugPrint('[LrcParse]   brackets=${bracketTimes.length} angles=${angleTimes.length} text="$rawText" wordByWord=${lyricLine.hasWordTimestamps}');
    if (lyricLine.hasWordTimestamps) {
      debugPrint('[LrcParse]   words=${lyricLine.words!.map((w) => '"${w.text}"@${w.timestamp.inMilliseconds}ms').join(', ')}');
    }
  }

  /// 从文件路径加载并解析 LRC 歌词
  static List<LyricLine>? loadFromFile(String lrcPath) {
    try {
      final file = File(lrcPath);
      if (!file.existsSync()) return null;
      final bytes = file.readAsBytesSync();
      String content;
      try {
        content = utf8.decode(bytes);
      } catch (_) {
        try {
          content = const Utf8Decoder(allowMalformed: true).convert(bytes);
        } catch (_) {
          content = systemEncoding.decode(bytes);
        }
      }
      final lines = parse(content);
      return lines.isEmpty ? null : lines;
    } catch (_) {
      return null;
    }
  }

  /// 根据音频文件路径自动查找同名 .lrc 歌词文件
  static ({List<LyricLine> lyrics, String sourcePath})? loadLyricForAudio(String audioPath) {
    try {
      final savedLrcPath = PreferencesService.getLyricMapping(audioPath);
      if (savedLrcPath != null) {
        final lyrics = loadFromFile(savedLrcPath);
        if (lyrics != null) return (lyrics: lyrics, sourcePath: savedLrcPath);
      }
    } catch (_) {}

    final dir = p.dirname(audioPath);
    final baseName = p.basenameWithoutExtension(audioPath);

    for (final ext in ['.lrc', '.LRC']) {
      final lrcPath = p.join(dir, '$baseName$ext');
      final lyrics = loadFromFile(lrcPath);
      if (lyrics != null) return (lyrics: lyrics, sourcePath: lrcPath);
    }

    try {
      final directory = Directory(dir);
      if (directory.existsSync()) {
        final baseLower = baseName.toLowerCase();
        for (final entry in directory.listSync(followLinks: false)) {
          if (entry is! File) continue;
          final entryName = p.basename(entry.path);
          final entryExt = p.extension(entryName).toLowerCase();
          if (entryExt != '.lrc') continue;
          final entryBase = p.basenameWithoutExtension(entryName);
          if (entryBase.toLowerCase() == baseLower) {
            final lyrics = loadFromFile(entry.path);
            if (lyrics != null) return (lyrics: lyrics, sourcePath: entry.path);
          }
        }
      }
    } catch (_) {}

    return null;
  }

  /// 根据音频文件路径自动查找同名 .lrc 歌词文件
  static List<LyricLine>? autoLoadForAudio(String audioPath) {
    return loadLyricForAudio(audioPath)?.lyrics;
  }

  /// 根据当前播放位置找到对应的歌词行索引
  static int findCurrentLineIndex(List<LyricLine> lines, Duration position) {
    if (lines.isEmpty) return -1;
    final posMs = position.inMilliseconds;

    int left = 0;
    int right = lines.length - 1;
    int result = -1;

    while (left <= right) {
      final mid = (left + right) ~/ 2;
      if (lines[mid].timestamp.inMilliseconds <= posMs) {
        result = mid;
        left = mid + 1;
      } else {
        right = mid - 1;
      }
    }

    return result;
  }

  /// 在逐字歌词行中找到当前应该高亮的字索引
  static int findCurrentWordIndex(LyricLine line, Duration position) {
    if (!line.hasWordTimestamps) return -1;

    final posMs = position.inMilliseconds;
    final words = line.words!;

    for (int i = words.length - 1; i >= 0; i--) {
      if (words[i].timestamp.inMilliseconds <= posMs) {
        return i;
      }
    }

    return -1;
  }
}
