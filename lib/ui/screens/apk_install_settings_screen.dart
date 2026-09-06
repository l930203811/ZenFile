import 'package:flutter/material.dart';
import 'package:zenfile/l10n/generated/app_localizations.dart';
import '../../services/preferences_service.dart';
import '../../services/root_shizuku_service.dart';
import '../../services/virus_total_service.dart';
import 'virus_total_settings_screen.dart';

class ApkInstallSettingsScreen extends StatefulWidget {
  const ApkInstallSettingsScreen({super.key});

  @override
  State<ApkInstallSettingsScreen> createState() => _ApkInstallSettingsScreenState();
}

class _ApkInstallSettingsScreenState extends State<ApkInstallSettingsScreen> {
  bool _silentInstall = false;
  bool _keepApk = false;
  bool _securityScan = false;
  RootShizukuStatus? _status;

  @override
  void initState() {
    super.initState();
    _silentInstall = PreferencesService.getSilentInstall();
    _keepApk = PreferencesService.getKeepApkAfterInstall();
    // 扫描开关独立于 API Key：关闭开关只禁用扫描，不清空 Key
    _securityScan = PreferencesService.getVirusTotalScanEnabled();
    _loadStatus();
  }

  Future<void> _loadStatus() async {
    final status = await RootShizukuService.checkStatus();
    if (mounted) setState(() => _status = status);
  }

  bool get _canSilentInstall {
    final s = _status;
    if (s == null) return false;
    return s.isRootAvailable || (s.isShizukuAvailable && s.shizukuPermissionGranted);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = L10n.of(context);

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.vt_install_settings_title),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _buildSwitchCard(
            context,
            theme,
            icon: Icons.install_mobile_rounded,
            title: l10n.vt_silent_install,
            subtitle: _canSilentInstall ? l10n.vt_silent_install_ready : l10n.vt_silent_install_requires,
            value: _silentInstall,
            enabled: _canSilentInstall,
            onChanged: (val) async {
              setState(() => _silentInstall = val);
              await PreferencesService.saveSilentInstall(val);
            },
          ),
          const SizedBox(height: 12),
          _buildSwitchCard(
            context,
            theme,
            icon: Icons.save_alt_rounded,
            title: l10n.vt_keep_apk,
            subtitle: l10n.vt_keep_apk_desc,
            value: _keepApk,
            onChanged: (val) async {
              setState(() => _keepApk = val);
              await PreferencesService.saveKeepApkAfterInstall(val);
            },
          ),
          const SizedBox(height: 12),
          _buildSwitchCard(
            context,
            theme,
            icon: Icons.security_rounded,
            title: l10n.vt_settings_title,
            subtitle: l10n.vt_settings_subtitle,
            value: _securityScan,
            onChanged: (val) async {
              if (val) {
                // 打开开关：如果已有 Key 直接启用，没有则跳转配置页
                final existingKey = VirusTotalService.getApiKey();
                if (existingKey != null && existingKey.isNotEmpty) {
                  await PreferencesService.saveVirusTotalScanEnabled(true);
                  if (mounted) setState(() => _securityScan = true);
                } else {
                  await Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const VirusTotalSettingsScreen()),
                  );
                  // 返回后：如果配置了 Key 则启用，否则保持关闭
                  if (mounted) {
                    final key = VirusTotalService.getApiKey();
                    final enabled = key != null && key.isNotEmpty;
                    await PreferencesService.saveVirusTotalScanEnabled(enabled);
                    setState(() => _securityScan = enabled);
                  }
                }
              } else {
                // 关闭开关：只禁用扫描，不清空 API Key（Key 持久化保留）
                await PreferencesService.saveVirusTotalScanEnabled(false);
                if (mounted) setState(() => _securityScan = false);
              }
            },
          ),
        ],
      ),
    );
  }

  Widget _buildSwitchCard(
    BuildContext context,
    ThemeData theme, {
    required IconData icon,
    required String title,
    required String subtitle,
    required bool value,
    bool enabled = true,
    required ValueChanged<bool> onChanged,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: theme.colorScheme.onSurface.withOpacity(0.08)),
      ),
      child: Row(
        children: [
          Icon(icon, size: 22, color: theme.colorScheme.primary),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style: TextStyle(fontSize: 12, color: theme.colorScheme.onSurface.withOpacity(0.55)),
                ),
              ],
            ),
          ),
          Switch(
            value: value,
            onChanged: enabled ? onChanged : null,
          ),
        ],
      ),
    );
  }
}
