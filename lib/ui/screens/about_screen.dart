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

  /// 跳转 QQ 群加群。
  /// 优先使用 mqqapi scheme 直接唤起 QQ 应用（不经过浏览器）；
  /// 若 QQ 未安装或无法处理该 scheme，则回退到官方加群页链接。
  Future<void> _joinQQGroup(BuildContext context) async {
    const groupCode = '792408214';
    final mqq = Uri.parse(
      'mqqapi://card/show_pslcard?src_type=internal&version=1'
      '&uin=$groupCode&card_type=group&source=qrcode',
    );
    try {
      final opened = await launchUrl(mqq, mode: LaunchMode.externalApplication);
      if (opened) return;
    } catch (_) {}
    // 回退：官方加群页（该页在移动端也会尝试唤起 QQ）
    await _launchUrl(
      context,
      'https://qun.qq.com/universal-share/share?ac=1'
      '&authKey=073RXV65qHzzOS3mT1FUc3zHaX2y2Gb%2BN6uhcfTktUKYit4D9V92wGkvtj%2BEcLa2'
      '&busi_data=eyJncm91cENvZGUiOiI3OTI0MDgyMTQiLCJ0b2tlbiI6IkZ3Z05TMXBabmZGaVE0a2lvdERYMTJnK01OVmo5d0dTOFB2QXJRc0RmN1ZCdE9JT1VJYlh5UWFZdzJBS3BUZ1UiLCJ1aW4iOiI5MzAyMDM4MTEifQ%3D%3D'
      '&data=mrv0ABsYyT3K-lef1Obq0pmjrg4szRt_ultVH8umFVcnlh5AX_xnY2DZ2ngWTE3Ayeq0MQUfMYiAtFI3Z8J-MA'
      '&svctype=4&tempid=h5_group_info',
    );
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
                              'assets/logo/zf_Classic1.webp',
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
                    'v2.1.5',
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
                    onTap: () {
                      Clipboard.setData(const ClipboardData(text: '1@sequel.dpdns.org'));
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text(L10n.of(context).emailCopied),
                          behavior: SnackBarBehavior.floating,
                        ),
                      );
                    },
                  ),
                  const SizedBox(height: 10),
                  _buildSocialAction(
                    context,
                    icon: Icons.group_rounded,
                    label: L10n.of(context).qqGroup,
                    onTap: () => _joinQQGroup(context),
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

                  _buildV215Changelog(ctx, theme),
                  const SizedBox(height: 40),
                ],
              ),
            );
          },
        );
      },
    );
  }

  /// v2.1.5 更新日志卡片。
  ///
  /// 按用户要求：**只保留当前版本**，上半部分中文、中间以分割线隔开、下半部分英文，
  /// 供国际用户阅读；文案直接硬编码，不走 l10n（无需多语言翻译）。
  /// 历史版本卡片（v2.1.4 / v2.1.3 / v2.1.2 / v2.1.1 / v2.1.0 / v2.0.0）已移除。
  Widget _buildV215Changelog(BuildContext ctx, ThemeData theme) {
    final textStyle = TextStyle(fontSize: 13.5, height: 1.6, color: theme.colorScheme.onSurface.withOpacity(0.85));
    final dividerColor = theme.colorScheme.onSurface.withOpacity(0.15);

    Widget gap([double h = 6]) => SizedBox(height: h);
    Widget item(String text) => Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text('\u00b7 $text', style: textStyle),
    );
    Widget section(String title) => Padding(
      padding: const EdgeInsets.only(top: 6, bottom: 4),
      child: Text(title, style: TextStyle(fontSize: 14, height: 1.6, color: theme.colorScheme.primary, fontWeight: FontWeight.w700)),
    );
    Widget divider() => Padding(
      padding: const EdgeInsets.symmetric(vertical: 16),
      child: Container(height: 1, color: dividerColor),
    );
    // 中英文之间的语言分割线（中间标注 English）
    Widget langDivider() => Padding(
      padding: const EdgeInsets.symmetric(vertical: 18),
      child: Row(
        children: [
          Expanded(child: Container(height: 1, color: dividerColor)),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: Text('English', style: TextStyle(fontSize: 12, letterSpacing: 1.2, fontWeight: FontWeight.w600, color: theme.colorScheme.onSurface.withOpacity(0.5))),
          ),
          Expanded(child: Container(height: 1, color: dividerColor)),
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
                child: Text('v2.1.5', style: TextStyle(color: theme.colorScheme.primary, fontSize: 13, fontWeight: FontWeight.bold, fontFamily: 'LexendDeca')),
              ),
              const SizedBox(width: 10),
              Text('2026-09-21', style: TextStyle(fontSize: 12, color: theme.colorScheme.onSurface.withOpacity(0.4))),
            ],
          ),
          gap(14),

          // ══════════════ 中文 ══════════════
          section('\u2728 新功能'),
          item('远程目录支持「原地加密 / 解密」：选中文件或文件夹后在原远程目录直接完成加密或解密，无需先下载到本地（下载→加密/解密→回传原目录替换原文件）'),
          item('远程加密目录中的文件复制 / 剪切到本地或其他目录保持密文，不再自动解密，与本地加密文件行为一致'),
          item('新增 3 款预设应用图标（Classic 4 / 3D Gradient / Glossy Blue），现共 10 款可选'),

          divider(),

          section('\u{1f3a8} 界面与交互'),
          item('远程加密 / 解密进度弹窗统一为双层圆环，与本地加解密进度一致'),
          item('保险箱加密 / 解密会话弹窗优先引导生物识别验证'),
          item('修复预设应用图标切换无效：改为通过 activity-alias 切换，现已真正生效'),

          divider(),

          section('\u{1f41b} 问题修复'),
          item('修复远程目录加密 / 解密成功后，点击面包屑或返回按钮无法进入其他目录、页面冻结的问题（WebDAV 复现）'),
          item('修复远程加密 / 解密产生的临时文件（RemoteDecrypted）未自动清理'),
          item('修复 ROOT / Shizuku 模式下访问系统根目录「/」显示空列表'),
          item('修复远程媒体缩略图同时完整下载原图占满带宽导致卡顿：改为串行加载 + 约 2MB/s 限速，并将原图压缩为 512px 缩略图缓存'),
          item('修复静默安装 APK 后临时副本未清理、以及安装源失效时的回退处理'),
          item('修复 IM 转发产生的带数字后缀安装包（如 .apk.1）无法识别类型：各文件类型入口统一识别，并渲染真实应用图标'),
          item('修复预设图标默认图标体积过大：恢复 7 款预设图标为 WebP 并压缩默认图标'),

          langDivider(),

          // ══════════════ English ══════════════
          section('\u2728 New Features'),
          item('In-place encrypt / decrypt for remote folders: select a file or folder and encrypt or decrypt it right in the original remote directory, no need to download first (download, encrypt/decrypt, upload back to replace the original)'),
          item('Copying or moving a file out of a remote encrypted folder keeps it encrypted, instead of decrypting automatically, matching local encrypted files'),
          item('3 new preset app icons added (Classic 4 / 3D Gradient / Glossy Blue), for a total of 10 to choose from'),

          divider(),

          section('\u{1f3a8} UI & Interaction'),
          item('Remote encrypt / decrypt progress dialog now uses the same dual-ring design as the local one'),
          item('The Vault encrypt / decrypt session dialog now prompts for biometrics first'),
          item('Fixed preset app icons not switching: switching now works through an activity-alias'),

          divider(),

          section('\u{1f41b} Bug Fixes'),
          item('Fixed the breadcrumb and back button doing nothing after encrypting / decrypting in a remote folder, freezing the page (reproduced on WebDAV)'),
          item('Fixed temporary files (RemoteDecrypted) left behind after remote encrypt / decrypt not being cleaned up'),
          item('Fixed the system root "/" showing an empty list in ROOT / Shizuku mode'),
          item('Fixed remote thumbnails choking the bandwidth by downloading full-size images at once: now serialized with a ~2MB/s cap and cached as 512px thumbnails'),
          item('Fixed temp copies left behind after a silent APK install, and the fallback when the install source is gone'),
          item('Fixed IM-renamed packages with a numeric suffix (e.g. .apk.1) not being recognized: all type entries now detect them and render the real app icon'),
          item('Fixed the oversized default preset icon: restored 7 preset icons as WebP and compressed the default icon'),
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
