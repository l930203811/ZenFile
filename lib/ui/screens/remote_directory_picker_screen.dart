import 'dart:async';
import 'package:flutter/material.dart';
import '../../core/utils.dart';
import '../../models/network_connection_model.dart';
import '../../services/network_connections_service.dart';
import '../../services/remote/ftp_client.dart';
import '../../services/remote/lan_client.dart';
import '../../services/remote/remote_client.dart';
import '../../services/remote/saf_client.dart';
import '../../services/remote/sftp_client.dart';
import '../../services/remote/webdav_client.dart';
import '../widgets/remote_path_picker.dart';
import 'package:zenfile/l10n/generated/app_localizations.dart';

class RemoteDirectoryPickerScreen extends StatefulWidget {
  final NetworkConnectionModel connection;

  const RemoteDirectoryPickerScreen({
    super.key,
    required this.connection,
  });

  static Future<String?> show(BuildContext context, NetworkConnectionModel connection) {
    return Navigator.push<String>(
      context,
      MaterialPageRoute(
        builder: (_) => RemoteDirectoryPickerScreen(connection: connection),
      ),
    );
  }

  @override
  State<RemoteDirectoryPickerScreen> createState() => _RemoteDirectoryPickerScreenState();
}

class _RemoteDirectoryPickerScreenState extends State<RemoteDirectoryPickerScreen> {
  RemoteClient? _client;
  bool _isLoading = true;
  String _errorMsg = '';
  String _currentPath = '/';
  late final String _rootPath;
  List<RemoteFileItem> _items = [];

  @override
  void initState() {
    super.initState();
    _rootPath = widget.connection.rootPath.isNotEmpty ? widget.connection.rootPath : '/';
    _currentPath = _rootPath;
    _initClient();
  }

  @override
  void dispose() {
    _client?.disconnect();
    super.dispose();
  }

  Future<void> _initClient() async {
    final conn = widget.connection;
    if (conn.type == 'FTP') {
      _client = FtpRemoteClient(
        host: conn.host,
        port: conn.port,
        username: conn.username,
        password: conn.password,
      );
    } else if (conn.type == 'SFTP') {
      _client = SftpRemoteClient(
        host: conn.host,
        port: conn.port,
        username: conn.username,
        password: conn.password,
        sshKeyPath: conn.sshKeyPath,
        sshKeyPassword: conn.sshKeyPassword,
        authMethod: conn.authMethod,
      );
    } else if (conn.type == 'WebDav') {
      _client = WebDavRemoteClient(
        host: conn.host,
        port: conn.port,
        username: conn.username,
        password: conn.password,
        protocol: conn.protocol,
        rootPath: conn.rootPath,
      );
    } else if (NetworkConnectionsService.isSmbType(conn.type)) {
      _client = LanClient(
        host: conn.host,
        port: conn.port,
        username: conn.username,
        password: conn.password,
      );
    } else if (conn.type == 'saf') {
      _client = SafRemoteClient(rootUri: conn.rootPath);
    }

    if (_client == null) {
      if (mounted) {
        setState(() {
          _errorMsg = 'Unsupported remote connection type: ${conn.type}';
          _isLoading = false;
        });
      }
      return;
    }

    try {
      await _client!.connect();
      await _loadDirectoryContents(_currentPath);
    } catch (e) {
      if (mounted) {
        setState(() {
          _errorMsg = e.toString();
          _isLoading = false;
        });
      }
    }
  }

  Future<void> _loadDirectoryContents(String path) async {
    if (_client == null) return;
    setState(() {
      _isLoading = true;
      _errorMsg = '';
    });
    try {
      final items = await _client!.listDirectory(path);
      final folders = items.where((i) => i.isDirectory).toList();
      folders.sort((a, b) => FileUtils.compareNatural(a.name, b.name));
      if (mounted) {
        setState(() {
          _items = folders;
          _currentPath = path;
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _errorMsg = e.toString();
          _isLoading = false;
        });
      }
    }
  }

  String? _parentPath(String path) {
    if (path == _rootPath) return null;
    if (path == '/' || path.isEmpty) return null;
    final normalized = path.endsWith('/') ? path.substring(0, path.length - 1) : path;
    final idx = normalized.lastIndexOf('/');
    if (idx <= 0) return _rootPath;
    return normalized.substring(0, idx);
  }

  void _selectCurrentFolder() {
    Navigator.pop(context, _currentPath);
  }

  /// 在当前远程目录下新建文件夹，成功后刷新当前目录列表。
  Future<void> _createFolder() async {
    final client = _client;
    if (client == null) return;
    final created = await createRemoteFolderInteractive(
      context: context,
      client: client,
      currentPath: _currentPath,
    );
    if (created && mounted) {
      await _loadDirectoryContents(_currentPath);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      appBar: AppBar(
        title: Text(widget.connection.name),
        backgroundColor: theme.scaffoldBackgroundColor,
        elevation: 0,
        iconTheme: IconThemeData(color: theme.colorScheme.onSurface),
        titleTextStyle: theme.textTheme.titleLarge?.copyWith(
          color: theme.colorScheme.onSurface,
          fontWeight: FontWeight.bold,
        ),
      ),
      body: Column(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            color: theme.colorScheme.surface,
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    _currentPath,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurface.withOpacity(0.7),
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: _buildBody(context, theme),
          ),
        ],
      ),
      bottomNavigationBar: buildRemotePickerActionBar(
        context: context,
        onCreateFolder: (_isLoading || _client == null) ? null : _createFolder,
        onSelect: _isLoading ? null : _selectCurrentFolder,
        onCancel: () => Navigator.pop(context),
      ),
    );
  }

  Widget _buildBody(BuildContext context, ThemeData theme) {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_errorMsg.isNotEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            _errorMsg,
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.error,
            ),
          ),
        ),
      );
    }

    final parent = _parentPath(_currentPath);
    final itemCount = _items.length + (parent != null ? 1 : 0);

    return ListView.builder(
      itemCount: itemCount,
      itemBuilder: (context, index) {
        if (parent != null && index == 0) {
          return ListTile(
            leading: Icon(Icons.arrow_upward, color: theme.colorScheme.onSurface.withOpacity(0.6)),
            title: Text(
              L10n.of(context).ui_parent_directory,
              style: TextStyle(color: theme.colorScheme.onSurface),
            ),
            onTap: () => _loadDirectoryContents(parent),
          );
        }
        final item = _items[parent != null ? index - 1 : index];
        return ListTile(
          leading: Icon(Icons.folder, color: theme.colorScheme.primary),
          title: Text(
            item.name,
            style: TextStyle(color: theme.colorScheme.onSurface),
          ),
          trailing: Icon(Icons.chevron_right, color: theme.colorScheme.onSurface.withOpacity(0.4)),
          onTap: () => _loadDirectoryContents(item.path),
        );
      },
    );
  }
}
