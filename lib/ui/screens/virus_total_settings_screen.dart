import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:zenfile/l10n/generated/app_localizations.dart';
import '../../services/virus_total_service.dart';
import '../../core/icon_fonts/broken_icons.dart';

/// APK 安装安全扫描设置页：功能说明 + API Key 配置 + 详细获取指引。
class VirusTotalSettingsScreen extends StatefulWidget {
  const VirusTotalSettingsScreen({super.key});

  @override
  State<VirusTotalSettingsScreen> createState() => _VirusTotalSettingsScreenState();
}

class _VirusTotalSettingsScreenState extends State<VirusTotalSettingsScreen> {
  late TextEditingController _controller;
  bool _obscure = true;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: VirusTotalService.getApiKey() ?? '');
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final key = _controller.text.trim();
    if (key.isEmpty) return;
    setState(() => _saving = true);
    final valid = await VirusTotalService.validateApiKey(key);
    if (!mounted) return;
    setState(() => _saving = false);
    if (!valid) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(L10n.of(context).vt_key_invalid)),
      );
      return;
    }
    await VirusTotalService.saveApiKey(key);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(L10n.of(context).vt_key_saved)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = L10n.of(context);
    final currentKey = VirusTotalService.getApiKey();
    final configured = currentKey != null && currentKey.isNotEmpty;

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.vt_settings_title),
        leading: IconButton(
          icon: const Icon(Broken.arrow_left),
          onPressed: () => Navigator.pop(context),
        ),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            _card(theme, [
              Text(
                l10n.vt_what_is_title,
                style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              Text(
                l10n.vt_what_is_desc,
                style: TextStyle(
                  fontSize: 13,
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.7),
                  height: 1.5,
                ),
              ),
            ]),
            const SizedBox(height: 16),
            _card(theme, [
              Text(
                l10n.vt_api_key_label,
                style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 4),
              Text(
                configured ? l10n.vt_current_key_configured : l10n.vt_not_configured,
                style: TextStyle(
                  fontSize: 12,
                  color: configured
                      ? const Color(0xFF52C41A)
                      : theme.colorScheme.onSurface.withValues(alpha: 0.5),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _controller,
                obscureText: _obscure,
                autocorrect: false,
                enableSuggestions: false,
                maxLines: 1,
                decoration: InputDecoration(
                  hintText: l10n.vt_api_key_hint,
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                  suffixIcon: IconButton(
                    icon: Icon(_obscure ? Icons.visibility_off : Icons.visibility),
                    onPressed: () => setState(() => _obscure = !_obscure),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: _saving ? null : _save,
                  child: _saving
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Text(l10n.vt_save_key),
                ),
              ),
            ]),
            const SizedBox(height: 16),
            _card(theme, [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      l10n.vt_how_to_get_title,
                      style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
                    ),
                  ),
                  TextButton.icon(
                    onPressed: () => launchUrl(
                      Uri.parse('https://www.virustotal.com'),
                      mode: LaunchMode.externalApplication,
                    ),
                    icon: const Icon(Icons.open_in_new, size: 16),
                    label: Text(l10n.vt_open_vt, style: const TextStyle(fontSize: 12)),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              _step(l10n.vt_step_1),
              _step(l10n.vt_step_2),
              _step(l10n.vt_step_3),
              _step(l10n.vt_step_4),
              _step(l10n.vt_step_5),
            ]),
            const SizedBox(height: 16),
            _card(theme, [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(Icons.info_outline, size: 18, color: Color(0xFF8BC8EA)),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      l10n.vt_limit_note,
                      style: TextStyle(
                        fontSize: 12,
                        color: theme.colorScheme.onSurface.withValues(alpha: 0.7),
                        height: 1.5,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(Icons.lock_outline, size: 18, color: Color(0xFF8BC8EA)),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      l10n.vt_privacy_note,
                      style: TextStyle(
                        fontSize: 12,
                        color: theme.colorScheme.onSurface.withValues(alpha: 0.7),
                        height: 1.5,
                      ),
                    ),
                  ),
                ],
              ),
            ]),
          ],
        ),
      ),
    );
  }

  Widget _card(ThemeData theme, List<Widget> children) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: theme.colorScheme.outline.withValues(alpha: 0.1)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: children),
    );
  }

  Widget _step(String text) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.check_circle_outline, size: 16, color: Color(0xFF52C41A)),
          const SizedBox(width: 8),
          Expanded(
            child: Text(text, style: const TextStyle(fontSize: 13, height: 1.5)),
          ),
        ],
      ),
    );
  }
}
