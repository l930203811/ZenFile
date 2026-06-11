import 'dart:io';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:path/path.dart' as p;
import '../../models/drag_payload.dart';
import '../../services/remote/remote_client.dart';
import '../../providers/file_manager_provider.dart';
import '../../core/icon_fonts/broken_icons.dart';
import '../../core/utils.dart';
import 'drag_drop_action_dialog.dart';

class DragDropHandler extends StatefulWidget {
  final Widget child;
  final String path;
  final bool isDirectory;
  final VoidCallback? onLongPress;
  final bool enabled;
  final bool isRemote;
  final List<RemoteFileItem>? remoteItems;

  const DragDropHandler({
    super.key,
    required this.child,
    required this.path,
    required this.isDirectory,
    this.onLongPress,
    this.enabled = true,
    this.isRemote = false,
    this.remoteItems,
  });

  @override
  State<DragDropHandler> createState() => _DragDropHandlerState();
}

class _DragDropHandlerState extends State<DragDropHandler> {
  bool _isDragOver = false;
  bool _hasMoved = false;
  Timer? _hoverTimer;
  Timer? _scrollTimer;
  Offset? _currentDragPosition;

  @override
  void dispose() {
    _hoverTimer?.cancel();
    _scrollTimer?.cancel();
    super.dispose();
  }

  void _startScrollTimerIfNeeded() {
    if (_scrollTimer != null) return;
    
    _scrollTimer = Timer.periodic(const Duration(milliseconds: 50), (timer) {
      if (_currentDragPosition == null || !mounted) {
        timer.cancel();
        _scrollTimer = null;
        return;
      }
      
      final scrollable = Scrollable.maybeOf(context);
      if (scrollable == null) {
        timer.cancel();
        _scrollTimer = null;
        return;
      }
      
      final renderBox = scrollable.context.findRenderObject() as RenderBox?;
      if (renderBox == null) return;
      
      final scrollableHeight = renderBox.size.height;
      final localY = renderBox.globalToLocal(_currentDragPosition!).dy;
      
      const double edgeThreshold = 70.0;
      const double baseScrollSpeed = 16.0;
      
      if (localY < edgeThreshold && localY > 0) {
        final fraction = (edgeThreshold - localY) / edgeThreshold;
        final speed = baseScrollSpeed * fraction.clamp(0.2, 1.0);
        final target = (scrollable.position.pixels - speed).clamp(
          scrollable.position.minScrollExtent,
          scrollable.position.maxScrollExtent,
        );
        if (target != scrollable.position.pixels) {
          scrollable.position.jumpTo(target);
        }
      } else if (localY > scrollableHeight - edgeThreshold && localY < scrollableHeight) {
        final fraction = (localY - (scrollableHeight - edgeThreshold)) / edgeThreshold;
        final speed = baseScrollSpeed * fraction.clamp(0.2, 1.0);
        final target = (scrollable.position.pixels + speed).clamp(
          scrollable.position.minScrollExtent,
          scrollable.position.maxScrollExtent,
        );
        if (target != scrollable.position.pixels) {
          scrollable.position.jumpTo(target);
        }
      } else {
        timer.cancel();
        _scrollTimer = null;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<FileManagerProvider>();

    // If drag & drop is disabled in settings or this handler is disabled, return the child widget directly
    if (!widget.enabled || !provider.enableDragDrop) {
      return widget.child;
    }

    final theme = Theme.of(context);
    final fileName = p.posix.basename(widget.path);

    final isSelected = provider.selectedPaths.contains(widget.path);
    final dragPaths = (isSelected && provider.selectedPaths.length > 1)
        ? provider.selectedPaths.toList()
        : [widget.path];

    final isMultiDrag = dragPaths.length > 1;
    final displayName = isMultiDrag ? '${dragPaths.length} items' : fileName;

    // Elevated, semi-transparent feedback widget shown while dragging
    final feedback = Material(
      color: Colors.transparent,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        decoration: BoxDecoration(
          color: theme.colorScheme.surface.withOpacity(0.92),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: theme.colorScheme.primary.withOpacity(0.35), width: 1.5),
          boxShadow: [
            BoxShadow(
              color: theme.colorScheme.shadow.withOpacity(0.18),
              blurRadius: 16,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              isMultiDrag
                  ? Broken.document_copy
                  : (widget.isDirectory ? Broken.folder : FileUtils.getIconForFile(widget.path)),
              color: theme.colorScheme.primary,
              size: 22,
            ),
            const SizedBox(width: 10),
            Text(
              displayName,
              style: TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: 14,
                color: theme.colorScheme.onSurface,
              ),
            ),
          ],
        ),
      ),
    );

    Widget itemWidget = LongPressDraggable<DragPayload>(
      data: DragPayload(
        path: widget.path,
        isDirectory: widget.isDirectory,
        paths: dragPaths,
        isRemote: widget.isRemote,
        remoteItems: widget.remoteItems,
      ),
      feedback: feedback,
      dragAnchorStrategy: pointerDragAnchorStrategy,
      delay: const Duration(milliseconds: 600),
      onDragStarted: () {
        _hasMoved = false;
      },
      onDragUpdate: (details) {
        if (details.delta.dx.abs() > 20.0 || details.delta.dy.abs() > 20.0) {
          _hasMoved = true;
        }
        _currentDragPosition = details.globalPosition;
        if (_hasMoved) {
          _startScrollTimerIfNeeded();
        }
      },
      onDragEnd: (details) {
        _scrollTimer?.cancel();
        _scrollTimer = null;
        _currentDragPosition = null;
        if (!_hasMoved && widget.onLongPress != null) {
          widget.onLongPress!();
        }
      },
      onDraggableCanceled: (velocity, offset) {
        _scrollTimer?.cancel();
        _scrollTimer = null;
        _currentDragPosition = null;
      },
      childWhenDragging: Opacity(
        opacity: 0.35,
        child: widget.child,
      ),
      child: widget.child,
    );

    // If it's a directory, wrap in a DragTarget to allow dropping items onto it
    if (widget.isDirectory) {
      return DragTarget<DragPayload>(
        onWillAccept: (data) {
          if (data == null || data.paths.isEmpty) return false;
          if (data.paths.contains(widget.path)) return false;
          if (data.paths.any((x) => widget.path.startsWith(x + p.posix.separator))) return false;
          // 如果拖拽源和目标文件夹在同一目录下，不接受
          final sourceParent = p.posix.dirname(data.paths.first);
          final targetParent = p.posix.dirname(widget.path);
          if (sourceParent == targetParent) return false;
          
          setState(() {
            _isDragOver = true;
          });

          _hoverTimer?.cancel();
          _hoverTimer = Timer(const Duration(milliseconds: 900), () {
            if (mounted) {
              provider.loadDirectory(widget.path);
            }
          });

          return true;
        },
        onLeave: (data) {
          setState(() {
            _isDragOver = false;
          });
          _hoverTimer?.cancel();
        },
        onAccept: (data) async {
          setState(() {
            _isDragOver = false;
          });
          _hoverTimer?.cancel();
          if (provider.showDragDropDialog) {
            DragDropActionDialog.show(
              context: Navigator.of(context).context,
              sourcePaths: data.paths,
              initialTargetPath: widget.path,
            );
          } else if (data.isRemote && data.remoteItems != null) {
            // 远程文件拖放到本地目录
            provider.setRemoteClipboard(data.remoteItems!, isCut: true, connection: provider.activeTab.remoteConnection!);
            await provider.pasteFile(context, clearAfterPaste: true);
          } else if (provider.currIsRemote) {
            // 本地文件拖放到远程目录
            provider.setClipboard(data.paths, isCut: true);
            await provider.pasteFile(context, clearAfterPaste: true);
          } else {
            provider.progressNotifier.value = FileOperationProgress(
              totalFiles: data.paths.length,
              currentFileIndex: 1,
              currentFileName: 'Moving...',
              percentage: 0.0,
              speedMBs: 0.0,
              eta: Duration.zero,
              totalBytes: data.paths.length,
              bytesProcessed: 0,
            );
            for (int i = 0; i < data.paths.length; i++) {
              provider.progressNotifier.value = FileOperationProgress(
                totalFiles: data.paths.length,
                currentFileIndex: i + 1,
                currentFileName: p.posix.basename(data.paths[i]),
                percentage: (i + 1) / data.paths.length,
                speedMBs: 0.0,
                eta: Duration.zero,
                totalBytes: data.paths.length,
                bytesProcessed: i + 1,
              );
              await provider.moveItem(context, data.paths[i], widget.path, showToast: false);
            }
            provider.progressNotifier.value = null;
            provider.clearSelection();
          }
        },
        builder: (context, candidateData, rejectedData) {
          return AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              color: _isDragOver
                  ? theme.colorScheme.primary.withOpacity(0.12)
                  : Colors.transparent,
              border: _isDragOver
                  ? Border.all(color: theme.colorScheme.primary, width: 2.0)
                  : null,
            ),
            child: itemWidget,
          );
        },
      );
    }

    return itemWidget;
  }
}
