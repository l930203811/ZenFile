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
  final String currentDir;

  const ExtractArchiveDialog({
    super.key,
    required this.archiveName,
    required this.currentDir,
  });

  static Future<ExtractArchiveResult?> show(BuildContext context, {required String archiveName, required String currentDir}) {
    return showDialog<ExtractArchiveResult>(
      context: context,
      builder: (_) => ExtractArchiveDialog(archiveName: archiveName, currentDir: currentDir),
    );
  }

  @override
  State<ExtractArchiveDialog> createState() => _ExtractArchiveDialogState();
}

class _ExtractArchiveDialogState extends State<ExtractArchiveDialog> {
  late TextEditingController _passwordController;
  late String _customDestDir;
  bool _useCurrentDir = true;
  bool _obscurePassword = true;

  @override
  void initState() {
    super.initState();
    _passwordController = TextEditingController();
    _customDestDir = widget.currentDir;
  }

  @override
  void dispose() {
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _pickCustomDirectory() async {
    final result = await InternalFilePickerScreen.show(
      context,
      rootPath: '/storage/emulated/0',
      pickDirectory: true,
    );
    if (result != null && result.isNotEmpty && mounted) {
      setState(() {
        _customDestDir = result.first;
      });
    }
  }

  String get _effectiveDestDir => _useCurrentDir ? widget.currentDir : _customDestDir;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

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
                          L10n.of(context).msg_extract_to,
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

              // 当前目录复选框
              InkWell(
                onTap: () => setState(() => _useCurrentDir = true),
                borderRadius: BorderRadius.circular(12),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
                  child: Row(
                    children: [
                      Checkbox(
                        value: _useCurrentDir,
                        onChanged: (v) => setState(() => _useCurrentDir = v ?? true),
                      ),
                      const SizedBox(width: 4),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              L10n.of(context).ui_current_directory,
                              style: theme.textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.w600),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              widget.currentDir,
                              style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurface.withOpacity(0.6)),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),

              // 自定义目录复选框 + 按钮
              InkWell(
                onTap: () => setState(() => _useCurrentDir = false),
                borderRadius: BorderRadius.circular(12),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
                  child: Row(
                    children: [
                      Checkbox(
                        value: !_useCurrentDir,
                        onChanged: (v) => setState(() => _useCurrentDir = !(v ?? false)),
                      ),
                      const SizedBox(width: 4),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              L10n.of(context).ui_custom_directory,
                              style: theme.textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.w600),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              _customDestDir,
                              style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurface.withOpacity(0.6)),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ],
                        ),
                      ),
                      TextButton(
                        onPressed: !_useCurrentDir ? _pickCustomDirectory : null,
                        child: Text(L10n.of(context).ui_browse),
                      ),
                    ],
                  ),
                ),
              ),

              const SizedBox(height: 16),

              // Password
              TextField(
                controller: _passwordController,
                obscureText: _obscurePassword,
                decoration: InputDecoration(
                  labelText: L10n.of(context).msgff69affd,
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
                    child: Text(L10n.of(context).ui_cancel),
                  ),
                  const SizedBox(width: 12),
                  FilledButton(
                    onPressed: () {
                      final dest = _effectiveDestDir.trim();
                      if (dest.isEmpty) return;

                      Navigator.pop(
                        context,
                        ExtractArchiveResult(
                          destinationDir: dest,
                          password: _passwordController.text.isNotEmpty ? _passwordController.text : null,
                        ),
                      );
                    },
                    child: Text(L10n.of(context).ui_extract),
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
