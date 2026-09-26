import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/icon_fonts/broken_icons.dart';
import '../../providers/file_manager_provider.dart';
import 'package:zenfile/l10n/generated/app_localizations.dart';
import '../screens/about_screen.dart';
import '../screens/decibel_meter_screen.dart';
import '../screens/ftp_server_screen.dart';
import '../screens/more_settings_screen.dart';
import '../screens/network_connection_wizard_screen.dart';
import '../screens/qr_scanner_screen.dart';
import '../screens/quick_transfer_screen.dart';
import '../screens/recycle_bin_screen.dart';
import '../screens/vault_lock_screen.dart';
import '../screens/wake_on_lan_screen.dart';
import '../screens/web_sharing_screen.dart';

import 'favorites_sheet.dart';

/// 全局搜索「功能入口」的分组。分组标题复用现有 l10n（见 [FeatureSearchIndex.groupTitle]）。
enum FeatureSearchGroup { quick, tools, nav }

/// 一条可被全局搜索命中的「功能入口」。
///
/// 与文件搜索结果不同，功能入口不依赖文件系统：它把「设置页 / 左侧抽屉 / 右侧
/// 抽屉」里已有的入口集中成一份可检索清单，命中后直接打开对应页面或执行动作。
///
/// ⚠️ 维护约定：以后往左右抽屉或设置页新增**入口级**功能时，同步在
/// [FeatureSearchIndex.build] 里补一条，否则全局搜索搜不到它。
/// （设置页内部的开关不必逐条登记 —— 全局搜索的「在设置中搜索」会把整句查询
/// 交给设置页自己的过滤逻辑，覆盖全部二级页条目。）
class FeatureSearchEntry {
  const FeatureSearchEntry({
    required this.group,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.keywords,
    required this.onOpen,
  });

  final FeatureSearchGroup group;

  final IconData icon;

  /// 展示标题（已本地化）。
  final String title;

  /// 展示副标题（已本地化，可为空串）。
  final String subtitle;

  /// 附加匹配关键词：小写、空格分隔、中英混合。
  ///
  /// 标题本身已本地化，能命中当前语言；关键词只用于补齐「同义说法 / 英文名」，
  /// 例如输入「刷新 / refresh / 重载」都能命同一条目。
  final String keywords;

  /// 命中后执行：先关闭搜索页（`navigator.popUntil` 回到首页），再打开目标页或
  /// 触发动作。
  ///
  /// ⚠️ `context` 在 pop 之后会失效（搜索页被 dispose），所以实现里必须**先**
  /// 取出 provider 等依赖，再 pop。
  final void Function(BuildContext context, NavigatorState navigator) onOpen;

  /// 是否命中查询（大小写不敏感，`queryLower` 需已转小写）。
  bool matches(String queryLower) {
    if (queryLower.isEmpty) return false;
    if (title.toLowerCase().contains(queryLower)) return true;
    if (subtitle.toLowerCase().contains(queryLower)) return true;
    return keywords.contains(queryLower);
  }
}

/// 功能入口清单（全局搜索用）。
class FeatureSearchIndex {
  const FeatureSearchIndex._();

  /// 分组标题（复用现有 l10n，不新增文案）。
  static String groupTitle(L10n l10n, FeatureSearchGroup group) {
    switch (group) {
      case FeatureSearchGroup.quick:
        return l10n.msg_quick_actions;
      case FeatureSearchGroup.tools:
        return l10n.drawer_tools;
      case FeatureSearchGroup.nav:
        return l10n.ui_search_group_nav;
    }
  }

  /// 构造当前语言下的功能入口清单。
  ///
  /// 调用方应缓存结果（本方法每次都会新建闭包），不要每帧调用。
  static List<FeatureSearchEntry> build(BuildContext context) {
    final l10n = L10n.of(context);
    final fileManager = context.read<FileManagerProvider>();

    // 打开某个全屏页面：先关掉搜索页回到首页，再 push。
    void openScreen(NavigatorState nav, Widget screen) {
      nav.popUntil((route) => route.isFirst);
      nav.push(MaterialPageRoute(builder: (_) => screen));
    }

    // 交给首页执行「依赖当前浏览页状态」的快捷操作（刷新 / 排序 / 主题 / 自定义）。
    // home_screen 监听 requestQuickAction 通道后按 action 名复用它自己已有的实现，
    // 避免在这里重复一份逻辑（否则两边行为会漂移）。
    void runQuickAction(BuildContext ctx, NavigatorState nav, String action) {
      final provider = ctx.read<FileManagerProvider>();
      nav.popUntil((route) => route.isFirst);
      provider.requestQuickAction(action);
    }

    // 切换根目录并跳到浏览页（对齐左侧抽屉里各存储卷的行为）。
    void openRootPath(BuildContext ctx, NavigatorState nav, String path) {
      final provider = ctx.read<FileManagerProvider>();
      nav.popUntil((route) => route.isFirst);
      provider.setRootPath(path);
      provider.loadDirectory(path);
      provider.setNavigateToBrowseTab(true);
    }

    return <FeatureSearchEntry>[
      // ============ 快捷操作（原右侧抽屉；收藏夹现为底部半屏面板） ============
      FeatureSearchEntry(
        group: FeatureSearchGroup.quick,
        icon: Broken.folder_favorite,
        title: l10n.ui_favorites,
        subtitle: l10n.msg_quick_actions,
        keywords: 'favorite bookmark favorites 收藏夹 书签 收藏 星标',
        onOpen: (ctx, nav) {
          // 先取出 provider（pop 之后搜索页 context 失效），再回首页弹底部面板；
          // 面板点收藏后靠 provider 通道切到浏览页（与首页自己的实现一致）。
          final provider = ctx.read<FileManagerProvider>();
          nav.popUntil((route) => route.isFirst);
          Future.delayed(const Duration(milliseconds: 220), () {
            FavoritesSheet.show(
              nav.context,
              provider: provider,
              onNavigateToBrowse: () => provider.setNavigateToBrowseTab(true),
            );
          });
        },
      ),
      FeatureSearchEntry(
        group: FeatureSearchGroup.quick,
        icon: Broken.refresh,
        title: l10n.msg354c1c9a,
        subtitle: l10n.msg_quick_actions,
        keywords: 'refresh reload rescan 刷新 重新加载 重载 重新扫描 更新',
        onOpen: (ctx, nav) => runQuickAction(ctx, nav, 'refresh'),
      ),
      FeatureSearchEntry(
        group: FeatureSearchGroup.quick,
        icon: Broken.filter_edit,
        title: l10n.msg97301f64,
        subtitle: l10n.msg_quick_actions,
        keywords: 'sort order 排序 排序方式 排列 顺序 名称 大小 时间 类型',
        onOpen: (ctx, nav) => runQuickAction(ctx, nav, 'sort'),
      ),
      FeatureSearchEntry(
        group: FeatureSearchGroup.quick,
        icon: Broken.edit_2,
        title: l10n.msge7d18d73,
        subtitle: l10n.msg_quick_actions,
        keywords: 'customize shortcuts 自定义 快捷方式 分类 卡片 快捷入口 定制',
        onOpen: (ctx, nav) => runQuickAction(ctx, nav, 'customize'),
      ),
      FeatureSearchEntry(
        group: FeatureSearchGroup.quick,
        icon: Broken.moon,
        title: l10n.ui_dark_mode,
        subtitle: l10n.msg_quick_actions,
        keywords: 'dark mode theme 深色 夜间 黑暗 暗色 主题 白天 light',
        onOpen: (ctx, nav) => runQuickAction(ctx, nav, 'toggle_theme'),
      ),
      FeatureSearchEntry(
        group: FeatureSearchGroup.quick,
        icon: fileManager.enableSplitScreen ? Broken.grid_1 : Broken.grid_2,
        title: fileManager.enableSplitScreen
            ? l10n.ui_single_window
            : l10n.ui_dual_window,
        subtitle: l10n.msg_quick_actions,
        keywords: 'split window pane 单窗口 双窗口 分屏 双栏 拆分视图 single dual',
        onOpen: (ctx, nav) {
          final provider = ctx.read<FileManagerProvider>();
          nav.popUntil((route) => route.isFirst);
          provider.toggleSplitScreen();
        },
      ),

      // ================= 工具（左侧抽屉） =================
      FeatureSearchEntry(
        group: FeatureSearchGroup.tools,
        icon: Broken.lock,
        title: l10n.msgbb590f19,
        subtitle: l10n.drawer_tools,
        keywords: 'vault lock 保险箱 加密 私密 密码 锁定 safe',
        onOpen: (ctx, nav) => openScreen(nav, const VaultLockScreen()),
      ),
      FeatureSearchEntry(
        group: FeatureSearchGroup.tools,
        icon: Broken.electricity,
        title: l10n.wol_title,
        subtitle: l10n.drawer_tools,
        keywords: 'wake on lan wol 网络唤醒 远程开机 开机',
        onOpen: (ctx, nav) => openScreen(nav, const WakeOnLanScreen()),
      ),
      FeatureSearchEntry(
        group: FeatureSearchGroup.tools,
        icon: Broken.send_2,
        title: l10n.quick_transfer,
        subtitle: l10n.drawer_tools,
        keywords: 'quick transfer 快速传输 传输 发送 互传 share',
        onOpen: (ctx, nav) => openScreen(nav, const QuickTransferScreen()),
      ),
      FeatureSearchEntry(
        group: FeatureSearchGroup.tools,
        icon: Broken.scan,
        title: l10n.toolbox_scan,
        subtitle: l10n.drawer_tools,
        keywords: 'scan qr 扫码 二维码 扫描',
        onOpen: (ctx, nav) => openScreen(nav, const QrScannerScreen()),
      ),
      FeatureSearchEntry(
        group: FeatureSearchGroup.tools,
        icon: Icons.graphic_eq_rounded,
        title: l10n.decibel_meter_title,
        subtitle: l10n.drawer_tools,
        keywords: 'decibel noise 分贝 噪音 噪声 声级 测量',
        onOpen: (ctx, nav) => openScreen(nav, const DecibelMeterScreen()),
      ),

      // ================= 导航（左侧抽屉） =================
      FeatureSearchEntry(
        group: FeatureSearchGroup.nav,
        icon: Broken.folder_open,
        title: l10n.msgd730e478,
        subtitle: l10n.ui_nav,
        keywords: 'root filesystem 根目录 系统 分区 dev proc',
        onOpen: (ctx, nav) => openRootPath(ctx, nav, '/'),
      ),
      FeatureSearchEntry(
        group: FeatureSearchGroup.nav,
        icon: Broken.trash,
        title: l10n.ui_recycle_bin,
        subtitle: l10n.ui_nav,
        keywords: 'recycle trash bin 回收站 垃圾箱 已删除 废纸篓',
        onOpen: (ctx, nav) => openScreen(nav, const RecycleBinScreen()),
      ),
      FeatureSearchEntry(
        group: FeatureSearchGroup.nav,
        icon: Broken.wifi,
        title: l10n.ftp2,
        subtitle: l10n.ui_nav,
        keywords: 'ftp server 服务器 共享 局域网 上传下载',
        onOpen: (ctx, nav) => openScreen(nav, const FtpServerScreen()),
      ),
      FeatureSearchEntry(
        group: FeatureSearchGroup.nav,
        icon: Icons.language_rounded,
        title: l10n.ui_web_share,
        subtitle: l10n.ui_nav,
        keywords: 'web share http 网页 共享 浏览器 局域网 webdav',
        onOpen: (ctx, nav) => openScreen(nav, const WebSharingScreen()),
      ),
      FeatureSearchEntry(
        group: FeatureSearchGroup.nav,
        icon: Icons.add_link_rounded,
        title: l10n.msg41e625d1,
        subtitle: l10n.ui_nav,
        keywords:
            'add connection smb sftp ftp webdav nas 新建连接 添加 远程 网络 服务器',
        onOpen: (ctx, nav) =>
            openScreen(nav, const NetworkConnectionWizardScreen()),
      ),
      FeatureSearchEntry(
        group: FeatureSearchGroup.nav,
        icon: Broken.setting_2,
        title: l10n.ui_personalize_settings,
        subtitle: l10n.ui_nav,
        keywords: 'settings preference 设置 偏好 选项 配置 个性化',
        onOpen: (ctx, nav) => openScreen(nav, const MoreSettingsScreen()),
      ),
      FeatureSearchEntry(
        group: FeatureSearchGroup.nav,
        icon: Broken.info_circle,
        title: l10n.zenfile1,
        subtitle: l10n.ui_nav,
        keywords: 'about version 关于 版本 信息 更新 反馈',
        onOpen: (ctx, nav) => openScreen(nav, const AboutZenFileScreen()),
      ),
    ];
  }
}
