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
  Future<List<RemoteFileItem>> listDirectory(String path) async {
    if (_ftpConnect == null) throw Exception('FTP not connected');

    final targetPath = (path.isEmpty || path == '/') ? '/' : path;

    List<FTPEntry> allEntries;
    try {
      // Navigate to directory with timeout
      if (targetPath != '/') {
        final ok = await _ftpConnect!
            .changeDirectory(targetPath)
            .timeout(const Duration(seconds: 30));
        if (!ok) throw Exception('Cannot open directory: $targetPath');
      } else {
        await _ftpConnect!
            .changeDirectory('/')
            .timeout(const Duration(seconds: 30));
      }

      allEntries = await _ftpConnect!
          .listDirectoryContent()
          .timeout(const Duration(seconds: 30));
    } catch (e) {
      // If changeDirectory failed, attempt to reconnect once
      if (e.toString().contains('Cannot open directory') ||
          e.toString().contains('TimeoutException')) {
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
        // Retry the listing once
        if (targetPath != '/') {
          final ok = await _ftpConnect!
              .changeDirectory(targetPath)
              .timeout(const Duration(seconds: 30));
          if (!ok) throw Exception('Cannot open directory: $targetPath');
        } else {
          await _ftpConnect!
              .changeDirectory('/')
              .timeout(const Duration(seconds: 30));
        }
        allEntries = await _ftpConnect!
            .listDirectoryContent()
            .timeout(const Duration(seconds: 30));
      } else {
        rethrow;
      }
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
          final ok = await _ftpConnect!
              .deleteDirectory(path)
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
        final match = RegExp(r'(\d+)').firstMatch(sizeResp);
        if (match != null) {
          fileSize = int.parse(match.group(1)!);
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

    // Navigate to the destination directory
    if (remoteDir.isNotEmpty && remoteDir != '/') {
      await _ftpConnect!.createFolderIfNotExist(remoteDir);
      final ok = await _ftpConnect!.changeDirectory(remoteDir);
      if (!ok) throw Exception('Cannot open remote directory: $remoteDir');
    }

    onProgress(0.0);

    final ok = await _ftpConnect!.uploadFile(
      localFile,
      sRemoteName: remoteFileName,
      onProgress: (progressPercent, sent, fileSize) {
        onProgress((progressPercent / 100.0).clamp(0.0, 1.0));
      },
    );

    if (!ok) throw Exception('Upload failed for: $localPath');
    onProgress(1.0);
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
