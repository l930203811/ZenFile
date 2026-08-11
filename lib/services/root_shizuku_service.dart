import 'dart:io';
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
  /// 路径 `/data/media/0/Android/{data,obb}` 绕过 FUSE 限制。此处将
  /// `/storage/emulated/0/Android/` 命令执行路径转为 `/data/media/0/Android/`，
  /// 确保 list/stat/rm/mv/mkdir 等在底层路径执行。
  static String _toFuseBypassPath(String path) {
    if (path.startsWith('/storage/emulated/0/Android/')) {
      return path.replaceFirst('/storage/emulated/0/Android/', '/data/media/0/Android/');
    }
    return path;
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
      return res?.toString();
    } catch (e) {
      throw Exception('Execution failed: $e');
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
    final cmd = 'for f in "$cmdPrefix"/* "$cmdPrefix"/.*; do [ -e "\$f" ] && [ "\${f##*/}" != "." ] && [ "\${f##*/}" != ".." ] && (stat -L -c "%F|%s|%Y|%n" "\$f" 2>/dev/null || stat -c "%F|%s|%Y|%n" "\$f"); done';

    final output = await runCommand(cmd, useRoot: useRoot);
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
    final clean = _toFuseBypassPath(_normalize(path));
    final cmd = 'rm -rf "$clean"';
    await runCommand(cmd, useRoot: useRoot);
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

  static Future<void> copyItem(String srcPath, String destPath, {required bool useRoot}) async {
    final cleanSrc = _toFuseBypassPath(_normalize(srcPath));
    final cleanDest = _toFuseBypassPath(_normalize(destPath));
    final cmd = 'cp -r "$cleanSrc" "$cleanDest"';
    await runCommand(cmd, useRoot: useRoot);
  }

  static Future<void> moveItem(String srcPath, String destPath, {required bool useRoot}) async {
    final cleanSrc = _toFuseBypassPath(_normalize(srcPath));
    final cleanDest = _toFuseBypassPath(_normalize(destPath));
    final cmd = 'mv "$cleanSrc" "$cleanDest"';
    await runCommand(cmd, useRoot: useRoot);
  }
}
