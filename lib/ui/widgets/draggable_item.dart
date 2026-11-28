import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../models/drag_payload.dart';
import '../../providers/file_manager_provider.dart';
import '../../services/webdav_debug_log.dart';

/// 独立的拖拽组件，不监听任何 provider，避免重建打断长按手势
class DraggableItem extends StatefulWidget {
  final Widget child;
  final Widget feedback;
  final DragPayload data;

  /// 长按多久才算「拖拽排序」。
  ///
  /// ## 为什么改回 500ms（2026-11-28 第十四轮）
  ///
  /// 这个值之前被从 600ms 提到 **1000ms**，理由是「死线越长越不容易在主线程
  /// 停顿时被误判」。**该取舍被真机日志直接证伪**：
  ///
  /// 第十四轮日志里，用户真实的长按手势只有两次：
  /// * `长按手势#6 按压528ms 最大位移9.8px`
  /// * `长按手势#8 按压808ms 最大位移3.8px`（几乎完全静止）
  ///
  /// ⇒ 死线设成 1000ms 时，**浏览项长按 100% 到不了死线**，
  ///    `DelayedMultiDragGestureRecognizer` 永远不会 resolve(accepted)
  ///    ⇒ `onDragStarted` 不触发 ⇒ `onLongPress` 不触发
  ///    ⇒ 用户长按什么都没发生，且 App 侧一条长按日志都没有。
  ///
  /// 这就是「长按完全无响应」的**确定原因**（App 侧长按回调 0 次，与此完全吻合）。
  ///
  /// 现在改回 Flutter 框架自己的 `kLongPressTimeout`（500ms），
  /// 与 `LongPressGestureRecognizer` 的死线一致 ⇒ 两类长按行为对齐。
  /// 「主线程停顿导致误判」的风险改由别处兜底：长按动作只在
  /// `onDragStarted` 触发一次，且已在第十一轮去掉重复触发。
  final Duration delay;
  final VoidCallback? onLongPress;
  final VoidCallback? onDragStarted;

  const DraggableItem({
    super.key,
    required this.child,
    required this.feedback,
    required this.data,
    this.delay = const Duration(milliseconds: 500),
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
    //
    // ⚠️ 外层这个 Listener **只做取证**，不做任何状态干预。
    //
    // 它用 `HitTestBehavior.translucent`：自己一定加入命中路径（所以「手指有没
    // 落在浏览项上」这件事必然能观测到），但**不拦截**子级，也不参与手势竞技场
    // ⇒ 不会抢走 InkWell 的 tap，也不会影响拖拽。
    //
    // 用途：`LongPressDraggable` 用的是 `DelayedMultiDragGestureRecognizer`，
    // 它**没有** `onLongPressDown` 这种回调，没法像分类卡那样直接证明
    // 「识别器收到了 down」。这里退一步在按下瞬间打点：
    // * 有这条 ⇒ 手指确实落在本控件上（命中路径成立）；
    // * 没有   ⇒ 手指压根没落在浏览项上。
    // 再配合 `onDragStarted` 里的「长按拖拽抢到手势」，就能把
    // 「没收到 down」和「收到了但没到死线」彻底分开。
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (event) {
        WebdavDebugLog.logAlways(
          '[tap] 长按下压(浏览项) ${widget.data.isRemote ? '远程' : '本地'} '
          'items=${widget.data.paths.length}',
        );
      },
      child: LongPressDraggable<DragPayload>(
        data: widget.data,
        feedback: widget.feedback,
        dragAnchorStrategy: pointerDragAnchorStrategy,
        delay: widget.delay,
        // ⚠️ 显式 opaque（2026-11-28 第十四轮）。
        //
        // `Draggable` 默认 `hitTestBehavior: HitTestBehavior.deferToChild`
        // （框架源码 `widgets/drag_target.dart`）⇒ 它的 `Listener` 只在
        // **子级先被命中**时才会收到 pointer down。
        //
        // 浏览项的可命中子级只有图标和文字（`RenderParagraph.hitTestSelf => true`），
        // 卡片其余区域（内边距、图标与文字之间的空隙）**命中不到任何东西**
        // ⇒ 长按识别器根本不在命中路径里 ⇒ 长按永远不触发。
        //
        // `opaque` 让整张浏览项（含空白区）都算命中，
        // 保证 `DelayedMultiDragGestureRecognizer` 100% 收到 down。
        hitTestBehavior: HitTestBehavior.opaque,
        onDragStarted: () {
          _hasMoved = false;
          // 取证：长按识别器抢到了手势 ⇒ 子级 InkWell 的 tap 会被 **reject**
          // ⇒ onTap 永不触发 ⇒ 用户看到「点了没反应」。
          // 这条日志能把「被长按抢走」与「被重建取消」两种成因区分开。
          WebdavDebugLog.logAlways(
            '[tap] 长按拖拽抢到手势 items=${widget.data.paths.length}',
          );
          final provider = context.read<FileManagerProvider>();
          provider.setDragging(true);
          provider.setFileDragInteracting(true);
          // ★★ 长按动作**只在**这里触发一次（2026-11-28 第十一轮修复）。
          //
          // `LongPressDraggable` 用的 `DelayedMultiDragGestureRecognizer` 在
          // **死线到达时**就 resolve(accepted) ⇒ 拖拽**立刻开始** ⇒
          // `onDragStarted` 触发 ⇒ **「按住不动」也能触发长按**。
          //
          // 旧实现把长按动作挂在 `onDragEnd`（`!_hasMoved`）上，于是：
          //   ① onDragStarted 触发一次（长按被识别的瞬间）；
          //   ② 抬起时 onDragEnd 又触发一次。
          // ⇒ 文件被「选中 → 立刻取消」来回抵消，**净效果为零**
          // ⇒ 用户看到的就是「长按完全没响应」（实测 100% 复现）。
          //
          // 现在动作只挂在 onDragStarted，`onDragEnd` 不再重复触发。
          widget.onLongPress?.call();
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
          // ⚠️ 这里**不再**触发 `widget.onLongPress`：长按动作已经在
          //    `onDragStarted` 里触发过一次，重复触发会把它自我抵消掉。
          //    `_hasMoved` 仅保留给日志判断，不再参与动作决策。
          if (!_hasMoved) {
            WebdavDebugLog.logAlways(
              '[tap] 长按拖拽结束(未移动) items=${widget.data.paths.length}',
            );
          }
        },
        onDraggableCanceled: (velocity, offset) {
          final provider = context.read<FileManagerProvider>();
          provider.setDragging(false);
          provider.setFileDragInteracting(false);
        },
        childWhenDragging: Opacity(opacity: 0.35, child: widget.child),
        child: widget.child,
      ),
    );
  }
}
