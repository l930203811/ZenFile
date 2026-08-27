import 'package:flutter/material.dart';
import '../../core/icon_fonts/broken_icons.dart';
import '../../l10n/generated/app_localizations.dart';
import 'vault_lock_screen.dart';
import 'wake_on_lan_screen.dart';
import 'quick_transfer_screen.dart';

/// 工具箱子页面：以列表形式聚合「私人保险箱 / 局域网唤醒 / 快传」三个入口，
/// 点击进入对应页面。进入/退出本页的动画由调用方（网格/抽屉）统一控制，
/// 与分类页其它类别的子页面行为保持一致。
class ToolboxScreen extends StatelessWidget {
  const ToolboxScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = L10n.of(context);

    final items = <_ToolboxItem>[
      _ToolboxItem(
        icon: Broken.security_safe,
        title: l10n.msgbb590f19,
        color: Colors.orange.shade700,
        buildPage: () => const VaultLockScreen(),
      ),
      _ToolboxItem(
        icon: Broken.electricity,
        title: l10n.wol_title,
        color: Colors.green,
        buildPage: () => const WakeOnLanScreen(),
      ),
      _ToolboxItem(
        icon: Broken.send_2,
        title: l10n.quick_transfer,
        color: Colors.blue,
        buildPage: () => const QuickTransferScreen(),
      ),
    ];

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.cat_toolbox),
      ),
      body: ListView.separated(
        padding: const EdgeInsets.all(16),
        itemCount: items.length,
        separatorBuilder: (_, __) => const Divider(height: 1),
        itemBuilder: (context, index) {
          final item = items[index];
          return ListTile(
            leading: Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: item.color.withOpacity(0.15),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(item.icon, color: item.color, size: 24),
            ),
            title: Text(item.title),
            trailing: Icon(
              Icons.chevron_right,
              color: theme.colorScheme.onSurface.withOpacity(0.5),
            ),
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => item.buildPage()),
              );
            },
          );
        },
      ),
    );
  }
}

class _ToolboxItem {
  final IconData icon;
  final String title;
  final Color color;
  final Widget Function() buildPage;

  const _ToolboxItem({
    required this.icon,
    required this.title,
    required this.color,
    required this.buildPage,
  });
}
