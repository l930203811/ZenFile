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

  /// 记录一条 Dart 未捕获错误。
  ///
  /// 策略：**先同步写公共目录**（Dart 层错误多半不致命，但同步写能保证「马上就要
  /// 崩」的瞬间也已落盘），公共目录不可写（如存储权限未授予）时**退到原生**写
  /// 私有目录（无需任何权限，必然可写）。
  static void recordError(String kind, Object error, StackTrace? stack) {
    final now = DateTime.now();
    final body = buildDartErrorReport(
      kind: kind,
      error: error,
      stack: stack,
      now: now,
      maxStackChars: _maxStackChars,
    );

    var written = false;
    try {
      final dir = Directory(_dir);
      if (!dir.existsSync()) dir.createSync(recursive: true);
      File(p.join(_dir, 'dart_error_${now.millisecondsSinceEpoch}.txt'))
          .writeAsStringSync(body, flush: true);
      written = true;
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
  static String buildDartErrorReport({
    required String kind,
    required Object error,
    required StackTrace? stack,
    required DateTime now,
    int maxStackChars = _maxStackChars,
  }) {
    final buf = StringBuffer()
      ..writeln('==================== ZenFile 崩溃取证 ====================')
      ..writeln('类型      : Dart 未捕获错误（$kind）')
      ..writeln('生成时间  : ${now.toIso8601String()}')
      ..writeln('说明      : Dart 层错误通常不会杀死进程，故可能不出现在系统的')
      ..writeln('            「异常退出」记录里；但它是「用户看到的异常表现」的')
      ..writeln('            常见根源，且时间戳可与同目录的原生报告互相印证。')
      ..writeln('设备/版本 : 见同目录下的 exit_*.txt / java_crash_*.txt 抬头')
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
