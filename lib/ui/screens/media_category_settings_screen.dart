import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/icon_fonts/broken_icons.dart';
import '../../services/preferences_service.dart';
import '../../providers/media_provider.dart';
import '../../providers/file_manager_provider.dart';
import '../../services/network_connections_service.dart';
import '../../l10n/generated/app_localizations.dart';
import '../../models/media_type.dart';
import 'internal_file_picker_screen.dart';
import '../widgets/remote_path_picker.dart';

/// 单个媒体分类的「类别设置」页。
/// 从 MediaCategoryScreen 右上角设置按钮进入，包含三大板块：
///  1. 智能过滤（噪音过滤主开关 + 规则）
///  2. 默认扫描位置（排除 / 恢复）
///  3. 自定义扫描位置（本地 / 远程路径增删）
class MediaCategorySettingsScreen extends StatefulWidget {
  final MediaType mediaType;

  const MediaCategorySettingsScreen({super.key, required this.mediaType});

  @override
  State<MediaCategorySettingsScreen> createState() =>
      _MediaCategorySettingsScreenState();
}

class _MediaCategorySettingsScreenState
    extends State<MediaCategorySettingsScreen> {
  late bool _enabled;

  @override
  void initState() {
    super.initState();
    _enabled = PreferencesService.getMediaNoiseFilter(_categoryName);
  }

  /// MediaType → MediaProvider 内部使用的类别名称（与 PreferencesService 键一致）。
  String get _categoryName {
    switch (widget.mediaType) {
      case MediaType.images:
        return '图片';
      case MediaType.videos:
        return '视频';
      case MediaType.audios:
        return '音频';
      case MediaType.documents:
        return '文档';
      case MediaType.archives:
        return '压缩包';
      case MediaType.downloads:
        return '下载';
      case MediaType.apks:
        return '安装包';
      case MediaType.screenshots:
        return '截图';
    }
  }

  String _categoryTitle(BuildContext context) {
    final l10n = L10n.of(context);
    switch (widget.mediaType) {
      case MediaType.images:
        return l10n.cat_images;
      case MediaType.videos:
        return l10n.cat_videos;
      case MediaType.audios:
        return l10n.cat_audios;
      case MediaType.documents:
        return l10n.cat_documents;
      case MediaType.archives:
        return l10n.msgc806d0fa;
      case MediaType.downloads:
        return l10n.cat_downloads;
      case MediaType.apks:
        return l10n.msg03070d08;
      case MediaType.screenshots:
        return l10n.cat_screenshots;
    }
  }

  IconData get _categoryIcon {
    switch (widget.mediaType) {
      case MediaType.images:
        return Broken.image;
      case MediaType.videos:
        return Broken.video;
      case MediaType.audios:
        return Broken.music;
      case MediaType.documents:
        return Broken.document;
      case MediaType.archives:
        return Broken.archive;
      case MediaType.downloads:
        return Broken.document_download;
      case MediaType.apks:
        return Broken.box;
      case MediaType.screenshots:
        return Broken.camera;
    }
  }

  String _ruleSubtitle(BuildContext context) {
    final l10n = L10n.of(context);
    switch (widget.mediaType) {
      case MediaType.images:
        return l10n.ui_noise_filter_images_subtitle;
      case MediaType.videos:
        return l10n.ui_noise_filter_videos_subtitle;
      case MediaType.audios:
        return l10n.ui_noise_filter_audios_subtitle;
      case MediaType.screenshots:
        return l10n.ui_noise_filter_screenshots_subtitle;
      case MediaType.documents:
        return l10n.ui_noise_filter_documents_subtitle;
      case MediaType.archives:
        return l10n.ui_noise_filter_archives_subtitle;
      case MediaType.downloads:
        return l10n.ui_noise_filter_downloads_subtitle;
      case MediaType.apks:
        return l10n.ui_noise_filter_apks_subtitle;
    }
  }

  /// 各分类的默认扫描位置（与历史实现保持一致）。
  List<String> _getDefaultPaths(BuildContext context) {
    final l10n = L10n.of(context);
    switch (_categoryName) {
      case '图片':
        return [l10n.msge86bd662, '/storage/emulated/0/DCIM', '/storage/emulated/0/Pictures'];
      case '视频':
        return [l10n.msge86bd662, '/storage/emulated/0/DCIM', '/storage/emulated/0/Movies'];
      case '音频':
        return [l10n.msg16166a01, '/storage/emulated/0/Music'];
      case '文档':
        return ['/storage/emulated/0/Documents', l10n.msgbb34b7ec];
      case '压缩包':
        return ['/storage/emulated/0/Download', l10n.msgbb34b7ec];
      case '下载':
        return ['/storage/emulated/0/Download', '/storage/emulated/0/Downloads'];
      case '安装包':
        return ['/storage/emulated/0/Download', l10n.msgbb34b7ec];
      case '截图':
        return [
          l10n.msg26a1f2d9,
          '/storage/emulated/0/DCIM/Screenshots',
          '/storage/emulated/0/Pictures/Screenshots',
        ];
      default:
        return [];
    }
  }

  Future<void> _setEnabled(bool value) async {
    await PreferencesService.saveMediaNoiseFilter(_categoryName, value);
    setState(() => _enabled = value);
  }

  Future<void> _restoreDefault() async {
    await PreferencesService.saveMediaNoiseFilter(_categoryName, true);
    setState(() => _enabled = true);
  }

  BoxDecoration _cardDecoration(ThemeData theme) {
    return BoxDecoration(
      color: theme.colorScheme.surface,
      borderRadius: BorderRadius.circular(16),
      border: Border.all(
        color: theme.colorScheme.onSurface.withOpacity(0.08),
      ),
    );
  }

  Widget _sectionTitle(ThemeData theme, String title) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 4, 4, 8),
      child: Text(
        title,
        style: theme.textTheme.titleSmall?.copyWith(
          fontWeight: FontWeight.bold,
          color: theme.colorScheme.primary,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = L10n.of(context);

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.ui_category_settings_title),
        leading: IconButton(
          icon: const Icon(Broken.arrow_left),
          onPressed: () => Navigator.pop(context),
        ),
      ),
      body: SafeArea(
        child: ListView(
          physics: const BouncingScrollPhysics(),
          padding: EdgeInsets.only(
            top: 16,
            left: 16,
            right: 16,
            bottom: MediaQuery.of(context).padding.bottom + 24,
          ),
          children: [
            _buildHeaderCard(theme, l10n),
            const SizedBox(height: 20),
            _sectionTitle(theme, l10n.ui_media_filter_master_switch),
            _buildMasterSwitchCard(theme, l10n),
            const SizedBox(height: 12),
            _buildRulesCard(theme, l10n),
            const SizedBox(height: 20),
            _sectionTitle(theme, l10n.ui_default_scan_locations),
            _buildDefaultLocationsCard(theme),
            const SizedBox(height: 20),
            _sectionTitle(theme, l10n.msg21de5dd7),
            _buildCustomLocationsCard(theme),
            const SizedBox(height: 20),
            _sectionTitle(theme, l10n.ui_excluded_folders_title),
            _buildExcludedFoldersCard(theme),
            const SizedBox(height: 24),
            Center(
              child: TextButton.icon(
                icon: Icon(Broken.refresh, color: theme.colorScheme.primary),
                label: Text(l10n.ui_media_filter_restore_default),
                onPressed: _restoreDefault,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHeaderCard(ThemeData theme, L10n l10n) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: theme.colorScheme.primary.withOpacity(0.08),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        children: [
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              color: theme.colorScheme.primary.withOpacity(0.12),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(
              _categoryIcon,
              color: theme.colorScheme.primary,
              size: 26,
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _categoryTitle(context),
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  l10n.ui_category_settings_description,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurface.withOpacity(0.6),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMasterSwitchCard(ThemeData theme, L10n l10n) {
    return Container(
      decoration: _cardDecoration(theme),
      child: SwitchListTile(
        value: _enabled,
        activeColor: theme.colorScheme.primary,
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        secondary: Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: theme.colorScheme.primary.withOpacity(0.1),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(
            Broken.filter,
            color: theme.colorScheme.primary,
            size: 22,
          ),
        ),
        title: Text(
          l10n.ui_media_filter_master_switch,
          style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15),
        ),
        subtitle: Text(
          l10n.ui_media_filter_master_hint,
          style: TextStyle(
            fontSize: 12,
            color: theme.colorScheme.onSurface.withOpacity(0.55),
          ),
        ),
        onChanged: _setEnabled,
      ),
    );
  }

  Widget _buildRulesCard(ThemeData theme, L10n l10n) {
    return Container(
      decoration: _cardDecoration(theme),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
            child: Text(
              l10n.ui_media_filter_rules,
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.bold,
                color: theme.colorScheme.primary,
              ),
            ),
          ),
          Opacity(
            opacity: _enabled ? 1.0 : 0.45,
            child: IgnorePointer(
              ignoring: !_enabled,
              child: Column(
                children: [
                  ListTile(
                    contentPadding: const EdgeInsets.symmetric(horizontal: 16),
                    leading: Icon(
                      _categoryIcon,
                      color: theme.colorScheme.primary,
                      size: 22,
                    ),
                    title: Text(
                      _ruleSubtitle(context),
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    trailing: Switch(
                      value: _enabled,
                      activeColor: theme.colorScheme.primary,
                      onChanged: _setEnabled,
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 6),
        ],
      ),
    );
  }

  /// 默认扫描位置：按类别列出系统默认目录，可排除 / 恢复。
  Widget _buildDefaultLocationsCard(ThemeData theme) {
    return Consumer<MediaProvider>(
      builder: (context, provider, _) {
        final defaultPaths = _getDefaultPaths(context);
        final excluded =
            provider.excludedDefaultPaths[_categoryName] ?? const <String>[];
        if (defaultPaths.isEmpty) return const SizedBox.shrink();
        return Container(
          decoration: _cardDecoration(theme),
          child: Column(
            children: defaultPaths.map((path) {
              final isExcluded = excluded.contains(path);
              return _defaultPathRow(theme, provider, path, isExcluded);
            }).toList(),
          ),
        );
      },
    );
  }

  Widget _defaultPathRow(
    ThemeData theme,
    MediaProvider provider,
    String path,
    bool isExcluded,
  ) {
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: isExcluded
            ? theme.colorScheme.error.withOpacity(0.03)
            : theme.colorScheme.primary.withOpacity(0.05),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: isExcluded
              ? theme.colorScheme.error.withOpacity(0.1)
              : theme.colorScheme.primary.withOpacity(0.1),
        ),
      ),
      child: Row(
        children: [
          Icon(
            Icons.folder_shared_outlined,
            size: 16,
            color: isExcluded
                ? theme.colorScheme.error.withOpacity(0.5)
                : theme.colorScheme.primary,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              path,
              style: TextStyle(
                fontSize: 12,
                color: isExcluded
                    ? theme.colorScheme.onSurface.withOpacity(0.4)
                    : theme.colorScheme.onSurface.withOpacity(0.85),
                decoration: isExcluded ? TextDecoration.lineThrough : null,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (isExcluded)
            IconButton(
              icon: const Icon(
                Icons.add_circle_outline,
                color: Colors.green,
                size: 18,
              ),
              tooltip: L10n.of(context).msg5c29ad2f,
              onPressed: () =>
                  provider.includeDefaultCategoryPath(_categoryName, path),
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(),
              visualDensity: VisualDensity.compact,
            )
          else
            IconButton(
              icon: const Icon(
                Broken.trash,
                color: Colors.redAccent,
                size: 18,
              ),
              tooltip: L10n.of(context).ui_exclude_location,
              onPressed: () =>
                  provider.excludeDefaultCategoryPath(_categoryName, path),
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(),
              visualDensity: VisualDensity.compact,
            ),
        ],
      ),
    );
  }

  /// 自定义扫描位置：本地 / 远程路径增删。
  Widget _buildCustomLocationsCard(ThemeData theme) {
    return Consumer<MediaProvider>(
      builder: (context, provider, _) {
        final fileManager = context.read<FileManagerProvider>();
        final customPaths =
            provider.customCategoryPaths[_categoryName] ?? const <String>[];
        return Container(
          decoration: _cardDecoration(theme),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (customPaths.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(
                    vertical: 12.0,
                    horizontal: 12,
                  ),
                  child: Text(
                    L10n.of(context).msg4bb81f99,
                    style: TextStyle(
                      color: theme.colorScheme.onSurface.withOpacity(0.4),
                      fontSize: 12,
                      fontStyle: FontStyle.italic,
                    ),
                  ),
                )
              else
                ...customPaths.map(
                  (path) => _customPathRow(theme, provider, path),
                ),
              const SizedBox(height: 8),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                child: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    TextButton.icon(
                      onPressed: () async {
                        final pickedPaths =
                            await InternalFilePickerScreen.show(
                          context,
                          rootPath: fileManager.rootPath,
                          pickDirectory: true,
                        );
                        if (pickedPaths != null && pickedPaths.isNotEmpty) {
                          for (final p in pickedPaths) {
                            provider.addCustomCategoryPath(_categoryName, p);
                          }
                        }
                      },
                      icon: const Icon(Broken.folder_add, size: 16),
                      label: Text(
                        L10n.of(context).ui_add_custom_path,
                        style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      style: TextButton.styleFrom(
                        foregroundColor: theme.colorScheme.primary,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 8,
                        ),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                        backgroundColor:
                            theme.colorScheme.primary.withOpacity(0.08),
                      ),
                    ),
                    TextButton.icon(
                      onPressed: () async {
                        final remotePath = await showRemotePathPicker(context);
                        if (remotePath != null) {
                          provider.addCustomCategoryPath(
                            _categoryName,
                            remotePath,
                          );
                        }
                      },
                      icon: const Icon(Broken.wifi, size: 16),
                      label: Text(
                        L10n.of(context).ui_add_remote_path,
                        style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      style: TextButton.styleFrom(
                        foregroundColor: theme.colorScheme.primary,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 8,
                        ),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                        backgroundColor:
                            theme.colorScheme.primary.withOpacity(0.08),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
  }

  Widget _customPathRow(
    ThemeData theme,
    MediaProvider provider,
    String path,
  ) {
    final isRemote = path.startsWith('remote://');
    String displayPath;
    IconData pathIcon;
    if (isRemote) {
      final uriPart = path.substring('remote://'.length);
      final separatorIndex = uriPart.indexOf('|');
      final connId = separatorIndex > 0 ? uriPart.substring(0, separatorIndex) : '';
      final remotePath =
          separatorIndex > 0 ? uriPart.substring(separatorIndex + 1) : '/';
      final conn = NetworkConnectionsService.getConnections()
          .where((c) => c.id == connId)
          .firstOrNull;
      displayPath = '${conn?.name ?? connId}:$remotePath';
      pathIcon = Broken.wifi;
    } else {
      displayPath = path;
      pathIcon = Broken.folder;
    }
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceVariant.withOpacity(0.3),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          Icon(
            pathIcon,
            size: 16,
            color: isRemote ? theme.colorScheme.primary : Colors.grey,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              displayPath,
              style: const TextStyle(fontSize: 12),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          IconButton(
            icon: const Icon(
              Broken.trash,
              color: Colors.redAccent,
              size: 18,
            ),
            onPressed: () =>
                provider.removeCustomCategoryPath(_categoryName, path),
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(),
            visualDensity: VisualDensity.compact,
          ),
        ],
      ),
    );
  }

  /// 屏蔽文件夹：添加后该分类不再扫描/索引此文件夹下的文件。
  Widget _buildExcludedFoldersCard(ThemeData theme) {
    return Consumer<MediaProvider>(
      builder: (context, provider, _) {
        final fileManager = context.read<FileManagerProvider>();
        final excludedFolders =
            provider.excludedFolders[_categoryName] ?? const <String>[];
        return Container(
          decoration: _cardDecoration(theme),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (excludedFolders.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(
                    vertical: 12.0,
                    horizontal: 12,
                  ),
                  child: Text(
                    L10n.of(context).ui_excluded_folders_empty,
                    style: TextStyle(
                      color: theme.colorScheme.onSurface.withOpacity(0.4),
                      fontSize: 12,
                      fontStyle: FontStyle.italic,
                    ),
                  ),
                )
              else
                ...excludedFolders.map(
                  (path) => _excludedFolderRow(theme, provider, path),
                ),
              const SizedBox(height: 8),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                child: TextButton.icon(
                  onPressed: () async {
                    final pickedPaths = await InternalFilePickerScreen.show(
                      context,
                      rootPath: fileManager.rootPath,
                      pickDirectory: true,
                    );
                    if (pickedPaths != null && pickedPaths.isNotEmpty) {
                      for (final p in pickedPaths) {
                        provider.addExcludedFolder(_categoryName, p);
                      }
                    }
                  },
                  icon: const Icon(Broken.folder_add, size: 16),
                  label: Text(
                    L10n.of(context).ui_add_excluded_folder,
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  style: TextButton.styleFrom(
                    foregroundColor: theme.colorScheme.primary,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                    backgroundColor:
                        theme.colorScheme.primary.withOpacity(0.08),
                  ),
                ),
              ),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
  }

  Widget _excludedFolderRow(
    ThemeData theme,
    MediaProvider provider,
    String path,
  ) {
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: theme.colorScheme.error.withOpacity(0.03),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: theme.colorScheme.error.withOpacity(0.1),
        ),
      ),
      child: Row(
        children: [
          Icon(
            Icons.folder_off_outlined,
            size: 16,
            color: theme.colorScheme.error.withOpacity(0.6),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              path,
              style: TextStyle(
                fontSize: 12,
                color: theme.colorScheme.onSurface.withOpacity(0.7),
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          IconButton(
            icon: const Icon(
              Broken.trash,
              color: Colors.redAccent,
              size: 18,
            ),
            tooltip: L10n.of(context).ui_remove_excluded_folder,
            onPressed: () => provider.removeExcludedFolder(_categoryName, path),
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(),
            visualDensity: VisualDensity.compact,
          ),
        ],
      ),
    );
  }
}
