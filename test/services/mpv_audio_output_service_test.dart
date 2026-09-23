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
/// 这些不变式一旦被改回去，肉眼看代码很难发现（就是一个字符串），故钉在测试里。
void main() {
  /// 模拟 mpv 的选项表：写进去什么，回读就是什么。
  late Map<String, String> written;

  /// 模拟「mpv 是否认识这个选项」——不在集合里则回读 '?'（现实中是抛异常）。
  late Set<String> mpvKnownKeys;

  Future<void> apply({
    required MpvAoMode mode,
    int? sessionId,
    bool hot = false,
  }) {
    return MpvAudioOutputService.applyAudioOutputConfig(
      setProperty: (key, value) async => written[key] = value,
      getProperty: (key) async =>
          mpvKnownKeys.contains(key) ? (written[key] ?? '') : '?',
      mode: mode,
      sessionId: sessionId,
      tag: 'test',
      hot: hot,
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
    test('auto：完全不碰 ao，沿用 media_kit 默认（真机 = 单值 opensles）', () async {
      await apply(mode: MpvAoMode.auto);
      expect(
        written.containsKey('ao'),
        isFalse,
        reason: 'auto 必须完全不碰 ao，否则等于替 mpv/media_kit 改了默认输出策略',
      );
    });

    test('每个非 auto 档位都必须是「候选列表」，不能退化成单值', () async {
      for (final mode in MpvAoMode.values) {
        final chain = mode.aoChain;
        if (chain == null) continue; // auto
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
        for (final chain in <String?>[mode.aoChain, mode.hotChain]) {
          if (chain == null) continue;
          expect(
            chain.contains(':'),
            isFalse,
            reason: '${mode.key}: "$chain" —— `--ao=驱动:子选项=值` 自 mpv 0.23.0 起'
                '非法（M_OPT_INVALID），且 media_kit 会静默吞掉这个失败：'
                '档位看起来存了、日志也打了，实际一个字节都没生效（2026-09-23 真机日志 实证）',
          );
        }
      }
    });

    test('audiotrack 档位：audiotrack 排在首位、opensles 兜底', () async {
      await apply(mode: MpvAoMode.audioTrack);
      final parts = written['ao']!.split(',');
      expect(
        parts.first.startsWith('audiotrack'),
        isTrue,
        reason: '本档位的全部意义就是让 audiotrack 真的生效 —— '
            '其源码不请求低延迟、75~150ms 普通缓冲、USAGE_MEDIA，'
            '是唯一有依据能被免 Root 音效软件接管的链路',
      );
      expect(parts, contains('opensles'), reason: '必须留兜底，防「建不起来就静音」');
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
      // mpv 的选项在同一实例内是残留的：从 16-bit 切回 audioTrack 时若什么都不写，
      // 位深会静默停在 16-bit —— 又是「切了档位但行为不变」。
      for (final mode in MpvAoMode.values) {
        written.clear();
        await apply(mode: mode, sessionId: 7);
        final pcm = written['audiotrack-pcm-float'];
        switch (mode) {
          case MpvAoMode.audioTrack:
            expect(pcm, 'yes', reason: '显式写回 mpv 默认值，清掉可能残留的 16-bit');
          case MpvAoMode.audioTrack16:
            expect(pcm, 'no');
          case MpvAoMode.auto:
          case MpvAoMode.openSlEs:
            expect(
              pcm,
              isNull,
              reason: '${mode.key}: auto 要求完全沿用 media_kit 默认；'
                  'opensles 驱动不认识该选项，写了也无意义',
            );
        }
      }
    });

    test('opensles 档位：opensles 在首位且 audiotrack 兜底（旧开关语义）', () async {
      await apply(mode: MpvAoMode.openSlEs);
      final parts = written['ao']!.split(',');
      expect(parts.first, 'opensles');
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

    test('只有 audiotrack 系列档位需要固定音频会话号', () {
      expect(MpvAoMode.auto.usesSessionId, isFalse);
      expect(MpvAoMode.audioTrack.usesSessionId, isTrue);
      expect(MpvAoMode.audioTrack16.usesSessionId, isTrue);
      expect(MpvAoMode.openSlEs.usesSessionId, isTrue);
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
      await apply(mode: MpvAoMode.audioTrack, sessionId: 4242);
      expect(written['ao'], MpvAoMode.audioTrack.aoChain);
      expect(written['audiotrack-session-id'], '4242');
    });
  });

  group('播放中热切换（档位必须立刻生效）', () {
    test('hot=true 且 auto：显式写回真机默认 opensles（运行中无法「取消覆盖」）', () async {
      await apply(mode: MpvAoMode.auto, hot: true);
      expect(
        written['ao'],
        'opensles',
        reason: 'open 前 auto 语义是「不写」，但运行中覆盖过 ao 后无法取消覆盖，'
            '只能显式写回 media_kit 在真机的默认值，否则从别的档位切回 Auto '
            '会静默留在旧驱动上（用户以为切了、实际没切）',
      );
    });

    test('hot=true 时非 auto 档位的链与 open 前完全一致', () async {
      for (final mode in MpvAoMode.values) {
        if (mode == MpvAoMode.auto) continue;
        written.clear();
        await apply(mode: mode, hot: true);
        expect(written['ao'], mode.aoChain, reason: '${mode.key} 热切换链不应与 open 前不同');
      }
    });

    test('hotChain 必须带兜底；**仅 auto 例外**（它要还原 media_kit 真机的单值默认）', () {
      for (final mode in MpvAoMode.values) {
        final chain = mode.hotChain;
        if (mode == MpvAoMode.auto) {
          // auto 的语义是「完全按 media_kit 默认」，而 media_kit 在 Android 真机
          // 默认写的就是**单值** opensles（real.dart）。
          // ⚠️ 这里刻意还原它、**不额外加候选** —— 加了就不是 auto 了。
          // 这不会引入新风险：万一 opensles 建不起来，在「我们从不碰 ao」的
          // 真正 auto 下同样会静音，行为一致。
          expect(chain, 'opensles');
          continue;
        }
        expect(chain.contains(','), isTrue, reason: '${mode.key}: 热切换也不能写单值');
        expect(chain.split(',').length, greaterThanOrEqualTo(2));
      }
    });

    test('hot=false（open 前）仍然完全不碰 auto 的 ao', () async {
      await apply(mode: MpvAoMode.auto);
      expect(written.containsKey('ao'), isFalse);
    });
  });

  group('音频会话 id', () {
    test('拿到会话号：写入 audiotrack-session-id 固定会话', () async {
      await apply(mode: MpvAoMode.audioTrack, sessionId: 4242);
      expect(written['audiotrack-session-id'], '4242');
    });

    test('会话号为 0：跳过（设 0 等于让系统另分配，与不设无异）', () async {
      await apply(mode: MpvAoMode.audioTrack, sessionId: 0);
      expect(written.containsKey('audiotrack-session-id'), isFalse);
    });

    test('会话号不可用（null）：跳过且不影响其它属性', () async {
      await apply(mode: MpvAoMode.audioTrack);
      expect(written.containsKey('audiotrack-session-id'), isFalse);
      expect(written['ao'], MpvAoMode.audioTrack.aoChain);
    });
  });

  group('诊断绝不能影响播放', () {
    test('setProperty 全部抛异常：不外抛，正常返回', () async {
      await expectLater(
        MpvAudioOutputService.applyAudioOutputConfig(
          setProperty: (key, value) async => throw StateError('set boom'),
          getProperty: (key) async => '',
          mode: MpvAoMode.audioTrack,
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
}
