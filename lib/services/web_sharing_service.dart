import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:dartssh2/dartssh2.dart';

class WebSharingService extends ChangeNotifier {
  static final WebSharingService instance = WebSharingService._();
  WebSharingService._();

  static const _channel = MethodChannel('com.sequl.zenfile/web_sharing_service');

  static const String _ed25519PrivateKeyPem = '''
-----BEGIN OPENSSH PRIVATE KEY-----
b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtzc2gtZW
QyNTUxOQAAACAWN3mZdOKrXnP+VFVDS6yuPfVgGbCOa0a/B0YHt7wfpAAAAJj80blj/NG5
YwAAAAtzc2gtZWQyNTUxOQAAACAWN3mZdOKrXnP+VFVDS6yuPfVgGbCOa0a/B0YHt7wfpA
AAAEBbg6hQHydFb0ZGHuYq+gCui5fFtXW1X2e3Ok3UKTfXMhY3eZl04qtec/5UVUNLrK49
9WAZsI5rRr8HRge3vB+kAAAAFWFkbWluQERFU0tUT1AtS1NIUkFVNw==
-----END OPENSSH PRIVATE KEY-----
''';

  SSHClient? _sshClient;
  SSHRemoteForward? _sshForward;

  HttpServer? _localServer;
  bool _isLocalActive = false;
  String _localIpAddress = '';
  final int _port = 8080;

  bool _isInternetActive = false;
  String _internetShareLink = '';

  // Getters
  bool get isLocalActive => _isLocalActive;
  bool get isInternetActive => _isInternetActive;
  String get localIpAddress => _localIpAddress;
  int get port => _port;
  String get internetShareLink => _internetShareLink;
  String get localServerUrl => 'http://$_localIpAddress:$_port';

  // Dynamic active clients state
  final Map<String, ActiveClient> _clientsMap = {};
  Timer? _speedTimer;

  /// Current locale for web sharing HTML pages (e.g., 'en', 'zh', 'zh_TW', 'ja', etc.)
  String _webLocale = 'en';

  /// Set the locale for web sharing HTML pages with normalization
  /// Maps Flutter locale codes to web translation keys
  void setWebLocale(String locale) {
    // Normalize locale codes to match web translation dictionary keys
    final normalized = _normalizeLocale(locale);
    _webLocale = normalized;
  }

  String get webLocale => _webLocale;

  /// Normalize Flutter locale code to web translation key
  static String _normalizeLocale(String locale) {
    final lower = locale.toLowerCase();
    // Map various locale formats to translation keys
    if (lower == 'zh' || lower == 'zh_cn' || lower == 'zh_hans') return 'zh';
    if (lower == 'zh_tw' || lower == 'zh_hant') return 'zh_TW';
    if (lower == 'ja' || lower == 'jp') return 'ja';
    if (lower == 'ko' || lower == 'kr') return 'ko';
    if (lower == 'de') return 'de';
    if (lower == 'fr') return 'fr';
    if (lower == 'es') return 'es';
    if (lower == 'ru') return 'ru';
    if (lower == 'ar') return 'ar';
    if (lower == 'en' || lower == 'en_us' || lower == 'en_gb') return 'en';
    return 'en'; // fallback
  }

  List<Map<String, dynamic>> get activeClients {
    return _clientsMap.values.map((client) {
      final double progress = client.totalBytes > 0
          ? (client.bytesTransferred / client.totalBytes).clamp(0.0, 1.0)
          : 0.0;

      String transferredStr = '';
      if (client.bytesTransferred > 1024 * 1024 * 1024) {
        transferredStr = '${(client.bytesTransferred / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
      } else if (client.bytesTransferred > 1024 * 1024) {
        transferredStr = '${(client.bytesTransferred / (1024 * 1024)).toStringAsFixed(1)} MB';
      } else {
        transferredStr = '${(client.bytesTransferred / 1024).toStringAsFixed(0)} KB';
      }

      return {
        'device': client.device,
        'speed': double.parse(client.speed.toStringAsFixed(1)),
        'transferred': transferredStr,
        'file': client.currentFile,
        'progress': progress,
      };
    }).toList();
  }

  // Real HTTP Local Server lifecycle
  Future<void> startLocalServer(String rootDir) async {
    if (_isLocalActive) return;

    // 如果 rootDir 为空，使用默认的内部存储根目录
    if (rootDir.isEmpty) {
      rootDir = '/storage/emulated/0';
    }

    try {
      // 1. Resolve local Wi-Fi IP address
      _localIpAddress = await _detectLocalIp();

      // 2. Bind HttpServer
      _localServer = await HttpServer.bind(InternetAddress.anyIPv4, _port);
      _isLocalActive = true;
      notifyListeners();

      // 3. Start Native Background Foreground Service
      try {
        await _channel.invokeMethod('startWebSharingService', {
          'url': 'http://$_localIpAddress:$_port',
          'isInternet': false,
        });
      } catch (e) {
        debugPrint('Failed to start native web sharing service: $e');
      }

      // 4. Listen to incoming requests
      _localServer!.listen((HttpRequest request) async {
        try {
          await _handleHttpRequest(request, rootDir);
        } catch (e) {
          debugPrint('Error handling web share HTTP request: $e');
          try {
            request.response.statusCode = HttpStatus.internalServerError;
            request.response.write('500 Internal Server Error: $e');
            await request.response.close();
          } catch (_) {}
        }
      });
    } catch (e) {
      _isLocalActive = false;
      _localServer = null;
      notifyListeners();
      rethrow;
    }
  }

  Future<void> stopLocalServer() async {
    if (!_isLocalActive) return;
    await _localServer?.close(force: true);
    _localServer = null;
    _isLocalActive = false;
    _clientsMap.clear();
    _speedTimer?.cancel();
    _speedTimer = null;

    // Stop Native Android Service if the internet tunnel is also stopped
    if (!_isInternetActive) {
      try {
        await _channel.invokeMethod('stopWebSharingService');
      } catch (e) {
        debugPrint('Failed to stop native web sharing service: $e');
      }
    }

    notifyListeners();
  }

  // --- Real HTTP File System Router ---
  Future<void> _handleHttpRequest(HttpRequest request, String rootDir) async {
    final response = request.response;
    final uriPath = Uri.decodeComponent(request.uri.path);

    // Security check: prevent directory traversal attacks
    if (uriPath.contains('..')) {
      response.statusCode = HttpStatus.forbidden;
      response.write('403 Forbidden: Directory traversal is prohibited.');
      await response.close();
      return;
    }

    // Map URL path to target local filesystem path
    final targetPath = p.join(rootDir, uriPath.startsWith('/') ? uriPath.substring(1) : uriPath);
    final entityType = FileSystemEntity.typeSync(targetPath);

    // Handle high-speed file uploads via binary stream piping
    if (request.method == 'POST') {
      final fileNameHeader = request.headers.value('x-file-name');
      if (fileNameHeader != null) {
        try {
          final decodedFileName = Uri.decodeComponent(fileNameHeader);
          final uploadDestination = FileSystemEntity.isDirectorySync(targetPath) 
              ? p.join(targetPath, decodedFileName) 
              : p.join(p.dirname(targetPath), decodedFileName);

          // Verify destination path safety to prevent directory traversal
          if (!p.normalize(uploadDestination).startsWith(p.normalize(rootDir))) {
            response.statusCode = HttpStatus.forbidden;
            response.write('403 Forbidden: Invalid file upload destination.');
            await response.close();
            return;
          }

          final file = File(uploadDestination);
          final sink = file.openWrite();
          await request.cast<List<int>>().pipe(sink);

          response.statusCode = HttpStatus.ok;
          response.write('Upload successful');
          await response.close();
          return;
        } catch (e) {
          response.statusCode = HttpStatus.internalServerError;
          response.write('500 Upload failed: $e');
          await response.close();
          return;
        }
      }
    }

    if (entityType == FileSystemEntityType.directory) {
      _trackClientActivity(request, targetPath, 0);
      // 1. Serve beautifully designed dark HTML Directory Explorer
      final dir = Directory(targetPath);
      List<FileSystemEntity> items = [];
      try {
        items = dir.listSync();
      } catch (e) {
        debugPrint('WebSharing: listSync failed for $targetPath: $e');
      }
      debugPrint('WebSharing: listed ${items.length} items in $targetPath');
      for (final item in items.take(5)) {
        debugPrint('WebSharing: item = ${item.path} (type: ${item is Directory ? "dir" : "file"})');
      }
      items.sort((a, b) {
        final aIsDir = a is Directory;
        final bIsDir = b is Directory;
        if (aIsDir && !bIsDir) return -1;
        if (!aIsDir && bIsDir) return 1;
        return p.basename(a.path).toLowerCase().compareTo(p.basename(b.path).toLowerCase());
      });

      // Detect if accessed via localhost.run tunnel or local network
      final host = request.headers.value(HttpHeaders.hostHeader) ?? '';
      final isInternet = host.contains('lhr.life') || host.contains('localhost.run');

      final html = _generateExplorerHtml(uriPath, items, rootDir, isInternet);
      response.headers.contentType = ContentType.html;
      response.write(html);
      await response.close();
    } else if (entityType == FileSystemEntityType.file) {
      // 2. Stream real file with dynamic high-speed buffering
      final file = File(targetPath);
      final ext = p.extension(targetPath).toLowerCase();

      // Resolve proper MIME Type for browsers to stream video/audio inline
      String contentType = 'application/octet-stream';
      if (['.mp4', '.m4v'].contains(ext)) {
        contentType = 'video/mp4';
      } else if (['.mp3', '.m4a', '.wav'].contains(ext)) {
        contentType = 'audio/mpeg';
      } else if (['.jpg', '.jpeg'].contains(ext)) {
        contentType = 'image/jpeg';
      } else if (['.png', '.gif', '.webp'].contains(ext)) {
        contentType = 'image/png';
      } else if (['.pdf'].contains(ext)) {
        contentType = 'application/pdf';
      } else if (['.txt'].contains(ext)) {
        contentType = 'text/plain; charset=utf-8';
      }

      final fileSize = file.lengthSync();
      final client = _trackClientActivity(request, targetPath, fileSize);
      response.headers.add(HttpHeaders.acceptRangesHeader, 'bytes');
      response.headers.contentType = ContentType.parse(contentType);

      // Force attachment headers with UTF-8 encoding support for all files to ensure downloading works flawlessly in every browser
      final encodedFilename = Uri.encodeComponent(p.basename(targetPath));
      response.headers.add(
        'Content-Disposition',
        'attachment; filename="$encodedFilename"; filename*=UTF-8\'\'$encodedFilename',
      );

      // Handle HTTP Range Requests for resumable downloading and seeking
      final rangeHeader = request.headers.value(HttpHeaders.rangeHeader);
      int start = 0;
      int end = fileSize - 1;
      bool isRange = false;

      if (rangeHeader != null && rangeHeader.startsWith('bytes=')) {
        final parts = rangeHeader.substring(6).split('-');
        if (parts.isNotEmpty) {
          final startPart = parts[0].trim();
          if (startPart.isNotEmpty) {
            start = int.parse(startPart);
          }
          if (parts.length > 1) {
            final endPart = parts[1].trim();
            if (endPart.isNotEmpty) {
              end = int.parse(endPart);
            }
          }
        }

        if (start >= fileSize || end >= fileSize || start > end) {
          response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
          response.headers.add(HttpHeaders.contentRangeHeader, 'bytes */$fileSize');
          await response.close();
          return;
        }

        response.statusCode = HttpStatus.partialContent;
        response.headers.add(HttpHeaders.contentRangeHeader, 'bytes $start-$end/$fileSize');
        response.headers.contentLength = end - start + 1;
        isRange = true;
      } else {
        response.headers.contentLength = fileSize;
      }

      // Stream the file in 64KB blocks for extreme high-speed data transmission
      try {
        final stream = file.openRead(start, isRange ? end + 1 : null);
        await for (final chunk in stream) {
          response.add(chunk);
          if (client != null) {
            client.bytesTransferred += chunk.length;
            client.lastActivityTime = DateTime.now();
          }
        }
      } catch (e) {
        debugPrint('Error streaming file chunk to client: $e');
      } finally {
        await response.close();
      }
    } else {
      response.statusCode = HttpStatus.notFound;
      response.write('404 Not Found: The specified resource does not exist.');
      await response.close();
    }
  }

  // --- Beautiful served Dark HTML Page Builder ---
  String _generateExplorerHtml(String currentPath, List<FileSystemEntity> items, String rootDir, bool isInternet) {
    // 优先使用 App 设置的语言（通过 setWebLocale 设置），确保跟随 App 语言切换
    // _webLocale 默认为 'en'，在 startLocalServer 时会被设为 App 当前语言
    final lang = _webLocale;

    // Dart-side translation map for HTML generation
    const _translations = <String, Map<String, String>>{
      'en': {
        'root': 'Root', 'parentDir': '.. (Parent Directory)', 'goUp': 'Go up one level',
        'folders': 'Folders', 'videos': 'Videos', 'audio': 'Audio', 'images': 'Images',
        'documents': 'Documents', 'others': 'Others', 'items': 'items',
        'noItems': 'No items in this category', 'search': 'Search files & folders...',
        'upload': 'Upload', 'emptySearch': 'No items match your search',
        'emptyDesc': 'Check the spelling or try a different search term.',
        'fileName': 'File Name', 'fileMeta': 'Size \u2022 Modified Date',
        'dropTitle': 'Drop files here to upload',
        'dropDesc': 'Your files will be uploaded instantly to this shared folder',
        'footer': 'Securely sharing and streaming files via ZenFile',
        'download': 'Download', 'copyLink': 'Copy Link',
      },
      'zh': {
        'root': '\u6839\u76ee\u5f55', 'parentDir': '.. (\u4e0a\u7ea7\u76ee\u5f55)', 'goUp': '\u8fd4\u56de\u4e0a\u4e00\u7ea7',
        'folders': '\u6587\u4ef6\u5939', 'videos': '\u89c6\u9891', 'audio': '\u97f3\u9891', 'images': '\u56fe\u7247',
        'documents': '\u6587\u6863', 'others': '\u5176\u4ed6', 'items': '\u4e2a\u9879\u76ee',
        'noItems': '\u6b64\u5206\u7c7b\u4e2d\u6ca1\u6709\u9879\u76ee', 'search': '\u641c\u7d22\u6587\u4ef6\u548c\u6587\u4ef6\u5939...',
        'upload': '\u4e0a\u4f20', 'emptySearch': '\u6ca1\u6709\u5339\u914d\u7684\u9879\u76ee',
        'emptyDesc': '\u68c0\u67e5\u62fc\u5199\u6216\u5c1d\u8bd5\u4e0d\u540c\u7684\u641c\u7d22\u8bcd\u3002',
        'fileName': '\u6587\u4ef6\u540d', 'fileMeta': '\u5927\u5c0f \u2022 \u4fee\u6539\u65e5\u671f',
        'dropTitle': '\u62d6\u62fd\u6587\u4ef6\u5230\u6b64\u5904\u4e0a\u4f20',
        'dropDesc': '\u6587\u4ef6\u5c06\u7acb\u5373\u4e0a\u4f20\u5230\u6b64\u5171\u4eab\u6587\u4ef6\u5939',
        'footer': '\u901a\u8fc7 ZenFile \u5b89\u5168\u5171\u4eab\u548c\u6d41\u5f0f\u4f20\u8f93\u6587\u4ef6',
        'download': '\u4e0b\u8f7d', 'copyLink': '\u590d\u5236\u94fe\u63a5',
      },
      'zh_TW': {
        'root': '\u6839\u76ee\u9304', 'parentDir': '.. (\u4e0a\u7d1a\u76ee\u9304)', 'goUp': '\u8fd4\u56de\u4e0a\u4e00\u7d1a',
        'folders': '\u8cc7\u6599\u593e', 'videos': '\u5f71\u7247', 'audio': '\u97f3\u8a0a', 'images': '\u5716\u7247',
        'documents': '\u6587\u4ef6', 'others': '\u5176\u4ed6', 'items': '\u500b\u9805\u76ee',
        'noItems': '\u6b64\u5206\u985e\u4e2d\u6c92\u6709\u9805\u76ee', 'search': '\u641c\u5c0b\u6a94\u6848\u548c\u8cc7\u6599\u593e...',
        'upload': '\u4e0a\u50b3', 'emptySearch': '\u6c92\u6709\u5339\u914d\u7684\u9805\u76ee',
        'emptyDesc': '\u6aa2\u67e5\u62fc\u5beb\u6216\u5617\u8a66\u4e0d\u540c\u7684\u641c\u5c0b\u8a5e\u3002',
        'fileName': '\u6a94\u6848\u540d', 'fileMeta': '\u5927\u5c0f \u2022 \u4fee\u6539\u65e5\u671f',
        'dropTitle': '\u62d6\u66f3\u6a94\u6848\u5230\u6b64\u8655\u4e0a\u50b3',
        'dropDesc': '\u6a94\u6848\u5c07\u7acb\u5373\u4e0a\u50b3\u5230\u6b64\u5171\u4eab\u8cc0\u6599\u593e',
        'footer': '\u900f\u904e ZenFile \u5b89\u5168\u5171\u4eab\u548c\u4e32\u6d41\u50b3\u8f38\u6a94\u6848',
        'download': '\u4e0b\u8f09', 'copyLink': '\u8907\u88fd\u9023\u7d50',
      },
      'ja': {
        'root': '\u30eb\u30fc\u30c8', 'parentDir': '.. (\u89aa\u30c7\u30a3\u30ec\u30af\u30c8\u30ea)', 'goUp': '1\u3064\u4e0a\u306e\u968e\u5c64\u306b\u623b\u308b',
        'folders': '\u30d5\u30a9\u30eb\u30c0', 'videos': '\u52d5\u753b', 'audio': '\u97f3\u697d', 'images': '\u753b\u50cf',
        'documents': '\u30c9\u30ad\u30e5\u30e1\u30f3\u30c8', 'others': '\u305d\u306e\u4ed6', 'items': '\u9805\u76ee',
        'noItems': '\u3053\u306e\u30ab\u30c6\u30b4\u30ea\u306b\u9805\u76ee\u306f\u3042\u308a\u307e\u305b\u3093', 'search': '\u30d5\u30a1\u30a4\u30eb\u3068\u30d5\u30a9\u30eb\u30c0\u3092\u691c\u7d22...',
        'upload': '\u30a2\u30c3\u30d7\u30ed\u30fc\u30c9', 'emptySearch': '\u4e00\u81f4\u3059\u308b\u9805\u76ee\u304c\u3042\u308a\u307e\u305b\u3093',
        'emptyDesc': '\u30b9\u30da\u30eb\u3092\u78ba\u8a8d\u3059\u308b\u304b\u3001\u5225\u306e\u691c\u7d22\u8a9e\u3092\u8a66\u3057\u3066\u304f\u3060\u3055\u3044\u3002',
        'fileName': '\u30d5\u30a1\u30a4\u30eb\u540d', 'fileMeta': '\u30b5\u30a4\u30ba \u2022 \u66f4\u65b0\u65e5\u6642',
        'dropTitle': '\u30d5\u30a1\u30a4\u30eb\u3092\u3053\u3053\u306b\u30c9\u30e9\u30c3\u30b0\u3057\u3066\u30a2\u30c3\u30d7\u30ed\u30fc\u30c9',
        'dropDesc': '\u30d5\u30a1\u30a4\u30eb\u306f\u3053\u306e\u5171\u6709\u30d5\u30a9\u30eb\u30c0\u306b\u5373\u5ea7\u306b\u30a2\u30c3\u30d7\u30ed\u30fc\u30c9\u3055\u308c\u307e\u3059',
        'footer': 'ZenFile \u3092\u4ecb\u3057\u3066\u30d5\u30a1\u30a4\u30eb\u3092\u5b89\u5168\u306b\u5171\u6709\u304a\u3088\u3073\u30b9\u30c8\u30ea\u30fc\u30df\u30f3\u30b0',
        'download': '\u30c0\u30a6\u30f3\u30ed\u30fc\u30c9', 'copyLink': '\u30ea\u30f3\u30af\u3092\u30b3\u30d4\u30fc',
      },
      'ko': {
        'root': '\ub8e8\ud2b8', 'parentDir': '.. (\uc0c1\uc704 \ub514\ub809\ud1a0\ub9ac)', 'goUp': '\ud55c \ub2e8\uacc4 \uc704\ub85c \uc774\ub3d9',
        'folders': '\ud3f4\ub354', 'videos': '\ub3d9\uc601\uc0c1', 'audio': '\uc624\ub514\uc624', 'images': '\uc774\ubbf8\uc9c0',
        'documents': '\ubb38\uc11c', 'others': '\uae30\ud0c0', 'items': '\uac1c \ud56d\ubaa9',
        'noItems': '\uc774 \ubd84\ub958\uc5d0 \ud56d\ubaa9\uc774 \uc5c6\uc2b5\ub2c8\ub2e4', 'search': '\ud30c\uc77c \ubc0f \ud3f4\ub354 \uac80\uc0c9...',
        'upload': '\uc5c5\ub85c\ub4dc', 'emptySearch': '\uc77c\uce58\ud558\ub294 \ud56d\ubaa9\uc774 \uc5c6\uc2b5\ub2c8\ub2e4',
        'emptyDesc': '\ucca0\uc790\ub97c \ud655\uc778\ud558\uac70\ub098 \ub2e4\ub978 \uac80\uc0c9\uc5b4\ub97c \uc2dc\ub3c4\ud558\uc138\uc694.',
        'fileName': '\ud30c\uc77c \uc774\ub984', 'fileMeta': '\ud06c\uae30 \u2022 \uc218\uc815 \ub0a0\uc9dc',
        'dropTitle': '\ud30c\uc77c\uc744 \uc5ec\uae30\uc5d0 \ub4dc\ub86d\ud558\uc5ec \uc5c5\ub85c\ub4dc',
        'dropDesc': '\ud30c\uc77c\uc774 \uc774 \uacf5\uc720 \ud3f4\ub354\uc5d0 \uc989\uc2dc \uc5c5\ub85c\ub4dc\ub429\ub2c8\ub2e4',
        'footer': 'ZenFile\uc744 \ud1b5\ud574 \ud30c\uc77c\uc744 \uc548\uc804\ud558\uac8c \uacf5\uc720 \ubc0f \uc2a4\ud2b8\ub9ac\ubc0d',
        'download': '\ub2e4\uc6b4\ub85c\ub4dc', 'copyLink': '\ub9c1\ud06c \ubcf5\uc0ac',
      },
      'de': {
        'root': 'Stammverzeichnis', 'parentDir': '.. (\u00dcbergeordnetes Verzeichnis)', 'goUp': 'Eine Ebene nach oben',
        'folders': 'Ordner', 'videos': 'Videos', 'audio': 'Audio', 'images': 'Bilder',
        'documents': 'Dokumente', 'others': 'Sonstiges', 'items': 'Elemente',
        'noItems': 'Keine Elemente in dieser Kategorie', 'search': 'Dateien & Ordner suchen...',
        'upload': 'Hochladen', 'emptySearch': 'Keine Elemente entsprechen Ihrer Suche',
        'emptyDesc': '\u00dcberpr\u00fcfen Sie die Schreibweise oder versuchen Sie einen anderen Suchbegriff.',
        'fileName': 'Dateiname', 'fileMeta': 'Gr\u00f6\u00dfe \u2022 \u00c4nderungsdatum',
        'dropTitle': 'Dateien hier ablegen zum Hochladen',
        'dropDesc': 'Ihre Dateien werden sofort in diesen freigegebenen Ordner hochgeladen',
        'footer': 'Sicheres Teilen und Streamen von Dateien \u00fcber ZenFile',
        'download': 'Herunterladen', 'copyLink': 'Link kopieren',
      },
      'fr': {
        'root': 'Racine', 'parentDir': '.. (R\u00e9pertoire parent)', 'goUp': 'Remonter d\'un niveau',
        'folders': 'Dossiers', 'videos': 'Vid\u00e9os', 'audio': 'Audio', 'images': 'Images',
        'documents': 'Documents', 'others': 'Autres', 'items': '\u00e9l\u00e9ments',
        'noItems': 'Aucun \u00e9l\u00e9ment dans cette cat\u00e9gorie', 'search': 'Rechercher des fichiers et dossiers...',
        'upload': 'T\u00e9l\u00e9charger', 'emptySearch': 'Aucun \u00e9l\u00e9ment ne correspond \u00e0 votre recherche',
        'emptyDesc': 'V\u00e9rifiez l\'orthographe ou essayez un terme de recherche diff\u00e9rent.',
        'fileName': 'Nom du fichier', 'fileMeta': 'Taille \u2022 Date de modification',
        'dropTitle': 'D\u00e9posez les fichiers ici pour les t\u00e9l\u00e9charger',
        'dropDesc': 'Vos fichiers seront instantan\u00e9ment t\u00e9l\u00e9charg\u00e9s dans ce dossier partag\u00e9',
        'footer': 'Partage et diffusion s\u00e9curis\u00e9s de fichiers via ZenFile',
        'download': 'T\u00e9l\u00e9charger', 'copyLink': 'Copier le lien',
      },
      'es': {
        'root': 'Ra\u00edz', 'parentDir': '.. (Directorio principal)', 'goUp': 'Subir un nivel',
        'folders': 'Carpetas', 'videos': 'V\u00eddeos', 'audio': 'Audio', 'images': 'Im\u00e1genes',
        'documents': 'Documentos', 'others': 'Otros', 'items': 'elementos',
        'noItems': 'No hay elementos en esta categor\u00eda', 'search': 'Buscar archivos y carpetas...',
        'upload': 'Subir', 'emptySearch': 'Ning\u00fan elemento coincide con su b\u00fasqueda',
        'emptyDesc': 'Verifique la ortograf\u00eda o intente un t\u00e9rmino de b\u00fasqueda diferente.',
        'fileName': 'Nombre del archivo', 'fileMeta': 'Tama\u00f1o \u2022 Fecha de modificaci\u00f3n',
        'dropTitle': 'Suelte los archivos aqu\u00ed para subirlos',
        'dropDesc': 'Sus archivos se subir\u00e1n instant\u00e1neamente a esta carpeta compartida',
        'footer': 'Compartir y transmitir archivos de forma segura a trav\u00e9s de ZenFile',
        'download': 'Descargar', 'copyLink': 'Copiar enlace',
      },
      'ru': {
        'root': '\u041a\u043e\u0440\u043d\u0435\u0432\u043e\u0439 \u043a\u0430\u0442\u0430\u043b\u043e\u0433', 'parentDir': '.. (\u0420\u043e\u0434\u0438\u0442\u0435\u043b\u044c\u0441\u043a\u0438\u0439 \u043a\u0430\u0442\u0430\u043b\u043e\u0433)', 'goUp': '\u041f\u0435\u0440\u0435\u0439\u0442\u0438 \u043d\u0430 \u0443\u0440\u043e\u0432\u0435\u043d\u044c \u0432\u044b\u0448\u0435',
        'folders': '\u041f\u0430\u043f\u043a\u0438', 'videos': '\u0412\u0438\u0434\u0435\u043e', 'audio': '\u0410\u0443\u0434\u0438\u043e', 'images': '\u0418\u0437\u043e\u0431\u0440\u0430\u0436\u0435\u043d\u0438\u044f',
        'documents': '\u0414\u043e\u043a\u0443\u043c\u0435\u043d\u0442\u044b', 'others': '\u041f\u0440\u043e\u0447\u0435\u0435', 'items': '\u044d\u043b\u0435\u043c\u0435\u043d\u0442\u043e\u0432',
        'noItems': '\u041d\u0435\u0442 \u044d\u043b\u0435\u043c\u0435\u043d\u0442\u043e\u0432 \u0432 \u044d\u0442\u043e\u0439 \u043a\u0430\u0442\u0435\u0433\u043e\u0440\u0438\u0438', 'search': '\u041f\u043e\u0438\u0441\u043a \u0444\u0430\u0439\u043b\u043e\u0432 \u0438 \u043f\u0430\u043f\u043e\u043a...',
        'upload': '\u0417\u0430\u0433\u0440\u0443\u0437\u0438\u0442\u044c', 'emptySearch': '\u041d\u0435\u0442 \u044d\u043b\u0435\u043c\u0435\u043d\u0442\u043e\u0432, \u0441\u043e\u043e\u0442\u0432\u0435\u0442\u0441\u0442\u0432\u0443\u044e\u0449\u0438\u0445 \u0432\u0430\u0448\u0435\u043c\u0443 \u0437\u0430\u043f\u0440\u043e\u0441\u0443',
        'emptyDesc': '\u041f\u0440\u043e\u0432\u0435\u0440\u044c\u0442\u0435 \u043f\u0440\u0430\u0432\u043e\u043f\u0438\u0441\u0430\u043d\u0438\u0435 \u0438\u043b\u0438 \u043f\u043e\u043f\u0440\u043e\u0431\u0443\u0439\u0442\u0435 \u0434\u0440\u0443\u0433\u043e\u0439 \u043f\u043e\u0438\u0441\u043a\u043e\u0432\u044b\u0439 \u0437\u0430\u043f\u0440\u043e\u0441.',
        'fileName': '\u0418\u043c\u044f \u0444\u0430\u0439\u043b\u0430', 'fileMeta': '\u0420\u0430\u0437\u043c\u0435\u0440 \u2022 \u0414\u0430\u0442\u0430 \u0438\u0437\u043c\u0435\u043d\u0435\u043d\u0438\u044f',
        'dropTitle': '\u041f\u0435\u0440\u0435\u0442\u0430\u0449\u0438\u0442\u0435 \u0444\u0430\u0439\u043b\u044b \u0441\u044e\u0434\u0430 \u0434\u043b\u044f \u0437\u0430\u0433\u0440\u0443\u0437\u043a\u0438',
        'dropDesc': '\u0412\u0430\u0448\u0438 \u0444\u0430\u0439\u043b\u044b \u0431\u0443\u0434\u0443\u0442 \u043c\u0433\u043d\u043e\u0432\u0435\u043d\u043d\u043e \u0437\u0430\u0433\u0440\u0443\u0436\u0435\u043d\u044b \u0432 \u044d\u0442\u0443 \u043e\u0431\u0449\u0443\u044e \u043f\u0430\u043f\u043a\u0443',
        'footer': '\u0411\u0435\u0437\u043e\u043f\u0430\u0441\u043d\u043e\u0435 \u0441\u043e\u0432\u043c\u0435\u0441\u0442\u043d\u043e\u0435 \u0438\u0441\u043f\u043e\u043b\u044c\u0437\u043e\u0432\u0430\u043d\u0438\u0435 \u0438 \u0441\u0442\u0440\u0438\u043c\u0438\u043d\u0433 \u0444\u0430\u0439\u043b\u043e\u0432 \u0447\u0435\u0440\u0435\u0437 ZenFile',
        'download': '\u0421\u043a\u0430\u0447\u0430\u0442\u044c', 'copyLink': '\u041a\u043e\u043f\u0438\u0440\u043e\u0432\u0430\u0442\u044c \u0441\u0441\u044b\u043b\u043a\u0443',
      },
      'ar': {
        'root': '\u0627\u0644\u062c\u0630\u0631', 'parentDir': '.. (\u0627\u0644\u062f\u0644\u064a\u0644 \u0627\u0644\u0623\u0635\u0644\u064a)', 'goUp': '\u0627\u0644\u0627\u0646\u062a\u0642\u0627\u0644 \u0644\u0644\u0623\u0639\u0644\u0649',
        'folders': '\u0627\u0644\u0645\u062c\u0644\u062f\u0627\u062a', 'videos': '\u0627\u0644\u0641\u064a\u062f\u064a\u0648', 'audio': '\u0627\u0644\u0635\u0648\u062a', 'images': '\u0627\u0644\u0635\u0648\u0631',
        'documents': '\u0627\u0644\u0645\u0633\u062a\u0646\u062f\u0627\u062a', 'others': '\u0623\u062e\u0631\u0649', 'items': '\u0639\u0646\u0635\u0631',
        'noItems': '\u0644\u0627 \u062a\u0648\u062c\u062f \u0639\u0646\u0627\u0635\u0631 \u0641\u064a \u0647\u0630\u0647 \u0627\u0644\u0641\u0626\u0629', 'search': '\u0627\u0644\u0628\u062d\u062b \u0639\u0646 \u0627\u0644\u0645\u0644\u0641\u0627\u062a \u0648\u0627\u0644\u0645\u062c\u0644\u062f\u0627\u062a...',
        'upload': '\u0631\u0641\u0639', 'emptySearch': '\u0644\u0627 \u062a\u0648\u062c\u062f \u0639\u0646\u0627\u0635\u0631 \u062a\u0637\u0627\u0628\u0642 \u0628\u062d\u062b\u0643',
        'emptyDesc': '\u062a\u062d\u0642\u0642 \u0645\u0646 \u0627\u0644\u0625\u0645\u0644\u0627\u0621 \u0623\u0648 \u062c\u0631\u0628 \u0645\u0635\u0637\u0644\u062d\u0627\u062d \u0622\u062e\u0631.',
        'fileName': '\u0627\u0633\u0645 \u0627\u0644\u0645\u0644\u0641', 'fileMeta': '\u0627\u0644\u062d\u062c\u0645 \u2022 \u062a\u0627\u0631\u064a\u062e \u0627\u0644\u062a\u0639\u062f\u064a\u0644',
        'dropTitle': '\u0623\u0633\u062d\u0628 \u0627\u0644\u0645\u0644\u0641\u0627\u062a \u0647\u0646\u0627 \u0644\u0644\u0631\u0641\u0639',
        'dropDesc': '\u0633\u062a\u0645 \u0631\u0641\u0639 \u0645\u0644\u0641\u0627\u062a\u0643 \u0641\u0648\u0631\u0627\u064b \u0625\u0644\u0649 \u0647\u0630\u0627 \u0627\u0644\u0645\u062c\u0644\u062f \u0627\u0644\u0645\u0634\u062a\u0631\u0643',
        'footer': '\u0645\u0634\u0627\u0631\u0643\u0629 \u0648\u0628\u062b \u0627\u0644\u0645\u0644\u0641\u0627\u062a \u0628\u0623\u0645\u0627\u0646 \u0639\u0628\u0631 ZenFile',
        'download': '\u062a\u062d\u0645\u064a\u0644', 'copyLink': '\u0646\u0633\u062e \u0627\u0644\u0631\u0627\u0628\u0637',
      },
    };
    final tr = _translations[lang] ?? _translations['en']!;

    final title = currentPath == '/' ? tr['root']! : p.posix.basename(currentPath);

    // Build breadcrumbs list
    final parts = currentPath.split('/').where((p) => p.isNotEmpty).toList();
    var breadcrumbsHtml = '<a href="/">${tr['root']}</a>';
    var pathAccumulator = '';
    for (int i = 0; i < parts.length; i++) {
      pathAccumulator += '/${parts[i]}';
      breadcrumbsHtml += ' <span class="arrow">&gt;</span> <a href="$pathAccumulator">${parts[i]}</a>';
    }

    // Build directories list & files lists - categorized
    var listHtml = '';

    // Standard high-fidelity SVGs to avoid emojis and offer a premium, modern layout
    const folderSvg = '<svg class="svg-icon" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M22 19a2 2 0 0 1-2 2H4a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h5l2 3h9a2 2 0 0 1 2 2z"></path></svg>';
    const videoSvg = '<svg class="svg-icon" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><polygon points="23 7 16 12 23 17 23 7"></polygon><rect x="1" y="5" width="15" height="14" rx="2" ry="2"></rect></svg>';
    const audioSvg = '<svg class="svg-icon" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M9 18V5l12-2v13"></path><circle cx="6" cy="18" r="3"></circle><circle cx="18" cy="16" r="3"></circle></svg>';
    const imageSvg = '<svg class="svg-icon" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><rect x="3" y="3" width="18" height="18" rx="2" ry="2"></rect><circle cx="8.5" cy="8.5" r="1.5"></circle><polyline points="21 15 16 10 5 21"></polyline></svg>';
    const pdfSvg = '<svg class="svg-icon" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8z"></path><polyline points="14 2 14 8 20 8"></polyline><line x1="16" y1="13" x2="8" y2="13"></line><line x1="16" y1="17" x2="8" y2="17"></line></svg>';
    const fileSvg = '<svg class="svg-icon" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M13 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V9z"></path><polyline points="13 2 13 9 20 9"></polyline></svg>';
    const backSvg = '<svg class="svg-icon" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><polyline points="9 14 4 9 9 4"></polyline><path d="M20 20v-7a4 4 0 0 0-4-4H4"></path></svg>';
    const downloadSvg = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><path d="M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4"></path><polyline points="7 10 12 15 17 10"></polyline><line x1="12" y1="15" x2="12" y2="3"></line></svg>';

    // Categorize items
    final folders = <FileSystemEntity>[];
    final videos = <FileSystemEntity>[];
    final audios = <FileSystemEntity>[];
    final images = <FileSystemEntity>[];
    final documents = <FileSystemEntity>[];
    final others = <FileSystemEntity>[];

    // Helper to categorize a file by extension
    void _categorizeFile(FileSystemEntity item, List<FileSystemEntity> vids, List<FileSystemEntity> auds, List<FileSystemEntity> imgs, List<FileSystemEntity> docs, List<FileSystemEntity> oth) {
      final ext = p.extension(item.path).toLowerCase();
      if (['.mp4', '.mkv', '.avi', '.mov', '.wmv', '.flv', '.webm', '.3gp', '.ts', '.m4v', '.rmvb', '.rm', '.asf', '.f4v'].contains(ext)) {
        vids.add(item);
      } else if (['.mp3', '.wav', '.flac', '.m4a', '.ogg', '.wma', '.aac', '.opus', '.amr', '.mid', '.midi'].contains(ext)) {
        auds.add(item);
      } else if (['.jpg', '.jpeg', '.png', '.gif', '.webp', '.bmp', '.svg', '.ico', '.tiff', '.tif', '.heic', '.heif', '.avif', '.raw'].contains(ext)) {
        imgs.add(item);
      } else if (['.pdf', '.doc', '.docx', '.xls', '.xlsx', '.ppt', '.pptx', '.txt', '.csv', '.rtf', '.odt', '.ods', '.odp', '.md', '.json', '.xml', '.html', '.htm', '.log', '.conf', '.cfg', '.ini', '.yaml', '.yml', '.toml'].contains(ext)) {
        docs.add(item);
      } else {
        oth.add(item);
      }
    }

    for (final item in items) {
      final name = p.basename(item.path);
      if (name.startsWith('.')) continue;
      if (item is Directory) {
        folders.add(item);
      } else {
        _categorizeFile(item, videos, audios, images, documents, others);
      }
    }

    // Recursively scan subdirectories for media/document files (limited depth)
    void scanSubdirs(Directory dir, int depth) {
      if (depth > 3) return; // limit recursion depth to prevent performance issues
      try {
        for (final sub in dir.listSync()) {
          final subName = p.basename(sub.path);
          if (subName.startsWith('.')) continue;
          if (sub is Directory) {
            scanSubdirs(sub, depth + 1);
          } else if (sub is File) {
            _categorizeFile(sub, videos, audios, images, documents, others);
          }
        }
      } catch (e) {
        // Skip directories we can't read (permission denied, etc.)
      }
    }

    // Scan each immediate subdirectory for media/document files
    for (final folder in folders) {
      if (folder is Directory) {
        scanSubdirs(folder, 1);
      }
    }

    debugPrint('WebSharing HTML: folders=${folders.length}, videos=${videos.length}, audios=${audios.length}, images=${images.length}, documents=${documents.length}, others=${others.length}');
    debugPrint('WebSharing HTML: currentPath=$currentPath, rootDir=$rootDir, totalItems=${items.length}');

    // Helper to generate a single item HTML
    String generateItemHtml(FileSystemEntity item) {
      final name = p.basename(item.path);
      final isDir = item is Directory;
      // Calculate correct URL relative to rootDir (important for recursively scanned files)
      final relativeUrl = '/' + p.posix.relative(item.path, from: rootDir);

      String sizeStr = '-';
      String dateStr = '-';
      String iconClass = 'file-icon';
      String mimeType = 'application/octet-stream';
      String svgIcon = '';

      if (isDir) {
        iconClass = 'dir-icon';
        svgIcon = folderSvg;
      } else {
        try {
        final stat = item.statSync();
        final sizeBytes = stat.size;
        dateStr = stat.modified.toString().substring(0, 16);

        if (sizeBytes > 1024 * 1024 * 1024) {
          sizeStr = '${(sizeBytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
        } else if (sizeBytes > 1024 * 1024) {
          sizeStr = '${(sizeBytes / (1024 * 1024)).toStringAsFixed(1)} MB';
        } else {
          sizeStr = '${(sizeBytes / 1024).toStringAsFixed(0)} KB';
        }
        } catch (e) {
          debugPrint('Error reading stat for ${item.path}: $e');
          sizeStr = '?';
          dateStr = '?';
        }

        final ext = p.extension(item.path).toLowerCase();
        if (['.mp4', '.mkv', '.avi', '.mov', '.wmv', '.flv', '.webm', '.3gp', '.ts', '.m4v', '.rmvb', '.rm', '.asf', '.f4v'].contains(ext)) {
          iconClass = 'video-icon';
          mimeType = 'video/mp4';
          svgIcon = videoSvg;
        } else if (['.mp3', '.wav', '.flac', '.m4a', '.ogg', '.wma', '.aac', '.opus', '.amr', '.mid', '.midi'].contains(ext)) {
          iconClass = 'audio-icon';
          mimeType = 'audio/mpeg';
          svgIcon = audioSvg;
        } else if (['.jpg', '.jpeg', '.png', '.gif', '.webp', '.bmp', '.svg', '.ico', '.tiff', '.tif', '.heic', '.heif', '.avif', '.raw'].contains(ext)) {
          iconClass = 'image-icon';
          mimeType = 'image/png';
          svgIcon = imageSvg;
        } else if (['.pdf', '.doc', '.docx', '.xls', '.xlsx', '.ppt', '.pptx', '.txt', '.csv', '.rtf', '.odt', '.ods', '.odp', '.md', '.json', '.xml', '.html', '.htm', '.log', '.conf', '.cfg', '.ini', '.yaml', '.yml', '.toml'].contains(ext)) {
          iconClass = 'pdf-icon';
          mimeType = 'application/pdf';
          svgIcon = pdfSvg;
        } else {
          iconClass = 'file-icon';
          svgIcon = fileSvg;
        }
      }

      if (isDir) {
        return '''
        <div class="explorer-item folder-item" data-name="${name.replaceAll('"', '&quot;')}" data-type="directory" data-url="$relativeUrl" onclick="handleItemClick(this)">
          <div class="item-icon-wrapper dir-icon">$svgIcon</div>
          <div class="item-details">
            <div class="item-name" title="${name.replaceAll('"', '&quot;')}">$name</div>
          </div>
        </div>
        ''';
      } else {
        final actionsHtml = '''
          <div class="item-actions">
            <button class="action-btn download-btn" onclick="downloadFile('$relativeUrl', '${name.replaceAll("'", "\\'")}', event)" title="Download File">
              $downloadSvg
            </button>
          </div>
        ''';

        return '''
        <div class="explorer-item file-item" data-name="${name.replaceAll('"', '&quot;')}" data-type="file" data-url="$relativeUrl" data-size="$sizeStr" data-modified="$dateStr" data-mime="$mimeType" onclick="handleItemClick(this)">
          <div class="item-icon-wrapper $iconClass">$svgIcon</div>
          <div class="item-details">
            <div class="item-name" title="${name.replaceAll('"', '&quot;')}">$name</div>
            <div class="item-meta">
              <span class="item-size">$sizeStr</span>
              <span class="item-sep">&#8226;</span>
              <span class="item-date">$dateStr</span>
            </div>
          </div>
          $actionsHtml
        </div>
        ''';
      }
    }

    // Parent directory item (if not root)
    if (currentPath != '/') {
      final parentPath = p.posix.dirname(currentPath);
      final parentUrl = parentPath == '.' || parentPath == '' ? '/' : parentPath;
      listHtml += '''
        <div class="explorer-item parent-dir" onclick="window.location.href='$parentUrl'">
          <div class="item-icon-wrapper dir-icon">$backSvg</div>
          <div class="item-details">
            <div class="item-name">${tr['parentDir']}</div>
            <div class="item-meta">${tr['goUp']}</div>
          </div>
        </div>
      ''';
    }

    // Helper to generate a category section
    String generateCategorySection(String catKey, String catName, String iconClass, String svgIcon, List<FileSystemEntity> catItems, {bool defaultCollapsed = false}) {
      final collapsedClass = (catItems.isEmpty || defaultCollapsed) ? 'collapsed' : '';
      if (catItems.isEmpty) {
        return '''
        <section class="category-section $collapsedClass" id="cat-section-$catKey">
          <div class="category-header" onclick="toggleCategory('$catKey')">
            <div class="category-icon $iconClass">$svgIcon</div>
            <div class="category-title">$catName</div>
            <div class="category-count">0 ${tr['items']}</div>
            <div class="category-toggle">&#9660;</div>
          </div>
          <div class="category-items" id="cat-$catKey">
            <div class="category-empty">${tr['noItems']}</div>
          </div>
        </section>
        ''';
      }

      var itemsHtml = '';
      for (final item in catItems) {
        try {
          itemsHtml += generateItemHtml(item);
        } catch (e) {
          debugPrint('Error generating HTML for item ${item.path}: $e');
        }
      }

      return '''
        <section class="category-section $collapsedClass" id="cat-section-$catKey">
          <div class="category-header" onclick="toggleCategory('$catKey')">
            <div class="category-icon $iconClass">$svgIcon</div>
            <div class="category-title">$catName</div>
            <div class="category-count">${catItems.length} ${tr['items']}</div>
            <div class="category-toggle">&#9660;</div>
          </div>
          <div class="category-items" id="cat-$catKey">
            $itemsHtml
          </div>
        </section>
        ''';
    }

    // Generate category sections in order
    // Folders section defaults to collapsed only at root path, subdirectories default to expanded
    // Media/document categories default to collapsed (content is from recursive scan)
    final isRoot = currentPath == '/';
    listHtml += generateCategorySection('folders', tr['folders']!, 'cat-folders', folderSvg, folders, defaultCollapsed: isRoot);
    listHtml += generateCategorySection('videos', tr['videos']!, 'cat-videos', videoSvg, videos, defaultCollapsed: true);
    listHtml += generateCategorySection('audio', tr['audio']!, 'cat-audio', audioSvg, audios, defaultCollapsed: true);
    listHtml += generateCategorySection('images', tr['images']!, 'cat-images', imageSvg, images, defaultCollapsed: true);
    listHtml += generateCategorySection('documents', tr['documents']!, 'cat-documents', pdfSvg, documents, defaultCollapsed: true);
    listHtml += generateCategorySection('others', tr['others']!, 'cat-others', fileSvg, others, defaultCollapsed: true);

    final badgeHtml = '''
      <div class="header-actions">
        <span class="status-indicator ${isInternet ? 'cloud' : 'local'}" title="${isInternet ? 'Secure Internet Share' : 'Local High-Speed Wi-Fi Share'}"></span>
        <button class="header-upload-btn" onclick="triggerFileInput()" title="Upload Files to this Folder">
          <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><path d="M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4"></path><polyline points="17 8 12 3 7 8"></polyline><line x1="12" y1="3" x2="12" y2="15"></line></svg>
          <span id="uploadBtnText">${tr['upload']}</span>
        </button>
      </div>
    ''';

    return '''
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>ZenFile Shared Portal - $title</title>
  <link href="https://fonts.googleapis.com/css2?family=Outfit:wght@300;400;500;600;700;800&family=JetBrains+Mono:wght@400;500&display=swap" rel="stylesheet">
  <style>
    :root {
      --primary: #3B82F6;
      --primary-rgb: 59, 130, 246;
      --primary-hover: #60A5FA;
      --bg: #090d16;
      --card: rgba(17, 24, 39, 0.45);
      --card-hover: rgba(30, 41, 59, 0.7);
      --text: #F3F4F6;
      --text-muted: #9CA3AF;
      --border: rgba(255, 255, 255, 0.06);
      --border-hover: rgba(59, 130, 246, 0.35);
      --hover-row: rgba(255, 255, 255, 0.03);

      /* Accent colors for file categories */
      --dir-color: #10B981;
      --video-color: #3B82F6;
      --audio-color: #8B5CF6;
      --image-color: #EC4899;
      --pdf-color: #EF4444;
      --file-color: #6B7280;
    }
    body {
      background-color: var(--bg);
      background-image: 
        radial-gradient(circle at 0% 0%, rgba(59, 130, 246, 0.06) 0%, transparent 40%),
        radial-gradient(circle at 100% 100%, rgba(139, 92, 246, 0.05) 0%, transparent 40%);
      background-attachment: fixed;
      color: var(--text);
      font-family: 'Outfit', sans-serif;
      margin: 0;
      padding: 0;
      min-height: 100vh;
      overflow-x: hidden;
    }
    header {
      background: rgba(9, 13, 22, 0.75);
      backdrop-filter: blur(20px);
      -webkit-backdrop-filter: blur(20px);
      padding: 16px 24px;
      border-bottom: 1px solid var(--border);
      position: sticky;
      top: 0;
      z-index: 100;
    }
    .header-content {
      max-width: 1100px;
      margin: 0 auto;
      display: flex;
      align-items: center;
      justify-content: space-between;
      gap: 16px;
    }
    .brand-section {
      display: flex;
      align-items: center;
      gap: 12px;
    }
    .logo-container {
      background: linear-gradient(135deg, #3B82F6, #1D4ED8);
      width: 36px;
      height: 36px;
      border-radius: 10px;
      display: flex;
      align-items: center;
      justify-content: center;
      box-shadow: 0 4px 14px rgba(59, 130, 246, 0.3);
      font-weight: 800;
      font-size: 18px;
      color: #fff;
    }
    h1 {
      margin: 0;
      font-size: 20px;
      font-weight: 700;
      letter-spacing: -0.5px;
      background: linear-gradient(to right, #F9FAFB, #D1D5DB);
      -webkit-background-clip: text;
      -webkit-text-fill-color: transparent;
    }
    .header-actions {
      display: flex;
      align-items: center;
      gap: 12px;
    }
    .status-indicator {
      width: 9px;
      height: 9px;
      border-radius: 50%;
      position: relative;
      display: inline-block;
    }
    .status-indicator.local {
      background: #34D399;
      box-shadow: 0 0 10px #34D399, 0 0 4px #34D399;
    }
    .status-indicator.cloud {
      background: #60A5FA;
      box-shadow: 0 0 10px #60A5FA, 0 0 4px #60A5FA;
    }
    .status-indicator::after {
      content: "";
      position: absolute;
      top: -2px;
      left: -2px;
      right: -2px;
      bottom: -2px;
      border-radius: 50%;
      border: 1.5px solid transparent;
      animation: statusPulse 2.2s infinite ease-in-out;
    }
    .status-indicator.local::after {
      border-color: rgba(52, 211, 153, 0.45);
    }
    .status-indicator.cloud::after {
      border-color: rgba(96, 165, 250, 0.45);
    }
    @keyframes statusPulse {
      0% { transform: scale(1); opacity: 1; }
      100% { transform: scale(1.6); opacity: 0; }
    }
    .header-upload-btn {
      background: var(--primary);
      border: 1px solid rgba(59, 130, 246, 0.2);
      color: #fff;
      padding: 7px 14px;
      font-size: 12.5px;
      font-weight: 600;
      border-radius: 10px;
      cursor: pointer;
      display: inline-flex;
      align-items: center;
      gap: 6px;
      box-shadow: 0 4px 12px rgba(59, 130, 246, 0.3);
      transition: all 0.2s ease;
      font-family: inherit;
    }
    .header-upload-btn:hover {
      background: var(--primary-hover);
      box-shadow: 0 4px 16px rgba(59, 130, 246, 0.45);
      transform: translateY(-1px);
    }
    .header-upload-btn svg {
      width: 14px;
      height: 14px;
    }
    .container {
      max-width: 1100px;
      margin: 24px auto;
      padding: 0 20px;
      box-sizing: border-box;
    }
    .breadcrumbs {
      background: var(--card);
      backdrop-filter: blur(12px);
      -webkit-backdrop-filter: blur(12px);
      padding: 12px 18px;
      border-radius: 14px;
      font-size: 14px;
      margin-bottom: 20px;
      border: 1px solid var(--border);
      color: var(--text-muted);
      display: flex;
      align-items: center;
      flex-wrap: wrap;
      gap: 6px;
    }
    .breadcrumbs a {
      color: var(--primary);
      text-decoration: none;
      font-weight: 600;
      transition: color 0.2s ease;
    }
    .breadcrumbs a:hover {
      color: var(--primary-hover);
    }
    .breadcrumbs .arrow {
      color: rgba(255, 255, 255, 0.15);
    }

    /* Modern Toolbar styling */
    .toolbar {
      display: flex;
      align-items: center;
      justify-content: space-between;
      gap: 16px;
      margin-bottom: 20px;
    }
    .search-wrapper {
      position: relative;
      flex: 1;
      max-width: 400px;
    }
    .search-input {
      width: 100%;
      background: var(--card);
      border: 1px solid var(--border);
      border-radius: 12px;
      padding: 12px 16px 12px 42px;
      color: var(--text);
      font-family: inherit;
      font-size: 14.5px;
      box-sizing: border-box;
      transition: all 0.2s ease;
    }
    .search-input:focus {
      outline: none;
      border-color: var(--primary);
      box-shadow: 0 0 0 3px rgba(59, 130, 246, 0.15);
      background: rgba(17, 24, 39, 0.7);
    }
    .search-icon {
      position: absolute;
      left: 14px;
      top: 50%;
      transform: translateY(-50%);
      width: 18px;
      height: 18px;
      color: var(--text-muted);
      pointer-events: none;
    }
    .toolbar-controls {
      display: flex;
      align-items: center;
      gap: 12px;
    }
    .view-toggles {
      display: flex;
      background: var(--card);
      border: 1px solid var(--border);
      padding: 4px;
      border-radius: 12px;
      gap: 4px;
    }
    .toggle-btn {
      background: transparent;
      border: none;
      color: var(--text-muted);
      padding: 8px;
      border-radius: 8px;
      cursor: pointer;
      display: flex;
      align-items: center;
      justify-content: center;
      transition: all 0.2s ease;
    }
    .toggle-btn svg {
      width: 18px;
      height: 18px;
      stroke-width: 2.2;
    }
    .toggle-btn:hover {
      color: var(--text);
      background: rgba(255, 255, 255, 0.03);
    }
    .toggle-btn.active {
      color: #fff;
      background: var(--primary);
      box-shadow: 0 2px 8px rgba(59, 130, 246, 0.35);
    }

    /* Core Catalog Grid / List */
    .items-container {
      transition: all 0.3s ease;
    }

    /* Explorer Item Styling */
    .explorer-item {
      background: var(--card);
      border: 1px solid var(--border);
      border-radius: 16px;
      cursor: pointer;
      display: flex;
      position: relative;
      overflow: hidden;
      box-sizing: border-box;
      transition: all 0.25s cubic-bezier(0.4, 0, 0.2, 1);
    }
    .explorer-item:hover {
      background: var(--card-hover);
      border-color: var(--border-hover);
      transform: translateY(-2px);
      box-shadow: 0 8px 24px rgba(0, 0, 0, 0.25);
    }
    .item-icon-wrapper {
      display: flex;
      align-items: center;
      justify-content: center;
      border-radius: 12px;
      transition: all 0.2s ease;
    }
    .item-icon-wrapper svg {
      width: 50%;
      height: 50%;
      transition: transform 0.2s ease;
    }
    .explorer-item:hover .item-icon-wrapper svg {
      transform: scale(1.08);
    }

    /* Categorized Accent Styling */
    .dir-icon {
      background: rgba(16, 185, 129, 0.08);
      border: 1px solid rgba(16, 185, 129, 0.15);
      color: var(--dir-color);
    }
    .video-icon {
      background: rgba(59, 130, 246, 0.08);
      border: 1px solid rgba(59, 130, 246, 0.15);
      color: var(--video-color);
    }
    .audio-icon {
      background: rgba(139, 92, 246, 0.08);
      border: 1px solid rgba(139, 92, 246, 0.15);
      color: var(--audio-color);
    }
    .image-icon {
      background: rgba(236, 72, 153, 0.08);
      border: 1px solid rgba(236, 72, 153, 0.15);
      color: var(--image-color);
    }
    .pdf-icon {
      background: rgba(239, 68, 68, 0.08);
      border: 1px solid rgba(239, 68, 68, 0.15);
      color: var(--pdf-color);
    }
    .file-icon {
      background: rgba(107, 114, 128, 0.08);
      border: 1px solid rgba(107, 114, 128, 0.15);
      color: var(--file-color);
    }

    .item-details {
      min-width: 0; /* Prevents overflow */
    }
    .item-name {
      font-weight: 600;
      color: var(--text);
      white-space: nowrap;
      overflow: hidden;
      text-overflow: ellipsis;
      font-size: 14.5px;
      transition: color 0.15s ease;
    }
    .explorer-item:hover .item-name {
      color: var(--primary-hover);
    }
    .item-meta {
      font-size: 12px;
      color: var(--text-muted);
      display: flex;
      align-items: center;
      gap: 6px;
      margin-top: 4px;
    }
    .item-size {
      font-family: 'JetBrains Mono', monospace;
    }
    .item-date {
      font-family: 'JetBrains Mono', monospace;
    }
    .item-sep {
      opacity: 0.4;
    }

    /* Actions buttons */
    .item-actions {
      display: flex;
      align-items: center;
      gap: 6px;
      opacity: 0;
      transition: opacity 0.2s ease;
    }
    .explorer-item:hover .item-actions {
      opacity: 1;
    }
    .action-btn {
      background: rgba(255, 255, 255, 0.04);
      border: 1px solid var(--border);
      color: var(--text-muted);
      width: 32px;
      height: 32px;
      border-radius: 8px;
      cursor: pointer;
      display: flex;
      align-items: center;
      justify-content: center;
      transition: all 0.15s ease;
    }
    .action-btn svg {
      width: 14px;
      height: 14px;
    }
    .action-btn:hover {
      color: #fff;
      background: var(--primary);
      border-color: var(--primary);
      box-shadow: 0 0 10px rgba(59, 130, 246, 0.4);
    }

    /* Grid Layout View Mode */
    .items-container.grid-mode {
      display: grid;
      grid-template-columns: repeat(auto-fill, minmax(180px, 1fr));
      gap: 16px;
    }
    .items-container.grid-mode .explorer-item {
      flex-direction: column;
      align-items: center;
      text-align: center;
      padding: 24px 16px 16px 16px;
    }
    .items-container.grid-mode .item-icon-wrapper {
      width: 64px;
      height: 64px;
      margin-bottom: 12px;
    }
    .items-container.grid-mode .item-icon-wrapper svg {
      width: 28px;
      height: 28px;
    }
    .items-container.grid-mode .item-details {
      width: 100%;
    }
    .items-container.grid-mode .item-meta {
      justify-content: center;
      margin-top: 6px;
    }
    .items-container.grid-mode .item-actions {
      margin-top: 14px;
      opacity: 0.3; /* Show slightly on grid for mobile compatibility */
    }
    .items-container.grid-mode .explorer-item:hover .item-actions {
      opacity: 1;
    }

    /* List Layout View Mode */
    .items-container.list-mode {
      display: flex;
      flex-direction: column;
      gap: 8px;
    }
    .items-container.list-mode .explorer-item {
      flex-direction: row;
      align-items: center;
      padding: 10px 16px;
    }
    .items-container.list-mode .item-icon-wrapper {
      width: 36px;
      height: 36px;
      flex-shrink: 0;
    }
    .items-container.list-mode .item-icon-wrapper svg {
      width: 18px;
      height: 18px;
    }
    .items-container.list-mode .item-details {
      flex: 1;
      margin-left: 16px;
      display: flex;
      align-items: center;
      justify-content: space-between;
      gap: 16px;
    }
    .items-container.list-mode .item-name {
      flex: 2;
      text-align: left;
    }
    .items-container.list-mode .item-meta {
      flex: 3;
      margin-top: 0;
      justify-content: flex-end;
      gap: 16px;
    }
    .items-container.list-mode .item-actions {
      margin-left: 16px;
      flex-shrink: 0;
    }

    /* Clean representation modifications for folder items in Grid/List views */
    .explorer-item.folder-item {
      padding: 20px 16px !important;
    }
    .items-container.grid-mode .explorer-item.folder-item {
      padding: 24px 16px !important;
    }
    .items-container.list-mode .explorer-item.folder-item .item-details {
      justify-content: flex-start;
    }

    /* Empty Search State */
    .empty-state {
      display: flex;
      flex-direction: column;
      align-items: center;
      justify-content: center;
      padding: 64px 20px;
      text-align: center;
      border: 1px dashed var(--border);
      border-radius: 20px;
      background: var(--card);
      margin-top: 24px;
    }
    .empty-icon {
      font-size: 32px;
      margin-bottom: 12px;
      opacity: 0.6;
    }
    .empty-state h3 {
      margin: 0 0 6px 0;
      font-weight: 600;
      color: var(--text);
    }
    .empty-state p {
      margin: 0;
      font-size: 13.5px;
      color: var(--text-muted);
    }

    /* Floating Blurred Glass Preview Modal */
    .modal-overlay {
      position: fixed;
      top: 0;
      left: 0;
      right: 0;
      bottom: 0;
      background: rgba(3, 7, 18, 0.45);
      backdrop-filter: blur(12px);
      -webkit-backdrop-filter: blur(12px);
      z-index: 1000;
      opacity: 0;
      pointer-events: none;
      display: flex;
      align-items: center;
      justify-content: center;
      padding: 20px;
      box-sizing: border-box;
      transition: opacity 0.3s cubic-bezier(0.4, 0, 0.2, 1);
    }
    .modal-overlay.active {
      opacity: 1;
      pointer-events: auto;
    }
    .modal-card {
      background: rgba(15, 23, 42, 0.7);
      border: 1px solid rgba(255, 255, 255, 0.1);
      backdrop-filter: blur(30px);
      -webkit-backdrop-filter: blur(30px);
      border-radius: 24px;
      width: 100%;
      max-width: 720px;
      box-shadow: 0 25px 50px -12px rgba(0, 0, 0, 0.6);
      transform: scale(0.95) translateY(10px);
      transition: all 0.3s cubic-bezier(0.34, 1.56, 0.64, 1);
      display: flex;
      flex-direction: column;
      max-height: 85vh;
      position: relative;
      overflow: hidden;
    }
    .modal-overlay.active .modal-card {
      transform: scale(1) translateY(0);
    }
    .modal-close {
      position: absolute;
      top: 18px;
      right: 18px;
      background: rgba(255, 255, 255, 0.05);
      border: 1px solid rgba(255, 255, 255, 0.08);
      color: var(--text-muted);
      width: 32px;
      height: 32px;
      border-radius: 50%;
      cursor: pointer;
      display: flex;
      align-items: center;
      justify-content: center;
      transition: all 0.15s ease;
      z-index: 10;
    }
    .modal-close:hover {
      background: rgba(239, 68, 68, 0.2);
      color: #EF4444;
      border-color: rgba(239, 68, 68, 0.3);
      transform: rotate(90deg);
    }
    .modal-close svg {
      width: 14px;
      height: 14px;
    }
    .modal-header {
      padding: 24px;
      display: flex;
      align-items: center;
      gap: 16px;
      border-bottom: 1px solid var(--border);
    }
    .modal-icon-wrapper {
      width: 44px;
      height: 44px;
      border-radius: 12px;
      display: flex;
      align-items: center;
      justify-content: center;
      flex-shrink: 0;
    }
    .modal-icon-wrapper svg {
      width: 20px;
      height: 20px;
    }
    .modal-title-wrapper {
      min-width: 0;
    }
    .modal-title-wrapper h3 {
      margin: 0;
      font-size: 17px;
      font-weight: 700;
      color: var(--text);
      white-space: nowrap;
      overflow: hidden;
      text-overflow: ellipsis;
    }
    .modal-title-wrapper p {
      margin: 4px 0 0 0;
      font-size: 12.5px;
      color: var(--text-muted);
    }
    .modal-body {
      flex: 1;
      padding: 24px;
      overflow-y: auto;
      display: flex;
      flex-direction: column;
      align-items: center;
      justify-content: center;
      background: rgba(0, 0, 0, 0.2);
      min-height: 260px;
    }
    .modal-footer {
      padding: 16px 24px;
      border-top: 1px solid var(--border);
      display: flex;
      align-items: center;
      justify-content: flex-end;
      gap: 12px;
      background: rgba(15, 23, 42, 0.4);
    }
    
    /* Interactive Preview Media Styling */
    .video-container {
      width: 100%;
      border-radius: 14px;
      overflow: hidden;
      background: #000;
      border: 1px solid var(--border);
      box-shadow: 0 8px 24px rgba(0,0,0,0.5);
    }
    .preview-video {
      width: 100%;
      max-height: 45vh;
      display: block;
      outline: none;
    }
    .image-container {
      max-width: 100%;
      max-height: 45vh;
      border-radius: 14px;
      overflow: hidden;
      border: 1px solid var(--border);
      box-shadow: 0 8px 24px rgba(0,0,0,0.4);
    }
    .preview-image {
      max-width: 100%;
      max-height: 45vh;
      object-fit: contain;
      display: block;
    }
    .preview-pdf {
      width: 100%;
      height: 45vh;
      border: 1px solid var(--border);
      border-radius: 14px;
      background: #fff;
    }

    /* Ambient Audio Streaming layout */
    .audio-container {
      width: 100%;
      padding: 40px 24px;
      border-radius: 16px;
      background: radial-gradient(circle at center, rgba(139, 92, 246, 0.12) 0%, rgba(9, 13, 22, 0.4) 100%);
      border: 1px solid rgba(139, 92, 246, 0.2);
      box-sizing: border-box;
      display: flex;
      flex-direction: column;
      align-items: center;
      gap: 24px;
      position: relative;
    }
    .audio-art-disc {
      width: 72px;
      height: 72px;
      border-radius: 50%;
      background: linear-gradient(135deg, #8B5CF6, #6D28D9);
      display: flex;
      align-items: center;
      justify-content: center;
      font-size: 32px;
      box-shadow: 0 0 24px rgba(139, 92, 246, 0.45);
      animation: pulseGlow 2.5s infinite alternate;
    }
    @keyframes pulseGlow {
      0% {
        box-shadow: 0 0 15px rgba(139, 92, 246, 0.3);
        transform: scale(0.98);
      }
      100% {
        box-shadow: 0 0 35px rgba(139, 92, 246, 0.6);
        transform: scale(1.02);
      }
    }
    .preview-audio {
      width: 100%;
      max-width: 450px;
      outline: none;
    }

    /* Scrollable Code/Text preview */
    .preview-text {
      width: 100%;
      max-height: 45vh;
      background: #05070c;
      border: 1px solid var(--border);
      border-radius: 14px;
      padding: 16px;
      margin: 0;
      overflow: auto;
      box-sizing: border-box;
      text-align: left;
    }
    .preview-text code {
      font-family: 'JetBrains Mono', monospace;
      font-size: 13px;
      color: #E5E7EB;
      line-height: 1.5;
    }
    .preview-text-loading {
      color: var(--text-muted);
      font-size: 14px;
      display: flex;
      align-items: center;
      gap: 8px;
    }
    .preview-text-loading::after {
      content: "";
      width: 14px;
      height: 14px;
      border: 2px solid var(--primary);
      border-right-color: transparent;
      border-radius: 50%;
      animation: spin 0.8s linear infinite;
    }
    @keyframes spin {
      to { transform: rotate(360deg); }
    }
    .preview-text-error {
      color: #EF4444;
      font-size: 14px;
    }

    /* Fallback generic file UI */
    .generic-container {
      text-align: center;
      display: flex;
      flex-direction: column;
      align-items: center;
      gap: 12px;
      padding: 32px;
    }
    .generic-preview-icon {
      width: 72px;
      height: 72px;
      border-radius: 20px;
      background: rgba(255,255,255,0.03);
      border: 1px solid var(--border);
      display: flex;
      align-items: center;
      justify-content: center;
      color: var(--text-muted);
    }
    .generic-preview-icon svg {
      width: 32px;
      height: 32px;
    }
    .generic-preview-text {
      margin: 0;
      font-weight: 600;
      color: var(--text);
      font-size: 15px;
    }
    .generic-preview-subtext {
      margin: 0;
      color: var(--text-muted);
      font-size: 13px;
    }

    /* Modal premium Buttons */
    .btn {
      display: inline-flex;
      align-items: center;
      padding: 10px 18px;
      font-size: 13.5px;
      font-weight: 600;
      border-radius: 10px;
      cursor: pointer;
      text-decoration: none;
      font-family: inherit;
      transition: all 0.2s ease;
    }
    .btn-secondary {
      background: rgba(255, 255, 255, 0.05);
      border: 1px solid var(--border);
      color: var(--text);
    }
    .btn-secondary:hover {
      background: rgba(255, 255, 255, 0.09);
      border-color: rgba(255, 255, 255, 0.15);
    }
    .btn-primary {
      background: var(--primary);
      border: 1px solid rgba(59, 130, 246, 0.2);
      color: #fff;
      box-shadow: 0 4px 14px rgba(59, 130, 246, 0.35);
    }
    .btn-primary:hover {
      background: var(--primary-hover);
      box-shadow: 0 4px 20px rgba(59, 130, 246, 0.5);
      transform: translateY(-1px);
    }

    /* Premium upload progress overlay */
    .upload-progress-overlay {
      position: fixed;
      bottom: 24px;
      right: 24px;
      z-index: 1500;
      opacity: 0;
      pointer-events: none;
      transition: opacity 0.3s ease;
    }
    .upload-progress-overlay.active {
      opacity: 1;
      pointer-events: auto;
    }
    .upload-progress-card {
      background: rgba(15, 23, 42, 0.85);
      border: 1px solid rgba(59, 130, 246, 0.3);
      backdrop-filter: blur(16px);
      -webkit-backdrop-filter: blur(16px);
      padding: 16px 20px;
      border-radius: 16px;
      width: 320px;
      box-shadow: 0 10px 30px rgba(0, 0, 0, 0.5);
    }
    .upload-progress-header {
      display: flex;
      justify-content: space-between;
      align-items: center;
      margin-bottom: 12px;
      font-size: 13.5px;
      font-weight: 600;
    }
    .upload-title {
      color: var(--text);
      white-space: nowrap;
      overflow: hidden;
      text-overflow: ellipsis;
      max-width: 220px;
    }
    .upload-percent {
      color: var(--primary);
    }
    .progress-bar-container {
      width: 100%;
      height: 6px;
      background: rgba(255, 255, 255, 0.08);
      border-radius: 3px;
      overflow: hidden;
    }
    .progress-bar-fill {
      height: 100%;
      width: 0%;
      background: linear-gradient(to right, #3B82F6, #60A5FA);
      border-radius: 3px;
      transition: width 0.1s ease;
      box-shadow: 0 0 8px rgba(59, 130, 246, 0.5);
    }

    /* Dynamic full screen Drag Over Upload Indicator Overlay */
    .drag-overlay {
      position: fixed;
      top: 0;
      left: 0;
      right: 0;
      bottom: 0;
      background: rgba(9, 13, 22, 0.8);
      backdrop-filter: blur(12px);
      -webkit-backdrop-filter: blur(12px);
      z-index: 2500;
      display: flex;
      flex-direction: column;
      align-items: center;
      justify-content: center;
      opacity: 0;
      pointer-events: none;
      transition: opacity 0.25s ease;
      border: 3px dashed var(--primary);
      margin: 12px;
      border-radius: 20px;
    }
    .drag-overlay.active {
      opacity: 1;
      pointer-events: auto;
    }
    .drag-overlay-icon {
      width: 80px;
      height: 80px;
      background: rgba(59, 130, 246, 0.1);
      border: 1px solid rgba(59, 130, 246, 0.3);
      border-radius: 50%;
      display: flex;
      align-items: center;
      justify-content: center;
      color: var(--primary);
      margin-bottom: 20px;
      box-shadow: 0 0 40px rgba(59, 130, 246, 0.2);
    }
    .drag-overlay-icon svg {
      width: 36px;
      height: 36px;
    }
    .drag-overlay h2 {
      margin: 0 0 8px 0;
      font-weight: 700;
      color: #fff;
    }
    .drag-overlay p {
      margin: 0;
      color: var(--text-muted);
      font-size: 14.5px;
    }

    /* Premium dynamic Toast Notification */
    .toast-notification {
      position: fixed;
      bottom: 24px;
      left: 50%;
      transform: translateX(-50%) translateY(20px);
      background: rgba(17, 24, 39, 0.85);
      border: 1px solid rgba(59, 130, 246, 0.35);
      backdrop-filter: blur(16px);
      -webkit-backdrop-filter: blur(16px);
      padding: 12px 24px;
      border-radius: 12px;
      font-weight: 600;
      font-size: 13.5px;
      color: #fff;
      display: flex;
      align-items: center;
      gap: 8px;
      box-shadow: 0 10px 25px rgba(0, 0, 0, 0.5);
      opacity: 0;
      pointer-events: none;
      z-index: 2000;
      transition: all 0.3s cubic-bezier(0.175, 0.885, 0.32, 1.275);
    }
    .toast-notification.active {
      transform: translateX(-50%) translateY(0);
      opacity: 1;
    }
    .toast-notification::before {
      content: "✓";
      color: #34D399;
      font-weight: 800;
      font-size: 15px;
    }

    footer {
      text-align: center;
      padding: 40px 24px;
      color: var(--text-muted);
      font-size: 12.5px;
      font-weight: 500;
      letter-spacing: 0.3px;
      border-top: 1px solid rgba(255, 255, 255, 0.03);
      max-width: 1100px;
      margin: 40px auto 0 auto;
    }

    /* Category Section Styling */
    .category-section {
      margin-bottom: 28px;
      border: 1px solid var(--border);
      border-radius: 18px;
      overflow: hidden;
      background: var(--card);
      transition: all 0.3s ease;
    }
    .category-header {
      display: flex;
      align-items: center;
      padding: 14px 20px;
      cursor: pointer;
      gap: 14px;
      border-bottom: 1px solid transparent;
      transition: all 0.2s ease;
      user-select: none;
    }
    .category-section.expanded .category-header {
      border-bottom-color: var(--border);
    }
    .category-header:hover {
      background: rgba(255, 255, 255, 0.02);
    }
    .category-icon {
      width: 40px;
      height: 40px;
      border-radius: 12px;
      display: flex;
      align-items: center;
      justify-content: center;
      flex-shrink: 0;
    }
    .category-icon svg {
      width: 20px;
      height: 20px;
    }
    .category-icon.cat-folders { background: rgba(16, 185, 129, 0.12); color: #10B981; }
    .category-icon.cat-videos { background: rgba(59, 130, 246, 0.12); color: #3B82F6; }
    .category-icon.cat-audio { background: rgba(139, 92, 246, 0.12); color: #8B5CF6; }
    .category-icon.cat-images { background: rgba(236, 72, 153, 0.12); color: #EC4899; }
    .category-icon.cat-documents { background: rgba(239, 68, 68, 0.12); color: #EF4444; }
    .category-icon.cat-others { background: rgba(107, 114, 128, 0.12); color: #6B7280; }
    .category-title {
      font-weight: 700;
      font-size: 15px;
      color: var(--text);
      flex: 1;
    }
    .category-count {
      font-size: 12.5px;
      color: var(--text-muted);
      font-weight: 500;
      background: rgba(255, 255, 255, 0.04);
      padding: 4px 10px;
      border-radius: 20px;
    }
    .category-toggle {
      font-size: 12px;
      color: var(--text-muted);
      transition: transform 0.3s ease;
      width: 20px;
      text-align: center;
    }
    .category-section.collapsed .category-toggle {
      transform: rotate(-90deg);
    }
    .category-items {
      display: flex;
      flex-direction: column;
      gap: 6px;
      padding: 12px 16px;
      transition: all 0.3s ease;
    }
    .category-section.collapsed .category-items {
      display: none;
    }
    .category-empty {
      padding: 8px 0;
      text-align: center;
      color: var(--text-muted);
      font-size: 13px;
      font-style: italic;
    }

    /* Mobile Responsive Optimizations */
    @media (max-width: 640px) {
      .header-content {
        flex-direction: column;
        align-items: flex-start;
      }
      .header-actions {
        align-self: flex-start;
      }
      .toolbar {
        flex-direction: column;
        align-items: stretch;
      }
      .search-wrapper {
        max-width: 100%;
      }
      .toolbar-controls {
        justify-content: space-between;
        margin-top: 4px;
      }
      .items-container.list-mode .item-meta {
        display: none; /* Hide date/size in compressed compact list on mobile */
      }
      .items-container.list-mode .item-actions {
        opacity: 1; /* Keep buttons visible on touch devices */
      }
      .explorer-item {
        padding: 14px !important;
      }
      .modal-card {
        max-height: 90vh;
      }
      .modal-body {
        padding: 16px;
      }
      .modal-footer {
        flex-direction: column-reverse;
        align-items: stretch;
      }
      .modal-footer .btn {
        justify-content: center;
      }
    }
  </style>
</head>
<body>
  <header>
    <div class="header-content">
      <div class="brand-section">
        <div class="logo-container">N</div>
        <h1>ZenFile Portal</h1>
      </div>
      $badgeHtml
    </div>
  </header>
  
  <div class="container">
    <div class="breadcrumbs">$breadcrumbsHtml</div>
    
    <div class="toolbar">
      <div class="search-wrapper">
        <svg class="search-icon" fill="none" stroke="currentColor" viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2.5" d="M21 21l-6-6m2-5a7 7 0 11-14 0 7 7 0 0114 0z"></path></svg>
        <input type="text" id="searchInput" class="search-input" placeholder="${tr['search']}">
      </div>
      
      <div class="view-toggles">
        <button class="toggle-btn" id="viewToggleList" onclick="setViewMode('list')" title="List View">
          <svg fill="none" stroke="currentColor" viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg"><line x1="8" y1="6" x2="21" y2="6"></line><line x1="8" y1="12" x2="21" y2="12"></line><line x1="8" y1="18" x2="21" y2="18"></line><line x1="3" y1="6" x2="3.01" y2="6"></line><line x1="3" y1="12" x2="3.01" y2="12"></line><line x1="3" y1="18" x2="3.01" y2="18"></line></svg>
        </button>
        <button class="toggle-btn" id="viewToggleGrid" onclick="setViewMode('grid')" title="Grid View">
          <svg fill="none" stroke="currentColor" viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg"><rect x="3" y="3" width="7" height="7"></rect><rect x="14" y="3" width="7" height="7"></rect><rect x="14" y="14" width="7" height="7"></rect><rect x="3" y="14" width="7" height="7"></rect></svg>
        </button>
      </div>
    </div>
    
    <div class="items-container grid-mode" id="itemsContainer">
      $listHtml
    </div>

    <div class="empty-state" id="emptyState" style="display: none;">
      <div class="empty-icon">🔍</div>
      <h3 id="emptySearchTitle">${tr['emptySearch']}</h3>
      <p id="emptySearchDesc">${tr['emptyDesc']}</p>
    </div>
  </div>

  <!-- Floating Preview Drawer Modal -->
  <div class="modal-overlay" id="previewModal" onclick="closeModal(event)">
    <div class="modal-card" onclick="event.stopPropagation()">
      <button class="modal-close" onclick="closeModal(event)" title="Close Modal">
        <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5"><line x1="18" y1="6" x2="6" y2="18"></line><line x1="6" y1="6" x2="18" y2="18"></line></svg>
      </button>
      
      <div class="modal-header">
        <div class="modal-icon-wrapper" id="modalIcon"></div>
        <div class="modal-title-wrapper">
          <h3 id="modalTitle">${tr['fileName']}</h3>
          <p id="modalMeta">${tr['fileMeta']}</p>
        </div>
      </div>
      
      <div class="modal-body" id="modalBody">
        <!-- Preview filled dynamically -->
      </div>
      
      <div class="modal-footer">
        <button class="btn btn-secondary" id="modalCopyBtn" onclick="copyModalLink()">
          <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round" style="width:14px; height:14px; margin-right:8px;"><rect x="9" y="9" width="13" height="13" rx="2" ry="2"></rect><path d="M5 15H4a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h9a2 2 0 0 1 2 2v1"></path></svg>
          <span id="modalCopyBtnText">${tr['copyLink']}</span>
        </button>
        <a class="btn btn-primary" id="modalDownloadBtn" href="" download>
          <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round" style="width:14px; height:14px; margin-right:8px;"><path d="M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4"></path><polyline points="7 10 12 15 17 10"></polyline><line x1="12" y1="15" x2="12" y2="3"></line></svg>
          <span id="modalDownloadBtnText">${tr['download']}</span>
        </a>
      </div>
    </div>
  </div>

  <!-- Hidden File Input for high-speed selector upload -->
  <input type="file" id="fileInputElement" multiple style="display: none;" onchange="handleFileSelection(this)">

  <!-- Floating Drag & Drop Fullscreen Overlay -->
  <div class="drag-overlay" id="dragOverlay">
    <div class="drag-overlay-icon">
      <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><path d="M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4"></path><polyline points="17 8 12 3 7 8"></polyline><line x1="12" y1="3" x2="12" y2="15"></line></svg>
    </div>
    <h2 id="dropTitle">${tr['dropTitle']}</h2>
    <p id="dropDesc">${tr['dropDesc']}</p>
  </div>

  <!-- Floating Progress indicator card -->
  <div class="upload-progress-overlay" id="uploadOverlay">
    <div class="upload-progress-card">
      <div class="upload-progress-header">
        <span class="upload-title" id="uploadTitle">Uploading file...</span>
        <span class="upload-percent" id="uploadPercent">0%</span>
      </div>
      <div class="progress-bar-container">
        <div class="progress-bar-fill" id="uploadBar"></div>
      </div>
    </div>
  </div>

  <footer>
    <span id="footerText">${tr['footer']}</span>
  </footer>

  <script>
    // Translation dictionary (lang is set from Dart)
    const lang = '${lang}';
    const L = {
      en: { search: 'Search files & folders...', upload: 'Upload', dropTitle: 'Drop files here to upload', dropDesc: 'Your files will be uploaded instantly to this shared folder', emptySearch: 'No items match your search', emptyDesc: 'Check the spelling or try a different search term', copyLink: 'Copy Link', download: 'Download', uploading: 'Uploading', uploadSuccess: 'Upload completed successfully!', uploadFailed: 'Failed to upload', previewUnsupported: 'Preview is not supported for this file type', previewDownload: 'Click Download below to save it on your system', footer: 'Securely sharing and streaming files via ZenFile', parentDir: 'Parent Directory', goUp: 'Go up one level', itemsCount: 'items', linkCopied: 'Link copied to clipboard!', copyFailed: 'Failed to copy link', loadingPreview: 'Loading preview...', previewError: 'Failed to stream document. You can still download it directly.', catFolders: 'Folders', catVideos: 'Videos', catAudio: 'Audio', catImages: 'Images', catDocuments: 'Documents', catOthers: 'Others' },
      zh: { search: '\u641c\u7d22\u6587\u4ef6\u548c\u6587\u4ef6\u5939...', upload: '\u4e0a\u4f20', dropTitle: '\u62d6\u62fd\u6587\u4ef6\u5230\u6b64\u5904\u4e0a\u4f20', dropDesc: '\u6587\u4ef6\u5c06\u7acb\u5373\u4e0a\u4f20\u5230\u6b64\u5171\u4eab\u6587\u4ef6\u5939', emptySearch: '\u6ca1\u6709\u5339\u914d\u7684\u9879\u76ee', emptyDesc: '\u68c0\u67e5\u62fc\u5199\u6216\u5c1d\u8bd5\u4e0d\u540c\u7684\u641c\u7d22\u8bcd', copyLink: '\u590d\u5236\u94fe\u63a5', download: '\u4e0b\u8f7d', uploading: '\u6b63\u5728\u4e0a\u4f20', uploadSuccess: '\u4e0a\u4f20\u6210\u529f\uff01', uploadFailed: '\u4e0a\u4f20\u5931\u8d25', previewUnsupported: '\u4e0d\u652f\u6301\u9884\u89c8\u6b64\u6587\u4ef6\u7c7b\u578b', previewDownload: '\u70b9\u51fb\u4e0b\u65b9\u4e0b\u8f7d\u6309\u94ae\u4fdd\u5b58\u5230\u60a8\u7684\u8bbe\u5907', footer: '\u901a\u8fc7 ZenFile \u5b89\u5168\u5171\u4eab\u548c\u6d41\u5f0f\u4f20\u8f93\u6587\u4ef6', parentDir: '\u4e0a\u7ea7\u76ee\u5f55', goUp: '\u8fd4\u56de\u4e0a\u4e00\u7ea7', itemsCount: '\u4e2a\u9879\u76ee', linkCopied: '\u94fe\u63a5\u5df2\u590d\u5236\u5230\u526a\u8d34\u677f\uff01', copyFailed: '\u590d\u5236\u94fe\u63a5\u5931\u8d25', loadingPreview: '\u6b63\u5728\u52a0\u8f7d\u9884\u89c8...', previewError: '\u65e0\u6cd5\u6d41\u5f0f\u4f20\u8f93\u6587\u6863\u3002\u60a8\u4ecd\u7136\u53ef\u4ee5\u76f4\u63a5\u4e0b\u8f7d\u3002', catFolders: '\u6587\u4ef6\u5939', catVideos: '\u89c6\u9891', catAudio: '\u97f3\u9891', catImages: '\u56fe\u7247', catDocuments: '\u6587\u6863', catOthers: '\u5176\u4ed6' },
      zh_TW: { search: '\u641c\u5c0b\u6a94\u6848\u548c\u8cc7\u6599\u593e...', upload: '\u4e0a\u50b3', dropTitle: '\u62d6\u66f3\u6a94\u6848\u5230\u6b64\u8655\u4e0a\u50b3', dropDesc: '\u6a94\u6848\u5c07\u7acb\u5373\u4e0a\u50b3\u5230\u6b64\u5171\u4eab\u8cc7\u6599\u593e', emptySearch: '\u6c92\u6709\u5339\u914d\u7684\u9805\u76ee', emptyDesc: '\u6aa2\u67e5\u62fc\u5beb\u6216\u5617\u8a66\u4e0d\u540c\u7684\u641c\u5c0b\u8a5e', copyLink: '\u8907\u88fd\u9023\u7d50', download: '\u4e0b\u8f09', uploading: '\u6b63\u5728\u4e0a\u50b3', uploadSuccess: '\u4e0a\u50b3\u6210\u529f\uff01', uploadFailed: '\u4e0a\u50b3\u5931\u6557', previewUnsupported: '\u4e0d\u652f\u63f4\u9810\u89bd\u6b64\u6a94\u6848\u985e\u578b', previewDownload: '\u9ede\u64ca\u4e0b\u65b9\u4e0b\u8f09\u6309\u9215\u5132\u5b58\u5230\u60a8\u7684\u88dd\u7f6e', footer: '\u900f\u904e ZenFile \u5b89\u5168\u5171\u4eab\u548c\u4e32\u6d41\u50b3\u8f38\u6a94\u6848', parentDir: '\u4e0a\u7d1a\u76ee\u9304', goUp: '\u8fd4\u56de\u4e0a\u4e00\u7d1a', itemsCount: '\u500b\u9805\u76ee', linkCopied: '\u9023\u7d50\u5df2\u8907\u88fd\u5230\u526a\u8cbc\u7c3f\uff01', copyFailed: '\u8907\u88fd\u9023\u7d50\u5931\u6557', loadingPreview: '\u6b63\u5728\u8f09\u5165\u9810\u89bd...', previewError: '\u7121\u6cd5\u4e32\u6d41\u50b3\u8f38\u6587\u4ef6\u3002\u60a8\u4ecd\u7136\u53ef\u4ee5\u76f4\u63a5\u4e0b\u8f09\u3002', catFolders: '\u8cc7\u6599\u593e', catVideos: '\u5f71\u7247', catAudio: '\u97f3\u8a0a', catImages: '\u5716\u7247', catDocuments: '\u6587\u4ef6', catOthers: '\u5176\u4ed6' },
      ja: { search: '\u30d5\u30a1\u30a4\u30eb\u3068\u30d5\u30a9\u30eb\u30c0\u3092\u691c\u7d22...', upload: '\u30a2\u30c3\u30d7\u30ed\u30fc\u30c9', dropTitle: '\u30d5\u30a1\u30a4\u30eb\u3092\u3053\u3053\u306b\u30c9\u30e9\u30c3\u30b0\u3057\u3066\u30a2\u30c3\u30d7\u30ed\u30fc\u30c9', dropDesc: '\u30d5\u30a1\u30a4\u30eb\u306f\u3053\u306e\u5171\u6709\u30d5\u30a9\u30eb\u30c0\u306b\u5373\u5ea7\u306b\u30a2\u30c3\u30d7\u30ed\u30fc\u30c9\u3055\u308c\u307e\u3059', emptySearch: '\u4e00\u81f4\u3059\u308b\u9805\u76ee\u304c\u3042\u308a\u307e\u305b\u3093', emptyDesc: '\u30b9\u30da\u30eb\u3092\u78ba\u8a8d\u3059\u308b\u304b\u3001\u5225\u306e\u691c\u7d22\u8a9e\u3092\u8a66\u3057\u3066\u304f\u3060\u3055\u3044', copyLink: '\u30ea\u30f3\u30af\u3092\u30b3\u30d4\u30fc', download: '\u30c0\u30a6\u30f3\u30ed\u30fc\u30c9', uploading: '\u30a2\u30c3\u30d7\u30ed\u30fc\u30c9\u4e2d', uploadSuccess: '\u30a2\u30c3\u30d7\u30ed\u30fc\u30c9\u304c\u5b8c\u4e86\u3057\u307e\u3057\u305f\uff01', uploadFailed: '\u30a2\u30c3\u30d7\u30ed\u30fc\u30c9\u306b\u5931\u6557\u3057\u307e\u3057\u305f', previewUnsupported: '\u3053\u306e\u30d5\u30a1\u30a4\u30eb\u30bf\u30a4\u30d7\u306e\u30d7\u30ec\u30d3\u30e5\u30fc\u306f\u30b5\u30dd\u30fc\u30c8\u3055\u308c\u3066\u3044\u307e\u305b\u3093', previewDownload: '\u4e0b\u306e\u30c0\u30a6\u30f3\u30ed\u30fc\u30c9\u30dc\u30bf\u30f3\u3092\u30af\u30ea\u30c3\u30af\u3057\u3066\u30c7\u30d0\u30a4\u30b9\u306b\u4fdd\u5b58', footer: 'ZenFile \u3092\u4ecb\u3057\u3066\u30d5\u30a1\u30a4\u30eb\u3092\u5b89\u5168\u306b\u5171\u6709\u304a\u3088\u3073\u30b9\u30c8\u30ea\u30fc\u30df\u30f3\u30b0', parentDir: '\u89aa\u30c7\u30a3\u30ec\u30af\u30c8\u30ea', goUp: '1\u3064\u4e0a\u306e\u968e\u5c64\u306b\u623b\u308b', itemsCount: '\u9805\u76ee', linkCopied: '\u30ea\u30f3\u30af\u3092\u30af\u30ea\u30c3\u30d7\u30dc\u30fc\u30c9\u306b\u30b3\u30d4\u30fc\u3057\u307e\u3057\u305f\uff01', copyFailed: '\u30ea\u30f3\u30af\u306e\u30b3\u30d4\u30fc\u306b\u5931\u6557\u3057\u307e\u3057\u305f', loadingPreview: '\u30d7\u30ec\u30d3\u30e5\u30fc\u3092\u8aad\u307f\u8fbc\u307f\u4e2d...', previewError: '\u30c9\u30ad\u30e5\u30e1\u30f3\u30c8\u3092\u30b9\u30c8\u30ea\u30fc\u30df\u30f3\u30b0\u3067\u304d\u307e\u305b\u3093\u3002\u76f4\u63a5\u30c0\u30a6\u30f3\u30ed\u30fc\u30c9\u3067\u304d\u307e\u3059\u3002', catFolders: '\u30d5\u30a9\u30eb\u30c0', catVideos: '\u52d5\u753b', catAudio: '\u30aa\u30fc\u30c7\u30a3\u30aa', catImages: '\u753b\u50cf', catDocuments: '\u30c9\u30ad\u30e5\u30e1\u30f3\u30c8', catOthers: '\u305d\u306e\u4ed6' },
      ko: { search: '\ud30c\uc77c \ubc0f \ud3f4\ub354 \uac80\uc0c9...', upload: '\uc5c5\ub85c\ub4dc', dropTitle: '\ud30c\uc77c\uc744 \uc5ec\uae30\uc5d0 \ub4dc\ub86d\ud558\uc5ec \uc5c5\ub85c\ub4dc', dropDesc: '\ud30c\uc77c\uc774 \uc774 \uacf5\uc720 \ud3f4\ub354\uc5d0 \uc989\uc2dc \uc5c5\ub85c\ub4dc\ub429\ub2c8\ub2e4', emptySearch: '\uc77c\uce58\ud558\ub294 \ud56d\ubaa9\uc774 \uc5c6\uc2b5\ub2c8\ub2e4', emptyDesc: '\ucca0\uc790\ub97c \ud655\uc778\ud558거\ub098 \ub2e4\ub978 \uac80\uc0c9\uc5b4\ub97c \uc2dc\ub3c4\ud558\uc138\uc694', copyLink: '\ub9c1\ud06c \ubcf5\uc0ac', download: '\ub2e4\uc6b4\ub85c\ub4dc', uploading: '\uc5c5\ub85c\ub4dc \uc911', uploadSuccess: '\uc5c5\ub85c\ub4dc\uac00 \uc644\ub8cc\ub418\uc5c8\uc2b5\ub2c8\ub2e4!', uploadFailed: '\uc5c5\ub85c\ub4dc\uc5d0 \uc2e4\ud328\ud588\uc2b5\ub2c8\ub2e4', previewUnsupported: '\uc774 \ud30c\uc77c \ud615\uc2dd\uc758 \ubbf8\ub9ac\ubcf4\uae30\ub294 \uc9c0\uc6d0\ub418\uc9c0 \uc54a\uc2b5\ub2c8\ub2e4', previewDownload: '\uc544\ub798\uc758 \ub2e4\uc6b4\ub85c\ub4dc\ub97c \ud074\ub9ad\ud558\uc5ec \uae30\uae30\uc5d0 \uc800\uc7a5', footer: 'ZenFile\uc744 \ud1b5\ud574 \ud30c\uc77c\uc744 \uc548\uc804\ud558\uac8c \uacf5\uc720 \ubc0f \uc2a4\ud2b8\ub9ac\ubc0d', parentDir: '\uc0c1\uc704 \ub514\ub809\ud1a0\ub9ac', goUp: '\ud55c \ub2e8\uacc4 \uc704\ub85c \uc774\ub3d9', itemsCount: '\uac1c \ud56d\ubaa9', linkCopied: '\ub9c1\ud06c\uac00 \ud074\ub9bd\ubcf4\ub4dc\uc5d0 \ubcf5\uc0ac\ub418\uc5c8\uc2b5\ub2c8\ub2e4!', copyFailed: '\ub9c1\ud06c \ubcf5\uc0ac \uc2e4\ud328', loadingPreview: '\ubbf8\ub9ac\ubcf4\uae30 \ub85c\ub4dc \uc911...', previewError: '\ubb38\uc11c\ub97c \uc2a4\ud2b8\ub9ac\ubc0d\ud560 \uc218 \uc5c6\uc2b5\ub2c8\ub2e4. \uc9c1\uc811 \ub2e4\uc6b4\ub85c\ub4dc\ud560 \uc218 \uc788\uc2b5\ub2c8\ub2e4.', catFolders: '\ud3f4\ub354', catVideos: '\ub3d9\uc601\uc0c1', catAudio: '\uc624\ub514\uc624', catImages: '\uc774\ubbf8\uc9c0', catDocuments: '\ubb38\uc11c', catOthers: '\uae30\ud0c0' },
      de: { search: 'Dateien & Ordner suchen...', upload: 'Hochladen', dropTitle: 'Dateien hier ablegen zum Hochladen', dropDesc: 'Ihre Dateien werden sofort in diesen freigegebenen Ordner hochgeladen', emptySearch: 'Keine Elemente entsprechen Ihrer Suche', emptyDesc: 'Uberprufen Sie die Schreibweise oder versuchen Sie einen anderen Suchbegriff', copyLink: 'Link kopieren', download: 'Herunterladen', uploading: 'Hochladen', uploadSuccess: 'Upload erfolgreich abgeschlossen!', uploadFailed: 'Hochladen fehlgeschlagen', previewUnsupported: 'Vorschau fur diesen Dateityp nicht unterstutzt', previewDownload: 'Klicken Sie unten auf Herunterladen, um es auf Ihrem Gerat zu speichern', footer: 'Sicheres Teilen und Streamen von Dateien uber ZenFile', parentDir: 'Ubergeordnetes Verzeichnis', goUp: 'Eine Ebene nach oben gehen', itemsCount: 'Elemente', linkCopied: 'Link in die Zwischenablage kopiert!', copyFailed: 'Link konnte nicht kopiert werden', loadingPreview: 'Vorschau wird geladen...', previewError: 'Dokument kann nicht gestreamt werden. Sie konnen es direkt herunterladen.', catFolders: 'Ordner', catVideos: 'Videos', catAudio: 'Audio', catImages: 'Bilder', catDocuments: 'Dokumente', catOthers: 'Sonstiges' },
      fr: { search: 'Rechercher des fichiers et dossiers...', upload: 'Telecharger', dropTitle: 'Deposez les fichiers ici pour les telecharger', dropDesc: 'Vos fichiers seront instantanement telecharges dans ce dossier partage', emptySearch: 'Aucun element ne correspond a votre recherche', emptyDesc: 'Verifiez l\u2019orthographe ou essayez un terme de recherche different', copyLink: 'Copier le lien', download: 'Telecharger', uploading: 'Telechargement', uploadSuccess: 'Telechargement termine avec succes!', uploadFailed: 'Echec du telechargement', previewUnsupported: 'L\u2019aper\u00e7u n\u2019est pas pris en charge pour ce type de fichier', previewDownload: 'Cliquez sur Telecharger ci-dessous pour l\u2019enregistrer sur votre appareil', footer: 'Partage et diffusion securises de fichiers via ZenFile', parentDir: 'Repertoire parent', goUp: 'Remonter d\u2019un niveau', itemsCount: 'elements', linkCopied: 'Lien copie dans le presse-papiers!', copyFailed: 'Echec de la copie du lien', loadingPreview: 'Chargement de l\u2019aper\u00e7u...', previewError: 'Impossible de diffuser le document. Vous pouvez toujours le telecharger directement.', catFolders: 'Dossiers', catVideos: 'Videos', catAudio: 'Audio', catImages: 'Images', catDocuments: 'Documents', catOthers: 'Autres' },
      es: { search: 'Buscar archivos y carpetas...', upload: 'Subir', dropTitle: 'Suelte los archivos aqui para subirlos', dropDesc: 'Sus archivos se subiran instantaneamente a esta carpeta compartida', emptySearch: 'Ningun elemento coincide con su busqueda', emptyDesc: 'Verifique la ortografia o intente un termino de busqueda diferente', copyLink: 'Copiar enlace', download: 'Descargar', uploading: 'Subiendo', uploadSuccess: 'Carga completada con exito!', uploadFailed: 'Error al subir', previewUnsupported: 'La vista previa no es compatible con este tipo de archivo', previewDownload: 'Haga clic en Descargar a continuacion para guardarlo en su dispositivo', footer: 'Compartir y transmitir archivos de forma segura a traves de ZenFile', parentDir: 'Directorio principal', goUp: 'Subir un nivel', itemsCount: 'elementos', linkCopied: 'Enlace copiado al portapapeles!', copyFailed: 'Error al copiar el enlace', loadingPreview: 'Cargando vista previa...', previewError: 'No se puede transmitir el documento. Aun puede descargarlo directamente.', catFolders: 'Carpetas', catVideos: 'Videos', catAudio: 'Audio', catImages: 'Imagenes', catDocuments: 'Documentos', catOthers: 'Otros' },
      ru: { search: '\u041f\u043e\u0438\u0441\u043a \u0444\u0430\u0439\u043b\u043e\u0432 \u0438 \u043f\u0430\u043f\u043e\u043a...', upload: '\u0417\u0430\u0433\u0440\u0443\u0437\u0438\u0442\u044c', dropTitle: '\u041f\u0435\u0440\u0435\u0442\u0430\u0449\u0438\u0442\u0435 \u0444\u0430\u0439\u043b\u044b \u0441\u044e\u0434\u0430 \u0434\u043b\u044f \u0437\u0430\u0433\u0440\u0443\u0437\u043a\u0438', dropDesc: '\u0412\u0430\u0448\u0438 \u0444\u0430\u0439\u043b\u044b \u0431\u0443\u0434\u0443\u0442 \u043c\u0433\u043d\u043e\u0432\u0435\u043d\u043d\u043e \u0437\u0430\u0433\u0440\u0443\u0436\u0435\u043d\u044b \u0432 \u044d\u0442\u0443 \u043e\u0431\u0449\u0443\u044e \u043f\u0430\u043f\u043a\u0443', emptySearch: '\u041d\u0435\u0442 \u044d\u043b\u0435\u043c\u0435\u043d\u0442\u043e\u0432, \u0441\u043e\u043e\u0442\u0432\u0435\u0442\u0441\u0442\u0432\u0443\u044e\u0449\u0438\u0445 \u0432\u0430\u0448\u0435\u043c\u0443 \u0437\u0430\u043f\u0440\u043e\u0441\u0443', emptyDesc: '\u041f\u0440\u043e\u0432\u0435\u0440\u044c\u0442\u0435 \u043f\u0440\u0430\u0432\u043e\u043f\u0438\u0441\u0430\u043d\u0438\u0435 \u0438\u043b\u0438 \u043f\u043e\u043f\u0440\u043e\u0431\u0443\u0439\u0442\u0435 \u0434\u0440\u0443\u0433\u043e\u0439 \u043f\u043e\u0438\u0441\u043a\u043e\u0432\u044b\u0439 \u0437\u0430\u043f\u0440\u043e\u0441', copyLink: '\u041a\u043e\u043f\u0438\u0440\u043e\u0432\u0430\u0442\u044c \u0441\u0441\u044b\u043b\u043a\u0443', download: '\u0421\u043a\u0430\u0447\u0430\u0442\u044c', uploading: '\u0417\u0430\u0433\u0440\u0443\u0437\u043a\u0430', uploadSuccess: '\u0417\u0430\u0433\u0440\u0443\u0437\u043a\u0430 \u0443\u0441\u043f\u0435\u0448\u043d\u043e \u0437\u0430\u0432\u0435\u0440\u0448\u0435\u043d\u0430!', uploadFailed: '\u041e\u0448\u0438\u0431\u043a\u0430 \u0437\u0430\u0433\u0440\u0443\u0437\u043a\u0438', previewUnsupported: '\u041f\u0440\u0435\u0434\u043f\u0440\u043e\u0441\u043c\u043e\u0442\u0440 \u043d\u0435 \u043f\u043e\u0434\u0434\u0435\u0440\u0436\u0438\u0432\u0430\u0435\u0442\u0441\u044f \u0434\u043b\u044f \u044d\u0442\u043e\u0433\u043e \u0442\u0438\u043f\u0430 \u0444\u0430\u0439\u043b\u0430', previewDownload: '\u041d\u0430\u0436\u043c\u0438\u0442\u0435 \u0421\u043a\u0430\u0447\u0430\u0442\u044c \u043d\u0438\u0436\u0435, \u0447\u0442\u0e43\u0431\u044b \u0441\u043e\u0445\u0440\u0430\u043d\u0438\u0442\u044c \u043d\u0430 \u0432\u0430\u0448\u0435\u043c \u0443\u0441\u0442\u0440\u043e\u0439\u0441\u0442\u0432\u0435', footer: '\u0411\u0435\u0437\u043e\u043f\u0430\u0441\u043d\u044b\u0439 \u043e\u0431\u043c\u0435\u043d \u0444\u0430\u0439\u043b\u0430\u043c\u0438 \u0438 \u043f\u043e\u0442\u043e\u043a\u043e\u0432\u0430\u044f \u043f\u0435\u0440\u0435\u0434\u0430\u0447\u0430 \u0447\u0435\u0440\u0435\u0437 ZenFile', parentDir: '\u0420\u043e\u0434\u0438\u0442\u0435\u043b\u044c\u0441\u043a\u0438\u0439 \u043a\u0430\u0442\u0430\u043b\u043e\u0433', goUp: '\u041f\u0435\u0440\u0435\u0439\u0442\u0438 \u043d\u0430 \u0443\u0440\u043e\u0432\u0435\u043d\u044c \u0432\u0432\u0435\u0440\u0445', itemsCount: '\u044d\u043b\u0435\u043c\u0435\u043d\u0442\u043e\u0432', linkCopied: '\u0421\u0441\u044b\u043b\u043a\u0430 \u0441\u043a\u043e\u043f\u0438\u0440\u043e\u0432\u0430\u043d\u0430 \u0432 \u0431\u0443\u0444\u0435\u0440 \u043e\u0431\u043c\u0435\u043d\u0430!', copyFailed: '\u041d\u0435 \u0443\u0434\u0430\u043b\u043e\u0441\u044c \u043a\u043e\u043f\u0438\u0440\u043e\u0432\u0430\u0442\u044c \u0441\u0441\u044b\u043b\u043a\u0443', loadingPreview: '\u0417\u0430\u0433\u0440\u0443\u0437\u043a\u0430 \u043f\u0440\u0435\u0434\u043f\u0440\u043e\u0441\u043c\u043e\u0442\u0440\u0430...', previewError: '\u041d\u0435 \u0443\u0434\u0430\u043b\u043e\u0441\u044c \u0442\u0440\u0430\u043d\u0441\u043b\u0438\u0440\u043e\u0432\u0430\u0442\u044c \u0434\u043e\u043a\u0443\u043c\u0435\u043d\u0442. \u0412\u044b \u043c\u043e\u0436\u0435\u0442\u0435 \u0441\u043a\u0430\u0447\u0430\u0442\u044c \u0435\u0433\u043e \u043d\u0430\u043f\u0440\u044f\u043c\u0443\u044e.', catFolders: '\u041f\u0430\u043f\u043a\u0438', catVideos: '\u0412\u0438\u0434\u0435\u043e', catAudio: '\u0410\u0443\u0434\u0438\u043e', catImages: '\u0418\u0437\u043e\u0431\u0440\u0430\u0436\u0435\u043d\u0438\u044f', catDocuments: '\u0414\u043e\u043a\u0443\u043c\u0435\u043d\u0442\u044b', catOthers: '\u0414\u0440\u0443\u0433\u043e\u0435' },
      ar: { search: '\u0627\u0644\u0628\u062d\u062b \u0639\u0646 \u0627\u0644\u0645\u0644\u0641\u0627\u062a \u0648\u0627\u0644\u0645\u062c\u0644\u062f\u0627\u062a...', upload: '\u0631\u0641\u0639', dropTitle: '\u0623\u0633\u062d\u0628 \u0627\u0644\u0645\u0644\u0641\u0627\u062a \u0647\u0646\u0627 \u0644\u0644\u0631\u0641\u0639', dropDesc: '\u0633\u062a\u0645 \u0631\u0641\u0639 \u0645\u0644\u0641\u0627\u062a\u0643 \u0641\u0648\u0631\u0627\u064b \u0625\u0644\u0649 \u0647\u0630\u0627 \u0627\u0644\u0645\u062c\u0644\u062f \u0627\u0644\u0645\u0634\u062a\u0631\u0643', emptySearch: '\u0644\u0627 \u062a\u0648\u062c\u062f \u0639\u0646\u0627\u0635\u0631 \u062a\u0637\u0627\u0628\u0642 \u0628\u062d\u062b\u0643', emptyDesc: '\u062a\u062d\u0642\u0642 \u0645\u0646 \u0627\u0644\u0625\u0645\u0644\u0627\u0621 \u0623\u0648 \u062c\u0631\u0628 \u0645\u0635\u0637\u062d\u0627\u062d \u0622\u062e\u0631', copyLink: '\u0646\u0633\u062e \u0627\u0644\u0631\u0627\u0628\u0637', download: '\u062a\u062d\u0645\u064a\u0644', uploading: '\u062c\u0627\u0631\u064a \u0627\u0644\u0631\u0641\u0639', uploadSuccess: '\u0627\u0643\u062a\u0645\u0644 \u0627\u0644\u0631\u0641\u0639 \u0628\u0646\u062c\u0627\u062d!', uploadFailed: '\u0641\u0634\u0644 \u0627\u0644\u0631\u0641\u0639', previewUnsupported: '\u0627\u0644\u0645\u0639\u0627\u064a\u0646\u0629 \u063a\u064a\u0631 \u0645\u062f\u0639\u0648\u0645\u0629 \u0644\u0647\u0630\u0627 \u0627\u0644\u0646\u0648\u0639 \u0645\u0646 \u0627\u0644\u0645\u0644\u0641', previewDownload: '\u0627\u0646\u0642\u0631 \u0639\u0644\u0649 \u062a\u062d\u0645\u064a\u0644 \u0623\u062f\u0646\u0627\u0647 \u0644\u062d\u0641\u0638\u0647 \u0639\u0644\u0649 \u062c\u0647\u0627\u0632\u0643', footer: '\u0645\u0634\u0627\u0631\u0643\u0629 \u0648\u0628\u062b \u0627\u0644\u0645\u0644\u0641\u0627\u062a \u0628\u0623\u0645\u0627\u0646 \u0639\u0628\u0631 ZenFile', parentDir: '\u0627\u0644\u062f\u0644\u064a\u0644 \u0627\u0644\u0623\u0635\u0644\u064a', goUp: '\u0627\u0644\u0627\u0646\u062a\u0642\u0627\u0644 \u0625\u0644\u0649 \u0627\u0644\u0645\u0633\u062a\u0648\u0649 \u0627\u0644\u0623\u0639\u0644\u0649', itemsCount: '\u0639\u0646\u0627\u0635\u0631', linkCopied: '\u062a\u0645 \u0646\u0633\u062e \u0627\u0644\u0631\u0627\u0628\u0637 \u0625\u0644\u0649 \u0627\u0644\u062d\u0627\u0641\u0638\u0629!', copyFailed: '\u0641\u0634\u0644 \u0646\u0633\u062e \u0627\u0644\u0631\u0627\u0628\u0637', loadingPreview: '\u062c\u0627\u0631\u064a \u062a\u062d\u0645\u064a\u0644 \u0627\u0644\u0645\u0639\u0627\u064a\u0646\u0629...', previewError: '\u062a\u0639\u0630\u0631 \u0628\u062b \u0627\u0644\u0645\u0633\u062a\u0646\u062f. \u064a\u0645\u0643\u0646\u0643 \u062a\u062d\u0645\u064a\u0644\u0647 \u0645\u0628\u0627\u0634\u0631\u0629.', catFolders: '\u0645\u062c\u0644\u062f\u0627\u062a', catVideos: '\u0645\u0642\u0627\u0637\u0639 \u0627\u0644\u0641\u064a\u062f\u064a\u0648', catAudio: '\u0635\u0648\u062a', catImages: '\u0635\u0648\u0631', catDocuments: '\u0645\u0633\u062a\u0646\u062f\u0627\u062a', catOthers: '\u0623\u062e\u0631\u0649' },
    };
    const t = L[lang] || L['en'];

    function toggleCategory(catKey) {
      const section = document.getElementById('cat-section-' + catKey);
      if (section) {
        section.classList.toggle('collapsed');
      }
    }

    // Get DOM elements and set localized texts
    const searchInput = document.getElementById('searchInput');
    if (searchInput) searchInput.placeholder = t.search;

    // Search Filtering logic with category support
    if (searchInput) {
    searchInput.addEventListener('input', (e) => {
      const query = e.target.value.toLowerCase().trim();
      const items = document.querySelectorAll('.explorer-item:not(.parent-dir)');
      const sections = document.querySelectorAll('.category-section');
      let visibleCount = 0;
      
      items.forEach(item => {
        const name = item.getAttribute('data-name').toLowerCase();
        if (name.includes(query)) {
          item.style.display = '';
          visibleCount++;
        } else {
          item.style.display = 'none';
        }
      });
      
      // Show/hide category sections based on visible items
      sections.forEach(section => {
        const catItems = section.querySelector('.category-items');
        if (catItems) {
          let hasVisible = false;
          catItems.querySelectorAll('.explorer-item').forEach(child => {
            if (child.style.display !== 'none') hasVisible = true;
          });
          if (query && !hasVisible) {
            section.style.display = 'none';
          } else {
            section.style.display = '';
          }
        }
      });
      
      const emptyState = document.getElementById('emptyState');
      if (emptyState) {
        if (visibleCount === 0 && items.length > 0) {
          emptyState.style.display = 'flex';
        } else {
          emptyState.style.display = 'none';
        }
      }
    });
    } // end if (searchInput)

    // List vs Grid View Toggle logic

    function setViewMode(mode) {
      const ic = document.getElementById('itemsContainer');
      const gl = document.getElementById('viewToggleGrid');
      const ll = document.getElementById('viewToggleList');
      if (!ic || !gl || !ll) return;
      if (mode === 'grid') {
        ic.classList.remove('list-mode');
        ic.classList.add('grid-mode');
        gl.classList.add('active');
        ll.classList.remove('active');
      } else {
        ic.classList.remove('grid-mode');
        ic.classList.add('list-mode');
        ll.classList.add('active');
        gl.classList.remove('active');
      }
      try {
        localStorage.setItem('nfile-view-mode', mode);
      } catch (e) { /* localStorage may be disabled */ }
    }

    // Default view is list
    let savedMode = 'list';
    try {
      savedMode = localStorage.getItem('nfile-view-mode') || 'list';
    } catch (e) { /* localStorage may be disabled */ }
    setViewMode(savedMode);

    // File Upload triggering and selection
    function triggerFileInput() {
      const input = document.getElementById('fileInputElement');
      if (input) input.click();
    }

    async function handleFileSelection(input) {
      const files = input.files;
      if (files.length === 0) return;
      
      const overlay = document.getElementById('uploadOverlay');
      const title = document.getElementById('uploadTitle');
      const percent = document.getElementById('uploadPercent');
      const bar = document.getElementById('uploadBar');
      
      if (overlay) overlay.classList.add('active');
      
      for (let i = 0; i < files.length; i++) {
        const file = files[i];
        if (title) title.textContent = t.uploading + `: \${file.name}...`;
        if (percent) percent.textContent = '0%';
        if (bar) bar.style.width = '0%';
        
        try {
          await uploadSingleFile(file, (p) => {
            if (percent) percent.textContent = `\${p}%`;
            if (bar) bar.style.width = `\${p}%`;
          });
        } catch (err) {
          showToast(t.uploadFailed + `: \${file.name}`);
          console.error(err);
        }
      }
      
      if (overlay) overlay.classList.remove('active');
      showToast(t.uploadSuccess);
      setTimeout(() => {
        window.location.reload();
      }, 800);
    }

    function uploadSingleFile(file, onProgress) {
      return new Promise((resolve, reject) => {
        const xhr = new XMLHttpRequest();
        xhr.open('POST', window.location.pathname, true);
        xhr.setRequestHeader('x-file-name', encodeURIComponent(file.name));
        
        xhr.upload.onprogress = (e) => {
          if (e.lengthComputable) {
            const p = Math.round((e.loaded / e.total) * 100);
            onProgress(p);
          }
        };
        
        xhr.onload = () => {
          if (xhr.status >= 200 && xhr.status < 300) {
            resolve();
          } else {
            reject(new Error(xhr.responseText || 'Upload failed'));
          }
        };
        
        xhr.onerror = () => reject(new Error('Network error'));
        xhr.send(file);
      });
    }

    // Drag & Drop event bindings
    const dragOverlay = document.getElementById('dragOverlay');
    let dragCounter = 0;

    window.addEventListener('dragenter', (e) => {
      e.preventDefault();
      dragCounter++;
      if (dragOverlay) dragOverlay.classList.add('active');
    });

    window.addEventListener('dragleave', (e) => {
      e.preventDefault();
      dragCounter--;
      if (dragCounter === 0) {
        if (dragOverlay) dragOverlay.classList.remove('active');
      }
    });

    window.addEventListener('dragover', (e) => {
      e.preventDefault();
    });

    window.addEventListener('drop', (e) => {
      e.preventDefault();
      dragCounter = 0;
      if (dragOverlay) dragOverlay.classList.remove('active');
      
      const files = e.dataTransfer.files;
      if (files.length > 0) {
        const input = document.getElementById('fileInputElement');
        if (input) {
          input.files = files;
          handleFileSelection(input);
        }
      }
    });

    // Dynamic modal state
    let currentModalUrl = '';

    function handleItemClick(el) {
      if (!el) return;
      const type = el.getAttribute('data-type');
      const url = el.getAttribute('data-url');
      const name = el.getAttribute('data-name') || '';
      const size = el.getAttribute('data-size') || '-';
      const modified = el.getAttribute('data-modified') || '-';
      const mime = el.getAttribute('data-mime') || 'application/octet-stream';
      
      if (type === 'directory') {
        if (url) window.location.href = url;
        return;
      }
      
      currentModalUrl = url;
      
      // Update basic fields
      const modalTitle = document.getElementById('modalTitle');
      const modalMeta = document.getElementById('modalMeta');
      const modalDownloadBtn = document.getElementById('modalDownloadBtn');
      if (modalTitle) modalTitle.textContent = name;
      if (modalMeta) modalMeta.textContent = `\${size} \u2022 \${modified}`;
      if (modalDownloadBtn) {
        modalDownloadBtn.href = url;
        modalDownloadBtn.setAttribute('download', name);
      }
      
      // Dynamic Icon wrapper styling
      const iconWrapper = document.getElementById('modalIcon');
      const itemIconWrapper = el.querySelector('.item-icon-wrapper');
      if (iconWrapper && itemIconWrapper) {
        iconWrapper.className = 'modal-icon-wrapper ' + (itemIconWrapper.className.split(' ')[1] || '');
        iconWrapper.innerHTML = itemIconWrapper.innerHTML;
      }
      
      // Render dedicated preview content
      const body = document.getElementById('modalBody');
      if (!body) return;
      body.innerHTML = '';
      
      const ext = name.split('.').pop().toLowerCase();
      
      if (['mp4', 'mkv', 'avi', 'mov', 'wmv', 'flv', 'webm', '3gp', 'ts', 'm4v', 'rmvb', 'rm', 'asf', 'f4v'].includes(ext)) {
        body.innerHTML = `
          <div class="video-container">
            <video controls autoplay class="preview-video">
              <source src="\${url}" type="\${mime}">
              Your browser does not support the video streaming tag.
            </video>
          </div>
        `;
      } else if (['mp3', 'wav', 'flac', 'm4a', 'ogg', 'wma', 'aac', 'opus', 'amr', 'mid', 'midi'].includes(ext)) {
        body.innerHTML = `
          <div class="audio-container">
            <div class="audio-art-disc">🎵</div>
            <audio controls autoplay class="preview-audio">
              <source src="\${url}" type="\${mime}">
              Your browser does not support the audio element.
            </audio>
          </div>
        `;
      } else if (['jpg', 'jpeg', 'png', 'gif', 'webp', 'bmp', 'svg', 'ico', 'tiff', 'tif', 'heic', 'heif', 'avif', 'raw'].includes(ext)) {
        body.innerHTML = `
          <div class="image-container">
            <img src="\${url}" class="preview-image" alt="\${name}">
          </div>
        `;
      } else if (ext === 'pdf') {
        body.innerHTML = `
          <iframe src="\${url}" class="preview-pdf"></iframe>
        `;
      } else if (['txt', 'log', 'json', 'md', 'xml', 'js', 'css', 'html', 'htm', 'csv', 'rtf', 'yaml', 'yml', 'toml', 'conf', 'cfg', 'ini', 'doc', 'docx', 'xls', 'xlsx', 'ppt', 'pptx', 'odt', 'ods', 'odp'].includes(ext)) {
        body.innerHTML = `<div class="preview-text-loading">\${t.loadingPreview}</div>`;
        fetch(url)
          .then(res => res.text())
          .then(text => {
            const escaped = text.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
            body.innerHTML = `<pre class="preview-text"><code>\${escaped}</code></pre>`;
          })
          .catch(() => {
            body.innerHTML = `<div class="preview-text-error">\${t.previewError}</div>`;
          });
      } else {
        const genericIcon = iconWrapper ? iconWrapper.innerHTML : '<svg class="svg-icon" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M13 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V9z"></path><polyline points="13 2 13 9 20 9"></polyline></svg>';
        body.innerHTML = `
          <div class="generic-container">
            <div class="generic-preview-icon">\${genericIcon}</div>
            <p class="generic-preview-text" id="previewUnsupported">\${t.previewUnsupported}</p>
            <p class="generic-preview-subtext" id="previewDownload">\${t.previewDownload}</p>
          </div>
        `;
      }
      
      const modal = document.getElementById('previewModal');
      if (!modal) return;
      modal.classList.add('active');
      document.body.style.overflow = 'hidden';
    }

    function closeModal(event) {
      const modal = document.getElementById('previewModal');
      if (!modal) return;
      modal.classList.remove('active');
      document.body.style.overflow = '';
      
      // Stop playing video or audio immediately on close
      const body = document.getElementById('modalBody');
      if (body) {
        const video = body.querySelector('video');
        if (video) video.pause();
        const audio = body.querySelector('audio');
        if (audio) audio.pause();
        body.innerHTML = '';
      }
    }

    // Download & Share operations
    function downloadFile(url, filename, event) {
      if (event) event.stopPropagation();
      const a = document.createElement('a');
      a.href = url;
      a.download = filename;
      document.body.appendChild(a);
      a.click();
      document.body.removeChild(a);
    }

    function copyFileLink(url, event) {
      if (event) event.stopPropagation();
      const absoluteUrl = new URL(url, window.location.href).href;
      copyToClipboard(absoluteUrl, t.linkCopied);
    }

    function copyModalLink() {
      const absoluteUrl = new URL(currentModalUrl, window.location.href).href;
      copyToClipboard(absoluteUrl, t.linkCopied);
    }

    function copyToClipboard(text, successMsg) {
      navigator.clipboard.writeText(text).then(() => {
        showToast(successMsg);
      }).catch(() => {
        // Safe fallback for insecure HTTP contexts
        const textarea = document.createElement("textarea");
        textarea.value = text;
        textarea.style.position = "fixed";
        document.body.appendChild(textarea);
        textarea.select();
        try {
          document.execCommand('copy');
          showToast(successMsg);
        } catch (e) {
          showToast(t.copyFailed);
        }
        document.body.removeChild(textarea);
      });
    }

    function showToast(message) {
      const existing = document.querySelector('.toast-notification');
      if (existing) document.body.removeChild(existing);

      const toast = document.createElement('div');
      toast.className = 'toast-notification';
      toast.textContent = message;
      document.body.appendChild(toast);
      
      setTimeout(() => {
        toast.classList.add('active');
      }, 20);
      
      setTimeout(() => {
        toast.classList.remove('active');
        setTimeout(() => {
          if (toast.parentNode) {
            document.body.removeChild(toast);
          }
        }, 300);
      }, 2500);
    }
  
    // Initialize localized text
    (function() {
      try {
        const si = document.getElementById('searchInput');
        if (si) si.placeholder = t.search;
        const uploadBtnText = document.getElementById('uploadBtnText');
        if (uploadBtnText) uploadBtnText.textContent = t.upload;
        const emptySearchTitle = document.getElementById('emptySearchTitle');
        if (emptySearchTitle) emptySearchTitle.textContent = t.emptySearch;
        const emptySearchDesc = document.getElementById('emptySearchDesc');
        if (emptySearchDesc) emptySearchDesc.textContent = t.emptyDesc;
        const modalCopyBtnText = document.getElementById('modalCopyBtnText');
        if (modalCopyBtnText) modalCopyBtnText.textContent = t.copyLink;
        const modalDownloadBtnText = document.getElementById('modalDownloadBtnText');
        if (modalDownloadBtnText) modalDownloadBtnText.textContent = t.download;
        const dropTitle = document.getElementById('dropTitle');
        if (dropTitle) dropTitle.textContent = t.dropTitle;
        const dropDesc = document.getElementById('dropDesc');
        if (dropDesc) dropDesc.textContent = t.dropDesc;
        const footerText = document.getElementById('footerText');
        if (footerText) footerText.textContent = t.footer;
        const previewUnsupported = document.getElementById('previewUnsupported');
        if (previewUnsupported) previewUnsupported.textContent = t.previewUnsupported;
        const previewDownload = document.getElementById('previewDownload');
        if (previewDownload) previewDownload.textContent = t.previewDownload;
        // Update category titles
        document.querySelectorAll('.category-title').forEach(el => {
          const section = el.closest('.category-section');
          if (section) {
            const catKey = section.id.replace('cat-section-', '');
            const keyMap = { folders: 'catFolders', videos: 'catVideos', audio: 'catAudio', images: 'catImages', documents: 'catDocuments', others: 'catOthers' };
            if (keyMap[catKey] && t[keyMap[catKey]]) el.textContent = t[keyMap[catKey]];
          }
        });
        // Update category empty text
        document.querySelectorAll('.category-empty').forEach(el => {
          const section = el.closest('.category-section');
          if (section) {
            const catKey = section.id.replace('cat-section-', '');
            const keyMap = { folders: 'catFolders', videos: 'catVideos', audio: 'catAudio', images: 'catImages', documents: 'catDocuments', others: 'catOthers' };
            if (keyMap[catKey] && t[keyMap[catKey]]) el.textContent = 'No ' + t[keyMap[catKey]].toLowerCase();
          }
        });
      } catch(e) { console.error('Localization init error:', e); }
    })();

  </script>
</body>
</html>
''';
  }

  // Detect WiFi Local IP
  Future<String> _detectLocalIp() async {
    try {
      final interfaces = await NetworkInterface.list(
        includeLoopback: false,
        type: InternetAddressType.IPv4,
      );
      for (final interface in interfaces) {
        for (final addr in interface.addresses) {
          if (!addr.isLoopback && (addr.address.startsWith('192.') || addr.address.startsWith('10.') || addr.address.startsWith('172.'))) {
            return addr.address;
          }
        }
      }
      if (interfaces.isNotEmpty && interfaces.first.addresses.isNotEmpty) {
        return interfaces.first.addresses.first.address;
      }
    } catch (_) {}
    return '127.0.0.1';
  }

  // --- Real Internet Sharing cloud tunnel ---
  Future<void> startInternetTunnel(String rootDir) async {
    if (_isInternetActive) return;

    try {
      // 1. Ensure local HTTP server is running
      if (!_isLocalActive) {
        await startLocalServer(rootDir);
      }

      _isInternetActive = true;
      _internetShareLink = 'Establishing secure proxy tunnel...';
      notifyListeners();

      // Update Foreground Service with tunnel starting text
      try {
        await _channel.invokeMethod('startWebSharingService', {
          'url': 'Establishing secure proxy tunnel...',
          'isInternet': true,
        });
      } catch (e) {
        debugPrint('Failed to start native web sharing service for tunnel: $e');
      }

      // 2. Connect to localhost.run SSH server
      SSHSocket socket;
      try {
        socket = await SSHSocket.connect('localhost.run', 22, timeout: const Duration(seconds: 15));
      } catch (e) {
        debugPrint('SSH connection to localhost.run failed: $e');
        _internetShareLink = localServerUrl;
        notifyListeners();
        rethrow;
      }
      final keys = SSHKeyPair.fromPem(_ed25519PrivateKeyPem);
      _sshClient = SSHClient(
        socket,
        username: 'nokey',
        identities: keys,
      );
      await _sshClient!.authenticated;

      // 3. Request remote port forwarding
      try {
        _sshForward = await _sshClient!.forwardRemote(port: 80);
      } catch (e) {
        debugPrint('Remote port forwarding failed: $e');
        _internetShareLink = localServerUrl;
        notifyListeners();
        rethrow;
      }
      if (_sshForward == null) {
        _internetShareLink = localServerUrl;
        notifyListeners();
        throw Exception('Remote port forwarding request denied by proxy server.');
      }

      // 4. Listen to incoming connection stream and pipe it to local HTTP Server (port 8080)
      _sshForward!.connections.listen((connection) async {
        try {
          final localSocket = await Socket.connect('127.0.0.1', _port);
          
          connection.stream.cast<List<int>>().listen(
            (data) => localSocket.add(data),
            onError: (e) {
              localSocket.close();
              connection.sink.close();
            },
            onDone: () {
              localSocket.close();
              connection.sink.close();
            },
          );

          localSocket.listen(
            (data) => connection.sink.add(data),
            onError: (e) {
              localSocket.close();
              connection.sink.close();
            },
            onDone: () {
              localSocket.close();
              connection.sink.close();
            },
          );
        } catch (e) {
          debugPrint('Error routing forwarded connection to local socket: $e');
          connection.sink.close();
        }
      });

      // 5. Start a session to obtain the allocated dynamic domain name from stdout
      final session = await _sshClient!.execute('');
      var stdoutBuffer = '';
      bool linkResolved = false;

      // Timeout fallback: if no domain is resolved within 30 seconds, use local URL
      Future.delayed(const Duration(seconds: 30), () {
        if (!_isInternetActive || linkResolved) return;
        // Fallback: show local server URL so user can still use it
        _internetShareLink = localServerUrl;
        notifyListeners();
        try {
          _channel.invokeMethod('startWebSharingService', {
            'url': _internetShareLink,
            'isInternet': true,
          });
        } catch (_) {}
      });

      // Helper function to try matching URL patterns in combined output
      void tryMatchUrl(String data) {
        stdoutBuffer += data;
        if (linkResolved) return;

        debugPrint('Localhost.run output: $data');

        // Try multiple regex patterns to match various localhost.run output formats
        final patterns = [
          // Standard domain pattern: xxx.localhost.run or xxx.lhr.life
          RegExp(r'(https?://[a-zA-Z0-9.-]+\.(localhost\.run|lhr\.life))'),
          // Domain without protocol
          RegExp(r'([a-zA-Z0-9-]+\.(localhost\.run|lhr\.life))'),
          // Any https URL in the output
          RegExp(r'(https://[a-zA-Z0-9.-]+\.[a-zA-Z]{2,})'),
          // Generic URL pattern
          RegExp(r'(https?://[^\s]+)'),
        ];

        String? matchedUrl;
        for (final pattern in patterns) {
          final match = pattern.firstMatch(stdoutBuffer);
          if (match != null) {
            matchedUrl = match.group(1)!;
            // Ensure URL starts with https://
            if (!matchedUrl.startsWith('http')) {
              matchedUrl = 'https://$matchedUrl';
            }
            break;
          }
        }

        if (matchedUrl != null) {
          linkResolved = true;
          _internetShareLink = matchedUrl;
          notifyListeners();

          // Update Foreground Service with real public URL!
          try {
            _channel.invokeMethod('startWebSharingService', {
              'url': _internetShareLink,
              'isInternet': true,
            });
          } catch (e) {
            debugPrint('Failed to update native web sharing service with link: $e');
          }
        }
      }

      // Listen to stdout for URL
      session.stdout.cast<List<int>>().transform(utf8.decoder).listen((data) {
        tryMatchUrl(data);
      });

      // Also listen to stderr (some servers output URL there)
      session.stderr.cast<List<int>>().transform(utf8.decoder).listen((data) {
        tryMatchUrl(data);
      });

      // Start client real traffic speed timer
      _startSpeedTimer();

    } catch (e) {
      debugPrint('Failed to start internet sharing tunnel: $e');
      stopInternetTunnel();
      rethrow;
    }
  }

  void _startSpeedTimer() {
    if (_speedTimer != null) return;
    _speedTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (_clientsMap.isEmpty) {
        _speedTimer?.cancel();
        _speedTimer = null;
        return;
      }

      final now = DateTime.now();
      final toRemove = <String>[];

      _clientsMap.forEach((key, client) {
        // Idle timeout: if no active request chunks or connections for 8 seconds, remove the client display
        if (now.difference(client.lastActivityTime).inSeconds > 8) {
          toRemove.add(key);
          return;
        }

        final bytesDiff = client.bytesTransferred - client._lastBytesTransferred;
        client.speed = bytesDiff / (1024 * 1024); // Convert to MB/s
        client._lastBytesTransferred = client.bytesTransferred;
      });

      if (toRemove.isNotEmpty) {
        for (final key in toRemove) {
          _clientsMap.remove(key);
        }
      }

      notifyListeners();
    });
  }

  ActiveClient? _trackClientActivity(HttpRequest request, String targetPath, int fileSize) {
    final userAgent = request.headers.value(HttpHeaders.userAgentHeader) ?? '';
    if (userAgent.isEmpty) return null;

    final uaLower = userAgent.toLowerCase();
    if (!uaLower.contains('mozilla') ||
        uaLower.contains('bot') ||
        uaLower.contains('crawler') ||
        uaLower.contains('spider') ||
        uaLower.contains('curl') ||
        uaLower.contains('wget') ||
        uaLower.contains('go-http') ||
        uaLower.contains('python') ||
        uaLower.contains('http-client') ||
        uaLower.contains('ping') ||
        uaLower.contains('probe') ||
        uaLower.contains('scan')) {
      return null;
    }

    final ip = request.connectionInfo?.remoteAddress.address ?? 'Unknown';
    final clientKey = '${ip}_$userAgent';

    final device = _parseUserAgent(userAgent);
    final fileName = FileSystemEntity.isDirectorySync(targetPath) ? 'Browsing Directories' : p.basename(targetPath);

    final client = _clientsMap.putIfAbsent(clientKey, () => ActiveClient(
      ip: ip,
      userAgent: userAgent,
      device: device,
      currentFile: fileName,
      totalBytes: fileSize,
    ));

    client.currentFile = fileName;
    client.totalBytes = fileSize;
    client.lastActivityTime = DateTime.now();

    _startSpeedTimer();
    notifyListeners();
    return client;
  }

  String _parseUserAgent(String ua) {
    if (ua.isEmpty) return 'Web Browser';

    final uaLower = ua.toLowerCase();
    String browser = 'Browser';
    if (uaLower.contains('chrome')) {
      browser = 'Chrome';
    } else if (uaLower.contains('safari') && !uaLower.contains('chrome')) {
      browser = 'Safari';
    } else if (uaLower.contains('firefox')) {
      browser = 'Firefox';
    } else if (uaLower.contains('edge') || uaLower.contains('edg')) {
      browser = 'Edge';
    } else if (uaLower.contains('opera') || uaLower.contains('opr')) {
      browser = 'Opera';
    }

    String os = 'Web';
    if (uaLower.contains('windows')) {
      os = 'Windows';
    } else if (uaLower.contains('macintosh') || uaLower.contains('mac os')) {
      os = 'macOS';
    } else if (uaLower.contains('iphone') || uaLower.contains('ipad')) {
      os = 'iOS';
    } else if (uaLower.contains('android')) {
      os = 'Android';
    } else if (uaLower.contains('linux')) {
      os = 'Linux';
    }

    return '$browser on $os';
  }

  void stopInternetTunnel() {
    if (!_isInternetActive) return;
    _speedTimer?.cancel();
    _speedTimer = null;
    _sshForward = null;
    _sshClient?.close();
    _sshClient = null;
    _isInternetActive = false;
    _internetShareLink = '';
    _clientsMap.clear();

    // Manage Native Android Background Service Reversion
    try {
      if (_isLocalActive) {
        _channel.invokeMethod('startWebSharingService', {
          'url': 'http://$_localIpAddress:$_port',
          'isInternet': false,
        });
      } else {
        _channel.invokeMethod('stopWebSharingService');
      }
    } catch (e) {
      debugPrint('Failed to manage native service on tunnel stop: $e');
    }

    notifyListeners();
  }

  @override
  void dispose() {
    _speedTimer?.cancel();
    _sshClient?.close();
    _localServer?.close(force: true);
    super.dispose();
  }
}

class ActiveClient {
  final String ip;
  final String userAgent;
  final String device;
  String currentFile;
  int bytesTransferred = 0;
  int totalBytes = 0;
  DateTime lastActivityTime;
  double speed = 0.0; // MB/s
  int _lastBytesTransferred = 0;

  ActiveClient({
    required this.ip,
    required this.userAgent,
    required this.device,
    required this.currentFile,
    required this.totalBytes,
  }) : lastActivityTime = DateTime.now();
}
