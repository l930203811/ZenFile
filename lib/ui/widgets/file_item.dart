import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:flutter_avif/flutter_avif.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import '../../models/file_item_model.dart';
import '../../core/utils.dart';
import '../../core/icon_fonts/broken_icons.dart';
import '../../services/pin_service.dart';
import '../../services/app_manager_service.dart';
import '../../services/preferences_service.dart';
import '../../services/media_thumbnail_service.dart';
import '../../providers/media_provider.dart';
import '../../providers/file_manager_provider.dart';
import 'package:on_audio_query/on_audio_query.dart';
import 'file_action_dialogs.dart';
import 'archive_type_icon.dart';
import 'file_type_icon.dart';
import 'package:zenfile/l10n/generated/app_localizations.dart';

// SVG 缩略图缓存
final Map<String, Uint8List> _svgThumbCache = {};

class FileItem extends StatelessWidget {
  final FileItemModel file;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final VoidCallback? onIconTap;
  final Function(String) onAction;
  final bool isSelected;
  final double iconScale;
  final double itemPaddingMultiplier;
  final bool showShowInLocationOption;
  final bool showOpenWithOption;

  const FileItem({
    super.key,
    required this.file,
    required this.onTap,
    this.onLongPress,
    this.onIconTap,
    required this.onAction,
    this.isSelected = false,
    this.iconScale = 1.0,
    this.itemPaddingMultiplier = 1.0,
    this.showShowInLocationOption = false,
    this.showOpenWithOption = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final iconColor = FileUtils.getColorForFile(file.path, context);
    final isArchive = FileUtils.isArchive(file.path);
    final isHighlighted = context.select<FileManagerProvider, bool>(
      (p) => p.forceHighlightedPaths.contains(file.path) || (p.enableFolderHighlight && p.highlightedPaths.contains(file.path)),
    );

    final cardMargin = EdgeInsets.symmetric(
      horizontal: (16 * itemPaddingMultiplier).clamp(4.0, 32.0),
      vertical: (4 * itemPaddingMultiplier).clamp(1.0, 16.0),
    );

    final child = Card(
      margin: cardMargin,
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
        onTap: onTap,
        onLongPress: onLongPress,
        borderRadius: BorderRadius.circular(12),
        child: Stack(
          children: [
            Padding(
              padding: EdgeInsets.all((12.0 * itemPaddingMultiplier).clamp(4.0, 24.0)),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  GestureDetector(
                    onTap: onIconTap ?? onLongPress,
                    child: Container(
                      width: 48 * iconScale,
                      height: 48 * iconScale,
                      decoration: BoxDecoration(
                        color: isSelected ? theme.colorScheme.primary : iconColor.withOpacity(0.1),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: MediaThumbnail(
                          file: file,
                          iconScale: iconScale,
                          isSelected: isSelected,
                          iconColor: iconColor,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            if (PinService.isPinned(file.path)) ...[
                              Icon(
                                Icons.push_pin_rounded,
                                size: 14 * (1 + (iconScale - 1) * 0.3),
                                color: Colors.orange,
                              ),
                              const SizedBox(width: 6),
                            ],
                            Expanded(
                              child: Text(
                                file.name,
                                style: theme.textTheme.titleMedium?.copyWith(
                                  fontWeight: FontWeight.w600,
                                  fontSize: 15 * (1 + (iconScale - 1) * 0.3),
                                ),
                                maxLines: context.select<FileManagerProvider, bool>((p) => p.adaptiveMultiLineNames) ? 3 : 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 4),
                        Consumer<FileManagerProvider>(
                          builder: (context, provider, _) {
                            return Row(
                              children: [
                                if (!provider.hideTimeAndDate) ...[
                                  Flexible(
                                    child: Text(
                                      FileUtils.formatDate(file.modified, use24Hour: provider.use24HourFormat),
                                      style: theme.textTheme.bodySmall?.copyWith(
                                        color: theme.textTheme.bodySmall?.color?.withOpacity(0.6),
                                      ),
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                ],
                                Text(
                                  FileUtils.formatBytes(file.size, 2),
                                  style: theme.textTheme.bodySmall?.copyWith(
                                    color: theme.textTheme.bodySmall?.color?.withOpacity(0.6),
                                  ),
                                ),
                              ],
                            );
                          },
                        ),
                      ],
                    ),
                  ),
                  if (!context.select<FileManagerProvider, bool>((p) => p.hideActionMenuButtons))
                    const SizedBox(width: 32)
                  else
                    _TrailingInfoWidget(
                      isFolder: file.isDirectory,
                      item: file,
                      iconScale: iconScale,
                    ),
                ],
              ),
            ),
            if (!context.select<FileManagerProvider, bool>((p) => p.hideActionMenuButtons))
              Positioned(
                top: 0,
                right: 0,
                child: IconButton(
                  icon: const Icon(Broken.more, size: 18),
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                  onPressed: () {
                    FileActionSheet.show(
                      context,
                      onAction,
                      isArchive: isArchive,
                      showInLocation: showShowInLocationOption,
                      openWith: showOpenWithOption && !file.isDirectory,
                    );
                  },
                ),
              ),
          ],
        ),
      ),
    );

    return Stack(
      children: [
        child,
        Positioned.fill(
          child: IgnorePointer(
            child: AnimatedOpacity(
              duration: const Duration(milliseconds: 500),
              opacity: isHighlighted ? 1.0 : 0.0,
              child: Container(
                margin: cardMargin,
                decoration: BoxDecoration(
                  color: theme.colorScheme.primary.withOpacity(0.06),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: theme.colorScheme.primary.withOpacity(0.25),
                    width: 1.5,
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class MediaThumbnail extends StatefulWidget {
  final FileItemModel file;
  final double iconScale;
  final bool isSelected;
  final Color iconColor;

  const MediaThumbnail({
    required this.file,
    required this.iconScale,
    required this.isSelected,
    required this.iconColor,
  });

  @override
  State<MediaThumbnail> createState() => _MediaThumbnailState();
}

class _MediaThumbnailState extends State<MediaThumbnail> {
  static final Map<String, Uint8List?> _apkIconCache = {};
  Uint8List? _videoThumb;
  Uint8List? _audioThumb;
  Uint8List? _apkIcon;
  Uint8List? _remoteThumb;  // 远程文件缩略图

  @override
  void initState() {
    super.initState();
    // 延迟到第一帧后执行，以便获取 context
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      // 远程文件优先处理
      if (widget.file.isRemote && PreferencesService.getRemoteMediaThumbnailPreview()) {
        _loadRemoteThumbnail();
        return;
      }
      final lowerPath = widget.file.path.toLowerCase();
      if (FileUtils.isVideo(widget.file.path)) {
        _loadVideoThumb();
      } else if (FileUtils.isAudio(widget.file.path)) {
        _loadAudioThumb();
      } else if (lowerPath.endsWith('.apk') || lowerPath.endsWith('.xapk') || lowerPath.endsWith('.apks') || lowerPath.endsWith('.apkm')) {
        _loadApkIcon();
      } else if (lowerPath.endsWith('.svg')) {
        // SVG 本地文件无需预加载，SvgPicture.file 会直接渲染
        // 但远程 SVG 需要在 _loadRemoteThumbnail 中下载字节
      }
    });
  }

  @override
  void didUpdateWidget(covariant MediaThumbnail oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.file.path != oldWidget.file.path) {
      setState(() {
        _videoThumb = null;
        _audioThumb = null;
        _apkIcon = null;
        _remoteThumb = null;
      });
      // 远程文件优先处理
      if (widget.file.isRemote && PreferencesService.getRemoteMediaThumbnailPreview()) {
        _loadRemoteThumbnail();
        return;
      }
      final lowerPath = widget.file.path.toLowerCase();
      if (FileUtils.isVideo(widget.file.path)) {
        _loadVideoThumb();
      } else if (FileUtils.isAudio(widget.file.path)) {
        _loadAudioThumb();
      } else if (lowerPath.endsWith('.apk') || lowerPath.endsWith('.xapk') || lowerPath.endsWith('.apks') || lowerPath.endsWith('.apkm')) {
        _loadApkIcon();
      } else if (lowerPath.endsWith('.svg')) {
        // SVG 本地文件无需预加载，SvgPicture.file 会直接渲染
      }
    }
  }

  /// 加载远程文件缩略图
  Future<void> _loadRemoteThumbnail() async {
    if (!mounted) return;
    try {
      final remoteSource = widget.file.remoteSource;
      if (remoteSource == null) return;
      
      // 从 widget 树获取 remoteClient
      final provider = context.read<FileManagerProvider>();
      final activeTab = provider.activeTab;
      if (activeTab?.remoteClient == null) return;
      
      final client = activeTab!.remoteClient!;
      
      // 构造缩略图缓存路径
      Directory thumbDir;
      try {
        thumbDir = Directory('/storage/emulated/0/Download/ZenFile_Remote/cache/thumbnails/remote');
        if (!thumbDir.existsSync()) thumbDir.createSync(recursive: true);
      } catch (_) {
        final appDir = await getApplicationDocumentsDirectory();
        thumbDir = Directory(p.join(appDir.path, 'ZenFile_Remote', 'cache', 'thumbnails', 'remote'));
        if (!thumbDir.existsSync()) thumbDir.createSync(recursive: true);
      }
      
      final thumbName = '${widget.file.path.replaceAll('/', '_').replaceAll('\\', '_')}_thumb.jpg';
      final thumbPath = p.join(thumbDir.path, thumbName);
      final thumbFile = File(thumbPath);
      
      // 检查缓存
      if (await thumbFile.exists()) {
        final bytes = await thumbFile.readAsBytes();
        if (mounted && bytes.isNotEmpty) {
          setState(() => _remoteThumb = bytes);
        }
        return;
      }
      
      // 下载到临时目录
      Directory tempDir;
      try {
        tempDir = Directory('/storage/emulated/0/Download/ZenFile_Remote/cache/temp');
        if (!tempDir.existsSync()) tempDir.createSync(recursive: true);
      } catch (_) {
        final appDir = await getApplicationDocumentsDirectory();
        tempDir = Directory(p.join(appDir.path, 'ZenFile_Remote', 'cache', 'temp'));
        if (!tempDir.existsSync()) tempDir.createSync(recursive: true);
      }
      
      final ext = p.extension(widget.file.name).toLowerCase();
      final tempPath = p.join(tempDir.path, 'remote_temp_${DateTime.now().millisecondsSinceEpoch}$ext');
      
      try {
        // 视频/音频只需下载头部 2MB 即可由 MediaMetadataRetriever 提取缩略图/封面
        // 图片/SVG 需要完整文件用于直接显示
        final isVideo = FileUtils.isVideo(widget.file.path);
        final isAudio = FileUtils.isAudio(widget.file.path);
        if (isVideo || isAudio) {
          try {
            await client.downloadRange(widget.file.path, tempPath, 0, 2 * 1024 * 1024);
          } catch (e) {
            // 部分服务器/客户端不支持 range 下载，回退到完整下载
            debugPrint('downloadRange 失败，回退完整下载: $e');
            await client.downloadFile(widget.file.path, tempPath, (_) {});
          }
        } else {
          await client.downloadFile(widget.file.path, tempPath, (_) {});
        }

        // SVG 文件：读取字节内容用于 SvgPicture.memory 渲染
        if (ext == '.svg') {
          final bytes = await File(tempPath).readAsBytes();
          if (mounted && bytes.isNotEmpty) {
            setState(() => _remoteThumb = bytes);
          }
          return;
        }

        // 图片直接复制作为缩略图
        if (['.jpg', '.jpeg', '.png', '.gif', '.webp', '.bmp', '.heic'].contains(ext)) {
          await File(tempPath).copy(thumbPath);
          // 读取缩略图字节并更新UI
          final bytes = await thumbFile.readAsBytes();
          if (mounted && bytes.isNotEmpty) {
            setState(() => _remoteThumb = bytes);
          }
          return;
        } else if (isVideo) {
          // 视频缩略图：通过原生 MediaMetadataRetriever 生成
          final thumbBytes = await MediaThumbnailService.generateVideoThumbnail(tempPath);
          if (thumbBytes != null && thumbBytes.isNotEmpty) {
            await thumbFile.writeAsBytes(thumbBytes, flush: true);
          }
        } else if (FileUtils.isAudio(widget.file.path)) {
          // 音频缩略图：通过原生 MediaMetadataRetriever 提取内嵌封面
          final thumbBytes = await MediaThumbnailService.generateAudioThumbnail(tempPath);
          if (thumbBytes != null && thumbBytes.isNotEmpty) {
            await thumbFile.writeAsBytes(thumbBytes, flush: true);
          }
        }
        
        if (await thumbFile.exists()) {
          final bytes = await thumbFile.readAsBytes();
          if (mounted && bytes.isNotEmpty) {
            setState(() => _remoteThumb = bytes);
          }
        }
      } finally {
        // 清理临时文件
        try { await File(tempPath).delete(); } catch (_) {}
      }
    } catch (e) {
      debugPrint('远程缩略图加载失败: $e');
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
          size: 200,
          quality: 60,
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
      // 方法1：从系统媒体库查找匹配的视频
      final mediaProvider = context.read<MediaProvider>();
      final match = mediaProvider.videos.where((v) {
        final titleLower = (v.title ?? '').toLowerCase();
        final nameLower = widget.file.name.toLowerCase();
        
        // Case 1: title matches filename exactly
        if (titleLower == nameLower) return true;
        
        // Case 2: title is basename without extension
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
          setState(() => _videoThumb = thumb);
          return;
        }
      }

      // 方法2：直接通过文件路径获取视频缩略图（不依赖系统媒体库）
      await _loadVideoThumbFromFile();
    } catch (_) {}
  }

  /// 直接从视频文件路径生成缩略图
  Future<void> _loadVideoThumbFromFile() async {
    if (!mounted) return;
    try {
      final filePath = widget.file.path;
      final file = File(filePath);
      if (!await file.exists()) return;

      // 尝试通过 photo_manager 从路径获取 AssetEntity
      final assetEntities = await PhotoManager.getAssetListRange(
        start: 0,
        end: 1000,
        type: RequestType.video,
      );
      
      // 查找路径匹配的视频
      AssetEntity? matchedAsset;
      for (final asset in assetEntities) {
        try {
          final assetPath = await asset.originFile.then((f) => f?.path);
          if (assetPath != null && assetPath.toLowerCase() == filePath.toLowerCase()) {
            matchedAsset = asset;
            break;
          }
        } catch (_) {}
      }

      if (matchedAsset != null) {
        final thumbData = await matchedAsset.thumbnailDataWithSize(
          const ThumbnailSize.square(300),
          quality: 80,
        );
        if (mounted && thumbData != null && thumbData.isNotEmpty) {
          setState(() => _videoThumb = thumbData);
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
      return Icon(Broken.tick_circle, color: Theme.of(context).colorScheme.onPrimary, size: 28 * widget.iconScale);
    }

    // 压缩包：显示带格式标签的自定义图标
    if (FileUtils.isArchive(widget.file.path)) {
      return ArchiveTypeIcon(
        label: FileUtils.getArchiveTypeLabel(widget.file.path),
        color: widget.iconColor,
        iconScale: widget.iconScale,
      );
    }

    // 文档：显示带格式标签的自定义图标
    if (FileUtils.isDocument(widget.file.path)) {
      return FileTypeIcon(
        icon: FileUtils.getIconForFile(widget.file.path),
        label: FileUtils.getDocumentTypeLabel(widget.file.path),
        color: widget.iconColor,
        iconScale: widget.iconScale,
      );
    }

    if (!showMediaPreviews) {
      if (isImg) {
        return FileTypeIcon(
          icon: Broken.image,
          label: FileUtils.getImageTypeLabel(widget.file.path),
          color: widget.iconColor,
          iconScale: widget.iconScale,
        );
      }
      return Icon(
        FileUtils.getIconForFile(widget.file.path),
        color: widget.iconColor,
        size: 28 * widget.iconScale,
      );
    }

    if (isApk && _apkIcon != null) {
      return Image.memory(
        _apkIcon!,
        fit: BoxFit.cover,
        width: double.infinity,
        height: double.infinity,
        errorBuilder: (context, error, stackTrace) => Icon(Broken.mobile, color: widget.iconColor, size: 28 * widget.iconScale),
      );
    }

    if (isImg && widget.file.size > 16) {
      // SVG 需要特殊处理（支持本地和远程）
      if (widget.file.path.toLowerCase().endsWith('.svg')) {
        // 远程 SVG 使用已下载的缓存字节
        if (widget.file.isRemote && _remoteThumb != null) {
          return SvgPicture.memory(
            _remoteThumb!,
            fit: BoxFit.cover,
            placeholderBuilder: (context) => FileTypeIcon(icon: Broken.image, label: FileUtils.getImageTypeLabel(widget.file.path), color: widget.iconColor, iconScale: widget.iconScale),
          );
        }
        return SvgPicture.file(
          File(widget.file.path),
          fit: BoxFit.cover,
          placeholderBuilder: (context) => FileTypeIcon(icon: Broken.image, label: FileUtils.getImageTypeLabel(widget.file.path), color: widget.iconColor, iconScale: widget.iconScale),
        );
      }
      if (widget.file.path.toLowerCase().endsWith('.avif')) {
        return AvifImage.file(
          File(widget.file.path),
          fit: BoxFit.cover,
          width: double.infinity,
          height: double.infinity,
          errorBuilder: (context, error, stackTrace) => FileTypeIcon(icon: Broken.image, label: FileUtils.getImageTypeLabel(widget.file.path), color: widget.iconColor, iconScale: widget.iconScale),
        );
      }
      // 远程图片优先使用已下载的缩略图缓存
      if (widget.file.isRemote && _remoteThumb != null) {
        return Image.memory(
          _remoteThumb!,
          fit: BoxFit.cover,
          width: double.infinity,
          height: double.infinity,
          errorBuilder: (context, error, stackTrace) => FileTypeIcon(icon: Broken.image, label: FileUtils.getImageTypeLabel(widget.file.path), color: widget.iconColor, iconScale: widget.iconScale),
        );
      }
      return Image.file(
        File(widget.file.path),
        fit: BoxFit.cover,
        width: double.infinity,
        height: double.infinity,
        cacheWidth: 160,
        errorBuilder: (context, error, stackTrace) => FileTypeIcon(icon: Broken.image, label: FileUtils.getImageTypeLabel(widget.file.path), color: widget.iconColor, iconScale: widget.iconScale),
      );
    }

    // SVG 文件（当 isImg 返回 false 时的兜底处理）
    if (widget.file.path.toLowerCase().endsWith('.svg')) {
      if (widget.file.isRemote && _remoteThumb != null) {
        return SvgPicture.memory(
          _remoteThumb!,
          fit: BoxFit.cover,
          placeholderBuilder: (context) => FileTypeIcon(icon: Broken.image, label: FileUtils.getImageTypeLabel(widget.file.path), color: widget.iconColor, iconScale: widget.iconScale),
        );
      }
      return SvgPicture.file(
        File(widget.file.path),
        fit: BoxFit.cover,
        placeholderBuilder: (context) => FileTypeIcon(icon: Broken.image, label: FileUtils.getImageTypeLabel(widget.file.path), color: widget.iconColor, iconScale: widget.iconScale),
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
            errorBuilder: (context, error, stackTrace) => Icon(Broken.video, color: widget.iconColor, size: 28 * widget.iconScale),
          ),
          Center(
            child: Container(
              padding: const EdgeInsets.all(4),
              decoration: BoxDecoration(color: Colors.black.withOpacity(0.6), shape: BoxShape.circle),
              child: Icon(Broken.video, color: Colors.white, size: 16 * widget.iconScale),
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
            errorBuilder: (context, error, stackTrace) => Icon(Broken.music, color: widget.iconColor, size: 28 * widget.iconScale),
          ),
          Center(
            child: Container(
              padding: const EdgeInsets.all(4),
              decoration: BoxDecoration(color: Colors.black.withOpacity(0.6), shape: BoxShape.circle),
              child: Icon(Broken.music, color: Colors.white, size: 16 * widget.iconScale),
            ),
          ),
        ],
      );
    }

    // 远程文件缩略图（图片类型）
    if (_remoteThumb != null) {
      return Image.memory(
        _remoteThumb!,
        fit: BoxFit.cover,
        width: double.infinity,
        height: double.infinity,
        errorBuilder: (context, error, stackTrace) => Icon(
          FileUtils.isVideo(widget.file.path) ? Broken.video : Broken.image,
          color: widget.iconColor,
          size: 28 * widget.iconScale,
        ),
      );
    }

    return Icon(
      FileUtils.getIconForFile(widget.file.path),
      color: widget.iconColor,
      size: 28 * widget.iconScale,
    );
  }
}

class _TrailingInfoWidget extends StatelessWidget {
  final bool isFolder;
  final FileItemModel item;
  final double iconScale;

  const _TrailingInfoWidget({
    required this.isFolder,
    required this.item,
    required this.iconScale,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final provider = context.watch<FileManagerProvider>();
    if (!provider.hideActionMenuButtons) return const SizedBox.shrink();

    final option = provider.trailingInfoType;
    if (option == 'none') return const SizedBox.shrink();

    if (option == 'dateTime') {
      return Padding(
        padding: const EdgeInsets.only(left: 8.0),
        child: Text(
          FileUtils.formatDate(item.modified, use24Hour: provider.use24HourFormat),
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.textTheme.bodySmall?.color?.withOpacity(0.5),
            fontSize: 12.0 * (1 + (iconScale - 1) * 0.3),
          ),
        ),
      );
    }

    if (option == 'sizeAndCount') {
      if (!isFolder) {
        return Padding(
          padding: const EdgeInsets.only(left: 8.0),
          child: Text(
            FileUtils.formatBytes(item.size, 1),
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.textTheme.bodySmall?.color?.withOpacity(0.5),
              fontSize: 12.0 * (1 + (iconScale - 1) * 0.3),
            ),
          ),
        );
      } else {
        return FutureBuilder<int>(
          future: provider.getFolderItemCount(item.path),
          builder: (context, snapshot) {
            final count = snapshot.data;
            String label = '...';
            if (count != null && count >= 0) {
              label = count == 1 ? '1 项' : '{count} 项';
            }
            return Padding(
              padding: const EdgeInsets.only(left: 8.0),
              child: Text(
                label,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.textTheme.bodySmall?.color?.withOpacity(0.5),
                  fontSize: 12.0 * (1 + (iconScale - 1) * 0.3),
                ),
              ),
            );
          },
        );
      }
    }

    return const SizedBox.shrink();
  }
}
