import 'dart:io';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

/// APK 清单信息（从 AndroidManifest.xml 解析）。
class ApkManifestInfo {
  final String packageName;
  final int minSdkVersion;
  final int targetSdkVersion;
  final int versionCode;
  final String versionName;
  final List<String> permissions;
  final List<String> activities;
  final bool isSplitApk;

  const ApkManifestInfo({
    required this.packageName,
    required this.minSdkVersion,
    required this.targetSdkVersion,
    required this.versionCode,
    required this.versionName,
    this.permissions = const [],
    this.activities = const [],
    this.isSplitApk = false,
  });

  /// 是否有有效数据
  bool get isValid => packageName.isNotEmpty;
}

/// APK 编辑参数。
class ApkEditParams {
  final int? minSdkVersion;
  final int? targetSdkVersion;
  final int? versionCode;
  final String? versionName;

  const ApkEditParams({
    this.minSdkVersion,
    this.targetSdkVersion,
    this.versionCode,
    this.versionName,
  });

  bool get hasChanges =>
      minSdkVersion != null || targetSdkVersion != null || versionCode != null || versionName != null;
}

/// APK 编辑服务：读取/修改 APK 的 AndroidManifest.xml。
/// 使用原生 aapt/apkanalyzer 工具解析，纯 Dart 无法直接修改二进制 XML。
class ApkEditorService {
  static const MethodChannel _channel = MethodChannel('com.sequl.zenfile/apk_editor');

  /// 读取 APK 清单信息。
  static Future<ApkManifestInfo> readManifest(String apkPath) async {
    try {
      final result = await _channel.invokeMethod<Map<dynamic, dynamic>>('readManifest', {
        'apkPath': apkPath,
      });
      if (result == null) {
        return const ApkManifestInfo(
          packageName: '',
          minSdkVersion: 0,
          targetSdkVersion: 0,
          versionCode: 0,
          versionName: '',
        );
      }
      return ApkManifestInfo(
        packageName: result['packageName']?.toString() ?? '',
        minSdkVersion: (result['minSdkVersion'] as num?)?.toInt() ?? 0,
        targetSdkVersion: (result['targetSdkVersion'] as num?)?.toInt() ?? 0,
        versionCode: (result['versionCode'] as num?)?.toInt() ?? 0,
        versionName: result['versionName']?.toString() ?? '',
        permissions: (result['permissions'] as List?)?.map((e) => e.toString()).toList() ?? [],
        activities: (result['activities'] as List?)?.map((e) => e.toString()).toList() ?? [],
        isSplitApk: result['isSplitApk'] as bool? ?? false,
      );
    } catch (e) {
      return const ApkManifestInfo(
        packageName: '',
        minSdkVersion: 0,
        targetSdkVersion: 0,
        versionCode: 0,
        versionName: '',
      );
    }
  }

  /// 修改 APK 清单并重新打包。
  /// [sourceApk] 源 APK 路径，[params] 修改参数，[outputPath] 输出路径。
  /// 返回输出 APK 路径，失败返回 null。
  static Future<String?> editApk({
    required String sourceApk,
    required ApkEditParams params,
    String? outputPath,
  }) async {
    try {
      final out = outputPath ??
          p.join(
            File(sourceApk).parent.path,
            '${p.basenameWithoutExtension(sourceApk)}_edited.apk',
      );
      final result = await _channel.invokeMethod<String>('editApk', {
        'sourceApk': sourceApk,
        'outputPath': out,
        'minSdkVersion': params.minSdkVersion,
        'targetSdkVersion': params.targetSdkVersion,
        'versionCode': params.versionCode,
        'versionName': params.versionName,
      });
      return result;
    } catch (e) {
      return null;
    }
  }

  /// 检查是否支持 APK 编辑（需要 aapt 工具）。
  static Future<bool> isSupported() async {
    try {
      final result = await _channel.invokeMethod<bool>('isApkEditorSupported');
      return result ?? false;
    } catch (_) {
      return false;
    }
  }
}
