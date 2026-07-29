import 'dart:async';
import 'dart:io';
import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'remote_client.dart';

/// 原生 SSH/SFTP 通道：在 Android 上用 Java JSch 实现（加解密走系统硬件加速），
/// 突破 dartssh2 纯 Dart 加密的速率天花板（详见 SshSftpService.kt）。
const String _kSftpNativeChannel = 'com.sequl.zenfile/sftpNative';

class SftpRemoteClient extends RemoteClient {
  final String host;
  final int port;
  final String username;
  final String password;
  
  SSHClient? _sshClient;
  SftpClient? _sftpClient;

  /// 原生 SSH/SFTP 会话 id（仅 Android 且 connect 成功时有效）。
  String? _nativeSessionId;

  /// 是否走原生通道（Android 且 connect 成功）。否则回退到下方 dartssh2 实现。
  bool _useNative = false;

  /// 仅在 Android 平台尝试原生 SSH；其余平台（桌面/Web/iOS）走 dartssh2。
  final bool _isAndroid = !kIsWeb && Platform.isAndroid;

  /// 单文件下载时并行开的 SSH 连接数。注意：Dart 单 isolate 下所有连接的
  /// 加解密仍共用同一 CPU 核心，多连接主要收益在「高 RTT / 跨网」场景（吃满
  /// 带宽时延积、绕过服务端单连接限速）；同局域网若瓶颈是单核纯 Dart 加密，
  /// 仍需多 Isolate 或原生 SSH 才能突破。可按真机实测调小/调大。
  static int parallelConnections = 4;

  /// 低于此大小的文件退化为单连接顺序流，避免为多开连接的握手开销不划算。
  static const int _minSizeForParallel = 8 * 1024 * 1024;

  SftpRemoteClient({
    required this.host,
    required this.port,
    required this.username,
    required this.password,
  });

  @override
  Future<void> connect() async {
    // 优先尝试原生 SSH 通道（Android + 硬件加速加解密，突破纯 Dart 速率上限）。
    if (_isAndroid) {
      try {
        _nativeSessionId = await const MethodChannel(_kSftpNativeChannel).invokeMethod<String>(
          'connect',
          {'host': host, 'port': port, 'username': username, 'password': password},
        );
        _useNative = _nativeSessionId != null && _nativeSessionId!.isNotEmpty;
        if (_useNative) return;
      } catch (e) {
        debugPrint('SFTP native connect failed, falling back to dartssh2: $e');
        _useNative = false;
      }
    }
    // —— 以下为纯 Dart dartssh2 实现（非 Android 平台 / 原生不可用时的回退）——
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
    if (_useNative && _nativeSessionId != null) {
      try {
        await const MethodChannel(_kSftpNativeChannel)
            .invokeMethod('disconnect', {'sessionId': _nativeSessionId});
      } catch (_) {}
      _nativeSessionId = null;
      _useNative = false;
      return;
    }
    _sshClient?.close();
    await _sshClient?.done;
    _sshClient = null;
    _sftpClient = null;
  }

  @override
  Future<List<RemoteFileItem>> listDirectory(String path, {bool forceRefresh = false}) async {
    if (_useNative && _nativeSessionId != null) {
      return _nativeListDirectory(path, forceRefresh);
    }
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
    if (_useNative && _nativeSessionId != null) {
      await const MethodChannel(_kSftpNativeChannel)
          .invokeMethod('createDirectory', {'sessionId': _nativeSessionId, 'path': path});
      return;
    }
    if (_sftpClient == null) throw Exception('SFTP not connected');
    await _sftpClient!.mkdir(path);
  }

  @override
  Future<void> createFile(String path) async {
    if (_useNative && _nativeSessionId != null) {
      await const MethodChannel(_kSftpNativeChannel)
          .invokeMethod('createFile', {'sessionId': _nativeSessionId, 'path': path});
      return;
    }
    if (_sftpClient == null) throw Exception('SFTP not connected');
    final remoteFile = await _sftpClient!.open(
      path,
      mode: SftpFileOpenMode.create | SftpFileOpenMode.truncate | SftpFileOpenMode.write,
    );
    await remoteFile.write(Stream.fromIterable([])).done;
  }

  @override
  Future<void> delete(String path, bool isDir) async {
    if (_useNative && _nativeSessionId != null) {
      const maxRetries = 3;
      Exception? lastError;
      for (int attempt = 0; attempt < maxRetries; attempt++) {
        try {
          await const MethodChannel(_kSftpNativeChannel).invokeMethod('delete', {
            'sessionId': _nativeSessionId,
            'path': path,
            'isDir': isDir,
          });
          return;
        } on Exception catch (e) {
          final msg = e.toString().toLowerCase();
          if (msg.contains('no such file') ||
              msg.contains('not found') ||
              msg.contains('does not exist') ||
              msg.contains('ssh_fx_no_such_file')) {
            rethrow;
          }
          lastError = e;
          if (attempt < maxRetries - 1) {
            await Future.delayed(Duration(milliseconds: 500 * (attempt + 1)));
          }
        }
      }
      throw Exception('SFTP native delete failed after $maxRetries attempts: $lastError');
    }
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
    if (_useNative && _nativeSessionId != null) {
      await const MethodChannel(_kSftpNativeChannel).invokeMethod('rename', {
        'sessionId': _nativeSessionId,
        'oldPath': oldPath,
        'newPath': newPath,
      });
      return;
    }
    if (_sftpClient == null) throw Exception('SFTP not connected');
    await _sftpClient!.rename(oldPath, newPath);
  }

  @override
  Future<void> downloadFile(String remotePath, String localPath, Function(double progress) onProgress) async {
    if (_useNative && _nativeSessionId != null) {
      return _nativeDownloadFile(remotePath, localPath, onProgress);
    }
    if (_sftpClient == null) throw Exception('SFTP not connected');

    // stat 获取文件大小，用于划分并行区间与进度报告（5s 超时）
    int totalSize = 0;
    try {
      final stat = await _sftpClient!.stat(remotePath).timeout(const Duration(seconds: 5));
      totalSize = stat.size ?? 0;
    } catch (_) {}

    // 无法获知大小、空文件、或文件过小不值得多开连接握手 → 退化为单连接顺序流。
    // 流式代理目标（.partial）必须【严格顺序落盘】：并行分段下载会先
    // truncate(totalSize) 预置整文件大小，而代理用「文件长度」作为已下载
    // 水位 → 瞬间误判为全部就绪 → 读到未写入的全 0 字节喂给播放器 → 卡死。
    final isStreamingTarget = localPath.endsWith('.partial');
    if (totalSize <= 0 || totalSize < _minSizeForParallel || isStreamingTarget) {
      await _downloadSingleStream(remotePath, localPath, onProgress, totalSize);
      return;
    }

    final localFile = File(localPath);
    final raf = await localFile.open(mode: FileMode.write);
    try {
      // 预置文件大小，使各并行连接能直接按「绝对偏移」落盘，无需任何重排缓冲，
      // 也不会产生空洞（流式代理不会读到 0 字节）。
      await raf.truncate(totalSize);

      // 按连接数均分区间，每段对齐到 64KB 边界（避免飞牛 NAS 等单次大读触发 EOF）。
      const align = 64 * 1024;
      final rawChunk = (totalSize / parallelConnections).ceil();
      final step = (rawChunk / align).ceil() * align;
      final ranges = <(int, int)>[];
      for (int i = 0; i < parallelConnections; i++) {
        final start = i * step;
        if (start >= totalSize) break;
        final len = (start + step <= totalSize) ? step : (totalSize - start);
        ranges.add((start, len));
      }

      // RandomAccessFile 的 setPosition + writeFrom 非并发安全，用互斥锁串行化
      // 本地写；网络读取在 N 条连接上真正并发——这正是并行收益所在（高 RTT /
      // 服务端单连接限速场景提速明显；同局域网若瓶颈是单核纯 Dart 加密则仍受限于单核）。
      final writeMutex = _SimpleMutex();
      int totalDownloaded = 0;
      Future<void> writeAt(int offset, Uint8List data) => writeMutex.run(() async {
            await raf.setPosition(offset);
            await raf.writeFrom(data);
          });

      Future<void> readRange(int start, int len) async {
        final conn = await _openAuxConnection();
        try {
          final file = await conn.sftp.open(remotePath);
          try {
            int consumed = 0;
            await for (final chunk in file.read(
              offset: start,
              length: len,
              chunkSize: 64 * 1024,
              maxPendingRequests: 128,
            )) {
              if (isCancelled) break;
              // 每块带绝对偏移，乱序到达也无所谓——直接写到正确位置。
              await writeAt(start + consumed, chunk);
              consumed += chunk.length;
              totalDownloaded += chunk.length;
              if (totalSize > 0) onProgress((totalDownloaded / totalSize).clamp(0.0, 1.0));
            }
          } finally {
            await file.close();
          }
        } finally {
          await conn.close();
        }
      }

      await Future.wait(ranges.map((r) => readRange(r.$1, r.$2)));
    } finally {
      await raf.flush();
      await raf.close();
    }
    if (isCancelled) {
      // 取消下载：删除本地未完成的半截文件，避免留下虚假文件。
      try { await File(localPath).delete(); } catch (_) {}
      throw Exception('Cancelled');
    }
    if (totalSize > 0) onProgress(1.0);
  }

  /// 单连接顺序流下载（退化路径）：用于无法 stat 到大小、空文件或过小文件。
  Future<void> _downloadSingleStream(
    String remotePath,
    String localPath,
    Function(double progress) onProgress,
    int totalSize,
  ) async {
    final localFile = File(localPath);
    final sink = localFile.openWrite();
    int downloaded = 0;
    int sinceFlush = 0;
    bool isFirstChunk = true;
    const flushInterval = 64 * 1024;

    try {
      final file = await _sftpClient!.open(remotePath);
      try {
        final stream = file.read(
          chunkSize: 64 * 1024,
          maxPendingRequests: 128,
        ).timeout(
          const Duration(seconds: 120),
          onTimeout: (eventSink) {
            eventSink.addError(Exception('SFTP read timed out: no data for 120s'));
            eventSink.close();
          },
        );
        await for (final chunk in stream) {
          if (isCancelled) break;
          sink.add(chunk);
          downloaded += chunk.length;
          sinceFlush += chunk.length;
          if (totalSize > 0) onProgress((downloaded / totalSize).clamp(0.0, 1.0));
          if (isFirstChunk || sinceFlush >= flushInterval) {
            await sink.flush();
            sinceFlush = 0;
            isFirstChunk = false;
          }
        }
      } finally {
        await file.close();
      }
    } finally {
      await sink.flush();
      await sink.close();
    }
    if (isCancelled) {
      // 取消下载：删除本地未完成的半截文件，避免留下虚假文件。
      try { await File(localPath).delete(); } catch (_) {}
      throw Exception('Cancelled');
    }
    if (totalSize > 0) onProgress(1.0);
  }

  /// 为单段并行读取单独开一条 SSH 连接（独立会话 = 独立的加解密流）。
  Future<_AuxSsh> _openAuxConnection() async {
    SSHSocket socket;
    try {
      socket = await SSHSocket.connect(host, port, timeout: const Duration(seconds: 15));
    } catch (_) {
      // 与主连接一致：失败重试一次，容忍瞬时握手抖动。
      socket = await SSHSocket.connect(host, port, timeout: const Duration(seconds: 15));
    }
    final ssh = SSHClient(socket, username: username, onPasswordRequest: () => password);
    final sftp = await ssh.sftp();
    return _AuxSsh(ssh, sftp);
  }

  @override
  Future<void> downloadRange(String remotePath, String localPath, int startByte, int length) async {
    if (_useNative && _nativeSessionId != null) {
      return _nativeDownloadRange(remotePath, localPath, startByte, length);
    }
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
    if (_useNative && _nativeSessionId != null) {
      return _nativeUploadFile(localPath, remotePath, onProgress);
    }
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
      // dartssh2 的 SftpFileWriter 把流拆成 16KB chunk 后顺序调用 writeBytes，
      // 导致在途窗口被硬编码为 1MB（chunkSize * 64），无法跑满高速链路。
      // 这里改为手动顺序写：每次读入 4MB 大块后调用 writeBytes，后者内部会把
      // 这 4MB 拆成 256 个 16KB 分包并发发送，整体在途窗口扩大到 4MB；同时
      // offset 严格递增，避免之前“多并发 writeBytes 带显式 offset”造成的乱序写，
      // 从而不再触发飞牛 NAS 等服务端生成 file-<随机> 临时文件。
      const blockSize = 4 * 1024 * 1024; // 4MB
      int offset = 0;
      int uploaded = 0;

      await for (final chunk in localFile.openRead(blockSize)) {
        if (isCancelled) throw Exception('Cancelled');
        final data = Uint8List.fromList(chunk);
        await remoteFile.writeBytes(data, offset: offset);
        offset += data.length;
        uploaded += data.length;
        if (totalSize > 0) onProgress((uploaded / totalSize).clamp(0.0, 1.0));
      }
    } finally {
      await remoteFile.close();
    }

    if (isCancelled) {
      // 取消上传：删除服务端尚未完成的半截目标文件，避免留下残缺文件。
      // dartssh2 顺序写（offset 递增）不会产生 file-<随机> 临时文件，目标即残留点。
      try { await delete(remotePath, false); } catch (_) {}
      throw Exception('Cancelled');
    }
    onProgress(1.0);
  }

  @override
  Future<int> getFileSize(String remotePath) async {
    if (_useNative && _nativeSessionId != null) {
      final size = await const MethodChannel(_kSftpNativeChannel)
          .invokeMethod<int>('getFileSize', {'sessionId': _nativeSessionId, 'remotePath': remotePath});
      return size ?? -1;
    }
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

  // ── 原生 SSH/SFTP（Android，JSch）实现 ──────────────────────────────────────

  Future<List<RemoteFileItem>> _nativeListDirectory(String path, bool forceRefresh) async {
    final raw = await const MethodChannel(_kSftpNativeChannel).invokeMethod<List<dynamic>>(
      'listDirectory',
      {'sessionId': _nativeSessionId, 'path': path, 'forceRefresh': forceRefresh},
    );
    final list = <RemoteFileItem>[];
    for (final item in raw ?? <dynamic>[]) {
      final m = item as Map<dynamic, dynamic>;
      final modified = (m['modified'] as num?)?.toInt() ?? 0;
      list.add(RemoteFileItem(
        name: m['name'] as String? ?? '',
        path: m['path'] as String? ?? '',
        isDirectory: m['isDirectory'] as bool? ?? false,
        size: (m['size'] as num?)?.toInt() ?? 0,
        modified: modified > 0 ? DateTime.fromMillisecondsSinceEpoch(modified) : DateTime.now(),
      ));
    }
    return list;
  }

  /// 原生整文件下载：传输在原生侧直接落盘，Dart 侧仅按 200ms 轮询进度并转发给
  /// onProgress（也用于驱动 RemoteStreamingService 的文件长度探测）。取消哨兵置位
  /// 时通过 cancelTransfer 中止原生传输。
  Future<void> _nativeDownloadFile(String remotePath, String localPath, Function(double) onProgress) async {
    final id = _nativeSessionId!;
    final timer = Timer.periodic(const Duration(milliseconds: 200), (_) async {
      try {
        if (isCancelled) {
          await const MethodChannel(_kSftpNativeChannel).invokeMethod('cancelTransfer', {'sessionId': id});
          return;
        }
        final p = await const MethodChannel(_kSftpNativeChannel)
            .invokeMethod<Map<dynamic, dynamic>>('getProgress', {'sessionId': id});
        final downloaded = (p?['downloaded'] as num?)?.toDouble() ?? 0;
        final total = (p?['total'] as num?)?.toDouble() ?? 0;
        if (total > 0) onProgress((downloaded / total).clamp(0.0, 1.0));
      } catch (_) {}
    });
    try {
      final ok = await const MethodChannel(_kSftpNativeChannel).invokeMethod<bool>('downloadFile', {
        'sessionId': id,
        'remotePath': remotePath,
        'localPath': localPath,
      });
      if (ok == true) onProgress(1.0);
      // 被取消时原生可能返回 false 或抛异常，统一按取消处理
      if (ok != true && !isCancelled) throw Exception('SFTP native download failed');
    } on PlatformException {
      if (!isCancelled) rethrow;
    } finally {
      timer.cancel();
    }
    if (isCancelled) {
      // 取消下载：删除本地未完成的半截文件（原生已停止传输），避免留下虚假文件。
      try { await File(localPath).delete(); } catch (_) {}
      throw Exception('Cancelled');
    }
  }

  /// 原生区间下载（缩略图头部 / 流媒体按需 seek）：精确读取 [startByte, +length)。
  Future<void> _nativeDownloadRange(String remotePath, String localPath, int startByte, int length) async {
    final ok = await const MethodChannel(_kSftpNativeChannel).invokeMethod<bool>('downloadRange', {
      'sessionId': _nativeSessionId,
      'remotePath': remotePath,
      'localPath': localPath,
      'startByte': startByte,
      'length': length,
    });
    if (ok != true) throw Exception('SFTP native downloadRange failed');
  }

  Future<void> _nativeUploadFile(String localPath, String remotePath, Function(double) onProgress) async {
    final id = _nativeSessionId!;
    final timer = Timer.periodic(const Duration(milliseconds: 200), (_) async {
      try {
        if (isCancelled) {
          await const MethodChannel(_kSftpNativeChannel).invokeMethod('cancelTransfer', {'sessionId': id});
          return;
        }
        final p = await const MethodChannel(_kSftpNativeChannel)
            .invokeMethod<Map<dynamic, dynamic>>('getProgress', {'sessionId': id});
        final uploaded = (p?['downloaded'] as num?)?.toDouble() ?? 0;
        final total = (p?['total'] as num?)?.toDouble() ?? 0;
        if (total > 0) onProgress((uploaded / total).clamp(0.0, 1.0));
      } catch (_) {}
    });
    try {
      final ok = await const MethodChannel(_kSftpNativeChannel).invokeMethod<bool>('uploadFile', {
        'sessionId': id,
        'localPath': localPath,
        'remotePath': remotePath,
      });
      if (ok == true) onProgress(1.0);
      if (ok != true && !isCancelled) throw Exception('SFTP native upload failed');
    } on PlatformException {
      if (!isCancelled) rethrow;
    } finally {
      timer.cancel();
    }
    if (isCancelled) throw Exception('Cancelled');
  }
}

/// 一条独立 SSH 连接的句柄（SSHClient + 其 Sftp 子系统），便于并行下载时
/// 每条连接用完即关。
class _AuxSsh {
  final SSHClient ssh;
  final SftpClient sftp;
  _AuxSsh(this.ssh, this.sftp);

  Future<void> close() async {
    ssh.close();
    await ssh.done;
  }
}

/// 极简异步互斥锁：把传入的 task 串成一个链顺序执行，保证同一时刻只有一个
/// task 在跑（用于串行化 RandomAccessFile 的 setPosition + writeFrom）。
class _SimpleMutex {
  Future<void> _chain = Future.value();

  Future<T> run<T>(Future<T> Function() task) {
    final completer = Completer<T>();
    _chain = _chain.then((_) => task()).then((value) {
      if (!completer.isCompleted) completer.complete(value);
    }).catchError((Object error, StackTrace stackTrace) {
      if (!completer.isCompleted) completer.completeError(error, stackTrace);
    });
    return completer.future;
  }
}
