import 'dart:convert';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/network_connection_model.dart';
import 'remote/remote_client.dart';
import 'remote/ftp_client.dart';
import 'remote/sftp_client.dart';
import 'remote/webdav_client.dart';
import 'remote/lan_client.dart';
import 'remote/saf_client.dart';
// ⛔ 聚合网盘（夸克 / 阿里云盘）功能暂时下线（2026-09-30）：连接仍有问题，留待重做。
// 恢复步骤：① 取消下面两行 import 的注释；② 恢复 detectRemoteProtocolKind 里的
// netdisk 分支；③ 恢复 buildRemoteClient 里的 netdisk 分支；④ 恢复各 UI 入口
// （network_connection_wizard_screen 的添加区、network_category_screen 的连接过滤）。
// import 'remote/netdisk/quark_client.dart';
// import 'remote/netdisk/alipan_client.dart';

/// 远程连接协议类型（由 `NetworkConnectionModel.type` 解析而来）。
///
/// ⚠️ `netdisk` 目前**不参与解析**（聚合网盘暂时下线），保留枚举值便于恢复。
enum RemoteProtocolKind { sftp, ftp, webdav, smb, saf, netdisk }

/// 从 `NetworkConnectionModel.type` 解析协议类型。
///
/// ⚠️ `type` 字段**取值不统一**：
///  - FTP / SFTP / WebDav / saf 存的是固定英文常量（向导里 `_selectedType` = 协议名）；
///  - **SMB 存的是本地化标签**（`L10n.smb`：中文「局域网/SMB」、英文「LAN/SMB」、
///    繁体「區域網/SMB」），历史版本还存过 `SMB` / `Samba` / `CIFS`。
/// 因此一律用小写**包含**匹配，绝不写字符串等值比较（换语言后必失配，曾致
/// 「编辑老连接时 SMB 专属 UI 整块消失」）。
///
/// 顺序要求：`sftp` 必须先于 `ftp`（`sftp` 本身就含子串 `ftp`）。
RemoteProtocolKind? detectRemoteProtocolKind(String? type) {
  if (type == null) return null;
  final t = type.toLowerCase();
  // ⛔ 聚合网盘暂时下线：不再把 NETDISK_* 识别为网盘协议，残留连接会走
  // 「不支持的类型」分支，而不是停在半可用状态。
  // if (t.contains('netdisk')) return RemoteProtocolKind.netdisk;
  if (t.contains('sftp')) return RemoteProtocolKind.sftp;
  if (t.contains('saf')) return RemoteProtocolKind.saf;
  if (t.contains('smb') || t.contains('samba') || t.contains('cifs')) {
    return RemoteProtocolKind.smb;
  }
  if (t.contains('dav') || t.contains('web')) return RemoteProtocolKind.webdav;
  if (t.contains('ftp')) return RemoteProtocolKind.ftp;
  return null;
}

class NetworkConnectionsService {
  static const String _keyConnections = 'network_connections';
  static SharedPreferences? _prefs;

  static Future<void> init() async {
    _prefs ??= await SharedPreferences.getInstance();
    await _loadSecretsFromSecureStorage();
    await _migratePlaintextCredentialsIfNeeded();
  }

  /// 启动时把 secure storage 中已保存的凭据载入内存缓存，
  /// 供同步的 [getConnections] 水合使用。
  static Future<void> _loadSecretsFromSecureStorage() async {
    final str = _prefs?.getString(_keyConnections);
    if (str == null || str.isEmpty) return;
    try {
      final list = json.decode(str) as List<dynamic>;
      for (final raw in list) {
        final id = (raw as Map<String, dynamic>)['id'] as String?;
        if (id == null || _secrets.containsKey(id)) continue;
        try {
          final value = await _secure.read(key: _credKey(id));
          if (value != null && value.isNotEmpty) {
            final decoded = json.decode(value) as Map<String, dynamic>;
            _secrets[id] = {
              'password': (decoded['password'] as String?) ?? '',
              'sshKeyPassword': (decoded['sshKeyPassword'] as String?) ?? '',
              'proxyPassword': (decoded['proxyPassword'] as String?) ?? '',
            };
          }
        } catch (_) {
          // 单条读取失败只影响该连接的凭据水合，不阻塞启动
        }
      }
    } catch (_) {}
  }

  static List<NetworkConnectionModel> getConnections() {
    if (_prefs == null) return [];
    final str = _prefs!.getString(_keyConnections);
    if (str == null || str.isEmpty) return [];
    try {
      final list = json.decode(str) as List<dynamic>;
      return list
          .map((e) => _hydrateCredentials(NetworkConnectionModel.fromJson(e as Map<String, dynamic>)))
          .toList();
    } catch (_) {
      return [];
    }
  }

  // ── 凭据安全存储 ─────────────────────────────────────────────────────────
  //
  // 连接口令 / SSH 私钥口令属高敏数据，历史上曾以明文 JSON 存于
  // SharedPreferences（可被云备份 / adb backup 导出）。现统一迁入
  // FlutterSecureStorage（Android Keystore / iOS Keychain），SharedPreferences
  // 中只保留脱敏后的连接元数据。`init()` 时一次性完成旧数据迁移。

  static const FlutterSecureStorage _secure = FlutterSecureStorage();
  static String _credKey(String id) => 'rc_cred_$id';

  /// 连接 id → {password, sshKeyPassword}（内存缓存，init 时填充）
  static final Map<String, Map<String, String>> _secrets = {};

  static NetworkConnectionModel _hydrateCredentials(NetworkConnectionModel conn) {
    final secrets = _secrets[conn.id];
    if (secrets == null) return conn;
    return NetworkConnectionModel(
      id: conn.id,
      name: conn.name,
      type: conn.type,
      host: conn.host,
      port: conn.port,
      username: conn.username,
      password: conn.password.isNotEmpty ? conn.password : (secrets['password'] ?? ''),
      rootPath: conn.rootPath,
      protocol: conn.protocol,
      sshKeyPath: conn.sshKeyPath,
      sshKeyPassword: conn.sshKeyPassword ?? secrets['sshKeyPassword'],
      authMethod: conn.authMethod,
      proxyPassword: conn.proxyPassword ?? secrets['proxyPassword'],
    );
  }

  static Future<void> _storeCredentials(NetworkConnectionModel conn) async {
    _secrets[conn.id] = {
      'password': conn.password,
      'sshKeyPassword': conn.sshKeyPassword ?? '',
      'proxyPassword': conn.proxyPassword ?? '',
    };
    try {
      await _secure.write(key: _credKey(conn.id), value: json.encode(_secrets[conn.id]));
    } catch (_) {
      // secure storage 写失败时保留内存缓存，本会话仍可用；下次保存会重试
    }
  }

  static Future<void> _deleteCredentials(String id) async {
    _secrets.remove(id);
    try {
      await _secure.delete(key: _credKey(id));
    } catch (_) {}
  }

  /// 备份导出：所有连接的凭据（id → {password, sshKeyPassword}）。
  ///
  /// 仅供全局备份链路调用；返回值必须先经备份口令加密（见
  /// BackupSecretsCodec）才能落盘，绝不能以明文写进任何文件或日志。
  static Map<String, Map<String, String>> exportAllCredentials() {
    return _secrets.map(
      (id, secrets) => MapEntry(id, Map<String, String>.from(secrets)),
    );
  }

  /// 备份恢复导入：写回内存缓存并逐条落 FlutterSecureStorage。
  ///
  /// [credentials] 形如 {id: {password, sshKeyPassword}}（来自备份 JSON
  /// 解密后的 connection_credentials 段）。暂不存在的连接 id 写了也无妨，
  /// 凭据按 id 与后续恢复的连接元数据对齐。
  static Future<void> importAllCredentials(
    Map<String, dynamic> credentials,
  ) async {
    for (final entry in credentials.entries) {
      final value = entry.value;
      if (value is! Map) continue;
      final secrets = <String, String>{
        'password': (value['password'] as String?) ?? '',
        'sshKeyPassword': (value['sshKeyPassword'] as String?) ?? '',
      };
      _secrets[entry.key] = secrets;
      try {
        await _secure.write(key: _credKey(entry.key), value: json.encode(secrets));
      } catch (_) {
        // secure storage 写失败时保留内存缓存，本会话仍可用
      }
    }
  }

  /// 一次性迁移：把旧版明文存于 SharedPreferences 的口令搬进 secure storage，
  /// 并将 JSON 重写为脱敏版本（password / sshKeyPassword 置空）。
  static Future<void> _migratePlaintextCredentialsIfNeeded() async {
    final str = _prefs?.getString(_keyConnections);
    if (str == null || str.isEmpty) return;
    try {
      final list = json.decode(str) as List<dynamic>;
      var migrated = false;
      for (final raw in list) {
        final map = raw as Map<String, dynamic>;
        final id = map['id'] as String?;
        if (id == null) continue;
        final password = (map['password'] as String?) ?? '';
        final sshKeyPassword = map['sshKeyPassword'] as String?;
        final proxyPassword = map['proxyPassword'] as String?;
        final hasPlaintext = password.isNotEmpty ||
            (sshKeyPassword != null && sshKeyPassword.isNotEmpty) ||
            (proxyPassword != null && proxyPassword.isNotEmpty);
        if (hasPlaintext) {
          _secrets[id] = {
            'password': password,
            'sshKeyPassword': sshKeyPassword ?? '',
            'proxyPassword': proxyPassword ?? '',
          };
          try {
            await _secure.write(key: _credKey(id), value: json.encode(_secrets[id]));
          } catch (_) {}
          map['password'] = '';
          map['sshKeyPassword'] = null;
          map['proxyPassword'] = null;
          migrated = true;
        }
      }
      if (migrated) {
        await _prefs?.setString(_keyConnections, json.encode(list));
      }
    } catch (_) {
      // 迁移失败不影响启动：明文数据仍在原处，下次启动重试
    }
  }

  /// 序列化连接列表为脱敏 JSON：password / sshKeyPassword 不落 SharedPreferences，
  /// 真实凭据只存 secure storage（见 [_storeCredentials]）。
  static String _scrubbedJson(List<NetworkConnectionModel> connections) {
    return json.encode(connections.map((e) {
      final map = e.toJson();
      map['password'] = '';
      map['sshKeyPassword'] = null;
      map['proxyPassword'] = null;
      return map;
    }).toList());
  }

  static Future<void> saveConnection(NetworkConnectionModel conn) async {
    await init();
    await _storeCredentials(conn);
    final current = getConnections();
    final index = current.indexWhere((c) => c.id == conn.id);
    if (index >= 0) {
      current[index] = conn;
    } else {
      current.add(conn);
    }
    await _prefs?.setString(_keyConnections, _scrubbedJson(current));
  }

  static Future<void> deleteConnection(String id) async {
    await init();
    await _deleteCredentials(id);
    final current = getConnections();
    current.removeWhere((c) => c.id == id);
    await _prefs?.setString(_keyConnections, _scrubbedJson(current));
  }

  /// 拖动排序：按 [visibleOrder] 这一新顺序写回全部连接。
  ///
  /// ⚠️ 列表页会先把「已下线的网盘连接」过滤掉再展示，所以 [visibleOrder] 通常
  /// 是全量列表的**子集**，它的下标不等于全量下标——直接按它重写会把被过滤掉
  /// 的条目挤掉/错位。这里先把可见项在全量列表中的槽位收集出来（升序），只在
  /// 这些槽位上按新顺序填回，其余条目保持原有位置不动。
  ///
  /// 长度为 0 或槽位数与入参不一致（例如期间别处增删了连接）时直接放弃本次
  /// 写入，宁可不排序也不能把连接写丢。
  static Future<void> reorderConnections(
    List<NetworkConnectionModel> visibleOrder,
  ) async {
    await init();
    final all = getConnections();
    final visibleIds = visibleOrder.map((c) => c.id).toSet();
    final slots = <int>[];
    for (var i = 0; i < all.length; i++) {
      if (visibleIds.contains(all[i].id)) slots.add(i);
    }
    if (slots.isEmpty || slots.length != visibleOrder.length) return;
    for (var k = 0; k < slots.length; k++) {
      all[slots[k]] = visibleOrder[k];
    }
    await _prefs?.setString(_keyConnections, _scrubbedJson(all));
  }

  /// 判断连接类型是否为 SMB（局域网）。标签本地化（中文「局域网/SMB」、英文
  /// 「LAN/SMB」），历史版本还存过 `Samba` / `CIFS`，故统一交给
  /// [detectRemoteProtocolKind] 做包含匹配，与 [FileManagerProvider.isSmbType] 一致。
  static bool isSmbType(String type) =>
      detectRemoteProtocolKind(type) == RemoteProtocolKind.smb;

  /// 中立的远程客户端工厂：按连接模型构造正确的 [RemoteClient] 子类。
  ///
  /// ⚠️ 放在此处（而非 `FileManagerProvider`）是为了避免循环依赖：
  /// `file_manager_provider` 已依赖 `crypt_stream_server`，若 crypt 流式解密
  /// 服务再反向调用 `FileManagerProvider.createRemoteClient` 就会形成环。
  /// 本方法无 UI / 无 crypt 依赖，可被两侧安全复用，逻辑与
  /// [FileManagerProvider.createRemoteClient] 保持一致。
  /// 测试注入点：非 null 时由用例提供伪造的 [RemoteClient]。
  ///
  /// 供「远程密文解密到本地 / 远程原地加解密」这类上层链路写集成测试用
  /// （本项目的约定：不要靠加日志让用户反复复现，给关键类留注入点本机验证）。
  /// 生产环境恒为 null，走下方真实协议分支。
  static RemoteClient Function(NetworkConnectionModel conn)? builderForTest;

  static RemoteClient buildRemoteClient(NetworkConnectionModel conn) {
    final fake = builderForTest;
    if (fake != null) return fake(conn);
    // 一律走 detectRemoteProtocolKind（包含匹配）而非 `conn.type == 'XXX'`：
    // type 可能是本地化标签，精确比较在换语言 / 编辑老连接时会失配并抛
    // ArgumentError('Unsupported connection type')，表现为整条连接打不开。
    final kind = detectRemoteProtocolKind(conn.type);
    if (kind == RemoteProtocolKind.ftp) {
      return FtpRemoteClient(
        host: conn.host,
        port: conn.port,
        username: conn.username,
        password: conn.password,
        proxyType: conn.proxyType,
        proxyHost: conn.proxyHost,
        proxyPort: conn.proxyPort,
        proxyUsername: conn.proxyUsername,
        proxyPassword: conn.proxyPassword,
      );
    }
    if (kind == RemoteProtocolKind.sftp) {
      return SftpRemoteClient(
        host: conn.host,
        port: conn.port,
        username: conn.username,
        password: conn.password,
        sshKeyPath: conn.sshKeyPath,
        sshKeyPassword: conn.sshKeyPassword,
        authMethod: conn.authMethod,
        proxyType: conn.proxyType,
        proxyHost: conn.proxyHost,
        proxyPort: conn.proxyPort,
        proxyUsername: conn.proxyUsername,
        proxyPassword: conn.proxyPassword,
      );
    }
    if (kind == RemoteProtocolKind.webdav) {
      return WebDavRemoteClient(
        host: conn.host,
        port: conn.port,
        username: conn.username,
        password: conn.password,
        protocol: conn.protocol,
        rootPath: conn.rootPath,
        proxyType: conn.proxyType,
        proxyHost: conn.proxyHost,
        proxyPort: conn.proxyPort,
        proxyUsername: conn.proxyUsername,
        proxyPassword: conn.proxyPassword,
      );
    }
    if (kind == RemoteProtocolKind.smb) {
      return LanClient(
        host: conn.host,
        port: conn.port,
        username: conn.username,
        password: conn.password,
        proxyType: conn.proxyType,
        proxyHost: conn.proxyHost,
        proxyPort: conn.proxyPort,
        proxyUsername: conn.proxyUsername,
        proxyPassword: conn.proxyPassword,
      );
    }
    if (kind == RemoteProtocolKind.saf) {
      return SafRemoteClient(rootUri: conn.rootPath);
    }
    // ⛔ 聚合网盘暂时下线（见文件头说明）：不再构造网盘客户端。
    // if (kind == RemoteProtocolKind.netdisk) {
    //   if (conn.type.toLowerCase().contains('quark')) {
    //     return QuarkRemoteClient(connection: conn);
    //   }
    //   return AlipanRemoteClient(connection: conn);
    // }
    throw ArgumentError('Unsupported connection type: ${conn.type}');
  }
}
