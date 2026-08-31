import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:path/path.dart' as p;
import 'package:zenfile/core/icon_fonts/broken_icons.dart';
import 'package:zenfile/l10n/generated/app_localizations.dart';
import 'package:zenfile/services/preferences_service.dart';
import 'package:zenfile/services/remote_streaming_service.dart';
import 'package:zenfile/services/network_connections_service.dart';
import 'package:zenfile/services/subtitle_parser.dart';
import 'package:zenfile/services/audio_background_handler.dart';
import 'package:zenfile/services/audio_equalizer_service.dart';
import 'package:zenfile/providers/file_manager_provider.dart';
import 'package:provider/provider.dart';
import '../internal_file_picker_screen.dart';
import 'video_loading_indicator.dart';
import 'video_seek_indicator.dart';
import 'video_controls_overlay.dart';
import 'vertical_slider_widget.dart';

class VideoPlayerScreen extends StatefulWidget {
  final String videoPath;
  final List<dynamic>? playlist;
  final List<AssetEntity>? assetPlaylist;
  final int? initialIndex;
  final bool isRemote;

  const VideoPlayerScreen({
    super.key,
    required this.videoPath,
    this.playlist,
    this.assetPlaylist,
    this.initialIndex,
    this.isRemote = false,
  });

  @override
  State<VideoPlayerScreen> createState() => _VideoPlayerScreenState();
}

class _VideoPlayerScreenState extends State<VideoPlayerScreen>
    with TickerProviderStateMixin {
  late Player player;
  late VideoController controller;

  late int _currentIndex;
  bool _isResolvingAsset = false;
  String? _currentFilePath;

  bool _controlsVisible = true;
  bool _isPlaying = false;
  bool _isSeeking = false;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  double _sliderValue = 0;
  bool _isFullScreen = false;
  // 用户是否通过全屏按钮手动锁定全屏。手动锁定后会强制横屏（不被系统旋转退出）；
  // 系统自动横屏进入的全屏不锁定，手机转回竖屏即退出全屏 UI。
  bool _userLockedFullScreen = false;
  // 最近一次系统方向，供手动全屏/退出全屏决策使用。
  Orientation _currentOrientation = Orientation.portrait;
  bool _isLocked = false;
  double _playbackSpeed = 1.0;
  // 音频均衡器（复用音频播放器的 mpv lavfi equalizer 服务）
  final AudioEqualizerService _eqService = AudioEqualizerService();
  EqPreset _eqPreset = EqPreset.flat;
  bool _isBuffering = false;
  bool _isWaitingForCache = false;
  Timer? _cacheCheckTimer;

  // 远程流式播放
  String? _currentStreamUrl;

  // Swipes for Volume & Brightness
  double _volume = 0.8; // 0.0 to 1.0
  double _brightness = 1.0; // 0.0 to 1.0
  bool _showVolumeSlider = false;
  bool _showBrightnessSlider = false;
  Timer? _sliderTimer;

  // 与系统音量同步：应用内音量滑块反映并控制系统媒体音量
  static const MethodChannel _volumeChannel = MethodChannel('com.sequl.zenfile/volume');
  Timer? _volumePollTimer;
  double _volumeBeforeMute = 0.5;

  Timer? _hideTimer;
  late AnimationController _controlsAnimController;
  late Animation<double> _controlsOpacity;

  // Horizontal drag seek
  bool _isHorizontalDragging = false;
  double _dragStartX = 0;
  Duration _dragStartPosition = Duration.zero;
  int _dragSeekDelta = 0;

  // Frame preview during drag
  bool _isPreviewDragging = false;
  Uint8List? _previewImage;
  Timer? _previewDebounceTimer;
  Duration _previewTarget = Duration.zero;

  // Double-tap seek accumulation & animation
  bool _showSeekLeft = false;
  bool _showSeekRight = false;
  Timer? _seekIndicatorTimer;
  int _seekSeconds = 0;

  // Long press 2.0x speed
  bool _isLongPressSpeed = false;
  double _previousSpeed = 1.0;

  // Utilities
  bool _isMuted = false;
  int _repeatMode = 0; // 0=none, 1=one, 2=all
  int _rotationTurns = 0; // 0=0°, 1=90°顺时针, 2=180°, 3=270°
  int _aspectRatioMode = 0; // 0=原始比例, 1=拉伸填充, 2=居中, 3=填充屏幕, 4=16:9, 5=4:3, 6=自定义
  double _customAspectRatio = 16 / 9;
  // 用户是否手动切换过缩放模式。未触碰时，全屏自动用 cover 填满（贴近 MX 无黑边）；
  // 一旦手动切换，则尊重用户选择，不再自动覆盖。
  bool _userTouchedAspect = false;
  String? _aspectToast;
  Timer? _aspectToastTimer;

  // Subtitle
  bool _subtitleEnabled = false;
  String? _subtitlePath;
  double _subtitleFontSize = 24;
  double _subtitlePosition = 100; // 0=顶部, 100=底部
  bool _subtitleNoBackground = false;

  // Audio / Subtitle track selection
  List<AudioTrack> _availableAudioTracks = [];
  List<SubtitleTrack> _availableSubtitleTracks = [];
  AudioTrack _currentAudioTrack = const AudioTrack('auto', null, null);
  SubtitleTrack _currentSubtitleTrack = const SubtitleTrack('auto', null, null);
  StreamSubscription<Tracks>? _tracksSub;
  StreamSubscription<Track>? _trackSub;

  // 解码方式：true=硬解(auto-safe), false=软解(no)，持久化保存
  bool _useHardwareDecode = true;
  // 外挂字幕改用 Flutter overlay 渲染，确保字号/位置滑块对所有格式 100% 生效
  List<SubtitleCue> _externalCues = [];
  int _activeCueIndex = -1;
  StreamSubscription<Duration>? _positionSub;

  // Playback Progress
  Timer? _progressSaveTimer;
  bool _hasRestoredPosition = false;

  // Dynamic playlist (auto-built from directory when widget.playlist is empty)
  List<dynamic>? _resolvedPlaylist;

  @override
  void initState() {
    super.initState();
    _currentIndex = widget.initialIndex ?? 0;
    _customAspectRatio = PreferencesService.getVideoCustomAspectRatio();
    _subtitleFontSize = PreferencesService.getSubtitleFontSize();
    _subtitlePosition = PreferencesService.getSubtitlePosition();
    _subtitleNoBackground = PreferencesService.getSubtitleNoBackground();
    _useHardwareDecode = PreferencesService.getUseHardwareDecode();

    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.landscapeRight,
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.portraitUp,
    ]);

    _controlsAnimController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 250),
    );
    _controlsOpacity = CurvedAnimation(
      parent: _controlsAnimController,
      curve: Curves.easeInOut,
    );
    _controlsAnimController.value = 1.0;

    // 软解模式使用更大的缓冲区，减少高码率视频卡顿
    const bufferSize = 64 * 1024 * 1024;
    player = Player(
      configuration: const PlayerConfiguration(
        ready: null,
        logLevel: MPVLogLevel.warn,
        bufferSize: bufferSize,
      ),
    );
    controller = VideoController(
      player,
      configuration: VideoControllerConfiguration(
        // 硬解=auto-safe，软解=no（纯 CPU 解码，兼容部分硬解黑屏/花屏的机型）
        hwdec: _useHardwareDecode ? 'auto-safe' : 'no',
      ),
    );

    // 覆盖 media_kit 硬编码的 network-timeout=5s。
    // SMB/FTP/SFTP 建立连接+认证可能需要 5-10s，5s 超时会导致 libmpv
    // 在数据到达前就放弃播放。设为 60s 给本地代理足够时间启动下载。
    // 必须在 _startPlayback 之前完成，否则播放已经开始读取超时值。
    _initListeners();
    _initTrackListeners();
    () async {
      try {
        final platform = player.platform;
      if (platform is NativePlayer) {
        await platform.setProperty('network-timeout', '60');
        // 远程（含本地代理 127.0.0.1）播放：放大缓存与解复用缓冲，吸收代理喂流的
        // 脉冲式抖动，使 SFTP/FTP/SMB 与 WebDAV 直连一样流畅。此前这些仅在软解模式
        // 才设置，硬解（默认）下 demuxer 缓冲极小，代理轻微抖动即导致 libmpv 缓冲
        // 耗尽而周期性卡顿。WebDAV 直连不经过 Dart 代理故不受影响。
        await platform.setProperty('cache-secs', '60');
        await platform.setProperty('demuxer-max-bytes', '300M');
        await platform.setProperty('demuxer-readahead-secs', '60');
        // 注意：不在初始化时设置 sub-ass-override，否则会破坏 VOBSub 位图字幕渲染
        // sub-ass-override 仅在加载 ASS/SSA 字幕时应用（见 _applySubtitle）
        await platform.setProperty('sub-font-size', _subtitleFontSize.round().toString());
        await platform.setProperty('sub-pos', _subtitlePosition.round().toString());
        await _applySubtitleBackgroundProps(platform);
        // 软解模式额外启用解码性能优化
        if (!_useHardwareDecode) {
          await _applySoftwareDecodeOptimizations(platform);
        }
        // 音频均衡器：绑定到当前 mpv 原生播放器，恢复上次使用的预设
        try {
          await _eqService.attach(platform);
          final savedEq = PreferencesService.getAudioEqPreset();
          _eqPreset = EqPresetExtension.fromKey(savedEq);
          await _eqService.applyPreset(_eqPreset);
        } catch (eqErr) {
          debugPrint('视频均衡器初始化失败: $eqErr');
        }
      }
      } catch (e) {
        debugPrint('设置 network-timeout 失败: $e');
      }
      _startPlayback();
      _resolvePlaylist();
    }();
    // 以系统音量为单一来源，播放器内部音量固定最大，避免双重缩放
    _syncVolumeFromSystem(setPlayerVolume: true);
    _startVolumePolling();
    _startHideTimer();

    // 同步初始系统方向 -> 全屏状态。
    // 若用户从横屏状态打开视频（或系统已处于自动横屏），应立即进入全屏播放器 UI，
    // 避免出现"竖屏 UI 被旋转到横屏"的错位观感。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final orientation = MediaQuery.of(context).orientation;
      _syncFullScreenWithOrientation(orientation);
    });
  }

  /// 系统方向变化时自动同步全屏状态。
  /// 规则：
  /// - 系统进入横屏 -> 自动进入全屏（沉浸 + 控件按横屏布局），让"自动旋转"等价于"全屏播放"。
  /// - 系统回到竖屏 -> 退出全屏 UI（除非用户是手动全屏锁定，此时保持）。
  /// 注意：系统驱动的全屏不锁定方向（保持允许横竖屏），因此手机转回竖屏即可退出全屏；
  /// 只有用户手动点全屏才会锁定横屏。
  void _syncFullScreenWithOrientation(Orientation orientation) {
    // 用户手动锁定全屏时，忽略系统方向变化（保持锁定）。
    if (_userLockedFullScreen) return;

    final target = orientation == Orientation.landscape;
    if (target == _isFullScreen) return;

    _isFullScreen = target;
    // 仅切换系统 UI 沉浸状态，不锁定方向（方向仍由系统自动旋转控制）。
    if (target) {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    } else {
      final hideNav = PreferencesService.getHideNavigationBar();
      if (hideNav) {
        SystemChrome.setEnabledSystemUIMode(
          SystemUiMode.manual,
          overlays: [SystemUiOverlay.top],
        );
      } else {
        SystemChrome.setEnabledSystemUIMode(
          SystemUiMode.manual,
          overlays: SystemUiOverlay.values,
        );
      }
    }
    if (mounted) setState(() {});
  }

  void _startPlayback() async {
    // 视频开始播放时，立即暂停后台音频，避免两路声音混在一起
    try {
      getAudioHandler().pauseForVideo();
    } catch (_) {}
    if (!widget.videoPath.startsWith('http://') &&
        !widget.videoPath.startsWith('https://') &&
        !widget.videoPath.startsWith('remote://')) {
      _currentFilePath = widget.videoPath;
    }
    if (_currentFilePath != null) {
      PreferencesService.saveLastPlayedVideo(_currentFilePath!, _fileName);
    }

    // 处理 remote:// 路径（从视频类别打开远程视频）
    if (widget.videoPath.startsWith('remote://')) {
      setState(() => _isBuffering = true);
      final resolved = await _resolveRemotePath(widget.videoPath);
      if (resolved == null) {
        debugPrint('远程视频路径解析失败: ${widget.videoPath}');
        if (mounted) setState(() => _isBuffering = false);
        return;
      }
      _currentStreamUrl = resolved;
      player.open(Media(resolved), play: false);
      if (mounted) setState(() => _isBuffering = false);
      return;
    }

    // 处理本地代理 URL（流式播放：http://127.0.0.1:PORT/stream...）
    // 记录到 _currentStreamUrl 以便 dispose 时清理流式会话（HTTP 服务器+后台下载）
    if (widget.videoPath.startsWith('http://127.0.0.1') ||
        widget.videoPath.startsWith('http://localhost')) {
      _currentStreamUrl = widget.videoPath;
    }

    // For remote files that are being cached, wait until the download completes
    // (download goes to .partial file, then renames to the actual file)
    if (widget.isRemote && !widget.videoPath.startsWith('http')) {
      final file = File(widget.videoPath);
      final initialSize = file.existsSync() ? file.lengthSync() : 0;
      // If file is empty or very small (placeholder), wait for download to complete
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
                _openMediaWithRetry();
              }
            }
          } catch (_) {}
        });
        return;
      }
    }
    _openMediaWithRetry();
  }

  void _openMediaWithRetry() {
    player.open(Media(widget.videoPath), play: false);
    _autoMatchSubtitle();
  }

  Future<void> _autoMatchSubtitle() async {
    if (widget.videoPath.startsWith('http://') || widget.videoPath.startsWith('https://')) {
      return;
    }
    if (widget.videoPath.startsWith('remote://')) {
      return;
    }
    try {
      final videoFile = File(widget.videoPath);
      if (!await videoFile.exists()) return;

      // 优先恢复用户手动指定的外挂字幕（持久化映射），避免退出重播后需重新添加。
      final savedSubtitle = PreferencesService.getSubtitleMapping(widget.videoPath);
      if (savedSubtitle != null && await File(savedSubtitle).exists()) {
        if (mounted) {
          setState(() {
            _subtitlePath = savedSubtitle;
            _subtitleEnabled = true;
          });
          // 延迟应用字幕，等待播放器初始化完成
          await Future.delayed(const Duration(milliseconds: 500));
          if (mounted) _applySubtitle(savedSubtitle);
        }
        return;
      }

      final dir = videoFile.parent;
      final videoNameWithoutExt = p.basenameWithoutExtension(widget.videoPath);
      final subtitleExtensions = ['.srt', '.ass', '.ssa', '.vtt', '.sub'];

      String? matchedSubtitle;
      for (final ext in subtitleExtensions) {
        final candidatePath = p.join(dir.path, '$videoNameWithoutExt$ext');
        if (await File(candidatePath).exists()) {
          // VOBSub 成对存在：优先用 .idx（mpv 加载位图字幕必须传 .idx）。
          if (ext == '.sub') {
            final idxPath = '${p.withoutExtension(candidatePath)}.idx';
            matchedSubtitle = await File(idxPath).exists() ? idxPath : candidatePath;
          } else {
            matchedSubtitle = candidatePath;
          }
          break;
        }
      }

      if (matchedSubtitle != null && mounted) {
        setState(() {
          _subtitlePath = matchedSubtitle;
          _subtitleEnabled = true;
        });
        // 延迟应用字幕，等待播放器初始化完成
        await Future.delayed(const Duration(milliseconds: 500));
        if (mounted) _applySubtitle(matchedSubtitle);
      }
    } catch (e) {
      debugPrint('自动匹配字幕失败: $e');
    }
  }

  void _applySubtitle(String subtitlePath) {
    try {
      // 解析外挂字幕，改用 Flutter overlay 渲染，确保字号/位置滑块 100% 生效
      final ext = p.extension(subtitlePath).toLowerCase();
      final isAss = ext == '.ass' || ext == '.ssa';
      // 外挂位图字幕：.idx（自动配对同名 .sub）、带同名 .idx 的 .sub、蓝光 .sup。
      // 无 .idx 配对的 .sub 视为文本字幕（MicroDVD），走文本解析分支。
      final isVobSub = ext == '.idx' ||
          ext == '.sup' ||
          (ext == '.sub' &&
              File('${p.withoutExtension(subtitlePath)}.idx').existsSync());
      // 仅对 ASS/SSA 字幕设置样式覆盖；VOBSub 等位图字幕必须保持 sub-ass-override=no
      final platform = player.platform;
      if (isAss) {
        if (platform is NativePlayer) {
          platform.setProperty('sub-ass-override', 'force');
        }
      } else if (isVobSub) {
        // VOBSub 位图字幕：必须设为 no 才能正确渲染。
        // VOBSub 由 .idx（文本索引）+ .sub（位图二进制）成对组成，mpv 加载时
        // 必须传入 .idx 路径（自动配对同名 .sub），且不能走 Flutter overlay
        // 文本解析（位图无法解析为 cue）。这里直接交给 mpv 渲染，跳过解析分支。
        if (platform is NativePlayer) {
          platform.setProperty('sub-ass-override', 'no');
        }
        _externalCues = const [];
        _activeCueIndex = -1;
        player.setSubtitleTrack(
          SubtitleTrack.uri(subtitlePath, title: 'External'),
        );
        // 关键修复：开启 mpv 原生渲染，否则位图字幕解码后不显示
        _syncSubVisibilityForTrack(
          SubtitleTrack.uri(subtitlePath, title: 'External'),
        );
        if (!_subtitleEnabled) {
          player.setSubtitleTrack(SubtitleTrack.no());
          _syncSubVisibilityForTrack(const SubtitleTrack('no', null, null));
        }
        // 位图字幕字号/位置由 mpv 自身控制，这里仍应用背景样式（不影响位图内容）。
        _applySubtitleBackground();
        if (mounted) setState(() {});
        return;
      }
      List<SubtitleCue>? cues;
      try {
        final content = File(subtitlePath).readAsStringSync();
        cues = SubtitleParser.parse(content, isAss: isAss);
      } catch (e) {
        debugPrint('解析外挂字幕失败，回退到 mpv 渲染: $e');
      }
      if (cues != null && cues.isNotEmpty) {
        _externalCues = cues;
        // 关闭 mpv 内嵌字幕渲染，避免与 overlay 双重显示
        try {
          player.setSubtitleTrack(SubtitleTrack.no());
        } catch (_) {}
        // 文本字幕走 Flutter overlay，同步关闭 mpv 原生渲染
        _syncSubVisibilityForTrack(const SubtitleTrack('no', null, null));
        _startSubtitlePositionSync();
        _updateActiveCue(_position);
        if (mounted) setState(() {});
        return;
      }
      // 解析失败兜底：仍用 mpv 渲染
      player.setSubtitleTrack(
        SubtitleTrack.uri(subtitlePath, title: 'External'),
      );
      // 文本兜底字幕走 SubtitleView，同步关闭 mpv 原生渲染
      _syncSubVisibilityForTrack(
        SubtitleTrack.uri(subtitlePath, title: 'External'),
      );
      if (!_subtitleEnabled) {
        player.setSubtitleTrack(SubtitleTrack.no());
      }
      _applySubtitleFontSize(_subtitleFontSize);
      _applySubtitlePosition(_subtitlePosition);
      _applySubtitleBackground();
      // 字幕轨刚加载时 mpv 可能尚未应用样式，延迟一帧重新应用，确保大小/位置生效
      Future.microtask(() {
        if (!mounted) return;
        _applySubtitleFontSize(_subtitleFontSize);
        _applySubtitlePosition(_subtitlePosition);
      });
    } catch (e) {
      debugPrint('应用字幕失败: $e');
    }
  }

  /// 监听播放进度，更新当前应显示的外挂字幕 cue
  void _startSubtitlePositionSync() {
    _positionSub?.cancel();
    _positionSub = player.stream.position.listen((pos) {
      _updateActiveCue(pos);
    });
  }

  void _updateActiveCue(Duration pos) {
    if (_externalCues.isEmpty) {
      if (_activeCueIndex != -1) {
        _activeCueIndex = -1;
        if (mounted) setState(() {});
      }
      return;
    }
    var idx = -1;
    for (var i = 0; i < _externalCues.length; i++) {
      if (pos >= _externalCues[i].start && pos <= _externalCues[i].end) {
        idx = i;
        break;
      }
    }
    if (idx != _activeCueIndex) {
      _activeCueIndex = idx;
      if (mounted) setState(() {});
    }
  }

  void _toggleSubtitle() {
    setState(() {
      _subtitleEnabled = !_subtitleEnabled;
    });
    try {
      // 外挂字幕走 Flutter overlay，切换可见性即可，无需动 mpv 轨道
      if (_externalCues.isNotEmpty) return;
      if (_subtitleEnabled && _subtitlePath != null) {
        player.setSubtitleTrack(
          SubtitleTrack.uri(_subtitlePath!, title: 'External'),
        );
        // 按字幕类型同步 mpv 原生渲染开关（位图开、文本关）
        _syncSubVisibilityForTrack(
          SubtitleTrack.uri(_subtitlePath!, title: 'External'),
        );
        _applySubtitleFontSize(_subtitleFontSize);
        _applySubtitlePosition(_subtitlePosition);
        _applySubtitleBackground();
        Future.microtask(() {
          if (!mounted) return;
          _applySubtitleFontSize(_subtitleFontSize);
          _applySubtitlePosition(_subtitlePosition);
        });
      } else {
        player.setSubtitleTrack(SubtitleTrack.no());
        _syncSubVisibilityForTrack(const SubtitleTrack('no', null, null));
      }
    } catch (e) {
      debugPrint('切换字幕失败: $e');
    }
  }

  void _showPlaylist() {
    final hasPlaylist = (_effectivePlaylist != null && _effectivePlaylist!.isNotEmpty) || (widget.assetPlaylist != null && widget.assetPlaylist!.isNotEmpty);
    if (!hasPlaylist) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(L10n.of(context).msg_no_playlist)),
      );
      return;
    }

    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) => _buildPlaylistPanel(ctx),
    );
  }

  Widget _buildPlaylistPanel(BuildContext ctx) {
    final theme = Theme.of(ctx);
    final playlist = _effectivePlaylist;
    final assetPlaylist = widget.assetPlaylist;
    final playlistLength = playlist?.length ?? assetPlaylist?.length ?? 0;

    return Container(
      decoration: BoxDecoration(
        color: theme.scaffoldBackgroundColor,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
      ),
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: theme.colorScheme.onSurface.withOpacity(0.2),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(height: 12),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                Icon(Icons.playlist_play_rounded, color: theme.colorScheme.primary, size: 24),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '${L10n.of(context).msg_playlist} ($playlistLength)',
                    style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close_rounded),
                  onPressed: () => Navigator.pop(ctx),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Flexible(
            fit: FlexFit.loose,
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: playlistLength,
              padding: const EdgeInsets.only(bottom: 8),
              itemBuilder: (context, index) {
                String itemTitle = '';
                if (playlist != null) {
                  final item = playlist[index];
                  if (item is String) {
                    itemTitle = item.split(RegExp(r'[/\\]')).last;
                  } else if (item is FileSystemEntity) {
                    itemTitle = item.path.split(RegExp(r'[/\\]')).last;
                  }
                } else if (assetPlaylist != null) {
                  final item = assetPlaylist[index];
                  itemTitle = item.title ?? '';
                }

                final isCurrent = index == _currentIndex;

                return ListTile(
                  leading: Icon(
                    isCurrent ? Icons.play_circle_filled_rounded : Icons.movie_rounded,
                    color: isCurrent ? theme.colorScheme.primary : theme.colorScheme.onSurface.withOpacity(0.6),
                  ),
                  title: Text(
                    itemTitle,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontWeight: isCurrent ? FontWeight.bold : FontWeight.normal,
                      color: isCurrent ? theme.colorScheme.primary : theme.colorScheme.onSurface,
                    ),
                  ),
                  onTap: () {
                    Navigator.pop(ctx);
                    if (!isCurrent) {
                      _playAtIndex(index);
                    }
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _addSubtitle() async {
    try {
      final provider = context.read<FileManagerProvider>();
      final pickedPaths = await InternalFilePickerScreen.show(
        context,
        rootPath: provider.rootPath,
      );
      if (pickedPaths != null && pickedPaths.isNotEmpty && mounted) {
        var subtitlePath = pickedPaths.first;
        // VOBSub 位图字幕由 .idx（文本索引）+ .sub（位图数据）成对组成，
        // mpv 加载 VOBSub 必须传入 .idx 路径（自动配对同名 .sub）。
        // 若用户选了 .sub，自动映射到同名的 .idx，否则 mpv 无法渲染。
        final pickedExt = p.extension(subtitlePath).toLowerCase();
        if (pickedExt == '.sub') {
          final idxPath = '${p.withoutExtension(subtitlePath)}.idx';
          if (await File(idxPath).exists()) {
            subtitlePath = idxPath;
          }
        }
        setState(() {
          _subtitlePath = subtitlePath;
          _subtitleEnabled = true;
        });
        // 持久化该视频手动指定的字幕路径，退出重播后自动恢复。
        if (!widget.videoPath.startsWith('http://') &&
            !widget.videoPath.startsWith('https://') &&
            !widget.videoPath.startsWith('remote://')) {
          await PreferencesService.saveSubtitleMapping(widget.videoPath, subtitlePath);
        }
        _applySubtitle(subtitlePath);
      }
    } catch (e) {
      debugPrint('选择字幕文件失败: $e');
    }
  }

  void _showSubtitleSettings() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF1E1E2E),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        final isLandscape = MediaQuery.of(ctx).orientation == Orientation.landscape;
        final maxHeight = isLandscape 
            ? MediaQuery.of(ctx).size.height * 0.7 
            : MediaQuery.of(ctx).size.height * 0.9;
        
        return StatefulBuilder(
          builder: (ctx, setModalState) {
            return ConstrainedBox(
              constraints: BoxConstraints(maxHeight: maxHeight),
              child: SingleChildScrollView(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(20, 20, 20, 32),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Center(
                        child: Container(
                          width: 40, height: 4,
                          decoration: BoxDecoration(color: Colors.white24, borderRadius: BorderRadius.circular(2)),
                        ),
                      ),
                      const SizedBox(height: 20),
                      Row(
                        children: [
                          Icon(Icons.subtitles_rounded, color: Theme.of(ctx).colorScheme.primary, size: 24),
                          const SizedBox(width: 12),
                      Text(
                        L10n.of(ctx).msg_subtitle_menu,
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 20),
                  // 添加字幕按钮
                  ListTile(
                    leading: Icon(Icons.file_open_rounded, color: Colors.white70, size: 22),
                    title: Text(L10n.of(ctx).msg_add_subtitle, style: TextStyle(color: Colors.white, fontSize: 15)),
                    trailing: Icon(_subtitlePath != null ? Icons.check_circle : Icons.chevron_right,
                        color: _subtitlePath != null ? Theme.of(ctx).colorScheme.primary : Colors.white38, size: 22),
                    onTap: () async {
                      Navigator.pop(ctx);
                      await _addSubtitle();
                    },
                  ),
                  if (_subtitlePath != null) ...[
                    Divider(color: Colors.white12, height: 1),
                    // 字幕开关
                    SwitchListTile(
                      value: _subtitleEnabled,
                      onChanged: (v) {
                        setModalState(() => _subtitleEnabled = v);
                        _toggleSubtitle();
                      },
                      activeColor: Theme.of(ctx).colorScheme.primary,
                      title: Text(_subtitleEnabled ? L10n.of(ctx).msg_subtitle_on : L10n.of(ctx).msg_subtitle_off,
                          style: TextStyle(color: Colors.white, fontSize: 15)),
                      secondary: Icon(_subtitleEnabled ? Icons.subtitles_rounded : Icons.subtitles_off_rounded,
                          color: Colors.white70, size: 22),
                    ),
                  ],
                  Divider(color: Colors.white12, height: 1),
                  // 字幕大小滑块
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                    child: Row(
                      children: [
                        Icon(Icons.format_size, color: Colors.white70, size: 22),
                        const SizedBox(width: 16),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(L10n.of(ctx).msg_subtitle_size, style: TextStyle(color: Colors.white, fontSize: 15)),
                              const SizedBox(height: 8),
                              Row(
                                children: [
                                  Text('12', style: TextStyle(color: Colors.white38, fontSize: 12)),
                                  Expanded(
                                    child: Slider(
                                      value: _subtitleFontSize,
                                      min: 12,
                                      max: 60,
                                      divisions: 24,
                                      activeColor: Theme.of(ctx).colorScheme.primary,
                                      label: _subtitleFontSize.round().toString(),
                                      onChanged: (v) {
                                        setModalState(() => _subtitleFontSize = v);
                                        _applySubtitleFontSize(v);
                                        if (mounted) setState(() {});
                                      },
                                      onChangeEnd: (v) {
                                        PreferencesService.saveSubtitleFontSize(v);
                                      },
                                    ),
                                  ),
                                  Text('60', style: TextStyle(color: Colors.white38, fontSize: 12)),
                                  const SizedBox(width: 8),
                                  SizedBox(
                                    width: 36,
                                    child: Text(
                                      _subtitleFontSize.round().toString(),
                                      style: TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.bold),
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  Divider(color: Colors.white12, height: 1),
                  // 字幕位置滑块
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                    child: Row(
                      children: [
                        Icon(Icons.vertical_align_center, color: Colors.white70, size: 22),
                        const SizedBox(width: 16),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(L10n.of(ctx).msg_subtitle_position, style: TextStyle(color: Colors.white, fontSize: 15)),
                              const SizedBox(height: 8),
                              Row(
                                children: [
                                  Text(L10n.of(ctx).msg_subtitle_pos_top, style: TextStyle(color: Colors.white38, fontSize: 12)),
                                  Expanded(
                                    child: Slider(
                                      value: _subtitlePosition,
                                      min: 0,
                                      max: 100,
                                      divisions: 20,
                                      activeColor: Theme.of(ctx).colorScheme.primary,
                                      label: _subtitlePosition.round().toString(),
                                      onChanged: (v) {
                                        setModalState(() => _subtitlePosition = v);
                                        _applySubtitlePosition(v);
                                        if (mounted) setState(() {});
                                      },
                                      onChangeEnd: (v) {
                                        PreferencesService.saveSubtitlePosition(v);
                                      },
                                    ),
                                  ),
                                  Text(L10n.of(ctx).msg_subtitle_pos_bottom, style: TextStyle(color: Colors.white38, fontSize: 12)),
                                  const SizedBox(width: 8),
                                  SizedBox(
                                    width: 36,
                                    child: Text(
                                      _subtitlePosition.round().toString(),
                                      style: TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.bold),
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  Divider(color: Colors.white12, height: 1),
                  // 移除字幕背景透明层开关
                  SwitchListTile(
                    value: _subtitleNoBackground,
                    onChanged: (v) {
                      setModalState(() => _subtitleNoBackground = v);
                      _applySubtitleBackground();
                      PreferencesService.saveSubtitleNoBackground(v);
                    },
                    activeColor: Theme.of(ctx).colorScheme.primary,
                    title: Text(L10n.of(ctx).msg_subtitle_no_background,
                        style: TextStyle(color: Colors.white, fontSize: 15)),
                    secondary: Icon(Icons.layers_clear_rounded, color: Colors.white70, size: 22),
                  ),
                ],
              ),
                ),
              ),
            );
          },
        );
      },
    );
  }

  /// 视频播放器音频均衡器对话框（复用音频播放器的 mpv lavfi equalizer）。
  /// 仅含均衡器预设，不包含播放速度/音调（视频通过顶部菜单单独调速度）。
  void _showEqualizerDialog() {
    showDialog(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setModalState) {
          return DefaultTextStyle(
            style: const TextStyle(color: Colors.white),
            child: AlertDialog(
              backgroundColor: const Color(0xFF1E1E2E),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
              title: Row(
                children: [
                  const Icon(Icons.equalizer_rounded, color: Colors.deepPurpleAccent),
                  const SizedBox(width: 10),
                  Text(L10n.of(context).msgb7c87215, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 18)),
                ],
              ),
              content: SizedBox(
                width: double.maxFinite,
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(L10n.of(dialogContext).eq_presets, style: const TextStyle(color: Colors.white70, fontSize: 13, fontWeight: FontWeight.w600)),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        runSpacing: 6,
                        children: [
                          for (final preset in EqPreset.values)
                            _eqPresetChip(preset, setModalState),
                        ],
                      ),
                      const SizedBox(height: 16),
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
                            setModalState(() => _eqPreset = EqPreset.flat);
                            setState(() {});
                            _eqService.reset();
                            PreferencesService.saveAudioEqPreset('flat');
                          },
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(dialogContext),
                  child: Text(L10n.of(dialogContext).ui_done, style: const TextStyle(color: Colors.deepPurpleAccent, fontWeight: FontWeight.bold, fontSize: 16)),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  /// 均衡器预设芯片组件。
  Widget _eqPresetChip(EqPreset preset, StateSetter setModalState) {
    final isSelected = _eqPreset == preset;
    return ChoiceChip(
      label: Text(preset.labelL10n(L10n.of(context)), style: TextStyle(fontSize: 12, color: isSelected ? Colors.white : Colors.white70)),
      selected: isSelected,
      selectedColor: Colors.deepPurpleAccent,
      backgroundColor: const Color(0xFF2A2A3E),
      onSelected: (selected) {
        if (!selected) return;
        setModalState(() => _eqPreset = preset);
        setState(() {});
        _eqService.applyPreset(preset);
        PreferencesService.saveAudioEqPreset(preset.key);
      },
    );
  }

  void _applySubtitleFontSize(double size) {
    try {
      final platform = player.platform;
      if (platform is NativePlayer) {
        // 仅使用 sub-font-size 设置绝对字号。之前同时设置 sub-scale 会导致
        // SRT 双重缩放、ASS 因内嵌样式被忽略而“大小不生效”，故移除 sub-scale。
        platform.setProperty('sub-font-size', size.round().toString());
      }
    } catch (e) {
      debugPrint('设置字幕大小失败: $e');
    }
  }

  void _applySubtitlePosition(double pos) {
    try {
      final platform = player.platform;
      if (platform is NativePlayer) {
        platform.setProperty('sub-pos', pos.round().toString());
      }
    } catch (e) {
      debugPrint('设置字幕位置失败: $e');
    }
  }

  Future<void> _applySubtitleBackgroundProps(NativePlayer platform) async {
    try {
      if (_subtitleNoBackground) {
        // 移除字幕背景透明层：背景全透明、无边框、无阴影
        await platform.setProperty('sub-back-color', '#00000000');
        await platform.setProperty('sub-border-size', '0');
        await platform.setProperty('sub-shadow-offset', '0');
      } else {
        // 恢复默认：无边框背景色（透明）、有边框、有阴影
        await platform.setProperty('sub-back-color', '#00000000');
        await platform.setProperty('sub-border-size', '3');
        await platform.setProperty('sub-shadow-offset', '1');
      }
    } catch (e) {
      debugPrint('设置字幕背景失败: $e');
    }
  }

  void _applySubtitleBackground() {
    try {
      final platform = player.platform;
      if (platform is NativePlayer) {
        _applySubtitleBackgroundProps(platform);
      }
    } catch (e) {
      debugPrint('设置字幕背景失败: $e');
    }
  }

  void _initListeners() {
    player.stream.playing.listen((v) {
      if (!mounted) return;
      setState(() => _isPlaying = v);
    });

    player.stream.position.listen((p) {
      if (!mounted || _isSeeking) return;
      setState(() {
        _position = p;
        _sliderValue = p.inMilliseconds.toDouble();
      });
    });

    player.stream.duration.listen((d) {
      if (!mounted) return;
      setState(() => _duration = d);
      if (!_hasRestoredPosition && d > Duration.zero) {
        _restorePlaybackPosition();
      }
    });

    player.stream.buffering.listen((v) {
      if (!mounted) return;
      setState(() => _isBuffering = v);
    });

    player.stream.completed.listen((v) {
      if (!v || !mounted) return;
      _clearPlaybackPosition();
      if (_repeatMode == 1 || _repeatMode == 2) {
        player.seek(Duration.zero);
        player.play();
      }
    });
  }

  /// 监听可用音轨/字幕轨变化与当前选中轨道，用于音轨/字幕轨选择 UI。
  void _initTrackListeners() {
    _tracksSub = player.stream.tracks.listen((tracks) {
      if (!mounted) return;
      setState(() {
        _availableAudioTracks = tracks.audio;
        _availableSubtitleTracks = tracks.subtitle;
      });
      // mpv 自动选择的默认字幕轨若为位图字幕（如默认标记 VOBSub 的 MKV），
      // 需开启原生渲染才能显示
      _syncSubVisibilityFromMpv();
    });
    _trackSub = player.stream.track.listen((track) {
      if (!mounted) return;
      setState(() {
        _currentAudioTrack = track.audio;
        _currentSubtitleTrack = track.subtitle;
      });
    });
  }

  /// 选择音轨。传入 AudioTrack.no() 表示关闭音频。
  Future<void> _selectAudioTrack(AudioTrack track) async {
    if (!mounted) return;
    setState(() => _currentAudioTrack = track);
    await player.setAudioTrack(track);
  }

  /// 选择字幕轨。传入 SubtitleTrack.no() 表示关闭字幕。
  Future<void> _selectSubtitleTrack(SubtitleTrack track) async {
    if (!mounted) return;
    setState(() {
      _currentSubtitleTrack = track;
      _subtitleEnabled = track.id != 'no';
    });
    // 关键修复：在切换字幕轨之前先设置 sub-ass-override，避免 mpv 用错误的覆盖模式渲染
    // ASS/SSA 字幕需要 force 覆盖以应用样式；VOBSub 等位图字幕必须保持 no，否则不渲染
    final platform = player.platform;
    if (platform is NativePlayer) {
      try {
        if (track.id != 'no' && !_isLikelyAssSubtitle(track)) {
          // VOBSub 等位图字幕：必须先设为 no，再切换字幕轨
          await platform.setProperty('sub-ass-override', 'no');
        }
      } catch (_) {}
    }
    await player.setSubtitleTrack(track);
    // 关键修复：media_kit 默认 libass=false 会把 mpv 设为 sub-visibility=no
    // （解码但不渲染）。位图字幕（VOBSub/PGS）无文本，Flutter 侧无法显示，
    // 必须开启 mpv 原生渲染；文本字幕保持 no，由 Flutter 渲染。
    await _syncSubVisibilityForTrack(track);
    // 切换字幕轨后，再次确认 sub-ass-override 设置（确保 ASS/SSA 字幕启用 force）
    if (track.id != 'no' && _isLikelyAssSubtitle(track)) {
      if (platform is NativePlayer) {
        try {
          await platform.setProperty('sub-ass-override', 'force');
        } catch (_) {}
      }
    }
  }

  /// 判断字幕轨是否为 ASS/SSA 格式（基于标题/语言/文件扩展名启发式判断）。
  bool _isLikelyAssSubtitle(SubtitleTrack track) {
    final title = (track.title ?? '').toLowerCase();
    final language = (track.language ?? '').toLowerCase();
    // VOBSub 常见标识：vobsub, dvd, bitmap, idx, sub
    for (final keyword in ['vobsub', 'dvd', 'bitmap']) {
      if (title.contains(keyword) || language.contains(keyword)) return false;
    }
    for (final keyword in ['ass', 'ssa', 'advanced', 'substation']) {
      if (title.contains(keyword) || language.contains(keyword)) return true;
    }
    return false;
  }

  /// 判断字幕轨是否为位图字幕（VOBSub/PGS/DVB/XSub）。
  /// 位图字幕没有文本（mpv 的 sub-text 恒为空），Flutter 侧的 SubtitleView
  /// 与外挂字幕 overlay 均无法显示，只能由 mpv 原生渲染进视频画面。
  bool _isBitmapSubtitleTrack(SubtitleTrack track) {
    if (track.id == 'no' || track.id == 'auto') return false;
    final codec = (track.codec ?? '').toLowerCase();
    const bitmapCodecs = [
      'dvd_subtitle', // VOBSub（MKV 内嵌 / 外挂 .idx+.sub）
      'vobsub',
      'vob_subtitle',
      'hdmv_pgs_subtitle', // 蓝光 PGS
      'dvb_subtitle',
      'xsub',
    ];
    if (bitmapCodecs.any((c) => codec.contains(c))) return true;
    // 外挂字幕轨（id 为文件路径）：按扩展名判断
    final id = track.id.toLowerCase();
    if (id.endsWith('.idx') || id.endsWith('.sup')) return true;
    if (id.endsWith('.sub')) {
      // .sub 有二义性（VOBSub 位图 / MicroDVD 文本）：有同名 .idx 才是 VOBSub
      return File('${p.withoutExtension(track.id)}.idx').existsSync();
    }
    // 兜底：标题/语言含位图关键字
    final title = (track.title ?? '').toLowerCase();
    final language = (track.language ?? '').toLowerCase();
    for (final keyword in ['vobsub', 'pgs', 'bitmap']) {
      if (title.contains(keyword) || language.contains(keyword)) return true;
    }
    return false;
  }

  /// 按字幕轨类型同步 mpv 原生字幕渲染开关（sub-visibility）：
  /// - 位图字幕（VOBSub/PGS 等）：yes，由 mpv 渲染进视频画面
  /// - 文本字幕/关闭：no，保持 Flutter（SubtitleView/overlay）渲染
  ///
  /// 背景：media_kit 默认 libass=false 会把 mpv 设为 sub-visibility=no
  /// （解码但不渲染），导致内嵌 VOBSub 轨道"检测到却不显示"。
  /// Android 端 media_kit 同时设置了 sub-font-provider=none，mpv 渲染不出
  /// 文本字幕，因此文本轨道即使误开 yes 也不会与 Flutter 双重渲染。
  Future<void> _syncSubVisibilityForTrack(SubtitleTrack track) async {
    final platform = player.platform;
    if (platform is! NativePlayer) return;
    try {
      final visible = track.id != 'no' && _isBitmapSubtitleTrack(track);
      await platform.setProperty('sub-visibility', visible ? 'yes' : 'no');
    } catch (_) {}
  }

  /// 按 mpv 实际选中的字幕轨（sid）同步原生渲染开关。
  /// 覆盖"自动选择的默认字幕轨"场景（如默认标记为 VOBSub 的 MKV）；
  /// 用户显式选择轨道时以 _selectSubtitleTrack 的同步为准。
  Future<void> _syncSubVisibilityFromMpv() async {
    final platform = player.platform;
    if (platform is! NativePlayer) return;
    if (_currentSubtitleTrack.id != 'auto') return;
    try {
      final sid = await platform.getProperty('sid');
      if (sid == 'no' || sid == 'auto' || sid.isEmpty) {
        await platform.setProperty('sub-visibility', 'no');
        return;
      }
      SubtitleTrack? selected;
      for (final t in _availableSubtitleTracks) {
        if (t.id == sid) {
          selected = t;
          break;
        }
      }
      await platform.setProperty(
        'sub-visibility',
        selected != null && _isBitmapSubtitleTrack(selected) ? 'yes' : 'no',
      );
    } catch (_) {}
  }

  /// 显示音轨选择底部弹窗。
  void _showAudioTrackSelector() {
    if (!mounted) return;
    _hideTimer?.cancel();
    _showTrackSelectionSheet(
      title: L10n.of(context).msg_audio_track,
      tracks: _availableAudioTracks,
      currentTrack: _currentAudioTrack,
      getTrackId: (t) => t.id,
      getTrackLabel: (t) => _formatTrackLabel(t),
      onSelected: (t) {
        _selectAudioTrack(t);
        Navigator.of(context).pop();
      },
    );
    _startHideTimer();
  }

  /// 显示字幕轨选择底部弹窗。
  void _showSubtitleTrackSelector() {
    if (!mounted) return;
    _hideTimer?.cancel();
    _showTrackSelectionSheet(
      title: L10n.of(context).msg_subtitle_track,
      tracks: _availableSubtitleTracks,
      currentTrack: _currentSubtitleTrack,
      getTrackId: (t) => t.id,
      getTrackLabel: (t) => _formatTrackLabel(t),
      onSelected: (t) {
        _selectSubtitleTrack(t);
        Navigator.of(context).pop();
      },
    );
    _startHideTimer();
  }

  /// 格式化轨道显示标签：标题 > 语言 > ID。
  String _formatTrackLabel(dynamic track) {
    final title = track.title;
    final language = track.language;
    final id = track.id;
    if (title != null && title.isNotEmpty) {
      if (language != null && language.isNotEmpty) return '$title ($language)';
      return title;
    }
    if (language != null && language.isNotEmpty) return 'Track $id ($language)';
    return 'Track $id';
  }

  /// 通用轨道选择底部弹窗。
  void _showTrackSelectionSheet({
    required String title,
    required List<dynamic> tracks,
    required dynamic currentTrack,
    required String Function(dynamic) getTrackId,
    required String Function(dynamic) getTrackLabel,
    required void Function(dynamic) onSelected,
  }) {
    final l10n = L10n.of(context);
    final noTrackLabel = title.contains('Audio')
        ? l10n.msg_no_audio_track
        : l10n.msg_no_subtitle_track;
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.black87,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  title,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              if (tracks.isEmpty)
                Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(
                    noTrackLabel,
                    style: const TextStyle(color: Colors.white70, fontSize: 14),
                  ),
                )
              else
                Flexible(
                  child: ListView.builder(
                    shrinkWrap: true,
                    itemCount: tracks.length,
                    itemBuilder: (_, i) {
                      final t = tracks[i];
                      final selected = getTrackId(t) == getTrackId(currentTrack);
                      return ListTile(
                        dense: true,
                        leading: Icon(
                          selected ? Icons.check_circle : Icons.circle_outlined,
                          color: selected ? Theme.of(context).colorScheme.primary : Colors.white54,
                          size: 20,
                        ),
                        title: Text(
                          getTrackLabel(t),
                          style: TextStyle(
                            color: selected ? Theme.of(context).colorScheme.primary : Colors.white,
                            fontSize: 14,
                          ),
                        ),
                        onTap: () => onSelected(t),
                      );
                    },
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  /// 切换硬解/软解：销毁当前 Player/Controller 并用新 hwdec 重建，
  /// 重新打开同一媒体并恢复到切换前的播放位置与播放状态。
  Future<void> _switchHwdec(bool useHardware) async {
    if (useHardware == _useHardwareDecode) return;
    if (!mounted) return;
    final oldPlayer = player;
    final pos = oldPlayer.state.position;
    final wasPlaying = oldPlayer.state.playing;
    // 已解析的可播放地址：远程流优先 _currentStreamUrl，本地优先 _currentFilePath，否则原始路径
    final uri = _currentStreamUrl ?? _currentFilePath ?? widget.videoPath;

    setState(() => _isBuffering = true);

    player = Player(
      configuration: const PlayerConfiguration(
        ready: null,
        logLevel: MPVLogLevel.warn,
        bufferSize: 64 * 1024 * 1024,
      ),
    );
    controller = VideoController(
      player,
      configuration: VideoControllerConfiguration(
        hwdec: useHardware ? 'auto-safe' : 'no',
      ),
    );
    // 先让 Video 控件切到新 controller，再于下一帧释放旧的 Player；
    // 旧 VideoController 会随 oldPlayer.dispose() 内部的 release 回调自动释放
    //（VideoController 本身无 dispose() 方法），与本项目 dispose() 约定一致。
    setState(() {});
    WidgetsBinding.instance.addPostFrameCallback((_) {
      try {
        oldPlayer.dispose();
      } catch (_) {}
    });

    // 复用初始化的网络超时/字幕属性（不设置 sub-ass-override，避免破坏 VOBSub 渲染）
    try {
      final platform = player.platform;
      if (platform is NativePlayer) {
        await platform.setProperty('network-timeout', '60');
        // 与初始播放一致：所有解码模式都放大缓存/解复用缓冲，掩盖代理喂流抖动
        // （硬解默认路径此前只有 cache-secs=10，demuxer 缓冲极小 → 远程视频卡顿）。
        await platform.setProperty('cache-secs', '60');
        await platform.setProperty('demuxer-max-bytes', '300M');
        await platform.setProperty('demuxer-readahead-secs', '60');
        await platform.setProperty('sub-font-size', _subtitleFontSize.round().toString());
        await platform.setProperty('sub-pos', _subtitlePosition.round().toString());
        await _applySubtitleBackgroundProps(platform);
        // 切换到软解时启用性能优化
        if (!useHardware) {
          await _applySoftwareDecodeOptimizations(platform);
        }
      }
    } catch (e) {
      debugPrint('切换解码方式后设置属性失败: $e');
    }
    // 重建播放器后保持内部音量为最大，由系统音量统一控制
    player.setVolume(100.0);
    _initListeners();
    // 重建 Player 后重新注册轨道监听（旧订阅随旧 Player 失效）；
    // 重置字幕轨选择与外挂字幕 overlay（overlay 的进度订阅已随旧 Player 失效），
    // 位图字幕渲染开关由新会话的轨道事件按 mpv 实际选择重新同步。
    _currentSubtitleTrack = const SubtitleTrack('auto', null, null);
    _externalCues = const [];
    _activeCueIndex = -1;
    _initTrackListeners();
    await player.open(Media(uri), play: false);
    if (pos > Duration.zero) {
      try {
        await player.seek(pos);
      } catch (_) {}
    }
    if (wasPlaying) player.play();
    await PreferencesService.saveUseHardwareDecode(useHardware);
    if (mounted) {
      setState(() {
        _useHardwareDecode = useHardware;
        _isBuffering = false;
      });
    }
  }

  Future<void> _restorePlaybackPosition() async {
    if (_hasRestoredPosition) return;
    if (_currentFilePath != null) {
      final savedMs = PreferencesService.getVideoPlaybackPosition(_currentFilePath!);
      if (savedMs != null && savedMs > 0) {
        final savedPosition = Duration(milliseconds: savedMs);
        if (savedPosition < _duration - const Duration(seconds: 5)) {
          await player.seek(savedPosition);
        }
      }
      _startProgressSaveTimer();
    }
    await player.play();
    _hasRestoredPosition = true;
  }

  void _startProgressSaveTimer() {
    _progressSaveTimer?.cancel();
    _progressSaveTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (!mounted) return;
      _saveCurrentPlaybackPosition();
    });
  }

  /// 软解模式性能优化：调整 mpv 属性减少 CPU 解码压力，降低卡顿。
  /// 仅在 hwdec=no 时调用，硬解模式下不需要（GPU 已高效处理）。
  Future<void> _applySoftwareDecodeOptimizations(NativePlayer platform) async {
    try {
      // 多线程解码：0=自动根据 CPU 核心数分配线程
      await platform.setProperty('vd-lavc-threads', '0');
      // 跳过环路滤波：牺牲少量画质换取显著性能提升（软解卡顿的主要优化手段）
      await platform.setProperty('vd-lavc-skiploopfilter', 'all');
      // 允许丢帧保持音画同步：解码跟不上时优先保音频连续
      await platform.setProperty('frame-drop', 'decoder');
      // 增大解复用缓冲区，减少高码率视频卡顿
      await platform.setProperty('demuxer-max-bytes', '300M');
      await platform.setProperty('demuxer-readahead-secs', '60');
      // 增大播放缓存时长，减少网络视频卡顿
      await platform.setProperty('cache-secs', '60');
      // 快速解码模式：启用 libavcodec 内部优化
      await platform.setProperty('vd-lavc-fast', '1');
    } catch (e) {
      debugPrint('软解性能优化设置失败: $e');
    }
  }

  void _saveCurrentPlaybackPosition() {
    if (_currentFilePath == null) return;
    if (_position.inSeconds < 5) return;
    if (_position >= _duration - const Duration(seconds: 3)) return;
    PreferencesService.saveVideoPlaybackPosition(_currentFilePath!, _position.inMilliseconds);
    PreferencesService.saveLastPlayedVideo(_currentFilePath!, _fileName);
  }

  void _clearPlaybackPosition() {
    if (_currentFilePath != null) {
      PreferencesService.clearVideoPlaybackPosition(_currentFilePath!);
    }
  }

  void _startHideTimer() {
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(seconds: 4), () {
      if (mounted && _isPlaying && !_isSeeking) {
        _hideControls();
      }
    });
  }

  void _hideControls() {
    if (!mounted) return;
    _controlsAnimController.reverse();
    setState(() => _controlsVisible = false);
  }

  void _showControls() {
    if (!mounted) return;
    _controlsAnimController.forward();
    setState(() => _controlsVisible = true);
    _startHideTimer();
  }

  void _toggleControls() {
    if (_isLocked) return;
    if (_controlsVisible) {
      _hideControls();
    } else {
      _showControls();
    }
  }

  Future<void> _playAtIndex(int index) async {
    if (_effectivePlaylist == null && widget.assetPlaylist == null) return;
    final playlistLength = _effectivePlaylist?.length ?? widget.assetPlaylist?.length ?? 0;
    if (index < 0 || index >= playlistLength) return;

    _saveCurrentPlaybackPosition();
    _progressSaveTimer?.cancel();
    _hasRestoredPosition = false;

    // 重置上一视频的字幕状态：清空外挂字幕 overlay 避免跨视频残留显示，
    // 字幕轨恢复 auto 让 mpv 按新视频的默认轨道重新选择。
    _externalCues = const [];
    _activeCueIndex = -1;
    _subtitlePath = null;
    _subtitleEnabled = false;
    _currentSubtitleTrack = const SubtitleTrack('auto', null, null);
    try {
      final platform = player.platform;
      if (platform is NativePlayer) {
        // 关闭上一视频可能遗留的 mpv 原生字幕渲染（位图字幕开启过）
        await platform.setProperty('sub-visibility', 'no');
      }
    } catch (_) {}

    setState(() {
      _currentIndex = index;
      _position = Duration.zero;
      _duration = Duration.zero;
      _sliderValue = 0;
      _isBuffering = true;
    });

    // 清理上一次的远程流式会话
    await _stopCurrentStream();

    String? newPath;

    if (_effectivePlaylist != null) {
      final item = _effectivePlaylist![index];
      String playPath;
      if (item is String) {
        playPath = item;
      } else if (item is FileSystemEntity) {
        playPath = item.path;
      } else {
        playPath = '';
      }

      // 处理 remote:// 路径
      if (playPath.startsWith('remote://')) {
        final resolved = await _resolveRemotePath(playPath);
        if (resolved == null) {
          debugPrint('远程路径解析失败: $playPath');
          if (mounted) setState(() => _isBuffering = false);
          return;
        }
        _currentStreamUrl = resolved;
        playPath = resolved;
      }

      newPath = playPath;

      if (item is AssetEntity) {
        setState(() => _isResolvingAsset = true);
        try {
          final file = await item.file;
          if (file != null && mounted) {
            newPath = file.path;
            player.open(Media(file.path), play: false);
          }
        } catch (e) {
          debugPrint('Error resolving video asset: $e');
        } finally {
          if (mounted) setState(() => _isResolvingAsset = false);
        }
      } else {
        player.open(Media(playPath), play: false);
      }
    } else if (widget.assetPlaylist != null) {
      setState(() => _isResolvingAsset = true);
      try {
        final asset = widget.assetPlaylist![index];
        final file = await asset.file;
        if (file != null && mounted) {
          newPath = file.path;
          player.open(Media(file.path), play: false);
        }
      } catch (e) {
        debugPrint('Error resolving video asset: $e');
      } finally {
        if (mounted) setState(() => _isResolvingAsset = false);
      }
    }

    // 更新最后播放记录和当前文件路径
    if (newPath != null && newPath.isNotEmpty) {
      if (!newPath.startsWith('http://') && !newPath.startsWith('https://')) {
        _currentFilePath = newPath;
        final fileName = newPath.split(RegExp(r'[/\\]')).last;
        PreferencesService.saveLastPlayedVideo(newPath, fileName);
      }
      if (mounted) setState(() {});
    }

    _startHideTimer();
  }

  /// 停止当前远程流式播放会话
  Future<void> _stopCurrentStream() async {
    if (_currentStreamUrl != null) {
      await RemoteStreamingService.instance.stopStreaming(_currentStreamUrl!);
      _currentStreamUrl = null;
    }
  }

  /// 获取实际使用的播放列表（优先使用动态构建的列表）
  List<dynamic>? get _effectivePlaylist => _resolvedPlaylist ?? widget.playlist;

  /// 当 widget.playlist 为空时，自动从视频所在目录扫描视频文件构建播放列表
  Future<void> _resolvePlaylist() async {
    if (widget.playlist != null && widget.playlist!.isNotEmpty) {
      _resolvedPlaylist = widget.playlist;
      return;
    }
    if (widget.assetPlaylist != null && widget.assetPlaylist!.isNotEmpty) {
      return;
    }

    final currentPath = _getCurrentPlayPath();
    if (currentPath == null) return;
    // 远程路径不构建本地播放列表
    if (currentPath.startsWith('http://') ||
        currentPath.startsWith('https://') ||
        currentPath.startsWith('remote://')) {
      return;
    }

    try {
      final dir = File(currentPath).parent;
      if (!await dir.exists()) return;

      const videoExts = {
        '.mp4', '.mkv', '.avi', '.mov', '.wmv', '.flv',
        '.webm', '.m4v', '.3gp', '.ts', '.mpeg', '.mpg',
      };
      final entities = await dir.list().toList();
      final videos = entities.whereType<File>().where((f) {
        final ext = p.extension(f.path).toLowerCase();
        return videoExts.contains(ext);
      }).toList()
        ..sort((a, b) => a.path.compareTo(b.path));

      if (videos.length > 1 && mounted) {
        final idx = videos.indexWhere((f) => f.path == currentPath);
        setState(() {
          _resolvedPlaylist = videos;
          if (idx >= 0) _currentIndex = idx;
        });
      }
    } catch (e) {
      debugPrint('构建播放列表失败: $e');
    }
  }

  /// 获取当前播放路径（不包含 remote:// 等协议前缀）
  String? _getCurrentPlayPath() {
    if (widget.videoPath.startsWith('remote://')) {
      return null;
    }
    return widget.videoPath;
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
        return streamUrl;
      }

      // 非 HTTP 流协议（FTP/SFTP 等）：通过本地代理服务器
      // 独立连接用于按需随机读取（拖动进度条），与后台顺序下载分开会话
      final seekClient = FileManagerProvider.createRemoteClient(conn);
      try {
        await seekClient.connect();
        // 取文件大小，让代理以 206 可 seek 方式响应：
        //   1) 进度条需要总时长才能走动；
        //   2) 拖动进度条依赖 Range 随机读取（seekClient）。
        // 不传大小时代理只能用 chunked 200（不可 seek），表现为进度条不走、
        // 拖动后卡在"正在缓存中"。
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

  void _onNext() {
    final playlistLength = _effectivePlaylist?.length ?? widget.assetPlaylist?.length ?? 0;
    if (_currentIndex + 1 < playlistLength) {
      _playAtIndex(_currentIndex + 1);
    }
  }

  void _onPrevious() {
    if (_currentIndex - 1 >= 0) {
      _playAtIndex(_currentIndex - 1);
    }
  }

  void _onTogglePlayPause() {
    if (_isLocked) return;
    player.playOrPause();
    _showControls();
  }

  void _onHorizontalDragStart(DragStartDetails details) {
    if (_isLocked) return;
    _isHorizontalDragging = true;
    _dragStartX = details.globalPosition.dx;
    _dragStartPosition = _position;
    _dragSeekDelta = 0;
    _hideTimer?.cancel();
    // Pause & show frame preview container
    player.pause();
    setState(() {
      _isPreviewDragging = true;
      _previewImage = null;
      _previewTarget = _position;
    });
    _schedulePreviewCapture();
  }

  void _onHorizontalDragUpdate(DragUpdateDetails details) {
    if (_isLocked || !_isHorizontalDragging) return;
    final screenWidth = MediaQuery.of(context).size.width;
    final totalSeconds = _duration.inSeconds;
    if (screenWidth <= 0 || totalSeconds <= 0) return;
    final deltaX = details.globalPosition.dx - _dragStartX;
    final seekSec = (deltaX / screenWidth * totalSeconds / 2).round();
    final targetPos = _dragStartPosition + Duration(seconds: seekSec);
    final clampedMs = targetPos.inMilliseconds.clamp(Duration.zero.inMilliseconds, _duration.inMilliseconds);
    final clampedTarget = Duration(milliseconds: clampedMs);
    setState(() {
      _dragSeekDelta = seekSec;
      _seekSeconds = seekSec.abs();
      _showSeekRight = seekSec > 0;
      _showSeekLeft = seekSec < 0;
      _previewTarget = clampedTarget;
    });
    _schedulePreviewCapture();
  }

  void _onHorizontalDragEnd(DragEndDetails details) {
    if (_isLocked || !_isHorizontalDragging) return;
    _isHorizontalDragging = false;
    final newPos = _dragStartPosition + Duration(seconds: _dragSeekDelta);
    final clampedMs = newPos.inMilliseconds.clamp(Duration.zero.inMilliseconds, _duration.inMilliseconds);
    final target = Duration(milliseconds: clampedMs);
    player.seek(target);
    _previewDebounceTimer?.cancel();
    setState(() {
      _isPreviewDragging = false;
      _previewImage = null;
    });
    _seekIndicatorTimer?.cancel();
    _seekIndicatorTimer = Timer(const Duration(milliseconds: 400), () {
      if (mounted) {
        setState(() {
          _showSeekLeft = false;
          _showSeekRight = false;
          _seekSeconds = 0;
        });
      }
    });
    _startHideTimer();
  }

  /// Debounced frame capture: seeks to [_previewTarget] and takes a screenshot,
  /// throttled so frequent drag updates don't hammer the player.
  void _schedulePreviewCapture() {
    if (!mounted || !_isPreviewDragging) return;
    _previewDebounceTimer?.cancel();
    _previewDebounceTimer = Timer(const Duration(milliseconds: 400), () async {
      if (!mounted || !_isPreviewDragging) return;
      try {
        await player.seek(_previewTarget);
        final bytes = await player.screenshot();
        if (mounted && _isPreviewDragging) {
          setState(() => _previewImage = bytes);
        }
      } catch (_) {}
    });
  }

  void _onVerticalDragUpdate(DragUpdateDetails details, bool isLeft) {
    if (_isLocked) return;
    final delta = -details.primaryDelta! / 250.0;
    if (isLeft) {
      final newVolume = (_volume + delta).clamp(0.0, 1.0);
      _setSystemVolume(newVolume);
      setState(() {
        _volume = newVolume;
        _isMuted = newVolume == 0;
        _showVolumeSlider = true;
        _showBrightnessSlider = false;
      });
    } else {
      setState(() {
        _brightness = (_brightness + delta).clamp(0.1, 1.0);
        _showBrightnessSlider = true;
        _showVolumeSlider = false;
      });
    }

    _sliderTimer?.cancel();
    _sliderTimer = Timer(const Duration(milliseconds: 1200), () {
      if (mounted) {
        setState(() {
          _showVolumeSlider = false;
          _showBrightnessSlider = false;
        });
      }
    });
  }

  /// 从系统读取当前媒体音量并同步到 UI。
  /// 将播放器内部音量固定为 100，让系统音量成为唯一控制层。
  Future<void> _syncVolumeFromSystem({bool setPlayerVolume = false}) async {
    try {
      final systemVolume = await _volumeChannel.invokeMethod<double>('getStreamVolume');
      if (systemVolume == null || !mounted) return;
      final changed = (_volume - systemVolume).abs() > 0.001;
      if (changed) {
        setState(() {
          _volume = systemVolume;
          _isMuted = systemVolume == 0;
          _showVolumeSlider = true;
        });
        _sliderTimer?.cancel();
        _sliderTimer = Timer(const Duration(milliseconds: 1200), () {
          if (mounted) setState(() => _showVolumeSlider = false);
        });
      }
      if (setPlayerVolume) {
        player.setVolume(100.0);
      }
    } catch (e) {
      debugPrint('同步系统音量失败: $e');
    }
  }

  /// 设置系统媒体音量（0.0 ~ 1.0）。
  Future<void> _setSystemVolume(double volume) async {
    try {
      await _volumeChannel.invokeMethod('setStreamVolume', {'volume': volume});
    } catch (e) {
      debugPrint('设置系统音量失败: $e');
    }
  }

  /// 启动轮询，确保通知面板等外部音量调节能实时同步到应用内滑块。
  void _startVolumePolling() {
    _volumePollTimer?.cancel();
    _volumePollTimer = Timer.periodic(const Duration(milliseconds: 300), (_) {
      _syncVolumeFromSystem();
    });
  }

  void _stopVolumePolling() {
    _volumePollTimer?.cancel();
    _volumePollTimer = null;
  }

  void _startLongPress() {
    if (_isLocked) return;
    _previousSpeed = _playbackSpeed;
    player.setRate(2.0);
    setState(() => _isLongPressSpeed = true);
  }

  void _endLongPress() {
    if (!_isLongPressSpeed) return;
    player.setRate(_previousSpeed);
    setState(() => _isLongPressSpeed = false);
  }

  void _toggleFullScreen() {
    // 手动全屏按钮：切换目标全屏状态，并强制/恢复相应方向。
    // 与系统自动旋转解耦——用户明确意图优先（手动锁定/解锁横屏）。
    final newFullScreen = !_isFullScreen;
    _userLockedFullScreen = newFullScreen;
    setState(() => _isFullScreen = newFullScreen);
    if (newFullScreen) {
      // 进入全屏：锁定横屏 + 沉浸（无论当前是竖屏还是横屏，都确保横屏全屏）。
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
      // edge-to-edge：让视频画面铺满系统手势区，消除左侧固定黑边。
      _setEdgeToEdge(true);
      SystemChrome.setPreferredOrientations([
        DeviceOrientation.landscapeRight,
        DeviceOrientation.landscapeLeft,
      ]);
    } else {
      // 退出全屏：
      // - 若当前处于横屏（多为系统自动进入全屏后再手动退出），强制转回竖屏，
      //   避免出现"横屏但非全屏"的旋转画面观感；
      // - 恢复允许横竖屏（交还系统自动旋转），按偏好显示系统栏。
      // 复位 edge-to-edge，交还系统手势区避让（由 SafeArea 处理）。
      _setEdgeToEdge(false);
      final forcePortrait = _currentOrientation == Orientation.landscape;
      final hideNav = PreferencesService.getHideNavigationBar();
      if (hideNav) {
        SystemChrome.setEnabledSystemUIMode(
          SystemUiMode.manual,
          overlays: [SystemUiOverlay.top],
        );
      } else {
        SystemChrome.setEnabledSystemUIMode(
          SystemUiMode.manual,
          overlays: SystemUiOverlay.values,
        );
      }
      SystemChrome.setPreferredOrientations(
        forcePortrait
            ? [DeviceOrientation.portraitUp]
            : [
                DeviceOrientation.landscapeRight,
                DeviceOrientation.landscapeLeft,
                DeviceOrientation.portraitUp,
              ],
      );
    }
    _showControls();
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    _positionSub?.cancel();
    _tracksSub?.cancel();
    _trackSub?.cancel();
    _seekIndicatorTimer?.cancel();
    _previewDebounceTimer?.cancel();
    _sliderTimer?.cancel();
    _volumePollTimer?.cancel();
    _cacheCheckTimer?.cancel();
    _aspectToastTimer?.cancel();
    _progressSaveTimer?.cancel();
    _saveCurrentPlaybackPosition();
    _controlsAnimController.dispose();
    // 清理远程流式会话：fire-and-forget 但确保异步执行。
    // dispose() 不能是 async（Framework 要求 void），
    // 但 stopStreaming 内部会调用 client.disconnect() 取消下载。
    _stopCurrentStream();
    _eqService.detach();
    player.dispose();
    // 离开播放页复位 edge-to-edge，避免影响其它页面布局。
    _setEdgeToEdge(false);
    final hideNav = PreferencesService.getHideNavigationBar();
    if (hideNav) {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.manual, overlays: [SystemUiOverlay.top]);
    } else {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.manual, overlays: SystemUiOverlay.values);
    }
    SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
    super.dispose();
  }

  /// 全屏时启用 edge-to-edge（视频画面延伸到系统手势导航区，消除左侧固定黑边）；
  /// 退出全屏复位，由 Flutter SafeArea 恢复正常避让。
  static const MethodChannel _edgeToEdgeChannel =
      MethodChannel('com.sequl.zenfile/edge_to_edge');

  Future<void> _setEdgeToEdge(bool enable) async {
    try {
      await _edgeToEdgeChannel.invokeMethod(enable ? 'enable' : 'disable');
    } on PlatformException catch (e) {
      debugPrint('[ZenFile] edge-to-edge failed: $e');
    }
  }

  String get _fileName {
    String currentPath = widget.videoPath;
    if (_effectivePlaylist != null && _currentIndex < _effectivePlaylist!.length) {
      final item = _effectivePlaylist![_currentIndex];
      if (item is String) {
        currentPath = item;
      } else if (item is FileSystemEntity) {
        currentPath = item.path;
      } else if (item is AssetEntity) {
        currentPath = item.title ?? 'Video';
      }
    } else if (widget.assetPlaylist != null && _currentIndex < widget.assetPlaylist!.length) {
      currentPath = widget.assetPlaylist![_currentIndex].title ?? 'Video';
    }
    final name = currentPath.split('/').last.split('\\').last;
    return name.length > 40 ? '${name.substring(0, 37)}...' : name;
  }

  /// 格式化时长为 HH:MM:SS / MM:SS
  String _formatDuration(Duration d) {
    if (d < Duration.zero) d = Duration.zero;
    final h = d.inHours;
    final m = d.inMinutes.remainder(60);
    final s = d.inSeconds.remainder(60);
    if (h > 0) {
      return '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
    }
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }

  /// 水平拖拽时的帧预览画面：显示截取帧缩略图 + 时间戳
  Widget _buildFramePreview() {
    final timeStr = _formatDuration(_previewTarget);
    return Container(
      width: 200,
      height: 120,
      decoration: BoxDecoration(
        color: Colors.black,
        borderRadius: BorderRadius.circular(8),
        boxShadow: const [
          BoxShadow(color: Colors.black54, blurRadius: 12, spreadRadius: 2),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          Expanded(
            child: _previewImage != null
                ? Image.memory(
                    _previewImage!,
                    fit: BoxFit.contain,
                    gaplessPlayback: true,
                  )
                : Container(
                    color: Colors.black87,
                    child: const Center(
                      child: SizedBox(
                        width: 24,
                        height: 24,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white70,
                        ),
                      ),
                    ),
                  ),
          ),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(vertical: 4),
            color: Colors.black87,
            child: Text(
              timeStr,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 12,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 根据当前伸缩比例模式构建视频画面。
  /// 参照 VLC (libVLC MediaPlayer.ScaleType) 的语义实现：
  /// - 0 原始比例  = BEST_FIT   等比例适配，可能留黑边 (BoxFit.contain)
  /// - 1 拉伸填充  = FILL       拉伸填满，画面会变形   (BoxFit.fill)
  /// - 2 居中      = ORIGINAL   原始尺寸居中           (BoxFit.none)
  /// - 3 填充屏幕  = FIT_SCREEN 等比例裁剪填满，无黑边 (BoxFit.cover)
  /// - 4 16:9      = 锁定容器比例 + 视频等比例裁剪填满 (AspectRatio + cover)
  /// - 5 4:3       = 同上
  /// - 6 自定义    = 同上
  /// 关键点：固定比例旧实现用了 BoxFit.fill 导致画面被拉伸变形（与 VLC 不符）；
  /// VLC 的 SURFACE_xx 是将 Surface 容器锁定为指定比例、视频以 cover 方式填充，
  /// 因此这里固定比例统一改用 BoxFit.cover（等比例裁切，不变形、无黑边）。
  Widget _buildVideoSurface() {
    BoxFit fit;
    double? forcedRatio;
    switch (_aspectRatioMode) {
      case 1: // 拉伸填充
        fit = BoxFit.fill;
        break;
      case 2: // 居中（原始尺寸）
        fit = BoxFit.none;
        break;
      case 3: // 填充屏幕（裁剪填满，无黑边，贴合 MX/VLC 默认观感）
        fit = BoxFit.cover;
        break;
      case 4: // 16:9（锁定容器比例 + 等比例裁剪填满，不变形）
        fit = BoxFit.cover;
        forcedRatio = 16 / 9;
        break;
      case 5: // 4:3
        fit = BoxFit.cover;
        forcedRatio = 4 / 3;
        break;
      case 6: // 自定义
        fit = BoxFit.cover;
        forcedRatio = _customAspectRatio;
        break;
      default: // 0 原始比例
        fit = BoxFit.contain;
    }

    // 全屏且用户未手动切换缩放时，自动以 cover 填满屏幕，消除左右/上下黑边
    // （贴近 MX / VLC FIT_SCREEN 观感）；用户一旦手动切过缩放档，则尊重其选择。
    // 注意：此行为已被移除，因为用户期望全屏时保持原始比例（contain），
    // 而非自动裁剪填满。若需裁剪填满，可手动切换到「填充屏幕」模式。
    // 保留注释以说明历史行为。

    Widget video = Video(
      controller: controller,
      controls: NoVideoControls,
      fit: fit,
    );
    if (forcedRatio != null) {
      video = Center(
        child: AspectRatio(
          aspectRatio: forcedRatio,
          child: video,
        ),
      );
    }
    return RotatedBox(
      quarterTurns: _rotationTurns,
      child: video,
    );
  }

  /// 获取当前伸缩比例模式的多语言提示词
  String _aspectRatioLabel() {
    final l10n = L10n.of(context);
    switch (_aspectRatioMode) {
      case 1:
        return l10n.msg_aspect_fill;
      case 2:
        return l10n.msg_aspect_center;
      case 3:
        return l10n.msg_aspect_fill_screen;
      case 4:
        return l10n.msg_aspect_16_9;
      case 5:
        return l10n.msg_aspect_4_3;
      case 6:
        return '${l10n.msg_aspect_custom} ${_customAspectRatio.toStringAsFixed(2)}';
      default:
        return l10n.msg_aspect_fit;
    }
  }

  /// 切换伸缩比例并显示提示词
  void _toggleAspectRatio() {
    setState(() {
      _userTouchedAspect = true;
      _aspectRatioMode = (_aspectRatioMode + 1) % 7;
      _aspectToast = _aspectRatioLabel();
    });
    _aspectToastTimer?.cancel();
    _aspectToastTimer = Timer(const Duration(milliseconds: 1500), () {
      if (mounted) setState(() => _aspectToast = null);
    });
    _showControls();
  }

  /// 显示自定义缩放比例输入对话框
  void _showCustomAspectRatioDialog() {
    final controller = TextEditingController(text: _customAspectRatio.toStringAsFixed(2));
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(L10n.of(context).msg_custom_aspect_ratio),
        content: TextField(
          controller: controller,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: InputDecoration(
            hintText: '16:9 = 1.78, 21:9 = 2.33',
            suffixText: ':1',
          ),
          autofocus: true,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(L10n.of(context).ui_cancel),
          ),
          TextButton(
            onPressed: () {
              final value = double.tryParse(controller.text.replaceAll(',', '.'));
              if (value != null && value > 0.1 && value < 10.0) {
                setState(() {
                  _userTouchedAspect = true;
                  _customAspectRatio = value;
                  _aspectRatioMode = 6;
                  _aspectToast = _aspectRatioLabel();
                });
                PreferencesService.saveVideoCustomAspectRatio(value);
                _aspectToastTimer?.cancel();
                _aspectToastTimer = Timer(const Duration(milliseconds: 1500), () {
                  if (mounted) setState(() => _aspectToast = null);
                });
              }
              Navigator.pop(ctx);
            },
            child: Text(L10n.of(context).ui_confirm),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // 系统方向变化 -> 自动同步全屏状态（系统驱动，不强制方向，由系统自动旋转决定）。
    // 用 addPostFrameCallback 避免在 build 期间直接 setState 触发断言。
    final orientation = MediaQuery.of(context).orientation;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _currentOrientation = orientation;
        _syncFullScreenWithOrientation(orientation);
      }
    });
    // 全屏时移除系统手势/导航区的 padding，确保视频画面铺满（消除左侧固定黑边）。
    // 配合原生 edge-to-edge 使用；即便 ROM 仍上报 inset，此处也把画面推到屏幕边缘。
    final videoBody = _isFullScreen
        ? MediaQuery.removePadding(
            context: context,
            removeLeft: true,
            removeRight: true,
            removeTop: true,
            removeBottom: true,
            child: _buildVideoSurface(),
          )
        : _buildVideoSurface();

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          // Main Video Surface (支持顺时针旋转 + 伸缩比例切换)
          videoBody,

          // 外挂字幕 Flutter overlay（字号/位置由滑块控制，对所有格式 100% 生效）
          if (_subtitleEnabled && _externalCues.isNotEmpty && _activeCueIndex >= 0)
            Positioned.fill(
              child: IgnorePointer(
                child: Align(
                  alignment: Alignment(0.0, (_subtitlePosition / 100 * 2) - 1),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Text(
                      _externalCues[_activeCueIndex].text,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: _subtitleFontSize,
                        color: Colors.white,
                        fontWeight: FontWeight.w500,
                        backgroundColor: _subtitleNoBackground
                            ? null
                            : Colors.black.withOpacity(0.55),
                        shadows: const [
                          Shadow(
                            offset: Offset(1, 1),
                            blurRadius: 2,
                            color: Colors.black,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),

          // Brightness Dimming Overlay
          IgnorePointer(
            child: Container(
              color: Colors.black.withOpacity(1.0 - _brightness),
            ),
          ),

          // Animated Buffering / Asset Resolution Indicator
          if (_isBuffering || _isResolvingAsset || _isWaitingForCache)
            Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const VideoLoadingIndicator(),
                  const SizedBox(height: 16),
                  Text(
                    (widget.isRemote && (_isWaitingForCache || _isBuffering)) ? L10n.of(context).ui_caching : '',
                    style: const TextStyle(color: Colors.white70, fontSize: 14),
                  ),
                ],
              ),
            ),

          // Gesture Zones (Horizontal Drag Seek, Double Tap Play/Pause, Long Press Speed)
          Row(
            children: [
              Expanded(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onDoubleTap: _onTogglePlayPause,
                  onTap: _toggleControls,
                  onLongPressStart: (_) => _startLongPress(),
                  onLongPressEnd: (_) => _endLongPress(),
                  onHorizontalDragStart: _onHorizontalDragStart,
                  onHorizontalDragUpdate: _onHorizontalDragUpdate,
                  onHorizontalDragEnd: _onHorizontalDragEnd,
                  onVerticalDragUpdate: (d) => _onVerticalDragUpdate(d, true),
                  child: const SizedBox.expand(),
                ),
              ),
              Expanded(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onDoubleTap: _onTogglePlayPause,
                  onTap: _toggleControls,
                  onLongPressStart: (_) => _startLongPress(),
                  onLongPressEnd: (_) => _endLongPress(),
                  onHorizontalDragStart: _onHorizontalDragStart,
                  onHorizontalDragUpdate: _onHorizontalDragUpdate,
                  onHorizontalDragEnd: _onHorizontalDragEnd,
                  onVerticalDragUpdate: (d) => _onVerticalDragUpdate(d, false),
                  child: const SizedBox.expand(),
                ),
              ),
            ],
          ),

          // Double Tap Seek Ripple Waves
          if (_showSeekLeft)
            Positioned(
              left: 0,
              top: 0,
              bottom: 0,
              width: MediaQuery.of(context).size.width * 0.45,
              child: IgnorePointer(
                child: Container(
                  decoration: BoxDecoration(
                    gradient: RadialGradient(
                      center: Alignment.centerRight,
                      radius: 1.0,
                      colors: [Colors.white.withOpacity(0.2), Colors.transparent],
                    ),
                  ),
                ),
              ),
            ),
          if (_showSeekRight)
            Positioned(
              right: 0,
              top: 0,
              bottom: 0,
              width: MediaQuery.of(context).size.width * 0.45,
              child: IgnorePointer(
                child: Container(
                  decoration: BoxDecoration(
                    gradient: RadialGradient(
                      center: Alignment.centerLeft,
                      radius: 1.0,
                      colors: [Colors.white.withOpacity(0.2), Colors.transparent],
                    ),
                  ),
                ),
              ),
            ),

          // Animated Seek Badge Overlays
          if (_showSeekLeft)
            Positioned(
              left: 64,
              top: 0,
              bottom: 0,
              child: Center(
                child: VideoSeekIndicator(
                  forward: false,
                  seconds: _seekSeconds,
                ),
              ),
            ),
          if (_showSeekRight)
            Positioned(
              right: 64,
              top: 0,
              bottom: 0,
              child: Center(
                child: VideoSeekIndicator(
                  forward: true,
                  seconds: _seekSeconds,
                ),
              ),
            ),

          // Frame Preview overlay during horizontal drag
          if (_isPreviewDragging)
            Positioned.fill(
              child: Center(
                child: IgnorePointer(
                  child: _buildFramePreview(),
                ),
              ),
            ),

          // Long Press Speed Badge
          if (_isLongPressSpeed)
            Positioned(
              left: 0,
              right: 0,
              child: SafeArea(
                top: !_isFullScreen,
                bottom: false,
                child: Padding(
                  padding: const EdgeInsets.only(top: 60),
                  child: Center(
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                      decoration: BoxDecoration(
                        color: Colors.black.withOpacity(0.75),
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(color: Colors.white.withOpacity(0.2), width: 1),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Broken.forward, color: Colors.deepPurpleAccent.shade100, size: 20),
                          const SizedBox(width: 8),
                          Text(
                            L10n.of(context).msg_speed_2x,
                            style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.bold),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),

          // Vertical Volume & Brightness Pill Sliders
          if (_showVolumeSlider)
            Positioned(
              left: 36,
              top: 0,
              bottom: 0,
              child: Center(
                child: VerticalSliderWidget(
                  value: _isMuted ? 0.0 : _volume,
                  icon: _isMuted || _volume == 0
                      ? Broken.volume_slash
                      : _volume > 0.5
                          ? Broken.volume_high
                          : Broken.volume_low,
                  label: '音量',
                ),
              ),
            ),
          if (_showBrightnessSlider)
            Positioned(
              right: 36,
              top: 0,
              bottom: 0,
              child: Center(
                child: VerticalSliderWidget(
                  value: _brightness,
                  icon: Broken.sun_1,
                  label: '亮度',
                ),
              ),
            ),

          // Aspect Ratio Toggle Toast
          if (_aspectToast != null)
            Positioned(
              left: 0,
              right: 0,
              child: SafeArea(
                top: !_isFullScreen,
                bottom: false,
                child: Padding(
                  padding: const EdgeInsets.only(top: 60),
                  child: Center(
                    child: IgnorePointer(
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                        decoration: BoxDecoration(
                          color: Colors.black.withOpacity(0.75),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: Colors.white.withOpacity(0.2), width: 1),
                        ),
                        child: Text(
                          _aspectToast!,
                          style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),

          // Modular Controls Overlay
          FadeTransition(
            opacity: _controlsOpacity,
            child: IgnorePointer(
              ignoring: !_controlsVisible,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  VideoControlsOverlay(
                    title: _fileName,
                    isPlaying: _isPlaying,
                    position: _position,
                    duration: _duration,
                    sliderValue: _sliderValue,
                    playbackSpeed: _playbackSpeed,
                    isFullScreen: _isFullScreen,
                    isLocked: false,
                    isMuted: _isMuted,
                    repeatMode: _repeatMode,
                    rotationTurns: _rotationTurns,
                    aspectRatioMode: _aspectRatioMode,
                    onChanged: (v) => setState(() => _sliderValue = v),
                    onChangeStart: (_) {
                      _isSeeking = true;
                      _hideTimer?.cancel();
                    },
                    onChangeEnd: (v) {
                      _isSeeking = false;
                      player.seek(Duration(milliseconds: v.toInt()));
                      _startHideTimer();
                    },
                    onPlayPause: () => player.playOrPause(),
                    onRewind: () {
                      player.seek(_position - const Duration(seconds: 10));
                      _showControls();
                    },
                    onFastForward: () {
                      player.seek(_position + const Duration(seconds: 10));
                      _showControls();
                    },
                    onPrevious: (_effectivePlaylist != null || widget.assetPlaylist != null) && _currentIndex > 0 ? _onPrevious : null,
                    onNext: (_effectivePlaylist != null || widget.assetPlaylist != null) && _currentIndex + 1 < (_effectivePlaylist?.length ?? widget.assetPlaylist?.length ?? 0) ? _onNext : null,
                    onToggleFullScreen: _toggleFullScreen,
                    onSelectSpeed: (v) {
                      setState(() => _playbackSpeed = v);
                      player.setRate(v);
                      _showControls();
                    },
                    onToggleLock: () {
                      setState(() => _isLocked = !_isLocked);
                      _showControls();
                    },
                    onToggleMute: () {
                      if (_isMuted) {
                        final target = _volumeBeforeMute > 0 ? _volumeBeforeMute : 0.5;
                        _setSystemVolume(target);
                        setState(() {
                          _volume = target;
                          _isMuted = false;
                        });
                      } else {
                        _volumeBeforeMute = _volume > 0 ? _volume : 0.5;
                        _setSystemVolume(0);
                        setState(() {
                          _volume = 0;
                          _isMuted = true;
                        });
                      }
                      _showControls();
                    },
                    onToggleRepeat: () {
                      setState(() => _repeatMode = (_repeatMode + 1) % 3);
                      _showControls();
                    },
                    onRotate: () {
                      setState(() => _rotationTurns = (_rotationTurns + 1) % 4);
                      _showControls();
                    },
                    onToggleAspectRatio: _toggleAspectRatio,
                    onCustomAspectRatio: _showCustomAspectRatioDialog,
                    onAddSubtitle: _addSubtitle,
                    onSubtitleSettings: _showSubtitleSettings,
                    onEqualizer: _showEqualizerDialog,
                    onToggleSubtitle: _toggleSubtitle,
                    onSelectAudioTrack: _showAudioTrackSelector,
                    onSelectSubtitleTrack: _showSubtitleTrackSelector,
                    onOpenPlaylist: _showPlaylist,
                    subtitleEnabled: _subtitleEnabled,
                    subtitlePath: _subtitlePath,
                    hasAudioTracks: _availableAudioTracks.length > 2,
                    hasSubtitleTracks: _availableSubtitleTracks.length > 2,
                    onInteract: _showControls,
                    useHardwareDecode: _useHardwareDecode,
                    onToggleHwdec: () => _switchHwdec(!_useHardwareDecode),
                  ),
                ],
              ),
            ),
          ),

          // Lock Indicator - Always visible when locked
          if (_isLocked)
            Positioned(
              top: 32,
              left: 24,
              child: SafeArea(
                top: !_isFullScreen,
                bottom: !_isFullScreen,
                child: GestureDetector(
                  onTap: () {
                    setState(() => _isLocked = false);
                    _showControls();
                  },
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
                    decoration: BoxDecoration(
                      color: Colors.black.withOpacity(0.75),
                      borderRadius: BorderRadius.circular(24),
                      border: Border.all(color: Colors.white.withOpacity(0.25), width: 1.5),
                      boxShadow: [
                        BoxShadow(color: Theme.of(context).colorScheme.primary.withOpacity(0.4), blurRadius: 16),
                      ],
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Broken.lock, color: Theme.of(context).colorScheme.primary, size: 22),
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
            ),
        ],
      ),
    );
  }
}
