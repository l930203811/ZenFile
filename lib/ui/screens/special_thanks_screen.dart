import 'package:flutter/material.dart';
import 'package:zenfile/l10n/generated/app_localizations.dart';

/// 「特别鸣谢」页。
///
/// 昵称是**原文照录**的身份信息（打赏者/反馈者的名字），刻意**不进 l10n**；
/// 只有标题与各节说明文字走多语言（见 arb 的 `ui_special_thanks_*` /
/// `thanks_*` 系列 key）。
class SpecialThanksScreen extends StatelessWidget {
  const SpecialThanksScreen({super.key});

  /// 打赏者（按致谢顺序，原文照录）。
  static const List<String> _donors = [
    '𝗖𝗵𝗲𝗻𝗴𝗵𝘂𝗮',
    '被窝一级避难所',
    '季风',
    '从前有座山',
    '羁客',
    '无处安放',
    '你没急吧',
  ];

  /// 应用内（Telegram/QQ 群等）提供建议与反馈的用户。
  static const List<String> _inAppFeedback = [
    '𝗖𝗵𝗲𝗻𝗴𝗵𝘂𝗮',
    '越界',
    'YC影尘',
    '猕猴桃',
    '大手拉小手',
    '小熊猫[自重率0%]',
    'SAS',
    'Dr. Homi J. Bhabha',
    'sky',
    'Aps',
    'Oxlne',
    'Jankst',
  ];

  /// 通过 GitHub Issues 反馈、其建议已被采纳的用户（对应 issue 均已实现/修复）。
  static const List<String> _githubFeedback = [
    'KamrulShahed',
    '0xlne',
    'SASlobby93',
    'aand1015',
    'LorianL98',
    'qwertti123',
  ];

  /// 本项目使用的核心开源组件（排名不分先后）。
  static const List<String> _openSource = [
    'Senzme/NFile — 本项目的 fork 起点',
    'media_kit (mpv) — 音视频播放引擎',
    'audio_service — 后台播放与系统媒体会话',
    'on_audio_query — 媒体库查询',
    'dartssh2 — SFTP 协议实现',
    'cronet_http — 网络传输',
    'Syncfusion — PDF / Office 文档渲染',
    'flutter_secure_storage — 凭据安全存储',
    'audioMotion-analyzer — 音频频谱可视化算法参考 (AGPL-3.0)',
    '腾讯 Bugly — 崩溃统计',
  ];

  @override
  Widget build(BuildContext context) {
    final l10n = L10n.of(context);
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(
          l10n.ui_special_thanks_title,
          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
        children: [
          _section(
            context,
            title: l10n.thanks_donors_section,
            note: l10n.thanks_donors_note,
            names: _donors,
            highlight: true,
          ),
          _section(
            context,
            title: l10n.thanks_author_section,
            note: l10n.thanks_author_note,
            names: const ['Senzme (github.com/Senzme/NFile)'],
          ),
          _section(
            context,
            title: l10n.thanks_opensource_section,
            note: l10n.thanks_opensource_note,
            bulletItems: _openSource,
          ),
          _section(
            context,
            title: l10n.thanks_feedback_section,
            note: l10n.thanks_feedback_note,
            names: _inAppFeedback,
          ),
          Padding(
            padding: const EdgeInsets.only(top: 6, bottom: 12),
            child: Text(
              l10n.thanks_github_note,
              style: TextStyle(
                fontSize: 12.5,
                height: 1.5,
                color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
              ),
            ),
          ),
          _nameChips(context, _githubFeedback),
        ],
      ),
    );
  }

  Widget _section(
    BuildContext context, {
    required String title,
    required String note,
    List<String>? names,
    List<String>? bulletItems,
    bool highlight = false,
  }) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: TextStyle(
              fontSize: 16.5,
              fontWeight: FontWeight.w800,
              color: highlight
                  ? theme.colorScheme.primary
                  : theme.colorScheme.onSurface,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            note,
            style: TextStyle(
              fontSize: 12.5,
              height: 1.55,
              color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
            ),
          ),
          const SizedBox(height: 10),
          if (names != null) _nameChips(context, names, highlight: highlight),
          if (bulletItems != null)
            ...bulletItems.map(
              (item) => Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(top: 7),
                      child: Text(
                        '·',
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w900,
                          color: theme.colorScheme.primary,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        item,
                        style: TextStyle(
                          fontSize: 13.5,
                          height: 1.5,
                          color: theme.colorScheme.onSurface.withValues(
                            alpha: 0.85,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// 昵称标签流式布局（圆角底色块，不可点击 —— 仅致谢展示）。
  Widget _nameChips(BuildContext context, List<String> names,
      {bool highlight = false}) {
    final theme = Theme.of(context);
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: names
          .map(
            (name) => Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
              decoration: BoxDecoration(
                color: highlight
                    ? theme.colorScheme.primary.withValues(alpha: 0.10)
                    : theme.colorScheme.onSurface.withValues(alpha: 0.06),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                name,
                style: TextStyle(
                  fontSize: 13.5,
                  fontWeight: FontWeight.w600,
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.9),
                ),
              ),
            ),
          )
          .toList(),
    );
  }
}
