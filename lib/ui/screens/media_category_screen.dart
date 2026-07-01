import 'dart:io';
import 'package:path/path.dart' as path_helper;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:on_audio_query/on_audio_query.dart';
import 'package:intl/intl.dart';
import 'package:audio_service/audio_service.dart';
import '../../providers/media_provider.dart';
import '../../providers/file_manager_provider.dart';
import '../../services/preferences_service.dart';
import '../../services/audio_background_handler.dart';
import '../../core/utils.dart';
import '../../services/app_manager_service.dart';
import 'image_viewer_screen.dart';
import 'video_player/video_player_screen.dart';
import 'audio_player/audio_player_screen.dart';
import '../../core/icon_fonts/broken_icons.dart';
import 'package:share_plus/share_plus.dart';
import 'package:flutter_svg/flutter_svg.dart';
import '../widgets/file_action_dialogs.dart';
import '../widgets/batch_rename_dialog.dart';
import '../widgets/archive_type_icon.dart';
import '../widgets/file_type_icon.dart';
import 'package:zenfile/l10n/generated/app_localizations.dart';

enum MediaType { images, videos, audios, documents, archives, downloads, apks, screenshots }

class MediaCategoryScreen extends StatefulWidget {
  final MediaType mediaType;
  final AssetPathEntity? album;
  final Function(int)? onNavigateTab;

  const MediaCategoryScreen({super.key, required this.mediaType, this.album, this.onNavigateTab});

  @override
  State<MediaCategoryScreen> createState() => _MediaCategoryScreenState();
}

class _MediaCategoryScreenState extends State<MediaCategoryScreen>
    with SingleTickerProviderStateMixin {
  late AnimationController _shimmerController;

  // Helper: check if artist string is effectively empty (null, empty, or "unknown" from plugin)
  static bool _isUnknownArtist(String? artist) => FileUtils.isUnknownArtist(artist);

  Set<String> _selectedFilePaths = {};
  Set<String> _selectedAssetIds = {};

  bool get _isSelectionMode => _selectedFilePaths.isNotEmpty || _selectedAssetIds.isNotEmpty;

  bool _showFoldersMode = false;
  List<AssetEntity> _albumAssets = [];
  bool _loadingAlbum = false;

  @override
  void initState() {
    super.initState();
    _shimmerController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    )..repeat();

    if (widget.album == null && (widget.mediaType == MediaType.images || widget.mediaType == MediaType.videos)) {
      _showFoldersMode = PreferencesService.getPreferFoldersInMedia();
    }

    if (widget.album != null) {
      _loadAlbumAssets();
    } else {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        context.read<MediaProvider>().loadMedia();
      });
    }
  }

  Future<void> _loadAlbumAssets() async {
    setState(() => _loadingAlbum = true);
    try {
      final count = await widget.album!.assetCountAsync;
      final assets = await widget.album!.getAssetListPaged(page: 0, size: count);
      if (mounted) {
        setState(() {
          _albumAssets = assets;
          _loadingAlbum = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loadingAlbum = false);
    }
  }

  @override
  void dispose() {
    _shimmerController.dispose();
    super.dispose();
  }

  String get _title {
    if (widget.album != null) {
      return widget.album!.name;
    }
    switch (widget.mediaType) {
      case MediaType.images:
        return L10n.of(context).cat_images;
      case MediaType.videos:
        return L10n.of(context).cat_videos;
      case MediaType.audios:
        return L10n.of(context).cat_audios;
      case MediaType.documents:
        return L10n.of(context).cat_documents;
      case MediaType.archives:
        return L10n.of(context).msgc806d0fa;
      case MediaType.downloads:
        return L10n.of(context).cat_downloads;
      case MediaType.apks:
        return L10n.of(context).msg03070d08;
      case MediaType.screenshots:
        return L10n.of(context).cat_screenshots;
    }
  }

  IconData get _emptyIcon {
    switch (widget.mediaType) {
      case MediaType.images:
        return Broken.image;
      case MediaType.videos:
        return Broken.video;
      case MediaType.audios:
        return Broken.music;
      case MediaType.documents:
        return Broken.document;
      case MediaType.archives:
        return Broken.box;
      case MediaType.downloads:
        return Broken.document_download;
      case MediaType.apks:
        return Broken.box;
      case MediaType.screenshots:
        return Broken.mobile;
    }
  }

  void _toggleSelection(String? filePath, String? assetId) {
    setState(() {
      if (filePath != null && filePath.isNotEmpty) {
        if (_selectedFilePaths.contains(filePath)) {
          _selectedFilePaths.remove(filePath);
        } else {
          _selectedFilePaths.add(filePath);
        }
      }
      if (assetId != null && assetId.isNotEmpty) {
        if (_selectedAssetIds.contains(assetId)) {
          _selectedAssetIds.remove(assetId);
        } else {
          _selectedAssetIds.add(assetId);
        }
      }
    });
  }

  void _selectAll(MediaProvider provider) {
    final filePaths = <String>{};
    final assetIds = <String>{};

    if (widget.mediaType == MediaType.images) {
      assetIds.addAll(provider.images.map((e) => e.id));
    } else if (widget.mediaType == MediaType.videos) {
      assetIds.addAll(provider.videos.map((e) => e.id));
    } else if (widget.mediaType == MediaType.screenshots) {
      assetIds.addAll(provider.screenshots.map((e) => e.id));
    } else if (widget.mediaType == MediaType.audios) {
      filePaths.addAll(provider.audios.map((e) => e.data));
    } else if (widget.mediaType == MediaType.archives) {
      filePaths.addAll(provider.archives.map((e) => e.path));
    } else if (widget.mediaType == MediaType.downloads) {
      filePaths.addAll(provider.downloads.map((e) => e.path));
    } else if (widget.mediaType == MediaType.apks) {
      filePaths.addAll(provider.apks.map((e) => e.path));
    } else if (widget.mediaType == MediaType.documents) {
      filePaths.addAll(provider.documents.map((e) => e.path));
    }

    setState(() {
      _selectedFilePaths = filePaths;
      _selectedAssetIds = assetIds;
    });
  }

  void _clearSelection() {
    setState(() {
      _selectedFilePaths.clear();
      _selectedAssetIds.clear();
    });
  }

  Future<void> _handleCopyCut(bool isCut) async {
    final paths = _selectedFilePaths.toList();
    if (_selectedAssetIds.isNotEmpty) {
      final provider = context.read<MediaProvider>();
      final allAssets = [...provider.images, ...provider.videos, ...provider.screenshots];
      for (final id in _selectedAssetIds) {
        final match = allAssets.where((a) => a.id == id).firstOrNull;
        if (match != null) {
          final f = await match.file;
          if (f != null) paths.add(f.path);
        }
      }
    }

    if (paths.isNotEmpty && mounted) {
      context.read<FileManagerProvider>().setClipboard(paths, isCut: isCut);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(isCut ? L10n.of(context).ui_cut_count(paths.length) : L10n.of(context).ui_copied_count(paths.length))),
      );
      _clearSelection();
    }
  }

  Future<void> _handleDelete() async {
    final count = _selectedFilePaths.length + _selectedAssetIds.length;
    if (count == 0) return;

    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(L10n.of(context).msg631cd220),
        content: Text(L10n.of(context).count1(count)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(L10n.of(context).ui_cancel)),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(L10n.of(context).ui_delete),
          ),
        ],
      ),
    );

    if (confirm == true && mounted) {
      final mediaProvider = context.read<MediaProvider>();
      final filePaths = _selectedFilePaths.toList();
      final assetIds = _selectedAssetIds.toList();

      if (_selectedAssetIds.isNotEmpty) {
        final allAssets = [...mediaProvider.images, ...mediaProvider.videos, ...mediaProvider.screenshots];
        for (final id in assetIds) {
          final match = allAssets.where((a) => a.id == id).firstOrNull;
          if (match != null) {
            final f = await match.file;
            if (f != null) filePaths.add(f.path);
          }
        }
      }

      await mediaProvider.deleteMediaItems(filePaths: filePaths, assetIds: assetIds);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(L10n.of(context).count2(count))));
        _clearSelection();
      }
    }
  }

  Future<void> _handlePaste() async {
    final fm = context.read<FileManagerProvider>();
    if (!fm.hasClipboard) return;

    String destDir = '/storage/emulated/0/Download';
    if (widget.mediaType == MediaType.documents) destDir = '/storage/emulated/0/Documents';
    if (widget.mediaType == MediaType.archives) destDir = '/storage/emulated/0/Download';
    if (widget.mediaType == MediaType.apks) destDir = '/storage/emulated/0/Download';

    final dir = Directory(destDir);
    if (!dir.existsSync()) dir.createSync(recursive: true);

    int pastedCount = 0;
    for (final src in fm.clipboardPaths) {
      try {
        final f = File(src);
        if (f.existsSync()) {
          final target = '${dir.path}/${src.split('/').last}';
          if (fm.isCut) {
            f.renameSync(target);
          } else {
            f.copySync(target);
          }
          pastedCount++;
        }
      } catch (_) {}
    }

    fm.clearClipboard();
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(L10n.of(context).pastedcountdestdir(pastedCount, destDir))));
    await context.read<MediaProvider>().loadMedia(forceRefresh: true);
  }

  Future<void> _handleShare() async {
    final count = _selectedFilePaths.length + _selectedAssetIds.length;
    if (count == 0) return;

    final filePaths = _selectedFilePaths.toList();
    if (_selectedAssetIds.isNotEmpty) {
      final mediaProvider = context.read<MediaProvider>();
      final allAssets = [...mediaProvider.images, ...mediaProvider.videos, ...mediaProvider.screenshots];
      for (final id in _selectedAssetIds) {
        final match = allAssets.where((a) => a.id == id).firstOrNull;
        if (match != null) {
          final f = await match.file;
          if (f != null) filePaths.add(f.path);
        }
      }
    }

    final filesToShare = <XFile>[];
    for (final path in filePaths) {
      if (FileSystemEntity.isFileSync(path)) {
        filesToShare.add(XFile(path));
      }
    }

    if (filesToShare.isNotEmpty) {
      try {
        await Share.shareXFiles(filesToShare);
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(L10n.of(context).e10(e))),
          );
        }
      }
    } else {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(L10n.of(context).msgfadbb0bc)),
        );
      }
    }
  }

  Future<void> _handleBatchRename() async {
    final count = _selectedFilePaths.length + _selectedAssetIds.length;
    if (count == 0) return;

    final mediaProvider = context.read<MediaProvider>();
    final filePaths = _selectedFilePaths.toList();
    final assetIds = _selectedAssetIds.toList();

    if (assetIds.isNotEmpty) {
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => const Center(
          child: CircularProgressIndicator(),
        ),
      );

      try {
        final allAssets = [...mediaProvider.images, ...mediaProvider.videos, ...mediaProvider.screenshots];
        for (final id in assetIds) {
          final match = allAssets.where((a) => a.id == id).firstOrNull;
          if (match != null) {
            final f = await match.file;
            if (f != null) filePaths.add(f.path);
          }
        }
      } catch (e) {
        debugPrint('Error resolving assets: $e');
      } finally {
        if (mounted) {
          Navigator.pop(context);
        }
      }
    }

    if (filePaths.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(L10n.of(context).msg3ad97542)),
        );
      }
      return;
    }

    if (filePaths.length == 1) {
      if (mounted) {
        final filePath = filePaths.first;
        final currentName = path_helper.basename(filePath);
        final newName = await FileActionDialogs.showTextInputDialog(
          context,
          title: L10n.of(context).msgc8ce4b36,
          hint: L10n.of(context).msgf139c5cf,
          initialValue: currentName,
          actionText: L10n.of(context).msgc8ce4b36,
        );
        if (newName != null && newName.isNotEmpty && mounted) {
          await context.read<FileManagerProvider>().renameFile(filePath, newName);
          _clearSelection();
          await context.read<MediaProvider>().loadMedia(forceRefresh: true);
        }
      }
      return;
    }

    if (!mounted) return;

    await showDialog<void>(
      context: context,
      barrierColor: Colors.black.withOpacity(0.55),
      builder: (ctx) => BatchRenameDialog(
        provider: context.read<FileManagerProvider>(),
        selectedPaths: filePaths,
      ),
    );

    if (mounted) {
      _clearSelection();
      await context.read<MediaProvider>().loadMedia(forceRefresh: true);
    }
  }

  Widget _buildCopyableRow(String label, String value, BuildContext ctx) {
    if (value.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(ctx);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8.0),
      child: InkWell(
        onTap: () {
          Clipboard.setData(ClipboardData(text: value));
          ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(content: Text('Copied $label to clipboard'), duration: const Duration(seconds: 1)));
        },
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.all(6.0),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                flex: 3,
                child: Text(label, style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: theme.colorScheme.primary)),
              ),
              Expanded(
                flex: 7,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(child: Text(value, style: const TextStyle(fontSize: 13), softWrap: true)),
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

  Future<void> _showPropertiesDialog({String? singleFilePath, String? singleAssetId, String? explicitName}) async {
    final filePaths = singleFilePath != null ? [singleFilePath] : _selectedFilePaths.toList();
    final assetIds = singleAssetId != null ? [singleAssetId] : _selectedAssetIds.toList();

    int totalBytes = 0;
    int count = filePaths.length + assetIds.length;
    DateTime? lastMod;
    String nameDisplay = explicitName ?? '';
    String fullPath = '';
    String mimeType = '';
    String dimensionsOrDuration = '';
    String permissionsStr = '';

    if (assetIds.isNotEmpty) {
      final provider = context.read<MediaProvider>();
      final allAssets = [...provider.images, ...provider.videos, ...provider.screenshots];
      for (final id in assetIds) {
        final match = allAssets.where((a) => a.id == id).firstOrNull;
        if (match != null) {
          final f = await match.file;
          if (f != null) {
            if (count == 1) fullPath = f.path;
            if (count == 1 && nameDisplay.isEmpty) nameDisplay = f.path.split('/').last;
            try {
              final FileStat st = f.statSync();
              totalBytes += st.size;
              if (count == 1) {
                lastMod = st.modified;
                permissionsStr = '${(st.mode & 0x100) != 0 ? "R" : ""}${(st.mode & 0x80) != 0 ? "/W" : ""}';
              }
            } catch (_) {}
            if (count == 1) {
              if (match.type == AssetType.image) {
                dimensionsOrDuration = '${match.width} x ${match.height}';
                mimeType = match.mimeType ?? 'image/${f.path.split('.').last}';
              } else if (match.type == AssetType.video) {
                final d = Duration(seconds: match.duration);
                dimensionsOrDuration = '${match.width} x ${match.height} • ${d.inMinutes}:${(d.inSeconds % 60).toString().padLeft(2, "0")}';
                mimeType = match.mimeType ?? 'video/${f.path.split('.').last}';
              }
            }
          }
        }
      }
    }

    for (final p in filePaths) {
      if (count == 1 && nameDisplay.isEmpty) nameDisplay = p.split('/').last;
      if (count == 1) fullPath = p;
      try {
        final f = File(p);
        if (f.existsSync()) {
          final FileStat st = f.statSync();
          totalBytes += st.size;
          if (count == 1) {
            lastMod = st.modified;
            permissionsStr = '${(st.mode & 0x100) != 0 ? "R" : ""}${(st.mode & 0x80) != 0 ? "/W" : ""}';
            final ext = path_helper.extension(p).toLowerCase();
            if (widget.mediaType == MediaType.audios) {
              mimeType = 'audio/$ext';
            } else if (widget.mediaType == MediaType.apks) {
              mimeType = 'application/vnd.android.package-archive';
            } else if (widget.mediaType == MediaType.archives) {
              mimeType = 'archive/$ext';
            } else {
              mimeType = 'file/$ext';
            }
          }
        }
      } catch (_) {}
    }

    if (!mounted) return;
    final theme = Theme.of(context);
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Row(
          children: [
            Icon(Broken.info_circle, color: theme.colorScheme.primary),
            const SizedBox(width: 10),
            Text(L10n.of(context).ui_properties, style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
          ],
        ),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (count == 1) ...[
                _buildCopyableRow(L10n.of(context).ui_name, nameDisplay, ctx),
                _buildCopyableRow(L10n.of(context).ui_path, fullPath, ctx),
                _buildCopyableRow(L10n.of(context).ui_size, '${FileUtils.formatBytes(totalBytes, 2)} ($totalBytes bytes)', ctx),
                if (lastMod != null) _buildCopyableRow(L10n.of(context).msg1303e638, FileUtils.formatDate(lastMod), ctx),
                if (mimeType.isNotEmpty && mimeType != 'file/') _buildCopyableRow(L10n.of(context).ui_type, mimeType, ctx),
                if (dimensionsOrDuration.isNotEmpty) _buildCopyableRow(L10n.of(context).msg5bab3781, dimensionsOrDuration, ctx),
                if (permissionsStr.isNotEmpty) _buildCopyableRow(L10n.of(context).ui_permissions, permissionsStr, ctx),
              ] else ...[
                _buildCopyableRow(L10n.of(context).msg880a18f3, '$count items', ctx),
                _buildCopyableRow(L10n.of(context).msgea9ecb93, '${FileUtils.formatBytes(totalBytes, 2)} ($totalBytes bytes)', ctx),
              ],
            ],
          ),
        ),
        actions: [
          FilledButton(onPressed: () => Navigator.pop(ctx), child: Text(L10n.of(context).ui_done)),
        ],
      ),
    );
  }

  void _showSingleItemOptions({required String name, String? filePath, String? assetId}) {
    final theme = Theme.of(context);
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      backgroundColor: theme.scaffoldBackgroundColor,
      builder: (ctx) {
        return SafeArea(
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
              GestureDetector(
                onLongPress: (filePath != null)
                    ? () {
                        try {
                          HapticFeedback.mediumImpact();
                        } catch (_) {}
                        Navigator.pop(ctx);
                        context.read<FileManagerProvider>().openFile(context, filePath, forceOpenWith: true);
                      }
                    : null,
                child: Container(
                  width: double.infinity,
                  alignment: Alignment.center,
                  padding: const EdgeInsets.symmetric(vertical: 16.0, horizontal: 24.0),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
                      ),
                      if (filePath != null) ...[
                        const SizedBox(height: 4),
                        Text(
                          L10n.of(context).msg5556baa3,
                          style: TextStyle(fontSize: 11, color: theme.colorScheme.onSurface.withOpacity(0.4)),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              const Divider(height: 1),
              if (filePath != null && FileUtils.isArchive(filePath))
                ListTile(
                  leading: Icon(Broken.archive, color: theme.colorScheme.primary),
                  title: Text(L10n.of(context).ui_extract),
                  onTap: () {
                    Navigator.pop(ctx);
                    context.read<FileManagerProvider>().extractArchiveDirectly(context, filePath);
                  },
                ),
              ListTile(
                leading: Icon(Broken.document_copy, color: theme.colorScheme.primary),
                title: Text(L10n.of(context).ui_copy),
                onTap: () async {
                  Navigator.pop(ctx);
                  String? target = filePath;
                  if (assetId != null) {
                    final provider = context.read<MediaProvider>();
                    final allAssets = [...provider.images, ...provider.videos, ...provider.screenshots];
                    final match = allAssets.where((a) => a.id == assetId).firstOrNull;
                    if (match != null) {
                      final f = await match.file;
                      target = f?.path;
                    }
                  }
                  if (target != null && mounted) {
                    context.read<FileManagerProvider>().setClipboard([target], isCut: false);
                    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Copied $name to clipboard')));
                  }
                },
              ),
              ListTile(
                leading: Icon(Broken.scissor, color: theme.colorScheme.primary),
                title: Text(L10n.of(context).ui_cut),
                onTap: () async {
                  Navigator.pop(ctx);
                  String? target = filePath;
                  if (assetId != null) {
                    final provider = context.read<MediaProvider>();
                    final allAssets = [...provider.images, ...provider.videos, ...provider.screenshots];
                    final match = allAssets.where((a) => a.id == assetId).firstOrNull;
                    if (match != null) {
                      final f = await match.file;
                      target = f?.path;
                    }
                  }
                  if (target != null && mounted) {
                    context.read<FileManagerProvider>().setClipboard([target], isCut: true);
                    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Cut $name to clipboard')));
                  }
                },
              ),
              ListTile(
                leading: const Icon(Broken.trash, color: Colors.red),
                title: Text(L10n.of(context).ui_delete, style: TextStyle(color: Colors.red)),
                onTap: () async {
                  Navigator.pop(ctx);
                  final confirm = await showDialog<bool>(
                    context: context,
                    builder: (c) => AlertDialog(
                      title: Text(L10n.of(context).msg631cd220),
                      content: Text(L10n.of(context).ui_permanently_delete_name(name)),
                      actions: [
                        TextButton(onPressed: () => Navigator.pop(c, false), child: Text(L10n.of(context).ui_cancel)),
                        FilledButton(
                          style: FilledButton.styleFrom(backgroundColor: Colors.red),
                          onPressed: () => Navigator.pop(c, true),
                          child: Text(L10n.of(context).ui_delete),
                        ),
                      ],
                    ),
                  );
                  if (confirm == true && mounted) {
                    final mediaProvider = context.read<MediaProvider>();
                    List<String> files = [];
                    if (filePath != null) files.add(filePath);
                    if (assetId != null) {
                      final allAssets = [...mediaProvider.images, ...mediaProvider.videos, ...mediaProvider.screenshots];
                      final match = allAssets.where((a) => a.id == assetId).firstOrNull;
                      if (match != null) {
                        final f = await match.file;
                        if (f != null) files.add(f.path);
                      }
                    }
                    await mediaProvider.deleteMediaItems(filePaths: files, assetIds: assetId != null ? [assetId] : []);
                    if (mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(L10n.of(context).name(name))));
                    }
                  }
                },
              ),
              if (filePath != null)
                ListTile(
                  leading: Icon(Broken.folder_open, color: theme.colorScheme.primary),
                  title: Text(L10n.of(context).msgcd8264f1),
                  onTap: () {
                    context.read<FileManagerProvider>().showFileInLocation(filePath);
                    Navigator.pop(ctx);
                    Navigator.popUntil(context, (route) => route.isFirst);
                    widget.onNavigateTab?.call(1);
                  },
                ),
              if (filePath != null)
                ListTile(
                  leading: Icon(Broken.edit, color: theme.colorScheme.primary),
                  title: Text(L10n.of(context).msgc8ce4b36),
                  onTap: () async {
                    Navigator.pop(ctx);
                    final currentName = path_helper.basename(filePath);
                    final newName = await FileActionDialogs.showTextInputDialog(
                      context,
                      title: L10n.of(context).msgc8ce4b36,
                      hint: L10n.of(context).msgf139c5cf,
                      initialValue: currentName,
                      actionText: L10n.of(context).msgc8ce4b36,
                    );
                    if (newName != null && newName.isNotEmpty && mounted) {
                      await context.read<FileManagerProvider>().renameFile(filePath, newName);
                      context.read<MediaProvider>().loadMedia(forceRefresh: true);
                    }
                  },
                ),
              if (filePath != null)
                ListTile(
                  leading: Icon(Broken.eye, color: theme.colorScheme.primary),
                  title: Text(L10n.of(context).msg2a4cfb07),
                  onTap: () {
                    Navigator.pop(ctx);
                    context.read<FileManagerProvider>().openFile(context, filePath, forceOpenWith: true);
                  },
                ),
              ListTile(
                leading: Icon(Broken.info_circle, color: theme.colorScheme.primary),
                title: Text(L10n.of(context).ui_properties),
                onTap: () {
                  Navigator.pop(ctx);
                  _showPropertiesDialog(singleFilePath: filePath, singleAssetId: assetId, explicitName: name);
                },
              ),
              ListTile(
                leading: Icon(Icons.share_outlined, color: theme.colorScheme.primary),
                title: Text(L10n.of(context).ui_share),
                onTap: () async {
                  Navigator.pop(ctx);
                  String? target = filePath;
                  if (assetId != null) {
                    final provider = context.read<MediaProvider>();
                    final allAssets = [...provider.images, ...provider.videos, ...provider.screenshots];
                    final match = allAssets.where((a) => a.id == assetId).firstOrNull;
                    if (match != null) {
                      final f = await match.file;
                      target = f?.path;
                    }
                  }
                  if (target != null && FileSystemEntity.isFileSync(target)) {
                    try {
                      await Share.shareXFiles([XFile(target)]);
                    } catch (e) {
                      if (mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text(L10n.of(context).e10(e))),
                        );
                      }
                    }
                  } else {
                    if (mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text(L10n.of(context).msg8bf52387)),
                      );
                    }
                  }
                },
              ),
            ],
          ),
        ),
      );
    },
  );
}

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final fm = context.watch<FileManagerProvider>();
    final canPaste = (widget.mediaType == MediaType.downloads || widget.mediaType == MediaType.documents || widget.mediaType == MediaType.archives || widget.mediaType == MediaType.apks) && fm.hasClipboard;

    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      appBar: AppBar(
        title: Text(_isSelectionMode ? L10n.of(context).ui_selected_count(_selectedFilePaths.length + _selectedAssetIds.length) : _title),
        leading: _isSelectionMode
            ? IconButton(icon: const Icon(Broken.close_square), onPressed: _clearSelection)
            : null,
        actions: [
          if (_isSelectionMode)
            Consumer<MediaProvider>(
              builder: (context, provider, child) => IconButton(
                icon: const Icon(Broken.task_square),
                tooltip: L10n.of(context).ui_select_all,
                onPressed: () => _selectAll(provider),
              ),
            )
          else ...[
            if (canPaste)
              IconButton(
                icon: const Icon(Broken.clipboard),
                tooltip: L10n.of(context).msg419be096,
                onPressed: _handlePaste,
              ),
            Consumer<MediaProvider>(
              builder: (context, provider, child) {
                return PopupMenuButton<MediaSortOrder>(
                  icon: const Icon(Icons.sort),
                  tooltip: L10n.of(context).ui_sort_options,
                  onSelected: (order) => provider.setSortOrder(order),
                  itemBuilder: (context) => [
                    CheckedPopupMenuItem(
                      value: MediaSortOrder.newest,
                      checked: provider.sortOrder == MediaSortOrder.newest,
                      child: Text(L10n.of(context).msg5093bc80),
                    ),
                    CheckedPopupMenuItem(
                      value: MediaSortOrder.oldest,
                      checked: provider.sortOrder == MediaSortOrder.oldest,
                      child: Text(L10n.of(context).ui_oldest_first),
                    ),
                    CheckedPopupMenuItem(
                      value: MediaSortOrder.dateWise,
                      checked: provider.sortOrder == MediaSortOrder.dateWise,
                      child: Text(L10n.of(context).msgbc74b5a8),
                    ),
                    CheckedPopupMenuItem(
                      value: MediaSortOrder.newestGrouped,
                      checked: provider.sortOrder == MediaSortOrder.newestGrouped,
                      child: Text(L10n.of(context).msgef7ae768),
                    ),
                    CheckedPopupMenuItem(
                      value: MediaSortOrder.oldestGrouped,
                      checked: provider.sortOrder == MediaSortOrder.oldestGrouped,
                      child: Text(L10n.of(context).msgb8140039),
                    ),
                    CheckedPopupMenuItem(
                      value: MediaSortOrder.sizeLargest,
                      checked: provider.sortOrder == MediaSortOrder.sizeLargest,
                      child: Text(L10n.of(context).msg2e2a26bb),
                    ),
                    CheckedPopupMenuItem(
                      value: MediaSortOrder.sizeSmallest,
                      checked: provider.sortOrder == MediaSortOrder.sizeSmallest,
                      child: Text(L10n.of(context).ui_size_small),
                    ),
                  ],
                );
              },
            ),
            Consumer<MediaProvider>(
              builder: (context, provider, child) {
                return IconButton(
                  icon: const Icon(Icons.refresh),
                  onPressed: () => provider.loadMedia(forceRefresh: true),
                  tooltip: L10n.of(context).ui_refresh,
                );
              },
            ),
          ],
        ],
      ),
      body: Column(
        children: [
          if (widget.album == null && (widget.mediaType == MediaType.images || widget.mediaType == MediaType.videos))
            _buildFoldersToggle(theme),
          if (widget.album == null && widget.mediaType == MediaType.audios)
            _buildResumePlayerButton(theme),
          Expanded(
            child: Consumer<MediaProvider>(
              builder: (context, provider, child) {
                if (widget.album == null && _showFoldersMode) {
                  final albums = widget.mediaType == MediaType.images ? provider.imageAlbums : provider.videoAlbums;
                  if (albums.isEmpty) {
                    return _buildEmptyState(theme);
                  }
                  return GridView.builder(
                    padding: const EdgeInsets.all(12),
                    physics: const BouncingScrollPhysics(),
                    gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: 2,
                      crossAxisSpacing: 12,
                      mainAxisSpacing: 12,
                      childAspectRatio: 0.95,
                    ),
                    itemCount: albums.length,
                    itemBuilder: (context, index) {
                      final album = albums[index];
                      return FolderGridItem(
                        album: album,
                        onTap: () {
                          Navigator.push(
                            context,
                            _slideRoute(MediaCategoryScreen(
                              mediaType: widget.mediaType,
                              album: album,
                              onNavigateTab: widget.onNavigateTab,
                            )),
                          );
                        },
                      );
                    },
                  );
                }

                if (widget.album != null) {
                  if (_loadingAlbum) {
                    return _buildShimmerLoading(theme);
                  }
                  final displayAssets = List<AssetEntity>.from(_albumAssets);
                  if (provider.sortOrder == MediaSortOrder.newest ||
                      provider.sortOrder == MediaSortOrder.newestGrouped ||
                      provider.sortOrder == MediaSortOrder.dateWise) {
                    displayAssets.sort((a, b) => b.createDateTime.compareTo(a.createDateTime));
                  } else if (provider.sortOrder == MediaSortOrder.oldest ||
                             provider.sortOrder == MediaSortOrder.oldestGrouped) {
                    displayAssets.sort((a, b) => a.createDateTime.compareTo(b.createDateTime));
                  } else if (provider.sortOrder == MediaSortOrder.sizeLargest ||
                             provider.sortOrder == MediaSortOrder.sizeSmallest) {
                    final isSmallest = provider.sortOrder == MediaSortOrder.sizeSmallest;
                    displayAssets.sort((a, b) {
                      final aRes = a.width * a.height;
                      final bRes = b.width * b.height;
                      return isSmallest ? aRes.compareTo(bRes) : bRes.compareTo(aRes);
                    });
                  }

                  final isDateWise = provider.sortOrder == MediaSortOrder.dateWise;
                  final isGrouped = provider.sortOrder == MediaSortOrder.newestGrouped ||
                      provider.sortOrder == MediaSortOrder.oldestGrouped ||
                      provider.sortOrder == MediaSortOrder.dateWise;

                  if (widget.mediaType == MediaType.images) {
                    return _buildImageGrid(displayAssets, theme, isDateWise, isGrouped);
                  } else {
                    return _buildVideoGrid(displayAssets, theme, isDateWise, isGrouped);
                  }
                }

                if (provider.isLoading && !provider.isLoaded) {
                  return _buildShimmerLoading(theme);
                }

                final isDateWise = provider.sortOrder == MediaSortOrder.dateWise;
                final isGrouped = provider.sortOrder == MediaSortOrder.newestGrouped ||
                    provider.sortOrder == MediaSortOrder.oldestGrouped ||
                    provider.sortOrder == MediaSortOrder.dateWise;

                if (widget.mediaType == MediaType.images) {
                  return _buildImageGrid(provider.images, theme, isDateWise, isGrouped);
                } else if (widget.mediaType == MediaType.videos) {
                  return _buildVideoGrid(provider.videos, theme, isDateWise, isGrouped);
                } else if (widget.mediaType == MediaType.audios) {
                  return _buildAudioList(provider.audios, theme, isDateWise, isGrouped);
                } else if (widget.mediaType == MediaType.screenshots) {
                  return _buildImageGrid(provider.screenshots, theme, isDateWise, isGrouped);
                } else if (widget.mediaType == MediaType.archives) {
                  return _buildGenericFileList(provider.archives, theme, isDateWise, isGrouped);
                } else if (widget.mediaType == MediaType.downloads) {
                  return _buildGenericFileList(provider.downloads, theme, isDateWise, isGrouped);
                } else if (widget.mediaType == MediaType.apks) {
                  return _buildGenericFileList(provider.apks, theme, isDateWise, isGrouped);
                } else {
                  return _buildDocumentList(provider.documents, theme, isDateWise, isGrouped);
                }
              },
            ),
          ),
        ],
      ),
      bottomNavigationBar: _isSelectionMode ? _buildBottomActionBar(theme) : null,
    );
  }

  Widget _buildBottomActionBar(ThemeData theme) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 8),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.08), blurRadius: 10, offset: const Offset(0, -2))],
      ),
      child: SafeArea(
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          physics: const BouncingScrollPhysics(),
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _buildActionItem(theme, icon: Broken.document_copy, label: L10n.of(context).ui_copy, onTap: () => _handleCopyCut(false)),
              _buildActionItem(theme, icon: Broken.scissor, label: L10n.of(context).ui_cut, onTap: () => _handleCopyCut(true)),
              _buildActionItem(theme, icon: Broken.edit, label: L10n.of(context).msgc8ce4b36, onTap: _handleBatchRename),
              _buildActionItem(theme, icon: Broken.trash, label: L10n.of(context).ui_delete, color: Colors.red, onTap: _handleDelete),
              _buildActionItem(theme, icon: Icons.share_outlined, label: L10n.of(context).ui_share, onTap: _handleShare),
              _buildActionItem(theme, icon: Broken.info_circle, label: L10n.of(context).ui_info, onTap: () => _showPropertiesDialog()),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildActionItem(ThemeData theme, {required IconData icon, required String label, required VoidCallback onTap, Color? color}) {
    final c = color ?? theme.colorScheme.primary;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: c, size: 24),
            const SizedBox(height: 4),
            Text(label, style: TextStyle(color: c, fontSize: 12, fontWeight: FontWeight.w600)),
          ],
        ),
      ),
    );
  }

  Widget _buildShimmerLoading(ThemeData theme) {
    final isDark = theme.brightness == Brightness.dark;
    final baseColor = isDark ? const Color(0xFF1E1E2E) : const Color(0xFFE0E0E0);
    final highlightColor = isDark ? const Color(0xFF2A2A3E) : const Color(0xFFF5F5F5);

    return AnimatedBuilder(
      animation: _shimmerController,
      builder: (context, child) {
        return GridView.builder(
          padding: const EdgeInsets.all(8),
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 3, crossAxisSpacing: 6, mainAxisSpacing: 6),
          itemCount: 24,
          itemBuilder: (context, index) {
            return ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: ShaderMask(
                shaderCallback: (rect) => LinearGradient(
                  colors: [baseColor, highlightColor, baseColor],
                  stops: [0.0, _shimmerController.value, 1.0],
                ).createShader(rect),
                child: Container(color: baseColor),
              ),
            );
          },
        );
      },
    );
  }

  DateTime _getItemDateTime(dynamic item) {
    if (item is AssetEntity) {
      return item.createDateTime;
    } else if (item is SongModel) {
      try {
        final f = File(item.data);
        if (f.existsSync()) {
          return f.statSync().modified;
        }
      } catch (_) {}
      return DateTime.fromMillisecondsSinceEpoch((item.dateAdded ?? 0) * 1000);
    } else if (item is FileSystemEntity) {
      try {
        return item.statSync().modified;
      } catch (_) {}
    }
    return DateTime.fromMillisecondsSinceEpoch(0);
  }

  Map<String, List<T>> _groupByMonth<T>(List<T> items, DateTime Function(T) getDate) {
    final groups = <String, List<T>>{};
    for (final item in items) {
      final date = getDate(item);
      final monthKey = DateFormat('MMMM yyyy').format(date);
      groups.putIfAbsent(monthKey, () => []).add(item);
    }
    return groups;
  }

  Widget _buildGroupedView<T>({
    required List<T> items,
    required ThemeData theme,
    required bool isGrid,
    required bool isDateWise,
    required Widget Function(T item, bool isDateWise) itemTileBuilder,
  }) {
    if (items.isEmpty) return _buildEmptyState(theme);

    final grouped = _groupByMonth(items, _getItemDateTime);
    final entries = grouped.entries.toList();

    return CustomScrollView(
      physics: const BouncingScrollPhysics(),
      slivers: [
        for (final entry in entries) ...[
          // Month Header
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.only(left: 16, right: 16, top: 16, bottom: 8),
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.primaryContainer.withOpacity(0.35),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(
                        color: theme.colorScheme.primary.withOpacity(0.15),
                      ),
                    ),
                    child: Text(
                      entry.key,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        color: theme.colorScheme.primary,
                        letterSpacing: 0.5,
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Divider(
                      color: theme.colorScheme.outlineVariant.withOpacity(0.3),
                      thickness: 1,
                    ),
                  ),
                ],
              ),
            ),
          ),
          // Group Items (Grid or List)
          if (isGrid)
            SliverPadding(
              padding: const EdgeInsets.symmetric(horizontal: 6),
              sliver: SliverGrid(
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 3,
                  crossAxisSpacing: 6,
                  mainAxisSpacing: 6,
                ),
                delegate: SliverChildBuilderDelegate(
                  (context, index) {
                    final item = entry.value[index];
                    return itemTileBuilder(item, isDateWise);
                  },
                  childCount: entry.value.length,
                ),
              ),
            )
          else
            SliverList(
              delegate: SliverChildBuilderDelegate(
                (context, index) {
                  final item = entry.value[index];
                  return itemTileBuilder(item, isDateWise);
                },
                childCount: entry.value.length,
              ),
            ),
          // Spacing / line after month of files
          SliverToBoxAdapter(
            child: entry.key == entries.last.key
                ? const SizedBox(height: 16)
                : Column(
                    children: [
                      const SizedBox(height: 12),
                      Divider(
                        color: theme.colorScheme.outlineVariant.withOpacity(0.15),
                        thickness: 1.5,
                        indent: 16,
                        endIndent: 16,
                      ),
                      const SizedBox(height: 8),
                    ],
                  ),
          ),
        ],
      ],
    );
  }

  Widget _buildImageTile(
    dynamic item,
    ThemeData theme,
    bool isSelected,
    bool showDate,
    String dateStr,
    List<dynamic> images,
  ) {
    final isAsset = item is AssetEntity;
    final id = isAsset ? item.id : item.path;
    final path = isAsset ? '' : item.path;
    final title = isAsset ? (item.title ?? 'Image_$id') : path_helper.basename(path);

    return Stack(
      key: ValueKey(id),
      fit: StackFit.expand,
      children: [
        if (isAsset)
          _CachedImageTile(
            asset: item,
            onTap: () async {
              if (_isSelectionMode) {
                _toggleSelection(null, item.id);
              } else {
                final file = await item.file;
                if (file != null && mounted) {
                  Navigator.push(context, _slideRoute(ImageViewerScreen(
                    imagePath: file.path,
                    siblingItems: images,
                    initialAssetId: item.id,
                  )));
                }
              }
            },
            onLongPress: () => _toggleSelection(null, item.id),
          )
        else
          GestureDetector(
            onTap: () {
              if (_isSelectionMode) {
                _toggleSelection(path, null);
              } else {
                Navigator.push(context, _slideRoute(ImageViewerScreen(
                  imagePath: path,
                  siblingItems: images,
                )));
              }
            },
            onLongPress: () => _toggleSelection(path, null),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: path.toLowerCase().endsWith('.svg')
                  ? SvgPicture.file(
                      File(path),
                      fit: BoxFit.cover,
                      width: double.infinity,
                      height: double.infinity,
                      placeholderBuilder: (context) => Container(
                        color: Colors.grey.withOpacity(0.1),
                        child: const Center(child: Icon(Broken.image, size: 24, color: Colors.grey)),
                      ),
                    )
                  : Image.file(
                      File(path),
                      fit: BoxFit.cover,
                      width: double.infinity,
                      height: double.infinity,
                      errorBuilder: (context, error, stackTrace) => Container(
                        color: Colors.grey.withOpacity(0.1),
                        child: const Center(child: Icon(Broken.image, size: 24, color: Colors.grey)),
                      ),
                    ),
            ),
          ),
        if (showDate)
          Positioned(
            bottom: 4,
            left: 4,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
              decoration: BoxDecoration(color: Colors.black.withOpacity(0.6), borderRadius: BorderRadius.circular(4)),
              child: Text(
                dateStr.split(',').first,
                style: const TextStyle(color: Colors.white, fontSize: 9, fontWeight: FontWeight.w600),
              ),
            ),
          ),
        if (_isSelectionMode || isSelected)
          Positioned(
            top: 6,
            right: 6,
            child: Icon(
              isSelected ? Broken.tick_square : Icons.check_box_outline_blank,
              color: isSelected ? theme.colorScheme.primary : Colors.white.withOpacity(0.8),
              size: 24,
            ),
          )
        else
          Positioned(
            top: 4,
            right: 4,
            child: InkWell(
              onTap: () async {
                if (isAsset) {
                  final f = await item.file;
                  if (f != null) {
                    _showSingleItemOptions(name: title, filePath: f.path, assetId: item.id);
                  }
                } else {
                  _showSingleItemOptions(name: title, filePath: path);
                }
              },
              child: Container(
                padding: const EdgeInsets.all(4),
                decoration: BoxDecoration(color: Colors.black.withOpacity(0.5), shape: BoxShape.circle),
                child: const Icon(Broken.more, color: Colors.white, size: 18),
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildImageGrid(List<dynamic> images, ThemeData theme, bool isDateWise, bool isGrouped) {
    if (images.isEmpty) return _buildEmptyState(theme);
    if (isGrouped) {
      return _buildGroupedView<dynamic>(
        items: images,
        theme: theme,
        isGrid: true,
        isDateWise: isDateWise,
        itemTileBuilder: (item, showDate) {
          final isSelected = item is AssetEntity
              ? _selectedAssetIds.contains(item.id)
              : _selectedFilePaths.contains(item.path);
          DateTime date = DateTime.fromMillisecondsSinceEpoch(0);
          if (item is AssetEntity) {
            date = item.createDateTime;
          } else if (item is FileSystemEntity) {
            try {
              date = File(item.path).statSync().modified;
            } catch (_) {}
          }
          final dateStr = FileUtils.formatDate(date);
          return _buildImageTile(item, theme, isSelected, showDate, dateStr, images);
        },
      );
    }
    return GridView.builder(
      padding: const EdgeInsets.all(6),
      physics: const BouncingScrollPhysics(),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 3, crossAxisSpacing: 6, mainAxisSpacing: 6),
      itemCount: images.length,
      itemBuilder: (context, index) {
        final item = images[index];
        final isSelected = item is AssetEntity
            ? _selectedAssetIds.contains(item.id)
            : _selectedFilePaths.contains(item.path);
        DateTime date = DateTime.fromMillisecondsSinceEpoch(0);
        if (item is AssetEntity) {
          date = item.createDateTime;
        } else if (item is FileSystemEntity) {
          try {
            date = File(item.path).statSync().modified;
          } catch (_) {}
        }
        final dateStr = FileUtils.formatDate(date);
        return _buildImageTile(item, theme, isSelected, isDateWise, dateStr, images);
      },
    );
  }

  Widget _RemoteVideoTile({
    required String remotePath,
    required VoidCallback onTap,
    required VoidCallback onLongPress,
  }) {
    return _RemoteVideoTileWidget(
      remotePath: remotePath,
      onTap: onTap,
      onLongPress: onLongPress,
    );
  }

  Widget _buildVideoTile(
    dynamic item,
    ThemeData theme,
    bool isSelected,
    bool showDate,
    String dateStr,
    List<dynamic> videoList,
  ) {
    final isAsset = item is AssetEntity;
    final id = isAsset ? item.id : item.path;
    final path = isAsset ? '' : item.path;
    final title = isAsset ? (item.title ?? 'Video_$id') : path_helper.basename(path);

    return Stack(
      key: ValueKey(id),
      fit: StackFit.expand,
      children: [
        if (isAsset)
          _CachedVideoTile(
            asset: item,
            onTap: () async {
              if (_isSelectionMode) {
                _toggleSelection(null, item.id);
              } else {
                final file = await item.file;
                if (file != null && mounted) {
                  Navigator.push(
                    context,
                    _slideRoute(
                      VideoPlayerScreen(
                        videoPath: file.path,
                        playlist: videoList,
                        initialIndex: videoList.indexOf(item),
                      ),
                    ),
                  );
                }
              }
            },
            onLongPress: () => _toggleSelection(null, item.id),
          )
        else if (path.startsWith('remote://'))
          _RemoteVideoTile(
            remotePath: path,
            onTap: () {
              if (_isSelectionMode) {
                _toggleSelection(path, null);
              } else {
                Navigator.push(
                  context,
                  _slideRoute(
                    VideoPlayerScreen(
                      videoPath: path,
                      playlist: videoList,
                      initialIndex: videoList.indexOf(item),
                    ),
                  ),
                );
              }
            },
            onLongPress: () => _toggleSelection(path, null),
          )
        else
          GestureDetector(
            onTap: () {
              if (_isSelectionMode) {
                _toggleSelection(path, null);
              } else {
                Navigator.push(
                  context,
                  _slideRoute(
                    VideoPlayerScreen(
                      videoPath: path,
                      playlist: videoList,
                      initialIndex: videoList.indexOf(item),
                    ),
                  ),
                );
              }
            },
            onLongPress: () => _toggleSelection(path, null),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: Container(
                color: theme.colorScheme.surfaceVariant,
                padding: const EdgeInsets.all(8),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Broken.video, size: 28, color: theme.colorScheme.primary),
                    const SizedBox(height: 6),
                    Text(
                      title,
                      style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w500),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                    ),
                  ],
                ),
              ),
            ),
          ),
        if (showDate)
          Positioned(
            bottom: 4,
            left: 4,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
              decoration: BoxDecoration(color: Colors.black.withOpacity(0.6), borderRadius: BorderRadius.circular(4)),
              child: Text(
                dateStr.split(',').first,
                style: const TextStyle(color: Colors.white, fontSize: 9, fontWeight: FontWeight.w600),
              ),
            ),
          ),
        if (_isSelectionMode || isSelected)
          Positioned(
            top: 6,
            right: 6,
            child: Icon(
              isSelected ? Broken.tick_square : Icons.check_box_outline_blank,
              color: isSelected ? theme.colorScheme.primary : Colors.white.withOpacity(0.8),
              size: 24,
            ),
          )
        else
          Positioned(
            top: 4,
            right: 4,
            child: InkWell(
              onTap: () async {
                if (isAsset) {
                  final f = await item.file;
                  if (f != null) {
                    _showSingleItemOptions(name: title, filePath: f.path, assetId: item.id);
                  }
                } else {
                  _showSingleItemOptions(name: title, filePath: path);
                }
              },
              child: Container(
                padding: const EdgeInsets.all(4),
                decoration: BoxDecoration(color: Colors.black.withOpacity(0.5), shape: BoxShape.circle),
                child: const Icon(Broken.more, color: Colors.white, size: 18),
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildVideoGrid(List<dynamic> videos, ThemeData theme, bool isDateWise, bool isGrouped) {
    if (videos.isEmpty) return _buildEmptyState(theme);
    if (isGrouped) {
      return _buildGroupedView<dynamic>(
        items: videos,
        theme: theme,
        isGrid: true,
        isDateWise: isDateWise,
        itemTileBuilder: (item, showDate) {
          final isSelected = item is AssetEntity
              ? _selectedAssetIds.contains(item.id)
              : _selectedFilePaths.contains(item.path);
          DateTime date = DateTime.fromMillisecondsSinceEpoch(0);
          if (item is AssetEntity) {
            date = item.createDateTime;
          } else if (item is FileSystemEntity) {
            try {
              date = File(item.path).statSync().modified;
            } catch (_) {}
          }
          final dateStr = FileUtils.formatDate(date);
          return _buildVideoTile(item, theme, isSelected, showDate, dateStr, videos);
        },
      );
    }
    return GridView.builder(
      padding: const EdgeInsets.all(6),
      physics: const BouncingScrollPhysics(),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 3, crossAxisSpacing: 6, mainAxisSpacing: 6),
      itemCount: videos.length,
      itemBuilder: (context, index) {
        final item = videos[index];
        final isSelected = item is AssetEntity
            ? _selectedAssetIds.contains(item.id)
            : _selectedFilePaths.contains(item.path);
        DateTime date = DateTime.fromMillisecondsSinceEpoch(0);
        if (item is AssetEntity) {
          date = item.createDateTime;
        } else if (item is FileSystemEntity) {
          try {
            date = File(item.path).statSync().modified;
          } catch (_) {}
        }
        final dateStr = FileUtils.formatDate(date);
        return _buildVideoTile(item, theme, isSelected, isDateWise, dateStr, videos);
      },
    );
  }

  Widget _buildAudioTile(
    SongModel audio,
    ThemeData theme,
    bool isSelected,
    bool showDate,
    String dateStr,
    int index,
    List<SongModel> audios,
  ) {
    final path = audio.data;
    return ListTile(
      key: ValueKey(path),
      onTap: () {
        if (_isSelectionMode) {
          _toggleSelection(path, null);
        } else {
          Navigator.push(
            context,
            PageRouteBuilder(
              pageBuilder: (context, animation, secondaryAnimation) => AudioPlayerScreen(
                audioPath: path,
                title: audio.title,
                artist: _isUnknownArtist(audio.artist) ? L10n.of(context).msg5e32276d : audio.artist!,
                allSongs: audios,
                initialIndex: index,
              ),
              transitionsBuilder: (context, animation, secondaryAnimation, child) => SlideTransition(
                position: Tween<Offset>(begin: const Offset(0, 1), end: Offset.zero).animate(CurvedAnimation(parent: animation, curve: Curves.easeOutCubic)),
                child: child,
              ),
              transitionDuration: const Duration(milliseconds: 400),
            ),
          );
        }
      },
      onLongPress: () => _toggleSelection(path, null),
      leading: Stack(
        children: [
          Container(
            width: 50,
            height: 50,
            decoration: BoxDecoration(borderRadius: BorderRadius.circular(10), color: theme.colorScheme.primaryContainer),
            child: QueryArtworkWidget(
              id: audio.id,
              type: ArtworkType.AUDIO,
              artworkBorder: BorderRadius.circular(10),
              artworkFit: BoxFit.cover,
              artworkWidth: 50,
              artworkHeight: 50,
              nullArtworkWidget: Icon(Icons.music_note, size: 26, color: theme.colorScheme.onPrimaryContainer),
            ),
          ),
          if (_isSelectionMode || isSelected)
            Positioned(
              bottom: 0,
              right: 0,
              child: Container(
                decoration: BoxDecoration(color: theme.colorScheme.surface, shape: BoxShape.circle),
                child: Icon(isSelected ? Broken.tick_square : Icons.check_box_outline_blank, color: isSelected ? theme.colorScheme.primary : Colors.grey, size: 20),
              ),
            ),
        ],
      ),
      title: Text(audio.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
      subtitle: Text(
        showDate
            ? '${_isUnknownArtist(audio.artist) ? L10n.of(context).msg5e32276d : audio.artist!} \u2022 $dateStr'
            : _isUnknownArtist(audio.artist) ? L10n.of(context).msg5e32276d : audio.artist!,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(color: theme.colorScheme.onSurface.withOpacity(0.55), fontSize: 11),
      ),
      trailing: _isSelectionMode
          ? null
          : IconButton(
              icon: const Icon(Broken.more),
              onPressed: () => _showSingleItemOptions(name: audio.title, filePath: path),
            ),
    );
  }

  Widget _buildAudioList(List<SongModel> audios, ThemeData theme, bool isDateWise, bool isGrouped) {
    if (audios.isEmpty) return _buildEmptyState(theme);
    if (isGrouped) {
      return _buildGroupedView<SongModel>(
        items: audios,
        theme: theme,
        isGrid: false,
        isDateWise: isDateWise,
        itemTileBuilder: (audio, showDate) {
          final path = audio.data;
          final isSelected = _selectedFilePaths.contains(path);
          DateTime? modified;
          try {
            modified = File(path).statSync().modified;
          } catch (_) {}
          final dateStr = modified != null ? FileUtils.formatDate(modified) : L10n.of(context).msg424a0110;
          final index = audios.indexOf(audio);
          return _buildAudioTile(audio, theme, isSelected, showDate, dateStr, index, audios);
        },
      );
    }
    return ListView.builder(
      physics: const BouncingScrollPhysics(),
      itemCount: audios.length,
      itemBuilder: (context, index) {
        final audio = audios[index];
        final path = audio.data;
        final isSelected = _selectedFilePaths.contains(path);
        DateTime? modified;
        try {
          modified = File(path).statSync().modified;
        } catch (_) {}
        final dateStr = modified != null ? FileUtils.formatDate(modified) : L10n.of(context).msg424a0110;
        return _buildAudioTile(audio, theme, isSelected, isDateWise, dateStr, index, audios);
      },
    );
  }

  Widget _buildDocumentTile(
    FileSystemEntity doc,
    ThemeData theme,
    bool isSelected,
    bool showDate,
    int size,
    DateTime modified,
  ) {
    final path = doc.path;
    final name = path.split('/').last;
    final ext = name.contains('.') ? name.substring(name.lastIndexOf('.')).toLowerCase() : '';
    final icon = _docIcon(ext);
    final color = _docColor(ext);

    return ListTile(
      key: ValueKey(path),
      onTap: () {
        if (_isSelectionMode) {
          _toggleSelection(path, null);
        } else {
          context.read<FileManagerProvider>().openFile(context, path);
        }
      },
      onLongPress: () => _toggleSelection(path, null),
      leading: Stack(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(color: color.withOpacity(0.15), borderRadius: BorderRadius.circular(10)),
            child: Center(
              child: FileTypeIcon(
                icon: icon,
                label: FileUtils.getDocumentTypeLabel(path),
                color: color,
                iconScale: 1.0,
              ),
            ),
          ),
          if (_isSelectionMode || isSelected)
            Positioned(
              bottom: 0,
              right: 0,
              child: Container(
                decoration: BoxDecoration(color: theme.colorScheme.surface, shape: BoxShape.circle),
                child: Icon(isSelected ? Broken.tick_square : Icons.check_box_outline_blank, color: isSelected ? theme.colorScheme.primary : Colors.grey, size: 20),
              ),
            ),
        ],
      ),
      title: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w500)),
      subtitle: Text(
        showDate
            ? '${FileUtils.formatBytes(size, 1)} • ${FileUtils.formatDate(modified)}'
            : FileUtils.formatBytes(size, 1),
        style: TextStyle(color: theme.colorScheme.onSurface.withOpacity(0.6), fontSize: 11),
      ),
      trailing: _isSelectionMode
          ? null
          : IconButton(
              icon: const Icon(Broken.more),
              onPressed: () => _showSingleItemOptions(name: name, filePath: path),
            ),
    );
  }

  Widget _buildDocumentList(List<FileSystemEntity> documents, ThemeData theme, bool isDateWise, bool isGrouped) {
    if (documents.isEmpty) return _buildEmptyState(theme);
    if (isGrouped) {
      return _buildGroupedView<FileSystemEntity>(
        items: documents,
        theme: theme,
        isGrid: false,
        isDateWise: isDateWise,
        itemTileBuilder: (doc, showDate) {
          final isSelected = _selectedFilePaths.contains(doc.path);
          int size = 0;
          DateTime modified = DateTime.now();
          try {
            final st = doc.statSync();
            size = st.size;
            modified = st.modified;
          } catch (_) {}
          return _buildDocumentTile(doc, theme, isSelected, showDate, size, modified);
        },
      );
    }
    return ListView.builder(
      physics: const BouncingScrollPhysics(),
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: documents.length,
      itemBuilder: (context, index) {
        final doc = documents[index];
        final isSelected = _selectedFilePaths.contains(doc.path);
        int size = 0;
        DateTime modified = DateTime.now();
        try {
          final st = doc.statSync();
          size = st.size;
          modified = st.modified;
        } catch (_) {}
        return _buildDocumentTile(doc, theme, isSelected, isDateWise, size, modified);
      },
    );
  }

  Widget _buildGenericFileTile(
    FileSystemEntity file,
    ThemeData theme,
    bool isSelected,
    bool showDate,
    int size,
    DateTime modified,
  ) {
    final path = file.path;
    final name = path.split('/').last;
    final iconColor = FileUtils.getColorForFile(name, context);
    final isApk = name.toLowerCase().endsWith('.apk') || name.toLowerCase().endsWith('.xapk') || name.toLowerCase().endsWith('.apks') || name.toLowerCase().endsWith('.apkm');

    return ListTile(
      key: ValueKey(path),
      onTap: () {
        if (_isSelectionMode) {
          _toggleSelection(path, null);
        } else {
          context.read<FileManagerProvider>().openFile(context, path);
        }
      },
      onLongPress: () => _toggleSelection(path, null),
      leading: Stack(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(color: iconColor.withOpacity(0.15), borderRadius: BorderRadius.circular(10)),
            child: isApk
                ? _ApkThumbnail(path: path, iconColor: iconColor)
                : path.toLowerCase().endsWith('.svg')
                    ? ClipRRect(
                        borderRadius: BorderRadius.circular(10),
                        child: SvgPicture.file(
                          File(path),
                          fit: BoxFit.cover,
                          placeholderBuilder: (context) => Icon(FileUtils.getIconForFile(name), color: iconColor, size: 22),
                        ),
                      )
                    : FileUtils.isArchive(path)
                        ? ArchiveTypeIcon(
                            label: FileUtils.getArchiveTypeLabel(path),
                            color: iconColor,
                            iconScale: 1.0,
                          )
                        : FileUtils.isDocument(path)
                            ? Center(
                                child: FileTypeIcon(
                                  icon: FileUtils.getIconForFile(name),
                                  label: FileUtils.getDocumentTypeLabel(path),
                                  color: iconColor,
                                  iconScale: 1.0,
                                ),
                              )
                            : Icon(FileUtils.getIconForFile(name), color: iconColor, size: 22),
          ),
          if (_isSelectionMode || isSelected)
            Positioned(
              bottom: 0,
              right: 0,
              child: Container(
                decoration: BoxDecoration(color: theme.colorScheme.surface, shape: BoxShape.circle),
                child: Icon(isSelected ? Broken.tick_square : Icons.check_box_outline_blank, color: isSelected ? theme.colorScheme.primary : Colors.grey, size: 20),
              ),
            ),
        ],
      ),
      title: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w500)),
      subtitle: Text(
        showDate
            ? '${FileUtils.formatBytes(size, 1)} • ${FileUtils.formatDate(modified)}'
            : FileUtils.formatBytes(size, 1),
        style: TextStyle(color: theme.colorScheme.onSurface.withOpacity(0.6), fontSize: 11),
      ),
      trailing: _isSelectionMode
          ? null
          : IconButton(
              icon: const Icon(Broken.more),
              onPressed: () => _showSingleItemOptions(name: name, filePath: path),
            ),
    );
  }

  Widget _buildGenericFileList(List<FileSystemEntity> files, ThemeData theme, bool isDateWise, bool isGrouped) {
    if (files.isEmpty) return _buildEmptyState(theme);
    if (isGrouped) {
      return _buildGroupedView<FileSystemEntity>(
        items: files,
        theme: theme,
        isGrid: false,
        isDateWise: isDateWise,
        itemTileBuilder: (file, showDate) {
          final isSelected = _selectedFilePaths.contains(file.path);
          int size = 0;
          DateTime modified = DateTime.now();
          try {
            final st = file.statSync();
            size = st.size;
            modified = st.modified;
          } catch (_) {}
          return _buildGenericFileTile(file, theme, isSelected, showDate, size, modified);
        },
      );
    }
    return ListView.builder(
      physics: const BouncingScrollPhysics(),
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: files.length,
      itemBuilder: (context, index) {
        final file = files[index];
        final isSelected = _selectedFilePaths.contains(file.path);
        int size = 0;
        DateTime modified = DateTime.now();
        try {
          final st = file.statSync();
          size = st.size;
          modified = st.modified;
        } catch (_) {}
        return _buildGenericFileTile(file, theme, isSelected, isDateWise, size, modified);
      },
    );
  }

  IconData _docIcon(String ext) {
    switch (ext) {
      case '.pdf': return Broken.document;
      case '.doc': case '.docx': case '.xls': case '.xlsx': return Broken.document_text;
      case '.ppt': case '.pptx': return Broken.presention_chart;
      case '.txt': return Icons.description;
      default: return Broken.document;
    }
  }

  Color _docColor(String ext) {
    switch (ext) {
      case '.pdf': return Colors.redAccent;
      case '.doc': case '.docx': return Colors.blueAccent;
      case '.xls': case '.xlsx': return Colors.green;
      case '.ppt': case '.pptx': return Colors.orangeAccent;
      case '.txt': return Colors.blue.shade700;
      default: return Colors.teal;
    }
  }

  Widget _buildEmptyState(ThemeData theme) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(_emptyIcon, size: 72, color: theme.colorScheme.onSurface.withOpacity(0.2)),
          const SizedBox(height: 16),
          Text(L10n.of(context).ui_not_found_title(_title.toLowerCase()), style: TextStyle(color: theme.colorScheme.onSurface.withOpacity(0.5), fontSize: 16)),
        ],
      ),
    );
  }

  PageRoute _slideRoute(Widget page) {
    return PageRouteBuilder(
      pageBuilder: (context, animation, secondaryAnimation) => page,
      transitionsBuilder: (context, animation, secondaryAnimation, child) => FadeTransition(opacity: animation, child: child),
      transitionDuration: const Duration(milliseconds: 250),
    );
  }

  Widget _buildFoldersToggle(ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Container(
        height: 40,
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest.withOpacity(0.4),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: [
            Expanded(
              child: InkWell(
                onTap: () {
                  setState(() => _showFoldersMode = false);
                  PreferencesService.savePreferFoldersInMedia(false);
                },
                borderRadius: BorderRadius.circular(12),
                child: Container(
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: !_showFoldersMode ? theme.colorScheme.primary : Colors.transparent,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    L10n.of(context).msgb19671d6,
                    style: TextStyle(
                      color: !_showFoldersMode ? theme.colorScheme.onPrimary : theme.colorScheme.onSurfaceVariant,
                      fontSize: 13,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ),
            ),
            Expanded(
              child: InkWell(
                onTap: () {
                  setState(() => _showFoldersMode = true);
                  PreferencesService.savePreferFoldersInMedia(true);
                },
                borderRadius: BorderRadius.circular(12),
                child: Container(
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: _showFoldersMode ? theme.colorScheme.primary : Colors.transparent,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    L10n.of(context).msg1f4c1042,
                    style: TextStyle(
                      color: _showFoldersMode ? theme.colorScheme.onPrimary : theme.colorScheme.onSurfaceVariant,
                      fontSize: 13,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildResumePlayerButton(ThemeData theme) {
    final handler = getAudioHandler();
    final lastPlayed = PreferencesService.getLastPlayedAudio();

    String formatDuration(Duration d) {
      final h = d.inHours;
      final m = d.inMinutes % 60;
      final s = d.inSeconds % 60;
      if (h > 0) {
        return '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
      }
      return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: StreamBuilder<PlaybackState>(
        stream: handler.playbackState,
        builder: (context, playingSnapshot) {
          final isPlaying = playingSnapshot.data?.playing ?? false;
          return StreamBuilder<MediaItem?>(
            stream: handler.mediaItem,
            builder: (context, itemSnapshot) {
              // 优先使用后台播放器的当前曲目，确保切歌后按钮立即同步
              final activeItem = handler.hasActivePlayer
                  ? (itemSnapshot.data ?? handler.currentMediaItem)
                  : null;
              final Map<String, String>? info;
              if (activeItem != null) {
                info = {
                  'path': activeItem.id,
                  'title': activeItem.title,
                  'artist': activeItem.artist ?? '',
                };
              } else if (lastPlayed != null) {
                info = lastPlayed;
              } else {
                return const SizedBox.shrink();
              }

              // 检查文件是否还存在
              final file = File(info['path']!);
              if (!file.existsSync()) return const SizedBox.shrink();

              final path = info['path']!;
              final title = info['title']!;
              final artist = info['artist']!;
              final isCurrentTrack = handler.isPlayingPath(path);
              final position = playingSnapshot.data?.updatePosition ?? Duration.zero;
              final duration = itemSnapshot.data?.duration ?? Duration.zero;
              final savedMs = PreferencesService.getPlaybackPosition(path);
              final savedPosition = savedMs != null ? Duration(milliseconds: savedMs) : Duration.zero;

              String subtitle;
              if (isCurrentTrack && isPlaying && duration > Duration.zero) {
                subtitle = '${formatDuration(position)} / ${formatDuration(duration)}';
              } else if (isCurrentTrack && !isPlaying && duration > Duration.zero) {
                subtitle = '${formatDuration(position)} / ${formatDuration(duration)} · ${L10n.of(context).ui_resume_playback}';
              } else if (savedPosition.inSeconds > 0) {
                subtitle = '${L10n.of(context).ui_resume_playback} · ${formatDuration(savedPosition)}';
              } else {
                subtitle = _isUnknownArtist(artist) ? L10n.of(context).msg5e32276d : artist;
              }

              final progress = duration.inMilliseconds > 0
                  ? (position.inMilliseconds / duration.inMilliseconds).clamp(0.0, 1.0)
                  : 0.0;

              return Stack(
                children: [
                  Positioned.fill(
                    child: CustomPaint(
                      painter: _RoundedRectProgressPainter(
                        progress: progress,
                        strokeWidth: 3,
                        radius: 16,
                        color: theme.colorScheme.primary,
                        backgroundColor: theme.colorScheme.onSurface.withOpacity(0.1),
                      ),
                    ),
                  ),
                  Material(
                    color: theme.colorScheme.primaryContainer.withOpacity(0.5),
                    borderRadius: BorderRadius.circular(13),
                    clipBehavior: Clip.antiAlias,
                    child: InkWell(
                      borderRadius: BorderRadius.circular(13),
                      onTap: () => _openAudioPlayerFromResume(path, title, artist),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                        child: Row(
                          children: [
                            SizedBox(
                              width: 40,
                              height: 40,
                              child: Material(
                                color: theme.colorScheme.primary,
                                shape: const CircleBorder(),
                                child: InkWell(
                                  customBorder: const CircleBorder(),
                                  onTap: () => _toggleResumePlayback(path, title, artist),
                                  child: Icon(
                                    isCurrentTrack && isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
                                    color: theme.colorScheme.onPrimary,
                                    size: 24,
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(
                                    isCurrentTrack && isPlaying ? L10n.of(context).ui_now_playing : L10n.of(context).ui_resume_playback,
                                    style: TextStyle(
                                      fontSize: 12,
                                      fontWeight: FontWeight.bold,
                                      color: theme.colorScheme.primary,
                                    ),
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    title,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontSize: 14,
                                      fontWeight: FontWeight.w600,
                                      color: theme.colorScheme.onSurface,
                                    ),
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    subtitle,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: theme.colorScheme.onSurface.withOpacity(0.6),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            Icon(
                              Icons.chevron_right_rounded,
                              color: theme.colorScheme.onSurface.withOpacity(0.4),
                              size: 24,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              );
            },
          );
        },
      ),
    );
  }

  void _openAudioPlayerFromResume(String path, String title, String artist) {
    final handler = getAudioHandler();
    final isSamePlaying = handler.isPlayingPath(path) && handler.hasActivePlayer;

    if (!isSamePlaying && handler.hasActivePlayer) {
      // 正在播放其他歌曲，先停止后台播放器，避免与新播放器同时出声
      handler.stop();
    }

    final provider = context.read<MediaProvider>();
    final audios = provider.audios;
    final index = audios.indexWhere((s) => s.data == path);

    Navigator.push(
      context,
      PageRouteBuilder(
        pageBuilder: (context, animation, secondaryAnimation) => AudioPlayerScreen(
          audioPath: path,
          title: title,
          artist: artist,
          allSongs: index >= 0 ? audios : null,
          initialIndex: index >= 0 ? index : 0,
          existingPlayer: isSamePlaying ? handler.currentPlayer : null,
        ),
        transitionsBuilder: (context, animation, secondaryAnimation, child) => SlideTransition(
          position: Tween<Offset>(begin: const Offset(0, 1), end: Offset.zero).animate(CurvedAnimation(parent: animation, curve: Curves.easeOutCubic)),
          child: child,
        ),
        transitionDuration: const Duration(milliseconds: 400),
      ),
    );
  }

  Future<void> _toggleResumePlayback(String path, String title, String artist) async {
    final handler = getAudioHandler();
    final isCurrentTrack = handler.isPlayingPath(path);

    if (!handler.hasActivePlayer || !isCurrentTrack) {
      // 没有播放器或播放的不是当前歌曲：打开播放器并开始播放
      _openAudioPlayerFromResume(path, title, artist);
      return;
    }

    if (handler.playbackState.value.playing) {
      await handler.pause();
    } else {
      await handler.play();
    }
  }
}

class _RoundedRectProgressPainter extends CustomPainter {
  final double progress;
  final double strokeWidth;
  final double radius;
  final Color color;
  final Color backgroundColor;

  _RoundedRectProgressPainter({
    required this.progress,
    required this.strokeWidth,
    required this.radius,
    required this.color,
    required this.backgroundColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Rect.fromLTWH(
      strokeWidth / 2,
      strokeWidth / 2,
      size.width - strokeWidth,
      size.height - strokeWidth,
    );
    final rrect = RRect.fromRectAndRadius(rect, Radius.circular(radius));

    final bgPaint = Paint()
      ..color = backgroundColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round;

    final fgPaint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round;

    final path = Path()..addRRect(rrect);

    // 绘制背景轨道
    canvas.drawPath(path, bgPaint);

    // 根据进度绘制前景
    if (progress > 0) {
      final metrics = path.computeMetrics().first;
      final drawLength = metrics.length * progress;
      final extractedPath = metrics.extractPath(0, drawLength);
      canvas.drawPath(extractedPath, fgPaint);
    }
  }

  @override
  bool shouldRepaint(covariant _RoundedRectProgressPainter oldDelegate) {
    return oldDelegate.progress != progress ||
        oldDelegate.strokeWidth != strokeWidth ||
        oldDelegate.radius != radius ||
        oldDelegate.color != color ||
        oldDelegate.backgroundColor != backgroundColor;
  }
}

class _ThumbnailShimmerPlaceholder extends StatefulWidget {
  const _ThumbnailShimmerPlaceholder({super.key});

  @override
  State<_ThumbnailShimmerPlaceholder> createState() => _ThumbnailShimmerPlaceholderState();
}

class _ThumbnailShimmerPlaceholderState extends State<_ThumbnailShimmerPlaceholder> with SingleTickerProviderStateMixin {
  late AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this, duration: const Duration(milliseconds: 1200))..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final baseColor = isDark ? const Color(0xFF1E1E2E) : const Color(0xFFE0E0E0);
    final highlightColor = isDark ? const Color(0xFF2A2A3E) : const Color(0xFFF5F5F5);

    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) => ShaderMask(
        shaderCallback: (rect) => LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [baseColor, highlightColor, baseColor],
          stops: [0.0, _controller.value, 1.0],
        ).createShader(rect),
        child: Container(color: baseColor),
      ),
    );
  }
}

class _CachedImageTile extends StatefulWidget {
  final AssetEntity asset;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  const _CachedImageTile({required this.asset, required this.onTap, required this.onLongPress});

  @override
  State<_CachedImageTile> createState() => _CachedImageTileState();
}

class _CachedImageTileState extends State<_CachedImageTile> {
  Uint8List? _thumbnail;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _loadThumbnail();
  }

  Future<void> _loadThumbnail() async {
    if (ThumbnailCache.hasCached(widget.asset.id)) {
      if (mounted) {
        setState(() {
          _thumbnail = ThumbnailCache.getCached(widget.asset.id);
          _loaded = true;
        });
      }
      return;
    }
    final data = await ThumbnailCache.get(widget.asset);
    if (mounted) {
      setState(() {
        _thumbnail = data;
        _loaded = true;
      });
    }
  }

  @override
  void didUpdateWidget(covariant _CachedImageTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.asset.id != widget.asset.id) {
      _loaded = false;
      _thumbnail = null;
      _loadThumbnail();
    }
  }

  @override
  Widget build(BuildContext context) {
    final title = widget.asset.title ?? '';
    final isSvg = title.toLowerCase().endsWith('.svg');
    return GestureDetector(
      onTap: widget.onTap,
      onLongPress: widget.onLongPress,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 300),
          child: isSvg
              ? FutureBuilder<File?>(
                  future: widget.asset.file,
                  builder: (context, snapshot) {
                    if (snapshot.hasData && snapshot.data != null) {
                      return SvgPicture.file(
                        snapshot.data!,
                        key: const ValueKey('svg'),
                        fit: BoxFit.cover,
                        width: double.infinity,
                        height: double.infinity,
                        placeholderBuilder: (context) => const _ThumbnailShimmerPlaceholder(key: ValueKey('shimmer')),
                      );
                    }
                    return const _ThumbnailShimmerPlaceholder(key: ValueKey('shimmer'));
                  },
                )
              : _loaded && _thumbnail != null
                  ? Image.memory(
                      _thumbnail!,
                      key: const ValueKey('img'),
                      fit: BoxFit.cover,
                      width: double.infinity,
                      height: double.infinity,
                      gaplessPlayback: true,
                      errorBuilder: (context, error, stackTrace) => Container(
                        color: Colors.grey.withOpacity(0.1),
                        child: const Center(child: Icon(Broken.image, size: 24, color: Colors.grey)),
                      ),
                    )
                  : const _ThumbnailShimmerPlaceholder(key: ValueKey('shimmer')),
        ),
      ),
    );
  }
}

/// 远程视频缩略图瓦片，通过 ThumbnailCache 加载远程视频缩略图。
class _RemoteVideoTileWidget extends StatefulWidget {
  final String remotePath;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  const _RemoteVideoTileWidget({
    required this.remotePath,
    required this.onTap,
    required this.onLongPress,
  });

  @override
  State<_RemoteVideoTileWidget> createState() => _RemoteVideoTileWidgetState();
}

class _RemoteVideoTileWidgetState extends State<_RemoteVideoTileWidget> {
  Uint8List? _thumbnail;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _loadThumbnail();
  }

  Future<void> _loadThumbnail() async {
    final data = await ThumbnailCache.getForRemoteVideo(widget.remotePath);
    if (mounted) {
      setState(() {
        _thumbnail = data;
        _loaded = true;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: widget.onTap,
      onLongPress: widget.onLongPress,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: Stack(
          fit: StackFit.expand,
          children: [
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 300),
              child: _loaded && _thumbnail != null
                  ? Image.memory(
                      _thumbnail!,
                      key: const ValueKey('remote_vid'),
                      fit: BoxFit.cover,
                      width: double.infinity,
                      height: double.infinity,
                      gaplessPlayback: true,
                      errorBuilder: (context, error, stackTrace) => Container(
                        color: Colors.grey.withOpacity(0.1),
                        child: const Center(child: Icon(Broken.video, size: 24, color: Colors.grey)),
                      ),
                    )
                  : const _ThumbnailShimmerPlaceholder(key: ValueKey('shimmer')),
            ),
            Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [Colors.transparent, Colors.black.withOpacity(0.5)],
                  ),
                ),
              ),
            ),
            Center(
              child: Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(color: Colors.black.withOpacity(0.5), shape: BoxShape.circle),
                child: const Icon(Icons.play_arrow, color: Colors.white, size: 22),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CachedVideoTile extends StatefulWidget {
  final AssetEntity asset;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  const _CachedVideoTile({required this.asset, required this.onTap, required this.onLongPress});

  @override
  State<_CachedVideoTile> createState() => _CachedVideoTileState();
}

class _CachedVideoTileState extends State<_CachedVideoTile> {
  Uint8List? _thumbnail;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _loadThumbnail();
  }

  Future<void> _loadThumbnail() async {
    if (ThumbnailCache.hasCached(widget.asset.id)) {
      if (mounted) {
        setState(() {
          _thumbnail = ThumbnailCache.getCached(widget.asset.id);
          _loaded = true;
        });
      }
      return;
    }
    final data = await ThumbnailCache.get(widget.asset);
    if (mounted) {
      setState(() {
        _thumbnail = data;
        _loaded = true;
      });
    }
  }

  String _formatDuration(int seconds) {
    final d = Duration(seconds: seconds);
    final m = d.inMinutes;
    final s = d.inSeconds % 60;
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }

  @override
  void didUpdateWidget(covariant _CachedVideoTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.asset.id != widget.asset.id) {
      _loaded = false;
      _thumbnail = null;
      _loadThumbnail();
    }
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: widget.onTap,
      onLongPress: widget.onLongPress,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: Stack(
          fit: StackFit.expand,
          children: [
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 300),
              child: _loaded && _thumbnail != null
                  ? Image.memory(
                      _thumbnail!,
                      key: const ValueKey('vid'),
                      fit: BoxFit.cover,
                      width: double.infinity,
                      height: double.infinity,
                      gaplessPlayback: true,
                      errorBuilder: (context, error, stackTrace) => Container(
                        color: Colors.grey.withOpacity(0.1),
                        child: const Center(child: Icon(Broken.video, size: 24, color: Colors.grey)),
                      ),
                    )
                  : const _ThumbnailShimmerPlaceholder(key: ValueKey('shimmer')),
            ),
            Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Colors.transparent, Colors.black.withOpacity(0.5)]),
                ),
              ),
            ),
            Center(
              child: Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(color: Colors.black.withOpacity(0.5), shape: BoxShape.circle),
                child: const Icon(Icons.play_arrow, color: Colors.white, size: 22),
              ),
            ),
            Positioned(
              bottom: 4,
              right: 6,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                decoration: BoxDecoration(color: Colors.black.withOpacity(0.7), borderRadius: BorderRadius.circular(4)),
                child: Text(
                  _formatDuration(widget.asset.duration),
                  style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.bold),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class FolderGridItem extends StatefulWidget {
  final AssetPathEntity album;
  final VoidCallback onTap;

  const FolderGridItem({super.key, required this.album, required this.onTap});

  @override
  State<FolderGridItem> createState() => _FolderGridItemState();
}

class _FolderGridItemState extends State<FolderGridItem> {
  AssetEntity? _firstAsset;
  int _count = 0;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadDetails();
  }

  Future<void> _loadDetails() async {
    try {
      final count = await widget.album.assetCountAsync;
      if (count > 0) {
        final assets = await widget.album.getAssetListPaged(page: 0, size: 1);
        if (assets.isNotEmpty && mounted) {
          setState(() {
            _firstAsset = assets.first;
            _count = count;
            _loading = false;
          });
          return;
        }
      }
    } catch (_) {}
    if (mounted) {
      setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    
    return GestureDetector(
      onTap: widget.onTap,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(20),
        child: Container(
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHighest.withOpacity(0.3),
            border: Border.all(color: theme.colorScheme.outlineVariant.withOpacity(0.4)),
          ),
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (_firstAsset != null)
                _CachedImageTile(
                  asset: _firstAsset!,
                  onTap: widget.onTap,
                  onLongPress: () {},
                )
              else
                Container(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: [theme.colorScheme.surfaceContainerHighest, theme.colorScheme.surface],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
                  ),
                  child: Icon(Broken.folder_2, color: theme.colorScheme.primary.withOpacity(0.5), size: 40),
                ),
              // Gradient Overlay
              Positioned.fill(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: [Colors.transparent, Colors.black.withOpacity(0.85)],
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      stops: const [0.4, 1.0],
                    ),
                  ),
                ),
              ),
              // Content
              Positioned(
                bottom: 12,
                left: 12,
                right: 12,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      widget.album.name,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 14,
                        fontWeight: FontWeight.bold,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '$_count items',
                      style: TextStyle(
                        color: Colors.white.withOpacity(0.75),
                        fontSize: 11,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
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

class _ApkThumbnail extends StatefulWidget {
  final String path;
  final Color iconColor;

  const _ApkThumbnail({
    required this.path,
    required this.iconColor,
  });

  @override
  State<_ApkThumbnail> createState() => _ApkThumbnailState();
}

class _ApkThumbnailState extends State<_ApkThumbnail> {
  static final Map<String, Uint8List?> _apkIconCache = {};
  Uint8List? _apkIcon;

  @override
  void initState() {
    super.initState();
    _loadApkIcon();
  }

  Future<void> _loadApkIcon() async {
    final path = widget.path;
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

  @override
  Widget build(BuildContext context) {
    if (_apkIcon != null) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: Image.memory(
          _apkIcon!,
          fit: BoxFit.cover,
          width: 44,
          height: 44,
          errorBuilder: (context, error, stackTrace) => Icon(Broken.mobile, color: widget.iconColor, size: 22),
        ),
      );
    }
    return Icon(Broken.mobile, color: widget.iconColor, size: 22);
  }
}
