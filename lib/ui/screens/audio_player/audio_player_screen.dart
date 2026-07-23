import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:on_audio_query/on_audio_query.dart';
import 'package:audio_service/audio_service.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';
import 'package:path/path.dart' as p;
import '../../../core/icon_fonts/broken_icons.dart';
import '../../../core/utils.dart';
import '../../../services/audio_background_handler.dart';
import '../../../services/desktop_lyric_service.dart';
import '../../../services/desktop_lyric_controller.dart';
import '../../../services/preferences_service.dart';
import '../../../services/lyric_parser.dart';
import '../../../services/lyric_search_service.dart';
import '../../../services/remote_streaming_service.dart';
import '../../../services/network_connections_service.dart';
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
    with TickerProviderStateMixin, WidgetsBindingObserver {
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

  /// 返回用于界面显示的艺术家名称，空值或 "unknown" 时使用 l10n 翻译。
  String _getDisplayArtist() {
    final artist = _currentArtist;
    if (FileUtils.isUnknownArtist(artist)) {
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
  // 标记用户已跳转系统设置请求通知权限，等待返回应用时复检
  bool _backgroundPlayPendingPermission = false;

  // 歌词
  List<LyricLine>? _lyrics;
  String? _lyricSourcePath; // 实际歌词文件路径
  bool _isLoadingLyrics = false;
  bool _showInlineLyrics = false; // 是否在播放器界面显示完整内联歌词
  int _lyricsLoadGeneration = 0; // 防止歌词加载竞态

  // 桌面歌词悬浮窗
  bool _desktopLyricEnabled = false;
  // 标记用户已跳转系统设置请求悬浮窗权限，等待返回应用时复检
  bool _desktopLyricPendingPermission = false;
  StreamSubscription<void>? _desktopLyricClickSub;

  // 远程流式播放
  String? _currentStreamUrl; // 当前远程流式播放的代理 URL

  // 播放进度记忆
  bool _hasSeekedToSavedPosition = false;
  Timer? _positionSaveTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _currentIndex = widget.initialIndex;
    _isBackgroundMode = PreferencesService.getAudioBackgroundPlay();
    _desktopLyricEnabled = PreferencesService.getDesktopLyricEnabled();

    // 桌面歌词悬浮窗：注册 MethodChannel 与单击回调
    DesktopLyricService.instance.ensureInitialized();
    _desktopLyricClickSub =
        DesktopLyricService.instance.onLyricClick.listen((_) {
      if (!mounted) return;
      if (isPlaying) {
        player.pause();
      } else {
        player.play();
      }
    });

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
      // 覆盖 media_kit 硬编码的 network-timeout=5s，给远程流式播放足够时间
      () async {
        try {
          final platform = player.platform;
          if (platform is NativePlayer) {
            await platform.setProperty('network-timeout', '60');
            await platform.setProperty('cache-secs', '10');
          }
        } catch (e) {
          debugPrint('设置 audio network-timeout 失败: $e');
        }
        _openTrack();
      }();
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

    // 若上次会话开启了桌面歌词，恢复悬浮窗显示
    if (_desktopLyricEnabled) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _showDesktopLyricIfEnabled();
      });
    } else if (DesktopLyricController.instance.isRunning) {
      // Controller 正在运行说明桌面歌词已开启（可能从后台播放恢复），同步开关状态
      setState(() => _desktopLyricEnabled = true);
    }
  }

  void _initListeners() {
    player.stream.playing.listen((playing) {
      if (!mounted) return;
      setState(() => isPlaying = playing);
    });
    player.stream.position.listen((p) {
      if (!mounted || isSeeking) return;
      setState(() => position = p);
      // 桌面歌词由 DesktopLyricController 独立监听更新，此处仅更新内联歌词
      _updateDesktopLyric();
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

  void _openTrack() async {
    // 重置进度恢复标记
    _hasSeekedToSavedPosition = false;
    // 保存当前播放的音频信息（用于从分类页恢复播放）
    PreferencesService.saveLastPlayedAudio(_currentPath, _currentTitle, _currentArtist);

    // 加载歌词
    _loadLyrics();

    // 处理 remote:// 路径：解析为流式播放 URL
    String playPath = _currentPath;
    if (_currentPath.startsWith('remote://')) {
      // 清理上一次的远程流式会话
      await _stopCurrentStream();
      final resolved = await _resolveRemotePath(_currentPath);
      if (resolved == null) {
        debugPrint('远程路径解析失败: $_currentPath');
        return;
      }
      playPath = resolved;
      _currentStreamUrl = playPath;
    }

    // For remote files that are being cached, wait until the download completes
    // (download goes to .partial file, then renames to the actual file)
    if (widget.isRemote && !playPath.startsWith('http') && !_currentPath.startsWith('remote://')) {
      final file = File(playPath);
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
                player.open(Media(playPath), play: true);
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
    player.open(Media(playPath), play: true);
    player.setRate(_playbackSpeed);
    player.setPitch(_pitch);
    _resetFade();
  }

  /// 停止当前远程流式播放会话
  Future<void> _stopCurrentStream() async {
    if (_currentStreamUrl != null) {
      await RemoteStreamingService.instance.stopStreaming(_currentStreamUrl!);
      _currentStreamUrl = null;
    }
  }

  /// 解析 remote://{connectionId}|{remotePath} 为可播放的流式 URL
  Future<String?> _resolveRemotePath(String remotePathStr) async {
    try {
      final uriPart = remotePathStr.substring('remote://'.length);
      final separatorIndex = uriPart.indexOf('|');
      if (separatorIndex < 0) return null;
      final connectionId = uriPart.substring(0, separatorIndex);
      final remoteFilePath = uriPart.substring(separatorIndex + 1);
      final fileName = p.basename(remoteFilePath);

      final connections = NetworkConnectionsService.getConnections();
      final conn = connections.where((c) => c.id == connectionId).firstOrNull;
      if (conn == null) {
        debugPrint('远程连接未找到: $connectionId');
        return null;
      }

      final remoteClient = FileManagerProvider.createRemoteClient(conn);
      await remoteClient.connect();

      // 优先尝试直接流式 URL（WebDAV 支持 HTTP 流）
      final streamUrl = remoteClient.getStreamUrl(remoteFilePath);
      if (streamUrl != null) {
        // WebDAV 流式播放：保持连接（由 GC 清理）
        return streamUrl;
      }

      // 非 HTTP 流协议（FTP/SFTP 等）：通过本地代理服务器
      try {
        final proxyUrl = await RemoteStreamingService.instance.startStreaming(remoteClient, remoteFilePath, fileName);
        // 代理服务器持有客户端引用，不 disconnect
        return proxyUrl;
      } catch (e) {
        debugPrint('远程流式代理启动失败，回退到下载模式: $e');
      }

      // 回退：完整下载后播放
      final cacheDir = Directory('/storage/emulated/0/ZenFile');
      if (!cacheDir.existsSync()) cacheDir.createSync(recursive: true);
      final cachePath = p.join(cacheDir.path, fileName);
      if (!File(cachePath).existsSync()) {
        await remoteClient.downloadFile(remoteFilePath, cachePath, (progress) {});
      }
      await remoteClient.disconnect();
      return cachePath;
    } catch (e) {
      debugPrint('解析远程路径失败: $e');
      return null;
    }
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
    WidgetsBinding.instance.removeObserver(this);
    // 保存当前播放进度
    if (position.inMilliseconds > 0) {
      PreferencesService.savePlaybackPosition(_currentPath, position.inMilliseconds);
    }
    _positionSaveTimer?.cancel();
    _cacheCheckTimer?.cancel();
    _sleepTimer?.cancel();
    _fadeController.dispose();
    // 清理桌面歌词悬浮窗
    _desktopLyricClickSub?.cancel();
    _desktopLyricClickSub = null;
    // 清理远程流式会话
    _stopCurrentStream();
    if (_isBackgroundMode) {
      // Let audio keep playing in background — don't dispose player
      // 桌面歌词也应保持显示，不随页面关闭而消失
      // DesktopLyricController 继续运行，独立于 widget 生命周期更新歌词
      getAudioHandler().setSkipCallback(null);
    } else {
      // 非后台模式：停止控制器并隐藏悬浮窗
      DesktopLyricController.instance.stop();
      DesktopLyricService.instance.hide();
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
    final title = _currentTitle;
    final artist = _getDisplayArtist();

    setState(() {
      _lyrics = null;
      _lyricSourcePath = null;
      _isLoadingLyrics = true;
    });

    // 异步加载歌词
    Future(() async {
      // 1. 先尝试本地加载
      final loaded = LyricParser.loadLyricForAudio(audioPath);

      // 只应用最新一次加载的结果，避免切歌竞态覆盖
      if (generation != _lyricsLoadGeneration) return;

      if (loaded != null) {
        if (mounted) {
          setState(() {
            _lyrics = loaded.lyrics;
            _lyricSourcePath = loaded.sourcePath;
            _isLoadingLyrics = false;
          });
          if (_desktopLyricEnabled) {
            DesktopLyricController.instance.setLyrics(loaded.lyrics);
          }
        }
        return;
      }

      // 2. 本地未找到，尝试在线搜索（静默后台）
      debugPrint('[LyricSearch] 本地未找到歌词，尝试在线搜索: $title - $artist');
      if (generation != _lyricsLoadGeneration) return;

      final onlineResult = await LyricSearchService.searchAndDownload(
        title: title,
        artist: artist,
        audioPath: audioPath,
      );

      // 只应用最新一次加载的结果
      if (mounted && generation == _lyricsLoadGeneration) {
        setState(() {
          if (onlineResult != null) {
            _lyrics = onlineResult.lyrics;
            _lyricSourcePath = onlineResult.sourcePath;
          } else {
            _lyrics = null;
            _lyricSourcePath = null;
          }
          _isLoadingLyrics = false;
        });
        if (_desktopLyricEnabled) {
          DesktopLyricController.instance.setLyrics(onlineResult?.lyrics);
        }
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

  /// 从完整文件名中智能分离歌曲名和歌手名。
  /// 支持分隔符: " - ", " – ", " — ", "-", "–", "—", "丨", "|"
  /// 返回 null 表示无法分离。
  List<String>? _trySplitTitleAndArtist(String raw) {
    if (raw.isEmpty) return null;
    final separators = [' - ', ' – ', ' — ', '-', '–', '—', '丨', '|'];
    for (final sep in separators) {
      final idx = raw.lastIndexOf(sep);
      if (idx > 0 && idx < raw.length - sep.length) {
        final title = raw.substring(0, idx).trim();
        final artist = raw.substring(idx + sep.length).trim();
        // 去除文件名中常见的后缀/标签
        final cleanArtist = artist
            .replaceAll(RegExp(r'\s*[（(][^)）]*[)）]\s*$'), '')
            .replaceAll(RegExp(r'\s*\[[^\]]*\]\s*$'), '')
            .trim();
        if (title.isNotEmpty && cleanArtist.isNotEmpty && cleanArtist.length > 1) {
          return [title, cleanArtist];
        }
      }
    }
    return null;
  }

  /// 弹出在线歌词搜索对话框，自动填入歌曲名和歌手名，可手动修改后搜索
  Future<void> _showLyricSearchDialog() async {
    // 使用原始歌手名（空字符串），而非界面显示的"未知艺术家"翻译
    String songTitle = _currentTitle;
    String artistForSearch = _currentArtist;

    // 如果歌手名为空/unknown，尝试从标题中分离
    if (FileUtils.isUnknownArtist(artistForSearch) && songTitle.isNotEmpty) {
      final split = _trySplitTitleAndArtist(songTitle);
      if (split != null) {
        songTitle = split[0];
        artistForSearch = split[1];
      }
    }

    final titleController = TextEditingController(text: songTitle);
    final artistController = TextEditingController(text: artistForSearch);

    final l10n = L10n.of(context);
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    String? errorMessage;
    bool isSearching = false;

    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) {
          return AlertDialog(
            backgroundColor: isDark ? const Color(0xFF1E1E2E) : theme.colorScheme.surface,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
            title: Row(
              children: [
                Icon(Broken.music_filter, color: theme.colorScheme.primary, size: 22),
                const SizedBox(width: 10),
                Text(
                  l10n.ui_search_lyrics_online,
                  style: TextStyle(
                    color: isDark ? Colors.white : theme.colorScheme.onSurface,
                    fontWeight: FontWeight.bold,
                    fontSize: 18,
                  ),
                ),
              ],
            ),
            content: SizedBox(
              width: 300,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // 歌曲名输入框
                  TextField(
                    controller: titleController,
                    enabled: !isSearching,
                    style: TextStyle(color: isDark ? Colors.white : theme.colorScheme.onSurface),
                    decoration: InputDecoration(
                      labelText: l10n.ui_lyric_search_song_title,
                      labelStyle: TextStyle(color: theme.colorScheme.primary.withOpacity(0.7)),
                      filled: true,
                      fillColor: isDark ? Colors.white.withOpacity(0.05) : theme.colorScheme.onSurface.withOpacity(0.04),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(16),
                        borderSide: BorderSide.none,
                      ),
                      prefixIcon: Icon(Icons.music_note_rounded, color: theme.colorScheme.primary.withOpacity(0.6), size: 20),
                    ),
                  ),
                  const SizedBox(height: 12),
                  // 歌手名输入框
                  TextField(
                    controller: artistController,
                    enabled: !isSearching,
                    style: TextStyle(color: isDark ? Colors.white : theme.colorScheme.onSurface),
                    decoration: InputDecoration(
                      labelText: l10n.ui_lyric_search_artist,
                      labelStyle: TextStyle(color: theme.colorScheme.primary.withOpacity(0.7)),
                      filled: true,
                      fillColor: isDark ? Colors.white.withOpacity(0.05) : theme.colorScheme.onSurface.withOpacity(0.04),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(16),
                        borderSide: BorderSide.none,
                      ),
                      prefixIcon: Icon(Icons.person_rounded, color: theme.colorScheme.primary.withOpacity(0.6), size: 20),
                    ),
                  ),
                  // 搜索中指示器 / 错误提示
                  if (isSearching) ...[
                    const SizedBox(height: 20),
                    const Center(child: CircularProgressIndicator()),
                    const SizedBox(height: 8),
                    Text(
                      l10n.ui_lyrics_searching,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: isDark ? Colors.white70 : theme.colorScheme.onSurface.withOpacity(0.5),
                        fontSize: 13,
                      ),
                    ),
                  ],
                  if (errorMessage != null && !isSearching) ...[
                    const SizedBox(height: 16),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                      decoration: BoxDecoration(
                        color: Colors.orangeAccent.shade100.withOpacity(0.15),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: Colors.orangeAccent.shade100.withOpacity(0.3)),
                      ),
                      child: Row(
                        children: [
                          Icon(Icons.info_outline_rounded, color: Colors.orange.shade600, size: 18),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              errorMessage!,
                              style: TextStyle(
                                color: isDark ? Colors.orange.shade200 : Colors.orange.shade800,
                                fontSize: 13,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: Text(l10n.ui_cancel, style: TextStyle(color: isDark ? Colors.white70 : theme.colorScheme.onSurface.withOpacity(0.6))),
              ),
              TextButton(
                onPressed: isSearching
                    ? null
                    : () async {
                        final title = titleController.text.trim();
                        final artist = artistController.text.trim();
                        if (title.isEmpty) {
                          setDialogState(() {
                            errorMessage = l10n.ui_lyrics_not_found_online;
                          });
                          return;
                        }

                        setDialogState(() {
                          isSearching = true;
                          errorMessage = null;
                        });

                        // 在对话框中执行搜索
                        final searchResult = await LyricSearchService.searchAndDownload(
                          title: title,
                          artist: artist,
                          audioPath: _currentPath,
                        );

                        if (!ctx.mounted) return;

                        if (searchResult != null) {
                          Navigator.pop(ctx, true); // 关闭对话框，返回成功
                        } else {
                          setDialogState(() {
                            isSearching = false;
                            errorMessage = l10n.ui_lyrics_not_found_online;
                          });
                        }
                      },
                child: Text(l10n.ui_search_lyrics_online, style: TextStyle(color: theme.colorScheme.primary, fontWeight: FontWeight.bold)),
              ),
            ],
          );
        },
      ),
    );

    // 清理控制器
    titleController.dispose();
    artistController.dispose();

    if (!mounted || result != true) return;

    // 对话框返回 true 表示搜索成功，reload lyrics
    _loadLyrics();
  }

  /// 切换完整内联歌词显示（用歌词视图替换封面）
  void _toggleInlineLyrics() {
    setState(() {
      _showInlineLyrics = !_showInlineLyrics;
    });
  }

  // ─── 桌面歌词悬浮窗 ────────────────────────────────────────────────────

  /// 获取桌面歌词颜色（ARGB int 格式，用于原生层渲染）
  /// 返回 [highlightColor, normalColor]。
  List<int> _getDesktopLyricColors() {
    final accent = Theme.of(context).colorScheme.primary;
    // 高亮色 = 主题主色（已唱部分）
    final highlightColor = accent.value;
    // 普通色 = 主题主色 35% 透明度（未唱部分）
    final normalColor = accent.withOpacity(0.35).value;
    return [highlightColor, normalColor];
  }

  /// 若用户上次开启了桌面歌词，恢复显示（带权限校验）
  void _showDesktopLyricIfEnabled() async {
    if (!_desktopLyricEnabled) return;
    final granted = await DesktopLyricService.instance.checkPermission();
    if (!granted) {
      // 权限已被撤销，关闭本地开关
      setState(() => _desktopLyricEnabled = false);
      await PreferencesService.saveDesktopLyricEnabled(false);
      return;
    }
    if (!mounted) return;
    final colors = _getDesktopLyricColors();
    DesktopLyricController.instance.setColors(highlightColor: colors[0], normalColor: colors[1]);
    DesktopLyricController.instance.setLyrics(_lyrics);
    DesktopLyricController.instance.start(player);
  }

  /// 切换桌面歌词悬浮窗开关
  void _toggleDesktopLyric() async {
    if (_desktopLyricEnabled) {
      DesktopLyricController.instance.stop();
      await DesktopLyricService.instance.hide();
      setState(() => _desktopLyricEnabled = false);
      await PreferencesService.saveDesktopLyricEnabled(false);
      return;
    }
    // 开启：先检查权限
    final granted = await DesktopLyricService.instance.checkPermission();
    if (!granted) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(L10n.of(context).msg_overlay_permission_required),
          duration: const Duration(seconds: 3),
        ),
      );
      // 标记等待权限授予；用户从系统设置返回后会复检并自动开启
      _desktopLyricPendingPermission = true;
      await DesktopLyricService.instance.requestPermission();
      return;
    }
    await _enableDesktopLyric();
  }

  /// 实际开启桌面歌词悬浮窗（权限已授予的前提下调用）
  Future<void> _enableDesktopLyric() async {
    final colors = _getDesktopLyricColors();
    DesktopLyricController.instance.setColors(highlightColor: colors[0], normalColor: colors[1]);
    DesktopLyricController.instance.setLyrics(_lyrics);
    DesktopLyricController.instance.start(player);
    setState(() => _desktopLyricEnabled = true);
    await PreferencesService.saveDesktopLyricEnabled(true);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;

    // 后台播放：用户从系统设置返回，复检通知权限；若已授予则自动开启
    if (_backgroundPlayPendingPermission) {
      _backgroundPlayPendingPermission = false;
      _resumeBackgroundPlayPermissionCheck();
    }

    // 桌面歌词：权限复检或状态同步
    if (_desktopLyricPendingPermission) {
      _desktopLyricPendingPermission = false;
      _resumeDesktopLyricPermissionCheck();
    } else {
      // 同步开关状态与原生层实际显示状态，避免状态不一致
      _syncDesktopLyricState();
    }
  }

  Future<void> _resumeBackgroundPlayPermissionCheck() async {
    bool granted = false;
    try {
      final status = await Permission.notification.status;
      granted = status.isGranted;
    } catch (e) {
      granted = false;
    }
    if (!granted) return;
    if (!mounted) return;
    await _enableBackgroundMode();
  }

  Future<void> _resumeDesktopLyricPermissionCheck() async {
    final granted = await DesktopLyricService.instance.checkPermission();
    if (!granted) return;
    if (!mounted) return;
    await _enableDesktopLyric();
  }

  /// 同步本地开关状态与原生层悬浮窗实际显示状态
  ///
  /// 关键修复：当本地开关为 ON 但原生层悬浮窗被系统回收（isShowing=false）时，
  /// 自动重新创建悬浮窗并推送当前歌词，避免「开启后无故消失」。
  Future<void> _syncDesktopLyricState() async {
    if (!mounted) return;
    final actuallyShowing = await DesktopLyricService.instance.isShowing();
    if (!mounted) return;
    if (_desktopLyricEnabled && !actuallyShowing) {
      // 开关为 ON 但悬浮窗被系统回收 → 自动恢复
      await _enableDesktopLyric();
    } else if (!_desktopLyricEnabled && actuallyShowing) {
      // 开关为 OFF 但悬浮窗仍在显示 → 主动关闭
      await DesktopLyricService.instance.hide();
    }
  }

  /// 同步当前歌词行到悬浮窗（由 DesktopLyricController 独立管理更新，此处仅做状态同步）
  void _updateDesktopLyric() {
    // 桌面歌词更新已由 DesktopLyricController 独立管理
    // 此方法保留用于向后兼容，未来可移除
  }



  /// 获取当前应显示的歌词行
  LyricLine? _getCurrentLyricLine() {
    if (_lyrics == null || _lyrics!.isEmpty) return null;
    final index = LyricParser.findCurrentLineIndex(_lyrics!, position);
    if (index < 0 || index >= _lyrics!.length) return null;
    return _lyrics![index];
  }

  /// 构建单行歌词显示（支持逐字高亮）
  Widget _buildSingleLineLyrics(Color accent, ThemeData theme, bool isDark) {
    final line = _getCurrentLyricLine();
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
          child: line != null
              ? SizedBox(
                  key: ValueKey<String>(line.text),
                  width: double.infinity,
                  child: _buildLyricLineText(line, accent, isDark),
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

  /// 构建歌词行文本（支持逐字高亮 + 平滑过渡 + 放大效果）
  Widget _buildLyricLineText(LyricLine line, Color accent, bool isDark) {
    if (line.text.isEmpty) {
      return Text(
        '♪',
        textAlign: TextAlign.center,
        style: TextStyle(
          fontSize: 15,
          fontWeight: FontWeight.w600,
          color: accent,
          height: 1.4,
        ),
      );
    }

    final baseColor = (isDark ? Colors.white : Colors.black).withOpacity(0.5);
    final highlightColor = accent;

    // 检查是否有逐字时间戳
    if (line.hasWordTimestamps) {
      return RichText(
        textAlign: TextAlign.center,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        text: TextSpan(
          children: line.words!.asMap().entries.map((entry) {
            final idx = entry.key;
            final word = entry.value;
            final progress = _calcWordProgress(line, idx);

            // 颜色插值
            final textColor = Color.lerp(baseColor, highlightColor, progress)!;

            // 字重过渡
            FontWeight fontWeight;
            if (progress > 0.7) {
              fontWeight = FontWeight.w700;
            } else if (progress > 0.3) {
              fontWeight = FontWeight.w600;
            } else {
              fontWeight = FontWeight.w500;
            }

            // 放大效果：progress=0.5 时达到最大放大
            final scaleBoost = 3.0 * _wordScaleCurve(progress);

            return TextSpan(
              text: word.text,
              style: TextStyle(
                fontSize: 15.0 + scaleBoost,
                fontWeight: fontWeight,
                color: textColor,
                height: 1.4,
              ),
            );
          }).toList(),
        ),
      );
    }

    // 普通歌词
    return Text(
      line.text,
      textAlign: TextAlign.center,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        fontSize: 15,
        fontWeight: FontWeight.w600,
        color: accent,
        height: 1.4,
      ),
    );
  }

  /// 计算单个字的高亮过渡进度 (0.0 ~ 1.0)
  double _calcWordProgress(LyricLine line, int wordIndex) {
    final words = line.words!;
    final posMs = position.inMilliseconds;
    final currentWordTs = words[wordIndex].timestamp.inMilliseconds;

    if (posMs < currentWordTs) {
      return 0.0;
    }

    // 固定过渡时长 300ms
    const transitionDuration = 300;

    // 如果不是最后一个字且间隔很短，缩短过渡时间避免重叠
    int actualDuration = transitionDuration;
    if (wordIndex + 1 < words.length) {
      final nextWordTs = words[wordIndex + 1].timestamp.inMilliseconds;
      final gapDuration = nextWordTs - currentWordTs;
      if (gapDuration < transitionDuration) {
        actualDuration = (gapDuration * 0.6).toInt().clamp(80, transitionDuration);
      }
    }

    final elapsed = posMs - currentWordTs;
    final progress = (elapsed / actualDuration).clamp(0.0, 1.0);
    return _easeInOutCubic(progress);
  }

  /// easeInOutCubic 缓动函数
  double _easeInOutCubic(double t) {
    return t < 0.5
        ? 4 * t * t * t
        : 1 - (-2 * t + 2) * (-2 * t + 2) * (-2 * t + 2) / 2;
  }

  /// 字体放大曲线：t=0 和 t=1 时为 0，t=0.5 时为 1
  double _wordScaleCurve(double t) {
    return 4 * t * (1 - t);
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
      builder: (ctx) => _LyricsPanel(
        player: player,
        lyrics: _lyrics,
        lyricSourcePath: _lyricSourcePath,
        title: _currentTitle,
        artist: _getDisplayArtist(),
        accentColor: Theme.of(context).colorScheme.primary,
        isLoading: _isLoadingLyrics,
        onSelectLyricFile: () {
          Navigator.pop(ctx);
          _selectLyricFile();
        },
        onSearchOnline: () {
          Navigator.pop(ctx);
          _showLyricSearchDialog();
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
      artist: FileUtils.isUnknownArtist(rawArtist) ? L10n.of(context).msg5e32276d : rawArtist,
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

  void _handleBackgroundToggle(BuildContext ctx) {
    if (_isBackgroundMode) {
      _toggleBackgroundMode();
    } else {
      Navigator.pop(ctx);
      _toggleBackgroundMode();
    }
  }

  Future<void> _toggleBackgroundMode() async {
    if (_isBackgroundMode) {
      // Turn off — stop background handler to completely clear the notification,
      // but do NOT dispose the player because we want it to keep playing in the foreground!
      // 注意：不要暂停 player，保持当前播放状态不变
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
    bool notifGranted = true;
    try {
      final status = await Permission.notification.request();
      notifGranted = status.isGranted;
    } catch (e) {
      debugPrint('[ZenFile] Error requesting notification permission: $e');
      notifGranted = false;
    }

    if (!notifGranted && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(L10n.of(context).msg_notification_permission_denied),
          backgroundColor: Colors.redAccent,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          duration: const Duration(seconds: 6),
          action: SnackBarAction(
            label: L10n.of(context).msg_open_settings,
            textColor: Colors.white,
            onPressed: () async {
              await openAppSettings();
            },
          ),
        ),
      );
      // 标记等待权限授予；用户从系统设置返回后会复检并自动开启
      _backgroundPlayPendingPermission = true;
      return;
    }

    // Android 13+ 权限授予后需要额外等待系统注册完成
    // 否则 audio_service 调用 startForegroundService 可能因权限未生效而失败
    if (Platform.isAndroid) {
      await Future.delayed(const Duration(milliseconds: 500));
    }

    await _enableBackgroundMode();
  }

  /// 实际开启后台播放（通知权限已授予的前提下调用）
  Future<void> _enableBackgroundMode() async {
    // 仅清除旧的订阅和 player 引用，不调用 stopNotification()。
    // stopNotification() 会 emit idle 状态导致 audio_service 调用 stopForeground()，
    // 随后 attach() emit ready 状态需要重新 startForeground()。
    // 在某些 ROM 上 stop→start 竞态会导致前台服务通知不显示。
    // detach() 只清除 Dart 端状态，不通知系统层停止，避免竞态。
    getAudioHandler().detach();

    // A small delay to ensure the OS registers the permission before we display the notification
    await Future.delayed(const Duration(milliseconds: 300));

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

    // 诊断检测：延迟 1.5 秒后检查通知栏是否真的生效
    // audio_service 在某些设备上可能因 ROM 限制（电池优化、通知渠道禁用）导致
    // 前台服务无法显示通知，但代码不会抛错。主动检测并提示用户。
    _diagnoseNotificationEffectiveness();
  }

  /// 诊断通知栏是否实际生效
  ///
  /// 检查逻辑（按优先级）：
  /// 1. AudioService 是否成功初始化（最关键，失败则通知完全无法显示）
  ///    - 若失败，尝试重新初始化一次
  /// 2. 通知权限是否真的授予（部分 ROM 下 Permission.notification.request 可能不弹窗）
  /// 3. audio_service 的 playbackState 是否包含控件（确认前台服务已注册）
  /// 若任一异常，提示用户去系统设置检查通知权限和电池优化
  Future<void> _diagnoseNotificationEffectiveness() async {
    await Future.delayed(const Duration(milliseconds: 1500));
    if (!mounted) return;

    try {
      // 1. 优先检查 AudioService 是否初始化成功
      //    这是最常见的"权限都开了但不显示"的根因
      if (!isAudioServiceInitialized) {
        // 尝试重新初始化一次
        bool reInitOk = false;
        try {
          await AudioService.init(
            builder: () => getAudioHandler(),
            config: const AudioServiceConfig(
              androidNotificationChannelId: 'com.sequl.zenfile.audio',
              androidNotificationChannelName: 'ZenFile Audio Player',
              androidNotificationIcon: 'mipmap/ic_launcher',
              androidShowNotificationBadge: true,
              androidStopForegroundOnPause: false,
              notificationColor: Color(0xFF6200EE),
            ),
          );
          isAudioServiceInitialized = true;
          reInitOk = true;
          debugPrint('[ZenFile] AudioService re-init succeeded');
        } catch (e) {
          debugPrint('[ZenFile] AudioService re-init failed: $e');
        }

        if (!reInitOk) {
          if (!mounted) return;
          _showNotificationDiagnosticSnackBar(
            L10n.of(context).msg_audio_service_init_failed,
            openSettings: false,
          );
          return;
        }

        // 重新初始化成功后，重新 attach 播放器
        // 因为之前的 attach 调用可能没有正确注册到 audio_service
        if (mounted) {
          _startBackgroundMode();
        }
        // 等待 attach + emit 完成
        await Future.delayed(const Duration(milliseconds: 800));
        if (!mounted) return;
      }

      // 2. 复检通知权限
      final notifStatus = await Permission.notification.status;
      if (!notifStatus.isGranted) {
        if (!mounted) return;
        _showNotificationDiagnosticSnackBar(
          L10n.of(context).msg_notification_not_granted,
          openSettings: true,
        );
        return;
      }

      // 3. 检查 audio_service 的 playbackState 是否包含控件
      //    若为空或无控件，说明前台服务注册失败（通常是 ROM 限制）
      final state = getAudioHandler().playbackState.value;
      if (state.controls.isEmpty) {
        if (!mounted) return;
        _showNotificationDiagnosticSnackBar(
          L10n.of(context).msg_notification_blocked_hint,
          openSettings: true,
        );
        return;
      }

      // 4. 检查通知渠道是否被系统或用户禁用（Android 8+）
      //    即使权限已授予且 controls 非空，如果通知渠道被设为 IMPORTANCE_NONE，
      //    系统也不会显示通知。这是之前诊断逻辑的盲区。
      if (Platform.isAndroid) {
        try {
          const channel = MethodChannel('com.sequl.zenfile/notifications');
          final result = await channel.invokeMethod<Map>('checkAudioChannelStatus');
          if (result != null) {
            final exists = result['exists'] as bool? ?? true;
            final enabled = result['enabled'] as bool? ?? true;
            if (!exists) {
              // 渠道不存在 — audio_service 可能没有正确创建渠道
              // 尝试重新初始化 AudioService 以触发渠道创建
              if (mounted && isAudioServiceInitialized) {
                _showNotificationDiagnosticSnackBar(
                  L10n.of(context).msg_notification_blocked_hint,
                  openSettings: true,
                );
              }
              return;
            }
            if (!enabled) {
              // 渠道存在但被禁用 — 用户在系统设置中关闭了通知渠道
              if (!mounted) return;
              _showNotificationDiagnosticSnackBar(
                L10n.of(context).msg_notification_channel_disabled,
                openSettings: true,
              );
              return;
            }
          }
        } catch (e) {
          debugPrint('[ZenFile] checkAudioChannelStatus error: $e');
          // 原生方法调用失败，不阻塞诊断流程
        }
      }
    } catch (e) {
      debugPrint('[ZenFile] Notification diagnosis error: $e');
    }
  }

  /// 显示通知诊断失败的 SnackBar
  void _showNotificationDiagnosticSnackBar(String message, {bool openSettings = false}) {
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: Colors.deepOrange,
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 8),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        action: openSettings
            ? SnackBarAction(
                label: L10n.of(context).msg_open_settings,
                textColor: Colors.white,
                onPressed: () async {
                  await openAppSettings();
                },
              )
            : null,
      ),
    );
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
                      L10n.of(context).msg29eed1da,
                      style: TextStyle(
                        color: _isBackgroundMode ? Colors.greenAccent : Colors.white,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    trailing: Switch(
                      value: _isBackgroundMode,
                      activeColor: Colors.greenAccent,
                      onChanged: (_) {
                        _handleBackgroundToggle(ctx);
                      },
                    ),
                    onTap: () {
                      _handleBackgroundToggle(ctx);
                    },
                  ),
                  // ── 桌面歌词悬浮窗 ────────────────────────────────────────────────
                  ListTile(
                    leading: Icon(
                      Broken.note_text,
                      color: _desktopLyricEnabled ? Colors.deepPurpleAccent : Colors.white,
                    ),
                    title: Text(
                      L10n.of(context).ui_desktop_lyric,
                      style: TextStyle(
                        color: _desktopLyricEnabled ? Colors.deepPurpleAccent : Colors.white,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    trailing: Switch(
                      value: _desktopLyricEnabled,
                      activeColor: Colors.deepPurpleAccent,
                      onChanged: (_) {
                        _toggleDesktopLyric();
                        setSheet(() {});
                      },
                    ),
                    onTap: () {
                      _toggleDesktopLyric();
                      setSheet(() {});
                    },
                  ),
                  ListTile(
                    leading: const Icon(Icons.search_rounded, color: Colors.white),
                    title: Text(L10n.of(context).ui_search_lyrics_online, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
                    onTap: () {
                      Navigator.pop(ctx);
                      _showLyricSearchDialog();
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
            child: LayoutBuilder(
              builder: (context, constraints) {
                final screenWidth = constraints.maxWidth;
                final screenHeight = constraints.maxHeight;
                final aspectRatio = screenWidth / screenHeight;
                final isWideScreen = aspectRatio > 1.8;

                if (isWideScreen) {
                  return _buildWideScreenLayout(context, accent, theme, isDark);
                } else {
                  return _buildNormalScreenLayout(context, accent, theme, isDark);
                }
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildNormalScreenLayout(BuildContext context, Color accent, ThemeData theme, bool isDark) {
    return Column(
      children: [
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
        Expanded(
          child: FadeTransition(
            opacity: _fadeAnim,
            child: SingleChildScrollView(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  _buildArtworkOrLyrics(accent, theme, isDark),
                  _buildSingleLineLyrics(accent, theme, isDark),
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
                        setState(() => position = d);
                        player.seek(d);
                      },
                    ),
                  ),
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
        ),
      ],
    );
  }

  Widget _buildWideScreenLayout(BuildContext context, Color accent, ThemeData theme, bool isDark) {
    return Row(
      children: [
        Expanded(
          flex: 1,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: Row(
                  children: [
                    IconButton(
                      icon: Icon(Broken.arrow_down_2, size: 24),
                      onPressed: () => Navigator.pop(context),
                    ),
                    const SizedBox(width: 12),
                    Container(
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: theme.colorScheme.onSurface.withOpacity(0.08),
                      ),
                      child: IconButton(
                        icon: const Icon(Icons.more_horiz_rounded, size: 20),
                        onPressed: _showMoreMenu,
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: FadeTransition(
                  opacity: _fadeAnim,
                  child: Center(
                    child: _buildArtworkOrLyrics(accent, theme, isDark),
                  ),
                ),
              ),
            ],
          ),
        ),
        Expanded(
          flex: 1,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: Text(
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
              ),
              Expanded(
                child: FadeTransition(
                  opacity: _fadeAnim,
                  child: SingleChildScrollView(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        _buildSingleLineLyrics(accent, theme, isDark),
                        const SizedBox(height: 16),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 24),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.center,
                            children: [
                              Text(
                                _currentTitle,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                textAlign: TextAlign.center,
                                style: const TextStyle(
                                  fontWeight: FontWeight.w800,
                                  fontSize: 20,
                                  letterSpacing: 0.2,
                                ),
                              ),
                              const SizedBox(height: 6),
                              Text(
                                _getDisplayArtist(),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  fontSize: 14,
                                  color: theme.colorScheme.onSurface.withOpacity(0.6),
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 16),
                        IconButton(
                          icon: Icon(
                            _isFavorite ? Icons.favorite_rounded : Icons.favorite_border_rounded,
                            color: _isFavorite ? Colors.redAccent : theme.colorScheme.onSurface.withOpacity(0.6),
                            size: 32,
                          ),
                          onPressed: () => setState(() => _isFavorite = !_isFavorite),
                        ),
                        const SizedBox(height: 16),
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
                              setState(() => position = d);
                              player.seek(d);
                            },
                          ),
                        ),
                        const SizedBox(height: 16),
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
              ),
            ],
          ),
        ),
      ],
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
  final VoidCallback? onSearchOnline;
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
    this.onSearchOnline,
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
            Wrap(
              alignment: WrapAlignment.center,
              spacing: 12,
              runSpacing: 12,
              children: [
                OutlinedButton.icon(
                  onPressed: widget.onSearchOnline,
                  icon: const Icon(Icons.search_rounded, size: 20),
                  label: Text(L10n.of(context).ui_search_lyrics_online),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: widget.accentColor,
                    side: BorderSide(color: widget.accentColor.withOpacity(0.4)),
                    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                  ),
                ),
                OutlinedButton.icon(
                  onPressed: widget.onSelectLyricFile,
                  icon: const Icon(Icons.folder_open_rounded, size: 20),
                  label: Text(L10n.of(context).ui_select_lyrics_file),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: widget.accentColor,
                    side: BorderSide(color: widget.accentColor.withOpacity(0.4)),
                    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
