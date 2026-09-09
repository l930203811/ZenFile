import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:zenfile/l10n/generated/app_localizations.dart';
import '../../services/crypt/crypt_config.dart';
import '../../services/crypt/crypt_mount.dart';
import '../../services/crypt/crypt_mount_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 添加/编辑加密挂载点页面
class CryptMountEditScreen extends StatefulWidget {
  final CryptMountPoint? existingMount;

  const CryptMountEditScreen({super.key, this.existingMount});

  @override
  State<CryptMountEditScreen> createState() => _CryptMountEditScreenState();
}

class _CryptMountEditScreenState extends State<CryptMountEditScreen> {
  final _formKey = GlobalKey<FormState>();
  late TextEditingController _passwordController;
  late TextEditingController _confirmPasswordController;
  late TextEditingController _saltController;
  late TextEditingController _suffixController;

  late FilenameEncryption _filenameEncryption;
  late bool _directoryNameEncryption;
  late FilenameEncoding _filenameEncoding;
  bool _showPassword = false;

  @override
  void initState() {
    super.initState();
    final mount = widget.existingMount;
    _passwordController = TextEditingController(text: mount?.config.password ?? '');
    _confirmPasswordController = TextEditingController(text: mount?.config.password ?? '');
    _saltController = TextEditingController(text: mount?.config.salt ?? '');
    _suffixController = TextEditingController(text: mount?.config.encryptedSuffix ?? '.bin');
    _filenameEncryption = mount?.config.filenameEncryption ?? FilenameEncryption.standard;
    _directoryNameEncryption = mount?.config.directoryNameEncryption ?? true;
    _filenameEncoding = mount?.config.filenameEncoding ?? FilenameEncoding.base32;

    // 如果是新建挂载点，从SharedPreferences读取上次保存的密码和加盐
    if (mount == null) {
      _loadSavedCredentials();
    }
  }

  /// 从SharedPreferences读取上次保存的密码和加盐
  Future<void> _loadSavedCredentials() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final savedPassword = prefs.getString('crypt_last_password') ?? '';
      final savedSalt = prefs.getString('crypt_last_salt') ?? '';
      if (savedPassword.isNotEmpty) {
        _passwordController.text = savedPassword;
        _confirmPasswordController.text = savedPassword;
      }
      if (savedSalt.isNotEmpty) {
        _saltController.text = savedSalt;
      }
    } catch (_) {}
  }

  /// 保存密码和加盐到SharedPreferences
  Future<void> _saveCredentials() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('crypt_last_password', _passwordController.text);
      await prefs.setString('crypt_last_salt', _saltController.text);
    } catch (_) {}
  }

  @override
  void dispose() {
    _passwordController.dispose();
    _confirmPasswordController.dispose();
    _saltController.dispose();
    _suffixController.dispose();
    super.dispose();
  }

  String _getFilenameEncryptionLabel(FilenameEncryption mode) {
    final l10n = L10n.of(context);
    switch (mode) {
      case FilenameEncryption.off:
        return l10n.crypt_filename_enc_off;
      case FilenameEncryption.standard:
        return l10n.crypt_filename_enc_standard;
      case FilenameEncryption.obfuscate:
        return l10n.crypt_filename_enc_obfuscate;
    }
  }

  String _getFilenameEncodingLabel(FilenameEncoding enc) {
    final l10n = L10n.of(context);
    switch (enc) {
      case FilenameEncoding.base64:
        return l10n.crypt_filename_enc_base64;
      case FilenameEncoding.base32:
        return l10n.crypt_filename_enc_base32;
      case FilenameEncoding.base32768:
        return l10n.crypt_filename_enc_base32768;
    }
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;

    final password = _passwordController.text;

    // 保存密码和加盐到SharedPreferences，方便下次使用
    await _saveCredentials();

    final existing = widget.existingMount;
    if (existing != null) {
      // 编辑已有挂载点：保留其物理路径/沙盒标记/名称，仅更新加密配置。
      final updated = existing.copyWith(
        config: RcloneCryptConfig(
          password: password,
          salt: _saltController.text.trim().isEmpty ? null : _saltController.text.trim(),
          filenameEncryption: _filenameEncryption,
          directoryNameEncryption: _directoryNameEncryption,
          filenameEncoding: _filenameEncoding,
          encryptedSuffix: _suffixController.text.trim().isEmpty ? '.bin' : _suffixController.text.trim(),
        ),
      );
      await CryptMountService.addMountPoint(updated);
    } else {
      // 新增 = 仅设置「主密码 / 盐」这组共享凭据（供原地加密、沙盒加密复用）。
      //
      // ⚠️ 此前这里会创建一个 physicalPath=/storage/emulated/0 的整机
      // CryptVFS 挂载点，导致浏览页把整个存储当成加密目录：所有文件夹
      // 上锁、进入后内容为空。真正的原地加密挂载点由
      // VaultCryptService.encryptInPlace 在加密【具体目录】时按需创建
      // （挂载在父目录），沙盒挂载点由 ensureSandboxMount 按需创建，
      // 都不应覆盖整机。
      //
      // 顺手清理历史遗留的「整机根目录」挂载点，避免已保存的错误配置
      // 继续让浏览页全锁。
      await _removeLegacyRootMounts();
    }

    if (mounted) {
      Navigator.pop(context, true);
    }
  }

  /// 移除历史遗留的「整机根目录」级别挂载点（错误配置）
  Future<void> _removeLegacyRootMounts() async {
    try {
      final mounts = await CryptMountService.loadMountPoints();
      var changed = false;
      mounts.removeWhere((m) {
        final normalized = p.normalize(m.physicalPath);
        final isRoot = normalized == '/storage/emulated/0' ||
            normalized == '/storage/emulated' ||
            normalized == '/storage' ||
            normalized == '/';
        if (isRoot) changed = true;
        return isRoot;
      });
      if (changed) await CryptMountService.saveMountPoints(mounts);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = L10n.of(context);

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.crypt_set_master_password),
        actions: [
          TextButton(
            onPressed: _save,
            child: Text(
              l10n.ui_save,
              style: TextStyle(color: theme.colorScheme.primary, fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            // 密码
            _buildLabel(l10n.crypt_field_password, theme),
            TextFormField(
              controller: _passwordController,
              obscureText: !_showPassword,
              decoration: InputDecoration(
                border: const OutlineInputBorder(),
                prefixIcon: const Icon(Icons.lock_outline),
                suffixIcon: IconButton(
                  icon: Icon(_showPassword ? Icons.visibility_off : Icons.visibility),
                  onPressed: () => setState(() => _showPassword = !_showPassword),
                ),
              ),
              validator: (value) {
                if (value == null || value.isEmpty) {
                  return l10n.crypt_error_password_required;
                }
                if (value.length < 4) {
                  return l10n.crypt_error_password_short;
                }
                return null;
              },
            ),
            const SizedBox(height: 16),

            // 确认密码
            _buildLabel(l10n.crypt_field_confirm_password, theme),
            TextFormField(
              controller: _confirmPasswordController,
              obscureText: !_showPassword,
              decoration: InputDecoration(
                border: const OutlineInputBorder(),
                prefixIcon: const Icon(Icons.lock_outline),
              ),
              validator: (value) {
                if (value != _passwordController.text) {
                  return l10n.crypt_error_password_mismatch;
                }
                return null;
              },
            ),
            const SizedBox(height: 16),

            // 加盐
            _buildLabel(l10n.crypt_field_salt, theme),
            TextField(
              controller: _saltController,
              decoration: InputDecoration(
                hintText: l10n.crypt_field_salt_hint,
                border: const OutlineInputBorder(),
                prefixIcon: const Icon(Icons.shield_outlined),
              ),
            ),
            const SizedBox(height: 16),

            // 加密后缀
            _buildLabel(l10n.crypt_field_suffix, theme),
            TextField(
              controller: _suffixController,
              decoration: InputDecoration(
                border: const OutlineInputBorder(),
                prefixIcon: const Icon(Icons.extension_outlined),
              ),
            ),
            const SizedBox(height: 16),

            // 文件名加密（下拉选择）
            _buildLabel(l10n.crypt_field_filename_enc, theme),
            DropdownButtonFormField<FilenameEncryption>(
              value: _filenameEncryption,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.vpn_key_outlined),
              ),
              items: FilenameEncryption.values.map((mode) {
                return DropdownMenuItem<FilenameEncryption>(
                  value: mode,
                  child: Text(_getFilenameEncryptionLabel(mode)),
                );
              }).toList(),
              onChanged: (value) {
                if (value != null) {
                  setState(() => _filenameEncryption = value);
                }
              },
            ),
            const SizedBox(height: 16),

            // 文件夹名称加密（下拉选择）
            _buildLabel(l10n.crypt_field_dirname_enc, theme),
            DropdownButtonFormField<bool>(
              value: _directoryNameEncryption,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.folder_copy_outlined),
              ),
              items: [
                DropdownMenuItem<bool>(value: true, child: Text(l10n.crypt_dirname_enc_yes)),
                DropdownMenuItem<bool>(value: false, child: Text(l10n.crypt_dirname_enc_no)),
              ],
              onChanged: (value) {
                if (value != null) {
                  setState(() => _directoryNameEncryption = value);
                }
              },
            ),
            const SizedBox(height: 16),

            // 文件名编码（下拉选择）
            _buildLabel(l10n.crypt_field_filename_encoding, theme),
            DropdownButtonFormField<FilenameEncoding>(
              value: _filenameEncoding,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.code_outlined),
              ),
              items: FilenameEncoding.values.map((enc) {
                return DropdownMenuItem<FilenameEncoding>(
                  value: enc,
                  child: Text(_getFilenameEncodingLabel(enc)),
                );
              }).toList(),
              onChanged: (value) {
                if (value != null) {
                  setState(() => _filenameEncoding = value);
                }
              },
            ),
            const SizedBox(height: 24),

            // 保存按钮
            FilledButton.icon(
              onPressed: _save,
              icon: const Icon(Icons.check),
              label: Text(l10n.ui_save),
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 14),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildLabel(String label, ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.only(left: 4, bottom: 8),
      child: Text(
        label,
        style: theme.textTheme.titleSmall?.copyWith(
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}
