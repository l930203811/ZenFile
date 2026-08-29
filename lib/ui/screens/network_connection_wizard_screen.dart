import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:file_picker/file_picker.dart';
import '../../core/icon_fonts/broken_icons.dart';
import '../../models/network_connection_model.dart';
import '../../providers/file_manager_provider.dart';
import '../../services/network_connections_service.dart';
import '../../services/remote/remote_client.dart';
import '../../services/remote/ftp_client.dart';
import '../../services/remote/sftp_client.dart';
import '../../services/remote/webdav_client.dart';
import '../../services/remote/lan_client.dart';
import 'package:zenfile/l10n/generated/app_localizations.dart';

class NetworkConnectionWizardScreen extends StatefulWidget {
  final NetworkConnectionModel? existingConnection;
  final Function(int)? onNavigateTab;
  const NetworkConnectionWizardScreen({super.key, this.existingConnection, this.onNavigateTab});

  @override
  State<NetworkConnectionWizardScreen> createState() => _NetworkConnectionWizardScreenState();
}

class _NetworkConnectionWizardScreenState extends State<NetworkConnectionWizardScreen> {
  final PageController _pageController = PageController();
  int _currentStep = 0;

  // Connection parameters
  String _selectedType = '';
  final _nameController = TextEditingController();
  final _hostController = TextEditingController();
  final _portController = TextEditingController();
  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();
  String _webdavProtocol = 'http';
  final _pathController = TextEditingController(text: '/');

  // SSH 密钥认证相关
  String? _sshKeyPath;
  final _sshKeyPasswordController = TextEditingController();
  bool _obscureSshKeyPassword = true;

  // Testing steps states
  bool _isTesting = false;
  int _testStepIndex = 0;

  // UI states
  bool _obscurePassword = true;

  @override
  void initState() {
    super.initState();
    final existing = widget.existingConnection;
    if (existing != null) {
      _selectedType = existing.type;
      _nameController.text = existing.name;
      _hostController.text = existing.host;
      _portController.text = existing.port.toString();
      _usernameController.text = existing.username;
      _passwordController.text = existing.password;
      _pathController.text = existing.rootPath;
      _sshKeyPath = existing.sshKeyPath;
      _sshKeyPasswordController.text = existing.sshKeyPassword ?? '';
      if (existing.type == 'WebDav') {
        _webdavProtocol = existing.protocol;
      }
      // 编辑模式: 跳过协议选择步骤，直接进入凭据输入页，
      // 避免用户再次点击协议时触发 _selectProtocol() 重置端口/名称。
      _currentStep = 1;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _pageController.hasClients) {
          _pageController.jumpToPage(1);
        }
      });
    }
  }

  @override
  void dispose() {
    _pageController.dispose();
    _nameController.dispose();
    _hostController.dispose();
    _portController.dispose();
    _usernameController.dispose();
    _passwordController.dispose();
    _pathController.dispose();
    _sshKeyPasswordController.dispose();
    super.dispose();
  }

  void _nextStep() {
    if (_currentStep < 2) {
      setState(() {
        _currentStep++;
      });
      _pageController.animateToPage(
        _currentStep,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeInOut,
      );
    }
  }

  void _prevStep() {
    if (_currentStep > 0) {
      setState(() {
        _currentStep--;
      });
      _pageController.animateToPage(
        _currentStep,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeInOut,
      );
    } else {
      Navigator.pop(context);
    }
  }

  void _selectProtocol(String protocol) {
    if (protocol == 'SAF Folder') {
      _requestSafAndSave();
      return;
    }
    setState(() {
      _selectedType = protocol;
      _nameController.text = '$protocol ${L10n.of(context).ui_connection_suffix}';

      // Set default ports
      if (protocol == 'FTP') {
        _portController.text = '21';
      } else if (protocol == 'SFTP') {
        _portController.text = '22';
      } else if (protocol == L10n.of(context).smb) {
        _portController.text = '445';
        _pathController.text = '';
      } else if (protocol == 'WebDav') {
        _webdavProtocol = 'http';
        _portController.text = '80';
        _pathController.text = '/';
      }
    });
    _nextStep();
  }

  Future<void> _requestSafAndSave() async {
    try {
      const safChannel = MethodChannel('com.sequl.zenfile/saf');
      final result = await safChannel.invokeMethod('requestSafDirectory');
      if (result == null) {
        // User cancelled picker
        return;
      }
      final map = Map<String, dynamic>.from(result);
      final String uri = map['uri'] as String;
      final String name = map['name'] as String;

      final connection = NetworkConnectionModel(
        id: DateTime.now().millisecondsSinceEpoch.toString(),
        name: name,
        type: 'saf',
        host: '',
        port: 0,
        username: '',
        password: '',
        rootPath: uri,
        protocol: 'saf',
      );

      await NetworkConnectionsService.saveConnection(connection);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Row(
              children: [
                const Icon(Broken.tick_circle, color: Colors.white),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '"$name" 添加成功！',
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
            behavior: SnackBarBehavior.floating,
            backgroundColor: Theme.of(context).colorScheme.primary,
          ),
        );
        // Auto-open the remote server after successful connection
        if (widget.onNavigateTab != null) {
          final remoteClient = FileManagerProvider.createRemoteClient(connection);
          try {
            await remoteClient.connect();
            if (mounted) {
              final provider = context.read<FileManagerProvider>();
              await provider.openRemoteTab(remoteClient, connection);
              widget.onNavigateTab!.call(1);
              Navigator.pop(context, true);
            }
          } catch (_) {
            if (mounted) {
              Navigator.pop(context, true);
            }
          }
        } else {
          Navigator.pop(context, true);
        }
      }
    } catch (e) {
      if (mounted) {
        if (e is PlatformException && e.code == 'ACTIVITY_NOT_FOUND') {
          showDialog(
            context: context,
            builder: (ctx) => AlertDialog(
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
              title: const Row(
                children: [
                  Icon(Icons.warning_amber_rounded, color: Colors.orange),
                  SizedBox(width: 8),
                  Text('系统应用已禁用', style: TextStyle(fontFamily: 'LexendDeca', fontSize: 18, fontWeight: FontWeight.bold)),
                ],
              ),
              content: const Text(
                '您的设备没有启用默认的系统文件/文档应用（DocumentsUI），'
                '这是 Android 选择和挂载目录所必需的。\n\n'
                '请检查"文件"或"文档"系统应用是否在设备设置中被禁用，'
                '或启用它以使用 SAF 目录功能。',
                style: TextStyle(fontSize: 14),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('确定', style: TextStyle(fontWeight: FontWeight.bold)),
                ),
              ],
            ),
          );
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('请求 SAF 文件夹失败：{e}'),
              backgroundColor: Colors.redAccent,
              behavior: SnackBarBehavior.floating,
            ),
          );
        }
      }
    }
  }

  // Build a valid RemoteClient from current form inputs (or null if missing required fields).
  RemoteClient? _buildCurrentClient({String? outHost, int? outPort, String? outUser, String? outPwd, String? outPath}) {
    final host = (outHost ?? _hostController.text).trim();
    final port = int.tryParse((outPort != null ? outPort.toString() : _portController.text).trim());
    if (host.isEmpty || port == null) return null;
    final username = (outUser ?? _usernameController.text).trim();
    final password = (outPwd ?? _passwordController.text).trim();
    final path = (_selectedType == 'WebDav' || _selectedType == L10n.of(context).smb)
        ? (((outPath != null ? outPath : _pathController.text).trim().isEmpty) ? '/' : (outPath != null ? outPath : _pathController.text).trim())
        : '/';

    // 确定认证方式
    final authMethod = (_selectedType == 'SFTP' && _sshKeyPath != null) ? 'key' : 'password';

    if (_selectedType == 'FTP') {
      return FtpRemoteClient(host: host, port: port, username: username, password: password);
    } else if (_selectedType == 'SFTP') {
      return SftpRemoteClient(
        host: host,
        port: port,
        username: username,
        password: password,
        sshKeyPath: _sshKeyPath,
        sshKeyPassword: _sshKeyPasswordController.text.trim().isEmpty ? null : _sshKeyPasswordController.text,
        authMethod: authMethod,
      );
    } else if (_selectedType == 'WebDav') {
      return WebDavRemoteClient(
        host: host,
        port: port,
        username: username,
        password: password,
        protocol: _webdavProtocol,
        rootPath: path,
      );
    } else if (_selectedType == L10n.of(context).smb) {
      return LanClient(host: host, port: port, username: username, password: password);
    }
    return null;
  }

  String? _validateBasicForm() {
    final l10n = L10n.of(context);
    if (_nameController.text.trim().isEmpty) return l10n.msg65c7ecb6;
    if (_hostController.text.trim().isEmpty) return l10n.msg69e3963c;
    return null;
  }

  // --- Test connection: show modal progress, connect/disconnect, then show result dialog ---
  Future<void> _testConnection() async {
    if (_selectedType == 'WebDav') _sanitizeWebdavFields();
    final basicErr = _validateBasicForm();
    if (basicErr != null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(basicErr)));
      return;
    }
    final client = _buildCurrentClient();
    if (client == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(L10n.of(context).msg69e3963c)),
      );
      return;
    }
    final l10n = L10n.of(context);
    // Show loading dialog
    final loadingKey = GlobalKey<State>();
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        key: loadingKey,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        content: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 22, height: 22,
              child: CircularProgressIndicator(strokeWidth: 2.5,
                valueColor: AlwaysStoppedAnimation<Color>(Theme.of(context).colorScheme.primary)),
            ),
            const SizedBox(width: 14),
            Text(l10n.msg3005ba4d, style: const TextStyle(fontSize: 14)),
          ],
        ),
      ),
    );

    String? errReason;
    try {
      await client.connect().timeout(const Duration(seconds: 15));
      try { await client.disconnect(); } catch (_) {}
    } catch (e) {
      errReason = e.toString();
    }

    if (mounted) {
      Navigator.of(context, rootNavigator: true).pop(); // close loading
      final theme = Theme.of(context);
      if (errReason == null) {
        showDialog(
          context: context,
          builder: (ctx) => AlertDialog(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
            title: Row(
              children: [
                const Icon(Icons.check_circle, color: Colors.green, size: 24),
                const SizedBox(width: 8),
                Text(l10n.ui_test_success,
                  style: const TextStyle(fontFamily: 'LexendDeca', fontSize: 18, fontWeight: FontWeight.bold)),
              ],
            ),
            content: Text(l10n.ui_test_success_desc, style: const TextStyle(fontSize: 14)),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                style: TextButton.styleFrom(foregroundColor: theme.colorScheme.primary),
                child: Text(MaterialLocalizations.of(context).okButtonLabel,
                  style: const TextStyle(fontWeight: FontWeight.bold)),
              ),
            ],
          ),
        );
      } else {
        showDialog(
          context: context,
          builder: (ctx) => AlertDialog(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
            title: Row(
              children: [
                const Icon(Icons.error, color: Colors.redAccent, size: 24),
                const SizedBox(width: 8),
                Text(l10n.ui_test_failed,
                  style: const TextStyle(fontFamily: 'LexendDeca', fontSize: 18, fontWeight: FontWeight.bold)),
              ],
            ),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('${l10n.ui_test_failed_reason}：',
                  style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                const SizedBox(height: 6),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: Colors.redAccent.withOpacity(0.08),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(errReason!,
                    style: TextStyle(fontSize: 12.5, color: theme.colorScheme.onSurface.withOpacity(0.85),
                      fontFamily: 'monospace')),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                style: TextButton.styleFrom(foregroundColor: theme.colorScheme.primary),
                child: Text(MaterialLocalizations.of(context).okButtonLabel,
                  style: const TextStyle(fontWeight: FontWeight.bold)),
              ),
            ],
          ),
        );
      }
    }
  }

  // --- Save connection (regardless of test result) and close wizard ---
  Future<void> _saveConnection() async {
    if (_selectedType == 'WebDav') _sanitizeWebdavFields();
    final basicErr = _validateBasicForm();
    if (basicErr != null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(basicErr)));
      return;
    }
    final port = int.tryParse(_portController.text.trim()) ?? 21;
    final host = _hostController.text.trim();
    final username = _usernameController.text.trim();
    final password = _passwordController.text.trim();
    final path = (_selectedType == 'WebDav' || _selectedType == L10n.of(context).smb)
        ? (_pathController.text.trim().isEmpty ? '/' : _pathController.text.trim())
        : '/';

    // 确定认证方式
    final authMethod = (_selectedType == 'SFTP' && _sshKeyPath != null) ? 'key' : 'password';

    final connection = NetworkConnectionModel(
      id: widget.existingConnection?.id ?? DateTime.now().millisecondsSinceEpoch.toString(),
      name: _nameController.text.trim(),
      type: _selectedType,
      host: host,
      port: port,
      username: username,
      password: password,
      rootPath: path,
      protocol: _selectedType == 'WebDav' ? _webdavProtocol : 'http',
      sshKeyPath: _sshKeyPath,
      sshKeyPassword: _sshKeyPasswordController.text.trim().isEmpty ? null : _sshKeyPasswordController.text,
      authMethod: authMethod,
    );

    if (widget.existingConnection != null) {
      await NetworkConnectionsService.deleteConnection(widget.existingConnection!.id);
    }
    await NetworkConnectionsService.saveConnection(connection);

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Row(
            children: [
              const Icon(Broken.tick_circle, color: Colors.white),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '"${connection.name}" ${L10n.of(context).ui_save}！',
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          behavior: SnackBarBehavior.floating,
          backgroundColor: Theme.of(context).colorScheme.primary,
        ),
      );
      Navigator.pop(context, true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new_rounded, size: 20),
          onPressed: _prevStep,
        ),
        title: Text(
          L10n.of(context).ui_remote_connection,
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        actions: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16.0),
            child: Center(
              child: Text(
            L10n.of(context).ui_step_n_of_3(_currentStep + 1),
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                  color: theme.colorScheme.primary,
                ),
              ),
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          // Step progress indicator bar
          Container(
            height: 4,
            width: double.infinity,
            color: theme.colorScheme.onSurface.withOpacity(0.05),
            child: Row(
              children: [
                Expanded(
                  child: Container(
                    height: double.infinity,
                    color: _currentStep >= 0 ? theme.colorScheme.primary : Colors.transparent,
                  ),
                ),
                Expanded(
                  child: Container(
                    height: double.infinity,
                    color: _currentStep >= 1 ? theme.colorScheme.primary : Colors.transparent,
                  ),
                ),
                Expanded(
                  child: Container(
                    height: double.infinity,
                    color: _currentStep >= 2 ? theme.colorScheme.primary : Colors.transparent,
                  ),
                ),
              ],
            ),
          ),

          // Main Pages contents
          Expanded(
            child: PageView(
              controller: _pageController,
              physics: const NeverScrollableScrollPhysics(),
              children: [
                _buildProtocolSelectionStep(theme),
                _buildCredentialsStep(theme, isDark),
                _buildTestingStep(theme, isDark),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // --- Step 1: Protocol Grid Selection ---
  Widget _buildProtocolSelectionStep(ThemeData theme) {
    final protocols = [
      {'name': L10n.of(context).smb, 'desc': L10n.of(context).ui_smb_desc, 'color': Color(0xFF5B21B6)},
      {'name': 'FTP', 'desc': L10n.of(context).msg25557d1f, 'color': Color(0xFFF97316)},
      {'name': 'SFTP', 'desc': L10n.of(context).ssh, 'color': Color(0xFF0D9488)},
      {'name': 'WebDav', 'desc': L10n.of(context).http, 'color': Color(0xFFE11D48)},
      {'name': 'SAF Folder', 'desc': L10n.of(context).androidsd, 'color': Color(0xFF0284C7)},
    ];

    return ScrollConfiguration(
      behavior: const ScrollBehavior().copyWith(overscroll: false),
      child: ListView(
        padding: const EdgeInsets.all(20.0),
        children: [
          Text(
            L10n.of(context).ui_choose_network_service,
            style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold, fontFamily: 'LexendDeca'),
          ),
          const SizedBox(height: 6),
          Text(
            L10n.of(context).naszenfile,
            style: TextStyle(fontSize: 13, color: theme.colorScheme.onSurface.withOpacity(0.6)),
          ),
          const SizedBox(height: 24),
          GridView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            itemCount: protocols.length,
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 2,
              mainAxisSpacing: 14,
              crossAxisSpacing: 14,
              childAspectRatio: 1.15,
            ),
            itemBuilder: (context, index) {
              final protocol = protocols[index];
              final name = protocol['name'] as String;
              final desc = protocol['desc'] as String;
              final color = protocol['color'] as Color;

              return Card(
                elevation: 2,
                margin: EdgeInsets.zero,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(20),
                  side: BorderSide(color: theme.colorScheme.primary.withOpacity(0.08)),
                ),
                clipBehavior: Clip.antiAlias,
                child: InkWell(
                  onTap: () => _selectProtocol(name),
                  child: Container(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: [
                          color.withOpacity(0.06),
                          color.withOpacity(0.01),
                        ],
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                      ),
                    ),
                    padding: const EdgeInsets.all(16.0),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Container(
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                            color: color.withOpacity(0.12),
                            borderRadius: BorderRadius.circular(14),
                          ),
                          child: _buildProtocolIcon(name, size: 22, customColor: color),
                        ),
                        const Spacer(),
                        Text(
                          name,
                          style: const TextStyle(
                            fontSize: 14.5,
                            fontWeight: FontWeight.bold,
                            fontFamily: 'LexendDeca',
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          desc,
                          style: TextStyle(
                            fontSize: 10.5,
                            color: theme.colorScheme.onSurface.withOpacity(0.5),
                            height: 1.2,
                          ),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        ],
      ),
    );
  }

  // --- Step 2: Configuration Fields Form ---
  Widget _buildCredentialsStep(ThemeData theme, bool isDark) {
    final l10n = L10n.of(context);
    final passwordSuffix = IconButton(
      icon: Icon(
        _obscurePassword ? Broken.eye_slash : Broken.eye,
        size: 18,
        color: theme.colorScheme.onSurface.withOpacity(0.5),
      ),
      onPressed: () => setState(() => _obscurePassword = !_obscurePassword),
      splashRadius: 20,
    );

    return ScrollConfiguration(
      behavior: const ScrollBehavior().copyWith(overscroll: false),
      child: ListView(
        padding: const EdgeInsets.all(24.0),
        children: [
          // Header
          Row(
            children: [
              _buildProtocolIcon(_selectedType, size: 30),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '$_selectedType ${l10n.cat_settings}',
                      style: const TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                        fontFamily: 'LexendDeca',
                      ),
                    ),
                    Text(
                      l10n.msg5c808d9a,
                      style: TextStyle(
                        fontSize: 12.5,
                        color: theme.colorScheme.onSurface.withOpacity(0.5),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 28),

          // Connection Nickname
          _buildInputLabel(l10n.ui_connection_name),
          _buildTextField(
            controller: _nameController,
            hint: l10n.nas,
            icon: Broken.tag,
          ),
          const SizedBox(height: 18),

          if (_selectedType == 'WebDav') ...[
            _buildInputLabel(l10n.ui_protocol),
            _buildProtocolToggle(theme),
            const SizedBox(height: 18),
          ],

          _buildInputLabel(l10n.msg5d57821d),
          _buildTextField(
            controller: _hostController,
            hint: _selectedType == 'WebDav' ? l10n.dav : l10n.naslocal,
            icon: Broken.global,
          ),
          const SizedBox(height: 18),

          _buildInputLabel(l10n.ui_port),
          _buildTextField(
            controller: _portController,
            hint: _selectedType == 'WebDav' ? '80' : '21',
            icon: Broken.hashtag,
            keyboardType: TextInputType.number,
          ),
          const SizedBox(height: 18),

          if (_selectedType == 'WebDav') ...[
            _buildInputLabel(l10n.ui_path_label),
            _buildTextField(
              controller: _pathController,
              hint: l10n.dav1,
              icon: Broken.folder_open,
            ),
            const SizedBox(height: 18),
          ] else if (_selectedType == l10n.smb) ...[
            _buildInputLabel(l10n.ui_share_name_optional),
            _buildTextField(
              controller: _pathController,
              hint: l10n.ui_share_name_hint,
              icon: Broken.folder_open,
            ),
            const SizedBox(height: 18),
          ],

          _buildInputLabel(l10n.ui_username_optional),
          _buildTextField(
            controller: _usernameController,
            hint: l10n.anonymousadmin,
            icon: Broken.user,
          ),
          const SizedBox(height: 18),

          _buildInputLabel(l10n.msgeec70cd2),
          _buildTextField(
            controller: _passwordController,
            hint: '••••••••',
            icon: Broken.lock,
            obscure: _obscurePassword,
            suffix: passwordSuffix,
          ),

          // SFTP SSH 密钥认证选项
          if (_selectedType == 'SFTP') ...[
            const SizedBox(height: 24),
            _buildSshKeySection(theme),
          ],

          const SizedBox(height: 40),

          // Three-button action bar: BACK (left) · TEST (center) · SAVE (right, primary)
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  style: OutlinedButton.styleFrom(
                    side: BorderSide(color: theme.colorScheme.outline.withOpacity(0.35)),
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                    foregroundColor: theme.colorScheme.onSurface,
                  ),
                  onPressed: _prevStep,
                  child: Text(l10n.ui_back,
                    style: const TextStyle(fontWeight: FontWeight.w600)),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    side: BorderSide(color: theme.colorScheme.primary.withOpacity(0.55)),
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                    foregroundColor: theme.colorScheme.primary,
                  ),
                  onPressed: _testConnection,
                  icon: const Icon(Broken.shield_tick, size: 18),
                  label: Text(l10n.ui_test,
                    style: const TextStyle(fontWeight: FontWeight.w700)),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: theme.colorScheme.primary,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                    elevation: 4,
                  ),
                  onPressed: _saveConnection,
                  icon: const Icon(Icons.save_rounded, size: 18, color: Colors.white),
                  label: Text(l10n.ui_save,
                    style: const TextStyle(fontWeight: FontWeight.w700, color: Colors.white)),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // --- Step 3: Connect and Diagnostics Live Validation Animation ---
  Widget _buildTestingStep(ThemeData theme, bool isDark) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Spacer(),
          Stack(
            alignment: Alignment.center,
            children: [
              Container(
                height: 130,
                width: 130,
                decoration: BoxDecoration(
                  color: theme.colorScheme.primary.withOpacity(0.04),
                  shape: BoxShape.circle,
                  border: Border.all(color: theme.colorScheme.primary.withOpacity(0.1), width: 1.5),
                ),
              ),
              SizedBox(
                height: 100,
                width: 100,
                child: CircularProgressIndicator(
                  strokeWidth: 4,
                  valueColor: AlwaysStoppedAnimation<Color>(theme.colorScheme.primary),
                  backgroundColor: theme.colorScheme.primary.withOpacity(0.1),
                ),
              ),
              Icon(
                _isTesting ? Broken.routing_2 : Broken.verify,
                size: 38,
                color: theme.colorScheme.primary,
              ),
            ],
          ),
          const SizedBox(height: 32),

          Text(
            L10n.of(context).msgf1fa9d44,
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.bold,
              color: theme.colorScheme.onSurface.withOpacity(0.9),
              fontFamily: 'LexendDeca',
            ),
          ),
          const SizedBox(height: 8),
          Text(
            L10n.of(context).selectedtype1(_selectedType),
            style: TextStyle(
              fontSize: 12.5,
              color: theme.colorScheme.onSurface.withOpacity(0.5),
            ),
            textAlign: TextAlign.center,
          ),

          const Spacer(),

          // Dynamic Diagnostic List
          Card(
            elevation: 0,
            color: isDark ? const Color(0xFF1E293B) : theme.colorScheme.primary.withOpacity(0.02),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(20),
              side: BorderSide(color: theme.colorScheme.primary.withOpacity(0.08)),
            ),
            child: Padding(
              padding: const EdgeInsets.all(20.0),
              child: Column(
                children: List.generate(4, (idx) {
                  final active = idx == _testStepIndex;
                  final done = idx < _testStepIndex;
                  final l10n = L10n.of(context);
                  final stepLabels = [
                    l10n.msgb5bc0bf1,
                    l10n.msgc3d4e5f6,
                    l10n.msg3005ba4d,
                    l10n.msgab36a8c6,
                  ];

                  Color itemColor;
                  IconData icon;

                  if (done) {
                    itemColor = Colors.green;
                    icon = Icons.check_circle;
                  } else if (active) {
                    itemColor = theme.colorScheme.primary;
                    icon = Icons.circle_outlined;
                  } else {
                    itemColor = theme.colorScheme.onSurface.withOpacity(0.25);
                    icon = Icons.radio_button_off_outlined;
                  }

                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8.0),
                    child: Row(
                      children: [
                        Icon(icon, color: itemColor, size: 18),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            stepLabels[idx],
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: active ? FontWeight.bold : FontWeight.normal,
                              color: active
                                  ? theme.colorScheme.onSurface.withOpacity(0.9)
                                  : theme.colorScheme.onSurface.withOpacity(done ? 0.6 : 0.35),
                            ),
                          ),
                        ),
                        if (active)
                          const SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                            ),
                          ),
                      ],
                    ),
                  );
                }),
              ),
            ),
          ),
          const Spacer(),
        ],
      ),
    );
  }

  // --- Helper Layout widgets ---

  /// 构建 SSH 密钥认证部分 UI
  Widget _buildSshKeySection(ThemeData theme) {
    final l10n = L10n.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 认证方式切换
        Row(
          children: [
            Expanded(
              child: _buildAuthMethodButton(
                theme: theme,
                label: l10n.ui_password_auth,
                isSelected: _sshKeyPath == null,
                onTap: () => setState(() => _sshKeyPath = null),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _buildAuthMethodButton(
                theme: theme,
                label: l10n.ui_ssh_key_auth,
                isSelected: _sshKeyPath != null,
                onTap: () => _selectSshKey(),
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),

        // 密钥文件选择
        if (_sshKeyPath != null) ...[
          _buildInputLabel(l10n.ui_private_key_file),
          InkWell(
            onTap: _selectSshKey,
            borderRadius: BorderRadius.circular(12),
            child: Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: isDark ? const Color(0xFF1E293B) : theme.colorScheme.primary.withOpacity(0.04),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: theme.colorScheme.primary.withOpacity(0.3)),
              ),
              child: Row(
                children: [
                  Icon(Broken.key, size: 20, color: theme.colorScheme.primary),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      _sshKeyPath!,
                      style: const TextStyle(fontSize: 13),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close, size: 18),
                    onPressed: () => setState(() => _sshKeyPath = null),
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
        ],

        // 密钥密码短语（可选）
        if (_sshKeyPath != null) ...[
          _buildInputLabel('${l10n.ui_passphrase} (${l10n.ui_optional})'),
          _buildTextField(
            controller: _sshKeyPasswordController,
            hint: '••••••••',
            icon: Broken.lock,
            obscure: _obscureSshKeyPassword,
            suffix: IconButton(
              icon: Icon(
                _obscureSshKeyPassword ? Broken.eye_slash : Broken.eye,
                size: 18,
                color: theme.colorScheme.onSurface.withOpacity(0.5),
              ),
              onPressed: () => setState(() => _obscureSshKeyPassword = !_obscureSshKeyPassword),
              splashRadius: 20,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            l10n.ui_ssh_key_password_hint,
            style: TextStyle(fontSize: 11, color: theme.colorScheme.onSurface.withOpacity(0.5)),
          ),
        ],
      ],
    );
  }

  Widget _buildAuthMethodButton({
    required ThemeData theme,
    required String label,
    required bool isSelected,
    required VoidCallback onTap,
  }) {
    final isDark = theme.brightness == Brightness.dark;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(vertical: 12),
        decoration: BoxDecoration(
          color: isSelected
              ? theme.colorScheme.primary.withOpacity(0.12)
              : (isDark ? const Color(0xFF1E293B) : theme.colorScheme.primary.withOpacity(0.04)),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: isSelected ? theme.colorScheme.primary : theme.colorScheme.outline.withOpacity(0.1),
            width: isSelected ? 1.5 : 1,
          ),
        ),
        alignment: Alignment.center,
        child: Text(
          label,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.bold,
            color: isSelected ? theme.colorScheme.primary : theme.colorScheme.onSurface.withOpacity(0.6),
          ),
        ),
      ),
    );
  }

  Future<void> _selectSshKey() async {
    final result = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['pem', 'key', 'pub'],
      allowMultiple: false,
    );

    if (result != null && result.files.single.path != null) {
      setState(() {
        _sshKeyPath = result.files.single.path!;
      });
    }
  }

  Widget _buildInputLabel(String label) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6.0, left: 4.0),
      child: Text(
        label,
        style: const TextStyle(
          fontSize: 12.5,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.2,
        ),
      ),
    );
  }

  Widget _buildTextField({
    required TextEditingController controller,
    required String hint,
    required IconData icon,
    bool obscure = false,
    TextInputType keyboardType = TextInputType.text,
    Widget? suffix,
  }) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return TextField(
      controller: controller,
      obscureText: obscure,
      keyboardType: keyboardType,
      style: const TextStyle(fontSize: 14),
      decoration: InputDecoration(
        hintText: hint,
        hintStyle: TextStyle(color: theme.colorScheme.onSurface.withOpacity(0.35)),
        prefixIcon: Icon(icon, size: 18, color: theme.colorScheme.onSurface.withOpacity(0.5)),
        suffixIcon: suffix,
        filled: true,
        fillColor: isDark ? const Color(0xFF1E293B) : theme.colorScheme.primary.withOpacity(0.04),
        contentPadding: const EdgeInsets.symmetric(vertical: 14, horizontal: 16),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide(color: theme.colorScheme.outline.withOpacity(0.1)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide(color: theme.colorScheme.primary.withOpacity(0.8), width: 1.5),
        ),
      ),
    );
  }

  Widget _buildProtocolIcon(String name, {required double size, Color? customColor}) {
    IconData iconData;
    Color color;
    final smbLabel = L10n.of(context).smb;

    if (name == smbLabel) {
      iconData = Icons.dns_rounded;
      color = const Color(0xFF5B21B6);
    } else if (name == 'FTP') {
      iconData = Icons.swap_horizontal_circle_rounded;
      color = const Color(0xFFF97316);
    } else if (name == 'SFTP') {
      iconData = Icons.vpn_lock_rounded;
      color = const Color(0xFF0D9488);
    } else if (name == 'WebDav') {
      iconData = Icons.web_rounded;
      color = const Color(0xFFE11D48);
    } else if (name == 'SAF Folder' || name == 'saf') {
      iconData = Icons.sd_card_rounded;
      color = const Color(0xFF0284C7);
    } else {
      iconData = Broken.wifi;
      color = Colors.blue;
    }

    return Icon(
      iconData,
      size: size,
      color: customColor ?? color,
    );
  }

  Widget _buildProtocolToggle(ThemeData theme) {
    return Row(
      children: [
        Expanded(
          child: _buildProtocolButton(
            theme: theme,
            label: 'HTTP',
            isSelected: _webdavProtocol == 'http',
            onTap: () {
              setState(() {
                _webdavProtocol = 'http';
                if (_portController.text == '443' || _portController.text.isEmpty) {
                  _portController.text = '80';
                }
              });
            },
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: _buildProtocolButton(
            theme: theme,
            label: 'HTTPS (Secure)',
            isSelected: _webdavProtocol == 'https',
            onTap: () {
              setState(() {
                _webdavProtocol = 'https';
                if (_portController.text == '80' || _portController.text.isEmpty) {
                  _portController.text = '443';
                }
              });
            },
          ),
        ),
      ],
    );
  }

  Widget _buildProtocolButton({
    required ThemeData theme,
    required String label,
    required bool isSelected,
    required VoidCallback onTap,
  }) {
    final isDark = theme.brightness == Brightness.dark;
    final activeColor = theme.colorScheme.primary;
    
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(vertical: 14),
        decoration: BoxDecoration(
          color: isSelected
              ? activeColor.withOpacity(0.12)
              : (isDark ? const Color(0xFF1E293B) : theme.colorScheme.primary.withOpacity(0.04)),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: isSelected ? activeColor : theme.colorScheme.outline.withOpacity(0.1),
            width: isSelected ? 1.5 : 1,
          ),
        ),
        alignment: Alignment.center,
        child: Text(
          label,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.bold,
            color: isSelected ? activeColor : theme.colorScheme.onSurface.withOpacity(0.6),
          ),
        ),
      ),
    );
  }

  void _sanitizeWebdavFields() {
    if (_selectedType != 'WebDav') return;
    
    var hostInput = _hostController.text.trim();
    if (hostInput.isEmpty) return;

    String protocol = _webdavProtocol;
    String host = hostInput;
    String portStr = _portController.text.trim();
    String path = _pathController.text.trim();

    // 1. Extract protocol if present
    if (host.startsWith('http://')) {
      protocol = 'http';
      host = host.substring(7);
    } else if (host.startsWith('https://')) {
      protocol = 'https';
      host = host.substring(8);
    }

    // 2. Extract port and path if present (e.g. 192.168.100.1:5244/dav)
    // Find the first '/' to separate host/port from path
    final slashIdx = host.indexOf('/');
    if (slashIdx != -1) {
      path = host.substring(slashIdx);
      host = host.substring(0, slashIdx);
    }

    // Check if host has a port (e.g. 192.168.100.1:5244)
    final colonIdx = host.indexOf(':');
    if (colonIdx != -1) {
      portStr = host.substring(colonIdx + 1);
      host = host.substring(0, colonIdx);
    }

    // Update controllers and state variables
    setState(() {
      _webdavProtocol = protocol;
      _hostController.text = host;
      _portController.text = portStr.isNotEmpty ? portStr : (protocol == 'https' ? '443' : '80');
      _pathController.text = path.isNotEmpty ? path : '/';
    });
  }
}
