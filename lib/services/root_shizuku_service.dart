import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/file_item_model.dart';
import 'package:path/path.dart' as p;

class RootShizukuStatus {
  final bool isRootAvailable;
  final bool isShizukuAvailable;
  final bool shizukuPermissionGranted;

  RootShizukuStatus({
    required this.isRootAvailable,
    required this.isShizukuAvailable,
    required this.shizukuPermissionGranted,
  });

  factory RootShizukuStatus.fromMap(Map<dynamic, dynamic> map) {
    return RootShizukuStatus(
      isRootAvailable: map['isRootAvailable'] == true,
      isShizukuAvailable: map['isShizukuAvailable'] == true,
      shizukuPermissionGranted: map['shizukuPermissionGranted'] == true,
    );
  }
}

class RootShizukuService {
  static const MethodChannel _channel = MethodChannel('com.sequl.zenfile/root_shizuku');

  static Future<RootShizukuStatus> checkStatus() async {
    if (!Platform.isAndroid) {
      return RootShizukuStatus(isRootAvailable: false, isShizukuAvailable: false, shizukuPermissionGranted: false);
    }
    try {
      final res = await _channel.invokeMethod('checkStatus');
      if (res is Map) {
        return RootShizukuStatus.fromMap(res);
      }
    } catch (_) {}
    return RootShizukuStatus(isRootAvailable: false, isShizukuAvailable: false, shizukuPermissionGranted: false);
  }

  static Future<Map<String, int>?> getStorageSpace({String? path}) async {
    if (!Platform.isAndroid) return null;
    try {
      final res = await _channel.invokeMethod('getStorageSpace', {'path': path});
      if (res is Map) {
        return {
          'totalBytes': res['totalBytes'] as int? ?? 0,
          'availableBytes': res['availableBytes'] as int? ?? 0,
          'usedBytes': res['usedBytes'] as int? ?? 0,
        };
      }
    } catch (_) {}
    return null;
  }

  static Future<bool> requestShizukuPermission() async {
    if (!Platform.isAndroid) return false;
    try {
      final res = await _channel.invokeMethod('requestShizukuPermission');
      return res == true;
    } catch (_) {
      return false;
    }
  }

  static String _normalize(String path) {
    String normalized = path.replaceAll(RegExp(r'/+'), '/');
    if (normalized.isEmpty) normalized = '/';
    if (normalized.startsWith('/sdcard')) {
      normalized = normalized.replaceFirst('/sdcard', '/storage/emulated/0');
    } else if (normalized.startsWith('/mnt/sdcard')) {
      normalized = normalized.replaceFirst('/mnt/sdcard', '/storage/emulated/0');
    }
    return normalized;
  }

  /// 安卓 11+（含 vivo/OPPO 等定制 ROM）上，`/storage/emulated/0/Android/{data,obb}`
  /// 经 FUSE 挂载，即使 Shizuku（shell 用户 uid 2000）通过该路径执行 ls/glob 也会被
  /// FUSE 层拦截返回空（表现为直接进入 Android/data 显示空目录或受限提示页，
  /// 但收藏夹进入深层子路径再返回上层能正常显示——因 FUSE 仅拦截 /Android/data
  /// 本身的 list，而不拦截已知的具体子路径）。ES 文件管理器等通过底层 ext4
  /// 路径 `/data/media/0/Android/{data,obb}` 绕过 FUSE 限制。
  /// 此处通过 StorageManager 反射 API 获取实际主卷路径，
  /// 将其映射到对应的 FUSE 路径，确保命令执行在正确的路径上。
  static String _toFuseBypassPath(String path) {
    final normalized = path.replaceAll(RegExp(r'/+'), '/');
    if (normalized.startsWith('/storage/emulated/0/Android/')) {
      return normalized.replaceFirst('/storage/emulated/0/Android/', '/data/media/0/Android/');
    }
    return normalized;
  }

  /// 将 stat `%n` 输出的底层路径 `/data/media/0/Android/...` 转回用户可见的
  /// `/storage/emulated/0/Android/...` 路径，保证后续所有操作（打开/复制/删除等）
  /// 基于 `/storage/emulated/0/` 路径，与普通（非受限）路径体系一致，避免路径分裂。
  static String _fromFuseBypassPath(String path) {
    if (path.startsWith('/data/media/0/Android/')) {
      return path.replaceFirst('/data/media/0/Android/', '/storage/emulated/0/Android/');
    }
    return path;
  }

  static Future<String?> runCommand(String command, {required bool useRoot}) async {
    if (!Platform.isAndroid) return null;
    try {
      final res = await _channel.invokeMethod('runCommand', {
        'command': command,
        'useRoot': useRoot,
      });
      final output = res?.toString() ?? '';
      debugPrint('[ZenFile] runCommand (${useRoot ? "root" : "shizuku"}): "$command" => "${output.substring(0, output.length.clamp(0, 200))}${output.length > 200 ? "..." : ""}"');
      return output;
    } catch (e) {
      debugPrint('[ZenFile] runCommand exception: $e');
      throw Exception('Execution failed: $e');
    }
  }

  /// 通过标准 Dart IO 访问原始路径（绕开 FUSE 层）。
  /// 适用于部分 ROM 对 `/storage/emulated/0/Android/data` 启用 FUSE 限制、
  /// 但对 `/data/media/0/Android/data` 不限制的场景（如部分未加固的 ROM）。
  /// 若原始路径仍被 FUSE 拦截或 SELinux 限制，返回 null。
  static Future<List<FileItemModel>?> listViaRawPath(String path,
      {bool showHiddenFiles = false}) async {
    if (!Platform.isAndroid) return null;
    final rawPath = _toFuseBypassPath(path);
    debugPrint('[ZenFile] listViaRawPath: rawPath=$rawPath');
    try {
      final dir = Directory(rawPath);
      final exists = await dir.exists();
      debugPrint('[ZenFile] listViaRawPath: exists=$exists');
      if (!exists) return null;
      final entities = await dir.list().toList();
      debugPrint('[ZenFile] listViaRawPath: got ${entities.length} entities');
      final items = <FileItemModel>[];
      for (final entity in entities) {
        final name = p.basename(entity.path);
        if (!showHiddenFiles && name.startsWith('.') && name != '.' && name != '..') continue;
        final isDir = await FileSystemEntity.type(entity.path) == FileSystemEntityType.directory;
        final stat = await entity.stat();
        items.add(FileItemModel.fromCustom(
          path: _fromFuseBypassPath(entity.path),
          isDirectory: isDir,
          size: stat.size,
          modified: stat.modified,
        ));
      }
      return items;
    } catch (e) {
      debugPrint('[ZenFile] listViaRawPath failed for $rawPath: $e');
      return null;
    }
  }

  static Future<List<FileItemModel>> listFiles(String path, {required bool useRoot, bool showHiddenFiles = false}) async {
    String normalizedPath = _normalize(path);

    final cleanPath = (normalizedPath == '/' || !normalizedPath.endsWith('/'))
        ? normalizedPath
        : normalizedPath.substring(0, normalizedPath.length - 1);

    // If cleanPath is "/", use empty string prefix to prevent search pattern from becoming //* and //.*
    final searchPrefix = cleanPath == '/' ? '' : cleanPath;
    // FUSE 绕过（见 _toFuseBypassPath 注释）。ES 文件管理器做法一致：
    // 对 Android/data 用底层 ext4 路径执行 glob/stat。
    final bypassPrefix = _toFuseBypassPath(searchPrefix);

    // 双路径尝试：小米/华为等 ROM 的 FUSE 层拦截 shell 访问 /storage 直达
    // 路径、放行底层 /data/media/0；vivo 等定制 ROM 的 SELinux 恰好相反——
    // 拦截 shell 访问 /data/media/0、放行 FUSE 直达路径。先底层后 FUSE，
    // 任一条路径能列出内容即采用。
    var items = await _listViaShell(bypassPrefix, useRoot: useRoot, showHiddenFiles: showHiddenFiles);
    if (items.isEmpty && bypassPrefix != searchPrefix) {
      debugPrint('[ZenFile] listFiles: bypass path empty, retry FUSE direct path: $searchPrefix');
      items = await _listViaShell(searchPrefix, useRoot: useRoot, showHiddenFiles: showHiddenFiles);
    }
    return items;
  }

  static Future<List<FileItemModel>> _listViaShell(String cmdPrefix, {required bool useRoot, required bool showHiddenFiles}) async {
    // 使用 find 命令列出目录内容，比 glob 更可靠（避免 shell 展开失败）
    final cmd = 'find "$cmdPrefix" -maxdepth 1 -mindepth 1 -exec stat -L -c "%F|%s|%Y|%n" {} \\; 2>&1';
    debugPrint('[ZenFile] Shell command: useRoot=$useRoot cmdPrefix=$cmdPrefix');

    final output = await runCommand(cmd, useRoot: useRoot);
    debugPrint('[ZenFile] listFiles: got ${output?.length ?? 0} chars, ${output?.split('\n').length ?? 0} lines');
    if (output == null || output.trim().isEmpty) return [];

    final lines = output.split('\n');
    final items = <FileItemModel>[];

    for (final line in lines) {
      if (line.trim().isEmpty) continue;
      final parts = line.split('|');
      if (parts.length < 4) continue;

      final typeStr = parts[0];
      final sizeStr = parts[1];
      final timeStr = parts[2];
      // stat %n 输出为底层路径 /data/media/0/Android/...（见 _toFuseBypassPath），
      // 转回用户可见的 /storage/emulated/0/Android/... 路径。
      final rawPath = parts.sublist(3).join('|');
      final fullPath = _fromFuseBypassPath(rawPath);

      final name = p.basename(fullPath);
      if (!showHiddenFiles && name.startsWith('.') && name != '.' && name != '..') {
        continue;
      }

      final isDir = typeStr.toLowerCase().contains('directory');
      final size = int.tryParse(sizeStr) ?? 0;
      final seconds = int.tryParse(timeStr) ?? 0;
      final modified = DateTime.fromMillisecondsSinceEpoch(seconds * 1000);

      items.add(FileItemModel.fromCustom(
        path: fullPath,
        isDirectory: isDir,
        size: size,
        modified: modified,
      ));
    }

    return items;
  }

  static Future<void> deleteItem(String path, {required bool useRoot}) async {
    final fuse = _normalize(path);
    final raw = _toFuseBypassPath(fuse);
    // FUSE 直接路径优先、底层路径回退：底层 ext4 上其它应用的
    // Android/{data,obb} 文件/目录属主为对应 app uid（0660/0771），
    // shell（Shizuku uid 2000）无权限，只能经 FUSE 直接子路径操作；
    // root 两条路径均可用。
    final cmd = raw != fuse
        ? 'rm -rf "$fuse" 2>/dev/null || rm -rf "$raw"'
        : 'rm -rf "$fuse"';
    await runCommand(cmd, useRoot: useRoot);
    // 结果校验：删除后源应不存在。剪切（cut）等场景若静默失败会导致
    // 「移动变成复制一份」——必须让调用方感知失败。
    if (await _exists(path, useRoot: useRoot)) {
      throw Exception('Delete failed (source still exists): $path');
    }
  }

  /// stat 单个路径（受限路径走底层绕过 + FUSE 回退）。返回 null 表示不存在。
  /// 复制/上传链路用于替代 Dart IO 的 typeSync/lengthSync——Android 11+
  /// FUSE 层使 app 进程对其它应用的 Android/{data,obb} 文件不可见，
  /// 只能经 shell/root 在 /data/media/0 底层路径访问。
  /// 底层路径与 FUSE 直达路径双试：小米/华为等 ROM 底层放行、FUSE 拦 shell；
  /// vivo 等 ROM 恰好相反（拦底层、放行 FUSE 直达）。
  static Future<FileItemModel?> statItem(String path, {required bool useRoot}) async {
    final fuse = _normalize(path);
    final raw = _toFuseBypassPath(fuse);
    final String cmd;
    if (raw != fuse) {
      cmd = 'stat -L -c "%F|%s|%Y|%n" "$raw" 2>/dev/null || stat -L -c "%F|%s|%Y|%n" "$fuse" 2>/dev/null || stat -c "%F|%s|%Y|%n" "$fuse" 2>/dev/null';
    } else {
      cmd = 'stat -L -c "%F|%s|%Y|%n" "$fuse" 2>/dev/null || stat -c "%F|%s|%Y|%n" "$fuse" 2>/dev/null';
    }
    final output = await runCommand(cmd, useRoot: useRoot);
    final line = output?.trim();
    if (line == null || line.isEmpty) return null;
    final parts = line.split('|');
    if (parts.length < 4) return null;
    final isDir = parts[0].toLowerCase().contains('directory');
    return FileItemModel.fromCustom(
      path: _fromFuseBypassPath(parts.sublist(3).join('|')),
      isDirectory: isDir,
      size: int.tryParse(parts[1]) ?? 0,
      modified: DateTime.fromMillisecondsSinceEpoch((int.tryParse(parts[2]) ?? 0) * 1000),
    );
  }

  static Future<void> renameItem(String oldPath, String newName, {required bool useRoot}) async {
    final fuseOld = _normalize(oldPath);
    final rawOld = _toFuseBypassPath(fuseOld);
    final fuseNew = _normalize(p.join(p.dirname(oldPath), newName));
    final rawNew = _toFuseBypassPath(fuseNew);
    // 与 moveItem/deleteItem/copyItem 一致的「FUSE 直接路径优先、底层路径回退」
    // 双跳：底层 /data/media/0 上其它应用的 Android/{data,obb} 文件属主为对应
    // app uid，shell（Shizuku uid 2000）无权限；FUSE 直接路径对 shell 可写
    // （其它文件管理器经 FUSE 路径可正常重命名 Android/data 内文件）。
    final String cmd;
    if (rawOld != fuseOld || rawNew != fuseNew) {
      cmd = 'mv "$fuseOld" "$fuseNew" 2>/dev/null || mv "$rawOld" "$rawNew"';
    } else {
      cmd = 'mv "$fuseOld" "$fuseNew"';
    }
    await runCommand(cmd, useRoot: useRoot);
    // 结果校验：重命名后新路径应存在，否则抛出（避免静默无效）。
    if (!await _exists(fuseNew, useRoot: useRoot)) {
      throw Exception('Rename failed: $oldPath -> $newName');
    }
  }

  static Future<void> createFolder(String parentPath, String name, {required bool useRoot}) async {
    final cleanParent = _toFuseBypassPath(_normalize(parentPath));
    final cleanPath = p.join(cleanParent, name);
    final cmd = 'mkdir -p "$cleanPath"';
    await runCommand(cmd, useRoot: useRoot);
  }

  static Future<void> createFile(String parentPath, String name, {required bool useRoot}) async {
    final cleanParent = _toFuseBypassPath(_normalize(parentPath));
    final cleanPath = p.join(cleanParent, name);
    final cmd = 'touch "$cleanPath"';
    await runCommand(cmd, useRoot: useRoot);
  }

  /// 复制文件/目录。受限路径采用「FUSE 直接路径优先、底层 /data/media/0
  /// 路径回退」双跳策略：底层 ext4 上其它应用的 Android/{data,obb} 文件为
  /// 0660（属主为对应 app uid），shell（Shizuku uid 2000）无读权限，只能经
  /// FUSE 直接子路径读取；root 两条路径均可用。
  ///
  /// 复制完成后校验目标存在且（源为文件时）大小与源一致；不一致说明 FUSE
  /// 读取内容受限（部分 ROM 对其它应用 Android/data 文件只开放元数据/0 字节），
  /// 自动删除不完整目标并改用底层路径重试，仍失败抛异常，避免静默 0 字节。
  static Future<void> copyItem(String srcPath, String destPath, {required bool useRoot}) async {
    final fuseSrc = _normalize(srcPath);
    final rawSrc = _toFuseBypassPath(fuseSrc);
    final fuseDest = _normalize(destPath);
    final rawDest = _toFuseBypassPath(fuseDest);
    final String cmd;
    if (rawSrc != fuseSrc || rawDest != fuseDest) {
      cmd = 'cp -r "$fuseSrc" "$fuseDest" 2>/dev/null || cp -r "$rawSrc" "$rawDest"';
    } else {
      cmd = 'cp -r "$fuseSrc" "$fuseDest"';
    }
    await runCommand(cmd, useRoot: useRoot);
    if (!await _exists(destPath, useRoot: useRoot)) {
      throw Exception('Copy failed: $srcPath -> $destPath');
    }
    // 大小一致性校验（仅文件，目录元数据无意义）
    final srcStat = await statItem(srcPath, useRoot: useRoot);
    if (srcStat != null && !srcStat.isDirectory) {
      final destStat = await statItem(destPath, useRoot: useRoot);
      if (destStat == null || destStat.size != srcStat.size) {
        debugPrint('[ZenFile] copyItem size mismatch $srcPath (${srcStat.size}) -> $destPath (${destStat?.size})');
        if (rawSrc != fuseSrc || rawDest != fuseDest) {
          // 删除不完整目标，改用底层 ext4 路径重试（FUSE 读受限、底层可读时）
          await runCommand('rm -rf "$fuseDest" 2>/dev/null || rm -rf "$rawDest"', useRoot: useRoot);
          await runCommand('cp -r "$rawSrc" "$rawDest"', useRoot: useRoot);
          final retryStat = await statItem(destPath, useRoot: useRoot);
          if (retryStat != null && retryStat.size == srcStat.size) {
            return;
          }
        }
        throw Exception('Copy size mismatch: $srcPath -> $destPath');
      }
    }
  }

  /// shell stat 检测路径是否存在（受限路径底层/FUSE 双试，用于复制等结果校验）。
  static Future<bool> _exists(String path, {required bool useRoot}) async {
    final fuse = _normalize(path);
    final raw = _toFuseBypassPath(fuse);
    final cmd = raw != fuse
        ? 'stat -c "%n" "$raw" 2>/dev/null || stat -c "%n" "$fuse" 2>/dev/null'
        : 'stat -c "%n" "$fuse" 2>/dev/null';
    try {
      final out = await runCommand(cmd, useRoot: useRoot);
      return out != null && out.trim().isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  static Future<void> moveItem(String srcPath, String destPath, {required bool useRoot}) async {
    final fuseSrc = _normalize(srcPath);
    final rawSrc = _toFuseBypassPath(fuseSrc);
    final fuseDest = _normalize(destPath);
    final rawDest = _toFuseBypassPath(fuseDest);
    // 与 copyItem 一致的双跳策略（见其注释）。
    final String cmd;
    if (rawSrc != fuseSrc || rawDest != fuseDest) {
      cmd = 'mv "$fuseSrc" "$fuseDest" 2>/dev/null || mv "$rawSrc" "$rawDest"';
    } else {
      cmd = 'mv "$fuseSrc" "$fuseDest"';
    }
    await runCommand(cmd, useRoot: useRoot);
    // 结果校验：mv 原子成功时源消失、目标存在；跨文件系统（EXDEV）或
    // 权限失败时源仍存在 → 抛异常，由调用方决定回退 copy+delete。
    final srcGone = !await _exists(srcPath, useRoot: useRoot);
    final destExists = await _exists(destPath, useRoot: useRoot);
    if (!srcGone || !destExists) {
      throw Exception('Move failed: $srcPath -> $destPath');
    }
  }

  /// 通过反射访问 StorageManager 内部 API 获取存储卷信息（ES 文件管理器方案）。
  /// 返回卷列表，每个卷包含 path、isEmulated 等字段。
  /// 用于检测主存储卷的实际挂载点，以绕过部分 ROM 的 FUSE 限制。
  static Future<List<Map<String, dynamic>>> getStorageVolumes() async {
    if (!Platform.isAndroid) return [];
    try {
      final res = await _channel.invokeMethod<List<dynamic>>('getStorageVolumes');
      if (res == null) return [];
      return res.map((m) => Map<String, dynamic>.from(m as Map)).toList();
    } catch (_) {
      return [];
    }
  }

  /// 获取主存储卷（emulated）的底层路径。
  /// 若反射调用成功则返回其 path；否则返回 null，由调用方回退到 /storage/emulated/0。
  static Future<String?> getPrimaryStoragePath() async {
    final volumes = await getStorageVolumes();
    for (final vol in volumes) {
      if (vol['isEmulated'] == true || vol['isEmulated'] == true) {
        final path = vol['path'] as String?;
        if (path != null && path.isNotEmpty) return path;
      }
    }
    // Fallback: 尝试从卷列表中取第一条有 path 的卷
    for (final vol in volumes) {
      final path = vol['path'] as String?;
      if (path != null && path.isNotEmpty) return path;
    }
    return null;
  }

  /// 直接用 Java File API 在 app 进程内访问原始路径（绕开 shell 进程）。
  /// 适用于 shell 进程被 SELinux 限制但 app 进程可以访问的场景。
  static Future<List<FileItemModel>?> listRawPath(String path,
      {bool showHiddenFiles = false}) async {
    if (!Platform.isAndroid) return null;
    final rawPath = _toFuseBypassPath(path);
    debugPrint('[ZenFile] listRawPath (Kotlin): rawPath=$rawPath');
    try {
      final res = await _channel.invokeMethod<List<dynamic>>('listRawPath', {'path': rawPath});
      if (res == null) return null;
      final items = <FileItemModel>[];
      for (final entry in res) {
        final map = Map<String, dynamic>.from(entry as Map);
        final name = map['name'] as String;
        if (!showHiddenFiles && name.startsWith('.') && name != '.' && name != '..') continue;
        items.add(FileItemModel.fromCustom(
          path: _fromFuseBypassPath(p.join(rawPath, name)),
          isDirectory: map['isDirectory'] as bool? ?? false,
          size: (map['length'] as num?)?.toInt() ?? 0,
          modified: DateTime.fromMillisecondsSinceEpoch((map['lastModified'] as num?)?.toInt() ?? 0),
        ));
      }
      debugPrint('[ZenFile] listRawPath (Kotlin): got ${items.length} items');
      return items;
    } catch (e) {
      debugPrint('[ZenFile] listRawPath (Kotlin) failed: $e');
      return null;
    }
  }

  /// 统计目录内所有文件的总字节数（递归）。受限路径（Android/data、Android/obb 等）
  /// 下 Dart IO 会被 FUSE 层拦截返回 0，必须经 shell du 在底层 /data/media/0 路径
  /// （或 FUSE 直达路径）上统计，与 listFiles 的访问方式一致。
  /// 返回 null 表示计算失败（由调用方回退 Dart IO）。
  ///
  /// 注意：不能在 shell 命令里用 `||` 做双路径回退——awk/cut 管道总是 exit 0，
  /// 在 vivo 等 ROM 上底层路径被 SELinux 拦截返回「假 0」（exit 0）时会吞掉回退，
  /// 导致 FUSE 直达路径永不执行（表现为文件夹大小恒为 0 B）。
  /// 因此改为 Dart 层双路径：底层结果无效（0/失败）时再试 FUSE 直达路径。
  static Future<int?> getFolderSizeShell(String path, {required bool useRoot}) async {
    final fuse = _normalize(path);
    final raw = _toFuseBypassPath(fuse);

    Future<int?> runDu(String p) async {
      // du -sb：递归统计字节数，输出 "<bytes>\t<path>"，cut -f1 取字节列。
      final cmd = 'du -sb "$p" 2>/dev/null | cut -f1';
      try {
        final output = await runCommand(cmd, useRoot: useRoot);
        final trimmed = output?.trim();
        if (trimmed == null || trimmed.isEmpty) return null;
        // 取最后一个非空行（避免路径/环境噪音干扰）
        for (final line in trimmed.split('\n').reversed) {
          if (line.trim().isEmpty) continue;
          return int.tryParse(line.trim());
        }
        return null;
      } catch (_) {
        return null;
      }
    }

    // 底层 /data/media/0 优先；若结果为 0/失败且存在 FUSE 直达路径，则回退
    // FUSE 路径（小米/华为拦 FUSE 放底层、vivo 相反，需双试）。
    final rawSize = await runDu(raw);
    if (rawSize != null && rawSize > 0) return rawSize;
    if (raw != fuse) {
      final fuseSize = await runDu(fuse);
      if (fuseSize != null && fuseSize > 0) return fuseSize;
      // 两层都 0/失败：返回底层结果（空目录为 0，权限假 0 也无法再突破）
      return rawSize;
    }
    return rawSize;
  }
}

/// SAF (Storage Access Framework) 服务：用于在 Shizuku/root 不可用时
/// 通过系统文件选择器授权访问 Android/data 等受限目录。
/// 这是 Android 11+ 官方推荐的访问方式，无需 Shizuku 或 root。
class SafAndroidDataService {
  static const MethodChannel _channel = MethodChannel('com.sequl.zenfile/saf');

  /// 已授权的 Android/data SAF tree URI（持久化存储的 key）
  static const String _prefKeyAndroidDataUri = 'saf_android_data_tree_uri';
  static const String _prefKeyAndroidObbUri = 'saf_android_obb_tree_uri';

  /// 请求 SAF 授权访问 Android/data（系统文件选择器直接定位到该目录）。
  /// 返回授权的 tree URI 字符串，用户取消返回 null。
  static Future<String?> requestAndroidDataAccess() async {
    if (!Platform.isAndroid) return null;
    try {
      final result = await _channel.invokeMethod<Map<dynamic, dynamic>>(
        'requestSafWithInitialUri',
        {'initialDocId': 'primary:Android/data'},
      );
      if (result == null) return null;
      final uri = result['uri'] as String?;
      if (uri != null) {
        await _saveTreeUri(_prefKeyAndroidDataUri, uri);
        debugPrint('[ZenFile] SAF Android/data authorized: $uri');
      }
      return uri;
    } catch (e) {
      debugPrint('[ZenFile] SAF request failed: $e');
      return null;
    }
  }

  /// 请求 SAF 授权访问 Android/obb。
  static Future<String?> requestAndroidObbAccess() async {
    if (!Platform.isAndroid) return null;
    try {
      final result = await _channel.invokeMethod<Map<dynamic, dynamic>>(
        'requestSafWithInitialUri',
        {'initialDocId': 'primary:Android/obb'},
      );
      if (result == null) return null;
      final uri = result['uri'] as String?;
      if (uri != null) {
        await _saveTreeUri(_prefKeyAndroidObbUri, uri);
      }
      return uri;
    } catch (e) {
      debugPrint('[ZenFile] SAF obb request failed: $e');
      return null;
    }
  }

  /// 获取已存储的 Android/data SAF tree URI。
  static Future<String?> getAndroidDataTreeUri() async {
    return _getTreeUri(_prefKeyAndroidDataUri);
  }

  /// 获取已存储的 Android/obb SAF tree URI。
  static Future<String?> getAndroidObbTreeUri() async {
    return _getTreeUri(_prefKeyAndroidObbUri);
  }

  /// 检查是否已有 Android/data 的 SAF 授权。
  static Future<bool> hasAndroidDataAccess() async {
    final uri = await getAndroidDataTreeUri();
    return uri != null && uri.isNotEmpty;
  }

  /// 使用 SAF 列出 Android/data 目录内容。
  /// 返回 FileItemModel 列表，失败返回 null。
  static Future<List<FileItemModel>?> listAndroidDataViaSAF({
    bool showHiddenFiles = false,
  }) async {
    final treeUri = await getAndroidDataTreeUri();
    if (treeUri == null) return null;
    return _listViaSAF(treeUri, '', showHiddenFiles: showHiddenFiles);
  }

  /// 使用 SAF 列出指定子路径的内容。
  /// [subPath] 相对于 Android/data（或 obb）的子路径，如 "com.tencent.mm" 或 ""。
  /// [isObb] 为 true 时基于 Android/obb 树构建 document ID。
  static Future<List<FileItemModel>?> listAndroidDataSubDirViaSAF(
    String subPath, {
    bool showHiddenFiles = false,
    bool isObb = false,
  }) async {
    final treeUri = isObb ? await getAndroidObbTreeUri() : await getAndroidDataTreeUri();
    if (treeUri == null) return null;

    // 构建子路径的 document URI
    String pathUri = '';
    if (subPath.isNotEmpty) {
      // 将子路径转换为 SAF document ID 格式
      final base = isObb ? 'Android/obb' : 'Android/data';
      final docId = 'primary:$base/$subPath';
      pathUri = 'content://com.android.externalstorage.documents/document/${Uri.encodeComponent(docId)}';
    }

    return _listViaSAF(treeUri, pathUri, showHiddenFiles: showHiddenFiles);
  }

  /// 使用 SAF 列出目录内容。
  static Future<List<FileItemModel>?> _listViaSAF(
    String treeUri,
    String pathUri, {
    bool showHiddenFiles = false,
  }) async {
    try {
      final List<dynamic> result = await _channel.invokeMethod('listDirectory', {
        'rootUri': treeUri,
        'pathUri': pathUri,
      });

      final items = <FileItemModel>[];
      for (final entry in result) {
        final map = Map<String, dynamic>.from(entry as Map);
        final name = map['name'] as String;
        if (!showHiddenFiles && name.startsWith('.') && name != '.' && name != '..') continue;

        // SAF URI 路径转换为本地路径格式
        final safPath = map['path'] as String;
        final localPath = _safUriToLocalPath(safPath);

        items.add(FileItemModel.fromCustom(
          path: localPath,
          isDirectory: map['isDirectory'] as bool? ?? false,
          size: (map['size'] as num?)?.toInt() ?? 0,
          modified: DateTime.fromMillisecondsSinceEpoch((map['modified'] as num?)?.toInt() ?? 0),
        ));
      }
      debugPrint('[ZenFile] SAF listDirectory: got ${items.length} items');
      return items;
    } catch (e) {
      debugPrint('[ZenFile] SAF listDirectory failed: $e');
      return null;
    }
  }

  /// 将 SAF document URI 转换为本地文件路径。
  /// 例如: content://com.android.externalstorage.documents/tree/primary%3AAndroid%2Fdata/document/primary%3AAndroid%2Fdata%2Fcom.tencent.mm
  /// → /storage/emulated/0/Android/data/com.tencent.mm
  static String _safUriToLocalPath(String safUri) {
    try {
      final uri = Uri.parse(safUri);
      final docId = uri.pathSegments.last;
      final decoded = Uri.decodeComponent(docId);
      // decoded 格式: "primary:Android/data/com.tencent.mm"
      if (decoded.startsWith('primary:')) {
        final relPath = decoded.substring('primary:'.length);
        return '/storage/emulated/0/$relPath';
      }
    } catch (_) {}
    return safUri;
  }

  static Future<void> _saveTreeUri(String key, String uri) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(key, uri);
    } catch (_) {}
  }

  static Future<String?> _getTreeUri(String key) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getString(key);
    } catch (_) {
      return null;
    }
  }
}
