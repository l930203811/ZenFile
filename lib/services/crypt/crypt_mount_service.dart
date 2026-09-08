import 'dart:convert';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'crypt_config.dart';
import 'crypt_mount.dart';

/// 加密挂载点持久化服务
///
/// 负责保存和加载加密挂载点配置。
/// 配置（不含密码）保存在 SharedPreferences，密码单独保存在 FlutterSecureStorage
/// （Android Keystore / iOS Keychain 硬件级加密）。
class CryptMountService {
  static const String _kMountPointsKey = 'crypt_mount_points';
  static const String _kPasswordPrefix = 'crypt_mount_password_';

  static const FlutterSecureStorage _secureStorage = FlutterSecureStorage();

  /// 加载所有已保存的加密挂载点
  static Future<List<CryptMountPoint>> loadMountPoints() async {
    final prefs = await SharedPreferences.getInstance();
    final jsonStr = prefs.getString(_kMountPointsKey);
    if (jsonStr == null || jsonStr.isEmpty) return [];

    try {
      final List<dynamic> list = jsonDecode(jsonStr);
      final mounts = <CryptMountPoint>[];
      for (final item in list) {
        if (item is! Map<String, dynamic>) continue;
        final physicalPath = item['physicalPath'] as String?;
        if (physicalPath == null || physicalPath.isEmpty) continue;

        // 从安全存储读取密码
        final password = await _secureStorage.read(
          key: '$_kPasswordPrefix${_pathHash(physicalPath)}',
        );

        final config = RcloneCryptConfig.fromJson(
          item['config'] as Map<String, dynamic>? ?? {},
          password ?? '',
        );

        mounts.add(CryptMountPoint(
          physicalPath: physicalPath,
          config: config,
          name: item['name'] as String?,
          isSandboxMode: item['isSandboxMode'] as bool? ?? false,
        ));
      }
      return mounts;
    } catch (_) {
      return [];
    }
  }

  /// 保存所有加密挂载点（覆盖式写入）
  static Future<void> saveMountPoints(List<CryptMountPoint> mounts) async {
    final prefs = await SharedPreferences.getInstance();
    final list = <Map<String, dynamic>>[];

    for (final mount in mounts) {
      // 保存密码到安全存储
      if (mount.config.password.isNotEmpty) {
        await _secureStorage.write(
          key: '$_kPasswordPrefix${_pathHash(mount.physicalPath)}',
          value: mount.config.password,
        );
      } else {
        await _secureStorage.delete(
          key: '$_kPasswordPrefix${_pathHash(mount.physicalPath)}',
        );
      }

      list.add({
        'physicalPath': mount.physicalPath,
        'name': mount.name,
        'isSandboxMode': mount.isSandboxMode,
        'config': mount.config.toJson(includePassword: false),
      });
    }

    await prefs.setString(_kMountPointsKey, jsonEncode(list));
  }

  /// 添加一个加密挂载点
  static Future<void> addMountPoint(CryptMountPoint mount) async {
    final mounts = await loadMountPoints();
    // 移除同路径的旧配置
    mounts.removeWhere((m) => m.physicalPath == mount.physicalPath);
    mounts.add(mount);
    await saveMountPoints(mounts);
  }

  /// 删除一个加密挂载点
  static Future<void> removeMountPoint(String physicalPath) async {
    final mounts = await loadMountPoints();
    mounts.removeWhere((m) => m.physicalPath == physicalPath);
    await saveMountPoints(mounts);
    // 同时删除安全存储中的密码
    await _secureStorage.delete(
      key: '$_kPasswordPrefix${_pathHash(physicalPath)}',
    );
  }

  /// 检查路径是否已配置为加密挂载点
  static Future<bool> isMountPoint(String physicalPath) async {
    final mounts = await loadMountPoints();
    return mounts.any((m) => m.physicalPath == physicalPath);
  }

  /// 路径哈希（用于安全存储的 key）
  static String _pathHash(String path) {
    // 简单的字符串哈希，避免路径中包含特殊字符导致 key 非法
    var hash = 0;
    for (var i = 0; i < path.length; i++) {
      hash = (hash * 31 + path.codeUnitAt(i)) & 0x7fffffff;
    }
    return hash.toString();
  }
}
