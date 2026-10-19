import 'dart:async';

import 'package:flutter/widgets.dart';

/// 冷启动「静默期」闸门。
///
/// 场景：开启「启动应用保护」后，用户输完 PIN 点解锁的那一瞬间，输入法开始
/// 收起（系统侧动画 250~400ms，MIUI / HyperOS 上更慢）。同一时刻如果启动
/// 全量媒体扫描（MediaStore 拉取 + 磁盘缓存反序列化 + 排序，大存储上万条）
/// 或穷举目录，主 isolate 会被排满 —— 收起动画每一帧都在等下一帧，表现就是
/// 「密码输完进分类页，键盘慢慢缩回去」。
///
/// 实测对比：键盘**弹出**不卡（那时还停在闸门页，只有一个小输入框），
/// 只有**收起**卡，正好对上「首页首帧 + 媒体扫描 + 目录穷举」三件事都挤在
/// 解锁那一帧之后。
///
/// 用法：
/// 1. 解锁闸门通过时调用 [armAfterUnlock]；
/// 2. 任何主 isolate 上的重活（媒体扫描 / 目录穷举）开头 `await waitIfSettling()`。
///
/// 判据优先读**真实**的 `viewInsets.bottom`（不猜固定时长，各 ROM 动画长短不一），
/// 同时保留一个最小等待：部分 ROM 在动画**开始**时就把 insets 置 0，
/// 只看 insets 会让闸门形同虚设。
class StartupGate {
  StartupGate._();

  static final StartupGate instance = StartupGate._();

  /// 静默期截止时间；null 表示当前不处于静默期。
  DateTime? _until;

  /// 共享等待：多个重活同时进来时只跑一份轮询，一起放行。
  Future<void>? _pending;

  /// 静默期上限（兜底）：万一 insets 一直拿不到或键盘异常，也不能无限等。
  static const Duration _window = Duration(milliseconds: 2000);

  /// 最小等待：覆盖 IME 收起动画的下限（不依赖 insets 是否提前归零）。
  static const Duration _minWait = Duration(milliseconds: 420);

  /// 键盘收起后的缓冲：给首屏图片解码、页面转场收尾留几帧。
  static const Duration _tail = Duration(milliseconds: 160);

  /// 轮询间隔：只读 metrics，不触发重建、不进 build。
  static const Duration _poll = Duration(milliseconds: 32);

  /// 当前是否处于静默期。
  bool get isSettling {
    final until = _until;
    return until != null && DateTime.now().isBefore(until);
  }

  /// 解锁闸门通过时调用：标记接下来这段时间为主 isolate 静默期。
  void armAfterUnlock() {
    _until = DateTime.now().add(_window);
    _pending = null;
  }

  /// 静默期内等到「键盘收起 + 缓冲」；非静默期立即返回。
  ///
  /// 多次并发调用共享同一个 Future，不会各自轮询。
  Future<void> waitIfSettling() {
    if (!isSettling) return Future<void>.value();
    return _pending ??= _settle().whenComplete(() => _pending = null);
  }

  Future<void> _settle() async {
    final startedAt = DateTime.now();
    final deadline = startedAt.add(_window);
    final minUntil = startedAt.add(_minWait);

    while (DateTime.now().isBefore(deadline)) {
      final inset =
          WidgetsBinding.instance.platformDispatcher.implicitView?.viewInsets.bottom ??
              0;
      final now = DateTime.now();
      // 两个条件都满足才放行：键盘确实收起了，且已过最小等待。
      if (inset <= 0 && !now.isBefore(minUntil)) break;
      await Future<void>.delayed(_poll);
    }

    await Future<void>.delayed(_tail);
  }
}
