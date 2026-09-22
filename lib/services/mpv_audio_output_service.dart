import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';

import 'webdav_debug_log.dart';

/// mpv 属性写入（与 `NativePlayer.setProperty` 同签名）。
typedef MpvPropertySetter = Future<void> Function(String key, String value);

/// mpv 属性读取（与 `NativePlayer.getProperty` 同签名）。
typedef MpvPropertyGetter = Future<String> Function(String key);

/// mpv 音频输出（AO）配置 + 诊断。
///
/// ## 为什么需要它
///
/// 用户反馈 RootlessJamesDSP（免 Root 音效软件）判定 ZenFile「不兼容」。
/// 复核时发现三个**互相独立**的可疑点，而旧实现把它们全埋在
/// 「开关一开、`ao=opensles`、剩下的靠体感」里，无法区分：
///
/// 1. **AO 链写法**：mpv 的 `--ao` 是**候选列表**（前一个起不来才试下一个），
///    不是「必须用这个」。旧实现写单值 `opensles` ⇒ 把 audiotrack 从候选里
///    整个删掉。opensles 在该机型上建不起来时 mpv **不会回退**，直接**没声音**，
///    而这与「开关没生效」在体感上无法区分。
/// 2. **音频会话 id 未固定**：`ao_audiotrack` 只暴露两个选项 —— `pcm-float`
///    （默认 1）与 `session-id`，且 `options_prefix = "audiotrack"`，所以 Dart
///    侧属性名是 `audiotrack-session-id`。不设置（默认 0）时 Android 会为每个
///    新建的 AudioTrack **另分配**一个会话号；开播/切歌时按 session 追踪或挂
///    音效的软件就会「丢失目标」—— 与 RJ 弹窗文案「失去对音频路由的控制」
///    「一开播就弹」高度吻合。
/// 3. **实际生效的 AO 无人知晓**：mpv 里 `ao` 是**可读属性**，回读即是真相。
///    播放中回读到的候选若带 `!` 前缀表示「建不起来」，这是决定性证据。
///
/// ## 设计约束
///
/// * 所有原生调用失败一律吞掉并只记日志 —— **绝不能因为诊断让音频播不出来**；
/// * 诊断只在 `WebdavDebugLog.enabled` 打开时才产生（订阅都省掉，零运行时开销）；
/// * [configureBeforeOpen] **必须**在 `player.open()` 之前调用：mpv 只在初始化
///   AO 时读这些选项，播放开始后再设已经晚了一个 AudioTrack。
class MpvAudioOutputService {
  MpvAudioOutputService._();

  /// 与 MainActivity 的 `com.sequl.zenfile/audio_session` 通道对应。
  static const MethodChannel _sessionChannel =
      MethodChannel('com.sequl.zenfile/audio_session');

  /// 开启「OpenSL ES 输出流」开关时使用的 AO 候选链。
  ///
  /// ⚠️ **必须保留第二个候选，绝不退化成单值 `opensles`**：
  /// mpv 的 `--ao` 是**候选列表**（前一个建不起来才试下一个），写单值等于
  /// 把 audiotrack 从候选里整个删掉 —— opensles 在该机型上建不起来时
  /// mpv **不回退、直接静音**，而这与「开关没生效」在体感上完全无法区分，
  /// 正是这个 bug 长期没能定位的原因。
  ///
  /// 顺序遵循开关语义：**opensles 在前**（既然打开这个开关，就该真的走
  /// OpenSL ES，否则开关名不副实、也测不出 opensles 的真实施工情况），
  /// audiotrack 兜底保证任何情况下都出得了声。
  ///
  /// 注：`audiotrack-session-id` 仅对 audiotrack 驱动有效；实际走 opensles
  /// 时该属性被忽略（选项本身已注册，设置不会报错）。**实际用了哪个驱动
  /// 看日志里的 `ACTUAL ao=` 回读值**，不要靠体感。
  static const String aoChainWithOpenSlEs = 'opensles,audiotrack';

  /// 在 `player.open()` **之前**完成 AO 相关配置。
  ///
  /// [tag] 仅用于日志区分调用方（`audio` / `video`）。
  static Future<void> configureBeforeOpen(
    NativePlayer platform, {
    required bool openSlEsEnabled,
    required String tag,
  }) async {
    final sessionId = await _generateAudioSessionId();
    return applyAudioOutputConfig(
      setProperty: platform.setProperty,
      getProperty: platform.getProperty,
      openSlEsEnabled: openSlEsEnabled,
      sessionId: sessionId,
      tag: tag,
    );
  }

  /// [configureBeforeOpen] 的可测内核：原生调用以回调注入，便于单测覆盖
  /// 「开关开/关」「session 有无」「写属性失败」四种分支。
  @visibleForTesting
  static Future<void> applyAudioOutputConfig({
    required MpvPropertySetter setProperty,
    required MpvPropertyGetter getProperty,
    required bool openSlEsEnabled,
    required int? sessionId,
    required String tag,
  }) async {
    // ① AO 候选链：只在开关打开时覆盖 mpv 默认（auto-safe）。
    if (openSlEsEnabled) {
      try {
        await setProperty('ao', aoChainWithOpenSlEs);
      } catch (e) {
        WebdavDebugLog.log('[AO/$tag] set ao failed: $e');
      }
    }

    // ② 固定音频会话：0 与 null 都表示「没有可用会话号」，跳过即可
    //    （设 0 等于让系统另分配，与不设无异）。
    try {
      if (sessionId != null && sessionId != 0) {
        await setProperty('audiotrack-session-id', sessionId.toString());
      }
    } catch (e) {
      WebdavDebugLog.log('[AO/$tag] set session-id failed: $e');
    }

    // ③ 诊断：立刻回读一次。此时 AO 还没建起来，读到的是**配置值**，
    //    用来确认 setProperty 真的写进去了（而不是被 media_kit 吞掉）。
    try {
      final requested = await getProperty('ao');
      WebdavDebugLog.log(
        '[AO/$tag] requested ao="$requested" '
        'opensles=$openSlEsEnabled sessionId=${sessionId ?? "-"}',
      );
    } catch (e) {
      WebdavDebugLog.log('[AO/$tag] read requested ao failed: $e');
    }
  }

  /// 播放真正开始后延迟回读一次 `ao` —— 此时 mpv 已建好音频输出链，
  /// 回读值是**实际生效的驱动**（建不起来的候选带 `!` 前缀）。
  ///
  /// 这是判「opensles 到底有没有生效」的唯一可靠手段（体感无效：
  /// 单值 opensles 建不起来时是没声音，而不是报错）。
  static void scheduleActualAoSample(Player player, String tag) {
    if (!WebdavDebugLog.enabled) return; // 未开日志则完全不订阅
    try {
      if (player.state.playing) {
        _sampleActualAo(player, tag);
        return;
      }
      late StreamSubscription<bool> sub;
      sub = player.stream.playing.listen((playing) {
        if (!playing) return;
        sub.cancel();
        _sampleActualAo(player, tag);
      });
    } catch (_) {
      // 诊断绝不能影响播放
    }
  }

  static void _sampleActualAo(Player player, String tag) {
    Future<void>(() async {
      try {
        // 等 AO 真正建起来（远程流首帧可能较慢），3s 后回读。
        await Future<void>.delayed(const Duration(seconds: 3));
        final platform = player.platform;
        if (platform is NativePlayer) {
          final actual = await platform.getProperty('ao');
          // `audio-format` 是喂给 AudioTrack 的采样格式：`float` 走的是
          // 常规混音路径，而免 Root 音效软件常把「HW-accelerated fast track」
          // 当作不能接管的原因 —— 回读这个值可直接验证该指控是否成立。
          final format = await _tryGetProperty(platform, 'audio-format');
          final device = await _tryGetProperty(platform, 'audio-device');
          WebdavDebugLog.log(
            '[AO/$tag] ACTUAL ao="$actual" audio-format="$format" '
            'audio-device="$device"',
          );
        }
      } catch (e) {
        WebdavDebugLog.log('[AO/$tag] sample actual ao failed: $e');
      }
    });
  }

  /// 单条属性回读失败（老版本 mpv 无此属性等）不应中断整段诊断。
  static Future<String> _tryGetProperty(
    NativePlayer platform,
    String key,
  ) async {
    try {
      return await platform.getProperty(key);
    } catch (_) {
      return '?';
    }
  }

  /// 向系统申请一个音频会话号。
  ///
  /// 返回 null 表示不可用（非 Android / 通道缺失 / 原生异常）——
  /// 调用方应静默跳过 `audiotrack-session-id`，绝不能因此中断播放。
  static Future<int?> _generateAudioSessionId() async {
    if (!Platform.isAndroid) return null;
    try {
      return await _sessionChannel.invokeMethod<int>('generateAudioSessionId');
    } catch (_) {
      // 测试环境无原生实现（MissingPluginException）属预期，静默返回
      return null;
    }
  }
}
