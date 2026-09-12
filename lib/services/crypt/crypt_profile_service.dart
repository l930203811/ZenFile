import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'crypt_config.dart';
import 'crypt_mount_service.dart';
import 'crypt_profile.dart';

/// 加密配置档案的存储后端抽象
///
/// 抽出来是为了可测试：单测注入 [InMemoryCryptProfileStorage] 即可，
/// 不必依赖 Android Keystore / SharedPreferences 的平台通道。
abstract class CryptProfileStorage {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

/// 默认实现：FlutterSecureStorage（Android Keystore / iOS Keychain）
class SecureCryptProfileStorage implements CryptProfileStorage {
  const SecureCryptProfileStorage([this._storage]);

  final FlutterSecureStorage? _storage;

  FlutterSecureStorage get _s => _storage ?? const FlutterSecureStorage();

  @override
  Future<String?> read(String key) async {
    try {
      return await _s.read(key: key);
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> write(String key, String value) async {
    try {
      await _s.write(key: key, value: value);
    } catch (_) {}
  }

  @override
  Future<void> delete(String key) async {
    try {
      await _s.delete(key: key);
    } catch (_) {}
  }
}

/// 内存实现（单测用）
class InMemoryCryptProfileStorage implements CryptProfileStorage {
  final Map<String, String> _data = {};

  @override
  Future<String?> read(String key) async => _data[key];

  @override
  Future<void> write(String key, String value) async => _data[key] = value;

  @override
  Future<void> delete(String key) async => _data.remove(key);
}

/// 加密配置档案服务
///
/// 负责多组「主密码 + 加盐 + 编码/后缀」配置的持久化，以及
/// 「路径 → 档案」的绑定关系。
///
/// ## 为什么档案与路径要分开存
/// 从密文**无法反推**它用的是哪组密钥（EME 文件名加密是确定性的，
/// 但没有密钥就无法验证）。所以浏览页不能"逐个档案试解"—— 每个
/// `CryptMountPoint` 构造都要跑一次 scrypt（100~300ms），N 个档案就是
/// N 倍卡顿。正确做法是显式记录绑定：有绑定用绑定，没绑定用当前默认档案。
class CryptProfileService {
  CryptProfileService._(this._storage);

  static CryptProfileService? _instance;

  static CryptProfileService get instance =>
      _instance ??= CryptProfileService._(const SecureCryptProfileStorage());

  /// 测试入口：注入内存存储
  static CryptProfileService withStorage(CryptProfileStorage storage) =>
      CryptProfileService._(storage);

  final CryptProfileStorage _storage;

  static const String kProfilesKey = 'crypt_profiles';
  static const String kBindingsKey = 'crypt_profile_bindings';

  /// legacy 单组凭据的 SharedPreferences 键（迁移后不再写）
  static const String kLegacyPasswordKey = 'crypt_last_password';
  static const String kLegacySaltKey = 'crypt_last_salt';
  static const String kLegacyEncKey = 'crypt_last_filename_encoding';
  static const String kLegacySuffixKey = 'crypt_last_encrypted_suffix';
  static const String kMigratedFlagKey = 'crypt_profile_migrated_v1';

  /// legacy 迁移后生成的默认档案名
  static const String defaultProfileName = '默认配置';

  /// 读取全部档案（已过滤无效项）。
  ///
  /// 首次调用会自动把 legacy 的单组凭据迁移成第一份档案，保证老用户无感。
  Future<List<CryptProfile>> loadProfiles() async {
    await ensureMigrated();
    final raw = await _storage.read(kProfilesKey);
    if (raw == null || raw.isEmpty) return const [];
    try {
      final list = jsonDecode(raw);
      if (list is! List) return const [];
      return list
          .whereType<Map<String, dynamic>>()
          .map(CryptProfile.fromJson)
          .where((p) => p.id.isNotEmpty && p.name.isNotEmpty && p.password.isNotEmpty)
          .toList();
    } catch (_) {
      return const [];
    }
  }

  Future<void> saveProfiles(List<CryptProfile> profiles) async {
    await _storage.write(
      kProfilesKey,
      jsonEncode(profiles.map((p) => p.toJson()).toList()),
    );
  }

  /// 名称是否已存在（trim + 忽略大小写）。[exceptId] 用于编辑自身时排除。
  static bool nameExistsIn(
    List<CryptProfile> profiles,
    String name, {
    String? exceptId,
  }) {
    final key = CryptProfile.nameKey(name);
    if (key.isEmpty) return false;
    return profiles.any(
      (p) => p.id != exceptId && CryptProfile.nameKey(p.name) == key,
    );
  }

  Future<bool> nameExists(String name, {String? exceptId}) async =>
      nameExistsIn(await loadProfiles(), name, exceptId: exceptId);

  /// 新增或更新一份档案。
  ///
  /// - 名称重复抛 [ArgumentError]（调用方应先用 [nameExists] 校验）。
  /// - 标记为 active 时会自动取消其它档案的 active。
  /// - 若库中尚无 active 档案（例如第一份），自动设为 active。
  Future<CryptProfile> addOrUpdate(CryptProfile profile) async {
    final profiles = (await loadProfiles()).toList();
    if (nameExistsIn(profiles, profile.name, exceptId: profile.id)) {
      throw ArgumentError('profile_name_duplicated: ${profile.name}');
    }

    var next = profile.copyWith(name: profile.name.trim());
    final idx = profiles.indexWhere((p) => p.id == next.id);
    final hasActive = profiles.any((p) => p.isActive && p.id != next.id);

    if (idx >= 0) {
      // 编辑：保留原 active 状态（除非显式传入 true）
      if (!next.isActive && profiles[idx].isActive) {
        next = next.copyWith(isActive: true);
      }
      profiles[idx] = next;
    } else {
      if (!hasActive) next = next.copyWith(isActive: true);
      profiles.add(next);
    }

    if (next.isActive) {
      for (var i = 0; i < profiles.length; i++) {
        if (profiles[i].id != next.id && profiles[i].isActive) {
          profiles[i] = profiles[i].copyWith(isActive: false);
        }
      }
    }

    await saveProfiles(profiles);
    return next;
  }

  Future<CryptProfile?> byId(String id) async {
    for (final p in await loadProfiles()) {
      if (p.id == id) return p;
    }
    return null;
  }

  /// 当前默认档案（没有则回退第一份）
  Future<CryptProfile?> activeProfile() async {
    final profiles = await loadProfiles();
    if (profiles.isEmpty) return null;
    for (final p in profiles) {
      if (p.isActive) return p;
    }
    return profiles.first;
  }

  Future<void> setActive(String id) async {
    final profiles = (await loadProfiles()).toList();
    var found = false;
    for (var i = 0; i < profiles.length; i++) {
      final active = profiles[i].id == id;
      if (active) found = true;
      profiles[i] = profiles[i].copyWith(isActive: active);
    }
    if (found) await saveProfiles(profiles);
  }

  /// 删除档案，并清理指向它的绑定。
  ///
  /// 若删除的是当前默认档案，自动把剩余第一份设为默认。
  Future<void> delete(String id) async {
    final profiles = (await loadProfiles()).toList();
    final wasActive = profiles.any((p) => p.id == id && p.isActive);
    profiles.removeWhere((p) => p.id == id);
    if (wasActive && profiles.isNotEmpty) {
      profiles[0] = profiles[0].copyWith(isActive: true);
    }
    await saveProfiles(profiles);

    final bindings = await loadBindings();
    bindings.removeWhere((_, pid) => pid == id);
    await saveBindings(bindings);
  }

  // ── 路径绑定表 ────────────────────────────────────────────────────

  Future<Map<String, String>> loadBindings() async {
    final raw = await _storage.read(kBindingsKey);
    if (raw == null || raw.isEmpty) return <String, String>{};
    try {
      final map = jsonDecode(raw);
      if (map is! Map) return <String, String>{};
      return map.map(
        (k, v) => MapEntry(CryptMountService.normalizePosix(k.toString()), v.toString()),
      );
    } catch (_) {
      return <String, String>{};
    }
  }

  Future<void> saveBindings(Map<String, String> bindings) async {
    await _storage.write(kBindingsKey, jsonEncode(bindings));
  }

  /// 从绑定表里为 [path] 找到最合适的档案 ID（**最长祖先前缀**优先）。
  ///
  /// 纯函数，便于单测：绑定 `/a` → 命中 `/a`、`/a/b`、`/a/b/c.txt`。
  static String? matchBindingId(Map<String, String> bindings, String path) {
    final target = CryptMountService.normalizePosix(path);
    if (target.isEmpty) return null;
    String? bestId;
    var bestLen = -1;
    for (final entry in bindings.entries) {
      final dir = entry.key;
      if (dir.isEmpty) continue;
      if (target == dir || target.startsWith('$dir/')) {
        if (dir.length > bestLen) {
          bestLen = dir.length;
          bestId = entry.value;
        }
      }
    }
    return bestId;
  }

  Future<void> bindPath(String path, String profileId) async {
    final normalized = CryptMountService.normalizePosix(path);
    if (normalized.isEmpty || profileId.isEmpty) return;
    final bindings = await loadBindings();
    bindings[normalized] = profileId;
    await saveBindings(bindings);
  }

  Future<void> unbindPath(String path) async {
    final normalized = CryptMountService.normalizePosix(path);
    final bindings = await loadBindings();
    if (bindings.remove(normalized) != null) {
      await saveBindings(bindings);
    }
  }

  /// 为 [path] 解析应使用的档案：先查绑定，再回退当前默认档案。
  Future<CryptProfile?> resolveFor(String path) async {
    final bindings = await loadBindings();
    final id = matchBindingId(bindings, path);
    if (id != null) {
      final bound = await byId(id);
      if (bound != null) return bound;
    }
    return activeProfile();
  }

  // ── legacy 迁移 ──────────────────────────────────────────────────

  /// 把旧版「单组主密码」（SharedPreferences `crypt_last_*`）迁移成第一份档案。
  ///
  /// 幂等：只执行一次（标记 `crypt_profile_migrated_v1`）。
  Future<void> ensureMigrated() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (prefs.getBool(kMigratedFlagKey) ?? false) return;

      final password = prefs.getString(kLegacyPasswordKey) ?? '';
      final existing = await _storage.read(kProfilesKey);
      final hasProfiles = existing != null && existing.isNotEmpty;

      if (password.isNotEmpty && !hasProfiles) {
        final salt = prefs.getString(kLegacySaltKey) ?? '';
        final encName = prefs.getString(kLegacyEncKey) ?? '';
        final suffix = prefs.getString(kLegacySuffixKey) ?? '';
        final profile = CryptProfile(
          id: CryptProfile.newId(),
          name: defaultProfileName,
          password: password,
          salt: salt.isEmpty ? null : salt,
          filenameEncryption: FilenameEncryption.standard,
          directoryNameEncryption: true,
          filenameEncoding: FilenameEncoding.values.firstWhere(
            (e) => e.name == encName,
            orElse: () => FilenameEncoding.base32,
          ),
          encryptedSuffix: suffix, // 保持原样；未保存过的空串由调用方补默认
          createdAtMs: DateTime.now().millisecondsSinceEpoch,
          isActive: true,
        );
        // 旧版未保存过后缀时写的是空串，这里补回 rclone 默认
        if (profile.encryptedSuffix.isEmpty &&
            !(prefs.containsKey(kLegacySuffixKey))) {
          await saveProfiles([profile.copyWith(encryptedSuffix: '.bin')]);
        } else {
          await saveProfiles([profile]);
        }
      }

      await prefs.setBool(kMigratedFlagKey, true);
    } catch (_) {}
  }
}
