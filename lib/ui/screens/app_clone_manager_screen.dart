import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/icon_fonts/broken_icons.dart';
import '../../models/app_info_model.dart';
import '../../providers/file_manager_provider.dart';
import '../../services/apk_clone/apk_clone_engine.dart';
import '../../services/app_clone_service.dart';
import '../../services/app_manager_service.dart';
import 'package:zenfile/l10n/generated/app_localizations.dart';

/// ─────────────────────────────────────────────────────────────────────────────
/// 克隆应用（改包名重打包，多开共存）
///
/// 两个入口共用 [AppCloneFlow] 的流程组件：
///  1. APK 长按菜单「克隆应用」→ [AppCloneFlow.cloneApk]（生成克隆安装包）
///  2. 已装应用菜单「克隆应用」→ [AppCloneFlow.cloneExistingApp]（取已装 APK 生成）
///  3. 本页（克隆管理）：列出 [AppCloneService.cloneDirPath] 下已生成的克隆包，
///     支持安装 / 分享 / 删除。
///
/// 克隆包不直接安装 —— 引擎改写包名（`.zcloneN`）并以内置固定密钥重新签名，
/// 生成的新 APK 保存到 Backups/Apps，由用户自行安装，可与原应用共存多开。
/// ─────────────────────────────────────────────────────────────────────────────
class AppCloneManagerScreen extends StatefulWidget {
  const AppCloneManagerScreen({super.key});

  @override
  State<AppCloneManagerScreen> createState() => _AppCloneManagerScreenState();
}

class _AppCloneManagerScreenState extends State<AppCloneManagerScreen> {
  bool _loading = true;
  List<File> _files = const [];

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    setState(() => _loading = true);
    List<File> files = const [];
    try {
      files = await AppCloneService.listCloneFiles();
    } catch (_) {}
    if (!mounted) return;
    setState(() {
      _files = files;
      _loading = false;
    });
  }

  /// 单个克隆包的动作菜单：安装 / 分享 / 删除。
  Future<void> _showFileMenu(File file) async {
    final l10n = L10n.of(context);
    final name = p.basename(file.path);
    final action = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text(name, style: const TextStyle(fontSize: 16)),
        contentPadding: const EdgeInsets.symmetric(vertical: 8),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: Icon(
                Icons.install_mobile_rounded,
                color: Theme.of(ctx).colorScheme.primary,
              ),
              title: Text(l10n.ui_clone_install),
              onTap: () => Navigator.pop(ctx, 'install'),
            ),
            ListTile(
              leading: const Icon(Broken.export_1, color: Colors.teal),
              title: Text(l10n.ui_clone_share),
              onTap: () => Navigator.pop(ctx, 'share'),
            ),
            ListTile(
              leading: const Icon(Broken.trash, color: Colors.redAccent),
              title: Text(l10n.ui_clone_delete),
              onTap: () => Navigator.pop(ctx, 'delete'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(l10n.ui_cancel),
          ),
        ],
      ),
    );
    if (action == null || !mounted) return;
    switch (action) {
      case 'install':
        final ok = await AppManagerService.installApk(file.path);
        if (!mounted) return;
        if (!ok) {
          AppCloneFlow.showSnack(
            context,
            L10n.of(context).ui_clone_install_failed,
          );
          break;
        }
        // 安装成功：解析克隆包名，提示「是否打开该应用」（避免依赖系统
        // 安装器的打开按钮，确保打开的是克隆包而非原应用）。
        final pkg = await _parseClonePackage(file.path);
        if (!mounted) return;
        final open = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(20),
            ),
            title: Text(l10n.vt_install_success),
            content: Text(l10n.ui_clone_open_ask),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: Text(l10n.ui_cancel),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: Text(l10n.ui_backup_apk_open),
              ),
            ],
          ),
        );
        if (open == true && mounted && pkg != null) {
          await AppManagerService.launchApp(pkg);
        }
        break;
      case 'share':
        try {
          await Share.shareXFiles([XFile(file.path)]);
        } catch (_) {}
        break;
      case 'delete':
        final confirmed = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(20),
            ),
            title: Text(l10n.ui_clone_delete),
            content: Text(l10n.ui_clone_delete_confirm(name)),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: Text(l10n.ui_cancel),
              ),
              FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: Theme.of(ctx).colorScheme.error,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                onPressed: () => Navigator.pop(ctx, true),
                child: Text(l10n.ui_confirm),
              ),
            ],
          ),
        );
        if (confirmed != true || !mounted) return;
        try {
          await file.delete();
          if (!mounted) return;
          AppCloneFlow.showSnack(context, L10n.of(context).ui_clone_deleted);
        } catch (e) {
          if (!mounted) return;
          AppCloneFlow.showSnack(
            context,
            L10n.of(context).ui_clone_failed('$e'),
          );
        }
        await _refresh();
        break;
    }
  }

  /// 从克隆 APK 解析其（新）包名，供安装后「打开应用」使用。
  Future<String?> _parseClonePackage(String path) async {
    try {
      final bytes = await File(path).readAsBytes();
      return ApkCloneEngine.parsePackageName(bytes);
    } catch (_) {
      return null;
    }
  }

  String _fileSizeText(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = L10n.of(context);

    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      appBar: AppBar(
        elevation: 0,
        title: Text(l10n.ui_clone_feature_title),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh_rounded),
            tooltip: l10n.ui_refresh,
            onPressed: _refresh,
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
              children: [
                // 功能说明卡：原理 + 局限
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.secondaryContainer.withOpacity(
                      0.35,
                    ),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(
                            Broken.copy,
                            size: 18,
                            color: theme.colorScheme.primary,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              l10n.ui_clone_feature_title,
                              style: const TextStyle(
                                fontWeight: FontWeight.w700,
                                fontSize: 14,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Text(
                        l10n.ui_clone_feature_desc,
                        style: TextStyle(
                          fontSize: 12.5,
                          height: 1.5,
                          color: theme.colorScheme.onSurface.withOpacity(0.75),
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        l10n.ui_clone_limit_note,
                        style: TextStyle(
                          fontSize: 12,
                          height: 1.5,
                          color: theme.colorScheme.onSurface.withOpacity(0.55),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 18),
                Text(
                  l10n.ui_clone_list_title,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 8),
                if (_files.isEmpty)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 32,
                    ),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.surfaceContainerHighest
                          .withOpacity(0.35),
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Column(
                      children: [
                        Icon(
                          Broken.document,
                          size: 36,
                          color: theme.colorScheme.onSurface.withOpacity(0.3),
                        ),
                        const SizedBox(height: 10),
                        Text(
                          l10n.ui_clone_list_empty_title,
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          l10n.ui_clone_list_empty_desc,
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 12,
                            height: 1.5,
                            color: theme.colorScheme.onSurface.withOpacity(
                              0.55,
                            ),
                          ),
                        ),
                      ],
                    ),
                  )
                else
                  ..._files.map((f) {
                    final name = p.basename(f.path);
                    int size = 0;
                    String timeText = '';
                    try {
                      size = f.lengthSync();
                      final m = f.lastModifiedSync();
                      timeText =
                          '${m.year}-${m.month.toString().padLeft(2, '0')}-${m.day.toString().padLeft(2, '0')} '
                          '${m.hour.toString().padLeft(2, '0')}:${m.minute.toString().padLeft(2, '0')}';
                    } catch (_) {}
                    return ListTile(
                      contentPadding: const EdgeInsets.symmetric(horizontal: 4),
                      leading: Icon(
                        Broken.copy,
                        color: theme.colorScheme.primary,
                      ),
                      title: Text(
                        name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(
                        timeText.isEmpty
                            ? _fileSizeText(size)
                            : '${_fileSizeText(size)} · $timeText',
                        style: TextStyle(
                          fontSize: 12,
                          color: theme.colorScheme.onSurface.withOpacity(0.55),
                        ),
                      ),
                      onTap: () => _showFileMenu(f),
                    );
                  }),
              ],
            ),
    );
  }
}

/// ─────────────────────────────────────────────────────────────────────────────
/// 克隆流程组件：菜单入口 → 份数选择 → 进度 → 完成提示。
/// ─────────────────────────────────────────────────────────────────────────────
class AppCloneFlow {
  AppCloneFlow._();

  static void showSnack(
    BuildContext context,
    String msg, {
    SnackBarAction? action,
  }) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 4),
        action: action,
      ),
    );
  }

  /// 选择克隆份数（1–5 份，每份包名不同）。下拉框默认 1 份。用户取消返回 null。
  static Future<int?> pickCopyCount(BuildContext context) async {
    final l10n = L10n.of(context);
    var selected = 1;
    return showDialog<int>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) => AlertDialog(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
          ),
          title: Text(l10n.ui_clone_count_title),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                l10n.ui_clone_count_desc(selected),
                style: TextStyle(
                  fontSize: 12.5,
                  height: 1.5,
                  color: Theme.of(ctx).colorScheme.onSurface.withOpacity(0.6),
                ),
              ),
              const SizedBox(height: 16),
              DropdownButtonFormField<int>(
                value: selected,
                decoration: InputDecoration(
                  isDense: true,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 4,
                  ),
                ),
                items: [
                  for (var n = 1; n <= 5; n++)
                    DropdownMenuItem(
                      value: n,
                      child: Text(l10n.ui_clone_count_item(n)),
                    ),
                ],
                onChanged: (v) => setState(() => selected = v ?? 1),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(l10n.ui_cancel),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, selected),
              child: Text(MaterialLocalizations.of(ctx).okButtonLabel),
            ),
          ],
        ),
      ),
    );
  }

  /// 带进度对话框执行任务：成功/失败都确保进度框被关闭。
  /// [message] 非空时用于动态更新进度文案（如「(2/3)」）。
  static Future<T?> runWithProgress<T>(
    BuildContext context,
    Future<T> Function() task, {
    ValueListenable<String>? message,
  }) async {
    final l10n = L10n.of(context);
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => AlertDialog(
        content: Row(
          children: [
            const CircularProgressIndicator(),
            const SizedBox(width: 20),
            Expanded(
              child: message == null
                  ? Text(l10n.ui_clone_working)
                  : ValueListenableBuilder<String>(
                      valueListenable: message,
                      builder: (_, v, __) => Text(v),
                    ),
            ),
          ],
        ),
      ),
    );
    try {
      return await task();
    } finally {
      // 进度框弹在根 Navigator 上，用 rootNavigator 关闭（页面可能已切换）。
      final root = Navigator.of(context, rootNavigator: true);
      if (root.canPop()) root.pop();
    }
  }

  /// APK 长按菜单「克隆应用」：选份数 → 生成不同包名的克隆安装包到
  /// Backups/Apps（不直接安装）。成功后提供「查看」入口跳转克隆管理页。
  static Future<void> cloneApk(
    BuildContext context,
    String apkPath, {
    String? displayName,
  }) async {
    if (!context.mounted) return;

    // 加固 / 加壳预检：克隆只改写清单与资源，覆盖不到受保护代码里写死的
    // 身份引用，克隆后很可能运行期崩溃。命中时弹出警告，用户可取消或仍克隆。
    final l10n0 = L10n.of(context);
    final markers = await AppCloneService.detectHardening(apkPath);
    if (markers.isNotEmpty && context.mounted) {
      final proceed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
          ),
          title: Text(l10n0.ui_clone_hardened_title),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(l10n0.ui_clone_hardened_warn),
              const SizedBox(height: 12),
              Text(
                markers.join('、'),
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: Theme.of(ctx).colorScheme.error,
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(l10n0.ui_cancel),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(l10n0.ui_clone_hardened_continue),
            ),
          ],
        ),
      );
      if (proceed != true) return;
    }

    final count = await pickCopyCount(context);
    if (count == null || !context.mounted) return;

    final l10n = L10n.of(context);
    // 关键：进度跑完再弹的结果对话框**不能**用 ScaffoldMessenger 的 context
    //（它在 Navigator 之上，showDialog 会因找不到 Navigator 抛异常且被吞，
    // 表现为「克隆成功但没有任何提示」）。这里提前捕获 navigator / provider /
    // messenger 三个对象，后续一律依赖它们，不依赖任何可失效的 BuildContext。
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context, rootNavigator: true);
    final provider = context.read<FileManagerProvider>();
    final progressMsg = ValueNotifier<String>(l10n.ui_clone_working);

    AppCloneOutput? output;
    Object? error;
    await runWithProgress(context, () async {
      try {
        output = await AppCloneService.cloneApk(
          sourceApkPath: apkPath,
          copies: count,
          displayName: displayName,
          onProgress: (done, total) {
            progressMsg.value = total > 1
                ? l10n.ui_clone_count_progress(done, total)
                : l10n.ui_clone_working;
          },
        );
      } catch (e) {
        error = e;
      }
      return true;
    }, message: progressMsg);
    final err = error;
    if (err != null) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            err is AppCloneException && err.code == AppCloneError.readFailed
                ? l10n.ui_clone_read_failed
                : l10n.ui_clone_failed('$err'),
          ),
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 4),
        ),
      );
      return;
    }
    final paths = output?.paths ?? const <String>[];
    final dirPath = paths.isNotEmpty ? p.dirname(paths.first) : '';
    if (!context.mounted) return;
    // 提示克隆成功并保存在所在位置，询问是否打开所在位置（跳转到
    // Backups/Apps 目录），而非仅给一个「查看」入口。
    final openLocation = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text(
          paths.length <= 1
              ? l10n.ui_clone_done_one
              : l10n.ui_clone_done_many(paths.length),
        ),
        content: Text(l10n.ui_clone_saved_ask(dirPath)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(l10n.ui_cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(l10n.ui_app_open_location),
          ),
        ],
      ),
    );
    if (openLocation == true && dirPath.isNotEmpty) {
      navigator.popUntil((route) => route.isFirst);
      Future.delayed(const Duration(milliseconds: 200), () {
        try {
          provider.setPendingBrowseNavigation(dirPath, paths);
          provider.setNavigateToBrowseTab(true);
        } catch (_) {}
      });
    }
  }

  /// 已装应用菜单「克隆应用」：取已装 base APK 生成克隆安装包。
  /// 拆分 APK（App Bundle）暂不支持，提前拦截提示。
  static Future<void> cloneExistingApp(
    BuildContext context,
    AppInfoModel app,
  ) async {
    if (app.splitSourceDirs.isNotEmpty) {
      showSnack(context, L10n.of(context).ui_clone_split_unsupported);
      return;
    }
    await cloneApk(context, app.sourceDir, displayName: app.name);
  }
}
