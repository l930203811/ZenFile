import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:zenfile/services/remote/socks5_socket.dart';

/// SOCKS5 助手单测：本地起一个最小 SOCKS5 服务端（RFC 1928/1929 子集）+
/// 回显目标服务器，对 [Socks5Socket.connectViaSocks5] /
/// [Socks5Socket.connectRawViaSocks5] 做真实握手（无 mock，覆盖：
/// 无鉴权、用户名/口令鉴权、鉴权失败、CONNECT 拒绝、RawSocket 通道）。
void main() {
  group('Socks5Socket handshake', () {
    late ServerSocket target;
    late ServerSocket proxy;
    int targetPort = 0;
    int proxyPort = 0;
    String? expectedUser;
    String? expectedPass;

    /// 按 RFC 1928 处理一个客户端连接。
    /// 鉴权行为由 [expectedUser]/[expectedPass] 控制：非空则要求 0x02 方法
    /// 并校验凭据；CONNECT 的目标端口若等于 targetPort 则放通到目标，否则
    /// 回 REP=0x01（一般性失败）。
    Future<void> _serveSocks5(Socket client) async {
      // 单订阅缓冲读（Socket 流只允许 listen 一次；透传阶段复用同一订阅转发）
      final buf = <int>[];
      final dataReady = StreamController<void>.broadcast();
      Socket? upstream;
      final sub = client.listen(
        (chunk) {
          buf.addAll(chunk);
          // 握手完成后（upstream 已建立）：缓冲里的新字节直接透传
          if (upstream != null && buf.isNotEmpty) {
            upstream!.add(buf.toList());
            buf.clear();
          }
          dataReady.add(null);
        },
        onDone: () {
          upstream?.destroy();
          dataReady.close();
        },
        onError: (Object _) => dataReady.close(),
      );

      Future<Uint8List> read(int n) async {
        while (buf.length < n) {
          await dataReady.stream.first
              .timeout(const Duration(seconds: 5), onTimeout: () {
            throw StateError('fake socks5 server read timeout');
          });
        }
        final out = Uint8List.fromList(buf.sublist(0, n));
        buf.removeRange(0, n);
        return out;
      }

      // 1. greeting
      final greeting = await read(2);
      expect(greeting[0], 0x05);
      final nMethods = greeting[1];
      final methods = await read(nMethods);
      final wantsAuth = expectedUser != null;
      if (wantsAuth) {
        expect(methods.contains(0x02), isTrue, reason: '客户端应提供用户名/口令方法');
        client.add([0x05, 0x02]);
        // RFC 1929: VER ULEN UNAME PLEN PASSWD
        final auth = await read(1);
        expect(auth[0], 0x01);
        final ulen = (await read(1))[0];
        final uname = utf8.decode(await read(ulen));
        final plen = (await read(1))[0];
        final pass = utf8.decode(await read(plen));
        if (uname == expectedUser && pass == expectedPass) {
          client.add([0x01, 0x00]);
        } else {
          client.add([0x01, 0x01]);
          await client.flush();
          await client.close();
          await sub.cancel();
          return;
        }
      } else {
        expect(methods.contains(0x00), isTrue, reason: '客户端应提供无鉴权方法');
        client.add([0x05, 0x00]);
      }

      // 2. CONNECT
      final req = await read(4);
      expect(req[0], 0x05); // VER
      expect(req[1], 0x01); // CMD = CONNECT
      final atyp = req[3];
      String host;
      if (atyp == 0x03) {
        final len = (await read(1))[0];
        host = utf8.decode(await read(len));
      } else if (atyp == 0x01) {
        final ip = await read(4);
        host = ip.join('.');
      } else {
        client.add([0x05, 0x08, 0x00, 0x01, 0, 0, 0, 0, 0, 0]);
        await client.flush();
        await sub.cancel();
        return;
      }
      final portBytes = await read(2);
      final port = (portBytes[0] << 8) | portBytes[1];

      if (port != targetPort) {
        // 目标不可达：REP=0x01
        client.add([0x05, 0x01, 0x00, 0x01, 0, 0, 0, 0, 0, 0]);
        await client.flush();
        await client.close();
        await sub.cancel();
        return;
      }

      // 3. 成功应答（绑定地址随意填 0）
      client.add([0x05, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0, 0]);
      await client.flush();
      // 4. 透传到目标（域名 echo.internal 只在「代理侧」可解析 → 映射到本地回显服务）
      upstream = await Socket.connect(
          host == 'echo.internal' ? '127.0.0.1' : host, port);
      upstream!.listen((data) => client.add(data), onDone: () => client.destroy());
      // 转发握手期间已缓冲的残余字节（正常时序应为空）
      if (buf.isNotEmpty) {
        upstream!.add(buf.toList());
        buf.clear();
      }
    }


    setUpAll(() async {
      // 目标服务器：收到什么就回什么（回显）
      target = await ServerSocket.bind('127.0.0.1', 0);
      targetPort = target.port;
      target.listen((sock) {
        sock.listen((data) => sock.add(data));
      });

      // 最小 SOCKS5 服务端
      proxy = await ServerSocket.bind('127.0.0.1', 0);
      proxyPort = proxy.port;
      proxy.listen((sock) => _serveSocks5(sock));
    });

    tearDownAll(() async {
      await target.close();
      await proxy.close();
    });

    test('无鉴权：握手 + 经代理与目标双向收发（Socket 形态）', () async {
      expectedUser = null;
      expectedPass = null;

      final sock = await Socks5Socket.connectViaSocks5(
        proxyHost: '127.0.0.1',
        proxyPort: proxyPort,
        targetHost: 'echo.internal', // 域名形式，由代理解析
        targetPort: targetPort,
      );

      // 上层订阅（若握手吞了流数据，这里会抛 already listened）
      final received = <int>[];
      final done = Completer<void>();
      late final StreamSubscription<Uint8List> sub;
      sub = sock.listen((chunk) {
        received.addAll(chunk);
        if (received.length >= 5 && !done.isCompleted) done.complete();
      }, onDone: () {
        if (!done.isCompleted) done.complete();
      });

      sock.add(utf8.encode('hello'));
      await done.future.timeout(const Duration(seconds: 5));
      expect(utf8.decode(received), 'hello');
      await sub.cancel();
      sock.destroy();
    });

    test('用户名/口令鉴权成功（RFC 1929）', () async {
      expectedUser = 'alice';
      expectedPass = 's3cret';

      final sock = await Socks5Socket.connectViaSocks5(
        proxyHost: '127.0.0.1',
        proxyPort: proxyPort,
        targetHost: 'echo.internal',
        targetPort: targetPort,
        username: 'alice',
        password: 's3cret',
      );
      sock.add(utf8.encode('auth-ok'));
      final first = await sock.first.timeout(const Duration(seconds: 5));
      expect(utf8.decode(first), 'auth-ok');
      sock.destroy();
    });

    test('用户名/口令鉴权失败 → SocketException', () async {
      expectedUser = 'alice';
      expectedPass = 's3cret';

      await expectLater(
        Socks5Socket.connectViaSocks5(
          proxyHost: '127.0.0.1',
          proxyPort: proxyPort,
          targetHost: 'echo.internal',
          targetPort: targetPort,
          username: 'alice',
          password: 'wrong',
        ),
        throwsA(isA<SocketException>()),
      );
    });

    test('代理回 CONNECT 失败（REP=0x01）→ SocketException', () async {
      expectedUser = null;
      expectedPass = null;

      await expectLater(
        Socks5Socket.connectViaSocks5(
          proxyHost: '127.0.0.1',
          proxyPort: proxyPort,
          targetHost: 'echo.internal',
          targetPort: 1, // 非 targetPort → 假服务端回 REP=0x01
        ),
        throwsA(isA<SocketException>()),
      );
    });

    test('RawSocket 形态：握手 + 原始 read/write 透传', () async {
      expectedUser = null;
      expectedPass = null;

      final raw = await Socks5Socket.connectRawViaSocks5(
        proxyHost: '127.0.0.1',
        proxyPort: proxyPort,
        targetHost: 'echo.internal',
        targetPort: targetPort,
      );

      final received = <int>[];
      final done = Completer<void>();
      raw.listen((event) {
        if (event != RawSocketEvent.read) return;
        final chunk = raw.read();
        if (chunk != null) received.addAll(chunk);
        if (received.length >= 4 && !done.isCompleted) done.complete();
      });
      raw.write(Uint8List.fromList(utf8.encode('raw!')));
      await done.future.timeout(const Duration(seconds: 5));
      expect(utf8.decode(received), 'raw!');
      raw.close();
    });
  });
}
