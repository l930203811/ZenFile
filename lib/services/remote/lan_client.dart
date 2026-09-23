import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'remote_client.dart';

/// Discovered server entry on the local network.
class LanDiscoveredServer {
  final String host;
  final int port;
  final String type; // 'FTP', 'SFTP', 'SMB', 'WebDav'
  final String name;

  /// 通过 NetBIOS 名称服务解析出的计算机名（解析不到时为 null）。
  final String? hostName;

  LanDiscoveredServer({
    required this.host,
    required this.port,
    required this.type,
    required this.name,
    this.hostName,
  });
}

/// 局域网扫描得到的 SMB 主机：地址 + 解析出的主机名 + 可列出的共享名。
/// 无主机名时 [displayName] 回退为 IP，保证旧行为不变。
class SmbDiscoveredDevice {
  final String host;
  final String? hostName;
  final List<String> shares;

  SmbDiscoveredDevice({
    required this.host,
    this.hostName,
    this.shares = const <String>[],
  });

  String get displayName =>
      (hostName != null && hostName!.isNotEmpty) ? hostName! : host;

  /// 是否解析到了与 IP 不同的主机名（用于决定是否额外显示 IP 副标题）。
  bool get hasHostName => hostName != null && hostName!.isNotEmpty && hostName != host;
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
/// 匿名（用户名为空）时依次尝试的身份。
///
/// 为什么需要一组候选：Samba 的匿名实现因固件而异 ——
///  - 标准做法（NTLMSSP anonymous）：提交**空用户名**；
///  - `map to guest = Bad User` 的服务器：任意无效用户名都会被映射到 guest account；
///  - 部分固件把匿名账号设成别的名字（如 `anonymous`），只认字面提交。
/// 旧实现硬编码 `guest`（见原生 SmbService），碰上"匿名账号不叫 guest"的
/// OpenWrt 固件就会被 STATUS_LOGON_FAILURE 直接拒绝（2026-09-20 用户反馈）。
/// 顺序按「最标准 → 最特殊」，命中即停。
const List<String> kSmbAnonymousUsernames = <String>['', 'guest', 'anonymous', 'nobody'];

/// 计算 SMB 实际要尝试的用户名序列：非匿名（用户填了名字）时只试一次。
List<String> smbUsernameAttempts(String username) {
  final trimmed = username.trim();
  if (trimmed.isNotEmpty) return <String>[trimmed];
  return kSmbAnonymousUsernames;
}

class LanClient extends RemoteClient {
  static const MethodChannel _channel = MethodChannel('com.sequl.zenfile/smb');

  // SMB 的原生 downloadRange 用 smbj 的 InputStream.skip(offset)（仅更新内部
  // readOffset，不实际传输被跳过的字节）做随机读，支持按需区间流式播放。
  @override
  bool get supportsRangeRead => true;

  final String host;
  final int port;
  final String username;
  final String password;
  final String domain;

  String? _sessionId;
  bool _isConnected = false;

  /// 匿名候选链最终命中的用户名（仅诊断用；非匿名为用户填写的值）。
  String? _resolvedUsername;
  String? get resolvedUsername => _resolvedUsername;

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

  /// Scan the local subnet(s) for likely file-share services.
  /// This is a TCP port-probe only; it does not actually authenticate.
  ///
  /// 网段来源：遍历所有活动网卡的 /24 子网，WLAN 网卡优先（多网卡设备如
  /// 同时开移动数据/VPN 时，取 `localIps.first` 可能选错网段导致扫不到设备）。
  /// 端口探测：SMB(445) 每个主机尝试 2 次、单次 500ms —— 首次连接含 ARP
  /// 解析常超 150ms（尤其路由器/NAS），旧版 150ms 单次超时会漏掉大量主机；
  /// 其余端口 300ms 单次。并发按 64 个主机分批，避免一次性打满 socket 表。
  ///
  /// 探测结束后对已响应主机做一次 NetBIOS 名称解析（[resolveNetbiosName]），
  /// 让 UI 能显示计算机名而非只有 IP。
  static Future<List<LanDiscoveredServer>> scanSubnet({
    required Function(double progress) onProgress,
    /// 限定要探测的端口（默认 445/21/22/80/8080 全扫）。SMB 向导只关心 445，
    /// 收窄后不可达主机的串行等待从 ~2.2s 降到 ~1.0s，整网段扫描近乎减半。
    Map<int, String>? ports,
  }) async {
    final discovered = <LanDiscoveredServer>[];

    // 1) 收集待扫网段：WLAN 优先，其余非回环 IPv4 网段兜底
    final wlanSubnets = <String>[];
    final otherSubnets = <String>[];
    try {
      final interfaces = await NetworkInterface.list();
      for (final interface in interfaces) {
        final isWlan = interface.name.toLowerCase().contains('wlan');
        for (final addr in interface.addresses) {
          if (addr.type != InternetAddressType.IPv4 || addr.isLoopback) continue;
          final parts = addr.address.split('.');
          if (parts.length < 4) continue;
          final subnet = '${parts[0]}.${parts[1]}.${parts[2]}';
          if (isWlan) {
            if (!wlanSubnets.contains(subnet)) wlanSubnets.add(subnet);
          } else if (!otherSubnets.contains(subnet) && !wlanSubnets.contains(subnet)) {
            otherSubnets.add(subnet);
          }
        }
      }
    } catch (_) {}
    final subnets = [...wlanSubnets, ...otherSubnets];
    if (subnets.isEmpty) subnets.add('192.168.1');

    // 2) SMB 放最前优先探测
    final targetPorts = ports ??
        <int, String>{
          445: 'SMB',
          21: 'FTP',
          22: 'SFTP',
          80: 'WebDav',
          8080: 'WebDav',
        };

    const hostsPerSubnet = 254;
    const batchSize = 64;
    final totalHosts = hostsPerSubnet * subnets.length;
    var scannedCount = 0;

    for (final baseSubnet in subnets) {
      final futures = <Future<void>>[];
      for (var i = 1; i <= hostsPerSubnet; i++) {
        final ip = '$baseSubnet.$i';
        futures.add(Future(() async {
          for (final entry in targetPorts.entries) {
            final port = entry.key;
            final type = entry.value;
            // SMB 加一次重试：首连包含 ARP 解析，经常超过单次超时
            final ok = await _probePort(
              ip,
              port,
              timeout: Duration(milliseconds: port == 445 ? 500 : 300),
              attempts: port == 445 ? 2 : 1,
            );
            if (ok) {
              discovered.add(LanDiscoveredServer(
                host: ip,
                port: port,
                type: type,
                name: '$type Server ($ip)',
              ));
            }
          }
          scannedCount++;
          onProgress(scannedCount / totalHosts);
        }));
        // 分批限流：避免 254×5 个 socket 同时并发被系统丢弃
        if (futures.length >= batchSize) {
          await Future.wait(futures);
          futures.clear();
        }
      }
      if (futures.isNotEmpty) await Future.wait(futures);
    }

    // 3) 对已响应主机解析 NetBIOS 计算机名（只解析有响应的主机，通常 < 20 台）
    final uniqueIps = discovered.map((d) => d.host).toSet().toList();
    final nameMap = <String, String>{};
    const nameBatch = 16;
    for (var i = 0; i < uniqueIps.length; i += nameBatch) {
      final slice = uniqueIps.sublist(
        i,
        i + nameBatch > uniqueIps.length ? uniqueIps.length : i + nameBatch,
      );
      final resolved = await Future.wait(
        slice.map((ip) => resolveNetbiosName(ip)),
      );
      for (var j = 0; j < slice.length; j++) {
        final n = resolved[j];
        if (n != null && n.isNotEmpty) nameMap[slice[j]] = n;
      }
    }

    return discovered.map((d) {
      final n = nameMap[d.host];
      return LanDiscoveredServer(
        host: d.host,
        port: d.port,
        type: d.type,
        name: n != null ? '$n (${d.host})' : '${d.type} Server (${d.host})',
        hostName: n,
      );
    }).toList();
  }

  static final Random _random = Random();

  /// 通过 NetBIOS 名称服务（NBNS，UDP 137）查询主机的计算机名。
  ///
  /// 发送 NBSTAT（Node Status Request，通配名 `*`）后解析应答的名称表：
  /// 取「后缀 0x00 且非组名」的条目即计算机名（Windows / Samba / 多数 NAS
  /// 都会应答）。不支持 NetBIOS 的设备（部分 Android、禁用 NBNS 的群晖等）
  /// 不响应，超时返回 null——调用方回退为 IP 展示即可。
  static Future<String?> resolveNetbiosName(
    String ip, {
    Duration timeout = const Duration(milliseconds: 500),
  }) async {
    RawDatagramSocket? sock;
    StreamSubscription<RawSocketEvent>? sub;
    try {
      final s = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      sock = s;

      // 组包：header(12) + 通配名问题(NBSTAT)
      final txId = _random.nextInt(0xFFFF);
      final packet = <int>[
        (txId >> 8) & 0xFF,
        txId & 0xFF,
        0x00, 0x00, // flags：标准查询
        0x00, 0x01, // QDCOUNT
        0x00, 0x00, // ANCOUNT
        0x00, 0x00, // NSCOUNT
        0x00, 0x00, // ARCOUNT
        0x20, // 名称长度：32 字符（nibble 编码）
        0x43, 0x4B, // 通配名 '*'（0x2A）的前两个 nibble
        ...List<int>.filled(30, 0x41), // 其余 15 个 0x00 → 'A'
        0x00, // 名称终止符
        0x00, 0x21, // QTYPE = NBSTAT
        0x00, 0x01, // QCLASS = IN
      ];

      final completer = Completer<String?>();
      sub = s.listen((event) {
        if (event != RawSocketEvent.read) return;
        for (Datagram? dg = s.receive(); dg != null; dg = s.receive()) {
          if (dg.address.address != ip) continue;
          if (!completer.isCompleted) {
            completer.complete(_parseNbstatName(dg.data));
          }
          return;
        }
      });
      s.send(packet, InternetAddress(ip), 137);
      return await completer.future.timeout(timeout, onTimeout: () => null);
    } catch (_) {
      return null;
    } finally {
      final s0 = sub;
      if (s0 != null) {
        try {
          await s0.cancel();
        } catch (_) {}
      }
      try {
        sock?.close();
      } catch (_) {}
    }
  }

  /// 仅供测试：解析一段 NBSTAT 应答报文（真实设备不可 mock，故开放解析入口）。
  @visibleForTesting
  static String? parseNbstatNameForTest(List<int> data) => _parseNbstatName(data);

  /// 解析 NBSTAT 应答：跳过问题段/答案段的名称，读 RDATA 里的名称表。
  static String? _parseNbstatName(List<int> data) {
    try {
      if (data.length < 12 + 5) return null;
      final anCount = (data[6] << 8) | data[7];
      if (anCount < 1) return null;

      var o = 12;
      o = _skipDnsName(data, o); // 问题段名称
      o += 4; // QTYPE + QCLASS
      final answerStart = o;

      // 部分 Samba 响应（如 OpenWrt/Kwrt）不回显问题段，answer name 直接从
      // 偏移 12 开始（完整编码通配名），answer 的 TYPE/CLASS 紧跟在被当作
      // "问题段名称"跳过的那个名字后面。此时 answerStart 处已经是 TTL（4 个
      // 零字节），后接 RDLEN（2 字节），不再有独立的 answer name / TYPE / CLASS 字段。
      // 判断：连续 4 个零字节 + RDLEN 不超过报文剩余长度。
      final possibleRdLen = o + 6 <= data.length
          ? ((data[o + 4] << 8) | data[o + 5])
          : 0;
      final noQuestionEcho = o + 6 <= data.length &&
          data[o] == 0 && data[o + 1] == 0 &&
          data[o + 2] == 0 && data[o + 3] == 0 &&
          possibleRdLen > 0 && possibleRdLen <= data.length - o - 6;
      if (noQuestionEcho) {
        o += 4; // 跳过 TTL
      } else {
        o = _skipDnsName(data, o); // 答案段名称
        o += 8; // TYPE(2) + CLASS(2) + TTL(4)
      }
      if (o + 2 > data.length) return null;
      final rdLength = (data[o] << 8) | data[o + 1];
      o += 2;
      if (o >= data.length) return null;
      final picked = _pickNameFromTable(data, o + 1, data[o], rdLength);
      if (picked != null) return picked;

      // 兜底：报文结构意外时，从答案段起搜 NBSTAT 记录头
      final p = _indexOfSeq(data, const [0x00, 0x21, 0x00, 0x01], 12);
      if (p < 0) return null;
      final q = p + 4 + 4; // TYPE/CLASS + TTL
      if (q + 2 > data.length) return null;
      final rd = (data[q] << 8) | data[q + 1];
      final start = q + 2;
      if (start >= data.length) return null;
      return _pickNameFromTable(data, start + 1, data[start], rd);
    } catch (_) {
      return null;
    }
  }

  /// 跳过 DNS 名称（支持 0xC0 压缩指针），返回下一个字段的偏移。
  static int _skipDnsName(List<int> data, int offset) {
    var o = offset;
    while (o < data.length) {
      final len = data[o];
      if (len == 0) return o + 1;
      if ((len & 0xC0) == 0xC0) return o + 2;
      o += 1 + len;
    }
    return o;
  }

  /// 从 NBSTAT 名称表里挑计算机名：优先「后缀 0x00 唯一」，其次「后缀 0x20 唯一」。
  static String? _pickNameFromTable(
    List<int> data,
    int tableStart,
    int numNames,
    int rdLength,
  ) {
    String? fallback;
    final tableEnd = tableStart + rdLength;
    for (var i = 0; i < numNames; i++) {
      final e = tableStart + i * 18; // 每条 15 名称 + 1 后缀 + 2 flags
      if (e + 18 > tableEnd || e + 18 > data.length) break;
      final suffix = data[e + 15];
      final isGroup = (data[e + 16] & 0x80) != 0;
      var name = '';
      for (var k = 0; k < 15; k++) {
        final ch = data[e + k];
        if (ch == 0 || ch == 0x20) break; // NetBIOS 名以空格/0 补齐
        name += String.fromCharCode(ch);
      }
      name = name.trim();
      if (name.isEmpty || isGroup) continue;
      if (suffix == 0x00) return name;
      if (suffix == 0x20) fallback ??= name;
    }
    return fallback;
  }

  static int _indexOfSeq(List<int> data, List<int> seq, int from) {
    for (var i = from; i + seq.length <= data.length; i++) {
      var ok = true;
      for (var j = 0; j < seq.length; j++) {
        if (data[i + j] != seq[j]) {
          ok = false;
          break;
        }
      }
      if (ok) return i;
    }
    return -1;
  }

  /// TCP 端口探测：[attempts] 次尝试内任一次连通即视为开放。
  static Future<bool> _probePort(
    String ip,
    int port, {
    Duration timeout = const Duration(milliseconds: 400),
    int attempts = 1,
  }) async {
    for (var i = 0; i < attempts; i++) {
      try {
        final socket = await Socket.connect(ip, port, timeout: timeout);
        socket.destroy();
        return true;
      } catch (_) {}
    }
    return false;
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
    // 匿名（用户名为空）时按候选链依次尝试：不同固件的 Samba 匿名账号名不同，
    // 只试一个必然在部分固件上失败（见 kSmbAnonymousUsernames 注释）。
    final attempts = smbUsernameAttempts(username);
    final failures = <String>[];
    for (var i = 0; i < attempts.length; i++) {
      final candidate = attempts[i];
      final bool isLast = i == attempts.length - 1;
      // 匿名候选链每步给较短超时（认证被拒通常秒回，30s 只留给真正的连接等待）；
      // 非匿名（用户填了账号）保持原有 30s 行为。
      final timeout = attempts.length > 1
          ? const Duration(seconds: 15)
          : const Duration(seconds: 30);
      try {
        final result = await _channel.invokeMethod<String>('connect', {
          'host': host,
          'port': port,
          'username': candidate,
          'password': password,
          'domain': domain,
        }).timeout(timeout);
        if (result == null || result.isEmpty) {
          throw Exception('Native SMB client returned empty session id');
        }
        _sessionId = result;
        _isConnected = true;
        _resolvedUsername = candidate;
        if (failures.isNotEmpty) {
          // 首个候选（标准空用户名）被拒、靠后面的候选救回来：留一笔日志，
          // 便于定位"某些固件只认 anonymous/guest"这类差异。
          debugPrint(
            '[ZenFile] SMB 匿名登录候选回退：${failures.join(' , ')} → '
            '"${candidate.isEmpty ? '<空用户名>' : candidate}" 成功',
          );
        }
        return;
      } on PlatformException catch (e) {
        _isConnected = false;
        _sessionId = null;
        final label = candidate.isEmpty ? '<空用户名>' : candidate;
        failures.add('"$label"(${e.code}: ${e.message})');
        if (isLast) {
          throw Exception(
            'SMB connect failed: ${e.code}: ${e.message}'
            '${attempts.length > 1 ? '（匿名候选均已尝试：${failures.join(' | ')}）' : ''}',
          );
        }
      } on TimeoutException {
        _isConnected = false;
        _sessionId = null;
        final label = candidate.isEmpty ? '<空用户名>' : candidate;
        failures.add('"$label"(超时 ${timeout.inSeconds}s)');
        if (isLast) {
          throw Exception(
            'SMB connect timed out after ${timeout.inSeconds}s (host=$host:$port)'
            '${attempts.length > 1 ? '（匿名候选均已尝试：${failures.join(' | ')}）' : ''}',
          );
        }
      }
    }
    // 正常路径在循环内必然 return 或 throw，这里是防御式兜底。
    throw Exception('SMB connect failed（匿名候选均已尝试）：${failures.join(' | ')}');
  }

  /// 查询原生 JVM 里 smbj Connection 的真实状态。
  ///
  /// 不能只信 Dart 侧的 [_isConnected]：应用切后台 / 网络切换后 socket 会被
  /// 回收，标记却还是 true（假连接），下一次操作必然失败。
  @override
  Future<bool> checkAlive() async {
    final id = _sessionId;
    if (!_isConnected || id == null) return false;
    try {
      final alive = await _channel
          .invokeMethod<bool>('isAlive', {'sessionId': id})
          .timeout(const Duration(seconds: 5));
      if (alive != true) {
        _isConnected = false;
      }
      return alive == true;
    } catch (_) {
      // 原生查询失败（通道异常 / 会话已被原生清理）同样视为不可用。
      return false;
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

  @override
  void cancel() {
    // 同步置位基类标志，保证 Dart 层 isCancelled 可见，供上层安全网判断取消。
    super.cancel();
    final session = _sessionId;
    if (session != null) {
      _channel.invokeMethod<void>('cancelTransfer', {'sessionId': session});
    }
  }

  @override
  void resetCancel() {
    // 必须重置基类标志，否则一次取消后 isCancelled 永远为 true。
    super.resetCancel();
    final session = _sessionId;
    if (session != null) {
      _channel.invokeMethod<void>('resetCancel', {'sessionId': session});
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
  Future<List<RemoteFileItem>> listDirectory(String path, {bool forceRefresh = false}) async {
    final session = _requireSession;
    final normalized = _normalizePath(path);

    final result = await _channel.invokeMethod<List<dynamic>>(
      'listDirectory',
      {'sessionId': session, 'path': normalized, 'forceRefresh': forceRefresh},
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
    // 不删除已存在的目标文件：原生侧 FileOutputStream 打开时会自行截断覆盖
    //（同一路径、同一 inode）。此处 deleteSync 会把流式代理【预创建并可能已
    // 打开读句柄】的 .partial 变成孤儿 inode——代理旧句柄永远读到空数据，
    // 表现为播放几秒后画面卡死。
    file.parent.createSync(recursive: true);

    // Kick off the download on the native side. The native helper streams
    // the bytes to disk synchronously (from this isolate's perspective),
    // so we emulate progress by polling the file size while it grows.
    // getFileSize 可能耗时 10s+（网络慢时），导致流式播放超时。
    // 用 2s 超时，超时就跳过 — 进度不更新但数据立即开始下载。
    final totalFuture = getFileSize(remotePath).timeout(
      const Duration(seconds: 2),
      onTimeout: () => -1,
    );

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
      // 原生层因取消返回 false 时，优先按“已取消”处理（而非“传输失败”）
      if (isCancelled) throw Exception('Cancelled');
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

    // 轮询「原生侧维护的上传字节计数」来显示进度。
    // 注意：不要在此轮询 getFileSize(remotePath) —— 它会与正在进行的上传
    // 争用同一个 smbj 会话，可能阻塞/死锁会话导致上传 future 永不返回（卡在 100%）。
    Timer? progressTimer;
    if (totalSize > 0) {
      progressTimer = Timer.periodic(const Duration(milliseconds: 200), (_) async {
        try {
          final current = await getTransferProgress();
          if (current > 0 && current <= totalSize) {
            onProgress((current / totalSize).clamp(0.0, 0.99));
          }
        } catch (_) {}
      });
    }

    try {
      Duration timeout = const Duration(minutes: 30);
      if (totalSize > 1024 * 1024 * 1024) {
        final estimatedMinutes = (totalSize / (10 * 1024 * 1024) / 60).ceil() + 10;
        timeout = Duration(minutes: estimatedMinutes.clamp(30, 240));
      }
      final success = await uploadFuture.timeout(timeout);
      // 原生层因取消返回 false 时，优先按“已取消”处理（而非“传输失败”）
      if (isCancelled) throw Exception('Cancelled');
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
  Future<String?> getStreamUrl(String remotePath) async {
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

  /// 返回当前会话「上传」已写入的字节数（原生侧在 uploadFile 循环中维护）。
  /// 用于安全轮询上传进度：只读取原生端的内存计数，不触发任何 SMB 操作，
  /// 因此不会与正在进行的上传争用同一会话而阻塞/死锁。未上传或已结束返回 -1。
  Future<int> getTransferProgress() async {
    final session = _requireSession;
    try {
      final result = await _channel.invokeMethod<num>('getTransferProgress', {
        'sessionId': session,
      }).timeout(const Duration(seconds: 5));
      return result?.toInt() ?? -1;
    } catch (e) {
      debugPrint('SMB getTransferProgress error: $e');
      return -1;
    }
  }
}
