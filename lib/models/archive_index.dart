// 压缩包「轻量索引」：只保留浏览 / 写链路真正需要的纯数据字段。
//
// 背景（v3.7.7 ANR 修复）：旧链路 ArchiveService.readArchive() 通过 compute()
// 把 package:archive 的完整 Archive 对象图回传主 isolate。ArchiveFile 内含惰性
// content / InputStream / FileBuffer 引用，跨隔离区边界要深拷贝整张对象图；大 RAR
// （koni_archive 会为每个条目 new 一个 ArchiveFile）会在主线程触发连续堆扩容与
// memcpy，栈上表现为 __memcpy_aarch64_simd / scudo::reallocate / realloc 后接
// 大量 libapp.so 重复帧，最终 Input dispatching timed out。
//
// 现在解析、文件名归一化、目录折叠、自然排序全部在 compute 隔离区内完成，主
// isolate 只收到由 String / int / bool 组成的纯数据；浏览目录时按 children
// O(1) 命中，不再每次全表扫描 + 全表排序。
//
// 本文件保持零外部 import（纯 Dart），以便安全地在隔离区之间传递。

/// 单个压缩包条目的纯数据快照（已归一化，不含任何文件内容 / 流引用）。
class ArchiveEntryInfo {
  const ArchiveEntryInfo({
    required this.name,
    required this.size,
    required this.isFile,
    this.lastModTime,
  });

  /// 归一化后的内部路径：反斜杠 → `/`，去掉前导 `/` 与 `./`。
  final String name;
  final int size;
  final bool isFile;

  /// 秒级修改时间；null 或 <= 0 表示无有效时间。
  final int? lastModTime;
}

/// 某目录下的一个「直接子项」（可能是深层条目折叠出来的目录）。
///
/// 与旧实现一致：目录项 size 恒 0；折叠目录取第一个贡献它的条目的修改时间。
class ArchiveDirItem {
  const ArchiveDirItem({
    required this.name,
    required this.fullPath,
    required this.isDirectory,
    required this.size,
    this.lastModTime,
  });

  final String name;

  /// 归一化后的完整内部路径（目录带尾 `/`，文件不带）。
  final String fullPath;
  final bool isDirectory;
  final int size;
  final int? lastModTime;
}

/// 一次解析产出的索引。可安全跨 isolate 传递：字段全是基本类型 / 简单集合。
class ArchiveIndex {
  const ArchiveIndex({
    required this.entries,
    required this.children,
    this.hasEncryptedEntries = false,
  });

  static const ArchiveIndex empty = ArchiveIndex(
    entries: <ArchiveEntryInfo>[],
    children: <String, List<ArchiveDirItem>>{},
  );

  /// 全量条目（供解压 / 重命名 / 粘贴等写链路枚举子树）。
  final List<ArchiveEntryInfo> entries;

  /// 目录索引：key = 父目录内部路径（带尾 `/`，根为 `''`）；
  /// value = 该目录已按「目录在前 + 自然序」排好的直接子项。
  final Map<String, List<ArchiveDirItem>> children;

  /// ZIP 中央目录里存在加密条目（供浏览页提前提示「需要密码」）。
  /// 对 .rar/.7z 等非 ZIP 格式恒为 false，与旧 zipNeedsPassword 行为一致。
  final bool hasEncryptedEntries;

  bool get isEmpty => entries.isEmpty;

  List<ArchiveDirItem> childrenOf(String dir) =>
      children[dir] ?? const <ArchiveDirItem>[];

  /// 收集以 [prefix] 开头的**文件**条目名（写链路展开目录树用）。
  /// [prefix] 需已归一化且不含尾 `/`，例如 `photos/2024`。
  List<String> fileNamesUnder(String prefix) {
    final match = '$prefix/';
    final out = <String>[];
    for (final e in entries) {
      if (e.isFile && e.name.startsWith(match)) out.add(e.name);
    }
    return out;
  }
}

/// 由全量条目构建目录索引（**在隔离区内调用**）。
///
/// 每个条目对其路径上的每一层父目录都贡献一个直接子项：
/// `a/b/c.txt` → 根下目录 `a/`、目录 `a/` 下目录 `b/`、目录 `a/b/` 下文件 `c.txt`。
/// 展开一次后各级子目录的列表都被缓存，进子目录不再重复扫描整包。
ArchiveIndex buildArchiveIndex(
  List<ArchiveEntryInfo> entries, {
  bool hasEncryptedEntries = false,
}) {
  // 与旧 _buildZipEntries / _currentItems 严格同语义：只有**折叠目录**按名字
  // 去重（seenFolders），文件条目即使同名也全部保留；不能用 name 做全局 key，
  // 否则「同名文件 + 同名目录」时会把目录吞掉。
  final buckets = <String, List<ArchiveDirItem>>{};
  final seenDirs = <String, Set<String>>{};
  void add(String parent, ArchiveDirItem item) {
    final list = buckets.putIfAbsent(parent, () => <ArchiveDirItem>[]);
    if (item.isDirectory &&
        !seenDirs.putIfAbsent(parent, () => <String>{}).add(item.name)) {
      return;
    }
    list.add(item);
  }

  for (final e in entries) {
    final name = e.name;
    if (name.isEmpty) continue;
    var parent = '';
    var start = 0;
    while (start < name.length) {
      final slash = name.indexOf('/', start);
      if (slash < 0) {
        // 末段：与旧 _buildZipEntries / _currentItems 保持一致，单段一律作为
        // 文件项（显式目录项必然以 `/` 结尾，会在上一轮被识破为目录）。
        final leaf = name.substring(start);
        if (leaf.isNotEmpty) {
          add(
            parent,
            ArchiveDirItem(
              name: leaf,
              fullPath: name,
              isDirectory: false,
              size: e.size,
              lastModTime: e.lastModTime,
            ),
          );
        }
        break;
      }
      final seg = name.substring(start, slash);
      if (seg.isNotEmpty) {
        final dirPath = name.substring(0, slash + 1);
        add(
          parent,
          ArchiveDirItem(
            name: seg,
            fullPath: dirPath,
            isDirectory: true,
            size: 0,
            lastModTime: e.lastModTime,
          ),
        );
        parent = dirPath;
      }
      start = slash + 1;
    }
  }

  // 小写排序 key 全局缓存：压缩包内重名前缀很多，避免每个比较重复 toLowerCase。
  final lowerCache = <String, String>{};
  String lowerOf(String s) => lowerCache.putIfAbsent(s, () => s.toLowerCase());

  final children = <String, List<ArchiveDirItem>>{};
  for (final bucket in buckets.entries) {
    final list = bucket.value;
    list.sort((a, b) {
      if (a.isDirectory && !b.isDirectory) return -1;
      if (!a.isDirectory && b.isDirectory) return 1;
      return compareNaturalLower(
        a.name,
        b.name,
        lowerOf(a.name),
        lowerOf(b.name),
      );
    });
    children[bucket.key] = list;
  }

  return ArchiveIndex(
    entries: entries,
    children: children,
    hasEncryptedEntries: hasEncryptedEntries,
  );
}

/// 与 FileUtils.compareNaturalLower 完全同语义（本文件保持零 import，供隔离区
/// 使用，故保留独立副本）。小写串由调用方预计算传入；数字段按有效位数逐位
/// 比较，不构造 BigInt/substring。
int compareNaturalLower(String a, String b, String aLower, String bLower) {
  int i = 0;
  int j = 0;
  while (i < aLower.length && j < bLower.length) {
    final charA = aLower.codeUnitAt(i);
    final charB = bLower.codeUnitAt(j);

    if (_isDigit(charA) && _isDigit(charB)) {
      final startA = i;
      while (i < aLower.length && _isDigit(aLower.codeUnitAt(i))) {
        i++;
      }
      final startB = j;
      while (j < bLower.length && _isDigit(bLower.codeUnitAt(j))) {
        j++;
      }
      final cmp = _compareDigitRuns(aLower, startA, i, bLower, startB, j);
      if (cmp != 0) return cmp;
    } else {
      if (charA != charB) return charA.compareTo(charB);
      i++;
      j++;
    }
  }
  if (i < aLower.length) return 1;
  if (j < bLower.length) return -1;
  return a.compareTo(b);
}

int _compareDigitRuns(
    String a, int startA, int endA, String b, int startB, int endB) {
  var sa = startA;
  var sb = startB;
  while (sa < endA - 1 && a.codeUnitAt(sa) == 0x30) {
    sa++;
  }
  while (sb < endB - 1 && b.codeUnitAt(sb) == 0x30) {
    sb++;
  }
  final lenA = endA - sa;
  final lenB = endB - sb;
  if (lenA != lenB) return lenA.compareTo(lenB);
  for (var k = 0; k < lenA; k++) {
    final d = a.codeUnitAt(sa + k) - b.codeUnitAt(sb + k);
    if (d != 0) return d;
  }
  return (endA - startA).compareTo(endB - startB);
}

bool _isDigit(int codeUnit) => codeUnit >= 48 && codeUnit <= 57;
