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
import '../../services/pin_service.dart';
import '../../core/navigator_key.dart';
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
            _buildMenuItem(
              context: context,
              icon: Broken.folder_favorite,
              label: L10n.of(context).ui_favorite,
              onTap: () {
                Navigator.pop(context);
                final selectedPaths = provider.selectedPaths.toList();
                final isRemote = provider.currIsRemote;
                final connectionId = provider.activeTab.remoteConnection?.id;
                for (final path in selectedPaths) {
                  final name = p.basename(path);
                  final isDir = isRemote ? true : Directory(path).existsSync();
                  provider.addFavorite(path, name, isDir, isRemote: isRemote, connectionId: connectionId);
                }
                final effectiveContext = outerContext ?? context;
                if (effectiveContext.mounted) {
                  ScaffoldMessenger.of(effectiveContext).showSnackBar(
                    SnackBar(
                      content: Text(L10n.of(effectiveContext).msg_favorited(p.basename(selectedPaths.first))),
                      behavior: SnackBarBehavior.floating,
                      duration: const Duration(seconds: 2),
                    ),
                  );
                }
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
                  try {
                    await provider.deleteSelected();
                  } catch (e) {
                    if (effectiveContext.mounted) {
                      ScaffoldMessenger.of(effectiveContext).showSnackBar(
                        SnackBar(content: Text(L10n.of(effectiveContext).msg_delete_failed(e)), behavior: SnackBarBehavior.floating),
                      );
                    }
                  }
                }
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
            _buildMoreButton(context),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }

  Widget _buildMoreButton(BuildContext context) {
    final theme = Theme.of(context);
    return PopupMenuButton<String>(
      icon: Row(
        children: [
          Icon(Broken.more, color: theme.colorScheme.onSurface.withOpacity(0.8), size: 22),
          const SizedBox(width: 16),
          Text(L10n.of(context).ui_more, style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: theme.colorScheme.onSurface)),
        ],
      ),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      position: PopupMenuPosition.under,
      elevation: 8,
      onSelected: (action) async {
        Navigator.pop(context);
        final effectiveContext = outerContext ?? context;
        if (action == 'compress') {
          final selectedPaths = provider.selectedPaths.toList();
          final firstSelected = selectedPaths.isNotEmpty
              ? p.basename(selectedPaths.first)
              : 'archive';
          final res = await CreateArchiveDialog.show(
            effectiveContext,
            initialName: firstSelected,
            isMultiSelection: provider.selectedPaths.length > 1,
          );
          if (res != null) {
            // 用根 navigator context，避免 selectedPaths.clear() 退出选择模式后
            // widget context 失效导致进度弹窗和刷新异常
            final rootContext = navigatorKey.currentContext ?? effectiveContext;
            await provider.createArchive(
              archiveName: res.archiveName,
              format: res.format,
              compressionLevel: res.compressionLevel,
              password: res.password,
              splitSizeMB: res.splitSizeMB,
              deleteSource: res.deleteSource,
              separateArchives: res.separateArchives,
              targetPaths: selectedPaths,
              context: rootContext,
            );
          }
        } else if (action == 'share') {
          final selectedPaths = provider.selectedPaths.toList();
          await FolderShareService.sharePaths(effectiveContext, selectedPaths);
        } else if (action == 'select_all') {
          provider.selectAll();
        } else if (action == 'pin_to_top') {
          final selected = provider.selectedPaths.toList();
          final allPinned = selected.every((p) => PinService.isPinned(p));
          for (final path in selected) {
            if (allPinned) {
              await PinService.unpin(path);
            } else {
              await PinService.pin(path);
            }
          }
        } else if (action == 'properties') {
          showDialog(
            context: effectiveContext,
            builder: (context) => PropertiesModalDialog(
              selectedPaths: provider.selectedPaths.toList(),
              provider: provider,
            ),
          );
        }
      },
      itemBuilder: (context) {
        return [
          PopupMenuItem(value: 'compress', child: Row(children: [Icon(Broken.box_add, size: 20), SizedBox(width: 12), Text(L10n.of(context).ui_compress)])),
          PopupMenuItem(value: 'share', child: Row(children: [Icon(Icons.share_outlined, size: 20), SizedBox(width: 12), Text(L10n.of(context).ui_share)])),
          PopupMenuItem(value: 'select_all', child: Row(children: [Icon(Broken.tick_square, size: 20), SizedBox(width: 12), Text(L10n.of(context).msg_select_all)])),
          PopupMenuItem(value: 'pin_to_top', child: Row(children: [Icon(Icons.push_pin, size: 20), SizedBox(width: 12), Text(L10n.of(context).ui_pin_to_top)])),
          const PopupMenuDivider(),
          PopupMenuItem(value: 'properties', child: Row(children: [Icon(Broken.info_circle, size: 20), SizedBox(width: 12), Text(L10n.of(context).msg1058354c)])),
        ];
      },
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
