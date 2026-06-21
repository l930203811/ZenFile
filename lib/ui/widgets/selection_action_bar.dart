import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import '../../providers/file_manager_provider.dart';
import '../../core/icon_fonts/broken_icons.dart';
import '../../core/utils.dart';
import '../../services/pin_service.dart';
import 'file_action_dialogs.dart';
import 'create_archive_dialog.dart';
import 'package:share_plus/share_plus.dart';
import 'batch_rename_dialog.dart';
import '../../services/folder_share_service.dart';
import 'package:zenfile/l10n/generated/app_localizations.dart';

class SelectionActionBar extends StatelessWidget {
  final FileManagerProvider provider;

  const SelectionActionBar({super.key, required this.provider});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final selectedCount = provider.selectedPaths.length;
    final hasClipboard = provider.hasClipboard;

    return Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.08),
            blurRadius: 16,
            offset: const Offset(0, -4),
          ),
        ],
      ),
      child: SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Selected count indicator
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 6),
              decoration: BoxDecoration(
                color: theme.colorScheme.primary.withOpacity(0.06),
                border: Border(
                  bottom: BorderSide(color: theme.colorScheme.primary.withOpacity(0.1)),
                ),
              ),
              child: Center(
                child: Text(
                  L10n.of(context).selectedcount(provider.selectedPaths.length),
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: theme.colorScheme.primary,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
            _ActionButton(
              icon: Broken.document_copy,
              label: L10n.of(context).ui_copy,
              hideLabel: provider.hideActionText,
              onTap: () {
                provider.copySelected();
                // ScaffoldMessenger.of(context).showSnackBar(
                //   SnackBar(content: Text('Copied $selectedCount item(s)')),
                // );
              },
            ),
            _ActionButton(
              icon: Broken.scissor,
              label: L10n.of(context).ui_cut,
              hideLabel: provider.hideActionText,
              onTap: () {
                provider.cutSelected();
                // ScaffoldMessenger.of(context).showSnackBar(
                //   SnackBar(content: Text('Cut $selectedCount item(s)')),
                // );
              },
            ),
            _ActionButton(
              icon: Broken.edit,
              label: L10n.of(context).msgc8ce4b36,
              hideLabel: provider.hideActionText,
              onTap: () async {
                if (selectedCount == 1) {
                  final path = provider.selectedPaths.first;
                  final currentName = p.basename(path);
                  final newName = await FileActionDialogs.showTextInputDialog(
                    context,
                    title: L10n.of(context).msgc8ce4b36,
                    hint: L10n.of(context).msgf139c5cf,
                    initialValue: currentName,
                    actionText: L10n.of(context).msgc8ce4b36,
                  );
                  if (newName != null && newName.isNotEmpty) {
                    await provider.renameFile(path, newName);
                    provider.clearSelection();
                  }
                } else if (selectedCount > 1) {
                  await BatchRenameDialog.show(context, provider);
                }
              },
            ),
            _ActionButton(
              icon: Broken.trash,
              label: L10n.of(context).ui_delete,
              color: Colors.redAccent,
              hideLabel: provider.hideActionText,
              onTap: () async {
                final confirm = await FileActionDialogs.showConfirmDialog(
                  context,
                  title: L10n.of(context).msgcd0b9aca,
                  content: L10n.of(context).selectedcount2(provider.selectedPaths.length),
                );
                if (confirm) {
                  await provider.deleteSelected();
                }
              },
            ),
            _ActionButton(
              icon: Broken.info_circle,
              label: L10n.of(context).ui_properties,
              hideLabel: provider.hideActionText,
              onTap: () => _showPropertiesModal(context, provider),
            ),
            PopupMenuButton<String>(
              icon: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Broken.more, size: 24),
                  if (!provider.hideActionText) ...[
                    const SizedBox(height: 4),
                    Text(L10n.of(context).ui_more, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w500)),
                  ],
                ],
              ),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              position: PopupMenuPosition.under,
              elevation: 8,
              onSelected: (action) async {
                if (action == 'extract') {
                  final selectedPaths = provider.selectedPaths.toList();
                  final archivePath = selectedPaths.firstWhere((p) => FileUtils.isArchive(p), orElse: () => '');
                  if (archivePath.isNotEmpty) {
                    await provider.extractArchiveDirectly(
                      context,
                      archivePath,
                    );
                  }
                } else if (action == 'archive') {
                  final res = await CreateArchiveDialog.show(
                    context,
                    initialName: p.basename(provider.currentPath).isEmpty ? 'archive' : p.basename(provider.currentPath),
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
                      context: context,
                    );
                  }
                } else if (action == 'paste') {
                  await provider.pasteFile(context);
                  provider.clearSelection();
                } else if (action == 'select_all') {
                  provider.selectAll();
                } else if (action == 'share') {
                  final selectedPaths = provider.selectedPaths.toList();
                  await FolderShareService.sharePaths(context, selectedPaths);
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
                  provider.refreshDirectoryView();
                  provider.clearSelection();
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(allPinned ? L10n.of(context).msga9b87614 : L10n.of(context).ui_pinned_selected),
                        behavior: SnackBarBehavior.floating,
                      ),
                    );
                  }
                }
              },
              itemBuilder: (context) {
                final selected = provider.selectedPaths.toList();
                final allPinned = selected.isNotEmpty && selected.every((p) => PinService.isPinned(p));
                final hasArchive = selected.any((p) => FileUtils.isArchive(p));
                return [
                  if (hasArchive)
                    PopupMenuItem(
                      value: 'extract',
                      child: Row(
                        children: [
                          const Icon(Broken.box, size: 20),
                          const SizedBox(width: 12),
                          Text(L10n.of(context).ui_extract, style: const TextStyle(fontWeight: FontWeight.w500)),
                        ],
                      ),
                    ),
                  PopupMenuItem(
                    value: 'archive',
                    child: Row(
                      children: [
                        const Icon(Broken.box_add, size: 20),
                        const SizedBox(width: 12),
                        Text(L10n.of(context).ui_compress, style: const TextStyle(fontWeight: FontWeight.w500)),
                      ],
                    ),
                  ),
                  if (hasClipboard)
                    PopupMenuItem(
                      value: 'paste',
                      child: Row(
                        children: [
                          const Icon(Broken.clipboard, size: 20),
                          const SizedBox(width: 12),
                          Text(L10n.of(context).msg419be096, style: const TextStyle(fontWeight: FontWeight.w500)),
                        ],
                      ),
                    ),
                  PopupMenuItem(
                    value: 'share',
                    child: Row(
                      children: [
                        const Icon(Icons.share_outlined, size: 20),
                        const SizedBox(width: 12),
                        Text(L10n.of(context).ui_share, style: const TextStyle(fontWeight: FontWeight.w500)),
                      ],
                    ),
                  ),
                  PopupMenuItem(
                    value: 'select_all',
                    child: Row(
                      children: [
                        const Icon(Broken.tick_square, size: 20),
                        const SizedBox(width: 12),
                        Text(L10n.of(context).ui_select_all, style: const TextStyle(fontWeight: FontWeight.w500)),
                      ],
                    ),
                  ),
                  PopupMenuItem(
                    value: 'pin_to_top',
                    child: Row(
                      children: [
                        Icon(
                          allPinned ? Icons.push_pin_rounded : Icons.push_pin_outlined,
                          size: 20,
                          color: allPinned ? Colors.orange : null,
                        ),
                        const SizedBox(width: 12),
                        Text(allPinned ? L10n.of(context).msg84e4fac9 : L10n.of(context).ui_pin_to_top, style: const TextStyle(fontWeight: FontWeight.w500)),
                      ],
                    ),
                  ),
                ];
              },
            ),
          ],
        ),
        const SizedBox(height: 8),
      ],
    ),
      ),
    );
  }

  void _showPropertiesModal(BuildContext context, FileManagerProvider provider) {
    final selectedPaths = provider.selectedPaths.toList();
    if (selectedPaths.isEmpty) return;

    showDialog(
      context: context,
      builder: (context) => PropertiesModalDialog(selectedPaths: selectedPaths, provider: provider),
    );
  }
}

class PropertiesModalDialog extends StatefulWidget {
  final List<String> selectedPaths;
  final FileManagerProvider provider;

  const PropertiesModalDialog({super.key, required this.selectedPaths, required this.provider});

  @override
  State<PropertiesModalDialog> createState() => PropertiesModalDialogState();
}

class PropertiesModalDialogState extends State<PropertiesModalDialog> {
  bool _isLoading = true;
  int _totalBytes = 0;
  int _folderCount = 0;
  int _fileCount = 0;
  DateTime? _lastModified;
  String _permissions = '';
  String _mimeType = '';

  @override
  void initState() {
    super.initState();
    _calculateProperties();
  }

  Future<void> _calculateProperties() async {
    int bytes = 0;
    int folders = 0;
    int files = 0;

    final currentFilesMap = {for (var f in widget.provider.currentFiles) f.path: f};

    for (final path in widget.selectedPaths) {
      try {
        final type = FileSystemEntity.typeSync(path);
        if (type == FileSystemEntityType.directory) {
          folders++;
          final dir = Directory(path);
          if (dir.existsSync()) {
            if (widget.selectedPaths.length == 1) {
              final stat = dir.statSync();
              _lastModified = stat.modified;
              _permissions = '${(stat.mode & 0x100) != 0 ? "读取" : ""}${(stat.mode & 0x80) != 0 ? " / 写入" : ""}';
            }
            try {
              await for (final entity in dir.list(recursive: true, followLinks: false)) {
                if (entity is File) {
                  files++;
                  bytes += await entity.length();
                } else if (entity is Directory) {
                  folders++;
                }
              }
            } catch (_) {}
          }
        } else if (type == FileSystemEntityType.file) {
          files++;
          final f = File(path);
          if (f.existsSync()) {
            bytes += f.lengthSync();
            if (widget.selectedPaths.length == 1) {
              final stat = f.statSync();
              _lastModified = stat.modified;
              _permissions = '${(stat.mode & 0x100) != 0 ? "读取" : ""}${(stat.mode & 0x80) != 0 ? " / 写入" : ""}';
            }
          }
        } else {
          // Fallback if restricted/Shizuku
          final item = currentFilesMap[path];
          if (item != null) {
            if (item.isDirectory) {
              folders++;
            } else {
              files++;
              bytes += item.size;
            }
          }
        }
      } catch (_) {
        final item = currentFilesMap[path];
        if (item != null) {
          if (item.isDirectory) {
            folders++;
          } else {
            files++;
            bytes += item.size;
          }
        }
      }
    }

    if (widget.selectedPaths.length == 1) {
      final pStr = widget.selectedPaths.first;
      final ext = pStr.contains('.') ? pStr.substring(pStr.lastIndexOf('.')).toLowerCase() : '';
      if (folders > 0) {
        _mimeType = 'Folder / Directory';
      } else {
        _mimeType = ext.isNotEmpty ? 'File ($ext)' : 'File';
      }
    }

    if (mounted) {
      setState(() {
        _totalBytes = bytes;
        _folderCount = folders;
        _fileCount = files;
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final count = widget.selectedPaths.length;
    final isSingle = count == 1;
    final nameDisplay = isSingle ? p.basename(widget.selectedPaths.first) : '$count items selected';

    return AlertDialog(
      title: Row(
        children: [
          Icon(Broken.info_circle, color: theme.colorScheme.primary, size: 28),
          const SizedBox(width: 12),
          Text(L10n.of(context).ui_properties, style: TextStyle(fontWeight: FontWeight.bold)),
        ],
      ),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      content: _isLoading
          ? Padding(
              padding: const EdgeInsets.all(32.0),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const CircularProgressIndicator(),
                  const SizedBox(height: 16),
                  Text(L10n.of(context).msg3be9abab, style: TextStyle(color: Colors.grey)),
                ],
              ),
            )
          : SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (isSingle) ...[
                    _CopyablePropertyRow(label: L10n.of(context).ui_name, value: nameDisplay),
                    _CopyablePropertyRow(label: L10n.of(context).ui_path, value: widget.selectedPaths.first),
                    _CopyablePropertyRow(
                      label: L10n.of(context).ui_size,
                      value: '${FileUtils.formatBytes(_totalBytes, 2)} ($_totalBytes bytes)',
                    ),
                    if (_mimeType == 'Folder / Directory')
                      _CopyablePropertyRow(
                        label: L10n.of(context).ui_contains,
                        value: '${_folderCount - 1} subfolder(s), $_fileCount file(s)',
                      ),
                    if (_lastModified != null)
                      _CopyablePropertyRow(label: L10n.of(context).msg1303e638, value: FileUtils.formatDate(_lastModified!)),
                    if (_mimeType.isNotEmpty) _CopyablePropertyRow(label: L10n.of(context).ui_type, value: _mimeType),
                    if (_permissions.isNotEmpty) _CopyablePropertyRow(label: L10n.of(context).ui_permissions, value: _permissions),
                  ] else ...[
                    _CopyablePropertyRow(
                      label: L10n.of(context).msg880a18f3,
                      value: '$count items ($_folderCount folder(s), $_fileCount file(s))',
                    ),
                    _CopyablePropertyRow(
                      label: L10n.of(context).msgea9ecb93,
                      value: '${FileUtils.formatBytes(_totalBytes, 2)} ($_totalBytes bytes)',
                    ),
                    const SizedBox(height: 12),
                    Text(L10n.of(context).msg7704aa2c, style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
                    const SizedBox(height: 8),
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxHeight: 180),
                      child: Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: theme.colorScheme.surfaceVariant.withOpacity(0.5),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: SingleChildScrollView(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: widget.selectedPaths
                                .map((path) => Padding(
                                      padding: const EdgeInsets.only(bottom: 6.0),
                                      child: SelectableText(
                                        p.basename(path),
                                        style: const TextStyle(fontSize: 13, fontFamily: 'monospace'),
                                      ),
                                    ))
                                .toList(),
                          ),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
      actions: [
        FilledButton(
          onPressed: () => Navigator.pop(context),
          style: FilledButton.styleFrom(shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
          child: Text(L10n.of(context).ui_done),
        ),
      ],
    );
  }
}

class _ActionButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final Color? color;
  final bool hideLabel;

  const _ActionButton({
    required this.icon,
    required this.label,
    required this.onTap,
    this.color,
    this.hideLabel = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final displayColor = color ?? theme.colorScheme.onSurface;

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: displayColor, size: 24),
            if (!hideLabel) ...[
              const SizedBox(height: 4),
              Text(
                label,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w500,
                  color: displayColor,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _CopyablePropertyRow extends StatelessWidget {
  final String label;
  final String value;

  const _CopyablePropertyRow({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    if (value.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.only(bottom: 8.0),
      child: InkWell(
        onTap: () {
          Clipboard.setData(ClipboardData(text: value));
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(L10n.of(context).label1(label)), duration: const Duration(seconds: 1)),
          );
        },
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6.0, horizontal: 8.0),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                flex: 3,
                child: Text(
                  label,
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: theme.colorScheme.primary),
                ),
              ),
              Expanded(
                flex: 7,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Text(
                        value,
                        style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
                        softWrap: true,
                      ),
                    ),
                    const SizedBox(width: 4),
                    Icon(Broken.document_copy, size: 14, color: theme.colorScheme.onSurface.withOpacity(0.4)),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
