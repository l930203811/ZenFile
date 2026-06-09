import 'dart:io';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../providers/file_manager_provider.dart';
import '../../core/icon_fonts/broken_icons.dart';
import '../../core/utils.dart';
import '../widgets/quick_categories_grid.dart';
import '../../services/preferences_service.dart';
import '../../services/recycle_bin_service.dart';
import 'package:path/path.dart' as p;
import 'internal_file_picker_screen.dart';
import 'backup_settings_screen.dart';
import '../../services/settings_backup_service.dart';

class MoreSettingsScreen extends StatefulWidget {
  const MoreSettingsScreen({super.key});

  @override
  State<MoreSettingsScreen> createState() => _MoreSettingsScreenState();
}

class _MoreSettingsScreenState extends State<MoreSettingsScreen> {
  bool _preferFolders = false;
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';
  bool _isSearching = false;

  @override
  void initState() {
    super.initState();
    _preferFolders = PreferencesService.getPreferFoldersInMedia();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  bool _shouldShow(String title, String subtitle) {
    if (_searchQuery.isEmpty) return true;
    final query = _searchQuery.toLowerCase();
    return title.toLowerCase().contains(query) || subtitle.toLowerCase().contains(query);
  }

  bool _shouldShowHeader(List<bool> visibilities) {
    if (_searchQuery.isEmpty) return true;
    return visibilities.contains(true);
  }

  String _getTrailingInfoTypeLabel(String option) {
    switch (option) {
      case 'dateTime': return '日期和时间';
      case 'sizeAndCount': return '文件大小 / 项目数';
      case 'none':
      default:
        return '无 / 隐藏信息';
    }
  }

  void _showTrailingInfoTypePickerDialog(BuildContext context, FileManagerProvider fileManager, ThemeData theme) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: theme.scaffoldBackgroundColor,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (ctx) {
        final current = fileManager.trailingInfoType;
        final options = [
          {'key': 'none', 'name': '无 / 隐藏信息', 'desc': '不在右侧显示额外信息'},
          {'key': 'dateTime', 'name': '日期和时间', 'desc': '显示最后修改日期和时间'},
          {'key': 'sizeAndCount', 'name': '文件大小 / 项目数', 'desc': '文件显示大小，文件夹显示项目数'},
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
                    Center(child: Container(width: 40, height: 4, decoration: BoxDecoration(color: Colors.grey.withOpacity(0.3), borderRadius: BorderRadius.circular(2)))),
                    const SizedBox(height: 16),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 8.0),
                      child: Text('选择尾部信息样式', style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold)),
                    ),
                    const SizedBox(height: 6),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 8.0),
                      child: Text('选择当三点操作按钮隐藏时，文件和文件夹右侧显示的内容。', style: TextStyle(color: theme.colorScheme.onSurface.withOpacity(0.6), fontSize: 13)),
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
                              color: isSelected ? theme.colorScheme.primary : theme.colorScheme.primary.withOpacity(0.1),
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Icon(
                              key == 'none' ? Icons.visibility_off_rounded : key == 'dateTime' ? Icons.access_time_rounded : Icons.info_outline_rounded,
                              color: isSelected ? theme.colorScheme.onPrimary : theme.colorScheme.primary,
                              size: 20,
                            ),
                          ),
                          title: Text(name, style: TextStyle(fontWeight: isSelected ? FontWeight.bold : FontWeight.w600)),
                          subtitle: Text(desc, style: TextStyle(fontSize: 12, color: theme.colorScheme.onSurface.withOpacity(0.5))),
                          trailing: isSelected ? Icon(Icons.radio_button_checked_rounded, color: theme.colorScheme.primary) : Icon(Icons.radio_button_off_rounded, color: theme.colorScheme.onSurface.withOpacity(0.3)),
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

  Widget _buildCategoryCard(
    BuildContext context,
    ThemeData theme, {
    required IconData icon,
    required String title,
    required String subtitle,
    required Widget targetScreen,
  }) {
    return Card(
      elevation: 0,
      margin: const EdgeInsets.symmetric(vertical: 6),
      color: theme.colorScheme.surface.withOpacity(0.5),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: theme.colorScheme.outline.withOpacity(0.1)),
      ),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        leading: Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: theme.colorScheme.primary.withOpacity(0.1),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Icon(icon, color: theme.colorScheme.primary, size: 22),
        ),
        title: Text(
          title,
          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
        ),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 4.0),
          child: Text(
            subtitle,
            style: TextStyle(fontSize: 12, color: theme.colorScheme.onSurface.withOpacity(0.6)),
          ),
        ),
        trailing: Icon(Icons.chevron_right_rounded, color: theme.colorScheme.onSurface.withOpacity(0.4), size: 22),
        onTap: () {
          Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => targetScreen),
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final fileManager = context.watch<FileManagerProvider>();

    // Visibilities for global search filtering
    final showAddressBarVis = _shouldShow('显示地址栏', '在文件列表顶部显示可编辑的Windows资源管理器风格地址栏');
    final preferFoldersVis = _shouldShow('默认相册首选视图', '直接以文件夹（相册）首选视图打开图片/视频快捷分类');
    final hideNavBarVis = _shouldShow('隐藏安卓导航栏', '隐藏底部导航栏以最大化屏幕空间（上滑可显示）');
    final resetViewersVis = _shouldShow('重置默认文件查看器', '清除所有已记住的"打开方式"关联');
    final skipDialogVis = _shouldShow('跳过"打开方式"对话框', '绕过应用选择对话框，直接使用默认查看器打开文件');
    final defaultBrowseVis = _shouldShow('默认进入浏览页', '启动时直接进入浏览存储管理器');
    final showFloatingVis = _shouldShow('显示浮动按钮', '在浏览页底部启用快速创建（+）按钮');
    final showHiddenVis = _shouldShow('显示隐藏文件', '显示以点(.)开头的系统文件和文件夹');
    final folderFileCountVis = _shouldShow('显示文件夹和文件计数标题', '在存储标题栏下显示文件夹和文件总数');
    final use24HourVis = _shouldShow('使用24小时制', '在列表中切换12小时（AM/PM）和24小时时间格式');
    final hideTimeDateVis = _shouldShow('在列表中隐藏时间和日期', '完全隐藏文件和文件夹的修改日期和时间');
    final folderContentsVis = _shouldShow('显示文件夹内容计数', '计算并显示目录中的文件和文件夹总数');
    final folderSizesVis = _shouldShow('显示文件夹大小', '计算并显示目录中所有文件的总大小（可能影响列表性能）');
    final bottomActionBarVis = _shouldShow('显示底部导航栏', '在浏览页启用底部操作栏');
    final hideActionTextVis = _shouldShow('隐藏操作栏文字标签', '在浏览和媒体页面的选择操作栏中仅显示图标');
    final showHomeBrowseNavVis = _shouldShow('显示首页和浏览底部栏', '切换首页底部导航栏的显示');
    final highlightFolderVis = _shouldShow('高亮退出文件夹', '返回时短暂闪烁并滚动到刚退出的文件夹');
    final mediaPreviewsVis = _shouldShow('显示媒体预览', '显示实际的图片和视频缩略图而非通用文件图标');
    final adaptiveNamesVis = _shouldShow('自适应多行文件名', '允许文件名换行显示3行而非截断');
    final hideActionButtonsVis = _shouldShow('隐藏三点操作按钮', '隐藏文件夹和文件旁边的三点菜单按钮');
    final dragDropVis = _shouldShow('启用拖放', '长按并拖动文件夹或文件将其移动到其他文件夹');
    final confirmDragVis = fileManager.enableDragDrop && _shouldShow('确认拖放操作', '拖放文件时显示选项弹窗（复制、移动、压缩）');
    final multipleTabsVis = _shouldShow('启用多标签页', '允许在单独的标签页中打开多个文件夹以便快速导航');
    final splitScreenVis = _shouldShow('启用分屏', '并排浏览两个目录并轻松传输文件');
    final disableLeftBackVis = _shouldShow('阻止左侧返回手势打开抽屉', '将屏幕左边缘排除在安卓系统返回手势之外，便于滑动打开抽屉。您仍可从右边缘滑动返回。');
    final rememberLastFolderVis = _shouldShow('记住上次打开的文件夹', '启动应用时打开上次浏览的文件夹');

    final generalStartupList = [
      defaultBrowseVis,
      rememberLastFolderVis,
      showHomeBrowseNavVis,
      hideNavBarVis,
      disableLeftBackVis,
    ];

    final fileExplorerList = [
      showAddressBarVis,
      showFloatingVis,
      showHiddenVis,
      highlightFolderVis,
      multipleTabsVis,
      splitScreenVis,
      dragDropVis,
      confirmDragVis,
    ];

    final listLayoutList = [
      folderFileCountVis,
      folderContentsVis,
      folderSizesVis,
      use24HourVis,
      hideTimeDateVis,
      adaptiveNamesVis,
      hideActionButtonsVis,
    ];

    final mediaActionsList = [
      preferFoldersVis,
      mediaPreviewsVis,
      skipDialogVis,
      resetViewersVis,
    ];

    final selectionActionBarList = [
      bottomActionBarVis,
      hideActionTextVis,
    ];

    final recycleBinVis = _shouldShow('启用回收站', '将删除的文件和文件夹移至隐藏的回收站而非永久删除');
    final autoDeleteDurationVis = RecycleBinService.isEnabled() && _shouldShow('自动删除回收站时长', _getAutoDeleteDaysLabel(RecycleBinService.getAutoDeleteDays()));
    final recycleBinList = [recycleBinVis, autoDeleteDurationVis];

    final accentColorVis = _shouldShow('主题色 / 动态主题', _getAccentColorLabel(fileManager.accentColorOption));
    final folderIconVis = _shouldShow('文件夹图标样式', _getFolderIconLabel(fileManager.folderIconOption));
    final menuIconStyleVis = _shouldShow('应用抽屉按钮样式', _getMenuIconStyleLabel(fileManager.menuIconStyle));
    final amoledVis = _shouldShow('AMOLED 纯黑模式', '在深色模式下为AMOLED屏幕使用纯黑背景');
    final appIconVis = _shouldShow('应用图标', _getAppIconLabel(fileManager.activeAppIcon));
    final typographyVis = _shouldShow('应用排版 / 字体', _getFontFamilyLabel(fileManager.fontFamilyOption));
    final appearanceList = [accentColorVis, folderIconVis, menuIconStyleVis, amoledVis, appIconVis, typographyVis];

    final customizeShortcutsVis = _shouldShow('自定义快捷方式', '重新排列和切换快捷分类项目的可见性');
    final showRecentVis = _shouldShow('显示最近文件', '在首页显示最近访问的文件列表');
    final homeScreenList = [customizeShortcutsVis, showRecentVis];

    final hasAnyMatch = generalStartupList.contains(true) ||
        fileExplorerList.contains(true) ||
        listLayoutList.contains(true) ||
        mediaActionsList.contains(true) ||
        selectionActionBarList.contains(true) ||
        recycleBinList.contains(true) ||
        appearanceList.contains(true) ||
        homeScreenList.contains(true);

    return PopScope(
      canPop: !_isSearching,
      onPopInvoked: (didPop) {
        if (didPop) return;
        if (_isSearching) {
          setState(() {
            _isSearching = false;
            _searchQuery = '';
            _searchController.clear();
          });
        }
      },
      child: Scaffold(
        appBar: AppBar(
          title: _isSearching
              ? TextField(
                  controller: _searchController,
                  autofocus: true,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w500,
                  ),
                  decoration: InputDecoration(
                    hintText: '搜索设置...',
                    border: InputBorder.none,
                    hintStyle: TextStyle(
                      color: theme.colorScheme.onSurface.withOpacity(0.4),
                    ),
                  ),
                  onChanged: (val) {
                    setState(() {
                      _searchQuery = val;
                    });
                  },
                )
              : const Text('更多设置'),
          leading: IconButton(
            icon: const Icon(Broken.arrow_left),
            onPressed: () {
              if (_isSearching) {
                setState(() {
                  _isSearching = false;
                  _searchQuery = '';
                  _searchController.clear();
                });
              } else {
                Navigator.pop(context);
              }
            },
          ),
          actions: [
            if (_isSearching)
              IconButton(
                icon: const Icon(Icons.clear_rounded),
                onPressed: () {
                  setState(() {
                    if (_searchController.text.isEmpty) {
                      _isSearching = false;
                    } else {
                      _searchController.clear();
                      _searchQuery = '';
                    }
                  });
                },
              )
            else
              IconButton(
                icon: const Icon(Broken.search_normal),
                onPressed: () {
                  setState(() {
                    _isSearching = true;
                  });
                },
              ),
          ],
        ),
        body: SafeArea(
          child: ListView(
            physics: const BouncingScrollPhysics(),
            padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 16),
            children: [
              if (_searchQuery.isEmpty) ...[
                Padding(
                  padding: const EdgeInsets.only(bottom: 16.0, left: 4.0),
                  child: Text(
                    '设置分类',
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                      color: theme.colorScheme.onSurface.withOpacity(0.8),
                    ),
                  ),
                ),
                _buildCategoryCard(
                  context,
                  theme,
                  icon: Broken.setting_2,
                  title: '常规与行为',
                  subtitle: '默认屏幕、导航控制和快捷方式',
                  targetScreen: const GeneralSettingsScreen(),
                ),
                _buildCategoryCard(
                  context,
                  theme,
                  icon: Broken.colorfilter,
                  title: '外观与主题',
                  subtitle: '主题、应用图标、文件夹样式和排版',
                  targetScreen: const AppearanceSettingsScreen(),
                ),
                _buildCategoryCard(
                  context,
                  theme,
                  icon: Broken.folder_open,
                  title: '文件浏览器选项',
                  subtitle: '地址栏、隐藏文件、标签页和拖放',
                  targetScreen: const ExplorerSettingsScreen(),
                ),
                _buildCategoryCard(
                  context,
                  theme,
                  icon: Broken.text,
                  title: '列表与布局样式',
                  subtitle: '文件夹大小、计数和时间/日期格式',
                  targetScreen: const LayoutSettingsScreen(),
                ),
                _buildCategoryCard(
                  context,
                  theme,
                  icon: Broken.image,
                  title: '媒体偏好',
                  subtitle: '默认相册视图和缩略图预览',
                  targetScreen: const MediaSettingsScreen(),
                ),
                _buildCategoryCard(
                  context,
                  theme,
                  icon: Broken.setting_3,
                  title: '文件操作与查看器',
                  subtitle: '打开操作和默认查看器配置',
                  targetScreen: const ActionsSettingsScreen(),
                ),
                _buildCategoryCard(
                  context,
                  theme,
                  icon: Broken.trash,
                  title: '回收站',
                  subtitle: '回收站开关和自动删除时长',
                  targetScreen: const TrashSettingsScreen(),
                ),
                SettingsTile(
                  icon: Broken.refresh_circle,
                  title: '备份与恢复',
                  subtitle: '备份或恢复所有应用设置',
                  trailing: Icon(Icons.chevron_right_rounded, color: theme.colorScheme.onSurface.withOpacity(0.4)),
                  onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const BackupSettingsScreen())),
                ),
              ] else ...[
                if (!hasAnyMatch) ...[
                  const SizedBox(height: 60),
                  Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Container(
                          padding: const EdgeInsets.all(20),
                          decoration: BoxDecoration(
                            color: theme.colorScheme.primary.withOpacity(0.08),
                            shape: BoxShape.circle,
                          ),
                          child: Icon(
                            Broken.search_normal,
                            size: 40,
                            color: theme.colorScheme.primary,
                          ),
                        ),
                        const SizedBox(height: 20),
                        Text(
                          '未找到设置',
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.bold,
                            color: theme.colorScheme.onSurface,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          '尝试搜索其他关键词',
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: theme.colorScheme.onSurface.withOpacity(0.55),
                          ),
                        ),
                      ],
                    ),
                  ),
                ] else ...[
                  if (_shouldShowHeader(generalStartupList) || _shouldShowHeader(selectionActionBarList) || _shouldShowHeader(homeScreenList)) ...[
                    _buildSectionHeader(theme, '常规与行为'),
                    if (defaultBrowseVis)
                      SettingsTile(
                        icon: Broken.folder_favorite,
                        title: '默认进入浏览页',
                        subtitle: '启动时直接进入浏览存储管理器',
                        trailing: Transform.scale(
                          scale: 0.85,
                          child: Switch(
                            value: fileManager.defaultToBrowseScreen,
                            activeColor: theme.colorScheme.primary,
                            onChanged: (_) => fileManager.toggleDefaultToBrowseScreen(),
                          ),
                        ),
                        onTap: () => fileManager.toggleDefaultToBrowseScreen(),
                      ),
                    if (rememberLastFolderVis)
                      SettingsTile(
                        icon: Broken.folder_open,
                        title: '记住上次打开的文件夹',
                        subtitle: '启动应用时打开上次浏览的文件夹',
                        trailing: Transform.scale(
                          scale: 0.85,
                          child: Switch(
                            value: fileManager.rememberLastFolder,
                            activeColor: theme.colorScheme.primary,
                            onChanged: (_) => fileManager.toggleRememberLastFolder(),
                          ),
                        ),
                        onTap: () => fileManager.toggleRememberLastFolder(),
                      ),
                    if (showHomeBrowseNavVis)
                      SettingsTile(
                        icon: Broken.menu,
                        title: '显示首页和浏览底部栏',
                        subtitle: '切换首页底部导航栏的显示',
                        trailing: Transform.scale(
                          scale: 0.85,
                          child: Switch(
                            value: fileManager.showHomeBrowseNav,
                            activeColor: theme.colorScheme.primary,
                            onChanged: (_) => fileManager.toggleShowHomeBrowseNav(),
                          ),
                        ),
                        onTap: () => fileManager.toggleShowHomeBrowseNav(),
                      ),
                    SettingsTile(
                      icon: Broken.menu_1,
                      title: '隐藏底部导航标签',
                      subtitle: '隐藏底部栏（首页/浏览）的文字标签，更简洁紧凑',
                      trailing: Transform.scale(
                        scale: 0.85,
                        child: Switch(
                          value: fileManager.hideNavLabels,
                          activeColor: theme.colorScheme.primary,
                          onChanged: (_) => fileManager.toggleHideNavLabels(),
                        ),
                      ),
                      onTap: () => fileManager.toggleHideNavLabels(),
                    ),
                    if (hideNavBarVis)
                      SettingsTile(
                        icon: Icons.android,
                        title: '隐藏安卓导航栏',
                        subtitle: '隐藏底部导航栏以最大化屏幕空间（上滑可显示）',
                        trailing: Transform.scale(
                          scale: 0.85,
                          child: Switch(
                            value: fileManager.hideNavigationBar,
                            activeColor: theme.colorScheme.primary,
                            onChanged: (_) => fileManager.toggleHideNavigationBar(),
                          ),
                        ),
                        onTap: () => fileManager.toggleHideNavigationBar(),
                      ),
                    if (disableLeftBackVis)
                      SettingsTile(
                        icon: Icons.gesture,
                        title: '阻止左侧返回手势打开抽屉',
                        subtitle: '将屏幕左边缘排除在安卓系统返回手势之外，便于滑动打开抽屉。您仍可从右边缘滑动返回。',
                        trailing: Transform.scale(
                          scale: 0.85,
                          child: Switch(
                            value: fileManager.disableLeftBackGesture,
                            activeColor: theme.colorScheme.primary,
                            onChanged: (_) => fileManager.toggleDisableLeftBackGesture(),
                          ),
                        ),
                        onTap: () => fileManager.toggleDisableLeftBackGesture(),
                      ),
                    if (bottomActionBarVis)
                      SettingsTile(
                        icon: Broken.menu,
                        title: '显示底部导航栏',
                        subtitle: '在浏览页启用底部操作栏',
                        trailing: Transform.scale(
                          scale: 0.85,
                          child: Switch(
                            value: fileManager.showBottomActionBar,
                            activeColor: theme.colorScheme.primary,
                            onChanged: (_) => fileManager.toggleBottomActionBar(),
                          ),
                        ),
                        onTap: () => fileManager.toggleBottomActionBar(),
                      ),
                    if (hideActionTextVis)
                      SettingsTile(
                        icon: Icons.label_off_rounded,
                        title: '隐藏操作栏文字标签',
                        subtitle: '在浏览和媒体页面的选择操作栏中仅显示图标',
                        trailing: Transform.scale(
                          scale: 0.85,
                          child: Switch(
                            value: fileManager.hideActionText,
                            activeColor: theme.colorScheme.primary,
                            onChanged: (_) => fileManager.toggleHideActionText(),
                          ),
                        ),
                        onTap: () => fileManager.toggleHideActionText(),
                      ),
                    if (customizeShortcutsVis)
                      SettingsTile(
                        icon: Broken.setting_2,
                        title: '自定义快捷方式',
                        subtitle: '重新排列和切换快捷分类项目的可见性',
                        onTap: () => QuickCategoriesGrid.showCustomizeDialog(context),
                      ),
                    if (showRecentVis)
                      SettingsTile(
                        icon: Broken.clock,
                        title: '显示最近文件',
                        subtitle: '在首页显示最近访问的文件列表',
                        trailing: Transform.scale(
                          scale: 0.85,
                          child: Switch(
                            value: fileManager.showRecentFiles,
                            activeColor: theme.colorScheme.primary,
                            onChanged: (_) => fileManager.toggleShowRecentFiles(),
                          ),
                        ),
                        onTap: () => fileManager.toggleShowRecentFiles(),
                      ),
                  ],
                  if (_shouldShowHeader(appearanceList)) ...[
                    const SizedBox(height: 24),
                    _buildSectionHeader(theme, '外观与主题'),
                    if (accentColorVis)
                      SettingsTile(
                        icon: Broken.colorfilter,
                        title: '主题色 / 动态主题',
                        subtitle: _getAccentColorLabel(fileManager.accentColorOption),
                        onTap: () => _showThemePickerDialog(context, fileManager, theme),
                      ),
                    if (folderIconVis)
                      SettingsTile(
                        icon: FileUtils.getFolderIcon(fileManager.folderIconOption),
                        title: '文件夹图标样式',
                        subtitle: _getFolderIconLabel(fileManager.folderIconOption),
                        onTap: () => _showFolderIconPickerDialog(context, fileManager, theme),
                      ),
                    if (menuIconStyleVis)
                      SettingsTile(
                        icon: Broken.category,
                        title: '应用抽屉按钮样式',
                        subtitle: _getMenuIconStyleLabel(fileManager.menuIconStyle),
                        onTap: () => _showMenuIconStylePickerDialog(context, fileManager, theme),
                      ),
                    if (amoledVis)
                      SettingsTile(
                        icon: Broken.moon,
                        title: 'AMOLED 纯黑模式',
                        subtitle: '在深色模式下为AMOLED屏幕使用纯黑背景',
                        trailing: Transform.scale(
                          scale: 0.85,
                          child: Switch(
                            value: fileManager.amoledMode,
                            activeColor: theme.colorScheme.primary,
                            onChanged: (_) => fileManager.toggleAmoledMode(),
                          ),
                        ),
                        onTap: () => fileManager.toggleAmoledMode(),
                      ),
                    if (appIconVis)
                      SettingsTile(
                        icon: Broken.category,
                        title: '应用图标',
                        subtitle: _getAppIconLabel(fileManager.activeAppIcon),
                        onTap: () => _showAppIconPickerDialog(context, fileManager, theme),
                      ),
                    if (typographyVis)
                      SettingsTile(
                        icon: Broken.text,
                        title: '应用排版 / 字体',
                        subtitle: _getFontFamilyLabel(fileManager.fontFamilyOption),
                        onTap: () => _showFontFamilyPickerDialog(context, fileManager, theme),
                      ),
                  ],
                  if (_shouldShowHeader(fileExplorerList)) ...[
                    const SizedBox(height: 24),
                    _buildSectionHeader(theme, '文件浏览器与导航'),
                    if (showAddressBarVis)
                      SettingsTile(
                        icon: Broken.edit,
                        title: '显示地址栏',
                        subtitle: '在文件列表顶部显示可编辑的Windows资源管理器风格地址栏',
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
                    if (showFloatingVis)
                      SettingsTile(
                        icon: Broken.add_square,
                        title: '显示浮动按钮',
                        subtitle: '在浏览页底部启用快速创建（+）按钮',
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
                    if (showHiddenVis)
                      SettingsTile(
                        icon: Broken.folder_open,
                        title: '显示隐藏文件',
                        subtitle: '显示以点(.)开头的系统文件和文件夹',
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
                    if (highlightFolderVis)
                      SettingsTile(
                        icon: Broken.colorfilter,
                        title: '高亮退出文件夹',
                        subtitle: '返回时短暂闪烁并滚动到刚退出的文件夹',
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
                    if (multipleTabsVis)
                      SettingsTile(
                        icon: Broken.category,
                        title: '启用多标签页',
                        subtitle: '允许在单独的标签页中打开多个文件夹以便快速导航',
                        trailing: Transform.scale(
                          scale: 0.85,
                          child: Switch(
                            value: fileManager.enableMultipleTabs,
                            activeColor: theme.colorScheme.primary,
                            onChanged: (_) => fileManager.toggleMultipleTabs(),
                          ),
                        ),
                        onTap: () => fileManager.toggleMultipleTabs(),
                      ),
                    if (splitScreenVis)
                      SettingsTile(
                        icon: Icons.splitscreen,
                        title: '启用分屏',
                        subtitle: '并排浏览两个目录并轻松传输文件',
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
                    if (dragDropVis)
                      SettingsTile(
                        icon: Broken.folder_connection,
                        title: '启用拖放',
                        subtitle: '长按并拖动文件夹或文件将其移动到其他文件夹',
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
                    if (confirmDragVis)
                      Padding(
                        padding: const EdgeInsets.only(left: 16.0),
                        child: SettingsTile(
                          icon: Broken.task_square,
                          title: '确认拖放操作',
                          subtitle: '拖放文件时显示选项弹窗（复制、移动、压缩）',
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
                  if (_shouldShowHeader(listLayoutList)) ...[
                    const SizedBox(height: 24),
                    _buildSectionHeader(theme, '列表与布局样式'),
                    if (folderFileCountVis)
                      SettingsTile(
                        icon: Broken.document_text_1,
                        title: '显示文件夹和文件计数标题',
                        subtitle: '在存储标题栏下显示文件夹和文件总数',
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
                    if (folderContentsVis)
                      SettingsTile(
                        icon: Broken.folder_open,
                        title: '显示文件夹内容计数',
                        subtitle: '计算并显示目录中的文件和文件夹总数',
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
                    if (folderSizesVis)
                      SettingsTile(
                        icon: Broken.document_text_1,
                        title: '显示文件夹大小',
                        subtitle: '计算并显示目录中所有文件的总大小（可能影响列表性能）',
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
                    if (use24HourVis)
                      SettingsTile(
                        icon: Icons.access_time_rounded,
                        title: '使用24小时制',
                        subtitle: '在列表中切换12小时（AM/PM）和24小时时间格式',
                        trailing: Transform.scale(
                          scale: 0.85,
                          child: Switch(
                            value: fileManager.use24HourFormat,
                            activeColor: theme.colorScheme.primary,
                            onChanged: (_) => fileManager.toggleUse24HourFormat(),
                          ),
                        ),
                        onTap: () => fileManager.toggleUse24HourFormat(),
                      ),
                    if (hideTimeDateVis)
                      SettingsTile(
                        icon: Icons.visibility_off_rounded,
                        title: '在列表中隐藏时间和日期',
                        subtitle: '完全隐藏文件和文件夹的修改日期和时间',
                        trailing: Transform.scale(
                          scale: 0.85,
                          child: Switch(
                            value: fileManager.hideTimeAndDate,
                            activeColor: theme.colorScheme.primary,
                            onChanged: (_) => fileManager.toggleHideTimeAndDate(),
                          ),
                        ),
                        onTap: () => fileManager.toggleHideTimeAndDate(),
                      ),
                    if (adaptiveNamesVis)
                      SettingsTile(
                        icon: Broken.text,
                        title: '自适应多行文件名',
                        subtitle: '允许文件名换行显示3行而非截断',
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
                    if (hideActionButtonsVis)
                      SettingsTile(
                        icon: Icons.more_vert_rounded,
                        title: '隐藏三点操作按钮',
                        subtitle: '隐藏文件夹和文件旁边的三点菜单按钮',
                        trailing: Transform.scale(
                          scale: 0.85,
                          child: Switch(
                            value: fileManager.hideActionMenuButtons,
                            activeColor: theme.colorScheme.primary,
                            onChanged: (_) => fileManager.toggleHideActionMenuButtons(),
                          ),
                        ),
                        onTap: () => fileManager.toggleHideActionMenuButtons(),
                      ),
                    SettingsTile(
                      icon: Icons.info_outline_rounded,
                      title: '三点禁用尾部信息',
                      subtitle: _getTrailingInfoTypeLabel(fileManager.trailingInfoType),
                      onTap: () => _showTrailingInfoTypePickerDialog(context, fileManager, theme),
                    ),
                  ],
                  if (_shouldShowHeader(mediaActionsList)) ...[
                    const SizedBox(height: 24),
                    _buildSectionHeader(theme, '媒体与默认操作'),
                    if (preferFoldersVis)
                      SettingsTile(
                        icon: Broken.folder_2,
                        title: '默认相册首选视图',
                        subtitle: '直接以文件夹（相册）首选视图打开图片/视频快捷分类',
                        trailing: Transform.scale(
                          scale: 0.85,
                          child: Switch(
                            value: _preferFolders,
                            activeColor: theme.colorScheme.primary,
                            onChanged: (val) {
                              setState(() {
                                _preferFolders = val;
                              });
                              PreferencesService.savePreferFoldersInMedia(val);
                            },
                          ),
                        ),
                        onTap: () {
                          final val = !_preferFolders;
                          setState(() {
                            _preferFolders = val;
                          });
                          PreferencesService.savePreferFoldersInMedia(val);
                        },
                      ),
                    if (mediaPreviewsVis)
                      SettingsTile(
                        icon: Broken.image,
                        title: '显示媒体预览',
                        subtitle: '显示实际的图片和视频缩略图而非通用文件图标',
                        trailing: Transform.scale(
                          scale: 0.85,
                          child: Switch(
                            value: fileManager.showMediaPreviews,
                            activeColor: theme.colorScheme.primary,
                            onChanged: (_) => fileManager.toggleMediaPreviews(),
                          ),
                        ),
                        onTap: () => fileManager.toggleMediaPreviews(),
                      ),
                    if (skipDialogVis)
                      SettingsTile(
                        icon: Broken.setting_3,
                        title: '跳过"打开方式"对话框',
                        subtitle: '绕过应用选择对话框，直接使用默认查看器打开文件',
                        trailing: Transform.scale(
                          scale: 0.85,
                          child: Switch(
                            value: fileManager.skipOpenWithDialog,
                            activeColor: theme.colorScheme.primary,
                            onChanged: (_) => fileManager.toggleSkipOpenWithDialog(),
                          ),
                        ),
                        onTap: () => fileManager.toggleSkipOpenWithDialog(),
                      ),
                    if (resetViewersVis)
                      SettingsTile(
                        icon: Broken.refresh_2,
                        title: '重置默认文件查看器',
                        subtitle: '清除所有已记住的"打开方式"关联',
                        onTap: () async {
                          await PreferencesService.clearAllDefaultOpenActions();
                          if (mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text('所有默认查看器选择已重置'),
                                behavior: SnackBarBehavior.floating,
                              ),
                            );
                          }
                        },
                      ),
                  ],
                  if (_shouldShowHeader(recycleBinList)) ...[
                    const SizedBox(height: 24),
                    _buildSectionHeader(theme, '回收站'),
                    if (recycleBinVis)
                      SettingsTile(
                        icon: Broken.trash,
                        title: '启用回收站',
                        subtitle: '将删除的文件和文件夹移至隐藏的回收站而非永久删除',
                        trailing: Transform.scale(
                          scale: 0.85,
                          child: Switch(
                            value: RecycleBinService.isEnabled(),
                            activeColor: theme.colorScheme.primary,
                            onChanged: (val) {
                              setState(() {
                                RecycleBinService.setEnabled(val);
                              });
                            },
                          ),
                        ),
                        onTap: () {
                          final val = !RecycleBinService.isEnabled();
                          setState(() {
                            RecycleBinService.setEnabled(val);
                          });
                        },
                      ),
                    if (autoDeleteDurationVis)
                      SettingsTile(
                        icon: Icons.access_time_rounded,
                        title: '自动删除回收站时长',
                        subtitle: _getAutoDeleteDaysLabel(RecycleBinService.getAutoDeleteDays()),
                        onTap: () => _showAutoDeleteDaysPickerDialog(context, theme, () {
                          setState(() {});
                        }),
                      ),
                  ],
                ],
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSectionHeader(ThemeData theme, String title) {
    return Padding(
      padding: const EdgeInsets.only(left: 8, bottom: 8, top: 8),
      child: Text(
        title.toUpperCase(),
        style: TextStyle(
          color: theme.colorScheme.primary.withOpacity(0.8),
          fontSize: 12,
          fontWeight: FontWeight.bold,
          letterSpacing: 1.2,
        ),
      ),
    );
  }
}

// ----------------------------------------------------
// Reusable Settings Tile
// ----------------------------------------------------
class SettingsTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback? onTap;
  final Widget? trailing;

  const SettingsTile({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    this.onTap,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      elevation: 0,
      margin: const EdgeInsets.symmetric(vertical: 4),
      color: theme.colorScheme.surface.withOpacity(0.5),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: theme.colorScheme.outline.withOpacity(0.1)),
      ),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        leading: Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: theme.colorScheme.primary.withOpacity(0.1),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Icon(icon, color: theme.colorScheme.primary, size: 22),
        ),
        title: Text(title, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 16)),
        subtitle: Text(subtitle, style: TextStyle(fontSize: 13, color: theme.colorScheme.onSurface.withOpacity(0.6))),
        trailing: trailing != null ? IgnorePointer(child: trailing) : null,
        onTap: onTap,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
    );
  }
}

// ----------------------------------------------------
// Sub-Category Settings Screens
// ----------------------------------------------------

class GeneralSettingsScreen extends StatelessWidget {
  const GeneralSettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final fileManager = context.watch<FileManagerProvider>();

    return Scaffold(
      appBar: AppBar(
        title: const Text('常规与行为'),
        leading: IconButton(
          icon: const Icon(Broken.arrow_left),
          onPressed: () => Navigator.pop(context),
        ),
      ),
      body: SafeArea(
        child: ListView(
          physics: const BouncingScrollPhysics(),
          padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 16),
          children: [
            SettingsTile(
              icon: Broken.folder_favorite,
              title: '默认进入浏览页',
              subtitle: '启动时直接进入浏览存储管理器',
              trailing: Transform.scale(
                scale: 0.85,
                child: Switch(
                  value: fileManager.defaultToBrowseScreen,
                  activeColor: theme.colorScheme.primary,
                  onChanged: (_) => fileManager.toggleDefaultToBrowseScreen(),
                ),
              ),
              onTap: () => fileManager.toggleDefaultToBrowseScreen(),
            ),
            SettingsTile(
              icon: Broken.folder_open,
              title: '记住上次打开的文件夹',
              subtitle: '启动应用时打开上次浏览的文件夹',
              trailing: Transform.scale(
                scale: 0.85,
                child: Switch(
                  value: fileManager.rememberLastFolder,
                  activeColor: theme.colorScheme.primary,
                  onChanged: (_) => fileManager.toggleRememberLastFolder(),
                ),
              ),
              onTap: () => fileManager.toggleRememberLastFolder(),
            ),
            SettingsTile(
              icon: Broken.menu,
              title: '显示首页和浏览底部栏',
              subtitle: '切换首页底部导航栏的显示',
              trailing: Transform.scale(
                scale: 0.85,
                child: Switch(
                  value: fileManager.showHomeBrowseNav,
                  activeColor: theme.colorScheme.primary,
                  onChanged: (_) => fileManager.toggleShowHomeBrowseNav(),
                ),
              ),
              onTap: () => fileManager.toggleShowHomeBrowseNav(),
            ),
            SettingsTile(
              icon: Icons.android,
              title: '隐藏安卓导航栏',
              subtitle: '隐藏底部导航栏以最大化屏幕空间（上滑可显示）',
              trailing: Transform.scale(
                scale: 0.85,
                child: Switch(
                  value: fileManager.hideNavigationBar,
                  activeColor: theme.colorScheme.primary,
                  onChanged: (_) => fileManager.toggleHideNavigationBar(),
                ),
              ),
              onTap: () => fileManager.toggleHideNavigationBar(),
            ),
            SettingsTile(
              icon: Broken.menu,
              title: '显示底部导航栏',
              subtitle: '在浏览页启用底部操作栏',
              trailing: Transform.scale(
                scale: 0.85,
                child: Switch(
                  value: fileManager.showBottomActionBar,
                  activeColor: theme.colorScheme.primary,
                  onChanged: (_) => fileManager.toggleBottomActionBar(),
                ),
              ),
              onTap: () => fileManager.toggleBottomActionBar(),
            ),
            SettingsTile(
              icon: Icons.label_off_rounded,
              title: '隐藏操作栏文字标签',
              subtitle: '在浏览和媒体页面的选择操作栏中仅显示图标',
              trailing: Transform.scale(
                scale: 0.85,
                child: Switch(
                  value: fileManager.hideActionText,
                  activeColor: theme.colorScheme.primary,
                  onChanged: (_) => fileManager.toggleHideActionText(),
                ),
              ),
              onTap: () => fileManager.toggleHideActionText(),
            ),
            SettingsTile(
              icon: Broken.setting_2,
              title: '自定义快捷方式',
              subtitle: '重新排列和切换快捷分类项目的可见性',
              onTap: () => QuickCategoriesGrid.showCustomizeDialog(context),
            ),
            SettingsTile(
              icon: Broken.clock,
              title: '显示最近文件',
              subtitle: '在首页显示最近访问的文件列表',
              trailing: Transform.scale(
                scale: 0.85,
                child: Switch(
                  value: fileManager.showRecentFiles,
                  activeColor: theme.colorScheme.primary,
                  onChanged: (_) => fileManager.toggleShowRecentFiles(),
                ),
              ),
              onTap: () => fileManager.toggleShowRecentFiles(),
            ),
            SettingsTile(
              icon: Icons.gesture,
              title: '阻止左侧返回手势打开抽屉',
              subtitle: '将屏幕左边缘排除在安卓系统返回手势之外，便于滑动打开抽屉。您仍可从右边缘滑动返回。',
              trailing: Transform.scale(
                scale: 0.85,
                child: Switch(
                  value: fileManager.disableLeftBackGesture,
                  activeColor: theme.colorScheme.primary,
                  onChanged: (_) => fileManager.toggleDisableLeftBackGesture(),
                ),
              ),
              onTap: () => fileManager.toggleDisableLeftBackGesture(),
            ),
          ],
        ),
      ),
    );
  }
}

class AppearanceSettingsScreen extends StatelessWidget {
  const AppearanceSettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final fileManager = context.watch<FileManagerProvider>();

    return Scaffold(
      appBar: AppBar(
        title: const Text('外观与主题'),
        leading: IconButton(
          icon: const Icon(Broken.arrow_left),
          onPressed: () => Navigator.pop(context),
        ),
      ),
      body: SafeArea(
        child: ListView(
          physics: const BouncingScrollPhysics(),
          padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 16),
          children: [
            SettingsTile(
              icon: Broken.colorfilter,
              title: '主题色 / 动态主题',
              subtitle: _getAccentColorLabel(fileManager.accentColorOption),
              onTap: () => _showThemePickerDialog(context, fileManager, theme),
            ),
            SettingsTile(
              icon: FileUtils.getFolderIcon(fileManager.folderIconOption),
              title: '文件夹图标样式',
              subtitle: _getFolderIconLabel(fileManager.folderIconOption),
              onTap: () => _showFolderIconPickerDialog(context, fileManager, theme),
            ),
            SettingsTile(
              icon: Broken.category,
              title: '应用抽屉按钮样式',
              subtitle: _getMenuIconStyleLabel(fileManager.menuIconStyle),
              onTap: () => _showMenuIconStylePickerDialog(context, fileManager, theme),
            ),
            SettingsTile(
              icon: Broken.moon,
              title: 'AMOLED 纯黑模式',
              subtitle: '在深色模式下为AMOLED屏幕使用纯黑背景',
              trailing: Transform.scale(
                scale: 0.85,
                child: Switch(
                  value: fileManager.amoledMode,
                  activeColor: theme.colorScheme.primary,
                  onChanged: (_) => fileManager.toggleAmoledMode(),
                ),
              ),
              onTap: () => fileManager.toggleAmoledMode(),
            ),
            SettingsTile(
              icon: Broken.category,
              title: '应用图标',
              subtitle: _getAppIconLabel(fileManager.activeAppIcon),
              onTap: () => _showAppIconPickerDialog(context, fileManager, theme),
            ),
            SettingsTile(
              icon: Broken.text,
              title: '应用排版 / 字体',
              subtitle: _getFontFamilyLabel(fileManager.fontFamilyOption),
              onTap: () => _showFontFamilyPickerDialog(context, fileManager, theme),
            ),
            SettingsTile(
              icon: Broken.shapes,
              title: '分类图标形状',
              subtitle: fileManager.categoryIconShape == 'square' ? '方形' : '圆形',
              onTap: () => _showCategoryIconShapePickerDialog(context, fileManager, theme),
            ),
          ],
        ),
      ),
    );
  }
}

class ExplorerSettingsScreen extends StatelessWidget {
  const ExplorerSettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final fileManager = context.watch<FileManagerProvider>();

    return Scaffold(
      appBar: AppBar(
        title: const Text('文件浏览器选项'),
        leading: IconButton(
          icon: const Icon(Broken.arrow_left),
          onPressed: () => Navigator.pop(context),
        ),
      ),
      body: SafeArea(
        child: ListView(
          physics: const BouncingScrollPhysics(),
          padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 16),
          children: [
            SettingsTile(
              icon: Broken.edit,
              title: '显示地址栏',
              subtitle: '在文件列表顶部显示可编辑的Windows资源管理器风格地址栏',
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
              title: '显示浮动按钮',
              subtitle: '在浏览页底部启用快速创建（+）按钮',
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
              icon: Broken.folder_open,
              title: '显示隐藏文件',
              subtitle: '显示以点(.)开头的系统文件和文件夹',
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
              icon: Broken.colorfilter,
              title: '高亮退出文件夹',
              subtitle: '返回时短暂闪烁并滚动到刚退出的文件夹',
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
              title: '启用多标签页',
              subtitle: '允许在单独的标签页中打开多个文件夹以便快速导航',
              trailing: Transform.scale(
                scale: 0.85,
                child: Switch(
                  value: fileManager.enableMultipleTabs,
                  activeColor: theme.colorScheme.primary,
                  onChanged: (_) => fileManager.toggleMultipleTabs(),
                ),
              ),
              onTap: () => fileManager.toggleMultipleTabs(),
            ),
            SettingsTile(
              icon: Icons.splitscreen,
              title: '启用分屏',
              subtitle: '并排浏览两个目录并轻松传输文件',
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
              title: '启用拖放',
              subtitle: '长按并拖动文件夹或文件将其移动到其他文件夹',
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
                  title: '确认拖放操作',
                  subtitle: '拖放文件时显示选项弹窗（复制、移动、压缩）',
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
    );
  }
}

class LayoutSettingsScreen extends StatelessWidget {
  const LayoutSettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final fileManager = context.watch<FileManagerProvider>();

    return Scaffold(
      appBar: AppBar(
        title: const Text('列表与布局样式'),
        leading: IconButton(
          icon: const Icon(Broken.arrow_left),
          onPressed: () => Navigator.pop(context),
        ),
      ),
      body: SafeArea(
        child: ListView(
          physics: const BouncingScrollPhysics(),
          padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 16),
          children: [
            SettingsTile(
              icon: Broken.document_text_1,
              title: '显示文件夹和文件计数标题',
              subtitle: '在存储标题栏下显示文件夹和文件总数',
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
              title: '显示文件夹内容计数',
              subtitle: '计算并显示目录中的文件和文件夹总数',
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
              title: '显示文件夹大小',
              subtitle: '计算并显示目录中所有文件的总大小（可能影响列表性能）',
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
              icon: Icons.access_time_rounded,
              title: '使用24小时制',
              subtitle: '在列表中切换12小时（AM/PM）和24小时时间格式',
              trailing: Transform.scale(
                scale: 0.85,
                child: Switch(
                  value: fileManager.use24HourFormat,
                  activeColor: theme.colorScheme.primary,
                  onChanged: (_) => fileManager.toggleUse24HourFormat(),
                ),
              ),
              onTap: () => fileManager.toggleUse24HourFormat(),
            ),
            SettingsTile(
              icon: Icons.visibility_off_rounded,
              title: '在列表中隐藏时间和日期',
              subtitle: '完全隐藏文件和文件夹的修改日期和时间',
              trailing: Transform.scale(
                scale: 0.85,
                child: Switch(
                  value: fileManager.hideTimeAndDate,
                  activeColor: theme.colorScheme.primary,
                  onChanged: (_) => fileManager.toggleHideTimeAndDate(),
                ),
              ),
              onTap: () => fileManager.toggleHideTimeAndDate(),
            ),
            SettingsTile(
              icon: Broken.text,
              title: '自适应多行文件名',
              subtitle: '允许文件名换行显示3行而非截断',
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
              title: '隐藏三点操作按钮',
              subtitle: '隐藏文件夹和文件旁边的三点菜单按钮',
              trailing: Transform.scale(
                scale: 0.85,
                child: Switch(
                  value: fileManager.hideActionMenuButtons,
                  activeColor: theme.colorScheme.primary,
                  onChanged: (_) => fileManager.toggleHideActionMenuButtons(),
                ),
              ),
              onTap: () => fileManager.toggleHideActionMenuButtons(),
            ),
          ],
        ),
      ),
    );
  }
}

class MediaSettingsScreen extends StatefulWidget {
  const MediaSettingsScreen({super.key});

  @override
  State<MediaSettingsScreen> createState() => _MediaSettingsScreenState();
}

class _MediaSettingsScreenState extends State<MediaSettingsScreen> {
  bool _preferFolders = false;
  int _autoCleanDays = 0;
  bool _remoteThumbnailPreview = false;

  @override
  void initState() {
    super.initState();
    _preferFolders = PreferencesService.getPreferFoldersInMedia();
    _autoCleanDays = PreferencesService.getRemoteCacheAutoCleanDays();
    _remoteThumbnailPreview = PreferencesService.getRemoteMediaThumbnailPreview();
  }

  String _getAutoCleanLabel(int days) {
    switch (days) {
      case 0: return '不自动清理';
      case 1: return '每天';
      case 3: return '每3天';
      case 7: return '每周';
      case 14: return '每两周';
      case 30: return '每月';
      default: return '每$days天';
    }
  }

  Future<void> _clearRemoteCache() async {
    try {
      // 清除整个 ZenFile_Remote 目录（包含下载文件和缓存）
      final cacheDir = Directory('/storage/emulated/0/Download/ZenFile_Remote');
      if (cacheDir.existsSync()) {
        await cacheDir.delete(recursive: true);
        cacheDir.createSync(recursive: true);
      }
      // 同时清理旧的临时缓存目录（兼容之前版本）
      final oldCacheDirs = [
        '/storage/emulated/0/Android/data/com.sequl.zenfile/cache/remote_cache',
        '/storage/emulated/0/Android/data/com.sequl.zenfile/cache/remote_thumbnails',
      ];
      for (final dir in oldCacheDirs) {
        final d = Directory(dir);
        if (d.existsSync()) await d.delete(recursive: true);
      }
      await PreferencesService.saveRemoteCacheLastCleanTime(DateTime.now().millisecondsSinceEpoch);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('远程服务器缓存已清除'), behavior: SnackBarBehavior.floating),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('清除缓存失败: $e'), behavior: SnackBarBehavior.floating),
        );
      }
    }
  }

  void _showAutoCleanPicker() {
    final options = [0, 1, 3, 7, 14, 30];
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (ctx) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 40, height: 4,
                  decoration: BoxDecoration(color: Colors.grey.withOpacity(0.3), borderRadius: BorderRadius.circular(2)),
                ),
                const SizedBox(height: 16),
                const Text('自动清理缓存', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                const SizedBox(height: 8),
                ...options.map((days) => ListTile(
                  leading: Icon(
                    _autoCleanDays == days ? Icons.check_circle_rounded : Icons.circle_outlined,
                    color: _autoCleanDays == days ? Theme.of(ctx).colorScheme.primary : Colors.grey,
                  ),
                  title: Text(_getAutoCleanLabel(days)),
                  onTap: () {
                    setState(() => _autoCleanDays = days);
                    PreferencesService.saveRemoteCacheAutoCleanDays(days);
                    Navigator.pop(ctx);
                  },
                )),
              ],
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final fileManager = context.watch<FileManagerProvider>();

    return Scaffold(
      appBar: AppBar(
        title: const Text('媒体偏好'),
        leading: IconButton(
          icon: const Icon(Broken.arrow_left),
          onPressed: () => Navigator.pop(context),
        ),
      ),
      body: SafeArea(
        child: ListView(
          physics: const BouncingScrollPhysics(),
          padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 16),
          children: [
            SettingsTile(
              icon: Broken.folder_2,
              title: '默认相册首选视图',
              subtitle: '直接以文件夹（相册）首选视图打开图片/视频快捷分类',
              trailing: Transform.scale(
                scale: 0.85,
                child: Switch(
                  value: _preferFolders,
                  activeColor: theme.colorScheme.primary,
                  onChanged: (val) {
                    setState(() {
                      _preferFolders = val;
                    });
                    PreferencesService.savePreferFoldersInMedia(val);
                  },
                ),
              ),
              onTap: () {
                final val = !_preferFolders;
                setState(() {
                  _preferFolders = val;
                });
                PreferencesService.savePreferFoldersInMedia(val);
              },
            ),
            SettingsTile(
              icon: Broken.image,
              title: '显示媒体预览',
              subtitle: '显示实际的图片和视频缩略图而非通用文件图标',
              trailing: Transform.scale(
                scale: 0.85,
                child: Switch(
                  value: fileManager.showMediaPreviews,
                  activeColor: theme.colorScheme.primary,
                  onChanged: (_) => fileManager.toggleMediaPreviews(),
                ),
              ),
              onTap: () => fileManager.toggleMediaPreviews(),
            ),
            const SizedBox(height: 8),
            SettingsTile(
              icon: Broken.trash,
              title: '清除远程缓存',
              subtitle: '立即清除网络服务器下载的缓存文件',
              trailing: IconButton(
                icon: Icon(Broken.trash, color: theme.colorScheme.error, size: 20),
                onPressed: _clearRemoteCache,
              ),
              onTap: _clearRemoteCache,
            ),
            SettingsTile(
              icon: Broken.folder_open,
              title: '查看缓存目录',
              subtitle: '浏览远程服务器缓存文件所在目录',
              trailing: Icon(Icons.chevron_right_rounded, color: theme.colorScheme.onSurface.withOpacity(0.4)),
              onTap: () {
                final provider = context.read<FileManagerProvider>();
                provider.loadDirectory('/storage/emulated/0/Download/ZenFile_Remote');
                // 设置导航标志，让 HomeScreen 切换到浏览标签
                provider.setNavigateToBrowseTab(true);
                // 关闭所有设置页面回到首页
                Navigator.of(context).popUntil((route) => route.isFirst);
              },
            ),
            SettingsTile(
              icon: Broken.clock,
              title: '自动清理缓存',
              subtitle: '定期自动清理远程服务器缓存文件: ${_getAutoCleanLabel(_autoCleanDays)}',
              trailing: Icon(Icons.chevron_right_rounded, color: theme.colorScheme.onSurface.withOpacity(0.4)),
              onTap: _showAutoCleanPicker,
            ),
            SettingsTile(
              icon: Broken.image,
              title: '远程媒体缩略图',
              subtitle: '为网络服务器上的图片和视频显示缩略图预览',
              trailing: Transform.scale(
                scale: 0.85,
                child: Switch(
                  value: _remoteThumbnailPreview,
                  activeColor: theme.colorScheme.primary,
                  onChanged: (val) {
                    setState(() => _remoteThumbnailPreview = val);
                    PreferencesService.saveRemoteMediaThumbnailPreview(val);
                  },
                ),
              ),
              onTap: () {
                final val = !_remoteThumbnailPreview;
                setState(() => _remoteThumbnailPreview = val);
                PreferencesService.saveRemoteMediaThumbnailPreview(val);
              },
            ),
          ],
        ),
      ),
    );
  }
}

class ActionsSettingsScreen extends StatelessWidget {
  const ActionsSettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final fileManager = context.watch<FileManagerProvider>();

    return Scaffold(
      appBar: AppBar(
        title: const Text('文件操作与查看器'),
        leading: IconButton(
          icon: const Icon(Broken.arrow_left),
          onPressed: () => Navigator.pop(context),
        ),
      ),
      body: SafeArea(
        child: ListView(
          physics: const BouncingScrollPhysics(),
          padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 16),
          children: [
            SettingsTile(
              icon: Broken.setting_3,
              title: '跳过"打开方式"对话框',
              subtitle: '绕过应用选择对话框，直接使用默认查看器打开文件',
              trailing: Transform.scale(
                scale: 0.85,
                child: Switch(
                  value: fileManager.skipOpenWithDialog,
                  activeColor: theme.colorScheme.primary,
                  onChanged: (_) => fileManager.toggleSkipOpenWithDialog(),
                ),
              ),
              onTap: () => fileManager.toggleSkipOpenWithDialog(),
            ),
            SettingsTile(
              icon: Broken.refresh_2,
              title: '重置默认文件查看器',
              subtitle: '清除所有已记住的"打开方式"关联',
              onTap: () async {
                await PreferencesService.clearAllDefaultOpenActions();
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('所有默认查看器选择已重置'),
                      behavior: SnackBarBehavior.floating,
                    ),
                  );
                }
              },
            ),
          ],
        ),
      ),
    );
  }
}

class TrashSettingsScreen extends StatefulWidget {
  const TrashSettingsScreen({super.key});

  @override
  State<TrashSettingsScreen> createState() => _TrashSettingsScreenState();
}

class _TrashSettingsScreenState extends State<TrashSettingsScreen> {
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('回收站'),
        leading: IconButton(
          icon: const Icon(Broken.arrow_left),
          onPressed: () => Navigator.pop(context),
        ),
      ),
      body: SafeArea(
        child: ListView(
          physics: const BouncingScrollPhysics(),
          padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 16),
          children: [
            SettingsTile(
              icon: Broken.trash,
              title: '启用回收站',
              subtitle: '将删除的文件和文件夹移至隐藏的回收站而非永久删除',
              trailing: Transform.scale(
                scale: 0.85,
                child: Switch(
                  value: RecycleBinService.isEnabled(),
                  activeColor: theme.colorScheme.primary,
                  onChanged: (val) {
                    setState(() {
                      RecycleBinService.setEnabled(val);
                    });
                  },
                ),
              ),
              onTap: () {
                final val = !RecycleBinService.isEnabled();
                setState(() {
                  RecycleBinService.setEnabled(val);
                });
              },
            ),
            if (RecycleBinService.isEnabled())
              SettingsTile(
                icon: Icons.access_time_rounded,
                title: '自动删除回收站时长',
                subtitle: _getAutoDeleteDaysLabel(RecycleBinService.getAutoDeleteDays()),
                onTap: () => _showAutoDeleteDaysPickerDialog(context, theme, () {
                  setState(() {});
                }),
              ),
          ],
        ),
      ),
    );
  }
}

// ----------------------------------------------------
// Global Helper Labels & Dialogs for Themes & Settings
// ----------------------------------------------------

String _getAccentColorLabel(String option) {
  switch (option) {
    case 'dynamic': return 'Material You（动态壁纸取色）';
    case 'orange': return '活力橙';
    case 'purple': return '皇家紫';
    case 'green': return '翠绿';
    case 'red': return '深红';
    case 'gold': return '琥珀金';
    case 'pink': return '赛博粉';
    case 'sapphire': return '蓝宝石';
    case 'forest': return '森林绿';
    case 'peach': return '日落桃';
    case 'blue':
    default:
      return '默认蓝（标志性蓝色）';
  }
}

String _getFolderIconLabel(String option) {
  switch (option) {
    case 'solid': return '经典实心（Material）';
    case 'rounded': return '现代圆角（Material）';
    case 'special': return '星标特别（Material）';
    case 'snippet': return '文档片段（Material）';
    case 'outlined': return '极简描边（Material）';
    case 'broken':
    default:
      return 'ZenFile 断线描边（默认）';
  }
}

String _getMenuIconStyleLabel(String option) {
  switch (option) {
    case 'category': return '分类网格 / Vuesax 网格';
    case 'hamburger':
    default:
      return '汉堡菜单 / 经典菜单';
  }
}

String _getAppIconLabel(String option) {
  switch (option) {
    case 'design1': return '极简风';
    case 'design2': return '玻璃拟态';
    case 'design3': return '3D 可爱';
    case 'design4': return '赛博朋克';
    case 'design5': return '自然禅意';
    case 'custom': return '自定义图标';
    case 'default':
    default:
      return '默认标志（自然禅意）';
  }
}

String _getFontFamilyLabel(String option) {
  switch (option) {
    case 'nothing': return '点阵与无衬线';
    case 'outfit': return 'Outfit 现代无衬线';
    case 'jetbrains': return 'JetBrains 科技等宽';
    case 'montserrat': return 'Montserrat 都市无衬线';
    case 'custom': return '自定义导入字体';
    case 'default':
    default:
      return '标志性默认（Lexend Deca）';
  }
}

String _getAutoDeleteDaysLabel(int days) {
  if (days <= 0) return '从不（禁用自动删除）';
  if (days == 1) return '1 天后';
  return '$days 天后';
}

void _showThemePickerDialog(BuildContext context, FileManagerProvider fileManager, ThemeData theme) {
  showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: theme.scaffoldBackgroundColor,
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
    builder: (ctx) {
      final current = fileManager.accentColorOption;
      final options = [
        {'key': 'blue', 'name': '默认蓝（标志性蓝色）', 'color': const Color(0xFF369FE7)},
        {'key': 'dynamic', 'name': 'Material You（动态壁纸取色）', 'color': Colors.teal},
        {'key': 'orange', 'name': '活力橙', 'color': const Color(0xFFFF6D00)},
        {'key': 'purple', 'name': '皇家紫', 'color': const Color(0xFF8E24AA)},
        {'key': 'green', 'name': '翠绿', 'color': const Color(0xFF00C853)},
        {'key': 'red', 'name': '深红', 'color': const Color(0xFFD50000)},
        {'key': 'gold', 'name': '琥珀金', 'color': const Color(0xFFFFD600)},
        {'key': 'pink', 'name': '赛博粉', 'color': const Color(0xFFFF2E93)},
        {'key': 'sapphire', 'name': '蓝宝石', 'color': const Color(0xFF0F52BA)},
        {'key': 'forest', 'name': '森林绿', 'color': const Color(0xFF228B22)},
        {'key': 'peach', 'name': '日落桃', 'color': const Color(0xFFFF7F50)},
      ];

      return SafeArea(
        child: Padding(
          padding: EdgeInsets.only(
            bottom: MediaQuery.of(ctx).viewInsets.bottom,
          ),
          child: SingleChildScrollView(
            physics: const BouncingScrollPhysics(),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Center(
                    child: Container(width: 40, height: 4, decoration: BoxDecoration(color: Colors.grey.withOpacity(0.3), borderRadius: BorderRadius.circular(2))),
                  ),
                  const SizedBox(height: 16),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8.0),
                    child: Text('选择主题色', style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold)),
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
                      final color = opt['color'] as Color;
                      final isSelected = current == key;

                      return ListTile(
                        leading: Container(
                          width: 36,
                          height: 36,
                          decoration: BoxDecoration(
                            color: key == 'dynamic' ? theme.colorScheme.primary : color,
                            shape: BoxShape.circle,
                          ),
                          child: key == 'dynamic' 
                              ? const Icon(Broken.colorfilter, color: Colors.white, size: 20)
                              : isSelected ? const Icon(Icons.check, color: Colors.white, size: 20) : null,
                        ),
                        title: Text(name, style: TextStyle(fontWeight: isSelected ? FontWeight.bold : FontWeight.normal)),
                        trailing: isSelected ? Icon(Icons.radio_button_checked, color: theme.colorScheme.primary) : const Icon(Icons.radio_button_unchecked, color: Colors.grey),
                        onTap: () {
                          fileManager.setAccentColorOption(key);
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

void _showFolderIconPickerDialog(BuildContext context, FileManagerProvider fileManager, ThemeData theme) {
  showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: theme.scaffoldBackgroundColor,
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
    builder: (ctx) {
      final current = fileManager.folderIconOption;
      final options = [
        {'key': 'broken', 'name': 'ZenFile 断线描边（默认）', 'icon': Broken.folder},
        {'key': 'rounded', 'name': '现代圆角（Material）', 'icon': Icons.folder_rounded},
        {'key': 'solid', 'name': '经典实心（Material）', 'icon': Icons.folder},
        {'key': 'special', 'name': '星标特别（Material）', 'icon': Icons.folder_special_rounded},
        {'key': 'snippet', 'name': '文档片段（Material）', 'icon': Icons.snippet_folder_rounded},
        {'key': 'outlined', 'name': '极简描边（Material）', 'icon': Icons.folder_outlined},
      ];

      return SafeArea(
        child: Padding(
          padding: EdgeInsets.only(
            bottom: MediaQuery.of(ctx).viewInsets.bottom,
          ),
          child: SingleChildScrollView(
            physics: const BouncingScrollPhysics(),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Center(
                    child: Container(width: 40, height: 4, decoration: BoxDecoration(color: Colors.grey.withOpacity(0.3), borderRadius: BorderRadius.circular(2))),
                  ),
                  const SizedBox(height: 16),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8.0),
                    child: Text('选择文件夹图标样式', style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold)),
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
                      final icon = opt['icon'] as IconData;
                      final isSelected = current == key;

                      return ListTile(
                        leading: Container(
                          width: 36,
                          height: 36,
                          decoration: BoxDecoration(
                            color: isSelected ? theme.colorScheme.primary : theme.colorScheme.primary.withOpacity(0.1),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Icon(icon, color: isSelected ? theme.colorScheme.onPrimary : theme.colorScheme.primary, size: 20),
                        ),
                        title: Text(name, style: TextStyle(fontWeight: isSelected ? FontWeight.bold : FontWeight.normal)),
                        trailing: isSelected ? Icon(Icons.radio_button_checked, color: theme.colorScheme.primary) : const Icon(Icons.radio_button_unchecked, color: Colors.grey),
                        onTap: () {
                          fileManager.setFolderIconOption(key);
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

void _showMenuIconStylePickerDialog(BuildContext context, FileManagerProvider fileManager, ThemeData theme) {
  showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: theme.scaffoldBackgroundColor,
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
    builder: (ctx) {
      final current = fileManager.menuIconStyle;
      final options = [
        {'key': 'hamburger', 'name': '汉堡菜单 / 经典菜单', 'icon': Broken.menu},
        {'key': 'category', 'name': '分类网格 / Vuesax 网格', 'icon': Broken.category},
      ];

      return SafeArea(
        child: Padding(
          padding: EdgeInsets.only(
            bottom: MediaQuery.of(ctx).viewInsets.bottom,
          ),
          child: SingleChildScrollView(
            physics: const BouncingScrollPhysics(),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Center(
                    child: Container(width: 40, height: 4, decoration: BoxDecoration(color: Colors.grey.withOpacity(0.3), borderRadius: BorderRadius.circular(2))),
                  ),
                  const SizedBox(height: 16),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8.0),
                    child: Text('选择抽屉按钮样式', style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold)),
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
                      final icon = opt['icon'] as IconData;
                      final isSelected = current == key;

                      return ListTile(
                        leading: Container(
                          width: 36,
                          height: 36,
                          decoration: BoxDecoration(
                            color: isSelected ? theme.colorScheme.primary : theme.colorScheme.primary.withOpacity(0.1),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Icon(icon, color: isSelected ? theme.colorScheme.onPrimary : theme.colorScheme.primary, size: 20),
                        ),
                        title: Text(name, style: TextStyle(fontWeight: isSelected ? FontWeight.bold : FontWeight.normal)),
                        trailing: isSelected ? Icon(Icons.radio_button_checked, color: theme.colorScheme.primary) : const Icon(Icons.radio_button_unchecked, color: Colors.grey),
                        onTap: () {
                          fileManager.setMenuIconStyle(key);
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

void _showCategoryIconShapePickerDialog(BuildContext context, FileManagerProvider fileManager, ThemeData theme) {
  showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: theme.scaffoldBackgroundColor,
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
    builder: (ctx) {
      final current = fileManager.categoryIconShape;
      final options = [
        {'key': 'circle', 'name': '圆形', 'icon': Broken.sun_fog},
        {'key': 'square', 'name': '方形', 'icon': Broken.stop},
      ];

      return SafeArea(
        child: Padding(
          padding: EdgeInsets.only(
            bottom: MediaQuery.of(ctx).viewInsets.bottom,
          ),
          child: SingleChildScrollView(
            physics: const BouncingScrollPhysics(),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Center(
                    child: Container(width: 40, height: 4, decoration: BoxDecoration(color: Colors.grey.withOpacity(0.3), borderRadius: BorderRadius.circular(2))),
                  ),
                  const SizedBox(height: 16),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8.0),
                    child: Text('选择分类图标形状', style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold)),
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
                      final icon = opt['icon'] as IconData;
                      final isSelected = current == key;

                      return ListTile(
                        leading: Container(
                          width: 36,
                          height: 36,
                          decoration: BoxDecoration(
                            color: isSelected ? theme.colorScheme.primary : theme.colorScheme.primary.withOpacity(0.1),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Icon(icon, color: isSelected ? theme.colorScheme.onPrimary : theme.colorScheme.primary, size: 20),
                        ),
                        title: Text(name, style: TextStyle(fontWeight: isSelected ? FontWeight.bold : FontWeight.normal)),
                        trailing: isSelected ? Icon(Icons.radio_button_checked, color: theme.colorScheme.primary) : const Icon(Icons.radio_button_unchecked, color: Colors.grey),
                        onTap: () {
                          fileManager.setCategoryIconShape(key);
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

void _showAppIconPickerDialog(BuildContext context, FileManagerProvider fileManager, ThemeData theme) {
  showGeneralDialog(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'App Icon Picker',
    barrierColor: Colors.black.withOpacity(0.55),
    transitionDuration: const Duration(milliseconds: 250),
    pageBuilder: (context, anim1, anim2) => const SizedBox.shrink(),
    transitionBuilder: (context, anim1, anim2, child) {
      return ScaleTransition(
        scale: CurvedAnimation(parent: anim1, curve: Curves.easeOutBack),
        child: FadeTransition(
          opacity: anim1,
          child: AlertDialog(
            backgroundColor: theme.colorScheme.surface,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
            title: Row(
              children: [
                Icon(Broken.category, color: theme.colorScheme.primary, size: 26),
                const SizedBox(width: 12),
                const Text('应用启动器图标', style: TextStyle(fontWeight: FontWeight.bold)),
              ],
            ),
            content: SizedBox(
              width: double.maxFinite,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text(
                    '为应用启动器图标选择一个自定义Logo。注意某些启动器可能需要几秒钟才能更新。',
                    style: TextStyle(fontSize: 13, height: 1.3, color: Colors.grey),
                  ),
                  const SizedBox(height: 20),
                  Flexible(
                    child: SingleChildScrollView(
                      child: GridView.count(
                        shrinkWrap: true,
                        physics: const NeverScrollableScrollPhysics(),
                        crossAxisCount: 2,
                        crossAxisSpacing: 12,
                        mainAxisSpacing: 12,
                        childAspectRatio: 0.85,
                        children: [
                          _buildIconOptionCard(
                            context,
                            fileManager,
                            theme,
                            id: 'default',
                            title: '默认标志',
                            imagePath: 'assets/logo/design_5_nature.jpg',
                          ),
                          _buildIconOptionCard(
                            context,
                            fileManager,
                            theme,
                            id: 'design1',
                            title: '极简风',
                            imagePath: 'assets/logo/design_1_minimalist.jpg',
                          ),
                          _buildIconOptionCard(
                            context,
                            fileManager,
                            theme,
                            id: 'design2',
                            title: '玻璃拟态',
                            imagePath: 'assets/logo/design_2_glassmorphism.jpg',
                          ),
                          _buildIconOptionCard(
                            context,
                            fileManager,
                            theme,
                            id: 'design3',
                            title: '3D 可爱',
                            imagePath: 'assets/logo/design_3_3d_cute.jpg',
                          ),
                          _buildIconOptionCard(
                            context,
                            fileManager,
                            theme,
                            id: 'design4',
                            title: '赛博朋克',
                            imagePath: 'assets/logo/design_4_cyberpunk.jpg',
                          ),
                          _buildIconOptionCard(
                            context,
                            fileManager,
                            theme,
                            id: 'design5',
                            title: '自然禅意',
                            imagePath: 'assets/logo/design_5_nature.jpg',
                          ),
                          _buildCustomIconOptionCard(
                            context,
                            fileManager,
                            theme,
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('关闭'),
              ),
            ],
          ),
        ),
      );
    },
  );
}

Widget _buildIconOptionCard(
  BuildContext context,
  FileManagerProvider fileManager,
  ThemeData theme, {
  required String id,
  required String title,
  required String imagePath,
}) {
  final isSelected = fileManager.activeAppIcon == id;

  return Card(
    color: isSelected ? theme.colorScheme.primaryContainer.withOpacity(0.4) : theme.colorScheme.surfaceVariant.withOpacity(0.15),
    elevation: 0,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(16),
      side: BorderSide(
        color: isSelected ? theme.colorScheme.primary : theme.dividerColor.withOpacity(0.08),
        width: isSelected ? 2.0 : 1.0,
      ),
    ),
    child: InkWell(
      onTap: () {
        fileManager.setActiveAppIcon(id);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('应用图标已切换为 $title'),
            behavior: SnackBarBehavior.floating,
            duration: const Duration(seconds: 2),
          ),
        );
      },
      borderRadius: BorderRadius.circular(16),
      child: Padding(
        padding: const EdgeInsets.all(8.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: Image.asset(
                imagePath,
                width: 56,
                height: 56,
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => Container(
                  width: 56,
                  height: 56,
                  color: Colors.grey.withOpacity(0.2),
                  child: const Icon(Icons.broken_image, size: 24),
                ),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              title,
              style: TextStyle(
                fontSize: 12,
                fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
                color: isSelected ? theme.colorScheme.primary : theme.colorScheme.onSurface,
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    ),
  );
}

Widget _buildCustomIconOptionCard(
  BuildContext context,
  FileManagerProvider fileManager,
  ThemeData theme,
) {
  final isSelected = fileManager.activeAppIcon == 'custom';
  final customIconPath = PreferencesService.getCustomAppIconPath();
  final hasCustomIcon = customIconPath != null && File(customIconPath).existsSync();

  return Card(
    color: isSelected ? theme.colorScheme.primaryContainer.withOpacity(0.4) : theme.colorScheme.surfaceVariant.withOpacity(0.15),
    elevation: 0,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(16),
      side: BorderSide(
        color: isSelected ? theme.colorScheme.primary : theme.dividerColor.withOpacity(0.08),
        width: isSelected ? 2.0 : 1.0,
      ),
    ),
    child: InkWell(
      onTap: () => _pickCustomIcon(context, fileManager, theme),
      borderRadius: BorderRadius.circular(16),
      child: Padding(
        padding: const EdgeInsets.all(8.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: hasCustomIcon
                  ? Image.file(
                      File(customIconPath!),
                      width: 56,
                      height: 56,
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => _buildCustomIconPlaceholder(theme),
                    )
                  : _buildCustomIconPlaceholder(theme),
            ),
            const SizedBox(height: 8),
            Text(
              isSelected ? '自定义图标' : '选择自定义图标',
              style: TextStyle(
                fontSize: 12,
                fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
                color: isSelected ? theme.colorScheme.primary : theme.colorScheme.onSurface,
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    ),
  );
}

Widget _buildCustomIconPlaceholder(ThemeData theme) {
  return Container(
    width: 56,
    height: 56,
    decoration: BoxDecoration(
      color: theme.colorScheme.primary.withOpacity(0.1),
      borderRadius: BorderRadius.circular(12),
      border: Border.all(
        color: theme.colorScheme.primary.withOpacity(0.3),
        width: 1.5,
        style: BorderStyle.solid,
      ),
    ),
    child: Icon(
      Broken.add_square,
      size: 24,
      color: theme.colorScheme.primary,
    ),
  );
}

Future<void> _pickCustomIcon(BuildContext context, FileManagerProvider fileManager, ThemeData theme) async {
  final result = await InternalFilePickerScreen.show(
    context,
    rootPath: '/storage/emulated/0',
  );

  if (result != null && result.isNotEmpty) {
    final selectedPath = result.first;
    final ext = p.extension(selectedPath).toLowerCase();
    const validExts = ['.png', '.jpg', '.jpeg', '.webp'];
    
    if (!validExts.contains(ext)) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('请选择图片文件（PNG/JPG/WEBP）'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
      return;
    }
    
    final file = File(selectedPath);
    if (await file.exists()) {
      try {
        // Copy to app private directory
        final appDir = await Directory('/storage/emulated/0/Android/data/com.sequl.zenfile/files/custom_icons').create(recursive: true);
        final destPath = p.join(appDir.path, 'custom_app_icon.png');
        await file.copy(destPath);
        
        await PreferencesService.saveCustomAppIconPath(destPath);
        await fileManager.setActiveAppIcon('custom');
        
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('自定义图标已应用'),
              behavior: SnackBarBehavior.floating,
              duration: Duration(seconds: 2),
            ),
          );
        }
      } catch (e) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('应用自定义图标失败: $e'),
              behavior: SnackBarBehavior.floating,
            ),
          );
        }
      }
    }
  }
}

void _showFontFamilyPickerDialog(BuildContext context, FileManagerProvider fileManager, ThemeData theme) {
  showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: theme.scaffoldBackgroundColor,
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
    builder: (ctx) {
      final current = fileManager.fontFamilyOption;
      final hasCustomFont = fileManager.customFontPath != null;
      final options = [
        {'key': 'default', 'name': '标志性默认（Lexend Deca）', 'desc': 'ZenFile 原始简洁几何风格'},
        {'key': 'nothing', 'name': 'Nothing 点阵与无衬线', 'desc': '高科技复古点阵标题 + 简洁正文'},
        {'key': 'outfit', 'name': 'Outfit 现代无衬线', 'desc': '超流畅、极简且高级的几何美学'},
        {'key': 'jetbrains', 'name': 'JetBrains 科技等宽', 'desc': '干净且未来感的开发者等宽风格'},
        {'key': 'montserrat', 'name': 'Montserrat 都市无衬线', 'desc': '大胆、现代且醒目的字体排版'},
        if (hasCustomFont)
          {'key': 'custom', 'name': '自定义字体（${p.basename(fileManager.customFontPath!)}）', 'desc': '您加载的自定义字体文件'},
      ];

      return SafeArea(
        child: Padding(
          padding: EdgeInsets.only(
            bottom: MediaQuery.of(ctx).viewInsets.bottom,
          ),
          child: SingleChildScrollView(
            physics: const BouncingScrollPhysics(),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Center(
                    child: Container(width: 40, height: 4, decoration: BoxDecoration(color: Colors.grey.withOpacity(0.3), borderRadius: BorderRadius.circular(2))),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    '应用排版',
                    style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold, fontFamily: 'LexendDeca'),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    '选择一种精美的字体来自定义ZenFile的整体视觉主题',
                    style: TextStyle(color: theme.colorScheme.onSurface.withOpacity(0.6), fontSize: 13, fontFamily: 'LexendDeca'),
                  ),
                  const SizedBox(height: 16),
                  ...options.map((opt) {
                    final isSelected = current == opt['key'];
                    return ListTile(
                      contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                      title: Text(
                        opt['name']!,
                        style: TextStyle(
                          fontWeight: isSelected ? FontWeight.bold : FontWeight.w600,
                          color: isSelected ? theme.colorScheme.primary : theme.colorScheme.onSurface,
                          fontFamily: 'LexendDeca',
                        ),
                      ),
                      subtitle: Text(
                        opt['desc']!,
                        style: TextStyle(
                          fontSize: 12,
                          color: theme.colorScheme.onSurface.withOpacity(0.5),
                          fontFamily: 'LexendDeca',
                        ),
                      ),
                      trailing: isSelected
                          ? Icon(Icons.radio_button_checked_rounded, color: theme.colorScheme.primary)
                          : Icon(Icons.radio_button_off_rounded, color: theme.colorScheme.onSurface.withOpacity(0.3)),
                      onTap: () {
                        fileManager.setFontFamilyOption(opt['key']!);
                        Navigator.pop(ctx);
                      },
                    );
                  }),
                  const SizedBox(height: 16),
                  const Divider(),
                  const SizedBox(height: 12),
                  OutlinedButton.icon(
                    icon: const Icon(Broken.document_upload, size: 20),
                    label: Text(
                      hasCustomFont ? '替换自定义字体文件' : '导入自定义字体文件 (.ttf/.otf)',
                      style: const TextStyle(fontWeight: FontWeight.bold, fontFamily: 'LexendDeca'),
                    ),
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size.fromHeight(46),
                      foregroundColor: theme.colorScheme.primary,
                      side: BorderSide(color: theme.colorScheme.primary.withOpacity(0.5)),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                    ),
                    onPressed: () async {
                      Navigator.pop(ctx);
                      final picked = await InternalFilePickerScreen.show(
                        context,
                        rootPath: fileManager.rootPath,
                      );
                      if (picked != null && picked.isNotEmpty) {
                        final filePat = picked.first;
                        final ext = p.extension(filePat).toLowerCase();
                        if (ext == '.ttf' || ext == '.otf') {
                          final success = await fileManager.setCustomFontPath(filePat);
                          if (success) {
                            fileManager.setFontFamilyOption('custom');
                            if (context.mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(content: Text('自定义字体"${p.basename(filePat)}"已成功应用！')),
                              );
                            }
                          } else {
                            if (context.mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(content: Text('加载所选字体文件失败。')),
                              );
                            }
                          }
                        } else {
                          if (context.mounted) {
                            showDialog(
                              context: context,
                              builder: (context) => AlertDialog(
                                title: const Text('无效的文件类型'),
                                content: const Text('请选择有效的 OpenType (.otf) 或 TrueType (.ttf) 字体文件.'),
                                actions: [
                                  TextButton(
                                    onPressed: () => Navigator.pop(context),
                                    child: const Text('确定'),
                                  ),
                                ],
                              ),
                            );
                          }
                        }
                      }
                    },
                  ),
                  if (hasCustomFont) ...[
                    const SizedBox(height: 8),
                    TextButton.icon(
                      icon: const Icon(Broken.trash, size: 18, color: Colors.redAccent),
                      label: const Text('移除自定义字体', style: TextStyle(color: Colors.redAccent, fontWeight: FontWeight.bold, fontFamily: 'LexendDeca')),
                      onPressed: () async {
                        Navigator.pop(ctx);
                        await fileManager.setCustomFontPath(null);
                        if (current == 'custom') {
                          fileManager.setFontFamilyOption('default');
                        }
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('自定义字体已移除。')),
                          );
                        }
                      },
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      );
    },
  );
}

void _showAutoDeleteDaysPickerDialog(BuildContext context, ThemeData theme, VoidCallback onChanged) {
  showModalBottomSheet(
    context: context,
    backgroundColor: theme.scaffoldBackgroundColor,
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
    builder: (ctx) {
      final current = RecycleBinService.getAutoDeleteDays();
      final options = [
        {'days': 7, 'label': '7 天'},
        {'days': 15, 'label': '15 天'},
        {'days': 30, 'label': '30 天（推荐）'},
        {'days': 0, 'label': '从不（手动清理）'},
      ];

      return SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: theme.colorScheme.onSurface.withOpacity(0.2),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 20),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8.0),
                child: Text(
                  '自动删除回收站时长',
                  style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold, fontSize: 18),
                ),
              ),
              const SizedBox(height: 4),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8.0),
                child: Text(
                  '回收站中的项目将在此时长后被永久删除。',
                  style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurface.withOpacity(0.5)),
                ),
              ),
              const SizedBox(height: 16),
              ...options.map((opt) {
                final days = opt['days'] as int;
                final label = opt['label'] as String;
                final isSelected = current == days;

                return Card(
                  color: isSelected ? theme.colorScheme.primary.withOpacity(0.12) : theme.colorScheme.surface,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                    side: BorderSide(color: isSelected ? theme.colorScheme.primary : theme.dividerColor.withOpacity(0.08)),
                  ),
                  margin: const EdgeInsets.symmetric(vertical: 6),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(12),
                    onTap: () {
                      RecycleBinService.setAutoDeleteDays(days);
                      onChanged();
                      Navigator.pop(ctx);
                    },
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                      child: Row(
                        children: [
                          Icon(Icons.access_time_rounded, color: isSelected ? theme.colorScheme.primary : theme.colorScheme.onSurface.withOpacity(0.6)),
                          const SizedBox(width: 16),
                          Expanded(
                            child: Text(
                              label,
                              style: TextStyle(
                                fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
                                color: isSelected ? theme.colorScheme.primary : theme.colorScheme.onSurface,
                              ),
                            ),
                          ),
                          if (isSelected) Icon(Icons.check_circle, color: theme.colorScheme.primary),
                        ],
                      ),
                    ),
                  ),
                );
              }),
            ],
          ),
        ),
      );
    },
  );
}
