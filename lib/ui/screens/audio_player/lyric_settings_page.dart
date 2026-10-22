import 'package:flutter/material.dart';

import '../../../core/icon_fonts/broken_icons.dart';
import '../../../l10n/generated/app_localizations.dart';
import '../../../services/lyric_animation_style.dart';
import '../../../services/preferences_service.dart';
import 'lyric_color_picker_dialog.dart';
import 'lyric_offset_dialog.dart';
import 'lyric_style_dropdown.dart';
import 'lyric_style_sheet.dart';

/// 歌词设置页：从播放页三点菜单进入，集中管理歌词相关功能。
///
/// 包含桌面歌词开关、歌词动画风格、歌词颜色（未播放/当前播放/已播放）、
/// 歌词整体偏移、在线搜索歌词、本地导入歌词。
///
/// 动画风格此前不在此页（只有全屏歌词页顶栏能进），但它是「歌词怎么显示」
/// 的一部分，放在设置页里才找得到；三个入口共用同一个下拉弹窗
/// [showLyricStyleSheet]，选中即写 [PreferencesService]，不会两处不同步。
/// 桌面歌词开关的权限/启动逻辑由播放页持有（需要 player 实例同步进度），
/// 因此通过 [onToggleDesktopLyric] 回调委托，页面只负责开关状态展示。
class LyricSettingsPage extends StatefulWidget {
  final bool desktopLyricEnabled;
  final Future<void> Function() onToggleDesktopLyric;
  final VoidCallback onSearchOnlineLyrics;
  final VoidCallback onImportLocalLyrics;

  /// 当前播放歌曲（歌词偏移「仅本曲」作用域用）。
  final String songPath;
  final String songTitle;

  /// 歌词偏移实时预览（拖动滑杆时持续回调，仅改内存不落盘）。
  final void Function(int previewMs)? onPreviewLyricOffset;

  const LyricSettingsPage({
    super.key,
    required this.desktopLyricEnabled,
    required this.onToggleDesktopLyric,
    required this.onSearchOnlineLyrics,
    required this.onImportLocalLyrics,
    this.songPath = '',
    this.songTitle = '',
    this.onPreviewLyricOffset,
  });

  @override
  State<LyricSettingsPage> createState() => _LyricSettingsPageState();
}

class _LyricSettingsPageState extends State<LyricSettingsPage> {
  late bool _desktopLyricEnabled;

  @override
  void initState() {
    super.initState();
    _desktopLyricEnabled = widget.desktopLyricEnabled;
  }

  /// 当前歌词动画风格（弹窗选中后会自己落盘，这里只读不写）。
  LyricAnimationStyle get _style => LyricAnimationStyle.fromName(
    PreferencesService.getLyricAnimationStyleName(),
  );

  // ── 歌词三色 ──────────────────────────────────────────────────────────
  // null = 未自定义（用默认配色）。effective 用于色点 / 色值展示。

  Color? get _unplayed => PreferencesService.getLyricColorUnplayed();
  Color? get _current => PreferencesService.getLyricColorCurrent();
  Color? get _played => PreferencesService.getLyricColorPlayed();

  Future<void> _pickColor({
    required String title,
    required Color effective,
    required Color? custom,
    required Future<void> Function(Color?) save,
  }) async {
    final result = await showLyricColorPicker(
      context,
      currentColor: effective,
      title: title,
    );
    if (result == null || !mounted) return;
    await save(result.reset ? null : result.color);
    if (!mounted) return;
    setState(() {});
  }

  Widget _colorDot(Color color, ThemeData theme) {
    return Container(
      width: 22,
      height: 22,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        border: Border.all(
          color: theme.colorScheme.onSurface.withValues(alpha: 0.25),
          width: 1,
        ),
      ),
    );
  }

  /// 色值文案：始终显示当前生效色的 hex（默认配色也是具体颜色）。
  String _colorLabel(Color effective) {
    final hex = effective.toARGB32().toRadixString(16).toUpperCase();
    return '#${hex.substring(2)}';
  }

  // ── 歌词整体偏移 ──────────────────────────────────────────────────────

  int? get _songOffsetMs =>
      PreferencesService.getLyricOffsetForSong(widget.songPath);

  /// 生效偏移：单曲覆盖优先，否则全局。
  int get _effectiveOffsetMs =>
      _songOffsetMs ?? PreferencesService.getLyricOffsetGlobal();

  String _offsetSubtitle() {
    final scope = _songOffsetMs != null
        ? L10n.of(context).lyric_offset_scope_current
        : L10n.of(context).lyric_offset_scope_global;
    return '${formatLyricOffset(_effectiveOffsetMs)} · $scope';
  }

  Future<void> _showOffsetDialog() async {
    await LyricOffsetDialog.show(
      context,
      songPath: widget.songPath,
      songTitle: widget.songTitle,
      globalMs: PreferencesService.getLyricOffsetGlobal(),
      songMs: _songOffsetMs,
      effectiveMs: _effectiveOffsetMs,
      onPreview: widget.onPreviewLyricOffset ?? (_) {},
    );
    if (!mounted) return;
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final l10n = L10n.of(context);
    final theme = Theme.of(context);
    final effUnplayed = _unplayed ?? kLyricColorUnplayedDefault;
    final effCurrent = _current ?? kLyricColorCurrentDefault;
    final effPlayed = _played ?? kLyricColorPlayedDefault;

    return Scaffold(
      appBar: AppBar(
        title: Text(
          l10n.lyric_settings,
          style: const TextStyle(fontWeight: FontWeight.w700),
        ),
        centerTitle: true,
      ),
      body: ListView(
        children: [
          const SizedBox(height: 8),
          // ── 桌面歌词悬浮窗 ──────────────────────────────────────────────
          SwitchListTile(
            secondary: const Icon(Broken.note_text),
            title: Text(
              l10n.ui_desktop_lyric,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            value: _desktopLyricEnabled,
            activeThumbColor: theme.colorScheme.primary,
            onChanged: (_) async {
              await widget.onToggleDesktopLyric();
              if (!mounted) return;
              setState(
                () => _desktopLyricEnabled =
                    PreferencesService.getDesktopLyricEnabled(),
              );
            },
          ),
          const Divider(height: 1),
          // ── 歌词动画风格 ────────────────────────────────────────────────
          ListTile(
            leading: const Icon(Icons.animation_rounded),
            title: Text(
              l10n.lyric_animation_style,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            subtitle: Text(lyricStyleName(l10n, _style)),
            trailing: const Icon(Icons.chevron_right_rounded),
            onTap: () => showLyricStyleSheet(
              context,
              current: _style,
              onSelected: (_) => setState(() {}),
            ),
          ),
          const Divider(height: 1),
          // ── 歌词颜色 ────────────────────────────────────────────────────
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
            child: Row(
              children: [
                const Icon(Icons.palette_outlined, size: 20),
                const SizedBox(width: 16),
                Text(
                  l10n.lyric_color_settings,
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.9),
                  ),
                ),
              ],
            ),
          ),
          ListTile(
            leading: const Icon(Icons.lyrics_outlined),
            title: Text(l10n.lyric_color_unplayed),
            subtitle: Text(l10n.lyric_color_unplayed_desc),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  _colorLabel(effUnplayed),
                  style: TextStyle(
                    fontSize: 12,
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
                  ),
                ),
                const SizedBox(width: 8),
                _colorDot(effUnplayed, theme),
              ],
            ),
            onTap: () => _pickColor(
              title: l10n.lyric_color_unplayed,
              effective: effUnplayed,
              custom: _unplayed,
              save: PreferencesService.saveLyricColorUnplayed,
            ),
          ),
          ListTile(
            leading: const Icon(Icons.music_note_rounded),
            title: Text(l10n.lyric_color_current),
            subtitle: Text(l10n.lyric_color_current_desc),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  _colorLabel(effCurrent),
                  style: TextStyle(
                    fontSize: 12,
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
                  ),
                ),
                const SizedBox(width: 8),
                _colorDot(effCurrent, theme),
              ],
            ),
            onTap: () => _pickColor(
              title: l10n.lyric_color_current,
              effective: effCurrent,
              custom: _current,
              save: PreferencesService.saveLyricColorCurrent,
            ),
          ),
          ListTile(
            leading: const Icon(Icons.playlist_add_check_rounded),
            title: Text(l10n.lyric_color_played),
            subtitle: Text(l10n.lyric_color_played_desc),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  _colorLabel(effPlayed),
                  style: TextStyle(
                    fontSize: 12,
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
                  ),
                ),
                const SizedBox(width: 8),
                _colorDot(effPlayed, theme),
              ],
            ),
            onTap: () => _pickColor(
              title: l10n.lyric_color_played,
              effective: effPlayed,
              custom: _played,
              save: PreferencesService.saveLyricColorPlayed,
            ),
          ),
          const Divider(height: 1),
          // ── 歌词整体偏移 ────────────────────────────────────────────────
          ListTile(
            leading: const Icon(Icons.timer_outlined),
            title: Text(l10n.lyric_offset),
            subtitle: Text(_offsetSubtitle()),
            trailing: const Icon(Icons.chevron_right_rounded),
            onTap: _showOffsetDialog,
          ),
          const Divider(height: 1),
          // ── 在线搜索歌词 ────────────────────────────────────────────────
          ListTile(
            leading: const Icon(Icons.search_rounded),
            title: Text(
              l10n.ui_search_lyrics_online,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            trailing: const Icon(Icons.chevron_right_rounded),
            onTap: () {
              Navigator.pop(context);
              widget.onSearchOnlineLyrics();
            },
          ),
          const Divider(height: 1),
          // ── 本地导入歌词 ────────────────────────────────────────────────
          ListTile(
            leading: const Icon(Icons.folder_open_rounded),
            title: Text(
              l10n.ui_select_lyrics_file,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            trailing: const Icon(Icons.chevron_right_rounded),
            onTap: () {
              Navigator.pop(context);
              widget.onImportLocalLyrics();
            },
          ),
          const Divider(height: 1),
        ],
      ),
    );
  }
}
