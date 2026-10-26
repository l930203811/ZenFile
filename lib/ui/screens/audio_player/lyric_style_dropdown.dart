import 'package:flutter/material.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../../services/lyric_animation_style.dart';

/// 歌词动画风格：图标（三处入口统一，避免各自硬编码）。
IconData lyricStyleIcon(LyricAnimationStyle style) {
  switch (style) {
    case LyricAnimationStyle.mixed:
      return Icons.shuffle_rounded;
    case LyricAnimationStyle.classic:
      return Icons.music_note_rounded;
    case LyricAnimationStyle.typewriter:
      return Icons.keyboard_rounded;
    case LyricAnimationStyle.meteor:
      return Icons.rocket_launch_rounded;
    case LyricAnimationStyle.pv:
      return Icons.bolt_rounded;
    case LyricAnimationStyle.echo:
      return Icons.blur_on_rounded;
    case LyricAnimationStyle.drop:
      return Icons.south_rounded;
    case LyricAnimationStyle.burst:
      return Icons.open_in_full_rounded;
    case LyricAnimationStyle.cube:
      return Icons.threed_rotation;
    case LyricAnimationStyle.punch:
      return Icons.flare_rounded;
    case LyricAnimationStyle.wave:
      return Icons.water_rounded;
  }
}

/// 风格的本地化名称。
String lyricStyleName(L10n l10n, LyricAnimationStyle style) {
  switch (style) {
    case LyricAnimationStyle.mixed:
      return l10n.lyric_style_mixed;
    case LyricAnimationStyle.classic:
      return l10n.lyric_style_classic;
    case LyricAnimationStyle.typewriter:
      return l10n.lyric_style_typewriter;
    case LyricAnimationStyle.meteor:
      return l10n.lyric_style_meteor;
    case LyricAnimationStyle.pv:
      return l10n.lyric_style_pv;
    case LyricAnimationStyle.echo:
      return l10n.lyric_style_echo;
    case LyricAnimationStyle.drop:
      return l10n.lyric_style_drop;
    case LyricAnimationStyle.burst:
      return l10n.lyric_style_burst;
    case LyricAnimationStyle.cube:
      return l10n.lyric_style_cube;
    case LyricAnimationStyle.punch:
      return l10n.lyric_style_punch;
    case LyricAnimationStyle.wave:
      return l10n.lyric_style_wave;
  }
}

/// 风格的一句话说明（下拉框下方展示当前选中项）。
String lyricStyleDesc(L10n l10n, LyricAnimationStyle style) {
  switch (style) {
    case LyricAnimationStyle.mixed:
      return l10n.lyric_style_mixed_desc;
    case LyricAnimationStyle.classic:
      return l10n.lyric_style_classic_desc;
    case LyricAnimationStyle.typewriter:
      return l10n.lyric_style_typewriter_desc;
    case LyricAnimationStyle.meteor:
      return l10n.lyric_style_meteor_desc;
    case LyricAnimationStyle.pv:
      return l10n.lyric_style_pv_desc;
    case LyricAnimationStyle.echo:
      return l10n.lyric_style_echo_desc;
    case LyricAnimationStyle.drop:
      return l10n.lyric_style_drop_desc;
    case LyricAnimationStyle.burst:
      return l10n.lyric_style_burst_desc;
    case LyricAnimationStyle.cube:
      return l10n.lyric_style_cube_desc;
    case LyricAnimationStyle.punch:
      return l10n.lyric_style_punch_desc;
    case LyricAnimationStyle.wave:
      return l10n.lyric_style_wave_desc;
  }
}

/// 「歌词动画风格」菜单的展示顺序：混合模式排最前（默认风格、表现力最强、
/// 用户最常选），其余按枚举定义顺序跟在后面。仅影响菜单展示顺序，
/// 不影响枚举定义与持久化（按 name 存取）。
const List<LyricAnimationStyle> kLyricStyleDisplayOrder = [
  LyricAnimationStyle.mixed,
  LyricAnimationStyle.classic,
  LyricAnimationStyle.typewriter,
  LyricAnimationStyle.meteor,
  LyricAnimationStyle.pv,
  LyricAnimationStyle.echo,
  LyricAnimationStyle.drop,
  LyricAnimationStyle.burst,
  LyricAnimationStyle.cube,
  LyricAnimationStyle.punch,
  LyricAnimationStyle.wave,
];

/// 歌词动画风格下拉框（与「音效与均衡器」页的下拉框同一套观感）。
///
/// 收起态**只显示当前选中的风格**（图标 + 名称），点击展开全部 11 项；
/// 选中后下拉菜单自动收起、收起态立即换成新风格 + 下方说明文字同步刷新。
/// 替代早期「11 个 ListTile 平铺」——那种形态在任何手机上都必然溢出，
/// 新增的 5 种风格会被挤到屏幕外。
class LyricStyleDropdown extends StatelessWidget {
  final LyricAnimationStyle value;
  final ValueChanged<LyricAnimationStyle> onChanged;

  /// 深色面板（0xFF1E1E2E 系）还是跟随主题（浅色）。
  final bool isDark;

  /// 面板前景色（标题 / 收起态文字）。
  final Color foreground;

  /// 强调色（图标与选中项）。
  final Color accent;

  const LyricStyleDropdown({
    super.key,
    required this.value,
    required this.onChanged,
    required this.isDark,
    required this.foreground,
    this.accent = Colors.deepPurpleAccent,
  });

  /// 下拉面板 / 收起态的底色：深色面板用比容器略亮的一档，浅色用主题容器色。
  Color get _fieldColor =>
      isDark ? const Color(0xFF2A2A3E) : const Color(0x14000000);

  @override
  Widget build(BuildContext context) {
    final l10n = L10n.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            color: _fieldColor,
            borderRadius: BorderRadius.circular(12),
          ),
          child: DropdownButton<LyricAnimationStyle>(
            value: value,
            isExpanded: true,
            // 与均衡器下拉框一致：无下划线、菜单底色与收起态同色。
            underline: const SizedBox.shrink(),
            dropdownColor: isDark ? const Color(0xFF2A2A3E) : null,
            iconEnabledColor: foreground.withValues(alpha: 0.7),
            borderRadius: BorderRadius.circular(16),
            style: TextStyle(color: foreground, fontSize: 13),
            // 11 项在矮屏上展开会超出屏幕 ⇒ 限高由框架内部滚动，
            // 380dp 能同时看到 7~8 项，滚一下就能到「波纹漂浮」。
            menuMaxHeight: 380,
            selectedItemBuilder: (ctx) => [
              // 按展示顺序渲染（混合模式在最前）
              for (final s in kLyricStyleDisplayOrder)
                Row(
                  children: [
                    Icon(lyricStyleIcon(s), size: 18, color: accent),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        lyricStyleName(l10n, s),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 13.5,
                          color: foreground,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
            ],
            items: [
              // 与 selectedItemBuilder 同序（混合模式在最前）
              for (final s in kLyricStyleDisplayOrder)
                DropdownMenuItem<LyricAnimationStyle>(
                  value: s,
                  child: Row(
                    children: [
                      Icon(
                        lyricStyleIcon(s),
                        size: 18,
                        color: s == value
                            ? accent
                            : foreground.withValues(alpha: 0.6),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          lyricStyleName(l10n, s),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 13.5,
                            color: s == value ? accent : foreground,
                            fontWeight: s == value
                                ? FontWeight.w700
                                : FontWeight.w500,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
            ],
            onChanged: (s) {
              if (s == null || s == value) return;
              onChanged(s);
            },
          ),
        ),
        const SizedBox(height: 8),
        // 选中项说明：风格差异靠文字描述传达，收起态也要看得到。
        Text(
          lyricStyleDesc(l10n, value),
          style: TextStyle(
            fontSize: 11.5,
            height: 1.35,
            color: foreground.withValues(alpha: 0.55),
          ),
        ),
      ],
    );
  }
}
