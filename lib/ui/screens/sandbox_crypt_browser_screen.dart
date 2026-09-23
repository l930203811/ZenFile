import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:zenfile/l10n/generated/app_localizations.dart';

import '../../core/utils.dart';
import '../../providers/file_manager_provider.dart';
import '../../services/crypt/crypt.dart';

/// 沙盒加密目录浏览器（保险箱 → 沙盒加密「文件夹」点进去）
///
/// 与 `RemoteCryptExplorerScreen` 同一套交互，区别只在数据源：这里用**本地沙盒
/// 挂载点**的 [CryptDirectoryLister] 直接在磁盘上解密列名并下钻子目录。
///
/// 点开文件时交给 [FileManagerProvider.openFile]（crypt 视图的统一打开链路）：
/// 它会临时解密成**文件名正确的**实体文件、用内置查看器/播放器打开（apk 走内置
/// 安装器），并在操作结束后自动清理临时文件 —— 不要把这段逻辑在本页重写一遍。
class SandboxCryptBrowserScreen extends StatefulWidget {
  /// 沙盒（`isSandboxMode`）挂载点，密码需已用主密码补齐。
  final CryptMountPoint mount;

  /// 待浏览目录的**虚拟（明文）路径**，形如 `<sandboxRoot>/<明文目录名>`。
  /// 用虚拟路径而非磁盘密文路径：[CryptMountPoint.resolvePhysicalPath] 的语义
  /// 就是「明文虚拟路径 → 磁盘密文路径」，少一次目录扫描兜底。
  final String virtualPath;

  /// 展示标题（解密后的目录名）
  final String title;

  const SandboxCryptBrowserScreen({
    super.key,
    required this.mount,
    required this.virtualPath,
    this.title = '',
  });

  @override
  State<SandboxCryptBrowserScreen> createState() =>
      _SandboxCryptBrowserScreenState();
}

class _SandboxCryptBrowserScreenState extends State<SandboxCryptBrowserScreen> {
  bool _loading = true;
  String _error = '';
  List<CryptFileEntry> _entries = const [];

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
      final entries = await CryptDirectoryLister(widget.mount)
          .listDirectory(widget.virtualPath);
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
          builder: (_) => SandboxCryptBrowserScreen(
            mount: widget.mount,
            virtualPath: entry.virtualPath,
            title: entry.name,
          ),
        ),
      );
      return;
    }
    // 统一打开链路：临时解密（扩展名用解密后的真实名）→ 内置查看器/播放器/
    // 内置安装器 → 操作结束后自动清理临时文件。
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
                        return _buildEntryTile(context, theme, l10n, isDark, e);
                      },
                    ),
    );
  }

  Widget _buildEntryTile(
    BuildContext context,
    ThemeData theme,
    L10n l10n,
    bool isDark,
    CryptFileEntry e,
  ) {
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
              const Icon(Icons.lock, size: 13, color: Colors.teal),
            ],
          ],
        ),
        subtitle: Text(
          e.isDirectory ? l10n.vault_item_folder : _formatSize(e.size),
          style: TextStyle(
            fontSize: 11.5,
            color: theme.colorScheme.onSurface.withOpacity(0.5),
          ),
        ),
        trailing: e.isDirectory
            ? const Icon(Icons.chevron_right_rounded)
            : const Icon(Icons.play_circle_outline_rounded),
      ),
    );
  }
}
