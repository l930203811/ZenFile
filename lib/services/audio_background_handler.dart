import 'dart:async';
import 'dart:io';
import 'package:audio_service/audio_service.dart';
import 'package:media_kit/media_kit.dart';
import 'package:path_provider/path_provider.dart';
import 'package:flutter/foundation.dart';
import 'package:permission_handler/permission_handler.dart';
import '../ui/screens/audio_player/audio_artwork_widget.dart';
import 'preferences_service.dart';
import 'power_management_service.dart';

/// Global singleton handler instance
ZenFileAudioHandler? _audioHandlerInstance;

/// Whether AudioService.init has successfully registered the handler.
/// 若为 false，表示 audio_service 框架未注册，通知栏无法显示，
/// 此时 playbackState 的更新不会到达系统通知层。
bool isAudioServiceInitialized = false;

/// Returns the global audio handler, creating it lazily if needed.
ZenFileAudioHandler getAudioHandler() {
  _audioHandlerInstance ??= ZenFileAudioHandler._();
  return _audioHandlerInstance!;
}

/// Utility to query artwork bytes, cache them locally in a temporary directory,
/// and return the local file [Uri] for the [MediaItem].
Future<Uri?> getArtworkUri(int audioId) async {
  if (audioId <= 0) return null;
  try {
    final tempDir = await getTemporaryDirectory();
    final file = File('${tempDir.path}/artwork_$audioId.png');
    if (await file.exists()) {
      return file.uri;
    }
    final data = await AudioArtworkCache.getArtwork(audioId);
    if (data != null && data.isNotEmpty) {
      await file.writeAsBytes(data);
      return file.uri;
    }
  } catch (e) {
    debugPrint('[ZenFile] Error getting artwork URI: $e');
  }
  return null;
}

/// Bridges media_kit [Player] to [audio_service] so the OS shows a proper
/// media notification with play / pause / skip controls.
class ZenFileAudioHandler extends BaseAudioHandler
    with QueueHandler, SeekHandler {
  ZenFileAudioHandler._();

  Player? _player;
  final List<StreamSubscription<dynamic>> _subs = [];
  Timer? _positionSaveTimer;

  /// 当前关联的播放器（后台播放时可用于恢复界面）
  Player? get currentPlayer => _player;

  /// 当前播放的媒体项
  MediaItem? get currentMediaItem => mediaItem.value;

  /// 当前播放路径（来自 MediaItem.id）
  String? get currentPath => mediaItem.value?.id;

  /// 是否有活跃的播放器实例
  bool get hasActivePlayer => _player != null;

  /// 判断指定路径是否正在当前播放器中播放
  bool isPlayingPath(String path) => _player != null && mediaItem.value?.id == path;

  /// 将当前 MediaItem 持久化为 lastPlayedAudio，确保后台切歌或界面销毁后仍能恢复
  void _persistCurrentMediaItem() {
    final item = mediaItem.value;
    if (item != null && item.id.isNotEmpty) {
      PreferencesService.saveLastPlayedAudio(item.id, item.title, item.artist ?? '');
    }
  }

  // ─── Attach / detach ────────────────────────────────────────────────────

  /// Call this whenever you want background mode to start (or restart with a
  /// new player / queue).
  void attach({
    required Player player,
    required List<MediaItem> queue,
    required int currentIndex,
  }) {
    final oldPlayer = _player;
    if (oldPlayer != null && oldPlayer != player) {
      Future.microtask(() async {
        try {
          await oldPlayer.dispose();
        } catch (e) {
          debugPrint('[ZenFile] Error disposing old player: $e');
        }
      });
    }

    detach();
    _player = player;

    // Push the queue
    this.queue.add(queue);
    if (queue.isNotEmpty) {
      mediaItem.add(queue[currentIndex]);
      _persistCurrentMediaItem();
    }

    // Mirror playing state
    _subs.add(player.stream.playing.listen((playing) {
      _emitPlaybackState(playing: playing);
    }));

    // Mirror position
    _subs.add(player.stream.position.listen((pos) {
      _emitPlaybackState(playing: _player?.state.playing ?? false, position: pos);
    }));

    // Mirror track completion → advance (only when background, otherwise let screen handle it)
    _subs.add(player.stream.completed.listen((completed) {
      if (completed && _onSkipCallback == null) {
        skipToNext();
      }
    }));

    // 直接 emit 当前播放状态，立即触发通知栏显示
    _emitPlaybackState(playing: player.state.playing);

    // 后台播放期间定期保存进度，即使界面被销毁也能记住位置
    _positionSaveTimer?.cancel();
    _positionSaveTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      final path = mediaItem.value?.id;
      final pos = _player?.state.position;
      if (path != null && pos != null && pos.inMilliseconds > 1000) {
        PreferencesService.savePlaybackPosition(path, pos.inMilliseconds);
      }
    });

    // ── 申请通知栏权限（安卓13+ 必须，否则系统拦截通知不显示）──
    unawaited(_requestNotificationPermission());
  }

  /// 申请通知栏权限（安卓 13+ 必须，否则系统拦截通知不显示）。
  /// permission_handler 会自动按版本处理：安卓 12- 返回已授予不弹框，
  /// 安卓 13+ 才弹系统授权框。低版本与已授权时直接跳过，绝不阻塞播放器启动。
  Future<void> _requestNotificationPermission() async {
    if (!Platform.isAndroid) return;
    try {
      final status = await Permission.notification.status;
      if (status.isDenied) {
        await Permission.notification.request();
      }
    } catch (e) {
      debugPrint('[ZenFile] request notification permission failed: $e');
    }
    // 申请忽略电池优化 + 唤醒锁，防止后台播放被系统中断
    _ensurePowerManagement();
  }

  /// 确保电源管理优化：请求忽略电池优化 + 申请唤醒锁。
  /// 首次播放时调用，不阻塞音频启动。
  Future<void> _ensurePowerManagement() async {
    if (!Platform.isAndroid) return;
    try {
      // 检查并请求电池优化白名单
      final ignoring = await PowerManagementService.isIgnoringBatteryOptimizations();
      if (!ignoring && !PreferencesService.getBatteryOptDismissed()) {
        await PowerManagementService.requestIgnoreBatteryOptimizations();
      }
      // 申请唤醒锁保持 CPU 运行
      await PowerManagementService.acquireWakeLock();
    } catch (e) {
      debugPrint('[ZenFile] power management setup failed: $e');
    }
  }

  void detach() {
    _positionSaveTimer?.cancel();
    _positionSaveTimer = null;
    for (final s in _subs) {
      s.cancel();
    }
    _subs.clear();
    _player = null;
  }

  /// 当用户开始播放视频时调用：立即暂停正在播放的后台音频，避免两路声音混在一起。
  /// 仅暂停不销毁播放器，返回音频播放页时仍可恢复原进度。
  void pauseForVideo() {
    final p = _player;
    if (p != null && p.state.playing) {
      p.pause();
    }
  }

  // ─── AudioHandler overrides ─────────────────────────────────────────────

  @override
  Future<void> play() async {
    await _player?.play();
  }

  @override
  Future<void> pause() async {
    await _player?.pause();
  }

  @override
  Future<void> stop() async {
    _positionSaveTimer?.cancel();
    _positionSaveTimer = null;
    playbackState.add(PlaybackState(
      controls: [],
      playing: false,
      processingState: AudioProcessingState.idle,
    ));

    final playerToDispose = _player;
    if (playerToDispose != null) {
      try {
        await playerToDispose.dispose();
      } catch (e) {
        debugPrint('[ZenFile] Error disposing player on stop: $e');
      }
    }

    detach();
    await super.stop();
  }

  /// Clears and dismisses the background media notification completely,
  /// but keeps the active player alive for foreground playback.
  void stopNotification() {
    playbackState.add(PlaybackState(
      controls: [],
      playing: false,
      processingState: AudioProcessingState.idle,
    ));
    detach();
  }

  @override
  Future<void> seek(Duration position) async {
    await _player?.seek(position);
  }

  @override
  Future<void> skipToNext() async {
    final q = queue.value;
    final current = mediaItem.value;
    if (q.isEmpty || current == null) return;
    final idx = q.indexOf(current);
    final nextIdx = (idx + 1) % q.length;
    final nextItem = q[nextIdx];
    mediaItem.add(nextItem);
    _persistCurrentMediaItem();

    if (_onSkipCallback != null) {
      _onSkipCallback?.call(nextIdx);
    } else {
      if (_player != null) {
        await _player!.open(Media(nextItem.id), play: true);
      }
    }
  }

  @override
  Future<void> skipToPrevious() async {
    final q = queue.value;
    final current = mediaItem.value;
    if (q.isEmpty || current == null) return;
    final idx = q.indexOf(current);
    final prevIdx = (idx - 1 + q.length) % q.length;
    final prevItem = q[prevIdx];
    mediaItem.add(prevItem);
    _persistCurrentMediaItem();

    if (_onSkipCallback != null) {
      _onSkipCallback?.call(prevIdx);
    } else {
      if (_player != null) {
        await _player!.open(Media(prevItem.id), play: true);
      }
    }
  }

  // ─── Callback for skip (screen must update player) ──────────────────────

  void Function(int index)? _onSkipCallback;

  void setSkipCallback(void Function(int index)? cb) {
    _onSkipCallback = cb;
  }

  /// Update the current media item displayed in the notification.
  void updateCurrentItem(MediaItem item) {
    mediaItem.add(item);
    _persistCurrentMediaItem();
  }

  /// Re-emit the current playback state without re-attaching the player.
  /// Used as a safety net when the first emit may have failed to create
  /// the foreground notification (e.g. startForeground race / permission delay).
  void reattachState() {
    final player = _player;
    if (player != null) {
      _emitPlaybackState(playing: player.state.playing);
    }
  }

  // ─── Private helpers ─────────────────────────────────────────────────────

  void _emitPlaybackState({
    required bool playing,
    Duration? position,
  }) {
    final currentPos = position ?? _player?.state.position ?? Duration.zero;
    playbackState.add(
      PlaybackState(
        controls: [
          MediaControl.skipToPrevious,
          playing ? MediaControl.pause : MediaControl.play,
          MediaControl.skipToNext,
          const MediaControl(
            androidIcon: 'drawable/audio_service_stop',
            label: '关闭',
            action: MediaAction.stop,
          ),
        ],
        systemActions: {
          MediaAction.seek,
          MediaAction.seekForward,
          MediaAction.seekBackward,
        },
        androidCompactActionIndices: const [0, 1, 2],
        processingState: AudioProcessingState.ready,
        playing: playing,
        updatePosition: currentPos,
        bufferedPosition: currentPos,
        speed: _player?.state.rate ?? 1.0,
      ),
    );
  }
}
