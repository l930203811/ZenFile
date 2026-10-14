import 'package:zenfile/l10n/generated/app_localizations.dart';

/// 文件名（单段名）合法性问题类型。
enum FileNameProblem {
  /// 名称为空或全是空白字符。
  empty,

  /// 名称包含路径分隔符（/ 或 \）。
  separator,

  /// 名称是 . 或 ..（路径遍历段）。
  dotSegment,

  /// 名称包含控制字符（U+0000-U+001F / U+007F）。
  controlChar,

  /// 名称以 . 结尾（Windows/FAT 语义下会被静默剥离，且易与扩展名混淆）。
  trailingDot,
}

/// 校验 [name] 是否为合法的单段文件名：非空白、不含路径分隔符
/// （/ 或 \）、不是 . / ..、无控制字符、不以 . 结尾。
///
/// 背景：重命名 / 批量重命名 / 新建曾对用户输入零校验。名称里带入 '/'
/// 时 `p.join(dirname, name)` 会拼出嵌套路径（a.jpg → a.jpg/a.jpg），
/// rename() 因父目录不存在而失败，随后兜底逻辑会把父目录真的创建出来并
/// copy 进去——表现为「自动创建同名文件夹、文件躺在文件夹里」。批量
/// 重命名的「查找/替换」注入是另一条同源入口。
///
/// 合法返回 null；非法返回具体原因（由 UI 层映射为本地化文案）。
FileNameProblem? validateFileName(String name) {
  if (name.trim().isEmpty) return FileNameProblem.empty;
  if (name.contains('/') || name.contains('\\')) {
    return FileNameProblem.separator;
  }
  if (name == '.' || name == '..') return FileNameProblem.dotSegment;
  for (final unit in name.codeUnits) {
    if (unit < 0x20 || unit == 0x7F) return FileNameProblem.controlChar;
  }
  if (name.endsWith('.')) return FileNameProblem.trailingDot;
  return null;
}

/// 把 [name] 清洗为合法单段名（批量重命名等「自动修正」场景）：
/// 路径分隔符替换为 '_'、剥掉控制字符、去掉首尾空白与结尾的点。
/// 清洗结果为空时返回 null（调用方应放弃该条目）。
String? sanitizeFileName(String name) {
  var out = name.replaceAll('/', '_').replaceAll('\\', '_');
  out = out.replaceAll(RegExp(r'[\x00-\x1F\x7F]'), '');
  out = out.trim();
  while (out.endsWith('.')) {
    out = out.substring(0, out.length - 1).trim();
  }
  if (out.isEmpty) return null;
  return out;
}

/// 把 [problem] 映射为本地化文案（对话框警告 / SnackBar 共用）。
String fileNameProblemText(AppLocalizations l10n, FileNameProblem problem) {
  switch (problem) {
    case FileNameProblem.empty:
      return l10n.msg_please_enter_name;
    case FileNameProblem.separator:
      return l10n.msg_name_invalid_separator;
    case FileNameProblem.dotSegment:
      return l10n.msg_name_invalid_dot;
    case FileNameProblem.controlChar:
    case FileNameProblem.trailingDot:
      return l10n.msg_name_invalid_chars;
  }
}
