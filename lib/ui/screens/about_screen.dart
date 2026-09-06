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
                    'v1.1.41',
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

                  _buildV1141Changelog(ctx, theme),
                  const SizedBox(height: 40),
                ],
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildV1141Changelog(BuildContext ctx, ThemeData theme) {
    final textStyle = TextStyle(fontSize: 13.5, height: 1.6, color: theme.colorScheme.onSurface.withOpacity(0.85));
    final enStyle = TextStyle(fontSize: 12, height: 1.5, color: theme.colorScheme.onSurface.withOpacity(0.5));
    final sectionStyle = TextStyle(fontSize: 14, height: 1.6, color: theme.colorScheme.primary, fontWeight: FontWeight.w700);

    Widget gap([double h = 6]) => SizedBox(height: h);
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
                child: Text('v1.1.41', style: TextStyle(color: theme.colorScheme.primary, fontSize: 13, fontWeight: FontWeight.bold, fontFamily: 'LexendDeca')),
              ),
              const SizedBox(width: 10),
              Text('2026-09-06', style: TextStyle(fontSize: 12, color: theme.colorScheme.onSurface.withOpacity(0.4))),
            ],
          ),
          gap(14),

          Text('\u{1f512} 保险箱重大升级 · Vault Major Upgrade', style: sectionStyle),
          gap(6),
          zhEn('V3 加密格式：内容加密从 AES-256-GCM 升级为 XChaCha20-Poly1305，吞吐提升约 3 倍（7.1 → 21.7 MiB/s），V1/V2 老文件仍可正常解密。',
               'V3 encryption format: Content encryption upgraded from AES-256-GCM to XChaCha20-Poly1305, throughput improved ~3x (7.1 → 21.7 MiB/s). V1/V2 legacy files remain decryptable.'),
          zhEn('会话级密钥缓存：派生一次密钥留在内存复用，批量加解密只有第一次慢，改密码派生次数从 2N 降到 2。',
               'Session-level key cache: Derive key once and reuse in memory. Batch encrypt/decrypt is slow only on first run; password change derivation reduced from 2N to 2.'),
          zhEn('加解密下沉 isolate：KDF + AEAD 分块循环在独立 isolate 执行，主线程不再卡顿；isolate 不可用时自动回退。',
               'Encrypt/decrypt offloaded to isolate: KDF + AEAD chunk loop runs in a separate isolate, main thread no longer freezes; auto-fallback when isolate unavailable.'),
          zhEn('目录锁定改流式 ZIP：ZipFileEncoder 逐文件落盘，不再整目录进内存，大目录 OOM 风险解除。',
               'Directory locking uses streaming ZIP: ZipFileEncoder writes file-by-file to disk, no longer loading entire directory into memory; large-directory OOM risk eliminated.'),
          zhEn('修复密码错误时截断目标文件：原实现先 openWrite 再解密，密码错误会留下空文件，现已修复。',
               'Fixed target file truncation on wrong password: Original implementation opened write before decrypting, leaving an empty file on wrong password; now fixed.'),
          gap(14),

          Text('\u{1f4e6} APK 安装器与安全扫描 · APK Installer & Security Scan', style: sectionStyle),
          gap(6),
          zhEn('VirusTotal APK 安装安全扫描：安装 APK 前自动哈希查询，支持安全/风险/未收录/扫描失败四态弹窗，未收录可上传完整扫描。',
               'VirusTotal APK install security scan: Auto hash query before installing APK. Supports 4-state dialog (safe/risky/not found/scan failed); full upload scan available for not-found files.'),
          zhEn('支持 xapk/apks/apkm/aab 格式扫描与安装：bundle 包先扫描再解压安装。',
               'Supports xapk/apks/apkm/aab format scan & install: Bundle packages are scanned first, then extracted and installed.'),
          zhEn('root/shizuku 静默安装器：获取权限后自动后台安装，支持单 APK 和多 APK 会话机制，失败自动回退系统安装器。',
               'root/shizuku silent installer: Auto background install after permission granted. Supports single APK and multi-APK session mechanism; auto-fallback to system installer on failure.'),
          zhEn('安装后保留安装包开关：开启后安装临时副本，防止系统安装器自动删除源 APK。',
               'Keep APK after install switch: When enabled, installs a temporary copy to prevent the system installer from auto-deleting the source APK.'),
          zhEn('安全扫描开关与 API Key 分离：关闭扫描不再清空 Key，Key 持久化保留；备份/恢复自动包含 Key 和开关状态。',
               'Scan switch separated from API Key: Turning off scan no longer clears the Key; Key is persistently retained. Backup/restore automatically includes Key and switch state.'),
          gap(14),

          Text('\u{1f4c1} 文件管理与导航 · File Management & Navigation', style: sectionStyle),
          gap(6),
          zhEn('导航按钮逻辑重构：参考 Windows 资源管理器，回退基于历史栈后退，向上进入父目录，前进基于历史栈前进（修复前进按钮永远灰色的问题）。',
               'Navigation button logic refactor: Following Windows Explorer, Back uses history stack, Up goes to parent directory, Forward uses history stack (fixed Forward button always greyed out).'),
          zhEn('双窗口模式文件拖放优化：一次长按即可开始拖放（无需先选中再长按），长按拖放期间抑制左右滑动切页和多选菜单误触。',
               'Dual-pane file drag-and-drop optimized: One long-press starts dragging (no need to select first). Swipe-to-switch-pane and multi-select menu are suppressed during drag.'),
          zhEn('Android/data 受限路径复制优化：受限 Android 路径文件一律走 shell cp（FUSE 直接路径 + 底层路径双跳 + 大小校验），从根本上避免复制出 0 字节文件。',
               'Android/data restricted path copy optimized: All restricted Android path files use shell cp (FUSE direct path + underlying path dual-fallback + size verification), fundamentally preventing 0-byte copies.'),
          zhEn('多选操作菜单俄语溢出修复：俄语长文案导致删除和更多按钮被挤出屏幕，优化横向布局。',
               'Fixed Russian overflow in multi-select action bar: Long Russian text caused Delete and More buttons to be pushed off-screen; horizontal layout optimized.'),
          zhEn('文件/文件夹三点菜单新增分享功能：分享按钮位于菜单底部，最近页同样支持。',
               'Added Share to file/folder three-dot menu: Share button at the bottom of the menu; also supported in the Recent page.'),
          gap(14),

          Text('\u{1f5bc}\ufe0f 分类页与媒体库 · Categories & Media Library', style: sectionStyle),
          gap(6),
          zhEn('类别设置屏蔽文件夹：每个类别（图片/视频/音频/文档等）独立设置屏蔽文件夹，添加后不再扫描该文件夹下的文件。',
               'Category setting: Exclude folders: Each category (images/videos/audio/documents, etc.) independently sets excluded folders; files under excluded folders are no longer scanned.'),
          zhEn('按类别独立排序 + 持久化：每个类别记住各自的排序方式（名称/日期/大小/类型），切换类别不互相影响。',
               'Per-category independent sort + persistence: Each category remembers its own sort method (name/date/size/type); switching categories does not affect each other.'),
          zhEn('修复图片/视频大小排序无效：根因是批量预加载 stat 时只检查 mtime 缓存不检查 size 缓存，导致系统索引文件 size 被误填为 0。',
               'Fixed image/video size sort not working: Root cause was that batch preload stat only checked mtime cache but not size cache, causing system-indexed file sizes to be incorrectly filled as 0.'),
          zhEn('修复图片/视频预览页快速下滑闪退：4 处 Image.file 添加 cacheWidth 限制。',
               'Fixed crash on fast scroll-down in image/video preview page: Added cacheWidth limit to 4 Image.file instances.'),
          zhEn('修复分类页音频列表启动后莫名清零：querySongs 不可靠，改文件系统枚举兜底，7 处修复确保任何路径都无法清空列表。',
               'Fixed category audio list mysteriously clearing on startup: querySongs unreliable, switched to filesystem enumeration fallback. 7 fixes ensure no path can clear the list.'),
          zhEn('分类页长按类别图标弹窗新增"自定义快捷方式"按钮。',
               'Added "Custom Shortcut" button to long-press category icon dialog in Categories page.'),
          gap(14),

          Text('\u{1f3b5} 音频播放器 · Audio Player', style: sectionStyle),
          gap(6),
          zhEn('音频均衡器在音频播放器生效：此前仅视频播放器生效，现已修复。',
               'Audio equalizer now works in audio player: Previously only worked in video player; now fixed.'),
          zhEn('音频文件名过长自动滚动：向左循环滚动，速度优化至最低，避免闪眼。',
               'Auto-scroll for long audio filenames: Loops scrolling left, speed optimized to minimum to avoid eye strain.'),
          zhEn('波形跳动根据音频频率：根据实际音频频率动态跳动，不再固定高度。',
               'Waveform beats according to audio frequency: Dynamically pulses based on actual audio frequency, no longer fixed height.'),
          gap(14),

          Text('\u{1f3a8} 图片编辑器 · Image Editor', style: sectionStyle),
          gap(6),
          zhEn('重建绘图功能：父 tab 位于调整与滤镜之间，子 tab 紧挨父 tab；支持画笔、橡皮擦、文字、矩形、椭圆、马赛克、箭头、直线。',
               'Rebuilt drawing feature: Parent tab between Adjust and Filters, child tab immediately below. Supports brush, eraser, text, rectangle, ellipse, mosaic, arrow, line.'),
          zhEn('文字/矩形/椭圆区域框操作：右下角手柄缩放旋转、左上角关闭按钮、长按移动、点击二次编辑；缩放/旋转/移动实时预览。',
               'Text/rectangle/ellipse bounding box: Bottom-right handle for scale/rotate, top-left close button, long-press to move, tap to re-edit; real-time preview for scale/rotate/move.'),
          zhEn('滑块智能切换：文本工具显示"字体"大小，其它工具显示"线粗"；切换工具自动保存当前绘制，可通过顶部撤回按钮撤销。',
               'Smart slider switch: Text tool shows "Font" size, other tools show "Line thickness"; switching tools auto-saves current drawing, undoable via top Undo button.'),
          gap(14),

          Text('\u{1f3a8} 界面与多语言 · UI & Localization', style: sectionStyle),
          gap(6),
          zhEn('AMOLED 纯黑模式真正变黑：此前与深色模式无区别，现已优化为真正的纯黑。',
               'AMOLED pure black mode truly black: Previously indistinguishable from dark mode; now optimized to true pure black.'),
          zhEn('关于页 QQ 群直唤加群：点击按钮通过 mqqapi 直接唤起 QQ 申请加群，无需打开浏览器；QQ 群文案支持多语言。',
               'About page QQ group direct join: Tap button to directly launch QQ group join via mqqapi, no browser needed; QQ group text supports multi-language.'),
          zhEn('关于页邮箱点击复制：从长按复制改为点击复制，复制提示文案支持多语言。',
               'About page email tap-to-copy: Changed from long-press copy to tap copy; copy toast text supports multi-language.'),
          zhEn('10 语言全同步：中文/繁体中文/英文/俄语/日语/韩语/德语/西班牙语/法语/阿拉伯语。',
               '10 languages fully synced: Chinese/Traditional Chinese/English/Russian/Japanese/Korean/German/Spanish/French/Arabic.'),
          gap(14),

          Text('\u{1f41b} 其它修复 · Other Fixes', style: sectionStyle),
          gap(6),
          zhEn('修复 Android/data 文件夹大小显示 0B：受限路径 stat 走底层绕过 + FUSE 回退双路径。',
               'Fixed Android/data folder size showing 0B: Restricted path stat uses underlying bypass + FUSE fallback dual paths.'),
          zhEn('修复 .xapk/.apkm 点击弹"打开方式"：所有 APK 格式一律走内置安装器，不受"外部打开"默认动作影响。',
               'Fixed .xapk/.apkm tap showing "Open with": All APK formats use the built-in installer, unaffected by "Open externally" default action.'),
          zhEn('修复保险箱指纹弹窗标题硬编码：启动应用保护时标题不再显示"远程守卫"，按业务场景区分文案。',
               'Fixed vault fingerprint dialog title hardcoded: Title no longer shows "Remote Guard" when launching app protection; text differentiated by business scenario.'),
          zhEn('修复 APK 上传扫描网络错误：优先直接 POST /files，仅文件过大时回退 upload_url 且不带 x-apikey header。',
               'Fixed APK upload scan network error: Prefer direct POST /files, only fallback to upload_url for oversized files without x-apikey header.'),
          zhEn('移除 PDF 编辑器：因依赖库导致安装包体积增大 10MB 且空白渲染问题未解决，已移除。',
               'Removed PDF editor: Removed due to dependency library increasing APK size by 10MB and unresolved blank rendering issue.'),
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
