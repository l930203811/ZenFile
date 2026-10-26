class NetworkConnectionModel {
  final String id;
  final String name;
  final String type;
  final String host;
  final int port;
  final String username;
  final String password;
  final String rootPath;
  final String protocol;
  // SSH 密钥认证相关字段（仅 SFTP 使用）
  final String? sshKeyPath;
  final String? sshKeyPassword;
  final String authMethod; // 'password' or 'key'

  // ── 逐连接代理（SOCKS5）──
  // 用途：让 FTP / WebDAV / SMB / SFTP 连接经 SOCKS5 代理出网，
  // 以访问「虚拟内网」里的网盘 / 文件服务器。
  // proxyType == null / 'none' 表示不启用代理；'socks5' 表示走 SOCKS5。
  // proxyHost / proxyPort / proxyUsername 为明文配置（与 host/port 同级，
  // 不属高敏）；proxyPassword 属高敏，落 FlutterSecureStorage（见
  // network_connections_service 的 _secrets）。
  final String? proxyType;
  final String? proxyHost;
  final int? proxyPort;
  final String? proxyUsername;
  final String? proxyPassword;

  NetworkConnectionModel({
    required this.id,
    required this.name,
    required this.type,
    required this.host,
    required this.port,
    required this.username,
    required this.password,
    this.rootPath = '/',
    this.protocol = 'http',
    this.sshKeyPath,
    this.sshKeyPassword,
    this.authMethod = 'password',
    this.proxyType,
    this.proxyHost,
    this.proxyPort,
    this.proxyUsername,
    this.proxyPassword,
  });

  /// 是否配置了可用的 SOCKS5 代理（类型正确且主机/端口齐全）。
  bool get hasProxy =>
      proxyType != null &&
      proxyType != 'none' &&
      proxyHost != null &&
      proxyHost!.isNotEmpty &&
      proxyPort != null &&
      proxyPort! > 0;

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'type': type,
        'host': host,
        'port': port,
        'username': username,
        'password': password,
        'rootPath': rootPath,
        'protocol': protocol,
        'sshKeyPath': sshKeyPath,
        'sshKeyPassword': sshKeyPassword,
        'authMethod': authMethod,
        'proxyType': proxyType,
        'proxyHost': proxyHost,
        'proxyPort': proxyPort,
        'proxyUsername': proxyUsername,
        'proxyPassword': proxyPassword,
      };

  factory NetworkConnectionModel.fromJson(Map<String, dynamic> json) =>
      NetworkConnectionModel(
        id: json['id'] as String,
        name: json['name'] as String,
        type: json['type'] as String,
        host: json['host'] as String,
        port: json['port'] as int,
        username: json['username'] as String,
        password: json['password'] as String,
        rootPath: (json['rootPath'] as String?) ?? '/',
        protocol: (json['protocol'] as String?) ?? 'http',
        sshKeyPath: json['sshKeyPath'] as String?,
        sshKeyPassword: json['sshKeyPassword'] as String?,
        authMethod: (json['authMethod'] as String?) ?? 'password',
        proxyType: (json['proxyType'] as String?) ?? 'none',
        proxyHost: json['proxyHost'] as String?,
        proxyPort: json['proxyPort'] as int?,
        proxyUsername: json['proxyUsername'] as String?,
        proxyPassword: json['proxyPassword'] as String?,
      );
}
