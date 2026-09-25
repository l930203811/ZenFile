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
/// * 提示用户的判据只能是「公共目录里确实存在异常退出报告、且尚未提示过」
///   （[CrashForensicsService.listExitReports] + `selectUnnotified`）。**不能**
///   再用「本次新增份数」—— 报告目录一旦被清理/手删，同一份报告每次启动都会被
///   重新导出并重复提示（2026-09-25 实测；详见 `CacheCleanService` 类注释）；
/// * [CrashForensicsService.recordError] **必须落盘**，且**落盘失败绝不外抛**
///   （取证要是成了新的崩溃源，就彻底本末倒置）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('com.sequl.zenfile/crash_forensics');
  late List<MethodCall> nativeCalls;

  setUp(() {
    nativeCalls = <MethodCall>[];
    // ⚠️ 节流状态是**静态**的（进程级）。不清的话，「同一错误只落一份」这条规则
    //    会跨用例生效，后面的用例会因为「被前一个用例抑制了」而莫名失败。
    CrashForensicsService.resetThrottle();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      nativeCalls.add(call);
      return 'ok:1:0:/fake';
    });
  });

  tearDown(() {
    CrashForensicsService.publicDirOverride = null;
    CrashForensicsService.environmentLineOverride = null;
    CrashForensicsService.resetThrottle();
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

    test('抬头写入「版本 + 机型」，不再让读者去别的文件里找', () {
      final body = CrashForensicsService.buildDartErrorReport(
        kind: 'FlutterError',
        error: 'x',
        stack: null,
        now: DateTime(2026, 9, 25),
        environmentLine:
            'apk=3.0.0@09-25 15:20  |  vivo V2054A · Android 11 (SDK 30)',
      );
      expect(body, contains('apk=3.0.0@09-25 15:20'));
      expect(body, contains('vivo V2054A'));
      expect(
        body.contains('见同目录下的 exit_*.txt'),
        isFalse,
        reason: '报告能自证版本后，不该再让读者去别的文件里找（2026-09-25 的歧义根因）',
      );
    });

    test('拿不到环境行时如实写「未知」，不留空也不抛', () {
      final body = CrashForensicsService.buildDartErrorReport(
        kind: 'zone',
        error: 'x',
        stack: null,
        now: DateTime(2026, 9, 25),
      );
      expect(body, contains('(未知'));
    });

    test('suppressedCount > 0 写明抑制次数；为 0 时整行不出现', () {
      final withSuppress = CrashForensicsService.buildDartErrorReport(
        kind: 'zone',
        error: 'x',
        stack: null,
        now: DateTime(2026, 9, 25),
        suppressedCount: 7,
      );
      expect(withSuppress, contains('已抑制 7 次'));

      final plain = CrashForensicsService.buildDartErrorReport(
        kind: 'zone',
        error: 'x',
        stack: null,
        now: DateTime(2026, 9, 25),
      );
      expect(plain.contains('重复      :'), isFalse);
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

    test('同一错误连续刷 12 次 → 只落 1 份（2026-09-25 实测场景）', () {
      final stack = StackTrace.fromString('#0 A\n#1 B\n#2 C');
      for (var i = 0; i < 12; i++) {
        CrashForensicsService.recordError('FlutterError', 'null check', stack);
      }
      final files = tmp
          .listSync()
          .whereType<File>()
          .where((f) => p.basename(f.path).startsWith('dart_error_'))
          .toList();
      expect(files, hasLength(1),
          reason: '同步写盘不能被同一个错误刷爆（实测 4 分钟刷了 12 份）');
    });

    test('不同错误各落一份（降噪不能吞掉别的 bug）', () {
      CrashForensicsService.recordError(
          'FlutterError', 'e1', StackTrace.fromString('#0 A'));
      CrashForensicsService.recordError(
          'FlutterError', 'e2', StackTrace.fromString('#0 B'));
      CrashForensicsService.recordError(
          'runZonedGuarded', 'e1', StackTrace.fromString('#0 A'));
      final files = tmp
          .listSync()
          .whereType<File>()
          .where((f) => p.basename(f.path).startsWith('dart_error_'))
          .toList();
      expect(files, hasLength(3));
    });

    test('被抑制时不写盘、也不打扰原生', () async {
      CrashForensicsService.recordError('zone', 'e', null);
      nativeCalls.clear();
      CrashForensicsService.recordError('zone', 'e', null); // 窗口内重复
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(
        tmp
            .listSync()
            .whereType<File>()
            .where((f) => p.basename(f.path).startsWith('dart_error_')),
        hasLength(1),
      );
      expect(nativeCalls, isEmpty, reason: '抑制就是彻底不落盘，不该退到原生兜底');
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

  /// 「要不要提示用户」的判据。
  ///
  /// 背景（2026-09-25 用户实测）：旧判据是 `CrashForensicsResult.newReports > 0`
  /// （本次往公共目录新增了几份），而清理缓存会把 `crash/` 删掉 ⇒ 同一份报告每次
  /// 启动都被重新导出、都被判成「新增」⇒ **无限重复提示**。且旧判据把 Dart 层
  /// 非致命错误（`dart_error_*`）也当成「异常退出」，属误报。
  group('异常退出报告的提示判据', () {
    test('只有 exit_* / java_crash_* 算「异常退出」，dart_error_* 不算', () {
      expect(CrashForensicsService.isExitReportName('exit_1700000000000_4.txt'), isTrue);
      expect(CrashForensicsService.isExitReportName('java_crash_1700000000001.txt'), isTrue);
      expect(CrashForensicsService.isExitReportName('dart_error_1700000000002.txt'), isFalse,
          reason: 'Dart 层未捕获错误通常不杀进程，当「异常退出」提示就是误报');
      expect(CrashForensicsService.isExitReportName('unsupported_sdk29.txt'), isFalse);
    });

    test('selectUnnotified：按文件名去重（报告被删后重新导出也不再提示）', () {
      const current = ['exit_1_4.txt', 'exit_2_4.txt'];
      expect(CrashForensicsService.selectUnnotified(current, const []), current);
      expect(
        CrashForensicsService.selectUnnotified(current, const ['exit_1_4.txt']),
        ['exit_2_4.txt'],
      );
      expect(CrashForensicsService.selectUnnotified(current, current), isEmpty,
          reason: '同一份报告不得提示第二次');
      expect(CrashForensicsService.selectUnnotified(const [], current), isEmpty);
    });

    test('listExitReports：只列退出类报告且升序', () {
      final tmp = Directory.systemTemp.createTempSync('zf_crash_list_');
      CrashForensicsService.publicDirOverride = tmp.path;
      try {
        for (final name in [
          'exit_20_4.txt',
          'exit_10_6.txt',
          'java_crash_30.txt',
          'dart_error_99.txt', // 非致命错误：导出保留，但不算「异常退出」
          'unsupported_sdk29.txt',
        ]) {
          File(p.join(tmp.path, name)).writeAsStringSync('x');
        }
        expect(CrashForensicsService.listExitReports(), [
          'exit_10_6.txt',
          'exit_20_4.txt',
          'java_crash_30.txt',
        ]);
      } finally {
        CrashForensicsService.publicDirOverride = null;
        tmp.deleteSync(recursive: true);
      }
    });

    test('listExitReports：目录不存在或路径非法时返回空而不抛', () {
      CrashForensicsService.publicDirOverride = p.join(
        Directory.systemTemp.createTempSync('zf_crash_missing_').path,
        'not-exists',
      );
      expect(CrashForensicsService.listExitReports(), isEmpty);

      final blocker = File(
        p.join(Directory.systemTemp.createTempSync('zf_crash_blk_').path, 'file'),
      )..writeAsStringSync('x');
      CrashForensicsService.publicDirOverride = blocker.path; // 指向文件而非目录
      expect(() => CrashForensicsService.listExitReports(), returnsNormally);
      expect(CrashForensicsService.listExitReports(), isEmpty);
    });
  });

  /// 错误签名 —— 「同一个 bug 反复触发」要被合并，「两个不同的 bug」不能被合并。
  group('signatureOf', () {
    test('同一 bug 反复触发 → 签名逐字相同（才能被节流合并）', () {
      final stack = StackTrace.fromString('#0 A\n#1 B\n#2 C');
      expect(
        CrashForensicsService.signatureOf('FlutterError', 'null check', stack),
        CrashForensicsService.signatureOf('FlutterError', 'null check', stack),
      );
    });

    test('错误文本不同 → 签名不同（不能把两个 bug 并成一个）', () {
      final stack = StackTrace.fromString('#0 A');
      expect(
        CrashForensicsService.signatureOf('FlutterError', 'e1', stack),
        isNot(CrashForensicsService.signatureOf('FlutterError', 'e2', stack)),
      );
    });

    test('栈位置不同 → 签名不同（kind 相同但落点不同）', () {
      expect(
        CrashForensicsService.signatureOf(
            'FlutterError', 'e', StackTrace.fromString('#0 A\n#1 B')),
        isNot(CrashForensicsService.signatureOf(
            'FlutterError', 'e', StackTrace.fromString('#0 A\n#1 Z'))),
      );
    });

    test('无 stack 时不抛（`recordError(..., null)` 是真实调用方式）', () {
      expect(
        () => CrashForensicsService.signatureOf('zone', 'e', null),
        returnsNormally,
      );
    });
  });

  /// 降噪闸门 —— 防止同一错误刷爆报告目录（同步写盘会拖住 UI 线程）。
  group('CrashErrorThrottle.admit', () {
    test('窗口内只放行首份，其余抑制；窗口过后放行并带出抑制次数', () {
      final t = CrashErrorThrottle(
        sameSignatureWindow: const Duration(minutes: 5),
      );
      final t0 = DateTime(2026, 9, 25, 15, 58);
      expect(t.admit('sig', t0), 0, reason: '首份必须放行');

      for (var i = 1; i <= 11; i++) {
        expect(
          t.admit('sig', t0.add(Duration(seconds: i * 10))),
          isNull,
          reason: '窗口内第 $i 次重复应被抑制（实测 12 份就是这么来的）',
        );
      }

      expect(
        t.admit('sig', t0.add(const Duration(minutes: 5))),
        11,
        reason: '「降噪但不丢信息」：抑制次数要能写进下一份报告',
      );
      // 放行后窗口重新计时，抑制计数归零
      expect(t.admit('sig', t0.add(const Duration(minutes: 5, seconds: 1))), isNull);
    });

    test('不同签名互不影响（一个 bug 不能压掉另一个）', () {
      final t = CrashErrorThrottle();
      final t0 = DateTime(2026, 9, 25);
      expect(t.admit('a', t0), 0);
      expect(t.admit('b', t0), 0);
      expect(t.admit('a', t0.add(const Duration(seconds: 1))), isNull);
      expect(t.admit('b', t0.add(const Duration(seconds: 1))), isNull);
    });
  });

  /// 总量裁剪 —— 目录无限膨胀的最后一道保险。
  group('CrashErrorThrottle.trim', () {
    test('超过上限只删最旧的 dart_error_*，绝不碰 exit_*/java_crash_*/其它文件', () {
      final dir = Directory.systemTemp.createTempSync('zf_crash_trim_');
      try {
        for (var i = 1; i <= 50; i++) {
          File(p.join(dir.path, 'dart_error_${1000 + i}.txt'))
              .writeAsStringSync('x');
        }
        for (final keep in [
          'exit_1_4.txt',
          'java_crash_1.txt',
          'user_note.txt',
          'unsupported_sdk29.txt',
        ]) {
          File(p.join(dir.path, keep)).writeAsStringSync('keep me');
        }

        final t = CrashErrorThrottle(maxReports: 40, keepReports: 20);
        expect(t.trim(dir.path), 30);

        final left = dir.listSync().map((e) => p.basename(e.path)).toList();
        final dartLeft =
            left.where((n) => n.startsWith('dart_error_')).toList()..sort();
        expect(dartLeft, hasLength(20));
        expect(dartLeft.first, 'dart_error_1031.txt',
            reason: '按文件名时间戳删最旧、留最新');
        expect(dartLeft.last, 'dart_error_1050.txt');

        for (final keep in [
          'exit_1_4.txt',
          'java_crash_1.txt',
          'user_note.txt',
          'unsupported_sdk29.txt',
        ]) {
          expect(left, contains(keep), reason: '$keep 是权威证据/用户文件，绝不能被裁掉');
        }
      } finally {
        dir.deleteSync(recursive: true);
      }
    });

    test('份数未超上限时不动任何文件', () {
      final dir = Directory.systemTemp.createTempSync('zf_crash_trim2_');
      try {
        for (var i = 1; i <= 5; i++) {
          File(p.join(dir.path, 'dart_error_$i.txt')).writeAsStringSync('x');
        }
        final t = CrashErrorThrottle(maxReports: 40, keepReports: 20);
        expect(t.trim(dir.path), 0);
        expect(dir.listSync(), hasLength(5));
      } finally {
        dir.deleteSync(recursive: true);
      }
    });

    test('目录不存在 / 路径非法时返回 0 而不抛', () {
      final t = CrashErrorThrottle();
      expect(
        t.trim(p.join(Directory.systemTemp.path, 'zf_no_such_dir_xyz')),
        0,
      );
      // 指向「文件」而非目录
      final blocker = File(
        p.join(Directory.systemTemp.createTempSync('zf_crash_trim3_').path, 'f'),
      )..writeAsStringSync('x');
      expect(() => t.trim(blocker.path), returnsNormally);
      expect(t.trim(blocker.path), 0);
    });
  });
}
