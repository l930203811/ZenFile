import 'package:flutter/material.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../../services/preferences_service.dart';

/// 歌词偏移量文本（如 `+1.2s` / `-0.5s` / `0.0s`）。
String formatLyricOffset(int ms) {
  final s = ms / 1000.0;
  final sign = s > 0 ? '+' : '';
  return '$sign${s.toStringAsFixed(1)}s';
}

/// 歌词整体偏移设置弹窗（全屏歌词页顶栏 / 歌词设置页共用）。
///
/// - **作用域**：「当前歌曲」仅对正在播放的歌曲生效（覆盖全局），
///   「全局」对所有歌曲生效；默认选中「当前歌曲」；
/// - 滑杆范围 ±30s、步进 0.1s；拖动过程中通过 [onPreview] 实时预览
///   （只改内存不落盘），点「确定」才写入偏好；
/// - 点击上方显示的偏移数值可弹出手动输入框（单位秒，支持小数与负号）；
/// - 返回新的生效偏移（毫秒）；取消则恢复进入弹窗时的值。
class LyricOffsetDialog extends StatefulWidget {
  final String songPath;
  final String songTitle;
  final int globalMs;
  final int? songMs; // null = 无单曲覆盖
  final int effectiveMs;

  /// 实时预览回调（拖动滑杆时持续触发；取消时以原值回调一次）。
  final void Function(int previewMs) onPreview;

  const LyricOffsetDialog({
    super.key,
    required this.songPath,
    required this.songTitle,
    required this.globalMs,
    required this.songMs,
    required this.effectiveMs,
    required this.onPreview,
  });

  /// 弹出歌词偏移弹窗；返回新的生效偏移（毫秒），取消返回 null。
  static Future<int?> show(
    BuildContext context, {
    required String songPath,
    required String songTitle,
    required int globalMs,
    required int? songMs,
    required int effectiveMs,
    required void Function(int previewMs) onPreview,
  }) {
    return showDialog<int>(
      context: context,
      builder: (_) => LyricOffsetDialog(
        songPath: songPath,
        songTitle: songTitle,
        globalMs: globalMs,
        songMs: songMs,
        effectiveMs: effectiveMs,
        onPreview: onPreview,
      ),
    );
  }

  @override
  State<LyricOffsetDialog> createState() => _LyricOffsetDialogState();
}

class _LyricOffsetDialogState extends State<LyricOffsetDialog> {
  /// 0 = 当前歌曲，1 = 全局。
  late int _scope;

  /// 单曲覆盖（本地视图；清除后为 null，确认时落盘删除）。
  int? _songOverrideMs;

  /// 是否已点「清除本曲偏移」（尚未确认）。
  bool _clearSong = false;

  late double _valueSec;

  int get _minMs => PreferencesService.lyricOffsetMinMs;
  int get _maxMs => PreferencesService.lyricOffsetMaxMs;

  @override
  void initState() {
    super.initState();
    _songOverrideMs = widget.songMs;
    // 默认编辑「当前歌曲」：偏移多数场景是给某一首歌单独校准，
    // 「全局」作为进阶选项保留，需要时手动切换。
    _scope = 0;
    _valueSec = (_songOverrideMs ?? widget.globalMs) / 1000.0;
  }

  /// 当前作用域 + 滑杆值下，确认后将生效的偏移。
  int _effectiveFor(int scope, double valueSec) {
    final v = (valueSec * 1000).round().clamp(_minMs, _maxMs);
    if (scope == 0) return v; // 编辑本曲覆盖 → 立即成为生效值
    return _songOverrideMs ?? v; // 编辑全局 → 有覆盖则覆盖仍赢
  }

  void _onScopeChanged(int scope) {
    if (scope == _scope) return;
    setState(() {
      _scope = scope;
      // 切换作用域时把滑杆对齐到该作用域当前的值。
      _valueSec =
          (scope == 0
              ? (_songOverrideMs ?? widget.globalMs)
              : widget.globalMs) /
          1000.0;
    });
    widget.onPreview(_effectiveFor(_scope, _valueSec));
  }

  void _onSlider(double v) {
    setState(() {
      _valueSec = v;
      _clearSong = false; // 清除后又拖动 → 存为新覆盖值
    });
    widget.onPreview(_effectiveFor(_scope, v));
  }

  /// 点击偏移数值 → 弹出手动输入框（单位：秒，支持小数与负号）。
  ///
  /// 输入只改内存并与滑杆联动（经 [_onSlider] 走同一条预览链路），
  /// 仍由外层「确定」统一落盘；无法解析的输入按「不修改」关闭。
  Future<void> _showManualInput() async {
    final l10n = L10n.of(context);
    final controller = TextEditingController(
      text: _valueSec.toStringAsFixed(1),
    );
    final input = await showDialog<double>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Theme.of(ctx).scaffoldBackgroundColor,
        title: Text(
          l10n.lyric_offset_input_title,
          style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
        ),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: const TextInputType.numberWithOptions(
            decimal: true,
            signed: true,
          ),
          textInputAction: TextInputAction.done,
          decoration: InputDecoration(
            labelText: l10n.lyric_offset_input_hint,
            suffixText: 's',
          ),
          onSubmitted: (s) => Navigator.pop(ctx, _parseOffsetSec(s)),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(MaterialLocalizations.of(ctx).cancelButtonLabel),
          ),
          TextButton(
            onPressed: () =>
                Navigator.pop(ctx, _parseOffsetSec(controller.text)),
            child: Text(MaterialLocalizations.of(ctx).okButtonLabel),
          ),
        ],
      ),
    );
    controller.dispose();
    if (input == null || !mounted) return;
    final clamped = input.clamp(_minMs / 1000.0, _maxMs / 1000.0);
    // 与滑杆保持同一 0.1s 步进。
    _onSlider((clamped * 10).round() / 10);
  }

  /// 解析手动输入（秒）：兼容 `1.2` / `+1.2` / `-0.5` / `1.2s` / `1.2秒`；
  /// 无法解析时返回 null（调用方按「不修改」处理）。
  double? _parseOffsetSec(String raw) {
    var s = raw.trim();
    if (s.isEmpty) return null;
    s = s.replaceAll(RegExp(r'[sS秒]+$'), '').trim();
    if (s.startsWith('+')) s = s.substring(1);
    if (s.isEmpty) return null;
    return double.tryParse(s);
  }

  void _reset() {
    setState(() => _valueSec = 0);
    widget.onPreview(_effectiveFor(_scope, 0));
  }

  /// 清除本曲覆盖：滑杆回落到全局值，确认时删除单曲偏好。
  void _clearSongOffset() {
    setState(() {
      _clearSong = true;
      _songOverrideMs = null;
      _valueSec = widget.globalMs / 1000.0;
    });
    widget.onPreview(_effectiveFor(_scope, _valueSec));
  }

  Future<void> _confirm() async {
    final v = (_valueSec * 1000).round().clamp(_minMs, _maxMs);
    if (_scope == 0) {
      if (_clearSong) {
        await PreferencesService.removeLyricOffsetForSong(widget.songPath);
      } else {
        await PreferencesService.saveLyricOffsetForSong(widget.songPath, v);
      }
    } else {
      await PreferencesService.saveLyricOffsetGlobal(v);
    }
    if (!mounted) return;
    Navigator.pop(context, _effectiveFor(_scope, _valueSec));
  }

  void _cancel() {
    // 恢复进入弹窗时的生效值。
    widget.onPreview(widget.effectiveMs);
    Navigator.pop(context, null);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = L10n.of(context);
    final theme = Theme.of(context);
    final primary = theme.colorScheme.primary;
    final effective = _effectiveFor(_scope, _valueSec);
    final overridden = _scope == 1 && _songOverrideMs != null;

    return AlertDialog(
      backgroundColor: theme.scaffoldBackgroundColor,
      title: Text(
        l10n.lyric_offset,
        style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // 当前歌曲名（作用域「当前歌曲」的对象）
            Text(
              widget.songTitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12,
                color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
              ),
            ),
            const SizedBox(height: 12),
            // 作用域切换
            SegmentedButton<int>(
              segments: [
                ButtonSegment(
                  value: 0,
                  icon: const Icon(Icons.music_note_rounded, size: 16),
                  label: Text(l10n.lyric_offset_scope_current),
                ),
                ButtonSegment(
                  value: 1,
                  icon: const Icon(Icons.public_rounded, size: 16),
                  label: Text(l10n.lyric_offset_scope_global),
                ),
              ],
              selected: {_scope},
              onSelectionChanged: (s) => _onScopeChanged(s.first),
            ),
            const SizedBox(height: 8),
            // 偏移值（点击可手动输入）+ 滑杆
            Center(
              child: Tooltip(
                message: l10n.lyric_offset_input_title,
                child: InkWell(
                  borderRadius: BorderRadius.circular(10),
                  onTap: _showManualInput,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 6,
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          formatLyricOffset((_valueSec * 1000).round()),
                          style: TextStyle(
                            fontSize: 26,
                            fontWeight: FontWeight.w800,
                            color: primary,
                            fontFeatures: const [FontFeature.tabularFigures()],
                          ),
                        ),
                        const SizedBox(width: 6),
                        Icon(
                          Icons.edit_outlined,
                          size: 14,
                          color: primary.withValues(alpha: 0.55),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            Slider(
              value: _valueSec.clamp(_minMs / 1000.0, _maxMs / 1000.0),
              min: _minMs / 1000.0,
              max: _maxMs / 1000.0,
              divisions: (_maxMs - _minMs) ~/ 100,
              label: formatLyricOffset((_valueSec * 1000).round()),
              onChanged: _onSlider,
            ),
            // 生效值说明
            Text(
              '${l10n.lyric_offset_effective}: '
              '${formatLyricOffset(effective)}'
              '${overridden ? '（${l10n.lyric_offset_scope_current}）' : ''}',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 12,
                color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              l10n.lyric_offset_desc,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 11,
                color: theme.colorScheme.onSurface.withValues(alpha: 0.4),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: _reset, child: Text(l10n.lyric_offset_reset)),
        if (_scope == 0 && _songOverrideMs != null)
          TextButton(
            onPressed: _clearSongOffset,
            child: Text(l10n.lyric_offset_clear_current),
          ),
        TextButton(
          onPressed: _cancel,
          child: Text(MaterialLocalizations.of(context).cancelButtonLabel),
        ),
        FilledButton(
          onPressed: _confirm,
          child: Text(MaterialLocalizations.of(context).okButtonLabel),
        ),
      ],
    );
  }
}
