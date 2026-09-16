// FTP 浏览「偶尔要等很久」的回归测试。
//
// 背景（2026-09-16）：用户反馈 FTP 客户端浏览/返回上级时偶尔要等很久，其它三个
// 客户端（SFTP/SMB/WebDAV）正常。定位到三条独立根因，本文件逐条钉住：
//
//   ① 上游 ftpconnect 的 `readResponse` 用固定 300ms 轮询 `RawSocket.available()`，
//      而 `sendCommand` 是「写完命令立刻读响应」→ **每条命令恒定白等 300ms**。
//      一次目录列举 = CWD + PASV + MLSD + 226 共 4 条 → ≈1.2s。
//      已在 plugins/ftpconnect 打补丁（2ms 粒度 + 静默窗口）。
//      → 用例「目录列举不再有每条命令 300ms 的固定白等」
//
//   ② 连接被服务端/中间设备按空闲超时静默回收（TCP 半开）后，客户端在死连接上
//      发 CWD 会白等满一个命令超时（上游 15s），紧接着重连前的 `disconnect()`
//      里 `QUIT` 又要等满 15s → **一次「进入目录」≈30s**。
//      修复：保活 NOOP + 失效探测 + 快速重连（不再等 QUIT 响应）。
//      → 用例「空闲连接被静默回收后…快速恢复」
//
//   ③ 依赖同一条控制连接的多个操作（list / delete / mkdir / rename / size）
//      并发时请求-响应序列会交错，响应错位进而掉进 ② 的重连长路径。
//      修复：全部纳入同一串行队列。
//      → 用例「并发列目录严格串行，不产生请求-响应交错」
//
// 测试用本机 mock FTP 服务端（真实 socket）驱动**生产代码**，不依赖真机或远程
// 服务器，也不需要 adb（本项目开发机无法用无线 adb）。

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zenfile/services/remote/ftp_client.dart';

/// 极简 FTP 服务端：只实现浏览路径用到的命令（USER/PASS/TYPE/CWD/PASV/MLSD/
/// NOOP/QUIT），足以驱动 FtpRemoteClient 的 listDirectory 全流程。
class MockFtpServer {
  ServerSocket? _server;
  final List<Socket> _sockets = [];

  int get port => _server!.port;

  /// 收到的命令名（按到达顺序）。
  final List<String> commands = [];

  /// 目录 → MLSD 行（不含 CRLF）。
  final Map<String, List<String>> dirs = {};

  /// true = 服务端把连接**静默回收**：收到任何命令都不响应，并立即销毁该连接
  /// （等价于对端消失 / TCP 半开）。这是真实世界里空闲连接被防火墙/NAT 丢弃的
  /// 行为：客户端写入不报错，但永远等不到响应。
  bool silent = false;

  /// 请求-响应交错违例计数：若一条命令到达时前一条尚未处理完，即计一次。
  int interleavedCount = 0;

  Future<void> start() async {
    _server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    _server!.listen((s) {
      _sockets.add(s);
      _handleControl(s);
    });
  }

  Future<void> stop() async {
    for (final s in _sockets) {
      try {
        s.destroy();
      } catch (_) {}
    }
    _sockets.clear();
    await _server?.close();
    _server = null;
  }

  void _handleControl(Socket s) {
    final buffer = <int>[];
    var cwd = '/';
    ServerSocket? dataServer;
    var pending = 0;
    var queue = Future<void>.value();

    // 欢迎语：客户端 connect() 后立刻等待这一行。
    s.write('220 ZenFile Mock FTP ready\r\n');

    Future<void> reply(String line) async {
      if (silent) return;
      s.write('$line\r\n');
      await s.flush();
    }

    Future<void> dispatch(String cmd) async {
      final name = cmd.split(' ').first.toUpperCase();
      // 无论是否静默都记录：静默回收期间的命令也必须可观测（例如保活 NOOP）。
      commands.add(name);
      if (silent) {
        // 静默回收：直接销毁连接，客户端会在命令超时后判定连接失效。
        s.destroy();
        return;
      }
      final arg = cmd.length > name.length ? cmd.substring(name.length + 1) : '';

      switch (name) {
        case 'USER':
          return reply('331 User name okay, need password');
        case 'PASS':
          return reply('230 Login successful');
        case 'TYPE':
          return reply('200 Type set to I');
        case 'NOOP':
          return reply('200 NOOP okay');
        case 'PWD':
          return reply('257 "/" is current directory');
        case 'SIZE':
          return reply('213 42');
        case 'CWD':
          cwd = arg.trim().isEmpty ? '/' : arg.trim();
          return reply('250 Directory changed to $cwd');
        case 'PASV':
          dataServer = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
          final p = dataServer!.port;
          return reply(
              '227 Entering Passive Mode (127,0,0,1,${p >> 8},${p & 0xff})');
        case 'MLSD':
          final ds = dataServer;
          if (ds == null) return reply('425 Use PASV first');
          await reply('150 Opening data connection');
          final data = await ds.first.timeout(const Duration(seconds: 5));
          final lines = dirs[cwd] ?? const <String>[];
          data.write(lines.map((l) => '$l\r\n').join());
          await data.flush();
          await data.close();
          await ds.close();
          dataServer = null;
          return reply('226 Transfer complete');
        case 'QUIT':
          await reply('221 Bye');
          s.destroy();
          return;
        default:
          return reply('500 Unknown command');
      }
    }

    s.listen((data) {
      buffer.addAll(data);
      while (true) {
        final idx = _crlfIndex(buffer);
        if (idx < 0) break;
        final cmd = utf8.decode(buffer.sublist(0, idx));
        buffer.removeRange(0, idx + 2);
        // 客户端应当严格「一条命令 → 等响应 → 下一条」。若上一条尚未处理完
        // 就收到下一条，说明请求-响应序列被交错（旧实现的并发缺陷）。
        if (pending > 0) interleavedCount++;
        pending++;
        queue = queue
            .then((_) => dispatch(cmd))
            .catchError((_) {})
            .whenComplete(() => pending--);
      }
    }, onError: (_) {}, onDone: () {});
  }

  int _crlfIndex(List<int> b) {
    for (var i = 0; i + 1 < b.length; i++) {
      if (b[i] == 13 && b[i + 1] == 10) return i;
    }
    return -1;
  }
}

void main() {
  late MockFtpServer server;
  late FtpRemoteClient client;

  // 注入极短的时序参数，让「保活探测 → 超时 → 标记失效 → 快速重连」在测试中
  // 秒级可观测（生产值见 FtpRemoteClient 顶部的 static Duration 定义）。
  setUp(() async {
    FtpRemoteClient.keepAliveInterval = const Duration(milliseconds: 200);
    FtpRemoteClient.idleProbeAfter = const Duration(milliseconds: 100);
    FtpRemoteClient.probeTimeout = const Duration(milliseconds: 400);
    FtpRemoteClient.commandTimeout = const Duration(seconds: 2);
    FtpRemoteClient.reconnectCooldown = Duration.zero;

    server = MockFtpServer();
    server.dirs['/'] = [
      'type=file;size=10;modify=20260916120000;readme.txt',
      'type=dir;modify=20260916120000;sub',
    ];
    server.dirs['/sub'] = ['type=file;size=20;modify=20260916120000;inner.bin'];
    await server.start();

    client = FtpRemoteClient(
      host: '127.0.0.1',
      port: server.port,
      username: 'u',
      password: 'p',
    );
    await client.connect();
  });

  tearDown(() async {
    await client.disconnect();
    await server.stop();
    FtpRemoteClient.keepAliveInterval = const Duration(seconds: 20);
    FtpRemoteClient.idleProbeAfter = const Duration(seconds: 20);
    FtpRemoteClient.probeTimeout = const Duration(seconds: 4);
    FtpRemoteClient.commandTimeout = const Duration(seconds: 10);
    FtpRemoteClient.reconnectCooldown = const Duration(seconds: 3);
  });

  test('目录列举不再有每条命令 300ms 的固定白等', () async {
    // 预热一次（首次调用可能包含握手后的首条命令）
    await client.listDirectory('/');

    final sw = Stopwatch()..start();
    final items = await client.listDirectory('/');
    sw.stop();

    expect(items.map((e) => e.name).toList()..sort(), ['readme.txt', 'sub']);
    expect(items.firstWhere((e) => e.name == 'sub').isDirectory, isTrue);
    expect(items.firstWhere((e) => e.name == 'readme.txt').size, 10);

    // 旧实现：一次列举 4 条命令 × 300ms 固定白等 ≈1.2s，单次必然 > 300ms。
    // 修复后本机为个位数~数十毫秒（留足余量，避免 CI 抖动误报）。
    expect(sw.elapsedMilliseconds, lessThan(300),
        reason: '单次目录列举耗时 ${sw.elapsedMilliseconds}ms，疑似 300ms 轮询白等回归');
  });

  test('连续多次列举的总耗时不随命令数线性膨胀', () async {
    await client.listDirectory('/');

    final sw = Stopwatch()..start();
    for (var i = 0; i < 6; i++) {
      final items = await client.listDirectory('/');
      expect(items.length, 2);
    }
    sw.stop();

    // 旧实现 6 次 ≈7.2s（48 条命令 × 300ms）。
    expect(sw.elapsedMilliseconds, lessThan(1200),
        reason: '6 次目录列举耗时 ${sw.elapsedMilliseconds}ms');
  });

  test('空闲连接被服务端静默回收后，能在秒级内恢复而不是赔满命令超时', () async {
    // 先确认连接可用
    expect((await client.listDirectory('/')).length, 2);

    // 模拟服务端/中间设备把空闲连接悄悄回收（TCP 半开）
    server.silent = true;

    // 等保活探测触发并判定连接失效：keepAliveInterval(200ms) + probeTimeout(400ms)
    await Future.delayed(const Duration(milliseconds: 1200));
    expect(server.commands.contains('NOOP'), isTrue,
        reason: '保活探测未发出 NOOP，空闲连接会一直被服务端回收');

    // 服务端恢复（此时旧连接已死，只能靠重连拿到可用连接）
    server.silent = false;

    final sw = Stopwatch()..start();
    final items = await client.listDirectory('/');
    sw.stop();

    expect(items.length, 2);
    // 关键：不应撞上 commandTimeout(测试注入 2s) 的命令级白等。
    // 旧实现是「15s 命令超时 + 15s QUIT 白等」，本用例注入值下也会 > 2s。
    expect(sw.elapsedMilliseconds, lessThan(1500),
        reason: '断连恢复耗时 ${sw.elapsedMilliseconds}ms，疑似撞上命令级超时白等');
  });

  test('空转时不发无效请求；有真实流量时不做多余保活', () async {
    await client.listDirectory('/');
    await Future.delayed(const Duration(milliseconds: 1000));
    final noops = server.commands.where((c) => c == 'NOOP').length;

    // 保活按 keepAliveInterval(200ms) 触发，且每次探测都是短超时，数量应远小于
    // 「每 tick 都发」的上限（1000/200 = 5）；CWD/PASV/MLSD 不应被保活淹没。
    expect(noops, greaterThan(0));
    expect(noops, lessThanOrEqualTo(9));
  });

  test('并发列目录严格串行，不产生请求-响应交错', () async {
    server.interleavedCount = 0;

    final results = await Future.wait([
      client.listDirectory('/'),
      client.listDirectory('/sub'),
      client.listDirectory('/'),
      client.listDirectory('/sub'),
    ]);

    expect(server.interleavedCount, 0,
        reason: '检测到请求-响应交错，说明存在并发使用同一控制连接的操作');
    expect(results[0].length, 2);
    expect(results[1].length, 1);
    expect(results[1].single.name, 'inner.bin');
    expect(results[2].length, 2);
    expect(results[3].single.name, 'inner.bin');
  });

  test('目录枚举结果在 CWD 漂移风险下依然正确（返回上级/再次进入）', () async {
    final sub = await client.listDirectory('/sub');
    expect(sub.single.name, 'inner.bin');

    final root = await client.listDirectory('/');
    expect(root.map((e) => e.name).toList()..sort(), ['readme.txt', 'sub']);

    final subAgain = await client.listDirectory('/sub');
    expect(subAgain.single.name, 'inner.bin');
  });
}
