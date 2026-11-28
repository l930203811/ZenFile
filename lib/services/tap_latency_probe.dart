import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

import 'webdav_debug_log.dart';
import 'build_trigger_counter.dart';

/// 点击延迟取证探针（2026-11-27 新增）。
///
/// ## 要回答的问题
///
/// 用户反馈「点任意按钮都要点两次才触发」。这有两种完全不同的成因，修法也完全不同：
///
/// * **(A) 点击被吞掉** —— 回调**根本没有执行**。可能来自手势竞技场落败、
///   控件在按下与抬起之间被重建销毁、或某个透明 barrier 吃掉了事件。
/// * **(B) 点击迟到** —— 回调**执行了**，但被排在几百个 IO 回调之后，
///   晚了几百毫秒才跑；此时界面还没画出变化，用户看着就是「点了没反应」，
///   于是又点一次 —— 第二次因为状态已就绪而「生效」，于是表现为「要点两次」。
///
/// 光看现象无法区分，必须在真机上量出数据。这个探针提供三个信号：
///
/// 1. **输入事件排队延迟**（全局）：框架处理 down→up 的墙钟间隔，减去系统记录的
///    按压时长。差值就是 up 事件在队列里多等的时间 ⇒ 直接证明 (B)。
/// 2. **点击回调延迟 / 点击未生效**（控件级）：底栏每个槽位在按下时自报时刻、
///    在 `onTap` 回调里自报到达时刻。有按下无回调 ⇒ (A)；有回调但很慢 ⇒ (B)。
/// 3. **掉帧**：超过阈值的 build/layout/raster 耗时，解释「为什么慢」。
///    其中 **vsync 等待**（buildStart − vsyncStart）是「主线程被堵了多久」的
///    直接量化值 —— 真机日志里出现过 `掉帧 1812ms (build 0ms, raster 19ms)`，
///    build/raster 都是 0，说明那 1.8 秒**根本不在 Flutter 的构建/光栅里**，
///    而是主线程被别的东西整段占住（那段时间里触摸与 IME 按键全在排队）。
///    同时附带**重建来源计数**，区分「被 provider 通知触发」与「滚动/动画触发」。
///
/// ## 约束
///
/// * 走 [WebdavDebugLog.logAlways]（不受诊断开关控制）—— 普通发版也能取到证据，
///   与 [UiStallWatchdog] 同理：诊断日志开关在正式版是关的，否则这条线索永远拿不到。
/// * **严格限频**：每类最多每 [reportInterval] 一条。探针绝不能自己变成新的卡顿源。
/// * ⚠️ 落盘已是**异步**（见 [WebdavDebugLog] 的缓冲说明）：旧实现是同步写
///   FUSE 外部存储，**探针自己就会把主线程堵住几百毫秒**（真机日志里那次
///   「主线程阻塞 1724ms」就紧跟在「探针启动 v3」这行同步写之后）。
/// * 不含任何敏感串：只有耗时、槽位下标、坐标。
class TapLatencyProbe {
  TapLatencyProbe._();

  /// 指针事件在队列里多等超过这个值 ⇒ 记一条「输入事件排队」。
  static const Duration inputLagThreshold = Duration(milliseconds: 150);

  /// 控件的「按下 → onTap 回调」耗时超过这个值 ⇒ 记一条「点击回调迟到」。  /// 控件的「按下 → onTap 回调」耗时超过这个值 ⇒ 记一条「点击回调迟到」。
  static const Duration tapCallbackThreshold = Duration(milliseconds: 250);

  /// 判定「这一次按下本该是一次点击」的按压时长上限（超过就是长按 / 拖拽，不算点击）。
  static const Duration tapLikeMaxDuration = Duration(milliseconds: 500);

  /// 判定「这一次按下本该是一次点击」的最大位移（超过就是拖拽）。
  static const double tapLikeMaxMove = 24.0;

  /// 按下之后多久还没有回调，就判定「这次点击没生效」。
  static const int _tapMissingTimeoutMs = 800;
  static const Duration tapMissingTimeout = Duration(
    milliseconds: _tapMissingTimeoutMs,
  );

  /// 单帧总耗时超过这个值 ⇒ 记一条「掉帧」（60fps 下 16.7ms，32ms 即掉一帧）。
  static const Duration frameThreshold = Duration(milliseconds: 32);

  /// 同类日志的最小间隔。
  static const Duration reportInterval = Duration(seconds: 3);

  /// 同时按下的指针数量上限：异常情况下防止记录表无限增长。
  static const int _maxTrackedPointers = 16;

  static bool _started = false;

  /// 单调时钟（不受改系统时间 / 深睡 / 校时影响）。
  static final Stopwatch _clock = Stopwatch()..start();

  /// 正在按下的指针。
  static final Map<int, _PointerRecord> _pointers = <int, _PointerRecord>{};

  /// 控件级：最近一次「按下」的自报记录。
  static _ControlTap? _controlTap;

  static int _lastInputLagReportUs = -1000000;
  static int _lastTapLateReportUs = -1000000;
  static int _lastTapMissingReportUs = -1000000;
  static int _lastFrameReportUs = -1000000;

  /// 启动探针，重复调用无副作用。
  ///
  /// 必须在 [WidgetsFlutterBinding.ensureInitialized] 之后调用。
  static void start() {
    if (_started) return;
    _started = true;
    // 全局路由：拿到**所有**指针事件（早于任何控件的命中测试）。
    GestureBinding.instance.pointerRouter.addGlobalRoute(_handlePointerEvent);
    // 帧耗时：只在真的出帧时回调。
    SchedulerBinding.instance.addTimingsCallback(_handleFrameTimings);
    // 主线程阻塞探测器（见 [_startHeartbeat]）。
    _startHeartbeat();
    // 前后台状态：用于把「后台时长」从主线程阻塞里剔除（见 [onLifecycle]）。
    WidgetsBinding.instance.addObserver(_ProbeLifecycleObserver());
    // 启动标记：让「这份日志是哪个包产出的」一眼可辨。
    // ⚠️ 非常重要：排查期间出现过「日志来自另一台手机/旧包」的情况，
    // 白白绕一大圈。下一份日志里只要有这一行，就说明探针在跑。
    WebdavDebugLog.logAlways('[tap] 探针启动 v3（含 vsync等待/Δ重建/主线程阻塞/媒体索引）');
  }

  // ── 主线程阻塞探测器 ──────────────────────────────────────────────

  /// 心跳周期（毫秒）。
  static const int _heartbeatPeriodMs = 200;

  /// 心跳迟到超过这个值 ⇒ 认定 UI isolate 被整段占住。
  static const int _heartbeatLateThresholdMs = 300;

  static Timer? _heartbeatTimer;
  static int _lastHeartbeatUs = 0;

  /// 当前是否在前台。
  ///
  /// 后台期间 Dart 定时器会被挂起 ⇒ 回到前台时心跳会「迟到」几秒甚至几十秒 ——
  /// 那是**后台时长**，不是主线程阻塞。
  /// 实测踩过这个坑：日志里一度出现 `主线程阻塞 13660ms`，其实是应用切后台停了
  /// 13.6 秒、回前台时被误判成阻塞（同一时刻的 `回到前台` 标记正好对上）。
  /// ⇒ 必须跟踪前后台状态，并在回前台时**重新校准心跳基线**。
  static bool _isForeground = true;

  /// 由 [_ProbeLifecycleObserver] 调用：应用前后台状态变化。
  static void onLifecycle(AppLifecycleState state) {
    _isForeground = state == AppLifecycleState.resumed;
    // 重新校准基线：把「后台期间累计的时长」从下一次测量里扣掉。
    _lastHeartbeatUs = _clock.elapsedMicroseconds;
    // ⚠️ **必须清空正在按下的指针记录**（2026-11-28 修正）。
    // 切后台时可能有「按下」没有对应的「抬起」（手势被系统掐断），那条记录会
    // 一直留在表里；下次回到前台，Android 会**复用同一个 pointer id**（从 0 开始），
    // 于是新手势的「抬起」会匹配到那条陈旧记录 ⇒ 算出的按压时长是**负的**
    // （真机日志实测 `按压 -1606571ms`），队列延迟随之变成纯噪声。
    if (!_isForeground) {
      _pointers.clear();
    }
  }

  /// 用一个**定时器心跳**测量 UI isolate 被占住多久。
  ///
  /// ## 为什么需要它
  ///
  /// `vsync 等待` 能告诉我们「主线程被堵了 1.7 秒」，但那 1.7 秒是**谁**干的，
  /// 帧日志说不出来；而 [SlowOp] 只能包住我们自己的代码，包不住第三方插件
  /// （photo_manager / on_audio_query 的平台通道回调等）。
  ///
  /// 定时器心跳是**通用**的：只要 UI isolate 被任何东西占住，
  /// 这次心跳就会迟到，迟到多少就是被占了多久。
  /// 它测不出「谁」，但能证明「有东西在占」，并且和 [SlowOp] 的点名互相印证。
  ///
  /// 注意：定时器本身在**主 isolate** 上，isolate 被占时定时器不会丢，
  /// 只是迟到 —— 这正是我们要测的量。
  static void _startHeartbeat() {
    _lastHeartbeatUs = _clock.elapsedMicroseconds;
    _heartbeatTimer ??= Timer.periodic(
      const Duration(milliseconds: _heartbeatPeriodMs),
      (_) {
        final nowUs = _clock.elapsedMicroseconds;
        final expectedUs = _lastHeartbeatUs + _heartbeatPeriodMs * 1000;
        _lastHeartbeatUs = nowUs;
        // 后台期间不测量（定时器被挂起，迟到量是后台时长，不是阻塞）。
        if (!_isForeground) return;
        final lateUs = nowUs - expectedUs;
        if (lateUs < _heartbeatLateThresholdMs * 1000) return;
        // 限频：一次长阻塞会让心跳连续迟到，只记第一条。
        if (nowUs - _lastHeartbeatReportUs < reportInterval.inMicroseconds) {
          return;
        }
        _lastHeartbeatReportUs = nowUs;
        WebdavDebugLog.logAlways(
          '[tap] 主线程阻塞 ${(lateUs / 1000).round()}ms '
          '(UI isolate 被整段占住，期间触摸/按键全部排队)',
        );
      },
    );
  }

  static int _lastHeartbeatReportUs = -1000000;

  /// 控件级自报：**收到按下**。
  ///
  /// 由「到处都在点」的控件（如底栏槽位）调用，[event] 用于与全局指针记录对齐。
  static void markControlDown(PointerDownEvent event, int slot) {
    _controlTap = _ControlTap(
      pointer: event.pointer,
      slot: slot,
      atUs: _clock.elapsedMicroseconds,
      fired: false,
    );
  }

  /// 控件级自报：**onTap 回调真的执行了**。
  static void markControlTap(int slot) {
    final tap = _controlTap;
    if (tap == null) return;
    if (tap.fired) return;
    tap.fired = true;
    // 迟到的回调不再参与「未生效」判定。
    if (identical(_controlTap, tap)) _controlTap = null;

    final lateUs = _clock.elapsedMicroseconds - tap.atUs;
    if (lateUs < tapCallbackThreshold.inMicroseconds) return;
    final nowUs = _clock.elapsedMicroseconds;
    if (nowUs - _lastTapLateReportUs < reportInterval.inMicroseconds) return;
    _lastTapLateReportUs = nowUs;
    WebdavDebugLog.logAlways(
      '[tap] 点击回调迟到 ${(lateUs / 1000).round()}ms (slot=${tap.slot})',
    );
  }

  // ── 全局指针事件 ────────────────────────────────────────────────────

  static void _handlePointerEvent(PointerEvent event) {
    if (event is PointerDownEvent) {
      if (_pointers.length >= _maxTrackedPointers) _pointers.clear();
      final receiptUs = _clock.elapsedMicroseconds;
      final gestureSeq = ++_gestureSeq;
      final hitTest = _describeHitTest(event.position);
      WebdavDebugLog.logAlways(
        '[tap] 指针#$gestureSeq DOWN kind=${event.kind.name} '
        'buttons=${event.buttons} synthesized=${event.synthesized} $hitTest',
      );
      _pointers[event.pointer] = _PointerRecord(
        osTime: event.timeStamp,
        fwAtUs: receiptUs,
        position: event.position,
        countersAtDown: BuildTriggerCounter.snapshot(),
        gestureSeq: gestureSeq,
        hitTest: hitTest,
      );
      // ⚠️ 长按取证（2026-11-28 第十一轮新增）。
      //
      // 探针原来只统计「≤500ms 且位移 ≤24px」的抬起，**长按手势被整段丢弃** ——
      // 既没有最大位移，也没有时长 ⇒ 用户报「长按全部无响应」时，
      // 探针**什么都看不见**，完全无法判断是「用户没按住」还是「App 没认」。
      //
      // 这里在探针侧**独立**复刻一遍 Flutter 的长按判定条件
      // （按住 ≥450ms 且位移 < kTouchSlop），只要条件达成就记一条。
      // 于是下一份日志里两条线可以对照：
      // * 探针记了「长按条件达成」，但 App 侧没有任何长按回调日志
      //   ⇒ **App 的长按识别器被否决了**（位移超 slop / 竞技场输掉 / 回调没接上）；
      // * 探针也没记 ⇒ 用户根本没按住那么久（或事件没进 App）。
      _armLongPressCheck(event.pointer);
      return;
    }
    if (event is PointerMoveEvent) {
      _pointers[event.pointer]?.move(event.position);
      return;
    }
    if (event is PointerUpEvent || event is PointerCancelEvent) {
      final rec = _pointers.remove(event.pointer);
      if (rec == null) return;
      _onPointerUp(event, rec);
    }
  }

  // ── 长按取证 ──────────────────────────────────────────────────────────

  /// Flutter 的长按死线是 500ms（`kLongPressTimeout`），位移容差是
  /// `kTouchSlop`（18 逻辑像素）。
  ///
  /// 探针用略小的阈值（450ms）判定「用户确实在长按」，并把**实际最大位移**
  /// 一并打出来 —— 位移一旦超过 18px，就能直接判定「长按是被 slop 否决的」，
  /// 而不是「App 根本没实现长按」。
  static const Duration _longPressProbeDelay = Duration(milliseconds: 450);

  /// 位移容差阈值。
  ///
  /// ⚠️ 必须与 App 实际生效的值一致：本项目通过 [GestureSlopScope] 把
  /// `MediaQuery.gestureSettings.touchSlop` 全局放宽到 **24px**（低端机上
  /// 平台只给 8px，手指轻微抖动就把长按否掉了）。
  /// ⇒ 探针若还用 18px 判定，日志会**误报**「框架必否决长按」。
  static const double _longPressSlopTolerance = 24.0;

  /// 长按判定定时器（按 pointer id 存）。
  static final Map<int, Timer> _longPressTimers = <int, Timer>{};

  /// 所有手势的序号（第几次按下）。
  static int _gestureSeq = 0;

  /// **命中测试链**（按下那一刻手指压在了谁身上）。
  ///
  /// ## 为什么需要它（2026-11-28 第十一轮末）
  ///
  /// 「长按全部无响应」查到了最后一步仍然无法定论：
  /// * 探针侧判定「按住 808ms、位移 3.8px」⇒ 长按条件**完全达成**；
  /// * 框架源码也确认：死线定时器在 pointer down 时启动、位移没超 slop
  ///   ⇒ `onLongPressStart` **应该**在 500ms 触发；
  /// * 但 App 侧的长按回调日志**一条都没有**。
  ///
  /// ⇒ 剩下的唯一可能：**那根手指压根没落在「带长按识别器」的控件上**。
  /// 而 `debugCreator`（RenderObject → Widget 的官方反查入口）**只在 debug
  /// 构建里赋值**（框架源码里是 `assert(() { renderObject.debugCreator = … })`），
  /// 正式包里拿不到控件类型。
  ///
  /// ⇒ 改用**不需要控件类型**的判据：统计命中路径里
  /// `RenderSemanticsGestureHandler` 的实际语义回调。
  ///
  /// `GestureDetector` / `InkWell` / `InkResponse` 内部都走 `RawGestureDetector`
  /// ⇒ 渲染树上会出现 `RenderSemanticsGestureHandler`，但是否具备长按能力
  /// 必须看 `onLongPress` 等回调是否非空。仅统计该渲染对象数量会把只有点击能力
  /// 的内层 InkWell 误判成“长按识别器已命中”；`点击=N 长按=N 拖动=N`
  /// 才是对应识别器是否位于命中路径中的证据。
  ///
  /// 同时输出 `RenderPointerListener` 的个数（每个 `Listener`/`GestureDetector`
  /// 都会带一个），用来数「叠了几层手势控件」，
  /// 便于区分「按在分类卡（外层 GestureDetector + InkWell + LiquidPressable）」
  /// 还是「按在别的地方」。
  static String _describeHitTest(Offset globalPosition) {
    try {
      final Iterable<RenderView> views = RendererBinding.instance.renderViews;
      if (views.isEmpty) return '命中=无视图';
      final HitTestResult result = HitTestResult();
      views.first.hitTest(result, position: globalPosition);
      int listeners = 0;
      int semantics = 0;
      int tapHandlers = 0;
      int longPressHandlers = 0;
      int dragHandlers = 0;
      final List<String> path = <String>[];
      // ⚠️ `HitTestResult.path` 的顺序是**从最具体到最宽泛**
      // （框架文档：The first entry in the path is the most specific,
      //  typically the one at the leaf of tree being hit tested）。
      // ⇒ 第一个条目才是「手指真正压到的那个渲染对象」（末端）。
      //
      // ⚠️⚠️ 2026-11-28 第十五轮修正：**计数必须覆盖整条路径**。
      //
      // 第十四轮的实现在 `path.length >= 14` 时直接 `break`，于是
      // `listeners` / `semantics` 两个计数也只统计了前 14 条 ——
      // 而外层 `GestureDetector` 与 `LiquidPressable` 的条目往往排在
      // 第 15 条以后 ⇒ **计数被截断**，「手势识别器层=0」是**假阴性**。
      //
      // ⇒ 现在：计数遍历**全部**条目；只有「打印用的路径字符串」才限量，
      //    且限量时明确打上 `…` 标记，表示后面还有内容。
      for (final HitTestEntry entry in result.path) {
        final String t = entry.target.runtimeType.toString();
        if (t == 'RenderPointerListener') {
          listeners++;
        } else if (t == 'RenderSemanticsGestureHandler') {
          semantics++;
          final target = entry.target;
          if (target is RenderSemanticsGestureHandler) {
            if (target.onTap != null) tapHandlers++;
            if (target.onLongPress != null) longPressHandlers++;
            if (target.onHorizontalDragUpdate != null ||
                target.onVerticalDragUpdate != null) {
              dragHandlers++;
            }
          }
        }
        // 完整路径（去重相邻同名）—— 这是判断「手势控件在不在路径里」的关键证据。
        if (path.isEmpty || path.last != t) {
          path.add(t);
        }
      }
      final bool truncated = path.length > _hitTestPathPrintLimit;
      final List<String> shown = truncated
          ? path.sublist(0, _hitTestPathPrintLimit)
          : path;
      return '命中 指针层=$listeners 语义手势层=$semantics '
          '点击=$tapHandlers 长按=$longPressHandlers 拖动=$dragHandlers '
          '路径=${shown.join('>')}${truncated ? '>…' : ''}';
    } catch (e) {
      return '命中=探测失败($e)';
    }
  }

  /// 打印用路径的最大条目数。
  ///
  /// ⚠️ 这个上限**只影响打印**，不影响上面的计数（计数遍历整条路径）。
  /// 第十四轮把两者混在一起，导致计数失真（见 [_describeHitTest] 的注释）。
  static const int _hitTestPathPrintLimit = 28;

  /// 在「按下」时挂一个长按判定定时器。
  ///
  /// 它与 App 自己的长按识别器**完全独立**：即使 App 的识别器被否决了，
  /// 这个定时器照样会响 ⇒ 于是两条日志可以对照，把「用户没按住」与
  /// 「App 认了但没反应」彻底分开。
  static void _armLongPressCheck(int pointer) {
    _longPressTimers.remove(pointer)?.cancel();
    _longPressTimers[pointer] = Timer(_longPressProbeDelay, () {
      _longPressTimers.remove(pointer);
      final rec = _pointers[pointer];
      if (rec == null) return; // 手指已经抬起
      final moved = rec.maxMoveFromStart;
      WebdavDebugLog.logAlways(
        '[tap] 长按条件#${rec.gestureSeq} 探针判定: 已按住'
        '${_longPressProbeDelay.inMilliseconds}ms '
        '最大位移${moved.toStringAsFixed(1)}px '
        '${moved > _longPressSlopTolerance ? '位移>slop ⇒ 框架必否决长按' : '位移在slop内 ⇒ App侧本应收到长按'} '
        '${rec.hitTest}',
      );
    });
  }

  /// 报告输入事件在框架队列中的相对排队延迟。
  ///
  /// 绝对延迟依赖跨时钟域换算，真机上会随深睡漂移，已停止输出。
  ///
  /// 主线程若在 down 之前被堵住，down/up 可能一起排队，这是相对延迟的盲区。
  static void _onPointerUp(PointerEvent event, _PointerRecord rec) {
    // 长按判定的定时器：手指已经抬起 ⇒ 取消。
    _longPressTimers.remove(event.pointer)?.cancel();

    // ① 事件排队延迟：框架处理 down→up 的墙钟间隔，减去系统记录的按压时长。
    //
    // ⚠️ 系统按压时长可能为**负**（2026-11-28 修正）：当「抬起」匹配到了一条
    // 陈旧的「按下」记录（切后台时手势被掐断，pointer id 又被系统复用），
    // `up.timeStamp − down.timeStamp` 就会算出负数，把队列延迟变成纯噪声
    // （真机日志实测 `按压 -1606571ms` / `输入事件排队 1607077ms`）。
    // ⇒ 负值一律视为「记录失效」，改用**框架侧**的按压时长，并跳过队列延迟判定。
    final osGapUs = (event.timeStamp - rec.osTime).inMicroseconds;
    final fwGapUs = _clock.elapsedMicroseconds - rec.fwAtUs;
    if (osGapUs >= 0) {
      final lagUs = fwGapUs - osGapUs;
      if (lagUs >= inputLagThreshold.inMicroseconds) {
        final nowUs = _clock.elapsedMicroseconds;
        if (nowUs - _lastInputLagReportUs >= reportInterval.inMicroseconds) {
          _lastInputLagReportUs = nowUs;
          WebdavDebugLog.logAlways(
            '[tap] 输入事件排队 ${(lagUs / 1000).round()}ms '
            '(系统按压 ${(osGapUs / 1000).round()}ms → 框架处理间隔 ${(fwGapUs / 1000).round()}ms)',
          );
        }
      }
    }

    // ③ **通用点击取证**（2026-11-28 新增）：覆盖**所有**控件，不只是底栏。
    //
    // ## 为什么必须加这条
    //
    // 之前只有底栏槽位自报「按下 → onTap」，覆盖面太窄：用户在分类页点
    // 文档/视频/图片/音频、在浏览页点文件夹、**在软键盘上按键**，
    // 这些都不经过底栏 ⇒ 探针对它们**完全失明**。
    //
    // 而最新真机日志里，用户复现期间**一条** `点击未生效` / `点击回调迟到` /
    // `输入延迟` / `输入事件排队` 都没有 —— 说明「没反应」的那部分点击
    // 根本没被现有的探针看见。
    //
    // ## 这条日志能区分三种截然不同的「没反应」
    //
    // 每次「像点击」的抬起都记一行，并在 400ms 后回看这期间有没有发生
    // provider 通知 / 页面重建：
    //
    // * **Δ 全为 0** ⇒ 点击到达了框架，但**没有任何业务代码响应它**
    //   ⇒ 事件被 App 自己吞掉（手势竞技场输掉 / 控件在抬起前被重建销毁 /
    //   命中测试落在了别的控件上）⇒ **行为问题**，要查代码；
    // * **Δ 不为 0** ⇒ 业务代码**确实执行了**，只是可见效果没出来
    //   ⇒ 状态/渲染问题（更新被覆盖、页面被立刻抵消、effect 没跑）；
    // * 同时打印「距上次点击的间隔」，能把用户的点击节奏与失败模式对上
    //   （例如：间隔 <1s 的失败、>1s 的成功 ⇒ 是节流/守卫；
    //   或奇偶交替 ⇒ 是配对语义/元素替换）。
    final moved = rec.maxMoveFromStart;
    // 按压时长：系统给的可能是负的（记录失效），此时改用框架侧时长。
    final pressUs = osGapUs >= 0 ? osGapUs : fwGapUs;

    // ③ 长按类手势**单独**记一条（2026-11-28 第十一轮新增）。
    //
    // 探针原来只统计「≤500ms 且位移 ≤24px」的抬起 —— **长按手势被整段丢弃**，
    // 连最大位移都没留下。于是用户报「所有长按都无响应」时，
    // 探针**什么都看不见**，无法区分「用户没按住」和「App 没认」。
    //
    // 这一条给出长按的三个关键量：总时长、最大位移、MOVE 次数。
    // 其中「最大位移」能直接判定 Flutter 的长按是否会被否决：
    // `LongPressGestureRecognizer` 的 `preAcceptSlopTolerance` 默认是
    // `kTouchSlop`（18 逻辑像素），**超期前位移超过它 ⇒ 长按直接被 reject**。
    if (pressUs >= _longPressProbeDelay.inMicroseconds) {
      WebdavDebugLog.logAlways(
        '[tap] 长按手势#${rec.gestureSeq} 按压${(pressUs / 1000).round()}ms '
        '最大位移${moved.toStringAsFixed(1)}px 移动${rec.moveCount}次 '
        '${moved > _longPressSlopTolerance ? '位移>slop(${_longPressSlopTolerance.toStringAsFixed(0)}px) ⇒ 框架必否决长按' : '位移在slop内 ⇒ App侧本应收到长按'} '
        '结束=${event is PointerCancelEvent ? 'CANCEL' : 'UP'} '
        '${rec.hitTest}',
      );
    }

    if (pressUs <= tapLikeMaxDuration.inMicroseconds &&
        moved <= tapLikeMaxMove) {
      _reportGlobalTap(event, rec, pressUs, moved);
    }

    // ② 「点击未生效」判定：这次手势像是一次点击，但对应的 onTap 回调没来。
    final tap = _controlTap;
    if (tap == null || tap.pointer != event.pointer || tap.fired) return;
    if (pressUs > tapLikeMaxDuration.inMicroseconds) return;
    if (moved > tapLikeMaxMove) return;
    // 等一小会儿：如果回调在这之前到了，说明只是慢，不是没生效。
    Timer(Duration(milliseconds: _tapMissingTimeoutMs), () {
      final current = _controlTap;
      if (current == null || current.fired || current.pointer != tap.pointer) {
        return;
      }
      final nowUs = _clock.elapsedMicroseconds;
      if (nowUs - _lastTapMissingReportUs < reportInterval.inMicroseconds)
        return;
      _lastTapMissingReportUs = nowUs;
      WebdavDebugLog.logAlways(
        '[tap] 点击未生效：按下后 ${tapMissingTimeout.inMilliseconds}ms 仍无 onTap 回调 '
        '(slot=${tap.slot}, 按压 ${(pressUs / 1000).round()}ms, 位移 ${moved.toStringAsFixed(1)}px) '
        '${rec.hitTest}',
      );
    });
  }

  /// 通用点击的全局序号（第几次「像点击」的抬起）。
  static int _globalTapSeq = 0;

  /// 上一次「像点击」的抬起时刻（微秒），用于算用户的点击节奏。
  static int _lastGlobalTapUpUs = -1;

  /// 记录一次通用点击，并在 400ms 后回看「有没有业务响应」。
  ///
  /// ## 计数窗口的取法（2026-11-28 修正，关键）
  ///
  /// 之前只在「抬起」这一刻拍一次计数快照 ⇒ **按压窗口（按下→抬起）内**发生的
  /// 重建/通知**全被漏掉**。而「重建把控件换掉 → 在飞手势被取消」正是要查的事 ——
  /// 漏掉它就等于把最关键的证据扔了。
  ///
  /// 现在拍**两次**：
  /// * `按下`时刻拍一份 ⇒ 「按压窗口内」的增量；
  /// * `抬起`时刻拍一份 ⇒ 「抬起后 400ms 内」的增量。
  ///
  /// ⇒ 日志里 `按压内` 与 `400ms内` 两组数字，能直接回答：
  /// 「抬起之前控件是不是被重建掉了」。
  static void _reportGlobalTap(
    PointerEvent upEvent,
    _PointerRecord rec,
    int pressUs,
    double moved,
  ) {
    final nowUs = _clock.elapsedMicroseconds;
    _globalTapSeq++;
    final seq = _globalTapSeq;
    final sinceLastUs = _lastGlobalTapUpUs < 0
        ? -1
        : nowUs - _lastGlobalTapUpUs;
    _lastGlobalTapUpUs = nowUs;

    // 按压窗口内的增量（按下 → 抬起）。
    final atUp = BuildTriggerCounter.snapshot();
    final atDown = rec.countersAtDown;
    final pFm = atUp[0] - atDown[0];
    final pMedia = atUp[1] - atDown[1];
    final pBrowse = atUp[2] - atDown[2];
    final pHome = atUp[3] - atDown[3];
    final pGrid = atUp[4] - atDown[4];
    final pNav = atUp[5] - atDown[5];

    Timer(const Duration(milliseconds: 400), () {
      final after = BuildTriggerCounter.snapshot();
      final dFm = after[0] - atUp[0];
      final dMedia = after[1] - atUp[1];
      final dBrowse = after[2] - atUp[2];
      final dHome = after[3] - atUp[3];
      final dGrid = after[4] - atUp[4];
      final dNav = after[5] - atUp[5];
      // ⚠️ 导航事件必须算进「有响应」（2026-11-28 第十一轮修正）。
      //
      // 之前只看「浏览/首页/网格 有没有重建」⇒ **打开一个新页面**既不重建
      // 这三处、也不通知 provider ⇒ 一次「成功打开了视频页」的点击会被判成
      // 「400ms 内无响应」。真机日志里 6 次分类卡片点击全是这种误判，
      // 把排查方向带偏了一整轮（以为是「点击被吞」，实际是「页面没打开」）。
      final afterReacted = (dFm + dMedia + dBrowse + dHome + dGrid + dNav) > 0;
      final pressReacted = (pFm + pMedia + pBrowse + pHome + pGrid + pNav) > 0;
      WebdavDebugLog.logAlways(
        '[tap] 点击#$seq 抬起 距上次${sinceLastUs < 0 ? '-' : (sinceLastUs / 1000).round()}ms '
        '按压${(pressUs / 1000).round()}ms 位移${moved.toStringAsFixed(1)}px '
        '按压内${pressReacted ? '有响应' : '无响应'} '
        '通知 fm=$pFm media=$pMedia 重建 浏览=$pBrowse 首页=$pHome 网格=$pGrid 导航=$pNav | '
        '400ms内${afterReacted ? '有响应' : '无响应'} '
        '通知 fm=$dFm media=$dMedia 重建 浏览=$dBrowse 首页=$dHome 网格=$dGrid 导航=$dNav '
        '${rec.hitTest}',
      );
    });
  }

  // ── 帧耗时 ──────────────────────────────────────────────────────────

  /// 上一次打印时各计数器的快照（用来算增量）。
  static List<int>? _lastCounterSnapshot;

  static void _handleFrameTimings(List<FrameTiming> timings) {
    for (final t in timings) {
      final localNowUs = _clock.elapsedMicroseconds;

      final total = t.totalSpan;
      if (total < frameThreshold) continue;
      if (localNowUs - _lastFrameReportUs < reportInterval.inMicroseconds)
        break;
      _lastFrameReportUs = localNowUs;

      // ── vsyncOverhead：主线程到底被堵了多久 ────────────────────────
      //
      // `vsyncOverhead` = buildStart − vsyncStart，即「vsync 信号来了之后，
      // UI 线程过了多久才开始构建这一帧」。
      //
      // **这是「要点两次」最直接的量化指标**：这段时间里 Android 主线程
      // 不处理 MotionEvent、不处理 IME 按键，用户的每一次触摸都在排队。
      //
      // 之前只看 `build` / `raster` 是看不出来的：真机日志里出现过
      // `掉帧 1812ms (build 0ms, raster 19ms)` —— build 和 raster 都是 0，
      // 说明这 1812ms **根本不在 Flutter 的构建/光栅里**，而是
      // 「主线程被别的什么东西占住了整整 1.8 秒」。
      final vsyncWaitMs = t.vsyncOverhead.inMilliseconds;

      // ── UI → 光栅的交接延迟 ─────────────────────────────────────────
      //
      // rasterStart − buildFinish：UI 线程把帧交给光栅线程后，
      // 光栅线程等了多久才开始干活。光栅线程排不上队时（比如 GPU 忙、
      // 或上一帧还没画完），这里会明显大于 0。
      final buildFinishUs = t.timestampInMicroseconds(
        ui.FramePhase.buildFinish,
      );
      final rasterStartUs = t.timestampInMicroseconds(
        ui.FramePhase.rasterStart,
      );
      final handoffMs = (buildFinishUs > 0 && rasterStartUs > 0)
          ? ((rasterStartUs - buildFinishUs) / 1000).round()
          : -1;

      // ── 重建来源 ───────────────────────────────────────────────────
      //
      // 光看「build 了 50ms」说不出**是谁**触发的这次重建。
      // 这里带上各触发点的**增量**计数，下一份日志就能直接区分：
      //   · 计数在涨 ⇒ provider 通知把整页重跑了（要收窄订阅范围）；
      //   · 计数不动 ⇒ 滚动/动画引起的 build+layout+paint（要降绘制成本）。
      // 两种成因的修法完全相反，必须先分清。
      final now = BuildTriggerCounter.snapshot();
      final prev = _lastCounterSnapshot;
      _lastCounterSnapshot = now;
      final dFm = prev == null ? now[0] : now[0] - prev[0];
      final dMedia = prev == null ? now[1] : now[1] - prev[1];
      final dBrowse = prev == null ? now[2] : now[2] - prev[2];
      final dHome = prev == null ? now[3] : now[3] - prev[3];
      final dGrid = prev == null ? now[4] : now[4] - prev[4];

      // layerCache / pictureCache 是 **GPU 侧**的资源缓存占用（Skia 的
      // resource cache / display list cache），单位 MB。它们不是 Dart 堆，
      // 但**会计入进程的 RSS** ⇒ Android 的 onTrimMemory 看到的就是它们。
      //
      // 这一项是把「掉帧」与「系统持续报低内存」串起来的关键证据：
      // 如果 layerCache 常驻几百 MB，那就同时解释了
      //   ① raster 慢（每帧都在大批量上传 / 回收纹理）；
      //   ② 系统反复回调 didHaveMemoryPressure（而 Dart 侧那三个缓存是空的）。
      WebdavDebugLog.logAlways(
        '[tap] 掉帧 ${total.inMilliseconds}ms '
        '(build ${t.buildDuration.inMilliseconds}ms, '
        'raster ${t.rasterDuration.inMilliseconds}ms, '
        'vsync等待 ${vsyncWaitMs}ms, '
        'UI→光栅 ${handoffMs}ms, '
        'layerCache ${t.layerCacheMegabytes.toStringAsFixed(1)}MB, '
        'pictureCache ${t.pictureCacheMegabytes.toStringAsFixed(1)}MB, '
        'Δ通知 fm=$dFm media=$dMedia, '
        'Δ重建 浏览=$dBrowse 首页=$dHome 网格=$dGrid)',
      );
    }
  }
}

/// 一个正在按下的指针的记录。
class _PointerRecord {
  _PointerRecord({
    required this.osTime,
    required this.fwAtUs,
    required this.position,
    required this.countersAtDown,
    required this.gestureSeq,
    required this.hitTest,
  });

  /// 本次手势的序号（第几次按下），用于把「按下」「抬起」「长按条件」三类
  /// 日志对齐到同一次手势。
  final int gestureSeq;

  /// **按下那一刻的命中测试链**摘要（见 [_describeHitTest]）。
  ///
  /// 用途：判断「手指是不是落在了带长按识别器的控件上」。
  /// 正式包里拿不到控件类型（`debugCreator` 只在 debug 构建赋值），
  /// 只能靠路径里 `RenderPointerListener`/`RenderSemanticsGestureHandler`
  /// 的个数（分类卡=3 / 浏览项=2 / 底栏项=2）来辨认。
  final String hitTest;

  /// 系统记录的事件时刻（down 那一刻）。
  final Duration osTime;

  /// 框架处理到 down 时的单调时刻（微秒）。
  final int fwAtUs;

  /// 按下位置，用于算最大位移。
  final Offset position;

  /// **按下那一刻**的重建/通知计数快照。
  ///
  /// 用于回答「按下→抬起这段窗口里，控件有没有被重建掉」——
  /// 这正是「点击被吞」最常见的成因（Element 被替换 ⇒ 在飞手势被 dispose）。
  final List<int> countersAtDown;

  double _maxMove = 0;

  /// 相对按下点的最大位移。
  double get maxMoveFromStart => _maxMove;

  /// 期间收到的 MOVE 事件数。
  int moveCount = 0;

  void move(Offset p) {
    moveCount++;
    final d = (p - position).distance;
    if (d > _maxMove) _maxMove = d;
  }
}

/// 控件级的一次「按下 → 回调」配对记录。
class _ControlTap {
  _ControlTap({
    required this.pointer,
    required this.slot,
    required this.atUs,
    required this.fired,
  });

  /// 对应的指针 id（与全局指针记录对齐）。
  final int pointer;

  /// 控件自报的槽位下标（仅用于日志定位，不含敏感信息）。
  final int slot;

  /// 收到按下时的单调时刻（微秒）。
  final int atUs;

  /// onTap 回调是否已经到达。
  bool fired;
}

/// 前后台状态观察者：把生命周期变化喂给探针。
///
/// 存在的唯一目的：**把「应用切后台的时长」从「主线程阻塞」里剔除**。
/// 后台期间 Dart 定时器被挂起，回前台时心跳必然迟到一大截 ——
/// 那个量是用户自己把应用切到后台又切回来造成的，不是应用卡住。
/// 少了这个观察者，日志里会出现 `主线程阻塞 13660ms` 这种**误报**。
class _ProbeLifecycleObserver extends WidgetsBindingObserver {
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    TapLatencyProbe.onLifecycle(state);
  }
}
