import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/icon_fonts/broken_icons.dart';
import '../../providers/file_manager_provider.dart';
import '../widgets/persistent_nav_bar_scope.dart';
import 'package:zenfile/l10n/generated/app_localizations.dart';
import 'more_settings_screen.dart';
import '../widgets/circled_back_button.dart';

// ----------------------------------------------------
// 浏览页设置：子页面私有 + 跨页复用的顶层工具（自 more_settings_screen.dart
// 原样迁移，仅改为公开顶层函数 —— 读写仍是同一份 FileManagerProvider 状态）
// ----------------------------------------------------

// （v2.3：原「手风琴折叠分组」组件 CollapsibleSection 已删除 —— 「通用设置」
// 与「浏览页设置」的分组入口改为 SettingsGroupEntryCard 卡片 + 全屏子页面，
// 见 more_settings_screen.dart。）

/// 「三点禁用尾部信息」当前选项的文案。
String getTrailingInfoTypeLabel(BuildContext context, String option) {
  switch (option) {
    case 'dateTime': return L10n.of(context).msg11fea612;
    case 'sizeAndCount': return L10n.of(context).msg12e86877;
    case 'none':
    default:
      return L10n.of(context).msg7908038f;
  }
}

/// 「三点禁用尾部信息」样式选择弹窗。
void showTrailingInfoTypePickerDialog(BuildContext context, FileManagerProvider fileManager, ThemeData theme) {
  showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: theme.scaffoldBackgroundColor,
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
    builder: (ctx) {
      final current = fileManager.trailingInfoType;
      final options = [
        {'key': 'none', 'name': L10n.of(context).msg7908038f, 'desc': L10n.of(context).msg9136d4dc},
        {'key': 'dateTime', 'name': L10n.of(context).msg11fea612, 'desc': L10n.of(context).msg84986f91},
        {'key': 'sizeAndCount', 'name': L10n.of(context).msg12e86877, 'desc': L10n.of(context).msgfc000737},
      ];

      return SafeArea(
        child: Padding(
          padding: EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom),
          child: SingleChildScrollView(
            physics: const BouncingScrollPhysics(),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Center(child: Container(width: 40, height: 4, decoration: BoxDecoration(color: Colors.grey.withValues(alpha: 0.3), borderRadius: BorderRadius.circular(2)))),
                  const SizedBox(height: 16),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8.0),
                    child: Text(L10n.of(context).msg83de16cc, style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold)),
                  ),
                  const SizedBox(height: 6),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8.0),
                    child: Text(L10n.of(context).msgaa2a18a1, style: TextStyle(color: theme.colorScheme.onSurface.withValues(alpha: 0.6), fontSize: 13)),
                  ),
                  const SizedBox(height: 16),
                  ListView.builder(
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    itemCount: options.length,
                    itemBuilder: (_, i) {
                      final opt = options[i];
                      final key = opt['key'] as String;
                      final name = opt['name'] as String;
                      final desc = opt['desc'] as String;
                      final isSelected = current == key;
                      return ListTile(
                        contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                        leading: Container(
                          width: 36, height: 36,
                          decoration: BoxDecoration(
                            color: isSelected ? theme.colorScheme.primary : theme.colorScheme.primary.withValues(alpha: 0.1),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Icon(
                            key == 'none' ? Icons.visibility_off_rounded : key == 'dateTime' ? Icons.access_time_rounded : Icons.info_outline_rounded,
                            color: isSelected ? theme.colorScheme.onPrimary : theme.colorScheme.primary,
                            size: 20,
                          ),
                        ),
                        title: Text(name, style: TextStyle(fontWeight: isSelected ? FontWeight.bold : FontWeight.w600)),
                        subtitle: Text(desc, style: TextStyle(fontSize: 12, color: theme.colorScheme.onSurface.withValues(alpha: 0.5))),
                        trailing: isSelected ? Icon(Icons.radio_button_checked_rounded, color: theme.colorScheme.primary) : Icon(Icons.radio_button_off_rounded, color: theme.colorScheme.onSurface.withValues(alpha: 0.3)),
                        onTap: () {
                          fileManager.setTrailingInfoType(key);
                          Navigator.pop(ctx);
                        },
                      );
                    },
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    },
  );
}

/// 三点操作按钮显示模式的当前文案。
String getActionMenuModeLabel(BuildContext context, String mode) {
  final l10n = L10n.of(context);
  switch (mode) {
    case 'single':
      return l10n.ui_action_menu_mode_single;
    case 'dual':
      return l10n.ui_action_menu_mode_dual;
    default:
      return l10n.ui_action_menu_mode_all;
  }
}

/// 「显示三点操作按钮」模式选择弹窗：单选即生效并收起。
Future<void> showActionMenuModePicker(
  BuildContext context,
  FileManagerProvider fileManager,
  ThemeData theme,
) async {
  final l10n = L10n.of(context);
  final mode = await showModalBottomSheet<String>(
    context: context,
    showDragHandle: true,
    builder: (sheetContext) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
            child: Text(
              l10n.ui_select_action_menu_mode,
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          _buildActionMenuModeOption(
            sheetContext,
            fileManager,
            theme,
            mode: 'all',
            title: l10n.ui_action_menu_mode_all,
            icon: Icons.visibility_rounded,
          ),
          _buildActionMenuModeOption(
            sheetContext,
            fileManager,
            theme,
            mode: 'single',
            title: l10n.ui_action_menu_mode_single,
            icon: Icons.looks_one_rounded,
          ),
          _buildActionMenuModeOption(
            sheetContext,
            fileManager,
            theme,
            mode: 'dual',
            title: l10n.ui_action_menu_mode_dual,
            icon: Icons.looks_two_rounded,
          ),
          const SizedBox(height: 12),
        ],
      ),
    ),
  );
  if (mode != null) {
    fileManager.setActionMenuDisplayMode(mode);
  }
}

/// 弹窗内单个显示模式选项：点选即返回该模式并收起。
Widget _buildActionMenuModeOption(
  BuildContext sheetContext,
  FileManagerProvider fileManager,
  ThemeData theme, {
  required String mode,
  required String title,
  required IconData icon,
}) {
  final isSelected = fileManager.actionMenuDisplayMode == mode;
  return ListTile(
    leading: Icon(
      icon,
      color: isSelected
          ? theme.colorScheme.primary
          : theme.colorScheme.onSurface.withValues(alpha: 0.5),
    ),
    title: Text(
      title,
      style: TextStyle(
        fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
        color: isSelected
            ? theme.colorScheme.primary
            : theme.colorScheme.onSurface,
      ),
    ),
    trailing: Icon(
      isSelected
          ? Icons.radio_button_checked_rounded
          : Icons.radio_button_off_rounded,
      color: isSelected
          ? theme.colorScheme.primary
          : theme.colorScheme.onSurface.withValues(alpha: 0.3),
      size: 22,
    ),
    onTap: () => Navigator.pop(sheetContext, mode),
  );
}

/// 切换多标签页开关时弹出选择适用范围的下拉框。
void toggleMultiTabsWithScope(BuildContext context, FileManagerProvider fileManager, ThemeData theme) {
  // 切换开关；仅在切换后为「开启」时弹出范围选择器（关闭时直接生效，不打扰）。
  fileManager.toggleMultipleTabs();
  if (!fileManager.enableMultipleTabs) return;

  showModalBottomSheet(
    context: context,
    backgroundColor: theme.scaffoldBackgroundColor,
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
    builder: (ctx) {
      final currentMode = fileManager.multiTabPaneMode;
      final options = [
        {
          'key': MultiTabPaneMode.singleOnly.name,
          'name': L10n.of(context).ui_multi_tab_scope_single_only,
          'desc': L10n.of(context).msg4b0a7063,
          'icon': Broken.grid_1,
        },
        {
          'key': MultiTabPaneMode.splitOnly.name,
          'name': L10n.of(context).ui_multi_tab_scope_split_only,
          'desc': L10n.of(context).ui_multi_tab_scope_split_only_desc,
          'icon': Broken.grid_2,
        },
        {
          'key': MultiTabPaneMode.all.name,
          'name': L10n.of(context).ui_multi_tab_scope_all,
          'desc': L10n.of(context).ui_multi_tab_scope_all_desc,
          'icon': Broken.category,
        },
      ];

      return SafeArea(
        child: Padding(
          padding: EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom),
          child: SingleChildScrollView(
            physics: const BouncingScrollPhysics(),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Center(
                    child: Container(width: 40, height: 4, decoration: BoxDecoration(
                      color: theme.colorScheme.onSurface.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(2),
                    )),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    L10n.of(context).ui_multi_tab_scope_title,
                    style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold, fontFamily: 'LexendDeca'),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    L10n.of(context).ui_multi_tab_scope_subtitle,
                    style: TextStyle(color: theme.colorScheme.onSurface.withValues(alpha: 0.6), fontSize: 13, fontFamily: 'LexendDeca'),
                  ),
                  const SizedBox(height: 16),
                  ...options.map((opt) {
                    final key = opt['key'] as String;
                    final name = opt['name'] as String;
                    final desc = opt['desc'] as String;
                    final icon = opt['icon'] as IconData;
                    final isSelected = currentMode.name == key;
                    return ListTile(
                      contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                      leading: Icon(icon, size: 24, color: isSelected ? theme.colorScheme.primary : theme.colorScheme.onSurface.withValues(alpha: 0.6)),
                      title: Text(
                        name,
                        style: TextStyle(
                          fontWeight: isSelected ? FontWeight.bold : FontWeight.w600,
                          color: isSelected ? theme.colorScheme.primary : theme.colorScheme.onSurface,
                          fontFamily: 'LexendDeca',
                        ),
                      ),
                      subtitle: Text(
                        desc,
                        style: TextStyle(fontSize: 12, color: theme.colorScheme.onSurface.withValues(alpha: 0.5), fontFamily: 'LexendDeca'),
                      ),
                      trailing: isSelected
                          ? Icon(Icons.check_circle_rounded, color: theme.colorScheme.primary)
                          : null,
                      onTap: () {
                        final mode = MultiTabPaneMode.values.firstWhere((m) => m.name == key);
                        fileManager.setMultiTabPaneMode(mode);
                        Navigator.pop(ctx);
                      },
                    );
                  }),
                  const SizedBox(height: 12),
                ],
              ),
            ),
          ),
        ),
      );
    },
  );
}

/// 「浏览页设置」子页面（v2.3 重组）：改为「入口列表」—— 两个分组入口卡片，
/// 点击经 MaterialPageRoute 进入对应全屏子页面（不再使用手风琴折叠）。
///
/// 分组内容拆为两个子页：文件浏览器与导航 / 列表与布局样式（见下方
/// _BrowserNavGroupScreen 等）。所有开关仍读写 [FileManagerProvider] 同一份
/// 字段并落盘到 PreferencesService，prefs key 与读写语义不变。
/// 原「时间与日期显示」按方案留在「通用设置」，此处不再重复。
class BrowseSettingsScreen extends StatelessWidget {
  const BrowseSettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    // 「导航栏常驻其他页面」：开启时本页（全屏路由）也显示与首页同款的底部
    // 4-tab —— 点击经 HomeScreen.pendingTabSwitch 回首页并切换到对应 tab；
    // 开关关闭时原样返回本页，行为与接入前一致。
    return PersistentNavBarScope(
      child: Scaffold(
      appBar: AppBar(
        title: Text(L10n.of(context).ui_settings_browse_page),
        leading: const CircledBackButton(),
      ),
      body: SafeArea(
        child: ListView(
          physics: const BouncingScrollPhysics(),
          padding: EdgeInsets.only(top: 16, left: 16, right: 16, bottom: MediaQuery.paddingOf(context).bottom + 16),
          children: [
            // ===== 文件浏览器与导航：入口卡片 → 全屏子页面 =====
            SettingsGroupEntryCard(
              icon: Broken.folder,
              title: L10n.of(context).msg1cfeaace,
              subtitle: L10n.of(context).ui_settings_browser_nav_desc,
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const _BrowserNavGroupScreen()),
              ),
            ),
            // ===== 列表与布局样式：入口卡片 → 全屏子页面 =====
            SettingsGroupEntryCard(
              icon: Broken.row_vertical,
              title: L10n.of(context).ui_list_layout_style,
              subtitle: L10n.of(context).ui_settings_list_layout_desc,
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const _ListLayoutGroupScreen()),
              ),
            ),
          ],
        ),
      ),
      ),
    );
  }
}

/// 「文件浏览器与导航」全屏子页面（原手风琴组 0 内容原样迁入，共 10 项）。
///
/// 纯 UI 迁移：地址栏 / 悬浮添加按钮 / 远程云徽章 / 隐藏文件 / 自动打开新建
/// 文件夹 / 文件夹高亮 / 多标签页 / 分屏 / 拖拽（及确认弹窗子项），
/// 读写语义不变。
class _BrowserNavGroupScreen extends StatelessWidget {
  const _BrowserNavGroupScreen();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final fileManager = context.watch<FileManagerProvider>();

    // 「导航栏常驻其他页面」接入（详见 BrowseSettingsScreen 同款包装）。
    return PersistentNavBarScope(
      child: Scaffold(
      appBar: AppBar(
        title: Text(L10n.of(context).msg1cfeaace),
        leading: const CircledBackButton(),
      ),
      body: SafeArea(
        child: ListView(
          physics: const BouncingScrollPhysics(),
          padding: EdgeInsets.only(top: 16, left: 16, right: 16, bottom: MediaQuery.paddingOf(context).bottom + 16),
          children: [
            SettingsTile(
              icon: Broken.edit,
              title: L10n.of(context).msg26e4c5d6,
              subtitle: L10n.of(context).windows1,
              trailing: Transform.scale(
                scale: 0.85,
                child: Switch(
                  value: fileManager.showAddressBar,
                  activeColor: theme.colorScheme.primary,
                  onChanged: (_) => fileManager.toggleShowAddressBar(),
                ),
              ),
              onTap: () => fileManager.toggleShowAddressBar(),
            ),
            SettingsTile(
              icon: Broken.add_square,
              title: L10n.of(context).ui_show_action_bar,
              subtitle: L10n.of(context).msg11b1ec65,
              trailing: Transform.scale(
                scale: 0.85,
                child: Switch(
                  value: fileManager.showFloatingAddButton,
                  activeColor: theme.colorScheme.primary,
                  onChanged: (_) => fileManager.toggleFloatingAddButton(),
                ),
              ),
              onTap: () => fileManager.toggleFloatingAddButton(),
            ),
            SettingsTile(
              icon: Broken.cloud,
              title: L10n.of(context).ui_show_remote_cloud_badge,
              subtitle: L10n.of(context).msg_remote_cloud_badge,
              trailing: Transform.scale(
                scale: 0.85,
                child: Switch(
                  value: fileManager.showRemoteCloudBadge,
                  activeColor: theme.colorScheme.primary,
                  onChanged: (_) => fileManager.toggleRemoteCloudBadge(),
                ),
              ),
              onTap: () => fileManager.toggleRemoteCloudBadge(),
            ),
            SettingsTile(
              icon: Broken.folder_open,
              title: L10n.of(context).msg124d9054,
              subtitle: L10n.of(context).msg7e7765b6,
              trailing: Transform.scale(
                scale: 0.85,
                child: Switch(
                  value: fileManager.showHiddenFiles,
                  activeColor: theme.colorScheme.primary,
                  onChanged: (_) => fileManager.toggleHiddenFiles(),
                ),
              ),
              onTap: () => fileManager.toggleHiddenFiles(),
            ),
            SettingsTile(
              icon: Broken.folder_add,
              title: L10n.of(context).auto_open_created_folder,
              subtitle: L10n.of(context).auto_open_created_folder_desc,
              trailing: Transform.scale(
                scale: 0.85,
                child: Switch(
                  value: fileManager.autoOpenCreatedFolder,
                  activeColor: theme.colorScheme.primary,
                  onChanged: (_) => fileManager.toggleAutoOpenCreatedFolder(),
                ),
              ),
              onTap: () => fileManager.toggleAutoOpenCreatedFolder(),
            ),
            SettingsTile(
              icon: Broken.colorfilter,
              title: L10n.of(context).msgd33e3082,
              subtitle: L10n.of(context).msgdd69671b,
              trailing: Transform.scale(
                scale: 0.85,
                child: Switch(
                  value: fileManager.enableFolderHighlight,
                  activeColor: theme.colorScheme.primary,
                  onChanged: (_) => fileManager.toggleEnableFolderHighlight(),
                ),
              ),
              onTap: () => fileManager.toggleEnableFolderHighlight(),
            ),
            SettingsTile(
              icon: Broken.category,
              title: L10n.of(context).ui_enable_multi_tabs,
              subtitle: L10n.of(context).msg4b0a7063,
              trailing: Transform.scale(
                scale: 0.85,
                child: Switch(
                  value: fileManager.enableMultipleTabs,
                  activeColor: theme.colorScheme.primary,
                  onChanged: (_) => toggleMultiTabsWithScope(context, fileManager, theme),
                ),
              ),
              onTap: () => toggleMultiTabsWithScope(context, fileManager, theme),
            ),
            SettingsTile(
              icon: Icons.splitscreen,
              title: L10n.of(context).ui_enable_split_screen,
              subtitle: L10n.of(context).msgf04ac00d,
              trailing: Transform.scale(
                scale: 0.85,
                child: Switch(
                  value: fileManager.enableSplitScreen,
                  activeColor: theme.colorScheme.primary,
                  onChanged: (_) => fileManager.toggleSplitScreen(),
                ),
              ),
              onTap: () => fileManager.toggleSplitScreen(),
            ),
            SettingsTile(
              icon: Broken.folder_connection,
              title: L10n.of(context).ui_enable_drag_drop,
              subtitle: L10n.of(context).msgad54815d,
              trailing: Transform.scale(
                scale: 0.85,
                child: Switch(
                  value: fileManager.enableDragDrop,
                  activeColor: theme.colorScheme.primary,
                  onChanged: (_) => fileManager.toggleEnableDragDrop(),
                ),
              ),
              onTap: () => fileManager.toggleEnableDragDrop(),
            ),
            if (fileManager.enableDragDrop)
              Padding(
                padding: const EdgeInsets.only(left: 16.0),
                child: SettingsTile(
                  icon: Broken.task_square,
                  title: L10n.of(context).ui_confirm_drag_drop,
                  subtitle: L10n.of(context).msg5dff8f2d,
                  trailing: Transform.scale(
                    scale: 0.85,
                    child: Switch(
                      value: fileManager.showDragDropDialog,
                      activeColor: theme.colorScheme.primary,
                      onChanged: (_) => fileManager.toggleShowDragDropDialog(),
                    ),
                  ),
                  onTap: () => fileManager.toggleShowDragDropDialog(),
                ),
              ),
          ],
        ),
      ),
      ),
    );
  }
}

/// 「列表与布局样式」全屏子页面（原手风琴组 1 内容原样迁入，共 6 项）。
///
/// 纯 UI 迁移：文件夹内文件数 / 文件夹内容数 / 文件夹大小 / 自适应多行名称 /
/// 显示三点操作按钮（含显示模式弹窗）/ 三点禁用尾部信息，读写语义不变。
class _ListLayoutGroupScreen extends StatelessWidget {
  const _ListLayoutGroupScreen();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final fileManager = context.watch<FileManagerProvider>();

    // 「导航栏常驻其他页面」接入（详见 BrowseSettingsScreen 同款包装）。
    return PersistentNavBarScope(
      child: Scaffold(
      appBar: AppBar(
        title: Text(L10n.of(context).ui_list_layout_style),
        leading: const CircledBackButton(),
      ),
      body: SafeArea(
        child: ListView(
          physics: const BouncingScrollPhysics(),
          padding: EdgeInsets.only(top: 16, left: 16, right: 16, bottom: MediaQuery.paddingOf(context).bottom + 16),
          children: [
            SettingsTile(
              icon: Broken.document_text_1,
              title: L10n.of(context).msg86f3d70f,
              subtitle: L10n.of(context).msg40e9c325,
              trailing: Transform.scale(
                scale: 0.85,
                child: Switch(
                  value: fileManager.showFolderFileCount,
                  activeColor: theme.colorScheme.primary,
                  onChanged: (_) => fileManager.toggleFolderFileCount(),
                ),
              ),
              onTap: () => fileManager.toggleFolderFileCount(),
            ),
            SettingsTile(
              icon: Broken.folder_open,
              title: L10n.of(context).ui_show_folder_contents_count,
              subtitle: L10n.of(context).msga517863e,
              trailing: Transform.scale(
                scale: 0.85,
                child: Switch(
                  value: fileManager.showFolderContentsCount,
                  activeColor: theme.colorScheme.primary,
                  onChanged: (_) => fileManager.toggleFolderContentsCount(),
                ),
              ),
              onTap: () => fileManager.toggleFolderContentsCount(),
            ),
            SettingsTile(
              icon: Broken.document_text_1,
              title: L10n.of(context).ui_show_folder_size,
              subtitle: L10n.of(context).msg59a24fcb,
              trailing: Transform.scale(
                scale: 0.85,
                child: Switch(
                  value: fileManager.showFolderSizes,
                  activeColor: theme.colorScheme.primary,
                  onChanged: (_) => fileManager.toggleShowFolderSizes(),
                ),
              ),
              onTap: () => fileManager.toggleShowFolderSizes(),
            ),
            SettingsTile(
              icon: Broken.text,
              title: L10n.of(context).ui_adaptive_multiline_names,
              subtitle: L10n.of(context).msg1eda8a50,
              trailing: Transform.scale(
                scale: 0.85,
                child: Switch(
                  value: fileManager.adaptiveMultiLineNames,
                  activeColor: theme.colorScheme.primary,
                  onChanged: (_) => fileManager.toggleAdaptiveMultiLineNames(),
                ),
              ),
              onTap: () => fileManager.toggleAdaptiveMultiLineNames(),
            ),
            SettingsTile(
              icon: Icons.more_vert_rounded,
              title: L10n.of(context).ui_show_action_menu_buttons,
              subtitle: fileManager.showActionMenuButtons
                  ? getActionMenuModeLabel(
                      context,
                      fileManager.actionMenuDisplayMode,
                    )
                  : L10n.of(context).ui_action_menu_subtitle,
              trailing: Transform.scale(
                scale: 0.85,
                child: Switch(
                  value: fileManager.showActionMenuButtons,
                  activeColor: theme.colorScheme.primary,
                  onChanged: (val) {
                    fileManager.setShowActionMenuButtons(val);
                    // 开启时弹出显示模式选择；关闭时不弹
                    if (val) {
                      showActionMenuModePicker(
                        context,
                        fileManager,
                        theme,
                      );
                    }
                  },
                ),
              ),
              trailingInteractive: true,
              onTap: () {
                fileManager.setShowActionMenuButtons(true);
                showActionMenuModePicker(
                  context,
                  fileManager,
                  theme,
                );
              },
            ),
            // 三点按钮被关闭时，条目尾部显示什么（原列表布局页缺失该行，
            // 此前只能在搜索态触达；按方案落位到浏览页设置）。
            SettingsTile(
              icon: Icons.info_outline_rounded,
              title: L10n.of(context).ui_trailing_info_when_hidden,
              subtitle: getTrailingInfoTypeLabel(context, fileManager.trailingInfoType),
              onTap: () => showTrailingInfoTypePickerDialog(context, fileManager, theme),
            ),
          ],
        ),
      ),
      ),
    );
  }
}
