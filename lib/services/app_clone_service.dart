import 'dart:async';
import 'package:flutter/foundation.dart';
import 'root_shizuku_service.dart';

/// 分身操作失败类型：UI 层据此映射为可读的错误提示文案。
enum AppCloneError {
  /// 无可用特权通道（Shizuku 未运行/未授权，且无 root）
  noPrivilege,

  /// 命令执行超时
  timeout,

  /// 达到系统用户数量上限（部分 ROM 限制可创建的用户数）
  userLimit,

  /// 其他失败（[AppCloneException.raw] 携带命令原始输出便于排查）
  failed,
}

/// 分身操作异常：统一携带错误码与原始输出。
class AppCloneException implements Exception {
  final AppCloneError code;
  final String raw;
  AppCloneException(this.code, [this.raw = '']);

  @override
  String toString() => 'AppCloneException($code, $raw)';
}

/// 系统用户（分身）条目：id + 名称 + 是否在线。
class CloneUserInfo {
  final int id;
  final String name;
  final bool isRunning;
  const CloneUserInfo({required this.id, required this.name, required this.isRunning});
}

/// 应用分身服务：基于 Android 系统多用户机制，经 Shizuku（shell 特权）或 root
/// 执行 pm/am 命令，把同一应用以分身形式多开、数据完全隔离。
/// 不重打包 APK、不引第三方库、零体积增量。
///
/// 命令链路概览：
///  - 列用户      `pm list users`
///  - 建分身      `pm create-user <name>`（成功行 `Success: created user id <n>`）
///  - 删分身      `pm remove-user <uid>`
///  - 装新 APK    `pm install --user <uid> <apk路径>`（shell 具备 INSTALL_PACKAGES）
///  - 毫秒级克隆  `pm install-existing --user <uid> <pkg>`（把本机已装应用装进分身）
///  - 卸载分身内  `pm uninstall --user <uid> <pkg>`（只影响该用户）
///  - 启动        `cmd package resolve-activity --brief --user <uid> <pkg>` 拿组件
///                → `am start --user <uid> -n <comp>`；失败回退
///                `monkey -p <pkg> --user <uid> 1`
class AppCloneService {
  AppCloneService._();

  /// 常规 pm/am 命令超时：list/install-existing 等毫秒级到秒级，留足余量。
  static const _genericTimeout = Duration(seconds: 20);

  /// `pm install --user` 装完整 APK 的超时：大包在低端机上可能要数十秒。
  static const _installTimeout = Duration(seconds: 300);

  /// 是否具备执行分身命令的特权通道（root 优先，其次已授权的 Shizuku）。
  static Future<bool> hasPrivilege() async {
    final s = await RootShizukuService.checkStatus();
    return s.isRootAvailable || (s.isShizukuAvailable && s.shizukuPermissionGranted);
  }

  /// 请求 Shizuku 授权（会弹出 Shizuku 的授权对话框）。
  static Future<bool> requestPrivilege() => RootShizukuService.requestShizukuPermission();

  /// 执行一条 pm/am 命令并返回完整 stdout（stderr 已重定向合并，便于解析错误原因）。
  ///
  /// 与 RootShizukuService._writeWithFallback 的经验一致：**不要在 shell 里用
  /// `||` 串接回退**（部分 ROM 假 exit 0 会吞掉回退），回退统一在 Dart 层逐条尝试。
  /// root 优先（su 环境 pm 权限更全），否则走 Shizuku shell（uid 2000，具备
  /// INSTALL_PACKAGES 等 shell 特权）。
  static Future<String> _exec(
    String command, {
    Duration timeout = _genericTimeout,
  }) async {
    final s = await RootShizukuService.checkStatus();
    final useRoot = s.isRootAvailable;
    final allowed = useRoot || (s.isShizukuAvailable && s.shizukuPermissionGranted);
    if (!allowed) throw AppCloneException(AppCloneError.noPrivilege);
    try {
      final out = await RootShizukuService.runCommand('$command 2>&1', useRoot: useRoot)
          .timeout(timeout);
      return out ?? '';
    } on TimeoutException {
      throw AppCloneException(AppCloneError.timeout);
    } catch (e) {
      // 通道层异常（native 抛错等）按普通失败处理，携带原因。
      throw AppCloneException(AppCloneError.failed, e.toString());
    }
  }

  /// 列出系统全部用户（含主用户 id 0，由调用方自行过滤）。
  ///
  /// `pm list users` 在不同 ROM 上有两种输出形态，逐行解析需同时兼容：
  ///   - 长格式：`UserInfo{id:10, name:分身 1, flags:[...]} running`
  ///   - 短格式：`UserInfo{10:分身 1:4100} running`
  static Future<List<CloneUserInfo>> listUsers() async {
    final out = await _exec('pm list users');
    final users = <CloneUserInfo>[];
    for (final rawLine in out.split('\n')) {
      final line = rawLine.trim();
      if (!line.contains('UserInfo')) continue;
      final running = line.contains('running');
      final long = RegExp(r'UserInfo\{id:(\d+),\s*name:([^,}]*)').firstMatch(line);
      final short = RegExp(r'UserInfo\{(\d+):(.+?):\d+\}').firstMatch(line);
      final m = long ?? short;
      if (m == null) continue;
      final id = int.tryParse(m.group(1)!);
      if (id == null) continue;
      var name = (m.group(2) ?? '').trim();
      if (name.isEmpty) name = 'U$id';
      users.add(CloneUserInfo(id: id, name: name, isRunning: running));
    }
    return users;
  }

  /// 创建分身用户，返回新用户条目。失败抛 [AppCloneException]：
  /// ROM 限制用户数时错误码为 [AppCloneError.userLimit]。
  static Future<CloneUserInfo> createUser(String name) async {
    final out = await _exec('pm create-user "$name"');
    final m = RegExp(r'created user id:?\s*(\d+)').firstMatch(out);
    if (m != null) {
      final id = int.tryParse(m.group(1)!);
      if (id != null) {
        debugPrint('[ZenFile] app_clone: created user $id ($name)');
        return CloneUserInfo(id: id, name: name, isRunning: false);
      }
    }
    throw AppCloneException(_classifyCreateUserError(out), out.trim());
  }

  /// 归类 create-user 失败原因：各家 ROM 的限制文案不一，按关键词覆盖常见写法。
  static AppCloneError _classifyCreateUserError(String out) {
    final lower = out.toLowerCase();
    if (lower.contains('maximum') ||
        lower.contains("can't create") ||
        lower.contains('cannot create') ||
        lower.contains('user limit') ||
        lower.contains('too many users') ||
        lower.contains('exceed')) {
      return AppCloneError.userLimit;
    }
    return AppCloneError.failed;
  }

  /// 删除分身用户（连同其内全部应用数据）。
  static Future<void> removeUser(int uid) async {
    final out = await _exec('pm remove-user $uid');
    if (!out.toLowerCase().contains('success')) {
      throw AppCloneException(AppCloneError.failed, out.trim());
    }
  }

  /// 列出指定用户安装的第三方包（`-3`），包名升序。
  static Future<List<String>> listThirdPartyPackages(int uid) async {
    final out = await _exec('pm list packages --user $uid -3');
    return out
        .split('\n')
        .map((l) => l.trim())
        .where((l) => l.startsWith('package:'))
        .map((l) => l.substring('package:'.length).trim())
        .where((s) => s.isNotEmpty)
        .toList()
      ..sort();
  }

  /// 把本机（主用户）已装应用毫秒级装进分身（pm install-existing）。
  static Future<void> installExistingForUser(int uid, String pkg) async {
    final out = await _exec(
      'pm install-existing --user $uid "$pkg"',
      timeout: const Duration(seconds: 60),
    );
    if (!out.toLowerCase().contains('success')) {
      throw AppCloneException(AppCloneError.failed, out.trim());
    }
  }

  /// 从指定分身卸载应用（只影响该用户，本机安装不受影响）。
  static Future<void> uninstallForUser(int uid, String pkg) async {
    final out = await _exec(
      'pm uninstall --user $uid "$pkg"',
      timeout: const Duration(seconds: 60),
    );
    if (!out.toLowerCase().contains('success')) {
      throw AppCloneException(AppCloneError.failed, out.trim());
    }
  }

  /// 把一个 .apk 文件安装到指定分身（pm install --user）。
  ///
  /// 降级安装（-d）需要 INSTALL_ALLOW_DOWNGRADE 权限、部分 ROM 的 shell 不具备，
  /// 与 RootShizukuService.installApkSilently 的策略一致：仅在明确报 downgrade
  /// 时补 -d 重试一次。
  static Future<void> installApkForUser(String apkPath, int uid) async {
    var out = await _exec('pm install --user $uid -r "$apkPath"', timeout: _installTimeout);
    if (out.toLowerCase().contains('success')) return;
    if (out.toLowerCase().contains('downgrade')) {
      out = await _exec('pm install --user $uid -r -d "$apkPath"', timeout: _installTimeout);
      if (out.toLowerCase().contains('success')) return;
    }
    throw AppCloneException(AppCloneError.failed, out.trim());
  }

  /// 在指定分身内启动应用。
  ///
  /// ① `cmd package resolve-activity --brief` 拿 launcher 组件 → `am start -n`；
  /// ② 失败回退 `monkey`（对 ROM 差异更宽容）。
  static Future<bool> launchAppForUser(int uid, String pkg) async {
    final resolveOut = await _exec(
      'cmd package resolve-activity --brief --user $uid -c android.intent.category.LAUNCHER "$pkg"',
    );
    // --brief 输出里形如 `pkg/Activity` 的行即组件（可能先有一行裸包名，取最后一条匹配）。
    String? component;
    for (final line in resolveOut.split('\n')) {
      final l = line.trim();
      if (RegExp(r'^[\w.]+/[\w.$]+$').hasMatch(l)) component = l;
    }
    if (component != null) {
      final out = await _exec('am start --user $uid -n "$component"');
      final lower = out.toLowerCase();
      if (lower.contains('starting') && !lower.contains('error')) return true;
    }
    // 兜底：monkey 注入一个 launcher 启动事件。
    final monkeyOut = await _exec('monkey -p "$pkg" --user $uid 1');
    final mLower = monkeyOut.toLowerCase();
    return mLower.contains('events injected: 1') && !mLower.contains('error');
  }
}
