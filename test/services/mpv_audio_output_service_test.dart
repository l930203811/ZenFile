import 'package:flutter_test/flutter_test.dart';
import 'package:zenfile/services/mpv_audio_output_service.dart';

/// 回归测试：mpv 音频输出（AO）配置。
///
/// 背景（用户反馈 RootlessJamesDSP 判定 ZenFile「不兼容」）：
/// * 旧实现把开关写成**单值** `ao=opensles`。mpv 的 `--ao` 是**候选列表**，
///   单值等于把 audiotrack 从候选里删掉，opensles 建不起来时**不回退、直接静音**
///   —— 与「开关没生效」在体感上无法区分，导致问题长期无法定位。
/// * `audiotrack-session-id` 是唯一能让按音频会话追踪/挂音效的软件稳定识别
///   目标的开关（`ao_audiotrack` 的 `session-id`，options_prefix=audiotrack），
///   漏写就会在开播/切歌时「丢失目标」。
///
/// 这些不变式一旦被改回去，肉眼看代码很难发现（一个字符串而已），故钉在测试里。
void main() {
  /// 记录被写入的属性，供断言使用。
  late Map<String, String> written;

  /// 读取时返回的值（模拟 mpv 回读）。
  late String readBack;

  Future<void> apply({
    required bool openSlEsEnabled,
    int? sessionId,
  }) {
    return MpvAudioOutputService.applyAudioOutputConfig(
      setProperty: (key, value) async => written[key] = value,
      getProperty: (key) async => readBack,
      openSlEsEnabled: openSlEsEnabled,
      sessionId: sessionId,
      tag: 'test',
    );
  }

  setUp(() {
    written = <String, String>{};
    readBack = 'auto-safe';
  });

  group('AO 候选链', () {
    test('开关关闭：不设置 ao，沿用 mpv 默认候选', () async {
      await apply(openSlEsEnabled: false);
      expect(
        written.containsKey('ao'),
        isFalse,
        reason: '关闭时必须完全不碰 ao，否则等于替 mpv 改了默认输出策略',
      );
    });

    test('开关打开：ao 必须是「候选列表」，不能退化成单值', () async {
      await apply(openSlEsEnabled: true);
      final ao = written['ao'];
      expect(ao, isNotNull);
      expect(
        ao!.contains(','),
        isTrue,
        reason: 'mpv 的 --ao 是候选列表；单值会让失败时不回退，直接静音',
      );
      expect(ao.split(',').length, greaterThanOrEqualTo(2));
    });

    test('开关打开：opensles 排在首位（打开开关就该真的走 OpenSL ES）', () async {
      await apply(openSlEsEnabled: true);
      expect(written['ao']!.split(',').first, 'opensles');
    });

    test('开关打开：audiotrack 必须留在候选里兜底（防「建不起来就静音」）', () async {
      await apply(openSlEsEnabled: true);
      expect(
        written['ao']!.split(','),
        contains('audiotrack'),
        reason: '单值 opensles 一旦建不起来就直接静音且不回退 —— 必须留兜底',
      );
    });

    test('开关打开：opensles 必须保留在候选里（旧音效方案的回退）', () async {
      await apply(openSlEsEnabled: true);
      expect(written['ao'], contains('opensles'));
      expect(
        written['ao'],
        MpvAudioOutputService.aoChainWithOpenSlEs,
      );
    });
  });

  group('音频会话 id', () {
    test('拿到会话号：写入 audiotrack-session-id 固定会话', () async {
      await apply(openSlEsEnabled: true, sessionId: 4242);
      expect(written['audiotrack-session-id'], '4242');
    });

    test('会话号为 0：跳过（设 0 等于让系统另分配，与不设无异）', () async {
      await apply(openSlEsEnabled: true, sessionId: 0);
      expect(written.containsKey('audiotrack-session-id'), isFalse);
    });

    test('会话号不可用（null）：跳过且不影响其它属性', () async {
      await apply(openSlEsEnabled: true);
      expect(written.containsKey('audiotrack-session-id'), isFalse);
      expect(written['ao'], MpvAudioOutputService.aoChainWithOpenSlEs);
    });

    test('关闭开关时同样固定会话（不依赖 opensles 开关）', () async {
      await apply(openSlEsEnabled: false, sessionId: 77);
      expect(written['audiotrack-session-id'], '77');
    });
  });

  group('诊断绝不能影响播放', () {
    test('setProperty 全部抛异常：不外抛，正常返回', () async {
      await expectLater(
        MpvAudioOutputService.applyAudioOutputConfig(
          setProperty: (key, value) async => throw StateError('set boom'),
          getProperty: (key) async => '',
          openSlEsEnabled: true,
          sessionId: 1,
          tag: 'test',
        ),
        completes,
      );
    });

    test('getProperty（回读诊断）抛异常：不外抛，正常返回', () async {
      await expectLater(
        MpvAudioOutputService.applyAudioOutputConfig(
          setProperty: (key, value) async => written[key] = value,
          getProperty: (key) async => throw StateError('get boom'),
          openSlEsEnabled: true,
          sessionId: 1,
          tag: 'test',
        ),
        completes,
      );
      // 回读失败也不能让前面的写入被跳过
      expect(written['ao'], MpvAudioOutputService.aoChainWithOpenSlEs);
    });
  });
}
