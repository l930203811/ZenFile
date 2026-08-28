import 'package:flutter/material.dart';
import 'package:zenfile/core/icon_fonts/broken_icons.dart';
import 'package:zenfile/l10n/generated/app_localizations.dart';

class VideoControlsOverlay extends StatelessWidget {
  final String title;
  final bool isPlaying;
  final Duration position;
  final Duration duration;
  final double sliderValue;
  final double playbackSpeed;
  final bool isFullScreen;
  final bool isLocked;
  final bool isMuted;
  final int repeatMode; // 0=none, 1=one, 2=all
  final int rotationTurns; // 0=0°, 1=90°, 2=180°, 3=270°
  final int aspectRatioMode; // 0=fit, 1=fill, 2=center, 3=16:9, 4=4:3
  final bool subtitleEnabled;
  final String? subtitlePath;
  final bool hasAudioTracks;
  final bool hasSubtitleTracks;
  final ValueChanged<double> onChanged;
  final ValueChanged<double> onChangeEnd;
  final ValueChanged<double> onChangeStart;
  final VoidCallback onPlayPause;
  final VoidCallback onRewind;
  final VoidCallback onFastForward;
  final VoidCallback? onPrevious;
  final VoidCallback? onNext;
  final VoidCallback onToggleFullScreen;
  final ValueChanged<double> onSelectSpeed;
  final VoidCallback onToggleLock;
  final VoidCallback onToggleMute;
  final VoidCallback onToggleRepeat;
  final VoidCallback onRotate;
  final VoidCallback onToggleAspectRatio;
  final VoidCallback onCustomAspectRatio;
  final VoidCallback onAddSubtitle;
  final VoidCallback onSubtitleSettings;
  final VoidCallback onToggleSubtitle;
  final VoidCallback onSelectAudioTrack;
  final VoidCallback onSelectSubtitleTrack;
  final VoidCallback onOpenPlaylist;
  final VoidCallback onInteract;
  final bool useHardwareDecode; // true=硬解, false=软解
  final VoidCallback onToggleHwdec;

  const VideoControlsOverlay({
    super.key,
    required this.title,
    required this.isPlaying,
    required this.position,
    required this.duration,
    required this.sliderValue,
    required this.playbackSpeed,
    required this.isFullScreen,
    required this.isLocked,
    required this.isMuted,
    required this.repeatMode,
    required this.rotationTurns,
    required this.aspectRatioMode,
    this.subtitleEnabled = false,
    this.subtitlePath,
    this.hasAudioTracks = false,
    this.hasSubtitleTracks = false,
    required this.onChanged,
    required this.onChangeEnd,
    required this.onChangeStart,
    required this.onPlayPause,
    required this.onRewind,
    required this.onFastForward,
    this.onPrevious,
    this.onNext,
    required this.onToggleFullScreen,
    required this.onSelectSpeed,
    required this.onToggleLock,
    required this.onToggleMute,
    required this.onToggleRepeat,
    required this.onRotate,
    required this.onToggleAspectRatio,
    required this.onCustomAspectRatio,
    required this.onAddSubtitle,
    required this.onSubtitleSettings,
    required this.onToggleSubtitle,
    required this.onSelectAudioTrack,
    required this.onSelectSubtitleTrack,
    required this.onOpenPlaylist,
    required this.onInteract,
    required this.useHardwareDecode,
    required this.onToggleHwdec,
  });

  String _formatDuration(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes % 60;
    final s = d.inSeconds % 60;
    if (h > 0) {
      return '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
    }
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accentColor = theme.colorScheme.primary;

    final maxMs = duration.inMilliseconds.toDouble();
    final safeMax = maxMs > 0 ? maxMs : 1.0;
    final safeVal = sliderValue.clamp(0.0, safeMax);
    final itemsColor = Colors.white.withOpacity(0.9);

    if (isLocked) {
      return Positioned(
        top: 32,
        left: 24,
        child: SafeArea(
          top: !isFullScreen,
          bottom: !isFullScreen,
          child: GestureDetector(
            onTap: onToggleLock,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
              decoration: BoxDecoration(
                color: Colors.black.withOpacity(0.75),
                borderRadius: BorderRadius.circular(24),
                border: Border.all(color: Colors.white.withOpacity(0.25), width: 1.5),
                boxShadow: [
                  BoxShadow(color: accentColor.withOpacity(0.4), blurRadius: 16),
                ],
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Broken.lock, color: accentColor, size: 22),
                  const SizedBox(width: 8),
                  Text(
                    L10n.of(context).msg_slide_to_unlock,
                    style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.bold),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }

    return Stack(
      children: [
        // Darkened Background Mask for better visibility of controls
        Positioned.fill(
          child: IgnorePointer(
            child: Container(color: Colors.black.withOpacity(0.35)),
          ),
        ),

        // TOP ROW HEADER
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          child: Container(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Colors.black87, Colors.transparent],
              ),
            ),
            child: SafeArea(
              top: !isFullScreen,
              bottom: !isFullScreen,
              child: Row(
                children: [
                  IconButton(
                    icon: Icon(Broken.arrow_down_2, color: itemsColor, size: 28),
                    onPressed: () => Navigator.pop(context),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          title,
                          style: TextStyle(color: itemsColor, fontSize: 16, fontWeight: FontWeight.bold),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 3),
                        Row(
                          children: [
                            GestureDetector(
                              onTap: onToggleHwdec,
                              child: Tooltip(
                                message: L10n.of(context).msg_toggle_decode,
                                child: Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                  decoration: BoxDecoration(
                                    color: accentColor.withOpacity(0.3),
                                    borderRadius: BorderRadius.circular(4),
                                    border: Border.all(color: accentColor, width: 0.8),
                                  ),
                                  child: Text(
                                    useHardwareDecode
                                        ? L10n.of(context).msg_hwdec
                                        : L10n.of(context).msg_swdec,
                                    style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.bold),
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Text(
                              'AVC / AAC • 1080p',
                              style: TextStyle(color: Colors.white.withOpacity(0.7), fontSize: 12),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  // Speed Selector Dropdown Menu
                  PopupMenuButton<double>(
                    tooltip: L10n.of(context).msgc16eed0e,
                    icon: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                      decoration: BoxDecoration(
                        color: Colors.black.withOpacity(0.4),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: Colors.white.withOpacity(0.2), width: 1),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Broken.play_cricle, color: itemsColor, size: 16),
                          const SizedBox(width: 6),
                          Text(
                            '${playbackSpeed}x',
                            style: TextStyle(color: itemsColor, fontSize: 12, fontWeight: FontWeight.bold),
                          ),
                        ],
                      ),
                    ),
                    color: const Color(0xFF1E1E2E),
                    onSelected: onSelectSpeed,
                    itemBuilder: (_) => [0.5, 0.75, 1.0, 1.25, 1.5, 2.0, 3.0]
                        .map((v) => PopupMenuItem(
                              value: v,
                              child: Text(
                                '${v}x',
                                style: TextStyle(
                                  color: playbackSpeed == v ? accentColor : Colors.white,
                                  fontWeight: playbackSpeed == v ? FontWeight.bold : FontWeight.normal,
                                ),
                              ),
                            ))
                        .toList(),
                  ),
                  const SizedBox(width: 8),
                  // Lock Toggle Button
                  IconButton(
                    icon: Icon(Broken.unlock, color: itemsColor, size: 24),
                    tooltip: L10n.of(context).msg8f106217,
                    onPressed: onToggleLock,
                  ),
                  const SizedBox(width: 8),
                  // Playlist Button
                  IconButton(
                    icon: Icon(Icons.playlist_play_rounded, color: itemsColor, size: 24),
                    tooltip: L10n.of(context).msg_playlist,
                    onPressed: () {
                      onInteract();
                      onOpenPlaylist();
                    },
                  ),
                  const SizedBox(width: 8),
                  // More Options Menu Button
                  PopupMenuButton<String>(
                    icon: Icon(Icons.menu_rounded, color: itemsColor, size: 24),
                    tooltip: L10n.of(context).msg3007c452,
                    color: const Color(0xFF1E1E2E),
                    onSelected: (value) {
                      onInteract();
                      if (value == 'subtitle_settings') {
                        onSubtitleSettings();
                      } else if (value == 'custom_aspect') {
                        onCustomAspectRatio();
                      }
                    },
                    itemBuilder: (_) => [
                      PopupMenuItem<String>(
                        value: 'custom_aspect',
                        child: Row(
                          children: [
                            Icon(Icons.aspect_ratio_rounded, size: 20, color: Colors.white),
                            const SizedBox(width: 12),
                            Text(
                              L10n.of(context).msg_custom_aspect_ratio,
                              style: const TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ],
                        ),
                      ),
                      PopupMenuItem<String>(
                        value: 'subtitle_settings',
                        child: Row(
                          children: [
                            Icon(Icons.subtitles_rounded, size: 20, color: Colors.white),
                            const SizedBox(width: 12),
                            Text(
                              L10n.of(context).msg_subtitle_menu,
                              style: const TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),

        // CENTER PLAYBACK CONTROLS
        Center(
          child: SafeArea(
            top: !isFullScreen,
            bottom: !isFullScreen,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                const SizedBox(),
                // Previous Button
                Opacity(
                  opacity: onPrevious != null ? 1.0 : 0.4,
                  child: Container(
                    decoration: BoxDecoration(color: Colors.black.withOpacity(0.35), shape: BoxShape.circle),
                    child: IconButton(
                      iconSize: 32,
                      padding: const EdgeInsets.all(14),
                      icon: Icon(Broken.previous, color: itemsColor),
                      onPressed: onPrevious != null ? () {
                        onInteract();
                        onPrevious?.call();
                      } : null,
                    ),
                  ),
                ),
                // Play / Pause Premium Circle
                Container(
                  decoration: BoxDecoration(
                    color: Colors.black.withOpacity(0.55),
                    shape: BoxShape.circle,
                    boxShadow: [
                      BoxShadow(color: accentColor.withOpacity(isPlaying ? 0.5 : 0.2), blurRadius: 28, spreadRadius: 4),
                    ],
                    border: Border.all(color: Colors.white.withOpacity(0.15), width: 1.5),
                  ),
                  child: IconButton(
                    iconSize: 52,
                    padding: const EdgeInsets.all(20),
                    icon: Icon(isPlaying ? Broken.pause : Broken.play, color: itemsColor),
                    onPressed: () {
                      onInteract();
                      onPlayPause();
                    },
                  ),
                ),
                // Next Button
                Opacity(
                  opacity: onNext != null ? 1.0 : 0.4,
                  child: Container(
                    decoration: BoxDecoration(color: Colors.black.withOpacity(0.35), shape: BoxShape.circle),
                    child: IconButton(
                      iconSize: 32,
                      padding: const EdgeInsets.all(14),
                      icon: Icon(Broken.next, color: itemsColor),
                      onPressed: onNext != null ? () {
                        onInteract();
                        onNext?.call();
                      } : null,
                    ),
                  ),
                ),
                const SizedBox(),
              ],
            ),
          ),
        ),

        // BOTTOM ROW CONTROLS
        Positioned(
          bottom: 0,
          left: 0,
          right: 0,
          child: Container(
            padding: const EdgeInsets.fromLTRB(20, 36, 20, 20),
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.bottomCenter,
                end: Alignment.topCenter,
                colors: [Colors.black87, Colors.transparent],
              ),
            ),
            child: SafeArea(
              top: !isFullScreen,
              bottom: !isFullScreen,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Time labels above slider (current time on left, total duration on right)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          _formatDuration(position),
                          style: TextStyle(color: itemsColor, fontSize: 12, fontWeight: FontWeight.bold),
                        ),
                        Text(
                          _formatDuration(duration),
                          style: TextStyle(color: itemsColor, fontSize: 12, fontWeight: FontWeight.bold),
                        ),
                      ],
                    ),
                  ),
                  // Full Width Seek Bar
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: SliderTheme(
                      data: SliderTheme.of(context).copyWith(
                        trackHeight: 4.5,
                        thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 8),
                        overlayShape: const RoundSliderOverlayShape(overlayRadius: 20),
                        activeTrackColor: accentColor,
                        inactiveTrackColor: Colors.white.withOpacity(0.25),
                        thumbColor: accentColor,
                        overlayColor: accentColor.withOpacity(0.3),
                      ),
                      child: Slider(
                        value: safeVal,
                        max: safeMax,
                        onChangeStart: (_) {
                          onInteract();
                          onChangeStart(safeVal);
                        },
                        onChanged: onChanged,
                        onChangeEnd: (_) {
                          onInteract();
                          onChangeEnd(safeVal);
                        },
                      ),
                    ),
                  ),
                  const SizedBox(height: 4),
                  // Action Icons Row
                  // 竖屏（非全屏）顺序（左→右）：旋转 → 循环 → 静音 → 比例 → 全屏 → 更多
                  //   更多（最右）菜单含：字幕开关、字幕轨、音轨（不含旋转）。
                  // 全屏（横屏进入）时：释放更多菜单的所有按钮，直接显示并堆在最右侧，
                  //   顺序（左→右）：旋转 → 循环 → 静音 → 比例 → 全屏 → 字幕开关 → 字幕轨 → 音轨。
                  //   全屏时不显示“更多”按钮（功能已全部外露）。
                  Wrap(
                    alignment: WrapAlignment.end,
                    spacing: 0,
                    runSpacing: 4,
                    children: [
                      // Rotate Video Clockwise（竖屏+全屏都直接显示在行内最左；仅竖屏时在行内，全屏时也在行内）
                      IconButton(
                        padding: const EdgeInsets.all(6),
                        icon: Icon(Icons.rotate_right_rounded, color: itemsColor, size: 22),
                        tooltip: L10n.of(context).msg_rotate_video,
                        onPressed: () {
                          onInteract();
                          onRotate();
                        },
                      ),
                      // Repeat Button
                      IconButton(
                        padding: const EdgeInsets.all(6),
                        icon: Icon(
                          repeatMode == 0
                              ? Icons.repeat_rounded
                              : repeatMode == 1
                                  ? Icons.repeat_one_rounded
                                  : Icons.repeat_rounded,
                          color: repeatMode != 0 ? accentColor : itemsColor.withValues(alpha: 0.7),
                          size: 22,
                        ),
                        tooltip: L10n.of(context).msg1f41f25d,
                        onPressed: () {
                          onInteract();
                          onToggleRepeat();
                        },
                      ),
                      // Mute Button
                      IconButton(
                        padding: const EdgeInsets.all(6),
                        icon: Icon(isMuted ? Broken.volume_slash : Broken.volume_high, color: itemsColor, size: 22),
                        tooltip: isMuted ? '取消静音' : '静音',
                        onPressed: () {
                          onInteract();
                          onToggleMute();
                        },
                      ),
                      // Aspect Ratio Toggle Button
                      IconButton(
                        padding: const EdgeInsets.all(6),
                        icon: Icon(Icons.aspect_ratio_rounded, color: aspectRatioMode != 0 ? accentColor : itemsColor, size: 22),
                        tooltip: L10n.of(context).msg_aspect_fit,
                        onPressed: () {
                          onInteract();
                          onToggleAspectRatio();
                        },
                      ),
                      // Full Screen
                      IconButton(
                        padding: const EdgeInsets.all(6),
                        icon: Icon(isFullScreen ? Icons.fullscreen_exit_rounded : Icons.fullscreen_rounded, color: itemsColor, size: 28),
                        tooltip: isFullScreen ? '退出全屏' : '全屏',
                        onPressed: () {
                          onInteract();
                          onToggleFullScreen();
                        },
                      ),
                      // 竖屏（非全屏）：更多按钮（最右），收纳 字幕开关/字幕轨/音轨（不含旋转）
                      if (!isFullScreen)
                        PopupMenuButton<String>(
                          padding: const EdgeInsets.all(6),
                          icon: Icon(Icons.more_vert_rounded, color: itemsColor, size: 22),
                          tooltip: L10n.of(context).ui_more,
                          color: const Color(0xFF1E1E2E),
                          onSelected: (value) {
                            onInteract();
                            if (value == 'subtitle_toggle') {
                              onToggleSubtitle();
                            } else if (value == 'audio_track') {
                              onSelectAudioTrack();
                            } else if (value == 'subtitle_track') {
                              onSelectSubtitleTrack();
                            }
                          },
                          itemBuilder: (_) => [
                            PopupMenuItem<String>(
                              value: 'subtitle_toggle',
                              child: Row(
                                children: [
                                  Icon(
                                    subtitleEnabled ? Icons.subtitles_rounded : Icons.subtitles_off_rounded,
                                    size: 20,
                                    color: Colors.white,
                                  ),
                                  const SizedBox(width: 12),
                                  Text(
                                    subtitlePath != null
                                        ? (subtitleEnabled ? L10n.of(context).msg_subtitle_off : L10n.of(context).msg_subtitle_on)
                                        : L10n.of(context).msg_no_subtitle,
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontWeight: FontWeight.w500,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            if (hasAudioTracks)
                              PopupMenuItem<String>(
                                value: 'audio_track',
                                child: Row(
                                  children: [
                                    Icon(Icons.audiotrack_rounded, size: 20, color: Colors.white),
                                    const SizedBox(width: 12),
                                    Text(
                                      L10n.of(context).msg_audio_track,
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontWeight: FontWeight.w500,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            if (hasSubtitleTracks)
                              PopupMenuItem<String>(
                                value: 'subtitle_track',
                                child: Row(
                                  children: [
                                    Icon(Icons.subtitles_rounded, size: 20, color: Colors.white),
                                    const SizedBox(width: 12),
                                    Text(
                                      L10n.of(context).msg_subtitle_track,
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontWeight: FontWeight.w500,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                          ],
                        ),
                      // 全屏（横屏进入）：释放更多菜单的所有按钮，直接显示在最右
                      if (isFullScreen) ...[
                        // Subtitle Toggle Button
                        Opacity(
                          opacity: subtitlePath != null ? 1.0 : 0.4,
                          child: IconButton(
                            padding: const EdgeInsets.all(6),
                            icon: Icon(
                              subtitleEnabled ? Icons.subtitles_rounded : Icons.subtitles_off_rounded,
                              color: subtitleEnabled ? accentColor : itemsColor,
                              size: 22,
                            ),
                            tooltip: subtitlePath != null
                                ? (subtitleEnabled ? L10n.of(context).msg_subtitle_off : L10n.of(context).msg_subtitle_on)
                                : L10n.of(context).msg_no_subtitle,
                            onPressed: subtitlePath != null
                                ? () {
                                    onInteract();
                                    onToggleSubtitle();
                                  }
                                : null,
                          ),
                        ),
                        if (hasAudioTracks)
                          IconButton(
                            padding: const EdgeInsets.all(6),
                            icon: Icon(Icons.audiotrack_rounded, color: itemsColor, size: 22),
                            tooltip: L10n.of(context).msg_audio_track,
                            onPressed: () {
                              onInteract();
                              onSelectAudioTrack();
                            },
                          ),
                        if (hasSubtitleTracks)
                          IconButton(
                            padding: const EdgeInsets.all(6),
                            icon: Icon(Icons.subtitles_rounded, color: itemsColor, size: 22),
                            tooltip: L10n.of(context).msg_subtitle_track,
                            onPressed: () {
                              onInteract();
                              onSelectSubtitleTrack();
                            },
                          ),
                      ],
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}
