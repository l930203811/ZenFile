import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:zenfile/services/crash_forensics_service.dart';

/// 崩溃取证（Dart 侧）的回归测试。
///
/// 钉住的不变式：
/// * [CrashForensicsResult.parse] 对**任何**输入都不得抛异常 —— 它跑在启动路径上，
///   原生返回的字符串格式一旦变化（或多平台差异），抛异常就等于「取证把启动弄挂」；
/// * 返回值里的 `newReports` 必须真的是「新增份数」（提示用户与否只认它，认错就会
///   每次启动都骚扰用户，或永远不提示）；
/// * [CrashForensicsService.recordError] **必须落盘**，且**落盘失败绝不外抛**
///   （取证要是成了新的崩溃源，就彻底本末倒置）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('com.sequl.zenfile/crash_forensics');
  late List<MethodCall> nativeCalls;

  setUp(() {
    nativeCalls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      nativeCalls.add(call);
      return 'ok:1:0:/fake';
    });
  });

  tearDown(() {
    CrashForensicsService.publicDirOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  group('CrashForensicsResult.parse', () {
    test('null / 空串 → 无报告，且不抛', () {
      for (final raw in <String?>[null, '']) {
        final r = CrashForensicsResult.parse(raw);
        expect(r.newReports, 0);
        expect(r.hasNewReport, isFalse);
      }
    });

    test('no-reports（从没崩过）→ 无报告', () {
      final r = CrashForensicsResult.parse('no-reports');
      expect(r.newReports, 0);
      expect(r.hasNewReport, isFalse);
      expect(r.error, isNull, reason: '「没崩过」不是错误，不该被当成失败');
    });

    test('ok:<新增>:<跳过>:<目录> → 逐项解析', () {
      final r = CrashForensicsResult.parse('ok:3:5:/storage/emulated/0/ZenFile/crash');
      expect(r.newReports, 3);
      expect(r.skipped, 5);
      expect(r.dir, '/storage/emulated/0/ZenFile/crash');
      expect(r.hasNewReport, isTrue);
      expect(r.error, isNull);
    });

    test('新增为 0 → 不提示用户（幂等的关键）', () {
      final r = CrashForensicsResult.parse('ok:0:7:/storage/emulated/0/ZenFile/crash');
      expect(r.newReports, 0);
      expect(r.hasNewReport, isFalse,
          reason: '报告已存在时若还判成「有新报告」，用户每次启动都会被提示一次');
      expect(r.skipped, 7);
    });

    test('目录里含冒号也不能被切断（按前 3 个分隔符切分）', () {
      final r = CrashForensicsResult.parse('ok:1:0:C:/Users/x/ZenFile/crash');
      expect(r.newReports, 1);
      expect(r.dir, 'C:/Users/x/ZenFile/crash');
    });

    test('mkdir-failed → 视为失败且无新增', () {
      final r = CrashForensicsResult.parse('mkdir-failed:/storage/emulated/0/ZenFile/crash');
      expect(r.newReports, 0);
      expect(r.hasNewReport, isFalse);
      expect(r.error, isNotNull);
    });

    test('error:... → 视为失败且无新增', () {
      final r = CrashForensicsResult.parse('error:SecurityException:denied');
      expect(r.newReports, 0);
      expect(r.error, contains('SecurityException'));
    });

    test('认不出的 ok 形式 → 退化成「无新增」而不是抛', () {
      final r = CrashForensicsResult.parse('ok:???');
      expect(r.newReports, 0);
      expect(r.hasNewReport, isFalse);
      expect(r.raw, 'ok:???');
    });

    test('任意垃圾输入都不抛', () {
      for (final raw in ['wtf', ':::', 'ok:::', 'ok:1:2:']) {
        expect(() => CrashForensicsResult.parse(raw), returnsNormally,
            reason: '启动路径上的解析不允许抛: $raw');
      }
    });
  });

  group('buildDartErrorReport', () {
    test('正文包含类型、错误、stack 与时间', () {
      final body = CrashForensicsService.buildDartErrorReport(
        kind: 'FlutterError',
        error: 'boom',
        stack: StackTrace.fromString('#0 foo'),
        now: DateTime.parse('2026-09-23T22:30:00.000'),
      );
      expect(body, contains('FlutterError'));
      expect(body, contains('boom'));
      expect(body, contains('#0 foo'));
      expect(body, contains('2026-09-23T22:30:00.000'));
      expect(body, contains('ZenFile 崩溃取证'));
    });

    test('没有 stack 时写明「无 stack」而不是留空', () {
      final body = CrashForensicsService.buildDartErrorReport(
        kind: 'zone',
        error: 'x',
        stack: null,
        now: DateTime(2026, 9, 23),
      );
      expect(body, contains('(无 stack)'));
    });

    test('超长 stack 被截断且标注原始长度（不静默丢内容）', () {
      final long = 'A' * 5000;
      final body = CrashForensicsService.buildDartErrorReport(
        kind: 'zone',
        error: 'x',
        stack: StackTrace.fromString(long),
        now: DateTime(2026, 9, 23),
        maxStackChars: 100,
      );
      expect(body, contains('已截断'));
      expect(body, contains('原始长度 5000'));
      expect(body.contains('A' * 200), isFalse, reason: '确实截断了');
    });
  });

  group('truncate', () {
    test('短文本原样返回', () {
      expect(CrashForensicsService.truncate('abc', 10), 'abc');
    });

    test('null 进 null 出', () {
      expect(CrashForensicsService.truncate(null, 10), isNull);
    });

    test('恰好等于上限时不截断（边界）', () {
      expect(CrashForensicsService.truncate('abcd', 4), 'abcd');
    });
  });

  group('recordError 落盘', () {
    late Directory tmp;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('zf_crash_');
      CrashForensicsService.publicDirOverride = tmp.path;
    });

    tearDown(() {
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });

    test('写出 dart_error_*.txt，内容含类型/错误/stack', () {
      CrashForensicsService.recordError(
        'FlutterError',
        'something broke',
        StackTrace.fromString('#0 line'),
      );

      final files = tmp
          .listSync()
          .whereType<File>()
          .where((f) => p.basename(f.path).startsWith('dart_error_'))
          .toList();
      expect(files, hasLength(1), reason: '每次错误应落一份报告');
      final text = files.single.readAsStringSync();
      expect(text, contains('FlutterError'));
      expect(text, contains('something broke'));
      expect(text, contains('#0 line'));
    });

    test('目录不存在时自动创建（首次崩溃就落盘）', () {
      final nested = p.join(tmp.path, 'a', 'b');
      CrashForensicsService.publicDirOverride = nested;

      CrashForensicsService.recordError('zone', 'e', null);

      expect(Directory(nested).existsSync(), isTrue);
      expect(
        Directory(nested)
            .listSync()
            .whereType<File>()
            .any((f) => p.basename(f.path).startsWith('dart_error_')),
        isTrue,
      );
    });

    test('落盘失败时不外抛，且退到原生兜底（写私有目录）', () async {
      // 注入手法：把归档目录指到一个「父级是文件」的非法路径上 → 建目录必然失败。
      final blocker = File(p.join(tmp.path, 'blocker'))..writeAsStringSync('x');
      CrashForensicsService.publicDirOverride = p.join(blocker.path, 'sub');

      expect(
        () => CrashForensicsService.recordError('zone', 'e', null),
        returnsNormally,
        reason: '取证绝不能成为新的崩溃源',
      );

      // 异步等待「退到原生」的那次调用完成
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(
        nativeCalls.any((c) => c.method == 'recordDartError'),
        isTrue,
        reason: '公共目录不可写时应交原生写私有目录（无需权限，必然可写）',
      );
      final call = nativeCalls.firstWhere((c) => c.method == 'recordDartError');
      final args = call.arguments as Map<Object?, Object?>;
      expect(args['kind'], 'zone');
      expect(args['message'], 'e');
    });

    test('落盘成功时不打扰原生（少一次通道往返）', () async {
      CrashForensicsService.recordError('zone', 'e', null);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(nativeCalls.any((c) => c.method == 'recordDartError'), isFalse);
    });
  });

  group('checkPreviousExit', () {
    test('原生可用时返回解析结果', () async {
      final r = await CrashForensicsService.checkPreviousExit();
      expect(r, isNotNull);
      expect(r!.newReports, 1);
      expect(nativeCalls.single.method, 'exportToPublicDir');
    });

    test('原生抛错时返回 null 而不是把启动弄挂', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        throw PlatformException(code: 'BOOM');
      });
      final r = await CrashForensicsService.checkPreviousExit();
      expect(r, isNull);
    });
  });
}
