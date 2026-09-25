import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// ─────────────────────────────────────────────────────────────────────────
/// GitHub 版本检测（纯逻辑层，可注入、可测试）
///
/// 为什么单独抽一个 service：这段逻辑此前**写在 `_UpdateScreenState` 里**，
/// 于是「没发新版本就永远测不了」「失败原因分不出来」「卡住时无法复现」三件事
/// 无法解决。抽出来后可以直接用本机 `HttpServer` 造假响应跑单测，**不需要真机、
/// 不需要发版、也不需要真有一个新版本存在**。
///
/// 本轮修的三个真实缺陷（都在旧实现里）：
///   ① **读响应体没有超时** —— 旧代码只给 `getUrl()` 与 `close()` 加了超时，
///      而 `resp.transform(utf8.decoder).join()` **没有任何超时**。国内网络最常见
///      的故障恰好是「TCP/TLS 通了，但数据不来」（半开连接 / 中间设备静默丢包），
///      此时旧实现会**永远停在「正在检查更新…」**：既不报成功、也不报失败。
///   ② **没有整体超时上限** —— 各阶段各 10s 串起来可达 30s+，叠加 ① 就是无上限。
///   ③ **拿不到本机版本号时被判为「已是最新」** —— 旧判定是
///      `_currentVersion.isNotEmpty && compare(tag, cur) > 0 ? hasUpdate : latest`，
///      `PackageInfo` 失败时条件为 false ⇒ 直接走进 `latest` ⇒ **谎报「已是最新版本」**。
///      现在显式返回 [UpdateCheckError.versionUnknown]，不再猜。
///
/// 通道优先级（第一个成功的即返回，失败自动降级）：
///   ① [UpdateChannel.custom]    —— 用户自定义更新源（镜像 / 自建接口）
///   ② [UpdateChannel.githubApi] —— api.github.com（唯一能拿到 assets 的通道 ⇒ 可应用内下载）
///   ③ [UpdateChannel.githubWeb] —— github.com 的 302 重定向（拿不到 assets ⇒ 只能跳浏览器）
/// ─────────────────────────────────────────────────────────────────────────

/// 检测走的通道。
enum UpdateChannel {
  /// 用户自定义更新源（镜像 / 自建接口），返回同构 JSON。
  custom,

  /// GitHub 官方 REST API。只有它能拿到 `assets`（⇒ 能走应用内下载安装）。
  githubApi,

  /// GitHub 网页端（只读 302 的 `Location` 拿 tag）。拿不到 assets。
  githubWeb,
}

/// 失败原因分类 —— 决定给用户看哪一句提示（旧实现所有失败只有一句通用文案）。
enum UpdateCheckError {
  /// 连不上：DNS 解析失败 / 连接被拒 / 连接被重置 / TLS 握手失败。
  network,

  /// 超时：连接、响应头、响应体任一阶段超时，或整次检测超过总上限。
  timeout,

  /// GitHub 限速（403 且 `x-ratelimit-remaining: 0`，或 429）。
  /// 未认证请求是 60 次/小时/IP，国内共享出口 IP 极易触发。
  rateLimited,

  /// 其它非 200 响应。
  http,

  /// 响应不是预期 JSON，或 `tag_name` 为空。
  malformed,

  /// 拿不到本机版本号 —— **不能谎报「已是最新」**。
  versionUnknown,

  /// 兜底。
  unknown,
}

/// Release 里的一个可下载资产。
class UpdateAsset {
  final String name;
  final String url;
  const UpdateAsset({required this.name, required this.url});
}

/// 一次检测的结果。失败时 [error] 非空，[remoteVersion] 可能为空。
class UpdateCheckResult {
  final bool hasUpdate;

  /// 远端最新 tag（如 `v2.1.7`）。失败时为空串。
  final String remoteVersion;

  /// 远端 Release 页面地址（失败时为兜底页面）。
  final String pageUrl;

  /// 可下载资产（只有 [UpdateChannel.githubApi] 拿得到）。
  final List<UpdateAsset> assets;

  final UpdateCheckError? error;

  /// 失败时的 HTTP 状态码（网络层失败时为 null）。
  final int? httpStatus;

  /// 本次结果来自哪个通道。
  final UpdateChannel channel;

  /// 用了备用通道（⇒ 界面可如实标注「已降级」）。
  final bool usedFallback;

  /// 耗时。
  final Duration elapsed;

  /// 诊断细节（只进日志，不进 UI）。
  final String detail;

  const UpdateCheckResult({
    this.hasUpdate = false,
    this.remoteVersion = '',
    this.pageUrl = '',
    this.assets = const <UpdateAsset>[],
    this.error,
    this.httpStatus,
    this.channel = UpdateChannel.githubApi,
    this.usedFallback = false,
    this.elapsed = Duration.zero,
    this.detail = '',
  });

  bool get ok => error == null;
}

/// 内部失败信号（带分类），只在 service 内流转。
class _Failure implements Exception {
  final UpdateCheckError error;
  final int? httpStatus;
  final String detail;
  const _Failure(this.error, this.httpStatus, this.detail);
  @override
  String toString() => 'UpdateCheckFailure(${error.name}, $httpStatus, $detail)';
}

/// 一次通道尝试的描述。
class _Attempt {
  final UpdateChannel channel;
  final String url;
  const _Attempt(this.channel, this.url);
}

class UpdateCheckService {
  /// GitHub 官方 REST API（默认源）。
  static const String defaultApiUrl =
      'https://api.github.com/repos/l930203811/ZenFile/releases/latest';

  /// GitHub 网页端（备用通道，只读 302）。
  static const String defaultWebUrl =
      'https://github.com/l930203811/ZenFile/releases/latest';

  /// `{repo}` 占位符展开成的仓库标识。
  static const String repoSlug = 'l930203811/ZenFile';

  /// 连接超时（TCP + TLS 建连）。
  final Duration connectTimeout;

  /// 响应头超时（`getUrl` + `close`）。
  final Duration responseTimeout;

  /// **响应体超时** —— 旧实现缺的就是这一条（也是「永远转圈」的根因）。
  final Duration bodyTimeout;

  /// 整次检测的总上限（含所有通道的降级尝试）。
  final Duration totalTimeout;

  /// 用户自定义 API 地址；空串表示用官方源。支持 `{repo}` 占位。
  final String? apiUrlOverride;

  /// 官方 API 地址（第一降级通道）。做成实例字段而非直接引用常量，
  /// 是为了让单测能把「官方通道」也指向本机假服务器，从而覆盖降级链路。
  final String apiUrl;

  /// 备用网页通道地址；传 null 可关闭该通道（自定义源模式下默认不需要）。
  final String? webUrl;

  /// 系统代理提供者（返回 `host:port`；拿不到返回 null ⇒ 直连）。
  /// 抽成注入点：① 原生通道在单测环境不可用；② 单测打本机服务器时绝不能被代理拦截。
  final Future<String?> Function()? httpProxyProvider;

  /// 诊断日志（生产环境接 `WebdavDebugLog.log`）。
  final void Function(String message)? logger;

  UpdateCheckService({
    this.connectTimeout = const Duration(seconds: 8),
    this.responseTimeout = const Duration(seconds: 8),
    this.bodyTimeout = const Duration(seconds: 8),
    this.totalTimeout = const Duration(seconds: 20),
    this.apiUrlOverride,
    this.apiUrl = defaultApiUrl,
    this.webUrl = defaultWebUrl,
    this.httpProxyProvider,
    this.logger,
  });

  /// 比较两个语义化版本号（允许 `v` 前缀）。
  /// a > b 返回正数，相等 0，a < b 返回负数。
  static int compareVersions(String a, String b) {
    List<int> parse(String v) => v
        .replaceFirst(RegExp(r'^[vV]'), '')
        .split('.')
        .map((e) => int.tryParse(e.trim().replaceAll(RegExp(r'[^0-9]'), '')) ?? 0)
        .toList();
    final pa = parse(a);
    final pb = parse(b);
    final len = pa.length > pb.length ? pa.length : pb.length;
    for (var i = 0; i < len; i++) {
      final x = i < pa.length ? pa[i] : 0;
      final y = i < pb.length ? pb[i] : 0;
      if (x != y) return x - y;
    }
    return 0;
  }

  /// 把 `{repo}` 占位展开。
  static String expandUrl(String template) =>
      template.replaceAll('{repo}', repoSlug);

  /// 用户手填的地址是否可用（用于设置项校验）。
  static bool isValidCustomUrl(String raw) {
    final v = raw.trim();
    if (v.isEmpty) return true; // 空 = 恢复默认，合法
    final uri = Uri.tryParse(expandUrl(v));
    if (uri == null) return false;
    return (uri.scheme == 'http' || uri.scheme == 'https') && uri.host.isNotEmpty;
  }

  void _log(String message) => logger?.call(message);

  /// 执行一次检测。[currentVersion] 为本机版本号（如 `2.1.7`）。
  ///
  /// **不抛异常**：任何失败都体现为返回值的 [UpdateCheckResult.error]。
  Future<UpdateCheckResult> check(String currentVersion) async {
    final sw = Stopwatch()..start();
    final cur = currentVersion.trim();

    // 旧实现拿不到版本号时会走进 latest ⇒ 谎报「已是最新」。这里显式报错。
    if (cur.isEmpty) {
      const detail = 'current version unavailable';
      _log('[update] FAIL versionUnknown: $detail');
      return UpdateCheckResult(
        error: UpdateCheckError.versionUnknown,
        channel: UpdateChannel.githubApi,
        detail: detail,
        elapsed: sw.elapsed,
      );
    }

    try {
      return await _run(cur, sw).timeout(totalTimeout);
    } on TimeoutException {
      final detail = 'total timeout ${totalTimeout.inSeconds}s';
      _log('[update] FAIL timeout: $detail');
      return UpdateCheckResult(
        error: UpdateCheckError.timeout,
        detail: detail,
        elapsed: sw.elapsed,
      );
    } on _Failure catch (f) {
      _log('[update] FAIL ${f.error.name}: ${f.detail}');
      return UpdateCheckResult(
        error: f.error,
        httpStatus: f.httpStatus,
        detail: f.detail,
        elapsed: sw.elapsed,
      );
    } catch (e) {
      final err = _classify(e);
      _log('[update] FAIL ${err.name}: $e');
      return UpdateCheckResult(
        error: err,
        detail: '$e',
        elapsed: sw.elapsed,
      );
    }
  }

  Future<UpdateCheckResult> _run(String cur, Stopwatch sw) async {
    final custom = (apiUrlOverride ?? '').trim();
    final attempts = <_Attempt>[
      if (custom.isNotEmpty)
        _Attempt(UpdateChannel.custom, expandUrl(custom)),
      _Attempt(UpdateChannel.githubApi, expandUrl(apiUrl)),
      // 自定义源模式下不再叠网页通道（自定义源本来就是为了绕开 GitHub 的不可达）
      if (custom.isEmpty && webUrl != null && webUrl!.trim().isNotEmpty)
        _Attempt(UpdateChannel.githubWeb, webUrl!.trim()),
    ];

    _Failure? last;
    for (var i = 0; i < attempts.length; i++) {
      final a = attempts[i];
      try {
        return await _attempt(a, cur, sw, usedFallback: i > 0);
      } on _Failure catch (f) {
        last = f;
        _log('[update] channel ${a.channel.name} failed: '
            '${f.error.name} (${f.detail})');
      }
    }
    throw last ?? const _Failure(UpdateCheckError.unknown, null, 'no attempt');
  }

  Future<UpdateCheckResult> _attempt(
    _Attempt a,
    String cur,
    Stopwatch sw, {
    required bool usedFallback,
  }) async {
    final client = HttpClient()..connectionTimeout = connectTimeout;
    try {
      await _applyProxy(client);

      final req = await client.getUrl(Uri.parse(a.url)).timeout(responseTimeout);
      req.headers.set(HttpHeaders.acceptHeader, 'application/vnd.github+json');
      req.headers.set(HttpHeaders.userAgentHeader, 'ZenFile-Update-Checker');
      if (a.channel == UpdateChannel.githubWeb) {
        // 只想知道「最新 tag 是什么」⇒ 不跟随重定向，直接读 Location
        req.followRedirects = false;
      }
      final resp = await req.close().timeout(responseTimeout);

      if (a.channel == UpdateChannel.githubWeb) {
        return await _parseWebRedirect(resp, a, cur, sw, usedFallback);
      }

      if (resp.statusCode == 403 || resp.statusCode == 429) {
        final remaining = resp.headers.value('x-ratelimit-remaining');
        await _drain(resp);
        throw _Failure(
          (resp.statusCode == 429 || remaining == '0')
              ? UpdateCheckError.rateLimited
              : UpdateCheckError.http,
          resp.statusCode,
          'HTTP ${resp.statusCode}, x-ratelimit-remaining=$remaining',
        );
      }
      if (resp.statusCode != 200) {
        await _drain(resp);
        throw _Failure(UpdateCheckError.http, resp.statusCode,
            'HTTP ${resp.statusCode}');
      }

      final body = await _readBody(resp);
      return _parseApi(body, a, cur, sw, usedFallback);
    } on _Failure {
      rethrow;
    } on TimeoutException catch (e) {
      throw _Failure(UpdateCheckError.timeout, null, '$e');
    } catch (e) {
      throw _Failure(_classify(e), null, '$e');
    } finally {
      // force：超时后必须真正断开，否则底层 socket 会一直挂着
      client.close(force: true);
    }
  }

  /// 读响应体 —— **必须带超时**（旧实现漏在这里，导致「永远转圈」）。
  Future<String> _readBody(HttpClientResponse resp) async {
    try {
      return await resp.transform(utf8.decoder).join().timeout(bodyTimeout);
    } on TimeoutException {
      throw _Failure(
        UpdateCheckError.timeout,
        null,
        'body timeout ${bodyTimeout.inSeconds}s',
      );
    }
  }

  /// 丢弃响应体（失败分支），同样限时，避免小 body 拖死连接。
  Future<void> _drain(HttpClientResponse resp) async {
    try {
      await resp.drain<void>().timeout(bodyTimeout);
    } catch (_) {
      // 丢弃失败无所谓，连接马上会 close(force)
    }
  }

  UpdateCheckResult _parseApi(
    String body,
    _Attempt a,
    String cur,
    Stopwatch sw,
    bool usedFallback,
  ) {
    Map<String, dynamic> json;
    try {
      json = jsonDecode(body) as Map<String, dynamic>;
    } catch (e) {
      throw _Failure(UpdateCheckError.malformed, 200, 'bad json: $e');
    }
    final tag = (json['tag_name'] as String? ?? '').trim();
    if (tag.isEmpty) {
      throw const _Failure(UpdateCheckError.malformed, 200, 'empty tag_name');
    }
    final assets = <UpdateAsset>[
      for (final x in (json['assets'] as List? ?? const []))
        if (x is Map && x['name'] is String && x['browser_download_url'] is String)
          UpdateAsset(
            name: x['name'] as String,
            url: x['browser_download_url'] as String,
          ),
    ];
    final page = (json['html_url'] as String? ?? '').trim();
    return _ok(
      tag: tag,
      pageUrl: page.isNotEmpty ? page : _fallbackPageUrl,
      assets: assets,
      channel: a.channel,
      cur: cur,
      sw: sw,
      usedFallback: usedFallback,
      detail: 'api ok, ${assets.length} asset(s)',
    );
  }

  Future<UpdateCheckResult> _parseWebRedirect(
    HttpClientResponse resp,
    _Attempt a,
    String cur,
    Stopwatch sw,
    bool usedFallback,
  ) async {
    final code = resp.statusCode;
    final isRedirect = code == 301 || code == 302 || code == 303 ||
        code == 307 || code == 308;
    if (!isRedirect) {
      final loc = resp.headers.value('location') ?? '';
      await _drain(resp);
      if (code == 403 || code == 429) {
        throw _Failure(UpdateCheckError.rateLimited, code,
            'web HTTP $code loc=$loc');
      }
      throw _Failure(UpdateCheckError.http, code, 'web HTTP $code');
    }
    final location = (resp.headers.value('location') ?? '').trim();
    await _drain(resp);
    final tag = tagFromLocation(location);
    if (tag.isEmpty) {
      throw _Failure(UpdateCheckError.malformed, code,
          'no tag in Location: $location');
    }
    return _ok(
      tag: tag,
      pageUrl: location.startsWith('http') ? location : _webUrlOrPage,
      assets: const <UpdateAsset>[],
      channel: a.channel,
      cur: cur,
      sw: sw,
      usedFallback: usedFallback,
      detail: 'web 302 ok (no assets on this channel)',
    );
  }

  /// 从 `https://github.com/owner/repo/releases/tag/v2.1.7` 里取 tag。
  static String tagFromLocation(String location) {
    final m = RegExp(r'/releases/tag/([^/?#]+)').firstMatch(location);
    if (m == null) return '';
    return Uri.decodeComponent(m.group(1)!).trim();
  }

  UpdateCheckResult _ok({
    required String tag,
    required String pageUrl,
    required List<UpdateAsset> assets,
    required UpdateChannel channel,
    required String cur,
    required Stopwatch sw,
    required bool usedFallback,
    required String detail,
  }) {
    final hasUpdate = compareVersions(tag, cur) > 0;
    _log('[update] OK channel=${channel.name} remote=$tag local=$cur '
        'hasUpdate=$hasUpdate fallback=$usedFallback '
        '${sw.elapsedMilliseconds}ms');
    return UpdateCheckResult(
      hasUpdate: hasUpdate,
      remoteVersion: tag,
      pageUrl: pageUrl,
      assets: assets,
      channel: channel,
      usedFallback: usedFallback,
      elapsed: sw.elapsed,
      detail: detail,
    );
  }

  String get _webUrlOrPage {
    final w = (webUrl ?? '').trim();
    return w.isNotEmpty ? w : defaultWebUrl;
  }

  String get _fallbackPageUrl {
    final w = (webUrl ?? '').trim();
    return w.isNotEmpty ? w : defaultWebUrl;
  }

  Future<void> _applyProxy(HttpClient client) async {
    final provider = httpProxyProvider;
    if (provider == null) return;
    try {
      final value = await provider().timeout(const Duration(seconds: 2));
      final hostPort = (value ?? '').trim();
      if (hostPort.isEmpty) return;
      client.findProxy = (uri) => 'PROXY $hostPort';
      _log('[update] using system proxy $hostPort');
    } catch (e) {
      _log('[update] proxy lookup failed, direct: $e');
    }
  }

  /// 异常 → 失败分类。
  ///
  /// 注意：`HttpException` 归到 [UpdateCheckError.network] —— 服务端**明确返回**
  /// 错误码的情况我们已主动抛 `_Failure(http, …)`，所以走到这里的 `HttpException`
  /// 只可能是底层传输（如 `Connection closed before full header was received`）。
  static UpdateCheckError _classify(Object e) {
    if (e is TimeoutException) return UpdateCheckError.timeout;
    if (e is SocketException) return UpdateCheckError.network;
    if (e is HandshakeException) return UpdateCheckError.network;
    if (e is TlsException) return UpdateCheckError.network;
    if (e is HttpException) return UpdateCheckError.network;
    if (e is OSError) return UpdateCheckError.network;
    if (e is FormatException) return UpdateCheckError.malformed;
    return UpdateCheckError.unknown;
  }
}
