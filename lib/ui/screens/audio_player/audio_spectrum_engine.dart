import 'dart:math' as math;
import 'dart:typed_data';

/// audioMotion-analyzer 风格的频谱分桶 + 平滑引擎。
///
/// 数据源：Android `Visualizer.getFft()`（前 fftSize/2 字节为 8bit 幅度，
/// 128 为满量程）。对齐 audioMotion（src/audioMotion-analyzer.js）的核心行为：
///
/// * **对数频率刻度分桶**：等宽柱对应指数增长的频段（30Hz~16kHz），每柱取
///   桶内最大 bin（audioMotion bar 模式的 peak 采样）；
/// * **固定 dB 显示窗口**：与 audioMotion 的 minDecibels/maxDecibels 一致地
///   用固定窗口映射柱高（不做自适应响度窗、不做高频抬升），保留原版
///   「低频高、高频自然衰减」的真实频谱轮廓。窗口 [-42, 0]，128 满量程
///   锚定——8bit 数据可用动态范围就 42dB，窗口上沿必须压在满量程 0dB，
///   否则满格线低于音乐典型幅度、所有柱子钉死在顶上不掉；
/// * **帧间指数平滑**：模拟 audioMotion 依赖的 AnalyserNode
///   smoothing=0.5（原版不做事后 attack/release，柱子跟随的是被平滑过的
///   FFT）；原生 FFT 回调仅 ~20Hz，时间常数平滑让 30fps 渲染保持连续；
/// * **峰值帽**：到顶先停留一拍（peakHoldTime，原版默认 500ms）再重力下落
///   （gravity），帽的颜色由渲染层从共享渐变中取（与柱体同色）。
///
/// 渲染节拍由波形组件的 AnimationController 驱动（dt 内部计时）。
class AudioSpectrumEngine {
  AudioSpectrumEngine({this.barCount = 56})
      : display = List.filled(barCount, 0),
        peaks = List.filled(barCount, 0),
        _peakVel = List.filled(barCount, 0),
        _peakHold = List.filled(barCount, 0),
        _raw = List.filled(barCount, 0);

  /// 柱数（与波形组件的 _barCount 一致）。
  final int barCount;

  /// 对数刻度频率范围（audioMotion 默认量级）。
  static const double minFreq = 30;
  static const double maxFreq = 16000;

  /// 固定 dB 显示窗口：db = 20·log10(幅度/128)，**128 = 0dB 满量程锚定**。
  ///
  /// 8bit 数据的可用动态范围上限就是 42dB（原始值 1 → -42dB，再低全被
  /// 量化噪声淹没），所以窗口取满量程 [-42, 0]：播放音乐时典型幅度
  /// （原始值 20~180）落在 0.35~1.0 的柱高区间，低/中/高频差与响度变化
  /// 都可见，安静段自然落回低位；静音归 0。**切勿把窗口抬到 -8 之类**
  /// ——满格线会低于音乐典型幅度，所有柱子长期钉死在顶上不掉。
  static const double minDb = -42;
  static const double maxDb = 0;

  /// 峰值帽到顶后的停留时间（对齐 audioMotion peakHoldTime 默认 500ms）。
  static const double _peakHoldSeconds = 0.5;

  /// 峰值帽重力加速度（归一化高度/秒²），停留结束后加速下落。
  static const double _peakGravity = 4.0;

  /// 柱体跟随的指数平滑时间常数（秒）。对应 audioMotion 的 AnalyserNode
  /// smoothing=0.5：FFT 数据 ~20Hz 一跳，不做时间平滑柱子会肉眼可见地抽动。
  static const double _tauSeconds = 0.08;

  /// 各柱当前显示高度（0..1）。
  final List<double> display;

  /// 各柱峰值帽高度（0..1）。
  final List<double> peaks;

  final List<double> _peakVel;
  final List<double> _peakHold;
  final List<int> _raw;

  List<int> _binLo = const [];
  List<int> _binHi = const [];
  int _binsForSize = 0;
  int _binsForRate = 0;

  DateTime? _lastFrame;
  DateTime? _lastNonZero;

  /// 自会话开始以来连续全零帧的时长。
  Duration _silentSinceStart = Duration.zero;

  /// 数据是否可信：从没见过非零帧且已连续全零超过 3 秒 → 判定会话号错挂
  /// （如 mpv 回退到了 opensles，Visualizer 挂的会话没有声音），调用方应
  /// 回落伪波形。**一旦见过非零帧就永远可信**——音乐本身的静音段不该把
  /// 频谱切回伪波形。
  bool get dataAlive => _lastNonZero != null || _silentSinceStart < const Duration(seconds: 3);

  /// 每柱的 bin 区间 [lo, hi)（幅度数组下标）。频率→bin：`f * fftSize / sampleRate`。
  ///
  /// 低频段一柱可能覆盖不到一个 bin（相邻柱共享/复制 bin），高频段一柱覆盖
  /// 多个 bin（取最大）。区间保证单调不减，且落在 [1, fftSize/2) 内
  /// （bin 0 是直流分量，跳过）。
  void _rebuildBins(int fftSize, int sampleRate) {
    if (_binsForSize == fftSize && _binsForRate == sampleRate) return;
    _binsForSize = fftSize;
    _binsForRate = sampleRate;
    final lo = List<int>.filled(barCount, 1);
    final hi = List<int>.filled(barCount, 2);
    final half = fftSize ~/ 2;
    final binHz = sampleRate / fftSize;
    var prevHi = 1;
    for (var i = 0; i < barCount; i++) {
      final fLo =
          minFreq * math.pow(maxFreq / minFreq, i / barCount).toDouble();
      final fHi = minFreq *
          math.pow(maxFreq / minFreq, (i + 1) / barCount)
              .toDouble();
      var bLo = (fLo / binHz).floor().clamp(1, half - 2);
      var bHi = (fHi / binHz).ceil().clamp(bLo + 1, half - 1);
      // 保证单调（低频段复制同一 bin，视觉上是连片的低频柱）。
      bLo = math.min(bLo, prevHi);
      bHi = math.max(bHi, bLo + 1);
      lo[i] = bLo;
      hi[i] = bHi;
      prevHi = bHi;
    }
    _binLo = lo;
    _binHi = hi;
  }

  /// 用最新一帧 FFT 推进一步，返回各柱归一化高度（0..1，峰值帽另见 [peaks]）。
  List<double> update(Uint8List mag, int fftSize, int sampleRate) {
    final now = DateTime.now();
    final prev = _lastFrame;
    _lastFrame = now;
    final dtSeconds = prev == null
        ? 1 / 60
        : (now.difference(prev).inMicroseconds / 1e6)
            .clamp(1 / 240, 0.1)
            .toDouble();

    _rebuildBins(fftSize, sampleRate);
    final half = fftSize ~/ 2;
    final n = math.min(mag.length, half);

    // ── 第一遍：各柱桶内峰值（8bit 幅度）──────────────────────────
    var anyNonZero = false;
    for (var i = 0; i < barCount; i++) {
      var m = 0;
      final bLo = math.min(_binLo[i], n - 2);
      final bHi = math.min(math.max(_binHi[i], bLo + 1), n - 1);
      for (var k = bLo; k < bHi; k++) {
        if (mag[k] > m) m = mag[k];
      }
      _raw[i] = m;
      if (m > 0) anyNonZero = true;
    }

    // ── 第二遍：固定 dB 窗口归一化 + 指数平滑 + 峰值帽 ─────────────
    final span = maxDb - minDb;
    final smoothK = 1 - math.exp(-dtSeconds / _tauSeconds);
    for (var i = 0; i < barCount; i++) {
      final linear = _raw[i] / 128.0;
      final db = 20.0 * (math.log(math.max(linear, 1e-5)) / math.ln10);
      final norm = ((db - minDb) / span).clamp(0.0, 1.0);

      // 帧间指数平滑（模拟 AnalyserNode smoothing）：上下沿同等跟随。
      display[i] += (norm - display[i]) * smoothK;

      // 峰值帽：到顶即重置，先停留一拍再重力加速下落（落在柱高之上）。
      if (display[i] >= peaks[i]) {
        peaks[i] = display[i];
        _peakVel[i] = 0;
        _peakHold[i] = _peakHoldSeconds;
      } else if (_peakHold[i] > 0) {
        _peakHold[i] -= dtSeconds;
      } else {
        _peakVel[i] += _peakGravity * dtSeconds;
        peaks[i] = math.max(display[i], peaks[i] - _peakVel[i] * dtSeconds);
      }
    }

    if (anyNonZero) {
      _lastNonZero = now;
      _silentSinceStart = Duration.zero;
    } else if (_lastNonZero == null) {
      _silentSinceStart += Duration(
          microseconds: (dtSeconds * 1e6).round());
    }
    return display;
  }
}
