import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../models/network_connection_model.dart';
import 'package:flutter_avif/flutter_avif.dart';
import 'package:flutter_svg/flutter_svg.dart';
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
import 'package:photo_manager/photo_manager.dart';
import 'file_action_dialogs.dart';
import 'archive_type_icon.dart';
import 'file_type_icon.dart';
import 'remote_cloud_badge.dart';

class FileGridItem extends StatelessWidget {
  final FileItemModel file;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final VoidCallback? onIconTap;
  final Function(String) onAction;
  final bool isSelected;
  final double iconScale;
  final double itemPaddingMultiplier;
  final NetworkConnectionModel? connection;

  const FileGridItem({
    super.key,
    required this.file,
    required this.onTap,
    this.onLongPress,
    this.onIconTap,
    required this.onAction,
    this.isSelected = false,
    this.iconScale = 1.0,
    this.itemPaddingMultiplier = 1.0,
    this.connection,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final iconColor = FileUtils.getColorForFile(file.path, context);
    final isArchive = FileUtils.isArchive(file.path);
    final isHighlighted = context.select<FileManagerProvider, bool>(
      (p) => p.forceHighlightedPaths.contains(file.path) || (p.enableFolderHighlight && p.highlightedPaths.contains(file.path)),
    );

    final child = Card(
      color: isSelected ? theme.colorScheme.primaryContainer.withOpacity(0.4) : theme.colorScheme.surface,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(
          color: isSelected ? theme.colorScheme.primary : theme.dividerColor.withOpacity(0.1),
          width: isSelected ? 1.5 : 1.0,
        ),
      ),
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        borderRadius: BorderRadius.circular(16),
        child: Stack(
          children: [
            Align(
              alignment: Alignment.center,
              child: SingleChildScrollView(
                physics: const NeverScrollableScrollPhysics(),
                child: Padding(
                  padding: EdgeInsets.symmetric(
                    horizontal: (8.0 * itemPaddingMultiplier).clamp(2.0, 16.0),
                    vertical: (8.0 * itemPaddingMultiplier).clamp(2.0, 16.0),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      GestureDetector(
                        onTap: onIconTap ?? onLongPress,
                        child: Stack(
                          children: [
                            Container(
                              width: 48 * iconScale,
                              height: 48 * iconScale,
                              decoration: BoxDecoration(
                                color: isSelected ? theme.colorScheme.primary : iconColor.withOpacity(0.1),
                                borderRadius: BorderRadius.circular(16),
                              ),
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(16),
                                child: _MediaThumbnail(
                                  file: file,
                                  iconScale: iconScale,
                                  isSelected: isSelected,
                                  iconColor: iconColor,
                                  connection: connection,
                                ),
                              ),
                            ),
                            if (file.isRemote && context.select<FileManagerProvider, bool>((p) => p.effectiveShowRemoteCloudBadge))
                              RemoteCloudBadge(size: 12 * (1 + (iconScale - 1) * 0.3)),
                          ],
                        ),
                      ),
                      const SizedBox(height: 12),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (PinService.isPinned(file.path)) ...[
                            Icon(
                              Icons.push_pin_rounded,
                              size: 12 * (1 + (iconScale - 1) * 0.3),
                              color: Colors.orange,
                            ),
                            const SizedBox(width: 4),
                          ],
                          Flexible(
                            child: Text(
                              file.name,
                              style: theme.textTheme.bodyMedium?.copyWith(
                                fontWeight: FontWeight.bold,
                                fontSize: 13.5 * (1 + (iconScale - 1) * 0.3),
                              ),
                              textAlign: TextAlign.center,
                              maxLines: context.select<FileManagerProvider, bool>((p) => p.adaptiveMultiLineNames) ? 3 : 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(
                        FileUtils.formatBytes(file.size, 1),
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.textTheme.bodySmall?.color?.withOpacity(0.6),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
             if (isSelected)
              Positioned(
                top: 8,
                left: 8,
                child: Container(
                  padding: const EdgeInsets.all(4),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.primary,
                    shape: BoxShape.circle,
                  ),
                  child: Icon(Broken.tick_circle, size: 16, color: theme.colorScheme.onPrimary),
                ),
              )
            else if (PinService.isPinned(file.path))
              Positioned(
                top: 8,
                left: 8,
                child: Container(
                  padding: const EdgeInsets.all(4),
                  decoration: BoxDecoration(
                    color: Colors.orange.withOpacity(0.9),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.push_pin_rounded, size: 12, color: Colors.white),
                ),
              ),
            if (!isSelected && !context.select<FileManagerProvider, bool>((p) => p.hideActionMenuButtons))
              Positioned(
                top: 0,
                right: 0,
                child: IconButton(
                  icon: const Icon(Broken.more, size: 16),
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                  onPressed: () {
                    FileActionSheet.show(
                      context,
                      onAction,
                      isArchive: isArchive,
                      openWith: !file.isDirectory,
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
                margin: const EdgeInsets.all(4.0),
                decoration: BoxDecoration(
                  color: theme.colorScheme.primary.withOpacity(0.06),
                  borderRadius: BorderRadius.circular(16),
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

class _MediaThumbnail extends StatefulWidget {
  final FileItemModel file;
  final double iconScale;
  final bool isSelected;
  final Color iconColor;
  final NetworkConnectionModel? connection;

  const _MediaThumbnail({
    required this.file,
    required this.iconScale,
    required this.isSelected,
    required this.iconColor,
    this.connection,
  });

  @override
  State<_MediaThumbnail> createState() => _MediaThumbnailState();
}

class _MediaThumbnailState extends State<_MediaThumbnail> {
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
      }
    });
  }

  @override
  void didUpdateWidget(covariant _MediaThumbnail oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 路径、修改时间或大小任一变化都说明文件内容已变更，必须清掉旧缩略图重新生成。
    // 仅判 path 不够：同名文件被删除重建后 path 不变但内容已变，旧缩略图会错误复用。
    final fileChanged = widget.file.path != oldWidget.file.path ||
        widget.file.modified != oldWidget.file.modified ||
        widget.file.size != oldWidget.file.size;
    if (fileChanged) {
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
      // mediaProvider.videos 返回的是 File（文件系统扫描），不是 AssetEntity，
      // 无法用 ThumbnailCache.get(asset)。直接走 PhotoManager 路径匹配 + 原生生成。
      final assetEntities = await PhotoManager.getAssetListRange(
        start: 0,
        end: 1000,
        type: RequestType.video,
      );
      for (final asset in assetEntities) {
        try {
          final assetPath = await asset.originFile.then((f) => f?.path);
          if (assetPath != null && assetPath.toLowerCase() == widget.file.path.toLowerCase()) {
            final thumbData = await asset.thumbnailDataWithSize(
              const ThumbnailSize.square(300),
              quality: 80,
            );
            if (mounted && thumbData != null && thumbData.isNotEmpty) {
              setState(() {
                _videoThumb = thumbData;
              });
              return;
            }
            break;
          }
        } catch (_) {}
      }

      // 回退：文件不在系统相册中（下载目录、NAS 挂载目录等），
      // 直接通过原生 MediaMetadataRetriever 从文件路径生成首帧缩略图。
      final thumbBytes = await MediaThumbnailService.generateVideoThumbnail(widget.file.path);
      if (mounted && thumbBytes != null && thumbBytes.isNotEmpty) {
        setState(() {
          _videoThumb = thumbBytes;
        });
      }
    } catch (_) {}
  }

  Future<void> _loadRemoteThumbnail() async {
    if (!mounted) return;
    // 尊重「远程媒体缩略图」开关：关闭后不再发起任何远程缩略图下载
    if (!PreferencesService.getRemoteMediaThumbnailPreview()) return;
    try {
      final provider = context.read<FileManagerProvider>();
      final activeTab = provider.activeTab;
      if (activeTab.remoteClient == null) return;
      final client = activeTab.remoteClient!;

      final thumbDir = Directory('/storage/emulated/0/ZenFile/cache/thumbnails/remote');
      if (!await thumbDir.exists()) {
        await thumbDir.create(recursive: true);
      }
      // 缓存文件名加入 connection 标识 + modified + size：
      // ① connection 标识区分不同远程连接（路径/修改时间/大小相同也会串图）；
      // ② modified/size 区分同名文件删除重建。
      final thumbName = MediaThumbnailService.remoteThumbName(widget.connection?.id, widget.file.path, widget.file.modified, widget.file.size);
      final thumbPath = p.join(thumbDir.path, thumbName);
      final thumbFile = File(thumbPath);

      if (await thumbFile.exists()) {
        final bytes = await thumbFile.readAsBytes();
        if (mounted && bytes.isNotEmpty) {
          if (FileUtils.isVideo(widget.file.path)) {
            setState(() => _videoThumb = bytes);
          } else if (FileUtils.isAudio(widget.file.path)) {
            setState(() => _audioThumb = bytes);
          } else {
            setState(() => _remoteThumb = bytes);
          }
        }
        return;
      }

      final tempDir = await getTemporaryDirectory();
      final ext = p.extension(widget.file.name).toLowerCase();
      final tempPath = p.join(tempDir.path, MediaThumbnailService.uniqueTempName(ext));
      
      try {
        // 视频/音频只需下载头部 2MB 即可由 MediaMetadataRetriever 提取缩略图/封面
        // 图片/SVG 需要完整文件用于直接显示
        final isVideo = FileUtils.isVideo(widget.file.path);
        final isAudio = FileUtils.isAudio(widget.file.path);
        if (isVideo || isAudio) {
          // 并发受限流保护：避免一屏多个远程媒体同时下载造成带宽竞争/超时失败
          await MediaThumbnailService.withRemoteThrottle(() async {
            try {
              await client.downloadRange(widget.file.path, tempPath, 0, 2 * 1024 * 1024);
            } catch (e) {
              // 部分服务器/客户端不支持 range 下载，回退到完整下载
              debugPrint('downloadRange 失败，回退完整下载: $e');
              await client.downloadFile(widget.file.path, tempPath, (_) {});
            }
          });
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
          // 视频缩略图：通过原生 MediaMetadataRetriever 生成。
          // 少部分视频的 moov 元数据在文件尾部（非 faststart 编码），
          // 仅头部 2MB 解析失败返回 null → 完整下载重试一次，仍失败才放弃。
          final thumbBytes = await MediaThumbnailService.withRemoteThrottle(() async {
            var tb = await MediaThumbnailService.generateVideoThumbnail(tempPath);
            if ((tb == null || tb.isEmpty) && widget.file.size <= 100 * 1024 * 1024) {
              try {
                await client.downloadFile(widget.file.path, tempPath, (_) {});
                tb = await MediaThumbnailService.generateVideoThumbnail(tempPath);
              } catch (_) {}
            }
            return tb;
          });
          if (thumbBytes != null && thumbBytes.isNotEmpty) {
            await thumbFile.writeAsBytes(thumbBytes, flush: true);
            if (mounted) setState(() => _videoThumb = thumbBytes);
          }
        } else if (FileUtils.isAudio(widget.file.path)) {
          // 音频缩略图：通过原生 MediaMetadataRetriever 提取内嵌封面
          final thumbBytes = await MediaThumbnailService.generateAudioThumbnail(tempPath);
          if (thumbBytes != null && thumbBytes.isNotEmpty) {
            await thumbFile.writeAsBytes(thumbBytes, flush: true);
            if (mounted) setState(() => _audioThumb = thumbBytes);
          }
        }

        if (await thumbFile.exists()) {
          final bytes = await thumbFile.readAsBytes();
          if (mounted && bytes.isNotEmpty) {
            if (FileUtils.isVideo(widget.file.path)) {
              setState(() => _videoThumb = bytes);
            } else if (FileUtils.isAudio(widget.file.path)) {
              setState(() => _audioThumb = bytes);
            } else {
              setState(() => _remoteThumb = bytes);
            }
          }
        }
      } finally {
        // 清理临时文件
        try { await File(tempPath).delete(); } catch (_) {}
      }
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final showMediaPreviews = context.select<FileManagerProvider, bool>((p) => p.showMediaPreviews) &&
        // 远程文件额外受「远程媒体缩略图」开关控制
        (!widget.file.isRemote || PreferencesService.getRemoteMediaThumbnailPreview());
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
        cacheWidth: 160,
        cacheHeight: 160,
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
          cacheWidth: 160,
          cacheHeight: 160,
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
            cacheWidth: 160,
            cacheHeight: 160,
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
            cacheWidth: 160,
            cacheHeight: 160,
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

    return Icon(
      FileUtils.getIconForFile(widget.file.path),
      color: widget.iconColor,
      size: 28 * widget.iconScale,
    );
  }
}
