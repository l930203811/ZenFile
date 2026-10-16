/// 受限目录（其它应用的 /Android/data、/Android/obb）路径变体工具。
///
/// 背景：Android 外置存储大小写不敏感，依赖内核 case-fold 做折叠比较；
/// 部分设备内核的 case-fold 比较会忽略零宽字符（U+200B），而 FUSE 对
/// /Android/{data,obb} 的访问控制按路径串匹配。向受限组件内注入零宽
/// 字符后：
///   - 访问控制的串匹配失配 → 不再判定为受限目录；
///   - 路径解析时零宽字符被折叠忽略 → 仍然落在真实目录上。
/// 两者叠加使标准文件 API 可以直接列目录、读写内容。
///
/// ⚠️ 该行为随设备内核与系统版本而异（已修补内核上变体路径直接 ENOENT），
/// 因此这里只提供「候选变体 + 探测式读写」，由调用方逐个尝试、以实际
/// 可访问者为准；全部失败时安静回退原有通道，不影响正常路径访问。
library;

import 'dart:io';

/// 零宽空格（U+200B）。用转义书写，避免源码里出现不可见字符。
const String kZeroWidthSpace = '\u200B';

/// 生成 `/storage/emulated/0/Android/{data,obb}` 受限路径的零宽字符变体，
/// 按优先级排列；非该前缀的路径返回空列表。
///
/// 注入位置的设备兼容性不同（后置 / 前置 / Android 前置均有实测可用的
/// 设备），因此给出多个候选，由调用方依次尝试。
List<String> androidRestrictedVariants(String path) {
  const base = '/storage/emulated/0/Android/';
  final normalized =
      path.replaceAll(RegExp(r'/+'), '/').replaceAll(RegExp(r'/+$'), '');
  if (!normalized.startsWith(base)) return const [];
  final segs = normalized
      .substring(base.length)
      .split('/')
    ..removeWhere((s) => s.isEmpty);
  if (segs.isEmpty) return const [];
  final head = segs.first; // data / obb
  final tail = segs.length > 1 ? '/${segs.sublist(1).join('/')}' : '';
  return [
    '$base$head$kZeroWidthSpace$tail', // data 后置
    '$base$kZeroWidthSpace$head$tail', // data 前置
    '/storage/emulated/0/$kZeroWidthSpace'
        'Android/$head$tail', // Android 前置
  ];
}

/// 把变体路径列出的子条目路径归一化回干净路径。
///
/// 变体父路径前缀整体替换为干净父路径；子文件名部分原样保留——子名里
/// 理论上可能合法含有零宽字符，不做全局剥离，避免误改真实文件名。
String normalizeVariantChildPath(
    String entityPath, String variantPath, String cleanPath) {
  if (variantPath.isNotEmpty && entityPath.startsWith(variantPath)) {
    return cleanPath + entityPath.substring(variantPath.length);
  }
  return entityPath;
}

/// 尝试以零宽字符变体用 Dart IO 直接拷贝受限文件。
/// 任一变异路径拷贝成功即返回 true；全部失败（含文件属主 0600 不可读）
/// 返回 false，由调用方回退其它通道。
Future<bool> tryCopyViaRestrictedVariants(String srcPath, String destPath) async {
  for (final variant in androidRestrictedVariants(srcPath)) {
    try {
      await File(variant).copy(destPath);
      if (File(destPath).existsSync()) return true;
    } catch (_) {}
  }
  return false;
}

/// 剥离「绕过变体」标记（零宽字符、'/./' 组件），还原标准路径。
///
/// 变体路径在界面上不可见（零宽字符不显示），**若调用方拿它做受限目录判定
/// 会漏判**（`/Android/​data` 被零宽字符断开，`contains('/android/data')`
/// 为假），进而把受限路径交给 Dart IO —— app 进程的 stat 会被 FUSE 拒绝并
/// 抛 `PathAccessException: Exists failed (errno 13)`。判定前一律先剥离。
String stripRestrictedVariantMarkers(String path) {
  var s = path.replaceAll(kZeroWidthSpace, '');
  while (s.contains('/./')) {
    s = s.replaceAll('/./', '/');
  }
  return s;
}

/// 经变体路径探测受限条目类型（不触碰干净路径的 Dart IO）。
/// 返回 null 表示所有候选变体都不可访问。
Future<FileSystemEntityType?> typeViaRestrictedVariants(String path) async {
  for (final variant in androidRestrictedVariants(path)) {
    try {
      final t = await FileSystemEntity.type(variant);
      if (t != FileSystemEntityType.notFound) return t;
    } catch (_) {}
  }
  return null;
}

/// 经变体路径删除受限条目（文件 unlink / 目录递归删除）。
/// 任一变体成功即返回 true；全部失败返回 false，由调用方回退其它通道。
///
/// 注意：删除前**不要求**调用方先做 stat —— 受限路径下 stat 正是被拦截的
/// 那一步（`Exists failed`），通道可用性由本函数自行探测。
Future<bool> tryDeleteViaRestrictedVariants(String path) async {
  for (final variant in androidRestrictedVariants(path)) {
    try {
      final t = await FileSystemEntity.type(variant);
      if (t == FileSystemEntityType.notFound) continue;
      if (t == FileSystemEntityType.directory) {
        await Directory(variant).delete(recursive: true);
      } else {
        await File(variant).delete();
      }
      return true;
    } catch (_) {}
  }
  return false;
}

/// 经变体路径把受限条目移动到普通路径（同卷 rename 只改元数据，不搬字节）。
/// 用于「回收站」这类「移动到 app 可写目录」的场景；失败返回 false。
Future<bool> tryRenameViaRestrictedVariants(
    String srcPath, String destPath) async {
  for (final variant in androidRestrictedVariants(srcPath)) {
    try {
      final t = await FileSystemEntity.type(variant);
      if (t == FileSystemEntityType.notFound) continue;
      if (t == FileSystemEntityType.directory) {
        await Directory(variant).rename(destPath);
      } else {
        await File(variant).rename(destPath);
      }
      return true;
    } catch (_) {}
  }
  return false;
}

/// 把普通路径的条目 rename **进**受限路径（变体施加在目标侧）。
/// 用于「回收站还原到 Android/data」这类源可读、目标受限的场景。
Future<bool> tryRenameToRestrictedVariant(
    String srcPath, String destPath) async {
  FileSystemEntityType srcType;
  try {
    srcType = await FileSystemEntity.type(srcPath);
  } catch (_) {
    return false;
  }
  if (srcType == FileSystemEntityType.notFound) return false;
  for (final variant in androidRestrictedVariants(destPath)) {
    try {
      if (srcType == FileSystemEntityType.directory) {
        await Directory(srcPath).rename(variant);
      } else {
        await File(srcPath).rename(variant);
      }
      return true;
    } catch (_) {}
  }
  return false;
}

/// 经变体路径把受限文件/目录复制到普通路径（rename 不可用时的末级回退）。
/// 目录递归复制；失败返回 false。
Future<bool> tryCopyTreeViaRestrictedVariants(
    String srcPath, String destPath) async {
  for (final variant in androidRestrictedVariants(srcPath)) {
    try {
      final t = await FileSystemEntity.type(variant);
      if (t == FileSystemEntityType.notFound) continue;
      if (t == FileSystemEntityType.directory) {
        await _copyDirViaVariant(Directory(variant), Directory(destPath));
      } else {
        await File(variant).copy(destPath);
      }
      return true;
    } catch (_) {}
  }
  return false;
}

/// 变体路径下的目录递归复制：list() 返回的子路径自带变体前缀，
/// 递归延续同一通道（不再触碰干净路径的 Dart IO）。
Future<void> _copyDirViaVariant(Directory src, Directory dest) async {
  if (!dest.existsSync()) {
    dest.createSync(recursive: true);
  }
  await for (final entity in src.list()) {
    final name = entity.path.split('/').last;
    final target = '${dest.path}/$name';
    if (entity is Directory) {
      await _copyDirViaVariant(entity, Directory(target));
    } else if (entity is File) {
      await entity.copy(target);
    }
  }
}

/// 尝试以零宽字符变体用 Dart IO 直接写入受限文件（整文件读后写出）。
/// 任一变异路径写入成功即返回 true；全部失败返回 false。
Future<bool> tryWriteViaRestrictedVariants(
    String srcPath, String destPath) async {
  List<int> bytes;
  try {
    bytes = await File(srcPath).readAsBytes();
  } catch (_) {
    return false;
  }
  for (final variant in androidRestrictedVariants(destPath)) {
    try {
      await File(variant).writeAsBytes(bytes, flush: true);
      return true;
    } catch (_) {}
  }
  return false;
}
