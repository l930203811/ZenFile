import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../models/drag_payload.dart';
import '../../providers/file_manager_provider.dart';

/// 独立的拖拽组件，不监听任何 provider，避免重建打断长按手势
class DraggableItem extends StatefulWidget {
  final Widget child;
  final Widget feedback;
  final DragPayload data;
  final Duration delay;
  final VoidCallback? onLongPress;
  final VoidCallback? onDragStarted;

  const DraggableItem({
    super.key,
    required this.child,
    required this.feedback,
    required this.data,
    this.delay = const Duration(milliseconds: 600),
    this.onLongPress,
    this.onDragStarted,
  });

  @override
  State<DraggableItem> createState() => _DraggableItemState();
}

class _DraggableItemState extends State<DraggableItem> {
  bool _hasMoved = false;

  @override
  Widget build(BuildContext context) {
    // 注意：这里刻意不再用 Listener 在「按下瞬间」就置位 fileDragInteracting。
    // 文件项占浏览页绝大部分面积，一旦按下即抑制，落在文件上的普通左右滑动
    // 会被全部误杀，表现为切页失效/极不灵敏（v1.1.41 问题）。
    // 改为只在拖拽「真正开始」后（onDragStarted）才置位，结束时复位；
    // 长按未触发拖动的普通点按/滑动完全不受影响。
    return LongPressDraggable<DragPayload>(
      data: widget.data,
      feedback: widget.feedback,
      dragAnchorStrategy: pointerDragAnchorStrategy,
      delay: widget.delay,
      onDragStarted: () {
        _hasMoved = false;
        final provider = context.read<FileManagerProvider>();
        provider.setDragging(true);
        provider.setFileDragInteracting(true);
        widget.onDragStarted?.call();
      },
      onDragUpdate: (details) {
        if (details.delta.dx.abs() > 20.0 || details.delta.dy.abs() > 20.0) {
          _hasMoved = true;
        }
      },
      onDragEnd: (details) {
        final provider = context.read<FileManagerProvider>();
        provider.setDragging(false);
        provider.setFileDragInteracting(false);
        if (!_hasMoved && widget.onLongPress != null) {
          widget.onLongPress!();
        }
      },
      onDraggableCanceled: (velocity, offset) {
        final provider = context.read<FileManagerProvider>();
        provider.setDragging(false);
        provider.setFileDragInteracting(false);
      },
      childWhenDragging: Opacity(
        opacity: 0.35,
        child: widget.child,
      ),
      child: widget.child,
    );
  }
}
