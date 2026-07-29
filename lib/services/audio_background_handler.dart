import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:audio_service/audio_service.dart';
import 'package:media_kit/media_kit.dart';
import 'package:path_provider/path_provider.dart';
import 'package:flutter/foundation.dart';
import '../ui/screens/audio_player/audio_artwork_widget.dart';
import 'media3_bridge.dart';
import 'preferences_service.dart';

/// Global singleton handler instance
ZenFileAudioHandler? _audioHandlerInstance;

/// Whether AudioService.init has successfully registered the handler.
/// 若为 false，表示 audio_service 框架未注册，通知栏无法显示，
/// 此时 playbackState 的更新不会到达系统通知层。
bool isAudioServiceInitialized = false;

/// 当前设备是否为安卓 13+（SDK >= 33）。
/// 安卓 13+ 使用 Media3（ZenMediaSessionService）媒体会话，低版本沿用 audio_service。
/// 在 [main] 启动时由 device_info_plus 初始化，供各模块判断走哪条媒体通知链路。
bool isAndroid13Plus = false;

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

    // ── Media3（安卓13+ 通知栏控制面板）桥接 ──
    unawaited(_startMedia3());
  }

  /// 启动 Media3 媒体会话桥接：把 media_kit 状态实时同步到原生 MediaSession，
  /// 并把通知栏/锁屏/耳机指令回传驱动 media_kit。
  /// 仅安卓 13+ 启用；低版本由 audio_service 原生通知承担，不走此链路。
  Future<void> _startMedia3() async {
    if (!isAndroid13Plus) return;
    Media3Bridge.instance.setCommandHandler((action, positionMs) {
      switch (action) {
        case 'play':
          play();
          break;
        case 'pause':
          pause();
          break;
        case 'seek':
          if (positionMs != null) seek(Duration(milliseconds: positionMs));
          break;
        case 'next':
          skipToNext();
          break;
        case 'previous':
          skipToPrevious();
          break;
        case 'stop':
          stop();
          break;
      }
    });

    // 监听媒体项与播放状态变化，自动同步到原生 MediaSession
    _subs.add(mediaItem.listen((item) {
      if (item != null) _pushMetadata(item);
    }));
    _subs.add(playbackState.listen((state) {
      _pushState(state);
    }));

    // 拉起原生 Media3 服务并推送当前队列/元数据/状态。
    // 必须 await startService() 完成后再 push，否则服务尚未 ready 时调用会被静默吞掉，
    // 导致通知永远卡在 placeholder。
    await Media3Bridge.instance.startService();
    final q = queue.value;
    final idx = q.isEmpty ? 0 : (q.indexOf(mediaItem.value ?? q.first)).clamp(0, q.length - 1);
    await Media3Bridge.instance.updateQueue(
      q.map((m) => <String, dynamic>{
        'id': m.id,
        'title': m.title,
        'artist': m.artist,
      }).toList(),
      idx,
    );
    if (mediaItem.value != null) _pushMetadata(mediaItem.value!);
    _pushState(playbackState.value);
  }

  /// 把当前 MediaItem 的元数据（标题/艺人/时长/封面）推送到原生 MediaSession。
  void _pushMetadata(MediaItem item) {
    final durationMs = item.duration?.inMilliseconds ?? 0;
    // 封面：getArtworkUri 返回本地临时文件 Uri，读取为字节推给原生（原生直接 setArtworkData）
    unawaited(() async {
      Uint8List? bytes;
      if (item.artUri != null) {
        try {
          final f = File.fromUri(item.artUri!);
          if (await f.exists()) bytes = await f.readAsBytes();
        } catch (_) {}
      }
      Media3Bridge.instance.updateMetadata(
        title: item.title,
        artist: item.artist,
        durationMs: durationMs,
        artworkBytes: bytes,
      );
    }());
  }

  /// 把当前 PlaybackState（播放/暂停、进度、缓冲）推送到原生 MediaSession。
  void _pushState(PlaybackState state) {
    Media3Bridge.instance.updatePlaybackState(
      playing: state.playing,
      positionMs: state.position.inMilliseconds,
      bufferedMs: state.bufferedPosition.inMilliseconds,
    );
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
    Media3Bridge.instance.stopService();
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
    Media3Bridge.instance.stopService();
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
            androidIcon: 'drawable/ic_close',
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
