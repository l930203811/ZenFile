import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// 分享目标桥接：接收第三方 App 分享到 ZenFile 的文件**原始 URI**。
///
/// 替代 receive_sharing_intent 插件（该插件在原生层就把 content:// 复制进
/// 应用 cache 再返回缓存路径，导致普通目录的文件也被无谓复制、且「打开
/// 所在位置」只能定位到缓存目录）。本服务只透传原始 URI，是否复制由
/// IntentHandlerService 在用户选完「打开 / 打开所在位置」后按需决定。
///
/// ⚠️ 原生侧是进程级单例（ShareIntentBridge.kt）：MainActivity 使用缓存引擎，
/// Activity 可能销毁重建而 Dart isolate 存活 —— 所有方法都查/清同一份静态
/// 状态。Dart 侧需在「权限就绪」与「回到前台（resumed）」两个时机各补查一次
/// [getPendingUris]（后者由 main.dart 的 resumed 处理触发）。
class ShareIntentService {
  static const MethodChannel _channel = MethodChannel(
    'com.sequl.zenfile/share_intent',
  );

  /// 查询当前待处理的分享 URI；无则返回 null（幂等，不消费）。
  static Future<ShareIntentInfo?> getPendingUris() async {
    try {
      final res = await _channel.invokeMethod<Map<dynamic, dynamic>>(
        'getShareIntent',
      );
      if (res == null) return null;
      final uris = (res['uris'] as List?)?.cast<String>() ?? const <String>[];
      if (uris.isEmpty) return null;
      return ShareIntentInfo(uris: uris, mime: res['mime'] as String?);
    } on PlatformException catch (e) {
      debugPrint('[share_intent] getPendingUris failed: ${e.code}');
      return null;
    }
  }

  /// 注册「原生侧主动推送分享请求」的回调（onNewIntent 场景）。
  static void setIntentHandler(void Function(ShareIntentInfo info) handler) {
    _channel.setMethodCallHandler((call) async {
      if (call.method != 'onShareIntent') return;
      final args = call.arguments;
      if (args is! Map) return;
      final uris = (args['uris'] as List?)?.cast<String>() ?? const <String>[];
      if (uris.isEmpty) return;
      handler(ShareIntentInfo(uris: uris, mime: args['mime'] as String?));
    });
  }

  /// 消费掉当前 pending 状态（Dart 开始处理时调用，防止 resumed 补查重复弹窗）。
  static Future<void> consume() async {
    try {
      await _channel.invokeMethod<void>('consume');
    } on PlatformException catch (e) {
      debugPrint('[share_intent] consume failed: ${e.code}');
    }
  }
}

/// 待处理的分享 URI 闸门（原生 pending → Flutter 之间的唯一交接点）。
///
/// ⚠️ 为什么必须走闸门、而不是 main.dart 拿到 navigatorKey 的 context 直接处理：
///  · [navigatorKey].currentContext 是 **Navigator 自己**的 context，
///    `Navigator.of(它)`（非 root）在 release 下取不到 NavigatorState → 返回
///    null → `popUntil` 空指针异常，处理链当场断在半路；
///  · 处理期间若把首页换成加载页，HomeScreen 会被卸载 —— 它持有的「切 tab /
///    定位目录」通道随之消失，压缩包虽然加载进了浏览页状态，界面却仍停在分类页。
///
/// 因此改由 **HomeScreen 在自己挂载后用自己的 context** 消费这里的值：
/// 冷启动（权限闸门 / 应用锁）时值会一直挂着，直到首页真正出现才被处理。
class ShareIntentGate {
  /// 当前待处理的原始 URI；null = 无。
  static final ValueNotifier<String?> pending = ValueNotifier<String?>(null);

  /// 发布一个待处理 URI（覆盖式：后来的分享以最新一条为准）。
  static void publish(String uri) {
    if (uri.isEmpty) return;
    pending.value = uri;
  }

  /// 取出并清空（消费）。无则返回 null。
  static String? take() {
    final value = pending.value;
    pending.value = null;
    return value;
  }
}

/// 一次分享请求的上下文。
class ShareIntentInfo {
  /// 分享的文件 URI 列表（原始 content://，未复制）。当前只处理第一个。
  final List<String> uris;

  /// 分享方声明的 MIME 类型（可能为 null）。
  final String? mime;

  const ShareIntentInfo({required this.uris, this.mime});
}
