import 'package:flutter_test/flutter_test.dart';
import 'package:zenfile/services/mpv_audio_output_service.dart';

/// 回归测试：mpv 音频输出（AO）配置与兼容档位。
///
/// 背景（用户反馈 RootlessJamesDSP 判定 ZenFile「不兼容」，2026-09 复核）：
/// * media_kit 在 Android **真机**上默认就把 `ao` 写成**单值** `opensles`
///   （`real.dart`: `if (isPhysicalDevice || APILevel > 25) 'ao': 'opensles'`），
///   所以「OpenSL ES 开关」开/关时实际 AO 完全一样 —— 那个开关是空操作。
/// * mpv 的 `--ao` 是**候选列表**，单值等于把另一个驱动整个删掉；建不起来时
///   **不回退、直接静音**，与「开关没生效」在体感上无法区分，这是本 bug
///   长期定位不到的直接原因。故「至少两个候选」必须钉死在测试里。
/// * **`--ao=驱动:子选项=值` 语法自 mpv 0.23.0 起被移除**（`m_option.c`：
///   *"Sub-options for --vo and --ao were removed from mpv in release 0.23.0."*），
///   带 `:` 会让**整条 ao 被拒**；而 media_kit **静默吞掉**这次失败。
///   真机症状：档位存了、日志也打了（`requested-ao` 回读还是旧值），实际没生效。
///   ⇒ 故「ao 链里不得出现 `:`」+「必须写后回读」两条一起钉死。
/// * `audiotrack-session-id` / `audiotrack-pcm-float` 是 `ao_audiotrack` 的
///   `options_prefix = "audiotrack"` 全局选项（不是 ao 子选项）。
///
/// **2026-09-23 真机逐档位实测**（本文件的档位集合即由此收敛而来）：
/// * `audiotrack` 优先 → `current-ao="audiotrack"`，会话号被采用，广播 OPEN 后
///   音效软件正常工作、音效可听；
/// * `opensles` 优先 → `current-ao="opensles"`，会话号被 mpv 丢弃（`ao_opensles`
///   不认识该选项）⇒ 无从广播 ⇒ 仍然弹「不兼容」。
/// ⇒ 默认档位（`auto`）必须落在 audiotrack 上，且**任何档位都不允许「不写 ao」**。
///
/// 这些不变式一旦被改回去，肉眼看代码很难发现（就是一个字符串），故钉在测试里。
void main() {
  /// 模拟 mpv 的选项表：写进去什么，回读就是什么。
  late Map<String, String> written;

  /// 模拟「mpv 是否认识这个选项」——不在集合里则回读 '?'（现实中是抛异常）。
  late Set<String> mpvKnownKeys;

  Future<void> apply({
    required MpvAoMode mode,
    int? sessionId,
  }) {
    return MpvAudioOutputService.applyAudioOutputConfig(
      setProperty: (key, value) async => written[key] = value,
      getProperty: (key) async =>
          mpvKnownKeys.contains(key) ? (written[key] ?? '') : '?',
      mode: mode,
      sessionId: sessionId,
      tag: 'test',
    );
  }

  Future<bool> setVerify({
    required String key,
    required String value,
    bool known = true,
  }) {
    return MpvAudioOutputService.setAndVerify(
      setProperty: (k, v) async => written[k] = v,
      getProperty: (k) async {
        if (!known) return '?';
        return written[k] ?? '';
      },
      key: key,
      value: value,
      tag: 'test',
    );
  }

  setUp(() {
    written = <String, String>{};
    mpvKnownKeys = <String>{
      'ao',
      'audiotrack-session-id',
      'audiotrack-pcm-float',
    };
  });

  group('AO 候选链', () {
    test('auto（默认档位）：audiotrack 排在首位、opensles 兜底', () async {
      await apply(mode: MpvAoMode.auto);
      final chain = written['ao'];
      expect(
        chain,
        isNotNull,
        reason: 'auto 必须**显式写** ao：不写就等于沿用 media_kit 真机默认的'
            '单值 opensles —— 真机实测该组合下音效软件必弹「不兼容」，'
            '且单值链建不起来时不回退（静音），是「默认档位不好用」的根因',
      );
      final parts = chain!.split(',');
      expect(
        parts.first.startsWith('audiotrack'),
        isTrue,
        reason: '本档位的全部意义就是让 audiotrack 真的生效 —— '
            '其源码不请求低延迟、75~150ms 普通缓冲、USAGE_MEDIA，'
            '是唯一有依据（且已真机验证）能被免 Root 音效软件接管的链路',
      );
      expect(parts, contains('opensles'), reason: '必须留兜底，防「建不起来就静音」');
    });

    test('每个档位都必须是「候选列表」，不能退化成单值', () {
      for (final mode in MpvAoMode.values) {
        final chain = mode.aoChain;
        expect(
          chain.contains(','),
          isTrue,
          reason: '${mode.key}: mpv 的 --ao 是候选列表；单值失败时不回退，直接静音',
        );
        expect(chain.split(',').length, greaterThanOrEqualTo(2));
      }
    });

    test('ao 链里**绝不能**出现 ":"（mpv 0.23 起移除子选项，带它整条 ao 被拒）', () {
      for (final mode in MpvAoMode.values) {
        final chain = mode.aoChain;
        expect(
          chain.contains(':'),
          isFalse,
          reason: '${mode.key}: "$chain" —— `--ao=驱动:子选项=值` 自 mpv 0.23.0 起'
              '非法（M_OPT_INVALID），且 media_kit 会静默吞掉这个失败：'
              '档位看起来存了、日志也打了，实际一个字节都没生效（2026-09-23 真机日志 实证）',
        );
      }
    });

    test('audiotrack 16-bit 档位：链只放驱动名，位深走**独立**全局选项', () async {
      await apply(mode: MpvAoMode.audioTrack16);
      expect(
        written['ao'],
        'audiotrack,opensles',
        reason: '带 `:` 的子选项写法会被 mpv 整条拒绝（静默），只能写纯驱动链',
      );
      expect(
        written['audiotrack-pcm-float'],
        'no',
        reason: 'ao_audiotrack 的 options_prefix = "audiotrack"，'
            '故位深选项名是 audiotrack-pcm-float（全局选项，独立写）',
      );
    });

    test('位深选项必须显式声明，不留「上次档位的残留」', () async {
      // mpv 的选项在同一实例内是残留的：从 16-bit 切回 auto 时若什么都不写，
      // 位深会静默停在 16-bit —— 又是「切了档位但行为不变」。
      for (final mode in MpvAoMode.values) {
        written.clear();
        await apply(mode: mode, sessionId: 7);
        final pcm = written['audiotrack-pcm-float'];
        switch (mode) {
          case MpvAoMode.auto:
            expect(pcm, 'yes', reason: '显式写回 mpv 默认值，清掉可能残留的 16-bit');
          case MpvAoMode.audioTrack16:
            expect(pcm, 'no');
          case MpvAoMode.openSlEs:
            expect(
              pcm,
              isNull,
              reason: '${mode.key}: 该档位走 opensles 驱动，'
                  'audiotrack-pcm-float 只对 ao_audiotrack 有意义，写了是噪音',
            );
        }
      }
    });

    test('opensles 档位：opensles 在首位且 audiotrack 兜底（**仅作兜底**）', () async {
      await apply(mode: MpvAoMode.openSlEs);
      final parts = written['ao']!.split(',');
      expect(parts.first, 'opensles',
          reason: '本档位的存在意义只剩「个别设备 audiotrack 建不起来时反过来试」；'
              '真机实测它**无法**被音效软件接管（会话号由系统分配、无从广播），'
              '所以绝不能把它做成默认或推荐档位');
      expect(parts, contains('audiotrack'));
    });

    test('档位键稳定且可往返（改 key 会丢用户设置）', () {
      for (final mode in MpvAoMode.values) {
        expect(MpvAoMode.fromKey(mode.key), mode);
        expect(mode.key, isNotEmpty);
        expect(mode.label, isNotEmpty);
      }
      expect(MpvAoMode.fromKey('不存在的键'), MpvAoMode.auto);
      expect(MpvAoMode.fromKey(null), MpvAoMode.auto);
    });

    test('历史键 audiotrack（已并入 auto）仍可解析，老用户设置不跳变', () {
      expect(
        MpvAoMode.fromKey('audiotrack'),
        MpvAoMode.auto,
        reason: 'v2.1.5 的独立 `audiotrack` 档位与 auto 行为完全相同（链 + 会话号'
            '+ 会话广播），合并后旧键必须落到 auto 而不是丢弃/报错',
      );
    });

    test('所有档位都要固定音频会话号（候选链里都有 audiotrack 兜底）', () {
      for (final mode in MpvAoMode.values) {
        expect(
          mode.usesSessionId,
          isTrue,
          reason: '${mode.key}: 会话号是「宣告本应用在哪个会话上出声」的唯一凭据；'
              '即使 opensles 排在首位，一旦回退到 audiotrack 也仍然用得上它',
        );
      }
    });
  });

  group('写后回读校验（media_kit 会静默吞掉 mpv 的写失败）', () {
    test('回读一致 → true', () async {
      expect(await setVerify(key: 'ao', value: 'audiotrack,opensles'), isTrue);
      expect(written['ao'], 'audiotrack,opensles');
    });

    test('mpv 拒绝该值（回读仍是旧值）→ false', () async {
      // 模拟真实故障：mpv 对合法属性收到非法值 → 返回 M_OPT_INVALID，
      // 选项**保持旧值**；media_kit 不抛异常（所以只能靠回读发现）。
      final ok = await MpvAudioOutputService.setAndVerify(
        setProperty: (k, v) async {}, // 写入被 mpv 丢弃
        getProperty: (k) async => 'opensles', // 回读还是旧值
        key: 'ao',
        value: 'audiotrack,opensles',
        tag: 'test',
      );
      expect(ok, isFalse, reason: '回读不等于写入值时，必须判定为「未生效」');
    });

    test('选项在本构建不存在（回读 "?"）→ false，且不抛异常', () async {
      expect(
        await setVerify(key: 'audiotrack-session-id', value: '123', known: false),
        isFalse,
      );
    });

    test('setProperty 本身抛异常 → false，且不抛出去', () async {
      final ok = await MpvAudioOutputService.setAndVerify(
        setProperty: (k, v) async => throw StateError('boom'),
        getProperty: (k) async => '',
        key: 'ao',
        value: 'audiotrack,opensles',
        tag: 'test',
      );
      expect(ok, isFalse);
    });

    test('整个档位应用流程：即使会话号写不进去，ao 仍然写了', () async {
      mpvKnownKeys.remove('audiotrack-session-id');
      await apply(mode: MpvAoMode.auto, sessionId: 4242);
      expect(written['ao'], MpvAoMode.auto.aoChain);
      expect(written['audiotrack-session-id'], '4242');
    });
  });

  group('AO 写入时机（open 前与播放中热切换走同一个入口）', () {
    test('auto 在 open 前也显式写 ao —— 「不覆盖」不再是任何一个档位的语义', () async {
      // 这一条是 2026-09-23 真机日志驱动的：默认档位曾经「不写 ao」，
      // 于是落到 media_kit 默认的单值 opensles（`current-ao="opensles"`），
      // 会话号被丢弃、`[FX] skip OPEN`，音效软件必然弹「不兼容」。
      await apply(mode: MpvAoMode.auto);
      expect(
        written.containsKey('ao'),
        isTrue,
        reason: '默认档位必须落到 audiotrack 链上，不能沿用 media_kit 的真机默认',
      );
      expect(written['ao'], MpvAoMode.auto.aoChain);
    });

    test('同一档位重复应用（模拟播放中切档位）写入稳定且仍带兜底', () async {
      for (final mode in MpvAoMode.values) {
        written.clear();
        await apply(mode: mode, sessionId: 99);
        await apply(mode: mode, sessionId: 99);
        expect(written['ao'], mode.aoChain, reason: '${mode.key}：幂等，且链必须带兜底');
        expect(written['ao']!.contains(','), isTrue);
      }
    });
  });

  group('音频会话 id', () {
    test('拿到会话号：写入 audiotrack-session-id 固定会话', () async {
      await apply(mode: MpvAoMode.auto, sessionId: 4242);
      expect(written['audiotrack-session-id'], '4242');
    });

    test('会话号为 0：跳过（设 0 等于让系统另分配，与不设无异）', () async {
      await apply(mode: MpvAoMode.auto, sessionId: 0);
      expect(written.containsKey('audiotrack-session-id'), isFalse);
    });

    test('会话号不可用（null）：跳过且不影响其它属性', () async {
      await apply(mode: MpvAoMode.auto);
      expect(written.containsKey('audiotrack-session-id'), isFalse);
      expect(written['ao'], MpvAoMode.auto.aoChain);
    });
  });

  group('诊断绝不能影响播放', () {
    test('setProperty 全部抛异常：不外抛，正常返回', () async {
      await expectLater(
        MpvAudioOutputService.applyAudioOutputConfig(
          setProperty: (key, value) async => throw StateError('set boom'),
          getProperty: (key) async => '',
          mode: MpvAoMode.auto,
          sessionId: 1,
          tag: 'test',
        ),
        completes,
      );
    });

    test('getProperty（回读诊断）抛异常：不外抛，且前面的写入不被跳过', () async {
      await expectLater(
        MpvAudioOutputService.applyAudioOutputConfig(
          setProperty: (key, value) async => written[key] = value,
          getProperty: (key) async => throw StateError('get boom'),
          mode: MpvAoMode.openSlEs,
          sessionId: 1,
          tag: 'test',
        ),
        completes,
      );
      expect(written['ao'], MpvAoMode.openSlEs.aoChain);
    });
  });

  group('音频效果控制会话广播（Android 官方协议）', () {
    // 背景：RootlessJamesDSP 的「不受支持」弹窗根因是**本应用从未广播**
    // `AudioEffect.ACTION_OPEN_AUDIO_EFFECT_CONTROL_SESSION` —— 该 action 由
    // 播放器主动发出，RJ 的 SessionReceiver（清单注册）收到才知道「这个应用的
    // 音频在哪个会话上」。VLC / YouTube Music / Poweramp 都实现了它。
    //
    // 真机无法自动化，故把判定核心抽成纯函数钉在这里：**只有**该会话号真的被
    // mpv 用上（current-ao 落在 audiotrack）才允许宣告 —— 否则效果应用会挂到
    // 一个空会话上，那在 RJ 那边会被判成「失去路由控制」反而触发弹窗。
    // 真机日志实证（2026-09-23）：audiotrack 档位 OPEN 后音效生效；
    // opensles 档位被这条判定拦住（`skip OPEN`），音效软件仍然弹窗 —— 一致。

    test('会话号缺失或为 0：不宣告（会话号由系统分配，无从告知）', () {
      expect(
        MpvAudioOutputService.shouldAnnounceOpen(
          sessionId: null,
          currentAo: 'audiotrack',
        ),
        isFalse,
      );
      expect(
        MpvAudioOutputService.shouldAnnounceOpen(
          sessionId: 0,
          currentAo: 'audiotrack',
        ),
        isFalse,
      );
    });

    test('current-ao 不是 audiotrack：不宣告（避免挂到没有音频流过的会话）', () {
      for (final ao in <String>['opensles', '?', '', 'aaudio']) {
        expect(
          MpvAudioOutputService.shouldAnnounceOpen(sessionId: 4242, currentAo: ao),
          isFalse,
          reason: '"$ao" 时这个会话号不是**有音频流过**的那个；'
              '宣告它会让效果应用挂空会话 → RJ 判「失去路由控制」',
        );
      }
    });

    test('会话号有效且 current-ao=audiotrack：宣告（唯一正确组合）', () {
      expect(
        MpvAudioOutputService.shouldAnnounceOpen(
          sessionId: 4242,
          currentAo: 'audiotrack',
        ),
        isTrue,
      );
      expect(
        MpvAudioOutputService.shouldAnnounceOpen(
          sessionId: 4242,
          currentAo: 'AudioTrack',
        ),
        isTrue,
        reason: '驱动名大小写不应影响判定',
      );
    });
  });
}
