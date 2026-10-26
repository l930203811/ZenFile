import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// 纯 Dart SOCKS5 客户端助手（无第三方依赖）。
///
/// 用途：让 FTP / WebDAV / SFTP(Dart 回退) 连接经 SOCKS5 代理出网，
/// 以访问「虚拟内网」里只有代理才可达的文件服务器。
///
/// 为什么自己写而不是用包：现成包（socks5_proxy 2.x）的
/// `assignToHttpClient` 内部用 `InternetAddress(uri.host, type: unix)` 当出口地址，
/// 对非 unix 目标有隐患；且逐连接代理需要完全可控的握手。SOCKS5 握手协议很短
/// （RFC 1928 + 用户名/口令扩展 RFC 1929），自实现既可靠又便于单测。
///
/// 出口主机名解析交给代理（`atyp=0x03` 域名），因此「内网主机只在代理侧可解析」
/// 的场景也能工作——这正是「虚拟内网网盘」的典型形态。
///
/// 两个入口的区别（⚠️ Dart 里 [RawSocket] **不是** [Socket] 的子类型，二者
/// 没有公开的互转 API，必须按调用方的 API 形态选入口）：
///  - [connectRawViaSocks5]：返回 [RawSocket]。ftpconnect fork 的控制连接
///    用 `read()/write()` 原始缓冲 API，需要这个形态。
///  - [connectViaSocks5]：返回实现 [Socket] 的 [Socks5TunnelSocket]。
///    `Socket` 是单订阅流：若直接在返回的 socket 上做握手读，握手期间对
///    流的订阅会让上层（HttpClient / `await for`）二次监听时报
///    "Stream has already been listened to"。因此握手读走
///    `asBroadcastStream()`，返回的包装类把 `stream` 暴露为广播流——
///    上层「首次监听」发生在广播流上，永远合法（与 socks5_proxy 包同思路）。
class Socks5Socket {
  Socks5Socket._();

  /// 经 SOCKS5 代理 [proxyHost]:[proxyPort] 建立到 [targetHost]:[targetPort] 的
  /// 透明 TCP 通道，返回已握完手的 [RawSocket]（对调用方而言就是一条直连目标的 socket）。
  ///
  /// 供 ftpconnect fork 的控制连接使用（其 API 形态为 RawSocket）。
  ///
  /// [username]/[password] 可选；提供时走 RFC 1929 用户名/口令鉴权。
  /// [timeout] 限定握手各阶段的等待（默认 15s）。
  static Future<RawSocket> connectRawViaSocks5({
    required String proxyHost,
    required int proxyPort,
    required String targetHost,
    required int targetPort,
    String? username,
    String? password,
    Duration timeout = const Duration(seconds: 15),
  }) async {
    final proxy = await RawSocket.connect(proxyHost, proxyPort, timeout: timeout);
    try {
      final reader = _RawSockReader(proxy, timeout);
      await _handshake(_SocksWriter.raw(proxy), reader, targetHost, targetPort,
          username: username, password: password);
      return proxy; // 握手完成：此 socket 已是到目标的透明通道
    } catch (e) {
      // 握手失败必须关闭代理连接，避免泄漏。
      try {
        proxy.close();
      } catch (_) {}
      rethrow;
    }
  }

  /// 经 SOCKS5 代理建立透明 TCP 通道，返回实现 [Socket] 的包装（已握完手）。
  ///
  /// 供 WebDAV（HttpClient.connectionFactory）、FTP 数据连接等以 [Socket]
  /// API 消费的调用方使用。HTTPS 目标由调用方拿到返回值后调
  /// [Socks5TunnelSocket.secureForTLS] 做 TLS 升级（`HttpClient` 设置了
  /// 自定义 `connectionFactory` 后**不会**自行完成 TLS 握手）。
  static Future<Socks5TunnelSocket> connectViaSocks5({
    required String proxyHost,
    required int proxyPort,
    required String targetHost,
    required int targetPort,
    String? username,
    String? password,
    Duration timeout = const Duration(seconds: 15),
  }) async {
    final proxy = await Socket.connect(proxyHost, proxyPort, timeout: timeout);
    try {
      // 广播流：握手期用它读；握手后包装类继续把 stream 暴露为该广播流，
      // 上层订阅广播流（首个订阅者）合法，且不会与握手读互相吞噬数据。
      final bcast = proxy.asBroadcastStream();
      final reader = _BcastSockReader(bcast, timeout);
      await _handshake(_SocksWriter.stream(proxy), reader, targetHost, targetPort,
          username: username, password: password);
      // 取消握手期订阅：asBroadcastStream 默认 onCancel 会 pause 底层订阅，
      // 后续到达的数据留在 OS 接收缓冲里，由上层订阅广播流后继续消费。
      await reader.dispose();
      return Socks5TunnelSocket(proxy, bcast);
    } catch (e) {
      try {
        proxy.destroy();
      } catch (_) {}
      rethrow;
    }
  }

  /// SOCKS5 握手共用协议流程（RFC 1928 + RFC 1929）。
  static Future<void> _handshake(
    _SocksWriter w,
    _SockReader reader,
    String targetHost,
    int targetPort, {
    String? username,
    String? password,
  }) async {
    // ── 1. 问候：SOCKS 版本 5 + 支持的方法列表 ──
    final useAuth = username != null && username.isNotEmpty;
    final methods = useAuth ? <int>[0x00, 0x02] : <int>[0x00];
    w.writeBytes(<int>[0x05, methods.length, ...methods]);
    final greeting = await reader.readExact(2);
    if (greeting[0] != 0x05) {
      throw const SocketException('SOCKS5 proxy returned unsupported version');
    }
    final selected = greeting[1];
    if (selected == 0x02) {
      // ── 2. 用户名 / 口令鉴权（RFC 1929）──
      final u = utf8.encode(username!);
      final p = utf8.encode(password ?? '');
      if (u.length > 255 || p.length > 255) {
        throw const SocketException('SOCKS5 proxy auth too long');
      }
      w.writeBytes(<int>[0x01, u.length, ...u, p.length, ...p]);
      final authReply = await reader.readExact(2);
      if (authReply[0] != 0x01 || authReply[1] != 0x00) {
        throw const SocketException('SOCKS5 proxy authentication failed');
      }
    } else if (selected != 0x00) {
      throw SocketException(
        'SOCKS5 proxy requires unsupported method 0x${selected.toRadixString(16)}',
      );
    }

    // ── 3. CONNECT 请求（域名形式，交给代理解析）──
    final hostBytes = utf8.encode(targetHost);
    if (hostBytes.length > 255) {
      throw const SocketException('SOCKS5 target host too long');
    }
    w.writeBytes(<int>[
      0x05, // VER
      0x01, // CMD = CONNECT
      0x00, // RSV
      0x03, // ATYP = 域名
      hostBytes.length,
      ...hostBytes,
      (targetPort >> 8) & 0xff,
      targetPort & 0xff,
    ]);

    // ── 4. 读取应答（VER REP RSV ATYP）──
    final rep = await reader.readExact(4);
    if (rep[0] != 0x05) {
      throw const SocketException('SOCKS5 proxy returned malformed reply');
    }
    if (rep[1] != 0x00) {
      throw SocketException(
        'SOCKS5 proxy CONNECT failed (code 0x${rep[1].toRadixString(16)})',
      );
    }

    // ── 5. 丢弃绑定地址 + 端口（调用方不需要）──
    final atyp = rep[3];
    int addrLen;
    if (atyp == 0x01) {
      addrLen = 4; // IPv4
    } else if (atyp == 0x04) {
      addrLen = 16; // IPv6
    } else if (atyp == 0x03) {
      final lenByte = await reader.readExact(1);
      addrLen = lenByte[0]; // 域名长度
    } else {
      throw SocketException(
          'SOCKS5 proxy returned unsupported ATYP 0x${atyp.toRadixString(16)}');
    }
    await reader.readExact(addrLen + 2);
  }
}

/// 握手期写侧抽象（RawSocket.write / Socket.add 两种形态）。
class _SocksWriter {
  final void Function(List<int> bytes) _send;
  _SocksWriter.raw(RawSocket s) : _send = ((b) => s.write(Uint8List.fromList(b)));
  _SocksWriter.stream(Socket s) : _send = s.add;
  void writeBytes(List<int> bytes) => _send(bytes);
}

/// 握手期读侧抽象（精确读 N 字节）。
abstract class _SockReader {
  Future<Uint8List> readExact(int n);
}

/// RawSocket 版：[RawSocket.read] 非阻塞，有数据返回字节、无数据返回 null。
/// 握手期代理响应通常毫秒级到达，用极短轮询等待即可（RawSocket 是单订阅流，
/// 订阅后即无法再被上层监听，故不引入流订阅）。
class _RawSockReader implements _SockReader {
  final RawSocket _socket;
  final Duration _timeout;
  _RawSockReader(this._socket, this._timeout);

  @override
  Future<Uint8List> readExact(int n) async {
    final out = <int>[];
    final sw = Stopwatch()..start();
    while (out.length < n) {
      final chunk = _socket.read(n - out.length);
      if (chunk != null && chunk.isNotEmpty) {
        out.addAll(chunk);
      } else {
        if (sw.elapsed > _timeout) {
          throw const SocketException('SOCKS5 handshake read timeout');
        }
        await Future.delayed(const Duration(milliseconds: 2));
      }
    }
    return Uint8List.fromList(out);
  }
}

/// Socket 广播流版：一次订阅，内部缓冲，精确读 N 字节。
class _BcastSockReader implements _SockReader {
  final Stream<Uint8List> _stream;
  final Duration _timeout;
  StreamSubscription<Uint8List>? _sub;
  final List<int> _buf = <int>[];

  _BcastSockReader(this._stream, this._timeout) {
    _sub = _stream.listen(
      _buf.addAll,
      onError: (Object _) {}, // 错误在读侧体现（readExact 拿不到数据 → 超时）
      cancelOnError: false,
    );
  }

  @override
  Future<Uint8List> readExact(int n) async {
    final sw = Stopwatch()..start();
    while (_buf.length < n) {
      if (sw.elapsed > _timeout) {
        throw const SocketException('SOCKS5 handshake read timeout');
      }
      // 广播流事件异步送达，让出事件循环等数据。
      await Future<void>.delayed(const Duration(milliseconds: 2));
    }
    final out = Uint8List.fromList(_buf.sublist(0, n));
    _buf.removeRange(0, n);
    return out;
  }

  Future<void> dispose() async {
    // 取消最后一次广播订阅：asBroadcastStream 默认 onCancel 会 pause 底层
    // 订阅（不是 cancel），数据不会丢，交给上层继续读。
    await _sub?.cancel();
    _sub = null;
  }
}

/// [Socket] 的透传包装：唯一差别是 `stream` 暴露为底层 socket 的广播流。
///
/// 为什么需要包装：[Socket] 是单订阅流，握手已经通过 `asBroadcastStream()`
/// 订阅过底层流；若把原 [Socket] 直接交给上层（HttpClient / `await for`），
/// 它们再次 listen 会抛 "Stream has already been listened to"。
/// 继承 [Stream] 让 `map/first/last/...` 等派生方法走本类 `listen`（即广播流）。
class Socks5TunnelSocket extends Stream<Uint8List> implements Socket {
  final Socket _raw;
  final Stream<Uint8List> _bcast;

  Socks5TunnelSocket(this._raw, this._bcast);

  /// 对底层真实 socket 做 TLS 升级（HTTPS 目标）。
  ///
  /// `SecureSocket.secure` 内部调用真实 Socket 的私有 `_detachRaw()`，
  /// 只能传**真实** Socket（包装类会 NoSuchMethodError），升级完成后重新包装。
  /// [host] 必须显式传目标主机名（否则 SNI/证书校验会用到代理的地址）。
  Future<Socket> secureForTLS({String? host}) async {
    final sec = await SecureSocket.secure(_raw, host: host);
    return Socks5TunnelSocket(sec, sec.asBroadcastStream());
  }

  // ── Stream<Uint8List>：唯一需要覆盖的是 listen（其余派生方法走这里）──
  @override
  StreamSubscription<Uint8List> listen(void Function(Uint8List event)? onData,
      {Function? onError, void Function()? onDone, bool? cancelOnError}) {
    return _bcast.listen(onData,
        onError: onError, onDone: onDone, cancelOnError: cancelOnError);
  }

  // ── IOSink ──
  @override
  void add(List<int> data) => _raw.add(data);

  @override
  void addError(Object error, [StackTrace? stackTrace]) =>
      _raw.addError(error, stackTrace);

  @override
  Future<void> addStream(Stream<List<int>> stream) => _raw.addStream(stream);

  @override
  void write(Object? obj) => _raw.write(obj);

  @override
  void writeAll(Iterable objects, [String separator = '']) =>
      _raw.writeAll(objects, separator);

  @override
  void writeln([Object? obj = '']) => _raw.writeln(obj);

  @override
  void writeCharCode(int charCode) => _raw.writeCharCode(charCode);

  @override
  Future<void> flush() => _raw.flush();

  @override
  Future<void> close() => _raw.close();

  @override
  void destroy() => _raw.destroy();

  // ── IOSink.encoding ──
  @override
  Encoding get encoding => _raw.encoding;

  @override
  set encoding(Encoding value) => _raw.encoding = value;

  // ── Socket 信息与控制 ──
  @override
  InternetAddress get address => _raw.address;

  @override
  int get port => _raw.port;

  @override
  InternetAddress get remoteAddress => _raw.remoteAddress;

  @override
  int get remotePort => _raw.remotePort;

  @override
  bool setOption(SocketOption option, bool enabled) =>
      _raw.setOption(option, enabled);

  @override
  Uint8List getRawOption(RawSocketOption option) => _raw.getRawOption(option);

  @override
  void setRawOption(RawSocketOption option) => _raw.setRawOption(option);

  @override
  Future<void> get done => _raw.done;
}
