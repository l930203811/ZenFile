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
  static const String _latestChangelogVersion = 'v3.5.5';

  /// 全部版本的更新日志，**最新在最前**。
  static const List<_Changelog> _changelogs = <_Changelog>[
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

  /// ── 当前版本：v3.5.5 ────────────────────────────────────────────────
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
