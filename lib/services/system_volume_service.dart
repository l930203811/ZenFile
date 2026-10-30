import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// 系统媒体音量（STREAM_MUSIC）服务：读取 / 设置 + 变化监听。
///
/// * 读写复用视频播放器已有的裸通道 `com.sequl.zenfile/volume`
///   （getStreamVolume / setStreamVolume，原生 AudioManager 实现）；
/// * 变化监听走 `com.sequl.zenfile/volume_events`（MainActivity 内注册系统
///   VOLUME_CHANGED_ACTION 接收器，仅转发 STREAM_MUSIC）—— 音频播放器底部
///   工具行的音量按钮依靠它与系统媒体音量**双向同步**：音量键 / 系统面板改动
///   实时反映到按钮图标，拖动按钮写入的是真实系统音量。
class SystemVolumeService {
  SystemVolumeService._();
  static final SystemVolumeService instance = SystemVolumeService._();

  static const MethodChannel _channel =
      MethodChannel('com.sequl.zenfile/volume');
  static const EventChannel _events =
      EventChannel('com.sequl.zenfile/volume_events');

  /// 当前媒体音量（0..1）。UI 用 [ValueListenableBuilder] 监听即可。
  final ValueNotifier<double> volume = ValueNotifier<double>(0.5);

  /// 最近一次非零音量（静音恢复用）。初值 0.5：启动时就是静音的话恢复到一半。
  double _lastNonZero = 0.5;
  StreamSubscription<dynamic>? _sub;

  /// 幂等初始化：读当前音量 + 订阅系统音量变化。播放页/控件进入时调用即可。
  Future<void> ensureInitialized() async {
    if (_sub != null) return;
    try {
      final v = await _channel.invokeMethod<double>('getStreamVolume');
      if (v != null && v >= 0) {
        volume.value = v.clamp(0.0, 1.0);
        if (volume.value > 0.001) _lastNonZero = volume.value;
      }
    } catch (_) {
      // 读不到（通道缺失等）不影响任何其他功能，UI 按本地状态工作。
    }
    try {
      _sub = _events.receiveBroadcastStream().listen(
        (dynamic v) {
          final d = (v as num?)?.toDouble();
          if (d == null) return;
          volume.value = d.clamp(0.0, 1.0);
          if (volume.value > 0.001) _lastNonZero = volume.value;
        },
        onError: (Object e) {
          // 系统广播接收器被系统回收等异常：置空，下次进入页面重新订阅。
          _sub = null;
        },
        cancelOnError: true,
      );
    } catch (_) {}
  }

  Future<void> dispose() async {
    await _sub?.cancel();
    _sub = null;
  }

  /// 设置系统媒体音量（0..1）。本地值即时回显，原生写入失败也不回滚 UI。
  Future<void> setVolume(double v) async {
    final nv = v.clamp(0.0, 1.0);
    volume.value = nv;
    if (nv > 0.001) _lastNonZero = nv;
    try {
      await _channel.invokeMethod('setStreamVolume', {'volume': nv});
    } catch (_) {}
  }

  /// 点按：静音 / 恢复到静音前的音量。
  Future<void> toggleMute() async {
    if (volume.value > 0.001) {
      await setVolume(0.0);
    } else {
      await setVolume(_lastNonZero > 0.001 ? _lastNonZero : 0.5);
    }
  }
}
