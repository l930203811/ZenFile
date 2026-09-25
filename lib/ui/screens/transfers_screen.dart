import 'package:flutter/material.dart';
import '../../core/icon_fonts/broken_icons.dart';
import '../../l10n/generated/app_localizations.dart';
import 'network_category_screen.dart';
import 'ftp_server_screen.dart';
import 'web_sharing_screen.dart';
import 'quick_transfer_screen.dart';

/// 传输页：以列表形式聚合「网络 / FTP共享 / Web共享 / 快传」四个入口，
/// UI 风格与工具箱（ToolboxScreen）一致。进入/退出动画由调用方统一控制。
class TransfersScreen extends StatelessWidget {
  /// 子页面（如网络）连接成功后通知首页切换底部 tab 的回调。
  final Function(int)? onNavigateTab;

  const TransfersScreen({super.key, this.onNavigateTab});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = L10n.of(context);

    final items = <_TransferItem>[
      _TransferItem(
        icon: Broken.wifi,
        title: l10n.cat_network,
        color: Colors.cyan.shade600,
        buildPage: () => NetworkCategoryScreen(
          onNavigateTab: onNavigateTab,
        ),
      ),
      _TransferItem(
        icon: Icons.swap_horizontal_circle_rounded,
        title: l10n.ftp,
        color: Colors.amber.shade700,
        buildPage: () => const FtpServerScreen(),
      ),
      _TransferItem(
        icon: Icons.language_rounded,
        title: l10n.web,
        color: Colors.indigo.shade400,
        buildPage: () => const WebSharingScreen(),
      ),
      _TransferItem(
        icon: Broken.send_2,
        title: l10n.quick_transfer,
        color: Colors.blue,
        buildPage: () => const QuickTransferScreen(),
      ),
    ];

    return Scaffold(
      backgroundColor: Colors.transparent,
      // 注意（勿删）：必须关掉 **Scaffold 自身的** primary —— 只给下面的 AppBar 设
      // primary: false 是**无效**的。依据 scaffold.dart：
      //   if (widget.appBar != null) {
      //     final double topPadding = widget.primary ? MediaQuery.paddingOf(context).top : 0.0;
      //     _appBarMaxHeight = AppBar.preferredHeightFor(...) + topPadding;
      //   }
      // 这里读的是 Scaffold.primary（默认 true）。本页位于 HomeScreen 的 IndexedStack 内，
      // 状态栏安全区已由 HomeScreen 顶部栏消费；若此处再加一次，AppBar 的 Material 会把这段
      // 状态栏高度铺成一条 surface 色背景条 —— 即「浏览页比分类页多出来的那一层」，
      // 与标签页栏显隐、多标签开关均无关系。
      primary: false,
      appBar: AppBar(
        primary: false,
        automaticallyImplyLeading: false,
        surfaceTintColor: Colors.transparent,
        scrolledUnderElevation: 0,
        toolbarHeight: 0,
        actions: const [SizedBox.shrink()],
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
            child: Text(
              l10n.ui_transfers,
              style: TextStyle(
                color: theme.colorScheme.onSurface,
                fontSize: 22,
                fontWeight: FontWeight.bold,
                letterSpacing: 0.5,
              ),
            ),
          ),
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
              itemCount: items.length,
              itemBuilder: (context, index) {
                final item = items[index];
                return Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Container(
                    decoration: BoxDecoration(
                      border: Border.all(
                        color: theme.colorScheme.onSurface.withOpacity(0.18),
                        width: 1,
                      ),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: ListTile(
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
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _TransferItem {
  final IconData icon;
  final String title;
  final Color color;
  final Widget Function() buildPage;

  const _TransferItem({
    required this.icon,
    required this.title,
    required this.color,
    required this.buildPage,
  });
}
