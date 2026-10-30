import 'package:flutter/material.dart';

import '../../../core/icon_fonts/broken_icons.dart';
import '../../../services/system_volume_service.dart';

/// 音量按钮（音频播放器底部工具行最右侧）。
///
/// 交互（与系统媒体音量 STREAM_MUSIC **双向同步**）：
/// * **点按** = 静音 / 恢复到静音前的音量（记忆在 [SystemVolumeService]）；
/// * **按住横向拖动** = 连续调节（左右均可，约 180px 走完全量程）；
/// * 音量键 / 系统音量面板的改动会经 volume_events 实时反映到图标状态
///   （静音 / 低 / 高），不依赖按钮自己维护的假状态。
class AudioVolumeButton extends StatefulWidget {
  final double iconSize;
  final BoxConstraints constraints;
  final Color accentColor;

  const AudioVolumeButton({
    super.key,
    required this.iconSize,
    required this.constraints,
    required this.accentColor,
  });

  @override
  State<AudioVolumeButton> createState() => _AudioVolumeButtonState();
}

class _AudioVolumeButtonState extends State<AudioVolumeButton> {
  final SystemVolumeService _svc = SystemVolumeService.instance;
  double? _dragStartVolume;

  @override
  void initState() {
    super.initState();
    // 幂等：读当前系统音量 + 订阅音量变化广播（页面/控件首次进入即生效）。
    _svc.ensureInitialized();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ValueListenableBuilder<double>(
      valueListenable: _svc.volume,
      builder: (context, vol, _) {
        final muted = vol <= 0.001;
        final icon = muted
            ? Broken.volume_cross
            : (vol < 0.4 ? Broken.volume_low : Broken.volume_up);
        final color = muted
            ? theme.colorScheme.onSurface.withValues(alpha: 0.55)
            : theme.colorScheme.onSurface.withValues(alpha: 0.8);
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => _svc.toggleMute(),
          onHorizontalDragStart: (_) => _dragStartVolume = vol,
          onHorizontalDragUpdate: (d) {
            final start = _dragStartVolume ?? vol;
            // 180px 逻辑像素 = 全量程；左右都能拖。
            _svc.setVolume(start + d.delta.dx / 180);
          },
          onHorizontalDragEnd: (_) => _dragStartVolume = null,
          onHorizontalDragCancel: () => _dragStartVolume = null,
          child: Container(
            width: widget.constraints.minWidth,
            height: widget.constraints.minHeight,
            alignment: Alignment.center,
            child: Icon(icon, size: widget.iconSize, color: color),
          ),
        );
      },
    );
  }
}
