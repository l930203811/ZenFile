// ⛔ 聚合网盘（夸克 / 阿里云盘）功能暂时下线 —— 2026-09-30。
// 原因：登录后进入目录仍有问题，暂不随正式版发布，代码原样保留待下次完善。
// 本文件目前已无生效引用（不参与构建）；恢复步骤见
// lib/services/network_connections_service.dart 文件头的说明。
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';
import '../../l10n/generated/app_localizations.dart';
import '../../services/remote/netdisk/netdisk_log.dart';
import '../../services/remote/netdisk/netdisk_ua.dart';
import '../widgets/circled_back_button.dart';

/// 网盘网页登录页。
///
/// 应用内打开网盘官方登录页，用户完成登录后抓取登录态：
/// - 夸克：走**原生 CookieManager**（[WebViewCookieManager]）读该域名下的**全部**
///   Cookie。⚠️ 不能用注入 JS 读 `document.cookie`：夸克登录态 Cookie
///   （`__puus` / `__pus`）是 **HttpOnly**，JS 看不到 ⇒ 页面永远不返回，
///   表现为「明明登录成功了却一直没反应」。这是夸克失败的历史根因之一。
/// - 阿里云盘：注入脚本读 `localStorage.token`（非 HttpOnly，JS 可见）。
///
/// 抓取到有效登录态后立即回传并关闭页面；轮询以避免错过登录瞬间。
class NetdiskLoginScreen extends StatefulWidget {
  /// 'quark' 或 'alipan'。
  final String provider;

  const NetdiskLoginScreen({super.key, required this.provider});

  @override
  State<NetdiskLoginScreen> createState() => _NetdiskLoginScreenState();
}

class _NetdiskLoginScreenState extends State<NetdiskLoginScreen> {
  late final WebViewController _controller;
  Timer? _pollTimer;
  bool _done = false;

  /// 登录 WebView 的 UA。
  ///
  /// ⚠️ 这里**不是**一个固定值，而是按网盘分别取（见 [NetdiskUserAgent]）：
  /// - 夸克：用**夸克 PC 客户端 UA**。夸克官方 PC 端本身就是 Chromium/Electron
  ///   套壳，其登录 WebView 访问 `pan.quark.cn` 用的正是这一串 ⇒ 登录页能正常
  ///   渲染，且与后续接口请求**完全一致**（两家都把会话与 UA 绑定，不一致就 401）。
  /// - 阿里：桌面 Chrome（其网页版按 UA 区分「登录界面」与「App 推广页」）。
  String get _ua => widget.provider == 'quark'
      ? NetdiskUserAgent.quarkClient
      : NetdiskUserAgent.desktop;

  /// 夸克登录态出现在这几个 Cookie 名里即视为登录完成。
  /// ⚠️ 都是 HttpOnly ⇒ 只能经原生 CookieManager 读到。
  static const List<String> _quarkAuthCookies = ['__puus', '__pus'];

  static const _pollScriptAlipan = '''
(function () {
  try {
    var raw = localStorage.getItem('token') || '';
    var t = '';
    if (raw.indexOf('{') === 0) {
      try { t = JSON.parse(raw).refresh_token || ''; } catch (e) { t = ''; }
    }
    if (t && t.length > 10 && t.indexOf('null') !== 0) {
      window.ZenFileBridge.postMessage('OK:' + raw);
    }
  } catch (e) {}
})();
''';

  Uri get _startUrl => widget.provider == 'quark'
      ? Uri.parse('https://pan.quark.cn/')
      : Uri.parse('https://www.aliyundrive.com/sign/in');

  /// 只有阿里走注入脚本；夸克走原生 CookieManager（见 [_pollQuarkCookie]）。
  String get _pollScript => _pollScriptAlipan;

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setUserAgent(_ua)
      ..setBackgroundColor(Colors.white)
      ..addJavaScriptChannel('ZenFileBridge',
          onMessageReceived: (message) {
        final body = message.message;
        if (_done || !body.startsWith('OK:')) return;
        // 只有阿里走这条 JS 通道；夸克走原生 CookieManager（[_pollQuarkCookie]）。
        // ⚠️ 这个判断必须在置 _done 之前：否则夸克收到一次无意义消息就会
        // 把轮询停掉，原生读取再也拿不到登录态。
        if (widget.provider != 'alipan') return;
        _done = true;
        _pollTimer?.cancel();
        Navigator.pop(context, {'token_json': body.substring(3)});
      })
      ..setNavigationDelegate(NavigationDelegate(
        onPageFinished: (url) {
          // 页面加载完成后立即尝试一次，再进入轮询
          _pollOnce();
          _startPolling();
        },
      ))
      ..loadRequest(_startUrl);
  }

  /// 取一次登录态：夸克走原生 CookieManager，阿里走注入脚本。
  void _pollOnce() {
    if (_done || !mounted) return;
    if (widget.provider == 'quark') {
      _pollQuarkCookie();
    } else {
      _controller.runJavaScript(_pollScript);
    }
  }

  void _startPolling() {
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(
      const Duration(milliseconds: 1200),
      (_) => _pollOnce(),
    );
  }

  /// 从**原生** CookieManager 读夸克登录态，拼成可直接当 `Cookie` 头用的字符串。
  ///
  /// 为什么两个源都要查：登录页在 `pan.quark.cn`，文件接口在
  /// `drive-pc.quark.cn`；`getCookies` 是按 URL 过滤的，只查一个可能拿不全。
  /// 返回 null 表示「还没登录完成」。
  Future<String?> _readQuarkCookie() async {
    final manager = WebViewCookieManager();
    final byName = <String, String>{};
    for (final host in const [
      'https://pan.quark.cn',
      'https://drive-pc.quark.cn',
    ]) {
      try {
        final list = await manager.getCookies(domain: Uri.parse(host));
        for (final c in list) {
          if (c.name.isEmpty || c.value.isEmpty) continue;
          byName.putIfAbsent(c.name, () => c.value);
        }
      } catch (e) {
        NetdiskLog.error('quark', 'CookieManager($host)', e);
      }
    }
    if (byName.isEmpty) return null;
    final hasAuth = _quarkAuthCookies.any((n) => (byName[n] ?? '').length > 10);
    if (!hasAuth) return null;
    return byName.entries.map((e) => '${e.key}=${e.value}').join('; ');
  }

  Future<void> _pollQuarkCookie() async {
    if (_done || !mounted) return;
    final header = await _readQuarkCookie();
    if (header == null || _done || !mounted) return;
    _done = true;
    _pollTimer?.cancel();
    NetdiskLog.event(
        'quark', '登录态已取得（原生 CookieManager）: ${header.length} 字');
    Navigator.pop(context, {'cookie': header});
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = L10n.of(context);
    return Scaffold(
      appBar: AppBar(
        leading: const CircledBackButton(),
        title: Text(
          widget.provider == 'quark'
              ? l10n.netdisk_quark
              : l10n.netdisk_alipan,
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
      ),
      body: Column(
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            color: theme.colorScheme.primary.withValues(alpha: 0.06),
            child: Row(
              children: [
                Icon(Icons.info_outline_rounded,
                    size: 18, color: theme.colorScheme.primary),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    l10n.netdisk_login_hint,
                    style: TextStyle(
                      fontSize: 13,
                      color: theme.colorScheme.onSurface.withValues(alpha: 0.7),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: WebViewWidget(controller: _controller),
          ),
        ],
      ),
    );
  }
}
