import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/icon_fonts/broken_icons.dart';
import '../../models/network_connection_model.dart';
import '../../services/network_connections_service.dart';
// ⛔ 聚合网盘暂时下线：登录态存储 import 已注释。
// import '../../services/netdisk_auth_store.dart';
import '../../providers/file_manager_provider.dart';
import '../../services/remote_guard_service.dart';
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
      // ⛔ 聚合网盘（夸克 / 阿里云盘）暂时下线：过滤掉 NETDISK_* 连接，避免残留的
      // 网盘连接出现在列表里、点开报错。恢复时去掉 .where 一行即可。
      _connections = NetworkConnectionsService.getConnections()
          .where((c) => !_isNetdisk(c))
          .toList();
      _isLoading = false;
    });
  }

  bool _isNetdisk(NetworkConnectionModel c) =>
      c.type.toLowerCase().contains('netdisk');

  IconData _getIconForType(String type) {
    if (FileManagerProvider.isSmbType(type)) return Icons.dns_rounded;
    // ⛔ 聚合网盘暂时下线：原先 quark / netdisk 的图标映射已移除。
    switch (type) {
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
    if (FileManagerProvider.isSmbType(type)) return const Color(0xFF5B21B6);
    // ⛔ 聚合网盘暂时下线：原先 quark / netdisk 的配色映射已移除。
    switch (type) {
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
      // ⛔ 聚合网盘暂时下线：删除网盘连接时同步清理登录态的逻辑已移除。
      _loadConnections();
    }
  }

  /// 拖动排序：先本地重排让 UI 立即跟上，再异步落盘。
  ///
  /// ⚠️ 直接用 [_connections]（已过滤掉下线网盘连接的可见列表）重排没问题，
  /// 但**不能**用它整体覆盖存储：那是全量列表的子集。真正的写回在
  /// [NetworkConnectionsService.reorderConnections] 里按 id 定位槽位完成。
  /// ⚠️ 回调用的是 `onReorderItem`（不是已废弃的 `onReorder`）：它给的 newIndex
  /// 已按「先移除再插入」换算过，这里**不能再 -1**，否则从下往上拖会偏一位。
  Future<void> _onReorderConnections(int oldIndex, int newIndex) async {
    if (oldIndex == newIndex) return;
    final list = List<NetworkConnectionModel>.of(_connections);
    if (oldIndex < 0 || oldIndex >= list.length) return;
    final moved = list.removeAt(oldIndex);
    list.insert(newIndex.clamp(0, list.length), moved);
    if (!mounted) return;
    setState(() => _connections = list);
    await NetworkConnectionsService.reorderConnections(list);
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
                      Icon(Broken.wifi, size: 64, color: theme.colorScheme.onSurface.withValues(alpha: 0.15)),
                      const SizedBox(height: 20),
                      Text(
                        L10n.of(context).msgc9c900d0,
                        style: theme.textTheme.titleMedium?.copyWith(
                          color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        L10n.of(context).ftpsftpwebdavsmb1,
                        style: TextStyle(
                          color: theme.colorScheme.onSurface.withValues(alpha: 0.4),
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
              : ReorderableListView.builder(
                  physics: const BouncingScrollPhysics(),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16.0,
                    vertical: 8.0,
                  ),
                  itemCount: _connections.length,
                  // 长按卡片即可上下拖动排序（卡片本身没有长按菜单，不冲突）。
                  onReorderItem: _onReorderConnections,
                  // 少于两条时拖动没有意义，不显示排序提示，避免多余的一行。
                  header: _connections.length < 2
                      ? null
                      : Padding(
                          padding: const EdgeInsets.fromLTRB(4, 0, 4, 2),
                          child: Text(
                            L10n.of(context).ui_connection_reorder_hint,
                            style: TextStyle(
                              fontSize: 12,
                              color: theme.colorScheme.onSurface.withValues(
                                alpha: 0.45,
                              ),
                            ),
                          ),
                        ),
                  itemBuilder: (context, index) {
                    final conn = _connections[index];
                    final color = _getColorForType(conn.type);
                    final iconData = _getIconForType(conn.type);

                    return Card(
                      // 拖动排序要求每项有稳定唯一的 key：连接 id 恒定。
                      key: ValueKey('conn_${conn.id}'),
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
                            color: color.withValues(alpha: 0.1),
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
                          // 协议连接显示类型与 host:port 两行（垂直方向有空间，两行都能完整展示）
                          // ⛔ 聚合网盘暂时下线：网盘「已登录」副标题分支已移除。
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                conn.type,
                                style: TextStyle(
                                  fontSize: 12,
                                  color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              const SizedBox(height: 2),
                              Text(
                                '${conn.host}:${conn.port}',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ],
                          ),
                        ),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            // ⛔ 聚合网盘暂时下线后列表里不会再有网盘连接，此处恒为 true，
                            // 保留判断以防旧设备上残留 NETDISK_* 记录。
                            if (!_isNetdisk(conn))
                              IconButton(
                                icon: Icon(Broken.edit, size: 18, color: theme.colorScheme.primary),
                                onPressed: () async {
                                  // 编辑页可见密码，远程保护开启且未解锁时先验证 PIN
                                  if (!await RemoteGuardService.guard(context)) return;
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
                          // 远程保护开启且未解锁时，先验证 PIN 再连接
                          if (!await RemoteGuardService.guard(context)) return;
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
                              final l10n = L10n.of(context);
                              // ⛔ 聚合网盘暂时下线：netdisk_auth_expired 专用提示与
                              // 「登录态过期即删除该连接」的处理一并移除。
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Text(l10n.e13(e.toString())),
                                  backgroundColor: Colors.redAccent,
                                ),
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
