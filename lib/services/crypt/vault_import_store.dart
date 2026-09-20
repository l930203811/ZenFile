/// 保险箱「导入清单」持久化 + rclone/OpenList 加密文件识别
///
/// 保险箱底部的三个区域中：
/// - 「未加密文件」= 导入清单里 `encrypted == false` 的条目
/// - 「原地加密文件」= 挂载点扫描出的加密条目 ∪ 导入清单里 `encrypted == true` 的条目
///
/// 导入只登记路径，不移动/复制原始文件；后续由用户对该条目选择
/// 「原地加密」或「沙盒加密」才真正处理文件。
library;

import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'crypt_config.dart';
import 'crypt_mount.dart';
import 'crypt_operations.dart';

/// 保险箱导入条目
class VaultImportEntry {
  /// 原始文件/文件夹路径
  final String path;

  /// 是否为文件夹
  final bool isDirectory;

  /// 导入时是否检测为 rclone/OpenList crypt 加密
  final bool encrypted;

  /// 文件大小（字节，文件夹为 0）
  final int size;

  /// 最后修改时间（毫秒时间戳）
  final int modifiedMs;

  VaultImportEntry({
    required this.path,
    required this.isDirectory,
    required this.encrypted,
    this.size = 0,
    int? modifiedMs,
  }) : modifiedMs = modifiedMs ?? 0;

  /// 显示名称
  String get name => p.basename(path);

  /// 最后修改时间
  DateTime get modified =>
      DateTime.fromMillisecondsSinceEpoch(modifiedMs == 0 ? DateTime.now().millisecondsSinceEpoch : modifiedMs);

  Map<String, dynamic> toJson() => {
        'path': path,
        'isDirectory': isDirectory,
        'encrypted': encrypted,
        'size': size,
        'modifiedMs': modifiedMs,
      };

  factory VaultImportEntry.fromJson(Map<String, dynamic> json) {
    return VaultImportEntry(
      path: json['path'] as String? ?? '',
      isDirectory: json['isDirectory'] as bool? ?? false,
      encrypted: json['encrypted'] as bool? ?? false,
      size: json['size'] as int? ?? 0,
      modifiedMs: json['modifiedMs'] as int? ?? 0,
    );
  }

  VaultImportEntry copyWith({
    String? path,
    bool? isDirectory,
    bool? encrypted,
    int? size,
    int? modifiedMs,
  }) {
    return VaultImportEntry(
      path: path ?? this.path,
      isDirectory: isDirectory ?? this.isDirectory,
      encrypted: encrypted ?? this.encrypted,
      size: size ?? this.size,
      modifiedMs: modifiedMs ?? this.modifiedMs,
    );
  }
}

/// 保险箱导入清单存储
class VaultImportStore {
  static const String _kKey = 'vault_import_entries';

  /// 加载全部导入条目
  static Future<List<VaultImportEntry>> load() async {
    final prefs = await SharedPreferences.getInstance();
    final jsonStr = prefs.getString(_kKey);
    if (jsonStr == null || jsonStr.isEmpty) return [];
    try {
      final List<dynamic> list = jsonDecode(jsonStr);
      return list
          .whereType<Map<String, dynamic>>()
          .map(VaultImportEntry.fromJson)
          .where((e) => e.path.isNotEmpty)
          .toList();
    } catch (_) {
      return [];
    }
  }

  /// 覆盖式保存
  static Future<void> save(List<VaultImportEntry> entries) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _kKey,
      jsonEncode(entries.map((e) => e.toJson()).toList()),
    );
  }

  /// 新增/更新条目（同路径覆盖）
  static Future<void> upsert(VaultImportEntry entry) async {
    final entries = await load();
    entries.removeWhere((e) => e.path == entry.path);
    entries.add(entry);
    await save(entries);
  }

  /// 移除条目
  static Future<void> remove(String path) async {
    final entries = await load();
    entries.removeWhere((e) => e.path == path);
    await save(entries);
  }

  /// 「已隐藏」集合的持久化 key：
  /// 用户在保险箱「原地加密文件」列表里点了「移除」的项。
  /// 仅从列表隐藏，不删除磁盘上的原地加密文件本身；挂载点重新扫描
  /// 仍会扫到该文件，因此必须用持久化集合过滤。
  static const String _kRemovedKey = 'vault_import_removed';

  /// 加载「已从原地加密列表移除」的路径集合
  static Future<Set<String>> loadRemoved() async {
    final prefs = await SharedPreferences.getInstance();
    final jsonStr = prefs.getString(_kRemovedKey);
    if (jsonStr == null || jsonStr.isEmpty) return {};
    try {
      final List<dynamic> list = jsonDecode(jsonStr);
      return list.whereType<String>().where((s) => s.isNotEmpty).toSet();
    } catch (_) {
      return {};
    }
  }

  /// 将路径加入「已从原地加密列表移除」集合（仅隐藏，不删文件）
  static Future<void> markRemoved(String path) async {
    final prefs = await SharedPreferences.getInstance();
    final removed = await loadRemoved();
    removed.add(path);
    await prefs.setString(_kRemovedKey, jsonEncode(removed.toList()));
  }

  /// 读取前 8 字节判断是否为 rclone/OpenList crypt 文件头 magic
  static Future<bool> _fileHasCryptMagic(String path) async {
    RandomAccessFile? raf;
    try {
      final file = File(path);
      if (!await file.exists()) return false;
      raf = await file.open(mode: FileMode.read);
      final head = await raf.read(fileMagicSize);
      if (head.length < fileMagicSize) return false;
      for (var i = 0; i < fileMagicSize; i++) {
        if (head[i] != fileHeaderMagicBytes[i]) return false;
      }
      return true;
    } catch (_) {
      return false;
    } finally {
      await raf?.close();
    }
  }

  /// 检测文件/文件夹是否为 rclone / OpenList crypt 加密
  ///
  /// - 文件：读取开头 8 字节比对 magic `RCLONE\x00\x00`
  /// - 文件夹：统一走 [CryptOperations.isDirectoryStillEncrypted]（**目录实体本身
  ///   是否加密**：目录名是密文名；名字不加密的配置才退回内容判定）。
  ///
  /// ⚠️ 旧实现「目录内任一子文件带 magic 即算加密目录」会把**夹带一个密文文件的
  /// 普通文件夹**误判成「已加密」→ 用户在保险箱选它做原地加密时被静默跳过
  /// （skipCount++，文件夹根本没被加密），与「文件夹没有加密，但文件夹中有一个
  /// 文件加密」的反馈同源。目录内真正的密文文件由加密时的 `skipEncrypted` 跳过，
  /// 不会重复加密。
  static Future<bool> detectEncrypted(
    String path,
    List<CryptMountPoint> mounts,
  ) async {
    try {
      if (File(path).existsSync()) {
        return await _fileHasCryptMagic(path);
      }
      if (Directory(path).existsSync()) {
        for (final mount in mounts) {
          try {
            if (await CryptOperations.isDirectoryStillEncrypted(
              path,
              mount: mount,
            )) {
              return true;
            }
          } catch (_) {}
        }
      }
    } catch (_) {}
    return false;
  }

  /// [path] 当前是否**仍是磁盘上的密文实体**。
  ///
  /// 用于剔除「已失效」的导入条目：用户在浏览页解密（文件变明文）或删除
  /// （路径消失）后，导入清单里的旧记录必须作废，否则它会继续出现在保险箱
  /// 「原地加密文件」区域，看起来像密文还在。
  ///
  /// ⚠️ 判定失败、或**无法判定**（没有任何可用挂载点）时一律返回 `true`
  /// （保守保留）：宁可多留一条记录，也绝不因为判不准就误删用户的导入清单。
  static Future<bool> stillEncrypted(
    String path,
    List<CryptMountPoint> mounts,
  ) async {
    try {
      final type = await FileSystemEntity.type(path);
      if (type == FileSystemEntityType.notFound) return false;
      // 文件：读 RCLONE magic 头，与密钥/档案无关，最可靠
      if (type == FileSystemEntityType.file) {
        return await _fileHasCryptMagic(path);
      }
      if (type != FileSystemEntityType.directory) return true;
      // 没有可用密钥（无挂载点 / 密码未补齐）→ 无法判定目录是否已解密 → 保留
      if (mounts.isEmpty ||
          mounts.every((m) => m.config.password.isEmpty)) {
        return true;
      }

      // 目录判定统一走 [CryptOperations.isDirectoryStillEncrypted]，与浏览页
      // 复制/剪切的目标判定共用同一实现（避免两处各自演化后再次分叉）。
      for (final m in mounts) {
        try {
          if (await CryptOperations.isDirectoryStillEncrypted(path, mount: m)) {
            return true;
          }
        } catch (_) {}
      }
      return false;
    } catch (_) {
      return true;
    }
  }

  /// 清理已失效的导入条目并持久化，返回清理后的清单。
  ///
  /// 「失效」的两种情形：
  /// ① 路径在磁盘上已不存在（用户在浏览页删除了原文件）；
  /// ② 条目标记为已加密，但当前已不再是密文（用户在浏览页解密了）。
  ///
  /// ⚠️ 判定「已删除」时必须先确认**父目录仍然存在**：否则在早期启动、
  /// SD 卡未挂载、存储权限尚未就绪等「整个存储暂时不可见」的场景下，
  /// 会把用户全部导入记录当成垃圾清空。
  static Future<List<VaultImportEntry>> pruneStale(
    List<CryptMountPoint> mounts,
  ) async {
    final entries = await load();
    if (entries.isEmpty) return entries;
    final kept = <VaultImportEntry>[];
    var changed = false;
    for (final e in entries) {
      if (FileSystemEntity.typeSync(e.path) == FileSystemEntityType.notFound) {
        final parent = p.dirname(e.path);
        final parentAlive =
            parent.isNotEmpty && await Directory(parent).exists();
        if (parentAlive) {
          changed = true; // 确实被删除了
          continue;
        }
        kept.add(e); // 整个存储暂时不可见 → 不能据此清空
        continue;
      }
      if (e.encrypted && !await stillEncrypted(e.path, mounts)) {
        changed = true;
        continue;
      }
      kept.add(e);
    }
    if (changed) {
      try {
        await save(kept);
      } catch (_) {}
    }
    return kept;
  }
}
