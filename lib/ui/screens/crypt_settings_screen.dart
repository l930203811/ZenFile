import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:zenfile/l10n/generated/app_localizations.dart';
import '../../providers/file_manager_provider.dart';
import '../../services/crypt/crypt_mount.dart';
import '../../services/crypt/crypt_operations.dart';
import '../../services/crypt/crypt_mount_service.dart';
import 'crypt_mount_edit_screen.dart';
import 'crypt_share_screen.dart';

/// 加密设置页面
///
/// 显示所有已配置的加密挂载点，支持添加、编辑、删除和浏览。
class CryptSettingsScreen extends StatefulWidget {
  const CryptSettingsScreen({super.key});

  @override
  State<CryptSettingsScreen> createState() => _CryptSettingsScreenState();
}

class _CryptSettingsScreenState extends State<CryptSettingsScreen> {
  List<CryptMountPoint> _mountPoints = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadMountPoints();
  }

  Future<void> _loadMountPoints() async {
    setState(() => _isLoading = true);
    final mounts = await CryptMountService.loadMountPoints();
    if (mounted) {
      setState(() {
        _mountPoints = mounts;
        _isLoading = false;
      });
    }
  }

  Future<void> _addMountPoint() async {
    final result = await Navigator.push<bool>(
      context,
      MaterialPageRoute(builder: (_) => const CryptMountEditScreen()),
    );
    if (result == true) {
      _loadMountPoints();
    }
  }

  Future<void> _editMountPoint(CryptMountPoint mount) async {
    final result = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (_) => CryptMountEditScreen(existingMount: mount),
      ),
    );
    if (result == true) {
      _loadMountPoints();
    }
  }

  Future<void> _deleteMountPoint(CryptMountPoint mount) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(L10n.of(context).crypt_delete_title),
        content: Text(
          L10n.of(context).crypt_delete_message(mount.name ?? mount.physicalPath),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(L10n.of(context).ui_cancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(
              L10n.of(context).ui_delete,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      await CryptMountService.removeMountPoint(mount.physicalPath);
      _loadMountPoints();
    }
  }

  /// 加密挂载点中的所有文件
  Future<void> _encryptMountPoint(CryptMountPoint mount) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(L10n.of(context).crypt_encrypt_title),
        content: Text(L10n.of(context).crypt_encrypt_message),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(L10n.of(context).ui_cancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(L10n.of(context).crypt_action_encrypt, style: TextStyle(fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    final progressNotifier = ValueNotifier<String>('0 / 0');

    if (!mounted) return;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: Text(L10n.of(context).crypt_encrypting),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 16),
            ValueListenableBuilder<String>(
              valueListenable: progressNotifier,
              builder: (context, value, _) => Text(value),
            ),
          ],
        ),
      ),
    );

    try {
      final operations = CryptOperations(mount);
      await operations.encryptDirectory(
        mount.physicalPath,
        onProgress: (processed, total) {
          progressNotifier.value = '$processed / $total';
        },
      );
      if (mounted) Navigator.pop(context);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(L10n.of(context).crypt_encrypt_success)),
        );
      }
      _loadMountPoints();
      // 刷新 FileManagerProvider 的加密挂载点缓存，无需重启应用
      if (mounted) {
        context.read<FileManagerProvider>().refreshCryptMountPoints();
      }
    } catch (e) {
      if (mounted) Navigator.pop(context);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(L10n.of(context).crypt_encrypt_failed(e.toString()))),
        );
      }
    }
  }

  /// 解密挂载点中的所有文件
  Future<void> _decryptMountPoint(CryptMountPoint mount) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(L10n.of(context).crypt_decrypt_title),
        content: Text(L10n.of(context).crypt_decrypt_message),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(L10n.of(context).ui_cancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(L10n.of(context).crypt_action_decrypt, style: TextStyle(fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    final progressNotifier = ValueNotifier<String>('0 / 0');

    if (!mounted) return;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: Text(L10n.of(context).crypt_decrypting),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 16),
            ValueListenableBuilder<String>(
              valueListenable: progressNotifier,
              builder: (context, value, _) => Text(value),
            ),
          ],
        ),
      ),
    );

    try {
      final operations = CryptOperations(mount);
      await operations.decryptDirectory(
        mount.physicalPath,
        onProgress: (processed, total) {
          progressNotifier.value = '$processed / $total';
        },
      );
      if (mounted) Navigator.pop(context);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(L10n.of(context).crypt_decrypt_success)),
        );
      }
      _loadMountPoints();
      // 刷新 FileManagerProvider 的加密挂载点缓存，无需重启应用
      if (mounted) {
        context.read<FileManagerProvider>().refreshCryptMountPoints();
      }
    } catch (e) {
      if (mounted) Navigator.pop(context);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(L10n.of(context).crypt_decrypt_failed(e.toString()))),
        );
      }
    }
  }

  void _browseMountPoint(CryptMountPoint mount) {
    final provider = context.read<FileManagerProvider>();
    Navigator.pop(context);
    provider.loadDirectory(mount.physicalPath);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = L10n.of(context);

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.crypt_settings_title),
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _mountPoints.isEmpty
              ? _buildEmptyState(theme, l10n)
              : ListView.builder(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  itemCount: _mountPoints.length,
                  itemBuilder: (context, index) {
                    final mount = _mountPoints[index];
                    return _buildMountTile(mount, theme, l10n);
                  },
                ),
    );
  }

  Widget _buildEmptyState(ThemeData theme, L10n l10n) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.lock_outline,
              size: 64,
              color: theme.colorScheme.primary.withOpacity(0.5),
            ),
            const SizedBox(height: 16),
            Text(
              l10n.crypt_no_mounts_title,
              style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              l10n.crypt_no_mounts_subtitle,
              style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurface.withOpacity(0.6)),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: _addMountPoint,
              icon: const Icon(Icons.add),
              label: Text(l10n.crypt_add_mount),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMountTile(CryptMountPoint mount, ThemeData theme, L10n l10n) {
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: theme.colorScheme.primary.withOpacity(0.1),
          child: Icon(
            mount.isSandboxMode ? Icons.sd_storage_outlined : Icons.folder_outlined,
            color: theme.colorScheme.primary,
          ),
        ),
        title: Text(
          mount.name ?? mount.physicalPath.split('/').last,
          style: const TextStyle(fontWeight: FontWeight.w600),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              mount.physicalPath,
              style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurface.withOpacity(0.6)),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 2),
            Row(
              children: [
                _buildChip(
                  mount.isSandboxMode ? l10n.crypt_mode_sandbox : l10n.crypt_mode_inplace,
                  theme,
                ),
                const SizedBox(width: 6),
                _buildChip(
                  '${l10n.crypt_filename_enc}: ${mount.config.filenameEncryption.name}',
                  theme,
                ),
              ],
            ),
          ],
        ),
        trailing: PopupMenuButton<String>(
          onSelected: (value) {
            switch (value) {
              case 'browse':
                _browseMountPoint(mount);
                break;
              case 'encrypt':
                _encryptMountPoint(mount);
                break;
              case 'decrypt':
                _decryptMountPoint(mount);
                break;
              case 'share':
                Navigator.push(context, MaterialPageRoute(builder: (_) => CryptShareScreen(mount: mount)));
                break;
              case 'edit':
                _editMountPoint(mount);
                break;
              case 'delete':
                _deleteMountPoint(mount);
                break;
            }
          },
          itemBuilder: (context) => [
            PopupMenuItem(value: 'browse', child: Text(l10n.crypt_action_browse)),
            PopupMenuItem(value: 'encrypt', child: Text(l10n.crypt_action_encrypt)),
            PopupMenuItem(value: 'decrypt', child: Text(l10n.crypt_action_decrypt)),
            PopupMenuItem(value: 'share', child: Text(l10n.crypt_action_share)),
            PopupMenuItem(value: 'edit', child: Text(l10n.ui_edit)),
            PopupMenuItem(
              value: 'delete',
              child: Text(l10n.ui_delete, style: TextStyle(color: theme.colorScheme.error)),
            ),
          ],
        ),
        onTap: () => _browseMountPoint(mount),
      ),
    );
  }

  Widget _buildChip(String label, ThemeData theme) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: theme.colorScheme.primary.withOpacity(0.08),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        label,
        style: theme.textTheme.labelSmall?.copyWith(
          color: theme.colorScheme.primary,
          fontSize: 10,
        ),
      ),
    );
  }
}
