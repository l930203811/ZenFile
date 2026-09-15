import 'dart:io';
import 'package:flutter/material.dart';
import '../../../core/icon_fonts/broken_icons.dart';
import 'package:zenfile/core/utils.dart';
import 'package:zenfile/l10n/generated/app_localizations.dart';

class AudioControlsWidget extends StatelessWidget {
  final bool isPlaying;
  final Duration position;
  final Duration duration;
  final VoidCallback onPlayPause;
  final VoidCallback? onPrevious;
  final VoidCallback? onNext;
  final VoidCallback onShowLyrics;
  final VoidCallback onShowSleepTimer;
  final VoidCallback onShowEqualizer;
  final VoidCallback onShowQueue;
  // 0=sequential, 1=list loop, 2=single loop, 3=shuffle
  final int playbackMode;
  final VoidCallback onTogglePlaybackMode;
  final Color accentColor;
  final bool hasLyrics;
  // 0=off, 1=single line, 2=multi line, 3=full panel
  final int lyricsDisplayMode;
  // 当前播放文件的路径，用于从扩展名/文件头推断真实格式与位深
  final String? audioPath;

  const AudioControlsWidget({
    super.key,
    required this.isPlaying,
    required this.position,
    required this.duration,
    required this.onPlayPause,
    required this.onPrevious,
    required this.onNext,
    required this.onShowLyrics,
    required this.onShowSleepTimer,
    required this.onShowEqualizer,
    required this.onShowQueue,
    required this.playbackMode,
    required this.onTogglePlaybackMode,
    required this.accentColor,
    this.hasLyrics = false,
    this.lyricsDisplayMode = 0,
    this.audioPath,
  });

  String _formatDuration(Duration d) {
    final m = d.inMinutes;
    final s = d.inSeconds % 60;
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Main Playback Row with Inline Duration (Matching Screenshot 2)
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              // Elapsed Time
              Text(
                _formatDuration(position),
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: theme.colorScheme.onSurface.withOpacity(0.6),
                ),
              ),
              // Main Control Buttons
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Previous Track
                  IconButton(
                    icon: const Icon(Broken.previous),
                    iconSize: 32,
                    color: onPrevious != null
                        ? theme.colorScheme.onSurface
                        : theme.colorScheme.onSurface.withOpacity(0.25),
                    onPressed: onPrevious,
                  ),
                  const SizedBox(width: 16),
                  // Big Play / Pause Circle (Indigo / Accent Tint matching Screenshot 2)
                  GestureDetector(
                    onTap: onPlayPause,
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 250),
                      width: 76,
                      height: 76,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: Color.alphaBlend(accentColor.withOpacity(0.75), theme.colorScheme.surface),
                        boxShadow: [
                          BoxShadow(
                            color: accentColor.withOpacity(isPlaying ? 0.4 : 0.15),
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
                            size: 38,
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 16),
                  // Next Track
                  IconButton(
                    icon: const Icon(Broken.next),
                    iconSize: 32,
                    color: onNext != null
                        ? theme.colorScheme.onSurface
                        : theme.colorScheme.onSurface.withOpacity(0.25),
                    onPressed: onNext,
                  ),
                ],
              ),
              // Total Duration
              Text(
                _formatDuration(duration),
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: theme.colorScheme.onSurface.withOpacity(0.6),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 32),
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
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                  decoration: BoxDecoration(
                    color: accentColor.withOpacity(0.12),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: accentColor.withOpacity(0.3), width: 1),
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
                    // Playback mode toggle
                    IconButton(
                      icon: Icon(
                        playbackMode == 0
                            ? Icons.playlist_play_rounded
                            : playbackMode == 1
                                ? Icons.repeat_rounded
                                : playbackMode == 2
                                    ? Icons.repeat_one_rounded
                                    : Icons.shuffle_rounded,
                      ),
                      iconSize: 22,
                      constraints: const BoxConstraints(minWidth: 40, minHeight: 40),
                      padding: EdgeInsets.zero,
                      tooltip: playbackMode == 0
                          ? L10n.of(context).ui_play_mode_sequential
                          : playbackMode == 1
                              ? L10n.of(context).ui_play_mode_list_loop
                              : playbackMode == 2
                                  ? L10n.of(context).ui_play_mode_single_loop
                                  : L10n.of(context).ui_play_mode_shuffle,
                      color: accentColor,
                      onPressed: onTogglePlaybackMode,
                    ),
                    // Sound FX / Equalizer
                    IconButton(
                      icon: const Icon(Icons.tune_rounded),
                      iconSize: 22,
                      constraints: const BoxConstraints(minWidth: 40, minHeight: 40),
                      padding: EdgeInsets.zero,
                      tooltip: L10n.of(context).ui_sound_effects,
                      color: theme.colorScheme.onSurface.withOpacity(0.8),
                      onPressed: onShowEqualizer,
                    ),
                    // Lyrics display mode toggle
                    IconButton(
                      icon: const Icon(Broken.document),
                      iconSize: 22,
                      constraints: const BoxConstraints(minWidth: 40, minHeight: 40),
                      padding: EdgeInsets.zero,
                      tooltip: lyricsDisplayMode == 0
                          ? L10n.of(context).ui_lyrics_mode_off
                          : lyricsDisplayMode == 1
                              ? L10n.of(context).ui_lyrics_mode_single_line
                              : lyricsDisplayMode == 2
                                  ? L10n.of(context).ui_lyrics_mode_multi_line
                                  : L10n.of(context).ui_lyrics_mode_full_panel,
                      color: lyricsDisplayMode != 0
                          ? accentColor
                          : hasLyrics
                              ? accentColor.withOpacity(0.6)
                              : theme.colorScheme.onSurface.withOpacity(0.8),
                      onPressed: onShowLyrics,
                    ),
                    // Sleep Timer
                    IconButton(
                      icon: const Icon(Broken.timer),
                      iconSize: 22,
                      constraints: const BoxConstraints(minWidth: 40, minHeight: 40),
                      padding: EdgeInsets.zero,
                      tooltip: L10n.of(context).msg47cab5ae,
                      color: theme.colorScheme.onSurface.withOpacity(0.8),
                      onPressed: onShowSleepTimer,
                    ),
                    // Queue
                    IconButton(
                      icon: const Icon(Icons.queue_music_rounded),
                      iconSize: 22,
                      constraints: const BoxConstraints(minWidth: 40, minHeight: 40),
                      padding: EdgeInsets.zero,
                      tooltip: L10n.of(context).ui_playback_queue,
                      color: theme.colorScheme.onSurface.withOpacity(0.8),
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


