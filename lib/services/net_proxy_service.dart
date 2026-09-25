import 'dart:async';

import 'package:flutter/services.dart';

/// 读取 Android 系统 HTTP 代理（WiFi 高级设置里手填的代理）。
///
/// 为什么需要它：Dart 的 `HttpClient` **默认不使用 Android 系统代理**。
/// 常见误解是「设一下 `findProxyFromEnvironment` 就好」——它读的是**进程环境变量**
/// （`http_proxy` / `https_proxy`），而 Android 应用进程根本没有这些变量
/// ⇒ 对「WiFi 里手填了代理」的用户等于没生效。真要拿系统代理只能读 Java 层的
/// `ProxySelector`（原生通道），所以这里加了一个很小的原生接口。
///
/// ⚠️ **VPN / 全局代理类工具不需要它**：那类工具在网络层透明拦截，
/// 应用无感知、也无需配置。这里只服务「手动配置代理」这一种场景。
///
/// 全程防御式：任何异常 / 超时 / 未实现都返回 null（= 直连），
/// **绝不因为读代理而卡住或搞挂更新检测**。
class NetProxyService {
  NetProxyService._();

  static const MethodChannel _channel =
      MethodChannel('com.sequl.zenfile/net_proxy');

  static String? _cached;
  static bool _loaded = false;

  /// 返回 `host:port`；无代理或读取失败返回 null。
  ///
  /// 首次调用走原生通道，之后走缓存（同一会话内代理设置基本不变）。
  static Future<String?> getHttpProxy() async {
    if (_loaded) return _cached;
    try {
      final v = await _channel
          .invokeMethod<String>('getHttpProxy')
          .timeout(const Duration(milliseconds: 1500));
      final s = (v ?? '').trim();
      _cached = s.isEmpty ? null : s;
    } catch (_) {
      // 通道缺失（如单测 / 非 Android）或原生异常 ⇒ 直连
      _cached = null;
    }
    _loaded = true;
    return _cached;
  }

  /// 使缓存失效（切换网络后如需要可调用）。
  static void invalidate() {
    _loaded = false;
    _cached = null;
  }
}
