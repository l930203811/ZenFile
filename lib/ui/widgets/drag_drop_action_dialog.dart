import 'dart:io';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:path/path.dart' as p;
import '../../providers/file_manager_provider.dart';
import '../../services/archive_service.dart';
import '../../core/icon_fonts/broken_icons.dart';
import '../../core/utils.dart';
import 'create_archive_dialog.dart';
import 'package:zenfile/l10n/generated/app_localizations.dart';

class DragDropActionDialog extends StatefulWidget {
  final List<String> sourcePaths;
  final String initialTargetPath;
  final BuildContext parentContext;

  const DragDropActionDialog({
    super.key,
    required this.sourcePaths,
    required this.initialTargetPath,
    required this.parentContext,
  });

  static Future<void> show({
    required BuildContext context,
    required List<String> sourcePaths,
    required String initialTargetPath,
  }) {
    return showDialog(
      context: context,
      barrierDismissible: true,
      builder: (_) => DragDropActionDialog(
        sourcePaths: sourcePaths,
        initialTargetPath: initialTargetPath,
        parentContext: context,
      ),
    );
  }

  @override
  State<DragDropActionDialog> createState() => _DragDropActionDialogState();
}

class _DragDropActionDialogState extends State<DragDropActionDialog> {
  String _selectedAction = 'move'; // 'move', 'copy', 'archive'

  IconData _getFileIcon() {
    if (widget.sourcePaths.length > 1) {
      return Broken.document_copy;
    }
    final path = widget.sourcePaths.first;
    if (Directory(path).existsSync()) {
      return Broken.folder;
    }
    return FileUtils.getIconForFile(path);
  }

  Color _getFileIconColor(BuildContext context) {
    if (widget.sourcePaths.length > 1) {
      return Theme.of(context).colorScheme.primary;
    }
    final path = widget.sourcePaths.first;
    if (Directory(path).existsSync()) {
      return Theme.of(context).colorScheme.primary;
    }
    return FileUtils.getColorForFile(path, context);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final provider = context.watch<FileManagerProvider>();
    final selectedCount = widget.sourcePaths.length;
    final isSingle = selectedCount == 1;
    final itemName = isSingle ? p.basename(widget.sourcePaths.first) : L10n.of(context).selectedcount(selectedCount.toString());

    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
      elevation: 12,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 400),
        child: SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.all(24.0),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // 文件信息
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: _getFileIconColor(context).withOpacity(0.12),
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Icon(
                        _getFileIcon(),
                        color: _getFileIconColor(context),
                        size: 28,
                      ),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            itemName,
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 15,
                              color: theme.colorScheme.onSurface,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          const SizedBox(height: 2),
                          Text(
                            widget.initialTargetPath,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 11,
                              color: theme.colorScheme.onSurface.withOpacity(0.5),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),

                const SizedBox(height: 20),

                _buildActionCard(
                  theme: theme,
                  action: 'move',
                  title: L10n.of(context).ui_move,
                  icon: Broken.scissor,
                  color: Colors.orange,
                  isDisabled: widget.sourcePaths.every((path) => p.posix.dirname(path) == widget.initialTargetPath),
                ),
                _buildActionCard(
                  theme: theme,
                  action: 'copy',
                  title: L10n.of(context).ui_copy,
                  icon: Broken.document_copy,
                  color: Colors.blue,
                ),
                _buildActionCard(
                  theme: theme,
                  action: 'archive',
                  title: L10n.of(context).ui_compress,
                  icon: Broken.box_add,
                  color: Colors.teal,
                ),

                const SizedBox(height: 20),

                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton(
                      onPressed: () => Navigator.pop(context),
                      style: TextButton.styleFrom(
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                      ),
                      child: Text(
                        L10n.of(context).ui_cancel,
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          color: theme.colorScheme.onSurface.withOpacity(0.55),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Container(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(16),
                        boxShadow: [
                          BoxShadow(
                            color: theme.colorScheme.primary.withOpacity(0.35),
                            blurRadius: 12,
                            offset: const Offset(0, 4),
                          )
                        ],
                      ),
                      child: ElevatedButton(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: theme.colorScheme.primary,
                          foregroundColor: theme.colorScheme.onPrimary,
                          elevation: 0,
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                          padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 14),
                        ),
                        onPressed: () => _executeAction(provider),
                        child: Text(
                          L10n.of(context).ui_apply,
                          style: TextStyle(
                            fontWeight: FontWeight.w900,
                            fontSize: 14,
                            letterSpacing: 0.5,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildActionCard({
    required ThemeData theme,
    required String action,
    required String title,
    required IconData icon,
    required Color color,
    bool isDisabled = false,
  }) {
    final isSelected = _selectedAction == action;

    return Opacity(
      opacity: isDisabled ? 0.45 : 1.0,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 6),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          boxShadow: isSelected
              ? [
                  BoxShadow(
                    color: color.withOpacity(0.04),
                    blurRadius: 8,
                    offset: const Offset(0, 4),
                  )
                ]
              : null,
        ),
        child: Card(
          margin: EdgeInsets.zero,
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: BorderSide(
              color: isSelected ? color : theme.colorScheme.onSurface.withOpacity(0.08),
              width: isSelected ? 2.0 : 1.0,
            ),
          ),
          color: isSelected ? color.withOpacity(0.06) : theme.colorScheme.surface,
          child: InkWell(
            borderRadius: BorderRadius.circular(16),
            onTap: isDisabled
                ? null
                : () {
                    setState(() {
                      _selectedAction = action;
                    });
                  },
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: color.withOpacity(0.12),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Icon(icon, color: color, size: 22),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Text(
                      title,
                      style: TextStyle(
                        fontWeight: isSelected ? FontWeight.w900 : FontWeight.bold,
                        fontSize: 15,
                        color: isSelected ? color : theme.colorScheme.onSurface,
                      ),
                    ),
                  ),
                  Container(
                    width: 22,
                    height: 22,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: isSelected ? color : theme.colorScheme.onSurface.withOpacity(0.25),
                        width: 2.0,
                      ),
                      color: isSelected ? color : Colors.transparent,
                    ),
                    child: isSelected
                        ? const Icon(
                            Icons.check,
                            color: Colors.white,
                            size: 14,
                          )
                        : null,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _executeAction(FileManagerProvider provider) async {
    Navigator.pop(context);

    final stableContext = widget.parentContext;
    final targetPath = widget.initialTargetPath;

    // 找到目标路径所在的tab索引并激活
    int targetTabIndex = provider.activeTabIndex;
    final tabs = provider.tabs;
    for (int i = 0; i < tabs.length; i++) {
      if (tabs[i].currentPath == targetPath) {
        targetTabIndex = i;
        break;
      }
    }
    provider.setActiveTab(targetTabIndex);

    if (_selectedAction == 'move') {
      // 通过剪贴板+pasteFile路径获得字节级进度
      provider.setClipboard(widget.sourcePaths, isCut: true);
      await provider.pasteFileToTab(stableContext, targetTabIndex, clearAfterPaste: true);
      provider.clearSelection();
    } else if (_selectedAction == 'copy') {
      // 通过剪贴板+pasteFile路径获得字节级进度
      provider.setClipboard(widget.sourcePaths, isCut: false);
      await provider.pasteFileToTab(stableContext, targetTabIndex, clearAfterPaste: true);
      provider.clearSelection();
    } else if (_selectedAction == 'archive') {
      final isSingle = widget.sourcePaths.length == 1;
      final initialName = isSingle ? p.basename(widget.sourcePaths.first) : L10n.of(widget.parentContext).ui_compress;
      if (!stableContext.mounted) return;
      final res = await CreateArchiveDialog.show(stableContext, initialName: initialName, isMultiSelection: !isSingle);

      if (res != null) {
        provider.activeTab.isLoading = true;
        provider.notifyListeners();

        try {
          await ArchiveService.createArchive(
            sourcePaths: widget.sourcePaths,
            destinationDir: widget.initialTargetPath,
            archiveName: res.archiveName,
            format: res.format,
            compressionLevel: res.compressionLevel,
            password: res.password,
            splitSizeMB: res.splitSizeMB,
            deleteSource: res.deleteSource,
            separateArchives: res.separateArchives,
          );
          
          if (stableContext.mounted) {
            ScaffoldMessenger.of(stableContext).showSnackBar(
              SnackBar(
                content: Text(L10n.of(stableContext).ui_drag_archive_created('${res.archiveName}.${res.format}')),
                behavior: SnackBarBehavior.floating,
              ),
            );
          }
        } catch (e) {
          debugPrint('Error creating drag-drop archive: $e');
          if (stableContext.mounted) {
            ScaffoldMessenger.of(stableContext).showSnackBar(
              SnackBar(
                content: Text(L10n.of(stableContext).ui_drag_archive_failed(e.toString())),
                backgroundColor: Colors.redAccent,
                behavior: SnackBarBehavior.floating,
              ),
            );
          }
        }

        provider.clearSelection();
        await provider.loadDirectory(provider.currentPath, showLoading: false);
      }
    }
  }
}
