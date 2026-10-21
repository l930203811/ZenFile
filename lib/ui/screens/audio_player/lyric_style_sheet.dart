import 'package:flutter/material.dart';

import '../../../services/lyric_animation_style.dart';
import '../../../services/preferences_service.dart';
import '../../../l10n/generated/app_localizations.dart';
import 'lyric_style_dropdown.dart';

/// 歌词动画风格选择弹窗（下拉框单选）。
///
/// 播放页三点菜单、歌词设置页、全屏歌词页共用同一弹窗；
/// 选中后立即持久化，并通过 [onSelected] 回调通知调用方刷新本地状态。
///
/// ⚠️ 形态已改为**下拉框**（与「音效与均衡器」页一致）：收起态只显示当前
/// 选中的风格，点开展开全部 11 项，选中后自动收起。早期版本用
/// `Column(mainAxisSize.min)` 平铺 11 个 ListTile，在手机上必然溢出，
/// 新增的 fade/slide/rotate/zoom/wave 直接被挤出屏幕（「全屏时右上角的
/// 风格列表没有完全显示出来」）。下拉框天然只占一行，任何屏幕都不会溢出。
///
/// 选中后**不关闭弹窗**：风格是即时生效的视觉偏好，留在原地可以连续比较
/// 几种风格；点空白处或下滑即可关闭。
Future<void> showLyricStyleSheet(
  BuildContext context, {
  required LyricAnimationStyle current,
  required ValueChanged<LyricAnimationStyle> onSelected,
}) {
  final l10n = L10n.of(context);
  return showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (ctx) {
      final theme = Theme.of(ctx);
      final isDark = theme.brightness == Brightness.dark;
      final surface = isDark
          ? const Color(0xFF1E1E2E)
          : theme.colorScheme.surface;
      final titleColor = isDark ? Colors.white : theme.colorScheme.onSurface;
      var selected = current;

      return StatefulBuilder(
        builder: (ctx, setSheet) {
          return SafeArea(
            child: Container(
              decoration: BoxDecoration(
                color: surface,
                borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(24),
                ),
              ),
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Icon(
                        Icons.animation_rounded,
                        color: Colors.deepPurpleAccent,
                        size: 20,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        l10n.lyric_animation_style,
                        style: TextStyle(
                          color: titleColor,
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const Spacer(),
                      IconButton(
                        tooltip: MaterialLocalizations.of(ctx).closeButtonLabel,
                        icon: Icon(
                          Icons.close_rounded,
                          color: titleColor.withValues(alpha: 0.6),
                          size: 20,
                        ),
                        onPressed: () => Navigator.pop(ctx),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  LyricStyleDropdown(
                    value: selected,
                    isDark: isDark,
                    foreground: titleColor,
                    onChanged: (style) {
                      setSheet(() => selected = style);
                      PreferencesService.saveLyricAnimationStyleName(
                        style.name,
                      );
                      onSelected(style);
                    },
                  ),
                ],
              ),
            ),
          );
        },
      );
    },
  );
}
