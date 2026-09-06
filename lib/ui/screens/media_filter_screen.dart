import 'package:flutter/material.dart';
import '../../core/icon_fonts/broken_icons.dart';
import '../../services/preferences_service.dart';
import '../../l10n/generated/app_localizations.dart';
import 'media_category_screen.dart';

/// 单个媒体分类的「噪音过滤」设置页。
/// 从 MediaCategoryScreen 右上角过滤按钮进入，按当前分类展示对应的过滤规则。
/// 设计参考：截图中的「媒体来源」卡片式设置页，主开关 + 规则列表 + 恢复默认。
class MediaFilterScreen extends StatefulWidget {
  final MediaType mediaType;

  const MediaFilterScreen({super.key, required this.mediaType});

  @override
  State<MediaFilterScreen> createState() => _MediaFilterScreenState();
}

class _MediaFilterScreenState extends State<MediaFilterScreen> {
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

  Future<void> _setEnabled(bool value) async {
    await PreferencesService.saveMediaNoiseFilter(_categoryName, value);
    setState(() => _enabled = value);
  }

  Future<void> _restoreDefault() async {
    await PreferencesService.saveMediaNoiseFilter(_categoryName, true);
    setState(() => _enabled = true);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = L10n.of(context);

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.ui_media_filter_title),
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
            // 分类标题卡片
            _buildHeaderCard(theme, l10n),
            const SizedBox(height: 16),
            // 主开关
            _buildMasterSwitchCard(theme, l10n),
            const SizedBox(height: 16),
            // 过滤规则
            _buildRulesCard(theme, l10n),
            const SizedBox(height: 24),
            // 恢复默认
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
                  l10n.ui_media_filter_description,
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
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: theme.colorScheme.onSurface.withOpacity(0.08),
        ),
      ),
      child: SwitchListTile(
        value: _enabled,
        activeColor: theme.colorScheme.primary,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 4,
        ),
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
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: theme.colorScheme.onSurface.withOpacity(0.08),
        ),
      ),
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
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 16,
                    ),
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
}
