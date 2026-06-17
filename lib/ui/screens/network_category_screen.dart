import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/icon_fonts/broken_icons.dart';
import '../../models/network_connection_model.dart';
import '../../services/network_connections_service.dart';
import '../../providers/file_manager_provider.dart';
import 'package:zenfile/l10n/generated/app_localizations.dart';

import 'network_connection_wizard_screen.dart';

class NetworkCategoryScreen extends StatefulWidget {
  final Function(int)? onNavigateTab;

  const NetworkCategoryScreen({super.key, this.onNavigateTab});

  @override
  State<NetworkCategoryScreen> createState() => _NetworkCategoryScreenState();
}

class _NetworkCategoryScreenState extends State<NetworkCategoryScreen> {
  List<NetworkConnectionModel> _connections = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadConnections();
  }

  void _loadConnections() {
    setState(() {
      _connections = NetworkConnectionsService.getConnections();
      _isLoading = false;
    });
  }

  IconData _getIconForType(String type) {
    switch (type) {
      case '局域网/SMB':
        return Icons.dns_rounded;
      case 'FTP':
        return Icons.swap_horizontal_circle_rounded;
      case 'SFTP':
        return Icons.vpn_lock_rounded;
      case 'WebDav':
        return Icons.web_rounded;
      default:
        return Broken.wifi;
    }
  }

  Color _getColorForType(String type) {
    switch (type) {
      case '局域网/SMB':
        return const Color(0xFF5B21B6);
      case 'FTP':
        return const Color(0xFFF97316);
      case 'SFTP':
        return const Color(0xFF0D9488);
      case 'WebDav':
        return const Color(0xFFE11D48);
      default:
        return const Color(0xFF00BCD4);
    }
  }

  Future<void> _deleteConnection(NetworkConnectionModel conn) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text(L10n.of(context).msg432fbb31, style: TextStyle(fontWeight: FontWeight.bold)),
        content: Text(L10n.of(context).msgdeleteconn(conn.name)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(L10n.of(context).ui_cancel),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red, foregroundColor: Colors.white),
            child: Text(L10n.of(context).ui_delete),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await NetworkConnectionsService.deleteConnection(conn.id);
      _loadConnections();
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Broken.arrow_left),
          onPressed: () => Navigator.pop(context),
        ),
        title: Text(
          L10n.of(context).ui_network,
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        actions: [
          IconButton(
            icon: const Icon(Broken.add),
            tooltip: L10n.of(context).msg3358aa10,
            onPressed: () async {
              await Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => NetworkConnectionWizardScreen(onNavigateTab: widget.onNavigateTab)),
              );
              _loadConnections();
            },
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _connections.isEmpty
              ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Broken.wifi, size: 64, color: theme.colorScheme.onSurface.withOpacity(0.15)),
                      const SizedBox(height: 20),
                      Text(
                        L10n.of(context).msgc9c900d0,
                        style: theme.textTheme.titleMedium?.copyWith(
                          color: theme.colorScheme.onSurface.withOpacity(0.5),
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        L10n.of(context).ftpsftpwebdavsmb1,
                        style: TextStyle(
                          color: theme.colorScheme.onSurface.withOpacity(0.4),
                          fontSize: 14,
                        ),
                      ),
                      const SizedBox(height: 24),
                      ElevatedButton.icon(
                        onPressed: () async {
                          await Navigator.push(
                            context,
                            MaterialPageRoute(builder: (_) => NetworkConnectionWizardScreen(onNavigateTab: widget.onNavigateTab)),
                          );
                          _loadConnections();
                        },
                        icon: const Icon(Broken.add),
                        label: Text(L10n.of(context).msg3358aa10),
                        style: ElevatedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                        ),
                      ),
                    ],
                  ),
                )
              : ListView.builder(
                  physics: const BouncingScrollPhysics(),
                  padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
                  itemCount: _connections.length,
                  itemBuilder: (context, index) {
                    final conn = _connections[index];
                    final color = _getColorForType(conn.type);
                    final iconData = _getIconForType(conn.type);

                    return Card(
                      margin: const EdgeInsets.only(bottom: 10),
                      elevation: 0,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                      color: isDark ? const Color(0xFF1E1E2A) : Colors.white,
                      child: ListTile(
                        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                        leading: Container(
                          width: 48,
                          height: 48,
                          decoration: BoxDecoration(
                            color: color.withOpacity(0.1),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Icon(iconData, color: color, size: 24),
                        ),
                        title: Text(
                          conn.name,
                          style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
                        ),
                        subtitle: Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Text(
                            '${conn.type} · ${conn.host}:${conn.port}',
                            style: TextStyle(
                              fontSize: 12,
                              color: theme.colorScheme.onSurface.withOpacity(0.5),
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              icon: Icon(Broken.edit, size: 18, color: theme.colorScheme.primary),
                              onPressed: () async {
                                await Navigator.push(
                                  context,
                                  MaterialPageRoute(
                                    builder: (_) => NetworkConnectionWizardScreen(existingConnection: conn),
                                  ),
                                );
                                _loadConnections();
                              },
                            ),
                            IconButton(
                              icon: const Icon(Broken.trash, size: 18, color: Colors.red),
                              onPressed: () => _deleteConnection(conn),
                            ),
                          ],
                        ),
                        onTap: () async {
                          final provider = context.read<FileManagerProvider>();
                          final client = FileManagerProvider.createRemoteClient(conn);
                          try {
                            await client.connect();
                            if (context.mounted) {
                              provider.openRemoteTab(client, conn);
                              // 通知首页切换到浏览页，并关闭当前页面
                              widget.onNavigateTab?.call(1);
                              Navigator.pop(context);
                            }
                          } catch (e) {
                            if (context.mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(content: Text(L10n.of(context).e13(e.toString())), backgroundColor: Colors.redAccent),
                              );
                            }
                          }
                        },
                      ),
                    );
                  },
                ),
    );
  }
}
