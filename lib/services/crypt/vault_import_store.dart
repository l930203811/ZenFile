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
  /// - 文件夹：依次尝试用各挂载点的密钥解密目录名/文件名；
  ///   若文件名加密关闭导致名称解不开，则回退检查其直接子文件是否带 magic
  static Future<bool> detectEncrypted(
    String path,
    List<CryptMountPoint> mounts,
  ) async {
    try {
      if (File(path).existsSync()) {
        return await _fileHasCryptMagic(path);
      }
      if (Directory(path).existsSync()) {
        final name = p.basename(path);
        for (final mount in mounts) {
          try {
            mount.crypt.decryptDirName(name);
            return true;
          } catch (_) {}
          try {
            mount.crypt.decryptFileName(name);
            return true;
          } catch (_) {}
        }
        // 回退：子文件带 magic 即视为加密目录
        await for (final entity in Directory(path).list(recursive: false)) {
          if (entity is File && await _fileHasCryptMagic(entity.path)) {
            return true;
          }
        }
      }
    } catch (_) {}
    return false;
  }
}
