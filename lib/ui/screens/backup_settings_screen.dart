import 'dart:io';
import 'package:flutter/material.dart';
import '../../services/settings_backup_service.dart';
import 'internal_file_picker_screen.dart';

class BackupSettingsScreen extends StatelessWidget {
  const BackupSettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

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
        title: const Text('备份与恢复'),
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
          // 备份设置卡片
          _buildCard(
            context: context,
            theme: theme,
            cardBg: cardBg,
            borderCol: borderCol,
            icon: Icons.backup,
            iconColor: Colors.blue,
            title: '备份设置',
            subtitle: '将所有当前设置保存到 ZenFile/Backups/Settings/',
            onTap: () async {
              await SettingsBackupService.backupSettings(context);
            },
          ),

          const SizedBox(height: 16),

          // 恢复设置卡片
          _buildCard(
            context: context,
            theme: theme,
            cardBg: cardBg,
            borderCol: borderCol,
            icon: Icons.restore,
            iconColor: Colors.orange,
            title: '恢复设置',
            subtitle: '选择并恢复 JSON 备份文件中的设置',
            onTap: () async {
              final pickedPaths = await InternalFilePickerScreen.show(
                context,
                rootPath: '/storage/emulated/0',
                pickDirectory: false,
              );

              if (pickedPaths != null && pickedPaths.isNotEmpty) {
                final selectedPath = pickedPaths.first;
                if (selectedPath.toLowerCase().endsWith('.json')) {
                  if (context.mounted) {
                    await SettingsBackupService.restoreSettings(context, selectedPath);
                  }
                } else {
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: const Text('请选择有效的 .json 设置备份文件'),
                        behavior: SnackBarBehavior.floating,
                        backgroundColor: theme.colorScheme.error,
                      ),
                    );
                  }
                }
              }
            },
          ),

          const SizedBox(height: 24),

          // 备份文件信息
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
    final backupDir = Directory(SettingsBackupService.backupDirPath);
    final backupFile = File(SettingsBackupService.backupFilePath);

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
            Text(
              '备份信息',
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w600,
                color: theme.colorScheme.onSurface,
              ),
            ),
            const SizedBox(height: 12),
            _buildInfoRow(
              theme: theme,
              label: '备份目录',
              value: SettingsBackupService.backupDirPath,
            ),
            const SizedBox(height: 8),
            _buildInfoRow(
              theme: theme,
              label: '备份文件',
              value: SettingsBackupService.backupFilePath,
            ),
            const SizedBox(height: 12),
            FutureBuilder<bool>(
              future: backupFile.exists(),
              builder: (context, snapshot) {
                if (snapshot.hasData && snapshot.data == true) {
                  return FutureBuilder<FileStat>(
                    future: backupFile.stat(),
                    builder: (context, statSnapshot) {
                      if (statSnapshot.hasData) {
                        final stat = statSnapshot.data!;
                        final modified = stat.modified;
                        final size = stat.size;
                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            _buildInfoRow(
                              theme: theme,
                              label: '文件大小',
                              value: _formatFileSize(size),
                            ),
                            const SizedBox(height: 8),
                            _buildInfoRow(
                              theme: theme,
                              label: '最后备份时间',
                              value: _formatDateTime(modified),
                            ),
                          ],
                        );
                      }
                      return const SizedBox.shrink();
                    },
                  );
                }
                return Text(
                  '暂无备份文件',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurface.withOpacity(0.5),
                  ),
                );
              },
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
