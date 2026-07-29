import 'package:flutter/material.dart';
import '../../../core/icon_fonts/broken_icons.dart';
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
                      Text(
                        'FLAC • 24-bit',
                        style: TextStyle(
                          color: accentColor,
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 0.3,
                        ),
                      ),
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


