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
import '../../../services/background_play_permission.dart';
import '../../../services/desktop_lyric_service.dart';
import '../../../services/desktop_lyric_controller.dart';
import '../../../services/preferences_service.dart';
import '../../../services/lyric_animation_style.dart';
import '../../../services/lyric_parser.dart';
import '../../../services/lyric_search_service.dart';
import '../../../services/remote_streaming_service.dart';
import '../../../services/network_connections_service.dart';
import '../../../services/audio_equalizer_service.dart';
import '../../../services/mpv_audio_output_service.dart';
import '../../../providers/file_manager_provider.dart';
import '../internal_file_picker_screen.dart';
import 'audio_artwork_widget.dart';
import 'audio_waveform_widget.dart';
import 'marquee_text_widget.dart';
import 'audio_controls_widget.dart';
import 'audio_queue_sheet.dart';
import 'audio_particles_widget.dart';
import 'lyric_settings_page.dart';
import 'lyric_offset_dialog.dart';
import 'lyric_color_picker_dialog.dart';
import 'lyric_style_dropdown.dart';
import 'lyric_style_sheet.dart';
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

  /// 本页实际使用的播放队列。
  ///
  /// 通常等于 `widget.allSongs`；但**复用后台播放会话**时会被 handler 里保存的原始
  /// 队列覆盖（见 [_adoptBackgroundQueue]）—— 因为调用方重建本页时往往拿不到当初
  /// 那个队列（从通知栏进来只给得到「当前这一首」；类别页「继续播放」给的却是
  /// 「全盘音频列表」），不校正就会出现「下一首跳到播放列表之外」+
  /// 「最大化后发现播放列表变了」（用户反馈 issue #34）。
  late List<SongModel> _songs;
  List<SongModel> get _allSongs => _songs;
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

  // Playback mode: 0=sequential, 1=list loop, 2=single loop, 3=shuffle
  int _playbackMode = 0;

  // Shuffle
  bool _isShuffled = false;
  late List<int> _shuffleQueue; // shuffled indices of _allSongs
  int _shufflePos = 0; // current position in _shuffleQueue

  // Background playback
  bool _isBackgroundMode = false;
  // 标记用户已跳转系统设置请求通知权限，等待返回应用时复检
  bool _backgroundPlayPendingPermission = false;

  // 歌词显示模式：0=关闭, 1=单行, 2=多行内联, 3=全屏面板
  int _lyricsDisplayMode = 2;

  // 歌词
  List<LyricLine>? _lyrics;
  bool _isLoadingLyrics = false;
  int _lyricsLoadGeneration = 0; // 防止歌词加载竞态
  bool _lyricsWerePlaceholder = false; // 检测歌词为占位文本时显示多语言提示

  /// 生效的歌词整体偏移（毫秒）：单曲覆盖优先，否则全局值。
  /// 正值 = 歌词延后，负值 = 歌词提前；见 [_lyricPosition]。
  int _lyricOffsetMs = 0;

  // 桌面歌词悬浮窗
  bool _desktopLyricEnabled = false;
  LyricAnimationStyle _lyricStyle = LyricAnimationStyle.mixed;
  // 标记用户已跳转系统设置请求悬浮窗权限，等待返回应用时复检
  bool _desktopLyricPendingPermission = false;
  StreamSubscription<void>? _desktopLyricClickSub;

  /// 播放器事件订阅（playing / position / duration / completed / buffering）。
  ///
  /// ⚠️ 必须显式保存、并在页面销毁时取消：**后台播放模式下本页销毁时不会销毁
  /// player**（音乐要继续播），复用的 player 会长期存活 ⇒ 反复进出播放页（从通知栏
  /// 返回、从音频类别页「继续播放」返回走的都是复用分支）会在同一个 player 上不断
  /// 叠加订阅。旧 State 的回调虽然被 `mounted` 挡住不会崩，但每个事件仍要空跑一遍，
  /// 且旧 State 连同其闭包、歌词、队列快照全部无法回收（隐性内存增长）。
  final List<StreamSubscription<dynamic>> _playerSubs =
      <StreamSubscription<dynamic>>[];

  // 远程流式播放
  String? _currentStreamUrl; // 当前远程流式播放的代理 URL

  /// 是否已经开过第一首歌。
  ///
  /// 用来区分「首次打开」与「播放列表切歌」两种进入 [_openTrack] 的时机：
  /// 首次的流由调用方（`FileManagerProvider`）预先建立并放在 `widget.audioPath`
  /// 里；切歌时才需要播放器自己按 `remote://{connId}|{path}` 建流。
  /// 不区分会导致首次也重复建流，且调用方那个会话永远不被停止（持续后台下载）。
  bool _firstTrackOpened = false;

  // 播放进度记忆
  bool _hasSeekedToSavedPosition = false;
  Timer? _positionSaveTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _songs = widget.allSongs ?? const <SongModel>[];
    _currentIndex = _safeIndex(widget.initialIndex, _songs.length);
    _isBackgroundMode = PreferencesService.getAudioBackgroundPlay();
    _desktopLyricEnabled = PreferencesService.getDesktopLyricEnabled();
    _lyricStyle = LyricAnimationStyle.fromName(
        PreferencesService.getLyricAnimationStyleName());
    _lyricsDisplayMode = PreferencesService.getLyricsDisplayMode();

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
    // 优先复用已有播放器：widget.existingPlayer > handler 后台播放中的 player
    if (widget.existingPlayer != null) {
      // 复用后台播放中已有的播放器，保持当前播放状态不断开
      player = widget.existingPlayer!;
      // ⚠️ 必须先校正队列再生成随机序：否则 _shuffleQueue 会按错的长度/顺序生成
      _adoptBackgroundQueue();
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
      // ⚠️ 复用已有播放器**不会**走下面 else 分支的 configureBeforeOpen，
      // 档位会完全失效（从播放列表/通知栏返回正是这条路径）。补一次热应用。
      _applyAudioOutputToReusedPlayer('audio-reuse');
    } else if (_isBackgroundMode &&
        getAudioHandler().hasActivePlayer &&
        // ⚠️ 排除视频后台会话：handler 里挂的是视频的 player，拿它播音频会让
        // UI 与播放状态完全错位（用户反馈 2026-09-27 的同源问题）。
        !getAudioHandler().videoSession) {
      // 先快照「调用方请求播放的曲目路径」：下方 _adoptBackgroundQueue() 会用后台
      // 旧会话的队列与下标覆盖 _songs/_currentIndex，使 _currentPath 指向后台正在播
      // 的旧歌 A —— 「点的是否为新歌」的比较将恒为相等，新歌永远开播不了（用户反馈：
      // 开启后台播放后回文件列表点其他音频，播放器仍播旧歌）。
      // _buildMediaItem 的 id 与 SongModel.data / widget.audioPath 同源，可直接判等。
      final String requestedPath =
          (widget.allSongs != null && widget.allSongs!.isNotEmpty)
              ? widget
                    .allSongs![_safeIndex(
                      widget.initialIndex,
                      widget.allSongs!.length,
                    )]
                    .data
              : widget.audioPath;
      final bool switchToRequested =
          getAudioHandler().currentPath != requestedPath;

      // 后台播放中从通知栏返回：复用 handler 的 player，避免新建导致 UI 与播放状态脱节
      player = getAudioHandler().currentPlayer!;
      if (switchToRequested) {
        // 用户点的是另一首：队列以调用方传入的为准（未传则单曲页），
        // 让 _currentSong/_currentPath 指向新歌 —— 不能沿用后台旧队列，
        // 否则 _openTrack 解析到的仍是旧歌。
        _songs = widget.allSongs ?? const <SongModel>[];
        _currentIndex = _safeIndex(widget.initialIndex, _songs.length);
      } else {
        // ⚠️ 从通知栏进来时调用方**不传 allSongs**，必须用 handler 的快照补齐队列，
        // 否则播放列表是空的，切歌/下一首全乱（issue #34）。同样要早于随机序生成。
        _adoptBackgroundQueue();
      }
      _shuffleQueue = List.generate(_allSongs.length, (i) => i);
      _initListeners();
      setState(() {
        isPlaying = player.state.playing;
        // 切歌时清掉旧歌的瞬时进度，避免新歌 open 前界面闪现旧进度
        position = switchToRequested ? Duration.zero : player.state.position;
        duration = switchToRequested ? Duration.zero : player.state.duration;
      });
      _hasSeekedToSavedPosition = true;
      // 重新建立 skip 回调（dispose 时清除了），确保通知栏切歌仍能同步 UI
      getAudioHandler().setSkipCallback(_onBackgroundSkip);
      if (switchToRequested) {
        // 打开用户点的新歌（内部会加载歌词、写 lastPlayedAudio 并 open 播放）
        _openTrack();
        // 以新队列重建后台会话：通知栏上一首/下一首才会按新队列切歌。
        // attach 对同一 player 重复调用是安全的（见 handler attach 注释）。
        _startBackgroundMode();
      } else {
        _loadLyrics();
        _updateBackgroundItem();
      }
      // 同上：后台 player 复用路径也必须补一次档位应用。
      _applyAudioOutputToReusedPlayer('audio-reuse-bg');
    } else {
      player = Player(
        configuration: const PlayerConfiguration(
          bufferSize: 16 * 1024 * 1024,
          pitch: true,
        ),
      );
      MpvAudioOutputService.notePlayerCreated(player, 'audio-init');
      _shuffleQueue = List.generate(_allSongs.length, (i) => i);
      _initListeners();
      // 覆盖 media_kit 硬编码的 network-timeout=5s，给远程流式播放足够时间
      () async {
        try {
          final platform = player.platform;
          if (platform is NativePlayer) {
            // 音频输出（AO 候选链 + 音频会话 id）配置：必须在 open 之前完成，
            // mpv 只在初始化音频输出链时读这些选项。⚠️ media_kit 在 Android 真机
            // 默认就把 ao 写成单值 opensles，所以「模式」决定的是候选链顺序，
            // 不是「要不要用 OpenSL ES」。细节见服务内注释。
            await MpvAudioOutputService.configureBeforeOpen(
              player,
              mode: PreferencesService.getAudioOutputMode(),
              tag: 'audio',
            );
            await platform.setProperty('network-timeout', '60');
            await platform.setProperty('cache-secs', '10');
          }
        } catch (e) {
          debugPrint('设置 audio network-timeout 失败: $e');
        }
        // 起播后采集一次音频输出诊断：回读**实际生效**的 AO（current-ao，
        // 而不是候选列表回显）+ mpv 自身日志 + 复刻 RJ 的挂音效自检。
        // 仅在诊断日志开启时产生（否则内部直接返回，零开销）。
        MpvAudioOutputService.schedulePlaybackDiagnostics(player, 'audio');
        _openTrack();
      }();
      if (_isBackgroundMode) {
        _startBackgroundMode();
      }
    }

    // 恢复上次选择的播放模式
    _playbackMode = PreferencesService.getAudioPlaybackMode();
    _applyPlaybackMode(_playbackMode);

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

  /// 把 [index] 收敛到 [len] 的合法区间（`_currentSong` 直接下标访问，越界会抛 RangeError）。
  int _safeIndex(int index, int len) {
    if (len <= 0 || index < 0) return 0;
    return index >= len ? len - 1 : index;
  }

  /// 复用后台播放会话时，用 handler 保存的**原始队列**校正本页的队列与当前下标。
  ///
  /// 只在「本页复用的正是 handler 当前那个 player」时调用：此时后台真正在播的队列就在
  /// handler 里（`audioSongQueue`），而调用方传进来的 `widget.allSongs` 可能是**另一个
  /// 列表** —— 从通知栏进来时 `main.dart` 压根不传（`allSongs` 为 null，列表直接空掉）；
  /// 从音频类别页「继续播放」进来时传的是 `MediaProvider.audios`（**全盘**音频列表，
  /// 而不是当初那个文件夹）。不校正就会出现「最小化后下一首跑到播放列表之外」+
  /// 「最大化后发现播放列表变了」（用户反馈 issue #34）。
  void _adoptBackgroundQueue() {
    final handler = getAudioHandler();
    // 视频会话的队列与本页无关（此时 mediaItem 里装的是视频）
    if (handler.videoSession) return;
    final q = handler.audioSongQueue;
    if (q == null || q.isEmpty) return;
    final curId = handler.currentMediaItem?.id;
    if (curId == null) return;
    final idx = q.indexWhere((s) => s.data == curId);
    // 当前播放项不在这个队列里（例如远程流的代理地址与队列项对不上）时不强行替换，
    // 保留调用方给的列表，避免把播放位置弄丢。
    if (idx < 0) return;
    _songs = q;
    _currentIndex = idx;
  }

  void _initListeners() {
    // 幂等：同一 State 重复调用（或复用了另一个 player）时先摘掉旧订阅，避免叠加。
    _cancelPlayerSubs();
    _playerSubs.add(
      player.stream.playing.listen((playing) {
        if (!mounted) return;
        setState(() => isPlaying = playing);
      }),
    );
    _playerSubs.add(
      player.stream.position.listen((p) {
        if (!mounted || isSeeking) return;
        setState(() => position = p);
        // 桌面歌词由 DesktopLyricController 独立监听更新，此处仅更新内联歌词
        _updateDesktopLyric();
      }),
    );
    _playerSubs.add(
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
      }),
    );
    _playerSubs.add(
      player.stream.completed.listen((completed) {
        if (!completed || !mounted) return;
        _onTrackComplete();
      }),
    );
    _playerSubs.add(
      player.stream.buffering.listen((buffering) {
        if (!mounted) return;
        setState(() => isBuffering = buffering);
      }),
    );
  }

  /// 取消全部播放器事件订阅（`dispose()` 与重复 `_initListeners()` 共用）。
  ///
  /// 对 media_kit 的 broadcast stream 而言 `cancel()` 是**同步摘除订阅者**，无需
  /// await；这里保持同步以贴合 `dispose()` 的 void 约束。
  void _cancelPlayerSubs() {
    if (_playerSubs.isEmpty) return;
    for (final sub in _playerSubs) {
      sub.cancel();
    }
    _playerSubs.clear();
  }

  void _onTrackComplete() {
    if (_repeatMode == 1) {
      // 单曲循环
      player.seek(Duration.zero);
      player.play();
    } else if (_repeatMode == 2 || _isShuffled) {
      // 列表循环 / 随机播放：一直播下去
      _playNext();
    } else if (_allSongs.isNotEmpty) {
      // 列表播放：顺序播放到最后一首后停止
      if (_currentIndex < _allSongs.length - 1) {
        _playNext();
      } else {
        player.seek(Duration.zero);
        player.pause();
      }
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
      // 首次打开时，调用方（FileManagerProvider）已经为当前这首建好了流，地址就在
      // widget.audioPath 里。此时若再按 remote:// 解析一次会**重复建流**，而且调用方
      // 建的那个会话永远不会被 stop —— 表现为每打开一首歌就多一个后台下载在跑。
      // 所以首次直接复用调用方的流；只有切歌（或调用方未提供流）才在这里新建。
      final canReuseInitialStream = !_firstTrackOpened &&
          widget.audioPath.isNotEmpty &&
          !widget.audioPath.startsWith('remote://');
      if (canReuseInitialStream) {
        playPath = widget.audioPath;
        // 记下来，dispose / 切歌时能停掉这个由调用方建立、交给本页接管的会话
        _currentStreamUrl = playPath;
      } else {
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
    }
    _firstTrackOpened = true;

    // For remote files that are being cached, wait until the download completes
    // (download goes to .partial file, then renames to the actual file)
    if (widget.isRemote && !playPath.startsWith('http') && !_currentPath.startsWith('remote://')) {
      final file = File(playPath);
      final initialSize = file.existsSync() ? file.lengthSync() : 0;
      if (initialSize < 1024) { // less than 1KB = placeholder file
        setState(() => _isWaitingForCache = true);
        _cacheCheckTimer = Timer.periodic(const Duration(milliseconds: 500), (timer) async {
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
                // 均衡器在 open 之前挂接（与视频播放器一致，af 随音频链初始化生效）
                _initEqualizer();
                await _openMediaSafe(Media(playPath), play: true);
                player.setRate(_playbackSpeed);
                player.setPitch(_pitch);
                _resetFade();
                _loadLyrics();
                _initEqualizer();
              }
            }
          } catch (_) {}
        });
        return;
      }
    }
    // 均衡器在 open 之前挂接：与视频播放器一致，mpv 初始化音频链时即应用 af 滤镜，
    // 避免 Android 上播放中动态修改 af 不生效的问题。
    _initEqualizer();
    if (!await _openMediaSafe(Media(playPath), play: true)) return;
    player.setRate(_playbackSpeed);
    player.setPitch(_pitch);
    _resetFade();
    // 音频打开成功后再次应用预设（覆盖 open 后 af 被重置的边界情况）
    _initEqualizer();
  }

  /// 停止当前远程流式播放会话
  Future<void> _stopCurrentStream() async {
    if (_currentStreamUrl != null) {
      await RemoteStreamingService.instance.stopStreaming(_currentStreamUrl!);
      _currentStreamUrl = null;
    }
  }

  /// 打开音频文件；若底层文件访问失败（典型为「所有文件管理」权限在清除数据后
  /// 处于幽灵授权状态，media_kit 直接 open 失败），不再让未捕获异常导致应用闪退，
  /// 而是弹出引导对话框，请用户前往设置「关闭并重新开启所有文件管理权限」后重试。
  /// 返回 true 表示已成功发起播放，false 表示失败并已引导用户重新授权。
  Future<bool> _openMediaSafe(Media media, {bool play = true}) async {
    try {
      await player.open(media, play: play);
      return true;
    } catch (e) {
      debugPrint('[ZenFile] audio open failed (likely storage permission): $e');
      if (mounted) _showStoragePermissionDialog();
      return false;
    }
  }

  /// 音频访问失败时的引导：提示重新授予「所有文件管理」权限（与清除数据后
  /// 手动「关闭再开启」该权限即可恢复的行为一致），避免直接闪退。
  void _showStoragePermissionDialog() {
    if (!mounted) return;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: Text(L10n.of(context).msg_grant_full_storage_permission),
        content: const Text(
          '无法访问该音频文件，可能是「所有文件管理」权限未完全生效。\n'
          '请前往系统设置中先关闭、再重新开启该权限后重试。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(L10n.of(context).ui_cancel),
          ),
          FilledButton(
            onPressed: () {
              Navigator.of(ctx).pop();
              const channel = MethodChannel('com.sequl.zenfile/permissions');
              channel
                  .invokeMethod('openManageExternalStorageSettings')
                  .catchError((_) => openAppSettings());
            },
            child: Text(L10n.of(context).ui_open_settings),
          ),
        ],
      ),
    );
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
      final streamUrl = await remoteClient.getStreamUrl(remoteFilePath);
      if (streamUrl != null) {
        // WebDAV 流式播放：保持连接（由 GC 清理）
        return streamUrl;
      }

      // 非 HTTP 流协议（FTP/SFTP 等）：通过本地代理服务器
      // 独立连接用于按需随机读取（拖动进度条），与后台顺序下载分开会话
      final seekClient = FileManagerProvider.createRemoteClient(conn);
      try {
        await seekClient.connect();
        // 取文件大小以支持可 seek 流式（进度条/拖动进度条所需）。
        int? fileSize;
        try {
          final size = await remoteClient.getFileSize(remoteFilePath)
              .timeout(const Duration(seconds: 5));
          if (size > 0) fileSize = size;
        } catch (_) {
          fileSize = null;
        }
        final proxyUrl = await RemoteStreamingService.instance.startStreaming(
          remoteClient, remoteFilePath, fileName,
          fileSize: fileSize,
          seekClient: seekClient,
        );
        return proxyUrl;
      } catch (e) {
        debugPrint('远程流式代理启动失败，回退到下载模式: $e');
        try {
          await seekClient.disconnect();
        } catch (_) {}
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
    // 与 _playNext/_playPrevious 对齐：后台会话下必须同步通知栏与 handler 的队列下标，
    // 否则从队列面板点歌后，通知栏显示的还是上一首，后台切歌也从旧位置算起。
    if (_isBackgroundMode) _updateBackgroundItem();
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
    // 本页即将销毁、不再持有 player ⇒ 撤销登记（**带 player 身份**）。之后通知栏
    // 的「关闭」或换绑其它播放器才可以安全退役它；若还留着登记，player 会被当成
    // 「有人持有」而永远不回收（泄漏一个 mpv 实例 + 解码线程）。
    getAudioHandler().clearForegroundHolds(player);
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
    // ⚠️ 摘掉挂在 player 上的事件订阅：后台播放模式下 player 会被保留（音乐继续
    // 播），不摘掉就会在复用的 player 上越堆越多（见 _playerSubs 声明处）。
    _cancelPlayerSubs();
    // 清理远程流式会话
    _stopCurrentStream();
    if (_isBackgroundMode) {
      // Let audio keep playing in background — don't dispose player
      // 桌面歌词也应保持显示，不随页面关闭而消失
      // DesktopLyricController 继续运行，独立于 widget 生命周期更新歌词
      getAudioHandler().setSkipCallback(null);
      // 后台模式：保留均衡器（player 仍在后台播放），不 detach，
      // 否则切后台后 af 被清空、预设失效变回 Flat
    } else {
      // 非后台模式：停止控制器并隐藏悬浮窗
      DesktopLyricController.instance.stop();
      DesktopLyricService.instance.hide();
      // 同时清掉 skip 回调：后台会话已结束，残留的回调会指向已销毁的 State，
      // 且会让 handler 的 completed 监听误判为「有页面接管」而不自动切歌。
      getAudioHandler().setSkipCallback(null);
      // ⚠️ 先解绑均衡器、等它完成后再销毁播放器（见 _disposePlayerAfterEqDetach）。
      _disposePlayerAfterEqDetach();
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

  /// 将统一的播放模式映射到 _repeatMode / _isShuffled
  void _applyPlaybackMode(int mode) {
    switch (mode) {
      case 0: // 列表播放
        _repeatMode = 0;
        _isShuffled = false;
        break;
      case 1: // 列表循环
        _repeatMode = 2;
        _isShuffled = false;
        break;
      case 2: // 单曲循环
        _repeatMode = 1;
        _isShuffled = false;
        break;
      case 3: // 随机播放
        _repeatMode = 0;
        _isShuffled = true;
        _buildShuffleQueue();
        break;
    }
  }

  void _cyclePlaybackMode() {
    final l10n = L10n.of(context);
    setState(() {
      _playbackMode = (_playbackMode + 1) % 4;
      _applyPlaybackMode(_playbackMode);
    });
    PreferencesService.saveAudioPlaybackMode(_playbackMode);
    final String message;
    switch (_playbackMode) {
      case 0:
        message = l10n.ui_play_mode_sequential;
        break;
      case 1:
        message = l10n.ui_play_mode_list_loop;
        break;
      case 2:
        message = l10n.ui_play_mode_single_loop;
        break;
      case 3:
      default:
        message = l10n.ui_play_mode_shuffle;
        break;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
        backgroundColor: Theme.of(context).colorScheme.primary,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        duration: const Duration(seconds: 1),
      ),
    );
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

  /// 检测歌词是否只是占位文本（如第三方歌词源返回的“无歌词/纯音乐”提示）。
  /// 如果是，则视为无歌词，让 UI 显示多语言提示。
  List<LyricLine>? _sanitizeLyrics(List<LyricLine>? lyrics) {
    if (lyrics == null || lyrics.isEmpty) return lyrics;
    // 只针对单行占位文本
    if (lyrics.length > 1) return lyrics;
    final text = lyrics.first.text.trim();
    const placeholderSubstrings = {
      '此歌曲为没有填词的纯音乐',
      '此歌曲為沒有填詞的純音樂',
      '请您欣赏',
      '請您欣賞',
      '没有填词',
      '沒有填詞',
      '纯音乐',
      '純音樂',
      'This track has no lyrics',
      'No lyrics',
    };
    final lower = text.toLowerCase();
    for (final p in placeholderSubstrings) {
      if (lower.contains(p.toLowerCase())) {
        _lyricsWerePlaceholder = true;
        return null;
      }
    }
    return lyrics;
  }

  /// 歌词用的播放位置：整体偏移后的位置。
  ///
  /// 偏移为「歌词时间轴整体平移量」：把播放位置减去偏移再交给歌词视图，
  /// 正值让歌词出现得更晚（歌词慢了），负值让歌词更早（歌词快了）。
  /// `findCurrentLineIndex` / `graphemeFillAt` 对负值均安全（无当前行）。
  Duration get _lyricPosition =>
      Duration(milliseconds: position.inMilliseconds - _lyricOffsetMs);

  /// 刷新生效的歌词偏移：单曲覆盖优先，否则全局；同步给桌面歌词。
  void _refreshLyricOffset() {
    final ms = PreferencesService.getLyricOffsetForSong(_currentPath) ??
        PreferencesService.getLyricOffsetGlobal();
    DesktopLyricController.instance.setOffsetMs(ms);
    if (!mounted) return;
    if (ms != _lyricOffsetMs) {
      setState(() => _lyricOffsetMs = ms);
    }
  }

  /// 自动加载当前歌曲的歌词
  void _loadLyrics() {
    final audioPath = _currentPath;
    final generation = ++_lyricsLoadGeneration;
    final title = _currentTitle;
    final artist = _getDisplayArtist();

    // 切歌：按新歌曲重算歌词整体偏移（单曲覆盖 / 全局）。
    _refreshLyricOffset();

    setState(() {
      _lyrics = null;
      _isLoadingLyrics = true;
      _lyricsWerePlaceholder = false;
    });

    // 异步加载歌词
    Future(() async {
      // 1. 先尝试本地加载
      final loaded = LyricParser.loadLyricForAudio(audioPath);

      // 只应用最新一次加载的结果，避免切歌竞态覆盖
      if (generation != _lyricsLoadGeneration) return;

      if (loaded != null) {
        final sanitized = _sanitizeLyrics(loaded.lyrics);
        if (mounted) {
          setState(() {
            _lyrics = sanitized;
            _isLoadingLyrics = false;
          });
          if (_desktopLyricEnabled) {
            DesktopLyricController.instance.setLyrics(sanitized);
          }
        }
        return;
      }

      // 2. 本地未找到歌词 — 不再自动在线搜索，保持无歌词状态
      //    用户可通过歌词面板的「在线搜索」按钮手动触发搜索
      debugPrint('[LyricSearch] 本地未找到歌词，跳过自动在线搜索: $title - $artist');
      if (mounted && generation == _lyricsLoadGeneration) {
        setState(() {
          _lyrics = null;
              _isLoadingLyrics = false;
        });
        if (_desktopLyricEnabled) {
          DesktopLyricController.instance.setLyrics(null);
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
          _lyricsDisplayMode = 2;
        });
        // 用户手动指定了歌词文件：切到半屏展示，并记住该模式。
        PreferencesService.saveLyricsDisplayMode(2);
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

  /// 弹出在线歌词搜索对话框：先搜索，列出候选结果，由用户手动选择，
  /// 避免同名不同歌手时自动匹配错误。
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
    List<LyricSearchResult> results = [];
    var view = 'form'; // form | results | notFound

    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) {
          // 执行搜索，列出候选结果
          Future<void> doSearch() async {
            final title = titleController.text.trim();
            final artist = artistController.text.trim();
            if (title.isEmpty) {
              setDialogState(() => errorMessage = l10n.ui_lyrics_not_found_online);
              return;
            }
            setDialogState(() {
              isSearching = true;
              errorMessage = null;
            });
            // 先按 歌名+歌手 搜，结果少则仅按歌名搜
            var list = await LyricSearchService.search('$title $artist');
            if (list.isEmpty) list = await LyricSearchService.search(title);
            if (!ctx.mounted) return;
            setDialogState(() {
              isSearching = false;
              if (list.isEmpty) {
                view = 'notFound';
              } else {
                results = list;
                view = 'results';
              }
            });
          }

          // 用户手动选择某一首后下载
          Future<void> pickSong(LyricSearchResult song) async {
            setDialogState(() => isSearching = true);
            final download = await LyricSearchService.downloadForSong(
              song: song,
              audioPath: _currentPath,
            );
            if (!ctx.mounted) return;
            if (download != null) {
              Navigator.pop(ctx, true);
            } else {
              setDialogState(() {
                isSearching = false;
                errorMessage = l10n.ui_lyrics_not_found_online;
              });
            }
          }

          // 主体内容
          Widget body;
          if (view == 'results') {
            body = SizedBox(
              width: 320,
              height: 380,
              child: ListView.separated(
                shrinkWrap: true,
                itemCount: results.length,
                separatorBuilder: (_, __) => Divider(color: Colors.white12, height: 1),
                itemBuilder: (_, i) {
                  final song = results[i];
                  final subParts = <String>[
                    if (song.singer.isNotEmpty) song.singer,
                    if (song.albumName != null && song.albumName!.isNotEmpty) song.albumName!,
                  ];
                  return ListTile(
                    contentPadding: const EdgeInsets.symmetric(horizontal: 8),
                    title: Text(
                      song.title,
                      style: TextStyle(
                        color: isDark ? Colors.white : theme.colorScheme.onSurface,
                        fontSize: 15,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: subParts.isNotEmpty
                        ? Text(
                            subParts.join(' · '),
                            style: TextStyle(color: Colors.white54, fontSize: 12),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          )
                        : null,
                    trailing: isSearching
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.chevron_right, color: Colors.white38),
                    onTap: isSearching ? null : () => pickSong(song),
                  );
                },
              ),
            );
          } else if (view == 'notFound') {
            body = SizedBox(
              width: 300,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const SizedBox(height: 16),
                  Icon(Icons.search_off_rounded, color: Colors.orange.shade400, size: 40),
                  const SizedBox(height: 12),
                  Text(
                    l10n.ui_lyrics_not_found_online,
                    style: TextStyle(
                      color: isDark ? Colors.white70 : theme.colorScheme.onSurface.withValues(alpha: 0.6),
                    ),
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            );
          } else {
            body = SizedBox(
              width: 300,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  TextField(
                    controller: titleController,
                    enabled: !isSearching,
                    style: TextStyle(color: isDark ? Colors.white : theme.colorScheme.onSurface),
                    decoration: InputDecoration(
                      labelText: l10n.ui_lyric_search_song_title,
                      labelStyle: TextStyle(color: theme.colorScheme.primary.withValues(alpha: 0.7)),
                      filled: true,
                      fillColor: isDark ? Colors.white.withValues(alpha: 0.05) : theme.colorScheme.onSurface.withValues(alpha: 0.04),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(16),
                        borderSide: BorderSide.none,
                      ),
                      prefixIcon: Icon(Icons.music_note_rounded, color: theme.colorScheme.primary.withValues(alpha: 0.6), size: 20),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: artistController,
                    enabled: !isSearching,
                    style: TextStyle(color: isDark ? Colors.white : theme.colorScheme.onSurface),
                    decoration: InputDecoration(
                      labelText: l10n.ui_lyric_search_artist,
                      labelStyle: TextStyle(color: theme.colorScheme.primary.withValues(alpha: 0.7)),
                      filled: true,
                      fillColor: isDark ? Colors.white.withValues(alpha: 0.05) : theme.colorScheme.onSurface.withValues(alpha: 0.04),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(16),
                        borderSide: BorderSide.none,
                      ),
                      prefixIcon: Icon(Icons.person_rounded, color: theme.colorScheme.primary.withValues(alpha: 0.6), size: 20),
                    ),
                  ),
                  if (isSearching) ...[
                    const SizedBox(height: 20),
                    const Center(child: CircularProgressIndicator()),
                    const SizedBox(height: 8),
                    Text(
                      l10n.ui_lyrics_searching,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: isDark ? Colors.white70 : theme.colorScheme.onSurface.withValues(alpha: 0.5),
                        fontSize: 13,
                      ),
                    ),
                  ],
                  if (errorMessage != null && !isSearching) ...[
                    const SizedBox(height: 16),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                      decoration: BoxDecoration(
                        color: Colors.orangeAccent.shade100.withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: Colors.orangeAccent.shade100.withValues(alpha: 0.3)),
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
            );
          }

          // 操作按钮
          List<Widget> actions;
          if (view == 'results' || view == 'notFound') {
            actions = [
              TextButton(
                onPressed: isSearching
                    ? null
                    : () => setDialogState(() {
                          view = 'form';
                          results = [];
                          errorMessage = null;
                        }),
                child: Text(l10n.ui_back, style: TextStyle(color: isDark ? Colors.white70 : theme.colorScheme.onSurface.withValues(alpha: 0.6))),
              ),
            ];
          } else {
            actions = [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: Text(l10n.ui_cancel, style: TextStyle(color: isDark ? Colors.white70 : theme.colorScheme.onSurface.withValues(alpha: 0.6))),
              ),
              TextButton(
                onPressed: isSearching ? null : doSearch,
                child: Text(l10n.ui_search_lyrics_online, style: TextStyle(color: theme.colorScheme.primary, fontWeight: FontWeight.bold)),
              ),
            ];
          }

          return AlertDialog(
            backgroundColor: isDark ? const Color(0xFF1E1E2E) : theme.colorScheme.surface,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
            title: Row(
              children: [
                Icon(Broken.music_filter, color: theme.colorScheme.primary, size: 22),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    l10n.ui_search_lyrics_online,
                    style: TextStyle(
                      color: isDark ? Colors.white : theme.colorScheme.onSurface,
                      fontWeight: FontWeight.bold,
                      fontSize: 18,
                    ),
                  ),
                ),
              ],
            ),
            content: body,
            actions: actions,
          );
        },
      ),
    );

    // 清理控制器
    titleController.dispose();
    artistController.dispose();

    if (!mounted || result != true) return;

    // 对话框返回 true 表示下载成功，reload lyrics
    _loadLyrics();
  }

  /// 歌词显示模式菜单（歌词按钮点击后向上弹出）：
  /// 第一组为显示模式（关闭 / 单行 / 半屏 / 全屏），分隔线之下为动画风格。
  /// 显示模式选中即关闭弹窗；动画风格改成下拉框，选中后留在弹窗内可连续比较。
  void _showLyricModeMenu() {
    final l10n = L10n.of(context);
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      // 下拉框展开时菜单最高 380dp，加上上方 4 个显示模式条目会超过默认的
      // 9/16 屏高 ⇒ 放开高度限制 + 内部滚动兜底（小屏 / 横屏）。
      isScrollControlled: true,
      builder: (ctx) {
        final theme = Theme.of(ctx);
        final isDark = theme.brightness == Brightness.dark;
        final surface =
            isDark ? const Color(0xFF1E1E2E) : theme.colorScheme.surface;
        final titleColor = isDark ? Colors.white : theme.colorScheme.onSurface;

        Widget item({
          required IconData icon,
          required String title,
          required bool selected,
          required VoidCallback onTap,
          String? desc,
        }) {
          return ListTile(
            leading: Icon(icon,
                color: selected
                    ? Colors.deepPurpleAccent
                    : titleColor.withValues(alpha: 0.7)),
            title: Text(title,
                style: TextStyle(
                    color: titleColor, fontWeight: FontWeight.w600)),
            subtitle: desc == null
                ? null
                : Text(desc,
                    style: TextStyle(
                        color: titleColor.withValues(alpha: 0.55),
                        fontSize: 12)),
            trailing: selected
                ? const Icon(Icons.check_circle_rounded,
                    color: Colors.deepPurpleAccent)
                : null,
            onTap: onTap,
          );
        }

        // 用 StatefulBuilder 承载「下拉框选中即生效」的局部刷新：弹窗保持
        // 打开，收起态立刻显示新风格、说明文字同步更新。
        Widget buildSheet(StateSetter setSheet) => SafeArea(
          child: Container(
            decoration: BoxDecoration(
              color: surface,
              borderRadius:
                  const BorderRadius.vertical(top: Radius.circular(24)),
            ),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
                    child: Row(
                      children: [
                        const Icon(Broken.document,
                            color: Colors.deepPurpleAccent, size: 20),
                        const SizedBox(width: 8),
                        Text(l10n.lyric_display,
                            style: TextStyle(
                                color: titleColor,
                                fontSize: 16,
                                fontWeight: FontWeight.w700)),
                      ],
                    ),
                  ),
                  item(
                    icon: Icons.block_flipped,
                    title: l10n.lyric_mode_off,
                    selected: _lyricsDisplayMode == 0,
                    onTap: () => _setLyricDisplayMode(ctx, 0),
                  ),
                  item(
                    icon: Icons.short_text_rounded,
                    title: l10n.lyric_mode_single,
                    selected: _lyricsDisplayMode == 1,
                    onTap: () => _setLyricDisplayMode(ctx, 1),
                  ),
                  item(
                    icon: Icons.view_agenda_outlined,
                    title: l10n.lyric_mode_half,
                    selected: _lyricsDisplayMode == 2,
                    onTap: () => _setLyricDisplayMode(ctx, 2),
                  ),
                  item(
                    icon: Icons.fullscreen_rounded,
                    title: l10n.lyric_mode_full,
                    selected: _lyricsDisplayMode == 3,
                    onTap: () => _setLyricDisplayMode(ctx, 3),
                  ),
                  // ── 分隔线：上方为显示模式，下方为动画风格 ────────────
                  Container(
                    height: 1,
                    margin: const EdgeInsets.symmetric(
                      horizontal: 20,
                      vertical: 8,
                    ),
                    color: titleColor.withValues(alpha: 0.08),
                  ),
                  // ── 动画风格：下拉框（收起态只显示当前选中的风格） ────────
                  // 与「音效与均衡器」页同一套观感。11 种风格平铺在任何手机上都
                  // 会溢出（新增的 5 种被挤到屏幕外、根本点不到），下拉框固定
                  // 只占一行，选中后自动收起并同步下方说明文字。
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 6, 20, 0),
                    child: Row(
                      children: [
                        const Icon(
                          Icons.animation_rounded,
                          color: Colors.deepPurpleAccent,
                          size: 18,
                        ),
                        const SizedBox(width: 8),
                        Text(
                          l10n.lyric_animation_style,
                          style: TextStyle(
                            color: titleColor.withValues(alpha: 0.75),
                            fontSize: 13,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
                    child: LyricStyleDropdown(
                      value: _lyricStyle,
                      isDark: isDark,
                      foreground: titleColor,
                      onChanged: (style) =>
                          _applyLyricStyleInline(style, setSheet),
                    ),
                  ),
                  const SizedBox(height: 8),
                ],
              ),
            ),
          ),
        );

        return StatefulBuilder(
          builder: (ctx, setSheet) => buildSheet(setSheet),
        );
      },
    );
  }

  /// 应用选中的歌词显示模式（0=关闭 / 1=单行 / 2=半屏 / 3=全屏）。
  /// 0~2 持久化，下次进入播放页恢复；3 为瞬时态、不落盘——
  /// 选中即推全屏路由，退出后回落到之前持久化的模式（见 [_showLyricsPanel]）。
  void _setLyricDisplayMode(BuildContext ctx, int mode) {
    Navigator.pop(ctx);
    if (mode == 3) {
      setState(() => _lyricsDisplayMode = 3);
      _showLyricsPanel();
      return;
    }
    setState(() => _lyricsDisplayMode = mode);
    PreferencesService.saveLyricsDisplayMode(mode);
  }

  /// 从下拉框选择动画风格：**不关闭弹窗**，按「当前显示模式」应用——
  /// 单行 / 半屏 / 全屏各自生效，不再强制拉全屏。当前为关闭时回落到
  /// 半屏，让所选风格立即可见。
  ///
  /// [setSheet] 只用于刷新弹窗内那一份 [_lyricStyle]：下拉框收起态与说明
  /// 文字都读它。留窗的用意是让用户能连续比较几种风格（风格是即时生效
  /// 的视觉偏好），点空白处即可关闭。
  void _applyLyricStyleInline(LyricAnimationStyle style, StateSetter setSheet) {
    final int base = _lyricsDisplayMode == 0 ? 2 : _lyricsDisplayMode;
    setState(() {
      _lyricStyle = style;
      _lyricsDisplayMode = base;
    });
    // 弹窗是独立的 StatefulBuilder 子树，页面 setState 刷不到它 ⇒ 必须
    // 显式刷新一次，否则下拉框收起态仍显示旧风格、说明文字也不更新。
    setSheet(() {});
    PreferencesService.saveLyricAnimationStyleName(style.name);
    // base 理论上只可能是 1/2（3 时全屏路由已遮挡本页菜单）；防御性 clamp，
    // 避免把瞬时态 3 写进持久化（读取端会被裁成 0）。
    PreferencesService.saveLyricsDisplayMode(base.clamp(0, 2));
  }

  // ─── 桌面歌词悬浮窗 ────────────────────────────────────────────────────

  /// 获取桌面歌词颜色（ARGB int 格式，用于原生层渲染）
  /// 返回 [highlightColor, normalColor]。
  ///
  /// ⚠️ 配色口径与屏幕歌词一致，**不跟随主题色**：已唱部分用「当前播放」
  /// 色，未唱部分用「未播放」色（压到 65% 不透明度，保留层次）。
  /// 早前取 `colorScheme.primary`，换主题就把桌面歌词染成主题色，与用户在
  /// 歌词设置里选的配色完全脱节。
  List<int> _getDesktopLyricColors() {
    final current =
        PreferencesService.getLyricColorCurrent() ?? kLyricColorCurrentDefault;
    final unplayed =
        PreferencesService.getLyricColorUnplayed() ??
        kLyricColorUnplayedDefault;
    return [current.toARGB32(), unplayed.withValues(alpha: 0.65).toARGB32()];
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
  Future<void> _toggleDesktopLyric() async {
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

    // 从通知栏点击返回前台：同步 UI 与后台播放器的状态
    // （通知栏切歌/暂停后，handler 的 player 状态可能与 UI 显示不一致）
    if (_isBackgroundMode && player != null) {
      setState(() {
        isPlaying = player.state.playing;
        position = player.state.position;
        duration = player.state.duration;
      });
      _updateBackgroundItem();
    }

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
    final index = LyricParser.findCurrentLineIndex(_lyrics!, _lyricPosition);
    if (index < 0 || index >= _lyrics!.length) return null;
    return _lyrics![index];
  }

  /// 构建单行歌词显示（支持逐字高亮）
  Widget _buildSingleLineLyrics(Color accent, ThemeData theme, bool isDark) {
    if (_lyricsDisplayMode != 1) return const SizedBox.shrink();
    final line = _getCurrentLyricLine();
    return GestureDetector(
      onTap: _showLyricsPanel,
      child: SizedBox(
        width: double.infinity,
        height: 44,
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 300),
          // 单行歌词的 PV/ECHO 唱字特效要向上穿越封面卡片显示：默认
          // layoutBuilder 的 Stack 与 SizeTransition 自带裁剪都会把溢出
          // 特效裁掉——这里自定义不裁剪的 Stack，过渡改为淡入 + 轻微
          // 上移（Transform 不裁剪，观感与原来的尺寸过渡接近）。
          layoutBuilder: (currentChild, previousChildren) => Stack(
            clipBehavior: Clip.none,
            alignment: Alignment.center,
            children: <Widget>[...previousChildren, ?currentChild],
          ),
          transitionBuilder: (child, animation) => FadeTransition(
            opacity: animation,
            child: Transform.translate(
              offset: Offset(0, 8 * (1 - animation.value)),
              child: child,
            ),
          ),
          child: line != null
              ? SizedBox(
                  key: ValueKey<String>(line.text),
                  width: double.infinity,
                  height: 44,
                  child: Center(
                    child: SingleLineLyricSweep(
                      lyrics: _lyrics!,
                      position: _lyricPosition,
                      accentColor: accent,
                      style: _lyricStyle,
                      isPlaying: isPlaying,
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
                        _lyricsWerePlaceholder
                            ? L10n.of(context).ui_instrumental_track_hint
                            : L10n.of(context).ui_no_lyrics_found,
                        textAlign: TextAlign.center,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                          color: (isDark ? Colors.white : theme.colorScheme.onSurface).withValues(alpha: 0.35),
                        ),
                      ),
                    ),
        ),
      ),
    );
  }

  /// 构建 artwork 或完整内联歌词视图
  Widget _buildArtworkOrLyrics(Color accent, ThemeData theme, bool isDark) {
    if (_lyricsDisplayMode != 2) {
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
            onLongPress: _showEqualizerSheet,
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
      onLongPress: _showEqualizerSheet,
      child: Container(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.35,
        ),
        decoration: BoxDecoration(
          color: (isDark ? Colors.white : Colors.black).withValues(alpha: 0.03),
          borderRadius: BorderRadius.circular(20),
        ),
        child: _isLoadingLyrics
            ? const Center(child: CircularProgressIndicator())
            : (_lyrics != null && _lyrics!.isNotEmpty
                ? LyricsViewWidget(
                    lyrics: _lyrics!,
                    position: _lyricPosition,
                    accentColor: accent,
                    style: _lyricStyle,
                    isPlaying: isPlaying,
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
              color: (isDark ? Colors.white : theme.colorScheme.onSurface).withValues(alpha: 0.2),
            ),
            const SizedBox(height: 12),
            Text(
              _lyricsWerePlaceholder
                  ? L10n.of(context).ui_instrumental_track_hint
                  : L10n.of(context).ui_no_lyrics_found,
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.bold,
                color: (isDark ? Colors.white : theme.colorScheme.onSurface).withValues(alpha: 0.5),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              L10n.of(context).ui_lyrics_auto_load_hint,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 12,
                height: 1.5,
                color: (isDark ? Colors.white : theme.colorScheme.onSurface).withValues(alpha: 0.35),
              ),
            ),
            const SizedBox(height: 16),
            TextButton.icon(
              onPressed: _showLyricSearchDialog,
              icon: const Icon(Icons.search_rounded, size: 18),
              label: Text(L10n.of(context).ui_search_lyrics_online, style: const TextStyle(fontWeight: FontWeight.w600)),
              style: TextButton.styleFrom(
                foregroundColor: accent,
                backgroundColor: accent.withValues(alpha: 0.1),
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              ),
            ),
            const SizedBox(height: 12),
            TextButton.icon(
              onPressed: _selectLyricFile,
              icon: const Icon(Icons.folder_open_rounded, size: 18),
              label: Text(L10n.of(context).ui_select_lyrics_file, style: const TextStyle(fontWeight: FontWeight.w600)),
              style: TextButton.styleFrom(
                foregroundColor: accent,
                backgroundColor: accent.withValues(alpha: 0.1),
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// current lyric animation style localized name (more-menu subtitle).
  String _lyricStyleLabel() {
    final l10n = L10n.of(context);
    switch (_lyricStyle) {
      case LyricAnimationStyle.classic:
        return l10n.lyric_style_classic;
      case LyricAnimationStyle.typewriter:
        return l10n.lyric_style_typewriter;
      case LyricAnimationStyle.meteor:
        return l10n.lyric_style_meteor;
      case LyricAnimationStyle.pv:
        return l10n.lyric_style_pv;
      case LyricAnimationStyle.echo:
        return l10n.lyric_style_echo;
      case LyricAnimationStyle.drop:
        return l10n.lyric_style_drop;
      case LyricAnimationStyle.burst:
        return l10n.lyric_style_burst;
      case LyricAnimationStyle.cube:
        return l10n.lyric_style_cube;
      case LyricAnimationStyle.punch:
        return l10n.lyric_style_punch;
      case LyricAnimationStyle.wave:
        return l10n.lyric_style_wave;
      case LyricAnimationStyle.mixed:
        return l10n.lyric_style_mixed;
    }
  }

  /// 歌词偏移弹窗的实时预览：只改内存（不落盘），单行/内联/全屏歌词
  /// 立即按新偏移渲染；取消时弹窗会以原值回调恢复。
  void _previewLyricOffset(int ms) {
    DesktopLyricController.instance.setOffsetMs(ms);
    if (!mounted || ms == _lyricOffsetMs) return;
    setState(() => _lyricOffsetMs = ms);
  }

  /// 打开歌词设置页（桌面歌词 / 歌词颜色 / 歌词偏移 / 在线搜索 / 本地导入）。
  void _showLyricSettingsPage() {
    Navigator.of(context)
        .push(
          MaterialPageRoute(
            builder: (_) => LyricSettingsPage(
              desktopLyricEnabled: _desktopLyricEnabled,
              onToggleDesktopLyric: _toggleDesktopLyric,
              onSearchOnlineLyrics: _showLyricSearchDialog,
              onImportLocalLyrics: _selectLyricFile,
              songPath: _currentPath,
              songTitle: _currentTitle,
              onPreviewLyricOffset: _previewLyricOffset,
            ),
          ),
        )
        .then((_) {
          // 设置页可改桌面歌词开关 / 歌词偏移，返回后同步本地状态。
          if (!mounted) return;
          setState(() {
            _desktopLyricEnabled =
                PreferencesService.getDesktopLyricEnabled();
          });
          _refreshLyricOffset();
          // 设置页还能改「三色」：桌面歌词正在显示时必须把新配色推给
          // 原生层，否则要等下次重开桌面歌词才变色（看着像没生效）。
          if (_desktopLyricEnabled &&
              DesktopLyricController.instance.isRunning) {
            final colors = _getDesktopLyricColors();
            DesktopLyricController.instance.setColors(
              highlightColor: colors[0],
              normalColor: colors[1],
            );
          }
        });
  }

  /// 打开全屏歌词页（真正全屏路由；退出后复位显示模式）。
  void _showLyricsPanel() {
    Navigator.of(context)
        .push(
          MaterialPageRoute(
            fullscreenDialog: true,
            builder: (_) => _FullScreenLyricsPage(
              player: player,
              lyrics: _lyrics,
              title: _currentTitle,
              artist: _getDisplayArtist(),
              accentColor: Theme.of(context).colorScheme.primary,
              isLoading: _isLoadingLyrics,
              onSelectLyricFile: _selectLyricFile,
              onSearchOnline: _showLyricSearchDialog,
              songPath: _currentPath,
              lyricOffsetMs: _lyricOffsetMs,
            ),
          ),
        )
        .then((_) {
          // 退出全屏后：模式 3 是瞬时态，回落到用户之前选择的显示模式
          // （从单行/半屏临时进入时不改动用户当前模式；从菜单选「全屏显示」
          // 进入的，回到菜单里选中的那个 0/1/2 模式）。
          if (mounted && _lyricsDisplayMode == 3) {
            setState(() {
              _lyricsDisplayMode = PreferencesService.getLyricsDisplayMode();
            });
          }
          // 全屏页可切换动画风格，退出后同步回播放页（单行/半屏也用该风格）。
          if (mounted) {
            setState(() {
              _lyricStyle = LyricAnimationStyle.fromName(
                  PreferencesService.getLyricAnimationStyleName());
            });
          }
          // 全屏页可调整歌词偏移，退出后按偏好重算（含桌面歌词同步）。
          _refreshLyricOffset();
        });
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
            hintStyle: TextStyle(color: Colors.white.withValues(alpha: 0.4)),
            filled: true,
            fillColor: Colors.white.withValues(alpha: 0.05),
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

  // ─── 均衡器状态（mpv 内置 equalizer 滤波器）──────────────────────────
  final AudioEqualizerService _eqService = AudioEqualizerService();
  int _eqRetryCount = 0;
  EqPreset _eqPreset = EqPreset.flat;

  /// 应用已保存的均衡器预设（每次打开音频前/后调用）。
  /// 使用 mpv 内置 equalizer 音频滤波器，直接在 libmpv 管线内处理，全设备通用。
  ///
  /// 修复（反馈 #1）：此前仅在首次 _initEqualizer 时尝试 attach，若当时
  /// player.platform 尚未就绪（非 NativePlayer）则整段跳过、_eqReady 永久为
  /// false，导致之后点预设也因 _nativePlayer 为 null 而静默失败（需重启才生效）。
  ///
  /// 修复（反馈 #2）：均衡器在音频播放器不生效。视频播放器在 open 之前 attach
  /// af 滤镜，mpv 初始化音频链时即应用，故生效；而本播放器此前在 open 成功之后
  /// 才 attach，Android 上播放中动态修改 af 经常不生效。现改为：
  /// ① 每次播放都重新 attach 到当前 platform（防止 player 实例变化导致旧引用）；
  /// ② attach 时机前移到 open 之前（与视频播放器一致，af 随音频链初始化生效）；
  /// ③ platform 未就绪时有限重试（最多 3 次），避免无限递归。
  Future<void> _initEqualizer() async {
    try {
      final platform = player.platform;
      if (platform is NativePlayer) {
        _eqRetryCount = 0;
        // 每次播放都重新 attach 到当前 platform
        await _eqService.attach(platform);
        // 每次播放都恢复上次使用的预设（覆盖 open 后 af 被重置的边界情况）
        final savedKey = PreferencesService.getAudioEqPreset();
        _eqPreset = savedKey.isNotEmpty
            ? EqPresetExtension.fromKey(savedKey)
            : EqPreset.flat;
        await _eqService.applyPreset(_eqPreset);
      } else {
        // platform 尚未就绪：有限重试，避免无限递归
        if (_eqRetryCount < 3) {
          _eqRetryCount++;
          await Future.delayed(const Duration(milliseconds: 300));
          if (mounted) _initEqualizer();
        } else {
          debugPrint('[EQ] 均衡器初始化重试耗尽，跳过');
        }
      }
    } catch (e) {
      debugPrint('[EQ] 初始化失败: $e');
    }
  }

  /// 释放均衡器资源并销毁播放器（仅完全停止播放时调用，后台模式保留以免变回 Flat）。
  ///
  /// ⚠️ 顺序铁律：必须**先等均衡器解绑完成**再 `player.dispose()`。
  /// `detach()` 内部要 `setProperty('af','')`，而 media_kit 的 `setProperty` 有内部
  /// `await`（等待播放器初始化）且**不持锁**；旧实现是 `player.dispose()` 之后才调
  /// detach ⇒ 对着已被释放的 mpv ctx 发原生调用 = use-after-free
  /// ⇒ CRASH_NATIVE（Dart 侧拿不到栈，报告只写「系统未提供 trace」）。
  void _disposePlayerAfterEqDetach() {
    final target = player;
    // ⚠️ 先声明作废再异步销毁：`MpvAudioOutputService` 的延迟诊断（3s/8s 后回读
    // mpv 属性）可能正持有这个 player，销毁后它发的**裸原生调用**就是
    // use-after-free ⇒ CRASH_NATIVE（Dart 侧无栈，报告只写「系统未提供 trace」）。
    MpvAudioOutputService.abandon(target);
    unawaited(
      _eqService.detach().whenComplete(() {
        try {
          target.dispose();
        } catch (_) {}
      }),
    );
  }

  /// 音效与均衡器面板：与歌词显示按钮一致，从底部弹出（showModalBottomSheet）。
  ///
  /// 「音频输出（AO）模式」与「均衡器预设」用下拉框呈现：点击展开全部选项、
  /// 选择后自动收起，收起态只显示当前选中项。
  ///
  /// 播放器页面 tune 按钮（`onShowEqualizer`）与三点菜单都走本方法，状态源
  /// 同一（[_eqPreset] + `PreferencesService`），两处入口天然双向同步。
  void _showEqualizerSheet() {
    final mediaQuery = MediaQuery.of(context);
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF1E1E2E),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setModalState) {
          return DefaultTextStyle(
            style: const TextStyle(color: Colors.white),
            child: Padding(
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
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // ── 标题 ──
                      Row(
                        children: [
                          const Icon(Icons.equalizer_rounded, color: Colors.deepPurpleAccent),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              L10n.of(context).msgb7c87215,
                              style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 18),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      // ── 音频输出（AO）兼容模式（兼容免 Root 音效软件） ──
                      Text(L10n.of(dialogContext).audio_opensles_title, style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w600)),
                      const SizedBox(height: 2),
                      Text(L10n.of(dialogContext).audio_opensles_desc, style: const TextStyle(color: Colors.white54, fontSize: 11)),
                      const SizedBox(height: 8),
                      // 档位名（Auto / AudioTrack / OpenSL ES）是产品/技术名，
                      // 各语言不译，故刻意不进 l10n；下拉框收起态只显示当前
                      // 档位，切换后对**正在播放的**播放器立即生效（见
                      // _applyAudioOutputToReusedPlayer）。
                      _aoModeDropdown(setModalState),
                      const SizedBox(height: 12),
                      // ── 均衡器预设（实时生效） ──
                      Text(L10n.of(dialogContext).eq_presets, style: const TextStyle(color: Colors.white70, fontSize: 13, fontWeight: FontWeight.w600)),
                      const SizedBox(height: 8),
                      _eqPresetDropdown(setModalState),
                      const SizedBox(height: 16),
                      // ── 播放速度 ──
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(L10n.of(dialogContext).msgc16eed0e, style: const TextStyle(color: Colors.white70, fontSize: 15)),
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
                      const SizedBox(height: 8),
                      // ── 音调 ──
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(L10n.of(dialogContext).ui_pitch_adjustment, style: const TextStyle(color: Colors.white70, fontSize: 15)),
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
                      // ── 重置 ──
                      SizedBox(
                        width: double.infinity,
                        child: OutlinedButton.icon(
                          icon: const Icon(Icons.restart_alt_rounded, color: Colors.white70, size: 18),
                          label: Text(L10n.of(dialogContext).ui_restore_default, style: const TextStyle(color: Colors.white70)),
                          style: OutlinedButton.styleFrom(
                            side: BorderSide(color: Colors.white.withValues(alpha: 0.2)),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                          ),
                          onPressed: () {
                            setModalState(() {
                              _playbackSpeed = 1.0;
                              _pitch = 1.0;
                              _eqPreset = EqPreset.flat;
                            });
                            setState(() {});
                            player.setRate(1.0);
                            player.setPitch(1.0);
                            _eqService.reset();
                            PreferencesService.saveAudioEqPreset('flat');
                          },
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  /// 音频输出（AO）档位热应用。
  ///
  /// 标签用技术名（`AudioTrack` / `OpenSL ES`），各语言不译，所以不进 l10n。
  /// 对**当前正在播放的** Player 立即应用 AO 档位。
  ///
  /// 两个必须走它的场景：
  /// 1. 用户在均衡器面板切档位 —— 只存偏好不会有任何听感变化（AO 是音频
  ///    输出路径、不是音质），必须热应用才谈得上"生效"；
  /// 2. 复用已有 Player（`existingPlayer` / 后台 player）进入本页 —— 该路径
  ///    **不经过** `configureBeforeOpen`，档位此前完全失效。
  ///
  /// 全程吞异常：档位应用**绝不能**影响正常播放；诊断日志由服务内部负责。
  void _applyAudioOutputToReusedPlayer(String tag) {
    try {
      unawaited(MpvAudioOutputService.applyToRunningPlayer(
        player,
        mode: PreferencesService.getAudioOutputMode(),
        tag: tag,
      ));
    } catch (_) {
      // 忽略：档位应用失败不应影响播放
    }
  }

  /// 语义（真机实测定稿，见 [MpvAoMode]）：`Auto (AudioTrack)` / `AudioTrack 16-bit`
  /// = 链 `audiotrack,opensles` + 固定会话号 + 会话广播 ⇒ 免 Root 音效软件能接管；
  /// `OpenSL ES` = 链 `opensles,audiotrack`，会话号由系统分配 ⇒ **无法**被音效软件
  /// 接管（仅作 audiotrack 建不起来时的兜底）。
  /// 下拉框形态：收起态只显示当前档位，点击展开全部档位、选择后自动收起
  /// （DropdownButton 默认行为），替代原先铺满两行的档位芯片。
  Widget _aoModeDropdown(StateSetter setModalState) {
    final current = PreferencesService.getAudioOutputMode();
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: const Color(0xFF2A2A3E),
        borderRadius: BorderRadius.circular(12),
      ),
      child: DropdownButton<MpvAoMode>(
        value: current,
        isExpanded: true,
        underline: const SizedBox.shrink(),
        dropdownColor: const Color(0xFF2A2A3E),
        iconEnabledColor: Colors.white70,
        style: const TextStyle(color: Colors.white, fontSize: 13),
        items: [
          for (final mode in MpvAoMode.values)
            DropdownMenuItem(
              value: mode,
              child: Text(mode.label, style: const TextStyle(fontSize: 13, color: Colors.white)),
            ),
        ],
        onChanged: (mode) {
          if (mode == null || mode == current) return;
          setModalState(() {});
          PreferencesService.saveAudioOutputMode(mode);
          // ⚠️ 必须**立即**对正在播放的播放器热应用：档位改的是 AO（音频输出
          // 路径），只有音频输出重建时才生效。只存偏好而不应用，「切档位」在
          // 听感上会毫无变化（AO 不是音质），体感等同功能失效 —— 真机反馈
          // 「切换了 4 个模式没有任何效果」。热切换会有极短暂音。
          _applyAudioOutputToReusedPlayer('audio-switch');
          // 同步页面侧状态：下一次从任一入口（tune 按钮 / 三点菜单）打开
          // 面板都读同一偏好，双向一致。
          setState(() {});
        },
      ),
    );
  }

  /// 均衡器预设下拉框：收起态只显示当前预设，点击展开全部、选择后自动收起；
  /// 选择即实时应用到 mpv 内置均衡器并落盘偏好。
  Widget _eqPresetDropdown(StateSetter setModalState) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: const Color(0xFF2A2A3E),
        borderRadius: BorderRadius.circular(12),
      ),
      child: DropdownButton<EqPreset>(
        value: _eqPreset,
        isExpanded: true,
        underline: const SizedBox.shrink(),
        dropdownColor: const Color(0xFF2A2A3E),
        iconEnabledColor: Colors.white70,
        style: const TextStyle(color: Colors.white, fontSize: 13),
        items: [
          for (final preset in EqPreset.values)
            DropdownMenuItem(
              value: preset,
              child: Text(
                preset.labelL10n(L10n.of(context)),
                style: const TextStyle(fontSize: 13, color: Colors.white),
                overflow: TextOverflow.ellipsis,
              ),
            ),
        ],
        onChanged: (preset) {
          if (preset == null || preset == _eqPreset) return;
          setModalState(() => _eqPreset = preset);
          setState(() {});
          // mpv 内置均衡器实时应用
          _eqService.applyPreset(preset);
          PreferencesService.saveAudioEqPreset(preset.key);
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
    // ⚠️ 必须带上队列下标：后台自动切歌靠它定位（不能靠 MediaItem 相等性，见 handler）
    getAudioHandler().updateCurrentItem(baseItem, index: _currentIndex);

    // Asynchronously fetch high-fidelity artwork and update notification once ready
    final song = _allSongs.isNotEmpty ? _allSongs[_currentIndex] : null;
    if (song != null && song.id > 0) {
      try {
        final artUri = await getArtworkUri(song.id);
        if (artUri != null && mounted) {
          final updatedItem = _buildMediaItem(_currentIndex, artUri: artUri);
          getAudioHandler().updateCurrentItem(
            updatedItem,
            index: _currentIndex,
          );
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
      // 存一份原始队列快照：从通知栏 / 类别页重新进入本页时用它恢复播放列表，
      // 避免「下一首跑到播放列表之外」（issue #34）
      songQueue: _allSongs,
    );
    // ⚠️ 必须登记「本页仍持有这个 player」。音频页此前从不登记（只有视频页登记），
    // 于是视频侧开启后台播放时 attach 换绑旧 player 会把它当成「无主对象」直接销毁，
    // 而音频页 / 桌面歌词仍在用它 ⇒ use-after-free ⇒ CRASH_NATIVE
    // （用户反馈 2026-09-27：「音频和视频都开启后台播放后，播放视频会崩溃闪退」）。
    handler.markForegroundHolds(player);
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

  void _handleBackgroundToggle(BuildContext ctx, [VoidCallback? onSheetState]) {
    if (_isBackgroundMode) {
      _toggleBackgroundMode();
      // 关闭后台播放时弹窗仍保持打开，需主动刷新弹窗内的开关状态
      onSheetState?.call();
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
    // 与视频播放器共用 [BackgroundPlayPermission]（权限申请 + 未授予提示），
    // 保证两端文案与判定一致。
    final notifGranted = await BackgroundPlayPermission.ensureGranted(context);
    if (!notifGranted) {
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

    // 安全网：延迟 800ms 后重新 emit 一次 playbackState。
    // 首次 attach() 的 emit 可能因 startForeground 竞态/权限延迟而未成功创建通知，
    // 重新 emit 会触发原生侧 retry enterPlayingState()。
    Future.delayed(const Duration(milliseconds: 800), () {
      if (mounted && _isBackgroundMode) {
        getAudioHandler().reattachState();
      }
    });

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

  /// 诊断通知栏是否实际生效。
  ///
  /// 实现见 [BackgroundPlayPermission.diagnose]（与视频播放器共用同一套检测），
  /// 确保两端在「通知权限被拒 / 通知渠道被禁用 / 前台服务没起来」时的提示一致。
  Future<void> _diagnoseNotificationEffectiveness() async {
    await BackgroundPlayPermission.diagnose(
      context,
      isActive: () => mounted,
      onReattach: () async {
        if (mounted) _startBackgroundMode();
      },
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
                        _handleBackgroundToggle(ctx, () => setSheet(() {}));
                      },
                    ),
                    onTap: () {
                      _handleBackgroundToggle(ctx, () => setSheet(() {}));
                    },
                  ),
                  // ── 歌词设置（桌面歌词 / 动画风格 / 搜索 / 导入统一入口） ──────
                  ListTile(
                    leading: const Icon(Icons.music_note_rounded,
                        color: Colors.white),
                    title: Text(
                      L10n.of(context).lyric_settings,
                      style: const TextStyle(
                          color: Colors.white, fontWeight: FontWeight.w600),
                    ),
                    subtitle: Text(
                      _lyricStyleLabel(),
                      style: const TextStyle(
                          color: Colors.white54, fontSize: 12),
                    ),
                    trailing: const Icon(Icons.chevron_right_rounded,
                        color: Colors.white54),
                    onTap: () {
                      Navigator.pop(ctx);
                      _showLyricSettingsPage();
                    },
                  ),
                  ListTile(
                    leading: const Icon(Icons.tune_rounded, color: Colors.white),
                    title: Text(L10n.of(context).msgb7c87215, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
                    onTap: () {
                      Navigator.pop(ctx);
                      _showEqualizerSheet();
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
                        accent.withValues(alpha: 0.2),
                        theme.scaffoldBackgroundColor,
                        theme.scaffoldBackgroundColor,
                      ]
                    : [
                        accent.withValues(alpha: 0.12),
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
                        color: theme.colorScheme.onSurface.withValues(alpha: 0.9),
                      ),
                    ),
                  ],
                ),
              ),
              Container(
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.08),
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
            child: Column(
              children: [
                Expanded(
                  child: SingleChildScrollView(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        _buildArtworkOrLyrics(accent, theme, isDark),
                        _buildSingleLineLyrics(accent, theme, isDark),
                      ],
                    ),
                  ),
                ),
                // 歌曲信息 + 波形 + 播控整体 pinned 到导航栏上方：三者间距
                // 均匀（14dp），底部再留 20dp 呼吸空间，不紧贴导航栏。
                Padding(
                  padding: const EdgeInsets.only(bottom: 20),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // 标题 / 歌手 / 收藏
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 28),
                        child: Row(
                          children: [
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  // 超长标题向左循环滚动（跑马灯），避免省略号截断
                                  MarqueeText(
                                    text: _currentTitle,
                                    textAlign: TextAlign.left,
                                    active: isPlaying,
                                    scrollWhenPaused: true,
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
                                      color: theme.colorScheme.onSurface
                                          .withValues(alpha: 0.6),
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            IconButton(
                              icon: Icon(
                                _isFavorite
                                    ? Icons.favorite_rounded
                                    : Icons.favorite_border_rounded,
                                color: _isFavorite
                                    ? Colors.redAccent
                                    : theme.colorScheme.onSurface.withValues(
                                        alpha: 0.6,
                                      ),
                                size: 28,
                              ),
                              onPressed: () =>
                                  setState(() => _isFavorite = !_isFavorite),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 14),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 24),
                        child: AudioWaveformWidget(
                          position: position,
                          duration: duration,
                          isPlaying: isPlaying,
                          accentColor: accent,
                          onSeekStart: () => isSeeking = true,
                          onSeekCancel: () => isSeeking = false,
                          onSeek: (d) {
                            isSeeking = false;
                            setState(() => position = d);
                            player.seek(d);
                          },
                        ),
                      ),
                      const SizedBox(height: 14),
                      AudioControlsWidget(
                        isPlaying: isPlaying,
                        position: position,
                        duration: duration,
                        onPlayPause: () => player.playOrPause(),
                        onPrevious: _allSongs.length > 1 ? _playPrevious : null,
                        onNext: _allSongs.length > 1 ? _playNext : null,
                        onShowLyrics: _showLyricModeMenu,
                        onShowSleepTimer: _showSleepTimerDialog,
                        onShowEqualizer: _showEqualizerSheet,
                        onShowQueue: () => _showQueueSheet(accent),
                        playbackMode: _playbackMode,
                        onTogglePlaybackMode: _cyclePlaybackMode,
                        accentColor: accent,
                        lyricsDisplayMode: _lyricsDisplayMode,
                        audioPath: _currentPath,
                      ),
                    ],
                  ),
                ),
              ],
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
                        color: theme.colorScheme.onSurface.withValues(alpha: 0.08),
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
                  child: Column(
                    children: [
                      Expanded(
                        child: SingleChildScrollView(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              _buildSingleLineLyrics(accent, theme, isDark),
                            ],
                          ),
                        ),
                      ),
                      // 标题 / 收藏 / 波形 / 播控整体 pinned 到导航栏上方：
                      // 间距均匀（12dp），底部再留 20dp 不紧贴导航栏。
                      Padding(
                        padding: const EdgeInsets.only(bottom: 20),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 24,
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.center,
                                children: [
                                  // 超长标题向左循环滚动（跑马灯），避免省略号截断
                                  MarqueeText(
                                    text: _currentTitle,
                                    textAlign: TextAlign.center,
                                    active: isPlaying,
                                    scrollWhenPaused: true,
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
                                      color: theme.colorScheme.onSurface
                                          .withValues(alpha: 0.6),
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(height: 12),
                            IconButton(
                              icon: Icon(
                                _isFavorite
                                    ? Icons.favorite_rounded
                                    : Icons.favorite_border_rounded,
                                color: _isFavorite
                                    ? Colors.redAccent
                                    : theme.colorScheme.onSurface.withValues(
                                        alpha: 0.6,
                                      ),
                                size: 32,
                              ),
                              onPressed: () =>
                                  setState(() => _isFavorite = !_isFavorite),
                            ),
                            const SizedBox(height: 12),
                            Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 24,
                              ),
                              child: AudioWaveformWidget(
                                position: position,
                                duration: duration,
                                isPlaying: isPlaying,
                                accentColor: accent,
                                onSeekStart: () => isSeeking = true,
                                onSeekCancel: () => isSeeking = false,
                                onSeek: (d) {
                                  isSeeking = false;
                                  setState(() => position = d);
                                  player.seek(d);
                                },
                              ),
                            ),
                            const SizedBox(height: 12),
                            AudioControlsWidget(
                              isPlaying: isPlaying,
                              position: position,
                              duration: duration,
                              onPlayPause: () => player.playOrPause(),
                              onPrevious: _allSongs.length > 1
                                  ? _playPrevious
                                  : null,
                              onNext: _allSongs.length > 1 ? _playNext : null,
                              onShowLyrics: _showLyricModeMenu,
                              onShowSleepTimer: _showSleepTimerDialog,
                              onShowEqualizer: _showEqualizerSheet,
                              onShowQueue: () => _showQueueSheet(accent),
                              playbackMode: _playbackMode,
                              onTogglePlaybackMode: _cyclePlaybackMode,
                              accentColor: accent,
                              lyricsDisplayMode: _lyricsDisplayMode,
                              audioPath: _currentPath,
                            ),
                          ],
                        ),
                      ),
                    ],
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

/// 全屏歌词页：真正全屏的歌词视图，支持切换动画风格、本地导入与在线搜索。
class _FullScreenLyricsPage extends StatefulWidget {
  final Player player;
  final List<LyricLine>? lyrics;
  final String title;
  final String artist;
  final Color accentColor;
  final bool isLoading;
  final VoidCallback onSelectLyricFile;
  final VoidCallback onSearchOnline;

  /// 当前歌曲标识（歌词偏移「仅本曲」作用域用）。
  final String songPath;

  /// 进入时的生效歌词偏移（毫秒）。
  final int lyricOffsetMs;

  const _FullScreenLyricsPage({
    required this.player,
    required this.lyrics,
    required this.title,
    required this.artist,
    required this.accentColor,
    required this.isLoading,
    required this.onSelectLyricFile,
    required this.onSearchOnline,
    required this.songPath,
    this.lyricOffsetMs = 0,
  });

  @override
  State<_FullScreenLyricsPage> createState() => _FullScreenLyricsPageState();
}

class _FullScreenLyricsPageState extends State<_FullScreenLyricsPage> {
  Duration _position = Duration.zero;
  StreamSubscription<Duration>? _positionSub;
  bool _isPlaying = false;
  StreamSubscription<bool>? _playingSub;
  late LyricAnimationStyle _style;

  /// 生效的歌词整体偏移（毫秒）：正值延后、负值提前。
  int _lyricOffsetMs = 0;

  /// 顶栏（歌曲信息 / 搜索 / 导入 / 风格切换 / 偏移）是否可见。
  /// 默认隐藏 = 沉浸式全屏；点击歌词区空白处显示，2s 无操作自动收起。
  bool _chromeVisible = false;

  /// 顶栏自动隐藏定时器（显示 2s 后回到沉浸模式）。
  Timer? _chromeTimer;

  @override
  void initState() {
    super.initState();
    _style = LyricAnimationStyle.fromName(
        PreferencesService.getLyricAnimationStyleName());
    _lyricOffsetMs = widget.lyricOffsetMs;
    _isPlaying = widget.player.state.playing;
    _positionSub = widget.player.stream.position.listen((p) {
      if (mounted) setState(() => _position = p);
    });
    _playingSub = widget.player.stream.playing.listen((playing) {
      if (mounted) setState(() => _isPlaying = playing);
    });
  }

  @override
  void dispose() {
    _chromeTimer?.cancel();
    _positionSub?.cancel();
    _playingSub?.cancel();
    super.dispose();
  }

  /// 显示顶栏并启动 2s 自动隐藏（再次点击空白处可立即收起）。
  void _showChrome() {
    _chromeTimer?.cancel();
    setState(() => _chromeVisible = true);
    _startChromeHideTimer();
  }

  void _hideChrome() {
    _chromeTimer?.cancel();
    setState(() => _chromeVisible = false);
  }

  /// 顶栏已显示时重排自动隐藏计时（弹出菜单开关后沿用相同节奏）。
  void _rearmChromeTimer() {
    if (!_chromeVisible) return;
    _chromeTimer?.cancel();
    _startChromeHideTimer();
  }

  void _startChromeHideTimer() {
    _chromeTimer = Timer(const Duration(seconds: 2), () {
      if (!mounted) return;
      setState(() => _chromeVisible = false);
    });
  }

  void _toggleChrome() {
    if (_chromeVisible) {
      _hideChrome();
    } else {
      _showChrome();
    }
  }

  /// 歌词整体偏移设置（实时预览，确认才落盘）。
  void _showOffsetDialog() {
    LyricOffsetDialog.show(
      context,
      songPath: widget.songPath,
      songTitle: widget.title,
      globalMs: PreferencesService.getLyricOffsetGlobal(),
      songMs: PreferencesService.getLyricOffsetForSong(widget.songPath),
      effectiveMs: _lyricOffsetMs,
      onPreview: (ms) {
        if (!mounted) return;
        setState(() => _lyricOffsetMs = ms);
        DesktopLyricController.instance.setOffsetMs(ms);
      },
    ).then((result) {
      if (!mounted || result == null) return;
      setState(() => _lyricOffsetMs = result);
      DesktopLyricController.instance.setOffsetMs(result);
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = L10n.of(context);
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final mediaQuery = MediaQuery.of(context);

    // 全屏沉浸：状态栏透明，顶部渐变延伸至状态栏后方。
    SystemChrome.setSystemUIOverlayStyle(SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: isDark ? Brightness.light : Brightness.dark,
    ));

    return Scaffold(
      extendBodyBehindAppBar: true,
      backgroundColor: theme.scaffoldBackgroundColor,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        leading: _chromeWrap(
          child: IconButton(
            icon: Icon(Broken.arrow_down_2,
                color: isDark ? Colors.white : theme.colorScheme.onSurface),
            tooltip: MaterialLocalizations.of(context).closeButtonLabel,
            onPressed: () => Navigator.pop(context),
          ),
        ),
        title: _chromeWrap(
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
                  fontSize: 16,
                ),
              ),
              Text(
                widget.artist,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: (isDark ? Colors.white : theme.colorScheme.onSurface)
                      .withValues(alpha: 0.55),
                  fontSize: 12,
                ),
              ),
            ],
          ),
        ),
        actions: [
          // 在线搜索 / 本地导入合并为一个入口：点击弹出菜单二选一。
          _chromeWrap(
            child: PopupMenuButton<String>(
              tooltip: l10n.ui_lyrics_menu,
              icon: Icon(
                Icons.lyrics_rounded,
                size: 22,
                color: (isDark ? Colors.white : theme.colorScheme.onSurface)
                    .withValues(alpha: 0.75),
              ),
              // 菜单打开期间暂停顶栏自动隐藏，避免锚点按钮消失。
              onOpened: () => _chromeTimer?.cancel(),
              onCanceled: _rearmChromeTimer,
              onSelected: (value) {
                if (value == 'search') {
                  widget.onSearchOnline();
                } else if (value == 'import') {
                  widget.onSelectLyricFile();
                }
                _rearmChromeTimer();
              },
              itemBuilder: (context) => [
                PopupMenuItem<String>(
                  value: 'search',
                  child: ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.search_rounded, size: 20),
                    title: Text(l10n.ui_search_lyrics_online),
                  ),
                ),
                PopupMenuItem<String>(
                  value: 'import',
                  child: ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.folder_open_rounded, size: 20),
                    title: Text(l10n.ui_select_lyrics_file),
                  ),
                ),
              ],
            ),
          ),
          _chromeWrap(
            child: IconButton(
              icon: Icon(
                Icons.animation_rounded,
                size: 22,
                color: widget.accentColor,
              ),
              tooltip: l10n.lyric_animation_style,
              onPressed: () {
                showLyricStyleSheet(
                  context,
                  current: _style,
                  onSelected: (s) => setState(() => _style = s),
                );
              },
            ),
          ),
          _chromeWrap(
            child: IconButton(
              icon: const Icon(Icons.timer_outlined, size: 22),
              color: _lyricOffsetMs != 0
                  ? widget.accentColor
                  : (isDark ? Colors.white : theme.colorScheme.onSurface)
                      .withValues(alpha: 0.75),
              tooltip: _lyricOffsetMs != 0
                  ? '${l10n.lyric_offset}  ${formatLyricOffset(_lyricOffsetMs)}'
                  : l10n.lyric_offset,
              onPressed: _showOffsetDialog,
            ),
          ),
        ],
      ),
      // 点击歌词区（非歌词行本身）显示顶栏；显示 2s 后自动收起，
      // 再次点击立即收起，回到沉浸模式。
      body: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onTap: _toggleChrome,
        child: AnimatedPadding(
          duration: const Duration(milliseconds: 240),
          curve: Curves.easeOutCubic,
          // 顶栏隐藏时歌词延伸至状态栏下方，真正沉浸；显示时让出 AppBar 高度。
          padding: EdgeInsets.only(
            top: _chromeVisible
                ? mediaQuery.padding.top + kToolbarHeight
                : mediaQuery.padding.top,
            bottom: mediaQuery.padding.bottom,
          ),
          child: Container(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  widget.accentColor.withValues(alpha: isDark ? 0.14 : 0.10),
                  theme.scaffoldBackgroundColor,
                  theme.scaffoldBackgroundColor,
                ],
                stops: const [0.0, 0.45, 1.0],
              ),
            ),
            child: widget.isLoading
                ? const Center(child: CircularProgressIndicator())
                : (widget.lyrics != null && widget.lyrics!.isNotEmpty
                    ? LyricsViewWidget(
                        lyrics: widget.lyrics!,
                        position: Duration(
                          milliseconds:
                              _position.inMilliseconds - _lyricOffsetMs,
                        ),
                        accentColor: widget.accentColor,
                        style: _style,
                        isPlaying: _isPlaying,
                        onSeek: (d) => widget.player.seek(d),
                      )
                    : _buildNoLyrics(theme, isDark)),
          ),
        ),
      ),
    );
  }

  /// 顶栏控件显隐包裹：沉浸态淡出 + 上移，并屏蔽点击。
  Widget _chromeWrap({required Widget child}) {
    return IgnorePointer(
      ignoring: !_chromeVisible,
      child: AnimatedSlide(
        offset: _chromeVisible ? Offset.zero : const Offset(0, -0.4),
        duration: const Duration(milliseconds: 240),
        curve: Curves.easeOutCubic,
        child: AnimatedOpacity(
          opacity: _chromeVisible ? 1 : 0,
          duration: const Duration(milliseconds: 200),
          child: child,
        ),
      ),
    );
  }

  Widget _buildNoLyrics(ThemeData theme, bool isDark) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Broken.document,
              size: 64,
              color: (isDark ? Colors.white : theme.colorScheme.onSurface)
                  .withValues(alpha: 0.2),
            ),
            const SizedBox(height: 16),
            Text(
              L10n.of(context).ui_no_lyrics_found,
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
                color: (isDark ? Colors.white : theme.colorScheme.onSurface)
                    .withValues(alpha: 0.6),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              L10n.of(context).ui_lyrics_auto_load_hint,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 14,
                height: 1.6,
                color: (isDark ? Colors.white : theme.colorScheme.onSurface)
                    .withValues(alpha: 0.4),
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
                    side: BorderSide(
                        color: widget.accentColor.withValues(alpha: 0.4)),
                    padding: const EdgeInsets.symmetric(
                        horizontal: 20, vertical: 12),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16)),
                  ),
                ),
                OutlinedButton.icon(
                  onPressed: widget.onSelectLyricFile,
                  icon: const Icon(Icons.folder_open_rounded, size: 20),
                  label: Text(L10n.of(context).ui_select_lyrics_file),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: widget.accentColor,
                    side: BorderSide(
                        color: widget.accentColor.withValues(alpha: 0.4)),
                    padding: const EdgeInsets.symmetric(
                        horizontal: 20, vertical: 12),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16)),
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
