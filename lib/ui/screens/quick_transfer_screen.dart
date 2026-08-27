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
/// - 任意一方点击对方设备名即可发起 P2P 连接；P2P 连接建立后，Group Owner (GO)
///   始终托管 TCP ServerSocket，另一方作为 client 连接；
/// - 连接成功后**不再区分发送方 / 接收方**：双方都可在同一连接上随时主动发送
///   文件，也随时接收对方发来的文件（由 [TransferSession] 统一调度，单一
///   SocketReader 被持久接收循环独占，发送响应经内部 [_pending] 转交）；
/// - 因此页面不再有「发送/接收」切换，统一展示：设备名 → 发送区 → 接收区 → 附近设备。
class QuickTransferScreen extends StatefulWidget {
  const QuickTransferScreen({super.key});

  @override
  State<QuickTransferScreen> createState() => _QuickTransferScreenState();
}

class _QuickTransferScreenState extends State<QuickTransferScreen>
    with TickerProviderStateMixin {
  final _svc = QuickTransferService();

  bool _busy = false; // 连接进行中（防重入）
  bool _scanning = false; // 仅表示「正在扫描附近设备」，与 _busy 解耦，扫描期间仍可点连接
  String? _deviceName;
  String? _goIp;
  List<PeerDevice> _peers = [];
  List<PeerDevice> _knownPeers = [];
  PeerDevice? _connectingPeer;
  P2pConnectionState _conn = P2pConnectionState.disconnected;

  // 双方都点连接的握手守卫
  // - _iClickedConnect：本机 UI 上是否点过「连接」按钮
  // - _waitingPeerClick：我点了连接，TCP socket 已建，在等对端也点
  //   （等待页显示「等待对方点击连接…」，可取消）
  bool _iClickedConnect = false;
  bool _waitingPeerClick = false;

  // 握手成功后建立的对称传输会话：拥有 Socket + SocketReader，
  // 由持久接收循环统一调度收发（详见 quick_transfer_service.dart）。
  TransferSession? _session;

  // 发送方
  List<String> _selectedPaths = [];
  ServerSocket? _server;

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
    _knownPeers = PreferencesService.getQuickTransferKnownPeers();
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
        _teardownConnection();
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
    _session?.dispose();
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
    setState(() => _scanning = true);
    _setScanningAnimation(true);
    final ok = await _svc.startDiscovery();
    if (!ok && mounted) {
      setState(() => _scanning = false);
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
      setState(() => _scanning = false);
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
    // 如果点击的是已记住设备且当前 peers 列表里没有它，说明还没扫描到对方，
    // 需要先触发一次 discovery，等原生发现到该设备后再 connect。
    if (!_peers.any((p) => p.address == peer.address)) {
      final found = await _ensurePeerDiscovered(
        peer.address,
        timeout: const Duration(seconds: 8),
      );
      if (!found) {
        if (mounted) {
          setState(() {
            _error = L10n.of(context).quick_transfer_peer_unreachable;
            _busy = false;
            _connectingPeer = null;
            _iClickedConnect = false;
          });
        }
        return;
      }
    }

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
        final message = _formatConnectError(e, context);
        setState(() {
          _error = message;
          _busy = false;
          _connectingPeer = null;
          _iClickedConnect = false;
        });
      }
    }
  }

  /// 确保指定 address 的设备已被原生 WiFi Direct discovery 发现。
  /// 若当前 peers 列表中已有该设备则立即返回 true；否则启动一次 discovery
  /// 并在 [timeout] 内轮询等待，发现后返回 true，超时返回 false。
  Future<bool> _ensurePeerDiscovered(String address, {required Duration timeout}) async {
    if (_peers.any((p) => p.address == address)) return true;

    if (!_permissionGranted) {
      await _checkPermission();
      if (!_permissionGranted) return false;
    }

    setState(() => _scanning = true);
    _setScanningAnimation(true);
    final ok = await _svc.startDiscovery();
    if (!ok) {
      if (mounted) {
        setState(() => _scanning = false);
        _setScanningAnimation(false);
      }
      return false;
    }

    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      if (_peers.any((p) => p.address == address)) {
        if (mounted) {
          setState(() => _scanning = false);
          _setScanningAnimation(false);
        }
        return true;
      }
      await Future.delayed(const Duration(milliseconds: 400));
    }

    if (mounted) {
      setState(() => _scanning = false);
      _setScanningAnimation(false);
    }
    return false;
  }

  /// 把原生 P2P 连接异常转换为用户友好的本地化提示，避免直接展示
  /// PlatformException(CONNECT_FAILED, reason=0, null, null) 等底层信息。
  String _formatConnectError(Object e, BuildContext context) {
    if (e is PlatformException) {
      final code = e.code;
      if (code == 'CONNECT_FAILED' || code == 'P2P_CONNECT_FAILED' || code == 'connect_failed') {
        return L10n.of(context).quick_transfer_peer_unreachable;
      }
    }
    return e.toString();
  }

  /// 把对端写入「已记住设备」持久化列表（按 address 去重、最近置顶）。
  Future<void> _rememberPeer(PeerDevice peer) async {
    await PreferencesService.addQuickTransferKnownPeer(peer);
    if (mounted) {
      setState(() => _knownPeers = PreferencesService.getQuickTransferKnownPeers());
    }
  }

  /// 从「已记住设备」列表中移除一个对端（按 address 匹配）。
  Future<void> _removeKnownPeer(PeerDevice peer) async {
    await PreferencesService.removeQuickTransferKnownPeer(peer.address);
    if (mounted) {
      setState(() => _knownPeers = PreferencesService.getQuickTransferKnownPeers());
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

      // 双向 peer_ready 握手：仅确认双方都在线，不再交换收发角色
      final reader = await _svc.doPeerReadyHandshake(
        socket: socket,
        shouldCancel: () async => !mounted,
      );
      if (!mounted) {
        reader.close();
        socket.destroy();
        return;
      }

      // 握手成功：把对端写入「已记住设备」，下次可直接点连接按钮重连。
      // _connectingPeer 在此处仍指向本次连接的对端（错误/teardown 才清空）。
      final peer = _connectingPeer;
      if (peer != null) {
        await _rememberPeer(peer);
      }

      // 建立对称传输会话：双方都能随时发送、随时接收
      _session = TransferSession(
        socket: socket,
        reader: reader,
        service: _svc,
        saveDir: _receiveDir,
        shouldCancel: () async => !mounted,
        onIncomingManifest: (manifest) async {
          if (mounted) {
            setState(() {
              _isSender = false;
              _transferring = true;
              _waitingManifest = false;
              _error = null;
            });
          }
          return _askAccept(manifest);
        },
        onReceiveProgress: (r, t, cur) {
          if (mounted) {
            setState(() {
              _isSender = false;
              _sent = r;
              _total = t;
              _currentFile = cur;
            });
          }
        },
        onFileSaved: (_) {},
        onReceiveFinished: (success) async {
          if (!mounted) return;
          setState(() {
            _transferring = false;
            _done = success;
            _sent = 0;
            _total = 0;
            _currentFile = '';
          });
          if (success) {
            final open = await _askOpenLocation();
            if (open == true && mounted) {
              // 复用 HomeScreen 的 pendingBrowseNavigation 机制，跳转浏览页打开接收目录。
              // 用 popUntil(isFirst) 一次性弹回首页（HomeScreen），确保无论快传从抽屉
              // 还是从「分类页→工具箱」进入，弹回后首页即为可见顶层并消费 pending 导航；
              // 若仅 pop() 一层，从工具箱进入时会残留 ToolboxScreen 遮挡已加载的目录。
              final fileManager = context.read<FileManagerProvider>();
              fileManager.setPendingBrowseNavigation(_receiveDir, []);
              Navigator.of(context).popUntil((route) => route.isFirst);
            }
          }
        },
        onError: (e) {
          if (mounted) setState(() => _error = e.toString());
        },
      );

      setState(() {
        _socketReady = true;
        _waitingPeerClick = false;
      });

      // 启动持久接收循环（不阻塞 UI）；连接断开由循环自然结束，会话保持
      // 直到本端断开/重置，从而支持一次连接内多次互发。
      unawaited(_session!.run());
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

  /// 发送方手动触发：通过对称会话在同一连接上推送清单 + 文件流。
  /// 连接保持不断开，支持一次连接内多次互发。
  Future<void> _startSend() async {
    final session = _session;
    if (session == null || _selectedPaths.isEmpty || _transferring) return;
    if (mounted) {
      setState(() {
        _isSender = true;
        _transferring = true;
        _busy = false;
        _error = null;
        _done = false;
      });
    }
    try {
      final files = await _svc.collectFiles(_selectedPaths);
      if (files.isEmpty) {
        if (mounted) setState(() => _transferring = false);
        return;
      }
      if (mounted) {
        setState(() {
          _total = files.fold(0, (s, f) => s + f.size);
          _sent = 0;
        });
      }
      await session.sendFiles(
        files: files,
        onProgress: (s, t, cur) {
          if (mounted) {
            setState(() {
              _sent = s;
              _total = t;
              _currentFile = cur;
              _isSender = true;
            });
          }
        },
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(L10n.of(context).quick_transfer_complete)),
        );
        setState(() {
          _transferring = false;
          _done = true;
        });
      }
    } on SocketException catch (e) {
      if (mounted) {
        setState(() => _error = '${L10n.of(context).quick_transfer_create_group_failed} ($e)');
      }
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _transferring = false);
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

  /// 清理 TCP 连接与会话资源（不动 P2P 组，由调用方决定是否 disconnect）
  void _teardownConnection() {
    _session?.dispose();
    _session = null;
    try {
      _server?.close();
    } catch (_) {}
    _server = null;
    _socketReady = false;
    _transferStarted = false;
    _waitingPeerClick = false;
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
        insetPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 24),
        title: Text(L10n.of(ctx).quick_transfer_incoming(_connectingPeer?.name ?? '')),
        content: Text(L10n.of(ctx).quick_transfer_incoming_files(
            manifest.totalCount.toString(), sizeStr)),
        actions: [
          // 拒绝靠左、接收靠右，两端分布拉开间距，降低误触概率。
          SizedBox(
            width: double.infinity,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
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
        insetPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 24),
        title: Text(L10n.of(ctx).quick_transfer_receive_complete),
        content: Text(L10n.of(ctx).quick_transfer_files_saved_to(_receiveDir)),
        actions: [
          Row(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(false),
                child: Text(L10n.of(ctx).quick_transfer_back),
              ),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: () => Navigator.of(ctx).pop(true),
                child: Text(L10n.of(ctx).quick_transfer_open_location),
              ),
            ],
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
            Container(
              width: 88,
              height: 88,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: theme.colorScheme.primaryContainer.withAlpha(100),
              ),
              child: const Center(
                child: SizedBox(
                  width: 40,
                  height: 40,
                  child: CircularProgressIndicator(strokeWidth: 3),
                ),
              ),
            ),
            const SizedBox(height: 24),
            Text(
              peerName.isEmpty
                  ? L10n.of(context).quick_transfer_waiting_peer
                  : L10n.of(context).quick_transfer_waiting_for_x(peerName),
              textAlign: TextAlign.center,
              style: theme.textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Text(
              L10n.of(context).quick_transfer_ask_peer_connect,
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
              label: Text(_error == L10n.of(context).quick_transfer_peer_unreachable
                  ? L10n.of(context).ui_close
                  : L10n.of(context).quick_transfer_retry),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMain(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 6, 16, 20),
      children: [
        // 1. 本机设备卡片
        _sectionCard(
          colorScheme,
          Row(
            children: [
              _iconBadge(context, Broken.profile_2user),
              const SizedBox(width: 12),
              Expanded(
                child: _deviceNameColumn(context),
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        // 2. 发送区卡片
        _sectionCard(
          colorScheme,
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _sectionTitle(context, Broken.export,
                  L10n.of(context).quick_transfer_send_mode),
              const SizedBox(height: 8),
              _buildSendBox(context),
            ],
          ),
        ),
        const SizedBox(height: 8),
        // 3. 接收区卡片
        _sectionCard(
          colorScheme,
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _sectionTitle(context, Broken.import,
                  L10n.of(context).quick_transfer_receive_mode),
              const SizedBox(height: 8),
              _buildReceiveBox(context),
            ],
          ),
        ),
        const SizedBox(height: 8),
        // 4. 附近设备发现区卡片
        _sectionCard(
          colorScheme,
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _sectionTitle(context, Broken.discover,
                  L10n.of(context).quick_transfer_available_peers),
              const SizedBox(height: 8),
              _buildDiscoveryArea(context),
            ],
          ),
        ),
      ],
    );
  }

  /// 分区卡片容器：统一圆角与浅色底，是快传主页面的基本视觉单元。
  Widget _sectionCard(ColorScheme colorScheme, Widget child) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(14, 11, 14, 11),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(16),
      ),
      child: child,
    );
  }

  /// 分区标题：小图标 + 加权标题。
  Widget _sectionTitle(BuildContext context, IconData icon, String text) {
    final theme = Theme.of(context);
    return Row(
      children: [
        Icon(icon, size: 18, color: theme.colorScheme.primary),
        const SizedBox(width: 8),
        Text(
          text,
          style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold),
        ),
      ],
    );
  }

  /// 圆形图标徽章：浅主色底 + 主色图标，用于设备/分区行首。
  Widget _iconBadge(BuildContext context, IconData icon) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      width: 40,
      height: 40,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: colorScheme.primaryContainer.withAlpha(140),
      ),
      child: Icon(icon, size: 20, color: colorScheme.primary),
    );
  }

  /// 本机设备名（卡片内两行：标签 + 设备名）。
  Widget _deviceNameColumn(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          L10n.of(context).quick_transfer_device_name,
          style: theme.textTheme.labelMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          _deviceName ?? '-',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.bodyLarge
              ?.copyWith(fontWeight: FontWeight.w600),
        ),
      ],
    );
  }

  /// 发送区：文件浏览框（点按选文件/夹）+ 已连接后显示连接状态卡与「发送」按钮。
  /// 与接收区始终同屏，连接成功后双方均可主动发送，不再区分角色。
  Widget _buildSendBox(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final hasSelection = _selectedPaths.isNotEmpty;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 胶囊框：标题/已选项占满左侧，文件夹图标靠右（填充式底色）
        InkWell(
          onTap: _busy ? null : _pickFiles,
          borderRadius: BorderRadius.circular(999),
          child: Container(
            height: 48,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(999),
              color: colorScheme.surfaceContainerHighest.withAlpha(110),
              border: Border.all(
                color: colorScheme.outlineVariant.withAlpha(80),
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
        const SizedBox(height: 12),
        // 已连接：显示连接状态卡 + 「发送」按钮（由发送方手动开始传输，
        // 未选文件时禁用；先连接后选文件完全支持）
        if (_conn.connected && _socketReady && !_transferring) ...[
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
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
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: _selectedPaths.isEmpty ? null : _startSend,
              icon: const Icon(Broken.export),
              label: Text(L10n.of(context).quick_transfer_send_button),
            ),
          ),
        ],
      ],
    );
  }

  /// 接收区：默认接收路径浏览框（点按可改路径，持久化）。
  Widget _buildReceiveBox(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    return InkWell(
      onTap: _busy ? null : _pickReceiveDir,
      borderRadius: BorderRadius.circular(999),
      child: Container(
        height: 56,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(999),
          color: colorScheme.surfaceContainerHighest.withAlpha(110),
          border: Border.all(
            color: colorScheme.outlineVariant.withAlpha(80),
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
    );
  }

  Widget _buildDiscoveryArea(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildDiscoveryRow(context),
        const SizedBox(height: 8),
        if (_scanning) ...[
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
          const SizedBox(height: 8),
        ],
        if (!_scanning)
          Text(
            L10n.of(context).quick_transfer_tap_to_connect,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        if (!_scanning) const SizedBox(height: 8),
        _buildKnownPeers(context),
        _buildPeerList(context),
      ],
    );
  }

  Widget _buildDiscoveryRow(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      child: FilledButton.tonalIcon(
        onPressed: _scanning ? null : _startDiscovery,
        icon: _scanning
            ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
            : const Icon(Broken.discover),
        label: Text(L10n.of(context).quick_transfer_nearby_devices),
      ),
    );
  }

  Widget _buildPeerList(BuildContext context) {
    // 已记住的设备已在上方单独列出，这里仅显示未在已记住列表中的实时发现设备，
    // 避免同一设备重复出现。分区标题已由发现区卡片统一提供。
    final knownAddrs = _knownPeers.map((p) => p.address).toSet();
    final livePeers = _peers.where((p) => !knownAddrs.contains(p.address)).toList();
    if (livePeers.isEmpty) {
      return const SizedBox.shrink();
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (int i = 0; i < livePeers.length; i++) ...[
          if (i > 0 || _knownPeers.isNotEmpty) const SizedBox(height: 8),
          _deviceRowCard(
            context,
            peer: livePeers[i],
            onTap: (_scanning || _conn.connected)
                ? null
                : () => _connectPeer(livePeers[i]),
          ),
        ],
      ],
    );
  }

  /// 已记住设备列表：无标题，每行右侧固定贴附连接按钮（复用 _buildConnectButton）
  /// 与删除按钮（靠右边缘）。点击左侧设备名称/图标区域亦可发起连接。
  Widget _buildKnownPeers(BuildContext context) {
    if (_knownPeers.isEmpty) {
      return const SizedBox.shrink();
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (int i = 0; i < _knownPeers.length; i++) ...[
          if (i > 0) const SizedBox(height: 8),
          _deviceRowCard(
            context,
            peer: _knownPeers[i],
            showDelete: true,
            onTap: (_busy || _conn.connected)
                ? null
                : () => _connectPeer(_knownPeers[i]),
          ),
        ],
      ],
    );
  }

  /// 设备行卡片：圆角浅底行，左端图标徽章 + 名称/地址，右端连接按钮
  /// （及可选的删除按钮），按钮组固定贴右边缘。左侧整片可点发起连接。
  Widget _deviceRowCard(
    BuildContext context, {
    required PeerDevice peer,
    required VoidCallback? onTap,
    bool showDelete = false,
  }) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final canDelete = !(_busy || _conn.connected);
    return Container(
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest.withAlpha(90),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          // 左侧：图标徽章 + 名称 + 地址，整片可点发起连接
          Expanded(
            child: InkWell(
              onTap: onTap,
              borderRadius: BorderRadius.circular(12),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 10),
                child: Row(
                  children: [
                    _iconBadge(context, Broken.profile_circle),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            peer.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodyLarge
                                ?.copyWith(fontWeight: FontWeight.w600),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            peer.address,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          // 右侧：连接按钮 + 删除按钮，固定贴右边缘
          Padding(
            padding: const EdgeInsets.only(right: 4),
            child: _buildConnectButton(context, peer),
          ),
          if (showDelete)
            IconButton(
              icon: const Icon(Broken.trash, size: 20),
              tooltip: L10n.of(context).quick_transfer_forget_device,
              onPressed: canDelete ? () => _removeKnownPeer(peer) : null,
            ),
        ],
      ),
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
    final colorScheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          // 图标徽章：等待清单时绿色对勾（连接已建立，等的是文件），
          // 否则按发送/接收方向显示箭头图标。
          Container(
            width: 88,
            height: 88,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: colorScheme.primaryContainer.withAlpha(100),
            ),
            child: Icon(
              waiting
                  ? Broken.tick_circle
                  : (_isSender ? Broken.export : Broken.import),
              size: 40,
              color: waiting ? Colors.green : colorScheme.primary,
            ),
          ),
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
            height: 48,
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
