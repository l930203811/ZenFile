import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import '../../models/network_connection_model.dart';
import '../../services/network_connections_service.dart';
import '../../services/settings_backup_service.dart';
import 'internal_file_picker_screen.dart';
import 'remote_directory_picker_screen.dart';
import 'package:zenfile/l10n/generated/app_localizations.dart';

class BackupSettingsScreen extends StatefulWidget {
  const BackupSettingsScreen({super.key});

  @override
  State<BackupSettingsScreen> createState() => _BackupSettingsScreenState();
}

class _BackupSettingsScreenState extends State<BackupSettingsScreen> {
  String _backupDirPath = SettingsBackupService.defaultBackupDirPath;
  final List<BackupFileInfo> _backupFiles = [];
  String? _selectedBackupPath;
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadBackupInfo();
  }

  Future<void> _loadBackupInfo() async {
    setState(() => _isLoading = true);
    final dirPath = await SettingsBackupService.getBackupDirPath();
    final files = await SettingsBackupService.listBackupFiles(dirPath);
    if (mounted) {
      setState(() {
        _backupDirPath = dirPath;
        _backupFiles
          ..clear()
          ..addAll(files);
        if (_selectedBackupPath != null &&
            !files.any((f) => f.path == _selectedBackupPath)) {
          _selectedBackupPath = files.isNotEmpty ? files.first.path : null;
        } else if (_selectedBackupPath == null && files.isNotEmpty) {
          _selectedBackupPath = files.first.path;
        }
        _isLoading = false;
      });
    }
  }

  Future<void> _showPathPicker() async {
    final theme = Theme.of(context);
    final l10n = L10n.of(context);
    final choice = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: theme.scaffoldBackgroundColor,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
                child: Text(
                  l10n.ui_select_backup_path,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: theme.colorScheme.onSurface,
                  ),
                ),
              ),
              const SizedBox(height: 8),
              ListTile(
                leading: Icon(Icons.sd_storage, color: theme.colorScheme.primary),
                title: Text(
                  l10n.ui_backup_path_local,
                  style: TextStyle(color: theme.colorScheme.onSurface),
                ),
                onTap: () => Navigator.pop(ctx, 'local'),
              ),
              ListTile(
                leading: Icon(Icons.cloud, color: theme.colorScheme.primary),
                title: Text(
                  l10n.ui_backup_path_remote,
                  style: TextStyle(color: theme.colorScheme.onSurface),
                ),
                onTap: () => Navigator.pop(ctx, 'remote'),
              ),
            ],
          ),
        ),
      ),
    );

    if (choice == null) return;

    if (choice == 'local') {
      final pickedPaths = await InternalFilePickerScreen.show(
        context,
        rootPath: '/storage/emulated/0',
        pickDirectory: true,
      );
      if (pickedPaths != null && pickedPaths.isNotEmpty) {
        final selectedPath = pickedPaths.first;
        await SettingsBackupService.setBackupDirPath(selectedPath);
        await _loadBackupInfo();
      }
    } else if (choice == 'remote') {
      final conn = await _showConnectionPicker();
      if (conn == null) return;
      if (!mounted) return;
      final pickedPath = await RemoteDirectoryPickerScreen.show(context, conn);
      if (pickedPath != null && pickedPath.isNotEmpty) {
        final remoteUri = SettingsBackupService.buildRemotePath(conn.id, pickedPath);
        await SettingsBackupService.setBackupDirPath(remoteUri);
        await _loadBackupInfo();
      }
    }
  }

  Future<NetworkConnectionModel?> _showConnectionPicker() async {
    final theme = Theme.of(context);
    final l10n = L10n.of(context);
    final connections = NetworkConnectionsService.getConnections();

    if (connections.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l10n.ui_no_remote_connections)),
        );
      }
      return null;
    }

    return showModalBottomSheet<NetworkConnectionModel>(
      context: context,
      backgroundColor: theme.scaffoldBackgroundColor,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
              child: Text(
                l10n.ui_select_remote_connection,
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                  color: theme.colorScheme.onSurface,
                ),
              ),
            ),
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: connections.length,
                itemBuilder: (ctx, idx) {
                  final conn = connections[idx];
                  return ListTile(
                    leading: Icon(
                      _connectionIcon(conn.type),
                      color: theme.colorScheme.primary,
                    ),
                    title: Text(
                      conn.name,
                      style: TextStyle(color: theme.colorScheme.onSurface),
                    ),
                    subtitle: Text(
                      '${conn.type} · ${conn.host}',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurface.withOpacity(0.6),
                      ),
                    ),
                    onTap: () => Navigator.pop(ctx, conn),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  IconData _connectionIcon(String type) {
    switch (type.toUpperCase()) {
      case 'FTP':
        return Icons.folder_shared;
      case 'SFTP':
        return Icons.security;
      case 'WEBDAV':
        return Icons.cloud;
      case 'SMB':
      case 'SAMBA':
      case 'CIFS':
        return Icons.storage;
      case 'SAF':
        return Icons.folder_copy;
      default:
        return Icons.cloud_queue;
    }
  }

  Future<void> _performBackup() async {
    final success = await SettingsBackupService.backupSettings(context);
    if (success) {
      await _loadBackupInfo();
    }
  }

  Future<void> _performRestore() async {
    final l10n = L10n.of(context);
    final theme = Theme.of(context);

    if (_selectedBackupPath == null || _selectedBackupPath!.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(l10n.ui_please_select_backup_file),
          behavior: SnackBarBehavior.floating,
          backgroundColor: theme.colorScheme.error,
        ),
      );
      return;
    }

    final success = await SettingsBackupService.restoreSettings(context, _selectedBackupPath!);
    if (success && mounted) {
      _showRestartDialog();
    }
  }

  void _showRestartDialog() {
    final l10n = L10n.of(context);
    final theme = Theme.of(context);

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        backgroundColor: theme.scaffoldBackgroundColor,
        title: Text(
          l10n.ui_restore_restart_title,
          style: TextStyle(color: theme.colorScheme.onSurface),
        ),
        content: Text(
          l10n.ui_restore_restart_message,
          style: TextStyle(color: theme.colorScheme.onSurface.withOpacity(0.8)),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(
              l10n.ui_later,
              style: TextStyle(color: theme.colorScheme.onSurface.withOpacity(0.7)),
            ),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              SystemNavigator.pop();
            },
            child: Text(
              l10n.ui_restart,
              style: TextStyle(color: theme.colorScheme.primary),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final l10n = L10n.of(context);

    final scaffoldBg = theme.scaffoldBackgroundColor;
    final cardBg = isDark
        ? Colors.white.withOpacity(0.04)
        : Colors.black.withOpacity(0.03);
    final borderCol = isDark
        ? Colors.white.withOpacity(0.08)
        : Colors.black.withOpacity(0.08);

    return Scaffold(
      backgroundColor: scaffoldBg,
      appBar: AppBar(
        title: Text(l10n.msgb4fbc92c),
        backgroundColor: scaffoldBg,
        elevation: 0,
        iconTheme: IconThemeData(color: theme.colorScheme.onSurface),
        titleTextStyle: theme.textTheme.titleLarge?.copyWith(
          color: theme.colorScheme.onSurface,
          fontWeight: FontWeight.bold,
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // 备份卡片
          _buildCard(
            context: context,
            theme: theme,
            cardBg: cardBg,
            borderCol: borderCol,
            icon: Icons.backup,
            iconColor: Colors.blue,
            title: l10n.ui_backup_settings,
            subtitle: l10n.zenfilebackupssettings1,
            onTap: _performBackup,
          ),

          const SizedBox(height: 16),

          // 恢复卡片
          _buildCard(
            context: context,
            theme: theme,
            cardBg: cardBg,
            borderCol: borderCol,
            icon: Icons.restore,
            iconColor: Colors.orange,
            title: l10n.ui_restore_settings,
            subtitle: l10n.json1,
            onTap: _performRestore,
          ),

          const SizedBox(height: 24),

          // 备份信息
          _buildInfoSection(
            context: context,
            theme: theme,
            cardBg: cardBg,
            borderCol: borderCol,
          ),
        ],
      ),
    );
  }

  Widget _buildCard({
    required BuildContext context,
    required ThemeData theme,
    required Color cardBg,
    required Color borderCol,
    required IconData icon,
    required Color iconColor,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
  }) {
    return Card(
      elevation: 0,
      color: cardBg,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: borderCol),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Row(
            children: [
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: iconColor.withOpacity(0.12),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Icon(icon, color: iconColor, size: 24),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                        color: theme.colorScheme.onSurface,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      subtitle,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurface.withOpacity(0.6),
                      ),
                    ),
                  ],
                ),
              ),
              Icon(
                Icons.chevron_right,
                color: theme.colorScheme.onSurface.withOpacity(0.4),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildInfoSection({
    required BuildContext context,
    required ThemeData theme,
    required Color cardBg,
    required Color borderCol,
  }) {
    final l10n = L10n.of(context);
    final isRemote = SettingsBackupService.isRemotePath(_backupDirPath);
    final displayPath = isRemote
        ? _backupDirPath
        : _backupDirPath;

    return Card(
      elevation: 0,
      color: cardBg,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: borderCol),
      ),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    l10n.ui_backup_info,
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                      color: theme.colorScheme.onSurface,
                    ),
                  ),
                ),
                InkWell(
                  borderRadius: BorderRadius.circular(8),
                  onTap: _showPathPicker,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.folder_open,
                          size: 16,
                          color: theme.colorScheme.primary,
                        ),
                        const SizedBox(width: 4),
                        Text(
                          l10n.ui_select_backup_path,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.primary,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            _buildInfoRow(
              theme: theme,
              label: l10n.msg534c621a,
              value: displayPath,
            ),
            const SizedBox(height: 16),
            Text(
              '${l10n.ui_backup_file} (${_backupFiles.length})',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurface.withOpacity(0.6),
                fontWeight: FontWeight.w500,
              ),
            ),
            const SizedBox(height: 8),
            if (_isLoading)
              const Center(child: Padding(
                padding: EdgeInsets.all(16),
                child: CircularProgressIndicator(),
              ))
            else if (_backupFiles.isEmpty)
              Text(
                l10n.ui_no_backup_files,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurface.withOpacity(0.5),
                ),
              )
            else
              ..._backupFiles.map((file) => _buildBackupFileTile(file, theme)),
          ],
        ),
      ),
    );
  }

  Widget _buildBackupFileTile(BackupFileInfo file, ThemeData theme) {
    final isSelected = _selectedBackupPath == file.path;

    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: () {
        setState(() {
          _selectedBackupPath = file.path;
        });
      },
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: isSelected
              ? theme.colorScheme.primary.withOpacity(0.1)
              : theme.colorScheme.surface.withOpacity(0.5),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: isSelected
                ? theme.colorScheme.primary.withOpacity(0.4)
                : theme.colorScheme.onSurface.withOpacity(0.08),
          ),
        ),
        child: Row(
          children: [
            Icon(
              isSelected ? Icons.radio_button_checked : Icons.radio_button_unchecked,
              size: 20,
              color: isSelected ? theme.colorScheme.primary : theme.colorScheme.onSurface.withOpacity(0.4),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    file.name,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurface,
                      fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${_formatFileSize(file.size)} · ${_formatDateTime(file.modified)}',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurface.withOpacity(0.5),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildInfoRow({
    required ThemeData theme,
    required String label,
    required String value,
  }) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 100,
          child: Text(
            label,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurface.withOpacity(0.6),
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
        Expanded(
          child: Text(
            value,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurface.withOpacity(0.8),
            ),
          ),
        ),
      ],
    );
  }

  String _formatFileSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  String _formatDateTime(DateTime dt) {
    return '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')} '
        '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}:${dt.second.toString().padLeft(2, '0')}';
  }
}
