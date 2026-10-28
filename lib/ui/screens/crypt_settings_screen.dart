import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:zenfile/l10n/generated/app_localizations.dart';

import '../../providers/file_manager_provider.dart';
import '../../services/crypt/crypt_profile.dart';
import '../../services/crypt/crypt_profile_service.dart';
import '../../services/crypt_auto_encrypt_service.dart';
import 'crypt_mount_edit_screen.dart';
import '../widgets/circled_back_button.dart';

/// 加密设置页面
///
/// 显示所有已配置的加密挂载点，支持添加、编辑、删除和浏览。
class CryptSettingsScreen extends StatefulWidget {
  const CryptSettingsScreen({super.key});

  @override
  State<CryptSettingsScreen> createState() => _CryptSettingsScreenState();
}

class _CryptSettingsScreenState extends State<CryptSettingsScreen> {
  List<CryptProfile> _profiles = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadMountPoints();
  }

  Future<void> _loadMountPoints() async {
    setState(() => _isLoading = true);
    final profiles = await CryptProfileService.instance.loadProfiles();
    if (mounted) {
      setState(() {
        _profiles = profiles;
        _isLoading = false;
      });
    }
  }

  /// 新建一份配置档案
  Future<void> _addProfile() async {
    final result = await Navigator.push<bool>(
      context,
      MaterialPageRoute(builder: (_) => const CryptMountEditScreen()),
    );
    if (result == true) {
      await _loadMountPoints();
      _refreshBrowser();
    }
  }

  /// 编辑配置档案（密码与加盐只读）
  Future<void> _editProfile(CryptProfile profile) async {
    final result = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (_) => CryptMountEditScreen(existingProfile: profile),
      ),
    );
    if (result == true) {
      await _loadMountPoints();
      _refreshBrowser();
    }
  }

  Future<void> _setDefaultProfile(CryptProfile profile) async {
    await CryptProfileService.instance.setActive(profile.id);
    await _loadMountPoints();
    _refreshBrowser();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(L10n.of(context).crypt_profile_default_done)),
      );
    }
  }

  Future<void> _deleteProfile(CryptProfile profile) async {
    final l10n = L10n.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.ui_delete),
        content: Text(l10n.crypt_profile_delete_message),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(l10n.ui_cancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(
              l10n.ui_delete,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await CryptProfileService.instance.delete(profile.id);
    await _loadMountPoints();
    _refreshBrowser();
  }

  /// 配置档案变化后让浏览页重建挂载点缓存（否则仍按旧密钥枚举）
  void _refreshBrowser() {
    try {
      context.read<FileManagerProvider>().refreshCryptMountPoints();
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = L10n.of(context);

    return Scaffold(
      appBar: AppBar(
        leading: const CircledBackButton(),
        title: Text(l10n.crypt_settings_title),
        actions: [
          IconButton(
            icon: const Icon(Icons.add),
            tooltip: l10n.crypt_profile_add,
            onPressed: _addProfile,
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.symmetric(vertical: 8),
              children: [
                // ① 配置档案区（名称唯一，可多组密码+加盐）
                _buildSectionHeader(
                  theme,
                  icon: Icons.key_outlined,
                  title: l10n.crypt_profile_section,
                  trailing: TextButton.icon(
                    onPressed: _addProfile,
                    icon: const Icon(Icons.add, size: 18),
                    label: Text(l10n.crypt_profile_add),
                  ),
                ),
                if (_profiles.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 10,
                    ),
                    child: Text(
                      l10n.crypt_profile_empty,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurface.withValues(
                          alpha: 0.55,
                        ),
                      ),
                    ),
                  )
                else
                  ..._profiles.map((p) => _buildProfileTile(p, theme, l10n)),
                const SizedBox(height: 12),
                // ② 自动关联：本地 / 远程加密文件的自动识别与登记
                _buildSectionHeader(
                  theme,
                  icon: Icons.link_outlined,
                  title: l10n.crypt_auto_encrypt_section,
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 2, 16, 6),
                  child: Text(
                    l10n.crypt_auto_assoc_note,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
                    ),
                  ),
                ),
                _buildAutoAssocTile(
                  theme,
                  icon: Icons.enhanced_encryption_outlined,
                  title: l10n.crypt_auto_encrypt_title,
                  subtitle: l10n.crypt_auto_encrypt_desc,
                  value: CryptAutoEncryptService.instance.autoAssociateLocal,
                  onChanged: (v) async {
                    await CryptAutoEncryptService.instance
                        .setAutoAssociateLocal(v);
                    if (mounted) setState(() {});
                  },
                ),
                _buildAutoAssocTile(
                  theme,
                  icon: Icons.cloud_outlined,
                  title: l10n.crypt_auto_remote_title,
                  subtitle: l10n.crypt_auto_remote_desc,
                  value: CryptAutoEncryptService.instance.autoAssociateRemote,
                  onChanged: (v) async {
                    await CryptAutoEncryptService.instance
                        .setAutoAssociateRemote(v);
                    if (mounted) setState(() {});
                  },
                ),
                const SizedBox(height: 12),
              ],
            ),
    );
  }

  /// 「自动关联」开关：把**已经识别到的**加密文件登记进对应登记表 ——
  /// 本地写进「原地加密目录登记表」（浏览/解密自此有确定性依据），
  /// 远程写进「关联远程加密目录」登记表（可在保险箱以明文名打开解密）。
  ///
  /// 判定都发生在**浏览目录时**（列表已经读出来了），开/关本身零开销；
  /// 旧版「实时监听 + 新文件自动加密」的开关已下线（默认值仍为关闭）。
  Widget _buildAutoAssocTile(
    ThemeData theme, {
    required IconData icon,
    required String title,
    required String subtitle,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 5),
      child: SwitchListTile(
        value: value,
        onChanged: (v) async => onChanged(v),
        secondary: Icon(
          icon,
          color: value
              ? theme.colorScheme.primary
              : theme.colorScheme.onSurface.withValues(alpha: 0.4),
        ),
        title: Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text(
            subtitle,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurface.withValues(alpha: 0.55),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildSectionHeader(
    ThemeData theme, {
    required IconData icon,
    required String title,
    Widget? trailing,
  }) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 8, 6),
      child: Row(
        children: [
          Icon(icon, size: 18, color: theme.colorScheme.primary),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              title,
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          if (trailing != null) trailing,
        ],
      ),
    );
  }

  Widget _buildProfileTile(CryptProfile profile, ThemeData theme, L10n l10n) {
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 5),
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: theme.colorScheme.primary.withValues(alpha: 0.1),
          child: Icon(Icons.key_outlined, color: theme.colorScheme.primary),
        ),
        title: Row(
          children: [
            Expanded(
              child: Text(
                profile.name,
                style: const TextStyle(fontWeight: FontWeight.w600),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (profile.isActive)
              Container(
                margin: const EdgeInsets.only(left: 8),
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: theme.colorScheme.primary.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  l10n.crypt_profile_default,
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                    color: theme.colorScheme.primary,
                  ),
                ),
              ),
          ],
        ),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Row(
            children: [
              _buildChip(
                '${l10n.crypt_filename_enc}: ${profile.filenameEncoding.name}',
                theme,
              ),
              const SizedBox(width: 6),
              _buildChip(
                profile.encryptedSuffix.isEmpty
                    ? l10n.crypt_profile_suffix_none
                    : profile.encryptedSuffix,
                theme,
              ),
            ],
          ),
        ),
        trailing: PopupMenuButton<String>(
          onSelected: (value) {
            switch (value) {
              case 'edit':
                _editProfile(profile);
                break;
              case 'default':
                _setDefaultProfile(profile);
                break;
              case 'delete':
                _deleteProfile(profile);
                break;
            }
          },
          itemBuilder: (context) => [
            PopupMenuItem(value: 'edit', child: Text(l10n.ui_edit)),
            if (!profile.isActive)
              PopupMenuItem(
                value: 'default',
                child: Text(l10n.crypt_profile_set_default),
              ),
            PopupMenuItem(
              value: 'delete',
              child: Text(
                l10n.ui_delete,
                style: TextStyle(color: theme.colorScheme.error),
              ),
            ),
          ],
        ),
        onTap: () => _editProfile(profile),
      ),
    );
  }

  Widget _buildChip(String label, ThemeData theme) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: theme.colorScheme.primary.withValues(alpha: 0.08),
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
