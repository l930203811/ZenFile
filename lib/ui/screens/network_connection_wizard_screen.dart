import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:file_picker/file_picker.dart';
import '../../core/icon_fonts/broken_icons.dart';
import '../../models/network_connection_model.dart';
import '../../providers/file_manager_provider.dart';
import '../../services/network_connections_service.dart';
// ⛔ 聚合网盘暂时下线：网盘登录态存储 / 登录页的 import 一并注释。
// import '../../services/netdisk_auth_store.dart';
import '../../services/remote/remote_client.dart';
import '../../services/remote/ftp_client.dart';
import '../../services/remote/sftp_client.dart';
import '../../services/remote/webdav_client.dart';
import '../../services/remote/lan_client.dart';
import '../../services/remote/remote_error_localizer.dart';
// import 'netdisk_login_screen.dart';
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

  /// 编辑的是 SAF 连接（issue #44）：SAF 来自 Android 存储访问框架，
  /// 没有 host/port/凭据概念，编辑页仅提供改名。
  bool _isEditingSaf = false;

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

  // SMB 匿名登录：勾选后用户名/密码不可输入，连接时以空凭据走 guest 匿名会话
  bool _anonymousLogin = false;

  // SMB 共享名扫描状态
  bool _isScanningLan = false;
  List<SmbDiscoveredDevice> _lanDevices = const [];
  String? _lanScanError;

  /// SMB/局域网类型判定（编辑老连接必须容错）。
  ///
  /// 先按关键字匹配（覆盖现版本的本地化标签「局域网/SMB」「LAN/SMB」、以及历史
  /// 遗留的 'SMB'/'Samba'/'CIFS'）；再兜底：凡不属于 FTP/SFTP/WebDav/SAF 的类型
  /// 一律按 SMB 处理。此前用 `_selectedType == l10n.smb` 精确比对本地化标签，
  /// 导致编辑历史连接时 SMB 专属 UI（匿名勾选、共享名、局域网扫描）整块消失。
  bool get _isSmbSelected {
    if (_selectedType.isEmpty) return false;
    final t = _selectedType.toLowerCase().trim();
    if (t.contains('smb') || t.contains('samba') || t == 'cifs') return true;
    if (t == 'ftp' || t == 'sftp' || t.contains('ftp')) return false;
    if (t == 'webdav' || t.contains('dav')) return false;
    if (t == 'saf' || t.contains('saf')) return false;
    return true; // 未知/历史类型兜底视为 SMB
  }

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
      // 编辑已有连接：**不再**按「用户名为空」自动勾选「匿名登录」。
      // 匿名必须由用户显式勾选 —— 否则打开一个历史匿名连接时，用户会
      // 毫无察觉地继续以 guest/匿名会话连接，服务器进而隐藏部分共享
      // （见 _validateBasicForm 的说明）。勾选框仅 SMB 类型显示。
      _pathController.text = existing.rootPath;
      _sshKeyPath = existing.sshKeyPath;
      _sshKeyPasswordController.text = existing.sshKeyPassword ?? '';
      if (existing.type == 'WebDav') {
        _webdavProtocol = existing.protocol;
      }
      if (existing.type.toLowerCase() == 'saf') {
        // SAF 连接（issue #44）：没有 host/port 等连接参数，编辑页只提供
        // 改名 —— 复用完整向导会强制要求主机地址，导致 SAF 远程无法编辑。
        _isEditingSaf = true;
        _currentStep = 0;
      } else {
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

//   /// 添加聚合网盘（夸克 / 阿里云盘）：网页登录 → 保存连接与登录态 →
//   /// 关闭向导返回远程列表（列表自动刷新显示新网盘）。
//   Future<void> _addNetdisk(String provider) async {
//     final l10n = L10n.of(context);
//     final isQuark = provider == 'quark';
//     final name = isQuark ? l10n.netdisk_quark : l10n.netdisk_alipan;
//     final id =
//         'nd_${isQuark ? 'quark' : 'alipan'}_${DateTime.now().millisecondsSinceEpoch}';

//     final auth = await Navigator.push<Map<String, dynamic>>(
//       context,
//       MaterialPageRoute(builder: (_) => NetdiskLoginScreen(provider: provider)),
//     );
//     if (auth == null || !mounted) return; // 用户取消登录，留在向导

//     await NetdiskAuthStore.saveAuth(id, auth);
//     await NetworkConnectionsService.saveConnection(NetworkConnectionModel(
//       id: id,
//       name: name,
//       type: isQuark ? 'NETDISK_QUARK' : 'NETDISK_ALIPAN',
//       host: provider,
//       port: 0,
//       username: '',
//       password: '',
//       rootPath: '/',
//     ));
//     if (!mounted) return;
//     ScaffoldMessenger.of(context).showSnackBar(
//       SnackBar(
//         content: Row(
//           children: [
//             const Icon(Broken.tick_circle, color: Colors.white),
//             const SizedBox(width: 8),
//             Expanded(child: Text(l10n.name1(name), overflow: TextOverflow.ellipsis)),
//           ],
//         ),
//         behavior: SnackBarBehavior.floating,
//         backgroundColor: Theme.of(context).colorScheme.primary,
//       ),
//     );
//     // 关闭向导返回远程列表，列表页 onReturn 时刷新
//     Navigator.pop(context, true);
//   }

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
                    L10n.of(context).name1(name),
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
              title: Row(
                children: [
                  const Icon(Icons.warning_amber_rounded, color: Colors.orange),
                  const SizedBox(width: 8),
                  Text(
                    L10n.of(ctx).msgdf434415,
                    style: const TextStyle(fontFamily: 'LexendDeca', fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                ],
              ),
              content: Text(
                '${L10n.of(ctx).documentsui}'
                '${L10n.of(ctx).androidnn}'
                '${L10n.of(ctx).msgb2af4e30}'
                '${L10n.of(ctx).saf_enable_docs}',
                style: const TextStyle(fontSize: 14),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: Text(
                    L10n.of(ctx).ui_confirm,
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                ),
              ],
            ),
          );
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(L10n.of(context).safe(e)),
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
    // SMB 匿名登录：忽略输入框内容，空凭据 → 原生层走 guest 匿名会话
    final isSmb = _isSmbSelected;
    final username = (_anonymousLogin && isSmb) ? '' : (outUser ?? _usernameController.text).trim();
    final password = (_anonymousLogin && isSmb) ? '' : (outPwd ?? _passwordController.text).trim();
    final path = (_selectedType == 'WebDav' || isSmb)
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
    } else if (_isSmbSelected) {
      return LanClient(host: host, port: port, username: username, password: password);
    }
    return null;
  }

  String? _validateBasicForm() {
    final l10n = L10n.of(context);
    if (_nameController.text.trim().isEmpty) return l10n.msg65c7ecb6;
    if (_hostController.text.trim().isEmpty) return l10n.msg69e3963c;
    // 禁止静默匿名：SMB 未显式勾选「匿名登录」却未填用户名时不予放行。
    // 否则会以空凭据走 guest/匿名会话 —— 服务器（如 Samba 的
    // `access based share enum`）会向其隐藏部分共享，用户却以为在用自己的
    // 账号（用户反馈：质感文件能看到 Book，ZenFile 看不到）。
    // 要匿名访问，必须显式勾选「匿名登录」。
    if (_isSmbSelected &&
        !_anonymousLogin &&
        _usernameController.text.trim().isEmpty) {
      return l10n.msg0b62b5ce;
    }
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
                // 本地化友好提示（按错误类型映射，10 语言）
                Text(localizeRemoteError(errReason, l10n),
                  style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                const SizedBox(height: 10),
                // 原始英文异常，仅供排查
                Text('${l10n.ui_test_failed_reason}：',
                  style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                const SizedBox(height: 6),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: Colors.redAccent.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(errReason!,
                    style: TextStyle(fontSize: 12.5, color: theme.colorScheme.onSurface.withValues(alpha: 0.85),
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
    // SMB 匿名登录：保存空凭据（原生层自动以 guest 匿名会话连接）
    final isSmbSave = _isSmbSelected;
    final username = (_anonymousLogin && isSmbSave) ? '' : _usernameController.text.trim();
    final password = (_anonymousLogin && isSmbSave) ? '' : _passwordController.text.trim();
    final path = (_selectedType == 'WebDav' || isSmbSave)
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
    if (_isEditingSaf) return _buildSafRenameScreen(context);

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
            color: theme.colorScheme.onSurface.withValues(alpha: 0.05),
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

  // --- SAF 连接编辑（issue #44）：仅支持改名，不涉及 host/port/凭据 ---
  Widget _buildSafRenameScreen(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = L10n.of(context);
    final existing = widget.existingConnection!;

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new_rounded, size: 20),
          onPressed: () => Navigator.pop(context),
        ),
        title: Text(
          l10n.ui_remote_connection,
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
        children: [
          Row(
            children: [
              _buildProtocolIcon('SAF Folder', size: 30),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      l10n.androidsd,
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.bold,
                        fontFamily: 'LexendDeca',
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      existing.rootPath,
                      style: TextStyle(
                        fontSize: 12,
                        color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),
          _buildTextField(
            controller: _nameController,
            label: l10n.ui_connection_name,
            hint: l10n.nas,
            icon: Broken.tag,
          ),
          const SizedBox(height: 24),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                backgroundColor: theme.colorScheme.primary,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 16),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                elevation: 4,
              ),
              onPressed: _saveSafConnection,
              icon: const Icon(Icons.save_rounded, size: 18, color: Colors.white),
              label: Text(l10n.ui_save,
                style: const TextStyle(fontWeight: FontWeight.w700, color: Colors.white)),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _saveSafConnection() async {
    final l10n = L10n.of(context);
    final name = _nameController.text.trim();
    if (name.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(l10n.msg65c7ecb6)));
      return;
    }
    final existing = widget.existingConnection!;
    // 仅更新名称，SAF 的其余字段（content URI 等）原样保留。
    final connection = NetworkConnectionModel(
      id: existing.id,
      name: name,
      type: existing.type,
      host: existing.host,
      port: existing.port,
      username: existing.username,
      password: existing.password,
      rootPath: existing.rootPath,
      protocol: existing.protocol,
      sshKeyPath: existing.sshKeyPath,
      sshKeyPassword: existing.sshKeyPassword,
      authMethod: existing.authMethod,
    );
    await NetworkConnectionsService.deleteConnection(existing.id);
    await NetworkConnectionsService.saveConnection(connection);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          children: [
            const Icon(Broken.tick_circle, color: Colors.white),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                '"${connection.name}" ${l10n.ui_save}！',
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
            style: TextStyle(fontSize: 13, color: theme.colorScheme.onSurface.withValues(alpha: 0.6)),
          ),
          const SizedBox(height: 24),
          // 协议选择：单行卡片样式（图标 + 标题 + 描述 + 右箭头）
          ...protocols.map((protocol) {
            final name = protocol['name'] as String;
            final desc = protocol['desc'] as String;
            final color = protocol['color'] as Color;
            return Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: _buildNetdiskEntry(
                context,
                icon: _buildProtocolIcon(name, size: 22, customColor: color),
                title: name,
                subtitle: desc,
                color: color,
                onTap: () => _selectProtocol(name),
              ),
            );
          }),

//           // 分割线：下方为聚合网盘添加区（夸克 / 阿里云盘）
//           const SizedBox(height: 30),
//           Divider(
//             height: 1,
//             thickness: 1,
//             color: theme.colorScheme.onSurface.withValues(alpha: 0.12),
//           ),
//           const SizedBox(height: 20),

//           Row(
//             children: [
//               Icon(Icons.cloud_outlined,
//                   size: 20, color: theme.colorScheme.primary),
//               const SizedBox(width: 8),
//               Text(
//                 L10n.of(context).netdisk_add,
//                 style: const TextStyle(
//                   fontSize: 16,
//                   fontWeight: FontWeight.bold,
//                   fontFamily: 'LexendDeca',
//                 ),
//               ),
//             ],
//           ),
//           const SizedBox(height: 6),
//           Text(
//             L10n.of(context).netdisk_empty_hint,
//             style: TextStyle(
//               fontSize: 12.5,
//               color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
//             ),
//           ),
//           const SizedBox(height: 14),
//           _buildNetdiskEntry(
//             context,
//             icon: const Icon(Broken.cloud, color: Color(0xFF2B6CB0), size: 22),
//             title: L10n.of(context).netdisk_quark,
//             color: const Color(0xFF2B6CB0),
//             onTap: () => _addNetdisk('quark'),
//           ),
//           const SizedBox(height: 10),
//           _buildNetdiskEntry(
//             context,
//             icon: const Icon(Icons.cloud_rounded, color: Color(0xFFFF6A00), size: 22),
//             title: L10n.of(context).netdisk_alipan,
//             color: const Color(0xFFFF6A00),
//             onTap: () => _addNetdisk('alipan'),
//           ),
        ],
      ),
    );
  }

  /// 添加网盘 / 协议入口卡片（单行：图标 + 标题[+描述] + 右箭头）。
  Widget _buildNetdiskEntry(
    BuildContext context, {
    required Widget icon,
    required String title,
    String? subtitle,
    required Color color,
    required VoidCallback onTap,
  }) {
    final theme = Theme.of(context);
    return Card(
      elevation: 2,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: BorderSide(color: theme.colorScheme.primary.withValues(alpha: 0.08)),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: icon,
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(
                        fontSize: 14.5,
                        fontWeight: FontWeight.bold,
                        fontFamily: 'LexendDeca',
                      ),
                    ),
                    if (subtitle != null) ...[
                      const SizedBox(height: 2),
                      Text(
                        subtitle,
                        style: TextStyle(
                          fontSize: 11.5,
                          color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
                          height: 1.2,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ],
                ),
              ),
              Icon(
                Icons.chevron_right,
                color: theme.colorScheme.onSurface.withValues(alpha: 0.4),
              ),
            ],
          ),
        ),
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
        color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
      ),
      onPressed: () => setState(() => _obscurePassword = !_obscurePassword),
      splashRadius: 20,
    );

    return ScrollConfiguration(
      behavior: const ScrollBehavior().copyWith(overscroll: false),
      child: ListView(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
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
                      // 历史连接的类型可能是旧值，SMB 统一显示当前语言标签
                      '${_isSmbSelected ? l10n.smb : _selectedType} ${l10n.cat_settings}',
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
                        color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 18),

          // Connection Nickname
          _buildTextField(
            controller: _nameController,
            label: l10n.ui_connection_name,
            hint: l10n.nas,
            icon: Broken.tag,
          ),
          const SizedBox(height: 12),

          if (_selectedType == 'WebDav') ...[
            // 一体分段控件（「协议」标题位于左上角边框，HTTP / HTTPS 竖线分隔）
            _buildProtocolToggle(theme),
            const SizedBox(height: 12),
          ],

          if (_isSmbSelected) ...[
            _buildLanScanSection(theme),
            const SizedBox(height: 12),
          ],
          _buildTextField(
            controller: _hostController,
            label: l10n.msg5d57821d,
            hint: _selectedType == 'WebDav' ? l10n.dav : l10n.naslocal,
            icon: Broken.global,
          ),
          const SizedBox(height: 12),

          _buildTextField(
            controller: _portController,
            label: l10n.ui_port,
            hint: _selectedType == 'WebDav' ? '80' : '21',
            icon: Broken.hashtag,
            keyboardType: TextInputType.number,
          ),
          const SizedBox(height: 12),

          if (_selectedType == 'WebDav') ...[
            _buildTextField(
              controller: _pathController,
              label: '${l10n.ui_path_label} (${l10n.ui_optional})',
              hint: l10n.dav1,
              icon: Broken.folder_open,
            ),
            const SizedBox(height: 12),
          ] else if (_isSmbSelected) ...[
            _buildSmbShareField(theme),
            const SizedBox(height: 12),
          ],

          // SMB：「匿名登录」勾选框（勾选后用户名/密码置灰不可输入）
          if (_isSmbSelected) ...[
            Align(
              alignment: Alignment.centerLeft,
              child: InkWell(
                borderRadius: BorderRadius.circular(8),
                onTap: () => setState(() => _anonymousLogin = !_anonymousLogin),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      SizedBox(
                        width: 20,
                        height: 20,
                        child: Checkbox(
                          value: _anonymousLogin,
                          onChanged: (v) => setState(() => _anonymousLogin = v ?? false),
                          materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          visualDensity: VisualDensity.compact,
                        ),
                      ),
                      const SizedBox(width: 5),
                      Text(
                        l10n.ui_anonymous_login,
                        style: TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w600,
                          color: _anonymousLogin
                              ? theme.colorScheme.primary
                              : theme.colorScheme.onSurface.withValues(alpha: 0.6),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(height: 4),
          ],
          _buildTextField(
            controller: _usernameController,
            label: l10n.ui_username_optional,
            hint: l10n.anonymousadmin,
            icon: Broken.user,
            enabled: !(_anonymousLogin && _isSmbSelected),
          ),
          const SizedBox(height: 12),

          _buildTextField(
            controller: _passwordController,
            label: l10n.msgeec70cd2,
            hint: '••••••••',
            icon: Broken.lock,
            obscure: _obscurePassword,
            suffix: passwordSuffix,
            enabled: !(_anonymousLogin && _isSmbSelected),
          ),

          // SFTP SSH 密钥认证选项
          if (_selectedType == 'SFTP') ...[
            const SizedBox(height: 16),
            _buildSshKeySection(theme),
          ],

          const SizedBox(height: 20),

          // Three-button action bar: BACK (left) · TEST (center) · SAVE (right, primary)
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  style: OutlinedButton.styleFrom(
                    side: BorderSide(color: theme.colorScheme.outline.withValues(alpha: 0.35)),
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
                    side: BorderSide(color: theme.colorScheme.primary.withValues(alpha: 0.55)),
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

  // --- SMB 局域网设备扫描（无需输入 IP） ---
  Widget _buildLanScanSection(ThemeData theme) {
    final l10n = L10n.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 与其他输入框等宽
        SizedBox(
          width: double.infinity,
          child: FilledButton.icon(
            onPressed: _isScanningLan ? null : _scanLanDevices,
            icon: _isScanningLan
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.white),
                  )
                : const Icon(Icons.wifi_find_rounded, size: 20),
            label: Text(
              _isScanningLan ? l10n.ui_scanning_lan : l10n.ui_scan_lan_devices,
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
            style: FilledButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 18),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
            ),
          ),
        ),
        const SizedBox(height: 12),
        _buildLanDeviceResults(theme),
      ],
    );
  }

  Widget _buildLanDeviceResults(ThemeData theme) {
    final l10n = L10n.of(context);
    if (_lanScanError != null) {
      return Text(
        l10n.ui_share_scan_failed(_lanScanError!),
        style: const TextStyle(fontSize: 12.5, color: Colors.redAccent),
      );
    }
    if (_lanDevices.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          l10n.ui_lan_scan_hint,
          style: TextStyle(
            fontSize: 12,
            color: theme.colorScheme.onSurface.withValues(alpha: 0.55),
          ),
        ),
        const SizedBox(height: 8),
        ..._lanDevices.map((device) {
          final host = device.host;
          final shares = device.shares;
          return Container(
            margin: const EdgeInsets.only(bottom: 10),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceVariant.withValues(alpha: 0.35),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: theme.colorScheme.outline.withValues(alpha: 0.15)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                InkWell(
                  onTap: () {
                    setState(() {
                      _hostController.text = host;
                      _portController.text = '445';
                      _lanScanError = null;
                    });
                  },
                  child: Row(
                    children: [
                      Icon(Broken.global, size: 18, color: theme.colorScheme.primary),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              device.displayName,
                              style: TextStyle(
                                fontWeight: FontWeight.bold,
                                fontSize: 14,
                                color: theme.colorScheme.primary,
                              ),
                            ),
                            if (device.hasHostName)
                              Padding(
                                padding: const EdgeInsets.only(top: 2),
                                child: Text(
                                  host,
                                  style: TextStyle(
                                    fontSize: 11.5,
                                    color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                      Icon(Icons.arrow_forward_ios_rounded,
                          size: 14, color: theme.colorScheme.onSurface.withValues(alpha: 0.4)),
                    ],
                  ),
                ),
                if (shares.isEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(
                      l10n.ui_no_shares_found,
                      style: TextStyle(
                        fontSize: 12,
                        color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
                      ),
                    ),
                  )
                else
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: shares.map((share) {
                        return ActionChip(
                          label: Text(share),
                          labelStyle: TextStyle(
                            color: theme.colorScheme.primary,
                            fontWeight: FontWeight.w600,
                          ),
                          backgroundColor: theme.colorScheme.primary.withValues(alpha: 0.1),
                          onPressed: () {
                            setState(() {
                              _hostController.text = host;
                              _portController.text = '445';
                              _pathController.text = share;
                              _lanScanError = null;
                            });
                          },
                        );
                      }).toList(),
                    ),
                  ),
              ],
            ),
          );
        }),
      ],
    );
  }

  Future<void> _scanLanDevices() async {
    final l10n = L10n.of(context);
    // 匿名勾选时以空凭据扫描（可发现 guest/匿名共享）；未勾选时用已填凭据
    final isSmbScan = _isSmbSelected;
    final username = (_anonymousLogin && isSmbScan) ? '' : _usernameController.text.trim();
    final password = (_anonymousLogin && isSmbScan) ? '' : _passwordController.text.trim();
    if (mounted) {
      setState(() {
        _isScanningLan = true;
        _lanScanError = null;
        _lanDevices = const [];
      });
    }
    try {
      final devices = await FileManagerProvider.discoverSmbDevices(
        username: username,
        password: password,
        onProgress: (double _) {},
      );
      if (!mounted) return;
      setState(() {
        _lanDevices = devices;
        if (devices.isEmpty) _lanScanError = l10n.ui_lan_no_devices;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _lanScanError = localizeRemoteError(e, l10n));
    } finally {
      if (mounted) setState(() => _isScanningLan = false);
    }
  }

  Widget _buildSmbShareField(ThemeData theme) {
    final l10n = L10n.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildTextField(
          controller: _pathController,
          label: l10n.ui_share_name_optional,
          hint: l10n.ui_share_name_hint,
          icon: Broken.folder_open,
        ),
        const SizedBox(height: 8),
        Text(
          l10n.ui_lan_scan_hint,
          style: TextStyle(fontSize: 12, color: theme.colorScheme.onSurface.withValues(alpha: 0.5)),
        ),
      ],
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
                  color: theme.colorScheme.primary.withValues(alpha: 0.04),
                  shape: BoxShape.circle,
                  border: Border.all(color: theme.colorScheme.primary.withValues(alpha: 0.1), width: 1.5),
                ),
              ),
              SizedBox(
                height: 100,
                width: 100,
                child: CircularProgressIndicator(
                  strokeWidth: 4,
                  valueColor: AlwaysStoppedAnimation<Color>(theme.colorScheme.primary),
                  backgroundColor: theme.colorScheme.primary.withValues(alpha: 0.1),
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
              color: theme.colorScheme.onSurface.withValues(alpha: 0.9),
              fontFamily: 'LexendDeca',
            ),
          ),
          const SizedBox(height: 8),
          Text(
            L10n.of(context).selectedtype1(_selectedType),
            style: TextStyle(
              fontSize: 12.5,
              color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
            ),
            textAlign: TextAlign.center,
          ),

          const Spacer(),

          // Dynamic Diagnostic List
          Card(
            elevation: 0,
            color: isDark ? const Color(0xFF1E293B) : theme.colorScheme.primary.withValues(alpha: 0.02),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(20),
              side: BorderSide(color: theme.colorScheme.primary.withValues(alpha: 0.08)),
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
                    itemColor = theme.colorScheme.onSurface.withValues(alpha: 0.25);
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
                                  ? theme.colorScheme.onSurface.withValues(alpha: 0.9)
                                  : theme.colorScheme.onSurface.withValues(alpha: done ? 0.6 : 0.35),
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
        // 认证方式切换：一体分段控件（竖线分隔）
        _buildSegmentPill(
          theme,
          segments: [
            (
              label: l10n.ui_password_auth,
              selected: _sshKeyPath == null,
              onTap: () => setState(() => _sshKeyPath = null),
            ),
            (
              label: l10n.ui_ssh_key_auth,
              selected: _sshKeyPath != null,
              onTap: _selectSshKey,
            ),
          ],
        ),

        // 密钥文件选择
        if (_sshKeyPath != null) ...[
          const SizedBox(height: 12),
          InkWell(
            onTap: _selectSshKey,
            borderRadius: BorderRadius.circular(12),
            child: Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: isDark ? const Color(0xFF1E293B) : theme.colorScheme.primary.withValues(alpha: 0.04),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: theme.colorScheme.primary.withValues(alpha: 0.3)),
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
        ],

        // 密钥密码短语（可选）
        if (_sshKeyPath != null) ...[
          const SizedBox(height: 12),
          _buildTextField(
            controller: _sshKeyPasswordController,
            label: '${l10n.ui_passphrase} (${l10n.ui_optional})',
            hint: '••••••••',
            icon: Broken.lock,
            obscure: _obscureSshKeyPassword,
            suffix: IconButton(
              icon: Icon(
                _obscureSshKeyPassword ? Broken.eye_slash : Broken.eye,
                size: 18,
                color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
              ),
              onPressed: () => setState(() => _obscureSshKeyPassword = !_obscureSshKeyPassword),
              splashRadius: 20,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            l10n.ui_ssh_key_password_hint,
            style: TextStyle(fontSize: 11, color: theme.colorScheme.onSurface.withValues(alpha: 0.5)),
          ),
        ],
      ],
    );
  }

  /// 一体分段控件：所有选项共用一个容器，选项之间用贯穿上下边框的竖线分隔；
  /// 选中项以主色铺满所在半边（外侧跟随容器 16dp 圆角）。
  /// 借助 InputDecorator 呈现与输入框一致的描边 + 填充；
  /// [title]（如「协议」）与字段标题一样固定在左上角边框缺口处。
  Widget _buildSegmentPill(
    ThemeData theme, {
    String? title,
    required List<({String label, bool selected, VoidCallback onTap})> segments,
  }) {
    final isDark = theme.brightness == Brightness.dark;
    final Widget divider = Container(
      width: 1,
      height: double.infinity,
      color: theme.colorScheme.outline.withValues(alpha: 0.25),
    );

    final List<Widget> children = [];
    for (var i = 0; i < segments.length; i++) {
      final seg = segments[i];
      final isFirst = i == 0;
      final isLast = i == segments.length - 1;
      // 水波纹贴合外侧圆角（高亮块本身为直角，由外层 ClipRRect 统一裁出圆角，
      // 保证选中色铺满到左右两侧边框）
      final segRadius = BorderRadius.only(
        topLeft: Radius.circular(isFirst ? 16 : 0),
        bottomLeft: Radius.circular(isFirst ? 16 : 0),
        topRight: Radius.circular(isLast ? 16 : 0),
        bottomRight: Radius.circular(isLast ? 16 : 0),
      );
      children.add(
        Expanded(
          child: InkWell(
            onTap: seg.onTap,
            borderRadius: segRadius,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              alignment: Alignment.center,
              color: seg.selected
                  ? theme.colorScheme.primary.withValues(alpha: 0.14)
                  : Colors.transparent,
              child: Text(
                seg.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: seg.selected ? FontWeight.w700 : FontWeight.w500,
                  color: seg.selected
                      ? theme.colorScheme.primary
                      : theme.colorScheme.onSurface.withValues(alpha: 0.55),
                ),
              ),
            ),
          ),
        ),
      );
      if (i < segments.length - 1) children.add(divider);
    }

    return Stack(
      clipBehavior: Clip.none,
      children: [
        // 底层：基础填充 + 分段高亮 + 贯穿上下边框的竖线分隔。
        // 不经 InputDecorator 承载（其 child 区域存在内缩），用直角色块绘制、
        // 由 ClipRRect 统一裁出 16dp 圆角 —— 选中高亮必然铺满到左右边框。
        ClipRRect(
          borderRadius: BorderRadius.circular(16),
          child: Container(
            height: 48,
            color: isDark
                ? const Color(0xFF1E293B)
                : theme.colorScheme.primary.withValues(alpha: 0.04),
            child: Row(children: children),
          ),
        ),
        // 顶层：仅绘制 16dp 描边与「协议」标题（与字段标题一致，固定在左上角边框缺口处）
        IgnorePointer(
          child: SizedBox(
            height: 48,
            child: InputDecorator(
              decoration: InputDecoration(
                labelText: title,
                floatingLabelBehavior: FloatingLabelBehavior.always,
                labelStyle: TextStyle(
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                ),
                floatingLabelStyle: TextStyle(
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                ),
                filled: false,
                contentPadding: EdgeInsets.zero,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(16),
                  borderSide: BorderSide(color: theme.colorScheme.outline.withValues(alpha: 0.1)),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(16),
                  borderSide: BorderSide(color: theme.colorScheme.outline.withValues(alpha: 0.1)),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(16),
                  borderSide: BorderSide(color: theme.colorScheme.outline.withValues(alpha: 0.1)),
                ),
              ),
              child: const SizedBox.expand(),
            ),
          ),
        ),
      ],
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

  Widget _buildTextField({
    required TextEditingController controller,
    required String label,
    String? hint,
    required IconData icon,
    bool obscure = false,
    TextInputType keyboardType = TextInputType.text,
    Widget? suffix,
    bool enabled = true,
  }) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return TextField(
      controller: controller,
      obscureText: obscure,
      keyboardType: keyboardType,
      enabled: enabled,
      style: const TextStyle(fontSize: 14),
      decoration: InputDecoration(
        // 标题固定在输入框左上角边框（始终浮动，不进入框内）；
        // 提示文本留在框内，两者颜色区分：标题更深，提示更浅。
        labelText: label,
        floatingLabelBehavior: FloatingLabelBehavior.always,
        labelStyle: TextStyle(
          color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
          fontSize: 12,
          fontWeight: FontWeight.w500,
        ),
        floatingLabelStyle: TextStyle(
          color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
          fontSize: 12,
          fontWeight: FontWeight.w500,
        ),
        hintText: hint,
        hintStyle: TextStyle(
          color: theme.colorScheme.onSurface.withValues(alpha: 0.35),
          fontSize: 13.5,
        ),
        prefixIcon: Icon(icon, size: 18, color: theme.colorScheme.onSurface.withValues(alpha: 0.5)),
        suffixIcon: suffix,
        filled: true,
        fillColor: isDark ? const Color(0xFF1E293B) : theme.colorScheme.primary.withValues(alpha: 0.04),
        contentPadding: const EdgeInsets.symmetric(vertical: 14, horizontal: 16),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide(color: theme.colorScheme.outline.withValues(alpha: 0.1)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide(color: theme.colorScheme.primary.withValues(alpha: 0.8), width: 1.5),
        ),
      ),
    );
  }

  Widget _buildProtocolIcon(String name, {required double size, Color? customColor}) {
    IconData iconData;
    Color color;
    // 容错：历史连接类型可能存成 'SMB'/'Samba'/'CIFS'，不只等于本地化标签
    final t = name.toLowerCase().trim();
    final isSmb = name == L10n.of(context).smb ||
        t.contains('smb') || t.contains('samba') || t == 'cifs';

    if (isSmb) {
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
    // 一体分段控件：「协议」标题位于左上角边框，HTTP / HTTPS 竖线分隔
    return _buildSegmentPill(
      theme,
      title: L10n.of(context).ui_protocol,
      segments: [
        (
          label: 'HTTP',
          selected: _webdavProtocol == 'http',
          onTap: () {
            setState(() {
              _webdavProtocol = 'http';
              if (_portController.text == '443' || _portController.text.isEmpty) {
                _portController.text = '80';
              }
            });
          },
        ),
        (
          label: 'HTTPS',
          selected: _webdavProtocol == 'https',
          onTap: () {
            setState(() {
              _webdavProtocol = 'https';
              if (_portController.text == '80' || _portController.text.isEmpty) {
                _portController.text = '443';
              }
            });
          },
        ),
      ],
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
