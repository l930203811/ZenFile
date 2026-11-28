import 'webdav_debug_log.dart';

/// 慢操作计时（诊断用，2026-11-27 新增）。
///
/// ## 为什么需要它
///
/// 真机日志里最关键的一行是：
/// ```
/// [tap] 掉帧 1724ms (build 0ms, raster 6ms, vsync等待 1717ms, ...)
/// ```
/// `vsync 等待 1717ms` = vsync 信号到了以后，UI 线程过了 **1.7 秒**才开始构建这一帧；
/// 而 build 只有 0ms、raster 只有 6ms —— 说明这 1.7 秒**根本不在 Flutter 的
/// 构建/光栅里**，是主线程被别的东西整段占住了。那段时间里 Android 主线程
/// 不派发 MotionEvent、不处理 IME 按键 ⇒ **「点任意按钮要点两次」「键盘也要点两次」**。
///
/// 光看帧日志只能知道「主线程被堵了 1.7 秒」，**说不出是被哪一步堵的**。
/// 本工具给启动/恢复链路上的每一步都套上计时，超过阈值就记一行，
/// 下一份日志就能直接点名凶手。
///
/// ## 约束
///
/// * 阈值 [threshold] 故意定得不高（200ms）：低于这个值的步骤不是问题。
/// * 落盘是同步 IO，所以**只在超过阈值时才写**，正常路径零开销。
/// * 不改变任何行为，只测量（`finally` 里计时，异常照样抛出）。
class SlowOp {
  SlowOp._();

  /// 超过这个耗时才算「慢」。
  static const Duration threshold = Duration(milliseconds: 200);

  /// 同类慢操作日志的最小间隔，避免刷屏。
  ///
  /// ⚠️ **按操作名各自限频**，而不是全局共用一个时间戳：
  /// 启动链路上的慢步骤是**连续**发生的（自定义分类 → 最近文件 → 落盘…），
  /// 全局限频会把后面几条**全部吞掉** —— 实测就因此漏掉了真正的凶手。
  static const Duration reportInterval = Duration(seconds: 3);

  static final Map<String, DateTime> _lastReportAt = {};

  /// 测量一段异步操作；超过 [threshold] 时记一条 `[慢操作]` 日志。
  ///
  /// [name] 只写业务名（如 `恢复刷新.加载音频`），不含任何用户数据。
  static Future<T> run<T>(String name, Future<T> Function() body) async {
    final sw = Stopwatch()..start();
    try {
      return await body();
    } finally {
      sw.stop();
      // 注意：这里**不能**用 `return;` 提前退出——`finally` 里的 `return`
      // 会把上面 `return await body()` 的返回值吞掉（还会触发
      // return_without_value 告警）。只能用 if 嵌套。
      if (sw.elapsed >= threshold) {
        final now = DateTime.now();
        final last = _lastReportAt[name];
        if (last == null || now.difference(last) >= reportInterval) {
          _lastReportAt[name] = now;
          WebdavDebugLog.logAlways('[慢操作] $name ${sw.elapsedMilliseconds}ms');
        }
      }
    }
  }
}
