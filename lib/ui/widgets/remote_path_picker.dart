import 'package:flutter/material.dart';
import '../../core/icon_fonts/broken_icons.dart';
import '../../providers/file_manager_provider.dart';
import '../../services/network_connections_service.dart';
import '../../models/network_connection_model.dart';
import '../../services/remote/remote_client.dart';
import 'package:zenfile/l10n/generated/app_localizations.dart';

/// 显示远程服务器目录选择器，返回 `remote://{connectionId}|{path}` 格式的路径。
Future<String?> showRemotePathPicker(BuildContext context) async {
  final theme = Theme.of(context);
  final connections = NetworkConnectionsService.getConnections();

  if (connections.isEmpty) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(L10n.of(context).ui_no_remote_connections),
        backgroundColor: Colors.orangeAccent,
      ),
    );
    return null;
  }

  // Step 1: 选择远程连接
  final NetworkConnectionModel? selectedConn = await showModalBottomSheet<NetworkConnectionModel>(
    context: context,
    isScrollControlled: true,
    backgroundColor: theme.scaffoldBackgroundColor,
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
    builder: (ctx) {
      return SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 12),
            Container(width: 40, height: 4, decoration: BoxDecoration(color: Colors.grey.withOpacity(0.3), borderRadius: BorderRadius.circular(2))),
            const SizedBox(height: 16),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20.0),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(L10n.of(context).ui_select_remote_server, style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold)),
                  TextButton(onPressed: () => Navigator.pop(ctx), child: Text(L10n.of(context).ui_cancel)),
                ],
              ),
            ),
            const SizedBox(height: 8),
            ...connections.map((conn) {
              IconData iconData;
              if (FileManagerProvider.isSmbType(conn.type)) {
                iconData = Icons.computer_rounded;
              } else if (conn.type == 'FTP') {
                iconData = Icons.swap_horizontal_circle_rounded;
              } else if (conn.type == 'SFTP') {
                iconData = Icons.vpn_lock_rounded;
              } else if (conn.type == 'WebDav') {
                iconData = Icons.web_rounded;
              } else {
                iconData = Broken.wifi;
              }
              return ListTile(
                leading: Container(
                  width: 42,
                  height: 42,
                  decoration: BoxDecoration(color: theme.colorScheme.primary.withOpacity(0.1), shape: BoxShape.circle),
                  child: Icon(iconData, color: theme.colorScheme.primary, size: 20),
                ),
                title: Text(conn.name, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15)),
                subtitle: Text('${conn.type} · ${conn.host}', style: TextStyle(fontSize: 12, color: theme.colorScheme.onSurface.withOpacity(0.5)), maxLines: 1, overflow: TextOverflow.ellipsis),
                trailing: const Icon(Icons.chevron_right_rounded),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                onTap: () => Navigator.pop(ctx, conn),
              );
            }),
            const SizedBox(height: 16),
          ],
        ),
      );
    },
  );

  if (selectedConn == null) return null;

  // Step 2: 浏览远程目录选择文件夹（全屏页面）
  return Navigator.push<String?>(
    context,
    MaterialPageRoute(
      builder: (ctx) => _RemoteDirectoryPickerPage(connection: selectedConn),
    ),
  );
}

/// 远程目录选择全屏页面，连接远程服务器并让用户选择一个目录。
/// 返回 `remote://{connectionId}|{path}` 格式的路径字符串。
class _RemoteDirectoryPickerPage extends StatefulWidget {
  final NetworkConnectionModel connection;

  const _RemoteDirectoryPickerPage({required this.connection});

  @override
  State<_RemoteDirectoryPickerPage> createState() => _RemoteDirectoryPickerPageState();
}

class _RemoteDirectoryPickerPageState extends State<_RemoteDirectoryPickerPage> {
  RemoteClient? _client;
  bool _isConnecting = true;
  bool _isLoading = false;
  String _errorMsg = '';
  late String _currentPath;
  List<RemoteFileItem> _items = [];

  @override
  void initState() {
    super.initState();
    _currentPath = widget.connection.rootPath.isNotEmpty
        ? widget.connection.rootPath
        : '/';
    _connectAndList();
  }

  @override
  void dispose() {
    _client?.disconnect();
    super.dispose();
  }

  Future<void> _connectAndList() async {
    setState(() {
      _isConnecting = true;
      _errorMsg = '';
    });
    try {
      _client?.disconnect();
      _client = FileManagerProvider.createRemoteClient(widget.connection);
      await _client!.connect();
      // For SMB keep "/" to list all shared directories.
      await _listDir(_currentPath);
    } catch (e) {
      if (mounted) {
        setState(() {
          _isConnecting = false;
          _errorMsg = e.toString();
        });
      }
    }
  }

  Future<void> _listDir(String path, {bool forceRefresh = false}) async {
    setState(() {
      _isLoading = true;
      _errorMsg = '';
    });
    try {
      final items = await _client!.listDirectory(path, forceRefresh: forceRefresh);
      items.sort((a, b) {
        if (a.isDirectory != b.isDirectory) return a.isDirectory ? -1 : 1;
        return a.name.toLowerCase().compareTo(b.name.toLowerCase());
      });
      if (mounted) {
        setState(() {
          _items = items.where((i) => i.isDirectory).toList();
          _isLoading = false;
          _isConnecting = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoading = false;
          _isConnecting = false;
          _errorMsg = e.toString();
        });
      }
    }
  }

  void _selectCurrent() {
    final remotePath = 'remote://${widget.connection.id}|$_currentPath';
    Navigator.of(context).pop(remotePath);
  }

  void _goUp() {
    final parts = _currentPath.split('/').where((s) => s.isNotEmpty).toList();
    if (parts.isNotEmpty) {
      parts.removeLast();
      _currentPath = '/${parts.join('/')}';
      if (_currentPath.isEmpty) _currentPath = '/';
      _listDir(_currentPath);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = L10n.of(context);

    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(l10n.ui_select_remote_server, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 2),
            Text(
              '${widget.connection.name} · $_currentPath',
              style: TextStyle(fontSize: 12, color: theme.colorScheme.onSurface.withOpacity(0.5)),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.close, size: 22),
            onPressed: () => Navigator.of(context).pop(),
          ),
        ],
      ),
      body: _isConnecting
          ? const Center(child: CircularProgressIndicator())
          : _errorMsg.isNotEmpty
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.error_outline, size: 48, color: theme.colorScheme.error),
                      const SizedBox(height: 12),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 32),
                        child: Text(_errorMsg, textAlign: TextAlign.center, style: TextStyle(fontSize: 13, color: theme.colorScheme.onSurface.withOpacity(0.6))),
                      ),
                      const SizedBox(height: 16),
                      FilledButton.icon(
                        onPressed: _connectAndList,
                        icon: const Icon(Icons.refresh, size: 18),
                        label: Text(l10n.ui_retry),
                      ),
                    ],
                  ),
                )
              : Column(
                  children: [
                    // 面包屑导航
                    if (_currentPath != '/' && _currentPath != widget.connection.rootPath)
                      Material(
                        color: theme.colorScheme.primary.withOpacity(0.05),
                        child: InkWell(
                          onTap: _goUp,
                          child: Container(
                            width: double.infinity,
                            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                            child: Row(
                              children: [
                                Icon(Icons.arrow_upward, size: 18, color: theme.colorScheme.primary),
                                const SizedBox(width: 8),
                                Text(l10n.msg1f4c1042, style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: theme.colorScheme.primary)),
                              ],
                            ),
                          ),
                        ),
                      ),
                    if (_isLoading)
                      const Expanded(child: Center(child: CircularProgressIndicator()))
                    else
                      Expanded(
                        child: _items.isEmpty
                            ? Center(
                                child: Text(l10n.ui_no_subfolders, style: TextStyle(color: theme.colorScheme.onSurface.withOpacity(0.4), fontSize: 14)),
                              )
                            : ListView.builder(
                                itemCount: _items.length,
                                itemBuilder: (ctx, index) {
                                  final item = _items[index];
                                  return ListTile(
                                    leading: Icon(Icons.folder, color: theme.colorScheme.primary.withOpacity(0.7), size: 26),
                                    title: Text(item.name, style: const TextStyle(fontSize: 15), maxLines: 1, overflow: TextOverflow.ellipsis),
                                    trailing: const Icon(Icons.chevron_right, size: 22),
                                    onTap: () {
                                      _currentPath = item.path;
                                      _listDir(_currentPath);
                                    },
                                  );
                                },
                              ),
                      ),
                  ],
                ),
      bottomNavigationBar: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(onPressed: () => Navigator.of(context).pop(), child: Text(l10n.ui_cancel)),
              const SizedBox(width: 8),
              FilledButton.icon(
                onPressed: _isConnecting || _errorMsg.isNotEmpty ? null : _selectCurrent,
                icon: const Icon(Icons.check, size: 18),
                label: Text(l10n.ui_select_this_folder),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
