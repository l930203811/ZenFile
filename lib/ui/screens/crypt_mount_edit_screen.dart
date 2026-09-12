import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:zenfile/l10n/generated/app_localizations.dart';
import '../../providers/file_manager_provider.dart';
import '../../services/crypt/crypt_config.dart';
import '../../services/crypt/crypt_mount_service.dart';
import '../../services/crypt/crypt_profile.dart';
import '../../services/crypt/crypt_profile_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 加密设置页：新建 / 编辑「加密配置档案」（主密码 + 加盐）。
///
/// 这份凭据是 crypt 加解密的**唯一**密钥来源，与保险箱解锁密码完全独立。
///
/// 两种模式：
/// - [existingProfile] != null → **编辑配置档案**（密码/加盐只读，只能改名与编码参数）；
/// - 否则 → **新建配置档案**（顶部填写唯一的「加密名称」）。
class CryptMountEditScreen extends StatefulWidget {
  final CryptProfile? existingProfile;

  const CryptMountEditScreen({super.key, this.existingProfile});

  @override
  State<CryptMountEditScreen> createState() => _CryptMountEditScreenState();
}

class _CryptMountEditScreenState extends State<CryptMountEditScreen> {
  final _formKey = GlobalKey<FormState>();
  late TextEditingController _nameController;
  late TextEditingController _passwordController;
  late TextEditingController _confirmPasswordController;
  late TextEditingController _saltController;
  late TextEditingController _suffixController;

  late FilenameEncryption _filenameEncryption;
  late bool _directoryNameEncryption;
  late FilenameEncoding _filenameEncoding;
  bool _showPassword = false;

  /// 已存在的档案（用于名称查重时排除自身）
  List<CryptProfile> _profiles = [];

  /// 编辑档案模式：密码与加盐锁定不可改（改了等于换密钥，旧密文永久解不开）
  bool get _isProfileEdit => widget.existingProfile != null;

  /// 新建档案模式（不是编辑挂载点）
  bool get _isProfileCreate => widget.existingProfile == null;

  /// 新建时是否设为默认档案
  late bool _setAsDefault;

  @override
  void initState() {
    super.initState();
    final profile = widget.existingProfile;

    _nameController = TextEditingController(text: profile?.name ?? '');
    _passwordController = TextEditingController(
      text: profile?.password ?? '',
    );
    _confirmPasswordController = TextEditingController(
      text: profile?.password ?? '',
    );
    _saltController = TextEditingController(
      text: profile?.salt ?? '',
    );
    _suffixController = TextEditingController(
      text: profile?.encryptedSuffix ?? '.bin',
    );
    _filenameEncryption =
        profile?.filenameEncryption ?? FilenameEncryption.standard;
    _directoryNameEncryption =
        profile?.directoryNameEncryption ?? true;
    _filenameEncoding =
        profile?.filenameEncoding ?? FilenameEncoding.base32;
    _setAsDefault = profile?.isActive ?? false;

    _loadProfiles();

    // 新建档案时，从SharedPreferences读取上次保存的密码和加盐（legacy 兼容）
    if (profile == null) {
      _loadSavedCredentials();
    }
  }

  Future<void> _loadProfiles() async {
    final profiles = await CryptProfileService.instance.loadProfiles();
    if (!mounted) return;
    setState(() => _profiles = profiles);
  }

  /// 从SharedPreferences读取上次保存的密码、加盐、文件名编码和加密后缀
  Future<void> _loadSavedCredentials() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final savedPassword = prefs.getString('crypt_last_password') ?? '';
      final savedSalt = prefs.getString('crypt_last_salt') ?? '';
      final savedEnc = prefs.getString('crypt_last_filename_encoding') ?? '';
      const suffixKey = 'crypt_last_encrypted_suffix';
      final hasSavedSuffix = prefs.containsKey(suffixKey);
      final savedSuffix = prefs.getString(suffixKey) ?? '';
      if (!mounted) return;
      // ⚠️ 必须走 setState：本方法在 initState 里异步执行，首帧 build 时
      // 用的仍是默认 base32/".bin"，不触发重建的话下拉框永远显示默认值，
      // 用户会以为「保存的 Base64 没生效」。
      setState(() {
        if (savedPassword.isNotEmpty) {
          _passwordController.text = savedPassword;
          _confirmPasswordController.text = savedPassword;
        }
        if (savedSalt.isNotEmpty) {
          _saltController.text = savedSalt;
        }
        if (savedEnc.isNotEmpty) {
          _filenameEncoding = FilenameEncoding.values.firstWhere(
            (e) => e.name == savedEnc,
            orElse: () => FilenameEncoding.base32,
          );
        }
        // 只要保存过 suffix 就覆盖输入框，允许空后缀；未保存过时保留默认 .bin。
        if (hasSavedSuffix) {
          _suffixController.text = savedSuffix;
        }
      });
    } catch (_) {}
  }

  /// 保存密码、加盐、文件名编码和加密后缀到SharedPreferences
  Future<void> _saveCredentials() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('crypt_last_password', _passwordController.text);
      await prefs.setString('crypt_last_salt', _saltController.text);
      await prefs.setString(
        'crypt_last_filename_encoding',
        _filenameEncoding.name,
      );
      await prefs.setString(
        'crypt_last_encrypted_suffix',
        _suffixController.text.trim(),
      );
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

    // 保存密码和加盐到SharedPreferences，方便下次使用（legacy 兼容）
    await _saveCredentials();

    final profile = widget.existingProfile;

    if (profile != null) {
      // 编辑档案：名称 / 编码参数可改，密码与加盐**强制沿用原值**
      // （改密钥 = 已有密文永久不可解，UI 已锁定输入，这里再兜底一次）。
      final updated = profile.copyWith(
        name: _nameController.text.trim(),
        password: profile.password,
        salt: profile.salt,
        filenameEncryption: _filenameEncryption,
        directoryNameEncryption: _directoryNameEncryption,
        filenameEncoding: _filenameEncoding,
        encryptedSuffix: _suffixController.text.trim(),
      );
      await CryptProfileService.instance.addOrUpdate(updated);
      if (_setAsDefault) {
        await CryptProfileService.instance.setActive(updated.id);
      }
    } else {
      // 新建一份配置档案：持久化到安全存储（Android Keystore）
      final created = CryptProfile(
        id: CryptProfile.newId(),
        name: _nameController.text.trim(),
        password: password,
        salt: _saltController.text.trim().isEmpty
            ? null
            : _saltController.text.trim(),
        filenameEncryption: _filenameEncryption,
        directoryNameEncryption: _directoryNameEncryption,
        filenameEncoding: _filenameEncoding,
        encryptedSuffix: _suffixController.text.trim(),
        createdAtMs: DateTime.now().millisecondsSinceEpoch,
        isActive: _setAsDefault,
      );
      await CryptProfileService.instance.addOrUpdate(created);
      if (_setAsDefault) {
        await CryptProfileService.instance.setActive(created.id);
      }
      // 顺手清理历史遗留的「整机根目录」挂载点，避免错误配置让浏览页全锁
      await _removeLegacyRootMounts();
    }

    if (mounted) {
      // 主密码 / 挂载点配置已变化：立刻让浏览页重建挂载点缓存并重载当前目录，
      // 否则浏览页仍按旧配置枚举 → 加密目录显示密文名。
      try {
        context.read<FileManagerProvider>().refreshCryptMountPoints();
      } catch (_) {}
      Navigator.pop(context, true);
    }
  }

  /// 移除历史遗留的「整机根目录」级别挂载点（错误配置）
  Future<void> _removeLegacyRootMounts() async {
    try {
      final mounts = await CryptMountService.loadMountPoints();
      var changed = false;
      mounts.removeWhere((m) {
        final isRoot = CryptMountService.isStorageRootPath(m.physicalPath);
        if (isRoot) changed = true;
        return isRoot;
      });
      if (changed) await CryptMountService.saveMountPoints(mounts);
    } catch (_) {}
  }

  /// 统一的输入框外观：圆角淡填充 + 细描边，与保险箱首页的卡片风格一致
  InputDecoration _fieldDecoration({
    required ThemeData theme,
    required bool isDark,
    required IconData icon,
    String? hint,
    Widget? suffix,
  }) {
    final radius = BorderRadius.circular(12);
    OutlineInputBorder border(Color color, double width) => OutlineInputBorder(
      borderRadius: radius,
      borderSide: BorderSide(color: color, width: width),
    );

    return InputDecoration(
      hintText: hint,
      prefixIcon: Icon(
        icon,
        size: 20,
        color: theme.colorScheme.onSurface.withOpacity(0.55),
      ),
      suffixIcon: suffix,
      filled: true,
      fillColor: isDark
          ? Colors.white.withOpacity(0.03)
          : Colors.black.withOpacity(0.02),
      border: border(theme.colorScheme.outline.withOpacity(0.18), 1),
      enabledBorder: border(theme.colorScheme.outline.withOpacity(0.18), 1),
      focusedBorder: border(theme.colorScheme.primary, 1.5),
      errorBorder: border(theme.colorScheme.error.withOpacity(0.6), 1),
      focusedErrorBorder: border(theme.colorScheme.error, 1.5),
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final l10n = L10n.of(context);

    // 背景与保险箱首页保持完全一致的渐变（透明 Scaffold 叠在渐变容器上，
    // 让 AppBar 也透出渐变，避免顶部出现一条突兀的纯色分界）。
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: isDark
              ? [
                  const Color(0xFF0B0F19),
                  const Color(0xFF111827),
                  const Color(0xFF030712),
                ]
              : [
                  theme.colorScheme.primaryContainer.withOpacity(0.3),
                  theme.colorScheme.surface,
                  theme.colorScheme.surface,
                ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          elevation: 0,
          title: Text(
            _isProfileEdit
                ? l10n.crypt_profile_title_edit
                : (_isProfileCreate
                    ? l10n.crypt_profile_title_new
                    : l10n.crypt_set_master_password),
          ),
        ),
        body: Form(
          key: _formKey,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
            children: [
              // 顶部说明卡：与保险箱首页的提示卡风格一致
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 12,
                ),
                decoration: BoxDecoration(
                  color: theme.colorScheme.primary.withOpacity(
                    isDark ? 0.12 : 0.07,
                  ),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      Icons.info_outline_rounded,
                      size: 18,
                      color: theme.colorScheme.primary,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        l10n.crypt_master_banner,
                        style: TextStyle(
                          fontSize: 12.5,
                          height: 1.45,
                          color: theme.colorScheme.onSurface.withOpacity(0.75),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 18),

              // 加密名称（配置档案的唯一标识）
              _buildLabel(l10n.crypt_profile_name, theme),
              TextFormField(
                controller: _nameController,
                enabled: true,
                decoration: _fieldDecoration(
                  theme: theme,
                  isDark: isDark,
                  icon: Icons.badge_outlined,
                  hint: l10n.crypt_profile_name_hint,
                ),
                validator: (value) {
                  final name = value?.trim() ?? '';
                  if (name.isEmpty) {
                    return l10n.crypt_profile_name_required;
                  }
                  if (CryptProfileService.nameExistsIn(
                    _profiles,
                    name,
                    exceptId: widget.existingProfile?.id,
                  )) {
                    return l10n.crypt_profile_name_duplicate;
                  }
                  return null;
                },
              ),
              const SizedBox(height: 16),

              // 密码
              _buildLabel(l10n.crypt_field_password, theme),
              TextFormField(
                controller: _passwordController,
                obscureText: !_showPassword,
                readOnly: _isProfileEdit,
                decoration: _fieldDecoration(
                  theme: theme,
                  isDark: isDark,
                  icon: Icons.lock_outline_rounded,
                  suffix: _isProfileEdit
                      ? Icon(
                          Icons.lock_outline,
                          size: 18,
                          color: theme.colorScheme.onSurface.withOpacity(0.4),
                        )
                      : IconButton(
                          icon: Icon(
                            _showPassword
                                ? Icons.visibility_off_outlined
                                : Icons.visibility_outlined,
                            size: 20,
                          ),
                          onPressed: () =>
                              setState(() => _showPassword = !_showPassword),
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

              // 确认密码（编辑档案时无需重复确认）
              if (!_isProfileEdit) ...[
                _buildLabel(l10n.crypt_field_confirm_password, theme),
                TextFormField(
                  controller: _confirmPasswordController,
                  obscureText: !_showPassword,
                  decoration: _fieldDecoration(
                    theme: theme,
                    isDark: isDark,
                    icon: Icons.lock_outline_rounded,
                  ),
                  validator: (value) {
                    if (value != _passwordController.text) {
                      return l10n.crypt_error_password_mismatch;
                    }
                    return null;
                  },
                ),
                const SizedBox(height: 16),
              ],

              // 加盐
              _buildLabel(l10n.crypt_field_salt, theme),
              TextField(
                controller: _saltController,
                readOnly: _isProfileEdit,
                decoration: _fieldDecoration(
                  theme: theme,
                  isDark: isDark,
                  icon: Icons.shield_outlined,
                  hint: _isProfileEdit
                      ? l10n.crypt_profile_credential_locked
                      : l10n.crypt_field_salt_hint,
                ),
              ),
              if (_isProfileEdit) ...[
                const SizedBox(height: 6),
                Padding(
                  padding: const EdgeInsets.only(left: 4),
                  child: Text(
                    l10n.crypt_profile_credential_locked_desc,
                    style: TextStyle(
                      fontSize: 11.5,
                      color: theme.colorScheme.onSurface.withOpacity(0.55),
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 16),

              // 加密后缀
              _buildLabel(l10n.crypt_field_suffix, theme),
              TextField(
                controller: _suffixController,
                decoration: _fieldDecoration(
                  theme: theme,
                  isDark: isDark,
                  icon: Icons.extension_outlined,
                ),
              ),
              const SizedBox(height: 16),

              // 文件名加密（下拉选择）
              _buildLabel(l10n.crypt_field_filename_enc, theme),
              DropdownButtonFormField<FilenameEncryption>(
                value: _filenameEncryption,
                isExpanded: true,
                decoration: _fieldDecoration(
                  theme: theme,
                  isDark: isDark,
                  icon: Icons.vpn_key_outlined,
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
                isExpanded: true,
                decoration: _fieldDecoration(
                  theme: theme,
                  isDark: isDark,
                  icon: Icons.folder_copy_outlined,
                ),
                items: [
                  DropdownMenuItem<bool>(
                    value: true,
                    child: Text(l10n.crypt_dirname_enc_yes),
                  ),
                  DropdownMenuItem<bool>(
                    value: false,
                    child: Text(l10n.crypt_dirname_enc_no),
                  ),
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
                isExpanded: true,
                decoration: _fieldDecoration(
                  theme: theme,
                  isDark: isDark,
                  icon: Icons.code_outlined,
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
              // 设为默认档案
              ...[
                const SizedBox(height: 4),
                Container(
                  decoration: BoxDecoration(
                    color: isDark
                        ? Colors.white.withOpacity(0.03)
                        : Colors.black.withOpacity(0.02),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: theme.colorScheme.outline.withOpacity(0.18),
                    ),
                  ),
                  child: SwitchListTile(
                    value: _setAsDefault,
                    onChanged: (v) => setState(() => _setAsDefault = v),
                    title: Text(
                      l10n.crypt_profile_set_default,
                      style: const TextStyle(fontSize: 14),
                    ),
                    subtitle: Text(
                      l10n.crypt_profile_set_default_desc,
                      style: TextStyle(
                        fontSize: 11.5,
                        color: theme.colorScheme.onSurface.withOpacity(0.55),
                      ),
                    ),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 14),
                  ),
                ),
              ],
              const SizedBox(height: 26),

              // 保存按钮：与保险箱解锁页的主按钮风格一致
              SizedBox(
                width: double.infinity,
                height: 52,
                child: FilledButton.icon(
                  onPressed: _save,
                  icon: const Icon(Icons.check_rounded, size: 20),
                  label: Text(l10n.ui_save),
                  style: FilledButton.styleFrom(
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                    textStyle: const TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 15,
                    ),
                  ),
                ),
              ),
            ],
          ),
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
