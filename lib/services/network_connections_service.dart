import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/network_connection_model.dart';
import 'remote/remote_client.dart';
import 'remote/ftp_client.dart';
import 'remote/sftp_client.dart';
import 'remote/webdav_client.dart';
import 'remote/lan_client.dart';
import 'remote/saf_client.dart';

class NetworkConnectionsService {
  static const String _keyConnections = 'network_connections';
  static SharedPreferences? _prefs;

  static Future<void> init() async {
    _prefs ??= await SharedPreferences.getInstance();
  }

  static List<NetworkConnectionModel> getConnections() {
    if (_prefs == null) return [];
    final str = _prefs!.getString(_keyConnections);
    if (str == null || str.isEmpty) return [];
    try {
      final list = json.decode(str) as List<dynamic>;
      return list
          .map((e) => NetworkConnectionModel.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return [];
    }
  }

  static Future<void> saveConnection(NetworkConnectionModel conn) async {
    await init();
    final current = getConnections();
    final index = current.indexWhere((c) => c.id == conn.id);
    if (index >= 0) {
      current[index] = conn;
    } else {
      current.add(conn);
    }
    final str = json.encode(current.map((e) => e.toJson()).toList());
    await _prefs?.setString(_keyConnections, str);
  }

  static Future<void> deleteConnection(String id) async {
    await init();
    final current = getConnections();
    current.removeWhere((c) => c.id == id);
    final str = json.encode(current.map((e) => e.toJson()).toList());
    await _prefs?.setString(_keyConnections, str);
  }

  /// 判断连接类型是否为 SMB（局域网）。标签是本地化的（中文「局域网/SMB」、
  /// 英文「LAN/SMB」），因此按类型名包含 `smb`（忽略大小写）判定，
  /// 与 [FileManagerProvider.isSmbType] 保持一致。
  static bool isSmbType(String type) => type.toLowerCase().contains('smb');

  /// 中立的远程客户端工厂：按连接模型构造正确的 [RemoteClient] 子类。
  ///
  /// ⚠️ 放在此处（而非 `FileManagerProvider`）是为了避免循环依赖：
  /// `file_manager_provider` 已依赖 `crypt_stream_server`，若 crypt 流式解密
  /// 服务再反向调用 `FileManagerProvider.createRemoteClient` 就会形成环。
  /// 本方法无 UI / 无 crypt 依赖，可被两侧安全复用，逻辑与
  /// [FileManagerProvider.createRemoteClient] 保持一致。
  static RemoteClient buildRemoteClient(NetworkConnectionModel conn) {
    if (conn.type == 'FTP') {
      return FtpRemoteClient(
        host: conn.host,
        port: conn.port,
        username: conn.username,
        password: conn.password,
      );
    }
    if (conn.type == 'SFTP') {
      return SftpRemoteClient(
        host: conn.host,
        port: conn.port,
        username: conn.username,
        password: conn.password,
        sshKeyPath: conn.sshKeyPath,
        sshKeyPassword: conn.sshKeyPassword,
        authMethod: conn.authMethod,
      );
    }
    if (conn.type == 'WebDav') {
      return WebDavRemoteClient(
        host: conn.host,
        port: conn.port,
        username: conn.username,
        password: conn.password,
        protocol: conn.protocol,
        rootPath: conn.rootPath,
      );
    }
    if (isSmbType(conn.type)) {
      return LanClient(
        host: conn.host,
        port: conn.port,
        username: conn.username,
        password: conn.password,
      );
    }
    if (conn.type == 'saf') {
      return SafRemoteClient(rootUri: conn.rootPath);
    }
    throw ArgumentError('Unsupported connection type: ${conn.type}');
  }
}
