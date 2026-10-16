import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:path/path.dart' as p;
import '../core/restricted_path_variant.dart';
import 'root_shizuku_service.dart';

class RecycleBinItem {
  final String id;
  final String originalPath;
  final String name;
  final DateTime deletedAt;
  final int size;
  final bool isDirectory;

  RecycleBinItem({
    required this.id,
    required this.originalPath,
    required this.name,
    required this.deletedAt,
    required this.size,
    required this.isDirectory,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'originalPath': originalPath,
        'name': name,
        'deletedAt': deletedAt.toIso8601String(),
        'size': size,
        'isDirectory': isDirectory,
      };

  factory RecycleBinItem.fromJson(Map<String, dynamic> json) => RecycleBinItem(
        id: json['id'],
        originalPath: json['originalPath'],
        name: json['name'],
        deletedAt: DateTime.parse(json['deletedAt']),
        size: json['size'] ?? 0,
        isDirectory: json['isDirectory'] ?? false,
      );
}

class RecycleBinService {
  static SharedPreferences? _prefs;
  static const String _keyRecycleBinItems = 'recycle_bin_items';
  static const String _keyEnableRecycleBin = 'enable_recycle_bin';
  static const String _keyRecycleBinAutoDeleteDays = 'recycle_bin_auto_delete_days';

  static const String trashDirectoryPath = '/storage/emulated/0/.nfile_trash';

  static List<RecycleBinItem> _trashItems = [];

  static Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();
    final list = _prefs?.getStringList(_keyRecycleBinItems) ?? [];
    _trashItems = list
        .map((itemStr) => RecycleBinItem.fromJson(jsonDecode(itemStr)))
        .toList();
    
    // Automatically trigger background cleanup of expired items on launch
    await autoCleanupExpired();
  }

  static bool isEnabled() {
    return _prefs?.getBool(_keyEnableRecycleBin) ?? false;
  }

  static Future<void> setEnabled(bool enabled) async {
    await _prefs?.setBool(_keyEnableRecycleBin, enabled);
  }

  static int getAutoDeleteDays() {
    return _prefs?.getInt(_keyRecycleBinAutoDeleteDays) ?? 30; // default 30 days
  }

  static Future<void> setAutoDeleteDays(int days) async {
    await _prefs?.setInt(_keyRecycleBinAutoDeleteDays, days);
  }

  static List<RecycleBinItem> getTrashItems() {
    // Return sorted by deletion date descending (newest first)
    _trashItems.sort((a, b) => b.deletedAt.compareTo(a.deletedAt));
    return _trashItems;
  }

  static Future<void> moveToTrash(String path, {bool useRoot = false}) async {
    // Ensure trash directory exists
    final trashDir = Directory(trashDirectoryPath);
    if (!trashDir.existsSync()) {
      trashDir.createSync(recursive: true);
    }

    final id = DateTime.now().millisecondsSinceEpoch.toString();
    final trashPath = p.join(trashDirectoryPath, id);

    // ⚠️ 受限路径（其它应用的 Android/{data,obb}）**绝不能**先用 Dart IO 探测类型：
    //    app 进程的 stat 会被 FUSE 拒绝并抛 `PathAccessException: Exists failed
    //    (errno 13)`，后面的 shell / 变体绕过分支根本没机会执行 —— 这正是
    //    「进入 Android/data 后删除必失败」的直接原因（真机反馈）。
    //    类型判定改走 shell → 零宽变体通道；也**不做**「不存在则抛」的前置校验
    //    （受限路径本来就 stat 不到，失败由下方移动结果统一暴露）。
    final isRestricted = _isRestrictedStoragePath(path);

    bool isDirectory = false;
    int size = 0;
    if (isRestricted) {
      isDirectory = await _restrictedIsDirectory(path, useRoot: useRoot);
      size = await _restrictedSize(path, useRoot: useRoot, isDirectory: isDirectory);
    } else {
      final fileExists = File(path).existsSync();
      final dirExists = Directory(path).existsSync();
      isDirectory = dirExists;
      if (!fileExists && !dirExists) {
        throw Exception("Source file/folder does not exist: $path");
      }
      // 体积仅用于回收站列表展示（recycle_bin_screen.dart:394/691）。
      // ⚠️ 目录体积**不能**在移动前同步遍历：Telegram 缓存动辄数万小文件，
      //    一次 dir.list(recursive:true) + 每文件 lengthSync() 会把整个删除动作
      //    阻塞住（可吃掉数十秒）；且受限目录（其它应用的 Android/data）Dart IO
      //    根本读不到内容，遍历出来恒为 0。目录一律改为移动完成后后台补算。
      if (!isDirectory) {
        try {
          size = File(path).lengthSync();
        } catch (_) {}
      }
    }

    // Move to trash using standard rename/move or Shizuku/root move-copy-delete
    if (isRestricted) {
      // ⚠️ 必须是**移动**，不能是 copy + delete（与 file_manager_provider.pasteFile
      //    7650-7668 的既定约定一致）：同文件系统内 `mv` 只改元数据，1.2GB 也是
      //    毫秒级；而 `cp -r` 会实打实读 1.2GB + 写 1.2GB（≈2.4GB I/O ⇒ 约 1 分钟）。
      //    旧实现用的就是 copy + delete —— 这正是「删 Telegram 文件夹要 1 分钟」的根因。
      //
      // 通道依次尝试（覆盖各类 ROM / 权限模式）：
      //   ① shell `mv` —— 有 root/Shizuku 时对底层路径与 FUSE 路径均有权限；
      //   ② 标准路径 rename(2) —— 部分 ROM 的 FUSE 只拦 stat 却放行 rename，
      //      同卷仍是纯元数据操作（File.rename 对目录同样有效，都是 rename(2)）；
      //   ③ 零宽变体路径 rename —— 「无需授权直访」模式（无 root/Shizuku）下，
      //      app 进程经变体路径绕过 FUSE 的路径串匹配；
      //   ④ shell copy+delete → 变体复制 + 变体删除（末级回退）。
      bool moved = false;
      try {
        await RootShizukuService.moveItem(path, trashPath, useRoot: useRoot);
        moved = true;
      } catch (e) {
        debugPrint('[RecycleBin] 受限路径 moveItem 失败，试标准 rename: $e');
      }
      if (!moved) {
        try {
          await File(path).rename(trashPath);
          moved = true;
          debugPrint('[RecycleBin] 受限路径经标准 rename 移入回收站成功');
        } catch (e) {
          debugPrint('[RecycleBin] 受限路径标准 rename 失败，试变体 rename: $e');
        }
      }
      if (!moved) {
        moved = await tryRenameViaRestrictedVariants(path, trashPath);
        if (moved) debugPrint('[RecycleBin] 受限路径经变体 rename 移入回收站成功');
      }
      if (!moved) {
        try {
          await RootShizukuService.copyItem(path, trashPath, useRoot: useRoot);
          await RootShizukuService.deleteItem(path, useRoot: useRoot);
          moved = true;
        } catch (e) {
          debugPrint('[RecycleBin] 受限路径 shell copy+delete 失败，试变体复制: $e');
        }
      }
      if (!moved) {
        final copied = await tryCopyTreeViaRestrictedVariants(path, trashPath);
        if (copied) {
          if (await tryDeleteViaRestrictedVariants(path)) {
            moved = true;
          } else {
            // 副本已落盘但源删不掉：撤走副本，避免「回收站有一份、原处还在」
            // 造成的假删除与空间翻倍。撤不掉也不登记条目（宁可报错）。
            await _removeTrashEntry(trashPath);
          }
        }
      }
      if (!moved) {
        throw Exception('Move to trash failed (restricted path): $path');
      }
    } else {
      try {
        if (isDirectory) {
          await Directory(path).rename(trashPath);
        } else {
          await File(path).rename(trashPath);
        }
      } catch (e) {
        // rename 失败（跨卷 EXDEV / 权限 / 路径过长）：先试 shell `mv`（有 root/Shizuku
        // 时同卷仍是元数据操作），最后才回退真正要搬字节的 copy + delete。
        bool moved = false;
        try {
          await RootShizukuService.moveItem(path, trashPath, useRoot: useRoot);
          moved = true;
        } catch (e2) {
          debugPrint('[RecycleBin] rename 失败且 moveItem 亦失败，回退 copy+delete: $e2');
        }
        if (!moved) {
          if (isDirectory) {
            await _copyDirectory(path, trashPath);
            await Directory(path).delete(recursive: true);
          } else {
            await File(path).copy(trashPath);
            await File(path).delete();
          }
        }
      }
    }

    // Add metadata entry
    final newItem = RecycleBinItem(
      id: id,
      originalPath: path,
      name: p.basename(path),
      deletedAt: DateTime.now(),
      size: size,
      isDirectory: isDirectory,
    );
    _trashItems.add(newItem);
    await _saveToPrefs();

    // 目录体积后台补算：目标已移动完成，不再阻塞删除返回（只影响回收站列表里的体积显示）。
    if (isDirectory) {
      unawaited(_backfillDirectorySize(newItem));
    }
  }

  static Future<void> restoreItem(RecycleBinItem item, {bool useRoot = false}) async {
    final trashPath = p.join(trashDirectoryPath, item.id);
    final destPath = item.originalPath;

    final isRestricted = _isRestrictedStoragePath(destPath);

    // Ensure parent directory exists
    // ⚠️ 受限路径的父目录同样 stat 不到（app 进程 stat 被 FUSE 拒绝 →
    //    PathAccessException），必须跳过 Dart IO 的存在性检查，直接交给下方的
    //    shell / 变体通道；父目录本来就在（条目当初就是从那里移走的）。
    if (!isRestricted) {
      final parentDir = Directory(p.dirname(destPath));
      if (!parentDir.existsSync()) {
        parentDir.createSync(recursive: true);
      }
    }

    if (isRestricted) {
      // 与 moveToTrash 同理：优先原子 `mv`（同卷只改元数据），失败才回退 copy + delete。
      bool moved = false;
      try {
        await RootShizukuService.moveItem(trashPath, destPath, useRoot: useRoot);
        moved = true;
      } catch (e) {
        debugPrint('[RecycleBin] 受限路径恢复 moveItem 失败，试标准 rename: $e');
      }
      if (!moved) {
        // 部分 ROM 只拦 stat、放行 rename(2)：标准路径直接改名即可回原处。
        try {
          await File(trashPath).rename(destPath);
          moved = true;
          debugPrint('[RecycleBin] 受限路径恢复经标准 rename 成功');
        } catch (e) {
          debugPrint('[RecycleBin] 受限路径恢复标准 rename 失败，试变体: $e');
        }
      }
      if (!moved) {
        // 直访模式（无 root/Shizuku）：变体施加在**目标侧**（源是回收站普通路径）。
        moved = await tryRenameToRestrictedVariant(trashPath, destPath);
        if (moved) debugPrint('[RecycleBin] 受限路径恢复经变体 rename 成功');
      }
      if (!moved) {
        try {
          await RootShizukuService.copyItem(trashPath, destPath, useRoot: useRoot);
          await RootShizukuService.deleteItem(trashPath, useRoot: useRoot);
          moved = true;
        } catch (e) {
          debugPrint('[RecycleBin] 受限路径恢复 shell copy+delete 失败: $e');
        }
      }
      if (!moved) {
        throw Exception('Restore failed (restricted path): $destPath');
      }
    } else {
      try {
        if (item.isDirectory) {
          await Directory(trashPath).rename(destPath);
        } else {
          await File(trashPath).rename(destPath);
        }
      } catch (e) {
        // rename 失败（跨卷 EXDEV / 权限）：先试 shell `mv`，最后才回退 copy + delete。
        bool moved = false;
        try {
          await RootShizukuService.moveItem(trashPath, destPath, useRoot: useRoot);
          moved = true;
        } catch (e2) {
          debugPrint('[RecycleBin] 恢复 rename 失败且 moveItem 亦失败，回退 copy+delete: $e2');
        }
        if (!moved) {
          if (item.isDirectory) {
            await _copyDirectory(trashPath, destPath);
            await Directory(trashPath).delete(recursive: true);
          } else {
            await File(trashPath).copy(destPath);
            await File(trashPath).delete();
          }
        }
      }
    }

    _trashItems.removeWhere((x) => x.id == item.id);
    await _saveToPrefs();
  }

  static Future<void> deletePermanently(RecycleBinItem item, {bool useRoot = false}) async {
    final trashPath = p.join(trashDirectoryPath, item.id);

    try {
      final type = FileSystemEntity.typeSync(trashPath);
      if (type == FileSystemEntityType.directory) {
        await Directory(trashPath).delete(recursive: true);
      } else if (type == FileSystemEntityType.file) {
        await File(trashPath).delete();
      }
    } catch (_) {
      // Just in case, try root/Shizuku delete
      try {
        await RootShizukuService.deleteItem(trashPath, useRoot: useRoot);
      } catch (_) {}
    }

    _trashItems.removeWhere((x) => x.id == item.id);
    await _saveToPrefs();
  }

  static Future<void> emptyBin({bool useRoot = false}) async {
    final trashDir = Directory(trashDirectoryPath);
    if (trashDir.existsSync()) {
      try {
        await trashDir.delete(recursive: true);
      } catch (_) {}
    }
    _trashItems.clear();
    await _saveToPrefs();
  }

  static Future<void> autoCleanupExpired({bool useRoot = false}) async {
    final days = getAutoDeleteDays();
    if (days <= 0) return; // 0 or negative means Never auto-delete

    final now = DateTime.now();
    final expiredItems = _trashItems.where((item) {
      final diff = now.difference(item.deletedAt).inDays;
      return diff >= days;
    }).toList();

    for (final item in expiredItems) {
      await deletePermanently(item, useRoot: useRoot);
    }
  }

  // --- Internals & Helpers ---

  /// 是否位于「其它应用的 Android/{data,obb}」FUSE 受限区。
  ///
  /// 判定前先剥离零宽字符 / `/./` 变体标记：变体路径在界面上不可见（零宽字符
  /// 不渲染），直接做子串匹配会漏判（`/Android/​data` 被断开），进而把受限路径
  /// 交给 Dart IO —— app 进程的 stat 被 FUSE 拒绝，必抛 `Exists failed`。
  /// 自身包名目录 app 本身可读写，不算受限。
  static bool _isRestrictedStoragePath(String path) {
    final normalized =
        stripRestrictedVariantMarkers(path).replaceAll(RegExp(r'/+'), '/');
    const marker = '/storage/emulated/0/Android/';
    if (!normalized.startsWith(marker)) return false;
    final sub =
        normalized.substring(marker.length).replaceAll(RegExp(r'/+$'), '');
    if (sub != 'data' &&
        !sub.startsWith('data/') &&
        sub != 'obb' &&
        !sub.startsWith('obb/')) {
      return false;
    }
    return !sub.startsWith('data/com.sequl.zenfile2') &&
        !sub.startsWith('obb/com.sequl.zenfile2');
  }

  /// 受限路径上判定条目是否为目录：shell stat → 零宽变体探测
  /// （两条通道都不触碰干净路径的 Dart IO）。均不可用时按「非目录」返回，
  /// 由后续移动通道的实际结果兜底报错。
  static Future<bool> _restrictedIsDirectory(String path,
      {required bool useRoot}) async {
    try {
      final st = await RootShizukuService.statItem(path, useRoot: useRoot);
      if (st != null) return st.isDirectory;
    } catch (_) {}
    return (await typeViaRestrictedVariants(path)) ==
        FileSystemEntityType.directory;
  }

  /// 受限路径上取文件体积（仅用于回收站列表展示；取不到按 0。
  /// 目录不做预遍历，移动完成后由 _backfillDirectorySize 后台补算）。
  static Future<int> _restrictedSize(String path,
      {required bool useRoot, required bool isDirectory}) async {
    if (isDirectory) return 0;
    try {
      final st = await RootShizukuService.statItem(path, useRoot: useRoot);
      if (st != null) return st.size;
    } catch (_) {}
    return 0;
  }

  /// 撤走回收站条目（复制成功但源未能删除时的清理，避免假删除与空间翻倍）。
  static Future<void> _removeTrashEntry(String trashPath) async {
    try {
      if (FileSystemEntity.typeSync(trashPath) == FileSystemEntityType.directory) {
        await Directory(trashPath).delete(recursive: true);
      } else {
        await File(trashPath).delete();
      }
    } catch (_) {}
  }

  static Future<void> _saveToPrefs() async {
    final list = _trashItems.map((item) => jsonEncode(item.toJson())).toList();
    await _prefs?.setStringList(_keyRecycleBinItems, list);
  }

  static Future<int> _getFolderSize(String path) async {
    int totalSize = 0;
    try {
      final dir = Directory(path);
      await for (final entity in dir.list(recursive: true, followLinks: false)) {
        if (entity is File) {
          totalSize += entity.lengthSync();
        }
      }
    } catch (_) {}
    return totalSize;
  }

  /// 移动**之后**在后台补算目录体积并回写（仅用于回收站列表展示）。
  /// 补算期间条目可能已被恢复 / 永久删除 ⇒ 找不到就丢弃结果，避免重复入账。
  static Future<void> _backfillDirectorySize(RecycleBinItem item) async {
    int size = 0;
    try {
      size = await _getFolderSize(p.join(trashDirectoryPath, item.id));
    } catch (_) {}
    final index = _trashItems.indexWhere((x) => x.id == item.id);
    if (index == -1) return;
    _trashItems[index] = RecycleBinItem(
      id: item.id,
      originalPath: item.originalPath,
      name: item.name,
      deletedAt: item.deletedAt,
      size: size,
      isDirectory: item.isDirectory,
    );
    await _saveToPrefs();
  }

  static Future<void> _copyDirectory(String source, String destination) async {
    final sourceDir = Directory(source);
    final destinationDir = Directory(destination);
    if (!destinationDir.existsSync()) {
      destinationDir.createSync(recursive: true);
    }
    await for (final entity in sourceDir.list(recursive: false)) {
      final name = p.basename(entity.path);
      final newPath = p.join(destination, name);
      if (entity is Directory) {
        await _copyDirectory(entity.path, newPath);
      } else if (entity is File) {
        await entity.copy(newPath);
      }
    }
  }
}
