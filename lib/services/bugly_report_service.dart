import 'package:flutter/services.dart';

/// 腾讯 Bugly 异常上报桥（Dart 侧）。
///
/// 原生崩溃（Java/Kotlin/NDK/ANR）由 Bugly SDK 自动捕获；Dart 层异常 Bugly
/// 看不见，由 `lib/main.dart` 的全局错误处理器经 [recordError] 转发到原生
/// `BuglyBridge`，以「非致命异常」形式上报。
///
/// 原生侧 APP_ID 未填时通道不会初始化，调用会抛 MissingPluginException ——
/// [recordError] 内部吞掉一切异常，上报链路**绝不**反过来影响主流程。
class BuglyReportService {
  static const MethodChannel _channel = MethodChannel(
    'com.sequl.zenfile/bugly',
  );

  /// 上报一条 Dart 层异常（非致命）。
  ///
  /// [tag] 用于 Bugly 控制台的异常归类，[error]/[stack] 原样转发。
  static Future<void> recordError(
    Object error,
    StackTrace? stack, {
    String tag = 'DartError',
  }) async {
    try {
      await _channel.invokeMethod<void>('postException', {
        'tag': tag,
        'message': error.toString(),
        'stack': stack?.toString() ?? '',
      });
    } catch (_) {
      // 上报失败静默：取证/上报是旁路，绝不能影响主流程。
    }
  }
}
