import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:archive/archive_io.dart';
import 'package:path/path.dart' as p;
import 'package:share_plus/share_plus.dart';
import '../models/app_info_model.dart';

class AppManagerService {
  static const MethodChannel _channel = MethodChannel('com.sequl.zenfile/root_shizuku');

  static Future<List<AppInfoModel>> getInstalledApps({bool includeSystem = false}) async {
    try {
      final List<dynamic>? apps = await _channel.invokeMethod<List<dynamic>>(
        'getInstalledApps',
        {'includeSystem': includeSystem},
      );
      if (apps == null) return [];
      return apps.map((map) => AppInfoModel.fromMap(Map<dynamic, dynamic>.from(map))).toList();
    } catch (e) {
      return [];
    }
  }

  static Future<Uint8List?> getAppIcon(String packageName) async {
    try {
      final Uint8List? iconBytes = await _channel.invokeMethod<Uint8List>(
        'getAppIcon',
        {'packageName': packageName},
      );
      return iconBytes;
    } catch (e) {
      return null;
    }
  }

  static Future<Uint8List?> getApkIcon(String apkPath) async {
    try {
      final Uint8List? iconBytes = await _channel.invokeMethod<Uint8List>(
        'getApkIcon',
        {'apkPath': apkPath},
      );
      return iconBytes;
    } catch (e) {
      return null;
    }
  }

  static Future<bool> launchApp(String packageName) async {
    try {
      final bool? success = await _channel.invokeMethod<bool>(
        'launchApp',
        {'packageName': packageName},
      );
      return success ?? false;
    } catch (e) {
      return false;
    }
  }

  static Future<bool> openAppDetails(String packageName) async {
    try {
      final bool? success = await _channel.invokeMethod<bool>(
        'openAppDetails',
        {'packageName': packageName},
      );
      return success ?? false;
    } catch (e) {
      return false;
    }
  }

  static Future<bool> uninstallApp(String packageName) async {
    try {
      final bool? success = await _channel.invokeMethod<bool>(
        'uninstallApp',
        {'packageName': packageName},
      );
      return success ?? false;
    } catch (e) {
      return false;
    }
  }

  static Future<bool> checkUsageStatsPermission() async {
    try {
      final bool? success = await _channel.invokeMethod<bool>('checkUsageStatsPermission');
      return success ?? false;
    } catch (e) {
      return false;
    }
  }

  static Future<bool> requestUsageStatsPermission() async {
    try {
      final bool? success = await _channel.invokeMethod<bool>('requestUsageStatsPermission');
      return success ?? false;
    } catch (e) {
      return false;
    }
  }

  static Future<bool> changeAppIcon(String aliasName) async {
    try {
      final bool? success = await _channel.invokeMethod<bool>(
        'changeAppIcon',
        {'alias': aliasName},
      );
      return success ?? false;
    } catch (e) {
      return false;
    }
  }

  static Future<bool> addHomeScreenShortcut({String? path}) async {
    try {
      final bool? success = await _channel.invokeMethod<bool>(
        'addHomeScreenShortcut',
        {'path': path},
      );
      return success ?? false;
    } catch (e) {
      return false;
    }
  }

  // --- New APK Backup, Share, Restore, and Batch Features ---

  /// 备份 APK，返回备份文件路径（成功）或 null（失败）。
  /// 使用 Android 原生方法在后台线程执行，避免阻塞 UI 线程和内存问题。
  static Future<String?> backupApp(AppInfoModel app) async {
    try {
      final backupDir = Directory('/storage/emulated/0/ZenFile/Backups/Apps');
      if (!backupDir.existsSync()) {
        backupDir.createSync(recursive: true);
      }

      final cleanName = app.name.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
      final version = app.version.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');

      if (app.splitSourceDirs.isEmpty) {
        // 单 APK：使用原生方法复制文件（10分钟超时）
        final destPath = p.join(backupDir.path, '${cleanName}_v$version.apk');
        try {
          final result = await _channel
              .invokeMethod<bool>('copyFile', {
                'source': app.sourceDir,
                'dest': destPath,
              })
              .timeout(const Duration(minutes: 10));
          if (result == true && await File(destPath).exists()) {
            return destPath;
          }
        } catch (e) {
          debugPrint('Native copyFile failed: $e');
          // 降级到 Dart 流式复制
          try {
            final source = File(app.sourceDir);
            final dest = File(destPath);
            await source.openRead().pipe(dest.openWrite());
            if (await dest.exists()) {
              return destPath;
            }
          } catch (e2) {
            debugPrint('Dart fallback copy failed: $e2');
          }
        }
        return null;
      } else {
        // Split APK：使用原生方法创建 ZIP（10分钟超时）
        final destPath = p.join(backupDir.path, '${cleanName}_v$version.apks');
        try {
          final result = await _channel
              .invokeMethod<bool>('createZip', {
                'basePath': app.sourceDir,
                'splitPaths': app.splitSourceDirs,
                'destPath': destPath,
              })
              .timeout(const Duration(minutes: 10));
          if (result == true && await File(destPath).exists()) {
            return destPath;
          }
        } catch (e) {
          debugPrint('Native createZip failed: $e');
          // 降级到 Dart 创建 ZIP
          try {
            final encoder = ZipFileEncoder();
            encoder.create(destPath);
            final baseFile = File(app.sourceDir);
            if (baseFile.existsSync()) {
              encoder.addFile(baseFile, 'base.apk');
            }
            for (final splitPath in app.splitSourceDirs) {
              final splitFile = File(splitPath);
              if (splitFile.existsSync()) {
                encoder.addFile(splitFile, p.basename(splitPath));
              }
            }
            encoder.close();
            if (await File(destPath).exists()) {
              return destPath;
            }
          } catch (e2) {
            debugPrint('Dart fallback zip failed: $e2');
          }
        }
        return null;
      }
    } catch (e) {
      debugPrint('Error backing up app: $e');
      return null;
    }
  }

  /// 通过系统文件管理器打开指定目录
  static Future<bool> openDirectory(String path) async {
    try {
      await _channel.invokeMethod('openDirectory', {'path': path});
      return true;
    } catch (e) {
      debugPrint('Error opening directory: $e');
      return false;
    }
  }

  static Future<void> batchBackupApps(
    List<AppInfoModel> apps,
    void Function(int current, int total) onProgress,
  ) async {
    int current = 0;
    final total = apps.length;
    for (final app in apps) {
      await backupApp(app);
      current++;
      onProgress(current, total);
    }
  }

  static Future<void> shareAppApk(AppInfoModel app) async {
    try {
      final List<XFile> filesToShare = [];

      final baseFile = File(app.sourceDir);
      if (baseFile.existsSync()) {
        filesToShare.add(XFile(baseFile.path, name: '${app.name}.apk'));
      }

      for (final splitPath in app.splitSourceDirs) {
        final splitFile = File(splitPath);
        if (splitFile.existsSync()) {
          filesToShare.add(XFile(splitFile.path, name: p.basename(splitPath)));
        }
      }

      if (filesToShare.isNotEmpty) {
        await Share.shareXFiles(filesToShare, text: 'Sharing APK for ${app.name}');
      }
    } catch (e) {
      debugPrint('Error sharing app: $e');
    }
  }

  static Future<void> batchShareAppApks(List<AppInfoModel> apps) async {
    try {
      final List<XFile> filesToShare = [];
      for (final app in apps) {
        final baseFile = File(app.sourceDir);
        if (baseFile.existsSync()) {
          filesToShare.add(XFile(baseFile.path, name: '${app.name}.apk'));
        }

        for (final splitPath in app.splitSourceDirs) {
          final splitFile = File(splitPath);
          if (splitFile.existsSync()) {
            filesToShare.add(XFile(splitFile.path, name: '${app.name}_${p.basename(splitPath)}'));
          }
        }
      }

      if (filesToShare.isNotEmpty) {
        await Share.shareXFiles(filesToShare, text: 'Sharing APKs of selected apps');
      }
    } catch (e) {
      debugPrint('Error batch sharing apps: $e');
    }
  }

  static Future<List<Map<String, dynamic>>> listBackups() async {
    final List<Map<String, dynamic>> backups = [];
    try {
      final backupDir = Directory('/storage/emulated/0/ZenFile/Backups/Apps');
      if (!backupDir.existsSync()) return [];

      final List<FileSystemEntity> entities = backupDir.listSync();
      for (final entity in entities) {
        if (entity is File) {
          final name = p.basename(entity.path);
          final ext = p.extension(entity.path).toLowerCase();
          if (ext == '.apk' || ext == '.apks') {
            final stat = entity.statSync();

            // Try to parse app name and version from filename (e.g. WhatsApp_v2.23.apk)
            String appName = p.basenameWithoutExtension(entity.path);
            String version = 'unknown';

            final vIndex = appName.lastIndexOf('_v');
            if (vIndex != -1) {
              version = appName.substring(vIndex + 2);
              appName = appName.substring(0, vIndex);
            }

            backups.add({
              'name': appName.replaceAll('_', ' '),
              'packageName': name, // Store original filename as unique package identifier
              'version': version,
              'apkSize': stat.size,
              'installTime': stat.modified,
              'path': entity.path,
              'isApks': ext == '.apks',
            });
          }
        }
      }
    } catch (e) {
      debugPrint('Error listing backups: $e');
    }
    // Sort by modification date (newest first)
    backups.sort((a, b) => (b['installTime'] as DateTime).compareTo(a['installTime'] as DateTime));
    return backups;
  }

  static Future<bool> deleteBackup(String path) async {
    try {
      final file = File(path);
      if (file.existsSync()) {
        file.deleteSync();
        return true;
      }
      return false;
    } catch (e) {
      debugPrint('Error deleting backup: $e');
      return false;
    }
  }

  static Future<bool> installSplitApks(List<String> apkPaths) async {
    try {
      final bool? success = await _channel.invokeMethod<bool>(
        'installSplitApks',
        {'apkPaths': apkPaths},
      );
      return success ?? false;
    } catch (e) {
      debugPrint('Error installing split APKs: $e');
      return false;
    }
  }
}

/// 在 isolate 中复制文件（顶层函数，供 compute 调用）
/// 使用流式复制，避免一次性读取大文件到内存
Future<void> _copyFileIsolate(Map<String, String> args) async {
  final source = File(args['source']!);
  final dest = File(args['dest']!);
  const bufferSize = 64 * 1024; // 64KB
  await source.openRead().pipe(dest.openWrite());
}

/// 在 isolate 中创建 ZIP 文件（顶层函数，供 compute 调用）
Future<void> _createZipIsolate(Map<String, dynamic> args) async {
  final basePath = args['basePath'] as String;
  final splitPaths = (args['splitPaths'] as List).cast<String>();
  final destPath = args['destPath'] as String;

  final encoder = ZipFileEncoder();
  encoder.create(destPath);

  final baseFile = File(basePath);
  if (baseFile.existsSync()) {
    encoder.addFile(baseFile, 'base.apk');
  }

  for (final splitPath in splitPaths) {
    final splitFile = File(splitPath);
    if (splitFile.existsSync()) {
      encoder.addFile(splitFile, p.basename(splitPath));
    }
  }
  encoder.close();
}
