import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:zenfile/l10n/generated/app_localizations.dart';

import '../../core/icon_fonts/broken_icons.dart';
import '../../services/quick_transfer_service.dart';
import '../../services/preferences_service.dart';
import '../../providers/file_manager_provider.dart';
import '../screens/internal_file_picker_screen.dart';

/// 快传页面：基于 WiFi Direct (P2P) 的点对点直传，参考 ES 快传 / QQ 面对面快传。
///
/// 对称连接模型：
/// - 发送页与接收页都展示"附近设备"，任意一方点击对方设备名即可发起 P2P 连接；
/// - P2P 连接建立后，Group Owner (GO) 始终托管 TCP ServerSocket，另一方作为 client 连接；
/// - 传输方向（谁发送文件）只由当前模式（发送/接收）决定，与哪一方发起了连接无关。
/// 这样无论是发送方还是接收方先点击，都能建立连接并自动开始传输。
class QuickTransferScreen extends StatefulWidget {
  const QuickTransferScreen({super.key});

  @override
  State<QuickTransferScreen> createState() => _QuickTransferScreenState();
}

class _QuickTransferScreenState extends State<QuickTransferScreen>
    with TickerProviderStateMixin {
  final _svc = QuickTransferService();

  int _mode = 0; // 0: 发送, 1: 接收
  bool _busy = false;
  String? _deviceName;
  String? _goIp;
  List<PeerDevice> _peers = [];
  PeerDevice? _connectingPeer;
  P2pConnectionState _conn = P2pConnectionState.disconnected;

  // 双方都点连接的握手守卫
  // - _iClickedConnect：本机 UI 上是否点过「连接」按钮
  // - _waitingPeerClick：我点了连接，TCP socket 已建，在等对端也点
  //   （等待页显示「等待对方点击连接…」，可取消）
  bool _iClickedConnect = false;
  bool _waitingPeerClick = false;

  // 握手成功后保留的 SocketReader：Socket 是 single-sub stream，
  // 传输层必须继续复用此 reader，否则 new 第二个会抛
  // 「Bad state: Stream has already been listened to.」
  SocketReader? _activeReader;

  // 发送方
  List<String> _selectedPaths = [];
  ServerSocket? _server;
  Socket? _activeSocket;

  // 接收方路径（可自定义，持久化）
  String _receiveDir = '/storage/emulated/0/ZenFile/Receive';

  // 进度
  bool _transferring = false;
  bool _transferStarted = false;
  bool _isSender = false;
  bool _socketReady = false;
  bool _waitingManifest = false;
  int _sent = 0;
  int _total = 0;
  String _currentFile = '';
  bool _done = false;
  String? _error;
  bool _permissionGranted = false;

  StreamSubscription<List<PeerDevice>>? _peersSub;
  StreamSubscription<P2pConnectionState>? _connSub;

  // 雷达动画
  AnimationController? _radarController;
  AnimationController? _sweepController;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    final supported = await _svc.isSupported();
    if (!supported) {
      if (mounted) setState(() => _error = L10n.of(context).quick_transfer_not_supported);
      return;
    }
    _deviceName = await _svc.getDeviceName();
    _receiveDir = PreferencesService.getQuickTransferReceivePath();
    await _checkPermission();
    _peersSub = _svc.peersStream.listen((p) {
      if (mounted) setState(() => _peers = p);
    });
    _connSub = _svc.connectionStream.listen((c) async {
      if (!mounted) return;
      setState(() => _conn = c);
      if (c.connected && c.groupOwnerAddress != null) {
        _goIp = c.groupOwnerAddress;
        // WiFi Direct 的一方 connect 会把另一方也拉入 P2P 组（系统机制），
        // 所以双方都会收到 connected 广播。为了实现「双方都必须在 UI 上
        // 点连接」的体验，只有本机也点过连接（_iClickedConnect）时，才建
        // TCP socket 并尝试双向握手；否则保持主界面不做任何处理，等用户
        // 自己点连接按钮时才进入后续流程。
        if (_iClickedConnect && !_transferStarted && !_transferring) {
          _transferStarted = true;
          await _onP2pConnected();
        }
      } else {
        _transferStarted = false;
        _socketReady = false;
        _waitingPeerClick = false;
      }
    });
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _peersSub?.cancel();
    _connSub?.cancel();
    _server?.close();
    _activeSocket?.destroy();
    _svc.disconnect();
    _radarController?.dispose();
    _sweepController?.dispose();
    super.dispose();
  }

  void _ensureRadarControllers() {
    if (_radarController == null) {
      _radarController = AnimationController(
        vsync: this,
        duration: const Duration(milliseconds: 2400),
      );
      _sweepController = AnimationController(
        vsync: this,
        duration: const Duration(milliseconds: 1800),
      );
    }
  }

  void _setScanningAnimation(bool scanning) {
    _ensureRadarControllers();
    if (scanning) {
      _radarController?.repeat();
      _sweepController?.repeat();
    } else {
      _radarController?.stop();
      _sweepController?.stop();
    }
  }

  Future<void> _checkPermission() async {
    final ok = await _svc.ensurePermission();
    if (mounted) setState(() => _permissionGranted = ok);
  }

  Future<void> _openSettings() async {
    await _svc.openSettings();
    // 从设置返回后再检查一次
    await _checkPermission();
  }

  Future<void> _startDiscovery() async {
    if (!_permissionGranted) {
      await _checkPermission();
      if (!_permissionGranted) return;
    }
    setState(() => _busy = true);
    _setScanningAnimation(true);
    final ok = await _svc.startDiscovery();
    if (!ok && mounted) {
      setState(() => _busy = false);
      _setScanningAnimation(false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(L10n.of(context).quick_transfer_permission_required)),
      );
      return;
    }
    // discoverPeers 成功后系统会持续扫描一段时间，保持雷达动画约 12 秒，
    // 期间发现的设备会实时显示在列表中。
    await Future.delayed(const Duration(seconds: 12));
    if (mounted) {
      setState(() => _busy = false);
      _setScanningAnimation(false);
    }
  }

  Future<void> _pickFiles() async {
    final picked = await InternalFilePickerScreen.show(
      context,
      rootPath: '/storage/emulated/0',
      pickDirectory: false,
    );
    if (picked != null && picked.isNotEmpty) {
      setState(() => _selectedPaths = picked);
    }
  }

  Future<void> _pickReceiveDir() async {
    final picked = await InternalFilePickerScreen.show(
      context,
      rootPath: '/storage/emulated/0',
      pickDirectory: true,
    );
    if (picked != null && picked.isNotEmpty) {
      final dir = picked.first;
      setState(() => _receiveDir = dir);
      await PreferencesService.saveQuickTransferReceivePath(dir);
    }
  }

  /// 用户点击「连接」按钮：标记本机已点连接并根据 P2P 是否已连分两路径。
  ///  - P2P 未连（本机是先点的一方）：执行原生 connect 拉入组，后续由
  ///    connectionStream 监听到 connected 后建 socket + 握手；
  ///  - P2P 已连（说明对方早已在原生层拉入我组，只是我 UI 上刚点）：
  ///    跳过原生 connect，直接建 socket + 双向握手进入下一步。
  Future<void> _connectPeer(PeerDevice peer) async {
    // 防止重复点击
    if (_busy || _transferStarted || _transferring) return;
    setState(() {
      _iClickedConnect = true;
      _busy = true;
      _connectingPeer = peer;
      _error = null;
      _transferStarted = false;
    });

    // 情况 A：P2P 组已经建好（对方先点了连接，我在原生层已被拉入组），
    // 这里直接走 socket 建立 + 双向握手流程，不用再调原生 connect。
    if (_conn.connected && _goIp != null && !_transferStarted) {
      _transferStarted = true;
      await _onP2pConnected();
      return;
    }

    // 情况 B：P2P 未连，我作为先点的一方发起原生 connect。
    _setScanningAnimation(true);
    try {
      // 先清理可能存在的旧组，确保全新建组，避免"已连接"导致 connect 失败
      try {
        await _svc.disconnect();
      } catch (_) {}
      await Future.delayed(const Duration(milliseconds: 300));
      await _svc.connect(peer.address);
      // 连接成功由 connectionStream 驱动，这里无需再等待
    } catch (e) {
      _setScanningAnimation(false);
      if (mounted) {
        setState(() {
          _error = e.toString();
          _busy = false;
          _connectingPeer = null;
          _iClickedConnect = false;
        });
      }
    }
  }

  /// 连接建立后（双方都会触发）：建 TCP socket + 执行双向 peer_ready 握手。
  /// 握手过程中显示「等待对方点击连接…」等待页（可取消）。
  /// 握手成功（双方都点过连接），再按模式分配：
  /// - 接收模式：进入接收等待（等 manifest 弹窗）
  /// - 发送模式：停留在主界面，等用户点「发送」
  Future<void> _onP2pConnected() async {
    final goIp = _goIp;
    if (goIp == null) {
      if (mounted) setState(() => _error = L10n.of(context).quick_transfer_create_group_failed);
      return;
    }
    final isGO = _conn.isGroupOwner;
    try {
      // 显示等待页：等待对方点击连接
      if (mounted) {
        setState(() {
          _waitingPeerClick = true;
          _busy = false;
        });
      }

      Socket socket;
      if (isGO) {
        _server = await ServerSocket.bind(InternetAddress.anyIPv4, QuickTransferService.transferPort);
        socket = await _server!.first;
      } else {
        socket = await _connectWithRetry(goIp);
      }
      _activeSocket = socket;

      // 双向 peer_ready 握手：先发自己 ready，阻塞等对方 ready（最长 60s）
      // 期间 shouldCancel=!mounted（用户退出即取消）。只有双方 ready
      // 才继续；抛异常则直接进错误面板。返回的 SocketReader 要保留并
      // 传入后续传输（socket 是 single-sub stream，不能再 new 第二个）。
      final handshake = await _svc.doPeerReadyHandshake(
        socket: socket,
        localMode: _mode,
        shouldCancel: () async => !mounted,
      );
      if (!mounted) {
        handshake.reader.close();
        return;
      }
      _activeReader = handshake.reader;

      setState(() {
        _socketReady = true;
        _waitingPeerClick = false;
      });

      if (_mode == 1) {
        // 接收方：立即进入接收等待状态（等 manifest）
        setState(() {
          _isSender = false;
          _transferring = true;
          _waitingManifest = true;
          _busy = false;
        });
        await _doReceive(socket);
      }
      // 发送方：保持主界面，等用户选好文件后点「发送」（_startSend）
    } on SocketException catch (e) {
      if (mounted) {
        setState(() {
          _error = '${L10n.of(context).quick_transfer_create_group_failed} ($e)';
          _waitingPeerClick = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString();
          _waitingPeerClick = false;
        });
      }
    }
  }

  /// 发送方手动触发：在已建立的 socket 上推送清单 + 文件流
  Future<void> _startSend() async {
    final socket = _activeSocket;
    if (socket == null || _selectedPaths.isEmpty || _transferring) return;
    if (mounted) {
      setState(() {
        _isSender = true;
        _transferring = true;
        _busy = false;
        _error = null;
      });
    }
    try {
      final files = await _svc.collectFiles(_selectedPaths);
      if (mounted) {
        setState(() {
          _total = files.fold(0, (s, f) => s + f.size);
          _sent = 0;
        });
      }
      final reader = _activeReader;
      try {
        await _svc.sendFiles(
          socket: socket,
          files: files,
          onProgress: (s, t, cur) {
            if (mounted) setState(() { _sent = s; _total = t; _currentFile = cur; });
          },
          shouldCancel: () async => !mounted,
          existingReader: reader,
        );
        if (mounted) setState(() => _done = true);
      } finally {
        // sendFiles 内部会 close reader；无论正常/异常路径都清引用
        _activeReader = null;
      }
    } on SocketException catch (e) {
      if (mounted) setState(() => _error = '${L10n.of(context).quick_transfer_create_group_failed} ($e)');
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
      _server?.close();
      _server = null;
      _activeSocket?.destroy();
      _activeSocket = null;
    }
  }

  /// 接收方：在已建立的 socket 上等待 manifest 并落盘
  Future<void> _doReceive(Socket socket) async {
    try {
      final reader = _activeReader;
      bool received;
      try {
        received = await _svc.receiveFiles(
          socket: socket,
          saveDir: _receiveDir,
          onManifest: (manifest) async {
            // 收到清单：退出等待状态，弹窗询问是否接受
            if (mounted) setState(() => _waitingManifest = false);
            return _askAccept(manifest);
          },
          onProgress: (r, t, cur) {
            if (mounted) setState(() { _sent = r; _total = t; _currentFile = cur; });
          },
          onFileSaved: (_) {},
          existingReader: reader,
        );
      } finally {
        // receiveFiles 内部会 close reader；无论正常/异常/拒绝路径都清引用
        _activeReader = null;
      }
      // 被拒绝或连接中断：不显示"完成"，直接复位等待下次传输
      if (!received) {
        if (mounted) _reset();
        return;
      }
      if (mounted) setState(() => _done = true);

      // 接收完成后提示用户是否打开文件所在位置
      if (mounted) {
        final open = await _askOpenLocation();
        if (open == true && mounted) {
          // 使用本应用文件管理器打开，跳转到浏览页并定位到接收目录
          // （复用 HomeScreen 的 pendingBrowseNavigation 机制，而非调系统文件管理器）
          final fileManager = context.read<FileManagerProvider>();
          fileManager.setPendingBrowseNavigation(_receiveDir, []);
          if (Navigator.of(context).canPop()) {
            Navigator.of(context).pop();
          }
        }
      }
    } on SocketException catch (e) {
      if (mounted) setState(() => _error = '${L10n.of(context).quick_transfer_create_group_failed} ($e)');
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
      _server?.close();
      _server = null;
      _activeSocket?.destroy();
      _activeSocket = null;
    }
  }

  /// 非 GO 端作为 client 连接 GO，带重试以应对 GO 尚未完成 bind 的时序窗口。
  Future<Socket> _connectWithRetry(String goIp) async {
    Socket? socket;
    for (int i = 0; i < 25; i++) {
      try {
        socket = await Socket.connect(
          goIp,
          QuickTransferService.transferPort,
          timeout: const Duration(seconds: 2),
        );
        break;
      } catch (_) {
        await Future.delayed(const Duration(milliseconds: 200));
        if (!mounted) rethrow;
      }
    }
    if (socket == null) throw Exception(L10n.of(context).quick_transfer_create_group_failed);
    return socket;
  }

  /// 清理 TCP 连接资源（不动 P2P 组，由调用方决定是否 disconnect）
  void _teardownConnection() {
    _server?.close();
    _server = null;
    try {
      _activeReader?.close();
    } catch (_) {}
    _activeReader = null;
    _activeSocket?.destroy();
    _activeSocket = null;
    _socketReady = false;
    _transferStarted = false;
  }

  void _reset() {
    try {
      _svc.disconnect();
    } catch (_) {}
    _teardownConnection();
    setState(() {
      _conn = P2pConnectionState.disconnected;
      _transferring = false;
      _done = false;
      _error = null;
      _isSender = false;
      _waitingManifest = false;
      _waitingPeerClick = false;
      _iClickedConnect = false;
      _sent = 0;
      _total = 0;
      _currentFile = '';
      _selectedPaths = [];
      _connectingPeer = null;
      _goIp = null;
    });
  }

  Future<bool> _askAccept(Manifest manifest) async {
    final sizeStr = _formatSize(manifest.totalBytes);
    final res = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: Text(L10n.of(ctx).quick_transfer_incoming(_connectingPeer?.name ?? '')),
        content: Text(L10n.of(ctx).quick_transfer_incoming_files(
            manifest.totalCount.toString(), sizeStr)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(L10n.of(ctx).quick_transfer_reject),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(L10n.of(ctx).quick_transfer_accept),
          ),
        ],
      ),
    );
    return res == true;
  }

  Future<bool> _askOpenLocation() async {
    final res = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: Text(L10n.of(ctx).quick_transfer_receive_complete),
        content: Text(L10n.of(ctx).quick_transfer_files_saved_to(_receiveDir)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(L10n.of(ctx).quick_transfer_back),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(L10n.of(ctx).quick_transfer_open_location),
          ),
        ],
      ),
    );
    return res == true;
  }

  String _formatSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
    return '${(bytes / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(L10n.of(context).quick_transfer),
        actions: [
          // 传输进行中不可断开；等待对方点击 / 接收等待（未收到清单）阶段允许断开
          if (_conn.connected &&
              (!_transferring || _waitingManifest || _waitingPeerClick))
            TextButton.icon(
              onPressed: () async {
                await _svc.disconnect();
                if (mounted) _reset();
              },
              icon: const Icon(Broken.close_circle),
              label: Text(L10n.of(context).quick_transfer_disconnect),
            ),
        ],
      ),
      body: !_permissionGranted
          ? _buildPermissionPanel(context)
          : _error != null
              ? _buildErrorPanel(context)
              : _waitingPeerClick
                  ? _buildWaitingPeerClick(context)
                  : _transferring
                      ? _buildProgress(context)
                      : _buildMain(context),
    );
  }

  Widget _buildPermissionPanel(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Broken.shield_tick, size: 64, color: Theme.of(context).colorScheme.primary),
            const SizedBox(height: 16),
            Text(L10n.of(context).quick_transfer_permission_required, textAlign: TextAlign.center, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(
              L10n.of(context).quick_transfer_permission_why,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: _busy ? null : _checkPermission,
              icon: const Icon(Broken.tick_circle),
              label: Text(L10n.of(context).quick_transfer_permission_grant),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: _busy ? null : _openSettings,
              icon: const Icon(Broken.setting),
              label: Text(L10n.of(context).quick_transfer_open_settings),
            ),
          ],
        ),
      ),
    );
  }

  /// 等待对方也点击「连接」的 UI 页面（双方握手前的中间态）
  Widget _buildWaitingPeerClick(BuildContext context) {
    final theme = Theme.of(context);
    final peerName = _connectingPeer?.name ?? '';
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(
              width: 48,
              height: 48,
              child: CircularProgressIndicator(strokeWidth: 3),
            ),
            const SizedBox(height: 24),
            Text(
              peerName.isEmpty
                  ? L10n.of(context).quick_transfer_waiting_peer
                  : '等待 $peerName 点击连接…',
              textAlign: TextAlign.center,
              style: theme.textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Text(
              '请让对端设备也在快传中点击本机的「连接」按钮',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 24),
            OutlinedButton.icon(
              onPressed: _reset,
              icon: const Icon(Broken.close_circle),
              label: Text(L10n.of(context).quick_transfer_cancel),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildErrorPanel(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Broken.info_circle, size: 64, color: Theme.of(context).colorScheme.error),
            const SizedBox(height: 16),
            Text(_error ?? '', textAlign: TextAlign.center, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: () {
                if (_error == L10n.of(context).quick_transfer_permission_required ||
                    _error == L10n.of(context).quick_transfer_create_group_failed) {
                  _checkPermission();
                } else {
                  setState(() => _error = null);
                }
              },
              icon: const Icon(Broken.refresh),
              label: Text(L10n.of(context).quick_transfer_retry),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMain(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        // 设备名称置顶
        ListTile(
          leading: const Icon(Broken.profile_2user),
          title: Text(L10n.of(context).quick_transfer_device_name),
          subtitle: Text(_deviceName ?? '-'),
        ),
        const SizedBox(height: 16),
        // 发送/接收切换（已建立连接后禁用：切换会导致双方协议方向错乱）
        SegmentedButton<int>(
          segments: [
            ButtonSegment(value: 0, label: Text(L10n.of(context).quick_transfer_send_mode), icon: const Icon(Broken.export)),
            ButtonSegment(value: 1, label: Text(L10n.of(context).quick_transfer_receive_mode), icon: const Icon(Broken.import)),
          ],
          selected: {_mode},
          onSelectionChanged: (_conn.connected && !_transferring)
              ? null
              : (s) => setState(() => _mode = s.first),
        ),
        const SizedBox(height: 16),
        if (_mode == 0) _buildSendPanel(context) else _buildReceivePanel(context),
      ],
    );
  }

  Widget _buildSendPanel(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final hasSelection = _selectedPaths.isNotEmpty;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 与接收页一致的椭圆框：标题/已选项占满左侧，文件夹图标靠右
        InkWell(
          onTap: _busy ? null : _pickFiles,
          borderRadius: BorderRadius.circular(999),
          child: Container(
            height: 52,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(999),
              border: Border.all(
                color: colorScheme.outlineVariant,
                width: 1,
              ),
            ),
            child: Row(
              children: [
                Expanded(
                  child: hasSelection
                      ? Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              L10n.of(context).quick_transfer_selected_count(_selectedPaths.length),
                              style: theme.textTheme.labelSmall?.copyWith(
                                    color: colorScheme.onSurfaceVariant,
                                  ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            const SizedBox(height: 2),
                            Text(
                              _selectedPaths.join(' · '),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.bodyMedium?.copyWith(
                                    fontWeight: FontWeight.w500,
                                  ),
                            ),
                          ],
                        )
                      : Text(
                          L10n.of(context).quick_transfer_select_files,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodyMedium?.copyWith(
                                fontWeight: FontWeight.w500,
                              ),
                        ),
                ),
                Icon(Broken.folder, size: 20, color: colorScheme.primary),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        // 已连接：显示连接状态卡 + 「发送」按钮（由发送方手动开始传输，
        // 未选文件时禁用；先连接后选文件完全支持），不再显示设备发现区域
        if (_conn.connected && _socketReady && !_transferring) ...[
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              color: colorScheme.primaryContainer.withAlpha(90),
            ),
            child: Row(
              children: [
                Icon(Broken.tick_circle, size: 20, color: colorScheme.primary),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _connectingPeer?.name ??
                        L10n.of(context).quick_transfer_connected_btn,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: _selectedPaths.isEmpty ? null : _startSend,
              icon: const Icon(Broken.export),
              label: Text(L10n.of(context).quick_transfer_send_button),
            ),
          ),
        ] else ...[
          _buildDiscoveryArea(context),
        ],
      ],
    );
  }

  Widget _buildReceivePanel(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 接收路径卡片：椭圆形边框，标题/路径占满左侧，文件夹按钮靠最右侧
        InkWell(
          onTap: _busy ? null : _pickReceiveDir,
          borderRadius: BorderRadius.circular(999),
          child: Container(
            height: 52,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(999),
              border: Border.all(
                color: colorScheme.outlineVariant,
                width: 1,
              ),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        L10n.of(context).quick_transfer_receive_path,
                        style: theme.textTheme.labelSmall?.copyWith(
                              color: colorScheme.onSurfaceVariant,
                            ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        _receiveDir,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyMedium?.copyWith(
                              fontWeight: FontWeight.w500,
                            ),
                      ),
                    ],
                  ),
                ),
                Icon(Broken.folder, size: 20, color: colorScheme.primary),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        _buildDiscoveryArea(context),
      ],
    );
  }

  Widget _buildDiscoveryArea(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildDiscoveryRow(context),
        const SizedBox(height: 12),
        if (_busy) ...[
          _RadarScanner(
            radarController: _radarController,
            sweepController: _sweepController,
          ),
          const SizedBox(height: 8),
          Center(
            child: Text(
              L10n.of(context).quick_transfer_scanning,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
            ),
          ),
          const SizedBox(height: 12),
        ],
        if (!_busy)
          Text(
            L10n.of(context).quick_transfer_tap_to_connect,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        if (!_busy) const SizedBox(height: 12),
        _buildPeerList(context),
      ],
    );
  }

  Widget _buildDiscoveryRow(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      child: ElevatedButton.icon(
        onPressed: _busy ? null : _startDiscovery,
        icon: _busy
            ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
            : const Icon(Broken.discover),
        label: Text(L10n.of(context).quick_transfer_nearby_devices),
      ),
    );
  }

  Widget _buildPeerList(BuildContext context) {
    if (_peers.isEmpty) {
      return const SizedBox.shrink();
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 4, bottom: 4),
          child: Text(
            L10n.of(context).quick_transfer_available_peers,
            style: Theme.of(context).textTheme.labelMedium?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
          ),
        ),
        ..._peers.map((p) {
          return ListTile(
            leading: const Icon(Broken.profile_circle),
            title: Text(p.name),
            subtitle: Text(p.address),
            trailing: _buildConnectButton(context, p),
            onTap: (_busy || _conn.connected) ? null : () => _connectPeer(p),
          );
        }).toList(),
      ],
    );
  }

  /// 设备行右侧的连接按钮：未连接显示"连接"，连接中显示进度圈，
  /// 连接成功后显示"已连接"。发送/接收两种模式均显示此按钮。
  Widget _buildConnectButton(BuildContext context, PeerDevice p) {
    final isThisConnecting = _connectingPeer?.address == p.address && _busy;
    final isConnected = _conn.connected && _connectingPeer?.address == p.address;
    if (isThisConnecting) {
      return const SizedBox(
        width: 16,
        height: 16,
        child: CircularProgressIndicator(strokeWidth: 2),
      );
    }
    if (isConnected) {
      return FilledButton.tonal(
        onPressed: null,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Broken.tick_circle, size: 16),
            const SizedBox(width: 4),
            Text(L10n.of(context).quick_transfer_connected_btn),
          ],
        ),
      );
    }
    return FilledButton.tonal(
      onPressed: _busy ? null : () => _connectPeer(p),
      child: Text(L10n.of(context).quick_transfer_connect_btn),
    );
  }

  Widget _buildProgress(BuildContext context) {
    final ratio = _total > 0 ? _sent / _total : 0.0;
    // 接收方已连接但尚未收到发送方的文件清单：显示「已连接」+ 等待发送
    // 提示（不定进度条）。文案必须与「等待对方点击连接」的等待页明确
    // 区分开，否则用户会误以为握手还没完成。
    final waiting = !_isSender && _waitingManifest && !_done;
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          if (waiting) ...[
            // 绿色对勾：明确告知连接已建立，等的是文件而非连接
            const Icon(Broken.tick_circle, color: Colors.green, size: 48),
          ] else ...[
            Icon(_isSender ? Broken.export : Broken.import, size: 48),
          ],
          const SizedBox(height: 16),
          Text(
            waiting
                ? L10n.of(context).quick_transfer_connected_waiting_files
                : (_isSender
                    ? L10n.of(context).quick_transfer_sending
                    : L10n.of(context).quick_transfer_receiving),
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 16),
          if (waiting)
            const LinearProgressIndicator(minHeight: 6)
          else ...[
            LinearProgressIndicator(value: ratio),
            const SizedBox(height: 8),
            Text('${(ratio * 100).toStringAsFixed(0)}%  ·  ${_formatSize(_sent)} / ${_formatSize(_total)}'),
            const SizedBox(height: 8),
            Text(_currentFile, maxLines: 1, overflow: TextOverflow.ellipsis, style: Theme.of(context).textTheme.bodySmall),
          ],
          if (_done) ...[
            const SizedBox(height: 16),
            const Icon(Broken.tick_circle, color: Colors.green, size: 40),
            Text(L10n.of(context).quick_transfer_complete),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: _reset,
              icon: const Icon(Broken.arrow_left_2),
              label: Text(L10n.of(context).quick_transfer_back),
            ),
          ],
        ],
      ),
    );
  }
}

/// 雷达扫描动画：同心圆扩散 + 旋转扫描扇面 + 中心设备图标。
class _RadarScanner extends StatelessWidget {
  final AnimationController? radarController;
  final AnimationController? sweepController;

  const _RadarScanner({this.radarController, this.sweepController});

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.primary;
    return SizedBox(
      height: 180,
      width: double.infinity,
      child: Stack(
        alignment: Alignment.center,
        children: [
          // 同心圆扩散
          if (radarController != null)
            ...List.generate(3, (i) {
              return AnimatedBuilder(
                animation: radarController!,
                builder: (context, child) {
                  final t = ((radarController!.value + i / 3) % 1.0);
                  final size = 50.0 + t * 130.0;
                  return Container(
                    width: size,
                    height: size,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: color.withAlpha((255 * (1 - t) * 0.55).round()),
                        width: 1.2,
                      ),
                    ),
                  );
                },
              );
            }),
          // 扫描扇面
          if (sweepController != null)
            AnimatedBuilder(
              animation: sweepController!,
              builder: (context, child) {
                return Transform.rotate(
                  angle: sweepController!.value * 2 * pi,
                  child: CustomPaint(
                    size: const Size(160, 160),
                    painter: _RadarSweepPainter(color: color),
                  ),
                );
              },
            ),
          // 中心设备图标
          Container(
            width: 56,
            height: 56,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: Theme.of(context).colorScheme.primaryContainer,
            ),
            child: Icon(
              Broken.mobile,
              size: 28,
              color: color,
            ),
          ),
        ],
      ),
    );
  }
}

class _RadarSweepPainter extends CustomPainter {
  final Color color;

  _RadarSweepPainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.width / 2;
    final rect = Rect.fromCircle(center: center, radius: radius);
    final paint = Paint()
      ..shader = SweepGradient(
        colors: [
          color.withAlpha(0),
          color.withAlpha(0),
          color.withAlpha((255 * 0.45).round()),
          color.withAlpha(0),
        ],
        stops: const [0.0, 0.55, 0.85, 1.0],
      ).createShader(rect);
    canvas.drawCircle(center, radius, paint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
