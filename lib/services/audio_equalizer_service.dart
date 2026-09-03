import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';

/// 均衡器预设。
enum EqPreset {
  flat,
  vocal, // HD 人声
  bass, // 低音
  live, // 现场
  jazz, // 爵士
}

extension EqPresetExtension on EqPreset {
  /// 本地化标签（需要传入 L10n 实例）。
  String labelL10n(dynamic l10n) {
    switch (this) {
      case EqPreset.flat:
        return l10n.eq_preset_flat;
      case EqPreset.vocal:
        return l10n.eq_preset_vocal;
      case EqPreset.bass:
        return l10n.eq_preset_bass;
      case EqPreset.live:
        return l10n.eq_preset_live;
      case EqPreset.jazz:
        return l10n.eq_preset_jazz;
    }
  }

  String get key {
    switch (this) {
      case EqPreset.flat:
        return 'flat';
      case EqPreset.vocal:
        return 'vocal';
      case EqPreset.bass:
        return 'bass';
      case EqPreset.live:
        return 'live';
      case EqPreset.jazz:
        return 'jazz';
    }
  }

  static EqPreset fromKey(String key) {
    return EqPreset.values.firstWhere(
      (p) => p.key == key,
      orElse: () => EqPreset.flat,
    );
  }

  /// 10 段均衡器增益值（dB，浮点数）。
  /// mpv 默认频段：31.25, 62.5, 125, 250, 500, 1000, 2000, 4000, 8000, 16000 Hz
  /// 增益范围：-12.0 ~ +12.0 dB
  List<double> get bandGainsDb {
    switch (this) {
      case EqPreset.flat:
        return [0, 0, 0, 0, 0, 0, 0, 0, 0, 0];
      case EqPreset.vocal: // HD 人声：提升中频 1-4kHz
        return [-2.0, -1.0, 0, 0, 0, 2.0, 5.0, 8.0, 5.0, 3.0];
      case EqPreset.bass: // 低音：提升低频段（明显可辨，配合峰值压缩防削波）
        return [5.0, 7.0, 5.0, 2.0, 0, 0, 0, -1.0, -2.0, -2.0];
      case EqPreset.live: // 现场：平坦 + 轻微高频提升
        return [1.0, 0, 0, 0, 0, 0, 1.0, 2.0, 3.0, 3.0];
      case EqPreset.jazz: // 爵士：V 型曲线
        return [4.0, 2.0, 0, -1.0, -2.0, -2.0, 0, 3.0, 5.0, 6.0];
    }
  }
}

/// 音频均衡器服务：使用 mpv lavfi 包装的 libavfilter equalizer 滤波器。
///
/// mpv 本身没有内置 equalizer 滤波器，需要通过 lavfi 包装器调用 libavfilter 的 equalizer。
/// 格式：lavfi=[equalizer=f=<freq>:g=<gain>,equalizer=f=<freq>:g=<gain>,...]
/// 低音预设末尾追加 acompressor 做峰值压缩（防削波，不改变响度）；其余预设保持纯净链路以保留听感差异。
/// gain 单位为 dB（浮点数），例如 5.0 = 5 dB，范围 -12.0 ~ +12.0 dB
class AudioEqualizerService {
  /// 当前关联的 mpv 原生播放器
  NativePlayer? _nativePlayer;

  /// 当前预设
  EqPreset _currentPreset = EqPreset.flat;
  EqPreset get currentPreset => _currentPreset;

  /// 是否已启用均衡器
  bool _isEnabled = false;
  bool get isEnabled => _isEnabled;

  /// 初始化均衡器（需要 NativePlayer 引用）。
  Future<void> attach(NativePlayer player) async {
    _nativePlayer = player;
    _isEnabled = true;
    // 应用当前预设（恢复上次使用的）
    await applyPreset(_currentPreset);
  }

  /// 释放均衡器（清除滤波器）。
  Future<void> detach() async {
    _isEnabled = false;
    try {
      await _nativePlayer?.setProperty('af', '');
    } catch (_) {}
    _nativePlayer = null;
  }

  /// 应用预设。
  Future<bool> applyPreset(EqPreset preset) async {
    _currentPreset = preset;
    if (!_isEnabled || _nativePlayer == null) return false;
    // 仅低音预设需要峰值压缩保护（大幅抬升低频易削波），其余预设保持纯净链路以保留响度差异
    final needCompression = preset == EqPreset.bass;
    return _applyGains(preset.bandGainsDb, enablePeakCompression: needCompression);
  }

  /// 设置自定义频段增益。
  /// [gainsDb] 各频段增益值（dB），对应 mpv 默认 10 频段。
  Future<bool> setCustomGains(List<double> gainsDb) async {
    if (!_isEnabled || _nativePlayer == null) return false;
    return _applyGains(gainsDb);
  }

  /// 构建 lavfi equalizer 滤波器字符串并应用。
  /// 格式：lavfi=[equalizer=f=freq1:g=gain1,equalizer=f=freq2:g=gain2,...]
  /// 每个频段是独立的 equalizer 滤波器实例，用逗号串联成 filter chain。
  /// gain 单位为 dB（浮点数），例如 5.0 = 5 dB，范围 -12.0 ~ +12.0 dB
  ///
  /// [enablePeakCompression]：为 true 时在链路末尾追加 acompressor 峰值压缩，
  /// 仅压低超过阈值的尖峰（防削波破音），**不做整段增益补偿**，因此不会改变各预设间的响度差异听感。
  Future<bool> _applyGains(List<double> gainsDb, {bool enablePeakCompression = false}) async {
    try {
      final player = _nativePlayer;
      if (player == null) return false;

      // 全部增益为 0 时直接清空 af，回到原声（避免无意义的滤波链路）
      final allZero = gainsDb.take(10).every((g) => g == 0);
      if (allZero) {
        debugPrint('[EQ] 全部增益为 0，清空 af（原声）');
        await player.setProperty('af', '');
        return true;
      }

      // mpv 默认 10 段均衡器频率（Hz）
      const frequencies = [31.25, 62.5, 125.0, 250.0, 500.0, 1000.0, 2000.0, 4000.0, 8000.0, 16000.0];

      // 每个频段构建为独立的 equalizer 滤波器实例：
      // equalizer=f=freq:g=gain
      // 多个实例用逗号串联（filter chain），不能用重复 f=/g= 参数（会被覆盖）。
      final filters = <String>[];
      for (var i = 0; i < 10 && i < gainsDb.length; i++) {
        // 限制范围：-12.0 ~ +12.0 dB，防止啸叫
        final gain = gainsDb[i].clamp(-12.0, 12.0);
        // 保留两位小数，避免浮点字符串过长
        final gainStr = gain.toStringAsFixed(1);
        filters.add('equalizer=f=${frequencies[i]}:g=$gainStr');
      }

      // 可选：峰值压缩（仅低音预设）。acompressor 仅在信号超过 threshold(-3dB) 时启动，
      // 压低尖峰防止削波破音；不开启 level/ makeup gain，故不改变整体响度，保留预设间差异。
      if (enablePeakCompression) {
        filters.add('acompressor=threshold=-3dB:ratio=4:attack=5:release=50:knee=2');
      }

      final filterString = 'lavfi=[${filters.join(',')}]';
      debugPrint('[EQ] 应用滤波器: $filterString');
      await player.setProperty('af', filterString);

      // 验证滤波器是否真被 mpv 接受：部分 Android 的 libmpv 缺少 libavfilter，
      // 设置 lavfi 后会被静音（af 实际为空或未生效）。若读回的 af 不含 equalizer，
      // 说明设备不支持该滤波链，清空 af 以恢复原始音频，避免“无声”问题。
      try {
        final result = await player.getProperty('af');
        debugPrint('[EQ] 当前 af 属性: $result');
        final afStr = result.toString();
        if (!afStr.contains('equalizer')) {
          debugPrint('[EQ] 设备不支持该音频滤波器，清空 af 以恢复声音');
          await player.setProperty('af', '');
          return false;
        }
      } catch (verifyErr) {
        debugPrint('[EQ] 读取 af 失败，清空 af 以恢复声音: $verifyErr');
        try {
          await player.setProperty('af', '');
        } catch (_) {}
        return false;
      }

      return true;
    } catch (e) {
      debugPrint('[EQ] 应用均衡器失败: $e');
      return false;
    }
  }

  /// 清除均衡器效果。
  Future<void> reset() async {
    _currentPreset = EqPreset.flat;
    if (!_isEnabled || _nativePlayer == null) return;
    try {
      // 设置所有频段增益为 0
      await _applyGains([0, 0, 0, 0, 0, 0, 0, 0, 0, 0]);
    } catch (_) {}
  }

  /// 打开系统均衡器（Android 原生）。
  /// 当 mpv lavfi 均衡器不可用时，可以回退到系统均衡器。
  static Future<void> openSystemEqualizer() async {
    // 系统均衡器需要通过平台通道打开
    // 这里只是一个占位符，实际实现需要在 AudioService.java 中添加
    debugPrint('[EQ] 打开系统均衡器');
  }

  /// 检查均衡器是否可用。
  /// 注意：mpv lavfi 均衡器需要 libavfilter 支持，某些设备可能不可用。
  static Future<bool> isAvailable() async {
    // 默认返回 true，实际可用性取决于设备上的 mpv 构建
    return true;
  }

  /// 初始化均衡器（静态方法，用于兼容旧代码）。
  @Deprecated('Use attach() instead')
  static Future<bool> initialize(int sessionId) async {
    return true;
  }

  /// 释放均衡器资源（静态方法，用于兼容旧代码）。
  @Deprecated('Use detach() instead')
  static void release() {
    // 空实现，实际释放由 detach() 处理
  }
}
