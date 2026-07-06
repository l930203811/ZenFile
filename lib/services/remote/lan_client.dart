import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'remote_client.dart';

/// Discovered server entry on the local network.
class LanDiscoveredServer {
  final String host;
  final int port;
  final String type; // 'FTP', 'SFTP', 'SMB', 'WebDav'
  final String name;

  LanDiscoveredServer({
    required this.host,
    required this.port,
    required this.type,
    required this.name,
  });
}

/// Real SMB client backed by Android native smbj via MethodChannel.
///
/// Communication protocol:
///   1. `connect()` opens an SMB session on the native side and returns a
///      `sessionId` (UUID) which is stored on this instance.
///   2. All subsequent operations (`listDirectory`, `downloadFile`, etc.)
///      pass the `sessionId` to the native side so it can look up the
///      cached `DiskShare`.
///   3. `disconnect()` releases native resources.
///
/// Paths use forward slashes (`/`) on the Dart side and are converted to
/// backslashes inside the native helper. The first path segment is treated
/// as the SMB share name; e.g. `/Public/Movies/film.mp4` resolves to
/// share=`Public`, path=`\Movies\film.mp4`.
class LanClient implements RemoteClient {
  static const MethodChannel _channel = MethodChannel('com.sequl.zenfile/smb');

  final String host;
  final int port;
  final String username;
  final String password;
  final String domain;

  String? _sessionId;
  bool _isConnected = false;

  LanClient({
    required this.host,
    required this.port,
    required this.username,
    required this.password,
    this.domain = '',
  });

  static Future<List<String>> getLocalIps() async {
    final ips = <String>[];
    try {
      final interfaces = await NetworkInterface.list();
      for (final interface in interfaces) {
        for (final addr in interface.addresses) {
          if (addr.type == InternetAddressType.IPv4 && !addr.isLoopback) {
            ips.add(addr.address);
          }
        }
      }
    } catch (_) {}
    return ips;
  }

  /// Scan the local subnet for likely file-share services.
  /// This is a TCP port-probe only; it does not actually authenticate.
  static Future<List<LanDiscoveredServer>> scanSubnet({
    required Function(double progress) onProgress,
  }) async {
    final discovered = <LanDiscoveredServer>[];
    final localIps = await getLocalIps();

    var baseSubnet = '192.168.1';
    if (localIps.isNotEmpty) {
      final parts = localIps.first.split('.');
      if (parts.length >= 3) {
        baseSubnet = '${parts[0]}.${parts[1]}.${parts[2]}';
      }
    }

    final targetPorts = {
      21: 'FTP',
      22: 'SFTP',
      445: 'SMB',
      80: 'WebDav',
      8080: 'WebDav',
    };

    const maxIps = 254;
    var scannedCount = 0;

    final futures = <Future<void>>[];
    for (var i = 1; i <= maxIps; i++) {
      final ip = '$baseSubnet.$i';
      futures.add(Future(() async {
        for (final entry in targetPorts.entries) {
          final port = entry.key;
          final type = entry.value;
          try {
            final socket = await Socket.connect(ip, port,
                timeout: const Duration(milliseconds: 150));
            socket.destroy();
            discovered.add(LanDiscoveredServer(
              host: ip,
              port: port,
              type: type,
              name: '$type Server ($ip)',
            ));
          } catch (_) {}
        }
        scannedCount++;
        onProgress(scannedCount / maxIps);
      }));
    }

    await Future.wait(futures);
    return discovered;
  }

  bool get _connected {
    return _isConnected && _sessionId != null;
  }

  String get _requireSession {
    final id = _sessionId;
    if (!_connected || id == null) {
      throw Exception('SMB session not established. Call connect() first.');
    }
    return id;
  }

  @override
  Future<void> connect() async {
    if (_connected) return;
    try {
      final result = await _channel.invokeMethod<String>('connect', {
        'host': host,
        'port': port,
        'username': username,
        'password': password,
        'domain': domain,
      }).timeout(const Duration(seconds: 30));
      if (result == null || result.isEmpty) {
        throw Exception('Native SMB client returned empty session id');
      }
      _sessionId = result;
      _isConnected = true;
    } on PlatformException catch (e) {
      _isConnected = false;
      _sessionId = null;
      throw Exception('SMB connect failed: ${e.code}: ${e.message}');
    } on TimeoutException {
      _isConnected = false;
      _sessionId = null;
      throw Exception('SMB connect timed out after 30s (host=$host:$port)');
    }
  }

  @override
  Future<void> disconnect() async {
    final id = _sessionId;
    if (id == null) {
      _isConnected = false;
      return;
    }
    try {
      await _channel.invokeMethod<bool>('disconnect', {'sessionId': id})
          .timeout(const Duration(seconds: 10));
    } catch (e) {
      debugPrint('SMB disconnect error: $e');
    } finally {
      _sessionId = null;
      _isConnected = false;
    }
  }

  String _normalizePath(String path) {
    if (path.isEmpty) return '/';
    if (!path.startsWith('/')) path = '/$path';
    // Collapse multiple slashes but keep leading/trailing single slashes.
    while (path.contains('//')) {
      path = path.replaceAll('//', '/');
    }
    return path;
  }

  /// Lists directory contents. For root path "/", the native side returns
  /// available SMB shares. For paths like "/{share}/...", it lists the
  /// contents within that share.
  @override
  Future<List<RemoteFileItem>> listDirectory(String path) async {
    final session = _requireSession;
    final normalized = _normalizePath(path);

    final result = await _channel.invokeMethod<List<dynamic>>(
      'listDirectory',
      {'sessionId': session, 'path': normalized},
    ).timeout(const Duration(seconds: 30));

    if (result == null) return <RemoteFileItem>[];

    final items = <RemoteFileItem>[];
    for (final entry in result) {
      if (entry is! Map) continue;
      try {
        final map = Map<String, dynamic>.from(entry);
        final name = map['name'] as String? ?? '';
        if (name.isEmpty || name == '.' || name == '..') continue;
        final itemPath = map['path'] as String? ?? '/$name';
        final isDir = map['isDirectory'] as bool? ?? false;
        final size = (map['size'] as num?)?.toInt() ?? 0;
        final modifiedMs = (map['modified'] as num?)?.toInt() ?? 0;
        items.add(RemoteFileItem(
          name: name,
          path: itemPath,
          isDirectory: isDir,
          size: size,
          modified: modifiedMs > 0
              ? DateTime.fromMillisecondsSinceEpoch(modifiedMs)
              : DateTime.now(),
        ));
      } catch (e) {
        debugPrint('SMB list entry parse error: $e');
      }
    }
    return items;
  }

  @override
  Future<void> createDirectory(String path) async {
    final session = _requireSession;
    await _channel.invokeMethod<bool>('createDirectory', {
      'sessionId': session,
      'path': _normalizePath(path),
    }).timeout(const Duration(seconds: 30));
  }

  @override
  Future<void> createFile(String path) async {
    final session = _requireSession;
    await _channel.invokeMethod<bool>('createFile', {
      'sessionId': session,
      'path': _normalizePath(path),
    }).timeout(const Duration(seconds: 30));
  }

  @override
  Future<void> delete(String path, bool isDir) async {
    final session = _requireSession;
    // SMB 删除偶尔会因网络抖动或服务器锁文件失败，增加重试逻辑
    const maxRetries = 3;
    Exception? lastError;
    for (int attempt = 0; attempt < maxRetries; attempt++) {
      try {
        await _channel.invokeMethod<bool>('delete', {
          'sessionId': session,
          'path': _normalizePath(path),
          'isDir': isDir,
        }).timeout(const Duration(seconds: 30));
        return; // 成功则直接返回
      } on PlatformException catch (e) {
        lastError = e;
        // 如果是"文件不存在"类错误，不重试直接返回
        final msg = (e.message ?? '').toLowerCase();
        if (msg.contains('no such file') || msg.contains('not found') || msg.contains('does not exist')) {
          rethrow;
        }
        // 其他错误（网络抖动、服务器锁文件等）延迟后重试
        if (attempt < maxRetries - 1) {
          await Future.delayed(Duration(milliseconds: 500 * (attempt + 1)));
        }
      } on TimeoutException {
        lastError = Exception('SMB delete timed out');
        if (attempt < maxRetries - 1) {
          await Future.delayed(Duration(milliseconds: 500 * (attempt + 1)));
        }
      }
    }
    // 所有重试都失败，抛出最后一个错误
    throw Exception('SMB delete failed after $maxRetries attempts: $lastError');
  }

  @override
  Future<void> rename(String oldPath, String newPath) async {
    final session = _requireSession;
    await _channel.invokeMethod<bool>('rename', {
      'sessionId': session,
      'oldPath': _normalizePath(oldPath),
      'newPath': _normalizePath(newPath),
    }).timeout(const Duration(seconds: 30));
  }

  @override
  Future<void> downloadFile(
    String remotePath,
    String localPath,
    Function(double progress) onProgress,
  ) async {
    final session = _requireSession;
    final file = File(localPath);
    if (file.existsSync()) file.deleteSync();
    file.parent.createSync(recursive: true);

    // Kick off the download on the native side. The native helper streams
    // the bytes to disk synchronously (from this isolate's perspective),
    // so we emulate progress by polling the file size while it grows.
    final totalFuture = getFileSize(remotePath);

    final downloadFuture = _channel.invokeMethod<bool>('downloadFile', {
      'sessionId': session,
      'remotePath': _normalizePath(remotePath),
      'localPath': localPath,
    });

    int totalSize = -1;
    try {
      totalSize = await totalFuture;
    } catch (_) {
      totalSize = -1;
    }

    // Poll progress until the download completes.
    Timer? progressTimer;
    if (totalSize > 0) {
      progressTimer = Timer.periodic(const Duration(milliseconds: 100), (_) {
        try {
          if (file.existsSync()) {
            final current = file.lengthSync();
            onProgress((current / totalSize).clamp(0.0, 0.99));
          }
        } catch (_) {}
      });
    }

    try {
      final success = await downloadFuture.timeout(
        const Duration(minutes: 30),
      );
      if (success != true) {
        throw Exception('SMB download returned false');
      }
      onProgress(1.0);
    } on TimeoutException {
      throw Exception('SMB download timed out');
    } finally {
      progressTimer?.cancel();
    }
  }

  @override
  Future<void> downloadRange(String remotePath, String localPath, int startByte, int length) async {
    final session = _requireSession;
    final file = File(localPath);
    if (file.existsSync()) file.deleteSync();
    file.parent.createSync(recursive: true);

    // 调用原生 downloadRange：只下载文件头部指定字节范围，用于生成缩略图
    // 无需轮询进度（数据量小，原生层同步写盘后即返回）
    try {
      final success = await _channel.invokeMethod<bool>('downloadRange', {
        'sessionId': session,
        'remotePath': _normalizePath(remotePath),
        'localPath': localPath,
        'startByte': startByte,
        'length': length,
      }).timeout(const Duration(minutes: 2));
      if (success != true) {
        throw Exception('SMB downloadRange returned false');
      }
    } on TimeoutException {
      throw Exception('SMB downloadRange timed out');
    }
  }

  @override
  Future<void> uploadFile(
    String localPath,
    String remotePath,
    Function(double progress) onProgress,
  ) async {
    final session = _requireSession;
    final localFile = File(localPath);
    if (!localFile.existsSync()) {
      throw Exception('Local file not found: $localPath');
    }

    final totalSize = await localFile.length();
    final uploadFuture = _channel.invokeMethod<bool>('uploadFile', {
      'sessionId': session,
      'localPath': localPath,
      'remotePath': _normalizePath(remotePath),
    });

    // Since the native upload is a blocking call with no progress reporting,
    // we report a slowly increasing fake progress so the UI shows activity
    // instead of being stuck at 0%.
    Timer? progressTimer;
    double fakeProgress = 0.0;
    if (totalSize > 0) {
      // Estimate upload time based on a conservative 2 MB/s speed
      final estimatedSeconds = (totalSize / (2 * 1024 * 1024)).ceil();
      final increment = 1.0 / (estimatedSeconds * 10); // 10 ticks per second
      progressTimer = Timer.periodic(const Duration(milliseconds: 100), (_) {
        fakeProgress = (fakeProgress + increment).clamp(0.0, 0.95);
        onProgress(fakeProgress);
      });
    } else {
      // For empty or unknown-size files, just report a small tick
      progressTimer = Timer.periodic(const Duration(milliseconds: 200), (_) {
        fakeProgress = (fakeProgress + 0.02).clamp(0.0, 0.95);
        onProgress(fakeProgress);
      });
    }

    try {
      // 根据文件大小动态调整超时：
      // - 默认 30 分钟（适用于大部分文件）
      // - 超过 1GB 的大文件按 10 MB/s 估算额外时间，避免大文件超时失败
      //   注意：原生层已使用 64KB 缓冲区 + 60s socket 超时，传输效率与稳定性已提升
      Duration timeout = const Duration(minutes: 30);
      if (totalSize > 1024 * 1024 * 1024) {
        // 超过 1GB：按 10 MB/s 估算 + 10 分钟余量
        final estimatedMinutes = (totalSize / (10 * 1024 * 1024) / 60).ceil() + 10;
        timeout = Duration(minutes: estimatedMinutes.clamp(30, 240));
      }
      final success = await uploadFuture.timeout(timeout);
      if (success != true) {
        throw Exception('SMB upload returned false');
      }
      onProgress(1.0);
    } on TimeoutException {
      throw Exception('SMB upload timed out');
    } finally {
      progressTimer?.cancel();
    }
  }

  @override
  String? getStreamUrl(String remotePath) {
    // SMB cannot expose an HTTP URL for direct streaming. The
    // RemoteStreamingService will download the file progressively and serve
    // it via the local HTTP proxy instead.
    return null;
  }

  @override
  Future<int> getFileSize(String remotePath) async {
    final session = _requireSession;
    try {
      final result = await _channel.invokeMethod<num>('getFileSize', {
        'sessionId': session,
        'remotePath': _normalizePath(remotePath),
      }).timeout(const Duration(seconds: 10));
      return result?.toInt() ?? -1;
    } catch (e) {
      debugPrint('SMB getFileSize error: $e');
      return -1;
    }
  }
}
