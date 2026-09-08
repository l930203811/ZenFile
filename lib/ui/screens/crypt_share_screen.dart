import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:zenfile/l10n/generated/app_localizations.dart';
import '../../services/crypt/crypt_mount.dart';

/// 加密文件夹二维码分享页面
///
/// 显示加密配置的二维码（不含密码），其他设备扫描后可导入配置，
/// 但需要手动输入密码才能解密文件。
class CryptShareScreen extends StatelessWidget {
  final CryptMountPoint mount;

  const CryptShareScreen({super.key, required this.mount});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = L10n.of(context);

    // 生成二维码内容：加密配置 JSON（不含密码）
    final configJson = jsonEncode({
      'type': 'zenfile_crypt_mount',
      'version': 1,
      'physicalPath': mount.physicalPath,
      'name': mount.name,
      'isSandboxMode': mount.isSandboxMode,
      'config': mount.config.toJson(includePassword: false),
    });

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.crypt_share_title),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            // 二维码
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(16),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.1),
                    blurRadius: 10,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: QrImageView(
                data: configJson,
                version: QrVersions.auto,
                size: 240,
                gapless: true,
                errorCorrectionLevel: QrErrorCorrectLevel.M,
              ),
            ),

            const SizedBox(height: 24),

            // 提示信息
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: theme.colorScheme.primary.withOpacity(0.08),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: theme.colorScheme.primary.withOpacity(0.2),
                ),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.info_outline, color: theme.colorScheme.primary, size: 20),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      l10n.crypt_share_hint,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurface.withOpacity(0.8),
                      ),
                    ),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 24),

            // 配置信息
            _buildConfigItem(l10n.crypt_field_name, mount.name ?? mount.physicalPath.split('/').last, theme),
            _buildConfigItem(l10n.crypt_field_path, mount.physicalPath, theme),
            _buildConfigItem(
              l10n.crypt_section_mode,
              mount.isSandboxMode ? l10n.crypt_mode_sandbox : l10n.crypt_mode_inplace,
              theme,
            ),
            _buildConfigItem(
              l10n.crypt_field_filename_enc,
              mount.config.filenameEncryption.name,
              theme,
            ),
            _buildConfigItem(
              l10n.crypt_field_filename_encoding,
              mount.config.filenameEncoding.name,
              theme,
            ),
            _buildConfigItem(
              l10n.crypt_field_suffix,
              mount.config.encryptedSuffix,
              theme,
            ),

            const SizedBox(height: 24),

            // 密码提示
            Text(
              l10n.crypt_share_password_note,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.error,
                fontWeight: FontWeight.w600,
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildConfigItem(String label, String value, ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 100,
            child: Text(
              label,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurface.withOpacity(0.6),
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: theme.textTheme.bodySmall?.copyWith(
                fontWeight: FontWeight.w500,
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}
