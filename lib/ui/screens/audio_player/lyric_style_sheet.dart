import 'package:flutter/material.dart';

import '../../../services/lyric_animation_style.dart';
import '../../../services/preferences_service.dart';
import '../../../l10n/generated/app_localizations.dart';

/// 歌词动画风格选择弹窗（底部弹起，单选 + 效果说明）。
///
/// 播放页三点菜单、歌词设置页、全屏歌词页共用同一弹窗；
/// 选中后立即持久化，并通过 [onSelected] 回调通知调用方刷新本地状态。
Future<void> showLyricStyleSheet(
  BuildContext context, {
  required LyricAnimationStyle current,
  required ValueChanged<LyricAnimationStyle> onSelected,
}) {
  final l10n = L10n.of(context);
  return showModalBottomSheet(
    context: context,
    backgroundColor: Colors.transparent,
    builder: (ctx) {
      final theme = Theme.of(ctx);
      final isDark = theme.brightness == Brightness.dark;
      final surface = isDark
          ? const Color(0xFF1E1E2E)
          : theme.colorScheme.surface;
      final titleColor = isDark ? Colors.white : theme.colorScheme.onSurface;
      final subColor = titleColor.withValues(alpha: 0.55);

      Widget item({
        required IconData icon,
        required String title,
        required String desc,
        required bool selected,
        required VoidCallback onTap,
      }) {
        return ListTile(
          leading: Icon(
            icon,
            color: selected
                ? Colors.deepPurpleAccent
                : titleColor.withValues(alpha: 0.7),
          ),
          title: Text(
            title,
            style: TextStyle(color: titleColor, fontWeight: FontWeight.w600),
          ),
          subtitle: Text(desc, style: TextStyle(color: subColor, fontSize: 12)),
          trailing: selected
              ? const Icon(
                  Icons.check_circle_rounded,
                  color: Colors.deepPurpleAccent,
                )
              : null,
          onTap: onTap,
        );
      }

      return SafeArea(
        child: Container(
          decoration: BoxDecoration(
            color: surface,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
                child: Row(
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
                  ],
                ),
              ),
              item(
                icon: Icons.shuffle_rounded,
                title: l10n.lyric_style_mixed,
                desc: l10n.lyric_style_mixed_desc,
                selected: current == LyricAnimationStyle.mixed,
                onTap: () => _pick(ctx, LyricAnimationStyle.mixed, onSelected),
              ),
              item(
                icon: Icons.music_note_rounded,
                title: l10n.lyric_style_classic,
                desc: l10n.lyric_style_classic_desc,
                selected: current == LyricAnimationStyle.classic,
                onTap: () =>
                    _pick(ctx, LyricAnimationStyle.classic, onSelected),
              ),
              item(
                icon: Icons.auto_awesome,
                title: l10n.lyric_style_glow,
                desc: l10n.lyric_style_glow_desc,
                selected: current == LyricAnimationStyle.glow,
                onTap: () => _pick(ctx, LyricAnimationStyle.glow, onSelected),
              ),
              item(
                icon: Icons.movie_rounded,
                title: l10n.lyric_style_immersive,
                desc: l10n.lyric_style_immersive_desc,
                selected: current == LyricAnimationStyle.immersive,
                onTap: () =>
                    _pick(ctx, LyricAnimationStyle.immersive, onSelected),
              ),
              item(
                icon: Icons.bolt_rounded,
                title: l10n.lyric_style_pv,
                desc: l10n.lyric_style_pv_desc,
                selected: current == LyricAnimationStyle.pv,
                onTap: () => _pick(ctx, LyricAnimationStyle.pv, onSelected),
              ),
              item(
                icon: Icons.blur_on_rounded,
                title: l10n.lyric_style_echo,
                desc: l10n.lyric_style_echo_desc,
                selected: current == LyricAnimationStyle.echo,
                onTap: () => _pick(ctx, LyricAnimationStyle.echo, onSelected),
              ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      );
    },
  );
}

void _pick(
  BuildContext ctx,
  LyricAnimationStyle style,
  ValueChanged<LyricAnimationStyle> onSelected,
) {
  PreferencesService.saveLyricAnimationStyleName(style.name);
  onSelected(style);
  Navigator.pop(ctx);
}
