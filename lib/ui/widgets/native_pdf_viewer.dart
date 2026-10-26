import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:zenfile/l10n/generated/app_localizations.dart';

/// 大 PDF 的原生分页查看器。
///
/// 通过 `com.sequl.zenfile/pdf_renderer` 通道调用 Android 原生
/// `PdfRenderer`，在**后台线程**把每一页渲染成 PNG（见 MainActivity.kt），
/// 本 Widget 只负责按需展示这些图片。这样无论 PDF 多大，Flutter 主线程
/// 都始终空闲、输入分发不超时 → 不再出现 Syncfusion 同步解析导致的 ANR 闪退。
///
/// 与内置 Syncfusion 查看器相比，这里**没有**文本选择 / 搜索 / 缩略图导航，
/// 仅做「逐页看图」，定位是大文件的安全兜底查看方案。
class NativePdfViewer extends StatefulWidget {
  final String filePath;
  final VoidCallback? onOpenExternal;

  const NativePdfViewer({
    super.key,
    required this.filePath,
    this.onOpenExternal,
  });

  @override
  State<NativePdfViewer> createState() => _NativePdfViewerState();
}

class _NativePdfViewerState extends State<NativePdfViewer> {
  static const _channel = MethodChannel('com.sequl.zenfile/pdf_renderer');

  int? _pageCount;
  bool _failed = false;
  final Map<int, String> _rendered = {};
  final Set<int> _rendering = {};
  int _visiblePage = 0;

  /// 是否正处于放大状态（任一页 scale>1）。放大时禁用 ListView 竖向滚动，
  /// 并把 InteractiveViewer 的 panEnabled 打开，这样单指可平移已放大的页，
  /// 而不会和「翻到下一页」的滚动冲突；缩回 1 倍时恢复 ListView 滚动。
  bool _isZoomed = false;

  /// 最近一次缩放手势的倍率（仅在 onInteractionUpdate 里记录，**不触发重建**）。
  double _lastScale = 1.0;

  /// 当前按下的指针数量（用来识别双指缩放手势）。
  int _activePointers = 0;

  /// 是否检测到双指按下（≥2 个指针）。为 true 时立刻关掉 ListView 的
  /// 竖向滚动，让 InteractiveViewer 的缩放独占手势 —— 否则第二根手指按慢
  /// 一点时，外层滚动识别器已经先接管、竞技场关闭，缩放再也起不来。
  bool _multiTouchZoom = false;

  @override
  void initState() {
    super.initState();
    _loadPageCount();
  }

  Future<void> _loadPageCount() async {
    try {
      final count =
          await _channel.invokeMethod<int>('pageCount', {'path': widget.filePath});
      if (!mounted) return;
      setState(() => _pageCount = count ?? 0);
    } catch (e) {
      if (!mounted) return;
      setState(() => _failed = true);
    }
  }

  Future<void> _renderPage(int index) async {
    if (_rendered.containsKey(index) || _rendering.contains(index)) return;
    _rendering.add(index);
    try {
      final width = (MediaQuery.of(context).size.width *
              MediaQuery.of(context).devicePixelRatio)
          .toInt()
          .clamp(600, 2000);
      final path = await _channel.invokeMethod<String>('renderPage', {
        'path': widget.filePath,
        'index': index,
        'width': width,
      });
      if (!mounted) return;
      setState(() => _rendered[index] = path ?? '__error__');
    } catch (e) {
      if (!mounted) return;
      setState(() => _rendered[index] = '__error__');
    } finally {
      _rendering.remove(index);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = L10n.of(context);

    if (_failed) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.broken_image_outlined, size: 48),
              const SizedBox(height: 12),
              Text(
                l10n.msg_pdf_large_render_failed,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium,
              ),
              const SizedBox(height: 12),
              if (widget.onOpenExternal != null)
                FilledButton.icon(
                  onPressed: widget.onOpenExternal,
                  icon: const Icon(Icons.open_in_new_rounded),
                  label: Text(l10n.msg1d93c30b),
                ),
            ],
          ),
        ),
      );
    }

    if (_pageCount == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_pageCount == 0) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.picture_as_pdf_rounded, size: 48, color: Colors.grey),
              const SizedBox(height: 12),
              Text(l10n.msg_pdf_large_empty, textAlign: TextAlign.center),
              const SizedBox(height: 12),
              if (widget.onOpenExternal != null)
                TextButton.icon(
                  onPressed: widget.onOpenExternal,
                  icon: const Icon(Icons.open_in_new_rounded),
                  label: Text(l10n.msg1d93c30b),
                ),
            ],
          ),
        ),
      );
    }

    // ⚠️ 先赋局部变量再 return：外层要套 Listener，直接内联会让整棵子树缩进 +2，
    // diff 变成整篇重写、掩盖真实改动（见备忘「套新父 widget」铁律）。
    final pages = Stack(
      children: [
        NotificationListener<ScrollNotification>(
          onNotification: (n) {
            if (n is ScrollUpdateNotification && n.metrics.maxScrollExtent > 0) {
              // 每项约 480 高 + 12 上 + 12 下边距 = 492，用其估算当前可视页。
              const itemH = 492.0;
              final idx = (n.metrics.pixels / itemH)
                  .floor()
                  .clamp(0, _pageCount! - 1);
              if (idx != _visiblePage && mounted) {
                setState(() => _visiblePage = idx);
              }
            }
            return false;
          },
          child: ListView.builder(
            // 放大时（_isZoomed）禁用竖向滚动，避免和 InteractiveViewer 的平移冲突；
            // 缩回原倍率后恢复滚动以便翻页。
            physics: (_isZoomed || _multiTouchZoom)
                ? const NeverScrollableScrollPhysics()
                : null,
            itemCount: _pageCount,
            itemBuilder: (ctx, i) {
              final p = _rendered[i];
              if (p == null) {
                // 仅对进入视图的条目触发渲染（ListView.builder 已做视图回收）。
                WidgetsBinding.instance.addPostFrameCallback((_) => _renderPage(i));
                return _placeholder();
              }
              if (p == '__error__') return _errorTile();
              return _pageTile(p, i);
            },
          ),
        ),
        Positioned(
          left: 0,
          right: 0,
          bottom: 12,
          child: Center(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              decoration: BoxDecoration(
                color: Colors.black54,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                '${_visiblePage + 1} / $_pageCount',
                style: const TextStyle(color: Colors.white, fontSize: 12),
              ),
            ),
          ),
        ),
      ],
    );

    // 双指捏合优先：一旦检测到 ≥2 个指针按下，立刻关掉 ListView 的竖向滚动。
    // 否则第二根手指按慢一点时，外层滚动识别器已经先接管、竞技场关闭，
    // 缩放再也起不来，表现为「必须双指快速滑动才放大，双指长按滑动失效」。
    // 指针全部抬起后恢复滚动以便翻页。
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: _onPointerDown,
      onPointerUp: _onPointerUp,
      onPointerCancel: _onPointerCancel,
      child: pages,
    );
  }

  void _onPointerDown(PointerDownEvent _) {
    _activePointers++;
    if (_activePointers >= 2 && !_multiTouchZoom) {
      setState(() => _multiTouchZoom = true);
    }
  }

  void _onPointerUp(PointerUpEvent _) => _releasePointer();

  void _onPointerCancel(PointerCancelEvent _) => _releasePointer();

  void _releasePointer() {
    if (_activePointers > 0) _activePointers--;
    if (_activePointers < 2 && _multiTouchZoom) {
      setState(() => _multiTouchZoom = false);
    }
  }

  Widget _placeholder() => Container(
        height: 480,
        margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        decoration: BoxDecoration(
          color: Colors.black12,
          borderRadius: BorderRadius.circular(8),
        ),
        child: const Center(child: CircularProgressIndicator()),
      );

  Widget _errorTile() => Container(
        height: 200,
        margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        decoration: BoxDecoration(
          color: Colors.black12,
          borderRadius: BorderRadius.circular(8),
        ),
        child: const Center(child: Icon(Icons.broken_image_outlined)),
      );

  Widget _pageTile(String path, int i) => Container(
        margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(8),
          boxShadow: const [
            BoxShadow(color: Colors.black26, blurRadius: 6, offset: Offset(0, 2)),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: InteractiveViewer(
            // 缩放用双指捏合（scaleEnabled 恒 true）。放大状态 _isZoomed **只在手势
            // 结束时更新**（onInteractionEnd）；绝不在 onInteractionUpdate 里 setState
            // ——否则每帧重建 ListView 会打断正在进行的缩放手势，导致「捏合后弹回」，
            // 表现为放大无效。放大后 panEnabled=true，单指可平移已放大的页；
            // 缩回原倍则恢复 ListView 竖向滚动翻页。
            minScale: 1.0,
            maxScale: 5.0,
            scaleEnabled: true,
            panEnabled: _isZoomed,
            onInteractionUpdate: (d) {
              // 仅记录倍率，不触发重建，保证缩放手势连续不被中断。
              _lastScale = d.scale;
            },
            onInteractionEnd: (_) {
              final z = _lastScale > 1.02;
              if (z != _isZoomed && mounted) setState(() => _isZoomed = z);
            },
            child: Image.file(
              File(path),
              fit: BoxFit.fitWidth,
              filterQuality: FilterQuality.medium,
            ),
          ),
        ),
      );
}
