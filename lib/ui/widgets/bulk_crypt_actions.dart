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
import 'crypt_progress_dialog.dart';

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

    final ctl = CryptProgressController();
    if (context.mounted) {
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (_) => ValueListenableBuilder<CryptProgressData?>(
          valueListenable: ctl.notifier,
          builder: (_, v, __) => CryptProgressDialog(
            message: l10n.vault_encrypting,
            progress: v,
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
              onProgress: (done, total) =>
                  ctl.setOverall((i + done / total) / selectedPaths.length),
              onFileProgress: ctl.onFile,
            );
          } else {
            await VaultCryptService.instance.encryptToSandbox(
              sourcePath: path,
              onProgress: (done, total) =>
                  ctl.setOverall((i + done / total) / selectedPaths.length),
              onFileProgress: ctl.onFile,
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
            ? l10n.vault_encrypt_done
            : (lastError != null
                ? l10n.vault_encrypt_failed(lastError.toString())
                : l10n.vault_encrypt_partial(success, failed));
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
      ctl.dispose();
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
          SnackBar(
            content: Text(l10n.vault_no_encrypted_selected),
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
          l10n.vault_decrypt_confirm_multi_desc(encryptedPaths.length),
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

    final ctl = CryptProgressController();
    if (context.mounted) {
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (_) => ValueListenableBuilder<CryptProgressData?>(
          valueListenable: ctl.notifier,
          builder: (_, v, __) => CryptProgressDialog(
            message: l10n.vault_decrypting,
            progress: v,
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
            onProgress: (done, total) =>
                ctl.setOverall((i + done / total) / encryptedPaths.length),
            onFileProgress: ctl.onFile,
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
                : l10n.vault_decrypt_partial(success, failed));
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
      ctl.dispose();
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

    await _runRemoteCryptOp(
      context,
      message: l10n.vault_encrypt_uploading,
      doneMessage: l10n.vault_encrypt_upload_done,
      failedLabel: l10n.vault_encrypt_upload_failed,
      run: (ctl) => provider.encryptUploadToRemoteCrypt(
        localPaths,
        context: context,
        onProgress: (_, p) => ctl.setOverall(p),
        onFileProgress: ctl.onFile,
      ),
    );
  }

  /// 远程**原地加密**：把选中的远程明文条目加密后写回同一远程目录。
  ///
  /// [paths] 既接受远程加密标签页里的 `cryptremote://…` 虚拟路径，也接受普通
  /// 远程目录里的后端真实路径（provider 内部按形态解析挂载点）。
  ///
  /// 进度弹窗与本地「原地加密」完全一致（双层圆环：外圈整体、内圈当前文件字节），
  /// 历史实现用的是单圈圆形遮罩，与本地观感不一致（用户反馈）。
  static Future<void> encryptRemoteInPlace(
    BuildContext context,
    FileManagerProvider provider,
    List<String> paths,
  ) async {
    final valid = paths.where((p) => p.isNotEmpty).toList();
    if (valid.isEmpty) return;
    if (!await requireVaultSessionUnlock(context)) return;
    if (!await ensureMasterPassword(context)) return;
    if (!context.mounted) return;
    final l10n = L10n.of(context);
    await _runRemoteCryptOp(
      context,
      message: l10n.vault_encrypting,
      doneMessage: l10n.vault_encrypt_done,
      failedLabel: l10n.vault_encrypt_upload_failed,
      run: (ctl) => provider.encryptRemoteInPlace(
        valid,
        onProgress: (_, p) => ctl.setOverall(p),
        onFileProgress: ctl.onFile,
      ),
    );
  }

  /// 远程**原地解密**：解密远程密文条目 → 本地留明文副本 → 明文回写替换远程原密文。
  ///
  /// [virtualPaths] 为 `cryptremote://…` 虚拟路径。
  static Future<void> decryptRemoteInPlace(
    BuildContext context,
    FileManagerProvider provider,
    List<String> virtualPaths,
  ) async {
    final valid = virtualPaths
        .where((v) => v.startsWith('cryptremote://'))
        .toList();
    if (valid.isEmpty) return;
    if (!await requireVaultSessionUnlock(context)) return;
    if (!await ensureMasterPassword(context)) return;
    if (!context.mounted) return;
    final l10n = L10n.of(context);
    await _runRemoteCryptOp(
      context,
      message: l10n.vault_decrypting,
      doneMessage: l10n.crypt_remote_download_done,
      failedLabel: l10n.crypt_remote_download_failed,
      run: (ctl) => provider.decryptRemoteInPlace(
        valid,
        onProgress: (_, p) => ctl.setOverall(p),
        onFileProgress: ctl.onFile,
      ),
    );
  }

  /// 远程加解密操作的统一外壳：双层圆环进度弹窗（与本地加解密一致）+ 成功/失败反馈。
  ///
  /// ⚠️ 过去远程链路用的是 [ProgressOverlay]（单圈 + 百分比），本地用的是
  /// [CryptProgressDialog]（双层圆环），两者观感割裂；这里统一走后者。
  static Future<void> _runRemoteCryptOp(
    BuildContext context, {
    required String message,
    required String doneMessage,
    required String failedLabel,
    required Future<void> Function(CryptProgressController ctl) run,
  }) async {
    final ctl = CryptProgressController();
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => ValueListenableBuilder<CryptProgressData?>(
        valueListenable: ctl.notifier,
        builder: (_, v, __) => CryptProgressDialog(message: message, progress: v),
      ),
    );
    try {
      await run(ctl);
      if (context.mounted) {
        Navigator.pop(context);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(doneMessage), behavior: SnackBarBehavior.floating),
        );
      }
    } catch (e) {
      if (context.mounted) {
        Navigator.pop(context);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('$failedLabel: $e'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } finally {
      ctl.dispose();
    }
  }
}
