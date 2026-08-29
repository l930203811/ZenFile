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
  });

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
      );
}
