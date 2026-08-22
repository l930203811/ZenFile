import 'dart:io';
import 'package:flutter/services.dart';

/// 电源管理服务：后台播放时请求忽略电池优化 + 申请唤醒锁，
/// 防止系统休眠导致音频播放中断。
class PowerManagementService {
  static const MethodChannel _channel = MethodChannel('com.sequl.zenfile/power_manager');

  /// 检查是否已忽略电池优化
  static Future<bool> isIgnoringBatteryOptimizations() async {
    if (!Platform.isAndroid) return true;
    try {
      final result = await _channel.invokeMethod<bool>('isIgnoringBatteryOptimizations');
      return result ?? false;
    } catch (_) {
      return false;
    }
  }

  /// 请求忽略电池优化（弹出系统设置页面）
  static Future<bool> requestIgnoreBatteryOptimizations() async {
    if (!Platform.isAndroid) return false;
    try {
      final result = await _channel.invokeMethod<bool>('requestIgnoreBatteryOptimizations');
      return result ?? false;
    } catch (_) {
      return false;
    }
  }

  /// 申请唤醒锁（后台播放时保持 CPU 运行）
  static Future<void> acquireWakeLock() async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod('acquireWakeLock');
    } catch (_) {}
  }

  /// 释放唤醒锁
  static Future<void> releaseWakeLock() async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod('releaseWakeLock');
    } catch (_) {}
  }
}
