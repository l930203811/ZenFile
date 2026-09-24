import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:zenfile/l10n/generated/app_localizations.dart';

import '../../core/icon_fonts/broken_icons.dart';
import '../../services/apk_installer_service.dart';

/// 「查看更新」全屏页面（入口在左抽屉：设置 与 关于ZenFile 之间）。
///
/// 结构：
/// ① GitHub 版本检测卡片 —— 打开页面自动检测一次，失败/想重查可手动重试；
///    发现新版本后按设备 ABI 匹配 Release 资产，应用内下载并走统一安装链路
///    [ApkInstallerService.installApk]（含 VirusTotal 扫描等既有逻辑）。
/// ② 网盘下载链接（自「关于」页迁移）。
/// ③ 当前版本更新日志（自「关于」页迁移，硬编码中英双语）。
class UpdateScreen extends StatefulWidget {
  const UpdateScreen({super.key});

  @override
  State<UpdateScreen> createState() => _UpdateScreenState();
}

enum _CheckState { checking, latest, hasUpdate, failed }

class _UpdateScreenState extends State<UpdateScreen> {
  static const String _releaseApi =
      'https://api.github.com/repos/l930203811/ZenFile/releases/latest';
  static const String _releasePageUrl =
      'https://github.com/l930203811/ZenFile/releases/latest';

  _CheckState _state = _CheckState.checking;
  String _currentVersion = '';
  String _latestVersion = '';
  String _latestPageUrl = _releasePageUrl;
  List<Map<String, String>> _assets = [];

  bool _downloading = false;
  double? _downloadProgress; // null = 服务器未给 contentLength，用不确定进度条

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    try {
      final info = await PackageInfo.fromPlatform();
      _currentVersion = info.version;
    } catch (_) {
      _currentVersion = '';
    }
    await _check();
  }

  /// 比较两个语义化版本号（允许 v 前缀）。a>b 返回正数，相等 0，a<b 负数。
  static int _compareVersions(String a, String b) {
    List<int> parse(String v) => v
        .replaceFirst(RegExp(r'^[vV]'), '')
        .split('.')
        .map((e) => int.tryParse(e.trim()) ?? 0)
        .toList();
    final pa = parse(a);
    final pb = parse(b);
    final len = pa.length > pb.length ? pa.length : pb.length;
    for (var i = 0; i < len; i++) {
      final x = i < pa.length ? pa[i] : 0;
      final y = i < pb.length ? pb[i] : 0;
      if (x != y) return x - y;
    }
    return 0;
  }

  Future<void> _check() async {
    setState(() {
      _state = _CheckState.checking;
      _assets = [];
    });
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
    try {
      final req = await client
          .getUrl(Uri.parse(_releaseApi))
          .timeout(const Duration(seconds: 10));
      req.headers.set(HttpHeaders.acceptHeader, 'application/vnd.github+json');
      req.headers.set(HttpHeaders.userAgentHeader, 'ZenFile-Update-Checker');
      final resp =
          await req.close().timeout(const Duration(seconds: 10));
      final body = await resp.transform(utf8.decoder).join();
      if (resp.statusCode != 200) {
        throw HttpException('HTTP ${resp.statusCode}');
      }
      final json = jsonDecode(body) as Map<String, dynamic>;
      final tag = (json['tag_name'] as String? ?? '').trim();
      if (tag.isEmpty) throw const FormatException('empty tag_name');
      final assets = <Map<String, String>>[
        for (final a in (json['assets'] as List? ?? const []))
          if (a is Map && a['name'] is String && a['browser_download_url'] is String)
            {'name': a['name'] as String, 'url': a['browser_download_url'] as String},
      ];
      if (!mounted) return;
      setState(() {
        _latestVersion = tag;
        _latestPageUrl = (json['html_url'] as String?) ?? _releasePageUrl;
        _assets = assets;
        _state = _currentVersion.isNotEmpty &&
                _compareVersions(tag, _currentVersion) > 0
            ? _CheckState.hasUpdate
            : _CheckState.latest;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _state = _CheckState.failed);
    } finally {
      client.close();
    }
  }

  /// 按设备 ABI 选择最匹配的 APK 资产；无匹配则回退到第一个 .apk。
  Future<String?> _pickAssetUrl() async {
    if (_assets.isEmpty) return null;
    final abis = <String>[];
    if (Platform.isAndroid) {
      try {
        final info = await DeviceInfoPlugin().androidInfo;
        abis.addAll(info.supportedAbis);
      } catch (_) {}
    }
    for (final abi in abis) {
      for (final a in _assets) {
        if (a['name']!.contains(abi)) return a['url'];
      }
    }
    for (final a in _assets) {
      if (a['name']!.endsWith('.apk')) return a['url'];
    }
    return null;
  }

  Future<void> _downloadAndInstall() async {
    if (_downloading) return;
    final url = await _pickAssetUrl();
    if (url == null) {
      // 没有可下载资产 → 退回浏览器打开 Release 页
      await _openUrl(_latestPageUrl);
      return;
    }
    setState(() {
      _downloading = true;
      _downloadProgress = 0;
    });
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
    try {
      final req = await client.getUrl(Uri.parse(url));
      req.headers.set(HttpHeaders.userAgentHeader, 'ZenFile-Update-Checker');
      final resp = await req.close();
      if (resp.statusCode != 200) {
        throw HttpException('HTTP ${resp.statusCode}');
      }
      final dir = await getTemporaryDirectory();
      final file = File('${dir.path}/ZenFile_update_$_latestVersion.apk');
      final sink = file.openWrite();
      final total = resp.contentLength; // -1 表示未知
      var received = 0;
      await for (final chunk in resp) {
        sink.add(chunk);
        received += chunk.length;
        if (total > 0 && mounted) {
          setState(() => _downloadProgress = received / total);
        }
      }
      await sink.flush();
      await sink.close();
      if (!mounted) return;
      setState(() {
        _downloading = false;
        _downloadProgress = null;
      });
      // 走统一安装链路（VirusTotal 扫描开关、系统安装器等逻辑与文件管理器一致）
      await ApkInstallerService.installApk(context, file.path);
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _downloading = false;
        _downloadProgress = null;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(L10n.of(context).update_download_failed),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } finally {
      client.close();
    }
  }

  Future<void> _openUrl(String url) async {
    try {
      await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = L10n.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.ui_view_update),
        centerTitle: true,
      ),
      body: ListView(
        physics: const BouncingScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          _buildGitHubCheckCard(theme, l10n),
          const SizedBox(height: 16),
          _buildDownloadLinksCard(theme, l10n),
          const SizedBox(height: 16),
          Align(
            alignment: Alignment.centerLeft,
            child: Text(
              l10n.msg305734ce,
              style: theme.textTheme.titleMedium
                  ?.copyWith(fontWeight: FontWeight.bold),
            ),
          ),
          const SizedBox(height: 8),
          _buildV216Changelog(theme),
        ],
      ),
    );
  }

  // ── ① GitHub 版本检测 ──────────────────────────────────────────────

  Widget _buildGitHubCheckCard(ThemeData theme, L10n l10n) {
    return Container(
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
        border:
            Border.all(color: theme.colorScheme.primary.withOpacity(0.15)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Broken.refresh,
                  size: 18, color: theme.colorScheme.primary),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  l10n.update_github_check,
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.bold,
                    color: theme.colorScheme.onSurface.withOpacity(0.9),
                  ),
                ),
              ),
              if (_state != _CheckState.checking && !_downloading)
                IconButton(
                  visualDensity: VisualDensity.compact,
                  tooltip: l10n.update_retry,
                  icon: Icon(Broken.refresh_2,
                      size: 18, color: theme.colorScheme.primary),
                  onPressed: _check,
                ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            l10n.update_current_version(
                _currentVersion.isEmpty ? '—' : _currentVersion),
            style: TextStyle(
              fontSize: 13,
              color: theme.colorScheme.onSurface.withOpacity(0.6),
              fontFamily: 'LexendDeca',
            ),
          ),
          const SizedBox(height: 12),
          _buildCheckStatus(theme, l10n),
        ],
      ),
    );
  }

  Widget _buildCheckStatus(ThemeData theme, L10n l10n) {
    switch (_state) {
      case _CheckState.checking:
        return Row(
          children: [
            SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: theme.colorScheme.primary,
              ),
            ),
            const SizedBox(width: 10),
            Text(l10n.update_checking,
                style: TextStyle(
                    fontSize: 13.5,
                    color: theme.colorScheme.onSurface.withOpacity(0.75))),
          ],
        );
      case _CheckState.latest:
        return Row(
          children: [
            Icon(Icons.check_circle_rounded,
                size: 18, color: theme.colorScheme.primary),
            const SizedBox(width: 8),
            Expanded(
              child: Text(l10n.update_latest,
                  style: TextStyle(
                      fontSize: 13.5,
                      fontWeight: FontWeight.w600,
                      color: theme.colorScheme.onSurface.withOpacity(0.85))),
            ),
          ],
        );
      case _CheckState.failed:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.error_outline_rounded,
                    size: 18, color: theme.colorScheme.error),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(l10n.update_check_failed,
                      style: TextStyle(
                          fontSize: 13.5,
                          color: theme.colorScheme.onSurface.withOpacity(0.85))),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                FilledButton.tonalIcon(
                  onPressed: _check,
                  icon: const Icon(Broken.refresh_2, size: 16),
                  label: Text(l10n.update_retry),
                ),
                const SizedBox(width: 10),
                TextButton.icon(
                  onPressed: () => _openUrl(_releasePageUrl),
                  icon: Icon(Icons.open_in_new,
                      size: 14,
                      color: theme.colorScheme.onSurface.withOpacity(0.5)),
                  label: Text(
                    l10n.update_view_github,
                    style: TextStyle(
                        fontSize: 12.5,
                        color: theme.colorScheme.onSurface.withOpacity(0.6)),
                  ),
                ),
              ],
            ),
          ],
        );
      case _CheckState.hasUpdate:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.new_releases_rounded,
                    size: 18, color: theme.colorScheme.primary),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    l10n.update_new_version(_latestVersion),
                    style: TextStyle(
                        fontSize: 13.5,
                        fontWeight: FontWeight.w700,
                        color: theme.colorScheme.primary),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            if (_downloading) ...[
              LinearProgressIndicator(
                value: _downloadProgress,
                borderRadius: BorderRadius.circular(4),
              ),
              const SizedBox(height: 6),
              Text(
                _downloadProgress == null
                    ? l10n.update_downloading
                    : '${l10n.update_downloading} ${(_downloadProgress! * 100).toStringAsFixed(0)}%',
                style: TextStyle(
                    fontSize: 12.5,
                    color: theme.colorScheme.onSurface.withOpacity(0.6)),
              ),
            ] else
              Row(
                children: [
                  FilledButton.icon(
                    onPressed: _downloadAndInstall,
                    icon: const Icon(Broken.document_download, size: 16),
                    label: Text(l10n.update_download_install),
                  ),
                  const SizedBox(width: 10),
                  TextButton.icon(
                    onPressed: () => _openUrl(_latestPageUrl),
                    icon: Icon(Icons.open_in_new,
                        size: 14,
                        color: theme.colorScheme.onSurface.withOpacity(0.5)),
                    label: Text(
                      l10n.update_view_github,
                      style: TextStyle(
                          fontSize: 12.5,
                          color: theme.colorScheme.onSurface.withOpacity(0.6)),
                    ),
                  ),
                ],
              ),
          ],
        );
    }
  }

  // ── ② 网盘下载链接（自「关于」页迁移） ──────────────────────────────

  Widget _buildDownloadLinksCard(ThemeData theme, L10n l10n) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceVariant.withOpacity(0.2),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: theme.colorScheme.onSurface.withOpacity(0.06)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.download_rounded,
                  size: 18, color: theme.colorScheme.primary),
              const SizedBox(width: 8),
              Text(l10n.zenfilev1041,
                  style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.bold,
                      color: theme.colorScheme.onSurface.withOpacity(0.9))),
            ],
          ),
          const SizedBox(height: 12),
          _buildDownloadLink(theme, l10n.msg9d287020, 'https://1820255615.share.123pan.cn/123pan/WrRojv-JHpnA?pwd=hBR2', Icons.cloud_outlined),
          const SizedBox(height: 8),
          _buildDownloadLink(theme, l10n.msgb2b41b6a, 'https://115cdn.com/s/swsho4j3hc6?password=m490', Icons.cloud_queue),
          const SizedBox(height: 8),
          _buildDownloadLink(theme, l10n.msg77ee718b, 'https://pan.baidu.com/s/1kYSfzTriRXwQPRL_c5Awig?pwd=xg94', Icons.cloud_circle),
          const SizedBox(height: 8),
          _buildDownloadLink(theme, l10n.msgbff1432a, 'https://pan.quark.cn/s/e6081a88d463', Icons.cloud),
          const SizedBox(height: 8),
          _buildDownloadLink(theme, l10n.msge03395d0, 'https://mypikpak.com/s/VOxGdQB3fVNO32sq_I3o2Wkmo2', Icons.flight),
        ],
      ),
    );
  }

  Widget _buildDownloadLink(ThemeData theme, String name, String url, IconData icon) {
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: () => _openUrl(url),
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

  // ── ③ 更新日志（自「关于」页迁移，硬编码中英双语，不走 l10n） ──────

  Widget _buildV216Changelog(ThemeData theme) {
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
                child: Text('v2.1.6', style: TextStyle(color: theme.colorScheme.primary, fontSize: 13, fontWeight: FontWeight.bold, fontFamily: 'LexendDeca')),
              ),
              const SizedBox(width: 10),
              Text('2026-09-23', style: TextStyle(fontSize: 12, color: theme.colorScheme.onSurface.withOpacity(0.4))),
            ],
          ),
          gap(14),

          // ══════════════ 中文 ══════════════
          section('\u2728 新功能'),
          item('新增「音频输出（AO）模式」设置（播放页 → 音效与均衡器）：Auto (AudioTrack) / AudioTrack 16-bit / OpenSL ES 三档，默认 AudioTrack 优先'),
          item('修复与 RootlessJamesDSP 等免 Root 音效软件不兼容：应用按 Android 官方协议广播音频效果控制会话，音效软件可正常接管，不再提示「不支持的应用程序」'),
          item('修复播放中切换音频输出模式不生效的问题，切换立即生效；修复切歌时音轨重建导致的断音'),

          divider(),

          section('\u{1f3a8} 界面与交互'),
          item('修复均衡器面板标题在部分语言下超出窗口'),
          item('服务器列表副标题类型与 IP 分行显示，IP 不再被省略号截断'),
          item('SMB 向导局域网扫描提速（约 3~4 倍）'),

          divider(),

          section('\u{1f41b} 问题修复'),
          item('修复仅大小写不同的重命名（如 a.jpg → a.JPG）不生效的问题（本地与 Root/Shizuku 受限路径均修复）'),
          item('修复本地/远程文件夹「解密后再原地加密」目录名不变密文的问题'),
          item('加密文件打开优化：原地加密的 APK/DOC/ZIP 点击后可临时解密并打开，操作结束自动清理；保险箱文件夹支持直接浏览'),
          item('修复分类页已删除音频重新出现的问题'),
          item('修复保险箱备份恢复后列表为空的问题'),
          item('修复 WebDAV 与本地面包屑导航错位的问题'),
          item('修复 SMB 匿名登录在 SMB 3.x 服务器上的崩溃（升级 smbj 0.14.0 + SMB2 方言自动兜底）'),

          langDivider(),

          // ══════════════ English ══════════════
          section('\u2728 New Features'),
          item('New "Audio Output (AO) Mode" setting (Playback → Sound Effects & Equalizer): Auto (AudioTrack) / AudioTrack 16-bit / OpenSL ES, AudioTrack-first by default'),
          item('Fixed incompatibility with rootless audio effect apps (e.g. RootlessJamesDSP): the app now broadcasts audio effect control sessions per Android\'s official protocol, so effect apps can take over normally ("unsupported app" no longer shown)'),
          item('Fixed switching AO mode during playback not taking effect — changes apply immediately; fixed audio gaps when switching tracks'),

          divider(),

          section('\u{1f3a8} UI & Interaction'),
          item('Fixed the equalizer panel title overflowing the window in some languages'),
          item('Server list subtitle now shows type and IP on separate lines; IPs are no longer truncated'),
          item('LAN share scanning in the SMB wizard is ~3-4x faster'),

          divider(),

          section('\u{1f41b} Bug Fixes'),
          item('Fixed case-only renames (e.g. a.jpg → a.JPG) not taking effect (local & Root/Shizuku restricted paths)'),
          item('Fixed folder names not becoming ciphertext when re-encrypting in place after decryption (local & remote)'),
          item('Improved opening encrypted files: in-place encrypted APK/DOC/ZIP can be temporarily decrypted and opened, auto-cleaned afterward; vault folders can be browsed directly'),
          item('Fixed deleted audio files reappearing in the category page'),
          item('Fixed empty file list after restoring vault backup'),
          item('Fixed breadcrumb navigation going to the wrong level (WebDAV & local root)'),
          item('Fixed SMB anonymous login crash on SMB 3.x servers (upgraded smbj to 0.14.0 with SMB2 dialect fallback)'),
        ],
      ),
    );
  }
}
