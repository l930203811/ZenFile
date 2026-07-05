import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart';
import 'package:provider/provider.dart';
import 'package:path/path.dart' as p;
import 'package:flutter_avif/flutter_avif.dart';
import '../../providers/file_manager_provider.dart';
import '../../providers/media_provider.dart';
import '../../models/file_item_model.dart';
import '../../models/folder_tab_model.dart';
import '../../models/drag_payload.dart';
import '../../models/file_filter_type.dart';
import '../../models/network_connection_model.dart';
import '../../core/icon_fonts/broken_icons.dart';
import 'drag_drop_action_dialog.dart';
import 'package:on_audio_query/on_audio_query.dart';
import '../../services/app_manager_service.dart';
import '../../core/utils.dart';
import 'file_item.dart';
import 'folder_item.dart';
import 'file_grid_item.dart';
import 'folder_grid_item.dart';
import 'drag_drop_handler.dart';
import 'archive_type_icon.dart';
import 'file_type_icon.dart';
import 'restricted_folder_banner.dart';
import 'selection_context_bottom_sheet.dart';
import 'file_action_dialogs.dart';
import 'create_archive_dialog.dart';
import 'batch_rename_dialog.dart';
import 'package:zenfile/l10n/generated/app_localizations.dart';

class PaneBrowser extends StatefulWidget {
  final int tabIndex;
  const PaneBrowser({super.key, required this.tabIndex});

  @override
  State<PaneBrowser> createState() => _PaneBrowserState();
}

class _PaneBrowserState extends State<PaneBrowser> {
  final ScrollController _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _activatePane(FileManagerProvider provider) {
    if (provider.activeTabIndex != widget.tabIndex) {
      provider.setActiveTab(widget.tabIndex);
    }
  }

  String _clipboardLabel(FileManagerProvider provider, BuildContext context) {
    final prefix = provider.isCut ? L10n.of(context).ui_cut : L10n.of(context).ui_copy;
    if (provider.isRemoteClipboard) {
      final items = provider.remoteClipboardItems;
      if (items.isEmpty) return prefix;
      final name = p.basename(items.first.path);
      return items.length > 1 ? '$prefix: $name +${items.length - 1}' : '$prefix: $name';
    }
    final paths = provider.clipboardPaths;
    if (paths.isEmpty) return prefix;
    final name = p.basename(paths.first);
    return paths.length > 1 ? '$prefix: $name +${paths.length - 1}' : '$prefix: $name';
  }

  void _showClipboardMenu(FileManagerProvider provider, ThemeData theme) {
    _activatePane(provider);
    
    final itemNames = <String>[];
    if (provider.isRemoteClipboard) {
      for (final item in provider.remoteClipboardItems) {
        itemNames.add(p.basename(item.path));
      }
    } else {
      for (final path in provider.clipboardPaths) {
        itemNames.add(p.basename(path));
      }
    }
    final l10n = L10n.of(context);
    final prefix = provider.isCut ? l10n.ui_cut : l10n.ui_copy;
    final maxItemHeight = 200.0;

    showDialog(
      context: context,
      barrierColor: Colors.black26,
      builder: (sheetContext) => Stack(
        children: [
          GestureDetector(
            onTap: () => Navigator.pop(sheetContext),
            child: Container(color: Colors.transparent),
          ),
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: Container(
              margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
              decoration: BoxDecoration(
                color: theme.colorScheme.surface,
                borderRadius: BorderRadius.circular(16),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.2),
                    blurRadius: 20,
                    offset: const Offset(0, 8),
                  ),
                ],
              ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 剪贴板内容列表
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: Row(
                children: [
                  Icon(
                    provider.isCut ? Broken.scissor : Broken.clipboard,
                    size: 16,
                    color: provider.isCut ? Colors.orange : theme.colorScheme.primary,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    l10n.ui_cut_copy_items(prefix, itemNames.length),
                    style: theme.textTheme.labelMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                      color: provider.isCut ? Colors.orange : theme.colorScheme.primary,
                    ),
                  ),
                ],
              ),
            ),
            Flexible(
              child: ConstrainedBox(
                constraints: BoxConstraints(maxHeight: maxItemHeight),
                child: ListView.builder(
                  shrinkWrap: true,
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                  itemCount: itemNames.length,
                  itemBuilder: (_, i) => Padding(
                    padding: const EdgeInsets.symmetric(vertical: 3),
                    child: Row(
                      children: [
                        Icon(
                          Icons.insert_drive_file_outlined,
                          size: 14,
                          color: theme.colorScheme.onSurface.withOpacity(0.45),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            itemNames[i],
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurface.withOpacity(0.7),
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 4),
            // 操作按钮
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
              child: Row(
                children: [
                  // 清除按钮（左侧，较小）
                  Expanded(
                    flex: 2,
                    child: OutlinedButton(
                      onPressed: () {
                        Navigator.pop(sheetContext);
                        provider.clearClipboard();
                      },
                      style: OutlinedButton.styleFrom(
                        foregroundColor: theme.colorScheme.error,
                        side: BorderSide(color: theme.colorScheme.error.withOpacity(0.25)),
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                      ),
                      child: Text(l10n.ui_clear, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500)),
                    ),
                  ),
                  const SizedBox(width: 10),
                  // 粘贴按钮（右侧，较大）— 粘贴到当前 pane 对应的 tab
                  Expanded(
                    flex: 5,
                    child: ElevatedButton.icon(
                      onPressed: () async {
                        Navigator.pop(sheetContext);
                        await provider.pasteFileToTab(context, widget.tabIndex, clearAfterPaste: true);
                      },
                      icon: const Icon(Icons.content_paste, size: 16),
                      label: Text(l10n.ui_paste, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: theme.colorScheme.primary,
                        foregroundColor: theme.colorScheme.onPrimary,
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
            ),
          ],
        ),
    );
  }

  void _openFolder(FileManagerProvider provider, String path) {
    _activatePane(provider);
    if (_scrollController.hasClients) {
      provider.saveScrollOffset(provider.tabs[widget.tabIndex].currentPath, _scrollController.offset);
    }
    provider.loadDirectory(path).then((_) {
      if (_scrollController.hasClients) {
        final savedOffset = provider.getSavedScrollOffset(path);
        _scrollController.jumpTo(savedOffset);
      }
    });
  }

  void _goBack(FileManagerProvider provider) async {
    _activatePane(provider);
    if (_scrollController.hasClients) {
      provider.saveScrollOffset(provider.tabs[widget.tabIndex].currentPath, _scrollController.offset);
    }
    final prevPath = p.posix.dirname(provider.tabs[widget.tabIndex].currentPath);
    final handled = await provider.goBack();
    if (handled && _scrollController.hasClients) {
      final savedOffset = provider.getSavedScrollOffset(prevPath);
      _scrollController.jumpTo(savedOffset);
    }
  }

  void _handleAction(BuildContext context, String action, String path) async {
    final provider = context.read<FileManagerProvider>();
    _activatePane(provider);
    switch (action) {
      case 'archive':
        final res = await CreateArchiveDialog.show(
          context,
          initialName: p.posix.basename(path),
          isMultiSelection: false,
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
            targetPaths: [path],
            context: context,
          );
        }
        break;
      case 'extract':
        await provider.extractArchiveDirectly(context, path);
        break;
      case 'copy':
        provider.copyFile(path);
        break;
      case 'cut':
        provider.cutFile(path);
        break;
      case 'rename':
        final isMulti = provider.selectedPaths.isNotEmpty && provider.selectedPaths.contains(path);
        if (isMulti && provider.selectedPaths.length > 1) {
          await BatchRenameDialog.show(context, provider);
        } else {
          final currentName = p.posix.basename(path);
          final newName = await FileActionDialogs.showTextInputDialog(
            context,
            title: L10n.of(context).msgc8ce4b36,
            hint: L10n.of(context).msgf139c5cf,
            initialValue: currentName,
            actionText: L10n.of(context).msgc8ce4b36,
          );
          if (newName != null && newName.isNotEmpty) {
            await provider.renameFile(path, newName);
            if (isMulti) {
              provider.clearSelection();
            }
          }
        }
        break;
      case 'delete':
        final isMulti = provider.selectedPaths.isNotEmpty && provider.selectedPaths.contains(path);
        final confirm = await FileActionDialogs.showConfirmDialog(
          context,
          title: isMulti ? L10n.of(context).msgcd0b9aca : L10n.of(context).msg4b342999,
          content: isMulti
              ? L10n.of(context).count1(provider.selectedPaths.length)
              : L10n.of(context).msgee14ee27,
        );
        if (confirm) {
          try {
            if (isMulti) {
              await provider.deleteSelected();
            } else {
              await provider.deleteFile(path);
            }
          } catch (e) {
            if (context.mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text(L10n.of(context).msg_delete_failed(e)), behavior: SnackBarBehavior.floating),
              );
            }
          }
        }
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final provider = context.watch<FileManagerProvider>();
    
    // 双窗口模式下，如果tabIndex超出范围，显示activeTab
    final FolderTab tab = widget.tabIndex < provider.tabs.length
        ? provider.tabs[widget.tabIndex]
        : provider.activeTab;
    final isActive = widget.tabIndex < provider.tabs.length
        ? provider.activeTabIndex == widget.tabIndex
        : true;
    final isSelectionMode = tab.selectedPaths.isNotEmpty;

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (_) => _activatePane(provider),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeInOut,
        margin: const EdgeInsets.symmetric(horizontal: 0, vertical: 2),
        decoration: BoxDecoration(
          color: theme.colorScheme.surface.withOpacity(isActive ? 1.0 : 0.85),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: isActive 
                ? theme.colorScheme.primary.withOpacity(0.3) 
                : theme.colorScheme.outline.withOpacity(0.08),
            width: isActive ? 1.0 : 0.5,
          ),
          boxShadow: isActive ? [
            BoxShadow(
              color: theme.colorScheme.primary.withOpacity(0.03),
              blurRadius: 2,
              spreadRadius: 0,
            )
          ] : null,
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: Stack(
            children: [
              Column(
                children: [
                  if (tab.isLoading)
                    LinearProgressIndicator(
                      minHeight: 2.0,
                      backgroundColor: theme.colorScheme.primary.withOpacity(0.1),
                      valueColor: AlwaysStoppedAnimation<Color>(theme.colorScheme.primary),
                    ),

                  // 路径已在浏览页顶部显示，此处移除
                  if (provider.filterType != FileFilterType.all)
                    _buildActiveFilterBanner(context, provider),
                  
                  // --- Pane Body ---
                  Expanded(
                    child: DragTarget<DragPayload>(
                      onWillAccept: (data) {
                        if (data == null || data.paths.isEmpty) return false;
                        final sourceParent = p.posix.dirname(data.paths.first);
                        if (sourceParent == tab.currentPath) return false;
                        if (data.paths.any((x) => tab.currentPath == x || tab.currentPath.startsWith(x + p.posix.separator))) return false;
                        return true;
                      },
                      onAccept: (data) async {
                        _activatePane(provider);
                        final targetTabIndex = widget.tabIndex;
                        final targetPath = tab.currentPath;
                        if (provider.showDragDropDialog) {
                          DragDropActionDialog.show(
                            context: context,
                            sourcePaths: data.paths,
                            initialTargetPath: targetPath,
                          );
                        } else if (data.isRemote && data.remoteItems != null && data.connection != null) {
                          // 远程文件拖放到本地目标pane
                          provider.setRemoteClipboard(data.remoteItems!, isCut: true, connection: data.connection!);
                          await provider.pasteFileToTab(context, targetTabIndex, clearAfterPaste: true);
                        } else if (tab.isRemote && tab.remoteClient != null) {
                          // 本地文件拖放到远程目标pane
                          provider.setClipboard(data.paths, isCut: true);
                          await provider.pasteFileToTab(context, targetTabIndex, clearAfterPaste: true);
                        } else {
                          // 本地拖放移动文件 — 通过剪贴板+paste路径获得字节级进度
                          provider.setClipboard(data.paths, isCut: true);
                          await provider.pasteFileToTab(context, targetTabIndex, clearAfterPaste: true);
                        }
                      },
                      builder: (context, candidateData, rejectedData) {
                        return (tab.isLoading && tab.currentFiles.isEmpty)
                            ? const Center(child: CircularProgressIndicator())
                            : tab.needsPermission
                                ? RestrictedFolderBanner(
                                    onEnableRoot: () {
                                      _activatePane(provider);
                                      provider.enableRootMode();
                                    },
                                    onEnableShizuku: () {
                                      _activatePane(provider);
                                      provider.enableShizukuMode();
                                    },
                                    onGoBack: () => _goBack(provider),
                                    isRootAvailable: tab.isRootAvailable,
                                  )
                                : CustomScrollView(
                                      controller: _scrollController,
                                      physics: const BouncingScrollPhysics(parent: AlwaysScrollableScrollPhysics()),
                                      slivers: [
                                      CupertinoSliverRefreshControl(
                                        onRefresh: () => provider.loadDirectoryForTab(widget.tabIndex, tab.currentPath, showLoading: false, clearCache: true),
                                      ),
                                      if (tab.currentFiles.isEmpty)
                                        SliverFillRemaining(
                                          hasScrollBody: false,
                                          child: Center(
                                            child: Padding(
                                              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
                                              child: Column(
                                                mainAxisAlignment: MainAxisAlignment.center,
                                                children: [
                                                  Container(
                                                    padding: const EdgeInsets.all(16),
                                                    decoration: BoxDecoration(
                                                      color: theme.colorScheme.primary.withOpacity(0.08),
                                                      shape: BoxShape.circle,
                                                    ),
                                                    child: Icon(
                                                      Broken.folder_open,
                                                      size: 48,
                                                      color: theme.colorScheme.primary.withOpacity(0.6),
                                                    ),
                                                  ),
                                                  const SizedBox(height: 16),
                                                  Text(
                                                    L10n.of(context).msge9691076,
                                                    style: theme.textTheme.titleMedium?.copyWith(
                                                      fontWeight: FontWeight.bold,
                                                      color: theme.colorScheme.onSurface,
                                                    ),
                                                  ),
                                                ],
                                              ),
                                            ),
                                          ),
                                        )
                                      else
                                        SliverPadding(
                                          padding: EdgeInsets.only(
                                            bottom: 80,
                                            left: provider.isGridView ? 8 : 0,
                                            right: provider.isGridView ? 8 : 0,
                                            top: 8,
                                          ),
                                          sliver: provider.isGridView
                                              ? SliverGrid(
                                                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                                                    crossAxisCount: (MediaQuery.of(context).size.width / (2 * 110 * provider.iconScale)).floor().clamp(1, 4),
                                                    mainAxisSpacing: (12 * provider.itemPaddingMultiplier).clamp(4.0, 24.0),
                                                    crossAxisSpacing: (12 * provider.itemPaddingMultiplier).clamp(4.0, 24.0),
                                                    childAspectRatio: 0.75 / provider.iconScale.clamp(0.7, 1.5),
                                                  ),
                                                  delegate: SliverChildBuilderDelegate(
                                                    (context, index) {
                                                      final item = tab.currentFiles[index];
                                                      final isSelected = tab.selectedPaths.contains(item.path);
                                                      if (item.isDirectory) {
                                                        final itemLongPress = () {
                                                          _activatePane(provider);
                                                          if (isSelectionMode && isSelected) {
                                                            SelectionContextBottomSheet.show(context, provider, item.path);
                                                          } else {
                                                            provider.toggleSelection(item.path);
                                                          }
                                                        };
                                                        return DragDropHandler(
                                                          path: item.path,
                                                          isDirectory: true,
                                                          onLongPress: itemLongPress,
                                                          isRemote: item.isRemote,
                                                          remoteItems: item.remoteSource != null ? [item.remoteSource!] : null,
                                                          connection: item.isRemote ? tab.remoteConnection : null,
                                                          child: FolderGridItem(
                                                            folder: item,
                                                            isSelected: isSelected,
                                                            iconScale: provider.iconScale,
                                                            itemPaddingMultiplier: provider.itemPaddingMultiplier,
                                                            onTap: () {
                                                              _activatePane(provider);
                                                              if (isSelectionMode) {
                                                                provider.toggleSelection(item.path);
                                                              } else {
                                                                _openFolder(provider, item.path);
                                                              }
                                                            },
                                                            onLongPress: provider.enableDragDrop ? null : itemLongPress,
                                                            onIconTap: itemLongPress,
                                                            onAction: (action) => _handleAction(context, action, item.path),
                                                          ),
                                                        );
                                                      } else {
                                                        final itemLongPress = () {
                                                          _activatePane(provider);
                                                          if (isSelectionMode && isSelected) {
                                                            SelectionContextBottomSheet.show(context, provider, item.path);
                                                          } else {
                                                            provider.toggleSelection(item.path);
                                                          }
                                                        };
                                                        return DragDropHandler(
                                                          path: item.path,
                                                          isDirectory: false,
                                                          onLongPress: itemLongPress,
                                                          isRemote: item.isRemote,
                                                          remoteItems: item.remoteSource != null ? [item.remoteSource!] : null,
                                                          connection: item.isRemote ? tab.remoteConnection : null,
                                                          child: FileGridItem(
                                                            file: item,
                                                            isSelected: isSelected,
                                                            iconScale: provider.iconScale,
                                                            itemPaddingMultiplier: provider.itemPaddingMultiplier,
                                                            onTap: () {
                                                              _activatePane(provider);
                                                              if (isSelectionMode) {
                                                                provider.toggleSelection(item.path);
                                                              } else {
                                                                provider.openFile(context, item.path);
                                                              }
                                                            },
                                                            onLongPress: provider.enableDragDrop ? null : itemLongPress,
                                                            onIconTap: itemLongPress,
                                                            onAction: (action) => _handleAction(context, action, item.path),
                                                          ),
                                                        );
                                                      }
                                                    },
                                                    childCount: tab.currentFiles.length,
                                                  ),
                                                )
                                              : SliverList(
                                                  delegate: SliverChildBuilderDelegate(
                                                    (context, index) {
                                                      final item = tab.currentFiles[index];
                                                      final isSelected = tab.selectedPaths.contains(item.path);
                                                      if (item.isDirectory) {
                                                        return _buildCompactFolderItem(
                                                          context,
                                                          provider,
                                                          item,
                                                          isSelected,
                                                          isSelectionMode,
                                                          tab.remoteConnection,
                                                        );
                                                      } else {
                                                        return _buildCompactFileItem(
                                                          context,
                                                          provider,
                                                          item,
                                                          isSelected,
                                                          isSelectionMode,
                                                          tab.remoteConnection,
                                                        );
                                                      }
                                                    },
                                                    childCount: tab.currentFiles.length,
                                                  ),
                                                ),
                                        ),
                                      ],
                                    );
                      },
                    ),
                  ),
                ],
              ),
              // 剪贴板按钮（双窗口模式，两 pane 各自右上角显示，点击粘贴到该 pane）
              if (provider.hasClipboard)
                Positioned(
                  top: 6,
                  right: 8,
                  child: GestureDetector(
                    onTap: () => _showClipboardMenu(provider, theme),
                    child: Container(
                      height: 26,
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(13),
                        color: provider.isCut
                            ? Colors.orange.withOpacity(0.12)
                            : theme.colorScheme.primary.withOpacity(0.12),
                        border: Border.all(
                          color: provider.isCut
                              ? Colors.orange.withOpacity(0.3)
                              : theme.colorScheme.primary.withOpacity(0.3),
                          width: 1,
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withOpacity(0.1),
                            blurRadius: 6,
                            offset: const Offset(0, 2),
                          ),
                        ],
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            provider.isCut ? Broken.scissor : Broken.clipboard,
                            size: 13,
                            color: provider.isCut
                                ? Colors.orange
                                : theme.colorScheme.primary,
                          ),
                          const SizedBox(width: 4),
                          ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 90),
                            child: Text(
                              _clipboardLabel(provider, context),
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.bold,
                                color: provider.isCut
                                    ? Colors.orange
                                    : theme.colorScheme.primary,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              // 文件传输进度条覆盖层
              Positioned.fill(
                child: ValueListenableBuilder<FileOperationProgress?>(
                  valueListenable: provider.progressNotifier,
                  builder: (context, progress, child) {
                    if (progress == null) return const SizedBox.shrink();
                    final percent = (progress.percentage * 100).clamp(0, 100).toInt();
                    final isDark = theme.brightness == Brightness.dark;
                    final circleBgColor = isDark ? const Color(0xFF1E1E2E).withValues(alpha: 0.92) : const Color(0xFFF8F8FC).withValues(alpha: 0.92);
                    return Stack(
                      children: [
                        IgnorePointer(
                          child: Container(color: Colors.black54),
                        ),
                        Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Container(
                                width: 160,
                                height: 160,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: circleBgColor,
                                  border: Border.all(
                                    color: theme.colorScheme.outline.withValues(alpha: 0.12),
                                    width: 1,
                                  ),
                                  boxShadow: [
                                    BoxShadow(
                                      color: Colors.black.withValues(alpha: 0.3),
                                      blurRadius: 24,
                                      spreadRadius: 3,
                                    ),
                                  ],
                                ),
                                child: Stack(
                                  fit: StackFit.expand,
                                  children: [
                                    Padding(
                                      padding: const EdgeInsets.all(15),
                                      child: CircularProgressIndicator(
                                        value: 1.0,
                                        strokeWidth: 4,
                                        backgroundColor: theme.colorScheme.primary.withValues(alpha: 0.06),
                                        valueColor: AlwaysStoppedAnimation<Color>(
                                          theme.colorScheme.primary.withValues(alpha: 0.06),
                                        ),
                                      ),
                                    ),
                                    Padding(
                                      padding: const EdgeInsets.all(15),
                                      child: CircularProgressIndicator(
                                        value: progress.percentage.clamp(0.0, 1.0),
                                        strokeWidth: 4,
                                        backgroundColor: Colors.transparent,
                                        valueColor: AlwaysStoppedAnimation<Color>(theme.colorScheme.primary),
                                        strokeCap: StrokeCap.round,
                                      ),
                                    ),
                                    Center(
                                      child: Column(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Text(
                                            '$percent%',
                                            style: TextStyle(
                                              fontSize: 36,
                                              fontWeight: FontWeight.w900,
                                              color: theme.colorScheme.primary,
                                              letterSpacing: -1,
                                              height: 1,
                                            ),
                                          ),
                                          const SizedBox(height: 4),
                                          Text(
                                            '${progress.currentFileIndex}/${progress.totalFiles}',
                                            style: TextStyle(
                                              fontSize: 10,
                                              fontWeight: FontWeight.w500,
                                              color: theme.colorScheme.onSurface.withValues(alpha: 0.35),
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(height: 12),
                              ConstrainedBox(
                                constraints: const BoxConstraints(maxWidth: 180),
                                child: Text(
                                  progress.currentFileName,
                                  style: theme.textTheme.bodySmall?.copyWith(
                                    fontWeight: FontWeight.w600,
                                    color: Colors.white.withValues(alpha: 0.85),
                                    fontSize: 11,
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  textAlign: TextAlign.center,
                                ),
                              ),
                              const SizedBox(height: 18),
                              SizedBox(
                                width: 120,
                                height: 32,
                                child: OutlinedButton(
                                  onPressed: () => provider.cancelOperation(),
                                  style: OutlinedButton.styleFrom(
                                    foregroundColor: Colors.white70,
                                    side: BorderSide(color: Colors.white.withValues(alpha: 0.2)),
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(16),
                                    ),
                                    padding: EdgeInsets.zero,
                                  ),
                                  child: Text(
                                    L10n.of(context).msg17093362,
                                    style: TextStyle(fontSize: 12),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    );
                  },
                ),
              ),

            ],
          ),
        ),
      ),
    );
  }

  Widget _buildCompactFolderItem(
    BuildContext context,
    FileManagerProvider provider,
    FileItemModel folder,
    bool isSelected,
    bool isSelectionMode,
    NetworkConnectionModel? remoteConnection,
  ) {
    final theme = Theme.of(context);
    final isHighlighted = provider.forceHighlightedPaths.contains(folder.path) || (provider.enableFolderHighlight && provider.highlightedPaths.contains(folder.path));

    final itemLongPress = () {
      _activatePane(provider);
      if (isSelectionMode && isSelected) {
        SelectionContextBottomSheet.show(context, provider, folder.path);
      } else {
        provider.toggleSelection(folder.path);
      }
    };

    return DragDropHandler(
      path: folder.path,
      isDirectory: true,
      onLongPress: itemLongPress,
      isRemote: folder.isRemote,
      remoteItems: folder.remoteSource != null ? [folder.remoteSource!] : null,
      connection: folder.isRemote ? remoteConnection : null,
      child: InkWell(
        onTap: () {
          _activatePane(provider);
          if (isSelectionMode) {
            provider.toggleSelection(folder.path);
          } else {
            _openFolder(provider, folder.path);
          }
        },
        onLongPress: provider.enableDragDrop ? null : itemLongPress,
        child: Stack(
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              decoration: BoxDecoration(
                color: isSelected
                    ? theme.colorScheme.primaryContainer.withOpacity(0.4)
                    : isHighlighted
                        ? theme.colorScheme.primary.withOpacity(0.05)
                        : Colors.transparent,
                border: isHighlighted
                    ? Border(
                        left: BorderSide(color: theme.colorScheme.primary, width: 3),
                      )
                    : null,
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  GestureDetector(
                    onTap: itemLongPress,
                    child: Container(
                      width: 32,
                      height: 32,
                      decoration: BoxDecoration(
                        color: isSelected
                            ? theme.colorScheme.primary
                            : theme.colorScheme.primary.withOpacity(0.1),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Icon(
                        isSelected
                            ? Broken.tick_circle
                            : FileUtils.getFolderIcon(provider.folderIconOption),
                        color: isSelected
                            ? theme.colorScheme.onPrimary
                            : theme.colorScheme.primary,
                        size: 18,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Padding(
                      // 右侧为三点按钮预留 24px，避免文字与按钮重叠
                      padding: const EdgeInsets.only(right: 24),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            folder.name,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              fontWeight: FontWeight.w600,
                              fontSize: 13,
                            ),
                            maxLines: provider.adaptiveMultiLineNames ? 3 : 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          const SizedBox(height: 1),
                          Consumer<FileManagerProvider>(
                            builder: (context, provider, _) {
                              final activeFilter = provider.filterType;
                              if (activeFilter != FileFilterType.all) {
                                return FutureBuilder<int>(
                                  future: provider.getMatchingFileCount(folder.path, activeFilter),
                                  builder: (context, snapshot) {
                                    final count = snapshot.data ?? 0;
                                    final name = provider.getFilterTypeName(activeFilter, count);
                                    return Text(
                                      '$count $name',
                                      style: theme.textTheme.bodySmall?.copyWith(
                                        color: theme.colorScheme.primary,
                                        fontWeight: FontWeight.bold,
                                        fontSize: 10.5,
                                      ),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    );
                                  },
                                );
                              } else {
                                if (provider.hideTimeAndDate && !provider.showFolderContentsCount) {
                                  return const SizedBox.shrink();
                                }
                                if (provider.showFolderContentsCount) {
                                  return FutureBuilder<int>(
                                    future: provider.getFolderItemCount(folder.path),
                                    builder: (context, snapshot) {
                                      final count = snapshot.data ?? 0;
                                      final countStr = count == 1 ? '1 item' : '$count items';
                                      if (provider.hideTimeAndDate) {
                                        return Text(
                                          countStr,
                                          style: theme.textTheme.bodySmall?.copyWith(
                                            color: theme.textTheme.bodySmall?.color?.withOpacity(0.55),
                                            fontSize: 10.5,
                                          ),
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                        );
                                      } else {
                                        return Text(
                                          '$countStr • ${FileUtils.formatDate(folder.modified, use24Hour: provider.use24HourFormat)}',
                                          style: theme.textTheme.bodySmall?.copyWith(
                                            color: theme.textTheme.bodySmall?.color?.withOpacity(0.55),
                                            fontSize: 10.5,
                                          ),
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                        );
                                      }
                                    },
                                  );
                                } else {
                                  return Text(
                                    FileUtils.formatDate(folder.modified, use24Hour: provider.use24HourFormat),
                                    style: theme.textTheme.bodySmall?.copyWith(
                                      color: theme.textTheme.bodySmall?.color?.withOpacity(0.55),
                                      fontSize: 10.5,
                                    ),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  );
                                }
                              }
                            },
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
            if (!context.select<FileManagerProvider, bool>((p) => p.hideActionMenuButtons))
              Positioned(
                top: 0,
                right: 0,
                child: IconButton(
                  icon: const Icon(Broken.more, size: 16),
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
                  onPressed: () {
                    _activatePane(provider);
                    FileActionSheet.show(
                      context,
                      (action) => _handleAction(context, action, folder.path),
                      isArchive: false,
                    );
                  },
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildCompactFileItem(
    BuildContext context,
    FileManagerProvider provider,
    FileItemModel file,
    bool isSelected,
    bool isSelectionMode,
    NetworkConnectionModel? remoteConnection,
  ) {
    final theme = Theme.of(context);
    final isHighlighted = provider.forceHighlightedPaths.contains(file.path) || (provider.enableFolderHighlight && provider.highlightedPaths.contains(file.path));
    final iconColor = FileUtils.getColorForFile(file.path, context);
    final isArchive = FileUtils.isArchive(file.path);

    final itemLongPress = () {
      _activatePane(provider);
      if (isSelectionMode && isSelected) {
        SelectionContextBottomSheet.show(context, provider, file.path);
      } else {
        provider.toggleSelection(file.path);
      }
    };

    return DragDropHandler(
      path: file.path,
      isDirectory: false,
      onLongPress: itemLongPress,
      isRemote: file.isRemote,
      remoteItems: file.remoteSource != null ? [file.remoteSource!] : null,
      connection: file.isRemote ? remoteConnection : null,
      child: InkWell(
        onTap: () {
          _activatePane(provider);
          if (isSelectionMode) {
            provider.toggleSelection(file.path);
          } else {
            provider.openFile(context, file.path);
          }
        },
        onLongPress: provider.enableDragDrop ? null : itemLongPress,
        child: Stack(
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              decoration: BoxDecoration(
                color: isSelected
                    ? theme.colorScheme.primaryContainer.withOpacity(0.4)
                    : isHighlighted
                        ? theme.colorScheme.primary.withOpacity(0.05)
                        : Colors.transparent,
                border: isHighlighted
                    ? Border(
                        left: BorderSide(color: theme.colorScheme.primary, width: 3),
                      )
                    : null,
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  GestureDetector(
                    onTap: itemLongPress,
                    child: Container(
                      width: 32,
                      height: 32,
                      decoration: BoxDecoration(
                        color: isSelected
                            ? theme.colorScheme.primary
                            : iconColor.withOpacity(0.1),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(6),
                        child: _CompactMediaThumbnail(
                          file: file,
                          isSelected: isSelected,
                          iconColor: iconColor,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Padding(
                      // 右侧为三点按钮预留 24px，避免文字与按钮重叠
                      padding: const EdgeInsets.only(right: 24),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            file.name,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              fontWeight: FontWeight.w600,
                              fontSize: 13,
                            ),
                            maxLines: provider.adaptiveMultiLineNames ? 3 : 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          const SizedBox(height: 1),
                          Text(
                            provider.hideTimeAndDate
                                ? FileUtils.formatBytes(file.size, 1)
                                : "${FileUtils.formatDate(file.modified, use24Hour: provider.use24HourFormat)}   ${FileUtils.formatBytes(file.size, 1)}",
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.textTheme.bodySmall?.color?.withOpacity(0.55),
                              fontSize: 10.5,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
            if (!context.select<FileManagerProvider, bool>((p) => p.hideActionMenuButtons))
              Positioned(
                top: 0,
                right: 0,
                child: IconButton(
                  icon: const Icon(Broken.more, size: 16),
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
                  onPressed: () {
                    _activatePane(provider);
                    FileActionSheet.show(
                      context,
                      (action) => _handleAction(context, action, file.path),
                      isArchive: FileUtils.isArchive(file.path),
                    );
                  },
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildActiveFilterBanner(BuildContext context, FileManagerProvider provider) {
    final theme = Theme.of(context);
    final filter = provider.filterType;
    String label = '';
    IconData icon = Broken.category;
    Color color = theme.colorScheme.primary;

    switch (filter) {
      case FileFilterType.all:
        break;
      case FileFilterType.documents:
        label = L10n.of(context).msg0c36f64f;
        icon = Broken.document;
        color = Colors.blueAccent;
        break;
      case FileFilterType.images:
        label = '仅图片';
        icon = Broken.image;
        color = Colors.purpleAccent;
        break;
      case FileFilterType.audio:
        label = L10n.of(context).msg26b041dd;
        icon = Broken.music;
        color = Colors.greenAccent;
        break;
      case FileFilterType.videos:
        label = '仅视频';
        icon = Broken.video;
        color = Colors.redAccent;
        break;
      case FileFilterType.archives:
        label = L10n.of(context).msge632ba85;
        icon = Broken.archive;
        color = Colors.brown;
        break;
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12.0, vertical: 6.0),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: color.withOpacity(0.12),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: color.withOpacity(0.25), width: 1.2),
        ),
        child: Row(
          children: [
            Icon(icon, color: color, size: 16),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                '$label Active',
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 12,
                  color: theme.colorScheme.onSurface.withOpacity(0.9),
                ),
              ),
            ),
            InkWell(
              onTap: () => provider.toggleHideFoldersInFilter(),
              borderRadius: BorderRadius.circular(10),
              child: Container(
                padding: const EdgeInsets.all(4),
                decoration: BoxDecoration(
                  color: color.withOpacity(0.15),
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  provider.hideFoldersInFilter ? Broken.folder : Broken.folder_connection,
                  color: color,
                  size: 13,
                ),
              ),
            ),
            const SizedBox(width: 8),
            InkWell(
              onTap: () => provider.setFilterType(FileFilterType.all),
              borderRadius: BorderRadius.circular(10),
              child: Container(
                padding: const EdgeInsets.all(3),
                decoration: BoxDecoration(
                  color: color.withOpacity(0.2),
                  shape: BoxShape.circle,
                ),
                child: Icon(Broken.close_square, color: color, size: 13),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CompactMediaThumbnail extends StatefulWidget {
  final FileItemModel file;
  final bool isSelected;
  final Color iconColor;

  const _CompactMediaThumbnail({
    required this.file,
    required this.isSelected,
    required this.iconColor,
  });

  @override
  State<_CompactMediaThumbnail> createState() => _CompactMediaThumbnailState();
}

class _CompactMediaThumbnailState extends State<_CompactMediaThumbnail> {
  static final Map<String, Uint8List?> _apkIconCache = {};
  Uint8List? _videoThumb;
  Uint8List? _audioThumb;
  Uint8List? _apkIcon;

  @override
  void initState() {
    super.initState();
    final lowerPath = widget.file.path.toLowerCase();
    if (FileUtils.isVideo(widget.file.path)) {
      _loadVideoThumb();
    } else if (FileUtils.isAudio(widget.file.path)) {
      _loadAudioThumb();
    } else if (lowerPath.endsWith('.apk') || lowerPath.endsWith('.xapk') || lowerPath.endsWith('.apks') || lowerPath.endsWith('.apkm')) {
      _loadApkIcon();
    }
  }

  Future<void> _loadApkIcon() async {
    final path = widget.file.path;
    if (_apkIconCache.containsKey(path)) {
      final cachedIcon = _apkIconCache[path];
      if (mounted && cachedIcon != null) {
        setState(() {
          _apkIcon = cachedIcon;
        });
      }
      return;
    }
    try {
      final iconBytes = await AppManagerService.getApkIcon(path);
      _apkIconCache[path] = iconBytes;
      if (mounted && iconBytes != null) {
        setState(() {
          _apkIcon = iconBytes;
        });
      }
    } catch (_) {}
  }

  Future<void> _loadAudioThumb() async {
    if (!mounted) return;
    try {
      final mediaProvider = context.read<MediaProvider>();
      final match = mediaProvider.audios.where((s) => s.data == widget.file.path).firstOrNull;
      if (match != null) {
        final artwork = await OnAudioQuery().queryArtwork(
          match.id,
          ArtworkType.AUDIO,
          size: 150,
          quality: 50,
        );
        if (mounted && artwork != null && artwork.isNotEmpty) {
          setState(() {
            _audioThumb = artwork;
          });
        }
      }
    } catch (_) {}
  }

  Future<void> _loadVideoThumb() async {
    if (!mounted) return;
    try {
      final mediaProvider = context.read<MediaProvider>();
      final match = mediaProvider.videos.where((v) {
        final titleLower = (v.title ?? '').toLowerCase();
        final nameLower = widget.file.name.toLowerCase();
        
        // Case 1: title matches filename exactly
        if (titleLower == nameLower) return true;
        
        // Case 2: title is basename without extension, e.g. title="my_video", filename="my_video.mp4"
        final extIndex = nameLower.lastIndexOf('.');
        final ext = extIndex != -1 ? nameLower.substring(extIndex) : '';
        if (ext.isNotEmpty) {
          final baseName = nameLower.substring(0, extIndex);
          if (titleLower == baseName || '${titleLower}${ext}' == nameLower) {
            return true;
          }
        }
        
        // Case 3: Match via mimeType
        final mimeExt = v.mimeType?.split("/").last.toLowerCase();
        if (mimeExt != null && '${titleLower}.$mimeExt' == nameLower) {
          return true;
        }
        
        return false;
      }).firstOrNull;

      if (match != null) {
        final thumb = await ThumbnailCache.get(match);
        if (mounted && thumb != null) {
          setState(() {
            _videoThumb = thumb;
          });
        }
      }
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final showMediaPreviews = context.select<FileManagerProvider, bool>((p) => p.showMediaPreviews);
    final isImg = FileUtils.isImage(widget.file.path);
    final isVid = FileUtils.isVideo(widget.file.path);
    final isAud = FileUtils.isAudio(widget.file.path);
    final isApk = widget.file.path.toLowerCase().endsWith('.apk') || widget.file.path.toLowerCase().endsWith('.xapk') || widget.file.path.toLowerCase().endsWith('.apks') || widget.file.path.toLowerCase().endsWith('.apkm');

    if (widget.isSelected) {
      return Icon(Broken.tick_circle, color: Theme.of(context).colorScheme.onPrimary, size: 18);
    }

    // 压缩包：显示带格式标签的自定义图标
    if (FileUtils.isArchive(widget.file.path)) {
      return ArchiveTypeIcon(
        label: FileUtils.getArchiveTypeLabel(widget.file.path),
        color: widget.iconColor,
        iconScale: 18 / 28,
      );
    }

    // 文档：显示带格式标签的自定义图标
    if (FileUtils.isDocument(widget.file.path)) {
      return FileTypeIcon(
        icon: FileUtils.getIconForFile(widget.file.path),
        label: FileUtils.getDocumentTypeLabel(widget.file.path),
        color: widget.iconColor,
        iconScale: 18 / 28,
      );
    }

    if (!showMediaPreviews) {
      if (isImg) {
        return FileTypeIcon(
          icon: Broken.image,
          label: FileUtils.getImageTypeLabel(widget.file.path),
          color: widget.iconColor,
          iconScale: 18 / 28,
        );
      }
      return Icon(
        FileUtils.getIconForFile(widget.file.path),
        color: widget.iconColor,
        size: 18,
      );
    }

    if (isApk && _apkIcon != null) {
      return Image.memory(
        _apkIcon!,
        fit: BoxFit.cover,
        width: double.infinity,
        height: double.infinity,
        errorBuilder: (context, error, stackTrace) => Icon(Broken.mobile, color: widget.iconColor, size: 18),
      );
    }

    if (isImg && widget.file.size > 16) {
      if (widget.file.path.toLowerCase().endsWith('.avif')) {
        return AvifImage.file(
          File(widget.file.path),
          fit: BoxFit.cover,
          width: double.infinity,
          height: double.infinity,
          errorBuilder: (context, error, stackTrace) => FileTypeIcon(icon: Broken.image, label: FileUtils.getImageTypeLabel(widget.file.path), color: widget.iconColor, iconScale: 18 / 28),
        );
      }
      return Image.file(
        File(widget.file.path),
        fit: BoxFit.cover,
        width: double.infinity,
        height: double.infinity,
        cacheWidth: 80,
        errorBuilder: (context, error, stackTrace) => FileTypeIcon(icon: Broken.image, label: FileUtils.getImageTypeLabel(widget.file.path), color: widget.iconColor, iconScale: 18 / 28),
      );
    }

    if (isVid && _videoThumb != null) {
      return Stack(
        fit: StackFit.expand,
        children: [
          Image.memory(
            _videoThumb!,
            fit: BoxFit.cover,
            width: double.infinity,
            height: double.infinity,
            errorBuilder: (context, error, stackTrace) => Icon(Broken.video, color: widget.iconColor, size: 18),
          ),
          Center(
            child: Container(
              padding: const EdgeInsets.all(2),
              decoration: BoxDecoration(color: Colors.black.withOpacity(0.6), shape: BoxShape.circle),
              child: Icon(Broken.video, color: Colors.white, size: 10),
            ),
          ),
        ],
      );
    }

    if (isAud && _audioThumb != null) {
      return Stack(
        fit: StackFit.expand,
        children: [
          Image.memory(
            _audioThumb!,
            fit: BoxFit.cover,
            width: double.infinity,
            height: double.infinity,
            errorBuilder: (context, error, stackTrace) => Icon(Broken.music, color: widget.iconColor, size: 18),
          ),
          Center(
            child: Container(
              padding: const EdgeInsets.all(2),
              decoration: BoxDecoration(color: Colors.black.withOpacity(0.6), shape: BoxShape.circle),
              child: Icon(Broken.music, color: Colors.white, size: 10),
            ),
          ),
        ],
      );
    }

    return Icon(
      FileUtils.getIconForFile(widget.file.path),
      color: widget.iconColor,
      size: 18,
    );
  }
}
