import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';

import 'desktop_lyric_service.dart';
import 'lyric_parser.dart';

/// 桌面歌词控制器（单例）
///
/// 独立于 widget 生命周期管理桌面歌词的位置监听与更新。
///
/// **解决的问题**: 当用户从音频播放器页面返回（非后台模式 dispose，
/// 或后台模式 widget 被销毁但播放器仍在运行）时，
/// 原先挂载在 widget 上的 `player.stream.position` 监听因 `!mounted` 检查而失效，
/// 导致桌面歌词悬浮窗虽然显示但文本卡住不更新。
///
/// 本控制器自行持有 `StreamSubscription`，在 [start] 后持续监听播放位置，
/// 即使 widget 被销毁也能正常更新悬浮窗歌词。
class DesktopLyricController {
  DesktopLyricController._();
  static final DesktopLyricController instance = DesktopLyricController._();

  Player? _player;
  StreamSubscription<Duration>? _positionSub;

  /// 当前歌词数据
  List<LyricLine>? _lyrics;

  /// 颜色配置（ARGB int）
  int? _highlightColor;
  int? _normalColor;

  /// 上次推送的文本与高亮位置，用于节流
  String? _lastText;
  int _lastHighlightLen = -1;

  /// 心跳计数器
  int _heartbeatCounter = 0;
  static const int _heartbeatInterval = 20;
  bool _recovering = false;

  /// 是否正在运行（已 start 且未 stop）
  bool get isRunning => _positionSub != null;

  /// 更新歌词数据（在歌词加载完成或切换歌曲时调用）
  void setLyrics(List<LyricLine>? lyrics) {
    _lyrics = lyrics;
    // 歌词变化后重置节流缓存，确保下次推送
    _lastText = null;
    _lastHighlightLen = -1;
  }

  /// 设置颜色
  void setColors({int? highlightColor, int? normalColor}) {
    _highlightColor = highlightColor;
    _normalColor = normalColor;
  }

  /// 启动位置监听
  ///
  /// 在 widget 启用桌面歌词或恢复桌面歌词时调用。
  /// 若已在运行，会先取消旧监听再创建新的。
  void start(Player player) {
    if (_player == player && _positionSub != null) return;
    stop();
    _player = player;
    _positionSub = player.stream.position.listen(_onPositionChanged);
  }

  /// 停止位置监听（不隐藏悬浮窗）
  void stop() {
    _positionSub?.cancel();
    _positionSub = null;
    _player = null;
  }

  /// 彻底停止并重置所有状态
  void reset() {
    stop();
    _lyrics = null;
    _highlightColor = null;
    _normalColor = null;
    _lastText = null;
    _lastHighlightLen = -1;
    _heartbeatCounter = 0;
    _recovering = false;
  }

  void _onPositionChanged(Duration position) {
    _update(position);
  }

  /// 根据当前位置更新桌面歌词
  void _update(Duration position) {
    final line = _getCurrentLyricLine(position);
    final text = line?.text ?? '';
    final highlightLen = _calcHighlightLen(line, position);

    if (text != _lastText || highlightLen != _lastHighlightLen) {
      _lastText = text;
      _lastHighlightLen = highlightLen;
      DesktopLyricService.instance.updateLyric(
        text,
        highlightLen: highlightLen,
        highlightColor: _highlightColor,
        normalColor: _normalColor,
      );
    }

    // 心跳检查
    _heartbeatCounter++;
    if (_heartbeatCounter >= _heartbeatInterval && !_recovering) {
      _heartbeatCounter = 0;
      _checkAndRecover();
    }
  }

  /// 检查悬浮窗是否仍显示，若已消失则自动恢复
  Future<void> _checkAndRecover() async {
    if (_recovering) return;
    final stillShowing = await DesktopLyricService.instance.isShowing();
    if (!stillShowing && _player != null) {
      _recovering = true;
      try {
        final line = _getCurrentLyricLine(_player!.state.position);
        final text = line?.text ?? '';
        final highlightLen = _calcHighlightLen(line, _player!.state.position);
        await DesktopLyricService.instance.show(
          text,
          highlightColor: _highlightColor,
          normalColor: _normalColor,
        );
        DesktopLyricService.instance.updateLyric(
          text,
          highlightLen: highlightLen,
          highlightColor: _highlightColor,
          normalColor: _normalColor,
        );
        _lastText = text;
        _lastHighlightLen = highlightLen;
      } catch (e) {
        debugPrint('[DesktopLyricController] recover failed: $e');
      } finally {
        _recovering = false;
      }
    }
  }

  /// 查找当前应显示的歌词行
  LyricLine? _getCurrentLyricLine(Duration position) {
    if (_lyrics == null || _lyrics!.isEmpty) return null;
    final index = LyricParser.findCurrentLineIndex(_lyrics!, position);
    if (index < 0 || index >= _lyrics!.length) return null;
    return _lyrics![index];
  }

  /// 计算逐字高亮字符数
  int _calcHighlightLen(LyricLine? line, Duration position) {
    if (line == null || !line.hasWordTimestamps || line.words == null) {
      return line != null ? line.text.length : 0;
    }

    final words = line.words!;
    final posMs = position.inMilliseconds;
    int charCount = 0;

    for (int i = 0; i < words.length; i++) {
      final word = words[i];
      final wordTs = word.timestamp.inMilliseconds;

      if (posMs < wordTs) break;

      int wordDuration = 300;
      if (i + 1 < words.length) {
        final nextTs = words[i + 1].timestamp.inMilliseconds;
        final gap = nextTs - wordTs;
        if (gap > 0 && gap < 5000) {
          wordDuration = gap;
        }
      }

      final elapsed = posMs - wordTs;
      final progress = (elapsed / wordDuration).clamp(0.0, 1.0);

      if (progress >= 1.0) {
        charCount += word.text.length;
      } else {
        charCount += (word.text.length * progress).round();
        break;
      }
    }

    return charCount.clamp(0, line.text.length);
  }
}
