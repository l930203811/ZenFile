import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import '../../core/icon_fonts/broken_icons.dart';
import '../../core/utils.dart';
import '../../core/file_name_validation.dart';
import '../../models/file_item_model.dart';
import 'package:provider/provider.dart';
import '../../providers/file_manager_provider.dart';
import '../../services/root_shizuku_service.dart';
import '../widgets/file_action_dialogs.dart';
import '../widgets/file_item.dart';
import '../widgets/folder_item.dart';
import '../widgets/file_grid_item.dart';
import '../widgets/folder_grid_item.dart';
import 'package:zenfile/l10n/generated/app_localizations.dart';

class InternalFilePickerScreen extends StatefulWidget {
  final String rootPath;
  final bool pickDirectory;
  final String? initialPath;

  const InternalFilePickerScreen({super.key, required this.rootPath, this.pickDirectory = false, this.initialPath});

  static Future<List<String>?> show(BuildContext context, {required String rootPath, bool pickDirectory = false, String? initialPath}) {
    return Navigator.push<List<String>>(
      context,
      MaterialPageRoute(builder: (_) => InternalFilePickerScreen(rootPath: rootPath, pickDirectory: pickDirectory, initialPath: initialPath)),
    );
  }

  @override
  State<InternalFilePickerScreen> createState() => _InternalFilePickerScreenState();
}

class _InternalFilePickerScreenState extends State<InternalFilePickerScreen> {
  /// 兜底起始目录：Android 内部存储。
  ///
  /// 被第三方 App 调起时不会走首页那条初始化链路（`DirectoryScreen.initState` 里才会
  /// 调 `provider.init()`），此时 `provider.rootPath` 仍是空串 ⇒ 直接拿它当起始目录会
  /// 打开一个「文件夹为空」的页面，用户必须自己点右上角驱动选择器切到内部存储才能用。
  /// 所以这里统一兜底：起始目录不可用时一律落到内部存储。
  static const String _internalStoragePath = '/storage/emulated/0';

  late String _activeRootPath;
  late String _currentPath;
  bool _isLoading = true;
  List<FileItemModel> _items = [];
  final Set<String> _selectedPaths = {};
  final Map<String, double> _scrollOffsets = {};
  final ScrollController _scrollController = ScrollController();

  static bool _isUsableDir(String? path) =>
      path != null && path.isNotEmpty && Directory(path).existsSync();

  /// 选择器的起始目录：`initialPath` → `rootPath` → 内部存储卷 → 内部存储常量。
  /// 任一为空串或目录已不存在就往下退，绝不让用户停在「文件夹为空」。
  String _resolveStartPath(FileManagerProvider provider) {
    if (_isUsableDir(widget.initialPath)) return widget.initialPath!;
    if (_isUsableDir(widget.rootPath)) return widget.rootPath;
    for (final vol in provider.storageVolumes) {
      if (vol.isInternal && _isUsableDir(vol.path)) return vol.path;
    }
    if (_isUsableDir(_internalStoragePath)) return _internalStoragePath;
    // 极端情况（卷也没枚举出来）：保留原值，由 _loadDirectory 呈现空态。
    return widget.initialPath ?? widget.rootPath;
  }

  @override
  void initState() {
    super.initState();
    final start = _resolveStartPath(context.read<FileManagerProvider>());
    _activeRootPath = start;
    _currentPath = start;
    _scrollController.addListener(() {
      _scrollOffsets[_currentPath] = _scrollController.offset;
    });
    _loadDirectory(_currentPath);
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _loadDirectory(String path) async {
    setState(() => _isLoading = true);

    try {
      final provider = context.read<FileManagerProvider>();
      final isRestricted = provider.isRestrictedPath(path);

      if (isRestricted) {
        final items = await RootShizukuService.listFiles(
          path,
          useRoot: provider.useRootMode,
          showHiddenFiles: provider.showHiddenFiles,
        );

        final folders = <FileItemModel>[];
        final files = <FileItemModel>[];

        for (var item in items) {
          if (item.isDirectory) {
            folders.add(item);
          } else if (!widget.pickDirectory) {
            files.add(item);
          }
        }

        folders.sort((a, b) => FileUtils.compareNatural(a.name, b.name));
        files.sort((a, b) => FileUtils.compareNatural(a.name, b.name));

        if (mounted) {
          setState(() {
            _currentPath = path;
            _items = [...folders, ...files];
            _isLoading = false;
          });

          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (_scrollController.hasClients) {
              final offset = _scrollOffsets[_currentPath] ?? 0.0;
              _scrollController.jumpTo(offset);
            }
          });
        }
        return;
      }

      final dir = Directory(path);
      if (await dir.exists()) {
        _currentPath = path;
        final entities = await dir.list().toList();

        final folders = <FileItemModel>[];
        final files = <FileItemModel>[];

        final items = await Future.wait(entities.map((e) => FileItemModel.fromEntityAsync(e)));

        for (var item in items) {
          try {
            if (item.isDirectory) {
              folders.add(item);
            } else if (!widget.pickDirectory) {
              files.add(item);
            }
          } catch (_) {}
        }

        folders.sort((a, b) => FileUtils.compareNatural(a.name, b.name));
        files.sort((a, b) => FileUtils.compareNatural(a.name, b.name));

        if (mounted) {
          setState(() {
            _items = [...folders, ...files];
            _isLoading = false;
          });

          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (_scrollController.hasClients) {
              final offset = _scrollOffsets[_currentPath] ?? 0.0;
              _scrollController.jumpTo(offset);
            }
          });
        }
        return;
      }
    } catch (e) {
      debugPrint('Error loading directory: $e');
    }

    if (mounted) {
      setState(() => _isLoading = false);
    }
  }

  Future<bool> _goBack() async {
    if (_currentPath == _activeRootPath || _currentPath == '/' || p.dirname(_currentPath) == _currentPath) {
      return false;
    }
    final parent = p.dirname(_currentPath);
    await _loadDirectory(parent);
    return true;
  }

  Future<void> _createFolder() async {
    final newFolderName = await FileActionDialogs.showTextInputDialog(
      context,
      title: L10n.of(context).msgf3a485df,
      hint: L10n.of(context).msgfba1f416,
      actionText: L10n.of(context).ui_create,
    );
    if (newFolderName != null && newFolderName.isNotEmpty) {
      // 名称合法性：含 '/' 等分隔符时 p.join 会拼出嵌套路径，
      // Directory.create() 会把中间目录一并建出。
      final problem = validateFileName(newFolderName);
      if (problem != null) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(fileNameProblemText(L10n.of(context), problem)),
              backgroundColor: Colors.redAccent,
              behavior: SnackBarBehavior.floating,
            ),
          );
        }
        return;
      }
      setState(() => _isLoading = true);
      try {
        final provider = context.read<FileManagerProvider>();
        final isRestricted = provider.isRestrictedPath(_currentPath);
        final targetPath = p.join(_currentPath, newFolderName);

        if (isRestricted) {
          await RootShizukuService.createFolder(
            _currentPath,
            newFolderName,
            useRoot: provider.useRootMode
          );
        } else {
          await Directory(targetPath).create();
        }

        await _loadDirectory(_currentPath);
      } catch (e) {
        debugPrint('Error creating folder in picker: $e');
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(L10n.of(context).e3(e))),
          );
        }
      } finally {
        if (mounted) {
          setState(() => _isLoading = false);
        }
      }
    }
  }

  void _toggleSelect(String path) {
    setState(() {
      if (_selectedPaths.contains(path)) {
        _selectedPaths.remove(path);
      } else {
        _selectedPaths.add(path);
      }
    });
  }

  void _showStorageVolumeModal(BuildContext context) {
    try {
      HapticFeedback.mediumImpact();
    } catch (_) {}

    final theme = Theme.of(context);
    final provider = context.read<FileManagerProvider>();

    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) {
        return Container(
          decoration: BoxDecoration(
            color: theme.colorScheme.surface,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.15),
                blurRadius: 24,
                offset: const Offset(0, -4),
              ),
            ],
          ),
          child: SafeArea(
            child: SingleChildScrollView(
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 16),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Center(
                      child: Container(
                        width: 38,
                        height: 4,
                        margin: const EdgeInsets.only(top: 4, bottom: 16),
                        decoration: BoxDecoration(
                          color: theme.colorScheme.onSurface.withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12.0, vertical: 8),
                      child: Text(
                        L10n.of(context).selectStorageDrive,
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                          fontSize: 18,
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    ...provider.storageVolumes.map((vol) {
                      final isSelected = _activeRootPath == vol.path;
                      return Card(
                        margin: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
                        color: isSelected ? theme.colorScheme.primaryContainer.withValues(alpha: 0.4) : theme.colorScheme.surfaceVariant.withValues(alpha: 0.3),
                        elevation: 0,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16),
                          side: BorderSide(
                            color: isSelected ? theme.colorScheme.primary : Colors.transparent,
                            width: 1.5,
                          ),
                        ),
                        child: ListTile(
                          contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                          leading: Container(
                            width: 44,
                            height: 44,
                            decoration: BoxDecoration(
                              color: isSelected ? theme.colorScheme.primary : theme.colorScheme.primary.withValues(alpha: 0.08),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Icon(
                              vol.isInternal ? Broken.folder_open : Icons.sd_storage_rounded,
                              color: isSelected ? theme.colorScheme.onPrimary : theme.colorScheme.primary,
                              size: 24,
                            ),
                          ),
                          title: Text(
                            vol.isInternal ? L10n.of(context).msg21cefa9b : vol.name,
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 15,
                              color: theme.colorScheme.onSurface,
                            ),
                          ),
                          subtitle: Text(
                            vol.path,
                            style: TextStyle(
                              fontSize: 12,
                              color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          trailing: isSelected
                              ? Icon(Icons.check_circle, color: theme.colorScheme.primary, size: 24)
                              : null,
                          onTap: () {
                            Navigator.pop(ctx);
                            setState(() {
                              _activeRootPath = vol.path;
                              _selectedPaths.clear();
                            });
                            _loadDirectory(vol.path);
                          },
                        ),
                      );
                    }),
                    Card(
                      margin: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
                      color: _activeRootPath == '/' ? theme.colorScheme.primaryContainer.withValues(alpha: 0.4) : theme.colorScheme.surfaceVariant.withValues(alpha: 0.3),
                      elevation: 0,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16),
                        side: BorderSide(
                          color: _activeRootPath == '/' ? theme.colorScheme.primary : Colors.transparent,
                          width: 1.5,
                        ),
                      ),
                      child: ListTile(
                        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                        leading: Container(
                          width: 44,
                          height: 44,
                          decoration: BoxDecoration(
                            color: _activeRootPath == '/' ? theme.colorScheme.primary : theme.colorScheme.primary.withValues(alpha: 0.08),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Icon(
                            Broken.cpu,
                            color: _activeRootPath == '/' ? theme.colorScheme.onPrimary : theme.colorScheme.primary,
                            size: 24,
                          ),
                        ),
                        title: Text(
                          L10n.of(context).msgd730e478,
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 15,
                            color: theme.colorScheme.onSurface,
                          ),
                        ),
                        subtitle: Text(
                          '/',
                          style: TextStyle(
                            fontSize: 12,
                            color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
                          ),
                        ),
                        trailing: _activeRootPath == '/'
                            ? Icon(Icons.check_circle, color: theme.colorScheme.primary, size: 24)
                            : null,
                        onTap: () {
                          Navigator.pop(ctx);
                          setState(() {
                            _activeRootPath = '/';
                            _selectedPaths.clear();
                          });
                          _loadDirectory('/');
                        },
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  /// 单个条目（列表态）。直接复用「文件浏览器」的 FolderItem / FileItem，
  /// 这样选择器与浏览器外观完全一致（同一套卡片、图标、缩略图、选中样式）。
  /// showActionMenu: false —— 选择器不需要重命名/删除/设为首页等操作。
  Widget _buildListItem(FileItemModel item, {required double iconScale, required double paddingMultiplier}) {
    final isSelected = _selectedPaths.contains(item.path);
    if (item.isDirectory) {
      return FolderItem(
        folder: item,
        isSelected: isSelected,
        iconScale: iconScale,
        itemPaddingMultiplier: paddingMultiplier,
        showActionMenu: false,
        onTap: () => _loadDirectory(item.path),
        onLongPress: () => _toggleSelect(item.path),
        onIconTap: () => _loadDirectory(item.path),
        onAction: (_) {},
      );
    }
    return FileItem(
      file: item,
      isSelected: isSelected,
      iconScale: iconScale,
      itemPaddingMultiplier: paddingMultiplier,
      showActionMenu: false,
      onTap: () => _toggleSelect(item.path),
      onLongPress: () => _toggleSelect(item.path),
      onIconTap: () => _toggleSelect(item.path),
      onAction: (_) {},
    );
  }

  /// 单个条目（网格态），同样复用浏览器的 FolderGridItem / FileGridItem。
  Widget _buildGridItem(FileItemModel item, {required double iconScale, required double paddingMultiplier}) {
    final isSelected = _selectedPaths.contains(item.path);
    if (item.isDirectory) {
      return FolderGridItem(
        folder: item,
        isSelected: isSelected,
        iconScale: iconScale,
        itemPaddingMultiplier: paddingMultiplier,
        showActionMenu: false,
        onTap: () => _loadDirectory(item.path),
        onLongPress: () => _toggleSelect(item.path),
        onIconTap: () => _loadDirectory(item.path),
        onAction: (_) {},
      );
    }
    return FileGridItem(
      file: item,
      isSelected: isSelected,
      iconScale: iconScale,
      itemPaddingMultiplier: paddingMultiplier,
      showActionMenu: false,
      onTap: () => _toggleSelect(item.path),
      onLongPress: () => _toggleSelect(item.path),
      onIconTap: () => _toggleSelect(item.path),
      onAction: (_) {},
    );
  }

  Widget _buildBody(BuildContext context, {required bool isGrid, required double iconScale, required double paddingMultiplier}) {
    final mediaQuery = MediaQuery.of(context);
    // FAB 悬浮在 body 之上，会给列表末尾的条目留出可点区域，
    // 否则最底部的文件/文件夹会被「添加所选」按钮遮挡，无法选中。
    final hasFab = widget.pickDirectory || _selectedPaths.isNotEmpty;
    final bottomPadding = hasFab
        ? mediaQuery.padding.bottom + 88 // FAB 高 56 + 边距 16 + 缓冲
        : mediaQuery.padding.bottom + 8;

    return CustomScrollView(
      controller: _scrollController,
      physics: const BouncingScrollPhysics(),
      slivers: [
        SliverPadding(
          padding: EdgeInsets.only(
            top: 8,
            bottom: bottomPadding,
            left: isGrid ? 16 : 0,
            right: isGrid ? 16 : 0,
          ),
          sliver: isGrid
              ? SliverGrid(
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: (mediaQuery.size.width / (110 * iconScale)).floor().clamp(2, 10),
                    mainAxisSpacing: (12 * paddingMultiplier).clamp(4.0, 24.0),
                    crossAxisSpacing: (12 * paddingMultiplier).clamp(4.0, 24.0),
                    childAspectRatio: 0.75,
                  ),
                  delegate: SliverChildBuilderDelegate(
                    (context, index) => _buildGridItem(
                      _items[index],
                      iconScale: iconScale,
                      paddingMultiplier: paddingMultiplier,
                    ),
                    childCount: _items.length,
                  ),
                )
              : SliverList(
                  delegate: SliverChildBuilderDelegate(
                    (context, index) => _buildListItem(
                      _items[index],
                      iconScale: iconScale,
                      paddingMultiplier: paddingMultiplier,
                    ),
                    childCount: _items.length,
                  ),
                ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // 视图状态与「文件浏览器」共用（网格/列表、图标缩放、条目间距），
    // 选择器因此和浏览器长得一模一样；用户在这里切换视图，浏览器也会跟着切。
    final isGrid = context.select<FileManagerProvider, bool>((p) => p.isGridView);
    final iconScale = context.select<FileManagerProvider, double>((p) => p.iconScale);
    final paddingMultiplier = context.select<FileManagerProvider, double>((p) => p.itemPaddingMultiplier);

    return PopScope(
      canPop: _currentPath == _activeRootPath || _currentPath == '/',
      onPopInvoked: (didPop) async {
        if (didPop) return;
        await _goBack();
      },
      child: Scaffold(
        backgroundColor: theme.scaffoldBackgroundColor,
        appBar: AppBar(
          leading: IconButton(
            icon: const Icon(Broken.arrow_left_2),
            onPressed: () async {
              if (!await _goBack()) {
                if (context.mounted) Navigator.pop(context, null);
              }
            },
          ),
          title: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(widget.pickDirectory ? L10n.of(context).msg33b0b21c : L10n.of(context).ui_pick_files_folders, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
              Text(_currentPath, style: TextStyle(fontSize: 12, color: theme.colorScheme.primary)),
            ],
          ),
          actions: [
            IconButton(
              icon: Icon(isGrid ? Broken.row_vertical : Broken.element_3),
              tooltip: L10n.of(context).ui_layout_mode,
              onPressed: () {
                HapticFeedback.selectionClick();
                context.read<FileManagerProvider>().setGridView(!isGrid);
              },
            ),
            IconButton(
              icon: const Icon(Broken.folder_add),
              tooltip: L10n.of(context).msgf3a485df,
              onPressed: _createFolder,
            ),
            IconButton(
              icon: const Icon(Icons.sd_storage_rounded),
              tooltip: L10n.of(context).selectStorageDrive,
              onPressed: () => _showStorageVolumeModal(context),
            ),
            if (_selectedPaths.isNotEmpty)
              IconButton(
                icon: const Icon(Broken.close_square),
                tooltip: L10n.of(context).msgff3200cc,
                onPressed: () => setState(() => _selectedPaths.clear()),
              ),
          ],
        ),
        body: _isLoading
            ? const Center(child: CircularProgressIndicator())
            : _items.isEmpty
                ? Center(child: Text(L10n.of(context).msg4614630a))
                : _buildBody(
                    context,
                    isGrid: isGrid,
                    iconScale: iconScale,
                    paddingMultiplier: paddingMultiplier,
                  ),
        floatingActionButton: widget.pickDirectory
            ? _selectedPaths.isNotEmpty
                ? FloatingActionButton.extended(
                    onPressed: () => Navigator.pop(context, _selectedPaths.toList()),
                    backgroundColor: theme.colorScheme.primary,
                    foregroundColor: theme.colorScheme.onPrimary,
                    icon: const Icon(Broken.folder_add),
                    label: Text(L10n.of(context).ui_pin_selected(_selectedPaths.length)),
                  )
                : FloatingActionButton.extended(
                    onPressed: () => Navigator.pop(context, [_currentPath]),
                    backgroundColor: theme.colorScheme.primary,
                    foregroundColor: theme.colorScheme.onPrimary,
                    icon: const Icon(Broken.folder_add),
                    label: Text(L10n.of(context).msg5dc1fa7b),
                  )
            : _selectedPaths.isNotEmpty
                ? FloatingActionButton.extended(
                    onPressed: () => Navigator.pop(context, _selectedPaths.toList()),
                    backgroundColor: theme.colorScheme.primary,
                    foregroundColor: theme.colorScheme.onPrimary,
                    icon: const Icon(Broken.add),
                    label: Text(L10n.of(context).ui_add_selected(_selectedPaths.length)),
                  )
                : null,
      ),
    );
  }
}
