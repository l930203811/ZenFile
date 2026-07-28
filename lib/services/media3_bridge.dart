import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/services.dart';

/// 与原生 [ZenMediaSessionService]（AndroidX Media3）通信的桥接层。
///
/// 设计参照 Echo-Music：由 Media3 的 MediaSessionService + DefaultMediaNotificationProvider
/// 自动生成安卓 13+ 的媒体控制面板（通知栏/锁屏/蓝牙耳机）。本类负责：
///   - 把 media_kit 的播放状态（元数据、播放/暂停、进度、队列）推送到原生；
///   - 接收系统在通知栏/锁屏/耳机上发出的播放指令（play/pause/seek/next/previous/stop），
///     回传给 [ZenFileAudioHandler] 以驱动 media_kit。
///
/// 仅 Android 生效；iOS / 桌面忽略（保持 audio_service 不变也不影响，因为本类只被
/// 安卓分支调用）。
class Media3Bridge {
  Media3Bridge._();

  static final Media3Bridge instance = Media3Bridge._();

  static const MethodChannel _channel =
      MethodChannel('com.sequl.zenfile/media3');
  static const MethodChannel _hostChannel =
      MethodChannel('com.sequl.zenfile/notifications');

  bool _initialized = false;

  /// 由原生（通知栏/锁屏/耳机）发来的指令回调。
  void Function(String action, int? positionMs)? _commandHandler;

  /// 注册 Dart 端指令接收器；幂等。
  Future<void> ensureStarted() async {
    if (_initialized) return;
    _initialized = true;
    _channel.setMethodCallHandler(_onNativeCall);
  }

  /// 启动原生 Media3 媒体会话服务（经 MainActivity 通道拉起，确保 Flutter 信使已就绪）。
  Future<void> startService() async {
    await ensureStarted();
    try {
      await _hostChannel.invokeMethod<bool>('startMediaSession');
    } catch (e) {
      // 服务可能已在运行，忽略
    }
    // 等待服务 onCreate 完成（注册 media3 通道处理器），避免首帧调用丢失
    await Future.delayed(const Duration(milliseconds: 350));
  }

  Future<void> stopService() async {
    try {
      await _channel.invokeMethod<void>('stop');
    } catch (_) {}
  }

  Future<void> updateMetadata({
    required String title,
    String? artist,
    required int durationMs,
    Uint8List? artworkBytes,
  }) async {
    try {
      await _channel.invokeMethod<void>('setMetadata', <String, dynamic>{
        'title': title,
        'artist': artist,
        'durationMs': durationMs,
        'artworkBytes': artworkBytes,
      });
    } catch (_) {}
  }

  Future<void> updatePlaybackState({
    required bool playing,
    required int positionMs,
    required int bufferedMs,
  }) async {
    try {
      await _channel.invokeMethod<void>('setPlaybackState', <String, dynamic>{
        'playing': playing,
        'positionMs': positionMs,
        'bufferedMs': bufferedMs,
      });
    } catch (_) {}
  }

  Future<void> updateQueue(List<Map<String, dynamic>> items, int index) async {
    try {
      await _channel.invokeMethod<void>('setQueue', <String, dynamic>{
        'items': items,
        'index': index,
      });
    } catch (_) {}
  }

  void setCommandHandler(void Function(String action, int? positionMs) handler) {
    _commandHandler = handler;
  }

  Future<void> _onNativeCall(MethodCall call) async {
    if (call.method == 'onCommand') {
      final action = call.arguments['action'] as String?;
      final positionMs = call.arguments['positionMs'] as int?;
      if (action != null) _commandHandler?.call(action, positionMs);
    }
  }
}
