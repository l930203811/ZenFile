import 'dart:io';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import '../../core/icon_fonts/broken_icons.dart';
import '../../core/utils.dart';
import 'package:zenfile/l10n/generated/app_localizations.dart';

enum ConflictResult {
  overwrite,
  keepBoth,
  skip,
  rename,
  cancel,
}

class ConflictDialogResponse {
  final ConflictResult result;
  final bool applyToAll;
  final String? customName;

  ConflictDialogResponse({
    required this.result,
    required this.applyToAll,
    this.customName,
  });
}

class ConflictDialog extends StatefulWidget {
  final String fileName;
  final File sourceFile;
  final File destFile;

  const ConflictDialog({
    super.key,
    required this.fileName,
    required this.sourceFile,
    required this.destFile,
  });

  static Future<ConflictDialogResponse?> show(
    BuildContext context, {
    required String fileName,
    required File sourceFile,
    required File destFile,
  }) {
    return showDialog<ConflictDialogResponse>(
      context: context,
      barrierDismissible: false,
      builder: (_) => ConflictDialog(
        fileName: fileName,
        sourceFile: sourceFile,
        destFile: destFile,
      ),
    );
  }

  @override
  State<ConflictDialog> createState() => _ConflictDialogState();
}

class _ConflictDialogState extends State<ConflictDialog> {
  bool _applyToAll = false;
  late final FileStat _sourceStat;
  late final FileStat _destStat;
  bool _statsLoaded = false;

  @override
  void initState() {
    super.initState();
    _loadStats();
  }

  Future<void> _loadStats() async {
    try {
      final srcStat = await widget.sourceFile.stat();
      final dstStat = await widget.destFile.stat();
      if (mounted) {
        setState(() {
          _sourceStat = srcStat;
          _destStat = dstStat;
          _statsLoaded = true;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _statsLoaded = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accentColor = theme.colorScheme.primary;

    return AlertDialog(
      title: Row(
        children: [
          Icon(Broken.warning_2, color: Colors.orange, size: 28),
          const SizedBox(width: 12),
          const Expanded(
            child: Text(
              '文件已存在',
              style: TextStyle(fontWeight: FontWeight.bold),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      content: SizedBox(
        width: MediaQuery.of(context).size.width * 0.9,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              '目标文件夹中已存在同名文件"${widget.fileName}"。您想怎么处理？',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurface.withOpacity(0.8),
              ),
            ),
            const SizedBox(height: 20),
            
            // Side-by-side or stacked file details comparison
            if (_statsLoaded)
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Existing File Card
                  Expanded(
                    child: _buildFileComparisonCard(
                      theme: theme,
                      title: '现有文件',
                      size: _destStat.size,
                      modified: _destStat.modified,
                      isNewer: _destStat.modified.isAfter(_sourceStat.modified),
                    ),
                  ),
                  const SizedBox(width: 12),
                  // New File Card
                  Expanded(
                    child: _buildFileComparisonCard(
                      theme: theme,
                      title: L10n.of(context).msge48a7157,
                      size: _sourceStat.size,
                      modified: _sourceStat.modified,
                      isNewer: _sourceStat.modified.isAfter(_destStat.modified),
                    ),
                  ),
                ],
              )
            else
              const Center(
                child: Padding(
                  padding: EdgeInsets.all(16.0),
                  child: CircularProgressIndicator(),
                ),
              ),
            const SizedBox(height: 20),

            // Checkbox for Apply to All
            InkWell(
              onTap: () => setState(() => _applyToAll = !_applyToAll),
              borderRadius: BorderRadius.circular(8),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 8.0, horizontal: 4.0),
                child: Row(
                  children: [
                    SizedBox(
                      width: 24,
                      height: 24,
                      child: Checkbox(
                        value: _applyToAll,
                        onChanged: (val) => setState(() => _applyToAll = val ?? false),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        L10n.of(context).msge59e35b5,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                          color: theme.colorScheme.onSurface.withOpacity(0.8),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 20),

            // Responsive Action Buttons Wrap
            Wrap(
              spacing: 8,
              runSpacing: 8,
              alignment: WrapAlignment.end,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                TextButton(
                  onPressed: () => Navigator.pop(
                    context,
                    ConflictDialogResponse(result: ConflictResult.cancel, applyToAll: false),
                  ),
                  style: TextButton.styleFrom(
                    foregroundColor: Colors.redAccent,
                  ),
                  child: const Text('取消粘贴', style: TextStyle(fontWeight: FontWeight.bold)),
                ),
                OutlinedButton(
                  onPressed: () async {
                    final newName = await _showRenameDialog(context, widget.fileName);
                    if (newName != null && newName.isNotEmpty && context.mounted) {
                      Navigator.pop(
                        context,
                        ConflictDialogResponse(
                          result: ConflictResult.rename,
                          applyToAll: _applyToAll,
                          customName: newName,
                        ),
                      );
                    }
                  },
                  style: OutlinedButton.styleFrom(
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                  child: Text(L10n.of(context).msgc8ce4b36),
                ),
                OutlinedButton(
                  onPressed: () => Navigator.pop(
                    context,
                    ConflictDialogResponse(result: ConflictResult.skip, applyToAll: _applyToAll),
                  ),
                  style: OutlinedButton.styleFrom(
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                  child: const Text('跳过'),
                ),
                OutlinedButton(
                  onPressed: () => Navigator.pop(
                    context,
                    ConflictDialogResponse(result: ConflictResult.keepBoth, applyToAll: _applyToAll),
                  ),
                  style: OutlinedButton.styleFrom(
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                  child: Text(L10n.of(context).msg27dfaae5),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(
                    context,
                    ConflictDialogResponse(result: ConflictResult.overwrite, applyToAll: _applyToAll),
                  ),
                  style: FilledButton.styleFrom(
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                  child: const Text('替换'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFileComparisonCard({
    required ThemeData theme,
    required String title,
    required int size,
    required DateTime modified,
    required bool isNewer,
  }) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceVariant.withOpacity(0.3),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: isNewer ? theme.colorScheme.primary.withOpacity(0.4) : theme.dividerColor.withOpacity(0.1),
          width: isNewer ? 1.8 : 1.0,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 6,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(
                title,
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 13,
                  color: isNewer ? theme.colorScheme.primary : theme.colorScheme.onSurface,
                ),
              ),
              if (isNewer)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.primary.withOpacity(0.15),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    '较新',
                    style: TextStyle(
                      fontSize: 9,
                      fontWeight: FontWeight.bold,
                      color: theme.colorScheme.primary,
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            FileUtils.formatBytes(size, 2),
            style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
          ),
          const SizedBox(height: 4),
          Text(
            FileUtils.formatDate(modified),
            style: TextStyle(
              fontSize: 11,
              color: theme.colorScheme.onSurface.withOpacity(0.6),
            ),
          ),
        ],
      ),
    );
  }

  Future<String?> _showRenameDialog(BuildContext context, String currentName) {
    final controller = TextEditingController(text: currentName);
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(L10n.of(context).msg6cfbf05d),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: '新文件名',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: Text(L10n.of(context).msgc8ce4b36),
          ),
        ],
      ),
    );
  }
}
