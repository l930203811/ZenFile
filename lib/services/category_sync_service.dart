import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

/// 分类页「备份到云端」相关持久化状态：
/// 1. 每个类别的「自动备份」开关（控制备份菜单中自动备份开关的显隐）。
/// 2. 同步记录 [CategorySyncRecord]：记录每一个被备份的本地文件与其远程副本的对应关系，
///    用于云徽显示与「远程/本地文件被删除后自动撤销云徽」的剪枝（prune）逻辑。
/// 注意：仅支持「本地 → 远程」单向备份，无方向选择。
class CategorySyncService {
  static const String _keyAutoSync = 'category_auto_sync_enabled';
  static const String _keyRecords = 'category_sync_records';

  static Map<String, bool> _autoSyncCache = {};
  static List<CategorySyncRecord> _recordsCache = [];
  static bool _loaded = false;

  /// 应用启动时调用，预加载缓存（需在 runApp 之前 await）。
  static Future<void> init() async {
    if (_loaded) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final autoStr = prefs.getString(_keyAutoSync);
      if (autoStr != null) {
        try {
          final map = jsonDecode(autoStr) as Map<String, dynamic>;
          _autoSyncCache = map.map((k, v) => MapEntry(k, v is bool ? v : false));
        } catch (_) {
          _autoSyncCache = {};
        }
      }
      final recStr = prefs.getString(_keyRecords);
      if (recStr != null) {
        try {
          final list = jsonDecode(recStr) as List<dynamic>;
          _recordsCache = list
              .whereType<Map<String, dynamic>>()
              .map((m) => CategorySyncRecord.fromJson(m))
              .where((r) => r != null)
              .cast<CategorySyncRecord>()
              .toList();
        } catch (_) {
          _recordsCache = [];
        }
      }
    } catch (_) {
      // 忽略读取异常，保持空缓存
    }
    _loaded = true;
  }

  /// 某类别是否开启了「自动备份」。
  static Future<bool> isAutoSyncEnabled(String label) async {
    await init();
    return _autoSyncCache[label] ?? false;
  }

  static Future<void> setAutoSyncEnabled(String label, bool enabled) async {
    await init();
    _autoSyncCache[label] = enabled;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_keyAutoSync, jsonEncode(_autoSyncCache));
    } catch (_) {}
  }

  /// 同步读取：本地路径是否已同步（存在有效记录即显示云徽）。
  /// 需在 [init] 之后调用（应用启动即已加载）。
  static bool isSyncedLocalPath(String path) {
    for (final r in _recordsCache) {
      if (r.localPath == path) return true;
    }
    return false;
  }

  /// 同步读取：某目录下是否存在已同步的文件（用于文件夹磁贴显示云徽）。
  static bool hasSyncedFileUnder(String dir) {
    if (dir.isEmpty) return false;
    final prefix = dir.endsWith('/') ? dir : '$dir/';
    for (final r in _recordsCache) {
      if (r.localPath == dir || r.localPath.startsWith(prefix)) return true;
    }
    return false;
  }

  /// 同步读取：返回当前全部同步记录（provider 在同步时据此剪枝）。
  static List<CategorySyncRecord> getAllRecords() {
    return List<CategorySyncRecord>.from(_recordsCache);
  }

  /// 整体覆盖保存记录（provider 在完成同步/剪枝后调用）。
  static Future<void> saveAllRecords(List<CategorySyncRecord> records) async {
    await init();
    _recordsCache = List<CategorySyncRecord>.from(records);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _keyRecords,
        jsonEncode(_recordsCache.map((r) => r.toJson()).toList()),
      );
    } catch (_) {}
  }
}

/// 单条同步记录：一个本地文件与其远程副本的映射。
/// [toRemote]=true 表示「本地 → 远程」产生（本地文件显示云徽）；
/// [toRemote]=false 表示「远程 → 本地」产生（从远程下载到本地的文件显示云徽）。
class CategorySyncRecord {
  final String category;
  final String localPath;
  /// 远程副本路径，形如 `remote://{connectionId}|{serverPath}`。
  final String remotePath;
  final int size;
  final bool toRemote;

  CategorySyncRecord({
    required this.category,
    required this.localPath,
    required this.remotePath,
    required this.size,
    required this.toRemote,
  });

  Map<String, dynamic> toJson() => {
        'c': category,
        'l': localPath,
        'r': remotePath,
        's': size,
        't': toRemote ? 1 : 0,
      };

  static CategorySyncRecord? fromJson(Map<String, dynamic> m) {
    try {
      return CategorySyncRecord(
        category: m['c'] as String,
        localPath: m['l'] as String,
        remotePath: m['r'] as String,
        size: (m['s'] is int) ? m['s'] as int : 0,
        toRemote: (m['t'] as int? ?? 1) == 1,
      );
    } catch (_) {
      return null;
    }
  }
}
