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
  /// socket 建立好后，两端先发 `{type:'peer_ready'}`，再阻塞等对方回
  /// peer_ready。只有双方 ready 才算连接握手成功，返回对应的 SocketReader
  /// （后续传输继续复用此 reader，避免对同一 single-sub socket stream 二次
  /// listen 抛「Bad state: Stream has already been listened to.」）。
  /// 取消回调返回 true 或 socket EOF（对方取消/断开）都立即中止并抛异常。
  ///
  /// 新版协议不再区分发送/接收角色（mode 已移除）：连接成功后双方皆可主动
  /// 发送、也随时可接收，由 [TransferSession] 统一调度。
  Future<SocketReader> doPeerReadyHandshake({
    required Socket socket,
    required Future<bool> Function() shouldCancel,
  }) async {
    final reader = SocketReader(socket);
    // 先发自己 ready
    await _writeJson(socket, {
      'type': 'peer_ready',
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
          // 握手成功：reader 不 close，交给 TransferSession 继续复用
          return reader;
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
  // 发送/接收逻辑已迁移至文件末尾的 [TransferSession]（对称、双方皆可收发）。

  // ======================= 接收方 =======================
  // 发送/接收逻辑已迁移至文件末尾的 [TransferSession]（对称、双方皆可收发）。

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
  // 分块队列替代单一 List<int>：① 每个元素是 Uint8List（1 字节/元素），
  //    避免 List<int> 每字节占 4~8 字节导致内存膨胀；② 用偏移推进而非
  //    removeRange(0,n)，消除 O(n) 头删卡死。
  final List<Uint8List> _chunks = [];
  int _total = 0; // 缓冲中的总字节数
  int _readOffset = 0; // 首块已读偏移
  final Completer<void> _closed = Completer<void>();
  bool _done = false;
  StreamSubscription? _sub;
  bool _paused = false;

  // 背压水位：缓冲超过高水位就暂停底层 socket 读取（传导 TCP 接收窗口背压，
  // 让发送方的 socket.flush() 自然阻塞，停止继续灌数据）；消费到低于低水位
  // 再恢复读取。这是修复「大文件接收一半卡死闪退」的关键——否则 _chunks 会
  // 无限增长直到 OOM 崩溃。
  static const int _highWater = 8 * 1024 * 1024; // 8MB
  static const int _lowWater = 1 * 1024 * 1024; // 1MB

  SocketReader(this._socket) {
    _sub = _socket.listen(
      (data) {
        final Uint8List bytes =
            data is Uint8List ? data : Uint8List.fromList(data);
        if (bytes.isNotEmpty) {
          _chunks.add(bytes);
          _total += bytes.length;
          _maybePause();
        }
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
      cancelOnError: false,
    );
  }

  void _maybePause() {
    if (!_paused && _total > _highWater) {
      _paused = true;
      _sub?.pause();
    }
  }

  void _maybeResume() {
    if (_paused && _total < _lowWater) {
      _paused = false;
      _sub?.resume();
    }
  }

  final List<_ReadCompleter> _waiters = [];

  void _pump() {
    while (_waiters.isNotEmpty) {
      final w = _waiters.removeAt(0);
      final needed = w._needed;
      if (_total >= needed) {
        final out = _readBytes(needed);
        w.complete(out);
      } else if (_done) {
        if (_total > 0) {
          final out = _readBytes(_total);
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
    _maybeResume();
  }

  /// 从分块队列中精确读取 [n] 字节（O(1) 推进偏移，不整体拷贝整块缓冲）。
  Uint8List _readBytes(int n) {
    final out = Uint8List(n);
    var filled = 0;
    while (filled < n) {
      final first = _chunks.first;
      final avail = first.length - _readOffset;
      if (avail == 0) {
        _chunks.removeAt(0);
        _readOffset = 0;
        continue;
      }
      final take = (n - filled) < avail ? (n - filled) : avail;
      out.setRange(filled, filled + take, first, _readOffset);
      filled += take;
      _readOffset += take;
      _total -= take;
      if (_readOffset == first.length) {
        _chunks.removeAt(0);
        _readOffset = 0;
      }
    }
    return out;
  }

  /// 精确读取 [n] 字节，不足或连接关闭返回 null
  Future<Uint8List?> readExact(int n) {
    if (_done && _total < n) {
      if (_total == 0) return Future.value(null);
      final out = _readBytes(_total);
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

/// 连接建立后的对称传输会话：双方都能随时发送，也随时接收对方发来的文件。
///
/// 单一 [SocketReader] 由本会话的接收循环独占；[sendFiles] 只负责写数据 +
/// 通过 `_pending` 等待接收循环转交的 accept/reject/receive_ack 响应，避免
/// 对 single-sub socket stream 二次 listen 抛「Stream has already been
/// listened to.」。同一时刻只允许一个传输（任一方向），[sendFiles] 与接收
/// 循环通过 `_transferring` 互斥，避免双向并发导致响应错乱。
class TransferSession {
  final Socket socket;
  final SocketReader reader;
  final QuickTransferService service;
  final String saveDir;
  final Future<bool> Function(Manifest) onIncomingManifest;
  final void Function(int received, int total, String currentFile) onReceiveProgress;
  final void Function(String relativePath) onFileSaved;
  final Future<bool> Function() shouldCancel;
  final void Function(dynamic error) onError;
  final Future<void> Function(bool success) onReceiveFinished;

  TransferSession({
    required this.socket,
    required this.reader,
    required this.service,
    required this.saveDir,
    required this.onIncomingManifest,
    required this.onReceiveProgress,
    required this.onFileSaved,
    required this.shouldCancel,
    required this.onError,
    required this.onReceiveFinished,
  });

  bool _active = true;
  bool _transferring = false;
  Completer<Map<String, dynamic>?>? _pending;

  /// 持久接收循环：读帧 → 分发。manifest 交接收子流程；accept/reject/
  /// receive_ack 是“本端发起的发送”的响应，转交 [sendFiles] 等待的 [_pending]。
  Future<void> run() async {
    try {
      while (_active) {
        final frame = await reader.readJson();
        if (frame == null) break; // 连接断开
        final type = frame['type'] as String?;
        if (type == 'manifest') {
          await _receiveOneTransfer(frame);
        } else if (type == 'accept' || type == 'reject' || type == 'receive_ack') {
          final p = _pending;
          _pending = null;
          p?.complete(frame);
        }
      }
    } catch (e) {
      onError(e);
    } finally {
      _active = false;
      _pending?.complete(null);
      _pending = null;
    }
  }

  /// 接收一个对端发来的传输（manifest → 文件流 → 落盘 → receive_ack）。
  /// 与 [run] 同一执行链，独占 reader 直到本传输结束，不会与接收循环抢读。
  Future<void> _receiveOneTransfer(Map<String, dynamic> frame) async {
    _transferring = true;
    IOSink? sink;
    try {
      final totalBytes = frame['totalBytes'] as int;
      final files = (frame['files'] as List)
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
      final manifest = Manifest(
        totalBytes: totalBytes,
        totalCount: frame['totalCount'] as int,
        files: files
            .map((m) => FileEntry(
                  absolutePath: '',
                  relativePath: m['relativePath'] as String,
                  size: m['size'] as int,
                  mtime: m['mtime'] as int,
                ))
            .toList(),
      );
      final accepted = await onIncomingManifest(manifest);
      if (!accepted) {
        await service._writeJson(socket, {'type': 'reject'});
        await socket.flush();
        await onReceiveFinished(false);
        return;
      }
      await service._writeJson(socket, {'type': 'accept'});
      await socket.flush();

      int received = 0;
      String? currentFile;
      int currentRemaining = 0;
      int lastEmitAt = 0;
      String lastEmitFile = '';

      // 继续从 reader 读取文件帧，直到收到 done
      while (true) {
        final lenBytes = await reader.readExact(4);
        if (lenBytes == null) break;
        final len = ByteData.sublistView(lenBytes).getUint32(0, Endian.big);
        final jsonBytes = await reader.readExact(len);
        if (jsonBytes == null) break;
        final map = jsonDecode(utf8.decode(jsonBytes)) as Map<String, dynamic>;
        final t = map['type'] as String;
        switch (t) {
          case 'file_start':
            currentFile = map['relativePath'] as String;
            currentRemaining = map['size'] as int;
            // 打开输出文件（覆盖写；append 在重传/残留半成品场景会叠加旧数据）
            await sink?.flush();
            await sink?.close();
            sink = null;
            final outPath = service._join(saveDir, currentFile);
            final dir = Directory(service._dirname(outPath));
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
            await service._writeJson(socket, {
              'type': 'receive_ack',
              'received': received,
              'totalBytes': totalBytes,
            });
            await socket.flush();
            await onReceiveFinished(true);
            return;
          case 'reject':
            await sink?.close();
            await onReceiveFinished(false);
            return;
          case 'accept':
            break;
        }
        // 文件数据模式：按 chunkSize 分块读取，每块立即落盘并回报进度
        while (currentFile != null && currentRemaining > 0) {
          final toRead = currentRemaining > QuickTransferService.chunkSize
              ? QuickTransferService.chunkSize
              : currentRemaining;
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
            onReceiveProgress(received, totalBytes, currentFile);
          }
        }
      }
      await onReceiveFinished(false);
    } finally {
      try {
        await sink?.flush();
      } catch (_) {}
      try {
        await sink?.close();
      } catch (_) {}
      _transferring = false;
    }
  }

  /// 本端主动发送文件：写 manifest → 等 accept/reject → 流式写文件 →
  /// 写 done → 等 receive_ack。响应通过 [_pending] 由接收循环转交。
  Future<void> sendFiles({
    required List<FileEntry> files,
    required void Function(int sent, int total, String currentFile) onProgress,
  }) async {
    if (_transferring) throw Exception('传输进行中，请稍后再发');
    _transferring = true;
    try {
      final totalBytes = files.fold<int>(0, (s, f) => s + f.size);
      int sent = 0;
      await service._writeJson(socket, {
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

      // 必须等待接收方"接受/拒绝"后再开始传输，否则数据会提前进入缓冲
      _pending = Completer<Map<String, dynamic>?>();
      final resp = await _pending!.future;
      if (resp == null) throw Exception('连接已断开，未能收到接收方的回应');
      if (resp['type'] == 'reject') throw Exception('对方已拒绝接收');

      // 进度节流：≥100ms 或文件切换或文件读完才回调，避免高频 setState 打爆 UI
      int lastEmitAt = 0;
      String lastEmitFile = '';
      for (final f in files) {
        if (await shouldCancel()) {
          await service._writeJson(socket, {'type': 'done', 'cancelled': true});
          return;
        }
        await service._writeJson(socket, {
          'type': 'file_start',
          'relativePath': f.relativePath,
          'size': f.size,
        });
        final file = File(f.absolutePath);
        int offset = 0;
        await for (final chunk in file.openRead()) {
          if (await shouldCancel()) {
            await service._writeJson(socket, {'type': 'done', 'cancelled': true});
            return;
          }
          socket.add(chunk);
          await socket.flush();
          offset += chunk.length;
          sent += chunk.length;
          final now = DateTime.now().millisecondsSinceEpoch;
          // 进度显示上限 = totalBytes - 1，所有数据 flush 完后 UI 停留在
          // 「等待对方接收完成…」的近 100% 态；收到 receive_ack 后才回调 100%。
          final displaySent = (sent < totalBytes) ? sent : totalBytes - 1;
          if (offset >= f.size ||
              f.relativePath != lastEmitFile ||
              now - lastEmitAt >= 100) {
            lastEmitAt = now;
            lastEmitFile = f.relativePath;
            onProgress(displaySent, totalBytes, f.relativePath);
          }
          if (offset % (QuickTransferService.chunkSize * 16) == 0) {
            await Future.delayed(Duration.zero);
          }
        }
        if (offset != f.size) {
          throw Exception('文件大小不一致: ${f.relativePath} ($offset/${f.size})');
        }
        await service._writeJson(socket, {
          'type': 'file_end',
          'relativePath': f.relativePath,
        });
      }
      await service._writeJson(socket, {'type': 'done', 'cancelled': false});

      // 阻塞等待接收方的落盘完成 ack
      _pending = Completer<Map<String, dynamic>?>();
      final ack = await _pending!.future;
      if (ack != null && ack['type'] == 'receive_ack') {
        onProgress(totalBytes, totalBytes, '');
      }
    } finally {
      _transferring = false;
    }
  }

  void dispose() {
    _active = false;
    try {
      socket.close();
    } catch (_) {}
    reader.close();
  }
}
