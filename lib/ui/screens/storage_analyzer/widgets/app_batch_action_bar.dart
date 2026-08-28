import 'package:flutter/material.dart';
import '../../../../core/icon_fonts/broken_icons.dart';
import '../../../../models/app_info_model.dart';
import '../../../../services/app_manager_service.dart';
import 'package:zenfile/l10n/generated/app_localizations.dart';

class AppBatchActionBar extends StatelessWidget {
  final List<AppInfoModel> allApps;
  final Set<String> selectedPackages;
  final VoidCallback onClearSelection;
  final VoidCallback onRefreshNeeded;
  final bool canUninstall; // False for system apps tab

  const AppBatchActionBar({
    super.key,
    required this.allApps,
    required this.selectedPackages,
    required this.onClearSelection,
    required this.onRefreshNeeded,
    required this.canUninstall,
  });

  List<AppInfoModel> get _selectedApps {
    return allApps.where((app) => selectedPackages.contains(app.packageName)).toList();
  }

  Future<void> _handleBatchUninstall(BuildContext context) async {
    if (selectedPackages.isEmpty) return;

    final l10n = L10n.of(context);
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) {
        final theme = Theme.of(context);
        return AlertDialog(
          backgroundColor: theme.colorScheme.surface,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          title: Text(l10n.msgeb3d7d70, style: TextStyle(fontWeight: FontWeight.bold)),
          content: Text(l10n.ui_batch_uninstall_confirm(selectedPackages.length)),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(l10n.ui_cancel),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.red,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              ),
              onPressed: () => Navigator.pop(context, true),
              child: Text(l10n.ui_batch_uninstall, style: const TextStyle(fontWeight: FontWeight.bold)),
            ),
          ],
        );
      },
    );

    if (confirm == true) {
      final List<String> toUninstall = selectedPackages.toList();
      // 在清除选择前捕获 navigator（rootNavigator 保证进度框可被关闭）
      final navigator = Navigator.of(context, rootNavigator: true);
      onClearSelection();

      for (final package in toUninstall) {
        await AppManagerService.uninstallApp(package);
      }
      
      Future.delayed(const Duration(seconds: 2), onRefreshNeeded);
    }
  }

  Future<void> _handleBatchBackup(BuildContext context) async {
    if (selectedPackages.isEmpty) return;

    final appsToBackup = _selectedApps;
    // 在清除选择前捕获引用，避免后续 context 失效
    final l10n = L10n.of(context);
    final scaffoldMessenger = ScaffoldMessenger.of(context);
    final rootContext = Navigator.of(context, rootNavigator: true).context;
    onClearSelection();

    // 使用 rootNavigator 保证进度对话框始终可被关闭
    // 避免「onClearSelection 触发 setState 后 context 脱离 navigator 树，Navigator.pop 失效」
    showDialog(
      context: rootContext,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        content: Row(
          children: [
            const CircularProgressIndicator(),
            const SizedBox(width: 20),
            Expanded(child: Text(l10n.ui_batch_backup)),
          ],
        ),
      ),
    );

    try {
      await AppManagerService.batchBackupApps(appsToBackup, (current, total) {});
      if (rootContext.mounted) {
        Navigator.of(rootContext, rootNavigator: true).pop(); // 关闭进度框
        scaffoldMessenger.showSnackBar(
          SnackBar(content: Text(l10n.ui_batch_backup_success(appsToBackup.length))),
        );
        onRefreshNeeded();
      }
    } catch (e) {
      if (rootContext.mounted) {
        Navigator.of(rootContext, rootNavigator: true).pop(); // 关闭进度框
        scaffoldMessenger.showSnackBar(
          SnackBar(content: Text(l10n.ui_batch_backup_failed('$e'))),
        );
      }
    }
  }

  void _handleBatchShare() {
    if (selectedPackages.isEmpty) return;
    final appsToShare = _selectedApps;
    onClearSelection();
    AppManagerService.batchShareAppApks(appsToShare);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = L10n.of(context);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.1),
            blurRadius: 10,
            offset: const Offset(0, -2),
          ),
        ],
      ),
      child: SafeArea(
        child: Row(
          children: [
            OutlinedButton(
              style: OutlinedButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
              ),
              onPressed: onClearSelection,
              child: Text(l10n.ui_cancel, style: const TextStyle(fontWeight: FontWeight.bold)),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Row(
                children: [
                  // Batch Backup
                  Expanded(
                    child: ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.orange.withOpacity(0.15),
                        foregroundColor: Colors.orange,
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                        elevation: 0,
                      ),
                      onPressed: () => _handleBatchBackup(context),
                      child: Text(l10n.ui_batch_backup, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                    ),
                  ),
                  const SizedBox(width: 8),
                  // Batch Share
                  Expanded(
                    child: ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.teal.withOpacity(0.15),
                        foregroundColor: Colors.teal,
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                        elevation: 0,
                      ),
                      onPressed: _handleBatchShare,
                      child: Text(l10n.ui_batch_share, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                    ),
                  ),
                  if (canUninstall) ...[
                    const SizedBox(width: 8),
                    // Batch Uninstall
                    Expanded(
                      child: ElevatedButton(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.red.withOpacity(0.15),
                          foregroundColor: Colors.red,
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                          elevation: 0,
                        ),
                        onPressed: () => _handleBatchUninstall(context),
                        child: Text(l10n.ui_batch_uninstall, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
