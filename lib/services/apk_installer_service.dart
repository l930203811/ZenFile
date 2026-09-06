
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:open_filex/open_filex.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:zenfile/l10n/generated/app_localizations.dart';
import 'archive_service.dart';
import 'app_manager_service.dart';
import 'preferences_service.dart';
import 'root_shizuku_service.dart';
import 'virus_total_service.dart';

class ApkInstallerService {
  static const List<String> apkExtensions = ['.apk', '.xapk', '.apks', '.apkm', '.aab'];

  static bool isApk(String path) {
    final ext = p.extension(path).toLowerCase();
    return apkExtensions.contains(ext);
  }

  static Future<void> installApk(BuildContext context, String path) async {
    final ext = p.extension(path).toLowerCase();
    final hasKey = (VirusTotalService.getApiKey() ?? '').isNotEmpty;

    if (ext == '.apk') {
      if (hasKey) {
        await _scanThenInstallApk(context, path);
      } else {
        await _openInstaller(context, path);
      }
      return;
    }

    // Bundle: .xapk .apks .apkm .aab —— 先扫描压缩包本身，再解压安装
    if (hasKey) {
      await _scanThenInstallApk(context, path);
    } else {
      await _installBundle(context, path);
    }
  }

  /// 打开安装器。单 APK 支持静默安装（root/shizuku），bundle 自动解压安装。
  static Future<void> _openInstaller(BuildContext context, String path) async {
    final ext = p.extension(path).toLowerCase();
    if (ext != '.apk') {
      await _installBundle(context, path);
      return;
    }

    // 开启"保留安装包"时，先复制到临时目录再安装，防止系统安装器删除源文件
    final installPath = await _prepareInstallPath(path);

    if (PreferencesService.getSilentInstall()) {
      final status = await RootShizukuService.checkStatus();
      bool ok = false;
      if (status.isRootAvailable) {
        ok = await RootShizukuService.installApkSilently(installPath, useRoot: true);
      } else if (status.isShizukuAvailable && status.shizukuPermissionGranted) {
        ok = await RootShizukuService.installApkSilently(installPath, useRoot: false);
      }
      if (ok) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(L10n.of(context).vt_install_success)),
          );
        }
        return;
      }
      // 静默安装失败，回退系统安装器
    }

    // 用原生 installApk（ACTION_VIEW + FileProvider + 优先指定系统包安装器），
    // 既不弹"打开方式"选择器，又比 PackageInstaller API 更通用可靠。
    final success = await AppManagerService.installApk(installPath);
    if (!success && context.mounted) {
      // 最后兜底：OpenFilex
      await OpenFilex.open(installPath);
    }
  }

  /// 开启"安装后保留安装包"时，把 APK 复制到应用临时目录再安装，防止系统安装器删除源文件。
  static Future<String> _prepareInstallPath(String path) async {
    if (!PreferencesService.getKeepApkAfterInstall()) return path;
    try {
      final tempDir = await getTemporaryDirectory();
      final installDir = Directory(p.join(tempDir.path, 'apk_install'));
      if (!await installDir.exists()) await installDir.create(recursive: true);
      final dest = p.join(installDir.path, p.basename(path));
      await File(path).copy(dest);
      return dest;
    } catch (_) {
      return path;
    }
  }

  /// 解压并安装 bundle（.xapk/.apks/.apkm/.aab）。
  static Future<void> _installBundle(BuildContext context, String path) async {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const AlertDialog(
        content: Row(
          children: [
            CircularProgressIndicator(),
            SizedBox(width: 20),
            Expanded(child: Text('正在解压安装包...')),
          ],
        ),
      ),
    );

    try {
      final tempDir = await getTemporaryDirectory();
      final bundleDirName = p.basenameWithoutExtension(path).replaceAll(RegExp(r'[^a-zA-Z0-9]'), '_');
      final extractDir = Directory(p.join(tempDir.path, 'apk_bundles', bundleDirName));

      if (await extractDir.exists()) {
        await extractDir.delete(recursive: true);
      }
      await extractDir.create(recursive: true);

      await ArchiveService.extractArchive(
        archivePath: path,
        destinationDir: extractDir.path,
      );

      if (!context.mounted) return;

      List<File> allApks = [];

      await for (final entity in extractDir.list(recursive: true)) {
        if (entity is File && p.extension(entity.path).toLowerCase() == '.apk') {
          allApks.add(entity);
        } else if (entity is File && p.extension(entity.path).toLowerCase() == '.obb') {
          try {
            final obbFileName = p.basename(entity.path);
            final parentDir = p.basename(p.dirname(entity.path));
            final targetObbDir = Directory('/storage/emulated/0/Android/obb/$parentDir');
            if (!await targetObbDir.exists()) {
              await targetObbDir.create(recursive: true);
            }
            await entity.copy('${targetObbDir.path}/$obbFileName');
          } catch (_) {}
        }
      }

      if (allApks.isEmpty) {
        if (!context.mounted) return;
        Navigator.pop(context);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('安装包中未找到可安装的APK')),
        );
        return;
      }

      if (!context.mounted) return;
      Navigator.pop(context);

      if (allApks.length == 1) {
        await _openInstaller(context, allApks.first.path);
      } else {
        // 开启"保留安装包"时，每个内部 APK 先复制到临时目录
        final apkPaths = <String>[];
        for (final f in allApks) {
          apkPaths.add(await _prepareInstallPath(f.path));
        }
        // 优先静默分包安装
        if (PreferencesService.getSilentInstall()) {
          final status = await RootShizukuService.checkStatus();
          bool ok = false;
          if (status.isRootAvailable) {
            ok = await RootShizukuService.installSplitApksSilently(apkPaths, useRoot: true);
          } else if (status.isShizukuAvailable && status.shizukuPermissionGranted) {
            ok = await RootShizukuService.installSplitApksSilently(apkPaths, useRoot: false);
          }
          if (ok) {
            if (context.mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text(L10n.of(context).vt_install_success)),
              );
            }
            return;
          }
        }
        // 回退系统分包安装器（PackageInstaller API）
        final success = await AppManagerService.installSplitApks(apkPaths);
        if (!success && context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('无法启动分包APK安装器')),
          );
        }
      }
    } catch (e) {
      if (!context.mounted) return;
      Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('解压安装包失败：$e')),
      );
    }
  }

  // ------------------------------------------------------------
  // VirusTotal 安装前扫描
  // ------------------------------------------------------------

  /// 扫描 APK 后按结果决定是否继续安装。
  static Future<void> _scanThenInstallApk(BuildContext context, String path) async {
    if (!context.mounted) return;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => AlertDialog(
        content: Row(
          children: [
            const CircularProgressIndicator(),
            const SizedBox(width: 20),
            Expanded(child: Text(L10n.of(context).vt_scan_before_install)),
          ],
        ),
      ),
    );

    final result = await VirusTotalService.scanFile(path);
    if (!context.mounted) return;
    Navigator.pop(context); // 关闭扫描中提示

    if (result.error != null && !result.found) {
      await _showScanErrorDialog(context, path, result.error!);
      return;
    }
    if (!result.found) {
      await _showUnknownDialog(context, path, result);
      return;
    }
    if (result.isSafe) {
      await _showSafeDialog(context, path, result);
    } else {
      await _showRiskDialog(context, path, result);
    }
  }

  /// 弹出结果对话框：绿色安全。
  static Future<void> _showSafeDialog(
    BuildContext context,
    String path,
    VirusTotalResult result,
  ) async {
    if (!context.mounted) return;
    final l10n = L10n.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: const Icon(Icons.verified_user_rounded, color: Color(0xFF52C41A), size: 44),
        title: Text(l10n.vt_safe_title),
        content: _buildStatsColumn(ctx, result, l10n),
        actionsAlignment: MainAxisAlignment.spaceEvenly,
        actionsPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(l10n.vt_cancel),
          ),
          TextButton(
            onPressed: () => _openReport(ctx, result),
            child: Text(l10n.vt_open_report),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(l10n.vt_install),
          ),
        ],
      ),
    );
    if (confirmed == true && context.mounted) {
      await _openInstaller(context, path);
    }
  }

  /// 弹出结果对话框：红色/橙色风险警告，默认阻止安装。
  static Future<void> _showRiskDialog(
    BuildContext context,
    String path,
    VirusTotalResult result,
  ) async {
    if (!context.mounted) return;
    final l10n = L10n.of(context);
    final hasMalicious = result.malicious > 0;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: Icon(
          Icons.gpp_bad_rounded,
          color: hasMalicious ? const Color(0xFFEA6668) : const Color(0xFFFAAD14),
          size: 44,
        ),
        title: Text(l10n.vt_risk_title),
        content: _buildStatsColumn(ctx, result, l10n),
        actionsAlignment: MainAxisAlignment.spaceEvenly,
        actionsPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(l10n.vt_cancel),
          ),
          TextButton(
            onPressed: () => _openReport(ctx, result),
            child: Text(l10n.vt_open_report),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: hasMalicious ? const Color(0xFFEA6668) : const Color(0xFFFAAD14),
              foregroundColor: Colors.white,
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(l10n.vt_continue_install),
          ),
        ],
      ),
    );
    if (confirmed == true && context.mounted) {
      await _openInstaller(context, path);
    }
  }

  /// 弹出结果对话框：文件未被收录，可上传完整扫描。
  static Future<void> _showUnknownDialog(
    BuildContext context,
    String path,
    VirusTotalResult result,
  ) async {
    if (!context.mounted) return;
    final l10n = L10n.of(context);
    final choice = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: const Icon(Icons.help_outline_rounded, color: Color(0xFF8BC8EA), size: 44),
        title: Text(l10n.vt_unknown_title),
        content: Text(l10n.vt_not_found_msg),
        actionsAlignment: MainAxisAlignment.spaceEvenly,
        actionsPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, 'cancel'),
            child: Text(l10n.vt_cancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, 'upload'),
            child: Text(l10n.vt_upload_scan),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, 'install'),
            child: Text(l10n.vt_direct_install),
          ),
        ],
      ),
    );
    if (!context.mounted) return;
    if (choice == 'upload') {
      await _uploadScanFlow(context, path);
    } else if (choice == 'install') {
      await _openInstaller(context, path);
    }
  }

  /// 弹出结果对话框：扫描失败（网络/API 错误），不阻止安装。
  static Future<void> _showScanErrorDialog(
    BuildContext context,
    String path,
    String error,
  ) async {
    if (!context.mounted) return;
    final l10n = L10n.of(context);
    final choice = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: const Icon(Icons.error_outline_rounded, color: Color(0xFFFAAD14), size: 44),
        title: Text(l10n.vt_scan_failed('')),
        content: Text(error, style: const TextStyle(fontSize: 13)),
        actionsAlignment: MainAxisAlignment.spaceEvenly,
        actionsPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, 'cancel'),
            child: Text(l10n.vt_cancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, 'retry'),
            child: Text(l10n.vt_retry),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, 'skip'),
            child: Text(l10n.vt_direct_install),
          ),
        ],
      ),
    );
    if (!context.mounted) return;
    if (choice == 'retry') {
      await _scanThenInstallApk(context, path);
    } else if (choice == 'skip') {
      await _openInstaller(context, path);
    }
  }

  /// 上传完整扫描流程：显示进度对话框并轮询结果。
  static Future<void> _uploadScanFlow(BuildContext context, String path) async {
    if (!context.mounted) return;
    final l10n = L10n.of(context);
    String statusText = l10n.vt_uploading;
    final status = ValueNotifier<String>(statusText);

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => AlertDialog(
        content: ValueListenableBuilder<String>(
          valueListenable: status,
          builder: (_, text, _) => Row(
            children: [
              const CircularProgressIndicator(),
              const SizedBox(width: 20),
              Expanded(child: Text(text)),
            ],
          ),
        ),
      ),
    );

    final result = await VirusTotalService.uploadAndScan(
      path,
      onStatus: (s) => status.value = s == 'uploading' ? l10n.vt_uploading : l10n.vt_analyzing,
    );

    if (!context.mounted) return;
    Navigator.pop(context); // 关闭上传进度

    if (result.error != null && !result.found) {
      await _showScanErrorDialog(context, path, result.error!);
      return;
    }
    if (!result.found) {
      await _showUnknownDialog(context, path, result);
      return;
    }
    if (result.isSafe) {
      await _showSafeDialog(context, path, result);
    } else {
      await _showRiskDialog(context, path, result);
    }
  }

  /// 引擎统计列表。
  static Widget _buildStatsColumn(
    BuildContext context,
    VirusTotalResult result,
    L10n l10n,
  ) {
    Widget row(String label, int count, Color color) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(label, style: const TextStyle(fontSize: 14)),
            Text(
              '$count',
              style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: color),
            ),
          ],
        ),
      );
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        row(l10n.vt_malicious_count(result.malicious), result.malicious, const Color(0xFFEA6668)),
        row(l10n.vt_suspicious_count(result.suspicious), result.suspicious, const Color(0xFFFAAD14)),
        row(l10n.vt_harmless_count(result.harmless), result.harmless, const Color(0xFF52C41A)),
        row(l10n.vt_undetected_count(result.undetected), result.undetected, const Color(0xFF6B7280)),
        const SizedBox(height: 4),
        Text(
          'SHA-256: ${result.sha256.length > 20 ? '${result.sha256.substring(0, 20)}…' : result.sha256}',
          style: TextStyle(fontSize: 11, color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.5)),
        ),
      ],
    );
  }

  /// 在浏览器中打开 VirusTotal 详细报告。
  static Future<void> _openReport(BuildContext context, VirusTotalResult result) async {
    final permalink = result.permalink;
    if (permalink == null) return;
    try {
      final ok = await launchUrl(Uri.parse(permalink), mode: LaunchMode.externalApplication);
      if (!ok && context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('无法打开报告链接')),
        );
      }
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('无法打开报告链接')),
        );
      }
    }
  }
}
