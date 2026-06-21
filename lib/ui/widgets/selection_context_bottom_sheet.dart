import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import '../../providers/file_manager_provider.dart';
import '../../core/icon_fonts/broken_icons.dart';
import '../../core/utils.dart';
import 'selection_action_bar.dart'; // To access PropertiesModalDialog
import 'file_action_dialogs.dart';
import 'create_archive_dialog.dart';
import 'package:share_plus/share_plus.dart';
import 'batch_rename_dialog.dart';
import '../../services/folder_share_service.dart';
import 'package:zenfile/l10n/generated/app_localizations.dart';

class SelectionContextBottomSheet extends StatelessWidget {
  final FileManagerProvider provider;
  final String targetPath; // The path of the specific item that was long pressed
  final BuildContext? outerContext; // The context from the caller (outside the bottom sheet)

  const SelectionContextBottomSheet({
    super.key,
    required this.provider,
    required this.targetPath,
    this.outerContext,
  });

  static Future<void> show(BuildContext context, FileManagerProvider provider, String targetPath) {
    try {
      HapticFeedback.mediumImpact();
    } catch (_) {}

    return showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (innerContext) => SelectionContextBottomSheet(
        provider: provider,
        targetPath: targetPath,
        outerContext: context,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final selectedCount = provider.selectedPaths.length;
    final isSingle = selectedCount == 1;
    final displayTitle = isSingle ? p.basename(targetPath) : L10n.of(context).selectedcount3(provider.selectedPaths.length);
    final isFolder = Directory(targetPath).existsSync() || 
        provider.currentFiles.firstWhere((e) => e.path == targetPath, orElse: () => provider.currentFiles.first).isDirectory;

    return Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.15),
            blurRadius: 24,
            offset: const Offset(0, -4),
          ),
        ],
      ),
      child: SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 38,
                height: 4,
                margin: const EdgeInsets.only(top: 12, bottom: 8),
                decoration: BoxDecoration(
                  color: theme.colorScheme.onSurface.withOpacity(0.15),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            
            GestureDetector(
              onLongPress: (isSingle && !isFolder)
                  ? () {
                      try {
                        HapticFeedback.mediumImpact();
                      } catch (_) {}
                      Navigator.pop(context);
                      provider.openFile(context, targetPath, forceOpenWith: true);
                    }
                  : null,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                child: Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: theme.colorScheme.primary.withOpacity(0.08),
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Icon(
                        !isSingle 
                            ? Broken.tick_square 
                            : isFolder 
                                ? Broken.folder 
                                : Broken.document,
                        color: theme.colorScheme.primary,
                        size: 26,
                      ),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            displayTitle,
                            style: theme.textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.bold,
                              fontSize: 16,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          if (isSingle)
                            Text(
                              isFolder ? L10n.of(context).msg1f4c1042 : L10n.of(context).msg8b73264b,
                              style: TextStyle(
                                fontSize: 12,
                                color: theme.colorScheme.onSurface.withOpacity(0.5),
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                        ],
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Broken.close_circle, size: 24),
                      onPressed: () => Navigator.pop(context),
                    ),
                  ],
                ),
              ),
            ),
            const Divider(height: 1),
            
            _buildMenuItem(
              context: context,
              icon: Broken.document_copy,
              label: L10n.of(context).msgc5c0646c,
              onTap: () {
                Navigator.pop(context);
                provider.copySelected();
                // ScaffoldMessenger.of(context).showSnackBar(
                //   SnackBar(content: Text('Copied $selectedCount item(s)')),
                // );
              },
            ),
            _buildMenuItem(
              context: context,
              icon: Broken.scissor,
              label: L10n.of(context).msg8e6d4604,
              onTap: () {
                Navigator.pop(context);
                provider.cutSelected();
                // ScaffoldMessenger.of(context).showSnackBar(
                //   SnackBar(content: Text('Cut $selectedCount item(s)')),
                // );
              },
            ),
            if (isSingle)
              _buildMenuItem(
                context: context,
                icon: Broken.edit,
                label: L10n.of(context).msgc8ce4b36,
                onTap: () async {
                  final effectiveContext = outerContext ?? context;
                  Navigator.pop(context);
                  final currentName = p.basename(targetPath);
                  final newName = await FileActionDialogs.showTextInputDialog(
                    effectiveContext,
                    title: L10n.of(context).msgc8ce4b36,
                    hint: L10n.of(context).msgf139c5cf,
                    initialValue: currentName,
                    actionText: L10n.of(context).msgc8ce4b36,
                  );
                  if (newName != null && newName.isNotEmpty) {
                    await provider.renameFile(targetPath, newName);
                    provider.clearSelection();
                  }
                },
              )
            else
              _buildMenuItem(
                context: context,
                icon: Broken.edit,
                label: L10n.of(context).msgc8ce4b36,
                onTap: () async {
                  final effectiveContext = outerContext ?? context;
                  Navigator.pop(context);
                  await BatchRenameDialog.show(effectiveContext, provider);
                },
              ),
            if (isSingle && !isFolder)
              _buildMenuItem(
                context: context,
                icon: Broken.eye,
                label: L10n.of(context).msg2a4cfb07,
                onTap: () {
                  final effectiveContext = outerContext ?? context;
                  Navigator.pop(context);
                  provider.openFile(effectiveContext, targetPath, forceOpenWith: true);
                },
              ),
            if (isSingle && !isFolder && FileUtils.isArchive(targetPath))
              _buildMenuItem(
                context: context,
                icon: Broken.box,
                label: L10n.of(context).ui_extract,
                onTap: () async {
                  final effectiveContext = outerContext ?? context;
                  Navigator.pop(context);
                  await provider.extractArchiveDirectly(effectiveContext, targetPath);
                },
              ),
            _buildMenuItem(
              context: context,
              icon: Broken.box_add,
              label: L10n.of(context).ui_compress,
              onTap: () async {
                final effectiveContext = outerContext ?? context;
                Navigator.pop(context);
                // 压缩选中项：默认名称使用第一个选中项的名字，而非当前目录名
                final firstSelected = provider.selectedPaths.isNotEmpty
                    ? p.basename(provider.selectedPaths.first)
                    : 'archive';
                final res = await CreateArchiveDialog.show(
                  effectiveContext,
                  initialName: firstSelected,
                  isMultiSelection: selectedCount > 1,
                );
                if (res != null) {
                  await provider.createArchive(
                    archiveName: res.archiveName,
                    format: res.format,
                    compressionLevel: res.compressionLevel,
                    password: res.password,
                    splitSizeMB: res.splitSizeMB,
                    deleteSource: res.deleteSource,
                    separateArchives: res.separateArchives,
                    targetPaths: provider.selectedPaths.toList(),
                    context: effectiveContext,
                  );
                  provider.clearSelection();
                }
              },
            ),
            _buildMenuItem(
              context: context,
              icon: Icons.share_outlined,
              label: L10n.of(context).ui_share,
              onTap: () async {
                final effectiveContext = outerContext ?? context;
                Navigator.pop(context);
                final selectedPaths = provider.selectedPaths.toList();
                await FolderShareService.sharePaths(effectiveContext, selectedPaths);
              },
            ),
            _buildMenuItem(
              context: context,
              icon: Broken.info_circle,
              label: L10n.of(context).msg1058354c,
              onTap: () {
                final effectiveContext = outerContext ?? context;
                Navigator.pop(context);
                showDialog(
                  context: effectiveContext,
                  builder: (context) => PropertiesModalDialog(
                    selectedPaths: provider.selectedPaths.toList(),
                    provider: provider,
                  ),
                );
              },
            ),
            const Divider(height: 1),
            _buildMenuItem(
              context: context,
              icon: Broken.trash,
              label: L10n.of(context).msgcd0b9aca,
              color: Colors.redAccent,
              onTap: () async {
                final effectiveContext = outerContext ?? context;
                Navigator.pop(context);
                final confirm = await FileActionDialogs.showConfirmDialog(
                  effectiveContext,
                  title: L10n.of(context).msgcd0b9aca,
                  content: L10n.of(context).selectedcount2(selectedCount),
                );
                if (confirm) {
                  await provider.deleteSelected();
                }
              },
            ),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }

  Widget _buildMenuItem({
    required BuildContext context,
    required IconData icon,
    required String label,
    required VoidCallback onTap,
    Color? color,
  }) {
    final theme = Theme.of(context);
    final displayColor = color ?? theme.colorScheme.onSurface;

    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        child: Row(
          children: [
            Icon(icon, color: displayColor.withOpacity(0.8), size: 22),
            const SizedBox(width: 16),
            Text(
              label,
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: displayColor,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
