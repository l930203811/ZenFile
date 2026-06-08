import 'package:flutter/material.dart';
import '../../core/icon_fonts/broken_icons.dart';
import 'package:url_launcher/url_launcher.dart';

class RestrictedFolderBanner extends StatelessWidget {
  final VoidCallback onEnableRoot;
  final VoidCallback onEnableShizuku;
  final VoidCallback? onGoBack;
  final bool isRootAvailable;

  const RestrictedFolderBanner({
    super.key,
    required this.onEnableRoot,
    required this.onEnableShizuku,
    this.onGoBack,
    required this.isRootAvailable,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    final bgGradient = isDark
        ? const LinearGradient(colors: [Color(0xFF1E293B), Color(0xFF0F172A)])
        : LinearGradient(colors: [theme.colorScheme.primary.withOpacity(0.15), theme.colorScheme.primary.withOpacity(0.05)]);

    return Center(
      child: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Container(
            decoration: BoxDecoration(
              gradient: bgGradient,
              borderRadius: BorderRadius.circular(28),
              border: Border.all(color: theme.colorScheme.primary.withOpacity(0.3), width: 1.5),
              boxShadow: [
                BoxShadow(
                  color: theme.colorScheme.primary.withOpacity(0.15),
                  blurRadius: 24,
                  offset: const Offset(0, 10),
                ),
              ],
            ),
            padding: const EdgeInsets.symmetric(horizontal: 24.0, vertical: 32.0),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  padding: const EdgeInsets.all(20),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.primary.withOpacity(0.2),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(Broken.lock, size: 48, color: theme.colorScheme.primary),
                ),
                const SizedBox(height: 24),
                Text(
                  '受限系统文件夹',
                  style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.bold),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 12),
                Text(
                  'Android 11+ 限制了对 Android/data 和 Android/obb 文件夹的标准访问，以保护应用数据。要查看和修改这些文件，ZenFile 需要高级权限。',
                  style: TextStyle(fontSize: 14, color: theme.colorScheme.onSurface.withOpacity(0.8), height: 1.4),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 24),
                if (onGoBack != null)
                  ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: theme.colorScheme.surfaceVariant.withOpacity(0.3),
                      foregroundColor: theme.colorScheme.onSurface,
                      minimumSize: const Size.fromHeight(48),
                      elevation: 2,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
                    ),
                    icon: Icon(Broken.arrow_right_3, size: 20, color: theme.colorScheme.primary),
                    label: Text('返回上一级', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15, color: theme.colorScheme.primary)),
                    onPressed: onGoBack,
                  ),
                if (onGoBack != null) const SizedBox(height: 16),
                if (isRootAvailable) ...[
                  ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.redAccent,
                      foregroundColor: Colors.white,
                      minimumSize: const Size.fromHeight(54),
                      elevation: 6,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
                    ),
                    icon: const Icon(Broken.key, size: 24),
                    label: const Text('使用 Root 访问（超级用户）', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                    onPressed: onEnableRoot,
                  ),
                  const SizedBox(height: 16),
                ],
                ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: theme.colorScheme.primary,
                    foregroundColor: Colors.white,
                    minimumSize: const Size.fromHeight(54),
                    elevation: 6,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
                  ),
                  icon: const Icon(Broken.shield_tick, size: 24),
                  label: const Text('授予Shizuku访问权限（无需Root）', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                  onPressed: onEnableShizuku,
                ),
                const SizedBox(height: 20),
                TextButton.icon(
                  icon: Icon(Broken.info_circle, size: 18, color: theme.colorScheme.primary),
                  label: Text('如何设置Shizuku？', style: TextStyle(color: theme.colorScheme.primary, fontWeight: FontWeight.w600)),
                  onPressed: () async {
                    final url = Uri.parse('https://shizuku.rikka.app/guide/setup/');
                    try {
                      await launchUrl(url, mode: LaunchMode.externalApplication);
                    } catch (e) {
                      debugPrint('Could not launch url: $e');
                    }
                  },
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
