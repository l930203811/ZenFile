// GitHub 版本检测（UpdateCheckService）的回归测试。
//
// 为什么要这批测试：旧实现把检测逻辑写在 `_UpdateScreenState` 里，于是
// ① 没有真实新版本时无法验证「发现新版本」整条链路；
// ② 失败原因分不出来（所有异常都是同一句提示）；
// ③ 「永远转圈」这种故障无法复现。
// 这里用**本机真实 HttpServer** 造假响应驱动生产代码（与 ftp_client_resilience_test
// 同一套路），不依赖真机、不依赖发版、不需要 GitHub 真的存在新 tag。
//
// 逐条钉住的不变式：
//   * 读响应体**必须有超时** —— 只给 getUrl/close 加超时是不够的，国内最常见的
//     故障是「头回来了、体永远不来」，旧实现会永远停在「正在检查更新…」；
//   * 全链路**不抛异常**，任何失败都体现为 `result.error`；
//   * 拿不到本机版本号时**不许谎报「已是最新」**，且**不该联网**；
//   * 降级链：自定义源 → 官方 API → 网页 302；每级失败都要自动落到下一级；
//   * 失败要能**分类**（限速 / 网络 / 超时 / HTTP / 解析），否则给不出有指导性的文案。

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zenfile/services/update_check_service.dart';

/// 起一个本机假服务端。返回 server（端口用 `server.port`）。
Future<HttpServer> _serve(
  Future<void> Function(HttpRequest req) handler,
) async {
  final srv = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  srv.listen((req) async {
    try {
      await handler(req);
    } catch (_) {
      // 客户端提前断开（超时用例）会在写回时抛，忽略
      try {
        await req.response.close();
      } catch (_) {}
    }
  });
  return srv;
}

/// 写一个 JSON 响应并结束。
Future<void> _json(
  HttpRequest req, {
  int status = 200,
  Object? body,
  Map<String, String> headers = const {},
}) async {
  req.response.statusCode = status;
  req.response.headers.contentType = ContentType.json;
  headers.forEach((k, v) => req.response.headers.set(k, v));
  req.response.write(body == null ? '{}' : jsonEncode(body));
  await req.response.close();
}

/// 标准 release JSON。
Map<String, Object> _release(
  String tag, {
  List<Map<String, String>> assets = const [],
}) =>
    {
      'tag_name': tag,
      'html_url': 'https://github.com/l930203811/ZenFile/releases/tag/$tag',
      'assets': assets,
    };

String _apiUrl(HttpServer s) => 'http://127.0.0.1:${s.port}/releases/latest';

void main() {
  group('UpdateCheckService · 成功路径', () {
    test('远端与本地同版本 → latest，且带回远端 tag（用户可据此自证真的联网了）',
        () async {
      final srv = await _serve((req) async => _json(req, body: _release('v2.1.7')));
      addTearDown(() => srv.close(force: true));

      final r = await UpdateCheckService(apiUrl: _apiUrl(srv), webUrl: null)
          .check('2.1.7');

      expect(r.ok, isTrue, reason: r.detail);
      expect(r.hasUpdate, isFalse);
      expect(r.remoteVersion, 'v2.1.7');
      expect(r.channel, UpdateChannel.githubApi);
      expect(r.usedFallback, isFalse);
    });

    test('远端版本更高 → hasUpdate（**没有真实新版本也能验证这条链路**）', () async {
      final srv = await _serve((req) async => _json(
            req,
            body: _release('v9.9.9', assets: [
              {
                'name': 'ZenFile_v9.9.9-arm64-v8a-release.apk',
                'browser_download_url': 'https://example.com/a.apk',
              },
            ]),
          ));
      addTearDown(() => srv.close(force: true));

      final r = await UpdateCheckService(apiUrl: _apiUrl(srv), webUrl: null)
          .check('2.1.7');

      expect(r.ok, isTrue, reason: r.detail);
      expect(r.hasUpdate, isTrue);
      expect(r.remoteVersion, 'v9.9.9');
      expect(r.assets, hasLength(1));
      expect(r.assets.first.name, contains('arm64-v8a'));
    });

    test('版本号比较：v 前缀 / 位数不齐 / 相等都正确', () {
      expect(UpdateCheckService.compareVersions('v2.1.9', '2.1.7') > 0, isTrue);
      expect(UpdateCheckService.compareVersions('2.2', '2.1.7') > 0, isTrue);
      expect(UpdateCheckService.compareVersions('2.1.7', '2.1.7'), 0);
      expect(UpdateCheckService.compareVersions('2.0.10', '2.0.9') > 0, isTrue);
      expect(UpdateCheckService.compareVersions('1.9.9', '2.0.0') < 0, isTrue);
    });
  });

  group('UpdateCheckService · 失败分类', () {
    test('403 + x-ratelimit-remaining: 0 → rateLimited（GitHub 限速）', () async {
      final srv = await _serve((req) async => _json(
            req,
            status: 403,
            headers: {'x-ratelimit-remaining': '0'},
            body: {'message': 'API rate limit exceeded'},
          ));
      addTearDown(() => srv.close(force: true));

      final r = await UpdateCheckService(apiUrl: _apiUrl(srv), webUrl: null)
          .check('2.1.7');

      expect(r.error, UpdateCheckError.rateLimited);
      expect(r.hasUpdate, isFalse, reason: '失败绝不能被当成「已是最新」');
    });

    test('403 但不是限速 → http（不能一律说成「请求频繁」）', () async {
      final srv = await _serve((req) async => _json(
            req,
            status: 403,
            headers: {'x-ratelimit-remaining': '55'},
          ));
      addTearDown(() => srv.close(force: true));

      final r = await UpdateCheckService(apiUrl: _apiUrl(srv), webUrl: null)
          .check('2.1.7');

      expect(r.error, UpdateCheckError.http);
      expect(r.httpStatus, 403);
    });

    test('500 → http 且带回状态码（文案里要能显示 HTTP 码）', () async {
      final srv = await _serve((req) async => _json(req, status: 500));
      addTearDown(() => srv.close(force: true));

      final r = await UpdateCheckService(apiUrl: _apiUrl(srv), webUrl: null)
          .check('2.1.7');

      expect(r.error, UpdateCheckError.http);
      expect(r.httpStatus, 500);
    });

    test('响应头回来了但 body 永远不来 → timeout（旧实现会永远停在「正在检查更新…」）',
        () async {
      final srv = await _serve((req) async {
        req.response.statusCode = 200;
        req.response.write('{"tag_name":'); // 半个 body
        await req.response.flush(); // 头 + 半个体已经发出去
        // 故意不 close ⇒ 客户端读不到「流结束」，join() 会一直挂
        await Future<void>.delayed(const Duration(seconds: 30));
      });
      addTearDown(() => srv.close(force: true));

      final r = await UpdateCheckService(
        apiUrl: _apiUrl(srv),
        webUrl: null,
        bodyTimeout: const Duration(milliseconds: 400),
        responseTimeout: const Duration(seconds: 5),
        totalTimeout: const Duration(seconds: 8),
      ).check('2.1.7');

      expect(r.error, UpdateCheckError.timeout, reason: r.detail);
    });

    test('整次检测有总上限（多个通道都慢也不能无限等）', () async {
      Future<void> slow(HttpRequest req) async {
        await Future<void>.delayed(const Duration(seconds: 20));
      }

      final a = await _serve(slow);
      final b = await _serve(slow);
      addTearDown(() => a.close(force: true));
      addTearDown(() => b.close(force: true));

      final sw = Stopwatch()..start();
      final r = await UpdateCheckService(
        apiUrl: _apiUrl(a),
        webUrl: _apiUrl(b),
        connectTimeout: const Duration(seconds: 5),
        responseTimeout: const Duration(seconds: 5),
        bodyTimeout: const Duration(seconds: 5),
        totalTimeout: const Duration(milliseconds: 700),
      ).check('2.1.7');
      sw.stop();

      expect(r.error, UpdateCheckError.timeout, reason: r.detail);
      expect(sw.elapsed, lessThan(const Duration(seconds: 4)),
          reason: '总上限必须真的生效，不能被单通道超时拖长');
    });

    test('端口无人监听 → network（连接失败 / 被拒）', () async {
      // 先占一个端口再释放，得到一个「确定没人监听」的端口
      final probe = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final deadPort = probe.port;
      await probe.close(force: true);

      final r = await UpdateCheckService(
        apiUrl: 'http://127.0.0.1:$deadPort/releases/latest',
        webUrl: null,
      ).check('2.1.7');

      expect(r.error, UpdateCheckError.network, reason: r.detail);
    });

    test('tag_name 为空 → malformed', () async {
      final srv = await _serve((req) async => _json(req, body: {'tag_name': '  '}));
      addTearDown(() => srv.close(force: true));

      final r = await UpdateCheckService(apiUrl: _apiUrl(srv), webUrl: null)
          .check('2.1.7');

      expect(r.error, UpdateCheckError.malformed, reason: r.detail);
    });

    test('响应不是 JSON → malformed（比如被劫持返回了一个 HTML 页面）', () async {
      final srv = await _serve((req) async {
        req.response.statusCode = 200;
        req.response.headers.contentType = ContentType.html;
        req.response.write('<html>blocked</html>');
        await req.response.close();
      });
      addTearDown(() => srv.close(force: true));

      final r = await UpdateCheckService(apiUrl: _apiUrl(srv), webUrl: null)
          .check('2.1.7');

      expect(r.error, UpdateCheckError.malformed, reason: r.detail);
    });

    test('拿不到本机版本号 → versionUnknown，**且完全不联网**（旧实现会谎报「已是最新」）',
        () async {
      var hits = 0;
      final srv = await _serve((req) async {
        hits++;
        await _json(req, body: _release('v2.1.7'));
      });
      addTearDown(() => srv.close(force: true));

      final r = await UpdateCheckService(apiUrl: _apiUrl(srv), webUrl: null)
          .check('');

      expect(r.error, UpdateCheckError.versionUnknown, reason: r.detail);
      expect(r.hasUpdate, isFalse);
      expect(r.remoteVersion, isEmpty);
      expect(hits, 0, reason: '版本号都不知道，联网比对没有意义');
    });
  });

  group('UpdateCheckService · 降级链与自定义源', () {
    test('官方 API 失败 → 自动降级到网页 302 通道（拿到 tag，但没有 assets）',
        () async {
      final api = await _serve((req) async => _json(req, status: 500));
      final web = await _serve((req) async {
        // github.com/.../releases/latest 的真实行为：302 → /releases/tag/<tag>
        req.response.statusCode = 302;
        req.response.headers.set(
            'location', 'https://github.com/l930203811/ZenFile/releases/tag/v3.0.0');
        await req.response.close();
      });
      addTearDown(() => api.close(force: true));
      addTearDown(() => web.close(force: true));

      final r = await UpdateCheckService(
        apiUrl: _apiUrl(api),
        webUrl: _apiUrl(web),
      ).check('2.1.7');

      expect(r.ok, isTrue, reason: r.detail);
      expect(r.channel, UpdateChannel.githubWeb);
      expect(r.usedFallback, isTrue);
      expect(r.remoteVersion, 'v3.0.0');
      expect(r.hasUpdate, isTrue);
      expect(r.assets, isEmpty, reason: '网页通道拿不到 assets，只能跳浏览器');
    });

    test('自定义源可用时优先走它，且不再碰官方源', () async {
      var officialHits = 0;
      final custom = await _serve(
          (req) async => _json(req, body: _release('v2.1.8')));
      final official = await _serve((req) async {
        officialHits++;
        await _json(req, body: _release('v1.0.0'));
      });
      addTearDown(() => custom.close(force: true));
      addTearDown(() => official.close(force: true));

      final r = await UpdateCheckService(
        apiUrlOverride: _apiUrl(custom),
        apiUrl: _apiUrl(official),
        webUrl: null,
      ).check('2.1.7');

      expect(r.ok, isTrue, reason: r.detail);
      expect(r.channel, UpdateChannel.custom);
      expect(r.usedFallback, isFalse);
      expect(r.remoteVersion, 'v2.1.8');
      expect(officialHits, 0);
    });

    test('自定义源挂了 → 仍回退官方源（镜像挂了不能让用户彻底查不到更新）', () async {
      final custom = await _serve((req) async => _json(req, status: 502));
      final official =
          await _serve((req) async => _json(req, body: _release('v2.1.9')));
      addTearDown(() => custom.close(force: true));
      addTearDown(() => official.close(force: true));

      final r = await UpdateCheckService(
        apiUrlOverride: _apiUrl(custom),
        apiUrl: _apiUrl(official),
        webUrl: null,
      ).check('2.1.7');

      expect(r.ok, isTrue, reason: r.detail);
      expect(r.channel, UpdateChannel.githubApi);
      expect(r.usedFallback, isTrue);
      expect(r.remoteVersion, 'v2.1.9');
    });

    test('自定义源地址支持 {repo} 占位（用户可填形如 .../repos/{repo}/releases/latest）',
        () {
      expect(
        UpdateCheckService.expandUrl('https://x.com/repos/{repo}/releases/latest'),
        'https://x.com/repos/l930203811/ZenFile/releases/latest',
      );
    });
  });

  group('UpdateCheckService · 输入校验与解析', () {
    test('自定义源地址校验：空合法（= 恢复默认），非 http(s) 或没 host 不合法', () {
      expect(UpdateCheckService.isValidCustomUrl(''), isTrue);
      expect(UpdateCheckService.isValidCustomUrl('   '), isTrue);
      expect(UpdateCheckService.isValidCustomUrl('https://a.com/x'), isTrue);
      expect(UpdateCheckService.isValidCustomUrl('http://a.com/{repo}'), isTrue);
      expect(UpdateCheckService.isValidCustomUrl('a.com/x'), isFalse);
      expect(UpdateCheckService.isValidCustomUrl('ftp://a.com/x'), isFalse);
      expect(UpdateCheckService.isValidCustomUrl('https://'), isFalse);
    });

    test('从 302 Location 里解析 tag（含 URL 编码）', () {
      expect(
        UpdateCheckService.tagFromLocation(
            'https://github.com/l930203811/ZenFile/releases/tag/v2.1.7'),
        'v2.1.7',
      );
      expect(
        UpdateCheckService.tagFromLocation(
            'https://github.com/o/r/releases/tag/v2.1.7?x=1'),
        'v2.1.7',
      );
      expect(UpdateCheckService.tagFromLocation('https://github.com/o/r'), isEmpty);
      expect(UpdateCheckService.tagFromLocation(''), isEmpty);
    });
  });
}
