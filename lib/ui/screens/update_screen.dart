import 'dart:async';
import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:zenfile/l10n/generated/app_localizations.dart';

import '../../core/icon_fonts/broken_icons.dart';
import '../../services/apk_installer_service.dart';
import '../../services/net_proxy_service.dart';
import '../../services/preferences_service.dart';
import '../../services/update_apk_cache.dart';
import '../../services/update_check_service.dart';
import '../../services/webdav_debug_log.dart';

/// 「版本更新」全屏页面（入口在左抽屉：设置 与 关于ZenFile 之间）。
///
/// 结构：
/// ① GitHub 版本检测卡片 —— 打开页面自动检测一次，失败/想重查可手动重试；
///    发现新版本后按设备 ABI 匹配 Release 资产，应用内下载并走统一安装链路
///    [ApkInstallerService.installApk]（含 VirusTotal 扫描等既有逻辑）；
///    同时展示该 Release 的**更新日志**（可滚动查看 + 一键复制，方便用户自行翻译）。
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

  /// 远端 Release 的更新日志正文（Markdown 原文）。
  /// 只有 API 通道拿得到；网页降级通道为空 ⇒ 界面显示 [update_changelog_empty]。
  String _releaseNotes = '';

  /// 失败原因与 HTTP 状态码（决定提示文案；旧实现所有失败共用一句通用文案）。
  UpdateCheckError? _error;
  int? _httpStatus;

  /// 是否用过降级通道（网页 302）。用过 ⇒ 界面标注「无法应用内下载」。
  bool _usedFallback = false;

  /// 最近一次检测完成的时间。
  DateTime? _checkedAt;

  /// 自定义更新源（镜像 / 自建接口）地址；空 = GitHub 官方源。
  String _apiUrlOverride = '';

  /// 「启动时弹窗提醒」总开关。与启动弹窗的「不再提醒」按钮共用同一个存储键
  /// （`update_prompt_enabled`）⇒ 用户在任何一处改，另一处立刻反映同样的值。
  bool _updatePromptEnabled = true;

  bool _downloading = false;
  double? _downloadProgress; // null = 服务器未给 contentLength，用不确定进度条

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    _apiUrlOverride = PreferencesService.getUpdateApiUrl();
    _updatePromptEnabled = PreferencesService.getUpdatePromptEnabled();
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
      // GitHub 的 release body 是 CRLF 原文，统一成 LF：Flutter 的 Text 对
      // `\r\n` 会多渲染一个空行，正文里每行之间都被拉开。
      _releaseNotes = result.releaseNotes.replaceAll('\r\n', '\n');
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
    // catch 里要删掉半成品，故路径在 try 外声明；解析本身留在 try 内
    // （解析若抛错也必须落到统一的失败分支，不能让按钮永远停在「下载中」）。
    String? filePath;
    try {
      // 目标路径 + 清理都交给 [UpdateApkCache]（安装包缓存的唯一管理者）：
      // 下载前先清掉历史更新包 —— 用户点「下载安装」就说明上一轮已经结束，
      // 而自动下载走系统安装器时应用拿不到「装完了没」的回报，只能挑这种
      // 「上一轮必然已结束」的时机做清理。
      final file = await UpdateApkCache.targetFile(_remoteVersion);
      filePath = file.path;
      await UpdateApkCache.sweep(keepPath: file.path);
      final req = await client
          .getUrl(Uri.parse(url))
          .timeout(const Duration(seconds: 15));
      req.headers.set(HttpHeaders.userAgentHeader, 'ZenFile-Update-Checker');
      final resp = await req.close().timeout(const Duration(seconds: 15));
      if (resp.statusCode != 200) {
        throw HttpException('HTTP ${resp.statusCode}');
      }
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
      // 装完之后不在这里删：走系统安装器时无法得知用户何时确认，
      // 立刻删会让安装器读不到文件（详见 [UpdateApkCache] 的说明）。
      await ApkInstallerService.installApk(context, file.path);
    } catch (_) {
      // 下载失败/被取消留下的半成品必须立刻删掉：它不会被复用（重下会覆盖），
      // 留着只会一个版本一个文件地堆在私有缓存里。
      if (filePath != null) await UpdateApkCache.discard(filePath);
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

  /// 把更新日志正文整段写进剪贴板 —— 用户常需要拿到原文去翻译 / 转发。
  ///
  /// 只复制正文（不带「发现新版本 vX」之类的界面文案），这样粘出去的就是
  /// 干净的 release notes。
  Future<void> _copyChangelog() async {
    if (_releaseNotes.isEmpty) return;
    final messenger = ScaffoldMessenger.of(context);
    final l10n = L10n.of(context);
    await Clipboard.setData(ClipboardData(text: _releaseNotes));
    if (!mounted) return;
    messenger.showSnackBar(
      SnackBar(
        content: Text(l10n.msg4fb42e6e), // 「已复制到剪贴板」
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  /// 清除「已忽略该版本」标记，让下次启动重新弹窗提示。
  Future<void> _restoreIgnoredPrompt() async {
    await PreferencesService.saveIgnoredUpdateVersion('');
    if (!mounted) return;
    setState(() {});
  }

  /// 开关「启动时弹窗提醒」。
  ///
  /// 只写一个键（`update_prompt_enabled`），启动弹窗的「不再提醒」按钮写的是**同一个键**
  /// ⇒ 两处天然同步，不存在「页面上开着、启动却不弹」这种自相矛盾。
  Future<void> _setUpdatePromptEnabled(bool value) async {
    setState(() => _updatePromptEnabled = value);
    await PreferencesService.saveUpdatePromptEnabled(value);
  }

  /// 当前显示的远端版本是否已被用户「忽略」（即启动弹窗不会再提示它）。
  ///
  /// 判据与 [main.dart] 的启动弹窗**完全一致**（走同一个存储键、同一个比较），
  /// 否则会出现「这里说已忽略、启动却还弹」这种自相矛盾。
  bool _isRemoteIgnored() {
    if (_remoteVersion.isEmpty) return false;
    return UpdateCheckService.isVersionIgnored(
      _remoteVersion,
      PreferencesService.getIgnoredUpdateVersion(),
    );
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
          _buildChangelogList(theme, l10n),
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
            theme.colorScheme.primary.withValues(alpha: 0.08),
            theme.colorScheme.secondary.withValues(alpha: 0.04),
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(16),
        border:
            Border.all(color: theme.colorScheme.primary.withValues(alpha: 0.15)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              // 标题图标 = 「系统更新」箭头（原来用 Broken.refresh，和右侧「重试」
              // 按钮的 refresh_2 撞脸，看不出这是「版本检测」而不是「刷新」）。
              Icon(Icons.system_update_alt_rounded,
                  size: 18, color: theme.colorScheme.primary),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  l10n.update_github_check,
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.bold,
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.9),
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
              color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
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
                    size: 13, color: theme.colorScheme.onSurface.withValues(alpha: 0.45)),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    '${l10n.update_source_label} · '
                    '${_apiUrlOverride.isEmpty ? l10n.update_source_default : l10n.update_source_custom}',
                    style: TextStyle(
                      fontSize: 12,
                      color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
                    ),
                  ),
                ),
              ],
            ),
          ),
          // 启动时「发现新版本」弹窗的总开关（与弹窗里的「不再提醒」同一个键）。
          // 关掉后启动检测连网络都不发（见 main.dart 的 _checkUpdateOnStartup）。
          Row(
            children: [
              Icon(
                Icons.notifications_active_outlined,
                size: 13,
                color: theme.colorScheme.onSurface.withValues(alpha: 0.45),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  l10n.update_startup_prompt,
                  style: TextStyle(
                    fontSize: 12,
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
                  ),
                ),
              ),
              Switch(
                value: _updatePromptEnabled,
                activeColor: theme.colorScheme.primary,
                onChanged: _setUpdatePromptEnabled,
              ),
            ],
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
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.75))),
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
                          color: theme.colorScheme.onSurface.withValues(alpha: 0.85))),
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
                      color: theme.colorScheme.onSurface.withValues(alpha: 0.5)),
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
                          color: theme.colorScheme.onSurface.withValues(alpha: 0.85))),
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
                      color: theme.colorScheme.onSurface.withValues(alpha: 0.5)),
                  label: Text(
                    l10n.update_view_github,
                    style: TextStyle(
                        fontSize: 12.5,
                        color: theme.colorScheme.onSurface.withValues(alpha: 0.6)),
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
                      color: theme.colorScheme.onSurface.withValues(alpha: 0.5)),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      l10n.update_degraded_hint,
                      style: TextStyle(
                          fontSize: 12,
                          color: theme.colorScheme.onSurface.withValues(alpha: 0.6)),
                    ),
                  ),
                ],
              ),
            ],
            // 用户曾在启动弹窗里点过「忽略」⇒ 给他一个恢复入口
            // （否则「不再弹窗」是个不可逆操作，点错了没法挽回）。
            if (_isRemoteIgnored()) ...[
              const SizedBox(height: 6),
              Row(
                children: [
                  Icon(
                    Icons.notifications_off_outlined,
                    size: 14,
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      l10n.update_ignored_hint,
                      style: TextStyle(
                        fontSize: 12,
                        color: theme.colorScheme.onSurface.withValues(
                          alpha: 0.6,
                        ),
                      ),
                    ),
                  ),
                  TextButton(
                    onPressed: _restoreIgnoredPrompt,
                    style: TextButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                    ),
                    child: Text(
                      l10n.ui_restore_default,
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
                ],
              ),
            ],
            const SizedBox(height: 12),
            _buildChangelogBlock(theme, l10n),
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
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.6)),
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
                        color: theme.colorScheme.onSurface.withValues(alpha: 0.5)),
                    label: Text(
                      l10n.update_view_github,
                      style: TextStyle(
                          fontSize: 12.5,
                          color: theme.colorScheme.onSurface.withValues(alpha: 0.6)),
                    ),
                  ),
                ],
              ),
          ],
        );
    }
  }

  // ── ①.5 远端 Release 的更新日志（查看 + 复制） ──────────────────────

  /// 远端 Release 的更新日志：可滚动查看（正文可选中）+ 一键复制。
  ///
  /// 为什么按纯文本呈现而不是渲染 Markdown：**这个功能不值得新增依赖**（pubspec
  /// 是红线）。GitHub 的 release notes 本身就是 Markdown 原文，原样展示既不失真，
  /// 也正好方便用户整段复制出去翻译 —— 那才是本区块的主要用途。
  Widget _buildChangelogBlock(ThemeData theme, L10n l10n) {
    final hasNotes = _releaseNotes.isNotEmpty;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(
              Icons.article_outlined,
              size: 15,
              color: theme.colorScheme.primary,
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                l10n.msg305734ce, // 「更新日志」
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.85),
                ),
              ),
            ),
            if (hasNotes)
              TextButton.icon(
                onPressed: _copyChangelog,
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                ),
                icon: Icon(
                  Broken.copy,
                  size: 14,
                  color: theme.colorScheme.primary,
                ),
                label: Text(
                  l10n.ui_copy,
                  style: const TextStyle(fontSize: 12.5),
                ),
              ),
          ],
        ),
        const SizedBox(height: 6),
        Container(
          width: double.infinity,
          // ⚠️ 高度必须有界：外层是本页的 ListView，这里再套滚动容器时若不给
          // maxHeight，会直接抛「Vertical viewport was given unbounded height」。
          constraints: const BoxConstraints(maxHeight: 220),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: theme.colorScheme.surface.withValues(alpha: 0.5),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: theme.colorScheme.onSurface.withValues(alpha: 0.08),
            ),
          ),
          child: hasNotes
              ? Scrollbar(
                  child: SingleChildScrollView(
                    child: SelectableText(
                      _releaseNotes,
                      style: TextStyle(
                        fontSize: 12.5,
                        height: 1.55,
                        color: theme.colorScheme.onSurface.withValues(
                          alpha: 0.8,
                        ),
                      ),
                    ),
                  ),
                )
              : Text(
                  // 网页降级通道拿不到正文 ⇒ 明确告知，而不是给一块空白。
                  l10n.update_changelog_empty,
                  style: TextStyle(
                    fontSize: 12.5,
                    height: 1.5,
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
                  ),
                ),
        ),
      ],
    );
  }

  // ── ② 网盘下载链接（自「关于」页迁移） ──────────────────────────────

  Widget _buildDownloadLinksCard(ThemeData theme, L10n l10n) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceVariant.withValues(alpha: 0.2),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: theme.colorScheme.onSurface.withValues(alpha: 0.06)),
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
                      color: theme.colorScheme.onSurface.withValues(alpha: 0.9))),
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
          color: theme.colorScheme.surfaceVariant.withValues(alpha: 0.2),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: theme.colorScheme.onSurface.withValues(alpha: 0.06)),
        ),
        child: Row(
          children: [
            Icon(icon, size: 18, color: theme.colorScheme.primary.withValues(alpha: 0.7)),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                name,
                style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w500, color: theme.colorScheme.onSurface.withValues(alpha: 0.85)),
              ),
            ),
            Icon(Icons.open_in_new, size: 14, color: theme.colorScheme.onSurface.withValues(alpha: 0.35)),
          ],
        ),
      ),
    );
  }

  // ── ③ 更新日志（自「关于」页迁移，硬编码中英双语，不走 l10n） ──────
  //
  // 2026-09-28 改版（用户要求）：
  //   · **不再「只留当前版本一张卡片」** —— 旧版本日志**保留**，只是默认**折叠**；
  //   · 当前版本**始终展开**（用户要求「新版本日志不要折叠」）；
  //   · 每张卡片**各带一个复制按钮**，把该版中英双语全文复制为**纯文本** ——
  //     用户常需要粘到别处（翻译工具 / 聊天 / 论坛）阅读；
  //   · 界面与复制文本**同源**（都自 [_Changelog] 生成）⇒ 不会出现
  //     「界面改了、复制出去的还是旧文案」这种偏移。
  //
  // 换版时只做两件事：① 在 [_changelogs] **最前面**插入新版本的 [_Changelog]；
  // ② 把 [_latestChangelogVersion] 改成新版本号。其余卡片会自动变为折叠态。

  /// 当前版本（那张始终展开、不可折叠的卡片）的版本号。
  static const String _latestChangelogVersion = 'v3.6.7';

  /// 全部版本的更新日志，**最新在最前**。
  static const List<_Changelog> _changelogs = <_Changelog>[
    _v367,
    _v366,
    _v365,
    _v364,
    _v363,
    _v362,
    _v361,
    _v360,
    _v359,
    _v358,
    _v357,
    _v356,
    _v355,
    _v354,
    _v353,
    _v352,
    _v351,
    _v350,
    _v341,
    _v340,
    _v330,
    _v320,
  ];

  /// ── 当前版本：v3.6.7 ────────────────────────────────────────────────
  static const _Changelog _v367 = _Changelog(
    version: 'v3.6.7',
    date: '2026-10-26',
    zh: [
      _ChangeSection('✨ 新功能', [
        '新增 SOCKS5 代理：FTP / SFTP / WebDAV / SMB 远程连接可按连接单独配置 SOCKS5 代理（支持用户名 / 口令鉴权），经代理访问虚拟内网中的网盘；在添加 / 编辑连接向导的「代理设置」中开启',
        '「应用克隆」替代原「应用分身」：APK 长按菜单与操作面板新增「克隆应用」，自动改包名并重新签名，生成可与原应用共存安装的克隆安装包，无需 Shizuku / root；克隆管理入口移至「应用管理」页顶栏',
        '歌词在线搜索升级：自动模式同时并发搜索 QQ 音乐 / 酷狗 / LRCLIB 三个歌词源，结果合并展示并标注来源；原「歌词搜索源」设置入口移除，统一收敛到在线搜索弹窗',
        '删除确认弹窗新增「移入回收站」勾选框：勾选后本次删除改为移入系统回收站',
      ]),
      _ChangeSection('✨ 界面优化', [
        '「连接」与「设置」页改为全屏显示：自动隐藏顶栏（抽屉 / 搜索 / 常用功能行），内容更沉浸；按返回键可从这两页回到分类页',
        '关闭「导航栏常驻其他页面」时，「浏览」「连接」「设置」页不再显示底部导航栏，仅分类页常显（开启常驻时行为不变）',
        '歌词 classic 风格按「已播放 / 当前播放 / 未播放」三态着色',
      ]),
      _ChangeSection('🐛 问题修复', [
        '修复 SAF 远程连接无法编辑的问题：现在可以直接重命名（GitHub issue #44）',
        '修复浏览页波形进度条与 PDF 双指缩放场景下，慢速点击 / 长按因手势竞争而失效的问题',
      ]),
    ],
    en: [
      _ChangeSection('✨ New Features', [
        'New SOCKS5 proxy: each FTP / SFTP / WebDAV / SMB remote connection can be configured with its own SOCKS5 proxy (username / password auth supported), letting you reach intranet-only network drives through the proxy; enable it under "Proxy settings" in the connection wizard',
        '"App clone" replaces the previous "App clones": the APK long-press menu and action sheet gain "Clone app" — the APK is repacked with a new package name and signature so the clone can be installed alongside the original, no Shizuku / root required; the clone manager entry moves to the top bar of the App management page',
        'Lyrics online search upgraded: auto mode now queries QQ Music / Kugou / LRCLIB in parallel, merging the results with their sources labelled; the separate "lyrics search source" setting is removed and folded into the online search dialog',
        'The delete confirmation dialog gains a "Move to recycle bin" checkbox: when checked, the deletion becomes a move to the system recycle bin',
      ]),
      _ChangeSection('✨ Interface', [
        'The Connections and Settings pages are now full-screen: the top bar (drawer / search / quick actions) hides automatically for a more immersive view; press back to return to the category page from either',
        'When "Keep the nav bar on other pages" is off, the Browse / Connections / Settings pages no longer show the bottom nav bar — only the category page keeps it (unchanged when the toggle is on)',
        'The classic lyric style now colours lines by state — played / current / unplayed',
      ]),
      _ChangeSection('🐛 Fixes', [
        'Fixed SAF remote connections being impossible to edit: they can now be renamed directly (GitHub issue #44)',
        'Fixed slow taps / long presses failing on the browse waveform seekbar and in PDF two-finger zoom due to gesture competition',
      ]),
    ],
  );

  /// ── v3.6.6 ──────────────────────────────────────────────────────────
  static const _Changelog _v366 = _Changelog(
    version: 'v3.6.6',
    date: '2026-10-25',
    zh: [
      _ChangeSection('✨ 新功能', [
        '删除文件确认弹窗现在会列出待删条目：每项显示文件类型图标与文件名，弹窗高度随条目数量自适应——条目少时是一行紧凑小条，条目多时是限高可滚动的列表；超过 50 项时末尾汇总显示「还有 N 项」',
        '文件操作菜单新增「用文本编辑器打开」：任意非图音视、非压缩包的文件都能直接用内置文本编辑器打开并编辑，不必再靠改后缀名绕过',
      ]),
      _ChangeSection('✨ 界面焕新', [
        '浏览页标签栏右侧的按钮改为弹出菜单：多标签时提供「关闭当前标签页」与「关闭所有标签页」两个选项（当前在上、所有在下），仅一个标签页时只显示「关闭当前标签页」；选择「关闭所有标签页」时不再二次确认，直接关闭全部标签页',
        '设置—导航栏设置中的「导航栏位置」选项改为与「自定义快捷方式」页面同款的下拉选择器，并在下方新增 5 个底部导航槽位入口；两处槽位共用同一份配置，改动实时同步',
        '顶栏最左侧的抽屉入口图标由三点改为三横线，采用与顶栏其他按钮一致的高亮色断线描边风格',
      ]),
      _ChangeSection('🐛 问题修复', [
        '修复 .m3u / .m3u8 / .pls 等播放列表与 .srt / .ass / .vtt / .lrc / .cue 等字幕歌词文件的 MIME 被误判成音频、点开只能进播放器、且「打开方式」里也选不到文本编辑器的问题：现在这类文件直接用内置文本编辑器打开，无需先把后缀改成 .txt（GitHub issue #43）',
        '修复上述文件在文件列表里显示音符图标与音频配色、还会被归入音频分类的问题：现在统一按文本文档显示（文档图标 + 扩展名角标 + 文本配色），不再对文本文件做音频封面提取',
      ]),
    ],
    en: [
      _ChangeSection('✨ New Features', [
        'The delete confirmation dialog now lists the items to be deleted: each row shows a file-type icon and the file name, and the dialog height adapts to the item count — a single compact row for one file, a height-limited scrollable list for many; when more than 50 items are selected the remainder is summarised as "and N more"',
        'A new "Open with text editor" entry in the file action menu: any file that is not an image / audio / video or an archive can be opened and edited in the built-in text editor directly, no extension renaming needed',
      ]),
      _ChangeSection('✨ Interface', [
        'The button at the right of the browse page\'s tab bar now opens a menu: with multiple tabs it offers "Close current tab" and "Close all tabs" (current first, all second), and with a single tab it shows only "Close current tab"; choosing "Close all tabs" closes every tab immediately with no extra confirmation',
        'The "Nav bar position" option in Settings → Nav bar settings now uses the same dropdown picker as the custom shortcuts page, and five bottom-nav slot entries were added below it — both places share one configuration and update in sync',
        'The drawer button at the far left of the top bar changed from three dots to a hamburger icon, matching the other top-bar buttons\' highlighted outline style',
      ]),
      _ChangeSection('🐛 Fixes', [
        'Fixed playlists (.m3u / .m3u8 / .pls) and subtitle / lyric files (.srt / .ass / .vtt / .lrc / .cue) being misdetected as audio by their MIME type: they used to open in the audio player with no way to pick the text editor from "Open with". They now open in the built-in text editor directly, without renaming the extension to .txt first (GitHub issue #43)',
        'Fixed the same files showing a music-note icon with audio colours and being counted under the audio category in file lists: they are now displayed consistently as text documents (document icon + extension badge + text colour), and no audio cover art is extracted from these plain-text files',
      ]),
    ],
  );

  /// ── v3.6.5 ──────────────────────────────────────────────────────────
  static const _Changelog _v365 = _Changelog(
    version: 'v3.6.5',
    date: '2026-10-24',
    zh: [
      _ChangeSection('✨ 新功能', [
        '保险箱「密码配置」页的「自动加密」改名为「自动关联」，并拆分为两个独立开关：「自动关联本地加密文件」与「自动关联远程加密文件」（默认均关闭）。开启后浏览目录时就地判定，命中的加密目录自动登记进保险箱的「原地加密 / 远程加密」列表，无需手动逐个添加；目录里混有普通文件时也能正确识别',
        '设置页按作用域重组为「通用」「分类页」「浏览页设置」三个独立子页面，合并原有 7 个零散入口；「文件操作与查看器」与「应用抽屉按钮样式」两个设置页移除，APK 安装设置迁入通用设置',
        '底部导航新增第 5 个槽位：自定义快捷方式页的槽位配置扩至 5 行（槽 1–4 默认开启、第 5 槽默认关闭）；自定义入口选择页新增「关闭」（红色）与「恢复默认」（黄色）动作，关闭只是隐藏槽位、原配置仍保留；全部关闭时兜底保留第 1 槽；第 5 槽开启但未配置时默认进入工具箱',
        '「导航栏常驻其他页面」重新接线：在设置等子页面中点击底部导航，可经首页切换到对应标签页（内置与自定义槽位均可用）；同时恢复了失效的「隐藏导航栏标签」开关',
        '新增「多标签页适用范围」设置：可指定多标签页仅在单窗口、仅在双窗口分屏下启用，或两者都启用',
        '新增应用分身功能：支持通过 Shizuku / root 将已安装的应用克隆到分身用户（Android 多用户）；APK 长按菜单新增「克隆到分身」，分身可在分身管理页中新建、命名与删除',
      ]),
      _ChangeSection('✨ 界面焕新', [
        '导航栏不透明度默认值改为 100% 实底（未自定义过时）：不再回退主题的玻璃配方，底栏整层跳过模糊渲染，滚动更顺滑；已手动调整过不透明度的用户不受影响',
      ]),
      _ChangeSection('🐛 问题修复', [
        '修复清除应用数据后，在保险箱中重新设置相同的密码与加盐，浏览页能识别原地加密文件却无法解密、提示「未找到对应的加密挂载点」的问题：现在会自动重新登记到原地加密列表并正常解密',
        '修复原地加密文件可以剪切到本地目录、却无法剪切到远程目录（提示「Local file not found」）的问题：按「只搬运、不改变加密状态」的语义，把密文原样上传到远程目录',
        '修复远程目录中加密文件与普通文件混存时，「自动关联远程加密文件」不关联（需删光普通文件后才关联）的问题',
        '修复把普通文件复制进已关联的远程加密目录时，普通文件被自动加密的问题：粘贴不再自动加密（仅显式的「加密上传」菜单会加密），来自密文目录的文件仍按密文原样搬运、不做二次加密',
        '修复远程加密视图内复制 / 移动普通条目时名字被套上密文名、打开乱码的问题',
      ]),
    ],
    en: [
      _ChangeSection('✨ New Features', [
        'In the vault\'s password settings, "Auto-encrypt" is renamed "Auto-associate" and split into two switches: "Auto-associate local encrypted files" and "Auto-associate remote encrypted files" (both off by default). When on, directories are judged on the spot while browsing and matching encrypted directories are registered in the vault\'s in-place / remote encryption lists automatically — no manual step needed; directories that mix plain files with ciphertext are recognised correctly too',
        'Settings pages are reorganised by scope into three standalone sub-pages — General, Category page and Browse settings — merging the previous seven scattered entries; the "File actions & viewers" and "App drawer button style" pages are removed, and APK install settings move into General settings',
        'The bottom navigation gained a 5th slot: the custom shortcuts page now offers five slot rows (slots 1–4 on by default, slot 5 off); the custom entry picker gained "Disable" (red) and "Restore default" (yellow) actions — disabling only hides a slot and keeps its configuration; if every slot is off, slot 1 is kept as a fallback; with slot 5 on but unconfigured it opens the toolbox by default',
        '"Keep the nav bar on other pages" is wired up again: tapping the bottom navigation inside settings and other sub-pages switches to the corresponding tab via the home page (built-in and custom slots alike); the broken "Hide nav bar labels" switch works again',
        'New "Multi-tab scope" setting: choose whether multi-tab mode applies to the single window only, the split-screen (dual window) only, or both',
        'New app cloning: clone installed apps to a secondary user via Shizuku / root (Android multi-user); the APK long-press menu gained "Clone to app clone", and clones can be created, renamed and removed in the clone manager page',
      ]),
      _ChangeSection('✨ Interface', [
        'The nav bar\'s default opacity is now 100% solid (when not customised): it no longer falls back to the theme\'s glass recipe, the whole bar skips blur rendering, and scrolling is smoother; users who adjusted the opacity manually are unaffected',
      ]),
      _ChangeSection('🐛 Fixes', [
        'Fixed in-place encrypted files being recognised but not decryptable after clearing app data and re-entering the same password and salt ("No matching encryption mount point found"): they are now re-registered automatically and decrypt normally',
        'Fixed in-place encrypted files that could be cut to a local folder but failed with "Local file not found" when cut to a remote folder: the ciphertext is now uploaded as-is, following the "transfer only, never change encryption state" rule',
        'Fixed "Auto-associate remote encrypted files" not triggering when a remote directory mixes encrypted and plain files (it used to require deleting all plain files first)',
        'Fixed plain files being auto-encrypted when copied into an already-associated remote encrypted directory: pasting no longer encrypts (only the explicit "Encrypt & upload" menu does), while files coming from ciphertext directories are still moved as raw ciphertext without double encryption',
        'Fixed copying or moving plain entries inside the remote encrypted view giving them ciphertext names, which made them unreadable when opened',
      ]),
    ],
  );

  /// ── v3.6.4 ──────────────────────────────────────────────────────────
  static const _Changelog _v364 = _Changelog(
    version: 'v3.6.4',
    date: '2026-10-24',
    zh: [
      _ChangeSection('✨ 新功能', [
        '歌词「全屏显示」重做：不再跳转到单独的全屏页面，而是直接在播放页内进入全屏沉浸态，背景与背景动画照常保留；全屏状态下按系统返回键即退出全屏，不会再直接退出播放页',
        '全屏状态下点击空白处可临时唤出操作界面（可交互），2 秒无操作后自动隐藏；这 2 秒内若操作了上一首、下一首、进度条等按钮，则再延后 1 秒才隐藏',
        '移除全屏显示右上角的三个按钮入口',
      ]),
      _ChangeSection('✨ 界面焕新', [
        '顶部栏的抽屉入口改为纵向排列的三点描边图标，与顶栏其它按钮风格统一',
        '单 / 双窗口切换按钮改用数字标识：单窗口显示「1」，双窗口显示「2」',
        '顶部栏移除「刷新仪表盘」按钮，改为在分类页下拉即可刷新仪表盘',
      ]),
      _ChangeSection('🐛 问题修复', [
        '修复受限目录（Android/data、Android/obb）中的文件无法复制、剪切到普通目录的问题：此前会提示需要 ROOT 或 Shizuku 授权，现在与浏览、删除一样，无需任何授权即可直接复制与剪切（支持目录、多选与同名冲突处理）',
        '修复全屏显示下按返回键会直接退出播放器页面的问题',
      ]),
    ],
    en: [
      _ChangeSection('✨ New Features', [
        'Reworked the lyrics full-screen mode: it no longer opens a separate full-screen page but goes immersive right inside the player, keeping the background and its animation intact; in full screen, the system back key exits full screen instead of leaving the player',
        'While in full screen, tapping a blank area brings the controls back (fully interactive) and they hide again after 2 seconds of inactivity; if you use buttons such as previous/next or the progress bar during those 2 seconds, hiding is delayed by another second',
        'Removed the three buttons in the top-right corner of the full-screen view',
      ]),
      _ChangeSection('✨ Interface', [
        'The drawer button in the top bar is now a vertically arranged three-dot outline icon, matching the other top-bar buttons',
        'The single/dual-window toggle now uses numbers: "1" for single window, "2" for dual window',
        'Removed the "Refresh dashboard" button from the top bar — pull down on the category page to refresh the dashboard instead',
      ]),
      _ChangeSection('🐛 Fixes', [
        'Fixed files in restricted directories (Android/data, Android/obb) failing to copy or move to normal folders: it used to ask for ROOT or Shizuku, and now copying and cutting work with no authorization at all, just like browsing and deleting (folders, multi-selection and name conflicts included)',
        'Fixed the back key leaving the player page while in full-screen mode',
      ]),
    ],
  );

  /// ── v3.6.3 ──────────────────────────────────────────────────────────
  static const _Changelog _v363 = _Changelog(
    version: 'v3.6.3',
    date: '2026-10-22',
    zh: [
      _ChangeSection('✨ 新功能', [
        '「流星坠落」重做为真正的飘落：唱过的字脱离格位，缓慢自转、左右摆动着一路飘到屏幕底部，并随机堆叠在底部（原先只是在行内坠一小段就烧完）；暂停时整片飘落的字一起静止',
        '歌词设置页新增「歌词动画风格」入口，副标题直接显示当前风格；改完返回播放页立即生效，不必再回到播放页菜单里切换',
      ]),
      _ChangeSection('✨ 界面焕新', [
        '标签栏的加号合并了两类动作：点击弹出「新建标签页 / 复制标签页」两个选项，原先放在底部操作栏的「复制标签页」不再单独占位',
        '双窗口的「互换左右窗口」移到底部操作栏：不再以悬浮按钮压在两个窗口中缝上（也就不再遮住窗口顶部状态条），单窗口时完全不显示',
        '「显示文件夹和文件计数标题」改为默认开启',
      ]),
      _ChangeSection('🐛 问题修复', [
        '修复歌词最后一个字迟迟不结束的问题：末字唱完后仍保持高亮与放大、坠落流星的末字也要等下一句开口才开始飘。原因是每行的结束时间被当成了下一行的起点，中间那段句间静默被算进了末字的演唱时间；现在行尾的静默会被切掉，末字在自己唱完的那一刻就结束，逐字歌词（QRC / KRC / 增强 LRC）的最后一个字还会按本行节奏补一个自然尾巴',
        '修复逐字歌词下「坠落流星」的末字还没唱到就提前飘落的问题',
        '修复播放队列里混入远程音频的问题：明明在播本地音频，队列里却出现远程文件（点它也不响应）；现在队列只保留与当前曲目同源的条目，此前已存下的旧混合队列也会自动收敛',
        '修复压缩包内的删除、粘贴与解压失效，以及 GZ 格式解压失败的问题',
        '修复逐字歌词中连续重复的字（叠词）时间戳错乱的问题',
      ]),
    ],
    en: [
      _ChangeSection('✨ New Features', [
        'Reworked "Meteor fall" into a real drift: once a character has been sung it leaves its slot, spins slowly and sways as it drifts all the way down to the bottom of the screen, then piles up there at random (it used to drop only a short way inside the line and burn out); everything freezes together when playback is paused',
        'Lyrics settings gained a "Lyrics animation style" entry that shows the current style as its subtitle; changes apply as soon as you return to the player, with no need to open the player menu again',
      ]),
      _ChangeSection('✨ Interface', [
        'The tab bar plus button now covers both actions: it opens a menu with "New tab" and "Duplicate tab", and "Duplicate tab" no longer takes a slot in the bottom action bar',
        '"Swap panes" in dual-window mode moved to the bottom action bar: it no longer floats over the seam between the two panes (so it stops covering the pane status band), and it is hidden entirely in single-window mode',
        '"Show folder and file count titles" is now enabled by default',
      ]),
      _ChangeSection('🐛 Fixes', [
        'Fixed the last character of a line never finishing: it stayed highlighted and enlarged, and with Meteor fall it only started falling when the next line began. The cause was that a line\'s end time is actually the start of the next line, so the silence between lines was counted as singing time for the last character; the trailing silence is now trimmed, the last character ends the moment it is sung, and for word-timestamped lyrics (QRC / KRC / enhanced LRC) the final character also gets a natural tail derived from the line\'s own rhythm',
        'Fixed the last character falling before it was actually sung with "Meteor fall" on word-timestamped lyrics',
        'Fixed remote audio leaking into the playback queue: remote files showed up even while a local track was playing (and tapping them did nothing); the queue now keeps only entries from the same source as the current track, and older mixed queues are cleaned up automatically',
        'Fixed delete, paste and extract failing inside archives, and GZ archives failing to extract',
        'Fixed garbled timestamps for immediately repeated characters in word-timestamped lyrics',
      ]),
    ],
  );

  /// ── v3.6.2 ──────────────────────────────────────────────────────────
  static const _Changelog _v362 = _Changelog(
    version: 'v3.6.2',
    date: '2026-10-21',
    zh: [
      _ChangeSection('✨ 新功能', [
        '压缩包内可以直接浏览和操作：点开压缩包即可看到里面的目录结构，并能直接删除、重命名、粘贴，或把条目解压到压缩包所在的上级目录；所有写操作都先重写一份临时副本再原子替换，中途失败不会损坏原来的压缩包',
        '收藏夹支持长按拖动排序：在同一分组内长按收藏项即可上下拖动，松手后顺序自动保存',
        '远程连接支持长按拖动排序：「网络」分类页与侧边抽屉里的已保存连接都能拖动调整顺序，两处排序保持同步',
        '新增「流星坠落」歌词风格，替换原「沉浸巨幕」：整句歌词先完整亮起，每唱完一个字就带着流星尾迹向下坠走，唱过的字在原位留一道淡痕，继续跟读不会断',
        '重做五种逐字歌词风格：重力坠落（砸落溅起光环与碎屑）、左右弹射（左右交替高速弹入带拖影）、立体旋入（字块带厚度绕竖轴旋入）、冲击爆字（两倍大猛缩到位并炸开冲击波）、波纹漂浮（逐字起伏带水面倒影）；「辉光扫过」改为「打字机」（逐字敲出、当前字右侧带闪动光标）',
        '混合模式改为单句舞台：每句歌词随机获得一种完整风格，任意连续十句互不重复，真正做到一句一时一面',
        '歌词动画风格改为下拉列表：点开是一次性展开的完整列表，选中后自动收起、只显示当前风格，不再占用整页高度',
        '桌面歌词颜色改为跟随歌词配色：当前播放的字用「当前播放色」，其余用「未播放色」半透明，不再固定跟随主题色',
      ]),
      _ChangeSection('✨ 界面焕新', [
        '双窗口模式新增「互换左右窗口」按钮：矩形、悬浮在左右两窗口正中，高度跟随窗口顶部状态条自动变高变矮，不再占用窗口宽度把左右窗口撑开',
        '顶栏的单/双窗口切换图标改为与其它按钮同一套断线描边风格：单窗是方框，双窗是方框中间加一道竖线',
      ]),
      _ChangeSection('🐛 问题修复', [
        '修复半屏与全屏歌词下拖动波形快进或快退后，当前歌词不会自动回到屏幕正中的问题；流星坠落等大字号逐字风格偏移最明显，现已统一修正，手动翻动歌词后立刻快进也能正常回中',
        '修复波形拖动被其它手势打断后进度条卡住、歌词不再跟随播放的问题',
        '音频播放列表标题「Playing Queue」改为支持全部 10 种界面语言',
      ]),
    ],
    en: [
      _ChangeSection('✨ New Features', [
        'You can now browse inside archives and act on their contents: open a zip to see its folder structure, then delete, rename, paste, or extract entries into the folder that holds the archive; every write rebuilds a temporary copy first and swaps it in atomically, so a failure never damages the original archive',
        'Favorites can be reordered by long-pressing and dragging: drag items up or down within a group and the new order is saved automatically',
        'Saved remote connections can be reordered by long-pressing and dragging, both on the Network category page and in the side drawer, and the order stays in sync between the two',
        'Added the "Meteor fall" lyrics style in place of "Immersive screen": the whole line lights up first, then each character falls away with a meteor trail as soon as it has been sung, leaving a faint trace behind so the line stays readable',
        'Reworked five character-by-character lyrics styles: Gravity drop (characters slam down, splashing rings and debris), Side burst (characters shoot in from left and right with motion trails), Cube spin (character blocks with thickness rotate in around a vertical axis), Impact punch (characters shrink down from double size and blast a shockwave ring) and Wave float (characters bob with a mirrored reflection); "Glow sweep" became "Typewriter" (characters typed out with a blinking cursor)',
        'Mixed mode is now a single-line stage: each line randomly takes one complete style, and no style repeats across ten consecutive lines',
        'The lyrics animation style is now a dropdown: it opens as a single list, collapses right after you pick a style, and shows only the current one instead of taking up a whole page',
        'Desktop lyrics now follow the lyric color scheme: the current word uses the "current" color and the rest use the "unplayed" color at reduced opacity, instead of following the theme',
      ]),
      _ChangeSection('✨ Interface', [
        'Dual-window mode has a new "Swap panes" button: a rectangle floating in the middle above both panes, growing taller or shorter with the pane top status band, and it no longer takes width away from the panes',
        'The single/dual window toggle in the top bar now uses the same broken-line outline style as the other buttons: a square for single window and a square with a vertical divider for dual window',
      ]),
      _ChangeSection('🐛 Fixes', [
        'Fixed the current lyric not returning to the centre of the screen after seeking with the waveform in half-screen and full-screen modes; the offset was worst with the large-type motion styles such as Meteor fall, and seeking right after scrolling the lyrics by hand now recentres as well',
        'Fixed the progress bar seizing up and the lyrics no longer following playback when a waveform drag was interrupted by another gesture',
        'Localized the audio playback queue title ("Playing Queue") into all 10 UI languages',
      ]),
    ],
  );

  /// ── v3.6.1 ──────────────────────────────────────────────────────────
  static const _Changelog _v361 = _Changelog(
    version: 'v3.6.1',
    date: '2026-10-21',
    zh: [
      _ChangeSection('✨ 新功能', [
        '歌词动画风格扩充至 6 种：新增「文字 PV」（唱字逐字飞入、逐渐揭示整句）与「回声碎片」（空心字碎片漂移）两种唱字特效，只呈现当前播放的一句歌词',
        '新增「混合模式」并作为默认动画风格：它是一个独立风格但没有单一形态——每句歌词随机呈现五种内置风格（经典、辉光、巨幕、文字 PV、回声碎片）中的一种，逐句变化；也可以固定为任意单一风格',
        '歌词显示菜单改版：用分隔线区分「显示模式」（关闭 / 单行 / 半屏 / 全屏）与「动画风格」；选择动画风格不再强制跳转全屏，而是按当前显示模式即时应用，单行与半屏同样支持全部 6 种风格',
        '歌词显示默认改为半屏：进入播放页即在内联歌词区显示歌词，仍可在显示菜单里切换为关闭 / 单行 / 全屏',
        '播放页三点菜单新增「歌词设置」：桌面歌词开关、动画风格、歌词配色与整体偏移集中在一处管理',
        '新增歌词整体偏移：全屏歌词页顶栏与「歌词设置」均可进入，支持只应用于当前歌曲或全局生效；拖动滑杆实时预览、点击数值可手动输入，范围 ±30 秒、步进 0.1 秒，桌面歌词同步应用，设置自动持久化',
        '新增歌词配色自定义：未播放 / 当前播放 / 已播放三色可分别调整，默认经典搭配（纯白 / 亮黄绿 / 草绿），支持一键恢复默认',
        '底部导航栏新增不透明度调节：「自定义快捷方式」页与「设置 → 常规与行为 → 导航栏设置」双入口，数值双向同步，可恢复默认，默认观感与之前一致',
      ]),
      _ChangeSection('✨ 界面焕新', [
        '播放页的歌曲名、歌手、收藏与波形整体下移，与播放控制按钮均匀排列',
        '歌词变色区分歌词源类型：普通 LRC（无逐字时间戳）整句一次性变色，不再逐字乱跳；带逐字时间戳的 LRC 仍严格逐字变色，逐字弹放动画与唱字特效保持原样',
        '全屏歌词模式下点击空白处可呼出顶部菜单，2 秒无操作自动隐藏，重回沉浸模式',
        '全屏歌词顶栏的「在线搜索歌词」与「本地导入歌词」合并为单一入口，点击弹出菜单选择',
        '单行歌词显示时，文字 PV 与回声碎片特效可向上穿过封面卡片显示',
        '半屏歌词未匹配到歌词文件时，在「导入本地歌词」上方新增「搜索在线歌词」入口',
      ]),
      _ChangeSection('⚡ 性能优化', [
        '浏览页文件列表滚动期间冻结底部操作栏玻璃层的背景模糊，滚动结束自动恢复，大目录滑动更顺畅',
      ]),
    ],
    en: [
      _ChangeSection('✨ New Features', [
        'Expanded the lyrics animation library to 6 styles: added "Text PV" (characters fly in one by one to gradually reveal the whole line) and "Echo Shards" (hollow character fragments drifting), both showing only the line currently being sung',
        'Added "Mixed" as the default animation style: a standalone style with no single shape - each line randomly renders as one of the five built-in styles (classic, glow, immersive, text PV, echo shards), changing line by line; any single style can still be pinned',
        'Reworked the lyrics display menu: a divider now separates the display modes (off / single line / half screen / full screen) from the animation styles; picking a style no longer forces full screen, it applies to the current display mode instead, and single-line and half-screen modes support all 6 styles too',
        'Lyrics now default to half-screen display: opening the player shows the inline lyrics area right away, and you can still switch to off / single line / full screen in the display menu',
        'Added a "Lyric settings" page to the player three-dot menu, gathering the desktop lyrics switch, animation styles, lyric colors and the overall offset in one place',
        'Added an overall lyric offset: available from the full-screen lyrics top bar and from "Lyric settings"; it can apply to the current song only or globally, the slider previews in real time and the displayed value can be tapped for manual input (±30 seconds in 0.1-second steps), desktop lyrics follow along, and the setting persists',
        'Added lyric color customization: the unplayed / current / played colors can be adjusted independently, with a classic default set (white / lime / light green) and one-tap restore',
        'Added navigation bar opacity control: available from both "Custom shortcuts" and "Settings → General & behavior → Navigation bar settings", the two stay in sync, it can be restored to default, and the default look is unchanged',
      ]),
      _ChangeSection('✨ Interface', [
        'Moved the song title, artist, favorite button and waveform down on the player page so they line up evenly with the playback controls',
        'Lyric coloring now follows the lyric source: plain LRC files (without word timestamps) fill the whole line at once instead of jumping character by character, while enhanced LRC with word timestamps still colors strictly word by word; the character pop animation and singing effects are unchanged',
        'In full-screen lyrics mode, tapping the blank area reveals the top menu, which auto-hides after 2 seconds of inactivity and returns to immersive mode',
        'Merged "Search lyrics online" and "Import local lyrics" in the full-screen lyrics top bar into a single button that opens a menu',
        'In single-line lyrics mode, the Text PV and Echo Shards effects can now travel up across the cover card',
        'When no lyrics file is matched in half-screen mode, a "Search lyrics online" entry now sits above "Import local lyrics"',
      ]),
      _ChangeSection('⚡ Performance', [
        'The browser file list now freezes the action bar glass blur while scrolling and restores it afterwards, making large folders scroll more smoothly',
      ]),
    ],
  );

  /// ── v3.6.0 ─────────────────────────────────────────────────────────
  static const _Changelog _v360 = _Changelog(
    version: 'v3.6.0',
    date: '2026-10-19',
    zh: [
      _ChangeSection('✨ 界面焕新', [
        '浏览页底部操作栏与导航栏真正拼成一体：左右留白一致、上下零间距、同一套底色，接缝只描一次边；操作栏随列表滚动折叠与展开时，导航栏顶角在方角与圆角之间平滑过渡',
        '浅色模式改为三档层次：顶栏、底部导航栏、浏览操作栏共用同一底色（主题色 12% 混白），页面底色再浅一档（4% 混白），栏位从页面里「浮」出来而不再糊成一片',
        '标签页栏的点击与切换改用与底部导航栏同一套弹簧动效：指示器在标签之间滑动，按下时轻微鼓包、被滑动速度横向拉长，不再生硬跳变',
        '长按标签页的关闭菜单改为从标签栏正下方弹出，并贴合被长按的那个标签；菜单内新增「双击可关闭当前标签页」提示，已支持全部 10 种界面语言',
        '双窗口模式下标签高亮分三档：焦点窗口保持主题色高亮，已显示在副窗口的标签降为中性灰底与淡描边，未参与双窗口的标签维持原样，一眼就能分清主次',
      ]),
      _ChangeSection('🐛 问题修复', [
        '修复加密图片打开后无法左右滑动的问题，覆盖原地加密、保险箱沙盒与远程加密三种入口：现在打开即可在整组加密图片之间连续翻页',
        '修复长按标签页没有反应、不弹出关闭按钮的问题：此前定位方式取到了错误的渲染对象，导致长按回调直接中断',
        '修复打开文档后会停留在上次的编辑模式：现在每次打开都从查看（只读）模式进入，需要编辑时主动切换；「自动换行 / 显示行号」改为独立的显示偏好，不再与编辑模式绑定',
        '修复重启后切到「记住上次打开文件夹」恢复出来的标签页是一片空白、必须手动下拉才出内容的问题：切换过去时会自动补一次目录加载',
        '修复副窗口的标签高亮反而比焦点窗口更抢眼的问题：副窗口不再使用主题色与加粗描边',
      ]),
      _ChangeSection('⚡ 性能优化', [
        '大幅优化软键盘弹出与收起的卡顿（文件越多越明显）：窗口不再随键盘逐帧改变尺寸，常驻页面在键盘动画期间完全不重排；解锁进入首页后先等键盘彻底收起，再开始扫描目录与加载媒体库；浏览页改为切入时才构建，解锁那一帧不再整页初始化',
        '优化全局搜索：输入新关键词会真正取消上一轮扫描、限制同时扫描的目录数量、结果分批刷新界面，大存储设备上输入时基本不再卡顿',
      ]),
    ],
    en: [
      _ChangeSection('✨ Interface', [
        'The browser action bar and the navigation bar are now genuinely joined into one piece: same side margins, zero gap, one shared background color, and a single hairline along the seam; when the action bar collapses or expands with scrolling, the navigation bar top corners ease between square and rounded',
        'Light mode now uses three background tiers: the top bar, the bottom navigation bar and the browser action bar share one color (12% primary over white), while pages sit one step lighter (4% primary over white), so the bars lift off the page instead of blending in',
        'Tab bar taps and switches now use the same spring as the bottom navigation bar: the indicator slides between tabs, bulges slightly while pressed and stretches with the swipe velocity instead of jumping',
        'Long-pressing a tab now drops the close menu from directly below the tab bar, aligned to the tab you pressed, and adds a "double-tap to close the current tab" hint localized into all 10 UI languages',
        'In dual-window mode tab highlights now have three levels: the focused window keeps the primary highlight, tabs already shown in the secondary window drop to a neutral fill with a faint border, and tabs outside both windows stay unchanged',
      ]),
      _ChangeSection('🐛 Bug Fixes', [
        'Fixed encrypted images not swiping left and right, across in-place encryption, vault sandbox and remote encryption: an opened image can now page through the whole encrypted set',
        'Fixed long-pressing a tab doing nothing and never showing the close button: the old code resolved the wrong render object, which aborted the long-press callback',
        'Fixed documents reopening in the last editing mode: every document now opens in view-only mode and must be unlocked to edit, while "word wrap / line numbers" became independent display preferences no longer tied to the mode',
        'Fixed tabs restored by "remember the last opened folder" showing a blank list after a restart until a manual pull-to-refresh: switching to such a tab now loads its directory automatically',
        'Fixed the secondary window highlight looking stronger than the focused one: the secondary window no longer uses the primary color or a heavier border',
      ]),
      _ChangeSection('⚡ Performance', [
        'Greatly reduced keyboard open and close jank, which was worse with more files: the window no longer resizes frame by frame with the keyboard and resident pages skip relayout entirely during the animation; after unlocking, directory scanning and media loading wait until the keyboard has fully retracted; the browser page is now built on first visit instead of on the unlock frame',
        'Improved global search: a new keyword now truly cancels the previous scan, the number of concurrently scanned directories is capped, and results refresh in batches, so typing stays smooth on devices with large storage',
      ]),
    ],
  );

  /// ── v3.5.9 ──────────────────────────────────────────────────────────
  static const _Changelog _v359 = _Changelog(
    version: 'v3.5.9',
    date: '2026-10-18',
    zh: [
      _ChangeSection('✨ 界面焕新', [
        '底部导航栏改为「液态玻璃」样式：选中项是一整块会在四个入口之间弹簧滑动的胶囊，按下时会轻微鼓包、被滑动速度横向拉长，图标随之放大；外层是半透明玻璃，带背景模糊、细描边与顶部高光',
        '底部导航栏支持左右拖动直接切换页面；任意入口长按都可以替换成自己常用的功能',
        '文件浏览页的底部操作栏与导航栏拼成一整块「底部控制台」：左右留白一致、上下零间距、同一套玻璃配色，只在最上沿受光一次；操作栏随列表滚动折叠与展开时，导航栏顶角在方角与圆角之间平滑过渡',
        '分类卡片、文件与文件夹条目、抽屉条目、传输卡片、标签页与面包屑按钮、顶栏图标都加入了同源的按压回弹：按下去略缩、松手弹回，点按更有手感',
        '修正底部导航栏在浏览页偏黑的问题：浏览页背景此前在深色模式下被强制压成纯黑，与分类 / 传输 / 设置页差一档，底部胶囊看起来像贴在一块更黑的底板上。现在全应用背景同色，开启「AMOLED 纯黑模式」时仍然保持纯黑',
      ]),
      _ChangeSection('🐛 问题修复', [
        '修复后台播放音乐时在列表里点另一首，播放器仍停留在上一首的问题：现在会立即切歌，并以新列表重建后台播放会话，通知栏的歌曲信息同步更新',
        '修复打开设置等不属于底部导航的页面后，导航栏里「文件」入口仍显示为选中、胶囊停留在原处的问题：不在四个入口对应的页面时，胶囊会淡出并整体隐藏',
      ]),
      _ChangeSection('⚙️ 默认值调整', [
        '「记住上次打开的文件夹」默认改为开启',
        '「导航栏常驻其他页面」默认改为关闭',
        '以上仅调整新安装的默认值，已手动改过设置的用户不受影响',
      ]),
    ],
    en: [
      _ChangeSection('✨ Interface', [
        'The bottom navigation bar now uses a "liquid glass" style: the selected item is a single capsule that springs between the four entries, bulges slightly while pressed, stretches horizontally with the swipe velocity, and scales its icon up; the whole bar is translucent glass with background blur, a hairline border and a top highlight',
        'The bottom navigation bar can be dragged left and right to switch pages, and any entry can be long-pressed to be replaced with your own shortcut',
        'On the file browser, the bottom action bar and the navigation bar are now joined into one "bottom console": same side margins, zero gap, one shared glass palette and a single highlight along the top edge; when the action bar collapses or expands with scrolling, the top corners of the navigation bar ease between square and rounded',
        'Category cards, file and folder rows, drawer entries, transfer cards, tab chips, breadcrumb buttons and top bar icons now share the same press feedback: a slight shrink while held and a spring back on release',
        'Fixed the bottom navigation bar looking darker on the file browser: the browser background used to be forced to pure black in dark mode, one step darker than the categories, transfers and settings pages, so the capsule looked like it sat on a darker plate. The background is now identical across the app, and still pure black with "AMOLED black mode" enabled',
      ]),
      _ChangeSection('🐛 Bug Fixes', [
        'Fixed tapping another song in the list while music was playing in the background leaving the player on the previous track: playback now switches immediately and rebuilds the background session with the new queue, keeping the notification in sync',
        'Fixed the "Files" entry still appearing selected (and the capsule staying in place) after opening a page outside the bottom navigation, such as Settings: the capsule now fades out and hides on such pages',
      ]),
      _ChangeSection('⚙️ Defaults', [
        '"Remember the last opened folder" now defaults to on',
        '"Keep the navigation bar on other pages" now defaults to off',
        'Only the defaults for fresh installs changed; existing preferences are untouched',
      ]),
    ],
  );

  /// ── v3.5.8 ──────────────────────────────────────────────────────────
  static const _Changelog _v358 = _Changelog(
    version: 'v3.5.8',
    date: '2026-10-16',
    zh: [
      _ChangeSection('✨ 新增功能', [
        '「自定义快捷方式」页新增「分类卡片样式」：分类页的卡片可在「极简」（只保留图标、名称与数量/说明，默认）与「边框」之间切换，用来按自己的喜好调整视觉密度',
        '「导航栏显示位置」改用与「每行显示」一致的下拉框样式，整个设置列表的控件风格统一',
      ]),
      _ChangeSection('🐛 问题修复', [
        '修复在其它应用的 Android/data、Android/obb 目录里删除文件或文件夹失败、提示「权限不足（errno = 13）」的问题',
        '修复受限目录里的条目被删空之后，列表误判为「需要授权」并弹出授权提示的问题',
        '修复把搜索范围选到 Android/data 时永远搜不到文件或文件夹（一直显示「未找到结果」）的问题',
        '修复受限目录内的复制、粘贴、重命名、移入回收站与从回收站还原在部分通道下失败或写入不完整的问题',
      ]),
      _ChangeSection('⚡ 性能优化', [
        '修复远程服务器（SFTP / SMB / FTP / WebDAV）进入目录偶发卡顿一两秒的问题：去掉了一次多余的列表排序、同一个文件夹的条目数改为只查询一次（此前重复请求会排队串行执行）、远程文件夹不再做无意义的本地扫描、WebDAV 不再把整份目录响应打进日志并补上了读取超时、SMB 回到前台时的连接体检不再强制重跑一遍共享枚举',
        '分类页左右留白收窄，卡片排列更舒展；上下间距与原来保持一致，一屏能显示的类别数量不变',
      ]),
    ],
    en: [
      _ChangeSection('✨ New Features', [
        'New "Category card style" option under Custom shortcuts: the cards on the categories page can switch between "Minimal" (icon, name and count only - now the default) and "Border", so you can tune the visual density to taste',
        'The "Navigation bar position" option now uses the same dropdown style as "Items per row", unifying the controls across the settings list',
      ]),
      _ChangeSection('🐛 Bug Fixes', [
        'Fixed deleting files or folders inside another app\'s Android/data or Android/obb directory failing with a "permission denied (errno = 13)" error',
        'Fixed a restricted folder being wrongly reported as "permission required" once everything inside it had been deleted',
        'Fixed searching with the scope set to Android/data never finding any file or folder (it always showed "No results")',
        'Fixed copy, paste, rename, move-to-recycle-bin and restore-from-recycle-bin failing or writing incomplete data for items inside restricted directories on some of the fallback channels',
      ]),
      _ChangeSection('⚡ Performance', [
        'Fixed occasional one-to-two second stalls when opening folders on remote servers (SFTP / SMB / FTP / WebDAV): one redundant list sort was removed, a folder\'s item count is now queried only once (repeated requests used to queue up and run serially), remote folders no longer trigger a pointless local scan, WebDAV no longer dumps the whole directory response into the log and now has a read timeout, and the SMB health check on returning to the foreground no longer forces a full share enumeration',
        'The categories page now uses narrower side margins so the cards sit more comfortably; vertical spacing is unchanged, so the number of rows visible on one screen stays the same',
      ]),
    ],
  );

  /// ── v3.5.7 ──────────────────────────────────────────────────────────
  static const _Changelog _v357 = _Changelog(
    version: 'v3.5.7',
    date: '2026-10-14',
    zh: [
      _ChangeSection('✨ 新增功能', [
        '压缩新增「分卷压缩」与「逐文件压缩」：可把大目录压成 .001 / .002 … 分卷包，也可以让每个选中的文件 / 目录各自生成独立压缩包（此前这两个选项在主压缩路径下会静默失效）',
        '其他应用的 Android/data、Android/obb 目录支持直接浏览与读写（无需授权），包名目录下的文件数不再显示为 0',
      ]),
      _ChangeSection('🐛 问题修复', [
        '修复压缩 / 解压进度条长时间不动、看着像卡死的问题：压缩改为逐块进行并实时上报进度，进度环、百分比、速度与剩余时间全程连续推进（此前一个大文件从头到尾进度都停在 0 B / 0 B）',
        '修复压缩时设置了密码、解压时却不要求密码的问题：加密压缩包现在会先要求输入密码，密码错误会明确提示并可重新输入；此前无密码解压会「成功」产出 0 字节文件且没有任何提示，让人误以为压缩包损坏',
        '修复压缩 / 解压完成后必须点弹窗里的「确定（打开所在位置）」才会刷新列表的问题：完成后自动刷新所在目录，新生成的压缩包 / 解压出的文件立刻出现在列表里，不再需要手动下拉刷新',
        '修复打开大 PDF 文件（约 20MB 以上）被系统判定「无响应」而闪退的问题：大文件自动改用原生渲染引擎在后台分页解析，界面全程可操作',
        '修复重命名文件时偶发自动创建同名文件夹、文件被放进文件夹里的问题：名称包含路径分隔符等非法字符时会直接提示「名称不合法」；批量重命名的查找 / 替换同样受到保护',
        '修复从远程服务器（SMB / FTP / WebDAV 等）复制文件到手机时偶发自动创建同名文件夹的问题：目标位置已有同名文件夹时会明确提示并跳过，不会再静默把文件嵌进去',
        '新建文件 / 文件夹时名称包含路径分隔符等非法字符同样会被拒绝',
      ]),
    ],
    en: [
      _ChangeSection('✨ New Features', [
        'Archiving gained "Split into volumes" and "One archive per file": a large folder can now be compressed into .001 / .002 ... volumes, and every selected file / folder can get its own archive (both options used to be silently ignored on the main compression path)',
        'The Android/data and Android/obb folders of other apps can now be browsed and edited directly (no permission required), and the item count under package folders no longer shows 0',
      ]),
      _ChangeSection('🐛 Bug Fixes', [
        'Fixed the compress / extract progress bar standing still for a long time and looking stuck: compression now runs block by block and reports progress continuously, so the ring, percentage, speed and remaining time keep moving (previously a single large file showed 0 B / 0 B from start to finish)',
        'Fixed archives created with a password not asking for it on extraction: encrypted archives now ask for the password first, and a wrong password is reported clearly with a retry - previously extracting without the password "succeeded" and produced 0-byte files with no message at all, which looked like a corrupted archive',
        'Fixed the file list only refreshing after tapping "Confirm (open location)" in the completion prompt: the folder is now refreshed automatically, so the new archive or the extracted files show up right away without a manual pull-to-refresh',
        'Fixed large PDF files (roughly 20 MB and up) being killed by the system as "not responding": files above the safe size now fall back to the native rendering engine, which parses pages in the background while the UI stays responsive',
        'Fixed renaming a file occasionally creating a folder with the same name and putting the file inside it: names containing path separators or other invalid characters are now rejected with an "invalid name" notice; the find / replace of batch rename is protected the same way',
        'Fixed copying files from a remote server (SMB / FTP / WebDAV, ...) to the phone occasionally creating a folder with the same name: when a folder with that name already exists at the destination, the copy is skipped with a clear notice instead of silently nesting the file inside',
        'Creating a new file / folder with a name that contains path separators or other invalid characters is rejected as well',
      ]),
    ],
  );

  /// ── v3.5.6 ──────────────────────────────────────────────────────────
  static const _Changelog _v356 = _Changelog(
    version: 'v3.5.6',
    date: '2026-10-13',
    zh: [
      _ChangeSection('🐛 问题修复', [
        '修复分类页的「幽灵条目」：音频、下载、文档、压缩包、安装包里会列出 0 字节、或实际已经不存在的文件 —— 点「打开所在位置」跳过去却找不到该文件，在列表里删掉后一刷新它又回来了。根因是分类列表有 5 条数据入口绕过了「文件是否真实存在 / 是否为 0 字节」的校验（系统媒体索引读出了大小却没拿它过滤、磁盘缓存恢复完全信任旧路径、与旧列表合并时把空条目原样保留），现在统一在后台一次性核对并剔除，删掉的条目也不会再从缓存被带回来',
        '修复分类卡片与快捷入口显示的数量多于列表实际条数（卡片上写着 12、点进去只有 8）的问题：数量的统计口径与列表统一为「过滤后的条数」',
        '修复浏览页把 RMVB 显示成「未知格式」（同一个文件在分类页却能正常识别播放）：补齐浏览页的视频后缀（WMV / 3GP / M4V / RMVB / RM / ASF / F4V）、音频后缀（AMR / MID / MIDI）与图片后缀（ICO / RAW），与分类页对齐',
      ]),
      _ChangeSection('🎨 界面与交互', [
        '设置—语言里的「自动（跟随系统）」改为跟随应用语言显示，此前在英文等界面下固定显示为中文',
        '压缩 / 解压、复制 / 粘贴等进度弹窗的文案不再带黄色下划线（此前每行文字下方都有一条黄线）',
        '进度弹窗的水平分隔线不再超出圆形进度环、也不再与进度环或「后台 / 取消」按钮重叠：分隔线宽度按圆环内缘重新对齐（圆周直径 300、内圈环内缘距圆边 17px，分隔线取 260px、两端各留 20px，贴住内缘但不压环）',
      ]),
    ],
    en: [
      _ChangeSection('🐛 Bug Fixes', [
        'Fixed the "ghost entries" in the category pages: Audio, Downloads, Documents, Archives and Packages used to list files that are 0 bytes or no longer exist on disk - tapping "Open containing folder" jumped to a folder that does not contain the file, and deleting such an entry brought it right back after a refresh. The category lists had five data paths that bypassed the "does the file really exist / is it 0 bytes" check (the system media index read the size but never filtered by it, the on-disk cache restore trusted the old paths as-is, and merging with the previous list kept the empty entries unchanged); they are now all verified once in the background and dropped, and deleted entries are no longer restored from the cache',
        'Fixed category cards and shortcut tiles showing a higher count than the list actually contains (the card said 12 while only 8 were listed): the count now uses the same filtered result as the list',
        'Fixed the file browser showing RMVB as "Unknown format" while the same file was recognised and played fine from the category pages: the browser now knows the video extensions (WMV / 3GP / M4V / RMVB / RM / ASF / F4V), audio extensions (AMR / MID / MIDI) and image extensions (ICO / RAW) that the categories already supported',
      ]),
      _ChangeSection('🎨 UI & Interaction', [
        'The "Automatic (follow system)" entry under Settings - Language now follows the app language; it used to stay in Chinese even on an English UI',
        'Text in the progress dialogs (compress / extract, copy / paste, ...) no longer carries a yellow underline under every line',
        'The horizontal dividers in the progress dialogs no longer stick out of the circular progress ring or overlap the ring and the "Background / Cancel" buttons: the divider width is re-aligned to the inner edge of the ring (the circle is 300 px across and the inner ring edge sits 17 px from the border, so the divider is 260 px with 20 px on each side - flush with the inner edge without covering the ring)',
      ]),
    ],
  );

  /// ── v3.5.5 ──────────────────────────────────────────────────────────
  static const _Changelog _v355 = _Changelog(
    version: 'v3.5.5',
    date: '2026-10-08',
    zh: [
      _ChangeSection('✨ 新增功能', [
        '文件属性新增「校验和」标签页：单个本地文件可即时计算 MD5 / SHA-1 / SHA-256（流式分块读取、显示进度），还能粘贴官方哈希自动比对（按长度识别算法，忽略大小写、空格与 - / : 分隔符），用来验证下载的大文件是否损坏或被篡改',
      ]),
      _ChangeSection('🎨 界面与交互', [
        '文件属性页由弹窗改为全屏页（左右满铺，关闭按钮在左上角）；校验和的长哈希各占一行，底部的粘贴比对框与结论始终可见 —— 此前 SHA-256 会被窄列挤断换行，还把比对框顶出屏幕、必须上滑才能用',
        '分类页长按文件进入的属性页与文件浏览页完全统一（此前分类页是另一套简化弹窗，缺 SHA-1 与粘贴比对）；并修复分类页里的远程媒体进属性页时大小显示为 0 的问题',
      ]),
      _ChangeSection('⚡ 性能优化', [
        '大目录移入回收站不再退化成整份拷贝：删除 1.2GB 的 Telegram 文件夹此前要等约一分钟 —— 受限目录（其它应用的 Android/data、Android/obb）改用原子 mv、普通目录在 rename 失败后先试 mv，都只改元数据；同时目录体积改为移动完成后后台补算，不再在删除前遍历整棵目录树（几万个小文件时这一步本身就要几十秒）',
        '打开图片更快：扫描同目录图片时不再逐个读取非图片文件（视频、压缩包等）的文件头，图片多、且同目录混有大量视频的文件夹改善尤其明显',
      ]),
      _ChangeSection('🐛 问题修复', [
        '修复从文件浏览页打开图片时「先空白等一两秒才显示、并且左右滑动切不了图」的问题：图片计数器一直显示「1 of 1」；从分类页 / 相册打开同一张图不受影响（论坛反馈）',
        '修复视频播放页每次进入都会把手机媒体音量顶回上次记忆值的问题：用户把音量调低或静音后再播放视频会被强制拉回原来的音量（默认为最大），并连带之后播放音频也变响（issue #41）',
      ]),
    ],
    en: [
      _ChangeSection('✨ New Features', [
        'Added a "Checksum" tab to file properties: compute MD5 / SHA-1 / SHA-256 for a single local file on the spot (streamed in chunks, with progress), and paste an official hash to compare against it (the algorithm is detected from the hash length; case, spaces and - / : separators are ignored) to verify that a downloaded large file is intact and untampered',
      ]),
      _ChangeSection('🎨 UI & Interaction', [
        'File properties is now a full-screen page instead of a dialog (full width, with the close button at the top-left). In the Checksum tab each long hash value gets its own line and the paste-and-compare box at the bottom stays visible - previously SHA-256 was broken across a narrow column and pushed the compare box off screen, so it required scrolling',
        'The properties page opened by long-pressing a file in a category now matches the file browser exactly (the category used to show a separate simplified dialog without SHA-1 or hash comparison); also fixed the size showing as 0 for remote media opened from a category',
      ]),
      _ChangeSection('⚡ Performance', [
        'Moving a large folder to the recycle bin no longer degrades into a full copy: deleting a 1.2 GB Telegram folder used to take about a minute. Restricted folders (the Android/data and Android/obb of other apps) now use an atomic mv, and normal folders try mv before falling back to copy - both only touch metadata. The folder size is now computed in the background after the move instead of walking the whole tree before deleting (which alone costs tens of seconds on folders with tens of thousands of small files)',
        'Faster image opening: the folder scan no longer reads the file header of every non-image file (videos, archives, ...). The gain is largest in folders with many images mixed with lots of videos',
      ]),
      _ChangeSection('🐛 Bug Fixes', [
        'Fixed images opened from the file browser taking a second or two of blank screen and then refusing to swipe left / right, with the counter stuck on "1 of 1". The same image opened from a category or the gallery was unaffected (reported on the forum)',
        'Fixed the video player forcing the phone media volume back to the last remembered value on every launch: after the user lowered the volume or muted it, playing a video was pushed back up (to maximum by default) and audio playback became louder too (issue #41)',
      ]),
    ],
  );

  /// ── v3.5.4 ──────────────────────────────────────────────────────────
  static const _Changelog _v354 = _Changelog(
    version: 'v3.5.4',
    date: '2026-10-05',
    zh: [
      _ChangeSection('🎨 界面与交互', [
        '「打开方式」系统选择器（安装包、未知类型文件弹出的应用选择框）的标题改为跟随应用语言，此前固定显示中文',
        '压缩 / 解压的后台通知按钮「打开 / 取消」改为跟随应用语言',
        '补齐大量此前写死在代码里的界面文案多语言：音量、亮度、静音 / 取消静音、全屏 / 退出全屏、重命名失败、删除失败、重新加载、显示设置、查找、端口、固定标签页 / 关闭标签页等（新增 26 条文案 × 10 种语言）',
        '进度弹窗的文件计数器改用常规文字色，不再使用主题色高亮',
      ]),
      _ChangeSection('🐛 问题修复', [
        '修复压缩 / 解压、加密 / 解密进度弹窗偶发变成「浅灰蒙层 + 没有进度环 + 按钮全部点不动 + 只能重启应用」的问题：根因是总文件数为 0 时进度计数计算抛异常，整个弹窗被替换成了错误占位块',
        '修复云端备份卡在 100% 时「取消 / 后台 / 返回」全部无响应的问题：弹窗与页面分属不同导航栈，关闭动作弹错了对象；现在「取消」会真正中断同步并关闭弹窗',
        '修复云端备份到远程时内圈、外圈进度条都不滚动的问题',
        '修复加密 / 解密时外圈进度条不滚动的问题',
        '修复多处界面把占位符原样显示出来的问题（如「打开失败：{e}」「路径不存在: {path}」「已替换 {count} 处」）',
        '修复本地复制 / 剪切到远程时外圈整体进度条偶发回退闪烁、以及目录粘贴计数器错位（第一个文件显示成 2/N）的问题',
      ]),
    ],
    en: [
      _ChangeSection('🎨 UI & Interaction', [
        'The title of the system "Open with" chooser (shown for packages and unknown file types) now follows the app language; it used to be hardcoded in Chinese',
        'The background notification buttons for compression / extraction ("Open" / "Cancel") now follow the app language',
        'Localised a large set of UI strings that were hardcoded in code: Volume, Brightness, Mute / Unmute, Fullscreen / Exit fullscreen, Rename failed, Delete failed, Reload, Display settings, Find, Port, Pin tab / Close tab and more (26 new strings x 10 languages)',
        'The file counter in the progress dialogs now uses the regular text colour instead of the accent colour',
      ]),
      _ChangeSection('🐛 Bug Fixes', [
        'Fixed the compress / extract and encrypt / decrypt progress dialogs occasionally turning into a "grey overlay with no progress ring, unresponsive buttons, app restart required": when the total file count was 0 the counter calculation threw an exception and the whole dialog was replaced by an error placeholder',
        'Fixed cloud backup getting stuck at 100% with Cancel / Send to background / Back all unresponsive: the dialog and the page live on different navigator stacks, so the close action popped the wrong route; Cancel now really aborts the sync and closes the dialog',
        'Fixed both the inner and outer progress rings not moving when backing up to a remote server',
        'Fixed the outer progress ring not moving during encryption / decryption',
        'Fixed several places showing raw placeholders on screen (e.g. "Open failed: {e}", "Path not found: {path}", "Replaced {count} occurrence(s)")',
        'Fixed the outer overall progress ring occasionally flickering backwards, and a wrong file counter (the first file in a folder shown as 2/N) when copying / cutting from local to a remote server',
      ]),
    ],
  );

  /// ── v3.5.3 ──────────────────────────────────────────────────────────
  static const _Changelog _v353 = _Changelog(
    version: 'v3.5.3',
    date: '2026-10-05',
    zh: [
      _ChangeSection('✨ 新功能', [
        '多文件操作新增进度计数器：复制 / 剪切、压缩 / 解压、加密 / 解密、云备份同步现在会显示「3/10」形式的进度（当前第几个 / 共几个文件）；复制 / 剪切弹窗中位于文件总大小与剩余时间之间，单文件操作不显示',
      ]),
      _ChangeSection('🎨 界面与交互', [
        '四类进度弹窗（复制剪切 / 压缩解压 / 加密解密 / 云备份同步）统一为同一个圆环进度组件，外观与布局完全一致，后续调整只需改一处',
      ]),
      _ChangeSection('🐛 问题修复', [
        '安装包的「已安装」判定改为严格匹配：包名、版本号、架构三者必须全部一致才显示「已安装」。同一应用的不同架构分包（arm64-v8a / armeabi-v7a / x86_64）或不同版本不再被统统判为已安装，只有与设备上实际安装的那一个相符才会亮起',
        '修复分类页的安装包、文档、压缩包、下载等类别扫不到深层文件的问题（例如放在 ZenFile/Backups/Apps 里的安装包），现在会扫描到更深的子目录',
        '修复从图片 / 视频 / 音频等分类页打开查看器后按返回直接跳回分类页网格的问题：现在按层级逐层返回，在文件夹视图里也能正常退回文件列表',
        '修复底部导航栏同时高亮多个标签的问题：打开自定义槽位页面（最近页 / 分类快捷入口）后，内置标签的高亮会自动熄灭，任意时刻只有一个高亮',
      ]),
    ],
    en: [
      _ChangeSection('✨ New Features', [
        'Multi-file operations now show a progress counter: copy / cut, compress / extract, encrypt / decrypt and cloud backup sync display progress in the form "3/10" (current file / total files). In the copy / cut dialog it sits between the total size and the estimated time; single-file operations do not show it',
      ]),
      _ChangeSection('🎨 UI & Interaction', [
        'The four progress dialogs (copy/cut, compress/extract, encrypt/decrypt, cloud backup sync) now share a single ring-progress component, so their appearance and layout are fully consistent and future tweaks only need one change',
      ]),
      _ChangeSection('🐛 Bug Fixes', [
        'The "Installed" check for packages now matches strictly: package name, version and CPU architecture must all match before a package shows as installed. The per-architecture builds of the same app (arm64-v8a / armeabi-v7a / x86_64) or a different version are no longer all marked as installed - only the one that actually matches the device lights up',
        'Fixed category pages (packages, documents, archives, downloads, etc.) not finding deeply nested files such as packages inside ZenFile/Backups/Apps; scanning now reaches deeper folders',
        'Fixed pressing Back after opening the media viewer from a category page (photos / videos / audio) jumping straight back to the category grid; navigation now goes back one level at a time and works correctly inside the folder view too',
        'Fixed the bottom navigation bar highlighting several tabs at once: after opening a custom slot page (Recent / Categories shortcut) the built-in tab highlight now turns off, so only one item is highlighted at any time',
      ]),
    ],
  );

  /// ── v3.5.2 ──────────────────────────────────────────────────────────
  static const _Changelog _v352 = _Changelog(
    version: 'v3.5.2',
    date: '2026-10-04',
    zh: [
      _ChangeSection('✨ 新功能', [
        '第三方 App 选文件时可直接使用 ZenFile 自己的文件浏览器：在 QQ / 微信等应用的「发送文件」「添加图片/视频/文件」里选择 ZenFile，打开的就是与文件浏览器一致的界面（列表 / 网格、缩略图、压缩包格式图标、选中态），选完自动回传，起始目录默认停在内部存储',
        '压缩包新增 .7z / .rar 支持：解压与内置浏览均可（纯 Dart 解码，无需额外组件），支持带密码（含中文密码）的压缩包',
        '文件浏览页与分类页的安装包（.apk / .xapk / .apks / .apkm / .aab）在图标下方显示「已安装 / 未安装」，无需逐个点开查看',
      ]),
      _ChangeSection('🎨 界面与交互', [
        'ZenFile 自己的文件选择器界面与文件浏览器完全一致（复用同一套列表 / 网格条目、缩略图、文件类型图标与选中高亮），并新增列表 / 网格视图切换',
        '系统文件选择器的抽屉里，ZenFile 重新以「ZenFile」应用条目与「ZenFile Storage」根并存出现；根条目提示改为引导语，降低误点',
      ]),
      _ChangeSection('🐛 问题修复', [
        '修复从 QQ 等第三方 App 调起 ZenFile 选文件时页面停在「文件夹为空」：起始目录现在按 指定目录 → 根目录 → 内部存储 依次回退，不再出现空白页（论坛反馈）',
        '修复 ZenFile 在后台未关闭时被调起选文件却停在普通首页、无法选文件的问题（缓存引擎下回到前台会自动补查状态）',
        '修复「打开文档」场景下 ZenFile 不出现在候选列表的问题（OPEN_DOCUMENT 过滤器缺少 CATEGORY_OPENABLE）',
        '修复 ZenFile 已在后台时再次被第三方调起时不刷新选文件界面（新增 onNewIntent 处理）',
        '修复 SMB 远程目录加载失败后路径错位（面包屑停在目标共享、内容却仍是上一层）且没有提示：现在失败即回滚并弹出真实错误（论坛反馈）',
        '修复 SMB 共享列表少显示共享的问题：不再静默以匿名（guest）身份登录，未勾选「匿名登录」时必须填写用户名（论坛反馈）',
        '修复远程媒体缩略图不全与播放卡顿：修复带宽令牌桶死循环导致的队列卡死，视频头部探测加宽（2MB → 8MB）、完整下载兜底放宽（100MB → 300MB），播放期间暂停缩略图下载以让出带宽（论坛反馈）',
        '修复中文密码解压 ZIP 失败：密码候选改用 CRC32 校验判定，不再被错误的第一个候选误判命中',
      ]),
    ],
    en: [
      _ChangeSection('✨ New Features', [
        'Third-party apps can now use ZenFile\'s own file browser when picking files: choose ZenFile in "Send file" / "Add photo, video or file" in QQ, WeChat and others and you get the full file-browser UI (list / grid, thumbnails, archive-format icons, selection state) with results returned automatically, starting in internal storage by default',
        'Archive support for .7z / .rar: both extraction and in-app browsing work (pure-Dart decoders, no extra components), including password-protected archives (Chinese passwords supported)',
        'Installation packages (.apk / .xapk / .apks / .apkm / .aab) in the file browser and category pages now show an "Installed / Not installed" badge under the icon, no need to open each one',
      ]),
      _ChangeSection('🎨 UI & Interaction', [
        'ZenFile\'s own file picker now looks exactly like the file browser (same list / grid entries, thumbnails, file-type icons and selection highlight) and gains a list / grid view toggle',
        'In the system file-picker drawer, ZenFile once again appears as both a "ZenFile" app entry and a "ZenFile Storage" root; the root entry hint is now a guidance line to reduce mistaps',
      ]),
      _ChangeSection('🐛 Bug Fixes', [
        'Fixed the picker showing an empty folder when launched from QQ and other third-party apps: the start directory now falls back through requested path, root path and internal storage, so no more blank pages (forum feedback)',
        'Fixed the picker landing on the normal home screen (with no way to pick a file) when ZenFile was still alive in the background (state is now re-checked on resume with the cached engine)',
        'Fixed ZenFile not appearing as a candidate in the "Open document" flow (the OPEN_DOCUMENT filter was missing CATEGORY_OPENABLE)',
        'Fixed the picker UI not refreshing when ZenFile was already in the background and got launched again (added onNewIntent handling)',
        'Fixed SMB remote directories going out of sync after a failed load (breadcrumb at the target share while the list still showed the parent) with no error shown: failures now roll back the path and surface the real error (forum feedback)',
        'Fixed some SMB shares missing from the share list: ZenFile no longer logs in silently as anonymous (guest); a username is now required unless "Anonymous login" is checked (forum feedback)',
        'Fixed incomplete remote video thumbnails and playback stutter: a token-bucket deadlock that stalled the thumbnail queue, a wider video header probe (2MB to 8MB), a higher full-download fallback cap (100MB to 300MB), and thumbnails are paused during playback to free up bandwidth (forum feedback)',
        'Fixed ZIP archives with a Chinese password failing to extract: password candidates are now validated by CRC32 instead of wrongly accepting the first candidate',
      ]),
    ],
  );

  static const _Changelog _v351 = _Changelog(
    version: 'v3.5.1',
    date: '2026-10-03',
    zh: [
      _ChangeSection('✨ 新功能', [
        '全局备份新增「敏感信息加密」：远程服务器密码、保险箱密码与哈希、网盘令牌等敏感项可整体加密进备份文件。备份时设置口令，恢复时输入对口令即自动还原，无需逐项重配；口令留空则保持仅备份非敏感设置（论坛反馈）',
      ]),
      _ChangeSection('🐛 问题修复', [
        '修复 SMB 连接切后台较久后彻底冻结：前两轮修复未覆盖「客户端缓存的树连接已关闭」形态，现已在取出缓存时校验连接状态并自动重建，回前台不再冻结（论坛反馈）',
        '修复 SMB 断连后 Dart 侧会话失效判定漏匹配（原生异常的关键文案未回传）导致远程页面卡死、只能重启应用的问题',
        '修复保险箱「自动加密」在相机重建同名明文目录场景下 pending 监听永不转正、以及目录名解密冲突（同名明文目录已存在）卡死无法收敛的问题',
        '修复自动加密前台服务对带 IN_ISDIR 标志的目录级 inotify 事件做精确等值比较失配，导致同名目录重建后不再被监听、新增文件不被自动加密',
      ]),
      _ChangeSection('🛠️ 安全与维护', [
        '关闭发布版本的调试日志输出（SMB/WebDAV 取证日志、自动加密日志），不再在用户设备上落盘',
      ]),
    ],
    en: [
      _ChangeSection('✨ New Features', [
        'Settings backup now supports "sensitive-data encryption": remote-server passwords, vault passwords/hashes and cloud-drive tokens are encrypted into the backup as a block. Set a passphrase when backing up; restoring with the matching passphrase brings everything back automatically - no more re-entering credentials one by one. Leaving the passphrase empty keeps the previous behavior of backing up only non-sensitive settings (forum feedback)',
      ]),
      _ChangeSection('🐛 Bug Fixes', [
        'Fixed SMB connections freezing hard after staying in the background for a while: a form not covered by the previous two fixes ("the cached tree connection was closed on the client side") is now detected by checking the connection state when the cache is fetched and rebuilt automatically, so returning to the app no longer freezes (forum feedback)',
        'Fixed SMB drops going undetected on the Dart side (the key exception text in the cause chain was not forwarded) which left the remote page stuck until the app was restarted',
        'Fixed the vault "auto-encrypt" getting stuck when the camera recreated a plain-text folder with the same name (pending watch never promoted) and when decrypting a directory name clashed with an existing plain-text folder (conflict never converged)',
        'Fixed the auto-encrypt foreground service doing an exact match on directory-level inotify events carrying the IN_ISDIR flag, so a recreated same-name folder stopped being watched and new files were no longer auto-encrypted',
      ]),
      _ChangeSection('🛠️ Security & Maintenance', [
        'Debug logging (SMB/WebDAV forensic logs, auto-encrypt logs) is turned off in release builds and no longer writes to the device',
      ]),
    ],
  );

  static const _Changelog _v350 = _Changelog(
    version: 'v3.5.0',
    date: '2026-10-03',
    zh: [
      _ChangeSection('✨ 新功能', [
        '保险箱新增「自动加密新增文件」：开启后，原地加密目录（如相机目录）里新出现的照片和视频会被自动加密，无需再手动点「加密新增文件」；即使相机重建了同名明文目录，也会自动并入已加密目录并实时刷新浏览页（论坛反馈）',
        '空间分析页新增「垃圾清理」：一键统计并清理应用缓存、旧版缓存目录与临时文件（24 小时内的更新安装包会自动保留，避免安装器读不到）',
        '文件与分类页的三点菜单新增「置顶 / 取消置顶」',
        '安全分享扩展到 ZIP 压缩包与 PDF 文档：同样先剥离元数据再分享临时副本',
        'Web 分享新增可选访问口令；启用公网隧道时强制鉴权，未设口令会自动生成 8 位口令并弹窗展示',
        'FTP 服务器新增用户名/密码认证模式（也可切回匿名）；SFTP 首次连接记录服务器主机密钥指纹，之后指纹不匹配即拒绝连接，防止中间人攻击',
      ]),
      _ChangeSection('🎨 界面与交互', [
        '加密目录与重建的同名明文目录并存时，两个条目都能正确进入：点加密条目看到已加密内容，点明文条目看到新文件，不再互相遮住',
        '加密冲突期间（同名目录并存时）浏览页面包屑改显解密后的明文名，点击仍导航到真实位置',
        '保险箱配置页的四个密钥空间参数（目录名/文件名加密方式等）创建后锁定并显示提示条，防止误改导致已有密文无法解回',
        '分类页「空间」卡片小字改为「清理」，与新增的垃圾清理功能呼应；加密/解密操作图标统一为 Broken 风格',
      ]),
      _ChangeSection('🐛 问题修复', [
        '修复 SMB 连接切后台或切页后回来「目录失效、必须关掉重进」：会话假死现在能被可靠识别，回前台或下次操作时自动重建连接，全程无感（论坛反馈）',
        '修复保险箱「原地加密」列表把普通文件夹误显示为密文目录（某些配置下判据恒真所致）',
        '修复「加密新增文件」合并完成后浏览页不自动刷新、需要手动下拉的问题',
        '修复在 FTP 服务器设置里只改用户名不改密码可能把认证配置改坏的问题',
      ]),
      _ChangeSection('🛠️ 安全与维护', [
        '远程连接密码、SSH 密钥口令、网盘令牌迁入系统安全存储：旧数据自动迁移，新写入不再含明文凭据',
        '应用解锁 PIN 哈希从单轮 SHA-256 升级为 scrypt：存量记录首次验证通过时透明升级，无需重设',
        '关闭 Android 云备份导出应用数据；设置备份文件不再包含 PIN 哈希、FTP 密码、分享口令、加密主密码等敏感项',
        '封堵 Web 分享与 FTP 服务器的路径逃逸（../ 绕过）及 FTP 主动模式端口反弹；FTPS 证书默认严格校验',
        '远程图片缩略图解码移入后台线程，10~30MB 大图不再卡住界面；缩略图缓存改为上限管理（400 条 / 64MB），不再无限增长',
        '加密文件覆盖写入改为块级读-改-写，大文件局部改写明显提速；应用字体本地打包，首次启动不再联网拉取',
      ]),
    ],
    en: [
      _ChangeSection('✨ New Features', [
        'The vault now offers "Auto-encrypt new files": once enabled, photos and videos appearing in an in-place encrypted directory (such as the camera folder) are encrypted automatically - no more tapping "Encrypt new files" by hand. Even if the camera recreates a plain-text folder with the same name, it is merged into the encrypted directory and the browser refreshes on its own (forum feedback)',
        'Storage analysis gains "Junk cleanup": scan and clean app caches, legacy cache directories and temp files in one tap (update packages younger than 24 hours are kept so the installer can still read them)',
        '"Pin / Unpin" added to the three-dot menus of file and category pages',
        'Secure share now covers ZIP archives and PDF documents: metadata is stripped before a temporary copy is shared',
        'Web sharing gains an optional access password; when a public tunnel is active, authentication is enforced and an 8-character password is generated automatically if none was set',
        'The FTP server now supports username/password authentication (anonymous mode remains available); SFTP records the server host key fingerprint on first connection (TOFU) and rejects mismatches afterwards, preventing man-in-the-middle attacks',
      ]),
      _ChangeSection('🎨 UI & Interaction', [
        'When an encrypted directory and a recreated plain-text directory with the same name coexist, both entries now work: the encrypted one shows encrypted content, the plain one shows new files - they no longer hide each other',
        'While such a conflict exists, breadcrumbs in the local browser show the decrypted plain name while still navigating to the real location',
        'The four key-space parameters of a vault profile (directory/file name encryption, etc.) are locked after creation with an amber notice, preventing accidental changes that would make existing ciphertext undecryptable',
        'The "Storage" card caption on the Categories page now reads "Clean" to match the new junk cleanup; encrypt/decrypt icons unified to the Broken style',
      ]),
      _ChangeSection('🐛 Bug Fixes', [
        'Fixed SMB sessions dying silently after switching away from the app ("directory no longer valid, must reopen"): the dead session is now detected reliably and rebuilt transparently when you return or on the next operation (forum feedback)',
        'Fixed the vault in-place encryption list treating ordinary folders as encrypted directories under certain configurations',
        'Fixed the browser not refreshing automatically after "Encrypt new files" finished merging a directory',
        'Fixed the FTP server settings allowing the password to be wiped when only the username was changed',
      ]),
      _ChangeSection('🛠️ Security & Maintenance', [
        'Remote connection passwords, SSH key passphrases and cloud-drive tokens moved into the system secure storage: legacy data migrates automatically and new writes never contain plain credentials',
        'The unlock PIN hash was upgraded from single-round SHA-256 to scrypt: existing records upgrade transparently on the first successful verification, no re-setup needed',
        'Android cloud backup of app data is now disabled; settings backup files no longer contain the PIN hash, FTP password, share password, vault master password or other sensitive items',
        'Path traversal (../ escape) in Web sharing and the FTP server is blocked, as is FTP active-mode port bounce; FTPS certificate verification is strict by default',
        'Remote image thumbnails are decoded on a background thread - 10~30 MB images no longer freeze the UI; the thumbnail cache is now LRU-capped (400 entries / 64 MB) instead of growing forever',
        'Encrypted-file overwrite switched to block-level read-modify-write, visibly speeding up partial rewrites of large files; fonts are bundled locally so the first launch no longer fetches them online',
      ]),
    ],
  );

  /// ── 当前版本：v3.4.1 ────────────────────────────────────────────────
  static const _Changelog _v341 = _Changelog(
    version: 'v3.4.1',
    date: '2026-10-01',
    zh: [
      _ChangeSection('✨ 新功能', [
        '分享图片时可以选择「安全分享」：先去掉 EXIF 等元数据，再分享一份临时副本，原图完全不受影响',
        '「版本更新」页新增「启动时弹窗提醒」开关：关掉后启动时不再检测更新（连网络请求都不会发），随时能在同一张卡片里开回来',
        '启动时的「发现新版本」弹窗新增「不再提醒」按钮：点一下等同于关掉上面那个开关，两处状态永远同步',
      ]),
      _ChangeSection('🎨 界面与交互', [
        '「版本更新」页 GitHub 检测卡片的标题图标换成更贴切的「系统更新」图标（旧图标与右侧「重试」的刷新图标撞脸，容易被误认成刷新按钮）',
        '启动弹窗的「忽略」改为**只忽略本次**：下次启动遇到同一个版本仍会提醒，不再被一次性永久静音；想彻底安静请点「不再提醒」',
        '底部 4-tab 的「连接」槽位默认图标由「快传」改为「连接」，与分类页的连接入口保持一致',
      ]),
      _ChangeSection('🐛 问题修复', [
        '修复文件夹「属性」里的「创建时间」整行消失（issue #39 回归）：改为读取文件系统真实的创建时间，取不到时继续隐藏该行，不再拿「修改时间」冒充',
        '修复自动下载的更新安装包在应用私有缓存里无限堆积：改为统一管理，每次启动清理超过 24 小时的旧包，下载失败或被取消留下的半成品立刻删除（正在安装的那个不动，否则安装器会读不到文件）',
      ]),
    ],
    en: [
      _ChangeSection('✨ New Features', [
        'Images can now be shared with "Secure share": a temporary copy with EXIF metadata stripped out is shared, leaving the original file untouched',
        'The Update page has a new "Prompt on startup" switch: turn it off and the app no longer checks for updates on launch (it does not even make a network request); flip it back on any time from the same card',
        'The startup "New version available" dialog has a new "Do not remind again" button: tapping it is the same as turning that switch off, so the two always stay in sync',
      ]),
      _ChangeSection('🎨 UI & Interaction', [
        'The title icon of the GitHub check card on the Update page is now a proper system-update icon (the old one clashed with the "Retry" refresh icon next to it and read as a refresh button)',
        '"Ignore" in the startup dialog now ignores that one prompt only: the next launch shows it again for the same version instead of silencing it forever; use "Do not remind again" to go fully quiet',
        'The default icon of the "Connection" slot in the 4-tab bar changed from "Quick transfer" to "Connection", matching the Connection entry on the Categories page',
      ]),
      _ChangeSection('🐛 Bug Fixes', [
        'Fixed the folder "Creation Time" row disappearing entirely in Properties (issue #39 regression): the real filesystem creation time is now read, and the row stays hidden when it is unavailable instead of falling back to "Modified"',
        'Fixed downloaded update packages piling up forever in the app private cache: they are managed centrally now - packages older than 24 hours are cleaned on every launch, and half-written files from failed or cancelled downloads are deleted immediately (the package being installed is left alone, otherwise the installer cannot read it)',
      ]),
    ],
  );

  /// ── 上一版：v3.4.0 ─────────────────────────────────────────────────
  static const _Changelog _v340 = _Changelog(
    version: 'v3.4.0',
    date: '2026-09-30',
    zh: [
      _ChangeSection('✨ 新功能', [
        '文件 / 文件夹「属性」对话框新增「创建时间」一行（类似 MiXplorer）：取自 MediaStore 加入时间（DATE_ADDED），与「修改时间」来源不同、绝大多数文件天然不相等；分类页属性页也已补齐这一行',
        '多任务剪贴板（issue #36）：复制 / 剪切现在累计为多个任务，面板用分割线区分，每个任务可单独粘贴 / 删除；远程（FTP / SMB / WebDAV）任务一并纳入，最多保留 20 个',
        '文件属性新增「计算哈希值」按钮：点击后才流式计算 MD5 / SHA-256（非打开属性即算），本地文件可用，大文件也只占少量内存',
        '分类页属性对话框对文件夹显示「包含 N 子文件夹 / M 文件」（与浏览页一致），并统计其总大小',
        '底部 4-tab 可常驻其他页面（默认开启）：从抽屉、分类、「最近」等入口进入的页面同样保留底部导航栏，随时切换标签；进入视频播放 / 图片查看的沉浸态时自动收起，唤出控制条或操作按钮时恢复（设置 → 常规与行为 → 导航栏中可关闭）',
        '时间与日期格式可自定义（issue #38）：日期支持 DD/MM/YYYY、MM/DD/YYYY、YYYY-MM-DD 三种格式，时间支持 12 / 24 小时制，选择后整个应用统一生效',
        '「显示三点操作按钮」设置方式优化：打开开关即弹出模式选择（全部显示 / 仅单窗口 / 仅双窗口），选完自动收起，不再内联展开占位',
      ]),
      _ChangeSection('🎨 界面与交互', [
        '分类页（视频、音频、图片、文档、下载、截图、压缩包、安装包）的多选操作栏，与浏览页、「最近」页改用同一套按钮组件',
        '开启「隐藏操作栏文字标签」后，上述所有分类页的多选操作栏现在都会同步隐藏文字、只显示图标，与浏览页 /「最近」页习惯一致',
        '「更多」操作（分享、详情、收藏等）在隐藏文字标签时同样只显示图标，不再露出文字',
        '剪贴板面板底部改为「清除（窄）+ 粘贴全部（右侧）」，粘贴全部按每任务勾选状态决定保留 / 清除；面板顶部标题已移除，更紧凑',
        '设置页「时间与日期格式」与「在列表中隐藏时间和日期」合并为「时间与日期显示」单一条目，点开弹出合并面板（日期 / 时间格式选择 + 隐藏开关）',
        '远程添加向导的协议卡片改为单行卡片（图标 + 标题 + 描述 + 右箭头），纵向排列、点选区域更大，整体风格统一',
        '分类页多选时，操作栏改为覆盖并收起底部导航栏，不再叠在它上方',
      ]),
      _ChangeSection('🛠️ 维护优化', [
        '将操作栏按钮渲染逻辑抽离为共用的 ActionBarButton 组件，浏览页与分类页共享同一份隐藏文字 / 配色 / 尺寸规则，后续只改一处',
        '剪贴板面板每个任务拥有独立的「清除」与「粘贴后保留」勾选，粘贴后默认自动清除该任务（复制不勾选则清除、剪切始终清除）',
        '远程添加向导的协议选项改为复用同一套卡片组件，后续调整只需改一处',
      ]),
      _ChangeSection('🐛 问题修复', [
        '修复「隐藏操作栏文字标签」设置对分类页（除「最近」外）不生效的问题',
        '修复新增的 4 个备用图标（蓝白 / 渐变蓝 / 深蓝鎏金 / 暮色）在设置中切换不生效的问题',
        '修复时间 / 日期格式选择弹窗点不中：选中状态被反复重置，选项永远停在默认值',
        '修复「时间与日期格式」「显示三点操作按钮」的开关点不动，只能整行点击弹窗',
        '修复远程连接（SMB 等）切到别的页面再回来就连不上、必须重启应用：重连判定补齐 socket 超时类错误，返回目录时自动重建连接',
        '修复远程文件列表的日期不跟随「时间与日期格式」设置',
      ]),
    ],
    en: [
      _ChangeSection('✨ New Features', [
        'The file / folder "Properties" dialog now shows a "Creation Time" row (like MiXplorer): sourced from MediaStore DATE_ADDED, a different clock from "Modified" so they differ for most files; the category-page properties dialog now shows this row too',
        'Multi-task clipboard (issue #36): copy / cut now accumulate into separate tasks, divided by dividers in the panel, each pannable and deletable on its own; remote (FTP / SMB / WebDAV) tasks are included too, up to 20 kept',
        'The file "Properties" dialog now has a "Calculate Hash" button: MD5 / SHA-256 are computed on demand (streaming, not at open) for local files, using little memory even for large files',
        'The category-page properties dialog now shows "N subfolder(s) / M file(s)" for folders (matching the Browse page) and their total size',
        'The bottom 4-tab bar can now stay visible on other pages (on by default): pages opened from the drawer, categories or Recent keep the bottom navigation so tabs are always reachable; it slides away when you enter immersive video playback or image viewing, and returns when the controls are shown (can be turned off in Settings -> General & Behavior -> Navigation bar)',
        'Customizable date & time format (issue #38): pick DD/MM/YYYY, MM/DD/YYYY or YYYY-MM-DD, and 12- or 24-hour time; the choice applies across the whole app',
        '"Show the three-dot action button" is easier to set up now: turning the switch on pops up the mode picker (Always / Single pane only / Dual pane only) and closes itself once chosen',
      ]),
      _ChangeSection('🎨 UI & Interaction', [
        'The multi-select action bar of category pages (Video, Audio, Image, Document, Downloads, Screenshots, Archives, APK) now shares the same button widget as the Browse and Recent pages',
        'With "Hide action bar text labels" on, those category pages now also hide the text and show icons only, matching the Browse and Recent pages',
        'The "More" overflow (Share, Details, Favorite, etc.) also shows icon only when labels are hidden',
        'Clipboard panel bottom is now "Clear (narrow) + Paste All (right)"; Paste All respects each task keep-after-paste choice; the top title was removed for a more compact panel',
        'In Settings, "Date & Time Format" and "Hide time and date in list" are merged into a single "Date & Time Display" item that opens a combined sheet (date / time format pickers + hide toggle)',
        'Protocol cards in the Add Remote wizard are now single-row cards (icon + title + description + arrow), stacked vertically with a bigger tap area and a consistent look',
        'In category pages, the multi-select action bar now covers and hides the bottom navigation bar instead of stacking above it',
      ]),
      _ChangeSection('🛠️ Maintenance', [
        'Extracted the action bar button into a shared ActionBarButton widget so the Browse and Category pages use one source of truth for label-hiding, color and sizing',
        'In the clipboard panel each task has its own "Clear" and "Keep after paste" toggle; after pasting a task is cleared by default (copy without the toggle is cleared, cut is always cleared)',
        'Protocol options in the Add Remote wizard now reuse one shared card widget, so future changes are made in a single place',
      ]),
      _ChangeSection('🐛 Bug Fixes', [
        'Fixed "Hide action bar text labels" having no effect on category pages (except Recent)',
        'Fixed the 4 newly added alternative icons (Blue-White / Gradient-Blue / Blue-Gold / Sunset) not taking effect when selected in Settings',
        'Fixed the date / time format picker not being selectable: the selection was reset on every rebuild and always fell back to the default',
        'Fixed the "Date & Time Format" and "Show three-dot action button" switches not being tappable - only tapping the whole row worked',
        'Fixed remote connections (SMB etc.) becoming unreachable after switching pages until the app was restarted: the reconnect check now recognizes socket-timeout errors and rebuilds the connection automatically',
        'Fixed remote file lists not following the "Date & Time Format" setting',
      ]),
    ],
  );

  /// ── 上一版：v3.3.0 ─────────────────────────────────────────────────
  static const _Changelog _v330 = _Changelog(
    version: 'v3.3.0',
    date: '2026-09-28',
    zh: [
      _ChangeSection('✨ 新功能', [
        '剪贴板粘贴后可选「保留剪贴板」或「自动清空」，并记住上次的选择',
        '双窗口剪切新增「剪切到另一窗口」与「剪切到剪贴板」',
        '新建文件夹后自动进入该文件夹（设置内可关闭）',
        '存储空间 / 应用管理的扫描结果本地缓存，重开页面秒出，下拉刷新才重新统计',
        '「版本更新」页可查看并一键复制更新日志；启动时发现新版本会弹窗提醒，可忽略该版本',
      ]),
      _ChangeSection('🎨 界面与交互', [
        '底部导航「传输」改名为「连接」，「网络」改名为「远程」，图标同步更新（10 种语言）',
        '剪贴板「粘贴后保留」勾选项改为整行可点，不再只有小方框点得中',
        '多选操作栏不再被底部导航栏遮挡',
        '设置新增「新建文件夹自动打开」开关',
      ]),
      _ChangeSection('🐛 问题修复', [
        '修复播放 / 切歌时闪退：通知栏小图标被资源裁剪，导致没有有效图标',
        '修复通知栏进度刷新过于频繁造成的「无响应」（ANR）',
        '修复后台播放：切歌偶尔跳到播放列表之外、断开耳机后音乐不暂停',
        '修复反复进出视频播放页的闪退（后台播放会话改为接管退役，同一时刻只保留一个播放实例）',
        '修复播放器事件订阅未释放，反复进出播放页时监听层层叠加',
        '修复存储分析 / 应用管理点刷新仍是旧数据、必须重启应用才正确',
        '修复已删除的崩溃报告被自动补回',
        '修复双窗口复制 / 剪切后文件列表空白',
      ]),
    ],
    en: [
      _ChangeSection('✨ New Features', [
        'Clipboard: after pasting you may keep the clipboard or clear it automatically, and the choice is remembered',
        'Dual-pane cut now offers "Cut to the other pane" and "Cut to clipboard"',
        'New folders open automatically right after creation (can be turned off in Settings)',
        'Storage and Apps scan results are cached, so reopening the page is instant; pull to refresh to re-scan',
        'The Version Update page shows the changelog with one-tap copy, and a dialog appears on startup when a new version is found (the version can be ignored)',
      ]),
      _ChangeSection('🎨 UI & Interaction', [
        'Bottom navigation: "Transfer" renamed to "Connections" and "Network" renamed to "Remote", with matching new icons (10 languages)',
        'The clipboard "keep after paste" option is now tappable across the whole row, not just the small checkbox',
        'The multi-select action bar is no longer covered by the bottom navigation bar',
        'New "Open new folder automatically" switch in Settings',
      ]),
      _ChangeSection('🐛 Bug Fixes', [
        'Fixed crashes while playing or skipping tracks: the notification small icon was stripped by resource shrinking',
        'Fixed "not responding" (ANR) caused by notification progress being refreshed too often',
        'Fixed background playback: skipping a track could land outside the playlist, and unplugging headphones did not pause playback',
        'Fixed crashes when repeatedly entering and leaving the video player (the background session now takes over and retires the old player, keeping only one instance alive)',
        'Fixed player event subscriptions never being cancelled, which piled up listeners when entering the player repeatedly',
        'Fixed Storage / Apps showing stale numbers after a refresh until the app was restarted',
        'Fixed deleted crash reports being restored automatically',
        'Fixed blank file lists after copy or cut in dual-pane mode',
      ]),
    ],
  );

  /// ── 上一版：v3.2.0（原文案原样保留，不再删除，改为折叠展示）──────────
  static const _Changelog _v320 = _Changelog(
    version: 'v3.2.0',
    date: '2026-09-28',
    zh: [
      _ChangeSection('✨ 新功能', [
        '目录加解密采用多核并行处理，速度提升约 2 倍',
        '视频后台播放支持随时开启与关闭（带提示），首次开启引导通知权限，开启后播放页不再退出',
        '音频播放器进度条常驻显示，支持倍速 / 音量记忆',
        '图片查看器新增宽度 / 高度 / 原始三态显示切换',
        '应用图标新增 4 款：浅灰纸纹、磨砂金属、蓝色文件夹、深蓝鎏金；深蓝鎏金设为默认图标，原默认图标转为备选「经典图标」',
      ]),
      _ChangeSection('🎨 界面与交互', [
        '新增「传输」页面：网络、FTP 共享、Web 共享入口迁入；「我的」页面入口保留',
        '收藏夹改为底部半屏面板，可从底部上滑唤起，附带使用提示',
        '导航栏显示 / 位置整合为统一入口并双向同步，默认显示在底部；分类页与浏览页顶部背景统一',
        '单 / 双窗口切换按钮点击后自动跳转文件浏览页',
      ]),
      _ChangeSection('🐛 问题修复', [
        '修复后台播放、切换软硬解码、退出播放等场景下的偶发闪退',
        '互联网分享链接修复：不再被管理后台地址顶替、不再卡在占位，多节点隧道自动切换',
        '修复「最近」页打开本地文件被误判为远程文件而无法打开的问题',
        '远程缩略图改为按顺序单文件加载并限制带宽，打开远程目录不再卡顿、占用大量流量',
        'SAF 提示与新增界面文案全部支持多语言',
      ]),
    ],
    en: [
      _ChangeSection('✨ New Features', [
        'Directory encryption/decryption now runs on multiple CPU cores in parallel — up to ~2x faster',
        'Video background playback can be toggled on/off anytime (with a toast), guides notification permission on first use, and the player page no longer closes',
        'Audio player: seek bar always visible, playback speed and volume remembered',
        'Image viewer: new fit modes — fit width / fit height / original size',
        '4 new app icons: Light Gray Paper, Frosted Metal, Blue Folder and Blue Gold; Blue Gold is now the default icon, and the original default becomes the "Classic Icon" alternative',
      ]),
      _ChangeSection('🎨 UI & Interaction', [
        'New "Transfer" page hosting Network, FTP Sharing and Web Sharing entries; the "Mine" page entry is kept',
        'Favorites is now a bottom half-screen panel, swipe up from the bottom edge to open, with a usage hint',
        'Navigation bar visibility and position merged into one setting with two-way sync, defaulting to the bottom; unified top backgrounds for Categories and Browse pages',
        'The single/dual-pane toggle now jumps to the file browser first',
      ]),
      _ChangeSection('🐛 Bug Fixes', [
        'Fixed occasional crashes when toggling background playback, switching hardware/software decoding, or leaving the player',
        'Internet sharing link fixed: no longer hijacked by the dashboard address or stuck at the placeholder; auto-fallback between multiple tunnel nodes',
        'Fixed "Recent" page misidentifying local files as remote and failing to open them',
        'Remote thumbnails now load one file at a time with a bandwidth cap, so opening remote folders no longer lags or eats bandwidth',
        'SAF prompts and all new UI copy are now fully translated',
      ]),
    ],
  );

  /// 折叠状态：旧版本卡片默认收起，键为版本号（如 `v3.2.0`）。
  final Set<String> _expandedOldChangelogs = <String>{};

  void _toggleOldChangelog(String version) {
    setState(() {
      if (!_expandedOldChangelogs.remove(version)) {
        _expandedOldChangelogs.add(version);
      }
    });
  }

  /// 把某版本的更新日志（中英双语）复制成**纯文本**。
  ///
  /// 与屏幕展示同源（都从 [_Changelog] 生成）⇒ 粘出去的内容不会跟界面走偏；
  /// 不带任何界面文案，粘出去就是干净的 release notes。
  Future<void> _copyChangelogText(L10n l10n, _Changelog data) async {
    final buffer = StringBuffer()
      ..writeln('ZenFile ${data.version} (${data.date})')
      ..writeln();
    void writeSections(List<_ChangeSection> sections) {
      for (var k = 0; k < sections.length; k++) {
        if (k > 0) buffer.writeln();
        buffer.writeln(sections[k].title);
        for (final it in sections[k].items) {
          buffer.writeln('\u00b7 $it');
        }
      }
    }

    writeSections(data.zh);
    buffer
      ..writeln()
      ..writeln('---------------- English ----------------')
      ..writeln();
    writeSections(data.en);

    final messenger = ScaffoldMessenger.of(context);
    await Clipboard.setData(ClipboardData(text: buffer.toString().trimRight()));
    if (!mounted) return;
    messenger.showSnackBar(
      SnackBar(
        content: Text(l10n.msg4fb42e6e), // 「已复制到剪贴板」
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  /// 全部版本的更新日志列表：最新版展开，其余折叠。
  Widget _buildChangelogList(ThemeData theme, L10n l10n) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final c in _changelogs)
          _buildChangelogCard(
            theme: theme,
            l10n: l10n,
            data: c,
            collapsible: c.version != _latestChangelogVersion,
          ),
      ],
    );
  }

  /// 一张更新日志卡片。
  ///
  /// [collapsible] 为 true = 旧版本（默认收起，点标题行展开）；
  /// false = 当前版本（始终展开，不给折叠入口）。
  Widget _buildChangelogCard({
    required ThemeData theme,
    required L10n l10n,
    required _Changelog data,
    required bool collapsible,
  }) {
    final expanded =
        !collapsible || _expandedOldChangelogs.contains(data.version);
    final textStyle = TextStyle(
      fontSize: 13.5,
      height: 1.6,
      color: theme.colorScheme.onSurface.withValues(alpha: 0.85),
    );
    final dividerColor = theme.colorScheme.onSurface.withValues(alpha: 0.15);

    Widget item(String text) => Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Text('\u00b7 $text', style: textStyle),
        );
    Widget section(String title) => Padding(
          padding: const EdgeInsets.only(top: 6, bottom: 4),
          child: Text(
            title,
            style: TextStyle(
              fontSize: 14,
              height: 1.6,
              color: theme.colorScheme.primary,
              fontWeight: FontWeight.w700,
            ),
          ),
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
                child: Text(
                  'English',
                  style: TextStyle(
                    fontSize: 12,
                    letterSpacing: 1.2,
                    fontWeight: FontWeight.w600,
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
                  ),
                ),
              ),
              Expanded(child: Container(height: 1, color: dividerColor)),
            ],
          ),
        );

    /// 一个语言的全部分区（区间插分隔线）。
    List<Widget> sectionsOf(List<_ChangeSection> sections) {
      final out = <Widget>[];
      for (var k = 0; k < sections.length; k++) {
        if (k > 0) out.add(divider());
        out.add(section(sections[k].title));
        for (final t in sections[k].items) {
          out.add(item(t));
        }
      }
      return out;
    }

    final copyButton = IconButton(
      onPressed: () => _copyChangelogText(l10n, data),
      tooltip: l10n.ui_copy,
      visualDensity: VisualDensity.compact,
      padding: const EdgeInsets.all(4),
      constraints: const BoxConstraints(),
      icon: Icon(Broken.copy, size: 16, color: theme.colorScheme.primary),
    );

    final title = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(
            color: theme.colorScheme.primary.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(20),
          ),
          child: Text(
            data.version,
            style: TextStyle(
              color: theme.colorScheme.primary,
              fontSize: 13,
              fontWeight: FontWeight.bold,
              fontFamily: 'LexendDeca',
            ),
          ),
        ),
        const SizedBox(width: 10),
        Text(
          data.date,
          style: TextStyle(
            fontSize: 12,
            color: theme.colorScheme.onSurface.withValues(alpha: 0.4),
          ),
        ),
      ],
    );

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceVariant.withValues(alpha: 0.3),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: theme.colorScheme.onSurface.withValues(alpha: 0.06),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (!collapsible)
            Row(
              children: [title, const Spacer(), copyButton],
            )
          else
            Row(
              children: [
                Expanded(
                  child: InkWell(
                    onTap: () => _toggleOldChangelog(data.version),
                    borderRadius: BorderRadius.circular(8),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Row(
                        children: [
                          title,
                          const Spacer(),
                          Icon(
                            expanded
                                ? Icons.expand_less
                                : Icons.expand_more,
                            size: 20,
                            color: theme.colorScheme.onSurface
                                .withValues(alpha: 0.55),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                copyButton,
              ],
            ),
          if (expanded) ...[
            const SizedBox(height: 14),
            ...sectionsOf(data.zh),
            langDivider(),
            ...sectionsOf(data.en),
          ],
        ],
      ),
    );
  }
}

/// 更新日志里的一个分区（标题 + 若干条目）。
class _ChangeSection {
  const _ChangeSection(this.title, this.items);

  final String title;
  final List<String> items;
}

/// 一个版本的完整更新日志（中文 + 英文双语，硬编码，不走 l10n）。
///
/// 界面与「复制按钮」的纯文本**都从这里生成** ⇒ 两处永远一致。
class _Changelog {
  const _Changelog({
    required this.version,
    required this.date,
    required this.zh,
    required this.en,
  });

  /// 形如 `v3.3.0`。同时用作折叠状态表的键。
  final String version;

  /// 形如 `2026-09-28`。
  final String date;

  final List<_ChangeSection> zh;
  final List<_ChangeSection> en;
}
