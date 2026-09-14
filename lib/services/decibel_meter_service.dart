import 'package:flutter/services.dart';

/// 分贝仪服务：通过原生 MethodChannel 调用 Android AudioRecord
/// 实时采集麦克风音量并转换为分贝值（dB SPL 近似值）。
class DecibelMeterService {
  static const MethodChannel _channel = MethodChannel(
    'com.sequl.zenfile/decibel_meter',
  );

  /// 每帧回调当前分贝值
  void Function(double db)? onData;

  String? lastError;

  bool _isRunning = false;
  bool get isRunning => _isRunning;

  /// 开始测量。返回是否成功启动。
  Future<bool> start() async {
    try {
      lastError = null;
      await _channel.invokeMethod<void>('start');
      _isRunning = true;
      // 开始接收事件流
      _channel.setMethodCallHandler((call) async {
        if (call.method == 'onData') {
          final db = (call.arguments as num?)?.toDouble() ?? 0;
          onData?.call(db);
        }
        return null;
      });
      return true;
    } on PlatformException catch (e) {
      lastError = e.message ?? 'Failed to start';
      return false;
    } catch (e) {
      lastError = e.toString();
      return false;
    }
  }

  /// 停止测量
  Future<void> stop() async {
    if (!_isRunning) return;
    _isRunning = false;
    try {
      await _channel.invokeMethod<void>('stop');
    } catch (_) {
      // 忽略停止错误
    }
    _channel.setMethodCallHandler(null);
  }
}
