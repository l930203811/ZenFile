// ⛔ 聚合网盘（夸克 / 阿里云盘）功能暂时下线 —— 2026-09-30。
// 原因：登录后进入目录仍有问题，暂不随正式版发布，代码原样保留待下次完善。
// 本文件目前已无生效引用（不参与构建）；恢复步骤见
// lib/services/network_connections_service.dart 文件头的说明。
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/icon_fonts/broken_icons.dart';
import '../../models/network_connection_model.dart';
import '../../services/network_connections_service.dart';
import '../../services/netdisk_auth_store.dart';
import '../../services/remote_guard_service.dart';
import '../../providers/file_manager_provider.dart';
import '../../l10n/generated/app_localizations.dart';

import 'netdisk_login_screen.dart';
import '../widgets/circled_back_button.dart';

/// 聚合网盘主页：列出已登录的网盘连接，提供添加入口。
///
/// 网盘连接复用「远程连接」模型（type 以 netdisk 开头），点击后经
/// [FileManagerProvider.openRemoteTab] 挂载为远程标签页，浏览 / 下载 / 播放
/// 能力与其它远程协议一致。
class NetdiskHomeScreen extends StatefulWidget {
  final Function(int)? onNavigateTab;

  const NetdiskHomeScreen({super.key, this.onNavigateTab});

  @override
  State<NetdiskHomeScreen> createState() => _NetdiskHomeScreenState();
}

class _NetdiskHomeScreenState extends State<NetdiskHomeScreen> {
  List<NetworkConnectionModel> _connections = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _load() {
    setState(() {
      _connections = NetworkConnectionsService.getConnections()
          .where((c) => c.type.toLowerCase().contains('netdisk'))
          .toList();
    });
  }

  bool _isQuark(NetworkConnectionModel c) =>
      c.type.toLowerCase().contains('quark');

  IconData _iconFor(NetworkConnectionModel c) =>
      _isQuark(c) ? Broken.cloud : Icons.cloud_rounded;

  Color _colorFor(NetworkConnectionModel c) =>
      _isQuark(c) ? const Color(0xFF2B6CB0) : const Color(0xFFFF6A00);

  /// 添加网盘：选择网盘 → 网页登录 → 保存连接与登录态。
  Future<void> _addNetdisk(String provider) async {
    final l10n = L10n.of(context);
    final isQuark = provider == 'quark';
    final name = isQuark ? l10n.netdisk_quark : l10n.netdisk_alipan;
    final id =
        'nd_${isQuark ? 'quark' : 'alipan'}_${DateTime.now().millisecondsSinceEpoch}';

    final auth = await Navigator.push<Map<String, dynamic>>(
      context,
      MaterialPageRoute(
        builder: (_) => NetdiskLoginScreen(provider: provider),
      ),
    );
    if (auth == null || !mounted) return;

    await NetdiskAuthStore.saveAuth(id, auth);
    await NetworkConnectionsService.saveConnection(NetworkConnectionModel(
      id: id,
      name: name,
      type: isQuark ? 'NETDISK_QUARK' : 'NETDISK_ALIPAN',
      host: provider,
      port: 0,
      username: '',
      password: '',
      rootPath: '/',
    ));
    if (mounted) _load();
  }

  Future<void> _openNetdisk(NetworkConnectionModel conn) async {
    final provider = context.read<FileManagerProvider>();
    if (!await RemoteGuardService.guard(context)) return;
    final client = FileManagerProvider.createRemoteClient(conn);
    try {
      await client.connect();
      if (!mounted) return;
      provider.openRemoteTab(client, conn);
      widget.onNavigateTab?.call(1);
      Navigator.pop(context);
    } catch (e) {
      if (mounted) {
        final l10n = L10n.of(context);
        final msg = e.toString() == 'netdisk_auth_expired'
            ? l10n.netdisk_auth_expired
            : l10n.e13(e.toString());
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(msg), backgroundColor: Colors.redAccent),
        );
        // 登录态失效：清理该连接，引导重新登录
        if (e.toString() == 'netdisk_auth_expired') {
          await NetworkConnectionsService.deleteConnection(conn.id);
          await NetdiskAuthStore.clearAuth(conn.id);
          if (mounted) _load();
        }
      }
    }
  }

  Future<void> _removeNetdisk(NetworkConnectionModel conn) async {
    final l10n = L10n.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text(l10n.msg432fbb31,
            style: const TextStyle(fontWeight: FontWeight.bold)),
        content: Text(l10n.msgdeleteconn(conn.name)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(l10n.ui_cancel),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(
                backgroundColor: Colors.red, foregroundColor: Colors.white),
            child: Text(l10n.ui_delete),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await NetworkConnectionsService.deleteConnection(conn.id);
      await NetdiskAuthStore.clearAuth(conn.id);
      if (mounted) _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = L10n.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      appBar: AppBar(
        leading: const CircledBackButton(),
        title: Text(
          l10n.netdisk,
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
        actions: [
          IconButton(
            icon: const Icon(Broken.add),
            tooltip: l10n.netdisk_add,
            onPressed: () => _showAddSheet(),
          ),
        ],
      ),
      body: _connections.isEmpty
          ? _buildEmpty(theme, l10n)
          : ListView.builder(
              physics: const BouncingScrollPhysics(),
              padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
              itemCount: _connections.length,
              itemBuilder: (context, index) {
                final conn = _connections[index];
                final color = _colorFor(conn);
                return Card(
                  margin: const EdgeInsets.only(bottom: 10),
                  elevation: 0,
                  shape:
                      RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                  color: isDark ? const Color(0xFF1E1E2A) : Colors.white,
                  child: ListTile(
                    contentPadding:
                        const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    leading: Container(
                      width: 48,
                      height: 48,
                      decoration: BoxDecoration(
                        color: color.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Icon(_iconFor(conn), color: color, size: 24),
                    ),
                    title: Text(
                      conn.name,
                      style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
                    ),
                    subtitle: Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(
                        l10n.netdisk_logged_in,
                        style: TextStyle(
                          fontSize: 12,
                          color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
                        ),
                      ),
                    ),
                    trailing: IconButton(
                      icon: const Icon(Broken.trash, size: 18, color: Colors.red),
                      onPressed: () => _removeNetdisk(conn),
                    ),
                    onTap: () => _openNetdisk(conn),
                  ),
                );
              },
            ),
    );
  }

  Widget _buildEmpty(ThemeData theme, L10n l10n) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.cloud_outlined,
              size: 64, color: theme.colorScheme.onSurface.withValues(alpha: 0.15)),
          const SizedBox(height: 20),
          Text(
            l10n.netdisk_empty,
            style: theme.textTheme.titleMedium?.copyWith(
              color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            l10n.netdisk_empty_hint,
            style: TextStyle(
              color: theme.colorScheme.onSurface.withValues(alpha: 0.4),
              fontSize: 14,
            ),
          ),
          const SizedBox(height: 24),
          ElevatedButton.icon(
            onPressed: () => _showAddSheet(),
            icon: const Icon(Broken.add),
            label: Text(l10n.netdisk_add),
            style: ElevatedButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
            ),
          ),
        ],
      ),
    );
  }

  void _showAddSheet() {
    final l10n = L10n.of(context);
    showModalBottomSheet<void>(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
              child: Text(
                l10n.netdisk_add,
                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
              ),
            ),
            ListTile(
              leading: Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  color: const Color(0xFF2B6CB0).withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Icon(Broken.cloud, color: Color(0xFF2B6CB0), size: 22),
              ),
              title: Text(l10n.netdisk_quark),
              onTap: () {
                Navigator.pop(ctx);
                _addNetdisk('quark');
              },
            ),
            ListTile(
              leading: Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  color: const Color(0xFFFF6A00).withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(10),
                ),
                child:
                    const Icon(Icons.cloud_rounded, color: Color(0xFFFF6A00), size: 22),
              ),
              title: Text(l10n.netdisk_alipan),
              onTap: () {
                Navigator.pop(ctx);
                _addNetdisk('alipan');
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }
}
