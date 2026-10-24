import 'dart:typed_data';
import 'package:flutter/material.dart';
import '../../core/icon_fonts/broken_icons.dart';
import '../../models/app_info_model.dart';
import '../../services/app_clone_service.dart';
import '../../services/app_manager_service.dart';
import '../widgets/file_action_dialogs.dart';
import 'package:zenfile/l10n/generated/app_localizations.dart';

/// ─────────────────────────────────────────────────────────────────────────────
/// 应用分身（Shizuku 多用户克隆）
///
/// 两个入口共用 [AppCloneFlow] 的流程组件：
///  1. APK 长按菜单「克隆到分身」→ [AppCloneFlow.cloneApk]（pm install --user）
///  2. 已装应用菜单「克隆到分身」→ [AppCloneFlow.cloneExistingApp]（毫秒级 install-existing）
///  3. 本页（分身管理）：列系统用户、管理分身内应用、建/删分身。
/// ─────────────────────────────────────────────────────────────────────────────
class AppCloneManagerScreen extends StatefulWidget {
  const AppCloneManagerScreen({super.key});

  @override
  State<AppCloneManagerScreen> createState() => _AppCloneManagerScreenState();
}

class _AppCloneManagerScreenState extends State<AppCloneManagerScreen> {
  bool _loading = true;
  bool _hasPrivilege = false;
  List<CloneUserInfo> _users = [];

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    setState(() => _loading = true);
    _hasPrivilege = await AppCloneService.hasPrivilege();
    List<CloneUserInfo> users = [];
    if (_hasPrivilege) {
      try {
        users = await AppCloneService.listUsers();
      } catch (_) {}
    }
    if (!mounted) return;
    setState(() {
      _users = users;
      _loading = false;
    });
  }

  /// 新建分身：默认命名「分身 1/2/…」（编号 = 当前用户总数，主用户占 1 个），
  /// 允许自定义名称。
  Future<void> _createUser() async {
    final l10n = L10n.of(context);
    final defaultName = l10n.ui_clone_default_user_name(_users.length);
    final name = await FileActionDialogs.showTextInputDialog(
      context,
      title: l10n.ui_clone_create_user,
      hint: l10n.ui_clone_user_name_hint,
      initialValue: defaultName,
      actionText: l10n.ui_save,
    );
    if (name == null || !mounted) return;
    try {
      await AppCloneService.createUser(name.trim().isEmpty ? defaultName : name.trim());
      if (!mounted) return;
      AppCloneFlow.showSnack(context, L10n.of(context).ui_clone_user_created);
      await _refresh();
    } catch (e) {
      if (!mounted) return;
      AppCloneFlow.showOpError(context, e);
    }
  }

  /// 删除分身用户（连同其内全部应用数据），需二次确认。
  Future<void> _deleteUser(CloneUserInfo user) async {
    final l10n = L10n.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text(l10n.ui_clone_delete_user),
        content: Text(l10n.ui_clone_delete_user_confirm(user.name)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(l10n.ui_cancel),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(ctx).colorScheme.error,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(l10n.ui_confirm),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await AppCloneService.removeUser(user.id);
      if (!mounted) return;
      AppCloneFlow.showSnack(context, L10n.of(context).ui_clone_user_removed);
    } catch (e) {
      if (!mounted) return;
      AppCloneFlow.showOpError(context, e);
    }
    if (mounted) await _refresh();
  }

  void _openUser(CloneUserInfo user) {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => _UserAppsPage(user: user)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = L10n.of(context);
    final cloneUsers = _users.where((u) => u.id != 0).toList();
    final primary = _users.where((u) => u.id == 0).toList();

    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      appBar: AppBar(
        elevation: 0,
        backgroundColor: theme.colorScheme.surface,
        leading: IconButton(
          icon: const Icon(Broken.arrow_left),
          onPressed: () => Navigator.pop(context),
        ),
        title: Text(
          l10n.ui_clone_feature_title,
          style: const TextStyle(fontWeight: FontWeight.w700),
        ),
        centerTitle: true,
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh_rounded),
            onPressed: _refresh,
            tooltip: l10n.msg93bc1f09,
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.symmetric(vertical: 8),
              children: [
                // ── 功能说明 ──────────────────────────────────────────────
                _bordered(
                  Padding(
                    padding: const EdgeInsets.all(14),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(Broken.info_circle, size: 20, color: theme.colorScheme.primary),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            l10n.ui_clone_feature_desc,
                            style: TextStyle(
                              fontSize: 12.5,
                              height: 1.4,
                              color: theme.textTheme.bodyMedium?.color?.withValues(alpha: 0.8),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  theme,
                ),
                // ── 无特权引导（Shizuku 未运行 / 未授权且无 root）──────────
                if (!_hasPrivilege) _buildPrivilegeBanner(theme),
                // ── 分身用户列表 ──────────────────────────────────────────
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                  child: Text(
                    l10n.ui_clone_users_title,
                    style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
                  ),
                ),
                for (final u in primary)
                  _bordered(
                    ListTile(
                      leading: const Icon(Broken.mobile),
                      title: Text(
                        l10n.ui_clone_primary_user,
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                      subtitle: Text('ID 0'),
                      onTap: () => _openUser(u),
                      trailing: const Icon(Broken.arrow_right_3, size: 16),
                    ),
                    theme,
                  ),
                for (final u in cloneUsers)
                  _bordered(
                    ListTile(
                      leading: const Icon(Broken.people),
                      title: Text(
                        u.name,
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                      subtitle: Text(
                        u.isRunning ? 'ID ${u.id} · ${l10n.ui_clone_running}' : 'ID ${u.id}',
                      ),
                      onTap: () => _openUser(u),
                      trailing: IconButton(
                        icon: Icon(Broken.trash, size: 20, color: theme.colorScheme.error),
                        tooltip: l10n.ui_clone_delete_user,
                        onPressed: () => _deleteUser(u),
                      ),
                    ),
                    theme,
                  ),
                _bordered(
                  ListTile(
                    leading: Icon(Icons.add_circle_outline_rounded, color: theme.colorScheme.primary),
                    title: Text(
                      l10n.ui_clone_create_user,
                      style: TextStyle(
                        fontWeight: FontWeight.w600,
                        color: theme.colorScheme.primary,
                      ),
                    ),
                    onTap: _createUser,
                  ),
                  theme,
                ),
                const SizedBox(height: 12),
              ],
            ),
    );
  }

  /// 无 Shizuku/root 时的引导横幅：样式与 AppManagerScreen 的权限横幅一致。
  Widget _buildPrivilegeBanner(ThemeData theme) {
    final l10n = L10n.of(context);
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: theme.colorScheme.primary.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: theme.colorScheme.primary.withValues(alpha: 0.15),
          width: 1.2,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Broken.info_circle, color: theme.colorScheme.primary, size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  l10n.ui_clone_need_privileged_title,
                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            l10n.ui_clone_need_privileged_desc,
            style: TextStyle(
              fontSize: 12.5,
              color: theme.textTheme.bodyMedium?.color?.withValues(alpha: 0.8),
              height: 1.3,
            ),
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: theme.colorScheme.primary,
                foregroundColor: theme.colorScheme.onPrimary,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                padding: const EdgeInsets.symmetric(vertical: 10),
                elevation: 0,
              ),
              onPressed: () async {
                await AppCloneService.requestPrivilege();
                if (mounted) await _refresh();
              },
              child: Text(
                l10n.ui_clone_grant_shizuku,
                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 条目统一样式（与 lyric_settings_page._bordered 同源）：12dp 圆角 +
  /// onSurface 12% 描边，本页不画分隔线。
  Widget _bordered(Widget child, ThemeData theme) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: theme.colorScheme.onSurface.withValues(alpha: 0.12),
        ),
      ),
      child: child,
    );
  }
}

/// 分身内应用列表页：展示该用户的第三方应用，支持启动 / 卸载分身内应用，
/// 以及把本机已装应用毫秒级装进该分身（pm install-existing）。
class _UserAppsPage extends StatefulWidget {
  final CloneUserInfo user;
  const _UserAppsPage({required this.user});

  @override
  State<_UserAppsPage> createState() => _UserAppsPageState();
}

class _UserAppsPageState extends State<_UserAppsPage> {
  bool _loading = true;
  List<String> _pkgs = [];
  // 本机（主用户）已装应用：包名 → 信息，用于显示应用名与图标。
  Map<String, AppInfoModel> _hostApps = {};
  final Map<String, Uint8List> _iconCache = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    List<String> pkgs = [];
    try {
      pkgs = await AppCloneService.listThirdPartyPackages(widget.user.id);
    } catch (_) {}
    try {
      final host = await AppManagerService.getInstalledApps(includeSystem: false);
      if (mounted) {
        setState(() => _hostApps = {for (final a in host) a.packageName: a});
      }
    } catch (_) {}
    if (!mounted) return;
    setState(() {
      _pkgs = pkgs;
      _loading = false;
    });
  }

  void _launch(String pkg) async {
    final l10n = L10n.of(context);
    final ok = await AppCloneService.launchAppForUser(widget.user.id, pkg).catchError((_) => false);
    if (!ok && mounted) {
      AppCloneFlow.showSnack(context, l10n.ui_clone_launch_failed);
    }
  }

  void _uninstall(String pkg) async {
    final l10n = L10n.of(context);
    final displayName = _hostApps[pkg]?.name ?? pkg;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text(l10n.ui_clone_uninstall),
        content: Text(l10n.ui_clone_uninstall_confirm(displayName)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(l10n.ui_cancel),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(ctx).colorScheme.error,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(l10n.ui_confirm),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await AppCloneService.uninstallForUser(widget.user.id, pkg);
      if (!mounted) return;
      AppCloneFlow.showSnack(context, l10n.ui_clone_uninstall_done);
    } catch (e) {
      if (!mounted) return;
      AppCloneFlow.showOpError(context, e);
    }
    if (mounted) await _load();
  }

  /// 「安装本机应用到该分身」选择器：列出本机有而该分身没有的第三方应用，
  /// 点击即毫秒级 install-existing。
  void _showInstallPicker() {
    final l10n = L10n.of(context);
    final theme = Theme.of(context);
    final missing =
        _hostApps.values.where((a) => !_pkgs.contains(a.packageName)).toList()
          ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    if (missing.isEmpty) {
      AppCloneFlow.showSnack(context, l10n.ui_clone_no_missing_apps);
      return;
    }
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (sheetCtx) => Container(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(sheetCtx).size.height * 0.75,
        ),
        decoration: BoxDecoration(
          color: theme.colorScheme.surface,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        ),
        child: SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Center(
                child: Container(
                  width: 38,
                  height: 4,
                  margin: const EdgeInsets.only(top: 12, bottom: 8),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
                child: Text(
                  l10n.ui_clone_install_host_apps,
                  style: theme.textTheme.titleMedium,
                ),
              ),
              Divider(height: 1, thickness: 1, color: theme.colorScheme.onSurface.withValues(alpha: 0.1)),
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: missing.length,
                  itemBuilder: (ctx, i) {
                    final app = missing[i];
                    return ListTile(
                      leading: _UserAppIcon(
                        packageName: app.packageName,
                        iconCache: _iconCache,
                      ),
                      title: Text(app.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                      subtitle: Text(
                        app.packageName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 11),
                      ),
                      trailing: Icon(
                        Icons.add_circle_outline_rounded,
                        color: theme.colorScheme.primary,
                      ),
                      onTap: () async {
                        final navigator = Navigator.of(sheetCtx);
                        try {
                          await AppCloneService.installExistingForUser(
                            widget.user.id,
                            app.packageName,
                          );
                          navigator.pop();
                          if (!mounted) return;
                          AppCloneFlow.showSnack(context, l10n.ui_clone_installed_existing);
                          await _load();
                        } catch (e) {
                          if (!ctx.mounted) return;
                          AppCloneFlow.showOpError(ctx, e);
                        }
                      },
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = L10n.of(context);
    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      appBar: AppBar(
        elevation: 0,
        backgroundColor: theme.colorScheme.surface,
        leading: IconButton(
          icon: const Icon(Broken.arrow_left),
          onPressed: () => Navigator.pop(context),
        ),
        title: Text(
          widget.user.name,
          style: const TextStyle(fontWeight: FontWeight.w700),
        ),
        centerTitle: true,
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh_rounded),
            onPressed: _load,
            tooltip: l10n.msg93bc1f09,
          ),
        ],
      ),
      body: Column(
        children: [
          // 头部操作条：把本机已装应用装进该分身
          Container(
            margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: theme.colorScheme.onSurface.withValues(alpha: 0.12),
              ),
            ),
            child: ListTile(
              leading: Icon(Icons.install_mobile_rounded, color: theme.colorScheme.primary),
              title: Text(
                l10n.ui_clone_install_host_apps,
                style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
              ),
              trailing: const Icon(Broken.arrow_right_3, size: 16),
              onTap: _showInstallPicker,
            ),
          ),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _pkgs.isEmpty
                    ? Center(
                        child: Text(
                          l10n.ui_clone_apps_empty,
                          style: TextStyle(
                            fontSize: 13,
                            color: theme.textTheme.bodyMedium?.color?.withValues(alpha: 0.5),
                          ),
                        ),
                      )
                    : ListView.builder(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        itemCount: _pkgs.length,
                        itemBuilder: (ctx, i) {
                          final pkg = _pkgs[i];
                          final displayName = _hostApps[pkg]?.name ?? pkg;
                          return ListTile(
                            leading: _UserAppIcon(packageName: pkg, iconCache: _iconCache),
                            title: Text(
                              displayName,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 14.5),
                            ),
                            subtitle: Text(
                              pkg,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 11),
                            ),
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                IconButton(
                                  icon: const Icon(Broken.play, size: 19),
                                  color: theme.colorScheme.primary,
                                  tooltip: l10n.ui_clone_launch,
                                  onPressed: () => _launch(pkg),
                                ),
                                IconButton(
                                  icon: Icon(Broken.trash, size: 19, color: theme.colorScheme.error),
                                  tooltip: l10n.ui_clone_uninstall,
                                  onPressed: () => _uninstall(pkg),
                                ),
                              ],
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

/// 应用图标（带缓存）：分身内只拿得到包名，名称/图标从本机已装应用信息匹配；
/// 本机没有的包（例如直接装进分身的应用）显示默认图标。
class _UserAppIcon extends StatelessWidget {
  final String packageName;
  final Map<String, Uint8List> iconCache;
  const _UserAppIcon({required this.packageName, required this.iconCache});

  @override
  Widget build(BuildContext context) {
    final cached = iconCache[packageName];
    if (cached != null) {
      return _img(cached);
    }
    return FutureBuilder<Uint8List?>(
      future: AppManagerService.getAppIcon(packageName),
      builder: (context, snapshot) {
        final data = snapshot.data;
        if (data != null) {
          iconCache[packageName] = data;
          return _img(data);
        }
        return Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(
            Broken.mobile,
            size: 20,
            color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.5),
          ),
        );
      },
    );
  }

  Widget _img(Uint8List data) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: Image.memory(data, width: 40, height: 40, fit: BoxFit.cover),
    );
  }
}

/// 「克隆到分身」流程组件：供 APK 长按菜单 / 已装应用菜单复用。
class AppCloneFlow {
  AppCloneFlow._();

  /// 统一 Snackbar 样式。
  static void showSnack(BuildContext context, String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), behavior: SnackBarBehavior.floating),
    );
  }

  /// 统一错误提示：userLimit / timeout 等映射为可读文案，其余带原始输出。
  static void showOpError(BuildContext context, Object e) {
    final l10n = L10n.of(context);
    final String msg;
    if (e is AppCloneException) {
      switch (e.code) {
        case AppCloneError.userLimit:
          msg = l10n.ui_clone_create_failed_limit;
          break;
        case AppCloneError.timeout:
          msg = l10n.ui_clone_cmd_timeout;
          break;
        case AppCloneError.noPrivilege:
          msg = l10n.ui_clone_need_privileged_title;
          break;
        case AppCloneError.failed:
          msg = e.raw.isEmpty ? l10n.ui_clone_op_failed('') : l10n.ui_clone_op_failed(e.raw);
          break;
      }
    } else {
      msg = l10n.ui_clone_op_failed('$e');
    }
    showSnack(context, msg);
  }

  /// 确保 Shizuku/root 特权可用：不可用时弹引导对话框并可一键请求 Shizuku 授权。
  static Future<bool> ensurePrivilege(BuildContext context) async {
    if (await AppCloneService.hasPrivilege()) return true;
    if (!context.mounted) return false;
    final l10n = L10n.of(context);
    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        icon: Icon(Icons.admin_panel_settings_outlined,
            color: Theme.of(ctx).colorScheme.primary, size: 40),
        title: Text(l10n.ui_clone_need_privileged_title),
        content: Text(l10n.ui_clone_need_privileged_desc),
        actionsAlignment: MainAxisAlignment.spaceEvenly,
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(l10n.ui_cancel),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(l10n.ui_clone_grant_shizuku),
          ),
        ],
      ),
    );
    if (go != true) return false;
    await AppCloneService.requestPrivilege();
    return AppCloneService.hasPrivilege();
  }

  /// 选择/新建分身用户：列出全部分身（不含主用户 0），底部提供「新建分身用户…」，
  /// 创建成功直接返回新 uid。用户取消返回 null。
  static Future<int?> pickOrCreateUser(BuildContext context, List<CloneUserInfo> users) async {
    final l10n = L10n.of(context);
    final theme = Theme.of(context);
    var creating = false;
    return showDialog<int>(
      context: context,
      builder: (dialogCtx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          title: Text(l10n.ui_clone_select_user),
          contentPadding: const EdgeInsets.fromLTRB(0, 16, 0, 0),
          content: SizedBox(
            width: double.maxFinite,
            child: users.isEmpty
                ? Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
                    child: Text(
                      l10n.ui_clone_need_privileged_desc,
                      style: const TextStyle(fontSize: 13, height: 1.4),
                    ),
                  )
                : ListView.builder(
                    shrinkWrap: true,
                    itemCount: users.length + 1,
                    itemBuilder: (listCtx, i) {
                      // 末项：新建分身用户入口
                      if (i == users.length) {
                        return ListTile(
                          leading: Icon(Icons.add_circle_outline_rounded,
                              color: theme.colorScheme.primary),
                          title: Text(
                            l10n.ui_clone_new_user,
                            style: TextStyle(
                              fontWeight: FontWeight.w600,
                              color: theme.colorScheme.primary,
                            ),
                          ),
                          enabled: !creating,
                          onTap: () async {
                            final navigator = Navigator.of(dialogCtx);
                            final messenger = ScaffoldMessenger.of(ctx);
                            final defaultName =
                                l10n.ui_clone_default_user_name(users.length + 1);
                            final name = await FileActionDialogs.showTextInputDialog(
                              dialogCtx,
                              title: l10n.ui_clone_create_user,
                              hint: l10n.ui_clone_user_name_hint,
                              initialValue: defaultName,
                              actionText: l10n.ui_save,
                            );
                            setDialogState(() => creating = true);
                            try {
                              final user = await AppCloneService.createUser(
                                (name == null || name.trim().isEmpty) ? defaultName : name.trim(),
                              );
                              navigator.pop(user.id);
                            } catch (e) {
                              setDialogState(() => creating = false);
                              messenger.showSnackBar(
                                SnackBar(
                                  content: Text(
                                    e is AppCloneException &&
                                            e.code == AppCloneError.userLimit
                                        ? l10n.ui_clone_create_failed_limit
                                        : l10n.ui_clone_op_failed('$e'),
                                  ),
                                  behavior: SnackBarBehavior.floating,
                                ),
                              );
                            }
                          },
                        );
                      }
                      final u = users[i];
                      return ListTile(
                        leading: const Icon(Broken.people),
                        title: Text(
                          u.name,
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                        subtitle: Text(
                          u.isRunning
                              ? 'ID ${u.id} · ${l10n.ui_clone_running}'
                              : 'ID ${u.id}',
                        ),
                        onTap: creating ? null : () => Navigator.pop(dialogCtx, u.id),
                      );
                    },
                  ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogCtx),
              child: Text(l10n.ui_cancel),
            ),
          ],
        ),
      ),
    );
  }

  /// 带进度对话框执行任务：成功/失败都确保进度框被关闭。
  static Future<T?> runWithProgress<T>(BuildContext context, Future<T> Function() task) async {
    final l10n = L10n.of(context);
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => AlertDialog(
        content: Row(
          children: [
            const CircularProgressIndicator(),
            const SizedBox(width: 20),
            Expanded(child: Text(l10n.ui_clone_installing)),
          ],
        ),
      ),
    );
    try {
      return await task();
    } finally {
      // 进度框弹在根 Navigator 上，用 rootNavigator 关闭（页面可能已切换）。
      final root = Navigator.of(context, rootNavigator: true);
      if (root.canPop()) root.pop();
    }
  }

  /// APK 长按菜单「克隆到分身」：选/建分身用户 → `pm install --user <uid> <apk>`。
  /// 成功后若能定位到新装包（安装前后 -3 包列表差集），提供「立即启动」。
  static Future<void> cloneApk(BuildContext context, String apkPath) async {
    if (!await ensurePrivilege(context)) return;
    if (!context.mounted) return;
    List<CloneUserInfo> users;
    try {
      users = (await AppCloneService.listUsers()).where((u) => u.id != 0).toList();
    } catch (e) {
      if (context.mounted) showOpError(context, e);
      return;
    }
    if (!context.mounted) return;
    final uid = await pickOrCreateUser(context, users);
    if (uid == null || !context.mounted) return;

    final l10n = L10n.of(context);
    final messenger = ScaffoldMessenger.of(context);
    // 安装前快照：pm install 不回传包名，靠 -3 包列表前后差集定位新装包。
    Set<String> before = {};
    try {
      before = (await AppCloneService.listThirdPartyPackages(uid)).toSet();
    } catch (_) {}
    if (!context.mounted) return;

    Object? installError;
    await runWithProgress(context, () async {
      try {
        await AppCloneService.installApkForUser(apkPath, uid);
      } catch (e) {
        installError = e;
      }
      return true;
    });
    if (installError != null) {
      if (context.mounted) showOpError(context, installError!);
      return;
    }
    if (!context.mounted) return;

    String? newPkg;
    try {
      final after = (await AppCloneService.listThirdPartyPackages(uid)).toSet();
      final diff = after.difference(before).toList();
      if (diff.isNotEmpty) newPkg = diff.first;
    } catch (_) {}

    messenger.showSnackBar(
      SnackBar(
        content: Text(l10n.ui_clone_install_success),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 5),
        action: newPkg == null
            ? null
            : SnackBarAction(
                label: l10n.ui_clone_launch_now,
                onPressed: () async {
                  final ok = await AppCloneService
                      .launchAppForUser(uid, newPkg!)
                      .catchError((_) => false);
                  if (!ok) {
                    messenger.showSnackBar(
                      SnackBar(
                        content: Text(l10n.ui_clone_launch_failed),
                        behavior: SnackBarBehavior.floating,
                      ),
                    );
                  }
                },
              ),
      ),
    );
  }

  /// 已装应用菜单「克隆到分身」：选/建分身用户 → 毫秒级 install-existing →
  /// 可「立即启动」。
  static Future<void> cloneExistingApp(BuildContext context, String packageName) async {
    if (!await ensurePrivilege(context)) return;
    if (!context.mounted) return;
    List<CloneUserInfo> users;
    try {
      users = (await AppCloneService.listUsers()).where((u) => u.id != 0).toList();
    } catch (e) {
      if (context.mounted) showOpError(context, e);
      return;
    }
    if (!context.mounted) return;
    final uid = await pickOrCreateUser(context, users);
    if (uid == null || !context.mounted) return;

    final l10n = L10n.of(context);
    final messenger = ScaffoldMessenger.of(context);
    Object? installError;
    await runWithProgress(context, () async {
      try {
        await AppCloneService.installExistingForUser(uid, packageName);
      } catch (e) {
        installError = e;
      }
      return true;
    });
    if (installError != null) {
      if (context.mounted) showOpError(context, installError!);
      return;
    }
    messenger.showSnackBar(
      SnackBar(
        content: Text(l10n.ui_clone_installed_existing),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 5),
        action: SnackBarAction(
          label: l10n.ui_clone_launch_now,
          onPressed: () async {
            final ok = await AppCloneService
                .launchAppForUser(uid, packageName)
                .catchError((_) => false);
            if (!ok) {
              messenger.showSnackBar(
                SnackBar(
                  content: Text(l10n.ui_clone_launch_failed),
                  behavior: SnackBarBehavior.floating,
                ),
              );
            }
          },
        ),
      ),
    );
  }
}
