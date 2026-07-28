import 'dart:io';
import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:ftpconnect/ftpconnect.dart';
import 'package:path/path.dart' as p;
import 'remote_client.dart';

class FtpRemoteClient extends RemoteClient {
  final String host;
  final int port;
  final String username;
  final String password;

  FTPConnect? _ftpConnect;
  Socket? _activeUploadControlSocket;
  Socket? _activeUploadDataSocket;

  @override
  void cancel() {
    // 必须同步置位基类的 _cancelled 标志，否则 isCancelled 永远为 false，
    // 所有基于 isCancelled 的取消检查（如下载循环的 if (isCancelled) break）
    // 都会失效。FTP 没有原生取消命令，同时断开连接让进行中的传输因
    // socket 关闭而抛异常，上层捕获后视为取消。
    super.cancel();
    // 手动上传使用独立的控制/数据 socket，必须一并销毁才能立即中断传输。
    try { _activeUploadControlSocket?.destroy(); } catch (_) {}
    try { _activeUploadDataSocket?.destroy(); } catch (_) {}
    _ftpConnect?.disconnect();
  }

  @override
  void resetCancel() {
    // FTP 取消后需要重新连接，resetCancel 由上层在传输前调用。
    // 这里必须重置基类标志，否则一次取消后 isCancelled 永远为 true，
    // 后续所有传输都会被误判为已取消。
    super.resetCancel();
  }

  FtpRemoteClient({
    required this.host,
    required this.port,
    required this.username,
    required this.password,
  });

  @override
  Future<void> connect() async {
    _ftpConnect = FTPConnect(
      host,
      port: port,
      user: username.isEmpty ? 'anonymous' : username,
      pass: password.isEmpty ? 'anonymous@' : password,
      timeout: 15,
    );
    var success = await _ftpConnect!.connect();
    if (!success) {
      // Retry once before giving up
      await _ftpConnect?.disconnect();
      _ftpConnect = FTPConnect(
        host,
        port: port,
        user: username.isEmpty ? 'anonymous' : username,
        pass: password.isEmpty ? 'anonymous@' : password,
        timeout: 15,
      );
      success = await _ftpConnect!.connect();
      if (!success) {
        throw Exception('FTP connection failed: could not connect to $host:$port');
      }
    }
  }

  @override
  Future<void> disconnect() async {
    await _ftpConnect?.disconnect();
    _ftpConnect = null;
  }

  @override
  Future<List<RemoteFileItem>> listDirectory(String path, {bool forceRefresh = false}) async {
    if (_ftpConnect == null) throw Exception('FTP not connected');

    final targetPath = (path.isEmpty || path == '/') ? '/' : path;

    List<FTPEntry> allEntries;
    try {
      allEntries = await _listCurrentDirectory(targetPath);
    } catch (e) {
      // 列表失败（网络抖动 / 服务器临时锁目录 / CWD 漂移）：重连后重试一次。
      // 重连会重置会话的当前工作目录，避免残留的 CWD 状态影响后续导航。
      try {
        await _ftpConnect?.disconnect();
      } catch (_) {}
      _ftpConnect = FTPConnect(
        host,
        port: port,
        user: username.isEmpty ? 'anonymous' : username,
        pass: password.isEmpty ? 'anonymous@' : password,
        timeout: 15,
      );
      final reconnected = await _ftpConnect!.connect();
      if (!reconnected) {
        throw Exception('FTP reconnection failed after error: $e');
      }
      allEntries = await _listCurrentDirectory(targetPath);
    }

    final list = <RemoteFileItem>[];
    for (final entry in allEntries) {
      if (entry.name == '.' || entry.name == '..') continue;
      if (entry.type == FTPEntryType.unknown) continue;

      final fullPath = path == '/' ? '/${entry.name}' : '$path/${entry.name}';
      final isDir = entry.type == FTPEntryType.dir;

      list.add(RemoteFileItem(
        name: entry.name,
        path: fullPath,
        isDirectory: isDir,
        size: entry.size ?? 0,
        modified: entry.modifyTime ?? DateTime.now(),
      ));
    }
    return list;
  }

  /// 切换到 [targetPath] 并列出“当前工作目录”的内容。
  ///
  /// 关键修复：ftpconnect 的 [FTPConnect.listDirectoryContent] 始终列出 FTP 会话的
  /// 当前工作目录（CWD），不带任何路径参数。若不在列表前先 [changeDirectory]，则无论
  /// 传入什么路径都会列出 CWD，导致：
  ///   - 点击子文件夹后列表看起来“没变化”（实际仍列着父目录）→ 表现为“点击无响应”；
  ///   - 其它操作（上传/删除/重命名）改变了 CWD 后，列表会列出错误目录 → 表现为
  ///     “进入目录偶尔为空”。
  /// 因此这里统一先 CWD 到目标目录再 LIST。
  Future<List<FTPEntry>> _listCurrentDirectory(String targetPath) async {
    if (targetPath != '/') {
      final ok = await _ftpConnect!
          .changeDirectory(targetPath)
          .timeout(const Duration(seconds: 30));
      if (!ok) throw Exception('Cannot open directory: $targetPath');
    } else {
      // 根目录：尝试 CWD /。部分服务器登录后 CWD 已位于根目录，即便 CWD /
      // 返回失败也不影响，直接按当前工作目录列出即可，保证根目录始终可用。
      try {
        await _ftpConnect!
            .changeDirectory('/')
            .timeout(const Duration(seconds: 30));
      } catch (_) {
        // 忽略，继续以当前工作目录列出
      }
    }
    return await _ftpConnect!
        .listDirectoryContent()
        .timeout(const Duration(seconds: 30));
  }

  @override
  Future<void> createDirectory(String path) async {
    if (_ftpConnect == null) throw Exception('FTP not connected');
    final dirName = p.basename(path);
    final parentPath = p.dirname(path);

    if (parentPath.isNotEmpty && parentPath != '/') {
      await _ftpConnect!.changeDirectory(parentPath);
    }

    final ok = await _ftpConnect!.makeDirectory(dirName);
    if (!ok) throw Exception('Failed to create directory: $path');
  }

  @override
  Future<void> createFile(String path) async {
    if (_ftpConnect == null) throw Exception('FTP not connected');
    final fileName = p.basename(path);
    final parentPath = p.dirname(path);
    if (parentPath.isNotEmpty && parentPath != '/') {
      await _ftpConnect!.changeDirectory(parentPath);
    }
    // Create empty file by uploading zero bytes
    final tempFile = File('${Directory.systemTemp.path}/.empty_${DateTime.now().millisecondsSinceEpoch}');
    await tempFile.writeAsString('');
    try {
      await _ftpConnect!.uploadFile(
        tempFile,
        sRemoteName: fileName,
      );
    } finally {
      if (await tempFile.exists()) await tempFile.delete();
    }
  }

  @override
  Future<void> delete(String path, bool isDir) async {
    if (_ftpConnect == null) throw Exception('FTP not connected');
    // FTP 删除偶尔会因网络抖动或服务器锁文件失败，增加重试逻辑
    const maxRetries = 3;
    Exception? lastError;
    for (int attempt = 0; attempt < maxRetries; attempt++) {
      try {
        if (isDir) {
          // 先切换到父目录，再删除子目录
          final parentPath = p.dirname(path);
          final dirName = p.basename(path);
          if (parentPath.isNotEmpty && parentPath != '/') {
            await _ftpConnect!.changeDirectory(parentPath);
          } else {
            await _ftpConnect!.changeDirectory('/');
          }
          final ok = await _ftpConnect!
              .deleteDirectory(dirName)
              .timeout(const Duration(seconds: 30));
          if (!ok) throw Exception('Failed to delete directory: $path');
        } else {
          final fileName = p.basename(path);
          final parentPath = p.dirname(path);
          if (parentPath.isNotEmpty && parentPath != '/') {
            await _ftpConnect!.changeDirectory(parentPath);
          }
          final ok = await _ftpConnect!
              .deleteFile(fileName)
              .timeout(const Duration(seconds: 30));
          if (!ok) throw Exception('Failed to delete file: $path');
        }
        return; // 成功则直接返回
      } on TimeoutException {
        lastError = Exception('FTP delete timed out');
        if (attempt < maxRetries - 1) {
          await Future.delayed(Duration(milliseconds: 500 * (attempt + 1)));
        }
      } on Exception catch (e) {
        lastError = e;
        // 如果是"文件不存在"类错误，不重试直接抛出
        final msg = e.toString().toLowerCase();
        if (msg.contains('no such file') ||
            msg.contains('not found') ||
            msg.contains('does not exist') ||
            msg.contains('550')) {
          rethrow;
        }
        // 其他错误（网络抖动、服务器锁文件等）延迟后重试
        if (attempt < maxRetries - 1) {
          await Future.delayed(Duration(milliseconds: 500 * (attempt + 1)));
        }
      }
    }
    // 所有重试都失败，抛出最后一个错误
    throw Exception('FTP delete failed after $maxRetries attempts: $lastError');
  }

  @override
  Future<void> rename(String oldPath, String newPath) async {
    if (_ftpConnect == null) throw Exception('FTP not connected');
    final ok = await _ftpConnect!.rename(oldPath, newPath);
    if (!ok) throw Exception('Failed to rename: $oldPath -> $newPath');
  }

  @override
  Future<void> downloadFile(
    String remotePath,
    String localPath,
    Function(double progress) onProgress,
  ) async {
    if (_ftpConnect == null) throw Exception('FTP not connected');

    // Try raw socket download first — it writes data to disk with periodic
    // flushing, which is critical for the streaming proxy to read data
    // while the download is in progress. ftpconnect's downloadFile buffers
    // data in its IOSink and may not flush to disk until completion.
    try {
      await _downloadWithRawSocket(remotePath, localPath, onProgress);
      return;
    } catch (e) {
      debugPrint('FTP raw socket download failed, falling back to ftpconnect: $e');
    }

    // Fallback: use ftpconnect's downloadFile (buffers entire download in IOSink)
    final fileName = p.basename(remotePath);
    final parentPath = p.dirname(remotePath);

    // Navigate to the parent directory of the file
    if (parentPath.isNotEmpty && parentPath != '/') {
      final ok = await _ftpConnect!.changeDirectory(parentPath);
      if (!ok) throw Exception('Cannot open directory: $parentPath');
    }

    final localFile = File(localPath);
    // Ensure parent directory exists
    if (!localFile.parent.existsSync()) {
      localFile.parent.createSync(recursive: true);
    }

    onProgress(0.0);

    // Timeout proportional to file size: 5min base + 2s per MB
    int timeoutMinutes = 30;
    try {
      final size = await _ftpConnect!.sizeFile(fileName).timeout(const Duration(seconds: 10));
      if (size > 0) {
        timeoutMinutes = (size ~/ (1024 * 1024 * 50)).clamp(5, 120) + 5;
      }
    } catch (_) {}

    final ok = await _ftpConnect!
        .downloadFile(
          fileName,
          localFile,
          onProgress: (progressPercent, received, fileSize) {
            onProgress((progressPercent / 100.0).clamp(0.0, 1.0));
          },
        )
        .timeout(Duration(minutes: timeoutMinutes));

    if (!ok) throw Exception('Download failed for: $remotePath');
    onProgress(1.0);
  }

  @override
  Future<void> downloadRange(String remotePath, String localPath, int startByte, int length) async {
    if (_ftpConnect == null) throw Exception('FTP not connected');
    // 复用 raw socket 实现，通过 FTP REST 命令指定起始偏移，限制读取长度
    await _downloadWithRawSocket(
      remotePath,
      localPath,
      (_) {},
      startByte: startByte,
      maxLength: length,
    );
  }

  /// Raw socket FTP download with periodic disk flushing.
  ///
  /// Opens a SEPARATE control+data connection to the FTP server (independent
  /// from the ftpconnect session used for listing/uploading). This is needed
  /// because ftpconnect's [FTPConnect.downloadFile] buffers all data in an
  /// internal IOSink that only flushes when the download completes — making
  /// it impossible for the streaming proxy to read data mid-download.
  ///
  /// This implementation writes data in 32KB chunks, flushing to disk after
  /// each chunk and yielding the event loop, so the streaming proxy can read
  /// data as it arrives.
  Future<void> _downloadWithRawSocket(
    String remotePath,
    String localPath,
    Function(double progress) onProgress, {
    int startByte = 0,
    int? maxLength,
  }) async {
    Socket? controlSocket;
    Socket? dataSocket;
    IOSink? sink;
    StreamSubscription? controlSub;

    try {
      // Connect control connection
      controlSocket = await Socket.connect(host, port,
          timeout: const Duration(seconds: 15));

      final buffer = <int>[];
      Completer<String>? responseCompleter;

      controlSub = controlSocket.listen(
        (data) {
          buffer.addAll(data);
          // Parse complete FTP response lines (terminated by \r\n)
          while (true) {
            final str = String.fromCharCodes(buffer);
            final crlfIndex = str.indexOf('\r\n');
            if (crlfIndex < 0) break;
            final line = str.substring(0, crlfIndex);
            buffer.removeRange(0, crlfIndex + 2);
            // Final line of a response: 3-digit code followed by space
            if (line.length >= 4 && line[3] == ' ') {
              final c = responseCompleter;
              responseCompleter = null;
              c?.complete(line);
              break;
            }
            // Multi-line response (code + '-') — keep reading
          }
        },
        onError: (e) {
          final c = responseCompleter;
          responseCompleter = null;
          c?.completeError(e);
        },
        onDone: () {
          final c = responseCompleter;
          responseCompleter = null;
          c?.completeError(Exception('Control connection closed'));
        },
      );

      Future<String> sendCommand(String cmd) {
        responseCompleter = Completer<String>();
        controlSocket!.write('$cmd\r\n');
        return responseCompleter!.future.timeout(const Duration(seconds: 15));
      }

      // Read welcome banner — server sends it immediately on connect.
      // 不使用 sendCommand('')（空命令会让服务器返回 500 错误，破坏协议序列）。
      // 等待 responseCompleter 被控制连接的 listen 回调填充。
      responseCompleter = Completer<String>();
      try {
        await responseCompleter!.future.timeout(const Duration(seconds: 5));
      } catch (_) {}

      // Authenticate
      final user = username.isEmpty ? 'anonymous' : username;
      final pass = password.isEmpty ? 'anonymous@' : password;
      final userResp = await sendCommand('USER $user');
      if (userResp.startsWith('3')) {
        // 331 — password required
        await sendCommand('PASS $pass');
      }

      // Binary mode
      await sendCommand('TYPE I');

      // 尝试快速查询 SIZE（3秒超时），失败就用 0（进度不更新但数据立即下载）
      int fileSize = 0;
      try {
        final sizeResp = await sendCommand('SIZE $remotePath')
            .timeout(const Duration(seconds: 3));
        // SIZE 响应形如 "213 1234567"（状态码 + 空格 + 文件字节数）。
        // 必须取状态码之后的数字，不能取首个数字——否则会把状态码 213
        // 当成文件大小，导致下载 213 字节后进度就到 100%（进度条瞬间满格）。
        final match = RegExp(r'^\d{3}[ -](\d+)').firstMatch(sizeResp.trim());
        if (match != null) {
          fileSize = int.tryParse(match.group(1)!) ?? 0;
        } else {
          // 兜底：取最后一个纯数字字段
          final parts = sizeResp.trim().split(RegExp(r'\s+'));
          if (parts.length >= 2) fileSize = int.tryParse(parts.last) ?? 0;
        }
      } catch (_) {
        // SIZE 查询超时或失败 — 继续下载，进度按字节无法报告
      }

      // Enter passive mode
      final pasvResp = await sendCommand('PASV');
      final pasvPort = _parsePasvPort(pasvResp);

      // Connect data socket
      dataSocket = await Socket.connect(host, pasvPort,
          timeout: const Duration(seconds: 15));

      // FTP REST 命令：指定下载起始字节偏移（用于 range 下载）
      if (startByte > 0) {
        await sendCommand('REST $startByte');
      }

      // Issue RETR — 发送命令后等待 150/125 响应
      // 不使用 sendCommand('')（空命令 hack 会破坏协议序列）
      controlSocket.write('RETR $remotePath\r\n');
      responseCompleter = Completer<String>();
      try {
        await responseCompleter!.future.timeout(const Duration(seconds: 10));
      } catch (_) {}

      // Prepare local file
      final file = File(localPath);
      if (!file.parent.existsSync()) {
        file.parent.createSync(recursive: true);
      }
      sink = file.openWrite();

      // Read data from data socket, write to file with periodic flushing.
      // 首块立即 flush（让代理尽快看到数据），后续每 64KB flush 一次。
      // 之前 4KB+1ms delay 限制了吞吐量到 ~1.5MB/s。
      int downloaded = 0;
      int sinceFlush = 0;
      bool isFirstChunk = true;
      const flushInterval = 64 * 1024; // 64KB

      await for (final chunk in dataSocket) {
        if (isCancelled) break;
        if (maxLength != null && downloaded + chunk.length > maxLength) {
          // 达到请求范围上限，只写入剩余需要的字节
          sink.add(chunk.sublist(0, maxLength - downloaded));
          downloaded = maxLength;
          break;
        }
        sink.add(chunk);
        downloaded += chunk.length;
        sinceFlush += chunk.length;
        if (fileSize > 0) {
          onProgress((downloaded / fileSize).clamp(0.0, 1.0));
        }
        if (isFirstChunk || sinceFlush >= flushInterval) {
          await sink.flush();
          sinceFlush = 0;
          isFirstChunk = false;
        }
        if (maxLength != null && downloaded >= maxLength) break;
      }

      if (isCancelled) {
        // 取消时删除本地未完成的半截文件，避免用户看到虚假的成功文件。
        try { file.deleteSync(); } catch (_) {}
        throw Exception('Cancelled');
      }

      await sink.flush();
      await sink.close();
      sink = null;

      await dataSocket.close();
      dataSocket = null;

      // Read final 226 response — 服务器在数据传输完成后自动发送
      // 不使用 sendCommand('')（空命令会破坏协议序列）
      responseCompleter = Completer<String>();
      try {
        await responseCompleter!.future.timeout(const Duration(seconds: 5));
      } catch (_) {}

      // Quit
      controlSocket.write('QUIT\r\n');
      onProgress(1.0);
    } finally {
      await controlSub?.cancel();
      await sink?.close();
      await dataSocket?.close();
      await controlSocket?.close();
    }
  }

  /// Parse the data port from a PASV response like:
  /// `227 Entering Passive Mode (192,168,1,1,4,1)`
  int _parsePasvPort(String response) {
    final match =
        RegExp(r'\((\d+),(\d+),(\d+),(\d+),(\d+),(\d+)\)').firstMatch(response);
    if (match == null) throw Exception('Invalid PASV response: $response');
    final p1 = int.parse(match.group(5)!);
    final p2 = int.parse(match.group(6)!);
    return p1 * 256 + p2;
  }

  @override
  Future<void> uploadFile(
    String localPath,
    String remotePath,
    Function(double progress) onProgress,
  ) async {
    if (_ftpConnect == null) throw Exception('FTP not connected');

    final localFile = File(localPath);
    if (!localFile.existsSync()) throw Exception('Local file not found: $localPath');

    final remoteFileName = p.basename(remotePath);
    final remoteDir = p.dirname(remotePath);

    Socket? controlSocket;
    Socket? dataSocket;
    StreamSubscription? controlSub;
    Completer<String>? responseCompleter;

    try {
      // 独立建立控制连接：ftpconnect 的 uploadFile 用 dataSocket.addStream，
      // 无法响应取消且默认 ASCII 传输会破坏二进制文件。这里手动实现 STOR，
      // 分块读取本地文件并检查 isCancelled，取消时立即销毁 socket。
      controlSocket = await Socket.connect(host, port,
          timeout: const Duration(seconds: 15));
      _activeUploadControlSocket = controlSocket;

      final buffer = <int>[];
      controlSub = controlSocket.listen(
        (data) {
          buffer.addAll(data);
          while (true) {
            final str = String.fromCharCodes(buffer);
            final crlfIndex = str.indexOf('\r\n');
            if (crlfIndex < 0) break;
            final line = str.substring(0, crlfIndex);
            buffer.removeRange(0, crlfIndex + 2);
            // Final line: 3-digit code followed by space
            if (line.length >= 4 && line[3] == ' ') {
              final c = responseCompleter;
              responseCompleter = null;
              c?.complete(line);
              break;
            }
            // Multi-line response (code + '-') — keep reading
          }
        },
        onError: (e) {
          final c = responseCompleter;
          responseCompleter = null;
          c?.completeError(e);
        },
        onDone: () {
          final c = responseCompleter;
          responseCompleter = null;
          c?.completeError(Exception('Control connection closed'));
        },
      );

      Future<String> sendCommand(String cmd) {
        responseCompleter = Completer<String>();
        controlSocket!.write('$cmd\r\n');
        return responseCompleter!.future.timeout(const Duration(seconds: 15));
      }

      // Read welcome banner
      responseCompleter = Completer<String>();
      try {
        await responseCompleter!.future.timeout(const Duration(seconds: 5));
      } catch (_) {}

      // Authenticate
      final user = username.isEmpty ? 'anonymous' : username;
      final pass = password.isEmpty ? 'anonymous@' : password;
      final userResp = await sendCommand('USER $user');
      if (userResp.startsWith('3')) {
        await sendCommand('PASS $pass');
      }

      // Binary mode — critical for video and other binary files
      await sendCommand('TYPE I');

      // Navigate to destination directory and create if needed
      if (remoteDir.isNotEmpty && remoteDir != '/') {
        try {
          await sendCommand('CWD $remoteDir');
        } catch (_) {
          await sendCommand('MKD $remoteDir');
          await sendCommand('CWD $remoteDir');
        }
      }

      // Passive mode
      final pasvResp = await sendCommand('PASV');
      final pasvPort = _parsePasvPort(pasvResp);

      // Connect data socket
      dataSocket = await Socket.connect(host, pasvPort,
          timeout: const Duration(seconds: 15));
      _activeUploadDataSocket = dataSocket;

      // Issue STOR — wait for 150/125 after sending command
      controlSocket.write('STOR $remoteFileName\r\n');
      responseCompleter = Completer<String>();
      try {
        await responseCompleter!.future.timeout(const Duration(seconds: 10));
      } catch (_) {}

      onProgress(0.0);

      final fileSize = localFile.lengthSync();
      int uploaded = 0;

      await for (final chunk in localFile.openRead()) {
        if (isCancelled) {
          // 取消：先销毁数据连接中止 STOR，再用 listing 会话删除已上传的半截
          // 目标文件与服务端可能生成的 file-<随机> 临时文件，避免残留。
          try { dataSocket.destroy(); } catch (_) {}
          _activeUploadDataSocket = null;
          try { await _abortAndCleanupUpload(remoteDir, remoteFileName); } catch (_) {}
          throw Exception('Cancelled');
        }
        dataSocket.add(chunk);
        uploaded += chunk.length;
        if (fileSize > 0) {
          onProgress((uploaded / fileSize).clamp(0.0, 1.0));
        }
      }

      await dataSocket.flush();
      await dataSocket.close();
      dataSocket = null;
      _activeUploadDataSocket = null;

      // Read final 226 response
      responseCompleter = Completer<String>();
      try {
        await responseCompleter!.future.timeout(const Duration(seconds: 10));
      } catch (_) {}

      // Graceful quit
      try { controlSocket.write('QUIT\r\n'); } catch (_) {}

      // 注意：此处**不再**同步等待服务端最终化（之前的 _waitForUploadFinalized
      // 会阻塞 uploadFile 返回，导致进度弹窗卡在 100% 很久）。服务端重命名的
      // 等待改由 provider 在后台异步轮询 loadDirectory 完成，UI 全程可响应。
      onProgress(1.0);
    } catch (e) {
      // cancel() 会销毁 socket，进行中的上传会在此抛异常；此时应视为取消
      if (isCancelled) throw Exception('Cancelled');
      rethrow;
    } finally {
      await controlSub?.cancel();
      try { dataSocket?.destroy(); } catch (_) {}
      try { controlSocket?.destroy(); } catch (_) {}
      _activeUploadDataSocket = null;
      _activeUploadControlSocket = null;

      // 上传使用的独立控制/数据连接断开后，部分 FTP 服务器会重置或影响主
      // listing 会话，导致后续 listDirectory 在旧 _ftpConnect 上挂起。
      // 因此无论上传成功还是取消，都立即重建 _ftpConnect，保证后续刷新
      // 和轮询能正常进行。
      try {
        await _ftpConnect?.disconnect();
      } catch (_) {}
      _ftpConnect = FTPConnect(
        host,
        port: port,
        user: username.isEmpty ? 'anonymous' : username,
        pass: password.isEmpty ? 'anonymous@' : password,
        timeout: 15,
      );
      try {
        await _ftpConnect!.connect().timeout(const Duration(seconds: 15));
      } catch (e) {
        debugPrint('FTP reconnect after upload failed: $e');
        _ftpConnect = null;
      }
    }
  }

  /// 取消上传时清理服务端残留：删除已上传的半截目标文件，以及 STOR 期间
  /// 服务端（如飞牛 NAS）生成的 file-<随机数字> 临时文件。
  ///
  /// 使用独立的 listing 会话（[_ftpConnect]）执行删除，与进行中的上传数据
  /// 连接互不干扰，确保取消后目录里不留下残缺文件。整体有超时保护：FTP
  /// 服务器在取消瞬间可能卡住 delete，若等待过久会拖住 [uploadFile] 返回、
  /// 导致进度弹窗卡住，故 6s 后放弃清理（残留文件由 provider 的延迟刷新或
  /// 用户重新进入目录时再处理）。
  Future<void> _abortAndCleanupUpload(String remoteDir, String remoteFileName) async {
    if (_ftpConnect == null) return;
    try {
      await (() async {
        try {
          await delete(p.join(remoteDir, remoteFileName), false);
        } catch (_) {}
        try {
          await _cleanupStrayTemp(remoteDir, remoteFileName);
        } catch (_) {}
      })().timeout(const Duration(seconds: 6));
    } catch (_) {}
  }

  /// 取消上传时清理服务端残留的 file-<随机数字>（无后缀）临时文件。
  ///
  /// 这些临时文件由服务端在 STOR 过程中创建，正常情况下会在传输完成后被
  /// 重命名为目标文件。成功上传时不能删除它们（里面可能是真实数据），只
  /// 有在取消上传时才删除，避免目录里留下残缺垃圾。
  Future<void> _cleanupStrayTemp(String remoteDir, String targetName) async {
    if (_ftpConnect == null) return;
    try {
      final items = await listDirectory(remoteDir, forceRefresh: true);
      final cutoff = DateTime.now().subtract(const Duration(seconds: 120));
      for (final item in items) {
        if (item.isDirectory) continue;
        if (item.name == targetName) continue;
        if (RegExp(r'^file-\d+$').hasMatch(item.name) &&
            item.modified.isAfter(cutoff)) {
          try { await delete(item.path, false); } catch (_) {}
        }
      }
    } catch (_) {}
  }

  /// 上传完成后最终化：部分 FTP/NAS 在 STOR 期间把真实数据写入 file-<随机>
  /// 临时文件，关闭数据连接后应重命名为目标文件。若服务端因目标文件已存在
  /// 等原因未自动完成重命名，此处主动处理：
  ///
  /// 1. 找到目标目录下符合 `file-<数字>` 且最近创建的临时文件；
  /// 2. 若临时文件大小 >= [expectedSize] 的 95%，视为完整上传，删除旧目标
  ///    文件（如果存在）并把临时文件重命名为目标文件名；
  /// 3. 若临时文件明显不完整，则直接删除临时文件，避免目录里残留垃圾；
  /// 4. 若不存在临时文件，返回 false（无需处理）。
  ///
  /// 整个操作有 10 秒超时保护，避免挂起。返回值表示是否发现并处理了临时
  /// 文件。
  Future<bool> finalizeUpload(String remoteDir, String targetName, int expectedSize) async {
    if (_ftpConnect == null) return false;
    try {
      return await (() async {
        final items = await listDirectory(remoteDir, forceRefresh: true);
        RemoteFileItem? tempItem;
        RemoteFileItem? targetItem;
        for (final item in items) {
          if (item.isDirectory) continue;
          if (RegExp(r'^file-\d+(\.|$)').hasMatch(item.name)) {
            // 取最新创建的临时文件（服务端可能残留历史临时文件）
            if (tempItem == null || item.modified.isAfter(tempItem.modified)) {
              tempItem = item;
            }
          } else if (item.name == targetName) {
            targetItem = item;
          }
        }
        if (tempItem == null) return false;

        final tempPath = tempItem.path;
        final targetPath = remoteDir == '/' ? '/$targetName' : '$remoteDir/$targetName';

        // 临时文件足够完整 → 用它替换目标文件
        if (expectedSize > 0 && tempItem.size >= (expectedSize * 0.95).round()) {
          if (targetItem != null) {
            try { await delete(targetItem.path, false); } catch (_) {}
          }
          try {
            await rename(tempPath, targetPath);
            return true;
          } catch (e) {
            debugPrint('FTP finalizeUpload rename failed: $e');
            // rename 失败时至少删掉临时文件，避免用户看到两个文件
            try { await delete(tempPath, false); } catch (_) {}
            return true;
          }
        } else {
          // 临时文件不完整 → 删除
          try { await delete(tempPath, false); } catch (_) {}
          return true;
        }
      })().timeout(const Duration(seconds: 10));
    } catch (e) {
      debugPrint('FTP finalizeUpload error: $e');
      return false;
    }
  }

  @override
  Future<int> getFileSize(String remotePath) async {
    if (_ftpConnect == null) throw Exception('FTP not connected');
    final fileName = p.basename(remotePath);
    final parentPath = p.dirname(remotePath);

    try {
      if (parentPath.isNotEmpty && parentPath != '/') {
        final ok = await _ftpConnect!.changeDirectory(parentPath)
            .timeout(const Duration(seconds: 15));
        if (!ok) return -1;
      } else {
        await _ftpConnect!.changeDirectory('/')
            .timeout(const Duration(seconds: 15));
      }
      final size = await _ftpConnect!.sizeFile(fileName).timeout(const Duration(seconds: 15));
      return size >= 0 ? size : -1;
    } catch (_) {
      return -1;
    }
  }

  @override
  String? getStreamUrl(String remotePath) => null;
}
