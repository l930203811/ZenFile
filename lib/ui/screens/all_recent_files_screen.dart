import 'dart:io';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:path/path.dart' as p;
import 'package:share_plus/share_plus.dart';
import '../../core/icon_fonts/broken_icons.dart';
import '../../providers/file_manager_provider.dart';
import '../../providers/media_provider.dart';
import '../../models/file_item_model.dart';
import '../widgets/file_item.dart';
import '../widgets/folder_item.dart';
import '../widgets/file_action_dialogs.dart';
import '../widgets/selection_context_bottom_sheet.dart';
import '../widgets/selection_action_bar.dart';
import '../widgets/create_archive_dialog.dart';
import 'package:zenfile/l10n/generated/app_localizations.dart';

class AllRecentFilesScreen extends StatefulWidget {
  final Function(int)? onNavigateTab;
  const AllRecentFilesScreen({super.key, this.onNavigateTab});

  @override
  State<AllRecentFilesScreen> createState() => _AllRecentFilesScreenState();
}

class _AllRecentFilesScreenState extends State<AllRecentFilesScreen> {
  List<FileItemModel> _recentFiles = [];
  bool _isLoading = true;

  bool get _isSelectionMode {
    try {
      return context.read<FileManagerProvider>().selectedPaths.isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  Set<String> get _selectedPaths {
    try {
      return context.read<FileManagerProvider>().selectedPaths;
    } catch (_) {
      return {};
    }
  }

  @override
  void initState() {
    super.initState();
    // 清除可能残留的全局选择状态
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        try {
          final provider = context.read<FileManagerProvider>();
          provider.clearSelection();
          // 监听选择状态变化，当选择被清除（操作完成）后刷新列表
          provider.addListener(_onProviderChanged);
        } catch (_) {}
      }
    });
    _loadRecentFiles();
  }

  bool _wasSelectionMode = false;

  void _onProviderChanged() {
    if (!mounted) return;
    final provider = context.read<FileManagerProvider>();
    final isSelection = provider.selectedPaths.isNotEmpty;
    // 当从选择模式退出时（操作完成），刷新最近文件列表
    if (_wasSelectionMode && !isSelection) {
      _loadRecentFiles();
    }
    _wasSelectionMode = isSelection;
  }

  @override
  void dispose() {
    try {
      context.read<FileManagerProvider>().removeListener(_onProviderChanged);
    } catch (_) {}
    super.dispose();
  }

  Future<void> _loadRecentFiles() async {
    try {
      final items = await _scanRecentFiles();
      if (mounted) {
        setState(() {
          _recentFiles = items;
          _isLoading = false;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  Future<List<FileItemModel>> _scanRecentFiles() async {
    final list = <FileSystemEntity>[];
    final seen = <String>{};

    final rootDir = Directory('/storage/emulated/0');
    if (await rootDir.exists()) {
      try {
        final List<String> pathsToScan = [];
        
        final rootEntities = await rootDir.list(recursive: false).toList();
        for (final entity in rootEntities) {
          if (entity is Directory) {
            final name = p.basename(entity.path);
            if (!name.startsWith('.') && name != 'Android') {
              pathsToScan.add(entity.path);
            }
          }
        }

        pathsToScan.addAll([
          '/storage/emulated/0/Android/media',
          '/storage/emulated/0/Download',
          '/storage/emulated/0/Documents',
        ]);

        await Future.wait(pathsToScan.map((path) async {
          final dir = Directory(path);
          if (await dir.exists()) {
            try {
              final entities = await dir.list(recursive: false).toList();
              for (final entity in entities) {
                if (!seen.contains(entity.path)) {
                  seen.add(entity.path);
                  list.add(entity);
                }
                if (entity is Directory && !p.basename(entity.path).startsWith('.')) {
                  try {
                    final subEntities = await entity.list(recursive: false).toList();
                    for (final sub in subEntities) {
                      if (!seen.contains(sub.path)) {
                        seen.add(sub.path);
                        list.add(sub);
                      }
                    }
                  } catch (_) {}
                }
              }
            } catch (_) {}
          }
        }));
      } catch (_) {}
    }

    final mediaProvider = context.read<MediaProvider>();

    void addFromMediaList(List<FileSystemEntity> mediaList) {
      for (final entity in mediaList) {
        if (!seen.contains(entity.path)) {
          seen.add(entity.path);
          list.add(entity);
        }
      }
    }

    addFromMediaList(mediaProvider.downloads);
    addFromMediaList(mediaProvider.documents);
    addFromMediaList(mediaProvider.archives);
    addFromMediaList(mediaProvider.apks);

    for (final song in mediaProvider.audios) {
      final path = song.data;
      if (!seen.contains(path)) {
        seen.add(path);
        try {
          final f = File(path);
          if (await f.exists()) list.add(f);
        } catch (_) {}
      }
    }

    final filteredList = <FileSystemEntity>[];
    for (final entity in list) {
      if (entity is Directory) {
        bool hasNestedChild = false;
        for (final other in list) {
          if (other.path != entity.path && p.isWithin(entity.path, other.path)) {
            hasNestedChild = true;
            break;
          }
        }
        if (hasNestedChild) {
          continue;
        }
      }
      filteredList.add(entity);
    }

    final items = <FileItemModel>[];
    await Future.wait(filteredList.map((f) async {
      try {
        final isDir = f is Directory;
        if (isDir) return;

        final name = p.basename(f.path);
        if (name.startsWith('.')) return;

        final stat = await f.stat();
        items.add(FileItemModel(
          entity: f,
          name: name,
          path: f.path,
          isDirectory: false,
          size: stat.size,
          modified: stat.modified,
        ));
      } catch (_) {}
    }));

    items.sort((a, b) => b.modified.compareTo(a.modified));
    return items;
  }

  void _toggleSelection(String path) {
    final provider = context.read<FileManagerProvider>();
    provider.toggleSelection(path);
    setState(() {});
  }

  void _selectAll() {
    final provider = context.read<FileManagerProvider>();
    for (final item in _recentFiles) {
      provider.toggleSelection(item.path);
    }
    setState(() {});
  }

  void _clearSelection() {
    final provider = context.read<FileManagerProvider>();
    provider.clearSelection();
    setState(() {});
  }

  void _handleAction(BuildContext context, String action, String path) async {
    final provider = context.read<FileManagerProvider>();
    switch (action) {
      case 'show_in_location':
        provider.showFileInLocation(path);
        Navigator.pop(context);
        widget.onNavigateTab?.call(1);
        break;
      case 'open_with':
        provider.openFile(context, path, forceOpenWith: true);
        break;
      case 'share':
        if (FileSystemEntity.isFileSync(path)) {
          try {
            await Share.shareXFiles([XFile(path)]);
          } catch (e) {
            if (context.mounted) {
              ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('分享出错：{e}')));
            }
          }
        }
        break;
      case 'copy':
        provider.copyFile(path);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(L10n.of(context).msg4fb42e6e)));
        break;
      case 'cut':
        provider.cutFile(path);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(L10n.of(context).msge5212c58)));
        break;
      case 'archive':
        final res = await CreateArchiveDialog.show(
          context,
          initialName: p.basename(path),
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
      case 'rename':
        final currentName = p.basename(path);
        final newName = await FileActionDialogs.showTextInputDialog(
          context,
          title: L10n.of(context).msgc8ce4b36,
          hint: L10n.of(context).msgf139c5cf,
          initialValue: currentName,
          actionText: L10n.of(context).msgc8ce4b36,
        );
        if (newName != null && newName.isNotEmpty) {
          try {
            await provider.renameFile(path, newName);
          } catch (e) {
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text('重命名失败: $e')),
              );
            }
            return;
          }
          _loadRecentFiles();
        }
        break;
      case 'delete':
        final confirm = await FileActionDialogs.showConfirmDialog(
          context,
          title: L10n.of(context).msg53518c22,
          content: L10n.of(context).msgee14ee27,
        );
        if (confirm) {
          try {
            await provider.deleteFile(path);
          } catch (e) {
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text('删除失败: $e')),
              );
            }
          }
        }
        break;
      case 'favorite':
        final name = p.basename(path);
        final isRemote = provider.currIsRemote;
        final connectionId = provider.activeTab.remoteConnection?.id;
        final isDir = isRemote ? true : Directory(path).existsSync();
        provider.addFavorite(path, name, isDir, isRemote: isRemote, connectionId: connectionId);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(L10n.of(context).msg_favorited(name)), behavior: SnackBarBehavior.floating, duration: const Duration(seconds: 2)),
          );
        }
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final provider = context.watch<FileManagerProvider>();

    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      appBar: AppBar(
        leading: _isSelectionMode
            ? IconButton(icon: const Icon(Broken.close_square), onPressed: _clearSelection)
            : IconButton(
                icon: const Icon(Broken.arrow_left),
                onPressed: () => Navigator.pop(context),
              ),
        title: Text(
          _isSelectionMode ? '' : L10n.of(context).msg54355dd8,
          style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
        ),
        actions: _isSelectionMode
            ? [
                IconButton(
                  icon: const Icon(Broken.tick_square),
                  tooltip: L10n.of(context).ui_select_all,
                  onPressed: _selectAll,
                ),
              ]
            : [
                IconButton(
                  icon: const Icon(Icons.refresh_rounded),
                  tooltip: L10n.of(context).ui_refresh,
                  onPressed: () {
                    setState(() => _isLoading = true);
                    _loadRecentFiles();
                  },
                ),
              ],
      ),
      bottomNavigationBar: _isSelectionMode
          ? SelectionActionBar(provider: provider)
          : null,
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _recentFiles.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(32.0),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Container(
                          padding: const EdgeInsets.all(24),
                          decoration: BoxDecoration(color: theme.colorScheme.primary.withAlpha(20), shape: BoxShape.circle),
                          child: Icon(Broken.document_filter, size: 64, color: theme.colorScheme.primary),
                        ),
                        const SizedBox(height: 24),
                        Text(L10n.of(context).msg47809e5d, style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.bold)),
                        const SizedBox(height: 8),
                        Text(
                          L10n.of(context).msg7a7e6c25,
                          textAlign: TextAlign.center,
                          style: TextStyle(color: theme.colorScheme.onSurface.withAlpha(127), fontSize: 15),
                        ),
                      ],
                    ),
                  ),
                )
              : ListView.builder(
                  physics: const BouncingScrollPhysics(),
                  padding: const EdgeInsets.only(top: 8, bottom: 24),
                  itemCount: _recentFiles.length,
                  itemBuilder: (context, index) {
                    final item = _recentFiles[index];
                    final isItemSelected = _selectedPaths.contains(item.path);

                    if (item.isDirectory) {
                      return FolderItem(
                        folder: item,
                        isSelected: isItemSelected,
                        onTap: () {
                          if (_isSelectionMode) {
                            _toggleSelection(item.path);
                          } else {
                            provider.loadDirectory(item.path);
                          }
                        },
                        onLongPress: () {
                          if (_isSelectionMode && isItemSelected) {
                            SelectionContextBottomSheet.show(context, provider, item.path);
                          } else {
                            _toggleSelection(item.path);
                          }
                        },
                        onAction: (action) => _handleAction(context, action, item.path),
                      );
                    } else {
                      return FileItem(
                        file: item,
                        isSelected: isItemSelected,
                        showShowInLocationOption: true,
                        showOpenWithOption: true,
                        onTap: () {
                          if (_isSelectionMode) {
                            _toggleSelection(item.path);
                          } else {
                            provider.openFile(context, item.path);
                          }
                        },
                        onLongPress: () {
                          if (_isSelectionMode && isItemSelected) {
                            SelectionContextBottomSheet.show(context, provider, item.path);
                          } else {
                            _toggleSelection(item.path);
                          }
                        },
                        onAction: (action) => _handleAction(context, action, item.path),
                      );
                    }
                  },
                ),
    );
  }
}
