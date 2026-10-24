import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import 'crypt/crypt_mount.dart';
import 'crypt/crypt_mount_service.dart';
import 'crypt/crypt_operations.dart';
import 'crypt/vault_crypt_service.dart';

/// 原地加密目录「新文件自动加密」服务。
///
/// ## 背景（用户预期）
/// 原地加密是一次性动作：把目录里**当时**的文件加密完就结束了。此后相机等
/// 外部 App 写进已加密目录的新文件永远是明文。用户选择「不加密目录名」后
/// 目录名不变，新照片直接落在密文目录**内部**，只差「发现明文 → 就地加密」
/// 一步 —— 本服务负责这一步，分两层：
///
/// **B. 实时监听**：Kotlin `CryptWatchForegroundService`（前台服务 + FileObserver）
/// 把新文件事件推回来，静默期（写入结束且大小稳定）后就地加密。
/// **A. 兜底补加密**：App 启动 / 服务启动 / 监听表变更时，对全部已注册容器目录
/// 跑一遍 [CryptOperations.mergeNewFilesIntoEncryptedDir]（即手动「加密新增文件」
/// 的同一套逻辑），补上服务未运行期间漏掉的文件。
///
/// ## 安全边界
/// - 只**加密**（保护方向），不解密；主密码来自 CryptProfile（secure storage），
///   不要求保险箱会话解锁 —— PIN 门禁保护的是「查看」，而加密只会让文件更不可见。
/// - 监听表来自 [CryptMountService.loadInPlaceContainerDirs] 登记表，
///   过滤整机根目录级别路径（历史错误配置，见 [CryptMountService.isStorageRootPath]）。
/// - 目录名加密（standard）形态下新文件落在**同名明文兄弟目录**：本服务把该
///   目录一并纳入监听（存在则直接监听；不存在则登记为 pending，由原生监控
///   其父目录，相机一重建就自动转正），事件触发 [防抖并入] —— 补上旧版
///   「只在 App 打开/服务启动时兜底一次」的空窗（2026-10-02 用户报障：
///   相机检测不到已加密目录会重建明文目录，新照片在两次兜底之间一直明文）。
class CryptAutoEncryptService extends ChangeNotifier {
  CryptAutoEncryptService._();
  static final CryptAutoEncryptService instance = CryptAutoEncryptService._();

  static const _channel = MethodChannel('com.sequl.zenfile/crypt_watch');
  static const String _kEnabledKey = 'crypt_auto_encrypt_enabled';

  /// 「自动关联本地加密文件」开关（设置页「自动关联」区）。
  ///
  /// 语义（2026-10-24 用户拍板）：**自动识别本地已存在的原地加密文件并登记**
  /// 进「原地加密目录登记表」（[CryptMountService.addEncryptedDir]），之后浏览
  /// 与解密即可正常；**不再**启动实时监听去加密新写入的文件（那是旧开关
  /// `_enabled` 的行为，已从设置页下线，代码保留以便回退）。
  ///
  /// 判定发生在**浏览目录时**（该目录的列表已经读出来了，见
  /// `FileManagerProvider._ephemeralMountForDir`）——不做全盘扫描，零额外 IO。
  static const String _kAssocLocalKey = 'crypt_auto_assoc_local_enabled';

  /// 「自动关联远程加密文件」开关：浏览远程目录时用**已拉取的列表**判定密文，
  /// 命中即登记为「关联远程加密目录」（[CryptMountService.addRemoteEncryptedDir]），
  /// 之后可在保险箱中以明文名打开与解密。同样不额外发起网络请求。
  static const String _kAssocRemoteKey = 'crypt_auto_assoc_remote_enabled';

  /// 事件静默期：最后一次文件事件后等待这么久才动手（相机/下载是渐进写）。
  static const Duration quiescence = Duration(seconds: 5);

  /// 同名明文兄弟目录的并入防抖：相机连拍/录像是成批渐进写，比单文件
  /// 静默期更久；merge 自身会跳过已加密项，多触发几次没有副作用。
  static const Duration shadowMergeQuiescence = Duration(seconds: 15);

  /// 大小稳定复查间隔与容忍度
  static const Duration _stabilityRecheck = Duration(milliseconds: 1200);

  /// 加密层的临时文件后缀（见 CryptOperations.tmpSuffix），事件里直接跳过
  static const String _cryptTmpSuffix = '.zencrypt_tmp';

  bool? _enabled;
  bool get enabled => _enabled ?? false;

  /// 当前监听的容器目录（已过滤存储根），供设置页展示
  List<String> _watchedDirs = const [];
  List<String> get watchedDirs => _watchedDirs;

  /// 原生监听服务是否已启动
  bool _serviceStarted = false;
  bool get serviceStarted => _serviceStarted;

  /// 见 [_kAssocLocalKey]。默认关闭。
  bool? _assocLocal;
  bool get autoAssociateLocal => _assocLocal ?? false;

  /// 见 [_kAssocRemoteKey]。默认关闭。
  bool? _assocRemote;
  bool get autoAssociateRemote => _assocRemote ?? false;

  bool _initialized = false;
  final Map<String, Timer> _pendingTimers = {};
  final Map<String, int> _lastKnownSize = {};
  final Set<String> _catchUpBusyDirs = {};

  /// 同名明文兄弟目录 → 密文容器目录（standard 配置才有）。
  /// 这些目录里的事件不做事就加密，而是防抖后触发整目录并入。
  final Map<String, String> _shadowPlainToCipher = {};
  Map<String, String> get shadowPlainToCipher =>
      Map.unmodifiable(_shadowPlainToCipher);

  final Map<String, Timer> _shadowMergeTimers = {};

  /// 影子明文目录轮询保底（2026-10-03）：FileObserver 事件链在部分环境
  /// （Android 11+ FUSE 上其他 App 的写入）不可靠甚至整体静默——三轮真机
  /// 报障均只有重启兜底生效。轮询不依赖任何事件，直接查磁盘：影子目录存在
  /// 且非空 → 走与事件相同的防抖合并。事件链正常时 merge 幂等提前跳过，
  /// 轮询只是空查几个 stat；事件链哑火时它就是唯一生效路径。
  static const Duration shadowPollInterval = Duration(seconds: 30);
  Timer? _shadowPollTimer;

  /// 影子明文目录成功并入密文容器后的回调（provider 注册它来刷新全部本地
  /// 标签页）：相机重建的同名明文目录被并入后，「密文 + 同名明文」并存态
  /// 自动收敛为一条，无需用户手动刷新（2026-10-02 用户报障收尾）。
  Future<void> Function()? onMergeCompleted;

  /// 取证日志开关（发版必须为 false；排查自动加密问题时临时置 true，
  /// 日志落公共目录 .nomedia/crypt_auto_encrypt.log，挂载盘/MTP 直读）。
  /// 2026-10-03 自动加密四轮排查 + SMB 冻结取证全部完毕（用户已确认
  /// 合并加密与冻结修复均生效），按红线改回 false。
  static bool logEnabled = false;

  /// 取证日志文件（公共目录 .nomedia 下，无 adb 也可经 MTP/挂载读取）。
  /// 只记录生命周期与加/并入结果；超 256KB 截半；任何失败静默忽略。
  static const String _logFilePath =
      '/storage/emulated/0/ZenFile/.nomedia/crypt_auto_encrypt.log';

  static Future<void> _log(String message) async {
    if (!logEnabled) return;
    try {
      final f = File(_logFilePath);
      if (await f.exists()) {
        final len = await f.length();
        if (len > 256 * 1024) {
          final bytes = await f.readAsBytes();
          final keep = bytes.sublist(bytes.length ~/ 2);
          // 截半后对齐到下一行首，避免首行残缺
          var start = 0;
          while (start < keep.length && keep[start] != 0x0A) {
            start++;
          }
          await f.writeAsBytes(
            start < keep.length ? keep.sublist(start + 1) : keep,
          );
        }
      } else {
        await f.parent.create(recursive: true);
      }
      final now = DateTime.now();
      String two(int v) => v.toString().padLeft(2, '0');
      final ts = '${two(now.month)}-${two(now.day)} '
          '${two(now.hour)}:${two(now.minute)}:${two(now.second)}.'
          '${now.millisecond.toString().padLeft(3, '0')}';
      await f.writeAsString('[$ts] $message\n', mode: FileMode.append);
    } catch (_) {}
  }

  /// 初始化：读取开关、注册事件通道、按登记表启动/刷新监听。
  /// 在 main.dart 启动序列中调用（需 Platform channel 可用）。
  Future<void> init() async {
    if (_initialized) return;
    _initialized = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      _enabled = prefs.getBool(_kEnabledKey) ?? false;
      _assocLocal = prefs.getBool(_kAssocLocalKey) ?? false;
      _assocRemote = prefs.getBool(_kAssocRemoteKey) ?? false;
    } catch (_) {
      _enabled = false;
      _assocLocal = false;
      _assocRemote = false;
    }
    _channel.setMethodCallHandler(_handleNativeCall);
    // 登记表变化（新的原地加密完成 / 解密注销）→ 刷新监听表
    CryptMountService.onInPlaceContainerDirsChanged = (_) => refreshWatchPaths();
    await refreshWatchPaths();
    if (enabled) {
      unawaited(runCatchUp());
    }
    notifyListeners();
  }

  Future<dynamic> _handleNativeCall(MethodCall call) async {
    if (call.method != 'onFileChanged') return null;
    final args = call.arguments as Map?;
    if (args == null) return null;
    final dir = args['dir'] as String?;
    final name = args['name'] as String?;
    final event = args['event'] as String?;
    if (dir == null || name == null || event == null) return null;
    _onNativeEvent(dir, name, event);
    return null;
  }

  // ── 开关与监听表 ──────────────────────────────────────────────────────────

  /// 「自动关联」两个开关的状态发生变化时的回调（供 FileManagerProvider 刷新
  /// 加密挂载点）。开关**关闭**时会回收此前自动登记的目录，浏览页必须立刻
  /// 重新按「普通文件」展示，否则用户看到的就是「关了还照样解密显示」。
  static Future<void> Function()? onAutoAssocChanged;

  /// 「自动关联」两个开关：只落盘开关 + 通知 UI，不做任何扫描/监听。
  ///
  /// 实际判定都发生在浏览目录时（列表已经在内存里），因此**开**的代价为 0。
  /// **关**则要做一件事：回收此前由本开关自动登记进来的目录（本地进
  /// 「原地加密目录登记表」的、远程进「关联远程加密目录」的）—— 登记表本身
  /// 不记来源，故另有一本账（见 [CryptMountService.loadAutoAssocLocalDirs] /
  /// [RemoteCryptDirRecord.source]）。加密操作本身登记的目录不在回收范围内。
  Future<void> setAutoAssociateLocal(bool value) async {
    _assocLocal = value;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_kAssocLocalKey, value);
    } catch (_) {}
    if (!value) {
      await CryptMountService.purgeAutoAssocLocalDirs();
    }
    notifyListeners();
    await onAutoAssocChanged?.call();
  }

  Future<void> setAutoAssociateRemote(bool value) async {
    _assocRemote = value;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_kAssocRemoteKey, value);
    } catch (_) {}
    if (!value) {
      await CryptMountService.purgeAutoRemoteEncryptedDirs();
    }
    notifyListeners();
    await onAutoAssocChanged?.call();
  }

  /// 设置页开关
  Future<void> setEnabled(bool value) async {
    _enabled = value;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_kEnabledKey, value);
    } catch (_) {}
    notifyListeners();
    if (value) {
      await refreshWatchPaths();
      unawaited(runCatchUp());
    } else {
      await _stopNative();
      _serviceStarted = false;
      _syncShadowPollTimer();
      notifyListeners();
    }
  }

  /// 从登记表重读容器目录并应用到原生监听（存储根等危险路径在此过滤）
  Future<void> refreshWatchPaths() async {
    final plan = await _resolveWatchPlan();
    _watchedDirs = plan.watchDirs;
    unawaited(_log(
      'refreshWatchPaths: enabled=$enabled, containers=${plan.containerDirs.length}, '
      'watch=${plan.watchDirs.length}, pending=${plan.pending.length}, '
      'shadows=${_shadowPlainToCipher.length}',
    ));
    if (enabled) {
      if (plan.watchDirs.isEmpty && plan.pending.isEmpty) {
        // 没有可监听的目录：停掉前台服务，省一条常驻通知
        await _stopNative();
        _serviceStarted = false;
      } else {
        try {
          await _channel.invokeMethod('start', {
            'paths': plan.watchDirs,
            // 尚不存在的同名明文兄弟目录：原生监控其父目录，出现即转正监听
            'pendingPaths': plan.pending,
            'title': 'ZenFile 自动加密',
            'contentText': '正在保护 ${plan.containerDirs.length} 个已加密目录',
          });
          _serviceStarted = true;
        } catch (e) {
          debugPrint('[CryptAutoEncrypt] start watch service failed: $e');
          _serviceStarted = false;
        }
      }
    }
    _syncShadowPollTimer();
    // 空计划自愈重试（2026-10-03 取证：某次启动 resolvePlan 全 0 且此后
    // 永不重跑 ⇒ 监听/轮询整体空转）。启动早期挂载点/主密码配置可能尚未
    // 就绪（getMasterConfig 返回 null ⇒ 来源 B 全跳过），重试窗口覆盖它。
    if (enabled && plan.containerDirs.isEmpty) {
      if (_emptyPlanRetries < 5) {
        _emptyPlanRetries++;
        unawaited(_log('plan empty, retry #$_emptyPlanRetries in 10s'));
        Future.delayed(const Duration(seconds: 10), () {
          if (enabled) unawaited(refreshWatchPaths());
        });
      } else {
        unawaited(_log('plan empty, retries exhausted'));
      }
    } else if (plan.containerDirs.isNotEmpty) {
      _emptyPlanRetries = 0;
    }
    notifyListeners();
  }

  /// 空计划连续重试计数（成功解析到容器即归零）
  int _emptyPlanRetries = 0;

  /// 轮询保底启停：有影子目录且开关打开 → 周期轮询；否则取消。
  void _syncShadowPollTimer() {
    if (enabled && _shadowPlainToCipher.isNotEmpty) {
      _shadowPollTimer ??= Timer.periodic(shadowPollInterval, (_) {
        unawaited(_pollShadowDirs());
      });
    } else {
      _shadowPollTimer?.cancel();
      _shadowPollTimer = null;
    }
  }

  /// 轮询保底：影子明文目录存在且非空 → 走与事件相同的防抖合并。
  /// 只查直接子项是否有内容（merge 自己会跳过已加密项，空目录留给
  /// 相机继续写，避免刚 mkdir 就被我们删掉导致相机报错）。
  Future<void> _pollShadowDirs() async {
    if (!enabled || _shadowPlainToCipher.isEmpty) return;
    // 快照遍历：循环内有 await，_resolveWatchPlan 可能并发 clear/重填原表
    // （Dart 对迭代中的 Map 做修改会抛 ConcurrentModificationError）。
    final snapshot = Map.of(_shadowPlainToCipher);
    for (final entry in snapshot.entries) {
      final plainDir = entry.key;
      final cipherDir = entry.value;
      try {
        final dir = Directory(plainDir);
        if (!await dir.exists()) continue;
        var hasContent = false;
        await for (final e in dir.list(followLinks: false)) {
          hasContent = true;
          break;
        }
        if (!hasContent) continue;
        unawaited(_log('poll: non-empty shadow dir $plainDir -> merge'));
        _onShadowPlainDirEvent(plainDir, cipherDir, 'poll');
      } catch (_) {}
    }
  }

  Future<void> _stopNative() async {
    try {
      await _channel.invokeMethod('stop');
    } catch (_) {}
  }

  /// 监听计划 → 容器目录的挂载点缓存（_resolveWatchPlan 填充，
  /// merge/catchUp 优先复用，避免每次合并重复解析配置/派生密钥）。
  final Map<String, CryptMountPoint> _containerMounts = {};

  /// 监听计划（两个来源，判据与保险箱「原地加密」列表完全同源）：
  ///
  /// 来源 A：`loadInPlaceContainerDirs` —— 「整体加密但**目录名保持明文**」的
  /// 容器登记表（挂载点根形态，encryptDirectory 的 else 分支登记）。
  ///
  /// 来源 B：`loadEncryptedDirs` —— 原地加密登记的**父目录**（如 /DCIM），
  /// 其下的**密文名子目录**就是「目录名加密」形态的容器（/DCIM/Camera →
  /// /DCIM/jX0p4…）。这种形态从不进来源 A 的表——2026-10-02 报障：
  /// 只接来源 A ⇒ 目录名加密场景监听表恒为空 ⇒ 自动加密整条链路空转，
  /// 实时与 catch-up 全部失效，只有手动「加密新增文件」能用。
  ///
  /// 产物：
  /// - [WatchPlan.containerDirs]：已存在的密文容器目录（catch-up 的处理对象）；
  /// - [WatchPlan.watchDirs]：containerDirs + **已存在**的同名明文兄弟目录
  ///   （相机重建的那个，直接监听、事件触发并入）；
  /// - [WatchPlan.pending]：**尚不存在**的同名明文兄弟目录（原生监控父目录，
  ///   出现即转正），同时登记进 [_shadowPlainToCipher] 供事件分流。
  Future<_WatchPlan> _resolveWatchPlan() async {
    final containerDirs = <String>[];
    final watchDirs = <String>[];
    final pending = <String>[];
    final seen = <String>{};
    _shadowPlainToCipher.clear();
    _containerMounts.clear();

    Future<void> collectContainer(
      String container,
      CryptMountPoint? mount,
    ) async {
      if (!seen.add(p.normalize(container))) return;
      if (mount != null) {
        _containerMounts[p.normalize(container)] = mount;
      }
      try {
        final type = await FileSystemEntity.type(container);
        if (type != FileSystemEntityType.directory) return;
      } catch (_) {
        return;
      }
      containerDirs.add(container);
      watchDirs.add(container);

      // 推导同名明文兄弟目录（目录名加密配置才有；明文名容器解不出不同名，
      // shadowPlainDirFor 返回 null，天然跳过）。
      String? shadowPath;
      if (mount != null) {
        try {
          final cipherName = p.basename(container);
          if (CryptOperations.isCipherDirName(cipherName, mount)) {
            final plainName = mount.crypt.decryptDirName(cipherName);
            shadowPath = shadowPlainDirFor(container, plainName);
            if (shadowPath != null) {
              _shadowPlainToCipher[shadowPath] = container;
            }
          }
        } catch (_) {}
      }
      if (shadowPath == null) return;
      try {
        final t = await FileSystemEntity.type(shadowPath);
        if (t == FileSystemEntityType.directory) {
          // 已存在（相机已重建）：直接监听，事件走并入分流
          watchDirs.add(shadowPath);
          unawaited(_log('container: $container, shadow exists: $shadowPath'));
        } else {
          pending.add(shadowPath);
          unawaited(_log('container: $container, shadow pending: $shadowPath'));
        }
      } catch (_) {
        pending.add(shadowPath);
        unawaited(_log('container: $container, shadow pending(err): $shadowPath'));
      }
    }

    // ── 来源 A：目录名保持明文的容器登记表 ──
    for (final dir in await CryptMountService.loadInPlaceContainerDirs()) {
      if (CryptMountService.isStorageRootPath(dir)) continue;
      // 挂载解析失败仍登记监听（catch-up 内部会再兜底解析一次）
      final mount = await _resolveMountForDir(dir);
      await collectContainer(dir, mount);
    }

    // ── 来源 B：原地加密父目录登记表 → 扫描其下的密文名子目录 ──
    try {
      final registered = await CryptMountService.loadEncryptedDirs();
      unawaited(_log(
        'sourceB: registered parents=${registered.length}: $registered',
      ));
      for (final parentPath in registered) {
        if (parentPath.isEmpty) continue;
        bool parentExists;
        try {
          parentExists = await Directory(parentPath).exists();
        } catch (_) {
          parentExists = false;
        }
        if (!parentExists) {
          unawaited(_log('sourceB: parent missing, skip: $parentPath'));
          continue; // 陈旧记录
        }
        final parentMount = await _resolveMountForDir(parentPath);
        if (parentMount == null) {
          // 启动早期主密码配置可能未就绪 —— 打点 + 靠 refreshWatchPaths
          // 的空计划重试自愈（2026-10-03 取证：此处曾静默跳过 ⇒ 全 0 空转）
          unawaited(
            _log('sourceB: no mount for parent, skip: $parentPath'),
          );
          continue;
        }
        final List<FileSystemEntity> children;
        try {
          children =
              await Directory(parentPath).list(followLinks: false).toList();
        } catch (e) {
          unawaited(_log('sourceB: list failed $parentPath: $e'));
          continue;
        }
        for (final entity in children) {
          if (entity is! Directory) continue;
          final name = p.basename(entity.path);
          // 与保险箱列表/merge② 完全同源的判据：往返校验
          final cipher = CryptOperations.isCipherDirName(name, parentMount);
          unawaited(_log('sourceB: child=$name cipher=$cipher'));
          if (!cipher) continue;
          await collectContainer(p.normalize(entity.path), parentMount);
        }
      }
    } catch (e) {
      unawaited(_log('sourceB FAILED: $e'));
    }

    unawaited(_log(
      'resolvePlan: containers=${containerDirs.length}, '
      'watch=${watchDirs.length}, pending=${pending.length}, '
      'shadows=${_shadowPlainToCipher.length}',
    ));
    return _WatchPlan(
      containerDirs: containerDirs,
      watchDirs: watchDirs,
      pending: pending,
    );
  }

  /// 由密文容器目录与解密出的明文名推导「同名明文兄弟目录」路径。
  /// 明文名为空、与容器目录同名（配置未加密目录名）或同路径时返回 null。
  @visibleForTesting
  static String? shadowPlainDirFor(String containerDir, String plainName) {
    if (plainName.isEmpty) return null;
    final candidate = p.join(p.dirname(containerDir), plainName);
    if (p.equals(candidate, containerDir)) return null;
    return candidate;
  }

  // ── 实时事件处理（B） ─────────────────────────────────────────────────────

  void _onNativeEvent(String dir, String name, String event) {
    // 同名明文兄弟目录的事件：不做事就地加密（那会留下「明文名目录装密文」
    // 的四不像），而是防抖后整目录并入密文容器。
    final cipherDir = _shadowPlainToCipher[dir];
    if (cipherDir != null) {
      _onShadowPlainDirEvent(dir, cipherDir, event);
      return;
    }
    // 反斜杠兼容：部分 ROM 的 FileObserver 回传带分隔符差异
    final normalized = name.replaceAll('\\', '/');
    if (normalized.isEmpty || normalized.contains('/')) {
      // 只处理监听目录的直接子项；含分隔符的路径不在本层职责内
      // （FileObserver 非递归，正常不会出现；防御性忽略）
      return;
    }
    final path = p.join(dir, normalized);
    final base = p.basename(path);

    if (event == 'delete' || event == 'delete_self' || event == 'move_self') {
      _pendingTimers.remove(path)?.cancel();
      _lastKnownSize.remove(path);
      return;
    }
    if (!shouldConsiderForEncryption(base)) return;

    // 记录当前大小，供静默期后比对
    () async {
      try {
        final s = await File(path).stat();
        _lastKnownSize[path] = s.size;
      } catch (_) {}
    }();

    // 静默期防抖：持续写入会不断重置计时器
    _pendingTimers.remove(path)?.cancel();
    _pendingTimers[path] = Timer(quiescence, () => _processQuietFile(path));
  }

  /// 同名明文兄弟目录事件：任何写入类事件（含目录自身被重建的 create）都
  /// 重置并入防抖；delete 类只清计时器。merge 幂等（跳过已加密项），
  /// 多触发几次没有副作用。
  void _onShadowPlainDirEvent(
    String plainDir,
    String cipherDir,
    String event,
  ) {
    unawaited(_log('shadow event: $event on $plainDir'));
    if (event == 'delete' || event == 'delete_self' || event == 'move_self') {
      // 目录被（可能是我们自己的 merge）删掉：清防抖，等原生 pending 转正
      _shadowMergeTimers.remove(plainDir)?.cancel();
      return;
    }
    _shadowMergeTimers.remove(plainDir)?.cancel();
    _shadowMergeTimers[plainDir] = Timer(shadowMergeQuiescence, () {
      _shadowMergeTimers.remove(plainDir);
      unawaited(_mergeShadowIntoCipher(plainDir, cipherDir));
    });
  }

  Future<void> _mergeShadowIntoCipher(String plainDir, String cipherDir) async {
    if (_catchUpBusyDirs.contains(cipherDir)) return;
    _catchUpBusyDirs.add(cipherDir);
    unawaited(_log('shadow merge start: $plainDir -> $cipherDir'));
    try {
      // 容器已不存在（被解密/手动删除）：清掉 stale 映射并重解析监听表，
      // 否则事件/poll 会拿死映射持续空转（2026-10-03 日志：13 次
      // Directory not found 噪音）。
      if (!await Directory(cipherDir).exists()) {
        if (_shadowPlainToCipher.remove(plainDir) != null) {
          unawaited(
            _log('shadow merge: cipher dir gone, refresh: $cipherDir'),
          );
          unawaited(refreshWatchPaths());
        }
        return;
      }
      final mount = _containerMounts[p.normalize(cipherDir)] ??
          await _resolveMountForDir(cipherDir);
      if (mount == null) {
        debugPrint(
          '[CryptAutoEncrypt] shadow merge: no mount for $cipherDir, deferred',
        );
        unawaited(_log('shadow merge: no mount for $cipherDir, deferred'));
        return;
      }
      final ops = CryptOperations(mount);
      final merged = await ops.mergeNewFilesIntoEncryptedDir(cipherDir);
      unawaited(_log('shadow merge done: merged=$merged into $cipherDir'));
      if (merged > 0) {
        debugPrint(
          '[CryptAutoEncrypt] shadow $plainDir merged $merged items into $cipherDir',
        );
        final cb = onMergeCompleted;
        if (cb != null) {
          try {
            await cb();
          } catch (_) {}
        }
      }
    } catch (e) {
      debugPrint(
        '[CryptAutoEncrypt] shadow merge failed ($plainDir → $cipherDir): $e',
      );
      unawaited(_log('shadow merge FAILED ($plainDir -> $cipherDir): $e'));
    } finally {
      _catchUpBusyDirs.remove(cipherDir);
    }
  }

  /// 文件名级过滤（供测试复用的纯逻辑）：
  /// 隐藏文件、加密层临时文件、常见临时/中间态文件不参与自动加密。
  @visibleForTesting
  static bool shouldConsiderForEncryption(String baseName) {
    if (baseName.isEmpty || baseName.startsWith('.')) return false;
    if (baseName.endsWith(_cryptTmpSuffix)) return false;
    if (baseName.endsWith('.zw')) return false; // remote_crypt_file 临时密文
    if (baseName.endsWith('.tmp') || baseName.endsWith('.part') || baseName.endsWith('.crdownload')) {
      return false;
    }
    return true;
  }

  /// 静默期到：做最终判定并加密
  Future<void> _processQuietFile(String path) async {
    _pendingTimers.remove(path);
    final sizeAtEvent = _lastKnownSize.remove(path);
    try {
      final f = File(path);
      if (!await f.exists()) return;
      final type = await FileSystemEntity.type(path);
      if (type != FileSystemEntityType.file) return;

      // 大小稳定复查：仍在增长（大文件拷贝/相机连拍）→ 再等一轮
      var stat = await f.stat();
      if (sizeAtEvent != null && stat.size != sizeAtEvent) {
        await Future<void>.delayed(_stabilityRecheck);
        if (!await f.exists()) return;
        final next = await f.stat();
        if (next.size != stat.size) return; // 仍在写，放弃本轮（下一次事件会再来）
        stat = next;
      }

      // 已是密文（rclone magic 头）→ 不动
      if (await CryptOperations.isEncryptedFile(path)) return;

      final mount = await _resolveMountForDir(p.dirname(path));
      if (mount == null) {
        // 主密码不可用/无法定位档案：留给下次 catch-up
        debugPrint('[CryptAutoEncrypt] no mount for ${p.dirname(path)}, deferred to catch-up');
        unawaited(_log('in-place: no mount for ${p.dirname(path)}, deferred'));
        return;
      }
      final ops = CryptOperations(mount);
      final encryptedPath = await ops.encryptFile(path);
      debugPrint('[CryptAutoEncrypt] auto-encrypted: $path -> $encryptedPath');
      unawaited(_log('in-place encrypted: $path'));
    } catch (e) {
      debugPrint('[CryptAutoEncrypt] auto-encrypt failed for $path: $e');
      unawaited(_log('in-place encrypt FAILED: $path : $e'));
    }
  }

  // ── 兜底补加密（A） ───────────────────────────────────────────────────────

  /// 对所有已登记容器目录跑一遍「加密新增文件」。
  ///
  /// 复用手动入口同一套 [CryptOperations.mergeNewFilesIntoEncryptedDir]：
  /// ① 容器内混进的明文文件就地加密；②（standard 配置）同名明文兄弟目录整树
  /// 加密后并入。失败互不影响，逐目录 try/catch。
  Future<void> runCatchUp() async {
    // 只处理密文容器目录；同名明文兄弟目录由 merge 的②逻辑（含实时并入）覆盖
    final dirs = (await _resolveWatchPlan()).containerDirs;
    unawaited(_log('catchUp: dirs=${dirs.length}'));
    // 注意不要把 _watchedDirs 覆盖成 containerDirs：watchedDirs 还包含
    // 已存在的影子明文目录（refreshWatchPaths 负责，这里只做兜底合并）。
    for (final dir in dirs) {
      if (_catchUpBusyDirs.contains(dir)) continue;
      _catchUpBusyDirs.add(dir);
      try {
        final mount = _containerMounts[p.normalize(dir)] ??
            await _resolveMountForDir(dir);
        if (mount == null) {
          unawaited(_log('catchUp: no mount for $dir, skipped'));
          continue;
        }
        final ops = CryptOperations(mount);
        final merged = await ops.mergeNewFilesIntoEncryptedDir(dir);
        if (merged > 0) {
          debugPrint('[CryptAutoEncrypt] catch-up merged $merged items into $dir');
          unawaited(_log('catchUp merged $merged into $dir'));
        }
      } catch (e) {
        debugPrint('[CryptAutoEncrypt] catch-up failed for $dir: $e');
        unawaited(_log('catchUp FAILED for $dir: $e'));
      } finally {
        _catchUpBusyDirs.remove(dir);
      }
    }
    notifyListeners();
  }

  /// 为容器目录定位加密配置（headless 版 vault_explorer 的同名逻辑）：
  /// 先匹配持久化挂载点，否则按路径解析加密档案（绑定优先）建临时挂载点。
  /// 与 vault_explorer 不同：**不持久化**新挂载点、不弹密码框。
  Future<CryptMountPoint?> _resolveMountForDir(String dirPath) async {
    final mounts = await CryptMountService.loadMountPoints();
    for (final m in mounts) {
      if (m.isSandboxMode || CryptMountService.isStorageRootPath(m.physicalPath)) {
        continue;
      }
      if (m.containsPath(dirPath)) return m;
    }
    try {
      final master = await VaultCryptService.instance.getMasterConfig(path: dirPath);
      if (master == null) return null;
      final parentDir = p.dirname(dirPath);
      return CryptMountPoint(
        physicalPath: parentDir,
        config: master,
        name: p.basename(parentDir),
        isSandboxMode: false,
      );
    } catch (_) {
      return null;
    }
  }

  @override
  void dispose() {
    _channel.setMethodCallHandler(null);
    _shadowPollTimer?.cancel();
    _shadowPollTimer = null;
    super.dispose();
  }
}

/// 一次监听表解析的结果（见 [_resolveWatchPlan]）。
class _WatchPlan {
  final List<String> containerDirs;
  final List<String> watchDirs;
  final List<String> pending;
  const _WatchPlan({
    required this.containerDirs,
    required this.watchDirs,
    required this.pending,
  });
}
