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

/// mpv 音频输出（AO）兼容模式。
///
/// ## 背景（2026-09 复核 RootlessJamesDSP 判「不兼容」时逐条查实）
///
/// 旧实现只有一个布尔开关，语义是「启用 OpenSL ES 输出流」，前提假设是
/// **mpv 默认走 AudioTrack、开开关才切 OpenSL ES**。该前提是**错的**：
///
/// * media_kit（`NativePlayer` 初始化，real.dart）在 Android **真机**上默认
///   就把 `ao` 写成**单值** `opensles`：
///   `if (isPhysicalDevice || APILevel > 25) 'ao': 'opensles'`。
///   ⇒ 旧开关**开与不开，实际生效的 AO 完全相同**，只是开启后多了一个
///   `audiotrack` 兜底候选。开关名不副实，也解释不了 RJ 的行为。
/// * RJ（rootless）的判定机制（源码 `RootlessSessionDatabase.createSession`）：
///   它为 `dumpsys media.audio_flinger` 里发现的每个 session 挂一个**静音
///   AudioEffect**（`DynamicsProcessing`，失败退到隐藏的 `Volume` 效果），
///   **挂不上就调 `onAppProblemDetected(uid)` → 弹「不兼容」+ `stopSelf()`**，
///   正是用户截图那一幕。RJ 官方文档把这一类失败归因为
///   「HW-accelerated audio playback (**fast tracks**)」。
/// * 两条链路在 mpv 源码里的差异：
///   - `ao_audiotrack`：**不**请求低延迟（无 `PERFORMANCE_MODE_LOW_LATENCY`、
///     无 `FLAG_LOW_LATENCY`），缓冲固定 `getMinBufferSize*2` 再 clamp 到
///     75~150ms，AudioAttributes = `USAGE_MEDIA`(+`CONTENT_TYPE_MUSIC/MOVIE`)
///     ⇒ 普通混音轨道，**理论上可挂音效**（RJ 能接管）；
///   - `ao_opensles`：交给 libOpenSLES 自建 AudioTrack，是否落 fast 由系统
///     决定 —— 这正是 RJ 举「某些 Unity 游戏」为例的那一类。
///
/// ⇒ 真正**从没被验证过**的组合是「把 `audiotrack` 放到链路**最前面**」：
/// media_kit 默认是 opensles 单值，我们此前也只是把 opensles 放在前面。
/// 见 [MpvAoMode.audioTrack]。
///
/// ## 设计约束
///
/// * 所有原生调用失败一律吞掉并只记日志 —— **绝不能因为诊断让音频播不出来**；
/// * 诊断只在 [WebdavDebugLog.enabled] 打开时才产生（订阅都省掉，零运行时开销）；
/// * [configureBeforeOpen] **必须**在 `player.open()` 之前调用：mpv 只在初始化
///   AO 时读这些选项，播放开始后再设已经晚了一个 AudioTrack。
enum MpvAoMode {
  /// 不覆盖 `ao`：完全沿用 media_kit 默认（Android 真机 = 单值 `opensles`）。
  auto('auto'),

  /// `audiotrack` 优先（普通轨道、USAGE_MEDIA、可挂音效），opensles 兜底。
  audioTrack('audiotrack'),

  /// 同 [audioTrack]，但把送进 AudioTrack 的采样格式从 float32 换成 16-bit PCM
  /// （`audiotrack-pcm-float=no`）—— 用于排除个别设备 float 输出异常的情况。
  ///
  /// ⚠️ **实现方式必须是独立属性**，绝不能写成 `--ao=audiotrack:pcm-float=no`：
  /// mpv 自 **0.23.0** 起移除了 `--vo/--ao` 的「驱动:子选项」语法
  /// （`options/m_option.c` `m_obj_parse_sub_config()` 原话：
  /// *"Sub-options for --vo and --ao were removed from mpv in release 0.23.0."*，
  /// 命中即 `return M_OPT_INVALID`）—— 所以那种写法会让**整条 `ao` 被拒绝**，
  /// 而 media_kit 会**静默吞掉**这次写失败（不抛异常）。
  /// 真机症状：档位存下了、日志也打了，但 `requested-ao` 回读到的还是旧值，
  /// 完全没生效（2026-09-23 日志 `mode=audiotrack16 requested-ao="opensles"`
  /// 正是此症；见 [extraOptions] 与 [applyAudioOutputConfig] 的写后回读校验）。
  ///
  /// 注：经核对 `ao_audiotrack.c`，其缓冲窗口按 `bps * channels` 换算后 clamp 到
  /// 75~150ms，16-bit 与 float32 **帧数一致**，故本档位与 [audioTrack] 在
  /// 「是否为低延迟/fast 轨道」上没有差别，只影响送进 AudioTrack 的位深。
  audioTrack16('audiotrack16'),

  /// `opensles` 优先，audiotrack 兜底（= 旧「OpenSL ES 输出流」开关的语义）。
  openSlEs('opensles');

  const MpvAoMode(this.key);

  /// 持久化用的稳定键（**不要改**，改了会丢用户设置）。
  final String key;

  /// 面向用户的技术标签。`OpenSL ES` / `AudioTrack` 是产品/技术名，
  /// 各语言均不译，因此这一行**刻意不进 l10n**。
  String get label => switch (this) {
        MpvAoMode.auto => 'Auto',
        MpvAoMode.audioTrack => 'AudioTrack',
        MpvAoMode.audioTrack16 => 'AudioTrack 16-bit',
        MpvAoMode.openSlEs => 'OpenSL ES',
      };

  /// 写入 mpv 的 `ao` 候选链；`null` 表示**不覆盖**（沿用 media_kit 默认）。
  ///
  /// ⚠️ 每条链都**必须**保留第二个候选：`--ao` 是候选列表（前一个建不起来才
  /// 试下一个），写单值等于把另一个从候选里整个删掉 —— 建不起来时 mpv
  /// **不回退、直接静音**，而「静音」与「开关没生效」在体感上无法区分，
  /// 正是这个 bug 长期定位不到的原因。
  String? get aoChain => switch (this) {
        MpvAoMode.auto => null,
        MpvAoMode.audioTrack => 'audiotrack,opensles',
        // ⚠️ 这里**只放驱动名**：`--ao=驱动:子选项=值` 语法自 mpv 0.23.0 起已移除，
        // 带 `:` 会让整条 ao 被拒（静默失败）。子选项走 [extraOptions]。
        MpvAoMode.audioTrack16 => 'audiotrack,opensles',
        MpvAoMode.openSlEs => 'opensles,audiotrack',
      };

  /// 档位需要的**附加 AO 选项**，以 mpv 全局选项 `<prefix>-<option>` 形式写入
  /// （`ao_audiotrack` 的 `options_prefix = "audiotrack"`）。
  ///
  /// 为什么不能用 `--ao=audiotrack:pcm-float=no`：见 [audioTrack16] 的注释。
  /// 这些键同样要经 `setProperty` + **写后回读**校验，否则「写了但没生效」
  /// 会毫无痕迹（media_kit 吞异常的坑）。
  ///
  /// ⚠️ `audiotrack` 档位**显式写 `yes`**（= mpv 默认值）而不是「不写」：mpv 的
  /// 选项在**同一实例内是残留的**，从 [audioTrack16] 切回 [audioTrack] 若什么都不写，
  /// 位深会静默留在 16-bit（「切了档位行为却不变」正是本项目反复踩的坑）。
  /// [auto]/[openSlEs] 不写：前者要求完全沿用 media_kit 默认，后者走 opensles
  /// 驱动、该选项对它无效。
  List<MapEntry<String, String>> get extraOptions => switch (this) {
        MpvAoMode.audioTrack => const [
            MapEntry<String, String>('audiotrack-pcm-float', 'yes'),
          ],
        MpvAoMode.audioTrack16 => const [
            MapEntry<String, String>('audiotrack-pcm-float', 'no'),
          ],
        _ => const <MapEntry<String, String>>[],
      };

  /// **热切换**（播放中改档位）用的链 —— 见 [MpvAoMode] 与
  /// `MpvAudioOutputService.applyToRunningPlayer`。
  ///
  /// 与 [aoChain] 的唯一差别在 `auto`：`open` 之前"不写"即可实现 auto 语义，
  /// 但运行中一旦覆盖过 `ao` 就**无法"取消覆盖"**，只能显式写回 media_kit 在
  /// Android 真机上的默认值（`opensles` 单值），否则从别的档位切回 `Auto`
  /// 会静默留在旧驱动上。
  ///
  /// ⚠️ **刻意例外**：`auto` 的 [hotChain] 是**单值**，与本类「禁止写单值」
  /// 的规则（[aoChain] 的注释）相反 —— 因为 auto 的定义就是"完全按 media_kit
  /// 默认"，而 media_kit 真机默认恰恰是单值 `opensles`；给它加候选就不再是
  /// auto 了。风险没有新增：真正 auto（我们从不碰 `ao`）在 opensles 建不起来
  /// 时同样静音，行为一致。
  String get hotChain => aoChain ?? 'opensles';

  /// 该模式是否要求固定音频会话号（只有 `audiotrack` 驱动认这个选项）。
  bool get usesSessionId => this != MpvAoMode.auto;

  static MpvAoMode fromKey(String? key) =>
      values.firstWhere((m) => m.key == key, orElse: () => MpvAoMode.auto);
}

/// mpv 音频输出（AO）配置 + 诊断。
class MpvAudioOutputService {
  MpvAudioOutputService._();

  /// 与 MainActivity 的 `com.sequl.zenfile/audio_session` 通道对应。
  static const MethodChannel _sessionChannel =
      MethodChannel('com.sequl.zenfile/audio_session');

  /// 最近一次为某个 [Player] 固定下来的音频会话号。
  ///
  /// 起播后的自检要用**同一个**会话号去复刻 RJ 的「挂静音音效」动作，
  /// 否则测的不是 RJ 会看到的那条轨道。`Expando` 不持有强引用，
  /// Player 被释放后条目自动失效。
  static final Expando<int> _sessionIdOf = Expando<int>('zenfile.aoSessionId');

  /// 已经挂过 mpv 日志转储的 [Player]（同一实例只挂一次，避免重复刷盘）。
  static final Expando<bool> _logAttached = Expando<bool>('zenfile.mpvLogAttached');

  /// 已经完成过一轮采样的 [Player]（`playing` 事件与定时兜底可能都会触发，
  /// 用它去重，保证同一实例只写一组数据）。
  static final Expando<bool> _diagnosed = Expando<bool>('zenfile.aoDiagnosed');

  /// APK 指纹（`versionName @ lastUpdateTime`）的缓存。首次取值走一次原生通道，
  /// 之后复用 —— 这样每条播放日志都能带上它，代价接近零。
  static String? _apkStamp;

  /// 已经挂上「音频效果控制会话广播器」的 [Player]（同一实例只挂一次）。
  static final Expando<bool> _fxNotifier = Expando<bool>('zenfile.fxSessionNotifier');

  /// 上一次**广播出去**的播放状态。`playing` 事件会重复发射，而 OPEN/CLOSE
  /// 只应在状态**翻转**时各发一次，否则效果类应用会被反复重建会话。
  static final Expando<bool> _fxAnnounced = Expando<bool>('zenfile.fxSessionAnnounced');

  /// 在 `player.open()` **之前**完成 AO 相关配置。
  ///
  /// [tag] 仅用于日志区分调用方（`audio` / `video` / `video-switch`）。
  /// 返回固定下来的会话号（未固定时为 null），供 [schedulePlaybackDiagnostics]
  /// 复用；调用方无需自己保存。
  static Future<int?> configureBeforeOpen(
    Player player, {
    required MpvAoMode mode,
    required String tag,
  }) async {
    final platform = player.platform;
    if (platform is! NativePlayer) return null;

    // 只有 audiotrack 驱动认这个选项；其他模式无需向系统要会话号。
    final sessionId = mode.usesSessionId ? await _generateAudioSessionId() : null;

    await applyAudioOutputConfig(
      setProperty: platform.setProperty,
      getProperty: platform.getProperty,
      mode: mode,
      sessionId: sessionId,
      tag: tag,
    );

    if (sessionId != null) _sessionIdOf[player] = sessionId;
    // 音频效果控制会话广播（Android 官方协议）——起播时挂上监听。这不是诊断，
    // 是**功能**：没有它，系统均衡器与免 Root 音效软件都不知道我们的会话。
    attachEffectSessionNotifier(player, isVideo: tag.startsWith('video'), tag: tag);
    return sessionId;
  }

  /// 对**已经建好音频输出**的播放器热应用档位。
  ///
  /// mpv 的 `ao` 是**运行时可写**属性：写入会重建音频输出（可能有极短静音）。
  ///
  /// 为什么必须存在这个入口：档位此前**只在 `open` 之前生效**
  /// （[configureBeforeOpen]），于是「播放中切档位」永远没有任何效果 ——
  /// 而 AO 是**输出路径、不是音质**，用户唯一能观察到的差异只有「声音有没有
  /// 变化」，体感上完全等同「这个功能坏了」。真机反馈原文（2026-09-23）：
  /// 「切换了 4 个模式没有任何效果」。
  ///
  /// 另一个必须调用它的场景：**复用已有播放器**时（音频播放器的
  /// `existingPlayer` / 后台 player 两条分支）不会新建 Player，因此也不会走
  /// [configureBeforeOpen] —— 那两条路径此前同样完全没有应用档位。
  static Future<void> applyToRunningPlayer(
    Player player, {
    required MpvAoMode mode,
    required String tag,
  }) async {
    final platform = player.platform;
    if (platform is! NativePlayer) return;

    final before = await _tryGetProperty(platform, 'current-ao');
    final sessionId = mode.usesSessionId ? await _generateAudioSessionId() : null;

    await applyAudioOutputConfig(
      setProperty: platform.setProperty,
      getProperty: platform.getProperty,
      mode: mode,
      sessionId: sessionId,
      tag: tag,
      hot: true,
    );

    if (sessionId != null) _sessionIdOf[player] = sessionId;
    attachEffectSessionNotifier(player, isVideo: tag.startsWith('video'), tag: tag);
    _reannounceIfPlaying(player, isVideo: tag.startsWith('video'), tag: tag);
    _verifyHotSwitch(platform, tag: tag, mode: mode, before: before);
  }

  /// 热切换后回读 `current-ao` —— 判断「档位到底有没有生效」的**唯一客观依据**
  /// （耳朵听不出来，见 [applyToRunningPlayer] 的注释）。
  static void _verifyHotSwitch(
    NativePlayer platform, {
    required String tag,
    required MpvAoMode mode,
    required String before,
  }) {
    Future<void>.delayed(const Duration(milliseconds: 900), () async {
      try {
        final after = await _tryGetProperty(platform, 'current-ao');
        final same = before == after;
        WebdavDebugLog.log(
          '[AO/$tag] hot-switch mode=${mode.key} chain="${mode.hotChain}" '
          'current-ao: "$before" -> "$after"${same ? '（未变化：该档位与当前驱动等价，或 mpv 忽略了热切换）' : ''}',
        );
      } catch (_) {
        // 诊断绝不能影响播放
      }
    });
  }

  /// [configureBeforeOpen] 的可测内核：原生调用以回调注入，便于单测覆盖
  /// 「各模式链」「session 有无」「写属性失败」等分支。
  @visibleForTesting
  static Future<void> applyAudioOutputConfig({
    required MpvPropertySetter setProperty,
    required MpvPropertyGetter getProperty,
    required MpvAoMode mode,
    required int? sessionId,
    required String tag,
    bool hot = false,
  }) async {
    WebdavDebugLog.log(
      '[AO/$tag] mode=${mode.key} 意图：ao="${(hot ? mode.hotChain : mode.aoChain) ?? "(不覆盖)"}" '
      'sessionId=${sessionId ?? "-"}',
    );

    // ① AO 候选链：`auto` 模式在 open 前刻意不覆盖（= media_kit 默认）；
    //    热切换（`hot`）时必须显式写回，原因见 [MpvAoMode.hotChain]。
    final chain = hot ? mode.hotChain : mode.aoChain;
    if (chain != null) {
      await setAndVerify(
        setProperty: setProperty,
        getProperty: getProperty,
        key: 'ao',
        value: chain,
        tag: tag,
      );
    }

    // ② 固定音频会话：0 与 null 都表示「没有可用会话号」，跳过即可
    //    （设 0 等于让系统另分配，与不设无异）。
    if (sessionId != null && sessionId != 0) {
      await setAndVerify(
        setProperty: setProperty,
        getProperty: getProperty,
        key: 'audiotrack-session-id',
        value: sessionId.toString(),
        tag: tag,
      );
    }

    // ③ 档位附加选项（如 16-bit PCM）。同样必须回读校验，见 [setAndVerify]。
    for (final option in mode.extraOptions) {
      await setAndVerify(
        setProperty: setProperty,
        getProperty: getProperty,
        key: option.key,
        value: option.value,
        tag: tag,
      );
    }
  }

  /// 写一个 mpv 选项，**并回读校验**——本项目排查 AO 问题时最重要的一条纪律。
  ///
  /// 为什么不能只写不查：**media_kit 会静默吞掉 mpv 的写失败**。mpv 拒绝非法值时
  /// 只返回错误码（例如 `--ao=驱动:子选项=值` 自 mpv 0.23.0 起非法 → 返回
  /// `M_OPT_INVALID`），media_kit 不抛异常，于是「写了、但一个字都没生效」在
  /// 应用侧毫无痕迹。真机症状就是 2026-09-23 那轮：档位存了、日志打了
  /// （`mode=audiotrack16 requested-ao="opensles"`），实际 AO 完全没变。
  ///
  /// 返回是否确认生效（无法回读时返回 false 并明确标注「无法判定」）。
  @visibleForTesting
  static Future<bool> setAndVerify({
    required MpvPropertySetter setProperty,
    required MpvPropertyGetter getProperty,
    required String key,
    required String value,
    required String tag,
  }) async {
    try {
      await setProperty(key, value);
    } catch (e) {
      WebdavDebugLog.log('[AO/$tag] set $key="$value" 抛异常：$e');
      return false;
    }
    try {
      final got = await getProperty(key);
      if (got == '?') {
        WebdavDebugLog.log(
          '[AO/$tag] set $key="$value" 已写入，但**回读不到**该选项'
          '（选项不存在 / 本构建未编入 → 该设置无效）',
        );
        return false;
      }
      final ok = got.contains(value);
      final verdict = ok
          ? '✅生效'
          : '❌未生效（mpv 拒绝了这个值 —— 语法非法/选项不存在；'
              '注意 media_kit 不会报错，只静默丢弃）';
      WebdavDebugLog.log('[AO/$tag] set $key="$value" 回读="$got" $verdict');
      return ok;
    } catch (e) {
      WebdavDebugLog.log('[AO/$tag] set $key="$value" 已写入，回读失败：$e（无法判定）');
      return false;
    }
  }

  /// 起播后采集一次音频输出诊断（仅在 [WebdavDebugLog.enabled] 打开时工作）。
  ///
  /// 采集三样东西，缺一不可：
  /// 1. `current-ao` —— mpv **运行时实际解析出的驱动**（`ao` 只是候选列表的
  ///    回显，读它等于自欺欺人，上一版就栽在这里）；
  /// 2. mpv 自己的日志行（`[cplayer] AO: [xxx]`、`[ao] ... failed ...`）——
  ///    AO 建不起来时唯一的原因来源；
  /// 3. **原生复刻自检**：用同一个会话号去挂 `DynamicsProcessing`（RJ 的判定
  ///    动作），直接给出「RJ 会不会判我们不兼容」的预测。
  static void schedulePlaybackDiagnostics(Player player, String tag) {
    if (!WebdavDebugLog.enabled) return; // 未开日志则完全不订阅
    _attachMpvLog(player, tag);

    // ⚠️ 无条件哨兵：证明这段代码**确实被执行到了**。
    // 上一轮真机测试的日志里连一行 AO 都没有，当时无法区分「调用点根本没走到」
    // 与「走到了但事件没触发」→ 白跑一轮构建。有这一行就能一眼分开。
    WebdavDebugLog.log('[AO/$tag] diagnostics armed (playing=${player.state.playing})');
    // 再补一行**包指纹**。理由：`[boot]` 只在进程启动时写一次，而实测日志里
    // 常常见不到它（用户为取干净日志会先删掉日志文件，删掉后新文件就从半路
    // 开始记）。此时「手机上跑的到底是哪个包」又变成一笔糊涂账，只能再花一次
    // 构建去确认。把指纹挂在每次播放上，半路开始的日志也能自证。
    unawaited(_logApkStamp(tag));

    // ① 事件触发（起播瞬间采样最准）。
    try {
      if (player.state.playing) {
        _runDiagnostics(player, tag);
        return;
      }
      late StreamSubscription<bool> sub;
      sub = player.stream.playing.listen((playing) {
        if (!playing) return;
        sub.cancel();
        _runDiagnostics(player, tag);
      });
    } catch (_) {
      // 诊断绝不能影响播放
    }

    // ② 定时兜底：`playing` 事件不一定会到（复用已有 player 时它可能早已为 true
    //    且不再重复发射、远程流起播慢、用户没真的播……），8s 后无条件采一次。
    //    没有这一层，「日志里什么都没有」就永远是个无法收敛的疑问。
    Future<void>.delayed(const Duration(seconds: 8), () => _runDiagnostics(player, tag));
  }

  /// 把 mpv 自身的日志（AO 相关）转存到落盘日志。
  ///
  /// 这是判断「候选链里到底谁建起来了、为什么没建起来」的唯一直接证据：
  /// mpv 会打出 `AO: [<driver>] ...`，失败时则打出 `Failed to initialize
  /// audio driver '<name>'` 之类，而 `getProperty('ao')` 只会回显候选列表。
  static void _attachMpvLog(Player player, String tag) {
    if (_logAttached[player] == true) return;
    _logAttached[player] = true;
    try {
      player.stream.log.listen((e) {
        try {
          final text = e.text;
          final lower = text.toLowerCase();
          final prefix = e.prefix.toLowerCase();
          final keep = lower.contains('opensles') ||
              lower.contains('audiotrack') ||
              text.contains('AO:') ||
              (lower.contains('audio') &&
                  (prefix == 'ao' ||
                      prefix.startsWith('ao/') ||
                      prefix.startsWith('cplayer')));
          if (!keep) return;
          WebdavDebugLog.log('[mpv/$tag][${e.prefix}] ${e.text}');
        } catch (_) {
          // 单行日志失败不影响播放
        }
      });
    } catch (_) {
      // 诊断绝不能影响播放
    }
  }

  /// 往日志里补一行 APK 指纹（版本号 @ 安装时间），供**半路开始**的日志自证
  /// 「手机上跑的到底是哪个包」。指纹只在首次取值时走一次原生通道并缓存。
  static Future<void> _logApkStamp(String tag) async {
    try {
      _apkStamp ??= await buildStamp();
      WebdavDebugLog.log('[AO/$tag] apk=${_apkStamp}');
    } catch (_) {
      // 诊断绝不能影响播放
    }
  }

  /// 挂上「音频效果控制会话」广播器：起播 → OPEN，停止 → CLOSE。
  ///
  /// ## 为什么必须有它（2026-09-23 追到 RootlessJamesDSP 源码级后的结论）
  ///
  /// Android 的音频效果控制协议要求**播放器自己**广播
  /// `AudioEffect.ACTION_OPEN_AUDIO_EFFECT_CONTROL_SESSION`（带会话号 + 包名 +
  /// 内容类型），效果类应用（系统均衡器、免 Root 音效软件）才知道「这个应用的
  /// 音频在哪个会话上」，从而按会话挂效果。
  ///
  /// 本应用此前**从未**广播过 —— 这正是「同一台机器上 RJ 能处理 Poweramp、
  /// 却点名 ZenFile 不受支持」的**协议级差异**：RJ 的 `SessionReceiver` 在清单里
  /// 注册的就是这两个 action，而 VLC / YouTube Music / Poweramp 全都实现了它。
  ///
  /// 只对**固定了会话号**的档位有意义：会话号来自 `audiotrack-session-id`，
  /// 由 mpv 的 `ao_audiotrack` 使用。走 `opensles`（含 `auto` 档位）时会话号由
  /// 系统分配，我们无从得知，也就无从宣告。
  ///
  /// ⚠️ 全程不抛异常：广播失败**绝不能**影响播放。
  static void attachEffectSessionNotifier(
    Player player, {
    required bool isVideo,
    required String tag,
  }) {
    if (_fxNotifier[player] == true) return;
    _fxNotifier[player] = true;
    try {
      player.stream.playing.listen((playing) {
        final last = _fxAnnounced[player];
        if (last == playing) return; // 只认状态翻转
        // 从未宣告过 OPEN 就不必发 CLOSE（避免给一个没人知道的会话发关闭）。
        if (!playing && last != true) return;
        _fxAnnounced[player] = playing;
        unawaited(_announceEffectSession(
          player,
          open: playing,
          isVideo: isVideo,
          tag: tag,
        ));
      });
    } catch (_) {
      // 广播失败绝不影响播放
    }
  }

  /// 会话号变化后**补一次宣告**。
  ///
  /// 为什么必须补：播放中切档位会重新取一个会话号，而 `playing` **不会**因为换
  /// 会话号而重复发射（它一直是 true）⇒ 光靠 [attachEffectSessionNotifier] 的
  /// 监听，效果软件会永远停在**旧会话**上，表现为「切了档位音效就没了」。
  static void _reannounceIfPlaying(
    Player player, {
    required bool isVideo,
    required String tag,
  }) {
    try {
      if (!player.state.playing) return;
      _fxAnnounced[player] = true;
      unawaited(_announceEffectSession(
        player,
        open: true,
        isVideo: isVideo,
        tag: tag,
      ));
    } catch (_) {
      // 广播失败绝不影响播放
    }
  }

  /// 真正的广播动作（OPEN 前先确认 mpv 确实把 AudioTrack 建在我们固定的会话号上）。
  static Future<void> _announceEffectSession(
    Player player, {
    required bool open,
    required bool isVideo,
    required String tag,
  }) async {
    try {
      final sid = _sessionIdOf[player];
      if (sid == null || sid == 0) return; // 会话号由系统分配 → 无从宣告
      final platform = player.platform;
      if (platform is! NativePlayer) return;
      if (open) {
        // ⚠️ 只有 `current-ao` 真的落在 audiotrack 时，这个会话号才是**有音频流过
        // 的那个**。否则等于让效果应用去挂一个空会话 —— 那种「挂上了却没有声音
        // 流过」的状态，在 RJ 那边会被判成「失去路由控制」，反而触发弹窗。
        //
        // `playing` 事件可能早于 AO 初始化（远程流首帧更慢），所以给几次机会：
        // 否则会静默丢掉这一次宣告，而这正是整条链路的起点。
        var ao = await _tryGetProperty(platform, 'current-ao');
        for (var attempt = 0;
            attempt < 3 && !ao.toLowerCase().contains('audiotrack');
            attempt++) {
          await Future<void>.delayed(const Duration(seconds: 1));
          ao = await _tryGetProperty(platform, 'current-ao');
        }
        if (!shouldAnnounceOpen(sessionId: sid, currentAo: ao)) {
          WebdavDebugLog.log(
            '[FX/$tag] skip OPEN：current-ao="$ao"（固定会话号未被 mpv 采用；'
            '要让音效类应用接管需选「AudioTrack」档位）',
          );
          return;
        }
      }
      final r = await _notifyEffectSessionNative(
        sessionId: sid,
        open: open,
        isVideo: isVideo,
      );
      WebdavDebugLog.log(
        '[FX/$tag] ${open ? "OPEN" : "CLOSE"} session=$sid -> $r',
      );
    } catch (_) {
      // 广播失败绝不影响播放
    }
  }

  /// [attachEffectSessionNotifier] 的判定核心：现在该不该向系统宣告
  /// 「本应用正在这个会话上出声」。
  ///
  /// 抽成**纯函数**以便回归测试（真机行为无法自动化）。钉住的不变式：
  /// 「有会话号」且「该会话号真的被 mpv 用上」（`current-ao` 落在 audiotrack）
  /// 两个条件**同时**满足才宣告 —— 缺一个就会让效果应用挂到一个空会话上，
  /// 而那种状态在 RootlessJamesDSP 那边会被判成「失去路由控制」并弹窗。
  @visibleForTesting
  static bool shouldAnnounceOpen({
    required int? sessionId,
    required String? currentAo,
  }) {
    if (sessionId == null || sessionId == 0) return false;
    return (currentAo ?? '').toLowerCase().contains('audiotrack');
  }

  static Future<String> _notifyEffectSessionNative({
    required int sessionId,
    required bool open,
    required bool isVideo,
  }) async {
    if (!Platform.isAndroid) return 'skip:not-android';
    try {
      final r = await _sessionChannel.invokeMethod<String>(
        'notifyEffectSession',
        <String, dynamic>{
          'sessionId': sessionId,
          'open': open,
          // AudioEffect.CONTENT_TYPE_MUSIC = 2 / CONTENT_TYPE_MOVIE = 4
          'contentType': isVideo ? 4 : 2,
        },
      );
      return r ?? 'null';
    } catch (e) {
      return 'error:$e';
    }
  }

  static void _runDiagnostics(Player player, String tag) {
    if (_diagnosed[player] == true) return; // 事件与定时兜底二选一，只采一组
    _diagnosed[player] = true;
    Future<void>(() async {
      try {
        // 等 AO 真正建起来（远程流首帧可能较慢），3s 后回读。
        await Future<void>.delayed(const Duration(seconds: 3));
        final platform = player.platform;
        if (platform is! NativePlayer) return;

        final current = await _tryGetProperty(platform, 'current-ao');
        final requested = await _tryGetProperty(platform, 'ao');
        // `audio-params` = 解码后送进 AO 的参数，`audio-out-params` = 真正
        // 送到设备的参数（采样率/声道/格式）—— fast 路径对三者都有要求。
        final params = await _tryGetProperty(platform, 'audio-params');
        final outParams = await _tryGetProperty(platform, 'audio-out-params');
        WebdavDebugLog.log(
          '[AO/$tag] ACTUAL current-ao="$current" requested-ao="$requested"',
        );
        WebdavDebugLog.log(
          '[AO/$tag] params=$params | out-params=$outParams',
        );

        final sid = _sessionIdOf[player];
        if (sid == null || sid == 0) {
          WebdavDebugLog.log('[AO/$tag] effect-attach probe: skipped（本模式未固定会话号）');
        } else {
          final verdict = await _probeEffectAttach(sid);
          // ⚠️⚠️ 语义边界（**不要**再像 v2 那样把它当成「RJ 会不会判我们不兼容」
          // 的预测）：这个探针是**本应用 uid 给自己创建的 session** 挂效果 ——
          // Android 对 session 属主永远放行，所以它必然 ok，与 RJ 的处境是两件事。
          // RJ 是**从它自己的 uid 往别人的 session** 挂 → 需要
          // MODIFY_AUDIO_ROUTING 级别权限（Shizuku/root 那条路），本探针测不到。
          // 它真正能证明的只有两件事：
          //   ① 该 session id 真实存在于音频系统且接受 effect（⇒ 不是 offload/DIRECT）；
          //   ② 结合 current-ao=audiotrack，可确认「固定会话号」这条链真的走通了。
          WebdavDebugLog.log(
            '[AO/$tag] effect-attach probe sid=$sid -> $verdict'
            '（⚠️本 uid 对自己 session 必然 ok，**不能**预测 RJ 跨 uid 能否挂上）',
          );
        }
        final device = await _describeAudioOutput();
        WebdavDebugLog.log('[AO/$tag] device=$device');
      } catch (e) {
        WebdavDebugLog.log('[AO/$tag] diagnostics failed: $e');
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

  /// 复刻 RJ 的「挂静音音效」动作，返回可读结论。
  ///
  /// ⚠️ **不要**把它当成「RJ 会不会判我们不兼容」的预测（v2 的诊断文案曾这样写，
  /// 是错的）：这里用的是**本应用 uid、对自己创建的 session**，属主必然放行。
  /// 它的价值只有两条：
  /// 1. 证明该 session 真实有效 —— offload/DIRECT 输出**完全不接受 effect**，
  ///    能挂上就说明我们不是那条路径；
  /// 2. 证明 `audiotrack-session-id` 固定下来的会话号真的被 mpv 用上了。
  /// 原生侧只创建 + 立即释放（不 enable、不改增益），**绝不会静音播放**。
  static Future<String> _probeEffectAttach(int sessionId) async {
    if (!Platform.isAndroid) return 'skip:not-android';
    try {
      final r = await _sessionChannel.invokeMethod<String>(
        'probeEffectAttach',
        <String, dynamic>{'sessionId': sessionId},
      );
      return r ?? 'null';
    } catch (e) {
      return 'error:$e';
    }
  }

  /// 设备侧音频输出画像（fast mixer 帧数/原生采样率 + 活跃播放配置）。
  static Future<String> _describeAudioOutput() async {
    if (!Platform.isAndroid) return 'skip:not-android';
    try {
      final r = await _sessionChannel.invokeMethod<String>('describeAudioOutput');
      return r ?? 'null';
    } catch (e) {
      return 'error:$e';
    }
  }

  /// 安装包指纹：`<versionName>@<lastUpdateTime>`（由原生侧提供）。
  ///
  /// 用途：在**无 adb** 的真机排查里证明「手机上跑的到底是哪个包」。
  /// 版本号在两版诊断包之间通常不变（都不发版），**必须带 lastUpdateTime**
  /// 否则无法区分「装了旧包」与「代码路径没走到」——2026-09-23 已因此白跑一轮。
  static Future<String> buildStamp() async {
    if (!Platform.isAndroid) return 'not-android';
    try {
      // ⚠️ 必须带超时：这个方法在 `main()` 里被 `await`（`[boot]` 哨兵），
      // 而它走的是 MethodChannel —— 原生侧一旦不回应（引擎未就绪、主线程被
      // 播放器初始化占住……），`runApp()` 之前的这个 await 就会**把启动卡死**。
      // 诊断绝不能有这种能力。
      final r = await _sessionChannel
          .invokeMethod<String>('buildStamp')
          .timeout(const Duration(seconds: 3));
      return r ?? '?';
    } catch (e) {
      return 'error:$e';
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
