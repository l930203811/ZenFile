import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

/// 崩溃取证（Dart 侧），与原生 `CrashForensics.kt` 配成一套。
///
/// ## 背景
/// 用户反馈「打开应用就闪退」时，云电脑环境没有无线 adb、release 包也没有 logcat，
/// 唯一能拿到的现场就是**系统自己留下的退出记录**。原生侧用
/// `ApplicationExitInfo`（API 30+）在**下次启动的最早时机**把它落盘；本类负责：
///  1. 启动后把原生写下的存档导出到用户随手可取的公共目录；
///  2. 把 **Dart 层**未捕获错误也落盘（原生取证只看得到进程级死亡，看不到
///     「Dart 抛了个异常但进程活着」这种更常见的现场）。
///
/// ## 为什么不复用 WebdavDebugLog
/// `WebdavDebugLog.enabled` 在 release 包里是 `false`（发版规范），而崩溃取证
/// **必须**在用户零操作的前提下工作 —— 不能要求他先开开关、也不能要求他装一个
/// 专门的诊断包。两者定位不同：那个是「我要看某条链路」，这个是「出事了自动留证」。
///
/// ## 安全约束（重要）
/// 本类的每一个入口都**绝不抛异常**：取证要是成了新的崩溃源，就本末倒置了。
class CrashForensicsService {
  CrashForensicsService._();

  static const MethodChannel _channel =
      MethodChannel('com.sequl.zenfile/crash_forensics');

  /// 公共归档目录：与 `webdav_debug.log` 同处，用户用任意文件管理器即可取出。
  static const String publicDir = '/storage/emulated/0/ZenFile/crash';

  /// 测试注入点：覆盖公共归档目录。
  ///
  /// [publicDir] 是 Android 专用绝对路径，单测跑在宿主（Windows/Linux）上必然
  /// 写不进去 —— 那会静默走「退到原生」的分支，等于没测到落盘本身。把目录换成
  /// 临时目录后，才能验证「真的写出了文件、内容对、目录不存在时会自动创建」。
  @visibleForTesting
  static String? publicDirOverride;

  static String get _dir => publicDirOverride ?? publicDir;

  /// 单份报告里 stack 最多写入的字符数（超长 stack 会掩盖真正有用的头部）。
  static const int _maxStackChars = 20000;

  /// Dart 层报告的文件名前缀 —— 也是**唯一**允许被裁剪删除的那一类。
  static const String dartErrorPrefix = 'dart_error_';

  // ────────────────────────────────────────────────────────────────────
  //  「本机是哪一版、什么机型」—— 报告抬头必须自带
  // ────────────────────────────────────────────────────────────────────

  /// 启动后缓存的「安装包指纹 + 机型」摘要。
  ///
  /// **为什么必须有**：`dart_error_*` 原本只写「设备/版本见同目录 exit_*.txt」，
  /// 自身**不含版本号**。2026-09-25 实测踩到了后果 —— 手上有 13 份报告，却说不清
  /// 它们来自 3.0.0 还是某个自建诊断包，只能靠同目录 `exit_*` 的安装时间去推断。
  static String? _environmentLine;

  /// 写入「安装包指纹 + 机型」摘要（由 `main.dart` 在 `runApp()` **之后**取好后调用）。
  ///
  /// 刻意**由调用方注入**而不在本类内自己去取：取它要 `await` 原生通道与
  /// `device_info_plus`，而本类会被单测直接跑在宿主上 —— 一旦这里 `import` 了
  /// 播放器服务（`MpvAudioOutputService.buildStamp()`），单测就被拖进 `media_kit`。
  /// 传一个现成的字符串进来最干净。
  ///
  /// ⚠️ 绝不要改成「在 `recordError` 里现取现 await」：崩溃路径上不允许新增等待。
  /// 取不到就保持 `null`，报告如实写 `(未知)` —— 宁可缺字段，不可拖慢或拖挂。
  static void setEnvironmentLine(String? line) {
    final v = line?.trim();
    _environmentLine = (v == null || v.isEmpty) ? null : v;
  }

  /// 报告抬头用的环境行（测试可注入；优先级高于 [setEnvironmentLine]）。
  @visibleForTesting
  static String? environmentLineOverride;

  // ────────────────────────────────────────────────────────────────────
  //  降噪闸门：同一个错误不要刷爆报告目录
  // ────────────────────────────────────────────────────────────────────

  static final CrashErrorThrottle _throttle = CrashErrorThrottle();

  /// 测试用：清空节流状态，避免用例之间互相抑制。
  @visibleForTesting
  static void resetThrottle() => _throttle.reset();

  /// 错误签名：`kind` + 错误文本 + stack 前 [frames] 帧。
  ///
  /// 把 stack 一起纳入签名是**必要的**：同一个 `kind`（例如 `FlutterError`）可能来自
  /// 完全不同的 bug，只看 kind 会把它们误并成一条。反过来，同一个 bug 反复触发时
  /// 签名必须**逐字相同** —— 2026-09-25 那 12 份 dispose-NPE 正好满足（错误文本与
  /// 栈顶帧每次都一样），因此能被正确合并成一条。
  static String signatureOf(
    String kind,
    Object error,
    StackTrace? stack, {
    int frames = 6,
  }) {
    final buf = StringBuffer()
      ..write(kind)
      ..write('\u0000')
      ..write(_clip('$error', 300));
    if (stack != null) {
      final lines = '$stack'.split('\n');
      final n = lines.length < frames ? lines.length : frames;
      for (var i = 0; i < n; i++) {
        buf
          ..write('\u0000')
          ..write(_clip(lines[i].trim(), 160));
      }
    }
    return buf.toString();
  }

  static String _clip(String s, int max) =>
      s.length <= max ? s : s.substring(0, max);

  /// 启动时调用：让原生补一次取证，并把私有存档导出到公共目录。
  ///
  /// ⚠️ **必须在 `runApp()` 之后**调用 —— 内部会 `await` 一次原生通道，而
  /// `runApp()` 之前任何等待都可能拖慢/拖挂启动（2026-09-23 的教训）。取证是为
  /// **下一次**崩溃服务的，本次启动快慢与它无关。
  ///
  /// 返回 `null` 表示拿不到结果（原生通道不可用等），调用方应静默跳过。
  static Future<CrashForensicsResult?> checkPreviousExit() async {
    try {
      final raw = await _channel.invokeMethod<String>('exportToPublicDir');
      return CrashForensicsResult.parse(raw);
    } catch (_) {
      return null;
    }
  }

  /// 归档目录概况（供诊断日志使用）。失败返回 `null`。
  static Future<String?> describe() async {
    try {
      return await _channel.invokeMethod<String>('describe');
    } catch (_) {
      return null;
    }
  }

  // ────────────────────────────────────────────────────────────────────
  //  「要不要提示用户」的判据
  // ────────────────────────────────────────────────────────────────────

  /// **进程异常退出**类报告的文件名前缀（原生侧 [CrashForensics.kt] 生成）。
  ///
  /// * `exit_*` —— `ApplicationExitInfo` 里的崩溃 / ANR / 初始化失败；
  /// * `java_crash_*` —— Java/Kotlin 未捕获异常。
  static const List<String> _exitReportPrefixes = ['exit_', 'java_crash_'];

  /// 该报告是否属于「异常退出」类。
  ///
  /// `dart_error_*` **刻意不算**：Dart 层未捕获错误（Flutter 框架报错、zone 里的
  /// 异步异常）通常根本不会杀死进程，把它当「上次异常退出」提示用户就是误报 ——
  /// 用户会以为自己真的崩过。它照样会导出到 `crash/` 供排查，只是不弹提示。
  static bool isExitReportName(String name) =>
      _exitReportPrefixes.any(name.startsWith);

  /// 列出公共归档目录里**异常退出类**报告的文件名（升序）。失败返回空列表。
  ///
  /// 用公共目录而不是原生私有存档：提示文案说的是「报告已保存到 ZenFile/crash」，
  /// 那就必须**真的有这个文件**才提示（导出失败时宁可不说，也不能给假地址）。
  static List<String> listExitReports() {
    try {
      final dir = Directory(_dir);
      if (!dir.existsSync()) return const <String>[];
      final names = dir
          .listSync()
          .whereType<File>()
          .map((f) => p.basename(f.path))
          .where(isExitReportName)
          .toList()
        ..sort();
      return names;
    } catch (_) {
      return const <String>[];
    }
  }

  /// 从 [current] 中挑出 [notified] 里没有的（纯函数，便于单测）。
  ///
  /// 判据按**文件名**去重：文件名含崩溃时间戳，同一份报告恒同名，因此
  /// 「报告被删掉又重新导出」也不会二次提示。
  static List<String> selectUnnotified(
    List<String> current,
    List<String> notified,
  ) {
    if (current.isEmpty) return const <String>[];
    final seen = notified.toSet();
    return current.where((n) => !seen.contains(n)).toList();
  }

  /// 记录一条 Dart 未捕获错误。
  ///
  /// 策略：**先同步写公共目录**（Dart 层错误多半不致命，但同步写能保证「马上就要
  /// 崩」的瞬间也已落盘），公共目录不可写（如存储权限未授予）时**退到原生**写
  /// 私有目录（无需任何权限，必然可写）。
  ///
  /// ## 降噪（2026-09-25 补）
  /// 原来这里是无条件同步写盘：一次真实的 `dispose()` NPE 在 4 分钟内刷了 12 份
  /// 报告；若某错误在 `build()` / 动画 / 滚动里抛，能每秒写几十份 —— **同步 IO**，
  /// 拖住 UI 线程的代价比错误本身更大。现在先过 [CrashErrorThrottle.admit]：
  /// 窗口内重复的同一错误**只计数不写盘**，窗口过后再落盘时把抑制次数写进报告
  /// （**降噪但不丢信息**）。
  static void recordError(String kind, Object error, StackTrace? stack) {
    final now = DateTime.now();

    final suppressed = _throttle.admit(signatureOf(kind, error, stack), now);
    if (suppressed == null) return; // 窗口内重复：只计数，不写盘

    final body = buildDartErrorReport(
      kind: kind,
      error: error,
      stack: stack,
      now: now,
      maxStackChars: _maxStackChars,
      suppressedCount: suppressed,
    );

    var written = false;
    try {
      final dir = Directory(_dir);
      if (!dir.existsSync()) dir.createSync(recursive: true);
      File(p.join(_dir, '$dartErrorPrefix${now.millisecondsSinceEpoch}.txt'))
          .writeAsStringSync(body, flush: true);
      written = true;
      // 裁剪放在「确实写成功之后」：没写进去就没什么可裁的。
      _throttle.trim(_dir);
    } catch (_) {
      written = false;
    }

    if (!written) {
      // 不 await：崩溃路径上不该再引入同步等待。
      unawaited(() async {
        try {
          await _channel.invokeMethod<String>('recordDartError', {
            'kind': kind,
            'message': '$error',
            'stack': truncate(stack?.toString(), _maxStackChars),
          });
        } catch (_) {
          // 记不下就算了，绝不能因此再抛。
        }
      }());
    }
  }

  /// 拼装 Dart 错误报告正文（纯函数，便于单测）。
  ///
  /// [environmentLine] 缺省用启动期缓存的 [_environmentLine]；[suppressedCount] 是
  /// 「本会话内同一错误被抑制掉的次数」，为 0 时不写这一行。
  static String buildDartErrorReport({
    required String kind,
    required Object error,
    required StackTrace? stack,
    required DateTime now,
    int maxStackChars = _maxStackChars,
    String? environmentLine,
    int suppressedCount = 0,
  }) {
    final env = environmentLine ??
        environmentLineOverride ??
        _environmentLine ??
        '(未知 —— 启动期尚未取到；可对照同目录 exit_*.txt 抬头)';

    final buf = StringBuffer()
      ..writeln('==================== ZenFile 崩溃取证 ====================')
      ..writeln('类型      : Dart 未捕获错误（$kind）')
      ..writeln('生成时间  : ${now.toIso8601String()}')
      ..writeln('设备/版本 : $env')
      ..writeln('说明      : Dart 层错误通常不会杀死进程，故可能不出现在系统的')
      ..writeln('            「异常退出」记录里；但它是「用户看到的异常表现」的')
      ..writeln('            常见根源，且时间戳可与同目录的原生报告互相印证。');
    if (suppressedCount > 0) {
      buf.writeln(
          '重复      : 本会话内同一错误已抑制 $suppressedCount 次（只留首份，避免刷爆目录）');
    }
    buf
      ..writeln('==========================================================')
      ..writeln('错误      : $error')
      ..writeln('')
      ..writeln('--- stack ---')
      ..writeln(truncate(stack?.toString(), maxStackChars) ?? '(无 stack)');
    return buf.toString();
  }

  /// 截断过长文本，并在尾部标注「已截断」（不静默丢内容）。
  static String? truncate(String? text, int maxChars) {
    if (text == null) return null;
    if (text.length <= maxChars) return text;
    return '${text.substring(0, maxChars)}\n…（已截断，原始长度 ${text.length} 字符）';
  }
}

/// 原生导出动作的结果。
///
/// 原生返回的是一行紧凑字符串（`MethodChannel` 只方便传基本类型），本类负责把它
/// 解析成结构化结果 —— 解析逻辑做成纯工厂 [parse]，单测可直接覆盖各种返回值。
class CrashForensicsResult {
  const CrashForensicsResult({
    required this.newReports,
    required this.skipped,
    this.dir,
    this.raw,
    this.error,
  });

  /// 本次**真正新增**到公共目录的报告份数（目标已存在的不计入）。
  ///
  /// 这是「要不要提示用户」的唯一判据：靠「文件已存在就跳过」实现天然幂等，
  /// 因此不需要额外持久化「上次提示过什么」。
  final int newReports;

  /// 公共目录里已存在、本次跳过的份数。
  final int skipped;

  /// 公共归档目录（成功时非空）。
  final String? dir;

  /// 原生返回的原始字符串，便于日志排查。
  final String? raw;

  /// 失败原因（成功时为 null）。
  final String? error;

  /// 是否检测到新的崩溃报告。
  bool get hasNewReport => newReports > 0;

  /// 解析原生的返回值。**任何无法识别的输入都退化成「无报告」而不是抛异常。**
  ///
  /// 原生可能返回：
  /// * `ok:<新增>:<跳过>:<目录>`
  /// * `no-reports`（私有目录还没有任何报告，最常见 —— 没崩过）
  /// * `mkdir-failed:<目录>`（公共目录建不出来，通常是存储权限未授予）
  /// * `error:<异常名>:<消息>`
  /// * `null`（通道不可用）
  static CrashForensicsResult parse(String? raw) {
    if (raw == null || raw.isEmpty) {
      return const CrashForensicsResult(newReports: 0, skipped: 0);
    }
    if (raw == 'no-reports') {
      return const CrashForensicsResult(newReports: 0, skipped: 0, raw: 'no-reports');
    }
    if (raw.startsWith('ok:')) {
      final parts = raw.split(':');
      // ok:<新增>:<跳过>:<目录>；目录本身可能含 ':'（Windows 风格路径），
      // 故只按前 3 个分隔符切分，其余原样拼回目录。
      if (parts.length >= 4) {
        final added = int.tryParse(parts[1]) ?? 0;
        final skipped = int.tryParse(parts[2]) ?? 0;
        final dir = parts.sublist(3).join(':');
        return CrashForensicsResult(
          newReports: added,
          skipped: skipped,
          dir: dir.isEmpty ? null : dir,
          raw: raw,
        );
      }
      // 认不出的 ok 形式：当作「无新增」，但保留 raw 供排查。
      return CrashForensicsResult(newReports: 0, skipped: 0, raw: raw);
    }
    return CrashForensicsResult(newReports: 0, skipped: 0, raw: raw, error: raw);
  }
}

/// 「同一个错误不要刷爆报告目录」的闸门。
///
/// ## 为什么需要它（2026-09-25 实测）
/// [CrashForensicsService.recordError] 走的是 `writeAsStringSync(flush: true)`
/// —— **同步 IO**，而原来它无条件执行，于是：
///  * 一次 `dispose()` 的 NPE 在 4 分钟内刷出 **12 份**报告；
///  * 若某错误在 `build()` / 动画 / 滚动回调里抛，能每秒写几十份，UI 线程被同步
///    写盘拖住 —— 那比错误本身更伤用户体验。
///
/// ## 两道闸门
/// 1. **同签名节流**：同一签名在 [sameSignatureWindow] 内只落一份，期间重复次数
///    累加起来，等窗口过后真正落盘时写进报告正文（**降噪，但不丢信息**）；
/// 2. **总量裁剪**：目录里 `dart_error_*` 超过 [maxReports] 份时，按文件名里的
///    时间戳删掉最旧的，只保留最新 [keepReports] 份。
///    ⚠️ **只认 `dart_error_` 前缀** —— `exit_*` / `java_crash_*` 以及用户自己放
///    进来的任何文件一律不动（原生报告是权威证据，Dart 报告才是可再生的噪音）。
///
/// 刻意**不做跨进程持久化**：崩溃路径上不该再读一次偏好设置（可能慢、可能失败）。
/// 代价是「每次冷启动会重新放行首份」，由总量裁剪兜住 —— 目录最坏也就是
/// [keepReports] 份上下，够事后排查用。
@visibleForTesting
class CrashErrorThrottle {
  CrashErrorThrottle({
    this.sameSignatureWindow = const Duration(minutes: 5),
    this.maxReports = 40,
    this.keepReports = 20,
  });

  /// 同一签名在这个时长内只落一份报告。
  final Duration sameSignatureWindow;

  /// 目录里 `dart_error_*` 超过这个份数就触发裁剪。
  final int maxReports;

  /// 裁剪后保留的最新份数。
  final int keepReports;

  final Map<String, _SignatureState> _states = <String, _SignatureState>{};

  /// 判定一次错误是否应当落盘。
  ///
  /// * 返回 `null` ⇒ **抑制**（窗口内重复，只计数，调用方不要写盘）；
  /// * 返回 `int` ⇒ **应落盘**，值为「此前被抑制掉的次数」（首次为 0）。
  int? admit(String signature, DateTime now) {
    final st = _states[signature];
    if (st == null) {
      _states[signature] = _SignatureState(firstAt: now);
      return 0;
    }
    if (now.difference(st.firstAt) < sameSignatureWindow) {
      st.suppressed++;
      return null;
    }
    final suppressed = st.suppressed;
    st
      ..firstAt = now
      ..suppressed = 0;
    return suppressed;
  }

  /// 裁剪 [dir] 里最旧的 `dart_error_*`，返回删除份数。**任何失败都吞掉。**
  int trim(String dir) {
    try {
      final d = Directory(dir);
      if (!d.existsSync()) return 0;
      final files = <File>[];
      for (final e in d.listSync()) {
        if (e is! File) continue;
        if (!p.basename(e.path).startsWith(CrashForensicsService.dartErrorPrefix)) {
          continue;
        }
        files.add(e);
      }
      if (files.length <= maxReports) return 0;
      final dropCount = files.length - keepReports;
      if (dropCount <= 0) return 0;
      files.sort((a, b) => stampOf(a.path).compareTo(stampOf(b.path)));
      var removed = 0;
      for (final f in files.take(dropCount)) {
        try {
          f.deleteSync();
          removed++;
        } catch (_) {
          // 单个删不掉不影响其余
        }
      }
      return removed;
    } catch (_) {
      return 0;
    }
  }

  /// 从文件名里取毫秒时间戳（`dart_error_<ms>.txt`）；取不到时退化成 mtime。
  @visibleForTesting
  static int stampOf(String path) {
    final name = p.basename(path);
    final digits =
        RegExp(r'\d+').allMatches(name).map((m) => m.group(0)!).join();
    final parsed = int.tryParse(digits);
    if (parsed != null) return parsed;
    try {
      return File(path).lastModifiedSync().millisecondsSinceEpoch;
    } catch (_) {
      return 0;
    }
  }

  /// 清空节流状态（测试用）。
  @visibleForTesting
  void reset() {
    _states.clear();
  }
}

/// 单个签名的节流状态。
class _SignatureState {
  _SignatureState({required this.firstAt});

  /// 本窗口内首次被放行的时刻。
  DateTime firstAt;

  /// 本窗口内被抑制掉的次数。
  int suppressed = 0;
}
