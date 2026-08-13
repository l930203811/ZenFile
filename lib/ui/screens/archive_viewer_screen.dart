import 'dart:io';
import 'package:archive/archive.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';
import '../../core/icon_fonts/broken_icons.dart';
import '../../core/utils.dart';
import '../../providers/file_manager_provider.dart';
import '../../services/archive_service.dart';
import '../widgets/archive_type_icon.dart';
import 'internal_file_picker_screen.dart';
import 'image_viewer_screen.dart';
import 'package:zenfile/l10n/generated/app_localizations.dart';

class ArchiveItem {
  final String name;
  final String fullPath;
  final bool isDirectory;
  final int size;

  ArchiveItem({
    required this.name,
    required this.fullPath,
    required this.isDirectory,
    required this.size,
  });
}


class ArchiveViewerScreen extends StatefulWidget {
  final String archivePath;

  const ArchiveViewerScreen({super.key, required this.archivePath});

  @override
  State<ArchiveViewerScreen> createState() => _ArchiveViewerScreenState();
}

class _ArchiveViewerScreenState extends State<ArchiveViewerScreen> {
  Archive? _archive;
  String _currentInternalPath = '';
  bool _isLoading = true;
  final Set<String> _selectedInternalPaths = {};

  String _normalizePath(String path) {
    var name = path.replaceAll('\\', '/');
    while (name.startsWith('/')) {
      name = name.substring(1);
    }
    while (name.startsWith('./')) {
      name = name.substring(2);
    }
    return name;
  }

  String get _archiveName => p.basename(widget.archivePath);
  bool get isSelectionMode => _selectedInternalPaths.isNotEmpty;

  @override
  void initState() {
    super.initState();
    _loadArchive();
  }

  Future<void> _loadArchive() async {
    setState(() => _isLoading = true);
    final arch = await ArchiveService.readArchive(widget.archivePath);
    if (mounted) {
      setState(() {
        _archive = arch;
        _isLoading = false;
        _selectedInternalPaths.clear();
      });
    }
  }

  List<ArchiveItem> get _currentItems {
    if (_archive == null) return [];

    final Set<String> folders = {};
    final List<ArchiveItem> items = [];

    for (final f in _archive!.files) {
      final name = _normalizePath(f.name);
      if (name.isEmpty || name == _currentInternalPath) continue;

      if (name.startsWith(_currentInternalPath)) {
        final remaining = name.substring(_currentInternalPath.length);
        final parts = remaining.split('/');

        if (parts.length == 1 || (parts.length == 2 && parts[1].isEmpty)) {
          if (parts.length == 2 && parts[1].isEmpty) {
            final folderName = parts[0];
            if (!folders.contains(folderName)) {
              folders.add(folderName);
              items.add(ArchiveItem(
                name: folderName,
                fullPath: '$_currentInternalPath$folderName/',
                isDirectory: true,
                size: 0,
              ));
            }
          } else {
            items.add(ArchiveItem(
              name: parts[0],
              fullPath: name,
              isDirectory: false,
              size: f.size,
            ));
          }
        } else {
          final folderName = parts[0];
          if (!folders.contains(folderName)) {
            folders.add(folderName);
            items.add(ArchiveItem(
              name: folderName,
              fullPath: '$_currentInternalPath$folderName/',
              isDirectory: true,
              size: 0,
            ));
          }
        }
      }
    }

    items.sort((a, b) {
      if (a.isDirectory && !b.isDirectory) return -1;
      if (!a.isDirectory && b.isDirectory) return 1;
      return FileUtils.compareNatural(a.name, b.name);
    });

    return items;
  }

  void _toggleSelect(ArchiveItem item) {
    setState(() {
      if (_selectedInternalPaths.contains(item.fullPath)) {
        _selectedInternalPaths.remove(item.fullPath);
      } else {
        _selectedInternalPaths.add(item.fullPath);
      }
    });
  }

  Future<bool> _handlePop() async {
    if (_currentInternalPath.isNotEmpty) {
      final parts = _currentInternalPath.substring(0, _currentInternalPath.length - 1).split('/');
      if (parts.length <= 1) {
        setState(() => _currentInternalPath = '');
      } else {
        parts.removeLast();
        setState(() => _currentInternalPath = '${parts.join('/')}/');
      }
      return false;
    }
    return true;
  }

  /// 将单个 ArchiveItem 提取到临时目录，返回临时文件路径（内部复用）
  /// 单张文件解压失败时返回 null，不向上抛异常，避免同目录其他图片预览被连带失败。
  /// 注意：内容通过 ArchiveService.extractEntriesToBytes 在隔离区内完成解压后回传，
  /// 不要直接读 _archive.files[x].content（跨隔离区的文件型流在解压时会失效/读空）。
  Future<String?> _extractItemToTemp(ArchiveItem item) async {
    try {
      final map = await ArchiveService.extractEntriesToBytes(widget.archivePath, [item.fullPath]);
      final content = map[item.fullPath];
      if (content == null || content.isEmpty) return null;

      final tempDir = Directory.systemTemp.createTempSync('zip_preview');
      final tempFile = File(p.join(tempDir.path, item.name));
      await tempFile.writeAsBytes(content);
      return tempFile.path;
    } catch (e) {
      debugPrint('Error extracting archive item ${item.fullPath}: $e');
      return null;
    }
  }

  Future<void> _openArchiveItem(ArchiveItem item) async {
    try {
      // 图片文件：收集同目录下所有图片，提取后传入 ImageViewerScreen 支持滑动切换
      if (FileUtils.isImage(item.name)) {
        await _openArchiveImagesWithSwipe(item);
        return;
      }

      // 其他文件：提取单个文件到临时目录后交给系统默认打开方式
      final tempPath = await _extractItemToTemp(item);
      if (tempPath == null) {
        throw Exception('文件内容为空或解压失败，可能文件过大、已损坏或使用了不支持的压缩方式');
      }

      if (mounted) {
        final provider = context.read<FileManagerProvider>();
        await provider.openFile(context, tempPath);
      }
    } catch (e) {
      debugPrint('Error opening item: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('无法打开: ${e.toString()}')),
        );
      }
    }
  }

  /// 打开压缩包内的图片，并收集同目录下所有图片作为 siblingPaths 支持左右滑动切换。
  /// 单张图片解压失败时跳过该张，避免某一张损坏/不支持的图片导致整组无法预览。
  /// 所有图片一次性在隔离区内解压后回传（解决大图 >4MB 跨隔离区文件流失效导致无法预览的问题）。
  Future<void> _openArchiveImagesWithSwipe(ArchiveItem item) async {
    try {
      // 1. 从已排序的 _currentItems 中收集当前目录下所有图片
      final currentItems = _currentItems;
      final imageItems = currentItems.where((i) => !i.isDirectory && FileUtils.isImage(i.name)).toList();
      if (imageItems.isEmpty) {
        // 兜底：仅打开当前文件
        final tempPath = await _extractItemToTemp(item);
        if (tempPath != null && mounted) {
          final provider = context.read<FileManagerProvider>();
          await provider.openFile(context, tempPath);
        }
        return;
      }

      final initialIndex = imageItems.indexWhere((i) => i.fullPath == item.fullPath);
      final safeInitial = initialIndex >= 0 ? initialIndex : 0;

      // 2. 一次性提取所有图片（隔离区内完成解压，规避跨隔离区文件流问题）
      final paths = imageItems.map((i) => i.fullPath).toList();
      final extractedMap = await ArchiveService.extractEntriesToBytes(widget.archivePath, paths);

      final extractedPaths = <String>[];
      final validIndexes = <int>[];
      for (int i = 0; i < imageItems.length; i++) {
        final bytes = extractedMap[imageItems[i].fullPath];
        if (bytes != null && bytes.isNotEmpty) {
          final tempDir = Directory.systemTemp.createTempSync('zip_preview');
          final tempFile = File(p.join(tempDir.path, imageItems[i].name));
          await tempFile.writeAsBytes(bytes);
          extractedPaths.add(tempFile.path);
          validIndexes.add(i);
        }
      }

      if (extractedPaths.isEmpty) {
        throw Exception('所有图片内容为空或无法解压');
      }

      // 3. 找到当前点击图片在有效列表中的位置；若当前图片失败，则打开第一张可用的
      var validInitial = validIndexes.indexOf(safeInitial);
      if (validInitial < 0) validInitial = 0;

      if (!mounted) return;

      // 4. 打开图片浏览器，只传入成功提取的图片路径
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => ImageViewerScreen(
            imagePath: extractedPaths[validInitial],
            siblingPaths: extractedPaths,
          ),
        ),
      );
    } catch (e) {
      debugPrint('Error opening archive image: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('无法预览图片: ${e.toString()}')),
        );
      }
    }
  }

  Future<void> _extractItemOut(ArchiveItem item) async {
    final provider = context.read<FileManagerProvider>();
    final destDir = provider.currentPath;

    setState(() => _isLoading = true);

    try {
      if (!item.isDirectory) {
        // 单文件：隔离区内解压后回传纯字节
        final map = await ArchiveService.extractEntriesToBytes(widget.archivePath, [item.fullPath]);
        final content = map[item.fullPath];
        if (content == null || content.isEmpty) {
          throw Exception('文件内容为空或无法解压（可能文件过大、已损坏或使用了不支持的压缩方式）');
        }
        final destFile = File(p.join(destDir, item.name));
        await destFile.writeAsBytes(content);
      } else {
        // 目录：收集该目录树下所有文件条目，一次性提取
        final subPaths = _archive!.files
            .where((f) => f.isFile && _normalizePath(f.name).startsWith(item.fullPath))
            .map((f) => _normalizePath(f.name))
            .toList();
        final map = await ArchiveService.extractEntriesToBytes(widget.archivePath, subPaths);
        for (final entry in map.entries) {
          final bytes = entry.value;
          if (bytes == null || bytes.isEmpty) continue;
          final rel = entry.key.substring(item.fullPath.length);
          final destFile = File(p.join(destDir, item.name, rel));
          destFile.createSync(recursive: true);
          await destFile.writeAsBytes(bytes);
        }
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Extracted ${item.name} to ${p.basename(destDir)}')));
      }
      await provider.loadDirectory(destDir, showLoading: false);
    } catch (e) {
      debugPrint('Error extracting out: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('解压失败: ${e.toString()}')),
        );
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _copySelectedToClipboard({required bool isCut}) async {
    if (_selectedInternalPaths.isEmpty || _archive == null) return;
    setState(() => _isLoading = true);

    try {
      final tempDir = Directory.systemTemp.createTempSync('archive_clipboard');
      final List<String> physicalPaths = [];

      // 收集所有需要提取的内部路径：选中的文件 + 选中目录树内的文件
      final filePaths = <String>[];
      final dirPaths = <String>[];
      for (final p in _selectedInternalPaths) {
        if (p.endsWith('/')) {
          dirPaths.add(p);
        } else {
          filePaths.add(p);
        }
      }
      final allPaths = <String>[...filePaths];
      for (final dirPath in dirPaths) {
        for (final f in _archive!.files) {
          if (f.isFile && _normalizePath(f.name).startsWith(dirPath)) {
            allPaths.add(_normalizePath(f.name));
          }
        }
      }

      // 隔离区内一次性解压，规避跨隔离区文件流导致大文件解压失败
      final map = await ArchiveService.extractEntriesToBytes(widget.archivePath, allPaths);

      // 先建立选中的目录结构
      final Map<String, String> dirTargetPaths = {};
      for (final dirPath in dirPaths) {
        final folderName = p.basename(dirPath.substring(0, dirPath.length - 1));
        final targetSubDir = Directory(p.join(tempDir.path, folderName));
        targetSubDir.createSync(recursive: true);
        dirTargetPaths[dirPath] = targetSubDir.path;
        physicalPaths.add(targetSubDir.path);
      }

      // 再把每条文件内容写入对应位置
      for (final internalPath in allPaths) {
        final bytes = map[internalPath];
        if (bytes == null || bytes.isEmpty) continue;

        String? matchedDir;
        for (final dirPath in dirPaths) {
          if (internalPath.startsWith(dirPath)) {
            matchedDir = dirPath;
            break;
          }
        }
        var targetBase = tempDir.path;
        if (matchedDir != null) {
          final rel = internalPath.substring(matchedDir.length);
          targetBase = p.join(dirTargetPaths[matchedDir]!, rel);
        }
        final fileName = p.basename(internalPath);
        final physicalFile = File(p.join(targetBase, fileName));
        physicalFile.createSync(recursive: true);
        await physicalFile.writeAsBytes(bytes);
        if (matchedDir == null) {
          physicalPaths.add(physicalFile.path);
        }
      }

      final provider = context.read<FileManagerProvider>();
      provider.setClipboard(
        physicalPaths,
        isCut: isCut,
        sourceArchive: isCut ? widget.archivePath : null,
        internalSourcePaths: isCut ? _selectedInternalPaths.toList() : null,
      );

      setState(() {
        _selectedInternalPaths.clear();
      });

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('${physicalPaths.length} 个项目已复制到剪贴板 ✓')));
      }
    } catch (e) {
      debugPrint('Error copying to clipboard: $e');
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _deleteSelectedInternalItems() async {
    if (_selectedInternalPaths.isEmpty) return;

    final confirm = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(L10n.of(context).msg765d1698, style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
        content: Text('确定要删除选中的 ${_selectedInternalPaths.length} 个项目吗？此操作无法撤销。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.redAccent),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除'),
          ),
        ],
      ),
    ) ?? false;

    if (confirm) {
      setState(() => _isLoading = true);
      final success = await ArchiveService.deleteItemsFromArchive(
        archivePath: widget.archivePath,
        internalPathsToDelete: _selectedInternalPaths.toList(),
      );

      _selectedInternalPaths.clear();
      await _loadArchive();

      if (mounted) {
        if (success) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(L10n.of(context).msg365f2f0a)));
        } else {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('删除项目失败')));
        }
      }
    }
  }

  Future<void> _addNewFile() async {
    final provider = context.read<FileManagerProvider>();
    final selectedPaths = await InternalFilePickerScreen.show(context, rootPath: provider.rootPath);

    if (selectedPaths != null && selectedPaths.isNotEmpty) {
      setState(() => _isLoading = true);

      for (final path in selectedPaths) {
        final type = FileSystemEntity.typeSync(path);
        if (type == FileSystemEntityType.directory) {
          final dir = Directory(path);
          final folderBaseName = p.basename(path);
          final entities = dir.listSync(recursive: true);

          for (final entity in entities) {
            if (entity is File) {
              final relPath = entity.path.substring(path.length + 1);
              final targetInternalPath = p.join(_currentInternalPath, folderBaseName, p.dirname(relPath)).replaceAll('\\', '/');
              await ArchiveService.addFileToArchive(
                archivePath: widget.archivePath,
                filePathToAdd: entity.path,
                internalPath: targetInternalPath == '.' ? '' : '$targetInternalPath/',
              );
            }
          }
        } else {
          await ArchiveService.addFileToArchive(
            archivePath: widget.archivePath,
            filePathToAdd: path,
            internalPath: _currentInternalPath,
          );
        }
      }

      await _loadArchive();

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('已成功添加 {successCount} 个项目到压缩包 ✓'),
        ));
      }
    }
  }

  Future<void> _pasteFromClipboard() async {
    final provider = context.read<FileManagerProvider>();
    if (!provider.hasClipboard) return;

    setState(() => _isLoading = true);

    for (final path in provider.clipboardPaths) {
      final success = await ArchiveService.addFileToArchive(
        archivePath: widget.archivePath,
        filePathToAdd: path,
        internalPath: _currentInternalPath,
      );
      if (success) {
        if (provider.isCut) {
          try {
            await File(path).delete();
          } catch (_) {}
        }
      }
    }

    provider.clearClipboard();
    await _loadArchive();

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('已粘贴 {count} 个项目到压缩包 ✓')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final provider = context.watch<FileManagerProvider>();
    final items = _currentItems;

    return PopScope(
      canPop: _currentInternalPath.isEmpty && !isSelectionMode,
      onPopInvoked: (didPop) async {
        if (didPop) return;
        if (isSelectionMode) {
          setState(() => _selectedInternalPaths.clear());
        } else {
          await _handlePop();
        }
      },
      child: Scaffold(
        backgroundColor: theme.scaffoldBackgroundColor,
        appBar: isSelectionMode
            ? AppBar(
                backgroundColor: theme.colorScheme.primaryContainer,
                leading: IconButton(
                  icon: const Icon(Broken.close_square),
                  onPressed: () => setState(() => _selectedInternalPaths.clear()),
                ),
                title: Text('${_selectedInternalPaths.length} selected', style: TextStyle(color: theme.colorScheme.onPrimaryContainer, fontWeight: FontWeight.bold, fontSize: 18)),
                actions: [
                  IconButton(
                    icon: const Icon(Broken.document_copy),
                    tooltip: '复制',
                    onPressed: () => _copySelectedToClipboard(isCut: false),
                  ),
                  IconButton(
                    icon: const Icon(Broken.scissor),
                    tooltip: '剪切',
                    onPressed: () => _copySelectedToClipboard(isCut: true),
                  ),
                  IconButton(
                    icon: const Icon(Broken.trash),
                    color: Colors.redAccent,
                    tooltip: '删除',
                    onPressed: _deleteSelectedInternalItems,
                  ),
                  IconButton(
                    icon: const Icon(Broken.task_square),
                    tooltip: '全选',
                    onPressed: () {
                      setState(() {
                        for (final item in items) {
                          _selectedInternalPaths.add(item.fullPath);
                        }
                      });
                    },
                  ),
                ],
              )
            : AppBar(
                title: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(_archiveName, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                    if (_currentInternalPath.isNotEmpty)
                      Text('/$_currentInternalPath', style: TextStyle(fontSize: 12, color: theme.colorScheme.primary)),
                  ],
                ),
                actions: [
                  IconButton(
                    icon: const Icon(Broken.refresh),
                    onPressed: _loadArchive,
                    tooltip: '刷新',
                  ),
                  if (items.isNotEmpty)
                    IconButton(
                      icon: const Icon(Broken.task_square),
                      tooltip: '全选',
                      onPressed: () {
                        setState(() {
                          for (final item in items) {
                            _selectedInternalPaths.add(item.fullPath);
                          }
                        });
                      },
                    ),
                ],
              ),
        body: _isLoading
            ? const Center(child: CircularProgressIndicator())
            : _archive == null
                ? Center(child: Text(L10n.of(context).msg39cb3352))
                : items.isEmpty
                    ? Center(child: Text(L10n.of(context).msg4614630a))
                    : ListView.builder(
                        physics: const BouncingScrollPhysics(),
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        itemCount: items.length,
                        itemBuilder: (context, index) {
                          final item = items[index];
                          final isSelected = _selectedInternalPaths.contains(item.fullPath);
                          final iconColor = item.isDirectory ? theme.colorScheme.primary : FileUtils.getColorForFile(item.name, context);

                          return Card(
                            margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                            color: isSelected ? theme.colorScheme.primaryContainer.withOpacity(0.4) : theme.colorScheme.surface,
                            elevation: 0,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                              side: BorderSide(
                                color: isSelected ? theme.colorScheme.primary : theme.dividerColor.withOpacity(0.1),
                                width: isSelected ? 1.5 : 1.0,
                              ),
                            ),
                            child: InkWell(
                              onTap: () {
                                if (isSelectionMode) {
                                  _toggleSelect(item);
                                } else if (item.isDirectory) {
                                  setState(() => _currentInternalPath = item.fullPath);
                                } else {
                                  _openArchiveItem(item);
                                }
                              },
                              onLongPress: () => _toggleSelect(item),
                              borderRadius: BorderRadius.circular(12),
                              child: Padding(
                                padding: const EdgeInsets.all(12.0),
                                child: Row(
                                  children: [
                                    Container(
                                      width: 48,
                                      height: 48,
                                      decoration: BoxDecoration(
                                        color: isSelected ? theme.colorScheme.primary : (item.isDirectory ? theme.colorScheme.primary.withOpacity(0.1) : iconColor.withOpacity(0.1)),
                                        borderRadius: BorderRadius.circular(12),
                                      ),
                                      child: (!isSelected && !item.isDirectory && FileUtils.isArchive(item.name))
                                        ? ArchiveTypeIcon(label: FileUtils.getArchiveTypeLabel(item.name), color: iconColor)
                                        : Icon(
                                            isSelected ? Broken.tick_circle : (item.isDirectory ? FileUtils.getFolderIcon(context.watch<FileManagerProvider>().folderIconOption) : FileUtils.getIconForFile(item.name)),
                                            color: isSelected ? theme.colorScheme.onPrimary : iconColor,
                                            size: 28,
                                          ),
                                    ),
                                    const SizedBox(width: 16),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            item.name,
                                            style: theme.textTheme.titleMedium?.copyWith(
                                              fontWeight: FontWeight.w600,
                                              fontSize: 15,
                                            ),
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                          if (!item.isDirectory) ...[
                                            const SizedBox(height: 4),
                                            Text(
                                              FileUtils.formatBytes(item.size, 2),
                                              style: theme.textTheme.bodySmall?.copyWith(
                                                color: theme.textTheme.bodySmall?.color?.withOpacity(0.6),
                                              ),
                                            ),
                                          ],
                                        ],
                                      ),
                                    ),
                                    PopupMenuButton<String>(
                                      icon: const Icon(Broken.more, size: 22),
                                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                                      position: PopupMenuPosition.under,
                                      elevation: 8,
                                      onSelected: (action) {
                                        if (action == 'extract') {
                                          _extractItemOut(item);
                                        }
                                      },
                                      itemBuilder: (context) => [
                                        PopupMenuItem(
                                          value: 'extract',
                                          child: Row(
                                            children: [
                                              Icon(Broken.document_download, size: 20, color: theme.colorScheme.primary),
                                              const SizedBox(width: 12),
                                              Text(L10n.of(context).msg99abedc6, style: TextStyle(fontWeight: FontWeight.w500)),
                                            ],
                                          ),
                                        ),
                                      ],
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          );
                        },
                      ),
        floatingActionButton: provider.hasClipboard
            ? FloatingActionButton.extended(
                onPressed: _pasteFromClipboard,
                backgroundColor: theme.colorScheme.primaryContainer,
                foregroundColor: theme.colorScheme.onPrimaryContainer,
                icon: const Icon(Broken.document_download),
                label: Text('在此粘贴 (${provider.clipboardPaths.length})'),
              )
            : FloatingActionButton.extended(
                onPressed: _addNewFile,
                icon: const Icon(Broken.add),
                label: Text(L10n.of(context).msg8d0cfb58),
              ),
      ),
    );
  }
}
