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
import 'package:zenfile/services/remote/remote_client.dart';
import 'package:zenfile/services/remote_streaming_service.dart';
import 'package:zenfile/services/network_connections_service.dart';
import 'package:zenfile/providers/file_manager_provider.dart';
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
  late final Player player;
  late final VideoController controller;

  late int _currentIndex;
  bool _isResolvingAsset = false;

  bool _controlsVisible = true;
  bool _isPlaying = false;
  bool _isSeeking = false;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  double _sliderValue = 0;
  bool _isFullScreen = false;
  bool _isLocked = false;
  double _playbackSpeed = 1.0;
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

  Timer? _hideTimer;
  late AnimationController _controlsAnimController;
  late Animation<double> _controlsOpacity;

  // Double-tap seek accumulation & animation
  bool _showSeekLeft = false;
  bool _showSeekRight = false;
  Timer? _seekIndicatorTimer;
  int _seekSeconds = 0;
  bool _lastSeekWasForward = true;

  // Long press 2.0x speed
  bool _isLongPressSpeed = false;
  double _previousSpeed = 1.0;

  // Utilities
  bool _isMuted = false;
  int _repeatMode = 0; // 0=none, 1=one, 2=all
  int _rotationTurns = 0; // 0=0°, 1=90°顺时针, 2=180°, 3=270°
  int _aspectRatioMode = 0; // 0=适应屏幕, 1=拉伸填充, 2=居中, 3=16:9, 4=4:3
  String? _aspectToast;
  Timer? _aspectToastTimer;

  @override
  void initState() {
    super.initState();
    _currentIndex = widget.initialIndex ?? 0;

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

    player = Player(
      configuration: const PlayerConfiguration(
        ready: null,
        logLevel: MPVLogLevel.warn,
        bufferSize: 32 * 1024 * 1024,
      ),
    );
    controller = VideoController(
      player,
      configuration: const VideoControllerConfiguration(
        hwdec: 'auto-safe',
      ),
    );

    // 覆盖 media_kit 硬编码的 network-timeout=5s。
    // SMB/FTP/SFTP 建立连接+认证可能需要 5-10s，5s 超时会导致 libmpv
    // 在数据到达前就放弃播放。设为 60s 给本地代理足够时间启动下载。
    // 必须在 _startPlayback 之前完成，否则播放已经开始读取超时值。
    _initListeners();
    () async {
      try {
        final platform = player.platform;
        if (platform is NativePlayer) {
          await platform.setProperty('network-timeout', '60');
          await platform.setProperty('cache-secs', '10');
        }
      } catch (e) {
        debugPrint('设置 network-timeout 失败: $e');
      }
      _startPlayback();
    }();
    player.setVolume(_volume * 100.0);
    _startHideTimer();
  }

  void _startPlayback() async {
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
      player.open(Media(resolved));
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
    player.open(Media(widget.videoPath));
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
    });

    player.stream.buffering.listen((v) {
      if (!mounted) return;
      setState(() => _isBuffering = v);
    });

    player.stream.completed.listen((v) {
      if (!v || !mounted) return;
      if (_repeatMode == 1 || _repeatMode == 2) {
        player.seek(Duration.zero);
        player.play();
      }
    });
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
    if (widget.playlist == null && widget.assetPlaylist == null) return;
    final playlistLength = widget.playlist?.length ?? widget.assetPlaylist?.length ?? 0;
    if (index < 0 || index >= playlistLength) return;

    setState(() {
      _currentIndex = index;
      _position = Duration.zero;
      _duration = Duration.zero;
      _sliderValue = 0;
      _isBuffering = true;
    });

    // 清理上一次的远程流式会话
    await _stopCurrentStream();

    if (widget.playlist != null) {
      final item = widget.playlist![index];
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

      if (item is AssetEntity) {
        setState(() => _isResolvingAsset = true);
        try {
          final file = await item.file;
          if (file != null && mounted) {
            player.open(Media(file.path));
          }
        } catch (e) {
          debugPrint('Error resolving video asset: $e');
        } finally {
          if (mounted) setState(() => _isResolvingAsset = false);
        }
      } else {
        player.open(Media(playPath));
      }
    } else if (widget.assetPlaylist != null) {
      setState(() => _isResolvingAsset = true);
      try {
        final asset = widget.assetPlaylist![index];
        final file = await asset.file;
        if (file != null && mounted) {
          player.open(Media(file.path));
        }
      } catch (e) {
        debugPrint('Error resolving video asset: $e');
      } finally {
        if (mounted) setState(() => _isResolvingAsset = false);
      }
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
      try {
        final proxyUrl = await RemoteStreamingService.instance.startStreaming(remoteClient, remoteFilePath, fileName);
        return proxyUrl;
      } catch (e) {
        debugPrint('远程流式代理启动失败，回退到下载模式: $e');
      }

      // 回退：完整下载后播放
      final cacheDir = Directory('/storage/emulated/0/Download/ZenFile_Remote');
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
    final playlistLength = widget.playlist?.length ?? widget.assetPlaylist?.length ?? 0;
    if (_currentIndex + 1 < playlistLength) {
      _playAtIndex(_currentIndex + 1);
    }
  }

  void _onPrevious() {
    if (_currentIndex - 1 >= 0) {
      _playAtIndex(_currentIndex - 1);
    }
  }

  void _onDoubleTapLeft() {
    if (_isLocked) return;
    if (_lastSeekWasForward || _seekSeconds == 0) {
      _seekSeconds = 10;
    } else {
      _seekSeconds += 10;
    }
    _lastSeekWasForward = false;
    player.seek(_position - const Duration(seconds: 10));

    setState(() {
      _showSeekLeft = true;
      _showSeekRight = false;
    });

    _seekIndicatorTimer?.cancel();
    _seekIndicatorTimer = Timer(const Duration(milliseconds: 900), () {
      if (mounted) {
        setState(() {
          _showSeekLeft = false;
          _seekSeconds = 0;
        });
      }
    });
  }

  void _onDoubleTapRight() {
    if (_isLocked) return;
    if (!_lastSeekWasForward || _seekSeconds == 0) {
      _seekSeconds = 10;
    } else {
      _seekSeconds += 10;
    }
    _lastSeekWasForward = true;
    player.seek(_position + const Duration(seconds: 10));

    setState(() {
      _showSeekRight = true;
      _showSeekLeft = false;
    });

    _seekIndicatorTimer?.cancel();
    _seekIndicatorTimer = Timer(const Duration(milliseconds: 900), () {
      if (mounted) {
        setState(() {
          _showSeekRight = false;
          _seekSeconds = 0;
        });
      }
    });
  }

  void _onVerticalDragUpdate(DragUpdateDetails details, bool isLeft) {
    if (_isLocked) return;
    final delta = -details.primaryDelta! / 250.0;
    setState(() {
      if (isLeft) {
        _volume = (_volume + delta).clamp(0.0, 1.0);
        if (!_isMuted) player.setVolume(_volume * 100.0);
        _showVolumeSlider = true;
        _showBrightnessSlider = false;
      } else {
        _brightness = (_brightness + delta).clamp(0.1, 1.0);
        _showBrightnessSlider = true;
        _showVolumeSlider = false;
      }
    });

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
    setState(() => _isFullScreen = !_isFullScreen);
    if (_isFullScreen) {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
      SystemChrome.setPreferredOrientations([
        DeviceOrientation.landscapeRight,
        DeviceOrientation.landscapeLeft,
      ]);
    } else {
      final hideNav = PreferencesService.getHideNavigationBar();
      if (hideNav) {
        SystemChrome.setEnabledSystemUIMode(SystemUiMode.manual, overlays: [SystemUiOverlay.top]);
      } else {
        SystemChrome.setEnabledSystemUIMode(SystemUiMode.manual, overlays: SystemUiOverlay.values);
      }
      SystemChrome.setPreferredOrientations([
        DeviceOrientation.portraitUp,
      ]);
    }
    _showControls();
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    _seekIndicatorTimer?.cancel();
    _sliderTimer?.cancel();
    _cacheCheckTimer?.cancel();
    _aspectToastTimer?.cancel();
    _controlsAnimController.dispose();
    // 清理远程流式会话：fire-and-forget 但确保异步执行。
    // dispose() 不能是 async（Framework 要求 void），
    // 但 stopStreaming 内部会调用 client.disconnect() 取消下载。
    _stopCurrentStream();
    player.dispose();
    final hideNav = PreferencesService.getHideNavigationBar();
    if (hideNav) {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.manual, overlays: [SystemUiOverlay.top]);
    } else {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.manual, overlays: SystemUiOverlay.values);
    }
    SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
    super.dispose();
  }

  String get _fileName {
    String currentPath = widget.videoPath;
    if (widget.playlist != null && _currentIndex < widget.playlist!.length) {
      final item = widget.playlist![_currentIndex];
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

  /// 根据当前伸缩比例模式构建视频画面
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
      case 3: // 16:9
        fit = BoxFit.fill;
        forcedRatio = 16 / 9;
        break;
      case 4: // 4:3
        fit = BoxFit.fill;
        forcedRatio = 4 / 3;
        break;
      default: // 0 适应屏幕
        fit = BoxFit.contain;
    }

    Widget video = Video(
      controller: controller,
      controls: NoVideoControls,
      fit: fit,
    );
    if (forcedRatio != null) {
      video = AspectRatio(aspectRatio: forcedRatio, child: video);
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
        return l10n.msg_aspect_16_9;
      case 4:
        return l10n.msg_aspect_4_3;
      default:
        return l10n.msg_aspect_fit;
    }
  }

  /// 切换伸缩比例并显示提示词
  void _toggleAspectRatio() {
    setState(() {
      _aspectRatioMode = (_aspectRatioMode + 1) % 5;
      _aspectToast = _aspectRatioLabel();
    });
    _aspectToastTimer?.cancel();
    _aspectToastTimer = Timer(const Duration(milliseconds: 1500), () {
      if (mounted) setState(() => _aspectToast = null);
    });
    _showControls();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          // Main Video Surface (支持顺时针旋转 + 伸缩比例切换)
          _buildVideoSurface(),

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

          // Gesture Zones (Left/Right Drag, Double Tap & Long Press)
          Row(
            children: [
              Expanded(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onDoubleTap: _onDoubleTapLeft,
                  onTap: _toggleControls,
                  onLongPressStart: (_) => _startLongPress(),
                  onLongPressEnd: (_) => _endLongPress(),
                  onVerticalDragUpdate: (d) => _onVerticalDragUpdate(d, true),
                  child: const SizedBox.expand(),
                ),
              ),
              Expanded(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onDoubleTap: _onDoubleTapRight,
                  onTap: _toggleControls,
                  onLongPressStart: (_) => _startLongPress(),
                  onLongPressEnd: (_) => _endLongPress(),
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

          // Long Press Speed Badge
          if (_isLongPressSpeed)
            Positioned(
              top: 54,
              left: 0,
              right: 0,
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
                      const Text(
                        'Speed 2.0x',
                        style: TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.bold),
                      ),
                    ],
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
              top: 54,
              left: 0,
              right: 0,
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
                    isLocked: _isLocked,
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
                    onPrevious: (widget.playlist != null || widget.assetPlaylist != null) && _currentIndex > 0 ? _onPrevious : null,
                    onNext: (widget.playlist != null || widget.assetPlaylist != null) && _currentIndex + 1 < (widget.playlist?.length ?? widget.assetPlaylist?.length ?? 0) ? _onNext : null,
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
                      setState(() {
                        _isMuted = !_isMuted;
                        player.setVolume(_isMuted ? 0.0 : _volume * 100.0);
                      });
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
                    onInteract: _showControls,
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
