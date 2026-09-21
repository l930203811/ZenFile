/// IM（QQ / 微信 / TIM）追加序号后缀的**纯字符串**归一化逻辑。
///
/// 背景：这些 IM 在目标目录已存在同名文件时，会把新上传的文件重命名成
/// 「原名.序号」——典型就是 `app.apk` 被传成 `app.apk.1`。此时
/// `p.extension()` / `endsWith('.apk')` 全部失效：图标、分类、缩略图、
/// 打开方式、安装入口统统识别不了（`.apk.1` 还会被当成 zip bundle 去解压安装）。
///
/// 规则：剥掉「末尾纯数字、且点号前已有扩展名」的追加段（`.1` … `.9999`）
///   - `app.apk.1` → `app.apk`、`movie.mp4.2` → `movie.mp4`
///   - **保留** `.001` 这类前导零（zip 分卷的真实扩展名）
///   - **不剥** `README.1`：点号前没有扩展名，可能是用户真实文件名，不猜
///   - `archive.tar.gz` 末尾不是数字，天然不受影响
///
/// 本文件**不依赖 Flutter**，便于 `remote_media_playlist.dart` 这类纯逻辑模块
/// 复用与单测（见 test/core/im_suffix_extension_test.dart）。
/// 应用层统一走 `FileUtils` 上的同名静态方法（内部委托到这里）。
library;

/// 路径最后一段（同时兼容 `/` 与 `\` 分隔符）。
String lastPathSegment(String path) {
  final slash = path.lastIndexOf('/');
  final backslash = path.lastIndexOf('\\');
  final cut = slash > backslash ? slash : backslash;
  return path.substring(cut + 1);
}

/// 文件名是否带 IM 追加的序号后缀（如 `app.apk.1`）。
bool hasImAppendedSuffix(String name) {
  final dot = name.lastIndexOf('.');
  if (dot <= 0 || dot == name.length - 1) return false;
  final tail = name.substring(dot + 1);
  if (tail.isEmpty || tail.length > 4) return false;
  // 前导零（`.001`）一律不剥：那是 zip/rar 分卷的真实扩展名。
  if (tail.startsWith('0')) return false;
  for (var i = 0; i < tail.length; i++) {
    final c = tail.codeUnitAt(i);
    if (c < 0x30 || c > 0x39) return false;
  }
  // 必须是「名字.扩展名.序号」——点号前得先有一个扩展名才算 IM 追加。
  return name.substring(0, dot).contains('.');
}

/// 去掉 IM 追加的序号后缀；无该后缀时原样返回（支持完整路径，只处理最后一段）。
String stripImAppendedSuffix(String path) {
  final name = lastPathSegment(path);
  if (!hasImAppendedSuffix(name)) return path;
  return path.substring(0, path.length - name.length) +
      name.substring(0, name.lastIndexOf('.'));
}

/// 取文件名扩展名（含点，小写），无扩展名返回空串。
///
/// 已自动忽略 IM 追加的序号后缀：`app.apk.1` → `.apk`。
/// 前导点不算扩展名（`.nomedia` → 空串）。
String effectiveExtensionWithDot(String path) {
  final name = lastPathSegment(stripImAppendedSuffix(path));
  final dot = name.lastIndexOf('.');
  if (dot <= 0 || dot == name.length - 1) return '';
  return name.substring(dot).toLowerCase();
}

/// 取文件名扩展名（不含点，小写），无扩展名返回空串。`app.apk.1` → `apk`
String effectiveExtension(String path) {
  final ext = effectiveExtensionWithDot(path);
  return ext.isEmpty ? '' : ext.substring(1);
}
