import 'dart:convert';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter/material.dart';

class SettingsBackupService {
  static const String _backupDirPath =
      '/storage/emulated/0/ZenFile/Backups/Settings';
  static const String _backupFileName = 'zenfile_settings_backup.json';

  /// 备份当前所有 SharedPreferences 设置到 JSON 文件
  static Future<bool> backupSettings(BuildContext context) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final allPrefs = prefs.getKeys();
      final Map<String, dynamic> backupData = {};

      for (final key in allPrefs) {
        final value = prefs.get(key);
        backupData[key] = value;
      }

      final backupDir = Directory(_backupDirPath);
      if (!await backupDir.exists()) {
        await backupDir.create(recursive: true);
      }

      final backupFile = File('${backupDir.path}/$_backupFileName');
      final jsonString = const JsonEncoder.withIndent('  ').convert(backupData);
      await backupFile.writeAsString(jsonString);

      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('设置已备份到 ZenFile/Backups/Settings/')),
        );
      }
      return true;
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('设置备份失败: $e')),
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
            const SnackBar(content: Text('请选择有效的 .json 设置备份文件')),
          );
        }
        return false;
      }

      final file = File(filePath);
      if (!await file.exists()) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('请选择有效的 .json 设置备份文件')),
          );
        }
        return false;
      }

      final jsonString = await file.readAsString();
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
          const SnackBar(content: Text('设置恢复成功！')),
        );
      }
      return true;
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('设置恢复失败: $e')),
        );
      }
      return false;
    }
  }

  /// 获取备份目录路径
  static String get backupDirPath => _backupDirPath;

  /// 获取备份文件完整路径
  static String get backupFilePath => '$_backupDirPath/$_backupFileName';
}
