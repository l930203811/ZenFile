import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';

import 'webdav_debug_log.dart';

/// 音频频谱可视化数据源：Android 原生 `Visualizer` 的 FFT 帧管道。
///
/// ## 数据链路
///
/// ```
/// mpv(audiotrack, 固定会话号) → AudioTrack(sessionId)
///     → Visualizer(sessionId).getFft()        [Kotlin, 原生回调 ~20Hz]
///     → EventChannel(audio_visualizer_events) [8bit 幅度数组]
///     → [fft] ValueNotifier                    [本服务]
///     → 波形组件按帧分桶渲染                    [AudioSpectrumEngine]
/// ```
///
/// 会话号来自 [MpvAudioOutputService.sessionIdOf]（`audiotrack-session-id`
/// 固定的会话，Visualizer 挂同一个会话即读到本应用正在播的声音，无需
/// RECORD_AUDIO）。挂不上时回退挂全局输出混音（0 号会话，需 RECORD_AUDIO，
/// 见 Kotlin 侧 start 的双路径决策树）。
///
/// ## 数据链路（波形采集 → Dart 自算 FFT）
///
/// 原生挂 `OnDataCaptureListener` 的**波形采集**（`onWaveFormDataCapture`，
/// 8bit 无符号、128 = 静音中心，格式无任何歧义）；Dart 侧用 [_FftPlan]
/// （512/1024 点 + 汉宁窗，20Hz 一次计算量可忽略）自算真实 FFT 得到幅度
/// 半区。⇒ 之所以不走 `getFft()`：真机实测（vivo V2054A）其回传数据无法
/// 解出正常谱形（官方「前实部/后虚部」解码得到的是平坦噪声状伪谱），格式
/// 存疑；而波形格式天生无歧义，自算 FFT 保证任何机型都能得到正确频谱。
/// audioMotion 依赖浏览器 AnalyserNode 天然给出真 FFT，这一环是我们对
/// 移植环境的补齐。
///
/// [fft] 对外**永远输出幅度格式**（长度 = 波形点数的一半，128 为满量程），
/// 分析参数见 [analysisFftSize] / [analysisSampleRate]（喂给
/// [AudioSpectrumEngine]）。
///
/// ## 自愈
///
/// 两类已知故障都会自动重挂（最多 3 次，出现非零帧立即复位）：
/// * **全零帧**：Visualizer 先于 AudioTrack 挂上时个别 ROM 不自动接续采集；
/// * **帧饿死**：已挂上但原生监听器迟迟不推帧（>3s 无回调）。
///
/// ## 诊断
///
/// 所有关键节点经 [WebdavDebugLog.log] 落盘到
/// `/storage/emulated/0/ZenFile/webdav_debug.log`（前缀 `[viz]`）——本项目的
/// 云电脑环境没有 adb，文件日志是唯一可取的诊断通道。
class AudioVisualizerService {
  AudioVisualizerService._();

  static final AudioVisualizerService instance = AudioVisualizerService._();

  static const MethodChannel _channel =
      MethodChannel('com.sequl.zenfile/audio_visualizer');
  static const EventChannel _events =
      EventChannel('com.sequl.zenfile/audio_visualizer_events');

  /// 最新一帧幅度（8bit，128 满量程；长度 = [analysisFftSize] / 2）。
  final ValueNotifier<Uint8List?> fft = ValueNotifier(null);

  /// 输出流采样率（44100/48000，由原生返回）。
  int sampleRate = 44100;

  /// 原生 captureSize（2 的幂，一般 1024）。
  int fftSize = 1024;

  /// 喂给频谱引擎的有效分析点数（= 原生 fftSize）。
  /// bin 频率 = k * [analysisSampleRate] / [analysisFftSize]。
  int analysisFftSize = 1024;
  int analysisSampleRate = 44100;

  /// Visualizer 是否已成功挂上（播放中为 true）。
  bool get available => _running;
  bool _running = false;
  int _activeSessionId = 0;
  StreamSubscription<dynamic>? _sub;

  /// 频谱回退所需的 RECORD_AUDIO 是否已主动请求过（进程生命周期一次，
  /// 避免反复弹窗打扰）。见 [start] 的权限请求逻辑。
  bool _micRequestAttempted = false;

  // —— 数据解码 ——
  final Map<int, _FftPlan> _fftPlans = {};

  // —— 自愈 / 看门狗状态 ——
  Timer? _watchdog; // 1s 周期检查帧饿死
  DateTime? _lastFrameAt; // 最近一帧到达时间（null = 一帧都没到过）
  bool _starvationLogged = false; // 本轮挂载周期是否已报过饿死（只报一次）
  int _zeroStreak = 0; // 连续全零帧数
  int _framesReceived = 0; // 累计帧数
  int _restartAttempts = 0; // 全零自愈次数（上限 4，含交替目标）
  int _attachTargetId = 0; // 当前实际挂载目标（0 = 输出混音回退）
  int _baseSessionId = 0; // 本次 start 的自会话号（交替恢复的回摆基准）

  // —— 生命周期串行化（2026-10-29 二次修复：重进页面偶发频谱不出）——
  /// 所有挂载/释放/重臂操作**串行排队**执行：旧页面 dispose 的
  /// `unawaited(stop())` 与新页面 initState 的 `start()` 谁先谁后、是否交叉，
  /// 都不再影响结果。这也同时确定了 events 通道上 `cancel → listen` 的顺序
  /// （此前两者分属不同 MethodChannel/EventChannel，**跨通道无顺序保证**：
  /// 旧页面的 cancel 若晚于新页面的 listen 到达原生，会把新订阅的 sink 清空
  /// ⇒ 帧永远推到 null ⇒ 频谱不出，直到切歌重新走一遍挂载——正是用户反馈
  /// 的偶发症状）。
  Future<void> _lifecycleQueue = Future<void>.value();

  /// 帧饿死重臂（重订阅 + 重挂）的节奏与次数：每 2.5s 一次、最多 8 次，
  /// 任何一帧到达即清零。旧实现只自救一次且不重订阅事件流，治标不治本。
  DateTime? _lastHealAt;
  int _healAttempts = 0;
  bool _healGiveUpLogged = false;

  void _log(String msg) => WebdavDebugLog.log('[viz] $msg');

  Future<void> _onFftData(dynamic data) async {
    final Uint8List? raw = data is Uint8List
        ? data
        : (data is List<int> ? Uint8List.fromList(data) : null);
    if (raw == null || raw.length < 16) return;

    // ── 波形（8bit 无符号，128 = 静音中心）→ 自算 FFT → 幅度半区 ──
    final plan = _fftPlans[raw.length] ??= _FftPlan(raw.length);
    final frame = plan.run(raw);
    if (frame == null) return;
    analysisFftSize = raw.length;
    analysisSampleRate = sampleRate;
    fft.value = frame;

    _framesReceived++;
    _lastFrameAt = DateTime.now();
    _starvationLogged = false;
    var maxV = 0;
    for (final b in frame) {
      if (b > maxV) maxV = b;
    }
    // 每 100 帧（≈5s）采样一次数据形态（用于远程定位机型差异）。
    if (_framesReceived % 100 == 0) {
      var minW = 255;
      var maxW = 0;
      var sumW = 0;
      for (final b in raw) {
        if (b < minW) minW = b;
        if (b > maxW) maxW = b;
        sumW += b;
      }
      String at(int k) => k < frame.length ? '${frame[k]}' : '-';
      _log('帧#$_framesReceived 波形[min=$minW max=$maxW avg='
          '${(sumW / raw.length).toStringAsFixed(0)}] '
          'bins=[1:${at(1)} 2:${at(2)} 4:${at(4)} 8:${at(8)} '
          '16:${at(16)} 32:${at(32)} 64:${at(64)} 128:${at(128)}] '
          'max=$maxV');
    }
    if (maxV > 0) {
      if (_zeroStreak > 0) {
        _log('恢复非零数据（frame=$_framesReceived max=$maxV）');
      }
      _zeroStreak = 0;
      _restartAttempts = 0;
      if (_framesReceived == 1) {
        _log('首帧 FFT len=${frame.length} max=$maxV');
      }
    } else {
      _zeroStreak++;
      // 全零 = 会话上没有我们的声音（会话错挂 / 挂早了）。间歇打日志并触发自愈。
      if (_zeroStreak == 1 || _zeroStreak % 40 == 0) {
        _log('全零帧 x$_zeroStreak len=${frame.length}');
      }
      if (_zeroStreak == 40) {
        await _selfHealRestart('全零数据');
      }
    }
  }

  /// 全零数据自愈：数据链路活着（帧在到达）但内容持续全零 —— 常见于目标挂错
  /// 或机型对某类目标只回零帧。策略（最多 4 次，帧恢复正常即清零）：
  ///   #1、#3：原目标重挂（原生 restart）；
  ///   #2、#4：**交替目标**（自会话 ↔ 输出混音 0），完整 stop + 重新挂载
  ///           —— 部分机型即便授予了麦克风权限、输出混音也回零，此时换回
  ///           自会话（或反之）往往能拿到真实数据，无需用户干预。
  Future<void> _selfHealRestart(String reason) async {
    if (!_running || _restartAttempts >= 4) return;
    _restartAttempts++;
    final attempt = _restartAttempts;
    final base = _baseSessionId;
    final cur = _attachTargetId;
    final alt = cur == 0 ? base : 0;
    _log('$reason → 自愈 #$attempt（cur=$cur alt=$alt）');
    if (attempt.isOdd || alt <= 0 || alt == cur) {
      // 奇数次 / 无可交替目标：原样重挂（原生仍持有目标会话号）。
      _lifecycleQueue = _lifecycleQueue.then((_) async {
        try {
          final ok = await _channel.invokeMethod<bool>('restart');
          _log('restart 结果 ok=$ok');
        } catch (e) {
          _log('restart 失败: $e');
        }
      });
    } else {
      _lifecycleQueue = _lifecycleQueue.then((_) async {
        if (!_running) return;
        await _stopNow();
        await _attachTarget(alt);
      });
    }
  }

  /// 帧饿死看门狗：挂上后 >2.5s 没有任何帧回调 ⇒ **持续重臂**——每 2.5s 一次
  /// （重订阅事件流 + 重挂 Visualizer，走 [start] 的饿死重臂路径），最多 8 次；
  /// 任何一帧到达即清零计数。旧实现只自救一次且只重挂原生、不重订阅 Dart 侧
  /// 事件流，治不了「订阅已死」这类饿死（重进页面偶发频谱不出的兜底防线）。
  void _watchdogTick(Timer _) {
    if (!_running) return;
    final last = _lastFrameAt;
    final now = DateTime.now();
    final starved =
        last == null || now.difference(last).inMilliseconds > 2500;
    if (!starved) {
      _healAttempts = 0;
      _healGiveUpLogged = false;
      return;
    }
    if (!_starvationLogged) {
      _starvationLogged = true;
      _log('已挂上但 >2.5s 无帧（lastFrame=$last frames=$_framesReceived）');
    }
    final sinceHeal = _lastHealAt == null
        ? 1 << 30
        : now.difference(_lastHealAt!).inMilliseconds;
    if (sinceHeal < 2500) return;
    if (_healAttempts >= 8) {
      if (!_healGiveUpLogged) {
        _healGiveUpLogged = true;
        _log('重臂 8 次仍无帧，本轮放弃（切歌 / 暂停再播会重新触发挂载）');
      }
      return;
    }
    _healAttempts++;
    _lastHealAt = now;
    final sid = _activeSessionId;
    _log('看门狗重臂 #$_healAttempts sid=$sid');
    _lifecycleQueue = _lifecycleQueue.then((_) async {
      if (!_running) return;
      await _startNow(sid);
    });
  }

  /// 挂上 Visualizer 开始推 FFT（入串行队列）。幂等：已在同一会话上且**帧流
  /// 健康**（2.5s 内有帧）时直接成功；帧流饿死则完整重臂（重订阅 + 重挂）。
  ///
  /// [audioSessionId] <= 0（拿不到固定会话号）直接失败——绝不退到全局输出
  /// 混音（0 号会话需要录音权限，语义完全不同）。失败不抛异常，返回 false。
  ///
  /// ## 麦克风权限（唯一需要的场景）
  ///
  /// 挂**本应用自己的音频会话**不需要任何权限（Android 官方语义：只读自己
  /// 出的声）。仅当个别机型自会话挂载失败（AudioEffect NO_INIT）、需要回退
  /// 挂全局输出混音（session 0）时才需要 RECORD_AUDIO —— 此时主动请求**一次**
  /// 麦克风权限（拒绝则本轮无频谱，不影响任何其他功能，也不再弹窗）。
  Future<bool> start(int audioSessionId) {
    final done = Completer<bool>();
    _lifecycleQueue = _lifecycleQueue.then((_) async {
      try {
        done.complete(await _startNow(audioSessionId));
      } catch (e) {
        _log('start 队列异常: $e');
        if (!done.isCompleted) done.complete(false);
      }
    });
    return done.future;
  }

  /// 挂载的真正执行体（只在串行队列内运行）。
  Future<bool> _startNow(int audioSessionId) async {
    if (!Platform.isAndroid || audioSessionId <= 0) {
      _log('start 跳过：platform=${Platform.operatingSystem} '
          'sid=$audioSessionId');
      return false;
    }
    if (_running && _activeSessionId == audioSessionId) {
      // 已在同一会话上：只有帧流健康才免挂。饿死 ⇒ 完整重臂——这是「重进
      // 页面偶发频谱不出」的另一条根因：旧实现盲目幂等早退，把「_running=true
      // 但事件流/原生监听已死」的僵尸态当成了健康，直到切歌才重新走挂载。
      final last = _lastFrameAt;
      final healthy = last != null &&
          DateTime.now().difference(last).inMilliseconds < 2500;
      if (healthy) return true;
      _log('start 幂等命中但帧流饿死（lastFrame=$last）→ 完整重臂');
      await _stopNow();
    }
    _baseSessionId = audioSessionId;
    return _attachTarget(audioSessionId);
  }

  /// 挂载到指定目标（自会话 sid 或 0 = 输出混音），含一次性麦克风权限回退。
  /// 全零自愈的「交替目标」也走这里，与常规挂载同一条代码路径。
  Future<bool> _attachTarget(int sid) async {
    var r = await _startAttempt(sid);
    if (!r.$1 && r.$2 && !_micRequestAttempted) {
      _micRequestAttempted = true;
      _log('输出混音回退需要 RECORD_AUDIO → 请求麦克风权限');
      try {
        final status = await Permission.microphone.request();
        _log('麦克风权限结果: $status');
        if (status.isGranted) {
          r = await _startAttempt(sid);
        }
      } catch (e) {
        _log('麦克风权限请求异常: $e');
      }
    }
    return r.$1;
  }

  /// 单次挂载尝试。返回 `(ok, needMic)`：needMic = 自会话失败、回退路径
  /// 需要 RECORD_AUDIO 但权限缺失（供 [start] 决定是否请求权限）。
  Future<(bool, bool)> _startAttempt(int audioSessionId) async {
    // ⚠️ 每次挂载都**全新订阅**（先 cancel 旧订阅再 listen）。串行队列保证了
    // events 通道上 cancel → listen 的到达顺序确定；同时治愈「旧订阅已死但
    // _sub 非空」的僵尸态（旧 `??=` 只在为空时订阅，死订阅永远不被替换）。
    try {
      await _sub?.cancel();
      _sub = _events.receiveBroadcastStream().listen(
        _onFftData,
        onError: (Object e) {
          _log('事件流错误: $e');
          // cancelOnError 会摘掉订阅，置空让下次 start 重新订阅。
          _sub = null;
        },
        cancelOnError: true,
      );
      final raw = await _channel
          .invokeMethod<Map<dynamic, dynamic>>('start', {
        'audioSessionId': audioSessionId,
      });
      if (raw == null) {
        _log('start 返回空（sid=$audioSessionId）');
        return (false, false);
      }
      // 旧原生（无 attached 键）视为成功；新原生失败时回传**完整决策树**：
      // ownFailed（自己会话挂载失败）/ micGranted（有无 RECORD_AUDIO）/
      // mixFailed（输出混音回退也失败）/ lastError / device——一锤定音是
      // 「缺权限」还是「机型缺 Visualizer 引擎」。
      final attached = raw['attached'] as bool? ?? true;
      if (!attached) {
        final ownFailed = raw['ownFailed'] as bool? ?? false;
        final micGranted = raw['micGranted'] as bool? ?? false;
        _log('挂载失败 ownFailed=$ownFailed '
            'micGranted=$micGranted mixFailed=${raw['mixFailed']} '
            'lastError=${raw['lastError']} device=${raw['device']}');
        // 需要权限但没授权 → 让 start 决定是否请求（needMic）。
        return (false, ownFailed && !micGranted);
      }
      sampleRate = (raw['sampleRate'] as num?)?.toInt() ?? 44100;
      // 防御：旧版原生曾把毫赫兹单位（getSamplingRate() 的返回）原样透传
      // （44100000），分桶会把 30Hz~16kHz 全挤进 bin1 → 所有柱子同跳。
      if (sampleRate > 1000000) sampleRate ~/= 1000;
      fftSize = (raw['captureSize'] as num?)?.toInt() ?? 1024;
      final usedOutputMix = raw['outputMix'] as bool? ?? false;
      _activeSessionId = audioSessionId;
      _attachTargetId = usedOutputMix ? 0 : audioSessionId;
      _running = true;
      _zeroStreak = 0;
      _framesReceived = 0;
      _restartAttempts = 0;
      _healAttempts = 0;
      _healGiveUpLogged = false;
      _lastHealAt = null;
      _lastFrameAt = null;
      _starvationLogged = false;
      _watchdog ??= Timer.periodic(const Duration(seconds: 1), _watchdogTick);
      _log('start ok sid=$audioSessionId fftSize=$fftSize '
          'sampleRate=$sampleRate outputMix=$usedOutputMix '
          'device=${raw['device']}');
      return (true, false);
    } catch (e) {
      // MissingPluginException（旧包没这个通道）/ Visualizer 创建失败等，
      // 一律静默回落伪波形（细节落盘便于定位）。
      _log('start FAILED sid=$audioSessionId: $e');
      _running = false;
      _activeSessionId = 0;
      return (false, false);
    }
  }

  /// 释放 Visualizer 并清空数据（组件立即收起频谱区）。幂等，入串行队列。
  Future<void> stop() {
    _lifecycleQueue = _lifecycleQueue.then((_) => _stopNow());
    return _lifecycleQueue;
  }

  /// 释放的真正执行体（只在串行队列内运行）。
  Future<void> _stopNow() async {
    _watchdog?.cancel();
    _watchdog = null;
    // 与下一次 start 的重新订阅同处一个队列 ⇒ events 通道上必然
    // 「先 cancel 后 listen」，旧页面的释放不可能清掉新页面的 sink。
    _sub?.cancel();
    _sub = null;
    _running = false;
    _activeSessionId = 0;
    _attachTargetId = 0;
    _zeroStreak = 0;
    _framesReceived = 0;
    _restartAttempts = 0;
    _healAttempts = 0;
    _healGiveUpLogged = false;
    _lastHealAt = null;
    _lastFrameAt = null;
    fft.value = null;
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod<void>('stop');
    } catch (_) {
      // 页面销毁竞态下引擎可能已不回应，忽略。
    }
  }
}


/// 波形 → 频谱的定点 FFT 计划（按点数缓存，迭代式 radix-2 Cooley-Tukey）。
///
/// 输入：8bit 无符号波形采样（128 为中心）。输出：幅度半区（8bit，128 满
/// 量程量级——满幅正弦（±128）经汉宁窗后主 bin |X| ≈ n/4，归一到 128，
/// 与引擎「128 = 0dB 满量程」的窗口锚定一致）。
class _FftPlan {
  _FftPlan(this.n)
      : rev = Uint16List(n),
        cosT = Float64List(n ~/ 2),
        sinT = Float64List(n ~/ 2),
        hann = Float64List(n),
        re = Float64List(n),
        im = Float64List(n) {
    var bits = 0;
    while ((1 << bits) < n) {
      bits++;
    }
    for (var i = 0; i < n; i++) {
      var x = i;
      var r = 0;
      for (var b = 0; b < bits; b++) {
        r = (r << 1) | (x & 1);
        x >>= 1;
      }
      rev[i] = r;
      // 汉宁窗：抑制频谱泄漏（矩形窗的旁瓣会把能量糊满全谱）。
      hann[i] = 0.5 * (1 - math.cos(2 * math.pi * i / (n - 1)));
    }
    for (var t = 0; t < n ~/ 2; t++) {
      cosT[t] = math.cos(2 * math.pi * t / n);
      sinT[t] = math.sin(2 * math.pi * t / n);
    }
  }

  final int n;
  final Uint16List rev;
  final Float64List cosT;
  final Float64List sinT;
  final Float64List hann;
  final Float64List re;
  final Float64List im;

  Uint8List? run(Uint8List raw) {
    if (raw.length < n) return null;
    for (var i = 0; i < n; i++) {
      re[i] = ((raw[i] - 128) / 128) * hann[i];
      im[i] = 0;
    }
    // 位反转置换
    for (var i = 0; i < n; i++) {
      final j = rev[i];
      if (j > i) {
        var t = re[i];
        re[i] = re[j];
        re[j] = t;
        t = im[i];
        im[i] = im[j];
        im[j] = t;
      }
    }
    // 蝶形
    for (var len = 2; len <= n; len <<= 1) {
      final half = len >> 1;
      final step = n ~/ len;
      for (var i = 0; i < n; i += len) {
        for (var j = 0; j < half; j++) {
          final t = j * step;
          final c = cosT[t];
          final s = sinT[t];
          final ar = re[i + j];
          final ai = im[i + j];
          final br = re[i + j + half];
          final bi = im[i + j + half];
          final tre = br * c + bi * s;
          final tim = bi * c - br * s;
          re[i + j] = ar + tre;
          im[i + j] = ai + tim;
          re[i + j + half] = ar - tre;
          im[i + j + half] = ai - tim;
        }
      }
    }
    final half = n ~/ 2;
    final out = Uint8List(half);
    out[0] = 0; // 直流分量恒弃
    // 满幅正弦（±1）经汉宁窗后主 bin |X| ≈ n/4 → 归一到 128 量级。
    for (var k = 1; k < half; k++) {
      final m =
          math.sqrt(re[k] * re[k] + im[k] * im[k]) / (n / 4) * 128;
      out[k] = m.clamp(0.0, 255.0).round();
    }
    return out;
  }
}
