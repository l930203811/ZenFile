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
    if (targetPath.isEmpty) {
      targetPath = '/';
    }
    // 注意：根路径使用绝对路径 '/' 而不是 '.'（登录后的 home）。
    // 飞牛 NAS 等服务把所有共享目录挂在绝对根 '/' 下；若列 '.'（home 目录）
    // 只会显示 home 内的部分共享，表现为"只显示部分共享目录"。其他同类客户端
    // 列的是 '/'，因此能看到全部共享。若 '/' 无权限，再回退到 '.'。
    // （dartssh2 的 listdir 已正确处理分页，不是分页导致的截断。）

    late final List<SftpName> items;
    try {
      items = await _sftpClient!.listdir(targetPath).timeout(const Duration(seconds: 30));
    } catch (e) {
      if (targetPath == '/') {
        try {
          items = await _sftpClient!.listdir('.').timeout(const Duration(seconds: 30));
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
        if (item.longname.isNotEmpty) {
          // Unix-style longname: first character indicates file type
          // 'd' = directory, '-' = regular file, 'l' = symlink
          isDir = item.longname.startsWith('d');
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
              .catchError((_) => SftpFileAttrs())),
        );

        for (int j = 0; j < results.length; j++) {
          final itemIdx = batchIndices[j];
          final name = items[itemIdx].filename;
          final idx = nameToIdx[name];
          if (idx != null) {
            list[idx] = RemoteFileItem(
              name: list[idx].name,
              path: list[idx].path,
              isDirectory: results[j].isDirectory,
              size: list[idx].size,
              modified: list[idx].modified,
            );
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

    // stat 获取文件大小，用于划分并发窗口与进度报告（5s 超时）
    int totalSize = 0;
    try {
      final stat = await _sftpClient!.stat(remotePath).timeout(const Duration(seconds: 5));
      totalSize = stat.size ?? 0;
    } catch (_) {}

    final localFile = File(localPath);

    // 大小未知时退回顺序读取，保证兼容与串流稳定（飞牛 NAS 等大块读取会 EOF）
    if (totalSize <= 0) {
      final file = await _sftpClient!.open(remotePath);
      final sink = localFile.openWrite();
      try {
        final stream = file.read().timeout(
          const Duration(seconds: 120),
          onTimeout: (eventSink) {
            eventSink.addError(Exception('SFTP read timed out: no data for 120s'));
            eventSink.close();
          },
        );
        await for (final chunk in stream) {
          if (isCancelled) break;
          sink.add(chunk);
        }
      } finally {
        await sink.flush();
        await sink.close();
        await file.close();
      }
      return;
    }

    // 滑动窗口并发 Range 读（参考 MaterialFiles 的 1MB 预读 + 异步双缓冲思路）。
    // 单流顺序 read 一次只在途一个 SSH_FXP_READ，round-trip 等待限制吞吐到
    // ~1.5-2MB/s。改为开启多个 SFTP 句柄，各自按偏移并发读取 64KB 块并写入本地
    // 文件对应偏移：多个在途读取可填满 SSH 通道，显著提升带宽利用率。
    // 每块限制 64KB 以避开飞牛 NAS 等服务端对“单次大读取”返回异常 EOF 的问题。
    const int concurrency = 12;
    const int chunkSize = 64 * 1024; // 64KB/块，在途约 768KB

    final raf = await localFile.open(mode: FileMode.write);
    try {
      await raf.truncate(totalSize);

      // 写入串行化：多个 worker 并发读取后会乱序写回，必须用锁保证
      // setPosition + writeFrom 的原子性，否则偏移错位导致文件损坏。
      Future<void> writeLock = Future.value();
      Future<void> writeAt(int pos, List<int> data) {
        final prev = writeLock;
        final completer = Completer<void>();
        writeLock = completer.future;
        return prev.then((_) async {
          try {
            await raf.setPosition(pos);
            await raf.writeFrom(data);
          } finally {
            completer.complete();
          }
        });
      }

      int nextOffset = 0;
      int downloaded = 0;
      Object? firstError;
      // 同步取值，事件循环内无 await，offset 分配无竞态
      int take() {
        final o = nextOffset;
        nextOffset += chunkSize;
        return o;
      }

      Future<void> worker(SftpFile handle) async {
        while (true) {
          final start = take();
          if (start >= totalSize) return;
          final len = (start + chunkSize <= totalSize) ? chunkSize : (totalSize - start);
          List<int> bytes;
          try {
            bytes = await handle
                .read(offset: start, length: len)
                .expand((e) => e)
                .toList();
          } catch (e) {
            firstError ??= e;
            return;
          }
          await writeAt(start, Uint8List.fromList(bytes));
          downloaded += len;
          if (totalSize > 0) onProgress((downloaded / totalSize).clamp(0.0, 1.0));
          if (isCancelled) throw Exception('Cancelled');
        }
      }

      final handles = <SftpFile>[];
      try {
        for (int i = 0; i < concurrency; i++) {
          handles.add(await _sftpClient!.open(remotePath));
        }
        await Future.wait(handles.map(worker));
      } finally {
        for (final h in handles) {
          try {
            await h.close();
          } catch (_) {}
        }
      }
      if (firstError != null) throw Exception('SFTP download failed: $firstError');
      if (isCancelled) throw Exception('Cancelled');
      onProgress(1.0);
    } finally {
      await raf.close();
    }
  }

  @override
  Future<void> downloadRange(String remotePath, String localPath, int startByte, int length) async {
    if (_sftpClient == null) throw Exception('SFTP not connected');

    final file = await _sftpClient!.open(remotePath);
    final localFile = File(localPath);
    final sink = localFile.openWrite();

    try {
      // dartssh2 的 read() 原生支持 offset + length，底层发起 SSH_FXP_READ 请求。
      // 使用默认参数，避免大 chunk 在部分服务端触发异常 EOF（与 downloadFile 同源坑）。
      final stream = file.read(
        offset: startByte,
        length: length,
      ).timeout(
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
      // dartssh2 的 remoteFile.write(Stream) 默认使用 16KB chunk + 64 pending，
      // 在途窗口仅约 1MB，无法跑满高速链路。这里改为手动分块 + 多缓冲并发：
      // openRead 默认返回 64KB chunk，最多允许 64 个 writeBytes 调用并发执行，
      // 整体在途数据约 4MB；writeBytes 内部还会把每块再拆成 16KB 并发写入，
      // 进一步填充 SSH 管道，提升上传吞吐。
      const maxConcurrentWrites = 64;

      int offset = 0;
      int uploaded = 0;
      final pending = <Future<void>>[];

      await for (final chunk in localFile.openRead()) {
        if (isCancelled) {
          throw Exception('Cancelled');
        }
        final data = Uint8List.fromList(chunk);
        pending.add(remoteFile.writeBytes(data, offset: offset));
        offset += data.length;
        uploaded += data.length;
        if (totalSize > 0) {
          onProgress((uploaded / totalSize).clamp(0.0, 1.0));
        }
        while (pending.length > maxConcurrentWrites) {
          await pending.removeAt(0);
        }
      }

      await Future.wait(pending);
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
