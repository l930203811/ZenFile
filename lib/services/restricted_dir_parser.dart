/// 受限目录（Android/{data,obb}、/data 等）列目录输出的**纯解析逻辑**。
///
/// 抽成不依赖 Flutter / MethodChannel 的纯函数，便于单测
/// （见 test/services/restricted_dir_parser_test.dart）。
///
/// 背景：这些目录在 Android 11+ 上被 FUSE 拦截，Dart IO 列不出来，必须经
/// root/Shizuku 在**底层 ext4 路径 `/data/media/0/...`** 上执行 find/ls。
/// 而 shell 侧的环境受 ROM 差异影响很大（find 缺失、`-exec ... {} +` 不支持、
/// su 的 PATH / mount namespace 不同），因此这里同时支持多种输出格式，
/// 并把路径统一还原成用户可见的 `/storage/emulated/0/...`。
library;

import 'package:path/path.dart' as p;

/// 主存储在 App 内统一使用的用户可见路径前缀。
const String kStorageRoot = '/storage/emulated/0';

/// 底层 ext4 路径前缀（绕开 FUSE 用）。Android 11+ 上它才是
/// `/storage/emulated/0` 的真实后端，访问它不受 FUSE 的 Android/data 拦截。
const String kRawStorageRoot = '/data/media/0';

/// 用户可见路径 → 底层路径。
///
/// 只对 `/storage/emulated/0/Android/` 下的内容做转换：只有 Android/{data,obb}
/// 需要绕 FUSE，其余路径保持原样——否则调用方会拿到一个系统里并不存在的
/// `/data/media/0/foo` 路径。
String toFuseBypassPath(String path) {
  final normalized = path.replaceAll(RegExp(r'/+'), '/');
  if (normalized.startsWith('$kStorageRoot/Android/')) {
    return normalized.replaceFirst(
        '$kStorageRoot/Android/', '$kRawStorageRoot/Android/');
  }
  return normalized;
}

/// 底层路径 → 用户可见路径。
///
/// 保证条目 path 始终是 `/storage/emulated/0/...`，与普通路径体系一致
/// （打开、复制、删除、重命名都以它为准），避免路径分裂成两套。
String fromFuseBypassPath(String path) {
  if (path.startsWith('$kRawStorageRoot/Android/')) {
    return path.replaceFirst(
        '$kRawStorageRoot/Android/', '$kStorageRoot/Android/');
  }
  return path;
}

/// 传给 `find` / `ls` 的目录参数。
///
/// 调用侧对**文件系统根目录**用空串当「空前缀」（历史写法 `for f in /* /.*`
/// 需要它，见 root_shizuku_service.listFiles）。但换成 `find "$dir"` / `ls -la "$dir"`
/// 之后，空串会让命令直接报错（toybox：`find: '': No such file or directory`），
/// 三条策略全部拿不到输出 → 静默返回空 → **「root/Shizuku 授权后打开系统根目录
/// 一片空白」**（命令压根没跑成，不是权限问题）。这里统一把空串还原成 `/`。
String shellListDirArg(String dir) {
  final d = dir.trim();
  return d.isEmpty ? '/' : d;
}

/// 一条受限目录条目（纯数据，便于单测；调用方自行转成 FileItemModel）。
class RestrictedDirEntry {
  final String path;
  final String name;
  final bool isDirectory;
  final int size;
  final DateTime modified;

  const RestrictedDirEntry({
    required this.path,
    required this.name,
    required this.isDirectory,
    required this.size,
    required this.modified,
  });
}

bool _isHidden(String name) =>
    name.startsWith('.') && name != '.' && name != '..';

/// 解析 `stat -L -c "%F|%s|%Y|%n"` 的输出。
///
/// 该格式同时由两条链路产生：
/// ① `find ... -exec stat ... {} +`（一次取回，进程数最少，首选）；
/// ② `find ... | while read; do stat ...; done`（find 不支持 `-exec +` 时）。
///
/// **刻意不要求调用方用 `2>/dev/null` 吞错误**：无法识别的行（例如混进来的
/// stderr 文本、toybox 缺 `%F` 时打出的告警）在这里被过滤掉，而原始文本仍可
/// 由调用方记录到诊断日志——这正是过去「明明列不出却查不到原因」的关键。
List<RestrictedDirEntry> parseStatPipeLines(
  String output, {
  required bool showHiddenFiles,
}) {
  final items = <RestrictedDirEntry>[];
  for (final line in output.split('\n')) {
    final trimmed = line.trim();
    if (trimmed.isEmpty) continue;
    final parts = trimmed.split('|');
    if (parts.length < 4) continue;

    // 字段必须是「类型 | 数字 | 数字 | 路径」，用它挡住把 stderr 当数据。
    final size = int.tryParse(parts[1].trim());
    final seconds = int.tryParse(parts[2].trim());
    if (size == null || seconds == null || size < 0) continue;

    // 文件名本身可能含 '|'，所以从第 4 个字段起重新拼回。
    final rawPath = parts.sublist(3).join('|').trim();
    if (rawPath.isEmpty) continue;

    final path = fromFuseBypassPath(rawPath);
    final name = p.basename(path);
    if (name.isEmpty) continue;
    if (!showHiddenFiles && _isHidden(name)) continue;

    items.add(RestrictedDirEntry(
      path: path,
      name: name,
      isDirectory: parts[0].toLowerCase().contains('directory'),
      size: size,
      modified: DateTime.fromMillisecondsSinceEpoch(seconds * 1000),
    ));
  }
  return items;
}

/// 解析 `ls -la` / `ls -l` 输出（toybox，兼容 coreutils 格式）。
///
/// 仅在 find 完全不可用时兜底：目录结构一定正确，但时间戳可能只能近似
/// （`Mon DD HH:mm` 没有年份 → 按当年处理），大小取 ls 给出的字节数。
///
/// 样例：
/// ```
/// total 24
/// drwxrwx--x  3 u0_a123 u0_a123 4096 2024-01-02 12:34 com.tencent.mm
/// -rw-r--r--  1 u0_a123 u0_a123  123 Jan  2 12:34 note.txt
/// lrwxrwxrwx  1 root    root      10 Jan  2  2023 link -> /data/x
/// ```
List<RestrictedDirEntry> parseLsLongOutput(
  String output, {
  required String dir,
  required bool showHiddenFiles,
}) {
  // 剥掉结尾斜杠（`/storage/emulated/0/` → `/storage/emulated/0`），
  // 但**根目录不能剥**：`/` 只剩一个斜杠，剥掉会让条目变成 `system` 这种
  // 相对路径；同时也不能让 base 变成 `//`，否则条目是 `//system`。
  final trimmed = dir.length > 1 && dir.endsWith('/')
      ? dir.substring(0, dir.length - 1)
      : dir;
  final base = (trimmed.isEmpty || trimmed == '/') ? '' : trimmed;
  final items = <RestrictedDirEntry>[];
  // 权限串后可能跟 '+'（ACL）或 '.'（SELinux），故留一个可选后缀位。
  final re = RegExp(
    r'^\s*([dlbcps-])[rwxsStT-]{9}[.+]?\s+\d+\s+\S+\s+\S+\s+(\d+)\s+'
    r'(\d{4}-\d{2}-\d{2}\s+\d{2}:\d{2}(?::\d{2})?|\S+\s+\d{1,2}\s+(?:\d{2}:\d{2}|\d{4}))'
    r'\s+(.+?)\s*$',
  );

  for (final line in output.split('\n')) {
    final m = re.firstMatch(line);
    if (m == null) continue;

    final typeChar = m.group(1)!;
    var name = m.group(4)!;
    var isDir = typeChar == 'd';

    // 符号链接：`name -> target`，只取链接名本身（目标不参与列表）。
    final arrow = name.indexOf(' -> ');
    if (typeChar == 'l' && arrow >= 0) {
      name = name.substring(0, arrow);
      isDir = false;
    }

    if (name.isEmpty || name == '.' || name == '..') continue;
    if (!showHiddenFiles && _isHidden(name)) continue;

    items.add(RestrictedDirEntry(
      path: fromFuseBypassPath('$base/$name'),
      name: name,
      isDirectory: isDir,
      size: int.tryParse(m.group(2)!) ?? 0,
      modified: _parseLsTime(m.group(3)!),
    ));
  }
  return items;
}

const Map<String, int> _lsMonths = {
  'jan': 1, 'feb': 2, 'mar': 3, 'apr': 4, 'may': 5, 'jun': 6,
  'jul': 7, 'aug': 8, 'sep': 9, 'oct': 10, 'nov': 11, 'dec': 12,
};

/// 解析 ls 的时间列：`yyyy-MM-dd HH:mm[:ss]` 或 `Mon DD HH:mm`（当年）
/// 或 `Mon DD YYYY`。识别不了返回 epoch（不影响列出条目）。
DateTime _parseLsTime(String text) {
  final t = text.trim();

  final iso = RegExp(r'^(\d{4})-(\d{2})-(\d{2})\s+(\d{2}):(\d{2})(?::(\d{2}))?$')
      .firstMatch(t);
  if (iso != null) {
    return DateTime(
      int.parse(iso.group(1)!),
      int.parse(iso.group(2)!),
      int.parse(iso.group(3)!),
      int.parse(iso.group(4)!),
      int.parse(iso.group(5)!),
      int.tryParse(iso.group(6) ?? '') ?? 0,
    );
  }

  final parts = t.split(RegExp(r'\s+'));
  if (parts.length == 3) {
    final month = _lsMonths[parts[0].toLowerCase()];
    final day = int.tryParse(parts[1]);
    if (month != null && day != null) {
      if (parts[2].contains(':')) {
        final hm = parts[2].split(':');
        return DateTime(
          DateTime.now().year,
          month,
          day,
          int.tryParse(hm[0]) ?? 0,
          int.tryParse(hm.length > 1 ? hm[1] : '0') ?? 0,
        );
      }
      final year = int.tryParse(parts[2]);
      if (year != null) return DateTime(year, month, day);
    }
  }

  return DateTime.fromMillisecondsSinceEpoch(0);
}
