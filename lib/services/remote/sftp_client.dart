import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:dartssh2/dartssh2.dart';
import 'remote_client.dart';

class SftpRemoteClient extends RemoteClient {
  final String host;
  final int port;
  final String username;
  final String password;
  
  SSHClient? _sshClient;
  SftpClient? _sftpClient;

  SftpRemoteClient({
    required this.host,
    required this.port,
    required this.username,
    required this.password,
  });

  @override
  Future<void> connect() async {
    SSHSocket socket;
    try {
      socket = await SSHSocket.connect(host, port, timeout: const Duration(seconds: 15));
    } catch (e) {
      // Retry once if connection fails
      socket = await SSHSocket.connect(host, port, timeout: const Duration(seconds: 15));
    }
    _sshClient = SSHClient(
      socket,
      username: username,
      onPasswordRequest: () => password,
    );
    _sftpClient = await _sshClient!.sftp();
  }

  @override
  Future<void> disconnect() async {
    _sshClient?.close();
    await _sshClient?.done;
    _sshClient = null;
    _sftpClient = null;
  }

  @override
  Future<List<RemoteFileItem>> listDirectory(String path, {bool forceRefresh = false}) async {
    if (_sftpClient == null) throw Exception('SFTP not connected');
    
    var targetPath = path;
    if (targetPath.isEmpty || targetPath == '/') {
      targetPath = '.';
    }
    
    late final List<SftpName> items;
    try {
      items = await _sftpClient!.listdir(targetPath).timeout(const Duration(seconds: 30));
    } catch (e) {
      if (targetPath == '.') {
        try {
          items = await _sftpClient!.listdir('').timeout(const Duration(seconds: 30));
        } catch (e2) {
          throw Exception('Failed to list directory: $e');
        }
      } else {
        throw Exception('Failed to list directory: $e');
      }
    }
    
    final list = <RemoteFileItem>[];
    // Collect items that need stat calls (mode is null)
    final needStat = <int, String>{};
    
    for (int i = 0; i < items.length; i++) {
      final item = items[i];
      if (item.filename == '.' || item.filename == '..') continue;
      
      var isDir = item.attr.isDirectory;
      // If mode is null, try parsing the longname field first (no network call)
      if (item.attr.mode == null) {
        if (item.longname != null && item.longname!.isNotEmpty) {
          // Unix-style longname: first character indicates file type
          // 'd' = directory, '-' = regular file, 'l' = symlink
          isDir = item.longname!.startsWith('d');
        } else {
          // No longname available — mark for batch stat
          final statPath = (targetPath == '.' || targetPath == '')
              ? item.filename
              : '$targetPath/${item.filename}';
          needStat[i] = statPath;
        }
      }
      
      final fullPath = (path == '/' || path.isEmpty) 
          ? '/${item.filename}' 
          : '${path.endsWith('/') ? path.substring(0, path.length - 1) : path}/${item.filename}';
      
      final modifyTimeSeconds = item.attr.modifyTime;
      final modifiedDate = modifyTimeSeconds != null
          ? DateTime.fromMillisecondsSinceEpoch(modifyTimeSeconds * 1000)
          : DateTime.now();

      list.add(RemoteFileItem(
        name: item.filename,
        path: fullPath,
        isDirectory: isDir,
        size: item.attr.size ?? 0,
        modified: modifiedDate,
      ));
    }
    
    // Batch stat calls for items with missing mode (parallel, capped at 8 concurrent)
    if (needStat.isNotEmpty) {
      // Build a name→index map for O(1) lookup when updating results
      final nameToIdx = <String, int>{};
      for (int i = 0; i < list.length; i++) {
        nameToIdx[list[i].name] = i;
      }

      final indices = needStat.keys.toList();
      const batchSize = 8;
      for (int i = 0; i < indices.length; i += batchSize) {
        final batchEnd = (i + batchSize < indices.length) ? i + batchSize : indices.length;
        final batchIndices = indices.sublist(i, batchEnd);

        final results = await Future.wait(
          batchIndices.map((idx) => _sftpClient!.stat(needStat[idx]!)
              .timeout(const Duration(seconds: 5))
              .catchError((_) => null)),
        );

        for (int j = 0; j < results.length; j++) {
          if (results[j] != null) {
            final itemIdx = batchIndices[j];
            final name = items[itemIdx].filename;
            final idx = nameToIdx[name];
            if (idx != null) {
              list[idx] = RemoteFileItem(
                name: list[idx].name,
                path: list[idx].path,
                isDirectory: results[j]!.isDirectory,
                size: list[idx].size,
                modified: list[idx].modified,
              );
            }
          }
        }
      }
    }
    
    return list;
  }

  @override
  Future<void> createDirectory(String path) async {
    if (_sftpClient == null) throw Exception('SFTP not connected');
    await _sftpClient!.mkdir(path);
  }

  @override
  Future<void> createFile(String path) async {
    if (_sftpClient == null) throw Exception('SFTP not connected');
    final remoteFile = await _sftpClient!.open(
      path,
      mode: SftpFileOpenMode.create | SftpFileOpenMode.truncate | SftpFileOpenMode.write,
    );
    await remoteFile.write(Stream.fromIterable([])).done;
  }

  @override
  Future<void> delete(String path, bool isDir) async {
    if (_sftpClient == null) throw Exception('SFTP not connected');
    // SFTP 删除偶尔会因网络抖动或服务器锁文件失败，增加重试逻辑
    const maxRetries = 3;
    Exception? lastError;
    for (int attempt = 0; attempt < maxRetries; attempt++) {
      try {
        if (isDir) {
          await _sftpClient!
              .rmdir(path)
              .timeout(const Duration(seconds: 30));
        } else {
          await _sftpClient!
              .remove(path)
              .timeout(const Duration(seconds: 30));
        }
        return; // 成功则直接返回
      } on TimeoutException {
        lastError = Exception('SFTP delete timed out');
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
            msg.contains('ssh_fx_no_such_file')) {
          rethrow;
        }
        // 其他错误（网络抖动、服务器锁文件等）延迟后重试
        if (attempt < maxRetries - 1) {
          await Future.delayed(Duration(milliseconds: 500 * (attempt + 1)));
        }
      }
    }
    // 所有重试都失败，抛出最后一个错误
    throw Exception('SFTP delete failed after $maxRetries attempts: $lastError');
  }

  @override
  Future<void> rename(String oldPath, String newPath) async {
    if (_sftpClient == null) throw Exception('SFTP not connected');
    await _sftpClient!.rename(oldPath, newPath);
  }

  @override
  Future<void> downloadFile(String remotePath, String localPath, Function(double progress) onProgress) async {
    if (_sftpClient == null) throw Exception('SFTP not connected');

    final file = await _sftpClient!.open(remotePath);
    // stat 可能耗时，用 5s 超时获取文件大小用于进度报告
    int totalSize = 0;
    try {
      final stat = await _sftpClient!.stat(remotePath)
          .timeout(const Duration(seconds: 5));
      totalSize = stat.size ?? 0;
    } catch (_) {
      // stat 超时或失败 — 继续下载，进度不更新
    }

    final localFile = File(localPath);
    final sink = localFile.openWrite();

    int downloaded = 0;
    int sinceFlush = 0;
    bool isFirstChunk = true;
    // 首块立即 flush（让代理尽快看到数据），后续每 64KB flush 一次。
    // 之前 4KB+1ms delay 限制了吞吐量到 ~1.5MB/s（4KB/3ms≈1.3MB/s）。
    // 64KB flush 可达到 ~10-20MB/s，满足高清视频播放需求。
    const flushInterval = 64 * 1024; // 64KB
    try {
      final stream = file.read().timeout(
        const Duration(seconds: 120),
        onTimeout: (eventSink) {
          eventSink.addError(
            Exception('SFTP read timed out: no data for 120s'),
          );
          eventSink.close();
        },
      );
      await for (final chunk in stream) {
        if (isCancelled) break;
        sink.add(chunk);
        downloaded += chunk.length;
        sinceFlush += chunk.length;
        if (totalSize > 0) {
          onProgress((downloaded / totalSize).clamp(0.0, 1.0));
        }
        // Flush immediately on first chunk so the streaming proxy sees the
        // file has data without waiting for the 100ms polling interval.
        // For subsequent chunks, flush every flushInterval bytes.
        if (isFirstChunk || sinceFlush >= flushInterval) {
          await sink.flush();
          sinceFlush = 0;
          isFirstChunk = false;
        }
      }
    } finally {
      await sink.flush();
      await sink.close();
      await file.close();
    }
  }

  @override
  Future<void> downloadRange(String remotePath, String localPath, int startByte, int length) async {
    if (_sftpClient == null) throw Exception('SFTP not connected');

    final file = await _sftpClient!.open(remotePath);
    final localFile = File(localPath);
    final sink = localFile.openWrite();

    try {
      // dartssh2 的 read() 原生支持 offset + length，底层发起 SSH_FXP_READ 请求
      final stream = file.read(offset: startByte, length: length).timeout(
        const Duration(seconds: 60),
        onTimeout: (eventSink) {
          eventSink.addError(Exception('SFTP readRange timed out: no data for 60s'));
          eventSink.close();
        },
      );
      int downloaded = 0;
      await for (final chunk in stream) {
        if (downloaded + chunk.length > length) {
          // 防止超出请求范围
          sink.add(chunk.sublist(0, length - downloaded));
          break;
        }
        sink.add(chunk);
        downloaded += chunk.length;
      }
    } finally {
      await sink.flush();
      await sink.close();
      await file.close();
    }
  }

  @override
  Future<void> uploadFile(
    String localPath,
    String remotePath,
    Function(double progress) onProgress,
  ) async {
    if (_sftpClient == null) throw Exception('SFTP not connected');

    final localFile = File(localPath);
    if (!localFile.existsSync()) throw Exception('Local file not found: $localPath');

    final totalSize = await localFile.length();

    // Open remote file for writing
    final remoteFile = await _sftpClient!.open(
      remotePath,
      mode: SftpFileOpenMode.create | SftpFileOpenMode.truncate | SftpFileOpenMode.write,
    );

    onProgress(0.0);

    try {
      // 使用 write(Stream) 流水线模式而非 writeBytes 逐块写入
      // writeBytes 每次都要等待服务器返回 SSH_FXP_STATUS（串行往返），
      // 导致速度仅 ~1.5MB/s（64KB / 40ms RTT）。
      // write(Stream) 内部做流水线，吞吐量提升 10-30 倍。
      // 通过自定义 Stream 拦截每个 chunk 实现取消和进度回调。
      int uploaded = 0;
      final transformedStream = localFile.openRead().map((chunk) {
        if (isCancelled) {
          throw Exception('Cancelled');
        }
        uploaded += chunk.length;
        if (totalSize > 0) {
          onProgress((uploaded / totalSize).clamp(0.0, 1.0));
        }
        return Uint8List.fromList(chunk);
      });
      final writer = remoteFile.write(transformedStream);
      await writer.done;
    } finally {
      await remoteFile.close();
    }

    if (!isCancelled) {
      onProgress(1.0);
    }
  }

  @override
  Future<int> getFileSize(String remotePath) async {
    if (_sftpClient == null) throw Exception('SFTP not connected');
    try {
      final stat = await _sftpClient!.stat(remotePath).timeout(const Duration(seconds: 10));
      return stat.size ?? -1;
    } catch (_) {
      return -1;
    }
  }

  @override
  String? getStreamUrl(String remotePath) => null;
}
