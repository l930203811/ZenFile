import 'dart:io';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../providers/file_manager_provider.dart';
import '../../core/icon_fonts/broken_icons.dart';
import '../../core/utils.dart';
import '../widgets/quick_categories_grid.dart';
import '../../services/preferences_service.dart';
import '../../services/app_manager_service.dart';
import '../../services/recycle_bin_service.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'internal_file_picker_screen.dart';
import 'backup_settings_screen.dart';
import '../../services/settings_backup_service.dart';
import 'package:zenfile/l10n/generated/app_localizations.dart';
import '../../../main.dart';

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
      case 'dateTime': return L10n.of(context).msg11fea612;
      case 'sizeAndCount': return L10n.of(context).msg12e86877;
      case 'none':
      default:
        return L10n.of(context).msg7908038f;
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
                    Center(child: Container(width: 40, height: 4, decoration: BoxDecoration(color: Colors.grey.withOpacity(0.3), borderRadius: BorderRadius.circular(2)))),
                    const SizedBox(height: 16),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 8.0),
                      child: Text(L10n.of(context).msg83de16cc, style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold)),
                    ),
                    const SizedBox(height: 6),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 8.0),
                      child: Text(L10n.of(context).msgaa2a18a1, style: TextStyle(color: theme.colorScheme.onSurface.withOpacity(0.6), fontSize: 13)),
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
    final showAddressBarVis = _shouldShow(L10n.of(context).msg26e4c5d6, L10n.of(context).windows1);
    final preferFoldersVis = _shouldShow(L10n.of(context).msg20c87c8e, L10n.of(context).msg74e86197);
    final hideNavBarVis = _shouldShow(L10n.of(context).msga1fbf3c6, L10n.of(context).msg02dddc02);
    final resetViewersVis = _shouldShow(L10n.of(context).ui_reset_default_viewers, L10n.of(context).msg50923c95);
    final skipDialogVis = _shouldShow(L10n.of(context).msg6fdc09ac, L10n.of(context).msg0a4b0442);
    final defaultBrowseVis = _shouldShow(L10n.of(context).msga432d127, L10n.of(context).msge1157984);
    final swipeModeVis = _shouldShow(L10n.of(context).msgd48a082d, L10n.of(context).msgae1854a2);
    final showFloatingVis = _shouldShow(L10n.of(context).ui_show_floating_button, L10n.of(context).msg11b1ec65);
    final showHiddenVis = _shouldShow(L10n.of(context).msg124d9054, L10n.of(context).msg7e7765b6);
    final folderFileCountVis = _shouldShow(L10n.of(context).msg86f3d70f, L10n.of(context).msg40e9c325);
    final use24HourVis = _shouldShow(L10n.of(context).ui_use_24h_format, L10n.of(context).ampm24);
    final hideTimeDateVis = _shouldShow(L10n.of(context).msg25ee6612, L10n.of(context).msg337359a6);
    final folderContentsVis = _shouldShow(L10n.of(context).ui_show_folder_contents_count, L10n.of(context).msga517863e);
    final folderSizesVis = _shouldShow(L10n.of(context).ui_show_folder_size, L10n.of(context).msg59a24fcb);
    final bottomActionBarVis = _shouldShow(L10n.of(context).ui_show_bottom_action_bar, L10n.of(context).msg309e2a28);
    final hideActionTextVis = _shouldShow(L10n.of(context).ui_hide_action_text, L10n.of(context).msg9b7639ac);
    final highlightFolderVis = _shouldShow(L10n.of(context).msgd33e3082, L10n.of(context).msgdd69671b);
    final mediaPreviewsVis = _shouldShow(L10n.of(context).ui_show_media_previews, L10n.of(context).msg57736228);
    final adaptiveNamesVis = _shouldShow(L10n.of(context).ui_adaptive_multiline_names, L10n.of(context).msg1eda8a50);
    final hideActionButtonsVis = _shouldShow(L10n.of(context).ui_hide_action_menu_buttons, L10n.of(context).msgc7196afd);
    final dragDropVis = _shouldShow(L10n.of(context).ui_enable_drag_drop, L10n.of(context).msgad54815d);
    final confirmDragVis = fileManager.enableDragDrop && _shouldShow(L10n.of(context).ui_confirm_drag_drop, L10n.of(context).msg5dff8f2d);
    final multipleTabsVis = _shouldShow(L10n.of(context).ui_enable_multi_tabs, L10n.of(context).msg4b0a7063);
    final splitScreenVis = _shouldShow(L10n.of(context).ui_enable_split_screen, L10n.of(context).msgf04ac00d);
    final disableLeftBackVis = false; // 已移除该功能
    final rememberLastFolderVis = _shouldShow(L10n.of(context).msg59c7debc, L10n.of(context).msgd1591ba4);

    final generalStartupList = [
      defaultBrowseVis,
      swipeModeVis,
      rememberLastFolderVis,
      hideNavBarVis,
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

    final recycleBinVis = _shouldShow(L10n.of(context).msge99f4762, L10n.of(context).msg25792550);
    final autoDeleteDurationVis = RecycleBinService.isEnabled() && _shouldShow(L10n.of(context).msgf0ef894a, _getAutoDeleteDaysLabel(context, RecycleBinService.getAutoDeleteDays()));
    final recycleBinList = [recycleBinVis, autoDeleteDurationVis];

    final accentColorVis = _shouldShow(L10n.of(context).msg1b9633fe, _getAccentColorLabel(context, fileManager.accentColorOption));
    final folderIconVis = _shouldShow(L10n.of(context).msg64db4c2d, _getFolderIconLabel(context, fileManager.folderIconOption));
    final menuIconStyleVis = _shouldShow(L10n.of(context).msgece44aa5, _getMenuIconStyleLabel(context, fileManager.menuIconStyle));
    final amoledVis = _shouldShow(L10n.of(context).amoled1, L10n.of(context).amoled2);
    final appIconVis = _shouldShow(L10n.of(context).ui_app_icon, _getAppIconLabel(context, fileManager.activeAppIcon));
    final typographyVis = _shouldShow(L10n.of(context).msg5228b59f, _getFontFamilyLabel(context, fileManager.fontFamilyOption));
    final appearanceList = [accentColorVis, folderIconVis, menuIconStyleVis, amoledVis, appIconVis, typographyVis];

    final customizeShortcutsVis = _shouldShow(L10n.of(context).msge7d18d73, L10n.of(context).msg036fe6a4);
    final homeScreenList = [customizeShortcutsVis];

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
                    hintText: L10n.of(context).msgead3e5c5,
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
              : Text(L10n.of(context).msg1cf6fcd3),
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
                    L10n.of(context).msg2590095f,
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                      color: theme.colorScheme.onSurface.withOpacity(0.8),
                    ),
                  ),
                ),
                SettingsTile(
                  icon: Broken.language_circle,
                  title: L10n.of(context).ui_language,
                  subtitle: _getCurrentLocaleName(PreferencesService.getAppLocale()),
                  trailing: Icon(Icons.chevron_right_rounded, color: theme.colorScheme.onSurface.withOpacity(0.4)),
                  onTap: () => _showLanguagePickerDialog(context),
                ),
                _buildCategoryCard(
                  context,
                  theme,
                  icon: Broken.setting_2,
                  title: L10n.of(context).msgfdae44c3,
                  subtitle: L10n.of(context).msgeae34685,
                  targetScreen: const GeneralSettingsScreen(),
                ),
                _buildCategoryCard(
                  context,
                  theme,
                  icon: Broken.colorfilter,
                  title: L10n.of(context).ui_appearance_theme,
                  subtitle: L10n.of(context).msg91b228b8,
                  targetScreen: const AppearanceSettingsScreen(),
                ),
                _buildCategoryCard(
                  context,
                  theme,
                  icon: Broken.folder_open,
                  title: L10n.of(context).msgad6e8bb8,
                  subtitle: L10n.of(context).msg8ddc4963,
                  targetScreen: const ExplorerSettingsScreen(),
                ),
                _buildCategoryCard(
                  context,
                  theme,
                  icon: Broken.text,
                  title: L10n.of(context).ui_list_layout_style,
                  subtitle: L10n.of(context).msg45db4e2a,
                  targetScreen: const LayoutSettingsScreen(),
                ),
                _buildCategoryCard(
                  context,
                  theme,
                  icon: Broken.image,
                  title: L10n.of(context).ui_media_preferences,
                  subtitle: L10n.of(context).msg09ca4d86,
                  targetScreen: const MediaSettingsScreen(),
                ),
                _buildCategoryCard(
                  context,
                  theme,
                  icon: Broken.setting_3,
                  title: L10n.of(context).ui_file_actions_viewers,
                  subtitle: L10n.of(context).msgeb3693fb,
                  targetScreen: const ActionsSettingsScreen(),
                ),
                _buildCategoryCard(
                  context,
                  theme,
                  icon: Broken.trash,
                  title: L10n.of(context).ui_recycle_bin,
                  subtitle: L10n.of(context).msg3a6a39ae,
                  targetScreen: const TrashSettingsScreen(),
                ),
                SettingsTile(
                  icon: Broken.refresh_circle,
                  title: L10n.of(context).msgb4fbc92c,
                  subtitle: L10n.of(context).msg9edfaff3,
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
                          L10n.of(context).ui_no_settings_found,
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.bold,
                            color: theme.colorScheme.onSurface,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          L10n.of(context).msg99c9cc56,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: theme.colorScheme.onSurface.withOpacity(0.55),
                          ),
                        ),
                      ],
                    ),
                  ),
                ] else ...[
                  if (_shouldShowHeader(generalStartupList) || _shouldShowHeader(selectionActionBarList) || _shouldShowHeader(homeScreenList)) ...[
                    _buildSectionHeader(theme, L10n.of(context).msgfdae44c3),
                    if (defaultBrowseVis)
                      SettingsTile(
                        icon: Broken.folder_favorite,
                        title: L10n.of(context).msga432d127,
                        subtitle: fileManager.defaultToBrowseScreen ? L10n.of(context).msg2c8a394a : L10n.of(context).msg226fc6ae,
                        trailing: Icon(Broken.arrow_right_3, size: 18, color: theme.colorScheme.onSurface.withOpacity(0.3)),
                        onTap: () => _showDefaultHomeDialog(context, fileManager),
                      ),
                    if (swipeModeVis)
                      SettingsTile(
                        icon: Broken.arrow_swap,
                        title: L10n.of(context).msgd48a082d,
                        subtitle: fileManager.swipeMode == 'single' ? L10n.of(context).msgaac01f32 : L10n.of(context).msgbc9bf336,
                        trailing: Icon(Broken.arrow_right_3, size: 18, color: theme.colorScheme.onSurface.withOpacity(0.3)),
                        onTap: () => _showSwipeModeDialog(context, fileManager),
                      ),
                    if (bottomActionBarVis)
                      SettingsTile(
                        icon: Broken.menu,
                        title: L10n.of(context).ui_show_bottom_action_bar,
                        subtitle: fileManager.showBottomActionBar
                            ? L10n.of(context).msg8c414b06
                            : L10n.of(context).msge34c23ff,
                        trailing: Icon(Broken.arrow_right_3, size: 18, color: theme.colorScheme.onSurface.withOpacity(0.3)),
                        onTap: () => _showBottomActionBarDialog(context, fileManager),
                      ),
                    if (rememberLastFolderVis)
                      SettingsTile(
                        icon: Broken.folder_open,
                        title: L10n.of(context).msg59c7debc,
                        subtitle: L10n.of(context).msgd1591ba4,
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
                      icon: Broken.menu_1,
                      title: L10n.of(context).ui_hide_nav_labels,
                      subtitle: L10n.of(context).msgce732d8a,
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
                        title: L10n.of(context).msga1fbf3c6,
                        subtitle: L10n.of(context).msg02dddc02,
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
                    if (hideActionTextVis)
                      SettingsTile(
                        icon: Icons.label_off_rounded,
                        title: L10n.of(context).ui_hide_action_text,
                        subtitle: L10n.of(context).msg9b7639ac,
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
                        title: L10n.of(context).msge7d18d73,
                        subtitle: L10n.of(context).msg036fe6a4,
                        onTap: () => QuickCategoriesGrid.showCustomizeDialog(context),
                      ),
                  ],
                  if (_shouldShowHeader(appearanceList)) ...[
                    const SizedBox(height: 24),
                    _buildSectionHeader(theme, L10n.of(context).ui_appearance_theme),
                    if (accentColorVis)
                      SettingsTile(
                        icon: Broken.colorfilter,
                        title: L10n.of(context).msg1b9633fe,
                        subtitle: _getAccentColorLabel(context, fileManager.accentColorOption),
                        onTap: () => _showThemePickerDialog(context, fileManager, theme),
                      ),
                    if (folderIconVis)
                      SettingsTile(
                        icon: FileUtils.getFolderIcon(fileManager.folderIconOption),
                        title: L10n.of(context).msg64db4c2d,
                        subtitle: _getFolderIconLabel(context, fileManager.folderIconOption),
                        onTap: () => _showFolderIconPickerDialog(context, fileManager, theme),
                      ),
                    if (menuIconStyleVis)
                      SettingsTile(
                        icon: Broken.category,
                        title: L10n.of(context).msgece44aa5,
                        subtitle: _getMenuIconStyleLabel(context, fileManager.menuIconStyle),
                        onTap: () => _showMenuIconStylePickerDialog(context, fileManager, theme),
                      ),
                    if (amoledVis)
                      SettingsTile(
                        icon: Broken.moon,
                        title: L10n.of(context).amoled1,
                        subtitle: L10n.of(context).amoled2,
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
                        title: L10n.of(context).ui_app_icon,
                        subtitle: _getAppIconLabel(context, fileManager.activeAppIcon),
                        onTap: () => _showAppIconPickerDialog(context, fileManager, theme),
                      ),
                    if (typographyVis)
                      SettingsTile(
                        icon: Broken.text,
                        title: L10n.of(context).msg5228b59f,
                        subtitle: _getFontFamilyLabel(context, fileManager.fontFamilyOption),
                        onTap: () => _showFontFamilyPickerDialog(context, fileManager, theme),
                      ),
                  ],
                  if (_shouldShowHeader(fileExplorerList)) ...[
                    const SizedBox(height: 24),
                    _buildSectionHeader(theme, L10n.of(context).msg1cfeaace),
                    if (showAddressBarVis)
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
                    if (showFloatingVis)
                      SettingsTile(
                        icon: Broken.add_square,
                        title: L10n.of(context).ui_show_floating_button,
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
                    if (showHiddenVis)
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
                    if (highlightFolderVis)
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
                    if (multipleTabsVis)
                      SettingsTile(
                        icon: Broken.category,
                        title: L10n.of(context).ui_enable_multi_tabs,
                        subtitle: L10n.of(context).msg4b0a7063,
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
                    if (dragDropVis)
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
                    if (confirmDragVis)
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
                  if (_shouldShowHeader(listLayoutList)) ...[
                    const SizedBox(height: 24),
                    _buildSectionHeader(theme, L10n.of(context).ui_list_layout_style),
                    if (folderFileCountVis)
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
                    if (folderContentsVis)
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
                    if (folderSizesVis)
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
                    if (use24HourVis)
                      SettingsTile(
                        icon: Icons.access_time_rounded,
                        title: L10n.of(context).ui_use_24h_format,
                        subtitle: L10n.of(context).ampm24,
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
                        title: L10n.of(context).msg25ee6612,
                        subtitle: L10n.of(context).msg337359a6,
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
                    if (hideActionButtonsVis)
                      SettingsTile(
                        icon: Icons.more_vert_rounded,
                        title: L10n.of(context).ui_hide_action_menu_buttons,
                        subtitle: L10n.of(context).msgc7196afd,
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
                      title: L10n.of(context).ui_trailing_info_when_hidden,
                      subtitle: _getTrailingInfoTypeLabel(fileManager.trailingInfoType),
                      onTap: () => _showTrailingInfoTypePickerDialog(context, fileManager, theme),
                    ),
                  ],
                  if (_shouldShowHeader(mediaActionsList)) ...[
                    const SizedBox(height: 24),
                    _buildSectionHeader(theme, L10n.of(context).msga4333788),
                    if (preferFoldersVis)
                      SettingsTile(
                        icon: Broken.folder_2,
                        title: L10n.of(context).msg20c87c8e,
                        subtitle: L10n.of(context).msg74e86197,
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
                        title: L10n.of(context).ui_show_media_previews,
                        subtitle: L10n.of(context).msg57736228,
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
                        title: L10n.of(context).msg6fdc09ac,
                        subtitle: L10n.of(context).msg0a4b0442,
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
                        title: L10n.of(context).ui_reset_default_viewers,
                        subtitle: L10n.of(context).msg50923c95,
                        onTap: () async {
                          await PreferencesService.clearAllDefaultOpenActions();
                          if (mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text(L10n.of(context).msg72b1f919),
                                behavior: SnackBarBehavior.floating,
                              ),
                            );
                          }
                        },
                      ),
                  ],
                  if (_shouldShowHeader(recycleBinList)) ...[
                    const SizedBox(height: 24),
                    _buildSectionHeader(theme, L10n.of(context).ui_recycle_bin),
                    if (recycleBinVis)
                      SettingsTile(
                        icon: Broken.trash,
                        title: L10n.of(context).msge99f4762,
                        subtitle: L10n.of(context).msg25792550,
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
                        title: L10n.of(context).msgf0ef894a,
                        subtitle: _getAutoDeleteDaysLabel(context, RecycleBinService.getAutoDeleteDays()),
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
        title: Text(L10n.of(context).msgfdae44c3),
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
              title: L10n.of(context).msga432d127,
              subtitle: fileManager.defaultToBrowseScreen ? L10n.of(context).msg2c8a394a : L10n.of(context).msg226fc6ae,
              trailing: Icon(Broken.arrow_right_3, size: 18, color: theme.colorScheme.onSurface.withOpacity(0.3)),
              onTap: () => _showDefaultHomeDialog(context, fileManager),
            ),
            SettingsTile(
              icon: Broken.arrow_swap,
              title: L10n.of(context).msgd48a082d,
              subtitle: fileManager.swipeMode == 'single' ? L10n.of(context).msgaac01f32 : L10n.of(context).msgbc9bf336,
              trailing: Icon(Broken.arrow_right_3, size: 18, color: theme.colorScheme.onSurface.withOpacity(0.3)),
              onTap: () => _showSwipeModeDialog(context, fileManager),
            ),
            SettingsTile(
              icon: Broken.menu,
              title: L10n.of(context).ui_show_bottom_action_bar,
              subtitle: fileManager.showBottomActionBar
                  ? L10n.of(context).msg8c414b06
                  : L10n.of(context).msge34c23ff,
              trailing: Icon(Broken.arrow_right_3, size: 18, color: theme.colorScheme.onSurface.withOpacity(0.3)),
              onTap: () => _showBottomActionBarDialog(context, fileManager),
            ),
            SettingsTile(
              icon: Broken.folder_open,
              title: L10n.of(context).msg59c7debc,
              subtitle: L10n.of(context).msgd1591ba4,
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
              icon: Icons.android,
              title: L10n.of(context).msga1fbf3c6,
              subtitle: L10n.of(context).msg02dddc02,
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
              icon: Icons.label_off_rounded,
              title: L10n.of(context).ui_hide_action_text,
              subtitle: L10n.of(context).msg9b7639ac,
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
              title: L10n.of(context).msge7d18d73,
              subtitle: L10n.of(context).msg036fe6a4,
              onTap: () => QuickCategoriesGrid.showCustomizeDialog(context),
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
        title: Text(L10n.of(context).ui_appearance_theme),
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
              title: L10n.of(context).msg1b9633fe,
              subtitle: _getAccentColorLabel(context, fileManager.accentColorOption),
              onTap: () => _showThemePickerDialog(context, fileManager, theme),
            ),
            SettingsTile(
              icon: FileUtils.getFolderIcon(fileManager.folderIconOption),
              title: L10n.of(context).msg64db4c2d,
              subtitle: _getFolderIconLabel(context, fileManager.folderIconOption),
              onTap: () => _showFolderIconPickerDialog(context, fileManager, theme),
            ),
            SettingsTile(
              icon: Broken.category,
              title: L10n.of(context).msgece44aa5,
              subtitle: _getMenuIconStyleLabel(context, fileManager.menuIconStyle),
              onTap: () => _showMenuIconStylePickerDialog(context, fileManager, theme),
            ),
            SettingsTile(
              icon: Broken.moon,
              title: L10n.of(context).amoled1,
              subtitle: L10n.of(context).amoled2,
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
              title: L10n.of(context).ui_app_icon,
              subtitle: _getAppIconLabel(context, fileManager.activeAppIcon),
              onTap: () => _showAppIconPickerDialog(context, fileManager, theme),
            ),
            SettingsTile(
              icon: Broken.text,
              title: L10n.of(context).msg5228b59f,
              subtitle: _getFontFamilyLabel(context, fileManager.fontFamilyOption),
              onTap: () => _showFontFamilyPickerDialog(context, fileManager, theme),
            ),
            SettingsTile(
              icon: Broken.shapes,
              title: L10n.of(context).msg2c3c5a35,
              subtitle: fileManager.categoryIconShape == 'square' ? L10n.of(context).ui_square : L10n.of(context).ui_circle,
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
        title: Text(L10n.of(context).msgad6e8bb8),
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
              title: L10n.of(context).ui_show_floating_button,
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
                  onChanged: (_) => fileManager.toggleMultipleTabs(),
                ),
              ),
              onTap: () => fileManager.toggleMultipleTabs(),
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
        title: Text(L10n.of(context).ui_list_layout_style),
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
              icon: Icons.access_time_rounded,
              title: L10n.of(context).ui_use_24h_format,
              subtitle: L10n.of(context).ampm24,
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
              title: L10n.of(context).msg25ee6612,
              subtitle: L10n.of(context).msg337359a6,
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
              title: L10n.of(context).ui_hide_action_menu_buttons,
              subtitle: L10n.of(context).msgc7196afd,
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
      case 0: return L10n.of(context).ui_no_auto_clean;
      case 1: return L10n.of(context).ui_daily;
      case 3: return L10n.of(context).msg267fcd86;
      case 7: return L10n.of(context).ui_weekly;
      case 14: return L10n.of(context).msg9104c0c5;
      case 30: return L10n.of(context).ui_monthly;
      default: return L10n.of(context).ui_every_n_days(days);
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
          SnackBar(content: Text(L10n.of(context).msg673ad9d4), behavior: SnackBarBehavior.floating),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(L10n.of(context).ui_clear_cache_failed(e)), behavior: SnackBarBehavior.floating),
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
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.of(ctx).size.height * 0.75,
            ),
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
                  Text(L10n.of(context).msgd9f142c4, style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 8),
                  ListTile(
                    leading: Icon(Broken.trash, color: Theme.of(ctx).colorScheme.error),
                    title: Text(L10n.of(context).ui_clear_remote_cache),
                    subtitle: Text(L10n.of(context).msg5472ef41, style: TextStyle(fontSize: 12)),
                    onTap: () {
                      Navigator.pop(ctx);
                      _clearRemoteCache();
                    },
                  ),
                  const Divider(height: 1),
                  const SizedBox(height: 4),
                  Flexible(
                    child: ListView(
                      shrinkWrap: true,
                      physics: const BouncingScrollPhysics(),
                      children: options.map((days) => ListTile(
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
                      )).toList(),
                    ),
                  ),
                ],
              ),
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
        title: Text(L10n.of(context).ui_media_preferences),
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
              title: L10n.of(context).msg20c87c8e,
              subtitle: L10n.of(context).msg74e86197,
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
              title: L10n.of(context).ui_show_media_previews,
              subtitle: L10n.of(context).msg57736228,
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
              icon: Broken.image,
              title: L10n.of(context).ui_remote_media_thumbnail,
              subtitle: L10n.of(context).msg225f6249,
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
            SettingsTile(
              icon: Broken.folder_open,
              title: L10n.of(context).ui_view_cache_dir,
              subtitle: L10n.of(context).msgac7687d9,
              trailing: Icon(Icons.chevron_right_rounded, color: theme.colorScheme.onSurface.withOpacity(0.4)),
              onTap: () {
                final provider = context.read<FileManagerProvider>();
                // 设置待导航路径，让 HomeScreen 切页后加载目录
                provider.setPendingBrowseNavigation('/storage/emulated/0/Download/ZenFile_Remote', []);
                provider.setNavigateToBrowseTab(true);
                // 关闭所有设置页面回到首页
                Navigator.of(context).popUntil((route) => route.isFirst);
              },
            ),
            SettingsTile(
              icon: Broken.clock,
              title: L10n.of(context).msgd9f142c4,
              subtitle: L10n.of(context).ui_auto_clean_remote_cache(_getAutoCleanLabel(_autoCleanDays)),
              trailing: Icon(Icons.chevron_right_rounded, color: theme.colorScheme.onSurface.withOpacity(0.4)),
              onTap: _showAutoCleanPicker,
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
        title: Text(L10n.of(context).ui_file_actions_viewers),
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
              title: L10n.of(context).msg6fdc09ac,
              subtitle: L10n.of(context).msg0a4b0442,
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
              title: L10n.of(context).ui_reset_default_viewers,
              subtitle: L10n.of(context).msg50923c95,
              onTap: () async {
                await PreferencesService.clearAllDefaultOpenActions();
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text(L10n.of(context).msg72b1f919),
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
        title: Text(L10n.of(context).ui_recycle_bin),
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
              title: L10n.of(context).msge99f4762,
              subtitle: L10n.of(context).msg25792550,
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
                title: L10n.of(context).msgf0ef894a,
                subtitle: _getAutoDeleteDaysLabel(context, RecycleBinService.getAutoDeleteDays()),
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

String _getAccentColorLabel(BuildContext context, String option) {
  switch (option) {
    case 'dynamic': return L10n.of(context).materialyou;
    case 'orange': return L10n.of(context).msg05cff3ad;
    case 'purple': return L10n.of(context).msg5ed35657;
    case 'green': return L10n.of(context).ui_emerald_green;
    case 'red': return L10n.of(context).ui_deep_red;
    case 'gold': return L10n.of(context).msge74a7283;
    case 'pink': return L10n.of(context).msg3904ba87;
    case 'sapphire': return L10n.of(context).msgd58d230a;
    case 'forest': return L10n.of(context).msg508b005e;
    case 'peach': return L10n.of(context).msgefdde083;
    case 'blue':
    default:
      return L10n.of(context).msg628e73a9;
  }
}

String _getFolderIconLabel(BuildContext context, String option) {
  switch (option) {
    case 'solid': return L10n.of(context).msg8244d240;
    case 'rounded': return L10n.of(context).msgf08d9b15;
    case 'special': return L10n.of(context).msge5fba3dd;
    case 'snippet': return L10n.of(context).msgfe4254dc;
    case 'outlined': return L10n.of(context).msg84719fd5;
    case 'broken':
    default:
      return L10n.of(context).zenfile4;
  }
}

String _getMenuIconStyleLabel(BuildContext context, String option) {
  switch (option) {
    case 'category': return L10n.of(context).vuesax;
    case 'hamburger':
    default:
      return L10n.of(context).msg5dc988f4;
  }
}

String _getAppIconLabel(BuildContext context, String option) {
  switch (option) {
    case 'design1': return L10n.of(context).msgd06ba04f;
    case 'design2': return L10n.of(context).msg5090469e;
    case 'design3': return L10n.of(context).d;
    case 'design4': return L10n.of(context).msg67836b24;
    case 'design5': return L10n.of(context).msgf08c8dc4;
    case 'design6': return L10n.of(context).msgdesign6;
    case 'design7': return L10n.of(context).msgdesign7;
    case 'design8': return L10n.of(context).msgdesign8;
    case 'design9': return L10n.of(context).msgdesign9;
    case 'custom': return L10n.of(context).msg7372dc9f;
    case 'default':
    default:
      return L10n.of(context).msg3004e40a;
  }
}

String _getFontFamilyLabel(BuildContext context, String option) {
  switch (option) {
    case 'nothing': return L10n.of(context).msgc540e940;
    case 'outfit': return L10n.of(context).msg00ea5776;
    case 'jetbrains': return L10n.of(context).msg7bdbfaa5;
    case 'montserrat': return L10n.of(context).msgdcb4082d;
    case 'custom': return L10n.of(context).msg9d7001d9;
    case 'default':
    default:
      return L10n.of(context).msgc2f5e9e4;
  }
}

String _getAutoDeleteDaysLabel(BuildContext context, int days) {
  if (days <= 0) return L10n.of(context).msg6a7c758f;
  if (days == 1) return L10n.of(context).ui_1_day_after;
  return L10n.of(context).days1(days);
}

void _showDefaultHomeDialog(BuildContext context, FileManagerProvider fileManager) {
  final theme = Theme.of(context);
  showModalBottomSheet(
    context: context,
    backgroundColor: theme.scaffoldBackgroundColor,
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
    builder: (ctx) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(24, 16, 24, 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Container(width: 36, height: 4,
                decoration: BoxDecoration(color: theme.colorScheme.onSurface.withOpacity(0.15), borderRadius: BorderRadius.circular(2)),
              ),
            ),
            const SizedBox(height: 20),
            Text(L10n.of(context).msga432d127, style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, fontFamily: 'LexendDeca')),
            const SizedBox(height: 6),
            Text(L10n.of(context).msgfe76ae54, style: TextStyle(fontSize: 13, color: theme.colorScheme.onSurface.withOpacity(0.5))),
            const SizedBox(height: 20),
            _buildSelectionTile(
              ctx, theme, Broken.category, L10n.of(context).msg226fc6ae, L10n.of(context).msg8af2412a,
              selected: !fileManager.defaultToBrowseScreen,
              onTap: () { Navigator.pop(ctx); fileManager.setDefaultToBrowseScreen(false); },
            ),
            const SizedBox(height: 8),
            _buildSelectionTile(
              ctx, theme, Broken.folder_open, L10n.of(context).msg2c8a394a, L10n.of(context).msg245c3258,
              selected: fileManager.defaultToBrowseScreen,
              onTap: () { Navigator.pop(ctx); fileManager.setDefaultToBrowseScreen(true); },
            ),
          ],
        ),
      );
    },
  );
}

String _getCurrentLocaleName(String locale) {
  switch (locale) {
    case 'en': return 'English';
    case 'zh_TW': return '繁體中文';
    case 'ja': return '日本語';
    case 'ko': return '한국어';
    case 'de': return 'Deutsch';
    case 'fr': return 'Français';
    case 'es': return 'Español';
    case 'ru': return 'Русский';
    case 'ar': return 'العربية';
    default: return '简体中文';
  }
}

void _showLanguagePickerDialog(BuildContext context) {
  final theme = Theme.of(context);
  final currentLocale = PreferencesService.getAppLocale();
  showModalBottomSheet(
    context: context,
    backgroundColor: theme.scaffoldBackgroundColor,
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
    builder: (ctx) {
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
                  currentLocale == 'en' ? 'Language' : L10n.of(context).ui_language,
                  style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold, fontSize: 18),
                ),
              ),
              const SizedBox(height: 16),
              Flexible(
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _buildLanguageOption(ctx, theme, currentLocale, 'zh', '简体中文', 'Simplified Chinese'),
                      _buildLanguageOption(ctx, theme, currentLocale, 'en', 'English', 'English'),
                      _buildLanguageOption(ctx, theme, currentLocale, 'zh_TW', '繁體中文', 'Traditional Chinese'),
                      _buildLanguageOption(ctx, theme, currentLocale, 'ja', '日本語', 'Japanese'),
                      _buildLanguageOption(ctx, theme, currentLocale, 'ko', '한국어', 'Korean'),
                      _buildLanguageOption(ctx, theme, currentLocale, 'de', 'Deutsch', 'German'),
                      _buildLanguageOption(ctx, theme, currentLocale, 'fr', 'Français', 'French'),
                      _buildLanguageOption(ctx, theme, currentLocale, 'es', 'Español', 'Spanish'),
                      _buildLanguageOption(ctx, theme, currentLocale, 'ru', 'Русский', 'Russian'),
                      _buildLanguageOption(ctx, theme, currentLocale, 'ar', 'العربية', 'Arabic'),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    },
  );
}

Widget _buildLanguageOption(BuildContext context, ThemeData theme, String currentLocale, String localeCode, String nativeName, String englishName) {
  final isSelected = currentLocale == localeCode;
  return Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Material(
      color: isSelected ? theme.colorScheme.primary.withOpacity(0.1) : theme.colorScheme.surface,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () {
          if (currentLocale != localeCode) {
            PreferencesService.saveAppLocale(localeCode);
            appStateKey.currentState?.setLocale(localeCode);
          }
          Navigator.pop(context);
        },
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          decoration: BoxDecoration(
            border: Border.all(
              color: isSelected ? theme.colorScheme.primary.withOpacity(0.3) : theme.colorScheme.onSurface.withOpacity(0.08),
            ),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      nativeName,
                      style: TextStyle(
                        fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
                        fontSize: 16,
                        color: isSelected ? theme.colorScheme.primary : theme.colorScheme.onSurface,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      englishName,
                      style: TextStyle(
                        fontSize: 13,
                        color: theme.colorScheme.onSurface.withOpacity(0.5),
                      ),
                    ),
                  ],
                ),
              ),
              if (isSelected) Icon(Icons.check_circle, color: theme.colorScheme.primary),
            ],
          ),
        ),
      ),
    ),
  );
}

void _showSwipeModeDialog(BuildContext context, FileManagerProvider fileManager) {
  final theme = Theme.of(context);
  showModalBottomSheet(
    context: context,
    backgroundColor: theme.scaffoldBackgroundColor,
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
    builder: (ctx) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(24, 16, 24, 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Container(width: 36, height: 4,
                decoration: BoxDecoration(color: theme.colorScheme.onSurface.withOpacity(0.15), borderRadius: BorderRadius.circular(2)),
              ),
            ),
            const SizedBox(height: 20),
            Text(L10n.of(context).msgd48a082d, style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, fontFamily: 'LexendDeca')),
            const SizedBox(height: 6),
            Text(L10n.of(context).msg4439669d, style: TextStyle(fontSize: 13, color: theme.colorScheme.onSurface.withOpacity(0.5))),
            const SizedBox(height: 20),
            _buildSelectionTile(
              ctx, theme, Broken.arrow_swap, L10n.of(context).msgaac01f32, L10n.of(context).msg46978666,
              selected: fileManager.swipeMode == 'single',
              onTap: () { Navigator.pop(ctx); fileManager.setSwipeMode('single'); },
            ),
            const SizedBox(height: 8),
            _buildSelectionTile(
              ctx, theme, Broken.arrow_swap_horizontal, L10n.of(context).msgbc9bf336, L10n.of(context).msg563871d3,
              selected: fileManager.swipeMode == 'dual',
              onTap: () { Navigator.pop(ctx); fileManager.setSwipeMode('dual'); },
            ),
          ],
        ),
      );
    },
  );
}

void _showBottomActionBarDialog(BuildContext context, FileManagerProvider fileManager) {
  final theme = Theme.of(context);
  showModalBottomSheet(
    context: context,
    backgroundColor: theme.scaffoldBackgroundColor,
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
    builder: (ctx) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(24, 16, 24, 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Container(width: 36, height: 4,
                decoration: BoxDecoration(color: theme.colorScheme.onSurface.withOpacity(0.15), borderRadius: BorderRadius.circular(2)),
              ),
            ),
            const SizedBox(height: 20),
            Text(L10n.of(context).ui_show_bottom_action_bar, style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, fontFamily: 'LexendDeca')),
            const SizedBox(height: 6),
            Text(L10n.of(context).msg309e2a28, style: TextStyle(fontSize: 13, color: theme.colorScheme.onSurface.withOpacity(0.5))),
            const SizedBox(height: 20),
            _buildSelectionTile(
              ctx, theme, Broken.arrow_square_up, L10n.of(context).msge34c23ff, L10n.of(context).msg3341e3ed,
              selected: !fileManager.showBottomActionBar,
              onTap: () { Navigator.pop(ctx); fileManager.setBottomActionBar(false); },
            ),
            const SizedBox(height: 8),
            _buildSelectionTile(
              ctx, theme, Broken.arrow_square_down, L10n.of(context).msg8c414b06, L10n.of(context).msg5d2c8e7f,
              selected: fileManager.showBottomActionBar,
              onTap: () { Navigator.pop(ctx); fileManager.setBottomActionBar(true); },
            ),
          ],
        ),
      );
    },
  );
}

Widget _buildSelectionTile(
  BuildContext ctx, ThemeData theme, IconData icon, String title, String subtitle, {
  required bool selected,
  required VoidCallback onTap,
}) {
  return InkWell(
    onTap: onTap,
    borderRadius: BorderRadius.circular(14),
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: selected ? theme.colorScheme.primary.withOpacity(0.08) : theme.colorScheme.surface.withOpacity(0.5),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: selected ? theme.colorScheme.primary.withOpacity(0.4) : theme.colorScheme.outline.withOpacity(0.1),
          width: selected ? 1.5 : 1,
        ),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: selected ? theme.colorScheme.primary.withOpacity(0.15) : theme.colorScheme.onSurface.withOpacity(0.05),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(icon, size: 20, color: selected ? theme.colorScheme.primary : theme.colorScheme.onSurface.withOpacity(0.5)),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: selected ? theme.colorScheme.primary : theme.colorScheme.onSurface)),
                const SizedBox(height: 2),
                Text(subtitle, style: TextStyle(fontSize: 11.5, color: theme.colorScheme.onSurface.withOpacity(0.5))),
              ],
            ),
          ),
          if (selected)
            Icon(Broken.tick_circle, size: 22, color: theme.colorScheme.primary),
        ],
      ),
    ),
  );
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
        {'key': 'blue', 'name': L10n.of(context).msg628e73a9, 'color': Color(0xFF369FE7)},
        {'key': 'dynamic', 'name': L10n.of(context).materialyou, 'color': Colors.teal},
        {'key': 'orange', 'name': L10n.of(context).msg05cff3ad, 'color': Color(0xFFFF6D00)},
        {'key': 'purple', 'name': L10n.of(context).msg5ed35657, 'color': Color(0xFF8E24AA)},
        {'key': 'green', 'name': L10n.of(context).ui_emerald_green, 'color': const Color(0xFF00C853)},
        {'key': 'red', 'name': L10n.of(context).ui_deep_red, 'color': const Color(0xFFD50000)},
        {'key': 'gold', 'name': L10n.of(context).msge74a7283, 'color': Color(0xFFFFD600)},
        {'key': 'pink', 'name': L10n.of(context).msg3904ba87, 'color': Color(0xFFFF2E93)},
        {'key': 'sapphire', 'name': L10n.of(context).msgd58d230a, 'color': Color(0xFF0F52BA)},
        {'key': 'forest', 'name': L10n.of(context).msg508b005e, 'color': Color(0xFF228B22)},
        {'key': 'peach', 'name': L10n.of(context).msgefdde083, 'color': Color(0xFFFF7F50)},
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
                    child: Text(L10n.of(context).msgca71ac0c, style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold)),
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
        {'key': 'solid', 'name': L10n.of(context).msg8244d240, 'icon': Icons.folder},
        {'key': 'broken', 'name': L10n.of(context).zenfile4, 'icon': Broken.folder},
        {'key': 'rounded', 'name': L10n.of(context).msgf08d9b15, 'icon': Icons.folder_rounded},
        {'key': 'special', 'name': L10n.of(context).msge5fba3dd, 'icon': Icons.folder_special_rounded},
        {'key': 'snippet', 'name': L10n.of(context).msgfe4254dc, 'icon': Icons.snippet_folder_rounded},
        {'key': 'outlined', 'name': L10n.of(context).msg84719fd5, 'icon': Icons.folder_outlined},
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
                    child: Text(L10n.of(context).msg732630c1, style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold)),
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
        {'key': 'hamburger', 'name': L10n.of(context).msg5dc988f4, 'icon': Broken.menu},
        {'key': 'category', 'name': L10n.of(context).vuesax, 'icon': Broken.category},
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
                    child: Text(L10n.of(context).msgf9224d98, style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold)),
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
        {'key': 'circle', 'name': L10n.of(context).ui_circle, 'icon': Broken.sun_fog},
        {'key': 'square', 'name': L10n.of(context).ui_square, 'icon': Broken.stop},
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
                    child: Text(L10n.of(context).msgc337ecfa, style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold)),
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
  final rootContext = context;
  showGeneralDialog(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'App Icon Picker',
    barrierColor: Colors.black.withOpacity(0.55),
    transitionDuration: const Duration(milliseconds: 250),
    pageBuilder: (dialogContext, anim1, anim2) => const SizedBox.shrink(),
    transitionBuilder: (dialogContext, anim1, anim2, child) {
      return ScaleTransition(
        scale: CurvedAnimation(parent: anim1, curve: Curves.easeOutBack),
        child: FadeTransition(
          opacity: anim1,
          child: AnimatedBuilder(
            animation: fileManager,
            builder: (context, child) {
              return AlertDialog(
                backgroundColor: theme.colorScheme.surface,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
                title: Row(
                  children: [
                    Icon(Broken.category, color: theme.colorScheme.primary, size: 26),
                    const SizedBox(width: 12),
                    Text(L10n.of(context).msgf18bc3d9, style: TextStyle(fontWeight: FontWeight.bold)),
                  ],
                ),
                content: SizedBox(
                  width: double.maxFinite,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        L10n.of(context).logo,
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
                                title: L10n.of(context).msg64a6476a,
                                imagePath: 'assets/logo/zf_Classic1.png',
                              ),
                              _buildIconOptionCard(
                                context,
                                fileManager,
                                theme,
                                id: 'design1',
                                title: L10n.of(context).msgd06ba04f,
                                imagePath: 'assets/logo/zf_m3_expressive_1.png',
                              ),
                              _buildIconOptionCard(
                                context,
                                fileManager,
                                theme,
                                id: 'design2',
                                title: L10n.of(context).msg5090469e,
                                imagePath: 'assets/logo/zf_m3_expressive_2.png',
                              ),
                              _buildIconOptionCard(
                                context,
                                fileManager,
                                theme,
                                id: 'design3',
                                title: L10n.of(context).d,
                                imagePath: 'assets/logo/zf_m3_expressive_3.png',
                              ),
                              _buildIconOptionCard(
                                context,
                                fileManager,
                                theme,
                                id: 'design4',
                                title: L10n.of(context).msg67836b24,
                                imagePath: 'assets/logo/zf_minimal_flat.png',
                              ),
                              _buildIconOptionCard(
                                context,
                                fileManager,
                                theme,
                                id: 'design5',
                                title: L10n.of(context).msgf08c8dc4,
                                imagePath: 'assets/logo/zf_glassmorphism.png',
                              ),
                              _buildIconOptionCard(
                                context,
                                fileManager,
                                theme,
                                id: 'design6',
                                title: L10n.of(context).msgdesign6,
                                imagePath: 'assets/logo/zf_cyberpunk.png',
                              ),
                              _buildIconOptionCard(
                                context,
                                fileManager,
                                theme,
                                id: 'design7',
                                title: L10n.of(context).msgdesign7,
                                imagePath: 'assets/logo/zf_neumorphism.png',
                              ),
                              _buildIconOptionCard(
                                context,
                                fileManager,
                                theme,
                                id: 'design8',
                                title: L10n.of(context).msgdesign8,
                                imagePath: 'assets/logo/zf_Classic2.png',
                              ),
                              _buildIconOptionCard(
                                context,
                                fileManager,
                                theme,
                                id: 'design9',
                                title: L10n.of(context).msgdesign9,
                                imagePath: 'assets/logo/zf_Classic3.png',
                              ),
                              _buildCustomIconOptionCard(
                                context,
                                fileManager,
                                theme,
                                rootContext,
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
                    child: Text(L10n.of(context).ui_close),
                  ),
                ],
              );
        },
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
            content: Text(L10n.of(context).title(title)),
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
  BuildContext rootContext,
) {
  return StatefulBuilder(
    builder: (context, setState) {
      final customIconPath = PreferencesService.getCustomAppIconPath();
      final hasCustomIcon = customIconPath != null && File(customIconPath).existsSync();
      final isSelected = fileManager.activeAppIcon == 'custom';

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
            if (hasCustomIcon && !isSelected) {
              _activateCustomIcon(context, fileManager, theme, rootContext, setState);
            } else {
              _pickCustomIcon(context, fileManager, theme, rootContext, setState);
            }
          },
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
                          File(customIconPath),
                          width: 56,
                          height: 56,
                          fit: BoxFit.cover,
                          errorBuilder: (_, __, ___) => _buildCustomIconPlaceholder(theme),
                        )
                      : _buildCustomIconPlaceholder(theme),
                ),
                const SizedBox(height: 8),
                Text(
                  hasCustomIcon ? L10n.of(context).msg_custom_shortcut : L10n.of(context).msg_add_custom_shortcut,
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
    },
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

Future<void> _pickCustomIcon(
  BuildContext context,
  FileManagerProvider fileManager,
  ThemeData theme,
  BuildContext rootContext, [
  StateSetter? setCardState,
]) async {
  final result = await InternalFilePickerScreen.show(
    context,
    rootPath: '/storage/emulated/0',
  );

  if (result == null || result.isEmpty) {
    debugPrint('Custom icon picker: cancelled or empty result');
    return;
  }

  final selectedPath = result.first;
  debugPrint('Custom icon picker: selected $selectedPath');
  final ext = p.extension(selectedPath).toLowerCase();
  const validExts = ['.png', '.jpg', '.jpeg', '.webp'];

  if (!validExts.contains(ext)) {
    debugPrint('Custom icon picker: invalid extension $ext');
    if (context.mounted) {
      Navigator.of(context).pop();
    }
    if (rootContext.mounted) {
      ScaffoldMessenger.of(rootContext).showSnackBar(
        SnackBar(
          content: Text(L10n.of(rootContext).pngjpgwebp),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
    return;
  }

  final file = File(selectedPath);
  if (!await file.exists()) {
    debugPrint('Custom icon picker: selected file does not exist');
    if (context.mounted) {
      Navigator.of(context).pop();
    }
    if (rootContext.mounted) {
      ScaffoldMessenger.of(rootContext).showSnackBar(
        SnackBar(
          content: Text(L10n.of(rootContext).msg_shortcut_failed),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
    return;
  }

  try {
    // Copy to app private directory using path_provider for reliability.
    // Use getApplicationDocumentsDirectory() so the path matches the native
    // filesDir, which is always accessible to the app.
    final appDir = await getApplicationDocumentsDirectory();
    final customDir = await Directory(p.join(appDir.path, 'custom_icons')).create(recursive: true);
    final destPath = p.join(customDir.path, 'custom_app_icon.png');
    debugPrint('Custom icon picker: copying to $destPath');
    await file.copy(destPath);
    await Future.delayed(const Duration(milliseconds: 100)); // ensure file is written

    await PreferencesService.saveCustomAppIconPath(destPath);
    debugPrint('Custom icon picker: saved path to preferences');

    // Refresh the custom icon card preview so it shows the newly selected image.
    setCardState?.call(() {});

    // Set active icon to custom so the UI reflects the selection and
    // preset icon cards are no longer highlighted.
    await fileManager.setActiveAppIcon('custom');

    // Option B: Add custom icon as a home screen shortcut (Android launcher
    // icon replacement via activity-alias is not feasible for runtime images).
    debugPrint('Custom icon picker: requesting home screen shortcut');
    final shortcutSuccess = await AppManagerService.addHomeScreenShortcut(path: destPath)
        .timeout(const Duration(seconds: 5), onTimeout: () {
      debugPrint('Custom icon picker: native shortcut timed out');
      return false;
    });
    debugPrint('Custom icon picker: shortcut success=$shortcutSuccess');

    // Close the icon picker dialog so the SnackBar is visible on the parent screen.
    if (context.mounted) {
      Navigator.of(context).pop();
    }
    if (rootContext.mounted) {
      ScaffoldMessenger.of(rootContext).showSnackBar(
        SnackBar(
          content: Text(shortcutSuccess
              ? L10n.of(rootContext).msg_shortcut_added
              : L10n.of(rootContext).msg_shortcut_failed),
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 2),
        ),
      );
    }
  } catch (e, stack) {
    debugPrint('Custom icon picker error: $e');
    debugPrint('$stack');
    if (context.mounted) {
      Navigator.of(context).pop();
    }
    if (rootContext.mounted) {
      ScaffoldMessenger.of(rootContext).showSnackBar(
        SnackBar(
          content: Text(L10n.of(rootContext).e12(e)),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }
}

Future<void> _activateCustomIcon(
  BuildContext context,
  FileManagerProvider fileManager,
  ThemeData theme,
  BuildContext rootContext,
  StateSetter setCardState,
) async {
  final customIconPath = PreferencesService.getCustomAppIconPath();
  if (customIconPath == null || !File(customIconPath).existsSync()) {
    // Fallback to picker if the saved file no longer exists.
    await _pickCustomIcon(context, fileManager, theme, rootContext, setCardState);
    return;
  }

  await fileManager.setActiveAppIcon('custom');
  setCardState(() {});

  debugPrint('Activate custom icon: requesting home screen shortcut');
  final shortcutSuccess = await AppManagerService.addHomeScreenShortcut(path: customIconPath)
      .timeout(const Duration(seconds: 5), onTimeout: () {
    debugPrint('Activate custom icon: native shortcut timed out');
    return false;
  });
  debugPrint('Activate custom icon: shortcut success=$shortcutSuccess');

  if (context.mounted) {
    Navigator.of(context).pop();
  }
  if (rootContext.mounted) {
    ScaffoldMessenger.of(rootContext).showSnackBar(
      SnackBar(
        content: Text(shortcutSuccess
            ? L10n.of(rootContext).msg_shortcut_added
            : L10n.of(rootContext).msg_shortcut_failed),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 2),
      ),
    );
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
        {'key': 'default', 'name': L10n.of(context).msgc2f5e9e4, 'desc': L10n.of(context).msg375c9eb8},
        {'key': 'nothing', 'name': L10n.of(context).msgc540e940, 'desc': L10n.of(context).msg817e321b},
        {'key': 'outfit', 'name': L10n.of(context).msg00ea5776, 'desc': L10n.of(context).msg3c2a24cc},
        {'key': 'jetbrains', 'name': L10n.of(context).msg7bdbfaa5, 'desc': L10n.of(context).msg978f8d11},
        {'key': 'montserrat', 'name': L10n.of(context).msgdcb4082d, 'desc': L10n.of(context).msg93b657aa},
        if (hasCustomFont)
          {'key': 'custom', 'name': L10n.of(context).ui_custom_font_with_name(p.basename(fileManager.customFontPath!)), 'desc': L10n.of(context).msg9db40ad6},
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
                    L10n.of(context).msg5228b59f,
                    style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold, fontFamily: 'LexendDeca'),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    L10n.of(context).zenfile5,
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
                      hasCustomFont ? L10n.of(context).msg7372efa5 : L10n.of(context).ui_import_custom_font,
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
                                SnackBar(content: Text(L10n.of(context).ui_custom_font_applied(p.basename(filePat)))),
                              );
                            }
                          } else {
                            if (context.mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(content: Text(L10n.of(context).msg3186839b)),
                              );
                            }
                          }
                        } else {
                          if (context.mounted) {
                            showDialog(
                              context: context,
                              builder: (context) => AlertDialog(
                                title: Text(L10n.of(context).ui_invalid_file_type),
                                content: Text(L10n.of(context).opentypeotftruetypettf),
                                actions: [
                                  TextButton(
                                    onPressed: () => Navigator.pop(context),
                                    child: Text(L10n.of(context).ui_confirm),
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
                      label: Text(L10n.of(context).msgcf42dedc, style: TextStyle(color: Colors.redAccent, fontWeight: FontWeight.bold, fontFamily: 'LexendDeca')),
                      onPressed: () async {
                        Navigator.pop(ctx);
                        await fileManager.setCustomFontPath(null);
                        if (current == 'custom') {
                          fileManager.setFontFamilyOption('default');
                        }
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(content: Text(L10n.of(context).msg2b9abfaa)),
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
        {'days': 7, 'label': L10n.of(context).msgfdef8c23},
        {'days': 15, 'label': L10n.of(context).msg25436ba3},
        {'days': 30, 'label': L10n.of(context).msg85e7f60c},
        {'days': 0, 'label': L10n.of(context).msgd61e706f},
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
                  L10n.of(context).msgf0ef894a,
                  style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold, fontSize: 18),
                ),
              ),
              const SizedBox(height: 4),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8.0),
                child: Text(
                  L10n.of(context).msg1200d6b7,
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
