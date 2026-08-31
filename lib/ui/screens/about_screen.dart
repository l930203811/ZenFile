import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:share_plus/share_plus.dart';
import '../../core/icon_fonts/broken_icons.dart';
import 'package:zenfile/l10n/generated/app_localizations.dart';

class AboutZenFileScreen extends StatelessWidget {
  const AboutZenFileScreen({super.key});

  Future<void> _launchUrl(BuildContext context, String urlString) async {
    final Uri url = Uri.parse(urlString);
    try {
      if (!await launchUrl(url, mode: LaunchMode.externalApplication)) {
        throw Exception(L10n.of(context).url);
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('无法打开链接：{urlString}')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    // AMOLED or normal backgrounds
    final scaffoldBg = theme.scaffoldBackgroundColor;
    final cardBg = isDark
        ? Colors.white.withOpacity(0.04)
        : Colors.black.withOpacity(0.03);
    final borderCol = isDark
        ? Colors.white.withOpacity(0.08)
        : Colors.black.withOpacity(0.08);

    return Scaffold(
      backgroundColor: scaffoldBg,
      body: CustomScrollView(
        physics: const BouncingScrollPhysics(),
        slivers: [
          // Elegant transparent App Bar
          SliverAppBar(
            expandedHeight: 120,
            floating: false,
            pinned: true,
            elevation: 0,
            backgroundColor: scaffoldBg.withOpacity(0.9),
            iconTheme: IconThemeData(color: theme.colorScheme.onSurface),
            flexibleSpace: FlexibleSpaceBar(
              centerTitle: true,
              title: Text(
                L10n.of(context).zenfile1,
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 20,
                  color: theme.colorScheme.onSurface,
                  fontFamily: 'LexendDeca',
                  letterSpacing: 0.5,
                ),
              ),
            ),
          ),

          // Scrollable content
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20.0, vertical: 10.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  // ── Beautiful App Icon with Double Ring Glowing Gradients ──
                  Stack(
                    alignment: Alignment.center,
                    children: [
                      // Outer soft glowing ring
                      Container(
                        width: 130,
                        height: 130,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          gradient: LinearGradient(
                            colors: [
                              theme.colorScheme.primary.withOpacity(0.2),
                              theme.colorScheme.secondary.withOpacity(0.0),
                            ],
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                          ),
                        ),
                      ),
                      // Middle ring gradient
                      Container(
                        width: 110,
                        height: 110,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          gradient: LinearGradient(
                            colors: [
                              theme.colorScheme.primary.withOpacity(0.4),
                              theme.colorScheme.secondary.withOpacity(0.1),
                            ],
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                          ),
                        ),
                      ),
                      // Inner content container showing App Icon
                      Container(
                        width: 90,
                        height: 90,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: isDark ? const Color(0xFF121212) : Colors.white,
                          border: Border.all(color: theme.colorScheme.primary.withOpacity(0.4), width: 2),
                          boxShadow: [
                            BoxShadow(
                              color: theme.colorScheme.primary.withOpacity(0.25),
                              blurRadius: 20,
                              offset: const Offset(0, 8),
                            )
                          ],
                        ),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(45),
                          child: Padding(
                            padding: const EdgeInsets.all(12.0),
                            child: Image.asset(
                              'assets/logo/zf_Classic1.png',
                              fit: BoxFit.contain,
                              errorBuilder: (context, error, stackTrace) {
                                // Fallback icon in case asset load fails
                                return Icon(
                                  Broken.folder_open,
                                  color: theme.colorScheme.primary,
                                  size: 40,
                                );
                              },
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 20),

                  // ── App Title & Dynamic Badges ──
                  Text(
                    'ZenFile',
                    style: theme.textTheme.headlineMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                      letterSpacing: 0.8,
                      fontFamily: 'LexendDeca',
                    ),
                  ),
                  const SizedBox(height: 6),
                  // 版本号文本（硬编码，无需 l10n；以后升级版本只改这里）
                  Text(
                    'v1.1.37',
                    style: TextStyle(
                      color: theme.colorScheme.onSurface.withOpacity(0.7),
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      fontFamily: 'LexendDeca',
                      letterSpacing: 0.3,
                    ),
                  ),
                  const SizedBox(height: 10),
                  // 「查看更新」按钮（独立可点击，文字走 l10n）
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.primary.withOpacity(0.12),
                      borderRadius: BorderRadius.circular(30),
                      border: Border.all(color: theme.colorScheme.primary.withOpacity(0.2)),
                    ),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(30),
                      onTap: () => _showChangelog(context, theme),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            L10n.of(context).ui_view_update,
                            style: TextStyle(
                              color: theme.colorScheme.primary,
                              fontSize: 12.5,
                              fontWeight: FontWeight.bold,
                              fontFamily: 'LexendDeca',
                            ),
                          ),
                          const SizedBox(width: 6),
                          Icon(Icons.arrow_forward_ios, size: 10, color: theme.colorScheme.primary.withOpacity(0.6)),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 24),

                  // ── Description Card ──
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(20),
                    decoration: BoxDecoration(
                      color: cardBg,
                      borderRadius: BorderRadius.circular(24),
                      border: Border.all(color: borderCol),
                    ),
                    child: Text(
                      L10n.of(context).zenfileflutter,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: theme.colorScheme.onSurface.withOpacity(0.85),
                        fontSize: 14.5,
                        height: 1.5,
                        fontWeight: FontWeight.w400,
                      ),
                    ),
                  ),
                  const SizedBox(height: 28),

                  // ── Beautiful Features Grid ──
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Padding(
                      padding: const EdgeInsets.only(left: 4.0),
                      child: Text(
                        L10n.of(context).msg30d17f96,
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                          color: theme.colorScheme.primary,
                          fontFamily: 'LexendDeca',
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),

                  GridView.count(
                    crossAxisCount: 2,
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    crossAxisSpacing: 14,
                    mainAxisSpacing: 14,
                    childAspectRatio: 1.3,
                    children: [
                      _buildFeatureTile(
                        context,
                        icon: Broken.flash,
                        title: L10n.of(context).msga12ebf50,
                        subtitle: L10n.of(context).msgfccb5a01,
                      ),
                      _buildFeatureTile(
                        context,
                        icon: Broken.lock,
                        title: L10n.of(context).msgaba638c4,
                        subtitle: L10n.of(context).msg6d8fbdac,
                      ),
                      _buildFeatureTile(
                        context,
                        icon: Broken.wifi_square,
                        title: L10n.of(context).msgd309e9ea,
                        subtitle: L10n.of(context).ftpsftpwebdav,
                      ),
                      _buildFeatureTile(
                        context,
                        icon: Broken.magicpen,
                        title: L10n.of(context).msge8f352b9,
                        subtitle: L10n.of(context).amoled,
                      ),
                    ],
                  ),
                  const SizedBox(height: 32),

                  // ── Socials / Actions Section ──
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Padding(
                      padding: const EdgeInsets.only(left: 4.0),
                      child: Text(
                        L10n.of(context).msg4a5f936c,
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                          color: theme.colorScheme.primary,
                          fontFamily: 'LexendDeca',
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),

                  _buildSocialAction(
                    context,
                    icon: Broken.magic_star,
                    label: L10n.of(context).msge8069659,
                    onTap: () => _launchUrl(context, 'https://github.com/l930203811/ZenFile'),
                  ),
                  const SizedBox(height: 10),
                  _buildSocialAction(
                    context,
                    icon: Icons.send_rounded,
                    label: L10n.of(context).telegram,
                    onTap: () => _launchUrl(context, 'https://t.me/+47n76Au6mhg0MDA1'),
                  ),
                  const SizedBox(height: 10),
                  _buildSocialAction(
                    context,
                    icon: Broken.send,
                    label: L10n.of(context).msg5f84adea,
                    onTap: () {
                      Share.share(
                        L10n.of(context).zenfilehttpsgithubcoml930203811zenfilereleases,
                        subject: L10n.of(context).msg4d48a010,
                      );
                    },
                  ),
                  const SizedBox(height: 10),
                  _buildSocialAction(
                    context,
                    icon: Icons.code_rounded,
                    label: L10n.of(context).github,
                    onTap: () => _launchUrl(context, 'https://github.com/l930203811/ZenFile'),
                  ),
                  const SizedBox(height: 10),
                  _buildSocialAction(
                    context,
                    icon: Icons.email_rounded,
                    label: L10n.of(context).sequeldpdnsorg,
                    onTap: () {},
                    onLongPress: () {
                      Clipboard.setData(const ClipboardData(text: '1@sequel.dpdns.org'));
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('邮箱已复制到剪贴板'),
                          behavior: SnackBarBehavior.floating,
                        ),
                      );
                    },
                  ),
                  const SizedBox(height: 10),
                  _buildSocialAction(
                    context,
                    icon: Icons.group_rounded,
                    label: 'QQ 群：792408214',
                    onTap: () {},
                    onLongPress: () {
                      Clipboard.setData(const ClipboardData(text: '792408214'));
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('QQ 群号已复制到剪贴板'),
                          behavior: SnackBarBehavior.floating,
                        ),
                      );
                    },
                  ),
                  const SizedBox(height: 10),
                  _buildSocialAction(
                    context,
                    icon: Icons.favorite_rounded,
                    label: L10n.of(context).msg1f4c0192,
                    onTap: () => _showDonationDialog(context, theme),
                  ),

                  const SizedBox(height: 48),

                  // ── Elegant Footer Tribute ──
                  Text(
                    L10n.of(context).bysequel,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: theme.colorScheme.onSurface.withOpacity(0.5),
                      fontFamily: 'LexendDeca',
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    L10n.of(context).based_on_nfile,
                    style: TextStyle(
                      fontSize: 11,
                      color: theme.colorScheme.onSurface.withOpacity(0.35),
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    L10n.of(context).zenfile2,
                    style: TextStyle(
                      fontSize: 11,
                      color: theme.colorScheme.onSurface.withOpacity(0.35),
                    ),
                  ),
                  const SizedBox(height: 40),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFeatureTile(
    BuildContext context, {
    required IconData icon,
    required String title,
    required String subtitle,
  }) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final cardBg = isDark
        ? Colors.white.withOpacity(0.03)
        : Colors.black.withOpacity(0.02);
    final borderCol = isDark
        ? Colors.white.withOpacity(0.06)
        : Colors.black.withOpacity(0.06);

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: cardBg,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: borderCol),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, color: theme.colorScheme.primary, size: 24),
          const SizedBox(height: 10),
          Text(
            title,
            style: const TextStyle(
              fontSize: 13.5,
              fontWeight: FontWeight.bold,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 2),
          Text(
            subtitle,
            style: TextStyle(
              fontSize: 10.5,
              color: theme.colorScheme.onSurface.withOpacity(0.5),
            ),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }

  Widget _buildSocialAction(
    BuildContext context, {
    required IconData icon,
    required String label,
    required VoidCallback onTap,
    VoidCallback? onLongPress,
  }) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final cardBg = isDark
        ? Colors.white.withOpacity(0.03)
        : Colors.black.withOpacity(0.02);
    final borderCol = isDark
        ? Colors.white.withOpacity(0.06)
        : Colors.black.withOpacity(0.06);

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        borderRadius: BorderRadius.circular(16),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          decoration: BoxDecoration(
            color: cardBg,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: borderCol),
          ),
          child: Row(
            children: [
              Icon(icon, color: theme.colorScheme.primary, size: 20),
              const SizedBox(width: 14),
              Expanded(
                child: Text(
                  label,
                  style: const TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              Icon(
                Icons.arrow_forward_ios_rounded,
                size: 14,
                color: theme.colorScheme.onSurface.withOpacity(0.3),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showDonationDialog(BuildContext context, ThemeData theme) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: theme.scaffoldBackgroundColor,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (ctx) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Center(
                  child: Container(width: 40, height: 4, margin: const EdgeInsets.only(bottom: 16), decoration: BoxDecoration(color: Colors.grey.withOpacity(0.3), borderRadius: BorderRadius.circular(2))),
                ),
                Text(L10n.of(context).msg2eceaa85, style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold)),
                const SizedBox(height: 8),
                Text(
                  L10n.of(context).msg138d3725,
                  style: TextStyle(fontSize: 13, color: theme.colorScheme.onSurface.withOpacity(0.6)),
                ),
                const SizedBox(height: 24),
                Row(
                  children: [
                    Expanded(
                      child: Column(
                        children: [
                          InkWell(
                            onTap: () => _showImagePreview(context, theme, 'assets/screenshots/zfb.png'),
                            onLongPress: () => _saveImageToGallery(context, 'assets/screenshots/zfb.png'),
                            borderRadius: BorderRadius.circular(12),
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(12),
                              child: Image.asset(
                                'assets/screenshots/zfb.png',
                                height: 180,
                                fit: BoxFit.contain,
                                errorBuilder: (context, error, stackTrace) {
                                  return Container(
                                    height: 180,
                                    decoration: BoxDecoration(
                                      color: theme.colorScheme.surfaceVariant.withOpacity(0.3),
                                      borderRadius: BorderRadius.circular(12),
                                    ),
                                    child: const Center(child: Icon(Icons.qr_code, size: 48)),
                                  );
                                },
                              ),
                            ),
                          ),
                          const SizedBox(height: 8),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(Icons.payment, size: 16, color: theme.colorScheme.primary),
                              const SizedBox(width: 6),
                              Text(L10n.of(context).msgccd097a7, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: theme.colorScheme.onSurface.withOpacity(0.85))),
                            ],
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        children: [
                          InkWell(
                            onTap: () => _showImagePreview(context, theme, 'assets/screenshots/wx.png'),
                            onLongPress: () => _saveImageToGallery(context, 'assets/screenshots/wx.png'),
                            borderRadius: BorderRadius.circular(12),
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(12),
                              child: Image.asset(
                                'assets/screenshots/wx.png',
                                height: 180,
                                fit: BoxFit.contain,
                                errorBuilder: (context, error, stackTrace) {
                                  return Container(
                                    height: 180,
                                    decoration: BoxDecoration(
                                      color: theme.colorScheme.surfaceVariant.withOpacity(0.3),
                                      borderRadius: BorderRadius.circular(12),
                                    ),
                                    child: const Center(child: Icon(Icons.qr_code, size: 48)),
                                  );
                                },
                              ),
                            ),
                          ),
                          const SizedBox(height: 8),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(Icons.chat_bubble_outline, size: 16, color: theme.colorScheme.primary),
                              const SizedBox(width: 6),
                              Text(L10n.of(context).msgbffe28c8, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: theme.colorScheme.onSurface.withOpacity(0.85))),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 20),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.primary.withOpacity(0.06),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: theme.colorScheme.primary.withOpacity(0.12)),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.favorite_rounded, size: 16, color: theme.colorScheme.primary.withOpacity(0.7)),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          L10n.of(context).msg0537b04e,
                          style: TextStyle(fontSize: 12.5, height: 1.4, color: theme.colorScheme.onSurface.withOpacity(0.65)),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 24),
              ],
            ),
          ),
        );
      },
    );
  }

  void _showChangelog(BuildContext context, ThemeData theme) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: theme.scaffoldBackgroundColor,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (ctx) {
        return DraggableScrollableSheet(
          initialChildSize: 0.6,
          minChildSize: 0.4,
          maxChildSize: 0.9,
          expand: false,
          builder: (ctx, scrollController) {
            return SingleChildScrollView(
              controller: scrollController,
              physics: const BouncingScrollPhysics(),
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Center(
                    child: Container(width: 40, height: 4, margin: const EdgeInsets.only(bottom: 16), decoration: BoxDecoration(color: Colors.grey.withOpacity(0.3), borderRadius: BorderRadius.circular(2))),
                  ),
                  Text(L10n.of(context).ui_download_links, style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold)),
                  const SizedBox(height: 20),

                  // ── 下载链接（置顶）──
                  Container(
                    margin: const EdgeInsets.only(bottom: 20),
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: [
                          theme.colorScheme.primary.withOpacity(0.08),
                          theme.colorScheme.secondary.withOpacity(0.04),
                        ],
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                      ),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: theme.colorScheme.primary.withOpacity(0.15)),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Icon(Icons.download_rounded, size: 18, color: theme.colorScheme.primary),
                            const SizedBox(width: 8),
                            Text(L10n.of(context).zenfilev1041, style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: theme.colorScheme.onSurface.withOpacity(0.9))),
                          ],
                        ),
                        const SizedBox(height: 12),
                        _buildDownloadLink(ctx, theme, L10n.of(context).msg9d287020, 'https://1820255615.share.123pan.cn/123pan/WrRojv-JHpnA?pwd=hBR2', Icons.cloud_outlined),
                        const SizedBox(height: 8),
                        _buildDownloadLink(ctx, theme, L10n.of(context).msgb2b41b6a, 'https://115cdn.com/s/swsho4j3hc6?password=m490', Icons.cloud_queue),
                        const SizedBox(height: 8),
                        _buildDownloadLink(ctx, theme, L10n.of(context).msg77ee718b, 'https://pan.baidu.com/s/1kYSfzTriRXwQPRL_c5Awig?pwd=xg94', Icons.cloud_circle),
                        const SizedBox(height: 8),
                        _buildDownloadLink(ctx, theme, L10n.of(context).msgbff1432a, 'https://pan.quark.cn/s/e6081a88d463', Icons.cloud),
                        const SizedBox(height: 8),
                        _buildDownloadLink(ctx, theme, L10n.of(context).msge03395d0, 'https://mypikpak.com/s/VOxGdQB3fVNO32sq_I3o2Wkmo2', Icons.flight),
                      ],
                    ),
                  ),

                  // ── 更新日志标题 ──
                  Text(L10n.of(context).msg305734ce, style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold)),
                  const SizedBox(height: 16),

                  _buildV1137Changelog(ctx, theme),
                  const SizedBox(height: 40),
                ],
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildV1133Changelog(BuildContext ctx, ThemeData theme) {
    final l10n = L10n.of(ctx);
    final textStyle = TextStyle(fontSize: 13.5, height: 1.6, color: theme.colorScheme.onSurface.withOpacity(0.85));
    final sectionStyle = TextStyle(fontSize: 13.5, height: 1.6, color: theme.colorScheme.primary, fontWeight: FontWeight.w600);

    Widget gap([double h = 6]) => SizedBox(height: h);
    Widget bulletText(String text) => Text('· $text', style: textStyle);

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceVariant.withOpacity(0.3),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: theme.colorScheme.onSurface.withOpacity(0.06)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: theme.colorScheme.primary.withOpacity(0.12),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text('v1.1.33', style: TextStyle(color: theme.colorScheme.primary, fontSize: 13, fontWeight: FontWeight.bold, fontFamily: 'LexendDeca')),
              ),
              const SizedBox(width: 10),
              Text('2026-08-26', style: TextStyle(fontSize: 12, color: theme.colorScheme.onSurface.withOpacity(0.4))),
            ],
          ),
          gap(14),

          // ── 新增 ──
          Text(l10n.changelog_section_new, style: sectionStyle),
          gap(4),
          bulletText(l10n.changelog_v1133_new_1),
          gap(6),
          bulletText(l10n.changelog_v1133_new_2),
          gap(6),
          bulletText(l10n.changelog_v1133_new_3),
          gap(6),
          bulletText(l10n.changelog_v1133_new_4),
          gap(6),
          bulletText(l10n.changelog_v1133_new_5),
          gap(6),
          bulletText(l10n.changelog_v1133_new_6),
          gap(6),
          bulletText(l10n.changelog_v1133_new_7),
          gap(6),
          bulletText(l10n.changelog_v1133_new_8),
          gap(14),

          // ── 优化 ──
          Text(l10n.changelog_section_optimizations, style: sectionStyle),
          gap(4),
          bulletText(l10n.changelog_v1133_opt_1),
          gap(6),
          bulletText(l10n.changelog_v1133_opt_2),
          gap(6),
          bulletText(l10n.changelog_v1133_opt_3),
          gap(6),
          bulletText(l10n.changelog_v1133_opt_4),
          gap(6),
          bulletText(l10n.changelog_v1133_opt_5),
          gap(6),
          bulletText(l10n.changelog_v1133_opt_6),
          gap(14),

          // ── 问题修复 ──
          Text(l10n.changelog_section_fixes, style: sectionStyle),
          gap(4),
          bulletText(l10n.changelog_v1133_fix_1),
          gap(6),
          bulletText(l10n.changelog_v1133_fix_2),
          gap(6),
          bulletText(l10n.changelog_v1133_fix_3),
          gap(6),
          bulletText(l10n.changelog_v1133_fix_4),
          gap(6),
          bulletText(l10n.changelog_v1133_fix_5),
        ],
      ),
    );
  }

  Widget _buildV1137Changelog(BuildContext ctx, ThemeData theme) {
    final textStyle = TextStyle(fontSize: 13.5, height: 1.6, color: theme.colorScheme.onSurface.withOpacity(0.85));
    final enStyle = TextStyle(fontSize: 12, height: 1.5, color: theme.colorScheme.onSurface.withOpacity(0.5));
    final sectionStyle = TextStyle(fontSize: 14, height: 1.6, color: theme.colorScheme.primary, fontWeight: FontWeight.w700);

    Widget gap([double h = 6]) => SizedBox(height: h);
    // 双语条目：中文在上，英文在下
    Widget zhEn(String zh, String en) => Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('· $zh', style: textStyle),
          const SizedBox(height: 2),
          Text('  $en', style: enStyle),
        ],
      ),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // ── 1.1.37 当前版本 ──
        Container(
          margin: const EdgeInsets.only(bottom: 8),
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceVariant.withOpacity(0.3),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: theme.colorScheme.onSurface.withOpacity(0.06)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.primary.withOpacity(0.12),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text('v1.1.37', style: TextStyle(color: theme.colorScheme.primary, fontSize: 13, fontWeight: FontWeight.bold, fontFamily: 'LexendDeca')),
                  ),
                  const SizedBox(width: 10),
                  Text('2026-08-31', style: TextStyle(fontSize: 12, color: theme.colorScheme.onSurface.withOpacity(0.4))),
                ],
              ),
              gap(14),

              Text('🐛 问题修复 · Bug Fixes', style: sectionStyle),
              gap(6),
              zhEn(
                '远程媒体播放卡顿 / 拖动进度条跳回原点：重构本地 HTTP 流式代理的 seek 缓存与分块填充，修复非零偏移区域读取 bug；拖动后首字节延迟由整段 24MB 降为首个分块，SFTP/SMB/FTP 拖动不再跳回原点。',
                'Remote media playback stutter / seek jumps to start: rebuilt the local HTTP streaming proxy seek cache and chunked prefetch; fixed a non-zero-region read offset bug; first-byte latency dropped from the whole 24 MB segment to the first chunk, so dragging no longer jumps back on SFTP/SMB/FTP.',
              ),
              zhEn(
                'SFTP 上传限速约 2MB/s：升级 JSch 0.1.55 → 2.28.7 以支持 rsa-sha2/ED25519/OpenSSH-v1 密钥，避免静默回退到纯 Dart 的 dartssh2（限速根因）；setBulkRequests(128) 提升在途请求数。',
                'SFTP upload capped at ~2MB/s: upgraded JSch 0.1.55 to 2.28.7 to support rsa-sha2/ED25519/OpenSSH-v1 keys, eliminating the silent fallback to the pure-Dart dartssh2 (root cause of the cap); setBulkRequests(128) raises in-flight requests.',
              ),
              zhEn(
                'SFTP 符号链接目录（如 /sdcard）识别：列表时跟随符号链接真实目标类型，目录可正常进入。',
                "SFTP symlink directory (e.g. /sdcard) recognition: follow the symlink's real target type on listing so directories can be entered normally.",
              ),
              zhEn(
                '编译错误（进度最小化状态机）：字段初始化器引用实例方法导致编译失败，改为构造函数体内赋值并放宽 final。',
                'Compile error (progress-minimize state machine): a field initializer referencing an instance method failed to compile; moved the assignment into the constructor body and relaxed final.',
              ),
              gap(14),

              Text('✨ 新功能 / 功能优化 · New Features / Improvements', style: sectionStyle),
              gap(6),
              zhEn(
                '双窗口激活窗口顶部高亮：激活窗口的整个顶部状态栏高亮（primary 背景 + 2.5px 高亮边），更易识别。',
                'Split-pane active window top highlight: the entire top status bar of the active pane is highlighted (primary background + 2.5px accent edge) for clearer identification.',
              ),
              zhEn(
                '进度后台最小化为浮窗：复制/剪切与分类页备份进度点「后台」后，在状态栏/工具栏显示可点击的圆形浮窗按钮（带旋转进度环），点击重开进度页；传输完成/取消后自动消失。',
                'Progress minimized to floating widget: after tapping "background" on copy/move or category backup progress, a clickable circular floating button (spinning progress ring) appears in the status/tool bar; tap to reopen the progress page; it auto-dismisses when transfer completes/cancels.',
              ),
              zhEn(
                '远程 Tab 云图标：远程浏览页 Tab 左侧图标直接用云图标替换原文件夹图标，本地 Tab 仍为文件夹图标。',
                'Remote tab cloud icon: the left icon of a remote tab is now a cloud icon replacing the folder icon; local tabs keep the folder icon.',
              ),
              zhEn(
                '文件类型图标优化：未获取媒体缩略图时，图片/视频/音频/安装包显示「类型图标 + 格式标签」（MP4/MKV/MP3/FLAC/APK 等）；安装包用安卓机器人图标（绿色），压缩包用捆绑包图标（Broken.box）并显示 ZIP/7Z/RAR 格式；分类页音乐页音乐图标下方也显示格式标签；浏览页与分类页图标显示一致。',
                'File-type icon polish: when no media thumbnail is available, images/videos/audio/install-packages show a "type icon + format label" (MP4/MKV/MP3/FLAC/APK...); install packages use the Android-robot icon (green), archives use a bundle icon (Broken.box) with ZIP/7Z/RAR labels; the music category page also shows a format label under each music icon; browsing and category pages share consistent icons.',
              ),
              zhEn(
                '远程缩略图缓存隐私保护：远程媒体缩略图缓存迁入 .nomedia 目录并写入标记文件，避免被系统媒体库/其他文件管理器索引；默认远程缓存自动清理间隔改为 0（不自动清理）。',
                'Remote thumbnail privacy: remote media thumbnails moved into a .nomedia directory with a marker file so they are not indexed by the system media library / other file managers; default remote-cache auto-clean interval changed to 0 (disabled).',
              ),
              gap(14),

              Text('🎨 性能优化 · Performance', style: sectionStyle),
              gap(6),
              zhEn(
                '远程媒体流式代理调优：多段独立 seek 缓存（上限 4 段）避免来回拖动反复缓冲；mpv 缓冲参数放大（cache-secs 60 / demuxer-max-bytes 300M）减少周期卡顿；引导预取 16MB、按需抓取 24MB 提升起播与拖动跟手度。',
                'Remote media streaming proxy tuning: multi-region seek cache (max 4 regions) avoids re-buffering on back-and-forth seeks; enlarged mpv buffering (cache-secs 60 / demuxer-max-bytes 300M) reduces periodic stutter; 16 MB prefetch and 24 MB on-demand fetch improve start-up and seek responsiveness.',
              ),
            ],
          ),
        ),
        // ── 历史版本 ──
        _buildV1136Changelog(ctx, theme),
      ],
    );
  }

  Widget _buildV1136Changelog(BuildContext ctx, ThemeData theme) {
    final textStyle = TextStyle(fontSize: 13.5, height: 1.6, color: theme.colorScheme.onSurface.withOpacity(0.85));
    final enStyle = TextStyle(fontSize: 12, height: 1.5, color: theme.colorScheme.onSurface.withOpacity(0.5));
    final sectionStyle = TextStyle(fontSize: 14, height: 1.6, color: theme.colorScheme.primary, fontWeight: FontWeight.w700);

    Widget gap([double h = 6]) => SizedBox(height: h);
    // 双语条目：中文在上，英文在下
    Widget zhEn(String zh, String en) => Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('· $zh', style: textStyle),
          const SizedBox(height: 2),
          Text('  $en', style: enStyle),
        ],
      ),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // ── 1.1.36 当前版本 ──
        Container(
          margin: const EdgeInsets.only(bottom: 8),
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceVariant.withOpacity(0.3),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: theme.colorScheme.onSurface.withOpacity(0.06)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.primary.withOpacity(0.12),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text('v1.1.36', style: TextStyle(color: theme.colorScheme.primary, fontSize: 13, fontWeight: FontWeight.bold, fontFamily: 'LexendDeca')),
                  ),
                  const SizedBox(width: 10),
                  Text('2026-08-29', style: TextStyle(fontSize: 12, color: theme.colorScheme.onSurface.withOpacity(0.4))),
                ],
              ),
              gap(14),
              Text('🔧 问题修复 · Bug Fixes', style: sectionStyle),
              gap(6),
              zhEn(
                '单窗口模式：当前激活（已打开）的标签页按钮背景现在会高亮，之前只有标题文字高亮、背景无区分。',
                'Single-pane mode: the active (current) tab button now shows a highlighted background; previously only the title text was highlighted with no background distinction.',
              ),
              zhEn(
                '双窗口多标签显示/切换重构：A 在左窗口、B 在右窗口；新建或切换到其他标签页时，已激活的标签页始终保持所在窗口位置不变，被顶替的始终是未激活一侧窗口。',
                'Split-pane multi-tab display/switch reworked: tab A stays in the left pane, B in the right; when creating or switching to another tab, the active tab keeps its pane position and only the inactive pane gets replaced.',
              ),
              zhEn(
                '双窗口仅剩两个标签页时现在可关闭任意一个，关闭后会自动新建一个标签页顶替被关闭的位置，保证两侧窗口始终有内容。',
                'When only two tabs remain in split-pane mode, either one can now be closed; closing auto-creates a replacement tab so both panes always show content.',
              ),
              zhEn(
                '双窗口模式下远程标签页标题固定显示已保存的远程客户端名称（此前会随打开的目录变化）。',
                'In split-pane mode a remote tab title now always shows the saved remote client name (previously it changed with the opened directory).',
              ),
              zhEn(
                '远程标签页标题左侧图标替换为云徽图标，方便一眼辨别远程/本地标签。',
                'The icon on the left of a remote tab title is now a cloud badge, making remote vs. local tabs easy to distinguish.',
              ),
            ],
          ),
        ),
        // ── 历史版本 ──
        _buildV1135Changelog(ctx, theme),
      ],
    );
  }

  Widget _buildV1135Changelog(BuildContext ctx, ThemeData theme) {
    final textStyle = TextStyle(fontSize: 13.5, height: 1.6, color: theme.colorScheme.onSurface.withOpacity(0.85));
    final enStyle = TextStyle(fontSize: 12, height: 1.5, color: theme.colorScheme.onSurface.withOpacity(0.5));
    final sectionStyle = TextStyle(fontSize: 14, height: 1.6, color: theme.colorScheme.primary, fontWeight: FontWeight.w700);

    Widget gap([double h = 6]) => SizedBox(height: h);
    // 双语条目：中文在上，英文在下
    Widget zhEn(String zh, String en) => Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('· $zh', style: textStyle),
          const SizedBox(height: 2),
          Text('  $en', style: enStyle),
        ],
      ),
    );

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceVariant.withOpacity(0.3),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: theme.colorScheme.onSurface.withOpacity(0.06)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: theme.colorScheme.primary.withOpacity(0.12),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text('v1.1.35', style: TextStyle(color: theme.colorScheme.primary, fontSize: 13, fontWeight: FontWeight.bold, fontFamily: 'LexendDeca')),
              ),
              const SizedBox(width: 10),
              Text('2026-08-29', style: TextStyle(fontSize: 12, color: theme.colorScheme.onSurface.withOpacity(0.4))),
            ],
          ),
          gap(14),

          // ── 新增功能 / New Features ──
          Text('✨ 新增功能 · New Features', style: sectionStyle),
          gap(6),
          zhEn(
            '多标签页适用范围选择器：开启「启用多标签页」后弹出三选项（仅在单窗口 / 仅在双窗口 / 全部），双窗口模式现支持独立多标签页，选择持久化。',
            'Multi-tab pane scope selector: enabling "Multi-tab" pops a 3-option dialog (Single only / Split only / All); split mode now has its own tabs; selection persists.',
          ),
          zhEn(
            'SFTP SSH 密钥认证：支持密码与 SSH 密钥认证切换，可选本地私钥（.pem / .key / .pub）与密码短语，兼容 OpenSSH / RSA / ED25519 / ECDSA。',
            'SFTP SSH key auth: switch between password and SSH key; pick a local private key (.pem / .key / .pub) with optional passphrase; compatible with OpenSSH / RSA / ED25519 / ECDSA.',
          ),
          zhEn(
            'SAF 系统授权访问 Android/data（vivo 等 ROM）：四级兜底策略，进入失败时显示「系统授权访问」按钮，授权后树形 URI 持久保存。',
            'SAF system authorization for Android/data (vivo etc.): four-tier fallback; a "System authorized access" button appears on failure; the tree URI is persisted after grant.',
          ),
          zhEn(
            'SMB 向导「扫描局域网共享设备」：顶部带文字标题的按钮，无需输入 IP 即自动探测局域网 SMB 设备并自动填入地址与共享名。',
            'SMB wizard "Scan LAN devices": a titled top button auto-discovers LAN SMB devices on port 445 without entering an IP, and auto-fills host and share name.',
          ),
          zhEn(
            '图片查看器拍摄地点显示：顶部元信息条显示拍摄 GPS 坐标，无位置信息自动隐藏该行，点击唤起系统地图。',
            'Image viewer shooting location: the top bar shows capture GPS coordinates and auto-hides when none; tap to open the system map.',
          ),
          zhEn(
            '图片编辑器「清除元数据」：tab 栏「裁剪」右侧新增入口，字节级无损剥离 EXIF / GPS / ICC，不重编码、不损失画质。',
            'Image editor "Clear metadata": a new entry next to Crop; byte-level lossless strip of EXIF / GPS / ICC without re-encoding or quality loss.',
          ),
          gap(8),

          // ── 问题修复 / Bug Fixes ──
          Text('🐛 问题修复 · Bug Fixes', style: sectionStyle),
          gap(6),
          zhEn(
            '快传大文件接收卡死 / 闪退：接收端改为 Uint8List 分块队列 + TCP 背压水位（8MB / 1MB），≥1GB 文件稳定接收。',
            'Quick Transfer large-file crash: the receiver now uses a chunked Uint8List queue + TCP backpressure (8MB / 1MB watermark); files ≥1GB are received stably.',
          ),
          zhEn(
            '图片查看器「无 EXIF 却误显示拍摄参数标题」：标题仅在含实际拍摄参数字段（光圈 / 快门 / ISO / 设备）时显示。',
            'Image viewer wrong EXIF title: the title now shows only when real capture-parameter fields (aperture / shutter / ISO / device) exist.',
          ),
          zhEn(
            '多标签页设置缺陷修复：接入范围选择弹窗、仅在开启时弹出、3 处硬编码中文改多语言。',
            'Multi-tab settings fixes: wired the scope picker, pops only when enabling, and localized 3 hardcoded Chinese strings.',
          ),
          zhEn(
            '构建失败（Java 堆内存不足）：将 gradle -Xmx 从 1536M 提升至 6144M。',
            'Build failed (Java heap space): raised gradle -Xmx from 1536M to 6144M.',
          ),
          gap(8),

          // ── 优化 / Optimizations ──
          Text('🔧 优化 · Optimizations', style: sectionStyle),
          gap(6),
          zhEn(
            '快传分块缓冲 + TCP 背压，内存稳定；清除元数据字节级剥离，结果确定；SMB 扫描与向导复用同一过滤逻辑。',
            'Quick Transfer chunked buffer + TCP backpressure keeps memory stable; clear metadata is byte-level strip; SMB scan reuses the same filter logic as the wizard.',
          ),
        ],
      ),
    );
  }

  void _showImagePreview(BuildContext context, ThemeData theme, String assetPath) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (ctx) => Scaffold(
          backgroundColor: Colors.black,
          appBar: AppBar(
            backgroundColor: Colors.black.withOpacity(0.5),
            elevation: 0,
            leading: IconButton(
              icon: const Icon(Icons.close, color: Colors.white),
              onPressed: () => Navigator.of(ctx).pop(),
            ),
            title: Text(L10n.of(context).msgd054a84c, style: TextStyle(color: Colors.white, fontSize: 14)),
            centerTitle: true,
          ),
          body: Center(
            child: InteractiveViewer(
              minScale: 0.5,
              maxScale: 4.0,
              child: GestureDetector(
                onLongPress: () => _saveImageToGallery(ctx, assetPath),
                child: Image.asset(
                  assetPath,
                  fit: BoxFit.contain,
                  errorBuilder: (context, error, stackTrace) {
                    debugPrint('Image preview error: $error');
                    return const Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.broken_image, color: Colors.white54, size: 64),
                          SizedBox(height: 16),
                          Text('图片加载失败', style: TextStyle(color: Colors.white54)),
                        ],
                      ),
                    );
                  },
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _saveImageToGallery(BuildContext context, String assetPath) async {
    try {
      final byteData = await DefaultAssetBundle.of(context).load(assetPath);
      final bytes = byteData.buffer.asUint8List();
      
      final PermissionState ps = await PhotoManager.requestPermissionExtend();
      if (!ps.isAuth) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(L10n.of(context).msgc2790d54)),
          );
        }
        return;
      }

      final String fileName = assetPath.split('/').last;
      await PhotoManager.editor.saveImage(
        bytes,
        title: fileName,
        filename: fileName,
      );

      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('图片已保存到相册'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } catch (e) {
      debugPrint('Save image error: $e');
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('保存失败: {e}'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    }
  }

  Widget _buildDownloadLink(BuildContext ctx, ThemeData theme, String name, String url, IconData icon) {
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: () async {
        try {
          await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
        } catch (_) {}
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceVariant.withOpacity(0.2),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: theme.colorScheme.onSurface.withOpacity(0.06)),
        ),
        child: Row(
          children: [
            Icon(icon, size: 18, color: theme.colorScheme.primary.withOpacity(0.7)),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                name,
                style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w500, color: theme.colorScheme.onSurface.withOpacity(0.85)),
              ),
            ),
            Icon(Icons.open_in_new, size: 14, color: theme.colorScheme.onSurface.withOpacity(0.35)),
          ],
        ),
      ),
    );
  }
}
