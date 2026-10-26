import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import 'apk_clone/apk_clone_engine.dart';

/// 克隆失败类型：UI 层据此映射为可读的错误提示文案。
enum AppCloneError {
  /// 源 APK 读取失败或无法解析（文件损坏 / 非 APK）。
  readFailed,

  /// 写盘失败（磁盘满 / 无权限等）。
  ioFailed,
}

/// 克隆操作异常：统一携带错误码与原始信息。
class AppCloneException implements Exception {
  final AppCloneError code;
  final String raw;
  const AppCloneException(this.code, [this.raw = '']);

  @override
  String toString() => 'AppCloneException($code, $raw)';
}

/// 克隆结果：原包名 + 生成的克隆安装包路径列表。
class AppCloneOutput {
  final String originalPackage;
  final List<String> paths;
  const AppCloneOutput({required this.originalPackage, required this.paths});
}

/// 单份克隆任务（跨 isolate 传给引擎；字段均为可传输的基础类型）。
class _CloneTask {
  final Uint8List source;
  final String newPackage;
  final String originalPackage;
  const _CloneTask(this.source, this.newPackage, this.originalPackage);
}

/// compute 入口：克隆引擎为纯 Dart 实现（无平台通道），可安全跑在后台 isolate。
Uint8List _cloneInIsolate(_CloneTask task) {
  return ApkCloneEngine.cloneToBytes(
    sourceApk: task.source,
    newPackage: task.newPackage,
    originalPackage: task.originalPackage,
  );
}

/// 应用克隆服务：把一个 APK 重打包为**不同包名**的克隆安装包（改包名 +
/// 内置固定密钥独立签名），克隆包与原应用可共存安装、多开同时运行。
/// 不直接安装 —— 生成新 APK 落盘到 [cloneDirPath]，由用户自行安装。
///
/// 每份克隆包：包名 = 原包名 + `.zcloneN`（N 从 1 起），
/// 输出文件名 `<原名>_zclone<N>.apk`，同名直接覆盖。
class AppCloneService {
  AppCloneService._();

  /// 克隆安装包输出目录（与备份 APK 同目录，备份功能不受影响）。
  static const cloneDirPath = '/storage/emulated/0/ZenFile/Backups/Apps';

  /// 克隆产物文件名模式（管理页据此筛选列表，与普通备份 `<名>_v<版本>.apk` 区分）。
  static const cloneFileNamePattern = r'_zclone\d+\.apk$';

  /// 把 [sourceApkPath] 克隆出 [copies] 份不同包名的安装包。
  ///
  /// [displayName] 用于输出文件命名（默认取源文件名，不含扩展名）。
  /// [onProgress] 每完成一份回调一次（done 从 1 起）。
  static Future<AppCloneOutput> cloneApk({
    required String sourceApkPath,
    required int copies,
    String? displayName,
    void Function(int done, int total)? onProgress,
  }) async {
    final source = File(sourceApkPath);
    final Uint8List bytes;
    try {
      bytes = await source.readAsBytes();
    } catch (_) {
      throw const AppCloneException(
        AppCloneError.readFailed,
        'cannot read source apk',
      );
    }
    final origPkg = ApkCloneEngine.parsePackageName(bytes);
    if (origPkg == null || origPkg.isEmpty) {
      throw const AppCloneException(
        AppCloneError.readFailed,
        'cannot parse package name',
      );
    }

    final dir = Directory(cloneDirPath);
    try {
      if (!dir.existsSync()) dir.createSync(recursive: true);
    } catch (e) {
      throw AppCloneException(AppCloneError.ioFailed, e.toString());
    }
    final baseName = (displayName ?? p.basenameWithoutExtension(sourceApkPath))
        .replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');

    final outputs = <String>[];
    for (var i = 1; i <= copies; i++) {
      // 克隆是 CPU 密集型（AXML/ARSC 改写 + ZIP 重排 + v2 签名），丢后台 isolate。
      final cloned = await compute(
        _cloneInIsolate,
        _CloneTask(bytes, '$origPkg.zclone$i', origPkg),
      );
      final destPath = p.join(dir.path, '${baseName}_zclone$i.apk');
      try {
        await File(destPath).writeAsBytes(cloned, flush: true);
      } catch (e) {
        throw AppCloneException(AppCloneError.ioFailed, e.toString());
      }
      outputs.add(destPath);
      onProgress?.call(i, copies);
    }
    return AppCloneOutput(originalPackage: origPkg, paths: outputs);
  }

  /// 命中加固 / 加壳特征：克隆仅改写 manifest + arsc，无法覆盖受保护代码里
  /// 写死的包名 / provider authority，克隆后可共存安装但运行期很可能崩溃。
  /// 返回命中标签；空列表表示未识别到加固。读取失败返回空列表（不阻断）。
  static Future<List<String>> detectHardening(String sourceApkPath) async {
    try {
      final bytes = await File(sourceApkPath).readAsBytes();
      return ApkCloneEngine.detectHardening(bytes);
    } catch (_) {
      return const [];
    }
  }

  /// 列出已生成的克隆安装包（文件名匹配克隆产物模式），按修改时间倒序。
  static Future<List<File>> listCloneFiles() async {
    final dir = Directory(cloneDirPath);
    if (!dir.existsSync()) return const [];
    final re = RegExp(cloneFileNamePattern);
    final files = <File>[];
    await for (final e in dir.list()) {
      if (e is! File) continue;
      if (!re.hasMatch(p.basename(e.path))) continue;
      files.add(e);
    }
    files.sort((a, b) {
      try {
        return b.lastModifiedSync().compareTo(a.lastModifiedSync());
      } catch (_) {
        return b.path.compareTo(a.path);
      }
    });
    return files;
  }
}
