import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';
import '../../core/icon_fonts/broken_icons.dart';
import '../../core/utils.dart';
import '../../models/network_connection_model.dart';
import '../../providers/file_manager_provider.dart';
import '../../providers/media_provider.dart';
import '../../services/preferences_service.dart';
import '../../services/media_thumbnail_service.dart';
import '../../services/remote/remote_client.dart';
import '../../services/remote/ftp_client.dart';
import '../../services/remote/sftp_client.dart';
import '../../services/remote/webdav_client.dart';
import '../../services/remote/lan_client.dart';
import '../../services/remote_streaming_service.dart';
import '../../services/remote/saf_client.dart';
import '../widgets/zenfile_drawer.dart';
import 'package:zenfile/l10n/generated/app_localizations.dart';

// Clipboard for remote→local operations
class _RemoteClipboard {
  final List<RemoteFileItem> items;
  final bool isCut;

  const _RemoteClipboard({required this.items, required this.isCut});
}

class RemoteExplorerScreen extends StatefulWidget {
  final NetworkConnectionModel connection;

  const RemoteExplorerScreen({super.key, required this.connection});

  @override
  State<RemoteExplorerScreen> createState() => _RemoteExplorerScreenState();
}

class _RemoteExplorerScreenState extends State<RemoteExplorerScreen> {
  RemoteClient? _client;
  bool _isConnected = false;
  bool _isLoading = true;
  String _errorMsg = '';
  String _currentPath = '/';
  List<RemoteFileItem> _items = [];

  // Selection mode
  bool _isSelectionMode = false;
  final Set<String> _selectedPaths = {};

  // Transfer overlay
  bool _isTransferring = false;
  double _transferProgress = 0.0;
  String _transferFileName = '';
  String _transferLabel = 'Transferring...';

  @override
  void initState() {
    super.initState();
    _currentPath = widget.connection.rootPath;
    _initClient();
  }

  @override
  void dispose() {
    _client?.disconnect();
    super.dispose();
  }

  Future<void> _initClient() async {
    final conn = widget.connection;
    if (conn.type == 'FTP') {
      _client = FtpRemoteClient(host: conn.host, port: conn.port, username: conn.username, password: conn.password);
    } else if (conn.type == 'SFTP') {
      _client = SftpRemoteClient(host: conn.host, port: conn.port, username: conn.username, password: conn.password);
    } else if (conn.type == 'WebDav') {
      _client = WebDavRemoteClient(
        host: conn.host,
        port: conn.port,
        username: conn.username,
        password: conn.password,
        protocol: conn.protocol,
        rootPath: conn.rootPath,
      );
    } else if (conn.type == L10n.of(context).smb) {
      _client = LanClient(host: conn.host, port: conn.port, username: conn.username, password: conn.password);
    } else if (conn.type == 'saf') {
      _client = SafRemoteClient(rootUri: conn.rootPath);
    }

    try {
      await _client?.connect();
      _isConnected = true;
      await _loadDirectoryContents(_currentPath);
    } catch (e) {
      if (mounted) {
        setState(() {
          _errorMsg = e.toString();
          _isLoading = false;
        });
      }
    }
  }

  Future<void> _loadDirectoryContents(String path) async {
    if (_client == null || !_isConnected) return;
    setState(() {
      _isLoading = true;
      _errorMsg = '';
    });
    try {
      final items = await _client!.listDirectory(path);
      items.sort((a, b) {
        if (a.isDirectory && !b.isDirectory) return -1;
        if (!a.isDirectory && b.isDirectory) return 1;
        return FileUtils.compareNatural(a.name, b.name);
      });
      if (mounted) {
        setState(() {
          _items = items;
          _currentPath = path;
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _errorMsg = e.toString();
          _isLoading = false;
        });
      }
    }
  }

  void _navigateTo(RemoteFileItem item) {
    if (item.isDirectory) {
      _loadDirectoryContents(item.path);
    } else {
      // 检查文件类型，媒体文件自动缓存播放
      final ext = p.extension(item.name).toLowerCase();
      final isVideo = ['.mp4', '.mkv', '.avi', '.mov', '.wmv', '.flv', '.webm', '.m4v', '.3gp'].contains(ext);
      final isAudio = ['.mp3', '.aac', '.wav', '.flac', '.m4a', '.ogg', '.wma', '.opus'].contains(ext);
      final isText = ['.txt', '.log', '.md', '.csv', '.json', '.xml', '.html', '.dart', '.py', '.java', '.cpp', '.c', '.h', '.js', '.css'].contains(ext);
      final isImage = ['.jpg', '.jpeg', '.png', '.gif', '.bmp', '.webp', '.heic', '.heif', '.avif'].contains(ext);
      
      if (isVideo || isAudio || isText || isImage) {
        _autoCacheAndPlay(item, isVideo: isVideo, isAudio: isAudio, isText: isText, isImage: isImage);
      } else {
        _showItemActions(item);
      }
    }
  }

  /// 自动下载并打开媒体文件（音视频支持边缓存边播放）
  Future<void> _autoCacheAndPlay(RemoteFileItem item, {bool isVideo = false, bool isAudio = false, bool isText = false, bool isImage = false}) async {
    if (_client == null) return;
    
    if (_isTransferring) return; // 防止重复点击
    
    // For video/audio, use streaming (WebDAV direct HTTP, FTP/SFTP via local proxy)
    if (isVideo || isAudio) {
      final streamUrl = _client!.getStreamUrl(item.path);
      if (streamUrl != null) {
        // Direct streaming playback (WebDAV) — no download needed
        if (!mounted) return;
        final provider = context.read<FileManagerProvider>();
        await provider.openFile(context, streamUrl, isRemoteStream: true);
        return;
      }
      // Non-HTTP protocols (FTP/SFTP): use local streaming proxy
      try {
        final proxyUrl = await RemoteStreamingService.instance.startStreaming(_client!, item.path, item.name);
        if (!mounted) return;
        final provider = context.read<FileManagerProvider>();
        await provider.openFile(context, proxyUrl, isRemoteStream: true);
        return;
      } catch (e) {
        debugPrint('Streaming proxy failed, falling back to download: $e');
      }
      // Fallback: delegate to openFile which handles download
      if (!mounted) return;
      final provider = context.read<FileManagerProvider>();
      await provider.openFile(context, item.path);
      return;
    }
    
    setState(() {
      _isTransferring = true;
      _transferProgress = 0.0;
      _transferFileName = item.name;
      _transferLabel = isText ? L10n.of(context).msgc44a57b6 : (isImage ? '正在缓存图片...' : L10n.of(context).msgd6d8292d);
    });
    
    try {
      Directory? downloadDir = Directory('/storage/emulated/0/Download');
      if (!downloadDir.existsSync()) {
        downloadDir = await getExternalStorageDirectory();
      }
      downloadDir ??= await getApplicationDocumentsDirectory();
      
      final nfileDir = Directory(p.join(downloadDir.path, 'ZenFile_Remote'));
      if (!nfileDir.existsSync()) nfileDir.createSync(recursive: true);
      
      final localPath = p.join(nfileDir.path, item.name);
      
      // 文本和图片：完整下载后打开
      await _client!.downloadFile(item.path, localPath, (prog) {
        if (mounted) setState(() => _transferProgress = prog);
      });
      
      if (!mounted) return;
      setState(() => _isTransferring = false);
      
      final provider = context.read<FileManagerProvider>();
      await provider.openFile(context, localPath);
    } catch (e) {
      if (mounted) {
        setState(() => _isTransferring = false);
        _showSnack(L10n.of(context).e16(e), isError: true);
      }
    }
  }

  String _getSafParentUri(String currentUri, String rootUri) {
    if (currentUri == rootUri) return rootUri;
    final docIndex = currentUri.indexOf('/document/');
    if (docIndex == -1) return rootUri;
    
    final baseUri = currentUri.substring(0, docIndex + 10); // includes "content://.../document/"
    final documentId = Uri.decodeComponent(currentUri.substring(docIndex + 10));
    final docParts = documentId.split('/');
    if (docParts.isEmpty) return rootUri;
    
    docParts.removeLast();
    if (docParts.isEmpty) return rootUri;
    
    final parentDocId = docParts.join('/');
    return '$baseUri${Uri.encodeComponent(parentDocId)}';
  }

  void _navigateUp() {
    if (_currentPath == widget.connection.rootPath) return;
    if (widget.connection.type == 'saf') {
      final parentUri = _getSafParentUri(_currentPath, widget.connection.rootPath);
      _loadDirectoryContents(parentUri);
      return;
    }
    final parts = _currentPath.split('/');
    if (parts.isNotEmpty) parts.removeLast();
    var parent = parts.join('/');
    if (parent.isEmpty) parent = '/';
    if (parent.length < widget.connection.rootPath.length) {
      parent = widget.connection.rootPath;
    }
    _loadDirectoryContents(parent);
  }

  void _navigateToBreadcrumb(String path) {
    _loadDirectoryContents(path);
  }

  // ─────────────────────────────────────────────────────────────────────────
  // COPY / CUT / PASTE - Remote items
  // ─────────────────────────────────────────────────────────────────────────

  void _copyRemoteItem(RemoteFileItem item) {
    context.read<FileManagerProvider>().setRemoteClipboard(
      [item],
      isCut: false,
      connection: widget.connection,
    );
    _showSnack('已复制"${item.name}"到剪贴板');
  }

  void _cutRemoteItem(RemoteFileItem item) {
    context.read<FileManagerProvider>().setRemoteClipboard(
      [item],
      isCut: true,
      connection: widget.connection,
    );
    _showSnack('已剪切"${item.name}"到剪贴板');
  }

  /// 粘贴远程剪贴板 items to current remote directory
  Future<void> _pasteRemoteClipboard() async {
    final provider = context.read<FileManagerProvider>();
    if (!provider.isRemoteClipboard || _client == null) return;
    final clipItems = provider.remoteClipboardItems;
    final isCut = provider.isCut;

    for (final item in clipItems) {
      final destPath = _currentPath == '/'
          ? '/${item.name}'
          : '$_currentPath/${item.name}';

      if (destPath == item.path) {
        _showSnack(L10n.of(context).msg53082c55);
        return;
      }

      setState(() {
        _isTransferring = true;
        _transferProgress = 0.0;
        _transferFileName = item.name;
        _transferLabel = isCut ? '正在移动...' : L10n.of(context).msg108feeed;
      });

      try {
        // Download to temp, then upload to new path
        final tempDir = await getTemporaryDirectory();
        final tempPath = p.join(tempDir.path, item.name);

        await _client!.downloadFile(item.path, tempPath, (p) {
          if (mounted) setState(() => _transferProgress = p * 0.5);
        });

        await _client!.uploadFile(tempPath, destPath, (p) {
          if (mounted) setState(() => _transferProgress = 0.5 + p * 0.5);
        });

        if (isCut) {
          await _client!.delete(item.path, item.isDirectory);
        }

        // Cleanup temp
        try { File(tempPath).deleteSync(); } catch (_) {}
      } catch (e) {
        if (mounted) {
          setState(() => _isTransferring = false);
          _showSnack('Transfer failed: $e', isError: true);
          return;
        }
      }
    }

    if (mounted) {
      setState(() {
        _isTransferring = false;
      });
      if (isCut) provider.clearClipboard();
      _showSnack(L10n.of(context).msg2d4b44ec);
      await _loadDirectoryContents(_currentPath);
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  // UPLOAD - Local device → Remote server
  // ─────────────────────────────────────────────────────────────────────────

  /// Upload all files from local app clipboard to current remote directory
  Future<void> _uploadFromLocalClipboard() async {
    final provider = context.read<FileManagerProvider>();
    if (!provider.hasClipboard) {
      _showSnack('Local clipboard is empty. Copy files in the file manager first.', isError: true);
      return;
    }
    if (_client == null) return;

    final paths = List<String>.from(provider.clipboardPaths);
    final isCut = provider.isCut;

    for (final localPath in paths) {
      final file = File(localPath);
      if (!file.existsSync()) continue;

      final fileName = p.basename(localPath);
      final remoteDest = _currentPath == '/' ? '/$fileName' : '$_currentPath/$fileName';

      setState(() {
        _isTransferring = true;
        _transferProgress = 0.0;
        _transferFileName = fileName;
        _transferLabel = 'Uploading to server...';
      });

      try {
        await _client!.uploadFile(localPath, remoteDest, (prog) {
          if (mounted) setState(() => _transferProgress = prog);
        });

        if (isCut) {
          try { file.deleteSync(); } catch (_) {}
        }
      } catch (e) {
        if (mounted) {
          setState(() => _isTransferring = false);
          _showSnack(L10n.of(context).filenamee(e, fileName), isError: true);
          return;
        }
      }
    }

    if (mounted) {
      setState(() => _isTransferring = false);
      if (isCut) provider.clearClipboard();
      _showSnack('Uploaded ${paths.length} file(s) successfully');
      await _loadDirectoryContents(_currentPath);
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  // DOWNLOAD - Remote → Local device clipboard / downloads folder
  // ─────────────────────────────────────────────────────────────────────────

  /// Download remote file to local Downloads and then put path in local clipboard
  Future<void> _downloadToLocalClipboard(RemoteFileItem item, {bool isCut = false}) async {
    if (_client == null) return;

    setState(() {
      _isTransferring = true;
      _transferProgress = 0.0;
      _transferFileName = item.name;
      _transferLabel = 'Downloading from server...';
    });

    try {
      Directory? downloadDir = Directory('/storage/emulated/0/Download');
      if (!downloadDir.existsSync()) {
        downloadDir = await getExternalStorageDirectory();
      }
      downloadDir ??= await getApplicationDocumentsDirectory();

      final nfileDir = Directory(p.join(downloadDir.path, 'ZenFile_Remote'));
      if (!nfileDir.existsSync()) nfileDir.createSync(recursive: true);

      final localPath = p.join(nfileDir.path, item.name);

      await _client!.downloadFile(item.path, localPath, (prog) {
        if (mounted) setState(() => _transferProgress = prog);
      });

      if (isCut) {
        await _client!.delete(item.path, item.isDirectory);
      }

      if (mounted) {
        setState(() => _isTransferring = false);
        // Put downloaded file in local clipboard
        context.read<FileManagerProvider>().setClipboard([localPath], isCut: false);
        _showSnack('"${item.name}" downloaded → local clipboard ready to paste');
        if (isCut) await _loadDirectoryContents(_currentPath);
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isTransferring = false);
        _showSnack('Download failed: $e', isError: true);
      }
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  // DELETE
  // ─────────────────────────────────────────────────────────────────────────

  /// 重命名远程文件/文件夹
  Future<void> _renameRemoteItem(RemoteFileItem item) async {
    if (_client == null) return;
    final controller = TextEditingController(text: item.name);
    final newName = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text(L10n.of(context).msgc8ce4b36, style: TextStyle(fontWeight: FontWeight.bold)),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: InputDecoration(
             hintText: L10n.of(context).msgf139c5cf,
            border: OutlineInputBorder(borderRadius: BorderRadius.all(Radius.circular(12))),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: Theme.of(ctx).colorScheme.primary,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            ),
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: Text(L10n.of(context).msgc8ce4b36),
          ),
        ],
      ),
    );

    if (newName == null || newName.isEmpty || newName == item.name) return;

    try {
      final parentPath = item.path.substring(0, item.path.length - item.name.length);
      final newPath = parentPath + newName;
      await _client!.rename(item.path, newPath);
      _showSnack(L10n.of(context).newname(newName));
      await _loadDirectoryContents(_currentPath);
    } catch (e) {
      _showSnack('重命名失败: $e', isError: true);
    }
  }

  Future<void> _deleteItem(RemoteFileItem item) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        final theme = Theme.of(ctx);
        return AlertDialog(
          title: Text(L10n.of(context).msg4b342999, style: TextStyle(fontFamily: 'LexendDeca', fontWeight: FontWeight.bold)),
          content: Text('从服务器永久删除"${item.name}"？'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent, foregroundColor: Colors.white, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10))),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('删除'),
            ),
          ],
        );
      },
    );
    if (confirmed != true) return;

    setState(() => _isLoading = true);
    try {
      await _client?.delete(item.path, item.isDirectory);
      await _loadDirectoryContents(_currentPath);
      _showSnack('已删除"${item.name}"');
    } catch (e) {
      _showSnack(L10n.of(context).e17(e), isError: true);
      setState(() => _isLoading = false);
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  // CREATE FOLDER
  // ─────────────────────────────────────────────────────────────────────────

  void _showAddFolderDialog() {
    final controller = TextEditingController();
    final theme = Theme.of(context);

    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text(
            L10n.of(context).msg79d7fef7,
            style: const TextStyle(fontFamily: 'LexendDeca', fontSize: 18, fontWeight: FontWeight.bold),
          ),
          content: TextField(
            controller: controller,
            autofocus: true,
            style: const TextStyle(fontSize: 14),
            decoration: InputDecoration(
              hintText: L10n.of(context).msga98473f2,
              hintStyle: TextStyle(color: theme.colorScheme.onSurface.withOpacity(0.35)),
              prefixIcon: Icon(Broken.folder_open, size: 18, color: theme.colorScheme.primary),
              filled: true,
              fillColor: theme.colorScheme.primary.withOpacity(0.04),
              contentPadding: const EdgeInsets.symmetric(vertical: 14, horizontal: 16),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: BorderSide.none),
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: theme.colorScheme.primary,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
              onPressed: () async {
                final name = controller.text.trim();
                if (name.isNotEmpty) {
                  Navigator.pop(context);
                  setState(() => _isLoading = true);
                  try {
                    final folderPath = _currentPath == '/' ? '/$name' : '$_currentPath/$name';
                    await _client?.createDirectory(folderPath);
                    await _loadDirectoryContents(_currentPath);
                  } catch (e) {
                    if (mounted) {
                      _showSnack(L10n.of(context).e18(e), isError: true);
                      setState(() => _isLoading = false);
                    }
                  }
                }
              },
              child: const Text('创建'),
            ),
          ],
        );
      },
    );
  }

  // ─────────────────────────────────────────────────────────────────────────
  // ITEM ACTIONS BOTTOM SHEET
  // ─────────────────────────────────────────────────────────────────────────

  void _showItemActions(RemoteFileItem item) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final provider = context.read<FileManagerProvider>();

    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        return Container(
          decoration: BoxDecoration(
            color: isDark ? const Color(0xFF1E293B) : Colors.white,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
          ),
          padding: const EdgeInsets.fromLTRB(24, 12, 24, 32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Handle
              Center(
                child: Container(
                  width: 36, height: 4,
                  decoration: BoxDecoration(
                    color: theme.colorScheme.onSurface.withOpacity(0.15),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 16),

              // Header
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.primary.withOpacity(0.1),
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Icon(
                      item.isDirectory ? Broken.folder_open : Broken.document,
                      size: 22, color: theme.colorScheme.primary,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(item.name,
                          style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold, fontFamily: 'LexendDeca'),
                          overflow: TextOverflow.ellipsis),
                        Text(
                          item.isDirectory ? L10n.of(context).msg5ca05a9b : item.formattedSize,
                          style: TextStyle(fontSize: 11.5, color: theme.colorScheme.onSurface.withOpacity(0.5)),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 20),
              const Divider(height: 1),
              const SizedBox(height: 8),

              // ── Actions ──
              // Copy remote item
              _buildActionTile(
                ctx, icon: Broken.copy, label: '复制',
                color: theme.colorScheme.primary,
                onTap: () { Navigator.pop(ctx); _copyRemoteItem(item); },
              ),

              // Cut remote item
              _buildActionTile(
                ctx, icon: Broken.scissor, label: '剪切',
                color: Colors.orange,
                onTap: () { Navigator.pop(ctx); _cutRemoteItem(item); },
              ),

              // Rename
              _buildActionTile(
                ctx, icon: Broken.edit, label: L10n.of(context).msgc8ce4b36,
                color: const Color(0xFF0D9488),
                onTap: () { Navigator.pop(ctx); _renameRemoteItem(item); },
              ),

              // Copy to local device (downloads file and puts in local clipboard)
              if (!item.isDirectory)
                _buildActionTile(
                  ctx, icon: Icons.download_for_offline_rounded, label: L10n.of(context).msga636c09d,
                  subtitle: L10n.of(context).msga4c461a4,
                  color: const Color(0xFF0D9488),
                  onTap: () { Navigator.pop(ctx); _downloadToLocalClipboard(item, isCut: false); },
                ),

              // Cut from remote to local device
              if (!item.isDirectory)
                _buildActionTile(
                  ctx, icon: Icons.drive_file_move_rtl_rounded, label: '移动到本地设备',
                  subtitle: L10n.of(context).msg425502fa,
                  color: const Color(0xFF7C3AED),
                  onTap: () { Navigator.pop(ctx); _downloadToLocalClipboard(item, isCut: true); },
                ),

              // Delete
              _buildActionTile(
                ctx, icon: Broken.trash, label: '删除',
                color: Colors.redAccent,
                onTap: () { Navigator.pop(ctx); _deleteItem(item); },
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildActionTile(
    BuildContext ctx, {
    required IconData icon,
    required String label,
    String? subtitle,
    required Color color,
    required VoidCallback onTap,
  }) {
    final theme = Theme.of(ctx);
    return InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 11, horizontal: 4),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: color.withOpacity(0.1),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(icon, size: 18, color: color),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label, style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600)),
                  if (subtitle != null)
                    Text(subtitle, style: TextStyle(fontSize: 11, color: theme.colorScheme.onSurface.withOpacity(0.45))),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _showSnack(String msg, {bool isError = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      behavior: SnackBarBehavior.floating,
      backgroundColor: isError ? Colors.redAccent : Theme.of(context).colorScheme.primary,
    ));
  }

  // ─────────────────────────────────────────────────────────────────────────
  // BUILD
  // ─────────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final provider = context.watch<FileManagerProvider>();

    final isSaf = widget.connection.type == 'saf';
    final rootPath = widget.connection.rootPath;
    
    List<String> pathNodes = [];
    List<String> pathUris = [];
    
    if (isSaf) {
      pathNodes.add(L10n.of(context).msgc2b9f4b9);
      pathUris.add(rootPath);
      
      final docIndex = _currentPath.indexOf('/document/');
      if (docIndex != -1) {
        final baseUri = _currentPath.substring(0, docIndex + 10);
        final documentId = Uri.decodeComponent(_currentPath.substring(docIndex + 10));
        final docParts = documentId.split('/').where((n) => n.isNotEmpty).toList();
        
        for (int i = 0; i < docParts.length; i++) {
          final part = docParts[i];
          String displayName = part;
          if (part.contains(':')) {
            displayName = part.split(':').last;
            if (displayName.isEmpty) {
              displayName = part;
            }
          }
          pathNodes.add(displayName);
          
          final subParts = docParts.sublist(0, i + 1);
          final subDocId = subParts.join('/');
          pathUris.add('$baseUri${Uri.encodeComponent(subDocId)}');
        }
      }
    } else {
      String relativePath = _currentPath;
      if (_currentPath.startsWith(rootPath)) {
        relativePath = _currentPath.substring(rootPath.length);
      }
      if (relativePath.isEmpty || relativePath == '/') relativePath = '';

      pathNodes = relativePath.isEmpty
          ? [L10n.of(context).msgc2b9f4b9]
          : [L10n.of(context).msgc2b9f4b9, ...relativePath.split('/').where((n) => n.isNotEmpty)];
    }

    final hasLocalClipboard = provider.clipboardPaths.isNotEmpty;
    final hasRemoteClipboard = provider.isRemoteClipboard;

    final canPopRemote = _currentPath != widget.connection.rootPath;

    return PopScope(
      canPop: canPopRemote,
      onPopInvoked: (didPop) {
        if (didPop) return;
        if (_currentPath != widget.connection.rootPath) {
          _navigateUp();
        }
      },
      child: Scaffold(
        drawer: ZenFileDrawer(
          toggleTheme: () {
            final brightness = Theme.of(context).brightness;
            final isDark = brightness == Brightness.dark;
            // 通知父级切换主题
          },
          onNavigateTab: (index) {
            Navigator.of(context).popUntil((route) => route.isFirst);
            if (index == 1) {
              final provider = context.read<FileManagerProvider>();
              provider.setNavigateToBrowseTab(true);
            }
          },
        ),
        appBar: AppBar(
          toolbarHeight: 96,
          titleSpacing: 0,
          centerTitle: false,
          leadingWidth: _isSelectionMode ? 56 : 160,
          leading: _isSelectionMode
              ? IconButton(
                  icon: const Icon(Broken.close_square),
                  onPressed: () => setState(() { _isSelectionMode = false; _selectedPaths.clear(); }),
                )
              : Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Builder(
                      builder: (context) => IconButton(
                        icon: Icon(Broken.sidebar_left, color: theme.colorScheme.primary),
                        onPressed: () => Scaffold.of(context).openDrawer(),
                      ),
                    ),
                    IconButton(
                      icon: Icon(Broken.category, color: theme.colorScheme.primary),
                      tooltip: L10n.of(context).msg6e0f9cef,
                      onPressed: () {
                        Navigator.of(context).popUntil((route) => route.isFirst);
                        context.read<MediaProvider>().refreshMediaBackground();
                      },
                    ),
                    IconButton(
                      icon: Icon(Broken.folder, color: theme.colorScheme.primary),
                      tooltip: '浏览',
                      onPressed: () {
                        Navigator.of(context).popUntil((route) => route.isFirst);
                        final provider = context.read<FileManagerProvider>();
                        provider.setNavigateToBrowseTab(true);
                      },
                    ),
                  ],
                ),
          title: _isSelectionMode
              ? Text('已选 ${_selectedPaths.length} 项', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16))
              : Padding(
                  padding: const EdgeInsets.only(top: 32),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(widget.connection.name,
                        style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16.5)),
                      Text('${widget.connection.type} Server',
                        style: TextStyle(fontSize: 11.5, color: theme.colorScheme.primary, fontWeight: FontWeight.w600)),
                    ],
                  ),
                ),
          actions: [
            // 移除抽屉、分类、浏览按钮（已移到 leading）
            if (_isConnected) ...[
              if (_isSelectionMode) ...[
                // 全选
                IconButton(
                  icon: const Icon(Broken.tick_square, size: 20),
                  tooltip: '全选',
                  onPressed: () {
                    setState(() {
                      if (_selectedPaths.length == _items.length) {
                        _selectedPaths.clear();
                      } else {
                        _selectedPaths.clear();
                        for (final item in _items) {
                          _selectedPaths.add(item.path);
                        }
                      }
                    });
                  },
                ),
                // 复制
                IconButton(
                  icon: const Icon(Broken.document_copy, size: 20),
                  tooltip: '复制',
                  onPressed: _selectedPaths.isEmpty ? null : () => _batchCopySelected(),
                ),
                // 剪切
                IconButton(
                  icon: const Icon(Broken.scissor, size: 20),
                  tooltip: '剪切',
                  onPressed: _selectedPaths.isEmpty ? null : () => _batchCutSelected(),
                ),
                // 更多操作
                PopupMenuButton<String>(
                  icon: const Icon(Broken.more, size: 20),
                  tooltip: L10n.of(context).msgfff96ede,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                  position: PopupMenuPosition.under,
                  onSelected: (value) async {
                    if (value == 'delete') {
                      await _batchDeleteSelected();
                    }
                  },
                  itemBuilder: (context) => [
                    const PopupMenuItem<String>(
                      value: 'delete',
                      child: Row(
                        children: [
                          Icon(Broken.trash, size: 20, color: Colors.redAccent),
                          SizedBox(width: 12),
                          Text('删除', style: TextStyle(fontWeight: FontWeight.w500, color: Colors.redAccent)),
                        ],
                      ),
                    ),
                  ],
                ),
              ] else ...[
                // Paste local clipboard to remote
                if (hasLocalClipboard)
                  IconButton(
                    icon: Stack(
                      alignment: Alignment.topRight,
                      children: [
                        Icon(Broken.copy, size: 20, color: theme.colorScheme.primary),
                        Container(
                          width: 8, height: 8,
                          decoration: BoxDecoration(color: Colors.orange, shape: BoxShape.circle,
                            border: Border.all(color: theme.scaffoldBackgroundColor, width: 1)),
                        ),
                      ],
                    ),
                    tooltip: L10n.of(context).msg2f7cd487,
                    onPressed: _uploadFromLocalClipboard,
                  ),
                // 粘贴远程剪贴板
                if (hasRemoteClipboard)
                  IconButton(
                    icon: Stack(
                      alignment: Alignment.topRight,
                      children: [
                        Icon(Icons.content_paste_rounded, size: 20, color: theme.colorScheme.primary),
                        Container(
                          width: 8, height: 8,
                          decoration: BoxDecoration(color: provider.isCut ? Colors.orange : Colors.green, shape: BoxShape.circle,
                            border: Border.all(color: theme.scaffoldBackgroundColor, width: 1)),
                        ),
                      ],
                    ),
                    tooltip: provider.isCut ? '移动到此处' : L10n.of(context).msg905c34fa,
                    onPressed: _pasteRemoteClipboard,
                  ),
                IconButton(
                  icon: const Icon(Broken.folder_add, size: 20),
                  tooltip: L10n.of(context).msgf3a485df,
                  onPressed: _showAddFolderDialog,
                ),
              ],
            ],
          ],
        ),

      body: Stack(
        children: [
          if (_isLoading)
            const Center(child: CircularProgressIndicator())
          else if (_errorMsg.isNotEmpty)
            Center(
              child: Padding(
                padding: const EdgeInsets.all(24.0),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(Broken.info_circle, size: 64, color: Colors.redAccent),
                    const SizedBox(height: 16),
                    Text(L10n.of(context).msg8439c155, style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold)),
                    const SizedBox(height: 8),
                    Text(_errorMsg, textAlign: TextAlign.center,
                      style: TextStyle(color: theme.colorScheme.onSurface.withOpacity(0.5))),
                    const SizedBox(height: 24),
                    ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: theme.colorScheme.primary, foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                      ),
                      onPressed: () {
                        setState(() { _isLoading = true; _errorMsg = ''; });
                        _initClient();
                      },
                      icon: const Icon(Icons.refresh_rounded),
                      label: Text(L10n.of(context).msgda43df27),
                    ),
                  ],
                ),
              ),
            )
          else
            Column(
              children: [
                // Clipboard status banner
                if (hasLocalClipboard || hasRemoteClipboard)
                  _buildClipboardBanner(theme, hasLocalClipboard, hasRemoteClipboard, provider),

                // Breadcrumbs
                Container(
                  height: 44,
                  width: double.infinity,
                  color: theme.colorScheme.onSurface.withOpacity(0.03),
                  padding: const EdgeInsets.symmetric(horizontal: 16.0),
                  child: ScrollConfiguration(
                    behavior: const ScrollBehavior().copyWith(overscroll: false),
                    child: ListView.builder(
                      scrollDirection: Axis.horizontal,
                      itemCount: pathNodes.length,
                      itemBuilder: (context, idx) {
                        final isLast = idx == pathNodes.length - 1;
                        final String reconstructedPath = isSaf
                            ? pathUris[idx]
                            : (idx > 0
                                ? (rootPath.endsWith('/') ? '$rootPath${pathNodes.sublist(1, idx + 1).join('/')}' : '$rootPath/${pathNodes.sublist(1, idx + 1).join('/')}')
                                : rootPath);
                        return Row(
                          children: [
                            InkWell(
                              borderRadius: BorderRadius.circular(8),
                              onTap: isLast ? null : () => _navigateToBreadcrumb(reconstructedPath),
                              child: Padding(
                                padding: const EdgeInsets.symmetric(horizontal: 6.0, vertical: 4.0),
                                child: Text(pathNodes[idx],
                                  style: TextStyle(
                                    fontSize: 12.5,
                                    fontWeight: isLast ? FontWeight.bold : FontWeight.w500,
                                    color: isLast
                                        ? theme.colorScheme.onSurface.withOpacity(0.9)
                                        : theme.colorScheme.primary,
                                  )),
                              ),
                            ),
                            if (!isLast)
                              Icon(Icons.chevron_right_rounded, size: 14, color: theme.colorScheme.onSurface.withOpacity(0.3)),
                          ],
                        );
                      },
                    ),
                  ),
                ),

                // File list
                Expanded(
                  child: _items.isEmpty
                      ? Center(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(Broken.folder_open, size: 56, color: theme.colorScheme.onSurface.withOpacity(0.2)),
                              const SizedBox(height: 14),
                              Text(L10n.of(context).msga21f6ab1,
                                style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold,
                                  color: theme.colorScheme.onSurface.withOpacity(0.4))),
                              if (hasLocalClipboard) ...[
                                const SizedBox(height: 12),
                                ElevatedButton.icon(
                                  onPressed: _uploadFromLocalClipboard,
                                  icon: const Icon(Icons.upload_rounded, size: 16),
                                  label: Text(L10n.of(context).msge1c538b8),
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: theme.colorScheme.primary, foregroundColor: Colors.white,
                                    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                                  ),
                                ),
                              ],
                            ],
                          ),
                        )
                      : ScrollConfiguration(
                          behavior: const ScrollBehavior().copyWith(overscroll: false),
                          child: ListView.builder(
                            physics: const BouncingScrollPhysics(),
                            padding: const EdgeInsets.symmetric(vertical: 8.0),
                            itemCount: _items.length,
                            itemBuilder: (context, index) {
                              final item = _items[index];
                              final isInRemoteClip = provider.isRemoteClipboard && provider.remoteClipboardItems.any((e) => e.path == item.path);

                              return ListTile(
                                selected: _isSelectionMode && _selectedPaths.contains(item.path),
                                selectedTileColor: theme.colorScheme.primary.withOpacity(0.08),
                                leading: _buildRemoteItemLeading(context, item, theme),
                                title: Text(item.name,
                                  style: TextStyle(
                                    fontSize: 14, fontWeight: FontWeight.w600,
                                    color: isInRemoteClip ? theme.colorScheme.primary.withOpacity(0.6) : null,
                                    decoration: (isInRemoteClip && provider.isCut)
                                        ? TextDecoration.lineThrough : null,
                                  ),
                                  overflow: TextOverflow.ellipsis),
                                subtitle: Text(
                                  item.isDirectory
                                      ? L10n.of(context).msg1f4c1042
                                      : '${item.formattedSize} • ${item.modified.toLocal().toString().substring(0, 10)}',
                                  style: TextStyle(fontSize: 11.5, color: theme.colorScheme.onSurface.withOpacity(0.4)),
                                ),
                                trailing: _isSelectionMode
                                    ? Checkbox(
                                        value: _selectedPaths.contains(item.path),
                                        onChanged: (val) {
                                          setState(() {
                                            if (val == true) {
                                              _selectedPaths.add(item.path);
                                            } else {
                                              _selectedPaths.remove(item.path);
                                            }
                                          });
                                        },
                                        activeColor: theme.colorScheme.primary,
                                      )
                                    : PopupMenuButton<String>(
                                        icon: Icon(Icons.more_vert_rounded, size: 18, color: theme.colorScheme.onSurface.withOpacity(0.4)),
                                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                                        onSelected: (value) async {
                                          switch (value) {
                                            case 'copy': _copyRemoteItem(item); break;
                                            case 'cut': _cutRemoteItem(item); break;
                                            case 'rename': await _renameRemoteItem(item); break;
                                            case 'paste': await _pasteRemoteClipboard(); break;
                                            case 'delete': await _deleteItem(item); break;
                                            case 'select': _enterSelectionMode(item); break;
                                          }
                                        },
                                        itemBuilder: (context) => [
                                          _popItem('select', Broken.tick_square, '多选', theme.colorScheme.primary),
                                          const PopupMenuDivider(),
                                          _popItem('copy', Broken.copy, '复制', theme.colorScheme.primary),
                                          _popItem('cut', Broken.scissor, '剪切', Colors.orange),
                                          _popItem('rename', Broken.edit, L10n.of(context).msgc8ce4b36, Color(0xFF0D9488)),
                                          if (hasRemoteClipboard)
                                            _popItem('paste', Icons.content_paste_rounded, L10n.of(context).msg419be096, Color(0xFF0D9488)),
                                          const PopupMenuDivider(),
                                          _popItem('delete', Broken.trash, '删除', Colors.redAccent),
                                        ],
                                      ),
                                onTap: () {
                                  if (_isSelectionMode) {
                                    setState(() {
                                      if (_selectedPaths.contains(item.path)) {
                                        _selectedPaths.remove(item.path);
                                      } else {
                                        _selectedPaths.add(item.path);
                                      }
                                    });
                                  } else {
                                    _navigateTo(item);
                                  }
                                },
                                onLongPress: () {
                                  if (_isSelectionMode) {
                                    setState(() {
                                      if (_selectedPaths.contains(item.path)) {
                                        _selectedPaths.remove(item.path);
                                      } else {
                                        _selectedPaths.add(item.path);
                                      }
                                    });
                                  } else {
                                    _enterSelectionMode(item);
                                  }
                                },
                              );
                            },
                          ),
                        ),
                ),
              ],
            ),

          // Transfer overlay
          if (_isTransferring)
            _buildTransferOverlay(theme, isDark),
        ],
      ),
    ),
    );
  }

  /// 构建远程文件列表项的 leading 图标或缩略图
  Widget _buildRemoteItemLeading(BuildContext context, RemoteFileItem item, ThemeData theme) {
    final ext = p.extension(item.name).toLowerCase();
    final isImage = ['.jpg', '.jpeg', '.png', '.gif', '.webp', '.bmp', '.heic', '.svg'].contains(ext);
    final isVideo = ['.mp4', '.mkv', '.avi', '.mov', '.wmv', '.flv', '.webm', '.m4v', '.3gp'].contains(ext);
    final isAudio = ['.mp3', '.aac', '.wav', '.flac', '.m4a', '.ogg', '.opus', '.wma', '.amr'].contains(ext);
    final enableThumbnail = PreferencesService.getRemoteMediaThumbnailPreview();

    if (item.isDirectory) {
      return Container(
        width: 40,
        height: 40,
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: theme.colorScheme.primary.withOpacity(0.1),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Icon(Broken.folder_open, size: 20, color: theme.colorScheme.primary.withOpacity(0.9)),
      );
    }

    if (!enableThumbnail || (!isImage && !isVideo && !isAudio)) {
      // 默认文件图标
      IconData iconData = Broken.document;
      if (isVideo) iconData = Broken.video;
      else if (['.mp3', '.aac', '.wav', '.flac', '.m4a', '.ogg'].contains(ext)) iconData = Broken.audio_square;
      else if (['.txt', '.log', '.md', '.json', '.xml', '.html'].contains(ext)) iconData = Broken.document_text;
      else if (['.zip', '.rar', '.7z', '.tar', '.gz'].contains(ext)) iconData = Broken.archive;

      return Container(
        width: 40,
        height: 40,
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: theme.colorScheme.primary.withOpacity(0.04),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Icon(iconData, size: 20, color: theme.colorScheme.primary.withOpacity(0.6)),
      );
    }

    // 缩略图模式
    return FutureBuilder<String?>(
      future: _getRemoteThumbnailPath(item),
      builder: (context, snapshot) {
        if (snapshot.hasData && snapshot.data != null) {
          return ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: Image.file(
              File(snapshot.data!),
              width: 40,
              height: 40,
              fit: BoxFit.cover,
              errorBuilder: (_, __, ___) => _buildDefaultFileIcon(ext, theme),
            ),
          );
        }
        return Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: theme.colorScheme.primary.withOpacity(0.04),
            borderRadius: BorderRadius.circular(12),
          ),
          child: const Center(
            child: SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
          ),
        );
      },
    );
  }

  Widget _buildDefaultFileIcon(String ext, ThemeData theme) {
    IconData iconData = Broken.document;
    if (['.mp4', '.mkv', '.avi', '.mov', '.wmv'].contains(ext)) iconData = Broken.video;
    else if (['.mp3', '.aac', '.wav', '.flac'].contains(ext)) iconData = Broken.audio_square;
    else if (['.txt', '.log', '.md'].contains(ext)) iconData = Broken.document_text;

    return Container(
      width: 40,
      height: 40,
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: theme.colorScheme.primary.withOpacity(0.04),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Icon(iconData, size: 20, color: theme.colorScheme.primary.withOpacity(0.6)),
    );
  }

  /// 获取远程文件缩略图路径，如果不存在则下载
  Future<String?> _getRemoteThumbnailPath(RemoteFileItem item) async {
    if (_client == null) return null;
    try {
      // 优先使用外部存储，失败则回退到应用私有目录
      Directory? thumbDir;
      Directory? tempDir;
      try {
        // 统一缩略图缓存路径为 thumbnails/remote（与 file_item.dart 一致）
        thumbDir = Directory('/storage/emulated/0/Download/ZenFile_Remote/cache/thumbnails/remote');
        if (!thumbDir.existsSync()) thumbDir.createSync(recursive: true);
        tempDir = Directory('/storage/emulated/0/Download/ZenFile_Remote/cache/temp');
        if (!tempDir.existsSync()) tempDir.createSync(recursive: true);
      } catch (_) {
        final appDir = await getApplicationDocumentsDirectory();
        thumbDir = Directory(p.join(appDir.path, 'ZenFile_Remote', 'cache', 'thumbnails', 'remote'));
        if (!thumbDir.existsSync()) thumbDir.createSync(recursive: true);
        tempDir = Directory(p.join(appDir.path, 'ZenFile_Remote', 'cache', 'temp'));
        if (!tempDir.existsSync()) tempDir.createSync(recursive: true);
      }
      
      final thumbName = '${item.path.replaceAll('/', '_')}_thumb.jpg';
      final thumbPath = p.join(thumbDir.path, thumbName);
      final thumbFile = File(thumbPath);

      if (await thumbFile.exists()) {
        return thumbPath;
      }

      // 下载文件到临时位置
      final tempPath = p.join(tempDir.path, 'remote_temp_${DateTime.now().millisecondsSinceEpoch}${p.extension(item.name)}');
      await _client!.downloadFile(item.path, tempPath, (_) {});

      // 如果是图片，直接复制作为缩略图
      final ext = p.extension(item.name).toLowerCase();
      if (['.jpg', '.jpeg', '.png', '.gif', '.webp', '.bmp', '.heic'].contains(ext)) {
        await File(tempPath).copy(thumbPath);
      } else if (['.mp4', '.mkv', '.avi', '.mov', '.wmv', '.flv', '.webm', '.m4v', '.3gp'].contains(ext)) {
        // 视频缩略图：通过原生 MediaMetadataRetriever 生成
        final thumbBytes = await MediaThumbnailService.generateVideoThumbnail(tempPath);
        if (thumbBytes != null && thumbBytes.isNotEmpty) {
          await thumbFile.writeAsBytes(thumbBytes, flush: true);
        }
      } else if (['.mp3', '.aac', '.wav', '.flac', '.m4a', '.ogg', '.opus', '.wma', '.amr'].contains(ext)) {
        // 音频缩略图：通过原生 MediaMetadataRetriever 提取内嵌封面
        final thumbBytes = await MediaThumbnailService.generateAudioThumbnail(tempPath);
        if (thumbBytes != null && thumbBytes.isNotEmpty) {
          await thumbFile.writeAsBytes(thumbBytes, flush: true);
        }
      }

      // 清理临时文件
      try { await File(tempPath).delete(); } catch (_) {}

      if (await thumbFile.exists()) {
        return thumbPath;
      }
      return null;
    } catch (e) {
      return null;
    }
  }

  /// 进入多选模式
  void _enterSelectionMode(RemoteFileItem item) {
    setState(() {
      _isSelectionMode = true;
      _selectedPaths.clear();
      _selectedPaths.add(item.path);
    });
  }

  /// 批量下载选中的文件到设备
  Future<void> _batchDownloadSelected() async {
    if (_client == null || _selectedPaths.isEmpty) return;
    final selectedItems = _items.where((item) => _selectedPaths.contains(item.path)).toList();
    final localBase = '/storage/emulated/0/Download/ZenFile_Remote';

    setState(() {
      _isTransferring = true;
      _transferProgress = 0.0;
      _transferLabel = '正在下载 ${selectedItems.length} 个文件...';
    });

    try {
      int completed = 0;
      for (final item in selectedItems) {
        _transferFileName = item.name;
        final localPath = '$localBase/${item.path.replaceAll('/', '_')}';
        final localFile = File(localPath);
        await localFile.parent.create(recursive: true);
        await _client!.downloadFile(item.path, localPath, (_) {});
        completed++;
        setState(() => _transferProgress = completed / selectedItems.length);
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('已下载 ${completed} 个文件'), behavior: SnackBarBehavior.floating),
        );
      }
    } catch (e) {
      if (mounted) {
        _showSnack(L10n.of(context).e19(e), isError: true);
      }
    } finally {
      if (mounted) {
        setState(() {
          _isTransferring = false;
          _isSelectionMode = false;
          _selectedPaths.clear();
        });
      }
    }
  }

  /// 批量复制选中的远程文件到远程剪贴板
  void _batchCopySelected() {
    final selectedItems = _items.where((item) => _selectedPaths.contains(item.path)).toList();
    if (selectedItems.isEmpty) return;
    final provider = context.read<FileManagerProvider>();
    provider.setRemoteClipboard(selectedItems, isCut: false, connection: widget.connection);
    setState(() {
      _isSelectionMode = false;
      _selectedPaths.clear();
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('已复制 ${selectedItems.length} 个项目'), behavior: SnackBarBehavior.floating),
    );
  }

  /// 批量剪切选中的远程文件到远程剪贴板
  void _batchCutSelected() {
    final selectedItems = _items.where((item) => _selectedPaths.contains(item.path)).toList();
    if (selectedItems.isEmpty) return;
    final provider = context.read<FileManagerProvider>();
    provider.setRemoteClipboard(selectedItems, isCut: true, connection: widget.connection);
    setState(() {
      _isSelectionMode = false;
      _selectedPaths.clear();
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('已剪切 ${selectedItems.length} 个项目'), behavior: SnackBarBehavior.floating),
    );
  }

  /// 批量删除选中的远程文件
  Future<void> _batchDeleteSelected() async {
    if (_client == null || _selectedPaths.isEmpty) return;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text(L10n.of(context).msg50eaf94d),
        content: Text(L10n.of(context).selectedcount2(_selectedPaths.length)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(foregroundColor: Colors.redAccent),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirm != true) return;

    setState(() {
      _isTransferring = true;
      _transferLabel = L10n.of(context).msgcb0da17b;
      _transferProgress = 0.0;
    });

    try {
      int completed = 0;
      for (final path in _selectedPaths.toList()) {
        final item = _items.firstWhere((i) => i.path == path);
        _transferFileName = item.name;
        await _client!.delete(path, item.isDirectory);
        completed++;
        setState(() => _transferProgress = completed / _selectedPaths.length);
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('已删除 ${completed} 个项目'), behavior: SnackBarBehavior.floating),
        );
      }
      _loadDirectoryContents(_currentPath);
    } catch (e) {
      if (mounted) {
        _showSnack('删除失败: $e', isError: true);
      }
    } finally {
      if (mounted) {
        setState(() {
          _isTransferring = false;
          _isSelectionMode = false;
          _selectedPaths.clear();
        });
      }
    }
  }

  PopupMenuItem<String> _popItem(String value, IconData icon, String label, Color color) {
    return PopupMenuItem<String>(
      value: value,
      child: Row(
        children: [
          Icon(icon, size: 16, color: color),
          const SizedBox(width: 10),
          Text(label, style: TextStyle(fontSize: 13, color: color, fontWeight: FontWeight.w500)),
        ],
      ),
    );
  }

  Widget _buildClipboardBanner(ThemeData theme, bool hasLocal, bool hasRemote, FileManagerProvider provider) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      color: theme.colorScheme.primary.withOpacity(0.08),
      child: Row(
        children: [
          Icon(hasLocal ? Icons.upload_rounded : Icons.content_paste_rounded,
            size: 18, color: theme.colorScheme.primary),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              hasLocal
                  ? '${provider.clipboardPaths.length} local file(s) ready to upload'
                  : '${provider.remoteClipboardItems.length} remote item(s) ${provider.isCut ? "cut" : "copied"}',
              style: TextStyle(fontSize: 12, color: theme.colorScheme.primary, fontWeight: FontWeight.w600),
            ),
          ),
          if (hasLocal)
            TextButton(
              onPressed: _uploadFromLocalClipboard,
              style: TextButton.styleFrom(
                foregroundColor: Colors.white,
                backgroundColor: theme.colorScheme.primary,
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                minimumSize: Size.zero,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              ),
              child: const Text('上传', style: TextStyle(fontSize: 12)),
            ),
          if (hasRemote)
            TextButton(
              onPressed: _pasteRemoteClipboard,
              style: TextButton.styleFrom(
                foregroundColor: Colors.white,
                backgroundColor: theme.colorScheme.primary,
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                minimumSize: Size.zero,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              ),
              child: const Text('粘贴', style: TextStyle(fontSize: 12)),
            ),
          const SizedBox(width: 4),
          GestureDetector(
            onTap: () {
              provider.clearClipboard();
            },
            child: Icon(Icons.close_rounded, size: 18, color: theme.colorScheme.onSurface.withOpacity(0.4)),
          ),
        ],
      ),
    );
  }

  Widget _buildTransferOverlay(ThemeData theme, bool isDark) {
    return Container(
      color: Colors.black.withOpacity(0.45),
      width: double.infinity,
      height: double.infinity,
      child: Center(
        child: Card(
          color: isDark ? const Color(0xFF1E293B) : Colors.white,
          elevation: 16,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32.0, vertical: 28.0),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  height: 72, width: 72,
                  child: CircularProgressIndicator(
                    strokeWidth: 5,
                    value: _transferProgress,
                    valueColor: AlwaysStoppedAnimation<Color>(theme.colorScheme.primary),
                    backgroundColor: theme.colorScheme.primary.withOpacity(0.15),
                  ),
                ),
                const SizedBox(height: 20),
                Text(_transferLabel,
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold,
                    color: theme.colorScheme.onSurface.withOpacity(0.9), fontFamily: 'LexendDeca')),
                const SizedBox(height: 4),
                SizedBox(
                  width: 200,
                  child: Text(_transferFileName,
                    style: TextStyle(fontSize: 12, color: theme.colorScheme.onSurface.withOpacity(0.5)),
                    textAlign: TextAlign.center, maxLines: 1, overflow: TextOverflow.ellipsis),
                ),
                const SizedBox(height: 10),
                Text('${(_transferProgress * 100).toInt()}%',
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: theme.colorScheme.primary)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
