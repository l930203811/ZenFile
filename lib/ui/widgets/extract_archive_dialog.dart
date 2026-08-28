import 'package:path/path.dart' as p;
import 'package:flutter/material.dart';
import '../../core/icon_fonts/broken_icons.dart';
import '../screens/internal_file_picker_screen.dart';
import 'package:zenfile/l10n/generated/app_localizations.dart';

class ExtractArchiveResult {
  final String destinationDir;
  final String? password;

  ExtractArchiveResult({required this.destinationDir, this.password});
}

class ExtractArchiveDialog extends StatefulWidget {
  final String archiveName;

  /// 压缩包所在的目录路径（解压目标的默认值）。
  final String archiveDir;

  /// 压缩包文件的完整路径（优先使用，可与 archiveDir 同时提供时以该路径的父目录为准）。
  final String? archivePath;

  const ExtractArchiveDialog({
    super.key,
    required this.archiveName,
    required this.archiveDir,
    this.archivePath,
  });

  static Future<ExtractArchiveResult?> show(
    BuildContext context, {
    required String archiveName,
    required String archiveDir,
    String? archivePath,
  }) {
    return showDialog<ExtractArchiveResult>(
      context: context,
      builder: (_) => ExtractArchiveDialog(
        archiveName: archiveName,
        archiveDir: archiveDir,
        archivePath: archivePath,
      ),
    );
  }

  @override
  State<ExtractArchiveDialog> createState() => _ExtractArchiveDialogState();
}

class _ExtractArchiveDialogState extends State<ExtractArchiveDialog> {
  late TextEditingController _passwordController;
  late String _destDir;
  bool _obscurePassword = true;

  @override
  void initState() {
    super.initState();
    _passwordController = TextEditingController();
    // 默认解压目标 = 压缩包所在位置（archivePath 有值时优先取其父目录，否则用 archiveDir）
    _destDir = widget.archivePath != null && widget.archivePath!.isNotEmpty
        ? p.dirname(widget.archivePath!)
        : widget.archiveDir;
  }

  @override
  void dispose() {
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _pickDirectory() async {
    final result = await InternalFilePickerScreen.show(
      context,
      rootPath: _destDir.startsWith('/') ? _destDir : '/storage/emulated/0',
      pickDirectory: true,
    );
    if (result != null && result.isNotEmpty && mounted) {
      setState(() {
        _destDir = result.first;
      });
    }
  }

  /// 取本地化字符串；如未在 arb 中注册则 fallback 到中文，避免 l10n 缺失时崩溃。
  /// 使用 dynamic 调用，绕开编译期 getter 检查（防止 L10n 具体类未注册 key 时直接报 undefined_getter）。
  String _safeL10n(String Function(dynamic l) getter, String fallback) {
    try {
      final dynamic l = L10n.of(context);
      final dynamic v = getter(l);
      if (v == null || v.toString().isEmpty) return fallback;
      return v.toString();
    } catch (_) {
      return fallback;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final msgExtractTo = _safeL10n((l) => l.msg_extract_to, '解压到…');
    final msgExtractTargetFolder = _safeL10n((l) => l.msg_extract_target_folder, '解压到的文件夹');
    final msgHintPassword = _safeL10n((l) => l.msgff69affd, '密码（如果已加密）');
    final msgCancel = _safeL10n((l) => l.ui_cancel, '取消');
    final msgExtract = _safeL10n((l) => l.ui_extract, '解压');
    final msgBrowse = _safeL10n((l) => l.ui_browse, '浏览');

    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      backgroundColor: theme.colorScheme.surface,
      child: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.secondary.withOpacity(0.1),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Icon(Broken.archive, color: theme.colorScheme.secondary, size: 24),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          msgExtractTo,
                          style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold),
                        ),
                        Text(
                          widget.archiveName,
                          style: theme.textTheme.bodySmall?.copyWith(color: theme.textTheme.bodySmall?.color?.withOpacity(0.6)),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 24),

              // 解压目标路径（当前路径 + 自定义路径合并为一行：左边显示当前选择的路径，右侧图标浏览修改）
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerHighest.withOpacity(0.35),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: theme.colorScheme.outlineVariant.withOpacity(0.45)),
                ),
                child: Row(
                  children: [
                    Icon(Broken.folder_2, color: theme.colorScheme.primary, size: 22),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            msgExtractTargetFolder,
                            style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurface.withOpacity(0.55)),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            _destDir,
                            style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600, color: theme.colorScheme.onSurface),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    IconButton(
                      onPressed: _pickDirectory,
                      tooltip: msgBrowse,
                      style: IconButton.styleFrom(
                        backgroundColor: theme.colorScheme.primary.withOpacity(0.08),
                        padding: const EdgeInsets.all(10),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                      ),
                      icon: Icon(Broken.folder_open, color: theme.colorScheme.primary, size: 20),
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 16),

              // Password
              TextField(
                controller: _passwordController,
                obscureText: _obscurePassword,
                decoration: InputDecoration(
                  labelText: msgHintPassword,
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                  prefixIcon: const Icon(Broken.lock),
                  suffixIcon: IconButton(
                    icon: Icon(_obscurePassword ? Broken.eye_slash : Broken.eye),
                    onPressed: () => setState(() => _obscurePassword = !_obscurePassword),
                  ),
                ),
              ),

              const SizedBox(height: 24),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: Text(msgCancel),
                  ),
                  const SizedBox(width: 12),
                  FilledButton(
                    onPressed: () {
                      final dest = _destDir.trim();
                      if (dest.isEmpty) return;

                      Navigator.pop(
                        context,
                        ExtractArchiveResult(
                          destinationDir: dest,
                          password: _passwordController.text.isNotEmpty ? _passwordController.text : null,
                        ),
                      );
                    },
                    child: Text(msgExtract),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
