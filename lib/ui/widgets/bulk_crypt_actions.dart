import 'dart:io';

import 'package:flutter/material.dart';

import '../../l10n/generated/app_localizations.dart';
import '../../models/file_item_model.dart';
import '../../providers/file_manager_provider.dart';
import '../../services/crypt/vault_crypt_service.dart';
import '../../ui/screens/crypt_mount_edit_screen.dart';
import '../../ui/screens/internal_file_picker_screen.dart';
import '../../ui/screens/vault_session_unlock_dialog.dart';
import 'encryption_mode_bottom_sheet.dart';
import 'progress_overlay.dart';

/// 批量加解密操作的公共逻辑，供多选菜单（长按底部弹窗 / 底部动作栏）共用。
class BulkCryptActions {
  const BulkCryptActions._();

  /// 确认「加密设置」中已配置主密码；未配置则引导去设置。
  static Future<bool> ensureMasterPassword(BuildContext context) async {
    if (await VaultCryptService.instance.hasMasterPassword()) return true;
    if (!context.mounted) return false;
    final l10n = L10n.of(context);
    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.crypt_need_master_title),
        content: Text(l10n.crypt_need_master_body),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(l10n.ui_cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(l10n.vault_go_set_password),
          ),
        ],
      ),
    );
    if (go != true || !context.mounted) return false;
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const CryptMountEditScreen()),
    );
    return VaultCryptService.instance.hasMasterPassword();
  }

  /// 弹出「原地加密 / 沙盒加密」选择底部面板，返回 'inplace' / 'sandbox' 或 null。
  static Future<String?> promptEncryptionMode(BuildContext context) async {
    return EncryptionModeBottomSheet.show(context);
  }

  /// 对 [provider] 当前选中的本地未加密项执行批量加密。
  /// 已包含保险箱会话闸门与主密码检查。
  static Future<void> encryptSelected(
    BuildContext context,
    FileManagerProvider provider,
  ) async {
    if (!await requireVaultSessionUnlock(context)) return;
    if (!await ensureMasterPassword(context)) return;
    if (!context.mounted) return;
    final l10n = L10n.of(context);
    final selectedPaths = provider.selectedPaths.toList();
    if (selectedPaths.isEmpty) return;

    final mode = await promptEncryptionMode(context);
    if (mode == null || !context.mounted) return;

    final progress = ValueNotifier<double?>(null);
    if (context.mounted) {
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (_) => ValueListenableBuilder<double?>(
          valueListenable: progress,
          builder: (_, v, __) => ProgressOverlay(
            message: l10n.vault_encrypting,
            value: v,
          ),
        ),
      );
    }

    int success = 0;
    int failed = 0;
    Object? lastError;
    try {
      for (int i = 0; i < selectedPaths.length; i++) {
        final path = selectedPaths[i];
        if (provider.currIsRemote || path.startsWith('remote://')) {
          failed++;
          continue;
        }
        try {
          if (mode == 'inplace') {
            await VaultCryptService.instance.encryptInPlace(
              sourcePath: path,
              onProgress: (done, total) => progress.value = total > 0
                  ? (i + done / total) / selectedPaths.length
                  : null,
            );
          } else {
            await VaultCryptService.instance.encryptToSandbox(
              sourcePath: path,
              onProgress: (done, total) => progress.value = total > 0
                  ? (i + done / total) / selectedPaths.length
                  : null,
            );
          }
          success++;
        } catch (e) {
          failed++;
          lastError = e;
        }
      }
      if (context.mounted) {
        Navigator.pop(context);
        await provider.refreshCryptMountPoints();
        await provider.loadDirectory(provider.activeTab.currentPath);
        final msg = failed == 0
            ? '加密成功'
            : (lastError != null
                ? l10n.vault_encrypt_failed(lastError.toString())
                : '加密完成，$success 成功，$failed 失败');
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(msg), behavior: SnackBarBehavior.floating),
        );
      }
    } catch (e) {
      if (context.mounted) {
        Navigator.pop(context);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(l10n.vault_encrypt_failed(e.toString())),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } finally {
      progress.dispose();
    }
  }

  /// 对 [provider] 当前选中的本地已加密项执行批量原地解密。
  /// 已包含保险箱会话闸门与主密码检查。
  static Future<void> decryptSelected(
    BuildContext context,
    FileManagerProvider provider,
  ) async {
    if (!await requireVaultSessionUnlock(context)) return;
    if (!await ensureMasterPassword(context)) return;
    if (!context.mounted) return;
    final l10n = L10n.of(context);
    final selectedPaths = provider.selectedPaths.toList();
    final encryptedPaths = selectedPaths.where((p) {
      final model = provider.currentFiles.firstWhere(
        (f) => f.path == p,
        orElse: () => FileItemModel(
          entity: File(p),
          name: p,
          path: p,
          isDirectory: Directory(p).existsSync(),
          size: 0,
          modified: DateTime.now(),
        ),
      );
      return model.isEncrypted;
    }).toList();

    if (encryptedPaths.isEmpty) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('没有选中的加密项'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
      return;
    }

    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.vault_decrypt_confirm_title),
        content: Text(
          '确定要解密选中的 ${encryptedPaths.length} 个文件吗？解密后文件将恢复为普通文件。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(l10n.ui_cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(l10n.ui_confirm),
          ),
        ],
      ),
    );
    if (confirm != true || !context.mounted) return;

    final progress = ValueNotifier<double?>(null);
    if (context.mounted) {
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (_) => ValueListenableBuilder<double?>(
          valueListenable: progress,
          builder: (_, v, __) => ProgressOverlay(
            message: l10n.vault_decrypting,
            value: v,
          ),
        ),
      );
    }

    int success = 0;
    int failed = 0;
    Object? lastError;
    try {
      for (int i = 0; i < encryptedPaths.length; i++) {
        final path = encryptedPaths[i];
        try {
          await VaultCryptService.instance.decryptInPlace(
            encryptedPath: path,
            onProgress: (done, total) => progress.value = total > 0
                ? (i + done / total) / encryptedPaths.length
                : null,
          );
          success++;
        } catch (e) {
          failed++;
          lastError = e;
        }
      }
      if (context.mounted) {
        Navigator.pop(context);
        await provider.refreshCryptMountPoints();
        await provider.loadDirectory(provider.activeTab.currentPath);
        final msg = failed == 0
            ? l10n.vault_decrypt_success
            : (lastError != null
                ? l10n.vault_decrypt_failed(lastError.toString())
                : '${l10n.vault_decrypt_success}，$success 成功，$failed 失败');
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(msg), behavior: SnackBarBehavior.floating),
        );
      }
    } catch (e) {
      if (context.mounted) {
        Navigator.pop(context);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(l10n.vault_decrypt_failed(e.toString())),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } finally {
      progress.dispose();
    }
  }

  /// 远程加密目录（cryptremote://）：选择本地文件，加密后上传到当前远程目录。
  ///
  /// 密文只存在于后端，本地没有任何残留；文件名与内容均按当前挂载点的
  /// 加密配置加密。会话闸门由 provider 内部处理。
  static Future<void> encryptUploadRemoteCrypt(
    BuildContext context,
    FileManagerProvider provider,
  ) async {
    final l10n = L10n.of(context);
    final rootPath =
        provider.rootPath.isNotEmpty ? provider.rootPath : '/storage/emulated/0';
    final localPaths =
        await InternalFilePickerScreen.show(context, rootPath: rootPath);
    if (localPaths == null || localPaths.isEmpty || !context.mounted) return;

    final progress = ValueNotifier<double?>(null);
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => ValueListenableBuilder<double?>(
        valueListenable: progress,
        builder: (_, v, __) => ProgressOverlay(
          message: l10n.vault_encrypt_uploading,
          value: v,
        ),
      ),
    );
    try {
      await provider.encryptUploadToRemoteCrypt(
        localPaths,
        context: context,
        onProgress: (_, p) => progress.value = p,
      );
      if (context.mounted) {
        Navigator.pop(context);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(l10n.vault_encrypt_upload_done),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } catch (e) {
      if (context.mounted) {
        Navigator.pop(context);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('${l10n.vault_encrypt_upload_failed}: $e'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } finally {
      progress.dispose();
    }
  }

  /// 远程加密目录（cryptremote://）：把远程密文条目解密后保存到本地。
  ///
  /// [virtualPaths] 为 cryptremote:// 虚拟路径；目录会递归解密下载。
  static Future<void> decryptDownloadRemoteCrypt(
    BuildContext context,
    FileManagerProvider provider,
    List<String> virtualPaths,
  ) async {
    if (virtualPaths.isEmpty) return;
    final l10n = L10n.of(context);
    final progress = ValueNotifier<double?>(null);
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => ValueListenableBuilder<double?>(
        valueListenable: progress,
        builder: (_, v, __) => ProgressOverlay(
          message: l10n.crypt_remote_downloading,
          value: v,
        ),
      ),
    );
    try {
      await provider.decryptDownloadFromRemoteCrypt(
        virtualPaths,
        context: context,
        onProgress: (_, p) => progress.value = p,
      );
      if (context.mounted) {
        Navigator.pop(context);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(l10n.crypt_remote_download_done),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } catch (e) {
      if (context.mounted) {
        Navigator.pop(context);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('${l10n.crypt_remote_download_failed}: $e'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } finally {
      progress.dispose();
    }
  }
}
