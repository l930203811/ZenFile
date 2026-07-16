import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

class FtpServerService {
  static final FtpServerService instance = FtpServerService._internal();
  FtpServerService._internal();

  static const _channel = MethodChannel('com.sequl.zenfile/ftp_service');

  ServerSocket? _controlSocket;
  int _port = 9999;
  String _homeDir = '/storage/emulated/0';
  String _username = 'Anonymous';
  bool _anonymous = true;
  bool _showHidden = false;
  bool _isActive = false;
  String _ipAddress = '127.0.0.1';

  final List<Socket> _activeSockets = [];
  final List<ServerSocket> _activeDataSockets = [];

  VoidCallback? onStatusChanged;

  // Notification text (localized via l10n)
  String _notifTitle = 'ZenFile FTP Server';
  String _notifRunningText = 'Running at ftp://{ip}:{port}';

  /// Set localized notification text (called from screen with L10n context)
  void setNotificationText({
    required String title,
    required String runningText,
  }) {
    _notifTitle = title;
    _notifRunningText = runningText;
  }

  bool get isActive => _isActive;
  int get port => _port;
  String get homeDir => _homeDir;
  String get username => _username;
  bool get anonymous => _anonymous;
  bool get showHidden => _showHidden;
  String get ipAddress => _ipAddress;

  void configure({
    int? port,
    String? homeDir,
    String? username,
    bool? anonymous,
    bool? showHidden,
  }) {
    if (port != null) _port = port;
    if (homeDir != null) _homeDir = homeDir;
    if (username != null) _username = username;
    if (anonymous != null) _anonymous = anonymous;
    if (showHidden != null) _showHidden = showHidden;
    onStatusChanged?.call();
  }

  Future<void> start() async {
    if (_isActive) return;
    try {
      _ipAddress = await _getLocalIp();
      _controlSocket = await ServerSocket.bind(InternetAddress.anyIPv4, _port, shared: true);
      _isActive = true;
      _controlSocket!.listen(_handleConnection, onError: (e) {
        if (kDebugMode) print('FTP Control Server error: $e');
      });
      if (Platform.isAndroid) {
        try {
          await _channel.invokeMethod('startFtpService', {
            'ip': _ipAddress,
            'port': _port,
            'title': _notifTitle,
            'contentText': _notifRunningText
                .replaceAll('{ip}', _ipAddress)
                .replaceAll('{port}', _port.toString()),
          });
        } catch (e) {
          if (kDebugMode) print('Failed to start background notification service: $e');
        }
      }
      onStatusChanged?.call();
    } catch (e) {
      if (kDebugMode) print('Failed to start FTP server: $e');
      stop();
      rethrow;
    }
  }

  void stop() {
    _isActive = false;
    _controlSocket?.close();
    _controlSocket = null;
    for (var socket in _activeSockets) {
      try {
        socket.destroy();
      } catch (_) {}
    }
    _activeSockets.clear();
    for (var server in _activeDataSockets) {
      try {
        server.close();
      } catch (_) {}
    }
    _activeDataSockets.clear();
    if (Platform.isAndroid) {
      try {
        _channel.invokeMethod('stopFtpService');
      } catch (e) {
        if (kDebugMode) print('Failed to stop background notification service: $e');
      }
    }
    onStatusChanged?.call();
  }

  Future<String> _getLocalIp() async {
    try {
      for (var interface in await NetworkInterface.list()) {
        for (var addr in interface.addresses) {
          if (addr.type == InternetAddressType.IPv4 && !addr.isLoopback) {
            return addr.address;
          }
        }
      }
    } catch (_) {}
    return '127.0.0.1';
  }

  void _handleConnection(Socket client) {
    _activeSockets.add(client);
    final session = FtpSession(this, client);
    session.start();
  }
}

class FtpSession {
  final FtpServerService server;
  final Socket controlSocket;
  String currentDir = '/';
  
  ServerSocket? passiveServer;
  Socket? passiveDataSocket;
  
  String? activeHost;
  int? activePort;

  String? renameFromPath;

  FtpSession(this.server, this.controlSocket);

  void start() {
    sendResponse('220 ZenFile FTP Server ready.');

    controlSocket.listen(
      (bytes) {
        try {
          // Use allowMalformed: true to tolerate non-UTF-8 bytes from
          // misbehaving FTP clients (some embedded clients send Latin-1).
          final data = utf8.decode(bytes, allowMalformed: true);
          final lines = data.split('\r\n');
          for (var line in lines) {
            if (line.trim().isEmpty) continue;
            _processCommand(line);
          }
        } catch (e) {
          if (kDebugMode) print('FTP decode error: $e');
        }
      },
      onError: (e) {
        if (kDebugMode) print('FTP control socket error: $e');
        close();
      },
      onDone: () {
        close();
      },
    );
  }

  void sendResponse(String response) {
    try {
      controlSocket.write('$response\r\n');
    } catch (_) {}
  }

  void close() {
    try {
      controlSocket.destroy();
    } catch (_) {}
    server._activeSockets.remove(controlSocket);
    passiveServer?.close();
  }

  String _getAbsolutePath(String relPath) {
    String path = relPath;
    if (!path.startsWith('/')) {
      path = p.join(currentDir, path);
    }
    path = p.normalize(path);
    final fullPath = p.join(server.homeDir, path.startsWith('/') ? path.substring(1) : path);
    return p.normalize(fullPath);
  }

  void _processCommand(String rawLine) async {
    final parts = rawLine.trim().split(' ');
    final cmd = parts[0].toUpperCase();
    final arg = parts.length > 1 ? parts.sublist(1).join(' ') : '';

    if (kDebugMode) print('FTP CMD: $cmd $arg');

    switch (cmd) {
      case 'USER':
        if (server.anonymous) {
          sendResponse('230 Anonymous user logged in.');
        } else {
          sendResponse('331 User name okay, need password.');
        }
        break;
      case 'PASS':
        sendResponse('230 User logged in, proceed.');
        break;
      case 'SYST':
        sendResponse('215 UNIX Type: L8');
        break;
      case 'FEAT':
        sendResponse('211-Features:\r\n UTF8\r\n MLSD\r\n NLST\r\n SIZE\r\n REST\r\n EPSV\r\n EPRT\r\n TVFS\r\n211 End');
        break;
      case 'OPTS':
        final upper = arg.toUpperCase();
        if (upper == 'UTF8 ON' || upper == 'UTF8 OFF') {
          sendResponse('200 UTF8 set to ${upper.endsWith('ON') ? 'on' : 'off'}.');
        } else {
          sendResponse('501 Option not understood');
        }
        break;
      case 'STRU':
        if (arg.toUpperCase() == 'F') {
          sendResponse('200 Structure set to File.');
        } else {
          sendResponse('504 Command not implemented for that structure.');
        }
        break;
      case 'MODE':
        if (arg.toUpperCase() == 'S') {
          sendResponse('200 Mode set to Stream.');
        } else {
          sendResponse('504 Command not implemented for that mode.');
        }
        break;
      case 'ALLO':
        sendResponse('200 No storage allocation necessary.');
        break;
      case 'STAT':
        sendResponse('211 ZenFile FTP Server status: connected.');
        break;
      case 'PWD':
      case 'XPWD':
        sendResponse('257 "$currentDir" is current directory.');
        break;
      case 'TYPE':
        sendResponse('200 Type set to $arg');
        break;
      case 'PASV':
        await _enterPassiveMode();
        break;
      case 'EPSV':
        await _enterExtendedPassiveMode(arg);
        break;
      case 'PORT':
        _enterActiveMode(arg);
        break;
      case 'EPRT':
        _enterExtendedActiveMode(arg);
        break;
      case 'LIST':
        await _handleList(arg);
        break;
      case 'MLSD':
        await _handleList(arg, useMlsd: true);
        break;
      case 'NLST':
        await _handleList(arg, namesOnly: true);
        break;
      case 'CWD':
      case 'XCWD':
        _handleCwd(arg);
        break;
      case 'CDUP':
      case 'XCUP':
        _handleCwd('..');
        break;
      case 'SIZE':
        _handleSize(arg);
        break;
      case 'RETR':
        await _handleRetrieve(arg);
        break;
      case 'STOR':
        await _handleStore(arg);
        break;
      case 'APPE':
        await _handleStore(arg, append: true);
        break;
      case 'DELE':
        _handleDelete(arg);
        break;
      case 'MKD':
      case 'XMKD':
        _handleMakeDir(arg);
        break;
      case 'RMD':
      case 'XRMD':
        _handleRemoveDir(arg);
        break;
      case 'RNFR':
        renameFromPath = _getAbsolutePath(arg);
        sendResponse('350 File exists, ready for destination name.');
        break;
      case 'RNTO':
        _handleRenameTo(arg);
        break;
      case 'REST':
        sendResponse('350 Restarting at $arg. Send STORE or RETRIEVE to initiate transfer.');
        break;
      case 'ABOR':
        sendResponse('226 ABOR command successful.');
        break;
      case 'NOOP':
        sendResponse('200 OK');
        break;
      case 'QUIT':
        sendResponse('221 Goodbye.');
        close();
        break;
      case 'AUTH':
        sendResponse('502 AUTH not implemented.');
        break;
      default:
        if (kDebugMode) print('FTP: Unknown command: $cmd');
        sendResponse('502 Command not implemented.');
    }
  }

  Future<void> _enterPassiveMode() async {
    try {
      passiveServer?.close();
      // Bind explicitly to 0.0.0.0 so the data port is reachable from the
      // control channel's peer address regardless of which local interface
      // the FTP server is listening on. Some Android devices reject the
      // default anyIPv4 binding for subsequent sockets.
      passiveServer = await ServerSocket.bind(InternetAddress.anyIPv4, 0);
      server._activeDataSockets.add(passiveServer!);

      final port = passiveServer!.port;

      // RFC 959 PASV response must contain an IP reachable by the client.
      // Use the IP the control connection came from when possible, so the
      // client can route to the data port even when the server has multiple
      // interfaces (e.g. mobile hotspot vs. Wi-Fi).
      String pasvIp = _resolvePasvAddress(controlSocket);
      final ipParts = pasvIp.split('.');
      if (ipParts.length != 4) {
        sendResponse('500 Internal error');
        return;
      }
      final p1 = port >> 8;
      final p2 = port & 0xFF;
      sendResponse('227 Entering Passive Mode (${ipParts.join(",")},$p1,$p2)');

      passiveServer!.listen((socket) {
        passiveDataSocket = socket;
      }, onDone: () {
        passiveServer = null;
      }, onError: (e) {
        if (kDebugMode) print('FTP PASV server error: $e');
      });
    } catch (e) {
      if (kDebugMode) print('FTP PASV error: $e');
      sendResponse('451 Local error in processing.');
    }
  }

  /// Resolve the IP that the client should use to connect back to the
  /// PASV data port. Prefer the IP of the interface the control connection
  /// came in on; otherwise fall back to the server's primary IP.
  String _resolvePasvAddress(Socket control) {
    try {
      final remote = control.remoteAddress;
      if (remote == null || remote.type != InternetAddressType.IPv4) {
        return server.ipAddress;
      }
      final remoteIp = remote.address;

      // Find a local interface that shares the same /24 subnet as the client
      // so the client can route back to the data port.
      final remoteParts = remoteIp.split('.');
      if (remoteParts.length != 4) return server.ipAddress;
      final remotePrefix = '${remoteParts[0]}.${remoteParts[1]}.${remoteParts[2]}';

      // Use synchronous lookup to keep this method sync; the list is small.
      // ignore: deprecated_member_use
      // NetworkInterface.list is async; instead inspect localAddress.
      final local = controlSocketToLocalIp(control);
      if (local != null && local.isNotEmpty) {
        return local;
      }
      // No match found - return the server's chosen IP, but the client
      // may need to use EPSV if it supports it.
      return remotePrefix.isNotEmpty ? remoteIp : server.ipAddress;
    } catch (_) {
      return server.ipAddress;
    }
  }

  /// Best-effort sync lookup of the local IPv4 address bound to the same
  /// interface as the control socket, matching the remote peer's subnet.
  /// Falls back to [server.ipAddress] when a match is not found.
  String? controlSocketToLocalIp(Socket control) {
    try {
      final local = control.address;
      if (local != null && local.type == InternetAddressType.IPv4) {
        return local.address;
      }
    } catch (_) {}
    return null;
  }

  void _enterActiveMode(String arg) {
    final parts = arg.split(',');
    if (parts.length != 6) {
      sendResponse('501 Syntax error');
      return;
    }
    activeHost = parts.sublist(0, 4).join('.');
    activePort = (int.parse(parts[4]) << 8) + int.parse(parts[5]);
    sendResponse('200 PORT command successful.');
  }

  Future<void> _enterExtendedPassiveMode(String arg) async {
    try {
      passiveServer?.close();
      passiveServer = await ServerSocket.bind(InternetAddress.anyIPv4, 0);
      server._activeDataSockets.add(passiveServer!);

      final port = passiveServer!.port;
      sendResponse('229 Entering Extended Passive Mode (|||$port|)');

      passiveServer!.listen((socket) {
        passiveDataSocket = socket;
      }, onDone: () {
        passiveServer = null;
      });
    } catch (e) {
      if (kDebugMode) print('FTP EPSV error: $e');
      sendResponse('451 Local error in processing.');
    }
  }

  void _enterExtendedActiveMode(String arg) {
    try {
      final cleanArg = arg.replaceAll('|', '');
      final parts = cleanArg.split(',');
      if (parts.length < 3) {
        sendResponse('501 Syntax error in EPRT parameters');
        return;
      }
      final protocol = int.parse(parts[0]);
      if (protocol == 1) {
        activeHost = parts[1];
        activePort = int.parse(parts[2]);
      } else {
        sendResponse('522 Network protocol not supported');
        return;
      }
      sendResponse('200 EPRT command successful.');
    } catch (e) {
      if (kDebugMode) print('FTP EPRT error: $e');
      sendResponse('501 Syntax error in EPRT parameters');
    }
  }

  Future<Socket?> _getDataSocket() async {
    if (passiveServer != null) {
      int elapsed = 0;
      // Wait up to 30 seconds for the client to connect to the data port.
      // Some clients (especially mobile ones over Wi-Fi) are slow to
      // establish the data connection after parsing PASV/EPSV.
      while (passiveDataSocket == null && elapsed < 30000) {
        await Future.delayed(const Duration(milliseconds: 100));
        elapsed += 100;
      }
      final sock = passiveDataSocket;
      passiveDataSocket = null;
      passiveServer?.close();
      passiveServer = null;
      return sock;
    } else if (activeHost != null && activePort != null) {
      try {
        final sock = await Socket.connect(activeHost, activePort!,
            timeout: const Duration(seconds: 30));
        activeHost = null;
        activePort = null;
        return sock;
      } catch (_) {
        return null;
      }
    }
    return null;
  }

  Future<void> _handleList(String arg, {bool useMlsd = false, bool namesOnly = false}) async {
    final dataSocket = await _getDataSocket();
    if (dataSocket == null) {
      sendResponse('425 Can\'t open data connection.');
      return;
    }
    
    try {
      String listPath = arg.isEmpty ? currentDir : arg;
      final targetPath = _getAbsolutePath(listPath);
      final dir = Directory(targetPath);
      
      if (!(await dir.exists())) {
        sendResponse('550 Directory not found.');
        try {
          await dataSocket.close();
        } catch (_) {}
        return;
      }

      sendResponse('150 Opening data connection for file list.');

      final buffer = StringBuffer();

      // Emit a synthetic ".." entry for non-root directories. Most FTP
      // clients expect this entry so the user can navigate up.
      if (currentDir != '/' && !namesOnly) {
        if (useMlsd) {
          buffer.write('type=dir;modify=${_formatMlsdDate(DateTime.now())}; ..\r\n');
        } else {
          final now = DateTime.now();
          final dateStr = _formatDate(now);
          buffer.write('drwxr-xr-x 1 owner group 0 $dateStr ..\r\n');
        }
      }

      try {
        final entities = await dir.list().toList();
        entities.sort((a, b) {
          final aIsDir = a is Directory;
          final bIsDir = b is Directory;
          if (aIsDir && !bIsDir) return -1;
          if (!aIsDir && bIsDir) return 1;
          return p.basename(a.path).toLowerCase().compareTo(p.basename(b.path).toLowerCase());
        });

        for (var entity in entities) {
          final stat = await entity.stat();
          final name = p.basename(entity.path);
          if (!server.showHidden && name.startsWith('.')) continue;

          final size = stat.size;
          final isDir = stat.type == FileSystemEntityType.directory;
          final modified = stat.modified;

          if (namesOnly) {
            buffer.write('$name\r\n');
          } else if (useMlsd) {
            final typeStr = isDir ? 'dir' : 'file';
            final modifyStr = _formatMlsdDate(modified);
            buffer.write('type=$typeStr;size=$size;modify=$modifyStr; $name\r\n');
          } else {
            final typeChar = isDir ? 'd' : '-';
            final permissions = isDir ? 'rwxr-xr-x' : 'rw-r--r--';
            final dateStr = _formatDate(modified);
            buffer.write('$typeChar$permissions 1 owner group $size $dateStr $name\r\n');
          }
        }
      } catch (e) {
        if (kDebugMode) print('FTP LIST read error: $e');
      }
      
      dataSocket.write(buffer.toString());
      await dataSocket.flush();
      await dataSocket.close();
      sendResponse('226 Transfer complete.');
    } catch (e) {
      if (kDebugMode) print('FTP LIST error for $arg: $e');
      try {
        sendResponse('451 Local error in processing.');
      } catch (_) {}
    }
  }

  String _formatMlsdDate(DateTime dt) {
    final year = dt.year.toString();
    final month = dt.month.toString().padLeft(2, '0');
    final day = dt.day.toString().padLeft(2, '0');
    final hour = dt.hour.toString().padLeft(2, '0');
    final minute = dt.minute.toString().padLeft(2, '0');
    final second = dt.second.toString().padLeft(2, '0');
    return '$year$month$day$hour$minute$second';
  }

  String _formatDate(DateTime dt) {
    final months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    final month = months[dt.month - 1];
    final day = dt.day.toString().padLeft(2);
    final hour = dt.hour.toString().padLeft(2, '0');
    final minute = dt.minute.toString().padLeft(2, '0');
    return '$month $day $hour:$minute';
  }

  void _handleCwd(String arg) {
    String newDir;
    String target = arg;
    
    if (target == '..') {
      if (currentDir == '/') {
        sendResponse('250 Directory successfully changed.');
        return;
      }
      final parts = currentDir.split('/');
      parts.removeLast();
      newDir = parts.join('/');
      if (newDir.isEmpty) newDir = '/';
    } else if (target.startsWith('/')) {
      newDir = p.normalize(target);
    } else {
      newDir = p.normalize(p.join(currentDir, target));
    }
    
    if (!newDir.startsWith('/')) {
      newDir = '/$newDir';
    }

    final absPath = p.join(server.homeDir, newDir.startsWith('/') ? newDir.substring(1) : newDir);
    if (!Directory(absPath).existsSync()) {
      sendResponse('550 Directory not found.');
    } else {
      currentDir = newDir;
      sendResponse('250 Directory successfully changed.');
    }
  }

  void _handleSize(String arg) async {
    final absPath = _getAbsolutePath(arg);
    final file = File(absPath);
    if (await file.exists()) {
      final len = await file.length();
      sendResponse('213 $len');
    } else {
      sendResponse('550 File not found.');
    }
  }

  Future<void> _handleRetrieve(String arg) async {
    final absPath = _getAbsolutePath(arg);
    final file = File(absPath);
    if (!await file.exists()) {
      sendResponse('550 File not found.');
      return;
    }

    final dataSocket = await _getDataSocket();
    if (dataSocket == null) {
      sendResponse('425 Can\'t open data connection.');
      return;
    }

    sendResponse('150 Opening BINARY mode data connection.');
    try {
      await dataSocket.addStream(file.openRead());
    } catch (_) {} finally {
      await dataSocket.close();
      sendResponse('226 Transfer complete.');
    }
  }

  Future<void> _handleStore(String arg, {bool append = false}) async {
    final absPath = _getAbsolutePath(arg);
    final file = File(absPath);

    final dataSocket = await _getDataSocket();
    if (dataSocket == null) {
      sendResponse('425 Can\'t open data connection.');
      return;
    }

    sendResponse('150 Opening BINARY mode data connection.');
    try {
      final sink = file.openWrite(mode: append ? FileMode.append : FileMode.write);
      await sink.addStream(dataSocket);
      await sink.close();
    } catch (e) {
      if (kDebugMode) print('FTP STOR error: $e');
    } finally {
      try {
        await dataSocket.close();
      } catch (_) {}
      sendResponse('226 Transfer complete.');
    }
  }

  void _handleDelete(String arg) async {
    final absPath = _getAbsolutePath(arg);
    final file = File(absPath);
    if (await file.exists()) {
      await file.delete();
      sendResponse('250 File deleted successfully.');
    } else {
      sendResponse('550 File not found.');
    }
  }

  void _handleMakeDir(String arg) async {
    final absPath = _getAbsolutePath(arg);
    final dir = Directory(absPath);
    try {
      await dir.create(recursive: true);
      sendResponse('257 "$arg" directory created.');
    } catch (_) {
      sendResponse('550 Can\'t create directory.');
    }
  }

  void _handleRemoveDir(String arg) async {
    final absPath = _getAbsolutePath(arg);
    final dir = Directory(absPath);
    try {
      await dir.delete(recursive: true);
      sendResponse('250 Directory deleted successfully.');
    } catch (_) {
      sendResponse('550 Can\'t delete directory.');
    }
  }

  void _handleRenameTo(String arg) async {
    if (renameFromPath == null) {
      sendResponse('503 Bad sequence of commands.');
      return;
    }
    final toPath = _getAbsolutePath(arg);
    try {
      final type = await FileSystemEntity.type(renameFromPath!);
      if (type == FileSystemEntityType.file) {
        await File(renameFromPath!).rename(toPath);
      } else if (type == FileSystemEntityType.directory) {
        await Directory(renameFromPath!).rename(toPath);
      } else {
        throw Exception();
      }
      sendResponse('250 File renamed successfully.');
    } catch (_) {
      sendResponse('550 File rename failed.');
    } finally {
      renameFromPath = null;
    }
  }
}
