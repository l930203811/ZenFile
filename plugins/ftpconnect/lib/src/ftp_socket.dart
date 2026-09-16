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

  FTPSocket(this.host, this.port, this.securityType, this.logger, this.timeout);

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
  Future<FTPReply> readResponse() async {
    const Duration pollInterval = Duration(milliseconds: 2);
    const Duration backoffInterval = Duration(milliseconds: 25);
    const Duration backoffAfter = Duration(milliseconds: 200);
    const Duration silenceWindow = Duration(milliseconds: 10);

    StringBuffer res = StringBuffer();
    Duration waited = Duration.zero;
    await Future.doWhile(() async {
      bool dataReceivedSuccessfully = false;

      //this is used to read all data for specific command line
      while (_socket.available() > 0) {
        res.write(Utf8Codec().decode(_socket.read()!).trim());
        dataReceivedSuccessfully = true;
      }
      if (dataReceivedSuccessfully) {
        // 已读到数据：再等一个静默窗口，确认没有后续分段，保证响应完整。
        await Future.delayed(silenceWindow);
        return _socket.available() > 0;
      }

      waited += pollInterval;
      await Future.delayed(
          waited < backoffAfter ? pollInterval : backoffInterval);
      return true;
    }).timeout(Duration(seconds: timeout), onTimeout: () {
      throw FTPConnectException('Timeout reached for Receiving response !');
    });

    String r = res.toString();
    if (r.startsWith("\n")) r = r.replaceFirst("\n", "");

    if (r.length < 3) throw FTPConnectException("Illegal Reply Exception", r);

    int? code;
    List<String> lines = r.split('\n');
    //get last code
    String? line;
    for (line in lines) {
      if (line.length >= 3) code = int.tryParse(line.substring(0, 3)) ?? code;
    }
    //multiline response
    if (line != null && line.length >= 4 && line[3] == '-') {
      return await readResponse();
    }

    if (code == null) throw FTPConnectException("Illegal Reply Exception", r);

    FTPReply reply = FTPReply(code, r);
    logger.log('< ${reply.toString()}');
    return reply;
  }

  /// Send a command [cmd] to the FTP Server
  /// if [waitResponse] the function waits for the reply, other wise return ''
  Future<FTPReply> sendCommand(String cmd) {
    logger.log('> $cmd');
    _socket.write(Utf8Codec().encode('$cmd\r\n'));

    return readResponse();
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
  Future<bool> disconnect() async {
    logger.log('Disconnecting...');

    try {
      await sendCommand('QUIT');
    } catch (ignored) {
      // Ignore
    } finally {
      await _socket.close();
      _socket.shutdown(SocketDirection.both);
    }

    logger.log('Disconnected!');
    return true;
  }
}
