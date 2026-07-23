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

  const DraggableItem({
    super.key,
    required this.child,
    required this.feedback,
    required this.data,
    this.delay = const Duration(milliseconds: 600),
    this.onLongPress,
  });

  @override
  State<DraggableItem> createState() => _DraggableItemState();
}

class _DraggableItemState extends State<DraggableItem> {
  bool _hasMoved = false;

  @override
  Widget build(BuildContext context) {
    return LongPressDraggable<DragPayload>(
      data: widget.data,
      feedback: widget.feedback,
      dragAnchorStrategy: pointerDragAnchorStrategy,
      delay: widget.delay,
      onDragStarted: () {
        _hasMoved = false;
        context.read<FileManagerProvider>().setDragging(true);
      },
      onDragUpdate: (details) {
        if (details.delta.dx.abs() > 20.0 || details.delta.dy.abs() > 20.0) {
          _hasMoved = true;
        }
      },
      onDragEnd: (details) {
        context.read<FileManagerProvider>().setDragging(false);
        if (!_hasMoved && widget.onLongPress != null) {
          widget.onLongPress!();
        }
      },
      onDraggableCanceled: (velocity, offset) {
        context.read<FileManagerProvider>().setDragging(false);
      },
      childWhenDragging: Opacity(
        opacity: 0.35,
        child: widget.child,
      ),
      child: widget.child,
    );
  }
}
