import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:path/path.dart' as p;
import '../../models/drag_payload.dart';
import '../../models/network_connection_model.dart';
import '../../services/remote/remote_client.dart';
import '../../providers/file_manager_provider.dart';
import '../../core/icon_fonts/broken_icons.dart';
import '../../core/utils.dart';
import 'drag_drop_action_dialog.dart';
import 'draggable_item.dart';

class DragDropHandler extends StatefulWidget {
  final Widget child;
  final String path;
  final bool isDirectory;
  final VoidCallback? onLongPress;
  final bool enabled;
  final bool isRemote;
  final List<RemoteFileItem>? remoteItems;
  final NetworkConnectionModel? connection;

  const DragDropHandler({
    super.key,
    required this.child,
    required this.path,
    required this.isDirectory,
    this.onLongPress,
    this.enabled = true,
    this.isRemote = false,
    this.remoteItems,
    this.connection,
  });

  @override
  State<DragDropHandler> createState() => _DragDropHandlerState();
}

class _DragDropHandlerState extends State<DragDropHandler> {
  bool _isDragOver = false;
  Timer? _hoverTimer;
  Timer? _scrollTimer;

  @override
  void dispose() {
    _hoverTimer?.cancel();
    _scrollTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.read<FileManagerProvider>();

    // If drag & drop is disabled in settings or this handler is disabled, return the child widget directly
    if (!widget.enabled || !provider.enableDragDrop) {
      return widget.child;
    }

    // 远程文件不使用 LongPressDraggable，避免轮询刷新打断长按手势
    // 远程文件的拖拽操作通过选中后使用底部操作栏实现
    if (widget.isRemote) {
      return GestureDetector(
        onLongPress: widget.onLongPress,
        child: widget.child,
      );
    }

    final theme = Theme.of(context);
    final fileName = p.posix.basename(widget.path);

    // Use Selector to only rebuild when selection for this specific item changes
    return Selector<FileManagerProvider, ({bool isSelected, List<String> dragPaths})>(
      selector: (_, p) {
        final isSelected = p.selectedPaths.contains(widget.path);
        final dragPaths = (isSelected && p.selectedPaths.length > 1)
            ? p.selectedPaths.toList()
            : [widget.path];
        return (isSelected: isSelected, dragPaths: dragPaths);
      },
      builder: (context, data, _) {
        final isSelected = data.isSelected;
        final dragPaths = data.dragPaths;
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

    // 未选中状态：只响应长按选中，不响应拖拽
    // 选中状态：响应拖拽操作，但拖拽释放时不触发 onLongPress（避免弹出多选菜单）
    Widget itemWidget = isSelected
        ? DraggableItem(
            key: ValueKey('draggable_${widget.path}'),
            data: DragPayload(
              path: widget.path,
              isDirectory: widget.isDirectory,
              paths: dragPaths,
              isRemote: widget.isRemote,
              remoteItems: widget.remoteItems,
              connection: widget.connection,
            ),
            feedback: feedback,
            // 选中状态下拖拽释放不触发 onLongPress，避免弹出多选菜单
            onLongPress: null,
            child: widget.child,
          )
        : GestureDetector(
            onLongPress: widget.onLongPress,
            child: widget.child,
          );

        // If it's a directory, wrap in a DragTarget to allow dropping items onto it
        if (widget.isDirectory) {
          return DragTarget<DragPayload>(
            onWillAccept: (data) {
              if (data == null || data.paths.isEmpty) return false;
              if (data.paths.contains(widget.path)) return false;
              if (data.paths.any((x) => widget.path.startsWith(x + p.posix.separator))) return false;
              // 如果目标文件夹就是拖拽源所在的目录，不接受
              final sourceParent = p.posix.dirname(data.paths.first);
              if (widget.path == sourceParent) return false;
              
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
                provider.setRemoteClipboard(data.remoteItems!, isCut: true, connection: data.connection!);
                await provider.pasteFile(context, clearAfterPaste: true);
              } else if (provider.currIsRemote) {
                // 本地文件拖放到远程目录
                provider.setClipboard(data.paths, isCut: true);
                await provider.pasteFile(context, clearAfterPaste: true);
              } else {
                // 本地拖放到本地目录 — 通过剪贴板+paste路径获得字节级进度
                // 找到目标路径所在的tab
                int targetTab = provider.activeTabIndex;
                for (int i = 0; i < provider.tabs.length; i++) {
                  if (provider.tabs[i].currentPath == widget.path ||
                      widget.path.startsWith(provider.tabs[i].currentPath + p.posix.separator)) {
                    targetTab = i;
                    break;
                  }
                }
                provider.setActiveTab(targetTab);
                provider.setClipboard(data.paths, isCut: true);
                await provider.pasteFileToTab(context, targetTab, clearAfterPaste: true);
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
      },
    );
  }
}
