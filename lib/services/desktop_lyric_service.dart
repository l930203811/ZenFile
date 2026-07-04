import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// 桌面歌词悬浮窗服务（Flutter 端封装）
///
/// 通过 MethodChannel 与原生 [DesktopLyricService.kt] 通信，提供：
///  - 权限检查 / 请求（SYSTEM_ALERT_WINDOW）
///  - 显示 / 隐藏悬浮窗
///  - 实时更新单行歌词文本
///  - 监听悬浮窗单击事件（用于切换播放/暂停）
///
/// 通知栏的播放控制面板由 [ZenFileAudioHandler]（audio_service）独立提供，
/// 不在此服务范围内。
class DesktopLyricService {
  DesktopLyricService._();

  static const MethodChannel _channel =
      MethodChannel('com.sequl.zenfile/desktop_lyric');

  /// 单例实例
  static final DesktopLyricService instance = DesktopLyricService._();

  /// 单击回调监听器（来自原生悬浮窗的点击）
  final StreamController<void> _onLyricClickController =
      StreamController<void>.broadcast();

  /// 暴露给上层的单击事件流
  Stream<void> get onLyricClick => _onLyricClickController.stream;

  bool _initialized = false;

  /// 初始化 MethodCallHandler（仅初始化一次）
  void ensureInitialized() {
    if (_initialized) return;
    _initialized = true;
    _channel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'onLyricClick':
          _onLyricClickController.add(null);
          break;
        default:
          break;
      }
    });
  }

  /// 检查是否已授予悬浮窗权限
  Future<bool> checkPermission() async {
    try {
      final result = await _channel.invokeMethod<bool>('checkPermission');
      return result ?? false;
    } catch (e) {
      debugPrint('[DesktopLyric] checkPermission failed: $e');
      return false;
    }
  }

  /// 跳转系统设置请求悬浮窗权限
  Future<bool> requestPermission() async {
    try {
      final result = await _channel.invokeMethod<bool>('requestPermission');
      return result ?? false;
    } catch (e) {
      debugPrint('[DesktopLyric] requestPermission failed: $e');
      return false;
    }
  }

  /// 显示悬浮窗（若已显示则仅更新文本）
  ///
  /// [text] 初始歌词文本；[x]/[y] 初始位置（左上为原点）。
  Future<bool> show(String text, {int x = 0, int y = 200}) async {
    try {
      final result = await _channel.invokeMethod<bool>('show', {
        'text': text,
        'x': x,
        'y': y,
      });
      return result ?? false;
    } catch (e) {
      debugPrint('[DesktopLyric] show failed: $e');
      return false;
    }
  }

  /// 隐藏悬浮窗
  Future<bool> hide() async {
    try {
      final result = await _channel.invokeMethod<bool>('hide');
      return result ?? false;
    } catch (e) {
      debugPrint('[DesktopLyric] hide failed: $e');
      return false;
    }
  }

  /// 更新歌词文本与逐字高亮位置
  ///
  /// [text] 当前歌词行全文；[highlightLen] 已唱字符数（从行首算起），
  /// 原生端会用 [ForegroundColorSpan] 将前 [highlightLen] 个字符渲染为高亮色，
  /// 其余渲染为普通色，实现逐字卡拉OK效果。
  Future<bool> updateLyric(String text, {int highlightLen = 0}) async {
    try {
      final result = await _channel.invokeMethod<bool>('updateLyric', {
        'text': text,
        'highlightLen': highlightLen,
      });
      return result ?? false;
    } catch (e) {
      // 高频调用时偶发错误不打扰用户
      return false;
    }
  }

  /// 当前是否正在显示悬浮窗
  Future<bool> isShowing() async {
    try {
      final result = await _channel.invokeMethod<bool>('isShowing');
      return result ?? false;
    } catch (e) {
      return false;
    }
  }

  /// 设置悬浮窗初始位置（仅在下次 show 时生效）
  Future<bool> setPosition(int x, int y) async {
    try {
      final result = await _channel.invokeMethod<bool>('setPosition', {
        'x': x,
        'y': y,
      });
      return result ?? false;
    } catch (e) {
      return false;
    }
  }

  /// 释放资源（一般在 app 退出时调用）
  void dispose() {
    _onLyricClickController.close();
  }
}
