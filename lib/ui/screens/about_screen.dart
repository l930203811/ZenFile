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
                    'v1.1.40',
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

                  _buildV1139Changelog(ctx, theme),
                  const SizedBox(height: 40),
                ],
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildV1139Changelog(BuildContext ctx, ThemeData theme) {
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
          Text('\u00b7 $zh', style: textStyle),
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
                child: Text('v1.1.39', style: TextStyle(color: theme.colorScheme.primary, fontSize: 13, fontWeight: FontWeight.bold, fontFamily: 'LexendDeca')),
              ),
              const SizedBox(width: 10),
              Text('2026-09-03', style: TextStyle(fontSize: 12, color: theme.colorScheme.onSurface.withOpacity(0.4))),
            ],
          ),
          gap(14),

          Text('✨ 新增功能 · New Features', style: sectionStyle),
          gap(6),
          zhEn(
            '图片编辑器绘图工具：新增 7 种绘图工具（画笔 / 文本 / 矩形 / 椭圆 / 直线 / 箭头 / 马赛克）；文本实时完整显示（不再被省略截断），矩形 / 椭圆即时预览，辅助框自动隐藏（仅点击选中项才显示），切换工具自动保存且可经顶部按钮撤回。',
            'Image editor drawing tool: 7 tools added (brush / text / rectangle / ellipse / line / arrow / mosaic). Text renders fully live, rectangles/ellipses preview instantly, helper boxes auto-hide (shown only for the tapped item), and switching tools auto-saves with the top undo button available.',
          ),
          zhEn(
            '保险箱指纹解锁 + 导出 / 导入备份：支持指纹解锁；可一键导出 / 导入整库备份，避免卸载重装后数据丢失。',
            'Vault fingerprint unlock + export/import backup: unlock with fingerprint; export/import a full vault backup in one tap so data survives uninstall & reinstall.',
          ),
          gap(14),

          Text('🐛 问题修复 · Bug Fixes', style: sectionStyle),
          gap(6),
          zhEn(
            '从其它应用分享不再复制进应用私有缓存：图库 / 文件管理器 / 媒体库的文件保留在原位置打开，不额外占空间；「打开文件所在位置」直达真实文件夹并高亮。私有内容分享（如 WhatsApp）因系统不暴露真实路径仍会缓存。',
            'Sharing from other apps no longer copies into the app-private cache: files from gallery / file manager / media library open in place with no extra space; "Open file location" jumps to the real folder and highlights the file. Private-content shares (e.g. WhatsApp) still cache because the system hides the real path.',
          ),
          zhEn(
            '分享入口选择框：无权限读取分享文件时直接弹权限提示（不再尝试注定失败的复制）；外部打开方式选择框改为左对齐，顺序为「打开 → 打开文件所在位置 → 取消」。',
            'Share dialog: lacking permission to read a shared file now prompts for permission directly (no doomed copy); the external-open chooser is left-aligned and ordered "Open → Open file location → Cancel".',
          ),
          zhEn(
            '分享后「打开文件所在位置」精准跳转：先切到浏览页，再加载父目录并居中高亮目标文件。',
            'Precise "Open file location" after sharing: it now switches to the browse tab, loads the parent directory, and highlights the target file.',
          ),
          zhEn(
            '视频无声修复：首次打开即有声音；软解 / 硬解切换后均衡器重新挂载且仍有声；退出重开不再丢失声音。',
            'Video no-audio fixed: video now has sound on first open; toggling soft/hard decode re-attaches the equalizer and keeps audio; reopening the player no longer loses sound.',
          ),
          zhEn(
            '均衡器修复：视频切回音频时预设生效；从后台返回不再被重置为 Flat，预设重新应用且后台播放保持挂载。',
            'Equalizer fixes: preset applies when switching from video back to audio; returning from background no longer resets to Flat — the preset is reapplied and stays attached during background playback.',
          ),
          zhEn(
            '点击媒体通知栏可正确跳转到对应播放页。',
            'Tapping the media notification now correctly jumps to the relevant player screen.',
          ),
          zhEn(
            'Android/data 根目录显示 0 项：回退到 Shizuku 原始路径列举以正确显示内容。',
            'Android/data root showing 0 items: now falls back to raw Shizuku path listing.',
          ),
          zhEn(
            '双窗口浏览器文件夹项：修复大小 / 数量 / 日期缺失与英文硬编码，现以紧凑的「数量 • 大小 • 日期」展示并跟随多语言。',
            'Split-pane browser folder items: fixed missing size/count/date and hardcoded English; now shown as compact "count • size • date" and localized.',
          ),
          zhEn(
            '卸载重装后保险箱恢复失败：备份包内嵌 V2 密码校验参数，重装后可用原密码解锁恢复；跨设备导入时把记录重新指向真实保险箱路径。',
            'Vault restore failure after reinstall: the backup now embeds V2 password parameters so the original password unlocks after reinstall; cross-device import redirects records to the real vault path.',
          ),
          gap(14),

          Text('🔧 其它优化 · Other', style: sectionStyle),
          gap(6),
          zhEn(
            '分类页多选栏：修复窄语言下的文字溢出；图片查看器操作栏：修复俄语等较长语言标签的溢出。',
            'Category multi-select bar: fixed text overflow under narrow languages; image viewer action bar: fixed overflow of long-language labels (e.g. Russian).',
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
