import 'dart:async';

import 'webdav_debug_log.dart';

/// UI isolate 卡顿看门狗：**只做取证与自愈，不做任何拦截**。
///
/// ## 为什么需要（issue #52 / #53 / #58）
/// 这三份报告都是同一个形态：`ANR ... Input dispatching timed out ...
/// Waited 5001ms for FocusEvent(hasFocus=false)`，主线程 `state=R`、栈全在
/// `libapp.so` 里（Dart 编译产物），`RssHwmKb ≈ 1.2 GB`。因为发布包没有带
/// `--split-debug-info` 符号表，`libapp.so` 只有 `.dynsym`、**无法符号化**，
/// 三次都只能给出「内存高压 + 主 isolate 忙」这类推测，定位不到具体页面。
///
/// 这个看门狗补的正是缺失的那一维：**卡顿了多久、当时是什么状态**。
/// 它跑在 UI isolate 自身，所以一旦 UI isolate 被长时间占住，定时器就不会准时
/// 触发；下一次触发时测到的间隔就是卡顿时长的下界。
///
/// ## 为什么用 1 秒定时器而不是别的
/// * `SchedulerBinding.addTimingsCallback` 只在**出帧**时回调，界面静止时判定
///   不了「卡住」与「空闲」的区别；
/// * 心跳是唯一能在**没有任何帧**的情况下判断 isolate 是否活着的办法。
/// 每次 tick 只做一次 `DateTime.now()` 与比较，开销可忽略。
///
/// ## 约束
/// * 上报走后门 [WebdavDebugLog.logAlways]（不受诊断开关控制）——
///   普通用户发版时诊断日志是关的，否则这条线索永远拿不到；
/// * **低频**：同类卡顿最多每 [reportInterval] 记一条，避免把自己写成新的卡顿源；
/// * 不含任何敏感串（只有时长、生命周期、缓存占用）。
class UiStallWatchdog {
  UiStallWatchdog._();

  /// 心跳间隔。
  static const Duration period = Duration(seconds: 1);

  /// 超过这个间隔才认定「卡过」（低于它的是普通调度抖动，不值得记）。
  static const Duration threshold = Duration(milliseconds: 2500);

  /// 同类卡顿的最小上报间隔。
  static const Duration reportInterval = Duration(seconds: 30);

  static Timer? _timer;
  static DateTime _last = DateTime.now();
  static DateTime? _lastReport;

  /// 附加现场信息（当前页面、生命周期、缓存占用由调用方拼）。
  static String Function()? _contextBuilder;

  /// 卡顿自愈回调（释放内存缓存等）。
  static void Function(Duration stall)? _onStall;

  static bool get isRunning => _timer != null;

  /// 启动看门狗，重复调用无副作用。
  ///
  /// [context] 在**卡顿发生时**才调用（不能提前调，否则测到的是自己的开销）。
  /// [onStall] 收到卡顿时长，用于释放缓存自救。
  static void start({
    String Function()? context,
    void Function(Duration stall)? onStall,
  }) {
    if (_timer != null) return;
    _contextBuilder = context;
    _onStall = onStall;
    _last = DateTime.now();
    _timer = Timer.periodic(period, (_) => _tick());
  }

  static void stop() {
    _timer?.cancel();
    _timer = null;
    _contextBuilder = null;
    _onStall = null;
  }

  static void _tick() {
    final now = DateTime.now();
    final gap = now.difference(_last);
    _last = now;
    if (gap < threshold) return;

    final lastReport = _lastReport;
    if (lastReport != null && now.difference(lastReport) < reportInterval) {
      return;
    }
    _lastReport = now;

    var extra = '';
    try {
      extra = _contextBuilder?.call() ?? '';
    } catch (_) {
      // 现场信息拿不到不影响主流程
    }
    WebdavDebugLog.logAlways('[stall] UI 线程卡顿 ${gap.inMilliseconds}ms$extra');
    try {
      _onStall?.call(gap);
    } catch (_) {}
  }
}
