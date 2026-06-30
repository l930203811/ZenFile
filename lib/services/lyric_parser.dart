import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;
import 'preferences_service.dart';

/// 单行歌词
class LyricLine {
  final Duration timestamp;
  final String text;

  LyricLine({required this.timestamp, required this.text});

  @override
  String toString() => 'LyricLine(${timestamp.inMilliseconds}ms: $text)';
}

/// LRC 歌词解析器
class LyricParser {
  /// 解析 LRC 文件内容，返回按时间排序的歌词行列表。
  /// 支持:
  /// - 单时间戳: [00:12.34]歌词文本
  /// - 多时间戳: [00:12.34][01:23.45]重复歌词
  /// - 元数据标签: [ti:], [ar:], [al:], [by:], [offset:]
  static List<LyricLine> parse(String content) {
    final lines = <LyricLine>[];
    final timeRegex = RegExp(r'\[(\d{1,3}):(\d{1,2})(?:[.:](\d{1,3}))?\]');
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

      // 查找所有时间戳
      final matches = timeRegex.allMatches(line);
      if (matches.isEmpty) {
        // 没有时间戳的行，跳过（可能是无时间戳的纯文本歌词）
        continue;
      }

      // 提取歌词文本（移除所有时间戳标签后的剩余内容）
      final text = line.replaceAll(timeRegex, '').trim();

      for (final match in matches) {
        final minutes = int.parse(match.group(1)!);
        final seconds = int.parse(match.group(2)!);
        final fractionStr = match.group(3) ?? '0';
        // 支持两位或三位小数
        int fraction;
        if (fractionStr.length == 2) {
          fraction = int.parse(fractionStr) * 10; // 转为毫秒
        } else if (fractionStr.length == 3) {
          fraction = int.parse(fractionStr);
        } else {
          fraction = int.tryParse(fractionStr) ?? 0;
        }

        final timestamp = Duration(
          minutes: minutes,
          seconds: seconds,
          milliseconds: fraction + offsetMs,
        );
        lines.add(LyricLine(timestamp: timestamp, text: text));
      }
    }

    // 按时间排序
    lines.sort((a, b) => a.timestamp.compareTo(b.timestamp));
    return lines;
  }

  /// 从文件路径加载并解析 LRC 歌词
  /// 优先使用 UTF-8 解码，失败时回退到 systemEncoding（兼容 GBK 等）
  static List<LyricLine>? loadFromFile(String lrcPath) {
    try {
      final file = File(lrcPath);
      if (!file.existsSync()) return null;
      final bytes = file.readAsBytesSync();
      String content;
      try {
        content = utf8.decode(bytes);
      } catch (_) {
        // UTF-8 解码失败，回退到 systemEncoding（Windows 上可能是 GBK）
        content = systemEncoding.decode(bytes);
      }
      final lines = parse(content);
      return lines.isEmpty ? null : lines;
    } catch (_) {
      return null;
    }
  }

  /// 根据音频文件路径自动查找同名 .lrc 歌词文件，并返回歌词内容及来源路径。
  /// 查找顺序:
  /// 1. 检查已保存的手动映射（PreferencesService）
  /// 2. 同目录下同名 .lrc / .LRC
  /// 3. 同目录下模糊匹配（忽略大小写、忽略扩展名差异）
  static ({List<LyricLine> lyrics, String sourcePath})? loadLyricForAudio(String audioPath) {
    // 1. 检查已保存的手动映射
    try {
      final savedLrcPath = PreferencesService.getLyricMapping(audioPath);
      if (savedLrcPath != null) {
        final lyrics = loadFromFile(savedLrcPath);
        if (lyrics != null) return (lyrics: lyrics, sourcePath: savedLrcPath);
      }
    } catch (_) {}

    final dir = p.dirname(audioPath);
    final baseName = p.basenameWithoutExtension(audioPath);

    // 2. 尝试精确匹配 .lrc / .LRC
    for (final ext in ['.lrc', '.LRC']) {
      final lrcPath = p.join(dir, '$baseName$ext');
      final lyrics = loadFromFile(lrcPath);
      if (lyrics != null) return (lyrics: lyrics, sourcePath: lrcPath);
    }

    // 3. 模糊匹配：列出同目录下所有 .lrc 文件，忽略大小写比较文件名
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

  /// 根据音频文件路径自动查找同名 .lrc 歌词文件。
  /// 同 [loadLyricForAudio]，但仅返回歌词列表。
  static List<LyricLine>? autoLoadForAudio(String audioPath) {
    return loadLyricForAudio(audioPath)?.lyrics;
  }

  /// 根据当前播放位置找到对应的歌词行索引。
  /// 返回当前应该高亮的歌词行索引，如果没有歌词则返回 -1。
  static int findCurrentLineIndex(List<LyricLine> lines, Duration position) {
    if (lines.isEmpty) return -1;
    final posMs = position.inMilliseconds;

    // 二分查找
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
}
