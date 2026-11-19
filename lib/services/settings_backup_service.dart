import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zenfile/l10n/generated/app_localizations.dart';
import '../models/network_connection_model.dart';
import '../services/network_connections_service.dart';
import '../services/remote/remote_client.dart';
import '../services/remote/ftp_client.dart';
import '../services/remote/sftp_client.dart';
import '../services/remote/webdav_client.dart';
import '../services/remote/lan_client.dart';
import '../services/remote/saf_client.dart';
import '../services/backup_secrets_codec.dart';
import '../services/crypt/crypt_mount_service.dart';
import '../services/crypt/crypt_profile.dart';
import '../services/crypt/crypt_profile_service.dart';

class BackupFileInfo {
  final String name;
  final String path;
  final int size;
  final DateTime modified;

  BackupFileInfo({
    required this.name,
    required this.path,
    required this.size,
    required this.modified,
  });
}

/// 恢复结果：success 之外还要暴露敏感块的恢复情况。
/// issue #79 后加密备份不允许跳过：口令未通过时 success=false 且不改动
/// 任何设置；secretsRestored 仅用于结果统计与 UI 文案兜底。
class SettingsRestoreResult {
  final bool success;

  /// 备份文件里是否带有加密敏感块（v2 且包含 secrets）
  final bool hasSecrets;

  /// 敏感块是否成功恢复（= false 且 hasSecrets = true 表示被用户跳过或口令未过）
  final bool secretsRestored;

  const SettingsRestoreResult({
    required this.success,
    this.hasSecrets = false,
    this.secretsRestored = false,
  });
}

class SettingsBackupService {
  static const String defaultBackupDirPath =
      '/storage/emulated/0/ZenFile/Backups/Settings';
  static const String _backupFileNamePrefix = 'zenfile_settings_backup';
  static const String _backupDirPrefKey = 'settings_backup_dir_path';

  /// 备份文件格式版本：v2 = {schema, settings, secrets?}；v1 = 扁平 prefs 表
  static const int _schemaVersion = 2;

  /// 获取当前配置的备份目录路径（本地绝对路径或 remote://{connId}|{remotePath}）
  static Future<String> getBackupDirPath() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_backupDirPrefKey) ?? defaultBackupDirPath;
  }

  /// 持久化备份目录路径
  static Future<void> setBackupDirPath(String path) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_backupDirPrefKey, path);
  }

  /// 判断路径是否为远程路径
  static bool isRemotePath(String path) => path.startsWith('remote://');

  /// 解析远程路径，返回 (connectionId, remoteDirectoryPath) 或 null
  static (String connectionId, String remotePath)? parseRemotePath(String path) {
    if (!isRemotePath(path)) return null;
    final payload = path.substring('remote://'.length);
    final sepIndex = payload.indexOf('|');
    if (sepIndex < 0) return null;
    return (payload.substring(0, sepIndex), payload.substring(sepIndex + 1));
  }

  /// 构造远程路径字符串
  static String buildRemotePath(String connectionId, String remotePath) {
    return 'remote://$connectionId|$remotePath';
  }

  /// 创建与连接类型匹配的远程客户端
  static RemoteClient? _createRemoteClient(NetworkConnectionModel conn) {
    if (conn.type == 'FTP') {
      return FtpRemoteClient(
        host: conn.host,
        port: conn.port,
        username: conn.username,
        password: conn.password,
        proxyType: conn.proxyType,
        proxyHost: conn.proxyHost,
        proxyPort: conn.proxyPort,
        proxyUsername: conn.proxyUsername,
        proxyPassword: conn.proxyPassword,
      );
    } else if (conn.type == 'SFTP') {
      return SftpRemoteClient(
        host: conn.host,
        port: conn.port,
        username: conn.username,
        password: conn.password,
        sshKeyPath: conn.sshKeyPath,
        sshKeyPassword: conn.sshKeyPassword,
        authMethod: conn.authMethod,
        proxyType: conn.proxyType,
        proxyHost: conn.proxyHost,
        proxyPort: conn.proxyPort,
        proxyUsername: conn.proxyUsername,
        proxyPassword: conn.proxyPassword,
      );
    } else if (conn.type == 'WebDav') {
      return WebDavRemoteClient(
        host: conn.host,
        port: conn.port,
        username: conn.username,
        password: conn.password,
        protocol: conn.protocol,
        rootPath: conn.rootPath,
        proxyType: conn.proxyType,
        proxyHost: conn.proxyHost,
        proxyPort: conn.proxyPort,
        proxyUsername: conn.proxyUsername,
        proxyPassword: conn.proxyPassword,
      );
    } else if (NetworkConnectionsService.isSmbType(conn.type)) {
      return LanClient(
        host: conn.host,
        port: conn.port,
        username: conn.username,
        password: conn.password,
        proxyType: conn.proxyType,
        proxyHost: conn.proxyHost,
        proxyPort: conn.proxyPort,
        proxyUsername: conn.proxyUsername,
        proxyPassword: conn.proxyPassword,
      );
    } else if (conn.type == 'saf') {
      return SafRemoteClient(rootUri: conn.rootPath);
    }
    return null;
  }

  /// 按连接 ID 查找已保存的远程连接
  static NetworkConnectionModel? _findConnection(String id) {
    final connections = NetworkConnectionsService.getConnections();
    try {
      return connections.firstWhere((c) => c.id == id);
    } catch (_) {
      return null;
    }
  }

  /// 列出指定目录下的所有 JSON 备份文件
  static Future<List<BackupFileInfo>> listBackupFiles(String dirPath) async {
    final files = <BackupFileInfo>[];

    if (isRemotePath(dirPath)) {
      final remote = parseRemotePath(dirPath);
      if (remote == null) return files;
      final (connId, remotePath) = remote;
      final conn = _findConnection(connId);
      if (conn == null) return files;

      final client = _createRemoteClient(conn);
      if (client == null) return files;

      try {
        await client.connect();
        final items = await client.listDirectory(remotePath);
        for (final item in items) {
          if (item.isDirectory) continue;
          if (!item.name.toLowerCase().endsWith('.json')) continue;
          files.add(BackupFileInfo(
            name: item.name,
            path: buildRemotePath(connId, item.path),
            size: item.size,
            modified: item.modified,
          ));
        }
      } catch (_) {
        // ignore
      } finally {
        try {
          await client.disconnect();
        } catch (_) {}
      }
    } else {
      final dir = Directory(dirPath);
      if (!await dir.exists()) return files;
      final entities = await dir.list().toList();
      for (final entity in entities) {
        if (entity is! File) continue;
        final name = p.basename(entity.path);
        if (!name.toLowerCase().endsWith('.json')) continue;
        final stat = await entity.stat();
        files.add(BackupFileInfo(
          name: name,
          path: entity.path,
          size: stat.size,
          modified: stat.modified,
        ));
      }
    }

    // 按修改时间从新到旧排序
    files.sort((a, b) => b.modified.compareTo(a.modified));
    return files;
  }

  /// 生成带日期时间的备份文件名
  static String _generateBackupFileName() {
    final now = DateTime.now();
    final ts =
        '${now.year}${now.month.toString().padLeft(2, '0')}${now.day.toString().padLeft(2, '0')}_'
        '${now.hour.toString().padLeft(2, '0')}${now.minute.toString().padLeft(2, '0')}${now.second.toString().padLeft(2, '0')}';
    return '${_backupFileNamePrefix}_$ts.json';
  }

  /// 敏感键黑名单：这些键包含凭据/口令/令牌/门禁哈希，绝不进明文 JSON。
  /// 方案 A（2026-10-03 用户拍板）：它们整体进 `secrets` 加密块，用用户输入
  /// 的备份口令加密后落盘（见 BackupSecretsCodec）；口令留空 = 不备份敏感项。
  static const Set<String> _sensitivePrefKeys = {
    // 保险箱 / 远程守卫门禁凭据（scrypt+salt 哈希，非明文，但同样进加密块）
    'vault_salt',
    'vault_password_hash',
    'vault_password_scheme',
    'vault_v2_pwcheck',
    'remote_guard_salt',
    'remote_guard_hash',
    // FTP 服务器口令
    'ftp_password',
    // Web 分享访问口令
    'web_share_password',
    // Google Drive OAuth 令牌
    'gdrive_access_token',
    'gdrive_refresh_token',
    // VirusTotal API Key
    'virustotal_api_key',
  };

  /// 备份当前所有 SharedPreferences 设置到 JSON 文件。
  ///
  /// [passphrase] 备份口令：非空时把敏感凭据（[_sensitivePrefKeys] + 远程
  /// 连接密码/SSH 口令 + 挂载点密码 + 加密档案）加密进 `secrets` 块；
  /// 留空 = 只备份非敏感设置（文件结构与旧版 v1 扁平格式完全一致）。
  static Future<bool> backupSettings(
    BuildContext context, {
    String? passphrase,
  }) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final allPrefs = prefs.getKeys();
      final Map<String, dynamic> backupData = {};

      // 排除备份路径自身，避免恢复后把旧的备份目录路径也恢复回来；
      // 敏感键统一走 secrets 加密块（有口令）或整体不备份（无口令）
      final keysToBackup = allPrefs
          .where((k) => k != _backupDirPrefKey && !_sensitivePrefKeys.contains(k))
          .toList();

      for (final key in keysToBackup) {
        final value = prefs.get(key);
        backupData[key] = value;
      }

      final String jsonString;
      final hasPassphrase = passphrase != null && passphrase.isNotEmpty;
      if (hasPassphrase) {
        final secretsPayload = await _collectSecretsPayload(prefs);
        final secretsBlock =
            await BackupSecretsCodec.encrypt(secretsPayload, passphrase);
        jsonString = const JsonEncoder.withIndent('  ').convert(<String, dynamic>{
          'schema': _schemaVersion,
          'settings': backupData,
          'secrets': secretsBlock,
        });
      } else {
        // 无口令：保持 v1 扁平结构，旧版应用也能恢复
        jsonString = const JsonEncoder.withIndent('  ').convert(backupData);
      }

      final dirPath = await getBackupDirPath();
      final fileName = _generateBackupFileName();

      if (isRemotePath(dirPath)) {
        final remote = parseRemotePath(dirPath);
        if (remote == null) throw Exception('Invalid remote backup path');
        final (connId, remotePath) = remote;
        final conn = _findConnection(connId);
        if (conn == null) throw Exception('Remote connection not found');

        final client = _createRemoteClient(conn);
        if (client == null) throw Exception('Unsupported remote connection type');

        // 确保远程目录存在
        await client.connect();
        try {
          await client.createDirectory(remotePath);
        } catch (_) {
          // 目录可能已存在，忽略
        }

        final tempDir = await getTemporaryDirectory();
        final tempFile = File(p.join(tempDir.path, fileName));
        await tempFile.writeAsString(jsonString);

        final targetRemotePath = remotePath.endsWith('/') ? '$remotePath$fileName' : '$remotePath/$fileName';
        await client.uploadFile(tempFile.path, targetRemotePath, (_) {});
        await tempFile.delete();
        try {
          await client.disconnect();
        } catch (_) {}
      } else {
        final backupDir = Directory(dirPath);
        if (!await backupDir.exists()) {
          await backupDir.create(recursive: true);
        }
        final backupFile = File(p.join(backupDir.path, fileName));
        await backupFile.writeAsString(jsonString);
      }

      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(L10n.of(context).ui_backup_success)),
        );
      }
      return true;
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(L10n.of(context).ui_backup_failed(e.toString()))),
        );
      }
      return false;
    }
  }

  /// 收集敏感信息负载（会被整体加密后才落盘）。
  ///
  /// 覆盖四类凭据：
  /// 1. prefs 敏感键（门禁哈希 / ftp / web_share / token 等）
  /// 2. 远程连接密码 + SSH 私钥口令（FlutterSecureStorage）
  /// 3. 加密挂载点密码（FlutterSecureStorage，按物理路径对齐）
  /// 4. 加密配置档案 + 路径绑定（CryptProfile 多密码架构）
  static Future<Map<String, dynamic>> _collectSecretsPayload(
    SharedPreferences prefs,
  ) async {
    final prefsSecrets = <String, dynamic>{};
    for (final key in _sensitivePrefKeys) {
      final value = prefs.get(key);
      if (value != null) prefsSecrets[key] = value;
    }

    Map<String, dynamic> connectionCredentials = {};
    try {
      connectionCredentials =
          NetworkConnectionsService.exportAllCredentials().map(
        (id, secrets) => MapEntry(id, <String, dynamic>{...secrets}),
      );
    } catch (_) {}

    Map<String, dynamic> mountPasswords = {};
    try {
      mountPasswords = await CryptMountService.exportPasswords();
    } catch (_) {}

    String? cryptProfiles;
    String? cryptProfileBindings;
    try {
      final profiles = await CryptProfileService.instance.loadProfiles();
      if (profiles.isNotEmpty) {
        cryptProfiles = jsonEncode(profiles.map((pr) => pr.toJson()).toList());
      }
      final bindings = await CryptProfileService.instance.loadBindings();
      if (bindings.isNotEmpty) {
        cryptProfileBindings = jsonEncode(bindings);
      }
    } catch (_) {}

    return <String, dynamic>{
      'prefs': prefsSecrets,
      'connection_credentials': connectionCredentials,
      'mount_passwords': mountPasswords,
      if (cryptProfiles != null) 'crypt_profiles': cryptProfiles,
      if (cryptProfileBindings != null) 'crypt_profile_bindings': cryptProfileBindings,
    };
  }

  /// 把解密后的敏感信息负载写回各存储（prefs / secure storage）。
  /// 每一段独立容错：一段失败不影响其余恢复。
  static Future<void> _applySecrets(Map<String, dynamic> secrets) async {
    final prefs = await SharedPreferences.getInstance();

    final prefsSecrets = secrets['prefs'];
    if (prefsSecrets is Map<String, dynamic>) {
      for (final entry in prefsSecrets.entries) {
        final key = entry.key;
        final value = entry.value;
        try {
          if (value is String) {
            await prefs.setString(key, value);
          } else if (value is int) {
            await prefs.setInt(key, value);
          } else if (value is double) {
            await prefs.setDouble(key, value);
          } else if (value is bool) {
            await prefs.setBool(key, value);
          } else if (value is List) {
            await prefs.setStringList(key, value.cast<String>());
          }
        } catch (_) {}
      }
    }

    final creds = secrets['connection_credentials'];
    if (creds is Map<String, dynamic>) {
      try {
        await NetworkConnectionsService.importAllCredentials(creds);
      } catch (_) {}
    }

    final mounts = secrets['mount_passwords'];
    if (mounts is Map<String, dynamic>) {
      try {
        await CryptMountService.restorePasswords(mounts);
      } catch (_) {}
    }

    final profilesRaw = secrets['crypt_profiles'];
    if (profilesRaw is String && profilesRaw.isNotEmpty) {
      try {
        final list = jsonDecode(profilesRaw);
        if (list is List) {
          final profiles = list
              .whereType<Map<String, dynamic>>()
              .map(CryptProfile.fromJson)
              .toList();
          await CryptProfileService.instance.saveProfiles(profiles);
        }
      } catch (_) {}
    }

    final bindingsRaw = secrets['crypt_profile_bindings'];
    if (bindingsRaw is String && bindingsRaw.isNotEmpty) {
      try {
        final decoded = jsonDecode(bindingsRaw);
        if (decoded is Map) {
          await CryptProfileService.instance.saveBindings(
            decoded.map((k, v) => MapEntry(k.toString(), v.toString())),
          );
        }
      } catch (_) {}
    }
  }

  /// 从 JSON 备份文件恢复设置到 SharedPreferences。
  ///
  /// [askPassphrase]：备份带 `secrets` 加密块时由本服务回调 UI 取口令；
  /// 返回 null/空串 = 用户取消 ⇒ 整次恢复作废（不写入任何设置，issue #79）；
  /// [wrongPassphrase] = 上一次口令错误，UI 应提示重输。
  /// 口令验证在任何写盘之前完成，加密备份必须输对口令才能恢复。
  /// v1 旧版扁平备份（无 secrets 块）不受影响。
  static Future<SettingsRestoreResult> restoreSettings(
    BuildContext context,
    String filePath, {
    Future<String?> Function(bool wrongPassphrase)? askPassphrase,
  }) async {
    try {
      if (!filePath.toLowerCase().endsWith('.json')) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(L10n.of(context).ui_restore_invalid_file)),
          );
        }
        return const SettingsRestoreResult(success: false);
      }

      String jsonString;
      if (isRemotePath(filePath)) {
        final remote = parseRemotePath(filePath);
        if (remote == null) throw Exception('Invalid remote backup path');
        final (connId, remotePath) = remote;
        final conn = _findConnection(connId);
        if (conn == null) throw Exception('Remote connection not found');

        final client = _createRemoteClient(conn);
        if (client == null) throw Exception('Unsupported remote connection type');

        await client.connect();
        final tempDir = await getTemporaryDirectory();
        final tempFile = File(p.join(tempDir.path, p.basename(remotePath)));
        await client.downloadFile(remotePath, tempFile.path, (_) {});
        jsonString = await tempFile.readAsString();
        await tempFile.delete();
        try {
          await client.disconnect();
        } catch (_) {}
      } else {
        final file = File(filePath);
        if (!await file.exists()) {
          if (context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text(L10n.of(context).ui_restore_invalid_file)),
            );
          }
          return const SettingsRestoreResult(success: false);
        }
        jsonString = await file.readAsString();
      }

      final decoded = jsonDecode(jsonString);
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('Invalid backup file');
      }

      // v2：{schema, settings, secrets?}；v1（旧版/无口令）：扁平 prefs 表
      Map<String, dynamic> backupData;
      Map<String, dynamic>? secretsBlock;
      if (decoded['schema'] == _schemaVersion &&
          decoded['settings'] is Map<String, dynamic>) {
        backupData = decoded['settings'] as Map<String, dynamic>;
        final rawSecrets = decoded['secrets'];
        if (rawSecrets is Map<String, dynamic>) secretsBlock = rawSecrets;
      } else {
        backupData = decoded;
      }

      final prefs = await SharedPreferences.getInstance();

      // ── issue #79：加密备份必须先解开敏感块，才允许改动本机设置 ──
      // 旧实现先 prefs.clear() 再要口令，用户跳过/取消时虽然敏感数据全丢，
      // 却仍返回 success=true 并重启——正是 issue #79 反馈的「不输密码也
      // 恢复了」。按维护者在 #79 的回复：加密备份文件必须输入正确口令
      // 才能恢复。因此这里把口令验证与解密**前置到写入之前**：
      //   · 口令取消/留空 ⇒ 整次恢复作废，prefs 一步未动；
      //   · 口令错误 ⇒ 重试；敏感块损坏 ⇒ 整体失败且不改动设置。
      Map<String, dynamic>? decryptedSecrets;
      if (secretsBlock != null) {
        if (askPassphrase == null) {
          if (context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                  content: Text(L10n.of(context).ui_restore_passphrase_required)),
            );
          }
          return SettingsRestoreResult(success: false, hasSecrets: true);
        }
        var wrong = false;
        while (true) {
          final pass = await askPassphrase(wrong);
          if (pass == null || pass.isEmpty) {
            // 用户取消：整次恢复作废，上面的 prefs 一步未动
            if (context.mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                    content:
                        Text(L10n.of(context).ui_restore_passphrase_required)),
              );
            }
            return SettingsRestoreResult(success: false, hasSecrets: true);
          }
          try {
            decryptedSecrets =
                await BackupSecretsCodec.decrypt(secretsBlock, pass);
            break;
          } on BackupPassphraseException {
            wrong = true;
          } on FormatException {
            // 敏感块损坏：不重试，整体失败且不改动任何设置
            if (context.mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(L10n.of(context)
                      .ui_restore_failed(L10n.of(context).ui_restore_invalid_file)),
                ),
              );
            }
            return SettingsRestoreResult(success: false, hasSecrets: true);
          }
        }
      }

      // 到这里口令已验证通过（或备份本身不含敏感块），才开始写入
      await prefs.clear();

      // 逐项恢复
      for (final entry in backupData.entries) {
        final key = entry.key;
        final value = entry.value;

        if (value is String) {
          await prefs.setString(key, value);
        } else if (value is int) {
          await prefs.setInt(key, value);
        } else if (value is double) {
          await prefs.setDouble(key, value);
        } else if (value is bool) {
          await prefs.setBool(key, value);
        } else if (value is List) {
          await prefs.setStringList(key, value.cast<String>());
        }
      }

      // 恢复加密挂载点的密码到 FlutterSecureStorage（旧版 v1 备份兼容）
      try {
        final cryptPasswords = backupData['_crypt_mount_passwords'];
        if (cryptPasswords is Map<String, dynamic>) {
          // 重新保存挂载点配置（会触发密码写入 FlutterSecureStorage）
          final mounts = await CryptMountService.loadMountPoints();
          for (final m in mounts) {
            final savedPw = cryptPasswords[m.physicalPath];
            if (savedPw is String && savedPw.isNotEmpty) {
              final updated = m.copyWith(password: savedPw);
              await CryptMountService.addMountPoint(updated);
            }
          }
        }
      } catch (_) {}

      // 应用已验证解密的敏感块（含远程连接密码、保险箱配置等）
      if (decryptedSecrets != null) {
        await _applySecrets(decryptedSecrets);
      }

      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(L10n.of(context).ui_restore_success)),
        );
      }
      return SettingsRestoreResult(
        success: true,
        hasSecrets: secretsBlock != null,
        secretsRestored: decryptedSecrets != null,
      );
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(L10n.of(context).ui_restore_failed(e.toString()))),
        );
      }
      return const SettingsRestoreResult(success: false);
    }
  }
}
