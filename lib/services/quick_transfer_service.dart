import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';

/// 快传：WiFi Direct (P2P) 控制 + Socket 直传协议
///
/// 原生 Kotlin [QuickTransferP2pPlugin] 负责 P2P 发现/连接/GO IP；
/// 本类负责：MethodChannel 调用、事件流、以及连接成功后的 TCP Socket 文件/文件夹直传。
///
/// 传输协议（端口 [transferPort] = 8989）：
///   所有非数据帧格式： [4字节 big-endian 长度][UTF-8 JSON 头]
///   JSON 头 type 取值：
///     manifest   - 文件清单 {totalBytes,totalCount,files:[{relativePath,size,mtime}]}
///     file_start - 单文件开始 {relativePath,size}（接收方据此读取 size 字节原始数据）
///     file_end   - 单文件结束 {relativePath}
///     accept     - 接收方接受
///     reject     - 接收方拒绝
///     done       - 全部完成 {cancelled:bool}
///   文件数据：file_start 之后、file_end 之前的原始字节流（无 JSON 头），
///            长度 = file_start.size，分块发送。
class QuickTransferService {
  static const String _channelName = 'com.sequl.zenfile/quick_transfer';
  static const String _peersEvent = 'com.sequl.zenfile/quick_transfer_peers';
  static const String _connectionEvent =
      'com.sequl.zenfile/quick_transfer_connection';

  /// Socket 直传端口
  static const int transferPort = 8989;

  /// 单文件分块大小（64KB）
  static const int chunkSize = 64 * 1024;

  static final QuickTransferService _instance = QuickTransferService._internal();
  factory QuickTransferService() => _instance;
  QuickTransferService._internal();

  final MethodChannel _channel = const MethodChannel(_channelName);
  final EventChannel _peersChannel = const EventChannel(_peersEvent);
  final EventChannel _connectionChannel = const EventChannel(_connectionEvent);

  Stream<List<PeerDevice>>? _peersStream;
  Stream<P2pConnectionState>? _connectionStream;

  P2pConnectionState _lastConnection = P2pConnectionState.disconnected;
  P2pConnectionState get lastConnection => _lastConnection;

  Stream<List<PeerDevice>> get peersStream {
    _peersStream ??= _peersChannel.receiveBroadcastStream().map((event) {
      final list = (event as List?) ?? [];
      return list.map((e) => PeerDevice.fromMap(Map<String, dynamic>.from(e))).toList();
    });
    return _peersStream!;
  }

  Stream<P2pConnectionState> get connectionStream {
    _connectionStream ??= _connectionChannel.receiveBroadcastStream().map((event) {
      final m = Map<String, dynamic>.from(event as Map);
      _lastConnection = P2pConnectionState.fromMap(m);
      return _lastConnection;
    });
    return _connectionStream!;
  }

  Future<bool> isSupported() async {
    final r = await _channel.invokeMethod<bool>('isSupported');
    return r ?? false;
  }

  /// 确保定位/附近设备权限（Android 10-12 需精确定位才能看到对端设备名）
  Future<bool> ensurePermission() async {
    if (Platform.isAndroid) {
      if (await _isAndroid13Plus()) {
        final st = await Permission.nearbyWifiDevices.status;
        if (!st.isGranted) {
          return (await Permission.nearbyWifiDevices.request()).isGranted;
        }
        return true;
      } else {
        final st = await Permission.locationWhenInUse.status;
        if (!st.isGranted) {
          return (await Permission.locationWhenInUse.request()).isGranted;
        }
        return true;
      }
    }
    return true;
  }

  /// 打开应用设置页，供用户手动开启权限
  Future<bool> openSettings() async {
    return await openAppSettings();
  }

  int? _sdkInt;

  /// 读取真实系统版本号（Build.VERSION.SDK_INT）。
  /// 旧的判断方式（捕获 nearbyWifiDevices 常量调用异常）在 Android 11 上会误判为 13+，
  /// 导致在低版本上错误地请求"附近设备"权限，而用户已授予的定位权限被无视。
  Future<int> getSdkInt() async {
    _sdkInt ??= await _channel.invokeMethod<int>('getSdkInt') ?? 0;
    return _sdkInt!;
  }

  Future<bool> _isAndroid13Plus() async {
    return await getSdkInt() >= 33;
  }

  Future<String?> getDeviceName() async =>
      _channel.invokeMethod<String>('getDeviceName');

  Future<String?> getDeviceAddress() async =>
      _channel.invokeMethod<String>('getDeviceAddress');

  /// 检查系统 WiFi 是否已开启
  Future<bool> isWifiEnabled() async {
    final r = await _channel.invokeMethod<bool>('isWifiEnabled');
    return r ?? false;
  }

  Future<bool> startDiscovery() async {
    if (!await ensurePermission()) return false;
    final r = await _channel.invokeMethod<bool>('startDiscovery');
    return r ?? false;
  }

  Future<bool> stopDiscovery() async {
    final r = await _channel.invokeMethod<bool>('stopDiscovery');
    return r ?? false;
  }

  Future<List<PeerDevice>> getPeers() async {
    final r = await _channel.invokeMethod<List<dynamic>>('getPeers');
    return (r ?? [])
        .map((e) => PeerDevice.fromMap(Map<String, dynamic>.from(e)))
        .toList();
  }

  /// 连接指定对端。成功返回 true；失败会抛出 PlatformException。
  /// 注意：原生意图返回 bool，Dart 侧切勿再按 String? 读取，否则会触发
  /// "type 'bool' is not a subtype of type 'String?' in type cast"。
  Future<bool> connect(String address) async {
    final r = await _channel.invokeMethod<bool>('connect', {'address': address});
    return r ?? false;
  }

  /// 发送方建组（成为 GO），随后可监听 ServerSocket 等待接收方连接
  Future<bool> createGroup() async {
    final r = await _channel.invokeMethod<bool>('createGroup');
    return r ?? false;
  }

  Future<bool> disconnect() async {
    final r = await _channel.invokeMethod<bool>('disconnect');
    return r ?? false;
  }

  Future<String?> getGroupOwnerAddress() async =>
      _channel.invokeMethod<String>('getGroupOwnerAddress');

  // ======================= 文件收集 =======================

  /// 收集文件/文件夹为扁平清单（含相对路径）。文件夹递归展开。
  Future<List<FileEntry>> collectFiles(List<String> paths) async {
    final List<FileEntry> result = [];
    for (final p in paths) {
      final type = FileSystemEntity.typeSync(p);
      if (type == FileSystemEntityType.directory) {
        final dir = Directory(p);
        await for (final f in dir.list(recursive: true)) {
          if (f is File) {
            final stat = await f.stat();
            result.add(FileEntry(
              absolutePath: f.path,
              relativePath: _relative(p, f.path),
              size: stat.size,
              mtime: stat.modified.millisecondsSinceEpoch,
            ));
          }
        }
      } else if (type == FileSystemEntityType.file) {
        final stat = await File(p).stat();
        result.add(FileEntry(
          absolutePath: p,
          relativePath: _basename(p),
          size: stat.size,
          mtime: stat.modified.millisecondsSinceEpoch,
        ));
      }
    }
    return result;
  }

  // ======================= 双向握手 =======================

  /// 双方都点击「连接」的 UI 握手。
  /// socket 建立好后，两端先发 `{type:'peer_ready', mode: 0|1}`，
  /// 再阻塞等对方回 peer_ready。只有双方 ready 才算连接握手成功，
  /// 返回对方的 mode（0 发送 / 1 接收）+ 对应的 SocketReader（后续传输
  /// 继续复用此 reader，避免对同一 single-sub socket stream 二次 listen
  /// 抛「Bad state: Stream has already been listened to.」）。
  /// 取消回调返回 true 或 socket EOF（对方取消/断开）都立即中止并抛异常。
  Future<({int peerMode, SocketReader reader})> doPeerReadyHandshake({
    required Socket socket,
    required int localMode,
    required Future<bool> Function() shouldCancel,
  }) async {
    final reader = SocketReader(socket);
    // 先发自己 ready
    await _writeJson(socket, {
      'type': 'peer_ready',
      'mode': localMode,
    });
    // 等对方 ready（最长 60s、1s 轮询；socket EOF 立即失败；循环 yield 防 ANR）
    final timeoutAt =
        DateTime.now().millisecondsSinceEpoch + const Duration(seconds: 60).inMilliseconds;
    while (DateTime.now().millisecondsSinceEpoch < timeoutAt) {
      if (await shouldCancel()) {
        reader.close();
        throw Exception('连接已取消');
      }
      final resp = await reader.readJson().timeout(
        const Duration(seconds: 1),
        onTimeout: () => null,
      );
      if (resp != null) {
        if (resp['type'] == 'peer_ready') {
          final peerMode = resp['mode'] as int? ?? 0;
          // 握手成功：reader 不 close，交给调用方传入 sendFiles/receiveFiles 继续复用
          return (peerMode: peerMode, reader: reader);
        }
      } else {
        // resp == null：readExact 在 socket EOF / broken pipe 时返回 null。
        // 立即中止，不再空转 60s——否则每 1s 一轮读 null 不 yield 会阻塞主
        // isolate 事件循环，造成 UI 冻住 60s 后系统 ANR 闪退。
        reader.close();
        throw Exception('连接已断开');
      }
      // 让事件循环跑一圈，避免 CPU 空转导致 UI 卡顿
      await Future.delayed(Duration.zero);
    }
    reader.close();
    throw Exception('等待对方点击连接超时');
  }

  // ======================= 发送方 =======================

  /// 在已连 Socket 上推送清单 + 文件原始字节流。
  /// [existingReader]：若上游已创建 SocketReader（如握手）必须传入，
  /// 否则对同一个 socket 二次 new SocketReader 会在 single-sub stream 上
  /// 抛「Stream has already been listened to.」。
  Future<void> sendFiles({
    required Socket socket,
    required List<FileEntry> files,
    required void Function(int sent, int total, String currentFile) onProgress,
    required Future<bool> Function() shouldCancel,
    SocketReader? existingReader,
  }) async {
    final totalBytes = files.fold<int>(0, (s, f) => s + f.size);
    int sent = 0;

    await _writeJson(socket, {
      'type': 'manifest',
      'totalBytes': totalBytes,
      'totalCount': files.length,
      'files': files
          .map((f) => {
                'relativePath': f.relativePath,
                'size': f.size,
                'mtime': f.mtime,
              })
          .toList(),
    });

    // 必须等待接收方"接受/拒绝"后再开始传输，否则数据会提前进入缓冲，
    // 造成"还没点接收文件就已经收到了"的错觉。
    final reader = existingReader ?? SocketReader(socket);
    final resp = await reader.readJson();
    if (resp == null) {
      reader.close();
      throw Exception('连接已断开，未能收到接收方的回应');
    }
    if (resp['type'] == 'reject') {
      reader.close();
      // 接收方拒绝，终止发送并提示
      throw Exception('对方已拒绝接收');
    }

    // 进度节流：≥100ms 或文件切换或文件读完才回调，避免高频 setState 打爆 UI
    int lastEmitAt = 0;
    String lastEmitFile = '';

    for (final f in files) {
      if (await shouldCancel()) {
        await _writeJson(socket, {'type': 'done', 'cancelled': true});
        return;
      }
      await _writeJson(socket, {
        'type': 'file_start',
        'relativePath': f.relativePath,
        'size': f.size,
      });
      final file = File(f.absolutePath);
      int offset = 0;
      await for (final chunk in file.openRead()) {
        if (await shouldCancel()) {
          await _writeJson(socket, {'type': 'done', 'cancelled': true});
          return;
        }
        socket.add(chunk);
        await socket.flush();
        offset += chunk.length;
        sent += chunk.length;
        final now = DateTime.now().millisecondsSinceEpoch;
        // 进度显示上限 = totalBytes - 1，所有数据 flush 完后 UI 停留在
        // 「等待对方接收完成…」的近 100% 态；只有在下方收到接收方
        // `receive_ack` 后才回调 100%，确保发送方「完成」与接收方落盘
        // 完成对齐，不会出现「发送方已完成，接收方还没收完」的体感差异。
        // （TCP flush 只保证写入内核缓冲区，不代表对端应用层已消费完毕。）
        final displaySent = (sent < totalBytes) ? sent : totalBytes - 1;
        if (offset >= f.size ||
            f.relativePath != lastEmitFile ||
            now - lastEmitAt >= 100) {
          lastEmitAt = now;
          lastEmitFile = f.relativePath;
          onProgress(displaySent, totalBytes, f.relativePath);
        }
        if (offset % (chunkSize * 16) == 0) await Future.delayed(Duration.zero);
      }
      if (offset != f.size) {
        throw Exception('文件大小不一致: ${f.relativePath} ($offset/${f.size})');
      }
      await _writeJson(socket, {'type': 'file_end', 'relativePath': f.relativePath});
    }
    await _writeJson(socket, {'type': 'done', 'cancelled': false});

    // 阻塞等待接收方的落盘完成 ack。接收方收到 done → flush+close 所有 sink
    // 成功后回 `{type:'receive_ack', received:int}`。只有收到 ack 才把
    // 进度推到 100% 并返回 done 态。
    try {
      final ack = await reader.readJson();
      if (ack != null && ack['type'] == 'receive_ack') {
        onProgress(totalBytes, totalBytes, '');
      } else {
        // 没收到 ack（连接中断等），静默返回；UI 将以显示近 100% 结束
        // 不抛异常，避免误判为失败。
      }
    } finally {
      reader.close();
    }
  }

  // ======================= 接收方 =======================

  /// 监听 Socket，先收 manifest 交 [onManifest] 决定接受/拒绝；
  /// 接受后按 relativePath 落盘到 [saveDir]，拒绝则关闭。
  /// 返回 true 表示已正常接收完成；false 表示被拒绝或连接中断。
  /// [existingReader]：若上游已创建 SocketReader（如握手）必须传入，
  /// 否则对同一个 socket 二次 new SocketReader 会在 single-sub stream 上
  /// 抛「Stream has already been listened to.」。
  Future<bool> receiveFiles({
    required Socket socket,
    required String saveDir,
    required Future<bool> Function(Manifest) onManifest,
    required void Function(int received, int total, String currentFile) onProgress,
    required void Function(String relativePath) onFileSaved,
    SocketReader? existingReader,
  }) async {
    int received = 0;
    int totalBytes = 0;
    String? currentFile;
    int currentRemaining = 0;
    IOSink? sink;
    // 进度节流：≥100ms 或文件切换或文件读完才回调，避免高频 setState 打爆 UI
    int lastEmitAt = 0;
    String lastEmitFile = '';

    final reader = existingReader ?? SocketReader(socket);

    try {
      while (true) {
        final lenBytes = await reader.readExact(4);
        if (lenBytes == null) break;
        final len = ByteData.sublistView(lenBytes).getUint32(0, Endian.big);
        final jsonBytes = await reader.readExact(len);
        if (jsonBytes == null) break;
        final map = jsonDecode(utf8.decode(jsonBytes)) as Map<String, dynamic>;
        final type = map['type'] as String;

        switch (type) {
          case 'manifest':
            totalBytes = map['totalBytes'] as int;
            final files = (map['files'] as List)
                .map((e) => Map<String, dynamic>.from(e))
                .toList();
            final manifest = Manifest(
              totalBytes: totalBytes,
              totalCount: map['totalCount'] as int,
              files: files
                  .map((m) => FileEntry(
                        absolutePath: '',
                        relativePath: m['relativePath'] as String,
                        size: m['size'] as int,
                        mtime: m['mtime'] as int,
                      ))
                  .toList(),
            );
            final accepted = await onManifest(manifest);
            if (!accepted) {
              await _writeJson(socket, {'type': 'reject'});
              await socket.flush();
              await socket.close();
              reader.close();
              return false;
            }
            await _writeJson(socket, {'type': 'accept'});
            await socket.flush();
            break;

          case 'file_start':
            currentFile = map['relativePath'] as String;
            currentRemaining = map['size'] as int;
            // 打开输出文件（覆盖写；append 在重传/残留半成品场景会叠加旧数据导致损坏）
            await sink?.flush();
            await sink?.close();
            sink = null;
            final outPath = _join(saveDir, currentFile);
            final dir = Directory(_dirname(outPath));
            if (!await dir.exists()) await dir.create(recursive: true);
            sink = File(outPath).openWrite();
            break;

          case 'file_end':
            await sink?.flush();
            await sink?.close();
            sink = null;
            onFileSaved(map['relativePath'] as String);
            currentFile = null;
            currentRemaining = 0;
            break;

          case 'done':
            await sink?.flush();
            await sink?.close();
            sink = null;
            // 关键：先回 ack 再关闭 socket，保证发送方能读到 ack
            // （TCP 半关闭下如果先 close，对端可能因 EOF 提前中止读取）
            await _writeJson(socket, {
              'type': 'receive_ack',
              'received': received,
              'totalBytes': totalBytes,
            });
            await socket.close();
            reader.close();
            return true;

          case 'reject':
            await socket.close();
            reader.close();
            return false;

          case 'accept':
            break;
        }

        // 文件数据模式：按 chunkSize 分块读取，每块立即落盘并回报进度。
        // 此前一次性 readExact(整个文件大小) 导致：传输期间 UI 进度条始终 0%
        // （回调只在整文件读完后触发一次），且整文件驻留内存有 OOM 风险。
        while (currentFile != null && currentRemaining > 0) {
          final toRead =
              currentRemaining > chunkSize ? chunkSize : currentRemaining;
          final data = await reader.readExact(toRead);
          if (data == null) break; // 连接中断
          sink?.add(data);
          received += data.length;
          currentRemaining -= data.length;
          final now = DateTime.now().millisecondsSinceEpoch;
          if (currentRemaining == 0 ||
              currentFile != lastEmitFile ||
              now - lastEmitAt >= 100) {
            lastEmitAt = now;
            lastEmitFile = currentFile;
            onProgress(received, totalBytes, currentFile);
          }
        }
      }
    } finally {
      // 任何退出路径（中断/异常）都确保文件句柄关闭，避免半成品文件占用
      try {
        await sink?.flush();
      } catch (_) {}
      try {
        await sink?.close();
      } catch (_) {}
    }
    await socket.close();
    reader.close();
    return false;
  }

  // ======================= 协议底层 =======================

  Future<void> _writeJson(Socket socket, Map<String, dynamic> json) async {
    final bytes = utf8.encode(jsonEncode(json));
    final header = Uint8List(4)
      ..buffer.asByteData().setUint32(0, bytes.length, Endian.big);
    socket.add(header);
    socket.add(bytes);
    await socket.flush();
  }

  // ======================= 路径工具 =======================

  String _relative(String root, String path) {
    final r = root.endsWith('/') ? root : '$root/';
    if (path.startsWith(r)) return path.substring(r.length);
    return _basename(path);
  }

  String _basename(String p) {
    final idx = p.lastIndexOf(Platform.pathSeparator);
    return idx >= 0 ? p.substring(idx + 1) : p;
  }

  String _dirname(String p) {
    final idx = p.lastIndexOf(Platform.pathSeparator);
    return idx >= 0 ? p.substring(0, idx) : '.';
  }

  String _join(String base, String rel) {
    if (rel.startsWith('/')) return rel;
    return base.endsWith('/') ? '$base$rel' : '$base/$rel';
  }
}

/// 基于 subscription 的 Socket 字节读取器：手动缓冲，精确读取 n 字节。
/// 不需要 async 包的 StreamQueue，降低依赖。
/// 公开类以便上游复用同一个 reader（Socket stream 是 single-sub，
/// 二次 new 注册监听会抛「Stream has already been listened to.」）。
class SocketReader {
  final Socket _socket;
  final List<int> _buffer = [];
  final Completer<void> _closed = Completer<void>();
  bool _done = false;

  SocketReader(this._socket) {
    _socket.listen(
      (data) {
        _buffer.addAll(data);
        _pump();
      },
      onDone: () {
        _done = true;
        _pump();
      },
      onError: (_) {
        _done = true;
        _pump();
      },
    );
  }

  final List<_ReadCompleter> _waiters = [];

  void _pump() {
    while (_waiters.isNotEmpty) {
      final w = _waiters.removeAt(0);
      final needed = w._needed;
      if (_buffer.length >= needed) {
        final out = Uint8List.fromList(_buffer.sublist(0, needed));
        _buffer.removeRange(0, needed);
        w.complete(out);
      } else if (_done) {
        if (_buffer.isNotEmpty) {
          final out = Uint8List.fromList(_buffer);
          _buffer.clear();
          w.complete(out);
        } else {
          w.complete(null);
        }
      } else {
        // 数据还不够，放回队列等下次
        _waiters.insert(0, w);
        break;
      }
    }
  }

  /// 精确读取 [n] 字节，不足或连接关闭返回 null
  Future<Uint8List?> readExact(int n) {
    if (_done && _buffer.length < n) {
      if (_buffer.isEmpty) return Future.value(null);
      final out = Uint8List.fromList(_buffer);
      _buffer.clear();
      return Future.value(out);
    }
    final c = _ReadCompleter(n);
    _waiters.add(c);
    _pump();
    return c.future;
  }

  /// 读取一个 JSON 帧（[4 字节长度][UTF-8 JSON]），连接关闭或非法返回 null
  Future<Map<String, dynamic>?> readJson() async {
    final lenBytes = await readExact(4);
    if (lenBytes == null) return null;
    final len = ByteData.sublistView(lenBytes).getUint32(0, Endian.big);
    final jsonBytes = await readExact(len);
    if (jsonBytes == null) return null;
    return jsonDecode(utf8.decode(jsonBytes)) as Map<String, dynamic>;
  }

  void close() {
    if (!_closed.isCompleted) _closed.complete();
  }
}

class _ReadCompleter implements Completer<Uint8List?> {
  final int _needed;
  final Completer<Uint8List?> _inner = Completer<Uint8List?>();
  _ReadCompleter(this._needed);
  @override
  void complete([FutureOr<Uint8List?>? value]) => _inner.complete(value);
  @override
  void completeError(Object error, [StackTrace? stackTrace]) =>
      _inner.completeError(error, stackTrace);
  @override
  Future<Uint8List?> get future => _inner.future;
  @override
  bool get isCompleted => _inner.isCompleted;
}

/// 对端设备
class PeerDevice {
  final String address;
  final String name;
  final int status;
  const PeerDevice({
    required this.address,
    required this.name,
    required this.status,
  });
  factory PeerDevice.fromMap(Map<String, dynamic> m) => PeerDevice(
        address: m['address'] as String,
        name: (m['name'] as String?) ?? (m['address'] as String),
        status: (m['status'] as int?) ?? 0,
      );
}

/// P2P 连接状态
class P2pConnectionState {
  final bool connected;
  final bool isGroupOwner;
  final String? groupOwnerAddress;
  const P2pConnectionState({
    required this.connected,
    required this.isGroupOwner,
    this.groupOwnerAddress,
  });
  factory P2pConnectionState.fromMap(Map<String, dynamic> m) => P2pConnectionState(
        connected: (m['connected'] as bool?) ?? false,
        isGroupOwner: (m['isGroupOwner'] as bool?) ?? false,
        groupOwnerAddress: m['groupOwnerAddress'] as String?,
      );
  static const disconnected = P2pConnectionState(
    connected: false,
    isGroupOwner: false,
    groupOwnerAddress: null,
  );
}

/// 文件清单项
class FileEntry {
  final String absolutePath;
  final String relativePath;
  final int size;
  final int mtime;
  const FileEntry({
    required this.absolutePath,
    required this.relativePath,
    required this.size,
    required this.mtime,
  });
}

/// 接收方看到的清单
class Manifest {
  final int totalBytes;
  final int totalCount;
  final List<FileEntry> files;
  const Manifest({
    required this.totalBytes,
    required this.totalCount,
    required this.files,
  });
}
