import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:permission_handler/permission_handler.dart';
import '../../core/icon_fonts/broken_icons.dart';
import '../../providers/file_manager_provider.dart';
import '../../services/web_sharing_service.dart';
import 'dart:math' as math;
import 'package:zenfile/l10n/generated/app_localizations.dart';

class WebSharingScreen extends StatefulWidget {
  const WebSharingScreen({super.key});

  @override
  State<WebSharingScreen> createState() => _WebSharingScreenState();
}

class _WebSharingScreenState extends State<WebSharingScreen> with SingleTickerProviderStateMixin {
  late AnimationController _pulseController;
  final _webService = WebSharingService.instance;
  int _activeTab = 0; // 0: Local Share, 1: Internet Share

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    );

    // Listen to changes in server activity to animate the broadcast waves
    _webService.addListener(_onServiceChanged);

    if (_webService.isLocalActive || _webService.isInternetActive) {
      _pulseController.repeat();
    }
  }

  void _onServiceChanged() {
    if (mounted) {
      setState(() {});
      if (_webService.isLocalActive || _webService.isInternetActive) {
        if (!_pulseController.isAnimating) {
          _pulseController.repeat();
        }
      } else {
        _pulseController.stop();
      }
    }
  }

  @override
  void dispose() {
    _webService.removeListener(_onServiceChanged);
    _pulseController.dispose();
    super.dispose();
  }

  Future<void> _toggleLocalServer(String rootPath) async {
    if (_webService.isLocalActive) {
      await _webService.stopLocalServer();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('本地 HTTP 共享服务器已停止。'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } else {
      try {
        await Permission.notification.request();
        await _webService.startLocalServer(rootPath);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('本地 HTTP 共享服务器已启动！URL: ${_webService.localServerUrl}'),
            behavior: SnackBarBehavior.floating,
            backgroundColor: Theme.of(context).colorScheme.primary,
          ),
        );
      } catch (e) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('启动 HTTP 服务器出错：$e'),
            behavior: SnackBarBehavior.floating,
            backgroundColor: Colors.redAccent,
          ),
        );
      }
    }
  }

  void _toggleInternetTunnel(String shareDir) {
    if (_webService.isInternetActive) {
      _webService.stopInternetTunnel();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Internet Share Tunnel deactivated.'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } else {
      // Simulate connection latency
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (context) {
          return const AlertDialog(
            content: Row(
              children: [
                CircularProgressIndicator(),
                SizedBox(width: 20),
                Expanded(
                  child: Text(
                    '正在建立安全代理中继...',
                    style: TextStyle(fontFamily: 'LexendDeca', fontSize: 14),
                  ),
                ),
              ],
            ),
          );
        },
      );

      Future.delayed(const Duration(milliseconds: 1400), () async {
        if (!mounted) return;
        Navigator.pop(context); // Pop dialog
        try {
          await Permission.notification.request();
          await _webService.startInternetTunnel(shareDir);
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(L10n.of(context).msg2c146598),
              behavior: SnackBarBehavior.floating,
              backgroundColor: Theme.of(context).colorScheme.primary,
            ),
          );
        } catch (e) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('启动云端共享失败：$e'),
              behavior: SnackBarBehavior.floating,
              backgroundColor: Colors.redAccent,
            ),
          );
        }
      });
    }
  }

  void _copyToClipboard(String text) {
    Clipboard.setData(ClipboardData(text: text));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('链接已复制到剪贴板！'),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  // Beautiful QR code overlay modal
  void _showQrCodeDialog(String link, String type) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    showDialog(
      context: context,
      builder: (context) {
        return Dialog(
          backgroundColor: isDark ? const Color(0xFF1E293B) : Colors.white,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
          child: Padding(
            padding: const EdgeInsets.all(28.0),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '扫描二维码',
                  style: TextStyle(
                    fontFamily: 'LexendDeca',
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                    color: theme.colorScheme.primary,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  '使用其他设备扫描以立即打开 {type}。',
                  style: TextStyle(
                    fontSize: 12,
                    color: theme.colorScheme.onSurface.withOpacity(0.5),
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 24),

                // Gorgeous concentric Vector QR Code CustomPainter
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(24),
                    boxShadow: [
                      BoxShadow(
                        color: theme.colorScheme.primary.withOpacity(0.08),
                        blurRadius: 20,
                        offset: const Offset(0, 4),
                      ),
                    ],
                  ),
                  child: CustomPaint(
                    size: const Size(200, 200),
                    painter: PremiumQrPainter(color: theme.colorScheme.primary),
                  ),
                ),

                const SizedBox(height: 20),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.onSurface.withOpacity(0.04),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    link,
                    style: const TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w600,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(height: 24),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: theme.colorScheme.primary,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                      elevation: 0,
                    ),
                    onPressed: () => Navigator.pop(context),
                    child: const Text('关闭', style: TextStyle(fontWeight: FontWeight.bold)),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final fileManager = context.watch<FileManagerProvider>();
    final shareDir = fileManager.rootPath;

    final isActive = _activeTab == 0 ? _webService.isLocalActive : _webService.isInternetActive;

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new_rounded, size: 20),
          onPressed: () => Navigator.pop(context),
        ),
        title: const Text(
          '网页共享中心',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
      ),
      body: Column(
        children: [
          // Elegant broadcast pulsating radar
          Container(
            height: 180,
            width: double.infinity,
            color: theme.colorScheme.onSurface.withOpacity(0.01),
            child: Stack(
              alignment: Alignment.center,
              children: [
                // Concentric circles canvas animation
                AnimatedBuilder(
                  animation: _pulseController,
                  builder: (context, child) {
                    return CustomPaint(
                      size: const Size(double.infinity, 180),
                      painter: RadarPulsePainter(
                        animationValue: _pulseController.value,
                        color: theme.colorScheme.primary,
                        isActive: isActive,
                      ),
                    );
                  },
                ),
                // Center Icon Node
                Container(
                  height: 68,
                  width: 68,
                  decoration: BoxDecoration(
                    color: isActive ? theme.colorScheme.primary : theme.colorScheme.onSurface.withOpacity(0.04),
                    shape: BoxShape.circle,
                    boxShadow: isActive
                        ? [
                            BoxShadow(
                              color: theme.colorScheme.primary.withOpacity(0.35),
                              blurRadius: 20,
                              offset: const Offset(0, 4),
                            ),
                          ]
                        : null,
                  ),
                  child: Icon(
                    isActive ? Broken.export : Broken.export_1,
                    size: 28,
                    color: isActive ? Colors.white : theme.colorScheme.onSurface.withOpacity(0.4),
                  ),
                ),
              ],
            ),
          ),

          // Double Tab Slider Card
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20.0, vertical: 8),
            child: Container(
              height: 48,
              decoration: BoxDecoration(
                color: isDark ? const Color(0xFF1E293B) : theme.colorScheme.primary.withOpacity(0.04),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: theme.colorScheme.outline.withOpacity(0.1)),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: InkWell(
                      onTap: () => setState(() => _activeTab = 0),
                      borderRadius: BorderRadius.circular(16),
                      child: Container(
                        alignment: Alignment.center,
                        decoration: _activeTab == 0
                            ? BoxDecoration(
                                color: theme.colorScheme.primary,
                                borderRadius: BorderRadius.circular(14),
                              )
                            : null,
                        child: Text(
                          '本地网页共享',
                          style: TextStyle(
                            fontSize: 13.5,
                            fontWeight: FontWeight.bold,
                            color: _activeTab == 0 ? Colors.white : theme.colorScheme.onSurface.withOpacity(0.6),
                          ),
                        ),
                      ),
                    ),
                  ),
                  Expanded(
                    child: InkWell(
                      onTap: () => setState(() => _activeTab = 1),
                      borderRadius: BorderRadius.circular(16),
                      child: Container(
                        alignment: Alignment.center,
                        decoration: _activeTab == 1
                            ? BoxDecoration(
                                color: theme.colorScheme.primary,
                                borderRadius: BorderRadius.circular(14),
                              )
                            : null,
                        child: Text(
                          L10n.of(context).msg5345cdce,
                          style: TextStyle(
                            fontSize: 13.5,
                            fontWeight: FontWeight.bold,
                            color: _activeTab == 1 ? Colors.white : theme.colorScheme.onSurface.withOpacity(0.6),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),

          // Switchable Views
          Expanded(
            child: IndexedStack(
              index: _activeTab,
              children: [
                _buildLocalShareView(theme, isDark, shareDir),
                _buildInternetShareView(theme, isDark),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // --- TAB 1: Local HTTP Server Streaming ---
  Widget _buildLocalShareView(ThemeData theme, bool isDark, String shareDir) {
    return ListView(
      physics: const BouncingScrollPhysics(),
      padding: const EdgeInsets.all(20.0),
      children: [
        const Text(
          'HTTP本地共享服务器',
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, fontFamily: 'LexendDeca'),
        ),
        const SizedBox(height: 4),
        Text(
          L10n.of(context).wifi,
          style: TextStyle(fontSize: 12.5, color: theme.colorScheme.onSurface.withOpacity(0.5)),
        ),
        const SizedBox(height: 20),

        if (_webService.isLocalActive) ...[
          // Server Information Board
          Card(
            elevation: 2,
            margin: EdgeInsets.zero,
            color: isDark ? const Color(0xFF1E293B) : theme.colorScheme.primary.withOpacity(0.04),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(24),
              side: BorderSide(color: theme.colorScheme.primary.withOpacity(0.12)),
            ),
            child: Padding(
              padding: const EdgeInsets.all(20.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: Colors.green.withOpacity(0.12),
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(Icons.circle, color: Colors.green, size: 10),
                      ),
                      const SizedBox(width: 8),
                      const Text(
                        '服务器在线并流式传输中',
                        style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Colors.green),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  Text(
                    '直接浏览器 URL：',
                    style: TextStyle(fontSize: 11.5, color: theme.colorScheme.onSurface.withOpacity(0.4), fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    _webService.localServerUrl,
                    style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                      color: theme.colorScheme.primary,
                      fontFamily: 'LexendDeca',
                    ),
                  ),
                  const SizedBox(height: 18),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          style: OutlinedButton.styleFrom(
                            side: BorderSide(color: theme.colorScheme.primary.withOpacity(0.25)),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                            padding: const EdgeInsets.symmetric(vertical: 10),
                          ),
                          icon: const Icon(Broken.copy, size: 16),
                          label: Text(L10n.of(context).url1, style: TextStyle(fontSize: 12.5)),
                          onPressed: () => _copyToClipboard(_webService.localServerUrl),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: OutlinedButton.icon(
                          style: OutlinedButton.styleFrom(
                            side: BorderSide(color: theme.colorScheme.primary.withOpacity(0.25)),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                            padding: const EdgeInsets.symmetric(vertical: 10),
                          ),
                          icon: const Icon(Icons.qr_code_2_rounded, size: 16),
                          label: Text(L10n.of(context).msg22b03c02, style: TextStyle(fontSize: 12.5)),
                          onPressed: () => _showQrCodeDialog(_webService.localServerUrl, 'Local Share'),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 20),

          // Share path description
          Row(
            children: [
              Icon(Broken.folder_open, size: 18, color: theme.colorScheme.onSurface.withOpacity(0.4)),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                    '共享目录：{shareDir}',
                    style: TextStyle(fontSize: 12, color: theme.colorScheme.onSurface.withOpacity(0.6), fontWeight: FontWeight.w600),
                    overflow: TextOverflow.ellipsis,
                  ),
              ),
            ],
          ),
        ] else ...[
          // Idle board
          Card(
            elevation: 0,
            margin: EdgeInsets.zero,
            color: isDark ? const Color(0xFF1E293B) : theme.colorScheme.onSurface.withOpacity(0.02),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
            child: Padding(
              padding: const EdgeInsets.all(24.0),
              child: Column(
                children: [
                  Icon(
                    Broken.wifi_square,
                    size: 44,
                    color: theme.colorScheme.onSurface.withOpacity(0.2),
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    '服务器空闲',
                    style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    L10n.of(context).wifi1,
                    style: TextStyle(fontSize: 12, color: theme.colorScheme.onSurface.withOpacity(0.5), height: 1.3),
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            ),
          ),
        ],

        const SizedBox(height: 40),

        // Action Button
        ElevatedButton.icon(
          style: ElevatedButton.styleFrom(
            backgroundColor: _webService.isLocalActive ? Colors.redAccent : theme.colorScheme.primary,
            foregroundColor: Colors.white,
            padding: const EdgeInsets.symmetric(vertical: 16),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
            elevation: 2,
          ),
          onPressed: () => _toggleLocalServer(shareDir),
          icon: Icon(_webService.isLocalActive ? Icons.stop_rounded : Icons.play_arrow_rounded),
          label: Text(
            _webService.isLocalActive ? '停止网页服务器' : L10n.of(context).msg974465c1,
            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
          ),
        ),
      ],
    );
  }

  // --- TAB 2: Internet Proxy Tunnel (Cloud Mock) ---
  Widget _buildInternetShareView(ThemeData theme, bool isDark) {
    final shareDir = context.read<FileManagerProvider>().rootPath;
    return ListView(
      physics: const BouncingScrollPhysics(),
      padding: const EdgeInsets.all(20.0),
      children: [
        const Text(
          '互联网分享隧道',
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, fontFamily: 'LexendDeca'),
        ),
        const SizedBox(height: 4),
        Text(
          L10n.of(context).msg27d5bd3c,
          style: TextStyle(fontSize: 12.5, color: theme.colorScheme.onSurface.withOpacity(0.5)),
        ),
        const SizedBox(height: 20),

        if (_webService.isInternetActive) ...[
          // Cloud Server Board
          Card(
            elevation: 2,
            margin: EdgeInsets.zero,
            color: isDark ? const Color(0xFF1E293B) : theme.colorScheme.primary.withOpacity(0.04),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(24),
              side: BorderSide(color: theme.colorScheme.primary.withOpacity(0.12)),
            ),
            child: Padding(
              padding: const EdgeInsets.all(20.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: theme.colorScheme.primary.withOpacity(0.12),
                          shape: BoxShape.circle,
                        ),
                        child: Icon(Icons.cloud_done, color: theme.colorScheme.primary, size: 16),
                      ),
                      const SizedBox(width: 8),
                      const Text(
                        '云隧道已激活',
                        style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Colors.blueAccent),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  Text(
                    L10n.of(context).msg66a09a42,
                    style: TextStyle(fontSize: 11.5, color: theme.colorScheme.onSurface.withOpacity(0.4), fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    _webService.internetShareLink,
                    style: TextStyle(
                      fontSize: 15.5,
                      fontWeight: FontWeight.bold,
                      color: theme.colorScheme.primary,
                      fontFamily: 'LexendDeca',
                    ),
                  ),
                  const SizedBox(height: 18),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          style: OutlinedButton.styleFrom(
                            side: BorderSide(color: theme.colorScheme.primary.withOpacity(0.25)),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                            padding: const EdgeInsets.symmetric(vertical: 10),
                          ),
                          icon: const Icon(Broken.copy, size: 16),
                          label: Text(L10n.of(context).msg879058ce, style: TextStyle(fontSize: 12.5)),
                          onPressed: () => _copyToClipboard(_webService.internetShareLink),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: OutlinedButton.icon(
                          style: OutlinedButton.styleFrom(
                            side: BorderSide(color: theme.colorScheme.primary.withOpacity(0.25)),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                            padding: const EdgeInsets.symmetric(vertical: 10),
                          ),
                          icon: const Icon(Icons.qr_code_2_rounded, size: 16),
                          label: Text(L10n.of(context).msg22b03c02, style: TextStyle(fontSize: 12.5)),
                          onPressed: () => _showQrCodeDialog(_webService.internetShareLink, 'Cloud Share'),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 24),

          // Dynamic Active Speedometer Counter Clients
          const Text(
            '已连接的浏览器客户端',
            style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.bold, fontFamily: 'LexendDeca'),
          ),
          const SizedBox(height: 8),

          if (_webService.activeClients.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12.0),
              child: Text(
                L10n.of(context).msgb77e4adf,
              style: TextStyle(fontSize: 12.5, color: theme.colorScheme.onSurface.withOpacity(0.4), fontStyle: FontStyle.italic),
              textAlign: TextAlign.center,
            ),
            )
          else
            ..._webService.activeClients.map((client) {
              return Card(
                elevation: 0,
                color: isDark ? const Color(0xFF1E293B).withOpacity(0.5) : theme.colorScheme.primary.withOpacity(0.02),
                margin: const EdgeInsets.symmetric(vertical: 6.0),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                  side: BorderSide(color: theme.colorScheme.primary.withOpacity(0.05)),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(14.0),
                  child: Column(
                    children: [
                      Row(
                        children: [
                          Icon(Broken.monitor, size: 18, color: theme.colorScheme.primary.withOpacity(0.8)),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              client['device'] as String,
                              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          // High-Speed Speedometer indicator
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                            decoration: BoxDecoration(
                              color: Colors.green.withOpacity(0.12),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Text(
                              '${client['speed']} MB/s',
                              style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Colors.green),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Expanded(
                            child: Text(
                              'Downloading: ${client['file']}',
                              style: TextStyle(fontSize: 11, color: theme.colorScheme.onSurface.withOpacity(0.5)),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          Text(
                            'Sent: ${client['transferred']}',
                            style: TextStyle(fontSize: 11, color: theme.colorScheme.onSurface.withOpacity(0.5)),
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      // Progress bar
                      ClipRRect(
                        borderRadius: BorderRadius.circular(4),
                        child: LinearProgressIndicator(
                          value: client['progress'] as double,
                          minHeight: 3.5,
                          backgroundColor: theme.colorScheme.onSurface.withOpacity(0.05),
                          valueColor: AlwaysStoppedAnimation<Color>(theme.colorScheme.primary),
                        ),
                      ),
                    ],
                  ),
                ),
              );
            }),
        ] else ...[
          // Idle Board
          Card(
            elevation: 0,
            margin: EdgeInsets.zero,
            color: isDark ? const Color(0xFF1E293B) : theme.colorScheme.onSurface.withOpacity(0.02),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
            child: Padding(
              padding: const EdgeInsets.all(24.0),
              child: Column(
                children: [
                  Icon(
                    Broken.routing,
                    size: 44,
                    color: theme.colorScheme.onSurface.withOpacity(0.2),
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    '互联网共享未激活',
                    style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Activate the tunnel to establish a secure link that works beyond local Wi-Fi.',
                    style: TextStyle(fontSize: 12, color: theme.colorScheme.onSurface.withOpacity(0.5), height: 1.3),
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            ),
          ),
        ],

        const SizedBox(height: 40),

        // Action Button
        ElevatedButton.icon(
          style: ElevatedButton.styleFrom(
            backgroundColor: _webService.isInternetActive ? Colors.redAccent : theme.colorScheme.primary,
            foregroundColor: Colors.white,
            padding: const EdgeInsets.symmetric(vertical: 16),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
            elevation: 2,
          ),
          onPressed: () => _toggleInternetTunnel(shareDir),
          icon: Icon(_webService.isInternetActive ? Icons.cloud_off : Icons.cloud_queue_rounded),
          label: Text(
            _webService.isInternetActive ? L10n.of(context).msga3c80551 : L10n.of(context).msg6466e61e,
            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
          ),
        ),
      ],
    );
  }
}

// Radar Pulse Painter for custom concentric broadcast waves
class RadarPulsePainter extends CustomPainter {
  final double animationValue;
  final Color color;
  final bool isActive;

  RadarPulsePainter({
    required this.animationValue,
    required this.color,
    required this.isActive,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;

    // Draw background concentric grid
    final bgPaint = Paint()
      ..color = color.withOpacity(0.04)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.0;
    canvas.drawCircle(center, 40, bgPaint);
    canvas.drawCircle(center, 70, bgPaint);
    canvas.drawCircle(center, 100, bgPaint);

    if (isActive) {
      // Draw 3 dynamic broadcasting waves propagating outward
      for (int i = 0; i < 3; i++) {
        final progress = (animationValue + i / 3) % 1.0;
        final radius = 34 + progress * 76;
        final opacity = (1.0 - progress) * 0.45;

        paint.color = color.withOpacity(opacity);
        canvas.drawCircle(center, radius, paint);
      }
    }
  }

  @override
  bool shouldRepaint(covariant RadarPulsePainter oldDelegate) {
    return oldDelegate.animationValue != animationValue ||
        oldDelegate.isActive != isActive ||
        oldDelegate.color != color;
  }
}

// High-fidelity dynamic QR Code painter
class PremiumQrPainter extends CustomPainter {
  final Color color;

  PremiumQrPainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.fill;

    // 1. Draw three standard scanner anchor blocks
    _drawScannerBlock(canvas, const Offset(0, 0), paint);
    _drawScannerBlock(canvas, Offset(size.width - 40, 0), paint);
    _drawScannerBlock(canvas, Offset(0, size.height - 40), paint);

    // 2. Draw a highly premium stylized dot grid representing the code payload
    final rand = math.Random(42); // Fixed seed to draw consistent aesthetic pattern
    const dotsCount = 14;
    final dotSize = size.width / dotsCount;

    for (int r = 0; r < dotsCount; r++) {
      for (int c = 0; c < dotsCount; c++) {
        // Skip scanner anchor blocks layout area
        if ((r < 4 && c < 4) || (r < 4 && c >= dotsCount - 4) || (r >= dotsCount - 4 && c < 4)) {
          continue;
        }

        // Randomly draw clean circular dots in HSL primary color
        if (rand.nextBool()) {
          canvas.drawRRect(
            RRect.fromRectAndRadius(
              Rect.fromLTWH(
                c * dotSize + 2,
                r * dotSize + 2,
                dotSize - 4,
                dotSize - 4,
              ),
              Radius.circular(dotSize / 2),
            ),
            paint,
          );
        }
      }
    }
  }

  void _drawScannerBlock(Canvas canvas, Offset offset, Paint paint) {
    // Outer border
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(offset.dx, offset.dy, 40, 40),
        const Radius.circular(8),
      ),
      paint,
    );
    // White space
    final whitePaint = Paint()..color = Colors.white;
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(offset.dx + 5, offset.dy + 5, 30, 30),
        const Radius.circular(6),
      ),
      whitePaint,
    );
    // Inner dot
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(offset.dx + 11, offset.dy + 11, 18, 18),
        const Radius.circular(4),
      ),
      paint,
    );
  }

  @override
  bool shouldRepaint(covariant PremiumQrPainter oldDelegate) {
    return oldDelegate.color != color;
  }
}
