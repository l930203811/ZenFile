import 'dart:io';
import 'dart:async';
import 'dart:typed_data';
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
  // 下载使用的独立控制/数据 socket（由 _downloadWithRawSocket 设置），
  // 取消时一并销毁，才能立即中断进行中的下载（否则后台会持续读 socket 直到完成）。
  Socket? _activeDownloadControlSocket;
  Socket? _activeDownloadDataSocket;

  /// 异步互斥锁（Future 链）：串行化所有依赖单连接的 CWD 状态的操作
  /// （[listDirectory] / [finalizeUpload] 内的 rename）。FTP 是单连接协议，
  /// CWD+LIST 不可并发；同一 `_ftpConnect` 的并发 LIST 会导致 CWD 状态错乱、
  /// 应用闪退（问题3）。通过此队列保证任意时刻只有一个 CWD 相关操作在执行。
  Future<void>? _serialQueue;

  /// 把 [fn] 串行进队执行，返回其结果。前一个任务异常不会阻塞队列推进。
  Future<T> _serialize<T>(Future<T> Function() fn) {
    final completer = Completer<T>();
    final prev = _serialQueue ?? Future<void>.value();
    _serialQueue = prev.then((_) async {
      try {
        completer.complete(await fn());
      } catch (e) {
        completer.completeError(e);
      }
    }).catchError((_) {/* 吞咽前一任务的异常，继续推进队列 */});
    return completer.future;
  }

  @override
  void cancel() {
    // 必须同步置位基类的 _cancelled 标志，否则 isCancelled 永远为 false，
    // 所有基于 isCancelled 的取消检查（如下载循环的 if (isCancelled) break）
    // 都会失效。
    super.cancel();
    // 手动上传使用独立的控制/数据 socket，必须一并销毁才能立即中断传输。
    try { _activeUploadControlSocket?.destroy(); } catch (_) {}
    try { _activeUploadDataSocket?.destroy(); } catch (_) {}
    // 下载同样使用独立 socket：销毁后才能立即中断进行中的下载，
    // 否则后台会持续读取数据 socket 直到整文件传输完成。
    try { _activeDownloadControlSocket?.destroy(); } catch (_) {}
    try { _activeDownloadDataSocket?.destroy(); } catch (_) {}
    // 修复B（问题1）：不再调用 _ftpConnect?.disconnect()。浏览会话 _ftpConnect 与
    // 传输所用的独立 socket 解耦——下载走 _downloadWithRawSocket（独立 socket +
    // isCancelled 检查），上传走独立控制/数据 socket 且 finally 会重建 _ftpConnect。
    // 断开浏览会话对中断传输无益，却会破坏取消后的目录刷新（配合修复A 保留旧列表，
    // 但若 _ftpConnect 被断则手动刷新会失败）。因此取消时只销毁活跃传输 socket。
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
    // 串行化：FTP 单连接，CWD+LIST 不可并发（问题3 闪退根因之一）。
    return _serialize(() => _listDirectoryInner(path, forceRefresh: forceRefresh));
  }

  /// [listDirectory] 的实际实现（必须在 [_serialize] 内调用，禁止再加锁，
  /// 否则 finalizeUpload 持锁调用时会死锁）。
  Future<List<RemoteFileItem>> _listDirectoryInner(String path, {bool forceRefresh = false}) async {
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
      // 取消导致的异常（isCancelled 为 true）一律不再回退到不可取消的
      // ftpconnect 缓冲路径，否则会「点了取消后台仍下载到完成」。
      if (isCancelled) {
        try { File(localPath).deleteSync(); } catch (_) {}
        throw Exception('Cancelled');
      }
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
            // 兜底路径同样响应取消：ftpconnect 会把整文件缓冲到 IOSink，
            // 若不在此拦截则取消无效（后台持续下载到完成）。
            if (isCancelled) {
              throw Exception('Cancelled');
            }
            onProgress((progressPercent / 100.0).clamp(0.0, 1.0));
          },
        )
        .timeout(Duration(minutes: timeoutMinutes));

    if (!ok) throw Exception('Download failed for: $remotePath');
    // 下载完成后若已处于取消状态（onProgress 拦截未生效），删除半截文件并抛出。
    if (isCancelled) {
      try { localFile.deleteSync(); } catch (_) {}
      throw Exception('Cancelled');
    }
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
      _activeDownloadControlSocket = controlSocket;

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
      _activeDownloadDataSocket = dataSocket;

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
      // 首块立即 flush（让代理尽快看到数据），后续每 1MB flush 一次。
      // 关键修复：原先每 64KB flush 一次，在千兆网下「await sink.flush()」会卡住
      // 读循环、收缩 TCP 接收窗口，导致服务端被限到 30-40MB/s；放大到 1MB 后读
      // 循环几乎不被打断，FTP 下载可跑满带宽（与上传 512KB flush 同思路）。
      // （上传用 512KB flush 即满速；下载写盘略慢，故用更大的 1MB 间隔。）
      int downloaded = 0;
      int sinceFlush = 0;
      bool isFirstChunk = true;
      const flushInterval = 1024 * 1024; // 1MB

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

      // 不等待最终 226 响应：150 响应完成时 responseCompleter 已置 null，
      // 226 到达时被 listen 回调丢弃，此处的等待必然等满 5s 超时——旧实现
      // 让每次下载（含流式代理的按需 seek downloadRange）结尾白等 5 秒，
      // 播放器拖动后 6-8s 才拿到数据，mpv seek 超时跳回原位置。
      // 数据流（dataSocket done）即传输完成，直接 QUIT 即可；服务器随后发来
      // 的 226/221 响应会被丢弃，无害。

      // Quit
      controlSocket.write('QUIT\r\n');
      onProgress(1.0);
      } finally {
        await controlSub?.cancel();
        try { await sink?.close(); } catch (_) {}
        try { await dataSocket?.close(); } catch (_) {}
        try { await controlSocket?.close(); } catch (_) {}
        _activeDownloadControlSocket = null;
        _activeDownloadDataSocket = null;
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
      int sinceFlush = 0;

      // 用 1MB readBuffer 通过 RandomAccessFile 读取，替代 openRead() 的 64KB 默认分块。
      // 更大的读取块减少 dataSocket.add() 调用次数和 TCP 小包数量，提升上传吞吐。
      // flush 间隔也从 512KB 增大到 1MB，与下载路径对称，减少 flush 阻塞打断发送循环。
      final raf = await localFile.open();
      const chunkSize = 1024 * 1024; // 1MB
      final readBuffer = Uint8List(chunkSize);
      try {
        while (true) {
          if (isCancelled) {
            try { dataSocket.destroy(); } catch (_) {}
            _activeUploadDataSocket = null;
            try { await _abortAndCleanupUpload(remoteDir, remoteFileName); } catch (_) {}
            throw Exception('Cancelled');
          }
          final n = await raf.readInto(readBuffer);
          if (n <= 0) break;
          // 仅发送实际读取到的字节（最后一块可能不足 1MB）
          final chunk = n < chunkSize ? Uint8List.sublistView(readBuffer, 0, n) : readBuffer;
          dataSocket.add(chunk);
          uploaded += n;
          sinceFlush += n;
          // 每 1MB flush 一次，确保数据从 Dart Socket 缓冲区真正发送到网络。
          if (sinceFlush >= chunkSize) {
            await dataSocket.flush();
            sinceFlush = 0;
          }
          if (fileSize > 0) {
            onProgress((uploaded / fileSize).clamp(0.0, 0.95));
          }
        }
      } finally {
        await raf.close();
      }

      await dataSocket.flush();
      await dataSocket.close();
      dataSocket = null;
      _activeUploadDataSocket = null;

      // 取消可能发生在数据刚写完、尚未读到 226 的窗口期；此时直接视为取消，
      // 避免等待服务端 226 响应（最多 10s）导致进度弹窗卡住。
      if (isCancelled) {
        throw Exception('Cancelled');
      }

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
  /// 取消瞬间服务端可能仍处于 STOR 中断的异常状态，复用主 listing 会话（
  /// [_ftpConnect]）删除容易卡住或失败，因此这里使用**全新独立连接**执行
  /// 删除，并以“列表验证”确认残留确实被清除；全程有超时保护，避免拖住
  /// [uploadFile] 返回导致进度弹窗卡死。清理失败不会静默吞掉——会记录日志，
  /// 最多重试 3 次，确保残留文件（目标 + 临时）被尽可能删除。
  Future<void> _abortAndCleanupUpload(String remoteDir, String remoteFileName) async {
    const maxAttempts = 3;
    for (int attempt = 0; attempt < maxAttempts; attempt++) {
      FTPConnect? cleanupConn;
      try {
        await (() async {
          cleanupConn = FTPConnect(
            host,
            port: port,
            user: username.isEmpty ? 'anonymous' : username,
            pass: password.isEmpty ? 'anonymous@' : password,
            timeout: 15,
          );
          final ok = await cleanupConn!.connect().timeout(const Duration(seconds: 15));
          if (!ok) throw Exception('cleanup connect failed');

          // 删除目标文件（若服务端已写入半截目标文件）。
          try {
            if (remoteDir.isNotEmpty && remoteDir != '/') {
              await cleanupConn!.changeDirectory(remoteDir).timeout(const Duration(seconds: 15));
            } else {
              await cleanupConn!.changeDirectory('/').timeout(const Duration(seconds: 15));
            }
            await cleanupConn!.deleteFile(remoteFileName).timeout(const Duration(seconds: 15));
          } catch (e) {
            debugPrint('FTP cleanup delete target failed (may not exist): $e');
          }

          // 删除所有 file-<随机> 临时文件。
          try {
            final items = await _listWith(cleanupConn!, remoteDir);
            final cutoff = DateTime.now().subtract(const Duration(seconds: 300));
            for (final item in items) {
              if (item.isDirectory) continue;
              if (item.name == remoteFileName) continue;
              if (RegExp(r'^file-\d+(\.|$)').hasMatch(item.name) &&
                  item.modified.isAfter(cutoff)) {
                try {
                  await cleanupConn!.deleteFile(item.name).timeout(const Duration(seconds: 15));
                } catch (e) {
                  debugPrint('FTP cleanup delete temp failed: $e');
                }
              }
            }
          } catch (e) {
            debugPrint('FTP cleanup list temp failed: $e');
          }
        })().timeout(const Duration(seconds: 10));

        // 验证：列一遍目录，确认目标与临时文件都已消失，才认为清理成功。
        try {
          final remaining = await _listWith(cleanupConn!, remoteDir);
          final stillThere = remaining.any((it) =>
              !it.isDirectory &&
              (it.name == remoteFileName || RegExp(r'^file-\d+(\.|$)').hasMatch(it.name)));
          if (!stillThere) return; // 清理成功，无需重试
        } catch (_) {}
      } catch (e) {
        debugPrint('FTP _abortAndCleanupUpload attempt $attempt failed: $e');
      } finally {
        try { await cleanupConn?.disconnect(); } catch (_) {}
      }
      await Future.delayed(const Duration(milliseconds: 500));
    }
  }

  /// 使用给定的 [conn]（而非 [this._ftpConnect]）列出 [path] 内容，便于在取消
  /// 清理等场景下用独立连接操作，避免复用可能处于异常状态的会话。
  Future<List<RemoteFileItem>> _listWith(FTPConnect conn, String path) async {
    final targetPath = (path.isEmpty || path == '/') ? '/' : path;
    if (targetPath != '/') {
      final ok = await conn.changeDirectory(targetPath).timeout(const Duration(seconds: 30));
      if (!ok) throw Exception('Cannot open directory: $targetPath');
    } else {
      try {
        await conn.changeDirectory('/').timeout(const Duration(seconds: 30));
      } catch (_) {}
    }
    final entries = await conn.listDirectoryContent().timeout(const Duration(seconds: 30));
    final list = <RemoteFileItem>[];
    for (final entry in entries) {
      if (entry.name == '.' || entry.name == '..') continue;
      if (entry.type == FTPEntryType.unknown) continue;
      final fullPath = path == '/' ? '/${entry.name}' : '$path/${entry.name}';
      list.add(RemoteFileItem(
        name: entry.name,
        path: fullPath,
        isDirectory: entry.type == FTPEntryType.dir,
        size: entry.size ?? 0,
        modified: entry.modifyTime ?? DateTime.now(),
      ));
    }
    return list;
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
        if (RegExp(r'^file-\d+(\.|$)').hasMatch(item.name) &&
            item.modified.isAfter(cutoff)) {
          try { await delete(item.path, false); } catch (_) {}
        }
      }
    } catch (_) {}
  }

  /// 上传完成后最终化：部分 FTP/NAS 在 STOR 期间把真实数据写入 file-<随机>
  /// 临时文件，关闭数据连接后才重命名为目标文件。
  ///
  /// **判定能否返回“已最终化”的唯一可靠标准**：目录里 **目标文件存在** 且
  /// **没有任何 file-<随机> 临时文件** 残留，且目标大小达标。只要还有临时文件
  /// 残留，就视为服务端仍在最终化（重命名），返回 false 等待下次轮询。
  ///
  /// **重要（数据完整性）**：本方法在“临时文件完整、目标缺失”时才会主动把
  /// 临时文件重命名为目标文件；**绝不删除**临时文件——上传结束后服务端仍在把
  /// 内存数据刷盘/重命名，此时 LIST 看到的临时文件可能“不完整”，贸然删除会
  /// 直接销毁刚上传的文件（表现为“目录为空、刷新/重启后文件仍丢失”）。
  ///
  /// 返回值：目标文件是否已最终化（存在、无临时文件、大小达标）。
  Future<bool> finalizeUpload(String remoteDir, String targetName, int expectedSize) async {
    if (_ftpConnect == null) return false;
    try {
      // 在 [_serialize] 内执行：本方法会 LIST 并在 rename 分支里 changeDirectory，
      // 与并发的手动刷新 LIST 共享同一单连接，必须串行以避免 CWD 错乱（问题3）。
      return await _serialize(() => _finalizeUploadInner(remoteDir, targetName, expectedSize))
          .timeout(const Duration(seconds: 10));
    } catch (e) {
      debugPrint('FTP finalizeUpload error: $e');
      return false;
    }
  }

  Future<bool> _finalizeUploadInner(String remoteDir, String targetName, int expectedSize) async {
    // 直接调用 _listDirectoryInner（持锁内），避免经公共 listDirectory 重复加锁死锁。
    final items = await _listDirectoryInner(remoteDir, forceRefresh: true);
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

    // 有临时文件残留：根据完整性决定主动最终化还是继续等待。
    if (tempItem != null) {
      // 临时文件已完整（大小达标或未知期望大小）
      if (expectedSize <= 0 || tempItem.size >= (expectedSize * 0.95).round()) {
        // 目标文件不存在 → 主动 rename（飞牛 NAS 覆盖场景：服务端不会自动 rename）
        if (targetItem == null) {
          try {
            if (remoteDir.isNotEmpty && remoteDir != '/') {
              await _ftpConnect!
                  .changeDirectory(remoteDir)
                  .timeout(const Duration(seconds: 15));
            } else {
              await _ftpConnect!
                  .changeDirectory('/')
                  .timeout(const Duration(seconds: 15));
            }
            await rename(tempItem.name, targetName);
            return true;
          } catch (e) {
            debugPrint('FTP finalizeUpload rename failed: $e');
            return false;
          }
        }
        // 目标文件已存在 → 服务端正在自己处理（如 openlist 流式写入目标
        // 文件）。**不主动 rename**：部分服务端（如 openlist 本机储存）
        // 的 rename 可能退化为"复制+删除"，对大文件会导致与重新上传
        // 相当的数据复制量。等待服务端自己清理临时文件即可。
        if (expectedSize > 0 && targetItem.size < (expectedSize * 0.95).round()) {
          return false; // 目标文件大小未达标，继续等待
        }
        return true; // 目标文件已达标，临时文件由服务端清理
      }
      // 临时文件不完整 → 服务端仍在刷盘，等待，绝不删除。
      return false;
    }

    // 没有任何临时文件：
    if (targetItem == null) {
      // 目标也不存在 → 尚未落盘，继续等待。
      return false;
    }
    // 目标存在且无临时文件 → 校验大小（若已知期望大小）。
    if (expectedSize > 0 && targetItem.size < (expectedSize * 0.95).round()) {
      // 大小不足：可能是旧文件或上传不完整，继续等待。
      return false;
    }
    return true;
  }

  /// 列出目录内容（带重连保护），供 finalizeUpload / _cleanupStrayTemp 复用，
  /// 避免在异常会话上 LIST 卡死。
  /// 注意：调用方必须已在 [_serialize] 内（如 finalizeUpload），或自行串行，
  /// 故此处直接调用 [_listDirectoryInner]（不再经公共 listDirectory 加锁）。
  Future<List<RemoteFileItem>> listDirectoryContentSafe(String targetPath) async {
    try {
      return await _listDirectoryInner(targetPath, forceRefresh: true);
    } catch (e) {
      // 列表失败：重连一次后重试。
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
      if (!reconnected) throw Exception('FTP reconnection failed: $e');
      return await _listDirectoryInner(targetPath, forceRefresh: true);
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
