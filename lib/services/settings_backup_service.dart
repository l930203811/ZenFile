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

class SettingsBackupService {
  static const String defaultBackupDirPath =
      '/storage/emulated/0/ZenFile/Backups/Settings';
  static const String _backupFileNamePrefix = 'zenfile_settings_backup';
  static const String _backupDirPrefKey = 'settings_backup_dir_path';

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
      );
    } else if (conn.type == 'WebDav') {
      return WebDavRemoteClient(
        host: conn.host,
        port: conn.port,
        username: conn.username,
        password: conn.password,
        protocol: conn.protocol,
        rootPath: conn.rootPath,
      );
    } else if (['SMB', 'Samba', 'CIFS'].contains(conn.type)) {
      return LanClient(
        host: conn.host,
        port: conn.port,
        username: conn.username,
        password: conn.password,
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

  /// 备份当前所有 SharedPreferences 设置到 JSON 文件
  static Future<bool> backupSettings(BuildContext context) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final allPrefs = prefs.getKeys();
      final Map<String, dynamic> backupData = {};

      // 排除备份路径自身，避免恢复后把旧的备份目录路径也恢复回来
      final keysToBackup = allPrefs.where((k) => k != _backupDirPrefKey).toList();

      for (final key in keysToBackup) {
        final value = prefs.get(key);
        backupData[key] = value;
      }

      final jsonString = const JsonEncoder.withIndent('  ').convert(backupData);
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

  /// 从 JSON 备份文件恢复设置到 SharedPreferences
  static Future<bool> restoreSettings(BuildContext context, String filePath) async {
    try {
      if (!filePath.toLowerCase().endsWith('.json')) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(L10n.of(context).ui_restore_invalid_file)),
          );
        }
        return false;
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
          return false;
        }
        jsonString = await file.readAsString();
      }

      final backupData = jsonDecode(jsonString) as Map<String, dynamic>;

      final prefs = await SharedPreferences.getInstance();

      // 先清除现有设置
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

      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(L10n.of(context).ui_restore_success)),
        );
      }
      return true;
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(L10n.of(context).ui_restore_failed(e.toString()))),
        );
      }
      return false;
    }
  }
}
