import 'package:flutter/material.dart';
import 'package:zenfile/l10n/generated/app_localizations.dart';

/// 保险箱帮助页。
///
/// 内容分区：功能亮点 / 基本操作 / 兼容性 / 原地加密（专章）/ 注意事项。
/// 全部文案走 l10n（key 前缀 `vault_help_`），10 种语言均已提供。
class VaultHelpScreen extends StatelessWidget {
  const VaultHelpScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = L10n.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.vault_help_title),
      ),
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: isDark
                ? [
                    const Color(0xFF0B0F19),
                    const Color(0xFF111827),
                    const Color(0xFF030712),
                  ]
                : [
                    theme.colorScheme.primaryContainer.withOpacity(0.25),
                    theme.colorScheme.surface,
                    theme.colorScheme.surface,
                  ],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
        ),
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 32),
          children: [
            _buildHero(theme, l10n),
            const SizedBox(height: 14),
            _Section(
              icon: Icons.star_border,
              accent: Colors.amber,
              title: l10n.vault_help_highlights,
              entries: [
                _Entry(l10n.vault_help_hl1_title, l10n.vault_help_hl1_desc),
                _Entry(l10n.vault_help_hl2_title, l10n.vault_help_hl2_desc),
                _Entry(l10n.vault_help_hl3_title, l10n.vault_help_hl3_desc),
              ],
            ),
            const SizedBox(height: 12),
            _Section(
              icon: Icons.list_alt,
              accent: Colors.teal,
              title: l10n.vault_help_basics,
              entries: [
                _Entry(l10n.vault_help_b1_title, l10n.vault_help_b1_desc),
                _Entry(l10n.vault_help_b2_title, l10n.vault_help_b2_desc),
                _Entry(l10n.vault_help_b3_title, l10n.vault_help_b3_desc),
                _Entry(l10n.vault_help_b4_title, l10n.vault_help_b4_desc),
                _Entry(l10n.vault_help_b5_title, l10n.vault_help_b5_desc),
              ],
            ),
            const SizedBox(height: 12),
            _Section(
              icon: Icons.link,
              accent: Colors.indigo,
              title: l10n.vault_help_compat,
              entries: [
                _Entry(l10n.vault_help_c1_title, l10n.vault_help_c1_desc),
                _Entry(l10n.vault_help_c2_title, l10n.vault_help_c2_desc),
                _Entry(l10n.vault_help_c3_title, l10n.vault_help_c3_desc),
              ],
            ),
            const SizedBox(height: 12),
            _Section(
              icon: Icons.lock_outline,
              accent: Colors.deepOrange,
              title: l10n.vault_help_inplace,
              intro: l10n.vault_help_inplace_intro,
              entries: [
                _Entry(l10n.vault_help_ip1_title, l10n.vault_help_ip1_desc),
                _Entry(l10n.vault_help_ip2_title, l10n.vault_help_ip2_desc),
                _Entry(l10n.vault_help_ip3_title, l10n.vault_help_ip3_desc),
                _Entry(l10n.vault_help_ip4_title, l10n.vault_help_ip4_desc),
              ],
            ),
            const SizedBox(height: 12),
            _Section(
              icon: Icons.info_outline,
              accent: Colors.redAccent,
              title: l10n.vault_help_notice,
              bullets: [
                l10n.vault_help_n1,
                l10n.vault_help_n2,
                l10n.vault_help_n3,
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHero(ThemeData theme, L10n l10n) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(18),
        color: theme.colorScheme.primary.withOpacity(0.08),
        border: Border.all(
          color: theme.colorScheme.primary.withOpacity(0.22),
          width: 1,
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: theme.colorScheme.primary.withOpacity(0.16),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(
              Icons.security,
              color: theme.colorScheme.primary,
              size: 26,
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Text(
              l10n.vault_help_intro,
              style: theme.textTheme.bodyMedium?.copyWith(
                height: 1.5,
                color: theme.colorScheme.onSurface.withOpacity(0.85),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 帮助条目：标题 + 说明
class _Entry {
  final String title;
  final String desc;
  const _Entry(this.title, this.desc);
}

/// 帮助页的一个分区卡片
class _Section extends StatelessWidget {
  final IconData icon;
  final Color accent;
  final String title;
  final String? intro;
  final List<_Entry> entries;
  final List<String> bullets;

  const _Section({
    required this.icon,
    required this.accent,
    required this.title,
    this.intro,
    this.entries = const [],
    this.bullets = const [],
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: theme.colorScheme.outline.withOpacity(0.18),
          width: 1,
        ),
        color: isDark
            ? Colors.white.withOpacity(0.03)
            : Colors.black.withOpacity(0.015),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, size: 20, color: accent),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    title,
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ],
            ),
            if (intro != null) ...[
              const SizedBox(height: 10),
              Text(
                intro!,
                style: theme.textTheme.bodyMedium?.copyWith(
                  height: 1.5,
                  color: theme.colorScheme.onSurface.withOpacity(0.8),
                ),
              ),
            ],
            const SizedBox(height: 6),
            ...entries.map(
              (e) => Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      e.title,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                        color: accent,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      e.desc,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        height: 1.45,
                        fontSize: 13.5,
                        color: theme.colorScheme.onSurface.withOpacity(0.75),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            ...bullets.map(
              (b) => Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Icon(
                        Icons.circle,
                        size: 6,
                        color: accent.withOpacity(0.9),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        b,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          height: 1.45,
                          fontSize: 13.5,
                          color: theme.colorScheme.onSurface.withOpacity(0.78),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
