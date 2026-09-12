import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:zenfile/l10n/generated/app_localizations.dart';

import '../../core/utils.dart';
import '../../providers/file_manager_provider.dart';
import '../../services/crypt/crypt.dart';

/// 远程加密目录浏览器（v1 只读）
///
/// 列出后端（SFTP/WebDAV/SMB/FTP）上 rclone crypt 目录的**解密后**文件名，
/// 支持进入子目录、点开文件（经 crypt 流式服务边拉取密文边本地解密播放/查看）。
///
/// 每个目录用一个独立的 Screen 实例承载（push 进入子目录），
/// [virtualPath] 形如 `cryptremote://{connId}|{serverEncryptedPath}`。
class RemoteCryptExplorerScreen extends StatefulWidget {
  final String virtualPath;

  /// 展示标题（解密后的目录名），为空时回退到通用标题
  final String title;

  const RemoteCryptExplorerScreen({
    super.key,
    required this.virtualPath,
    this.title = '',
  });

  @override
  State<RemoteCryptExplorerScreen> createState() =>
      _RemoteCryptExplorerScreenState();
}

class _RemoteCryptExplorerScreenState extends State<RemoteCryptExplorerScreen> {
  bool _loading = true;
  String _error = '';
  List<CryptFileEntry> _entries = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = '';
    });
    try {
      final provider = context.read<FileManagerProvider>();
      final entries = await provider.listRemoteCryptDir(widget.virtualPath);
      if (!mounted) return;
      setState(() {
        _entries = entries;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '$e';
      });
    }
  }

  void _open(CryptFileEntry entry) {
    if (entry.isDirectory) {
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => RemoteCryptExplorerScreen(
            virtualPath: entry.virtualPath,
            title: entry.name,
          ),
        ),
      );
      return;
    }
    // 文件：交给 provider 的 cryptremote 分支流式解密播放/查看
    context.read<FileManagerProvider>().openFile(context, entry.virtualPath);
  }

  String _formatSize(int size) {
    if (size <= 0) return '0 B';
    const suffixes = ['B', 'KB', 'MB', 'GB', 'TB'];
    var i = 0;
    var s = size.toDouble();
    while (s >= 1024 && i < suffixes.length - 1) {
      s /= 1024;
      i++;
    }
    return '${s.toStringAsFixed(1)} ${suffixes[i]}';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = L10n.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title.isNotEmpty
            ? widget.title
            : l10n.vault_inplace_encrypt),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error.isNotEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.error_outline,
                            size: 48, color: theme.colorScheme.error),
                        const SizedBox(height: 12),
                        Text(
                          _error,
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 13,
                            color: theme.colorScheme.onSurface.withOpacity(0.6),
                          ),
                        ),
                        const SizedBox(height: 16),
                        TextButton(onPressed: _load, child: Text(l10n.ui_retry)),
                      ],
                    ),
                  ),
                )
              : _entries.isEmpty
                  ? Center(
                      child: Text(
                        l10n.vault_no_files,
                        style: TextStyle(
                          color: theme.colorScheme.onSurface.withOpacity(0.4),
                          fontSize: 13,
                        ),
                      ),
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 8),
                      itemCount: _entries.length,
                      itemBuilder: (context, index) {
                        final e = _entries[index];
                        final icon = e.isDirectory
                            ? Icons.folder_rounded
                            : FileUtils.getIconForFile(e.name);
                        final color = e.isDirectory
                            ? Colors.teal
                            : FileUtils.getColorForFile(e.name, context);
                        return Container(
                          margin: const EdgeInsets.symmetric(vertical: 4),
                          decoration: BoxDecoration(
                            color: isDark
                                ? Colors.white.withOpacity(0.03)
                                : Colors.black.withOpacity(0.02),
                            borderRadius: BorderRadius.circular(14),
                          ),
                          child: ListTile(
                            onTap: () => _open(e),
                            leading: Container(
                              width: 44,
                              height: 44,
                              decoration: BoxDecoration(
                                color: color.withOpacity(0.12),
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: Icon(icon, color: color, size: 24),
                            ),
                            title: Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    e.name,
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w600,
                                      fontSize: 14,
                                    ),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                                if (e.isEncrypted) ...[
                                  const SizedBox(width: 6),
                                  const Icon(Icons.lock,
                                      size: 13, color: Colors.teal),
                                ],
                              ],
                            ),
                            subtitle: Text(
                              e.isDirectory
                                  ? l10n.vault_item_folder
                                  : _formatSize(e.size),
                              style: TextStyle(
                                fontSize: 11.5,
                                color:
                                    theme.colorScheme.onSurface.withOpacity(0.5),
                              ),
                            ),
                            trailing: e.isDirectory
                                ? const Icon(Icons.chevron_right_rounded)
                                : const Icon(Icons.play_circle_outline_rounded),
                          ),
                        );
                      },
                    ),
    );
  }
}
