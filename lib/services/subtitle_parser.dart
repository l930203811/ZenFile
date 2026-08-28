/// 外挂字幕解析（SRT / ASS），用于 Flutter overlay 渲染，
/// 以保证字幕字号、位置滑块对所有字幕格式 100% 生效。
class SubtitleCue {
  final Duration start;
  final Duration end;
  final String text;

  const SubtitleCue(this.start, this.end, this.text);
}

class SubtitleParser {
  const SubtitleParser._();

  static List<SubtitleCue> parse(String content, {bool isAss = false}) {
    if (content.trim().isEmpty) return const [];
    return isAss ? _parseAss(content) : _parseSrt(content);
  }

  // ---------- SRT ----------

  static Duration _parseSrtTime(String s) {
    final parts = s.trim().split(':');
    if (parts.length != 3) return Duration.zero;
    final secParts = parts[2].split(',');
    final hours = int.tryParse(parts[0]) ?? 0;
    final minutes = int.tryParse(parts[1]) ?? 0;
    final seconds = int.tryParse(secParts[0]) ?? 0;
    final ms = secParts.length > 1
        ? int.tryParse(secParts[1].padRight(3, '0').substring(0, 3)) ?? 0
        : 0;
    return Duration(hours: hours, minutes: minutes, seconds: seconds, milliseconds: ms);
  }

  static List<SubtitleCue> _parseSrt(String content) {
    final cues = <SubtitleCue>[];
    final blocks = content.split(RegExp(r'\n\s*\n'));
    for (final raw in blocks) {
      final lines = raw.split('\n').where((l) => l.trim().isNotEmpty).toList();
      if (lines.isEmpty) continue;
      var startIdx = 0;
      // 跳过纯数字序号行
      if (int.tryParse(lines[0].trim()) != null) startIdx = 1;
      if (startIdx >= lines.length) continue;
      final timeLine = lines[startIdx];
      final arrowIdx = timeLine.indexOf('-->');
      if (arrowIdx < 0) continue;
      final start = _parseSrtTime(timeLine.substring(0, arrowIdx));
      final end = _parseSrtTime(timeLine.substring(arrowIdx + 3));
      final text = lines.sublist(startIdx + 1).join('\n').trim();
      if (text.isEmpty) continue;
      cues.add(SubtitleCue(start, end, text));
    }
    cues.sort((a, b) => a.start.compareTo(b.start));
    return cues;
  }

  // ---------- ASS / SSA ----------

  static Duration _parseAssTime(String s) {
    final parts = s.trim().split(':');
    if (parts.length != 3) return Duration.zero;
    final secParts = parts[2].split('.');
    final hours = int.tryParse(parts[0]) ?? 0;
    final minutes = int.tryParse(parts[1]) ?? 0;
    final seconds = int.tryParse(secParts[0]) ?? 0;
    final cs = secParts.length > 1
        ? int.tryParse(secParts[1].padRight(2, '0').substring(0, 2)) ?? 0
        : 0;
    return Duration(hours: hours, minutes: minutes, seconds: seconds, milliseconds: cs * 10);
  }

  static String _cleanAssText(String text) {
    return text
        .replaceAll(RegExp(r'\{\\[^}]*\}'), '') // 去除 {\...} 样式标签
        .replaceAll(r'\N', '\n') // ASS 换行符
        .replaceAll(r'\n', '\n')
        .replaceAll(r'\h', ' ')
        .replaceAll(r'\t', ' ')
        .trim();
  }

  static List<SubtitleCue> _parseAss(String content) {
    final cues = <SubtitleCue>[];
    final lines = content.split('\n');
    var inEvents = false;
    var textIdx = -1;
    for (final line in lines) {
      final trimmed = line.trim();
      if (trimmed.startsWith('[')) {
        inEvents = trimmed == '[Events]';
        continue;
      }
      if (!inEvents) continue;
      if (trimmed.startsWith('Format:')) {
        final fields = trimmed.substring(7).split(',').map((e) => e.trim()).toList();
        textIdx = fields.indexOf('Text');
        continue;
      }
      if (trimmed.startsWith('Dialogue:')) {
        final body = trimmed.substring(9);
        final fields = body.split(',');
        if (textIdx < 0 || fields.length <= textIdx) continue;
        final start = _parseAssTime(fields[1]);
        final end = _parseAssTime(fields[2]);
        final text = _cleanAssText(fields.sublist(textIdx).join(','));
        if (text.isEmpty) continue;
        cues.add(SubtitleCue(start, end, text));
      }
    }
    cues.sort((a, b) => a.start.compareTo(b.start));
    return cues;
  }
}
