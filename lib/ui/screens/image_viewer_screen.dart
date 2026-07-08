import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:photo_view/photo_view.dart';
import 'package:photo_view/photo_view_gallery.dart';
import 'package:mime/mime.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:flutter_avif/flutter_avif.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:share_plus/share_plus.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';
import '../../providers/media_provider.dart';
import '../../providers/file_manager_provider.dart';
import '../../core/icon_fonts/broken_icons.dart';
import '../../core/utils.dart';
import 'package:zenfile/l10n/generated/app_localizations.dart';

final Uint8List _kTransparentImage = Uint8List.fromList([
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D,
  0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, 0x89, 0x00, 0x00, 0x00,
  0x0A, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
  0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00, 0x00, 0x00, 0x00, 0x49,
  0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
]);

class ImageViewerScreen extends StatefulWidget {
  final String imagePath;
  final List<String>? siblingPaths;
  final List<AssetEntity>? siblingAssets;
  final List<dynamic>? siblingItems;
  final String? initialAssetId;

  const ImageViewerScreen({
    super.key,
    required this.imagePath,
    this.siblingPaths,
    this.siblingAssets,
    this.siblingItems,
    this.initialAssetId,
  });

  @override
  State<ImageViewerScreen> createState() => _ImageViewerScreenState();
}

class _ImageViewerScreenState extends State<ImageViewerScreen> {
  late PageController _pageController;
  List<String> _imageList = [];
  final Map<int, File?> _fileCache = {};
  int _currentIndex = 0;
  bool _showUI = true;
  bool _isZoomed = false;

  @override
  void initState() {
    super.initState();
    _findSiblings();
    _pageController = PageController(initialPage: _currentIndex);
    _preloadAdjacent(_currentIndex);
  }

  void _findSiblings() {
    if (widget.siblingItems != null && widget.siblingItems!.isNotEmpty) {
      _currentIndex = widget.siblingItems!.indexWhere((e) {
        if (e is AssetEntity) return e.id == widget.initialAssetId;
        if (e is FileSystemEntity) return e.path == widget.imagePath;
        return false;
      });
      if (_currentIndex == -1) _currentIndex = 0;
      return;
    }

    if (widget.siblingAssets != null && widget.siblingAssets!.isNotEmpty) {
      _currentIndex = widget.siblingAssets!.indexWhere((e) => e.id == widget.initialAssetId);
      if (_currentIndex == -1) _currentIndex = 0;
      return;
    }

    if (widget.siblingPaths != null && widget.siblingPaths!.isNotEmpty) {
      _imageList = widget.siblingPaths!;
      _currentIndex = _imageList.indexOf(widget.imagePath);
      if (_currentIndex == -1) _currentIndex = 0;
      return;
    }

    try {
      final file = File(widget.imagePath);
      final parent = file.parent;
      final files = parent.listSync();
      final images = <String>[];
      for (final f in files) {
        if (f is File) {
          final mime = lookupMimeType(f.path);
          if ((mime != null && mime.startsWith('image/')) || f.path.toLowerCase().endsWith('.avif')) {
            images.add(f.path);
          }
        }
      }
      images.sort((a, b) => a.compareTo(b));
      _imageList = images;
      _currentIndex = _imageList.indexOf(widget.imagePath);
      if (_currentIndex == -1) {
        _imageList.insert(0, widget.imagePath);
        _currentIndex = 0;
      }
    } catch (_) {
      _imageList = [widget.imagePath];
      _currentIndex = 0;
    }
  }

  void _preloadAdjacent(int index) {
    if (widget.siblingItems == null && widget.siblingAssets == null) return;
    _loadAssetFile(index);
    _loadAssetFile(index - 1);
    _loadAssetFile(index + 1);
  }

  Future<void> _loadAssetFile(int index) async {
    final length = widget.siblingItems != null
        ? widget.siblingItems!.length
        : (widget.siblingAssets != null ? widget.siblingAssets!.length : 0);
    if (index < 0 || index >= length) return;
    if (_fileCache.containsKey(index) && _fileCache[index] != null) return;

    if (widget.siblingItems != null) {
      final item = widget.siblingItems![index];
      if (item is AssetEntity) {
        final file = await item.file;
        if (mounted && file != null) {
          setState(() {
            _fileCache[index] = file;
          });
        }
      } else if (item is FileSystemEntity) {
        setState(() {
          _fileCache[index] = File(item.path);
        });
      }
    } else if (widget.siblingAssets != null) {
      final asset = widget.siblingAssets![index];
      final file = await asset.file;
      if (mounted && file != null) {
        setState(() {
          _fileCache[index] = file;
        });
      }
    }
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  /// 获取当前图片的 File 对象
  File? _getCurrentFile() {
    if (widget.siblingItems != null && _currentIndex < widget.siblingItems!.length) {
      final item = widget.siblingItems![_currentIndex];
      if (item is AssetEntity) {
        return _fileCache[_currentIndex];
      } else if (item is FileSystemEntity) {
        return File(item.path);
      }
    } else if (widget.siblingAssets != null && _currentIndex < widget.siblingAssets!.length) {
      return _fileCache[_currentIndex];
    } else if (_imageList.isNotEmpty && _currentIndex < _imageList.length) {
      return File(_imageList[_currentIndex]);
    }
    return null;
  }

  void _showImageOptions() {
    final l10n = L10n.of(context);
    final file = _getCurrentFile();
    final filePath = file?.path;

    showModalBottomSheet(
      context: context,
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        final theme = Theme.of(ctx);
        final primary = theme.colorScheme.primary;
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        file?.path.split('/').last.split('\\').last ?? 'Image',
                        style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              if (filePath != null && FileUtils.isArchive(filePath)) ...[
                ListTile(
                  leading: Icon(Broken.archive, color: primary, size: 22),
                  title: Text(l10n.ui_extract),
                  onTap: () {
                    Navigator.pop(ctx);
                    _extractArchive();
                  },
                ),
              ],
              ListTile(
                leading: Icon(Broken.document_copy, color: primary, size: 22),
                title: Text(l10n.ui_copy),
                onTap: () {
                  Navigator.pop(ctx);
                  _copyToClipboard();
                },
              ),
              ListTile(
                leading: Icon(Broken.scissor, color: primary, size: 22),
                title: Text(l10n.ui_cut),
                onTap: () {
                  Navigator.pop(ctx);
                  _cutToClipboard();
                },
              ),
              ListTile(
                leading: Icon(Broken.trash, color: Colors.red, size: 22),
                title: Text(l10n.ui_delete, style: const TextStyle(color: Colors.red)),
                onTap: () {
                  Navigator.pop(ctx);
                  _deleteCurrentImage();
                },
              ),
              if (filePath != null) ...[
                ListTile(
                  leading: Icon(Broken.folder_open, color: primary, size: 22),
                  title: Text(l10n.msgcd8264f1),
                  onTap: () {
                    Navigator.pop(ctx);
                    _showInLocation();
                  },
                ),
                ListTile(
                  leading: Icon(Broken.edit, color: primary, size: 22),
                  title: Text(l10n.msgc8ce4b36),
                  onTap: () {
                    Navigator.pop(ctx);
                    _renameFile();
                  },
                ),
                ListTile(
                  leading: Icon(Broken.eye, color: primary, size: 22),
                  title: Text(l10n.msg2a4cfb07),
                  onTap: () {
                    Navigator.pop(ctx);
                    _openWith();
                  },
                ),
              ],
              ListTile(
                leading: Icon(Broken.info_circle, color: primary, size: 22),
                title: Text(l10n.ui_properties),
                onTap: () {
                  Navigator.pop(ctx);
                  _showImageInfo();
                },
              ),
              ListTile(
                leading: const Icon(Icons.share_outlined, size: 22),
                title: Text(l10n.ui_share),
                onTap: () {
                  Navigator.pop(ctx);
                  _shareCurrentImage();
                },
              ),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
  }

  void _copyToClipboard() {
    final file = _getCurrentFile();
    if (file == null) return;
    final provider = context.read<FileManagerProvider>();
    provider.setClipboard([file.path], isCut: false);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Copied ${p.basename(file.path)} to clipboard')),
    );
  }

  void _cutToClipboard() {
    final file = _getCurrentFile();
    if (file == null) return;
    final provider = context.read<FileManagerProvider>();
    provider.setClipboard([file.path], isCut: true);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Cut ${p.basename(file.path)} to clipboard')),
    );
  }

  void _showInLocation() {
    final file = _getCurrentFile();
    if (file == null) return;
    context.read<FileManagerProvider>().showFileInLocation(file.path);
    Navigator.pop(context);
  }

  Future<void> _renameFile() async {
    final file = _getCurrentFile();
    if (file == null) return;
    final l10n = L10n.of(context);

    final controller = TextEditingController(text: p.basename(file.path));
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.msgc8ce4b36),
        content: TextField(
          controller: controller,
          decoration: InputDecoration(hintText: l10n.msgf139c5cf),
          autofocus: true,
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(l10n.ui_cancel)),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: Text(l10n.msgc8ce4b36)),
        ],
      ),
    );

    if (confirmed != true) return;

    final newName = controller.text.trim();
    if (newName.isEmpty) return;

    try {
      await context.read<FileManagerProvider>().renameFile(file.path, newName);
      final newPath = p.join(file.parent.path, newName);

      if (widget.siblingItems != null && _currentIndex < widget.siblingItems!.length) {
        final item = widget.siblingItems![_currentIndex];
        if (item is FileSystemEntity) {
          widget.siblingItems![_currentIndex] = File(newPath);
        }
      }
      if (_imageList.isNotEmpty && _currentIndex < _imageList.length) {
        _imageList[_currentIndex] = newPath;
      }

      setState(() {});
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.toString()), backgroundColor: Colors.redAccent),
      );
    }
  }

  void _openWith() {
    final file = _getCurrentFile();
    if (file == null) return;
    context.read<FileManagerProvider>().openFile(context, file.path, forceOpenWith: true);
  }

  void _extractArchive() {
    final file = _getCurrentFile();
    if (file == null) return;
    context.read<FileManagerProvider>().extractArchiveDirectly(context, file.path);
  }

  Future<void> _shareCurrentImage() async {
    final file = _getCurrentFile();
    if (file != null && file.existsSync()) {
      await Share.shareXFiles([XFile(file.path)]);
    }
  }

  Future<void> _deleteCurrentImage() async {
    final l10n = L10n.of(context);
    final file = _getCurrentFile();

    // 检查是否为 AssetEntity（相册图片）
    AssetEntity? asset;
    if (widget.siblingItems != null && _currentIndex < widget.siblingItems!.length) {
      final item = widget.siblingItems![_currentIndex];
      if (item is AssetEntity) asset = item;
    } else if (widget.siblingAssets != null && _currentIndex < widget.siblingAssets!.length) {
      asset = widget.siblingAssets![_currentIndex];
    }

    if (file == null && asset == null) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.ui_delete),
        content: Text(l10n.ui_delete_file_confirm),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(l10n.ui_cancel)),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(foregroundColor: Colors.redAccent),
            child: Text(l10n.ui_delete),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    try {
      if (asset != null) {
        // 相册图片通过 PhotoManager 删除
        await PhotoManager.editor.deleteWithIds([asset.id]);
      } else if (file != null && file.existsSync()) {
        await file.delete();
      }
      if (!mounted) return;

      // 从列表中移除并导航
      final total = widget.siblingItems?.length ??
          widget.siblingAssets?.length ??
          _imageList.length;
      if (_imageList.isNotEmpty && _currentIndex < _imageList.length) {
        _imageList.removeAt(_currentIndex);
      }
      if (total <= 1) {
        Navigator.pop(context);
        return;
      }
      // 调整索引
      final newTotal = total - 1;
      _currentIndex = _currentIndex.clamp(0, newTotal - 1);
      setState(() {});
      // 跳转到新的当前页
      if (_pageController.hasClients) {
        _pageController.jumpToPage(_currentIndex);
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.toString()), backgroundColor: Colors.redAccent),
      );
    }
  }

  void _showImageInfo() async {
    final l10n = L10n.of(context);
    final file = _getCurrentFile();
    if (file == null) return;

    String fileName = file.path.split('/').last.split('\\').last;
    String filePath = file.path;
    String sizeStr = '-';
    String modifiedStr = '-';

    try {
      if (file.existsSync()) {
        final stat = await file.stat();
        const suffixes = ['B', 'KB', 'MB', 'GB'];
        var s = stat.size.toDouble();
        var i = 0;
        while (s >= 1024 && i < suffixes.length - 1) {
          s /= 1024;
          i++;
        }
        sizeStr = '${s.toStringAsFixed(1)} ${suffixes[i]}';
        modifiedStr = stat.modified.toString().split('.').first;
      }
    } catch (_) {}

    if (!mounted) return;

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.ui_properties),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(fileName, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
            const SizedBox(height: 12),
            _infoRow(l10n.ui_path, filePath),
            const SizedBox(height: 8),
            _infoRow(l10n.ui_size, sizeStr),
            const SizedBox(height: 8),
            _infoRow(l10n.msg1303e638, modifiedStr),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text(l10n.ui_close)),
        ],
      ),
    );
  }

  Widget _infoRow(String label, String value) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('$label: ', style: TextStyle(fontSize: 13, color: Theme.of(context).colorScheme.onSurface.withOpacity(0.6))),
        Expanded(child: Text(value, style: const TextStyle(fontSize: 13))),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final int totalCount = widget.siblingItems != null
        ? widget.siblingItems!.length
        : (widget.siblingAssets != null ? widget.siblingAssets!.length : _imageList.length);
    String currentTitle = 'Image';
    if (widget.siblingItems != null && _currentIndex < widget.siblingItems!.length) {
      final item = widget.siblingItems![_currentIndex];
      if (item is AssetEntity) {
        currentTitle = item.title ?? 'Image';
      } else if (item is FileSystemEntity) {
        currentTitle = item.path.split('/').last.split('\\').last;
      }
    } else if (widget.siblingAssets != null && _currentIndex < widget.siblingAssets!.length) {
      currentTitle = widget.siblingAssets![_currentIndex].title ?? 'Image';
    } else if (_imageList.isNotEmpty && _currentIndex < _imageList.length) {
      currentTitle = _imageList[_currentIndex].split('/').last.split('\\').last;
    }

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: const SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: Brightness.light,
      ),
      child: Scaffold(
        backgroundColor: Colors.black,
        extendBodyBehindAppBar: true,
        appBar: _showUI 
            ? AppBar(
                backgroundColor: Colors.black.withValues(alpha: 0.55),
                elevation: 0,
                leading: Padding(
                  padding: const EdgeInsets.all(8.0),
                  child: Container(
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.15),
                      shape: BoxShape.circle,
                    ),
                    child: IconButton(
                      icon: const Icon(Icons.arrow_back_ios_new_rounded, color: Colors.white, size: 18),
                      onPressed: () => Navigator.pop(context),
                    ),
                  ),
                ),
                title: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      currentTitle,
                      style: const TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.bold, letterSpacing: 0.3),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${_currentIndex + 1} of $totalCount',
                      style: TextStyle(color: Colors.white.withValues(alpha: 0.7), fontSize: 12, fontWeight: FontWeight.w500),
                    ),
                  ],
                ),
                actions: [
                  Padding(
                    padding: const EdgeInsets.all(8.0),
                    child: Container(
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.5),
                        shape: BoxShape.circle,
                      ),
                      child: IconButton(
                        icon: const Icon(Broken.more, color: Colors.white, size: 18),
                        onPressed: _showImageOptions,
                      ),
                    ),
                  ),
                ],
              )
            : null,
        body: Dismissible(
          key: const ValueKey('image_viewer_dismissible'),
          direction: _isZoomed ? DismissDirection.none : DismissDirection.vertical,
          onDismissed: (_) => Navigator.pop(context),
          dismissThresholds: const {
            DismissDirection.down: 0.2,
            DismissDirection.up: 0.2,
          },
          child: GestureDetector(
            onTap: () {
              setState(() {
                _showUI = !_showUI;
              });
            },
            child: PhotoViewGallery.builder(
              scrollPhysics: _isZoomed ? const NeverScrollableScrollPhysics() : const BouncingScrollPhysics(),
              pageController: _pageController,
              itemCount: totalCount,
              onPageChanged: (index) {
                setState(() {
                  _currentIndex = index;
                });
                _preloadAdjacent(index);
              },
              scaleStateChangedCallback: (state) {
                setState(() {
                  _isZoomed = state != PhotoViewScaleState.initial;
                });
              },
              builder: (context, index) {
                File? imgFile;
                Uint8List? thumbData;
                String tagKey = 'img_$index';

                if (widget.siblingItems != null) {
                  final item = widget.siblingItems![index];
                  if (item is AssetEntity) {
                    tagKey = item.id;
                    imgFile = _fileCache[index];
                    thumbData = ThumbnailCache.getCached(item.id);
                  } else if (item is FileSystemEntity) {
                    tagKey = item.path;
                    imgFile = File(item.path);
                  }
                } else if (widget.siblingAssets != null) {
                  final asset = widget.siblingAssets![index];
                  tagKey = asset.id;
                  imgFile = _fileCache[index];
                  thumbData = ThumbnailCache.getCached(asset.id);
                } else {
                  final path = _imageList[index];
                  tagKey = path;
                  imgFile = File(path);
                }

                final bool isValidFile = imgFile != null && imgFile.existsSync() && imgFile.lengthSync() > 16;
                final bool isAvif = imgFile != null && imgFile.path.toLowerCase().endsWith('.avif');
                final bool isSvg = imgFile != null && imgFile.path.toLowerCase().endsWith('.svg');

                if (isSvg) {
                  return PhotoViewGalleryPageOptions.customChild(
                    child: SvgPicture.file(imgFile, fit: BoxFit.contain),
                    initialScale: PhotoViewComputedScale.contained,
                    minScale: PhotoViewComputedScale.contained,
                    maxScale: PhotoViewComputedScale.covered * 4,
                    heroAttributes: PhotoViewHeroAttributes(tag: tagKey),
                  );
                }

                final ImageProvider provider = isValidFile
                    ? (isAvif ? FileAvifImage(imgFile) : FileImage(imgFile)) as ImageProvider
                    : (thumbData != null ? MemoryImage(thumbData) : MemoryImage(_kTransparentImage));

                return PhotoViewGalleryPageOptions(
                  imageProvider: provider,
                  initialScale: PhotoViewComputedScale.contained,
                  minScale: PhotoViewComputedScale.contained,
                  maxScale: PhotoViewComputedScale.covered * 4,
                  heroAttributes: PhotoViewHeroAttributes(tag: tagKey),
                  errorBuilder: (context, error, stackTrace) {
                    return Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Broken.image, size: 64, color: Colors.white.withOpacity(0.5)),
                          const SizedBox(height: 16),
                          Text(
                            'Failed to load image',
                            style: TextStyle(color: Colors.white.withOpacity(0.7), fontSize: 16, fontWeight: FontWeight.w600),
                          ),
                        ],
                      ),
                    );
                  },
                  onTapUp: (context, details, controllerValue) {
                    setState(() {
                      _showUI = !_showUI;
                    });
                  },
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}
