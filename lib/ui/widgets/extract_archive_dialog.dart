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

  /// 已预检到压缩包加密：未填密码时不允许开始解压（否则会解出 0 字节文件）。
  final bool passwordRequired;

  /// 上一次解压因密码错误失败：直接给出红色错误提示并聚焦到密码框。
  final bool passwordRejected;

  /// 回填密码（例如让用户接着修改上一次输入）。
  final String? initialPassword;

  const ExtractArchiveDialog({
    super.key,
    required this.archiveName,
    required this.archiveDir,
    this.archivePath,
    this.passwordRequired = false,
    this.passwordRejected = false,
    this.initialPassword,
  });

  static Future<ExtractArchiveResult?> show(
    BuildContext context, {
    required String archiveName,
    required String archiveDir,
    String? archivePath,
    bool passwordRequired = false,
    bool passwordRejected = false,
    String? initialPassword,
  }) {
    return showDialog<ExtractArchiveResult>(
      context: context,
      builder: (_) => ExtractArchiveDialog(
        archiveName: archiveName,
        archiveDir: archiveDir,
        archivePath: archivePath,
        passwordRequired: passwordRequired,
        passwordRejected: passwordRejected,
        initialPassword: initialPassword,
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

  /// 密码相关的即时错误（红色提示），null 表示无错误。
  String? _passwordError;

  @override
  void initState() {
    super.initState();
    _passwordController =
        TextEditingController(text: widget.initialPassword ?? '');
    // 默认解压目标 = 压缩包所在位置（archivePath 有值时优先取其父目录，否则用 archiveDir）
    _destDir = widget.archivePath != null && widget.archivePath!.isNotEmpty
        ? p.dirname(widget.archivePath!)
        : widget.archiveDir;
    if (widget.passwordRejected) {
      _obscurePassword = false;
    }
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

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // 一律走强类型本地化 getter：此前这里用 dynamic 调用 + 中文 fallback 兜底，
    // key 缺失时会静默降级成硬编码中文（界面其它文案是英文、只有某一行是中文），
    // 编译期与运行期都无从察觉。改强类型后缺 key 会直接编译失败。
    final l10n = L10n.of(context);
    final msgExtractTo = l10n.msg_extract_to;
    final msgExtractTargetFolder = l10n.msg_extract_target_folder;
    final msgHintPassword = l10n.msgff69affd;
    final msgCancel = l10n.ui_cancel;
    final msgExtract = l10n.ui_extract;
    final msgBrowse = l10n.ui_browse;

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
                      color: theme.colorScheme.secondary.withValues(alpha: 0.1),
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
                          style: theme.textTheme.bodySmall?.copyWith(color: theme.textTheme.bodySmall?.color?.withValues(alpha: 0.6)),
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
                  color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.35),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: theme.colorScheme.outlineVariant.withValues(alpha: 0.45)),
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
                            style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurface.withValues(alpha: 0.55)),
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
                        backgroundColor: theme.colorScheme.primary.withValues(alpha: 0.08),
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
                autofocus: widget.passwordRequired || widget.passwordRejected,
                decoration: InputDecoration(
                  labelText: msgHintPassword,
                  errorText: _passwordError ??
                      (widget.passwordRejected
                          ? l10n.msg_archive_password_invalid
                          : null),
                  helperText: widget.passwordRequired && !widget.passwordRejected
                      ? l10n.msg_archive_password_required
                      : null,
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
                      final pw = _passwordController.text;
                      // 已知加密包却没填密码：原地提示，不要带着空密码去解压
                      // （那会解出一堆 0 字节文件，像压缩包损坏）。
                      if (widget.passwordRequired && pw.isEmpty) {
                        setState(() {
                          _passwordError = l10n.msg_archive_password_required;
                        });
                        return;
                      }

                      Navigator.pop(
                        context,
                        ExtractArchiveResult(
                          destinationDir: dest,
                          password: pw.isNotEmpty ? pw : null,
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
