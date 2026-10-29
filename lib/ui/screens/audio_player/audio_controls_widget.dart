import 'dart:io';
import 'package:flutter/material.dart';
import '../../../core/icon_fonts/broken_icons.dart';
import 'package:zenfile/core/utils.dart';
import 'package:zenfile/l10n/generated/app_localizations.dart';

class AudioControlsWidget extends StatelessWidget {
  final bool isPlaying;
  final VoidCallback onPlayPause;
  final VoidCallback? onPrevious;
  final VoidCallback? onNext;
  final VoidCallback onShowLyrics;
  final VoidCallback onShowSleepTimer;
  final VoidCallback onShowEqualizer;
  final VoidCallback onShowQueue;
  // 0=sequential, 1=list loop, 2=single loop, 3=shuffle
  final int playbackMode;

  /// 从弹出菜单中选定播放模式（值同 [playbackMode] 的编码）。
  final ValueChanged<int> onPlaybackModeSelected;
  final Color accentColor;
  // 0=off, 1=single line, 2=multi line, 3=full panel
  final int lyricsDisplayMode;
  // 当前播放文件的路径，用于从扩展名/文件头推断真实格式与位深
  final String? audioPath;

  /// 紧凑模式（横屏等矮视口）：播放圆钮 76→56、行距 32→10、工具键 40→32，
  /// 保证「主控行 + 底部工具行」在横屏高度内完整可见。
  final bool compact;

  const AudioControlsWidget({
    super.key,
    required this.isPlaying,
    required this.onPlayPause,
    required this.onPrevious,
    required this.onNext,
    required this.onShowLyrics,
    required this.onShowSleepTimer,
    required this.onShowEqualizer,
    required this.onShowQueue,
    required this.playbackMode,
    required this.onPlaybackModeSelected,
    required this.accentColor,
    this.lyricsDisplayMode = 0,
    this.audioPath,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final compact = this.compact;
    // 紧凑模式的几何参数（普通模式与原值一致）。
    final mainIconSize = compact ? 26.0 : 32.0;
    final playSize = compact ? 56.0 : 76.0;
    final playIconSize = compact ? 30.0 : 38.0;
    final rowGap = compact ? 10.0 : 16.0;
    final sectionGap = compact ? 10.0 : 32.0;
    final utilIconSize = compact ? 20.0 : 22.0;
    final utilConstraints = BoxConstraints(
      minWidth: compact ? 32 : 40,
      minHeight: compact ? 32 : 40,
    );

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Main Playback Row（当前/总时长已移至波形组件进度条下方，此处只留控制键）
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              // Main Control Buttons
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Previous Track
                  IconButton(
                    icon: const Icon(Broken.previous),
                    iconSize: mainIconSize,
                    color: onPrevious != null
                        ? theme.colorScheme.onSurface
                        : theme.colorScheme.onSurface.withValues(alpha: 0.25),
                    onPressed: onPrevious,
                  ),
                  SizedBox(width: rowGap),
                  // Big Play / Pause Circle (Indigo / Accent Tint matching Screenshot 2)
                  GestureDetector(
                    onTap: onPlayPause,
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 250),
                      width: playSize,
                      height: playSize,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: Color.alphaBlend(accentColor.withValues(alpha: 0.75), theme.colorScheme.surface),
                        boxShadow: [
                          BoxShadow(
                            color: accentColor.withValues(alpha: isPlaying ? 0.4 : 0.15),
                            blurRadius: isPlaying ? 28 : 12,
                            spreadRadius: isPlaying ? 6 : 2,
                            offset: const Offset(0, 8),
                          ),
                        ],
                      ),
                      child: Center(
                        child: AnimatedSwitcher(
                          duration: const Duration(milliseconds: 200),
                          transitionBuilder: (child, animation) => ScaleTransition(
                            scale: animation,
                            child: child,
                          ),
                          child: Icon(
                            isPlaying ? Broken.pause : Broken.play,
                            key: ValueKey(isPlaying),
                            color: Colors.white,
                            size: playIconSize,
                          ),
                        ),
                      ),
                    ),
                  ),
                  SizedBox(width: rowGap),
                  // Next Track
                  IconButton(
                    icon: const Icon(Broken.next),
                    iconSize: mainIconSize,
                    color: onNext != null
                        ? theme.colorScheme.onSurface
                        : theme.colorScheme.onSurface.withValues(alpha: 0.25),
                    onPressed: onNext,
                  ),
                ],
              ),
            ],
          ),
        ),
        SizedBox(height: sectionGap),
        // Bottom Utility Row (Quality badge on Left, Action Utilities on Right)
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                // Quality Badge
                Container(
                  padding: EdgeInsets.symmetric(
                    horizontal: compact ? 10 : 14,
                    vertical: compact ? 3 : 6,
                  ),
                  decoration: BoxDecoration(
                    color: accentColor.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: accentColor.withValues(alpha: 0.3), width: 1),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.high_quality_rounded, color: accentColor, size: 16),
                      const SizedBox(width: 6),
                      _QualityBadge(audioPath: audioPath, accentColor: accentColor),
                    ],
                  ),
                ),
                const SizedBox(width: 16),
                // Action Utility Icons
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Playback mode：点击向上弹出菜单选择模式（不再点击一次
                    // 切换一个）。PopupMenuButton 在屏幕底部时框架会自动把
                    // 菜单弹在按钮上方；四个标题复用既有 l10n 键，天然多语言。
                    PopupMenuButton<int>(
                      icon: Icon(
                        playbackMode == 0
                            ? Icons.playlist_play_rounded
                            : playbackMode == 1
                                ? Icons.repeat_rounded
                                : playbackMode == 2
                                    ? Icons.repeat_one_rounded
                                    : Icons.shuffle_rounded,
                      ),
                      iconSize: utilIconSize,
                      constraints: utilConstraints,
                      padding: EdgeInsets.zero,
                      tooltip: playbackMode == 0
                          ? L10n.of(context).ui_play_mode_sequential
                          : playbackMode == 1
                              ? L10n.of(context).ui_play_mode_list_loop
                              : playbackMode == 2
                                  ? L10n.of(context).ui_play_mode_single_loop
                                  : L10n.of(context).ui_play_mode_shuffle,
                      color: theme.brightness == Brightness.dark
                          ? const Color(0xFF2A2A3C)
                          : null,
                      initialValue: playbackMode,
                      onSelected: onPlaybackModeSelected,
                      itemBuilder: (ctx) => [
                        _playModeItem(ctx, 0, Icons.playlist_play_rounded,
                            L10n.of(context).ui_play_mode_sequential),
                        _playModeItem(ctx, 1, Icons.repeat_rounded,
                            L10n.of(context).ui_play_mode_list_loop),
                        _playModeItem(ctx, 2, Icons.repeat_one_rounded,
                            L10n.of(context).ui_play_mode_single_loop),
                        _playModeItem(ctx, 3, Icons.shuffle_rounded,
                            L10n.of(context).ui_play_mode_shuffle),
                      ],
                    ),
                    // Sound FX / Equalizer
                    IconButton(
                      icon: const Icon(Icons.tune_rounded),
                      iconSize: utilIconSize,
                      constraints: utilConstraints,
                      padding: EdgeInsets.zero,
                      tooltip: L10n.of(context).ui_sound_effects,
                      color: theme.colorScheme.onSurface.withValues(alpha: 0.8),
                      onPressed: onShowEqualizer,
                    ),
                    // Lyrics display mode toggle
                    IconButton(
                      icon: const Icon(Broken.document),
                      iconSize: utilIconSize,
                      constraints: utilConstraints,
                      padding: EdgeInsets.zero,
                      tooltip: lyricsDisplayMode == 0
                          ? L10n.of(context).ui_lyrics_mode_off
                          : lyricsDisplayMode == 1
                              ? L10n.of(context).ui_lyrics_mode_single_line
                              : lyricsDisplayMode == 2
                                  ? L10n.of(context).ui_lyrics_mode_multi_line
                                  : L10n.of(context).ui_lyrics_mode_full_panel,
                      // 仅在实际展示歌词（模式非关闭）时高亮；
                      // 关闭态统一中性色，避免"有歌词"造成的常亮误导。
                      color: lyricsDisplayMode != 0
                          ? accentColor
                          : theme.colorScheme.onSurface.withValues(alpha: 0.8),
                      onPressed: onShowLyrics,
                    ),
                    // Sleep Timer
                    IconButton(
                      icon: const Icon(Broken.timer),
                      iconSize: utilIconSize,
                      constraints: utilConstraints,
                      padding: EdgeInsets.zero,
                      tooltip: L10n.of(context).msg47cab5ae,
                      color: theme.colorScheme.onSurface.withValues(alpha: 0.8),
                      onPressed: onShowSleepTimer,
                    ),
                    // Queue
                    IconButton(
                      icon: const Icon(Icons.queue_music_rounded),
                      iconSize: utilIconSize,
                      constraints: utilConstraints,
                      padding: EdgeInsets.zero,
                      tooltip: L10n.of(context).ui_playback_queue,
                      color: theme.colorScheme.onSurface.withValues(alpha: 0.8),
                      onPressed: onShowQueue,
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  /// 播放模式菜单项：图标 + 本地化标题，当前模式带勾选标记。
  PopupMenuItem<int> _playModeItem(
    BuildContext context,
    int value,
    IconData icon,
    String label,
  ) {
    final theme = Theme.of(context);
    final selected = playbackMode == value;
    return PopupMenuItem<int>(
      value: value,
      child: Row(
        children: [
          Icon(
            icon,
            size: 18,
            color: selected
                ? theme.colorScheme.primary
                : theme.colorScheme.onSurface.withValues(alpha: 0.75),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              label,
              style: TextStyle(
                fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                color: selected ? theme.colorScheme.primary : null,
              ),
            ),
          ),
          if (selected)
            Icon(Icons.check_rounded,
                size: 18, color: theme.colorScheme.primary),
        ],
      ),
    );
  }
}

/// 音质徽标：根据文件路径推断真实格式（扩展名）与位深（FLAC/WAV 文件头）。
/// 无法判定位深时仅显示格式，绝不显示虚假位深（修复此前硬编码 "FLAC • 24-bit"）。
class _QualityBadge extends StatefulWidget {
  final String? audioPath;
  final Color accentColor;
  const _QualityBadge({this.audioPath, required this.accentColor});

  @override
  State<_QualityBadge> createState() => _QualityBadgeState();
}

class _QualityBadgeState extends State<_QualityBadge> {
  String _label = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant _QualityBadge oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.audioPath != widget.audioPath) {
      setState(() => _label = '');
      _load();
    }
  }

  void _load() {
    final path = widget.audioPath;
    final format =
        (path == null || path.isEmpty) ? '' : FileUtils.getAudioTypeLabel(path);
    if (mounted) setState(() => _label = format);
    // 仅本地真实文件路径才尝试读取文件头推断位深（排除 content://、http(s)://、cryptremote:// 等）
    if (path == null || path.isEmpty || path.contains('://')) return;
    _loadBits(format, path);
  }

  Future<void> _loadBits(String format, String path) async {
    try {
      final file = File(path);
      if (!await file.exists()) return;
      final chunk = await file.openRead(0, 65536).first;
      final bits = _detectBitsPerSample(chunk, format);
      if (bits != null && mounted) setState(() => _label = '$format • $bits-bit');
    } catch (_) {
      // 读取失败（权限/加密/损坏）时保守保留仅格式标签
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_label.isEmpty) {
      return const SizedBox(width: 8, height: 14);
    }
    return Text(
      _label,
      style: TextStyle(
        color: widget.accentColor,
        fontSize: 12,
        fontWeight: FontWeight.bold,
        letterSpacing: 0.3,
      ),
    );
  }
}

/// 从文件头前 64KB 推断位深（仅 FLAC / WAV 可靠）。
int? _detectBitsPerSample(List<int> b, String format) {
  if (b.length < 12) return null;
  // FLAC: 'fLaC' 魔数；STREAMINFO 中 bits-per-sample 位于文件偏移 20~21 字节
  if (format == 'FLAC' &&
      b[0] == 0x66 &&
      b[1] == 0x4C &&
      b[2] == 0x41 &&
      b[3] == 0x43) {
    if (b.length < 22) return null;
    final bits = (((b[20] >> 7) & 1) << 4) | (b[21] & 0x0F);
    if (bits >= 4 && bits <= 32) return bits;
    return null;
  }
  // WAV: 'RIFF'...'WAVE'，扫描 fmt 块取 bitsPerSample
  if (format == 'WAV' &&
      b[0] == 0x52 &&
      b[1] == 0x49 &&
      b[2] == 0x46 &&
      b[3] == 0x46 &&
      b[8] == 0x57 &&
      b[9] == 0x41 &&
      b[10] == 0x56 &&
      b[11] == 0x45) {
    var i = 12;
    while (i + 8 <= b.length) {
      final id = String.fromCharCodes(b.sublist(i, i + 4));
      final size = _le32(b, i + 4);
      if (id == 'fmt ') {
        if (i + 8 + 16 <= b.length) {
          final bits = _le16(b, i + 8 + 14);
          if (bits >= 4 && bits <= 32) return bits;
        }
        return null;
      }
      i += 8 + size + (size & 1);
    }
    return null;
  }
  return null;
}

int _le16(List<int> b, int off) => b[off] | (b[off + 1] << 8);
int _le32(List<int> b, int off) =>
    b[off] | (b[off + 1] << 8) | (b[off + 2] << 16) | (b[off + 3] << 24);


