import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
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
    final cmdPrefix = _toFuseBypassPath(searchPrefix);
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
  }

  /// stat 单个路径（受限路径走底层绕过）。返回 null 表示不存在。
  /// 复制/上传链路用于替代 Dart IO 的 typeSync/lengthSync——Android 11+
  /// FUSE 层使 app 进程对其它应用的 Android/{data,obb} 文件不可见，
  /// 只能经 shell/root 在 /data/media/0 底层路径访问。
  static Future<FileItemModel?> statItem(String path, {required bool useRoot}) async {
    final clean = _toFuseBypassPath(_normalize(path));
    final cmd = 'stat -L -c "%F|%s|%Y|%n" "$clean" 2>/dev/null || stat -c "%F|%s|%Y|%n" "$clean" 2>/dev/null';
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
    final cleanOld = _toFuseBypassPath(_normalize(oldPath));
    final cleanNew = _toFuseBypassPath(_normalize(p.join(p.dirname(oldPath), newName)));
    final cmd = 'mv "$cleanOld" "$cleanNew"';
    await runCommand(cmd, useRoot: useRoot);
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
  /// FUSE 直接子路径读取；root 两条路径均可用。复制完成后校验目标存在，
  /// 失败抛异常，避免静默失败导致后续链路（如上传暂存文件缺失）报
  /// "Local file not found"。
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
  }

  /// shell stat 检测路径是否存在（用于复制结果校验）。
  static Future<bool> _exists(String path, {required bool useRoot}) async {
    final clean = _toFuseBypassPath(_normalize(path));
    final cmd = 'stat -c "%n" "$clean" 2>/dev/null';
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
}
