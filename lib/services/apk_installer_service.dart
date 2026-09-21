
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:open_filex/open_filex.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:zenfile/l10n/generated/app_localizations.dart';
import '../core/utils.dart';
import 'archive_service.dart';
import 'app_manager_service.dart';
import 'preferences_service.dart';
import 'root_shizuku_service.dart';
import 'virus_total_service.dart';

class ApkInstallerService {
  static const List<String> apkExtensions = ['.apk', '.xapk', '.apks', '.apkm', '.aab'];

  /// 是否为「可直接安装」的包。
  ///
  /// ⚠️ 必须走 [FileUtils.effectiveExtensionWithDot]：IM（QQ / 微信等）遇到重名文件会
  /// 追加序号，`app.apk` 落地成 `app.apk.1`，此时 `p.extension()` 给出的是 `.1` →
  /// 这里判成「不是 APK」，再往下就被当成 zip bundle 去解压安装，用户看到的
  /// 就是「点了安装没反应 / 提示包内没有 APK」。
  static bool isApk(String path) =>
      apkExtensions.contains(FileUtils.effectiveExtensionWithDot(path));

  static Future<void> installApk(BuildContext context, String path) async {
    final ext = FileUtils.effectiveExtensionWithDot(path);
    final apiKey = VirusTotalService.getApiKey();
    final hasKey = apiKey != null && apiKey.isNotEmpty;
    // 扫描需同时满足：已配置 Key + 扫描开关已开启（关闭开关不清空 Key）
    final scanEnabled = PreferencesService.getVirusTotalScanEnabled();
    final shouldScan = hasKey && scanEnabled;

    if (ext == '.apk') {
      if (shouldScan) {
        await _scanThenInstallApk(context, path);
      } else {
        await _openInstaller(context, path);
      }
      return;
    }

    // Bundle: .xapk .apks .apkm .aab —— 先扫描压缩包本身，再解压安装
    if (shouldScan) {
      await _scanThenInstallApk(context, path);
    } else {
      await _installBundle(context, path);
    }
  }

  /// 打开安装器。单 APK 支持静默安装（root/shizuku），bundle 自动解压安装。
  ///
  /// 返回 true 表示安装已通过静默安装**确认完成**（调用方可安全清理 bundle
  /// 解压目录等不再被引用的临时文件）；返回 false 表示走系统安装器
  /// （仅代表安装界面已启动，用户可能尚未确认，不得据此清理临时文件）。
  static Future<bool> _openInstaller(BuildContext context, String path) async {
    final ext = FileUtils.effectiveExtensionWithDot(path);
    if (ext != '.apk') {
      await _installBundle(context, path);
      return false;
    }

    // 开启"保留安装包"时，先复制到临时目录再安装，防止系统安装器删除源文件
    final installPath = await _prepareInstallPath(path);

    if (PreferencesService.getSilentInstall()) {
      final status = await RootShizukuService.checkStatus();
      bool ok = false;
      var tried = false;
      if (status.isRootAvailable) {
        ok = await RootShizukuService.installApkSilently(installPath, useRoot: true);
        tried = true;
      } else if (status.isShizukuAvailable && status.shizukuPermissionGranted) {
        ok = await RootShizukuService.installApkSilently(installPath, useRoot: false);
        tried = true;
      }
      if (ok) {
        // 静默安装已确认完成（pm install 返回 success），临时副本不再需要，
        // 立即删除，避免 apk_install 目录堆积占用存储空间。
        await _deleteTempCopy(installPath);
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(L10n.of(context).vt_install_success)),
          );
        }
        return true;
      }
      // 静默安装失败 → 回退系统安装器。若已具备 root/shizuku 权限仍失败
      // （多为 shell 无安装权限 / 受限 ROM），给用户明确提示，避免误解为静默成功。
      if (tried && context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(L10n.of(context).vt_silent_fallback)),
        );
      }
    }

    // 用原生 installApk（ACTION_VIEW + FileProvider + 优先指定系统包安装器），
    // 既不弹"打开方式"选择器，又比 PackageInstaller API 更通用可靠。
    final success = await AppManagerService.installApk(installPath);
    if (!success && context.mounted) {
      // 最后兜底：OpenFilex
      await OpenFilex.open(installPath);
    }
    return false;
  }

  /// 开启"安装后保留安装包"时，把 APK 复制一份到共享目录再安装，防止系统安装器删除源文件。
  ///
  /// 目标目录必须同时满足三类安装器可读：
  ///  - 系统安装器 / PackageInstaller(FileProvider)：app 私有 cache 或共享目录均可；
  ///  - Shizuku(root 之外的 shell pm install)：shell(uid 2000) **读不到** app 私有
  ///    cache(/data/user/0/...)，只能读 /storage/emulated/0 共享目录。
  /// 故统一复制到共享目录 `/storage/emulated/0/ZenFile/apk_install/`，
  /// root / shizuku shell / 系统安装器 / app 自身全部可读。
  /// 文件名加时间戳后缀，避免多个同名 split 相互覆盖。
  static Future<String> _prepareInstallPath(String path) async {
    if (!PreferencesService.getKeepApkAfterInstall()) return path;
    // 复制新副本前先清理历史残留，避免 apk_install / apk_extract 长期堆积。
    await _cleanupStaleTempFiles();
    try {
      final baseDir = Directory('/storage/emulated/0/ZenFile/apk_install');
      if (!await baseDir.exists()) await baseDir.create(recursive: true);
      final stamp = DateTime.now().millisecondsSinceEpoch;
      // 复制时顺手去掉 IM 追加的序号后缀（`app.apk.1` → `app.apk`）：系统安装器 /
      // OpenFilex 兜底都按扩展名嗅探 MIME，名字带 `.1` 会让兜底路径失败。
      final dest = p.join(
        baseDir.path,
        '${stamp}_${FileUtils.stripImAppendedSuffix(p.basename(path))}',
      );
      await File(path).copy(dest);
      return dest;
    } catch (_) {
      return path;
    }
  }

  /// 清理安装临时目录中已过期的残留文件。
  ///
  /// 系统安装器（ACTION_VIEW）路径下，应用无法得知用户何时完成/取消安装，
  /// 立即删除临时副本会导致系统安装器正在读取时文件消失、安装失败。
  /// 因此对这类路径采用"延迟兜底"：每次复制新副本前，把超过
  /// [_tempRetention] 的旧副本 / 旧解压目录一并清掉。
  ///
  /// 覆盖两个目录：
  ///  - `apk_install/`：开启"安装后保留安装包"时复制的临时 APK 副本；
  ///  - `apk_extract/`：bundle 解压出的 split APK / OBB 目录。
  static const Duration _tempRetention = Duration(hours: 24);

  static Future<void> _cleanupStaleTempFiles() async {
    for (final dirName in ['apk_install', 'apk_extract']) {
      try {
        final dir = Directory('/storage/emulated/0/ZenFile/$dirName');
        if (!await dir.exists()) continue;
        final cutoff = DateTime.now().subtract(_tempRetention);
        await for (final entity in dir.list()) {
          try {
            final stat = await entity.stat();
            if (stat.modified.isBefore(cutoff)) {
              await entity.delete(recursive: true);
            }
          } catch (_) {}
        }
      } catch (_) {}
    }
  }

  /// 静默安装成功后，删除本次复制出的临时副本。
  ///
  /// 仅删除 `apk_install/` 目录内、由 [_prepareInstallPath] 复制的临时文件；
  /// 若传入的是用户原始文件路径（未开启"保留安装包"），不会误删。
  static Future<void> _deleteTempCopy(String installPath) async {
    const base = '/storage/emulated/0/ZenFile/apk_install/';
    if (!installPath.startsWith(base)) return;
    try {
      final f = File(installPath);
      if (await f.exists()) await f.delete();
    } catch (_) {}
  }

  /// 解压并安装 bundle（.xapk/.apks/.apkm/.aab）。
  static Future<void> _installBundle(BuildContext context, String path) async {
    final l10n = L10n.of(context);
    // 解压进度对话框：用 mounted 守卫 + 单一出口关闭，避免页面退出时泄漏/双 pop。
    var dialogOpen = true;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => AlertDialog(
        content: Row(
          children: [
            const CircularProgressIndicator(),
            const SizedBox(width: 20),
            Expanded(child: Text(l10n.vt_extracting)),
          ],
        ),
      ),
    );

    Future<void> closeDialog() async {
      if (!dialogOpen) return;
      dialogOpen = false;
      if (context.mounted) Navigator.of(context, rootNavigator: true).pop();
    }

    // 解压目录声明在 try 之外：catch 分支也需要引用它做残留清理。
    // 目标放共享目录（非 app 私有 cache）：bundle 内 split APK 需经
    // Shizuku shell pm install 读取，shell(uid 2000) 读不到 /data/user/0/...
    final baseDir = Directory('/storage/emulated/0/ZenFile/apk_extract');
    final bundleDirName = p.basenameWithoutExtension(path).replaceAll(RegExp(r'[^a-zA-Z0-9]'), '_');
    final extractDir = Directory(p.join(baseDir.path, '${DateTime.now().millisecondsSinceEpoch}_$bundleDirName'));

    try {
      if (!await baseDir.exists()) await baseDir.create(recursive: true);
      await extractDir.create(recursive: true);

      await ArchiveService.extractArchive(
        archivePath: path,
        destinationDir: extractDir.path,
      );

      if (!context.mounted) {
        // 清理解压残留，防止共享目录堆积
        try {
          await extractDir.delete(recursive: true);
        } catch (_) {}
        return;
      }

      final allApks = <File>[];
      await for (final entity in extractDir.list(recursive: true)) {
        if (entity is! File) continue;
        final ext = p.extension(entity.path).toLowerCase();
        if (ext == '.apk') {
          allApks.add(entity);
        } else if (ext == '.obb') {
          await _tryInstallObb(entity);
        }
      }

      if (allApks.isEmpty) {
        // 解压成功但包内没有 APK：清理解压残留，避免 apk_extract 堆积。
        try {
          if (await extractDir.exists()) await extractDir.delete(recursive: true);
        } catch (_) {}
        await closeDialog();
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(l10n.vt_no_apk_in_bundle)),
          );
        }
        return;
      }

      await closeDialog();
      if (!context.mounted) return;

      if (allApks.length == 1) {
        final installed = await _openInstaller(context, allApks.first.path);
        // 仅当静默安装确认完成时清理解压目录：此时 extractDir 内的原文件
        // 要么已被复制走（开启保留）、要么已读完（未开启保留），删除安全；
        // 回退系统安装器时用户可能仍在确认，extractDir 留给 24h 过期兜底。
        if (installed) {
          try {
            if (await extractDir.exists()) await extractDir.delete(recursive: true);
          } catch (_) {}
        }
      } else {
        // 开启"保留安装包"时，每个内部 APK 先复制到共享目录
        final apkPaths = <String>[];
        for (final f in allApks) {
          apkPaths.add(await _prepareInstallPath(f.path));
        }
        // 优先静默分包安装
        if (PreferencesService.getSilentInstall()) {
          final status = await RootShizukuService.checkStatus();
          bool ok = false;
          var tried = false;
          if (status.isRootAvailable) {
            ok = await RootShizukuService.installSplitApksSilently(apkPaths, useRoot: true);
            tried = true;
          } else if (status.isShizukuAvailable && status.shizukuPermissionGranted) {
            // shizuku：同上，用 PackageInstaller 会话安装，规避 shell pm install 权限不足
            ok = await AppManagerService.installSplitApks(apkPaths);
            tried = true;
          }
          if (ok) {
            // 静默分包安装成功：删除复制到 apk_install 的临时 split 副本，
            // 并清理解压目录 apk_extract（split 已安装，不再需要源文件）。
            for (final apkPath in apkPaths) {
              await _deleteTempCopy(apkPath);
            }
            try {
              if (await extractDir.exists()) await extractDir.delete(recursive: true);
            } catch (_) {}
            if (context.mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text(l10n.vt_install_success)),
              );
            }
            return;
          }
          if (tried && context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text(l10n.vt_silent_fallback)),
            );
          }
        }
        // 回退系统分包安装器（PackageInstaller API）
        final success = await AppManagerService.installSplitApks(apkPaths);
        if (!success && context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(l10n.vt_split_installer_launch_failed)),
          );
        }
      }
    } catch (e) {
      // 解压/安装过程异常：清理已产生的解压残留，防止共享目录堆积。
      try {
        if (await extractDir.exists()) await extractDir.delete(recursive: true);
      } catch (_) {}
      await closeDialog();
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('${l10n.vt_extract_failed}$e')),
        );
      }
    }
  }

  /// 尽力把 bundle 内 OBB 复制到 Android/obb 对应包名目录。
  /// 目录名启发式：优先取 OBB 文件前缀里的包名（如 `main.<ver>.<pkg>.obb`），
  /// 取不到再取上层目录名。失败静默跳过（不致命）。
  static Future<void> _tryInstallObb(File obbFile) async {
    try {
      final obbName = p.basenameWithoutExtension(obbFile.path); // main.123.com.example.game
      var pkgName = '';
      // main.<ver>.<pkg>.obb / patch.<ver>.<pkg>.obb
      final seg = obbName.split('.');
      if (seg.length >= 3) pkgName = seg.sublist(2).join('.');
      if (pkgName.isEmpty) pkgName = p.basename(p.dirname(obbFile.path));
      if (pkgName.isEmpty) return;
      final targetDir = Directory('/storage/emulated/0/Android/obb/$pkgName');
      if (!await targetDir.exists()) await targetDir.create(recursive: true);
      final dest = p.join(targetDir.path, p.basename(obbFile.path));
      if (!await File(dest).exists()) {
        await obbFile.copy(dest);
      }
    } catch (_) {}
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
    void notifyFailed() {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(L10n.of(context).vt_open_report_failed)),
        );
      }
    }

    try {
      final ok = await launchUrl(Uri.parse(permalink), mode: LaunchMode.externalApplication);
      if (!ok) notifyFailed();
    } catch (_) {
      notifyFailed();
    }
  }
}
