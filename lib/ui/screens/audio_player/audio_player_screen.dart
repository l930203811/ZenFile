import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:on_audio_query/on_audio_query.dart';
import 'package:audio_service/audio_service.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';
import '../../../core/icon_fonts/broken_icons.dart';
import '../../../services/audio_background_handler.dart';
import '../../../services/preferences_service.dart';
import '../../../services/lyric_parser.dart';
import '../../../providers/file_manager_provider.dart';
import '../internal_file_picker_screen.dart';
import 'audio_artwork_widget.dart';
import 'audio_waveform_widget.dart';
import 'audio_controls_widget.dart';
import 'audio_queue_sheet.dart';
import 'audio_particles_widget.dart';
import 'lyrics_view_widget.dart';
import 'package:zenfile/l10n/generated/app_localizations.dart';

class AudioPlayerScreen extends StatefulWidget {
  final String audioPath;
  final String title;
  final String artist;
  final List<SongModel>? allSongs;
  final int initialIndex;
  final bool isRemote;
  final Player? existingPlayer;

  const AudioPlayerScreen({
    super.key,
    required this.audioPath,
    required this.title,
    this.artist = '',
    this.allSongs,
    this.initialIndex = 0,
    this.isRemote = false,
    this.existingPlayer,
  });

  @override
  State<AudioPlayerScreen> createState() => _AudioPlayerScreenState();
}

class _AudioPlayerScreenState extends State<AudioPlayerScreen>
    with TickerProviderStateMixin {
  late final Player player;

  bool isPlaying = false;
  Duration position = Duration.zero;
  Duration duration = Duration.zero;
  bool isSeeking = false;
  bool isBuffering = false;
  bool _isWaitingForCache = false;
  Timer? _cacheCheckTimer;

  // Sleep timer
  Timer? _sleepTimer;
  int? _sleepTimerMinutes;
  DateTime? _sleepTimerEndTime;

  late int _currentIndex;
  List<SongModel> get _allSongs => widget.allSongs ?? [];
  SongModel? get _currentSong =>
      _allSongs.isEmpty ? null : _allSongs[_currentIndex];

  String get _currentTitle => _currentSong?.title ?? widget.title;
  String get _currentArtist => _currentSong?.artist ?? widget.artist;
  int get _currentId => _currentSong?.id ?? 0;
  String get _currentPath => _currentSong?.data ?? widget.audioPath;

  /// 返回用于界面显示的艺术家名称，空值时使用 l10n 翻译。
  String _getDisplayArtist() {
    final artist = _currentArtist;
    if (artist.isEmpty) {
      return L10n.of(context).msg5e32276d;
    }
    return artist;
  }

  /// 返回用于界面显示的专辑名称，空值时使用 l10n 翻译。
  String _getDisplayAlbum() {
    final album = _currentSong?.album ?? '';
    if (album.isEmpty) {
      return L10n.of(context).ui_single;
    }
    return album;
  }

  // Animations
  late AnimationController _fadeController;
  late Animation<double> _fadeAnim;

  // Modes & Audio FX
  bool _isFavorite = false;
  int _repeatMode = 0; // 0=none, 1=one, 2=all
  double _playbackSpeed = 1.0;
  double _pitch = 1.0;

  // Shuffle
  bool _isShuffled = false;
  late List<int> _shuffleQueue; // shuffled indices of _allSongs
  int _shufflePos = 0; // current position in _shuffleQueue

  // Background playback
  bool _isBackgroundMode = false;

  // 歌词
  List<LyricLine>? _lyrics;
  String? _lyricSourcePath; // 实际歌词文件路径
  bool _isLoadingLyrics = false;
  bool _showInlineLyrics = false; // 是否在播放器界面显示完整内联歌词
  int _lyricsLoadGeneration = 0; // 防止歌词加载竞态

  // 播放进度记忆
  bool _hasSeekedToSavedPosition = false;
  Timer? _positionSaveTimer;

  @override
  void initState() {
    super.initState();
    _currentIndex = widget.initialIndex;
    _isBackgroundMode = PreferencesService.getAudioBackgroundPlay();

    _fadeController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 400),
    );
    _fadeAnim = CurvedAnimation(parent: _fadeController, curve: Curves.easeIn);
    _fadeController.forward();

    // MUST enable pitch in PlayerConfiguration for runtime pitch control
    if (widget.existingPlayer != null) {
      // 复用后台播放中已有的播放器，保持当前播放状态不断开
      player = widget.existingPlayer!;
      _shuffleQueue = List.generate(_allSongs.length, (i) => i);
      _initListeners();
      setState(() {
        isPlaying = player.state.playing;
        position = player.state.position;
        duration = player.state.duration;
      });
      _hasSeekedToSavedPosition = true; // 已在播放中，不再 seek 到记忆位置
      _loadLyrics();
      if (_isBackgroundMode) {
        getAudioHandler().setSkipCallback(_onBackgroundSkip);
        _updateBackgroundItem();
      }
    } else {
      player = Player(
        configuration: const PlayerConfiguration(
          bufferSize: 16 * 1024 * 1024,
          pitch: true,
        ),
      );
      _shuffleQueue = List.generate(_allSongs.length, (i) => i);
      _initListeners();
      _openTrack();
      if (_isBackgroundMode) {
        _startBackgroundMode();
      }
    }

    // 定期保存播放进度
    _positionSaveTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (mounted && position.inMilliseconds > 0) {
        PreferencesService.savePlaybackPosition(_currentPath, position.inMilliseconds);
      }
    });
  }

  void _initListeners() {
    player.stream.playing.listen((playing) {
      if (!mounted) return;
      setState(() => isPlaying = playing);
    });
    player.stream.position.listen((p) {
      if (!mounted || isSeeking) return;
      setState(() => position = p);
    });
    player.stream.duration.listen((d) {
      if (!mounted) return;
      setState(() => duration = d);
      // 首次获取到时长后，恢复上次播放进度
      if (!_hasSeekedToSavedPosition && d > Duration.zero) {
        _hasSeekedToSavedPosition = true;
        final savedMs = PreferencesService.getPlaybackPosition(_currentPath);
        if (savedMs != null && savedMs > 1000) {
          final savedPos = Duration(milliseconds: savedMs);
          // 确保保存的进度不超过总时长，且距离结尾至少3秒
          if (savedPos < d - const Duration(seconds: 3)) {
            player.seek(savedPos);
          }
        }
      }
      if (_isBackgroundMode) {
        _updateBackgroundItem();
      }
    });
    player.stream.completed.listen((completed) {
      if (!completed || !mounted) return;
      _onTrackComplete();
    });
    player.stream.buffering.listen((buffering) {
      if (!mounted) return;
      setState(() => isBuffering = buffering);
    });
  }

  void _onTrackComplete() {
    if (_repeatMode == 1) {
      player.seek(Duration.zero);
      player.play();
    } else if (_repeatMode == 2 || _allSongs.isNotEmpty) {
      _playNext();
    }
  }

  void _openTrack() {
    // 重置进度恢复标记
    _hasSeekedToSavedPosition = false;
    // 保存当前播放的音频信息（用于从分类页恢复播放）
    PreferencesService.saveLastPlayedAudio(_currentPath, _currentTitle, _currentArtist);

    // 加载歌词
    _loadLyrics();

    // For remote files that are being cached, wait until the download completes
    // (download goes to .partial file, then renames to the actual file)
    if (widget.isRemote && !_currentPath.startsWith('http')) {
      final file = File(_currentPath);
      final initialSize = file.existsSync() ? file.lengthSync() : 0;
      if (initialSize < 1024) { // less than 1KB = placeholder file
        setState(() => _isWaitingForCache = true);
        _cacheCheckTimer = Timer.periodic(const Duration(milliseconds: 500), (timer) {
          if (!mounted) {
            timer.cancel();
            return;
          }
          try {
            if (!file.existsSync()) return;
            final currentSize = file.lengthSync();
            // File size significantly increased = download complete (renamed from .partial)
            if (currentSize > 1024 && currentSize != initialSize) {
              timer.cancel();
              if (mounted) {
                setState(() => _isWaitingForCache = false);
                player.open(Media(_currentPath), play: true);
                player.setRate(_playbackSpeed);
                player.setPitch(_pitch);
                _resetFade();
                _loadLyrics();
              }
            }
          } catch (_) {}
        });
        return;
      }
    }
    player.open(Media(_currentPath), play: true);
    player.setRate(_playbackSpeed);
    player.setPitch(_pitch);
    _resetFade();
  }

  void _resetFade() {
    _fadeController.forward(from: 0);
  }

  void _selectTrack(int index) {
    if (index == _currentIndex) return;
    _currentIndex = index;
    setState(() {
      position = Duration.zero;
      duration = Duration.zero;
    });
    _openTrack();
  }

  void _playNext() {
    if (_allSongs.isEmpty) return;
    if (_isShuffled) {
      _shufflePos = (_shufflePos + 1) % _shuffleQueue.length;
      _currentIndex = _shuffleQueue[_shufflePos];
    } else {
      _currentIndex = (_currentIndex + 1) % _allSongs.length;
    }
    setState(() {
      position = Duration.zero;
      duration = Duration.zero;
    });
    _openTrack();
    if (_isBackgroundMode) _updateBackgroundItem();
  }

  void _playPrevious() {
    if (_allSongs.isEmpty) return;
    if (_isShuffled) {
      _shufflePos = (_shufflePos - 1 + _shuffleQueue.length) % _shuffleQueue.length;
      _currentIndex = _shuffleQueue[_shufflePos];
    } else {
      _currentIndex = (_currentIndex - 1 + _allSongs.length) % _allSongs.length;
    }
    setState(() {
      position = Duration.zero;
      duration = Duration.zero;
    });
    _openTrack();
    if (_isBackgroundMode) _updateBackgroundItem();
  }

  @override
  void dispose() {
    // 保存当前播放进度
    if (position.inMilliseconds > 0) {
      PreferencesService.savePlaybackPosition(_currentPath, position.inMilliseconds);
    }
    _positionSaveTimer?.cancel();
    _cacheCheckTimer?.cancel();
    _sleepTimer?.cancel();
    _fadeController.dispose();
    if (_isBackgroundMode) {
      // Let audio keep playing in background — don't dispose player
      getAudioHandler().setSkipCallback(null);
    } else {
      player.dispose();
      getAudioHandler().detach();
    }
    super.dispose();
  }

  // ─── Shuffle helpers ────────────────────────────────────────────────────

  void _buildShuffleQueue() {
    _shuffleQueue = List.generate(_allSongs.length, (i) => i);
    _shuffleQueue.shuffle();
    // Move current song to front so it plays now, rest is shuffled
    _shuffleQueue.remove(_currentIndex);
    _shuffleQueue.insert(0, _currentIndex);
    _shufflePos = 0;
  }

  void _toggleShuffle() {
    setState(() {
      _isShuffled = !_isShuffled;
      if (_isShuffled) {
        _buildShuffleQueue();
      }
    });
  }

  void _showQueueSheet(Color accentColor) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => DraggableScrollableSheet(
        initialChildSize: 0.65,
        maxChildSize: 0.9,
        minChildSize: 0.4,
        builder: (_, controller) => AudioQueueSheet(
          songs: _allSongs,
          currentIndex: _currentIndex,
          onSelectSong: _selectTrack,
          accentColor: accentColor,
        ),
      ),
    );
  }

  /// 自动加载当前歌曲的歌词
  void _loadLyrics() {
    final audioPath = _currentPath;
    final generation = ++_lyricsLoadGeneration;

    setState(() {
      _lyrics = null;
      _lyricSourcePath = null;
      _isLoadingLyrics = true;
    });

    // 异步加载歌词
    Future(() {
      final loaded = LyricParser.loadLyricForAudio(audioPath);

      // 只应用最新一次加载的结果，避免切歌竞态覆盖
      if (mounted && generation == _lyricsLoadGeneration) {
        setState(() {
          if (loaded != null) {
            _lyrics = loaded.lyrics;
            _lyricSourcePath = loaded.sourcePath;
          } else {
            _lyrics = null;
            _lyricSourcePath = null;
          }
          _isLoadingLyrics = false;
        });
      }
    });
  }

  /// 手动选择歌词文件
  Future<void> _selectLyricFile() async {
    try {
      final fileManager = context.read<FileManagerProvider>();
      final rootPath = fileManager.rootPath;
      final pickedPaths = await InternalFilePickerScreen.show(
        context,
        rootPath: rootPath,
      );
      if (pickedPaths == null || pickedPaths.isEmpty) return;

      final lrcPath = pickedPaths.first;
      final lyrics = LyricParser.loadFromFile(lrcPath);
      if (lyrics != null && mounted) {
        // 保存映射关系，以便切歌再切回来时自动加载
        await PreferencesService.saveLyricMapping(_currentPath, lrcPath);
        setState(() {
          _lyrics = lyrics;
          _lyricSourcePath = lrcPath;
          _showInlineLyrics = true;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(L10n.of(context).ui_lyrics_loaded, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
            backgroundColor: Colors.deepPurpleAccent,
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          ),
        );
      } else if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(L10n.of(context).ui_lyrics_load_failed, style: const TextStyle(color: Colors.white)),
            backgroundColor: Colors.redAccent,
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          ),
        );
      }
    } catch (e) {
      debugPrint('[ZenFile] 选择歌词文件失败: $e');
    }
  }

  /// 切换完整内联歌词显示（用歌词视图替换封面）
  void _toggleInlineLyrics() {
    setState(() {
      _showInlineLyrics = !_showInlineLyrics;
    });
  }

  /// 获取当前应显示的单行歌词文本
  String? _getCurrentLyricLineText() {
    if (_lyrics == null || _lyrics!.isEmpty) return null;
    final index = LyricParser.findCurrentLineIndex(_lyrics!, position);
    if (index < 0 || index >= _lyrics!.length) return null;
    final text = _lyrics![index].text;
    return text.isEmpty ? '♪' : text;
  }

  /// 构建单行歌词显示
  Widget _buildSingleLineLyrics(Color accent, ThemeData theme, bool isDark) {
    final lineText = _getCurrentLyricLineText();
    return GestureDetector(
      onTap: _showLyricsPanel,
      child: SizedBox(
        width: double.infinity,
        height: 44,
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 300),
          transitionBuilder: (child, animation) => FadeTransition(
            opacity: animation,
            child: SizeTransition(
              sizeFactor: animation,
              axisAlignment: 0,
              child: child,
            ),
          ),
          child: lineText != null
              ? SizedBox(
                  key: ValueKey<String>(lineText),
                  width: double.infinity,
                  child: Text(
                    lineText,
                    textAlign: TextAlign.center,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: accent,
                      height: 1.4,
                    ),
                  ),
                )
              : _isLoadingLyrics
                  ? SizedBox(
                      key: const ValueKey('loading'),
                      width: double.infinity,
                      child: Center(
                        child: SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2, color: accent),
                        ),
                      ),
                    )
                  : SizedBox(
                      key: const ValueKey('empty'),
                      width: double.infinity,
                      child: Text(
                        L10n.of(context).ui_no_lyrics_found,
                        textAlign: TextAlign.center,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                          color: (isDark ? Colors.white : theme.colorScheme.onSurface).withOpacity(0.35),
                        ),
                      ),
                    ),
        ),
      ),
    );
  }

  /// 构建 artwork 或完整内联歌词视图
  Widget _buildArtworkOrLyrics(Color accent, ThemeData theme, bool isDark) {
    if (!_showInlineLyrics) {
      // 显示封面
      return Stack(
        alignment: Alignment.center,
        children: [
          AudioArtworkWidget(
            audioId: _currentId,
            audioPath: _currentPath,
            accentColor: accent,
            isPlaying: isPlaying,
            onDoubleTap: _showLyricsPanel,
            onLongPress: _showEqualizerDialog,
          ),
          if ((isBuffering || _isWaitingForCache) && widget.isRemote)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              decoration: BoxDecoration(
                color: Colors.black54,
                borderRadius: BorderRadius.circular(20),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)),
                  const SizedBox(width: 8),
                  Text(L10n.of(context).ui_caching, style: const TextStyle(color: Colors.white, fontSize: 13)),
                ],
              ),
            ),
        ],
      );
    }

    // 显示内联歌词
    return GestureDetector(
      onDoubleTap: _showLyricsPanel,
      onLongPress: _showEqualizerDialog,
      child: Container(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.35,
        ),
        decoration: BoxDecoration(
          color: (isDark ? Colors.white : Colors.black).withOpacity(0.03),
          borderRadius: BorderRadius.circular(20),
        ),
        child: _isLoadingLyrics
            ? const Center(child: CircularProgressIndicator())
            : (_lyrics != null && _lyrics!.isNotEmpty
                ? LyricsViewWidget(
                    lyrics: _lyrics!,
                    position: position,
                    accentColor: accent,
                    onSeek: (d) => player.seek(d),
                  )
                : _buildInlineNoLyrics(theme, isDark, accent)),
      ),
    );
  }

  /// 内联模式下的"无歌词"提示
  Widget _buildInlineNoLyrics(ThemeData theme, bool isDark, Color accent) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Broken.document,
              size: 48,
              color: (isDark ? Colors.white : theme.colorScheme.onSurface).withOpacity(0.2),
            ),
            const SizedBox(height: 12),
            Text(
              L10n.of(context).ui_no_lyrics_found,
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.bold,
                color: (isDark ? Colors.white : theme.colorScheme.onSurface).withOpacity(0.5),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              L10n.of(context).ui_lyrics_auto_load_hint,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 12,
                height: 1.5,
                color: (isDark ? Colors.white : theme.colorScheme.onSurface).withOpacity(0.35),
              ),
            ),
            const SizedBox(height: 16),
            TextButton.icon(
              onPressed: _selectLyricFile,
              icon: const Icon(Icons.folder_open_rounded, size: 18),
              label: Text(L10n.of(context).ui_select_lyrics_file, style: const TextStyle(fontWeight: FontWeight.w600)),
              style: TextButton.styleFrom(
                foregroundColor: accent,
                backgroundColor: accent.withOpacity(0.1),
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 显示歌词面板
  void _showLyricsPanel() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => _LyricsPanel(
        player: player,
        lyrics: _lyrics,
        lyricSourcePath: _lyricSourcePath,
        title: _currentTitle,
        artist: _getDisplayArtist(),
        accentColor: Theme.of(context).colorScheme.primary,
        isLoading: _isLoadingLyrics,
        onSelectLyricFile: () {
          Navigator.pop(context);
          _selectLyricFile();
        },
        onSeek: (d) => player.seek(d),
      ),
    );
  }

  /// 设置睡眠定时器，指定分钟后暂停播放并退出播放器。
  void _setSleepTimer(int minutes) {
    _sleepTimer?.cancel();
    _sleepTimer = Timer(Duration(minutes: minutes), () {
      try {
        player.pause();
      } catch (_) {}
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(L10n.of(context).ui_sleep_timer_end, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
            backgroundColor: Colors.deepPurpleAccent,
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          ),
        );
        // 关闭播放器界面
        Navigator.of(context).pop();
        setState(() {
          _sleepTimerMinutes = null;
          _sleepTimerEndTime = null;
        });
      }
      _sleepTimer = null;
    });
    setState(() {
      _sleepTimerMinutes = minutes;
      _sleepTimerEndTime = DateTime.now().add(Duration(minutes: minutes));
    });
  }

  /// 取消已设置的睡眠定时器。
  void _cancelSleepTimer() {
    _sleepTimer?.cancel();
    _sleepTimer = null;
    if (mounted) {
      setState(() {
        _sleepTimerMinutes = null;
        _sleepTimerEndTime = null;
      });
    } else {
      _sleepTimerMinutes = null;
      _sleepTimerEndTime = null;
    }
  }

  /// 显示自定义分钟数输入对话框。
  Future<void> _showCustomSleepTimerInput() async {
    final controller = TextEditingController();
    final minutes = await showDialog<int>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF1E1E2E),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        title: Row(
          children: [
            Icon(Broken.timer, color: Colors.deepPurpleAccent),
            const SizedBox(width: 10),
            Text(L10n.of(context).msg47cab5ae, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 18)),
          ],
        ),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: TextInputType.number,
          style: const TextStyle(color: Colors.white),
          decoration: InputDecoration(
            hintText: L10n.of(context).ui_enter_minutes,
            hintStyle: TextStyle(color: Colors.white.withOpacity(0.4)),
            filled: true,
            fillColor: Colors.white.withOpacity(0.05),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(16),
              borderSide: BorderSide.none,
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(L10n.of(context).ui_cancel, style: const TextStyle(color: Colors.white70)),
          ),
          TextButton(
            onPressed: () {
              final value = int.tryParse(controller.text.trim());
              if (value != null && value > 0) {
                Navigator.pop(context, value);
              }
            },
            child: Text(L10n.of(context).ui_confirm, style: const TextStyle(color: Colors.deepPurpleAccent, fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
    controller.dispose();
    if (minutes != null && mounted) {
      _setSleepTimer(minutes);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(L10n.of(context).ui_sleep_timer_set(minutes), style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
          backgroundColor: Colors.deepPurpleAccent,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ),
      );
    }
  }

  void _showSleepTimerDialog() {
    final l10n = L10n.of(context);
    final isTimerActive = _sleepTimer != null && _sleepTimer!.isActive;
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF1E1E2E),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        title: Row(
          children: [
            Icon(Broken.timer, color: Colors.deepPurpleAccent),
            const SizedBox(width: 10),
            Text(l10n.msg47cab5ae, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 18)),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ...[15, 30, 45, 60].map((mins) => ListTile(
              title: Text(
                isTimerActive && _sleepTimerMinutes == mins
                    ? '${l10n.ui_minutes_format(mins)} ✓'
                    : l10n.ui_minutes_format(mins),
                style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w500),
              ),
              trailing: const Icon(Icons.chevron_right_rounded, color: Colors.white54),
              onTap: () {
                Navigator.pop(context);
                _setSleepTimer(mins);
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(l10n.ui_sleep_timer_set(mins), style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
                    backgroundColor: Colors.deepPurpleAccent,
                    behavior: SnackBarBehavior.floating,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                );
              },
            )),
            const Divider(color: Colors.white24, height: 1),
            ListTile(
              leading: const Icon(Icons.edit_outlined, color: Colors.white70),
              title: Text(l10n.msgf1d4ff50, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w500)),
              trailing: const Icon(Icons.chevron_right_rounded, color: Colors.white54),
              onTap: () {
                Navigator.pop(context);
                _showCustomSleepTimerInput();
              },
            ),
            if (isTimerActive)
              ListTile(
                leading: const Icon(Icons.cancel_outlined, color: Colors.redAccent),
                title: Text(l10n.ui_cancel, style: const TextStyle(color: Colors.redAccent, fontWeight: FontWeight.w500)),
                onTap: () {
                  Navigator.pop(context);
                  _cancelSleepTimer();
                },
              ),
          ],
        ),
      ),
    );
  }

  void _showEqualizerDialog() {
    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setModalState) {
          return AlertDialog(
            backgroundColor: const Color(0xFF1E1E2E),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
            title: Row(
              children: [
                const Icon(Icons.tune_rounded, color: Colors.deepPurpleAccent),
                const SizedBox(width: 10),
                Text(L10n.of(context).ui_sound_effects_speed, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 18)),
              ],
            ),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(L10n.of(context).msgc16eed0e, style: TextStyle(color: Colors.white70, fontSize: 15)),
                    Text('${_playbackSpeed.toStringAsFixed(2)}x', style: const TextStyle(color: Colors.deepPurpleAccent, fontWeight: FontWeight.bold, fontSize: 15)),
                  ],
                ),
                Slider(
                  value: _playbackSpeed,
                  min: 0.5,
                  max: 2.0,
                  divisions: 15,
                  activeColor: Colors.deepPurpleAccent,
                  onChanged: (v) {
                    setModalState(() => _playbackSpeed = v);
                    setState(() {});
                    player.setRate(v);
                  },
                ),
                const SizedBox(height: 16),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(L10n.of(context).ui_pitch_adjustment, style: TextStyle(color: Colors.white70, fontSize: 15)),
                    Text('${_pitch.toStringAsFixed(2)}x', style: const TextStyle(color: Colors.deepPurpleAccent, fontWeight: FontWeight.bold, fontSize: 15)),
                  ],
                ),
                Slider(
                  value: _pitch,
                  min: 0.5,
                  max: 1.5,
                  divisions: 10,
                  activeColor: Colors.deepPurpleAccent,
                  onChanged: (v) {
                    setModalState(() => _pitch = v);
                    setState(() {});
                    player.setPitch(v);
                  },
                ),
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  icon: const Icon(Icons.restart_alt_rounded, color: Colors.white70, size: 18),
                  label: Text(L10n.of(context).ui_restore_default, style: const TextStyle(color: Colors.white70)),
                  style: OutlinedButton.styleFrom(
                    side: BorderSide(color: Colors.white.withOpacity(0.2)),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                  ),
                  onPressed: () {
                    setModalState(() {
                      _playbackSpeed = 1.0;
                      _pitch = 1.0;
                    });
                    setState(() {});
                    player.setRate(1.0);
                    player.setPitch(1.0);
                  },
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: Text(L10n.of(context).ui_done, style: const TextStyle(color: Colors.deepPurpleAccent, fontWeight: FontWeight.bold, fontSize: 16)),
              ),
            ],
          );
        },
      ),
    );
  }

  // ─── Background mode ─────────────────────────────────────────────────────

  /// Build MediaItem for the current song for the notification.
  MediaItem _buildMediaItem(int index, {Uri? artUri}) {
    final song = _allSongs.isNotEmpty ? _allSongs[index] : null;
    Duration? songDuration;
    final durationMs = song?.duration;
    if (durationMs != null) {
      songDuration = Duration(milliseconds: durationMs);
    } else if (index == _currentIndex && duration != Duration.zero) {
      songDuration = duration;
    }
    final rawArtist = song?.artist ?? widget.artist;
    final rawAlbum = song?.album ?? '';
    return MediaItem(
      id: song?.data ?? widget.audioPath,
      title: song?.title ?? widget.title,
      artist: rawArtist.isEmpty ? L10n.of(context).msg5e32276d : rawArtist,
      album: rawAlbum.isEmpty ? L10n.of(context).ui_single : rawAlbum,
      artUri: artUri,
      duration: songDuration,
    );
  }

  void _updateBackgroundItem() async {
    final baseItem = _buildMediaItem(_currentIndex);
    getAudioHandler().updateCurrentItem(baseItem);

    // Asynchronously fetch high-fidelity artwork and update notification once ready
    final song = _allSongs.isNotEmpty ? _allSongs[_currentIndex] : null;
    if (song != null && song.id > 0) {
      try {
        final artUri = await getArtworkUri(song.id);
        if (artUri != null && mounted) {
          final updatedItem = _buildMediaItem(_currentIndex, artUri: artUri);
          getAudioHandler().updateCurrentItem(updatedItem);
        }
      } catch (e) {
        debugPrint('[ZenFile] Failed to load background artwork: $e');
      }
    }
  }

  void _startBackgroundMode() async {
    final queue = _allSongs.isNotEmpty
        ? List.generate(_allSongs.length, (i) => _buildMediaItem(i))
        : [_buildMediaItem(0)];

    final handler = getAudioHandler();
    handler.attach(
      player: player,
      queue: queue,
      currentIndex: _currentIndex,
    );
    // Skip callback so notification controls update the screen's index
    handler.setSkipCallback(_onBackgroundSkip);

    _updateBackgroundItem();
  }

  void _onBackgroundSkip(int idx) {
    if (!mounted) return;
    setState(() {
      _currentIndex = idx;
      position = Duration.zero;
      duration = Duration.zero;
    });
    _openTrack();
    _updateBackgroundItem();
  }

  Future<void> _toggleBackgroundMode() async {
    try {
      player.pause();
    } catch (_) {}

    if (_isBackgroundMode) {
      // Turn off — stop background handler to completely clear the notification,
      // but do NOT dispose the player because we want it to keep playing in the foreground!
      getAudioHandler().stopNotification();
      setState(() => _isBackgroundMode = false);
      await PreferencesService.saveAudioBackgroundPlay(false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(L10n.of(context).msg50c1b248),
            backgroundColor: Colors.blueGrey,
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          ),
        );
      }
      return;
    }

    // Turn on — request notification permission dynamically on Android 13+
    try {
      await Permission.notification.request();
    } catch (e) {
      debugPrint('[ZenFile] Error requesting notification permission: $e');
    }

    // Stop notification first to clear any blocked native service state!
    getAudioHandler().stopNotification();

    // A small delay to ensure the OS registers the permission before we display the notification
    await Future.delayed(const Duration(milliseconds: 500));

    if (!mounted) return;

    _startBackgroundMode();
    setState(() => _isBackgroundMode = true);
    await PreferencesService.saveAudioBackgroundPlay(true);

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(L10n.of(context).msg6d16d396),
          backgroundColor: Colors.deepPurpleAccent,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ),
      );
    }
  }

  void _showMoreMenu() {
    final mediaQuery = MediaQuery.of(context);
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF1E1E2E),
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) => Padding(
          padding: EdgeInsets.only(
            top: 20,
            bottom: 20 + mediaQuery.padding.bottom,
          ),
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: mediaQuery.size.height * 0.75,
            ),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // ── Shuffle toggle ────────────────────────────────────────────────
                  ListTile(
                    leading: Icon(
                      Icons.shuffle_rounded,
                      color: _isShuffled ? Colors.deepPurpleAccent : Colors.white,
                    ),
                    title: Text(
                      _isShuffled ? L10n.of(context).ui_shuffle_on : L10n.of(context).msg3038d9b8,
                      style: TextStyle(
                        color: _isShuffled ? Colors.deepPurpleAccent : Colors.white,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    trailing: Switch(
                      value: _isShuffled,
                      activeColor: Colors.deepPurpleAccent,
                      onChanged: (_) {
                        _toggleShuffle();
                        setSheet(() {});
                      },
                    ),
                    onTap: () {
                      _toggleShuffle();
                      setSheet(() {});
                    },
                  ),
                  // ── Play in Background ────────────────────────────────────────────
                  ListTile(
                    leading: Icon(
                      Icons.headphones_rounded,
                      color: _isBackgroundMode ? Colors.greenAccent : Colors.white,
                    ),
                    title: Text(
                      _isBackgroundMode ? L10n.of(context).msg6d16d396 : L10n.of(context).msg29eed1da,
                      style: TextStyle(
                        color: _isBackgroundMode ? Colors.greenAccent : Colors.white,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    subtitle: Text(
                      _isBackgroundMode
                          ? L10n.of(context).msg4aa059f7
                          : L10n.of(context).msg8f7f4490,
                      style: const TextStyle(color: Colors.white54, fontSize: 12),
                    ),
                    onTap: () {
                      Navigator.pop(ctx);
                      _toggleBackgroundMode();
                    },
                  ),
                  const Divider(color: Colors.white12, height: 1),
                  ListTile(
                    leading: Icon(Broken.document, color: _showInlineLyrics ? Colors.deepPurpleAccent : Colors.white),
                    title: Text(
                      _showInlineLyrics ? L10n.of(context).ui_hide_lyrics : L10n.of(context).ui_show_lyrics,
                      style: TextStyle(color: _showInlineLyrics ? Colors.deepPurpleAccent : Colors.white, fontWeight: FontWeight.w600),
                    ),
                    onTap: () {
                      Navigator.pop(ctx);
                      _toggleInlineLyrics();
                    },
                  ),
                  ListTile(
                    leading: const Icon(Icons.folder_open_rounded, color: Colors.white),
                    title: Text(L10n.of(context).ui_select_lyrics_file, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
                    onTap: () {
                      Navigator.pop(ctx);
                      _selectLyricFile();
                    },
                  ),
                  ListTile(
                    leading: const Icon(Icons.tune_rounded, color: Colors.white),
                    title: Text(L10n.of(context).msgb7c87215, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
                    onTap: () {
                      Navigator.pop(ctx);
                      _showEqualizerDialog();
                    },
                  ),
                  ListTile(
                    leading: Icon(Broken.timer, color: _sleepTimer != null && _sleepTimer!.isActive ? Colors.deepPurpleAccent : Colors.white),
                    title: Text(L10n.of(context).msg47cab5ae, style: TextStyle(color: _sleepTimer != null && _sleepTimer!.isActive ? Colors.deepPurpleAccent : Colors.white, fontWeight: FontWeight.w600)),
                    subtitle: (_sleepTimer != null && _sleepTimer!.isActive && _sleepTimerEndTime != null)
                        ? Text(
                            L10n.of(context).ui_minutes_format(_sleepTimerEndTime!.difference(DateTime.now()).inMinutes.clamp(0, 9999)),
                            style: const TextStyle(color: Colors.white54, fontSize: 12),
                          )
                        : null,
                    onTap: () {
                      Navigator.pop(ctx);
                      _showSleepTimerDialog();
                    },
                  ),
                  ListTile(
                    leading: const Icon(Icons.info_outline_rounded, color: Colors.white),
                    title: Text(L10n.of(context).msgfc449780, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
                    subtitle: Text(_currentPath, style: const TextStyle(color: Colors.white54, fontSize: 12), maxLines: 1, overflow: TextOverflow.ellipsis),
                    onTap: () => Navigator.pop(ctx),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final accent = theme.colorScheme.primary;

    SystemChrome.setSystemUIOverlayStyle(SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: isDark ? Brightness.light : Brightness.dark,
    ));

    return Scaffold(
      extendBodyBehindAppBar: true,
      backgroundColor: theme.scaffoldBackgroundColor,
      body: Stack(
        fit: StackFit.expand,
        children: [
          // Background Soft Glow
          Container(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: isDark
                    ? [
                        accent.withOpacity(0.2),
                        theme.scaffoldBackgroundColor,
                        theme.scaffoldBackgroundColor,
                      ]
                    : [
                        accent.withOpacity(0.12),
                        theme.scaffoldBackgroundColor,
                        theme.scaffoldBackgroundColor,
                      ],
              ),
            ),
          ),
          // Floating Particles
          AudioParticlesWidget(isPlaying: isPlaying, accentColor: accent),
          // Main Layout Matching Screenshot 2
          SafeArea(
            child: Column(
              children: [
                // Premium Top Bar
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  child: Row(
                    children: [
                      IconButton(
                        icon: Icon(Broken.arrow_down_2, size: 28),
                        onPressed: () => Navigator.pop(context),
                      ),
                      Expanded(
                        child: Column(
                          children: [
                            Text(
                              _allSongs.isNotEmpty
                                  ? '${_currentIndex + 1} / ${_allSongs.length}'
                                  : '1 / 1',
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                fontWeight: FontWeight.bold,
                                fontSize: 12,
                                color: accent,
                                letterSpacing: 1.0,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              _getDisplayAlbum(),
                              textAlign: TextAlign.center,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontWeight: FontWeight.w700,
                                fontSize: 15,
                                color: theme.colorScheme.onSurface.withOpacity(0.9),
                              ),
                            ),
                          ],
                        ),
                      ),
                      Container(
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: theme.colorScheme.onSurface.withOpacity(0.08),
                        ),
                        child: IconButton(
                          icon: const Icon(Icons.more_horiz_rounded, size: 22),
                          onPressed: _showMoreMenu,
                        ),
                      ),
                    ],
                  ),
                ),
                // Main Animated Body
                Expanded(
                  child: FadeTransition(
                    opacity: _fadeAnim,
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                      children: [
                        // Artwork or Inline Lyrics (toggleable)
                        _buildArtworkOrLyrics(accent, theme, isDark),
                        // Single-line current lyric (always visible by default)
                        _buildSingleLineLyrics(accent, theme, isDark),
                        // Title row with Favorite Heart icon on right matching Screenshot 2
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 28),
                          child: Row(
                            children: [
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      _currentTitle,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        fontWeight: FontWeight.w800,
                                        fontSize: 24,
                                        letterSpacing: 0.2,
                                      ),
                                    ),
                                    const SizedBox(height: 6),
                                    Text(
                                      _getDisplayArtist(),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        fontSize: 15,
                                        color: theme.colorScheme.onSurface.withOpacity(0.6),
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              IconButton(
                                icon: Icon(
                                  _isFavorite ? Icons.favorite_rounded : Icons.favorite_border_rounded,
                                  color: _isFavorite ? Colors.redAccent : theme.colorScheme.onSurface.withOpacity(0.6),
                                  size: 28,
                                ),
                                onPressed: () => setState(() => _isFavorite = !_isFavorite),
                              ),
                            ],
                          ),
                        ),
                        // Interactive Glowing Waveform Seek Bar
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 24),
                          child: AudioWaveformWidget(
                            position: position,
                            duration: duration,
                            isPlaying: isPlaying,
                            accentColor: accent,
                            onSeekStart: () => isSeeking = true,
                            onSeek: (d) {
                              isSeeking = false;
                              player.seek(d);
                            },
                          ),
                        ),
                        // Compact Playback Controls & Bottom Utilities
                        AudioControlsWidget(
                          isPlaying: isPlaying,
                          position: position,
                          duration: duration,
                          onPlayPause: () => player.playOrPause(),
                          onPrevious: _allSongs.length > 1 ? _playPrevious : null,
                          onNext: _allSongs.length > 1 ? _playNext : null,
                          onShowLyrics: _toggleInlineLyrics,
                          onShowSleepTimer: _showSleepTimerDialog,
                          onShowEqualizer: _showEqualizerDialog,
                          onShowQueue: () => _showQueueSheet(accent),
                          repeatMode: _repeatMode,
                          onToggleRepeat: () => setState(() => _repeatMode = (_repeatMode + 1) % 3),
                          accentColor: accent,
                          hasLyrics: _lyrics != null && _lyrics!.isNotEmpty,
                          isShowingLyrics: _showInlineLyrics,
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 12),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 歌词面板：全屏底部弹窗，实时同步显示歌词。
class _LyricsPanel extends StatefulWidget {
  final Player player;
  final List<LyricLine>? lyrics;
  final String? lyricSourcePath;
  final String title;
  final String artist;
  final Color accentColor;
  final bool isLoading;
  final VoidCallback? onSelectLyricFile;
  final void Function(Duration)? onSeek;

  const _LyricsPanel({
    required this.player,
    required this.lyrics,
    required this.lyricSourcePath,
    required this.title,
    required this.artist,
    required this.accentColor,
    required this.isLoading,
    this.onSelectLyricFile,
    this.onSeek,
  });

  @override
  State<_LyricsPanel> createState() => _LyricsPanelState();
}

class _LyricsPanelState extends State<_LyricsPanel> {
  Duration _position = Duration.zero;
  StreamSubscription<Duration>? _positionSub;

  @override
  void initState() {
    super.initState();
    _positionSub = widget.player.stream.position.listen((p) {
      if (mounted) setState(() => _position = p);
    });
  }

  @override
  void dispose() {
    _positionSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final mediaQuery = MediaQuery.of(context);

    return Container(
      height: mediaQuery.size.height * 0.85,
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF1E1E2E) : theme.colorScheme.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: Column(
        children: [
          // 拖拽指示器
          Container(
            margin: const EdgeInsets.only(top: 12),
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: theme.colorScheme.onSurface.withOpacity(0.2),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          // 标题栏
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        widget.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: isDark ? Colors.white : theme.colorScheme.onSurface,
                          fontWeight: FontWeight.bold,
                          fontSize: 18,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        widget.artist,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: (isDark ? Colors.white : theme.colorScheme.onSurface).withOpacity(0.5),
                          fontSize: 13,
                        ),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  icon: Icon(Icons.folder_open_rounded, color: widget.accentColor, size: 22),
                  tooltip: L10n.of(context).ui_select_lyrics_file,
                  onPressed: widget.onSelectLyricFile,
                ),
                IconButton(
                  icon: Icon(Broken.arrow_down_2, color: isDark ? Colors.white : theme.colorScheme.onSurface, size: 24),
                  onPressed: () => Navigator.pop(context),
                ),
              ],
            ),
          ),
          Divider(color: theme.colorScheme.onSurface.withOpacity(0.08), height: 1),
          // 歌词内容
          Expanded(
            child: widget.isLoading
                ? const Center(child: CircularProgressIndicator())
                : widget.lyrics != null && widget.lyrics!.isNotEmpty
                    ? LyricsViewWidget(
                        lyrics: widget.lyrics!,
                        position: _position,
                        accentColor: widget.accentColor,
                        onSeek: widget.onSeek,
                      )
                    : _buildNoLyricsWidget(theme, isDark),
          ),
        ],
      ),
    );
  }

  Widget _buildNoLyricsWidget(ThemeData theme, bool isDark) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Broken.document,
              size: 64,
              color: (isDark ? Colors.white : theme.colorScheme.onSurface).withOpacity(0.2),
            ),
            const SizedBox(height: 16),
            Text(
              L10n.of(context).ui_no_lyrics_found,
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
                color: (isDark ? Colors.white : theme.colorScheme.onSurface).withOpacity(0.6),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              L10n.of(context).ui_lyrics_auto_load_hint,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 14,
                height: 1.6,
                color: (isDark ? Colors.white : theme.colorScheme.onSurface).withOpacity(0.4),
              ),
            ),
            const SizedBox(height: 24),
            ElevatedButton.icon(
              onPressed: widget.onSelectLyricFile,
              icon: const Icon(Icons.folder_open_rounded, size: 20),
              label: Text(L10n.of(context).ui_select_lyrics_file),
              style: ElevatedButton.styleFrom(
                backgroundColor: widget.accentColor,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
