import 'package:flutter/material.dart';

import '../../../l10n/generated/app_localizations.dart';

/// 歌词三色默认值（歌词设置页图示配色）：未播放 / 当前播放 / 已播放。
/// 偏好未自定义（null）时使用这组颜色；「恢复默认」即回退到此。
const Color kLyricColorUnplayedDefault = Color(0xFFFFFFFF);
const Color kLyricColorCurrentDefault = Color(0xFFCDDC39);
const Color kLyricColorPlayedDefault = Color(0xFF8BC34A);

/// 歌词三色选择弹窗（未播放 / 当前播放 / 已播放共用）。
///
/// 与「设置-主题色」的自定义选色同风格：预设色板 + RGB 滑杆 + 实时预览，
/// 另提供「恢复默认」——删除偏好，回退到默认配色（白 / 黄绿 / 绿）。
/// 不引入第三方依赖，纯 Flutter 内置控件。
class LyricColorPickerDialog extends StatefulWidget {
  /// 进入弹窗时的初始颜色（当前生效色，可能是主题默认色）。
  final Color initialColor;

  /// 标题（如「未播放歌词颜色」）。
  final String title;

  const LyricColorPickerDialog({
    super.key,
    required this.initialColor,
    required this.title,
  });

  @override
  State<LyricColorPickerDialog> createState() => _LyricColorPickerDialogState();
}

class _LyricColorPickerDialogState extends State<LyricColorPickerDialog> {
  late double _r;
  late double _g;
  late double _b;
  late Color _current;

  static const List<Color> _presets = [
    Color(0xFFE91E63),
    Color(0xFFFF5722),
    Color(0xFFFF9800),
    Color(0xFFFFC107),
    Color(0xFFFFEB3B),
    Color(0xFFCDDC39),
    Color(0xFF8BC34A),
    Color(0xFF4CAF50),
    Color(0xFF009688),
    Color(0xFF00BCD4),
    Color(0xFF03A9F4),
    Color(0xFF2196F3),
    Color(0xFF3F51B5),
    Color(0xFF673AB7),
    Color(0xFF9C27B0),
    Color(0xFF000000),
    Color(0xFFFFFFFF),
    Color(0xFF795548),
  ];

  @override
  void initState() {
    super.initState();
    _r = _ch255(widget.initialColor.r);
    _g = _ch255(widget.initialColor.g);
    _b = _ch255(widget.initialColor.b);
    _current = widget.initialColor;
  }

  /// Color.r/g/b（0..1 double）→ 0..255 double 滑杆值。
  static double _ch255(double ch) =>
      (ch * 255.0).round().clamp(0, 255).toDouble();

  void _setChannel(String channel, double v) {
    setState(() {
      if (channel == 'R') _r = v;
      if (channel == 'G') _g = v;
      if (channel == 'B') _b = v;
      _current = Color.fromARGB(255, _r.round(), _g.round(), _b.round());
    });
  }

  void _applyPreset(Color c) {
    setState(() {
      _r = _ch255(c.r);
      _g = _ch255(c.g);
      _b = _ch255(c.b);
      _current = c;
    });
  }

  String get _hex =>
      '#${_current.toARGB32().toRadixString(16).toUpperCase().padLeft(8, '0').substring(2)}';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = L10n.of(context);

    return AlertDialog(
      backgroundColor: theme.scaffoldBackgroundColor,
      title: Text(
        widget.title,
        style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 预览 + 色值
            Row(
              children: [
                Container(
                  width: 52,
                  height: 52,
                  decoration: BoxDecoration(
                    color: _current,
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: theme.colorScheme.onSurface.withValues(alpha: 0.2),
                      width: 2,
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: _current.withValues(alpha: 0.4),
                        blurRadius: 12,
                        spreadRadius: 2,
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 14),
                Text(
                  _hex,
                  style: TextStyle(
                    fontSize: 13,
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.7),
                    fontFamily: 'monospace',
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                l10n.ui_preset_colors,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.7),
                ),
              ),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: _presets.map((color) {
                final selected = color.toARGB32() == _current.toARGB32();
                return GestureDetector(
                  onTap: () => _applyPreset(color),
                  child: Container(
                    width: 34,
                    height: 34,
                    decoration: BoxDecoration(
                      color: color,
                      shape: BoxShape.circle,
                      border: selected
                          ? Border.all(
                              color: theme.colorScheme.primary,
                              width: 3,
                            )
                          : Border.all(
                              color: theme.colorScheme.onSurface.withValues(
                                alpha: 0.15,
                              ),
                              width: 1,
                            ),
                    ),
                    child: selected
                        ? Icon(
                            Icons.check,
                            size: 18,
                            color: color.computeLuminance() > 0.6
                                ? Colors.black
                                : Colors.white,
                          )
                        : null,
                  ),
                );
              }).toList(),
            ),
            const SizedBox(height: 10),
            _buildSlider('R', _r, Colors.red, (v) => _setChannel('R', v)),
            _buildSlider('G', _g, Colors.green, (v) => _setChannel('G', v)),
            _buildSlider('B', _b, Colors.blue, (v) => _setChannel('B', v)),
          ],
        ),
      ),
      actions: [
        // 恢复默认：清除自定义，回退默认配色
        TextButton(
          onPressed: () =>
              Navigator.pop(context, const LyricColorResult(null, reset: true)),
          child: Text(l10n.lyric_color_reset),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(MaterialLocalizations.of(context).cancelButtonLabel),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, LyricColorResult(_current)),
          child: Text(MaterialLocalizations.of(context).okButtonLabel),
        ),
      ],
    );
  }

  Widget _buildSlider(
    String label,
    double value,
    Color color,
    ValueChanged<double> onChanged,
  ) {
    return Row(
      children: [
        SizedBox(
          width: 16,
          child: Text(
            label,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.bold,
              color: color,
            ),
          ),
        ),
        Expanded(
          child: Slider(
            value: value,
            min: 0,
            max: 255,
            activeColor: color,
            inactiveColor: color.withValues(alpha: 0.2),
            onChanged: onChanged,
          ),
        ),
        SizedBox(
          width: 36,
          child: Text(
            value.round().toString(),
            textAlign: TextAlign.right,
            style: const TextStyle(fontSize: 12),
          ),
        ),
      ],
    );
  }
}

/// 弹出歌词选色弹窗。
///
/// 返回 [LyricColorResult]：
/// - `LyricColorResult(color)` = 点确定，应用 [color]；
/// - `LyricColorResult(null, reset: true)` = 点「恢复默认」；
/// - null = 取消/点击外部关闭，不作更改。
Future<LyricColorResult?> showLyricColorPicker(
  BuildContext context, {
  required Color currentColor,
  required String title,
}) {
  return showDialog<LyricColorResult>(
    context: context,
    builder: (_) =>
        LyricColorPickerDialog(initialColor: currentColor, title: title),
  );
}

/// 选色结果：[color] 为 null 且 [reset] 为 true 表示恢复默认。
class LyricColorResult {
  final Color? color;
  final bool reset;
  const LyricColorResult(this.color, {this.reset = false});
}
