import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '/src/ftp_reply.dart';
import '../ftpconnect.dart';

class FTPSocket {
  final String host;
  final int port;
  final Logger logger;
  final int timeout;
  final SecurityType securityType;
  late RawSocket _socket;
  TransferMode transferMode = TransferMode.passive;
  TransferType _transferType = TransferType.auto;
  ListCommand listCommand = ListCommand.mlsd;
  bool supportIPV6 = false;

  /// 已从 socket 读出、但尚未被任何一次响应消费的字节。
  ///
  /// ── ZenFile 本地补丁（2026-09-16）──────────────────────────────────────
  /// 上游把每次 `read()` 到的数据 `trim()` 后直接拼进当前响应，遇到「同一个
  /// TCP 分段内在途多条响应」时会把它们**粘成一条**（中间的 `\r\n` 被 trim
  /// 吃掉）。例如数据通道的 `150 Opening data connection` 与紧随其后的
  /// `226 Transfer complete` 被粘成 `150 ...226 ...`，解析出的 code 变成 150。
  ///
  /// 后果（真实故障，非理论风险）：`FTPDirectory.directoryContent()` 读到
  /// `150` 后判定「传输尚未结束」，于是再 `readResponse()` 等 `226` —— 而
  /// `226` 已在上一步被吞掉丢弃 → **白等到命令超时 → 上层判定列表失败 →
  /// 重连**。目录越小、网络越快，150 与 226 越容易落进同一个静默窗口，因此
  /// 症状恰好表现为「偶尔进入目录要等很久」。
  ///
  /// 修法：字节级缓冲 + 按协议解析出**第一条完整响应**即返回，剩余字节留在
  /// 本缓冲供下一次 `readResponse()` 使用，保证「一次 readResponse 消费且仅
  /// 消费一条响应」这一基本不变量。
  final List<int> _pendingBytes = <int>[];

  /// ── ZenFile 本地补丁（2026-09-16）──────────────────────────────────────
  /// 数据连接（PASV/EPSV 通告的端口）建立超时。
  ///
  /// 上游把控制连接超时 [timeout]（默认 15~30s）直接复用到数据连接上，而被动
  /// 模式的数据端口是服务端**临时开启**的随机高端口，若被防火墙/内核队列丢弃，
  /// 客户端要白等满整个控制超时才会失败重试，表现为「偶尔进入目录要等十几秒」。
  /// 数据连接是本地可立即判定的连接（同机房/局域网），8s 已非常宽裕。
  Duration dataConnectTimeout;

  FTPSocket(this.host, this.port, this.securityType, this.logger, this.timeout)
      : dataConnectTimeout =
            Duration(seconds: timeout < 8 ? timeout : 8);

  /// Set current transfer type of socket
  ///
  /// Supported types are: [TransferType.auto], [TransferType.ascii], [TransferType.binary],
  TransferType get transferType => _transferType;

  /// Read the FTP Server response from the Stream
  ///
  /// Blocks until data is received!
  ///
  /// ── ZenFile 本地补丁（2026-09-16）──────────────────────────────────────
  /// 上游实现用**固定 300ms** 轮询 `RawSocket.available()`（原代码为
  /// `await Future.delayed(Duration(milliseconds: 300))`），而 `sendCommand()`
  /// 是「写完命令立刻调用 readResponse」——`Future.doWhile` 会**同步**执行
  /// 第一次检查，此刻服务端响应绝无可能已到达（至少要一个网络 RTT），于是
  /// **每一条 FTP 命令都恒定白等 300ms**。
  ///
  /// 一次目录列举需要 CWD + PASV + MLSD + 226 共 4 条命令 → 每次「进入目录」
  /// 与「返回上一级」都固定多花 ≈1.2s；连接（欢迎语 + USER + PASS）、上传后
  /// 的 finalizeUpload 轮询、删除 / 重命名 / 新建目录 / SIZE 同理。这正是
  /// 「FTP 浏览远程目录载入很久，而 SFTP / SMB / WebDAV 正常」的根因——后
  /// 三者的响应读取都是事件驱动，没有这层固定等待。
  ///
  /// 补丁：首字节改为 2ms 粒度轮询（若 200ms 内未到则退避到 25ms，避免异常
  /// 慢的服务端导致长时间空转）；收到数据后追加一个 10ms「静默窗口」再判定
  /// 响应结束，以保留原实现「确保响应完整」的语义（防 TCP 分段只读到半截）。
  /// 若服务端在多行响应中间停顿超过静默窗口，会退化为原有多行递归读取路径
  /// （见下方 `line[3] == '-'`），不会更差。
  ///
  /// 修回上游前请先确认上游是否已修复该轮询（2.0.10 / 3.0.0 均未修）。
  /// ZenFile 补丁（2026-09-16）：新增 [timeoutOverride]。上游只有一个固定超时
  /// [timeout]（默认 15~30s），既当 TCP 连接超时又当命令响应超时。对「连接活性
  /// 探测 / 短查询（NOOP、SIZE）」来说 15s 太长——连接已被服务端静默回收时，
  /// 客户端要白等满 15s 才能判定失败，这正是「FTP 偶尔进目录等很久」的主因。
  /// 允许调用方按命令性质指定更短的超时，即可把探测失败的代价压到数秒。
  Future<FTPReply> readResponse({Duration? timeoutOverride}) async {
    const Duration pollInterval = Duration(milliseconds: 2);
    const Duration backoffInterval = Duration(milliseconds: 25);
    const Duration backoffAfter = Duration(milliseconds: 200);
    const Duration silenceWindow = Duration(milliseconds: 2);

    String r = '';
    Duration waited = Duration.zero;
    await Future.doWhile(() async {
      // 先把内核里可读的字节全部收进缓冲。
      while (_socket.available() > 0) {
        _pendingBytes.addAll(_socket.read()!);
      }

      // ① 协议层面已能判定「第一条完整响应」→ 立即切出并返回。
      //    **绝不等待静默窗口**：等待期间到达的、属于下一条命令的响应会被
      //    误吞进本次响应（上游实现正是如此，见下方说明）。
      final first = _consumeFirstResponse();
      if (first != null) {
        r = first;
        return false;
      }

      // ② 收到了部分数据但协议上还不完整（TCP 分段把响应切成两半）。
      if (_pendingBytes.isNotEmpty) {
        await Future.delayed(silenceWindow);
        if (_socket.available() > 0) return true; // 还有后续分段 → 继续读
        // 静默后仍无新数据：兼容少数不按 RFC 用 CRLF 结尾的服务器
        // （只发 "200" 这类裸状态码，上游的 trim 拼接实现能容忍）。
        final loose = _consumeLooseSingleLine();
        if (loose != null) {
          r = loose;
          return false;
        }
        return true; // 多行响应尚未收到结束行 → 继续等（直到超时）
      }

      // ③ 什么都没收到：轮询（前 200ms 用 2ms 粒度，之后退避到 25ms）。
      waited += pollInterval;
      await Future.delayed(
          waited < backoffAfter ? pollInterval : backoffInterval);
      return true;
    }).timeout(timeoutOverride ?? Duration(seconds: timeout), onTimeout: () {
      throw FTPConnectException('Timeout reached for Receiving response !');
    });

    if (r.startsWith("\n")) r = r.replaceFirst("\n", "");

    if (r.length < 3) throw FTPConnectException("Illegal Reply Exception", r);

    int? code;
    List<String> lines = r.split('\n');
    //get last code
    for (var line in lines) {
      if (line.length >= 3) code = int.tryParse(line.substring(0, 3)) ?? code;
    }
    //multiline response
    // 说明：多行响应已由 _consumeFirstResponse 一次性取全（含 "NNN " 结束行），
    // 因此不再需要上游「递归读下一段」的兜底逻辑。

    if (code == null) throw FTPConnectException("Illegal Reply Exception", r);

    FTPReply reply = FTPReply(code, r);
    logger.log('< ${reply.toString()}');
    return reply;
  }

  /// 从 [_pendingBytes] 头部取出**第一条完整响应**（返回其文本并消费对应字节）。
  ///
  /// 完整性判据（RFC 959）：单行响应为 `NNN<SP>...CRLF`；多行响应以
  /// `NNN-...CRLF` 开头，直到出现同码的 `NNN<SP>...CRLF` 结束行。
  /// 数据不足以判定时返回 null，等待后续分段。
  String? _consumeFirstResponse() {
    var pos = 0;
    String? firstCode;
    var multiline = false;
    while (true) {
      final nl = _lfIndex(_pendingBytes, pos);
      if (nl < 0) return null; // 尚无完整行
      var line = String.fromCharCodes(_pendingBytes.sublist(pos, nl));
      if (line.endsWith('\r')) line = line.substring(0, line.length - 1);
      final lineEnd = nl + 1;

      if (firstCode == null) {
        if (line.length < 3) return null;
        final code = line.substring(0, 3);
        if (int.tryParse(code) == null) return null;
        firstCode = code;
        multiline = line.length > 3 && line[3] == '-';
        if (!multiline) return _takeBytes(lineEnd);
      } else if (line.length >= 4 &&
          line.startsWith(firstCode) &&
          line[3] == ' ') {
        return _takeBytes(lineEnd);
      }
      pos = lineEnd;
    }
  }

  /// 兼容兜底：少数服务器不按 RFC 用 CRLF 结尾，只发裸状态码（如 `200`）。
  /// 在静默窗口内确认无后续数据后，把缓冲内容整体当作一条单行响应接受。
  /// （上游的 trim 拼接实现同样能容忍这种服务器，此兜底保持行为兼容。）
  String? _consumeLooseSingleLine() {
    final text = Utf8Codec().decode(_pendingBytes, allowMalformed: true).trim();
    if (text.isEmpty || text.contains('\n')) return null;
    if (!RegExp(r'^\d{3}(\s|$)').hasMatch(text)) return null;
    _pendingBytes.clear();
    return text;
  }

  /// 取走 [_pendingBytes] 的前 [n] 个字节，作为一条已消费的响应返回。
  String _takeBytes(int n) {
    final text =
        Utf8Codec().decode(_pendingBytes.sublist(0, n), allowMalformed: true);
    _pendingBytes.removeRange(0, n);
    return text;
  }

  static int _lfIndex(List<int> bytes, int from) {
    for (var i = from; i < bytes.length; i++) {
      if (bytes[i] == 10) return i;
    }
    return -1;
  }

  /// Send a command [cmd] to the FTP Server
  /// if [waitResponse] the function waits for the reply, other wise return ''
  ///
  /// [responseTimeout] 可覆盖本次命令的响应等待超时（ZenFile 补丁，见 [readResponse]）。
  Future<FTPReply> sendCommand(String cmd, {Duration? responseTimeout}) {
    logger.log('> $cmd');
    _socket.write(Utf8Codec().encode('$cmd\r\n'));

    return readResponse(timeoutOverride: responseTimeout);
  }

  /// Send a command [cmd] to the FTP Server
  /// if [waitResponse] the function waits for the reply, other wise return ''
  void sendCommandWithoutWaitingResponse(String cmd) async {
    logger.log('> $cmd');
    _socket.write(Utf8Codec().encode('$cmd\r\n'));
  }

  /// Connect to the FTP Server and Login with [user] and [pass]
  Future<bool> connect(String user, String pass, {String? account}) async {
    logger.log('Connecting...');

    final timeout = Duration(seconds: this.timeout);

    try {
      // FTPS starts secure
      if (securityType == SecurityType.ftps) {
        _socket = await RawSecureSocket.connect(
          host,
          port,
          timeout: timeout,
          onBadCertificate: (certificate) => true,
        );
      } else {
        _socket = await RawSocket.connect(
          host,
          port,
          timeout: timeout,
        );
      }
    } catch (e) {
      throw FTPConnectException(
          'Could not connect to $host ($port)', e.toString());
    }

    logger.log('Connection established, waiting for welcome message...');
    await readResponse();

    // FTPES needs to be upgraded prior to getting a welcome
    if (securityType == SecurityType.ftpes) {
      FTPReply lResp = await sendCommand('AUTH TLS');
      if (!lResp.isSuccessCode()) {
        lResp = await sendCommand('AUTH SSL');
        if (!lResp.isSuccessCode()) {
          throw FTPConnectException(
              'FTPES cannot be applied: the server refused both AUTH TLS and AUTH SSL commands',
              lResp.message);
        }
      }

      _socket = await RawSecureSocket.secure(_socket,
          onBadCertificate: (certificate) => true);
    }

    if ([SecurityType.ftpes, SecurityType.ftps].contains(securityType)) {
      await sendCommand('PBSZ 0');
      await sendCommand('PROT P');
    }

    // Send Username
    FTPReply lResp = await sendCommand('USER $user');

    //password required
    if (lResp.code == 331) {
      lResp = await sendCommand('PASS $pass');
      if (lResp.code == 332) {
        if (account == null) throw FTPConnectException('Account required');
        lResp = await sendCommand('ACCT $account');
        if (!lResp.isSuccessCode()) {
          throw FTPConnectException('Wrong Account', lResp.message);
        }
      } else if (!lResp.isSuccessCode()) {
        throw FTPConnectException('Wrong Username/password', lResp.message);
      }
      //account required
    } else if (lResp.code == 332) {
      if (account == null) throw FTPConnectException('Account required');
      lResp = await sendCommand('ACCT $account');
      if (!lResp.isSuccessCode()) {
        throw FTPConnectException('Wrong Account', lResp.message);
      }
    } else if (!lResp.isSuccessCode()) {
      throw FTPConnectException('Wrong username $user', lResp.message);
    }

    logger.log('Connected!');
    return true;
  }

  Future<FTPReply> openDataTransferChannel() async {
    FTPReply res = FTPReply(200, "");
    if (transferMode == TransferMode.active) {
      //todo later
    } else {
      res = await sendCommand(supportIPV6 ? 'EPSV' : 'PASV');
      if (!res.isSuccessCode()) {
        throw FTPConnectException('Could not start Passive Mode', res.message);
      }
    }

    return res;
  }

  /// Set the Transfer mode on [socket] to [mode]
  Future<void> setTransferType(TransferType pTransferType) async {
    //if we already in the same transfer type we do nothing
    if (_transferType == pTransferType) return;
    switch (pTransferType) {
      case TransferType.auto:
        // Set to ASCII mode
        await sendCommand('TYPE A');
        break;
      case TransferType.ascii:
        // Set to ASCII mode
        await sendCommand('TYPE A');
        break;
      case TransferType.binary:
        // Set to BINARY mode
        await sendCommand('TYPE I');
        break;
    }
    _transferType = pTransferType;
  }

  // Disconnect from the FTP Server
  //
  // ── ZenFile 本地补丁（2026-09-16）──────────────────────────────────────
  // 上游用 `await sendCommand('QUIT')` 等待 QUIT 响应。当连接已被服务端或中间
  // 设备静默回收（TCP 半开）时，这条 QUIT 永远收不到响应，会白等满一个命令超时
  // （默认 15s）才抛异常并被 catch 吞掉。而本项目的「列表失败 → 重连」路径里
  // disconnect() 正是第一步，于是**一次失败列表被放大成「15s 超时 + 15s QUIT
  // 白等 + 重连握手」**，这正是「FTP 偶尔要等很久才打开目录」的一半耗时。
  // QUIT 只是礼貌通知（服务端不依赖它做清理），故改为「发出即关闭、不等响应」。
  Future<bool> disconnect() async {
    logger.log('Disconnecting...');

    try {
      sendCommandWithoutWaitingResponse('QUIT');
    } catch (ignored) {
      // Ignore
    }
    try {
      await _socket.close();
      _socket.shutdown(SocketDirection.both);
    } catch (ignored) {
      // Ignore
    }

    logger.log('Disconnected!');
    return true;
  }

  /// 硬关闭底层 socket：不发 QUIT、不等任何响应（ZenFile 补丁，2026-09-16）。
  ///
  /// 用于「已知连接已死」的场景（活性探测失败 / 命令超时 / 取消传输）：此时任何
  /// 走控制连接的收尾动作都只会再赔上一个超时，直接销毁才是最快的复位方式。
  void destroy() {
    try {
      _socket.close();
    } catch (_) {}
    try {
      _socket.shutdown(SocketDirection.both);
    } catch (_) {}
  }
}
