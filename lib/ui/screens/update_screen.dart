import 'dart:async';
import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:zenfile/l10n/generated/app_localizations.dart';

import '../../core/icon_fonts/broken_icons.dart';
import '../../services/apk_installer_service.dart';
import '../../services/net_proxy_service.dart';
import '../../services/preferences_service.dart';
import '../../services/update_check_service.dart';
import '../../services/webdav_debug_log.dart';

/// 「版本更新」全屏页面（入口在左抽屉：设置 与 关于ZenFile 之间）。
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
  static const String _releasePageUrl =
      'https://github.com/l930203811/ZenFile/releases/latest';

  _CheckState _state = _CheckState.checking;
  String _currentVersion = '';

  /// 远端最新 tag（如 `v2.1.7`）。**「已是最新」时也展示它** ——
  /// 用户据此分辨「真的联网查到了」还是「失败被静默吞掉」。
  String _remoteVersion = '';
  String _pageUrl = _releasePageUrl;
  List<UpdateAsset> _assets = const <UpdateAsset>[];

  /// 失败原因与 HTTP 状态码（决定提示文案；旧实现所有失败共用一句通用文案）。
  UpdateCheckError? _error;
  int? _httpStatus;

  /// 是否用过降级通道（网页 302）。用过 ⇒ 界面标注「无法应用内下载」。
  bool _usedFallback = false;

  /// 最近一次检测完成的时间。
  DateTime? _checkedAt;

  /// 自定义更新源（镜像 / 自建接口）地址；空 = GitHub 官方源。
  String _apiUrlOverride = '';

  bool _downloading = false;
  double? _downloadProgress; // null = 服务器未给 contentLength，用不确定进度条

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    _apiUrlOverride = PreferencesService.getUpdateApiUrl();
    try {
      final info = await PackageInfo.fromPlatform();
      _currentVersion = info.version;
    } catch (_) {
      _currentVersion = '';
    }
    await _check();
  }

  Future<void> _check() async {
    setState(() {
      _state = _CheckState.checking;
      _assets = const <UpdateAsset>[];
    });

    // 检测逻辑已抽到 [UpdateCheckService]（可注入、可单测）。旧实现写在 State 里，
    // 于是「没有真实新版本就永远测不了」「失败原因分不出来」两件事无解。
    // 关键修复（都在 service 里）：读响应体带超时、整次检测有总上限、
    // 拿不到本机版本号不再谎报「已是最新」、失败按原因分类、多通道自动降级。
    final result = await UpdateCheckService(
      apiUrlOverride: _apiUrlOverride,
      httpProxyProvider: NetProxyService.getHttpProxy,
      logger: WebdavDebugLog.log,
    ).check(_currentVersion);

    if (!mounted) return;
    setState(() {
      _remoteVersion = result.remoteVersion;
      _pageUrl = result.pageUrl.isNotEmpty ? result.pageUrl : _releasePageUrl;
      _assets = result.assets;
      _error = result.error;
      _httpStatus = result.httpStatus;
      _usedFallback = result.usedFallback;
      _checkedAt = DateTime.now();
      if (!result.ok) {
        _state = _CheckState.failed;
      } else {
        _state = result.hasUpdate ? _CheckState.hasUpdate : _CheckState.latest;
      }
    });
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
        if (a.name.contains(abi)) return a.url;
      }
    }
    for (final a in _assets) {
      if (a.name.endsWith('.apk')) return a.url;
    }
    return null;
  }

  Future<void> _downloadAndInstall() async {
    if (_downloading) return;
    final url = await _pickAssetUrl();
    if (url == null) {
      // 没有可下载资产（例如降级到了网页通道）→ 退回浏览器打开 Release 页
      await _openUrl(_pageUrl);
      return;
    }
    setState(() {
      _downloading = true;
      _downloadProgress = 0;
    });
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
    try {
      final req = await client
          .getUrl(Uri.parse(url))
          .timeout(const Duration(seconds: 15));
      req.headers.set(HttpHeaders.userAgentHeader, 'ZenFile-Update-Checker');
      final resp = await req.close().timeout(const Duration(seconds: 15));
      if (resp.statusCode != 200) {
        throw HttpException('HTTP ${resp.statusCode}');
      }
      final dir = await getTemporaryDirectory();
      final file = File('${dir.path}/ZenFile_update_$_remoteVersion.apk');
      final sink = file.openWrite();
      final total = resp.contentLength; // -1 表示未知
      var received = 0;
      // 下载同样要有超时：半开连接会让 `await for` 永远挂着（与检测同源的问题，
      // 在这里表现为「进度条永远停在某个百分比、也不报错」）。
      await for (final chunk in resp.timeout(
        const Duration(seconds: 30),
        onTimeout: (sink) => sink.addError(TimeoutException('download stalled')),
      )) {
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

  /// 失败提示：按原因分类。
  ///
  /// 旧实现所有失败共用一句「检查更新失败，请检查网络连接后重试」——
  /// 用户既分不清是没网、超时，还是被 GitHub 限速（未认证 60 次/小时/IP，
  /// 国内共享出口极易触发），也就无从采取正确的下一步。
  String _errorText(L10n l10n) {
    switch (_error) {
      case UpdateCheckError.network:
        return l10n.update_err_network;
      case UpdateCheckError.timeout:
        return l10n.update_err_timeout;
      case UpdateCheckError.rateLimited:
        return l10n.update_err_rate_limit;
      case UpdateCheckError.http:
        return l10n.update_err_http('${_httpStatus ?? '?'}');
      case UpdateCheckError.malformed:
        return l10n.update_err_malformed;
      case UpdateCheckError.versionUnknown:
        return l10n.update_err_version_unknown;
      case UpdateCheckError.unknown:
      case null:
        return l10n.update_check_failed;
    }
  }

  /// 「已是最新」时的自证信息：远端实际 tag + 本次检查时间。
  String _metaLine(L10n l10n) {
    final parts = <String>[];
    if (_remoteVersion.isNotEmpty) {
      parts.add(l10n.update_remote_version(_remoteVersion));
    }
    final t = _checkedAt;
    if (t != null) {
      final hh = t.hour.toString().padLeft(2, '0');
      final mm = t.minute.toString().padLeft(2, '0');
      parts.add(l10n.update_checked_at('$hh:$mm'));
    }
    return parts.join(' · ');
  }

  /// 自定义更新源（镜像 / 自建接口）。
  ///
  /// 留空 = GitHub 官方接口。校验规则直接复用
  /// [UpdateCheckService.isValidCustomUrl]，不在 UI 里再写一遍。
  Future<void> _openSourceDialog() async {
    final l10n = L10n.of(context);
    final theme = Theme.of(context);
    final controller = TextEditingController(text: _apiUrlOverride);

    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => ValueListenableBuilder<TextEditingValue>(
        valueListenable: controller,
        builder: (_, value, __) {
          final valid = UpdateCheckService.isValidCustomUrl(value.text);
          return AlertDialog(
            title: Text(l10n.update_source_dialog_title),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(l10n.update_source_dialog_desc,
                    style: const TextStyle(fontSize: 12.5, height: 1.5)),
                const SizedBox(height: 12),
                TextField(
                  controller: controller,
                  maxLines: 2,
                  minLines: 1,
                  keyboardType: TextInputType.url,
                  autocorrect: false,
                  decoration: InputDecoration(
                    hintText: l10n.update_source_hint,
                    hintStyle: const TextStyle(fontSize: 12),
                    border: const OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
                if (!valid) ...[
                  const SizedBox(height: 8),
                  Text(l10n.update_source_invalid,
                      style: TextStyle(
                          fontSize: 12, color: theme.colorScheme.error)),
                ],
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: Text(MaterialLocalizations.of(ctx).cancelButtonLabel),
              ),
              TextButton(
                // 地址非法时直接禁用「确定」，比让它失败一次再报错更清楚
                onPressed: valid ? () => Navigator.pop(ctx, true) : null,
                child: Text(MaterialLocalizations.of(ctx).okButtonLabel),
              ),
            ],
          );
        },
      ),
    );

    final value = controller.text.trim();
    controller.dispose();
    if (saved != true) return;

    await PreferencesService.saveUpdateApiUrl(value);
    if (!mounted) return;
    setState(() => _apiUrlOverride = value);
    await _check();
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
          _buildV300Changelog(theme),
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
          const SizedBox(height: 4),
          // 更新源：刻意放在本页而不是设置页 —— 它是「版本更新」专属配置，
          // 改完可立刻重试，也让用户一眼看清当前是不是走了镜像。
          GestureDetector(
            onTap: _openSourceDialog,
            behavior: HitTestBehavior.opaque,
            child: Row(
              children: [
                Icon(Icons.cloud_outlined,
                    size: 13, color: theme.colorScheme.onSurface.withOpacity(0.45)),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    '${l10n.update_source_label} · '
                    '${_apiUrlOverride.isEmpty ? l10n.update_source_default : l10n.update_source_custom}',
                    style: TextStyle(
                      fontSize: 12,
                      color: theme.colorScheme.onSurface.withOpacity(0.5),
                    ),
                  ),
                ),
              ],
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
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
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
            ),
            // 「已是最新」必须能自证：显示远端实际 tag 与检查时间，用户才能分辨
            // 「真的联网查到了」还是「请求失败被静默吞掉」。
            if (_metaLine(l10n).isNotEmpty) ...[
              const SizedBox(height: 6),
              Padding(
                padding: const EdgeInsets.only(left: 26),
                child: Text(
                  _metaLine(l10n),
                  style: TextStyle(
                      fontSize: 11.5,
                      color: theme.colorScheme.onSurface.withOpacity(0.5)),
                ),
              ),
            ],
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
                  child: Text(_errorText(l10n),
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
                    l10n.update_new_version(_remoteVersion),
                    style: TextStyle(
                        fontSize: 13.5,
                        fontWeight: FontWeight.w700,
                        color: theme.colorScheme.primary),
                  ),
                ),
              ],
            ),
            // 降级到网页通道时拿不到 assets ⇒ 只能跳浏览器。
            // 这里如实说明，避免用户以为「下载安装」按钮坏了。
            if (_usedFallback && _assets.isEmpty) ...[
              const SizedBox(height: 6),
              Row(
                children: [
                  Icon(Icons.info_outline_rounded,
                      size: 14,
                      color: theme.colorScheme.onSurface.withOpacity(0.5)),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      l10n.update_degraded_hint,
                      style: TextStyle(
                          fontSize: 12,
                          color: theme.colorScheme.onSurface.withOpacity(0.6)),
                    ),
                  ),
                ],
              ),
            ],
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
                    onPressed: () => _openUrl(_pageUrl),
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

  Widget _buildV300Changelog(ThemeData theme) {
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
                child: Text('v3.0.0', style: TextStyle(color: theme.colorScheme.primary, fontSize: 13, fontWeight: FontWeight.bold, fontFamily: 'LexendDeca')),
              ),
              const SizedBox(width: 10),
              Text('2026-09-25', style: TextStyle(fontSize: 12, color: theme.colorScheme.onSurface.withOpacity(0.4))),
            ],
          ),
          gap(14),

          // ══════════════ 中文 ══════════════
          section('\u2728 新功能'),
          item('全新四标签导航（分类 / 文件 / 传输 / 设置），默认移到底部：原顶部标签栏与抽屉入口重新归位，升级后自动迁移导航偏好'),
          item('「我的」页下线，设置收敛为底部导航第 4 项（内嵌渲染，不再 push 全屏路由），左抽屉不再重复提供入口'),
          item('启动期崩溃取证：基于 ApplicationExitInfo 自动留证（用户零操作）；启动路径去掉 runApp() 前的原生通道等待，修复启动阶段闪退'),
          item('版本更新页：GitHub 版本检测 + 应用内下载安装，「查看更新」由设置迁至左抽屉'),
          item('文本编辑器：工具箱与左抽屉可直接打开空白编辑器，右上角菜单可导入已有文本文件'),
          item('视频播放：进度条常驻开关、倍速与音量记忆、后台播放选择持久化'),
          item('图片查看器三态适配：适应宽度 / 适应高度 / 原始尺寸'),
          item('全局搜索支持直接跳转功能入口，搜索框移至顶部'),
          item('分类页新增自定义入口卡片（可开关）与每行显示列数（新增 2 列）'),
          item('剪贴板新增「粘贴并清除」'),

          divider(),

          section('\u{1f3a8} 界面与交互'),
          item('分类页顶部间距清零、卡片圆角收紧（14→8）、3 列卡片改为正方形，整体更紧凑'),
          item('顶部背景统一细边框；浏览操作栏移至底部并自动折叠展开'),
          item('单标签时隐藏空的标签页栏'),
          item('左抽屉移除「设置」入口；「查看更新」图标更换，与页内重试按钮区分'),
          item('右抽屉「常用功能」与「收藏夹」同时展开时不再出现两条分割线'),
          item('视频缩略图不再被中心播放图标覆盖，完整显示（列表/网格同步；音频封面图标保留）'),
          item('全局搜索提示词更新为「搜索文件、应用和设置」'),

          divider(),

          section('\u{1f41b} 问题修复'),
          item('修复自动清理缓存连诊断数据一并删除的问题：崩溃报告与调试日志被清空，导致每次启动重复提示「上次异常退出」且丢失事故现场；清理范围收窄为仅清缓存，固定保留 Backups / crash / Receive / 调试日志'),
          item('崩溃提示判据改为「报告确实存在于公共目录且从未提示过」，同一次崩溃只提示一次；Dart 层非致命错误不再被误报为异常退出'),
          item('修复版本检测读取响应体没有超时，导致永远停在「正在检查更新…」'),
          item('修复拿不到本机版本号时谎报「已是最新」且并未联网的问题'),
          item('检测失败不再静默：按网络不通 / 连接超时 / 请求频繁 / HTTP 错误 / 数据异常分类提示；「已是最新」同时显示远端版本与检查时间'),
          item('修复版本检测不走系统代理（Dart 默认只读进程环境变量，Android 上恒为空）'),
          item('官方 API 不可达时自动降级网页检测，并支持在页内填写自定义镜像源'),
          item('修复传输页网络入口无法跳转远程目录'),
          item('修复视频进度条常驻时半透明遮罩撑满全屏'),

          langDivider(),

          section('\u2728 New Features'),
          item('Brand-new 4-tab navigation (Categories / Files / Transfers / Settings), now at the bottom by default: top tabs and drawer entries are reorganized, and navigation preference migrates automatically on upgrade'),
          item('The "Me" page was retired; Settings is now the 4th tab, rendered inline instead of pushed as a full-screen route, and the left drawer no longer duplicates the entry'),
          item('Startup crash forensics based on ApplicationExitInfo (zero user action); removed native channel awaits before runApp(), fixing startup-stage crashes'),
          item('Version updates page: GitHub version detection with in-app download & install; the entry moved from Settings to the left drawer'),
          item('Text editor: open a blank editor directly from the toolbox or drawer, with an import option in the overflow menu'),
          item('Video playback: always-on progress bar switch, speed & volume memory, and persisted background-play preference'),
          item('Image viewer: three fit modes (width / height / actual size)'),
          item('Global search now jumps to feature entries directly; the search field moved to the top'),
          item('Category page: optional custom entry card and a new 2-column layout option'),
          item('Clipboard: new "paste and clear" action'),

          divider(),

          section('\u{1f3a8} UI & Interaction'),
          item('Category page: top spacing reset, card radius tightened (14 to 8), square cards at 3 columns - denser and cleaner'),
          item('Unified thin border on top backgrounds; browse action bar moved to the bottom with auto collapse/expand'),
          item('Empty tab bar is hidden when only one tab is open'),
          item('Left drawer: "Settings" entry removed; the update entry icon changed to avoid confusion with the in-page retry button'),
          item('Right drawer: no more double dividers when "Frequent features" and "Favorites" are both expanded'),
          item('Video thumbnails are no longer covered by the center play icon (list & grid; audio cover icons kept)'),
          item('Global search hint updated to "Search files, apps and settings"'),

          divider(),

          section('\u{1f41b} Bug Fixes'),
          item('Fixed auto cache cleanup deleting diagnostic data along with cache - crash reports and debug logs were wiped, causing a repeated "abnormal exit" notice on every launch and losing the crash scene; cleanup now preserves Backups / crash / Receive / debug log'),
          item('Crash notices now require that the report really exists and was never notified, so each crash is reported only once; non-fatal Dart errors are no longer misreported as abnormal exits'),
          item('Fixed the version check hanging forever on "Checking for updates..." because reading the response body had no timeout'),
          item('Fixed falsely reporting "up to date" without any network request when the local version could not be read'),
          item('Version check failures are no longer silent: classified into network / timeout / rate limit / HTTP error / malformed data; "up to date" now also shows the remote version and check time'),
          item('Fixed the version check ignoring the system proxy (Dart only reads process env vars, which are always empty on Android)'),
          item('Falls back to web-based detection when the official API is unreachable, and supports a custom mirror URL'),
          item('Fixed the network entry on the Transfers page not opening the remote directory'),
          item('Fixed the always-on video progress bar causing a full-screen translucent overlay'),
        ],
      ),
    );
  }
}
