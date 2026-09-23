import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/file_item_model.dart';
import 'package:path/path.dart' as p;
import 'restricted_dir_parser.dart';
import 'webdav_debug_log.dart';

class RootShizukuStatus {
  final bool isRootAvailable;
  final bool isShizukuAvailable;
  final bool shizukuPermissionGranted;

  RootShizukuStatus({
    required this.isRootAvailable,
    required this.isShizukuAvailable,
    required this.shizukuPermissionGranted,
  });

  factory RootShizukuStatus.fromMap(Map<dynamic, dynamic> map) {
    return RootShizukuStatus(
      isRootAvailable: map['isRootAvailable'] == true,
      isShizukuAvailable: map['isShizukuAvailable'] == true,
      shizukuPermissionGranted: map['shizukuPermissionGranted'] == true,
    );
  }
}

class RootShizukuService {
  static const MethodChannel _channel = MethodChannel('com.sequl.zenfile/root_shizuku');

  static Future<RootShizukuStatus> checkStatus() async {
    if (!Platform.isAndroid) {
      return RootShizukuStatus(isRootAvailable: false, isShizukuAvailable: false, shizukuPermissionGranted: false);
    }
    try {
      final res = await _channel.invokeMethod('checkStatus');
      if (res is Map) {
        return RootShizukuStatus.fromMap(res);
      }
    } catch (_) {}
    return RootShizukuStatus(isRootAvailable: false, isShizukuAvailable: false, shizukuPermissionGranted: false);
  }

  static Future<Map<String, int>?> getStorageSpace({String? path}) async {
    if (!Platform.isAndroid) return null;
    try {
      final res = await _channel.invokeMethod('getStorageSpace', {'path': path});
      if (res is Map) {
        return {
          'totalBytes': res['totalBytes'] as int? ?? 0,
          'availableBytes': res['availableBytes'] as int? ?? 0,
          'usedBytes': res['usedBytes'] as int? ?? 0,
        };
      }
    } catch (_) {}
    return null;
  }

  static Future<bool> requestShizukuPermission() async {
    if (!Platform.isAndroid) return false;
    try {
      final res = await _channel.invokeMethod('requestShizukuPermission');
      return res == true;
    } catch (_) {
      return false;
    }
  }

  static String _normalize(String path) {
    String normalized = path.replaceAll(RegExp(r'/+'), '/');
    if (normalized.isEmpty) normalized = '/';
    if (normalized.startsWith('/sdcard')) {
      normalized = normalized.replaceFirst('/sdcard', '/storage/emulated/0');
    } else if (normalized.startsWith('/mnt/sdcard')) {
      normalized = normalized.replaceFirst('/mnt/sdcard', '/storage/emulated/0');
    }
    return normalized;
  }

  /// 安卓 11+（含 vivo/OPPO 等定制 ROM）上，`/storage/emulated/0/Android/{data,obb}`
  /// 经 FUSE 挂载，即使 Shizuku（shell 用户 uid 2000）通过该路径执行 ls/glob 也会被
  /// FUSE 层拦截返回空（表现为直接进入 Android/data 显示空目录或受限提示页，
  /// 但收藏夹进入深层子路径再返回上层能正常显示——因 FUSE 仅拦截 /Android/data
  /// 本身的 list，而不拦截已知的具体子路径）。ES 文件管理器等通过底层 ext4
  /// 路径 `/data/media/0/Android/{data,obb}` 绕过 FUSE 限制。
  /// 此处通过 StorageManager 反射 API 获取实际主卷路径，
  /// 将其映射到对应的 FUSE 路径，确保命令执行在正确的路径上。
  static String _toFuseBypassPath(String path) => toFuseBypassPath(path);

  /// 将 stat `%n` 输出的底层路径 `/data/media/0/Android/...` 转回用户可见的
  /// `/storage/emulated/0/Android/...` 路径，保证后续所有操作（打开/复制/删除等）
  /// 基于 `/storage/emulated/0/` 路径，与普通（非受限）路径体系一致，避免路径分裂。
  static String _fromFuseBypassPath(String path) => fromFuseBypassPath(path);

  /// root 下 `su` 启动的 shell，其 PATH 不保证包含 `/system/bin`（部分 ROM 只给
  /// 精简 PATH，甚至为空），会让 `find`/`stat`/`rm`/`mv`/`du` 这类**非内建**命令
  /// 直接 "not found" 并返回空——过去「root 模式打开 Android/data 显示空目录」
  /// 就属于这一类**静默失败**：命令没跑成，输出为空，界面只会显示「空」。
  /// 这里对 root 命令统一前置补全 PATH，与命令里已有的绝对路径写法形成双保险。
  /// Shizuku 分支继承 adbd 环境（PATH 正常），**不改动**。
  static const String _rootPathPrefix =
      'export PATH=/system/bin:/system/xbin:/system/sbin:/sbin:/vendor/bin:\$PATH; ';

  /// 执行 shell 命令，返回 stdout。
  ///
  /// [fallbackSu] 仅对 root 模式有意义：为 true 时原生侧会依次尝试多种 su 调用
  /// 形式（`su -c` → `su -M -c` → `su 0 sh -c`）直到某一种真的产生输出。
  /// **只给「列目录」这类『输出为空』无法区分『目录真空』与『路径不可达』的命令
  /// 开启**；`rm`/`mv`/`mkdir` 成功时本就没有输出，开了会白跑几次 su。
  static Future<String?> runCommand(
    String command, {
    required bool useRoot,
    bool fallbackSu = false,
  }) async {
    if (!Platform.isAndroid) return null;
    final effective = useRoot ? '$_rootPathPrefix$command' : command;
    try {
      final res = await _channel.invokeMethod('runCommand', {
        'command': effective,
        'useRoot': useRoot,
        'fallbackSu': fallbackSu,
      });
      final output = res?.toString() ?? '';
      debugPrint('[ZenFile] runCommand (${useRoot ? "root" : "shizuku"}): "$effective" => "${output.substring(0, output.length.clamp(0, 200))}${output.length > 200 ? "..." : ""}"');
      return output;
    } catch (e) {
      debugPrint('[ZenFile] runCommand exception: $e');
      _logDiag('runCommand failed useRoot=$useRoot fallbackSu=$fallbackSu cmd="$effective" err=$e');
      throw Exception('Execution failed: $e');
    }
  }

  /// 统一诊断日志：debugPrint + 落盘到 /storage/emulated/0/ZenFile/webdav_debug.log。
  /// 排查受限目录（Android/{data,obb}）读写问题时把 WebdavDebugLog.enabled 置 true，
  /// 即可用任意文件管理器取出日志；注释掉右值可恢复静默。
  static void _logDiag(String msg) {
    debugPrint('[ZenFile] $msg');
    WebdavDebugLog.log('[root_shizuku] $msg');
  }

  /// 受限目录下「写」类操作（mkdir / touch / cp）的通用执行器。
  ///
  /// **为什么不能用一条 `| |` 命令串两条路径**（listFiles/du 已踩过同类坑）：
  /// 部分 ROM 的 shell 在 FUSE 路径上创建失败却返回 exit 0，`||` 的回退分支
  /// 永不触发；且 fail-first 分支的 stderr 被 `2>/dev/null` 吞掉，失败原因不可见。
  /// 这正是过去几轮「新建文件/文件夹点了没反应」的直接原因之一。
  ///
  /// 改为 Dart 层逐条尝试并**每次都用 shell stat 复核真实结果**：
  /// ① FUSE 直达路径 `/storage/emulated/0/...`（MT/ES 管理器 Shizuku 方案的可行路径）；
  /// ② 底层 `/data/media/0/...`（小米/华为等 ROM 只放行这一条）。
  /// 全部尝试均未产生目标时抛出带 stderr 的异常 —— **绝不静默返回**，
  /// 否则上层会误判成功、界面不报错但实际什么都没创建。
  static Future<void> _writeWithFallback(
    String fuseTarget,
    String rawTarget,
    bool useRoot,
    String Function(String target) cmdOf,
  ) async {
    String lastOutput = '';
    final candidates = <String>[fuseTarget, if (rawTarget != fuseTarget) rawTarget];
    for (final target in candidates) {
      final cmd = cmdOf(target);
      try {
        lastOutput = (await runCommand(cmd, useRoot: useRoot)) ?? '';
      } catch (e) {
        lastOutput = 'EXCEPTION: $e';
      }
      // 校验始终针对 fuseTarget（用户可见路径）——_exists 内部已做双路径 stat。
      final verified = await _exists(fuseTarget, useRoot: useRoot);
      _logDiag(
        'write try ${target == fuseTarget ? "FUSE" : "RAW"} useRoot=$useRoot: '
        '"$cmd" verified=$verified out=${lastOutput.trim()}',
      );
      if (verified) return;
    }
    throw Exception('Write failed: $fuseTarget | ${lastOutput.trim()}');
  }

  /// 通过标准 Dart IO 访问原始路径（绕开 FUSE 层）。
  /// 适用于部分 ROM 对 `/storage/emulated/0/Android/data` 启用 FUSE 限制、
  /// 但对 `/data/media/0/Android/data` 不限制的场景（如部分未加固的 ROM）。
  /// 若原始路径仍被 FUSE 拦截或 SELinux 限制，返回 null。
  static Future<List<FileItemModel>?> listViaRawPath(String path,
      {bool showHiddenFiles = false}) async {
    if (!Platform.isAndroid) return null;
    final rawPath = _toFuseBypassPath(path);
    debugPrint('[ZenFile] listViaRawPath: rawPath=$rawPath');
    try {
      final dir = Directory(rawPath);
      final exists = await dir.exists();
      debugPrint('[ZenFile] listViaRawPath: exists=$exists');
      if (!exists) return null;
      final entities = await dir.list().toList();
      debugPrint('[ZenFile] listViaRawPath: got ${entities.length} entities');
      final items = <FileItemModel>[];
      for (final entity in entities) {
        final name = p.basename(entity.path);
        if (!showHiddenFiles && name.startsWith('.') && name != '.' && name != '..') continue;
        final isDir = await FileSystemEntity.type(entity.path) == FileSystemEntityType.directory;
        final stat = await entity.stat();
        items.add(FileItemModel.fromCustom(
          path: _fromFuseBypassPath(entity.path),
          isDirectory: isDir,
          size: stat.size,
          modified: stat.modified,
        ));
      }
      return items;
    } catch (e) {
      debugPrint('[ZenFile] listViaRawPath failed for $rawPath: $e');
      return null;
    }
  }

  /// shell 侧 stat 的格式串：类型|字节数|修改时间(秒)|路径。
  static const String _statFormat = '%F|%s|%Y|%n';

  static Future<List<FileItemModel>> listFiles(String path, {required bool useRoot, bool showHiddenFiles = false}) async {
    String normalizedPath = _normalize(path);

    final cleanPath = (normalizedPath == '/' || !normalizedPath.endsWith('/'))
        ? normalizedPath
        : normalizedPath.substring(0, normalizedPath.length - 1);

    // 根目录用「空前缀」表示（旧实现 `for f in "$p"/*` 拼出来才是 `/*`）。
    // ⚠️ 空前缀只在本函数的候选集里有意义：真正拼 find/ls 命令时由
    // _listViaShell → shellListDirArg 还原成 `/`，否则命令会带着空参数报错、
    // 让系统根目录恒为空（过去 root/Shizuku 授权后打开「系统根目录」空白的原因）。
    final searchPrefix = cleanPath == '/' ? '' : cleanPath;
    // FUSE 绕过（见 _toFuseBypassPath 注释）。ES 文件管理器做法一致：
    // 对 Android/data 用底层 ext4 路径执行 glob/stat。
    final bypassPrefix = _toFuseBypassPath(searchPrefix);

    // 双路径尝试：小米/华为等 ROM 的 FUSE 层拦截 shell 访问 /storage 直达
    // 路径、放行底层 /data/media/0；vivo 等定制 ROM 的 SELinux 恰好相反——
    // 拦截 shell 访问 /data/media/0、放行 FUSE 直达路径。先底层后 FUSE，
    // 任一条路径能列出内容即采用。
    //
    // ⚠️ 每条路径各自 try/catch：单条路径抛异常时**不再中断整个列目录**，
    // 否则另一条路径根本没机会试，调用方只能拿到一个空结果（过去正是如此）。
    final candidates = <String>[
      bypassPrefix,
      if (bypassPrefix != searchPrefix) searchPrefix,
    ];
    for (final dir in candidates) {
      try {
        final items = await _listViaShell(dir, useRoot: useRoot, showHiddenFiles: showHiddenFiles);
        if (items.isNotEmpty) return items;
      } catch (e) {
        debugPrint('[ZenFile] listFiles path failed ($dir): $e');
        _logDiag('listFiles path failed dir=$dir useRoot=$useRoot: $e');
      }
    }
    return [];
  }

  /// 把解析出的纯数据条目转成 FileItemModel。
  static List<FileItemModel> _toModels(List<RestrictedDirEntry> entries) => entries
      .map((e) => FileItemModel.fromCustom(
            path: e.path,
            isDirectory: e.isDirectory,
            size: e.size,
            modified: e.modified,
          ))
      .toList();

  /// 诊断用的输出摘要（单行、限长）。
  static String _snippet(String text) {
    final t = text.trim().replaceAll('\n', ' \\n ');
    return t.length <= 160 ? t : '${t.substring(0, 160)}...';
  }

  /// 列目录的 shell 实现。
  ///
  /// **Shizuku 分支保持历史行为不变**（adbd 环境 PATH 正常，find/stat 直接可用；
  /// 用户侧已验证该链路工作正常，不做任何改动）。
  ///
  /// **root 分支改为多策略回退**。root 的 `su -c` 与 Shizuku 的 `sh -c` 环境
  /// 不同（PATH、mount namespace、su 语法各家 ROM 不一），任何一处不满足，旧实现
  /// 都会因为 `2>/dev/null` 把错误吞掉而**静默返回空**——界面只显示「目录是空的」，
  /// 既看不出是权限、路径不可达还是命令没找到，也无法自愈。现在：
  ///   ① 用裸命令名（PATH 已在 [runCommand] 统一补全，比写死 `/system/bin/find`
  ///      覆盖更广：有的 ROM 里 find 在 /system/xbin）；
  ///   ② 不再用 `2>/dev/null`，stderr 一并取回，由解析器严格过滤非数据行——
  ///      失败原因进入诊断日志，不再无声无息；
  ///   ③ 打开 `fallbackSu`，让原生侧换着形式试 su；
  ///   ④ find `-exec +` 不行 → `find | while read + stat` → `ls -la`，逐级降级。
  static Future<List<FileItemModel>> _listViaShell(String cmdPrefix, {required bool useRoot, required bool showHiddenFiles}) async {
    // ⚠️ 系统根目录（`/`）在 listFiles 里传下来的是**空前缀**（历史写法 `for f in /*`
    // 需要它），但 find/ls 必须拿到真正的以 `/` 开头（或非空）的目录参数——
    // `find "" -maxdepth 1` / `ls -la ""` 会直接报错，导致根目录恒为空
    // （见 restricted_dir_parser.shellListDirArg 的注释）。这里统一还原。
    final dir = shellListDirArg(cmdPrefix);

    if (!useRoot) {
      // ── Shizuku：与历史实现完全一致，不做改动 ──
      final cmd = 'find "$dir" -maxdepth 1 -mindepth 1 '
          '-exec stat -L -c "$_statFormat" {} + 2>/dev/null';
      debugPrint('[ZenFile] Shell command (shizuku): $cmd');
      final output = await runCommand(cmd, useRoot: false);
      debugPrint('[ZenFile] listFiles: got ${output?.length ?? 0} chars, ${output?.split('\n').length ?? 0} lines');
      return _toModels(parseStatPipeLines(output ?? '', showHiddenFiles: showHiddenFiles));
    }

    // ── root：多策略 ──
    // 说明：`-exec stat ... {} +` 把整目录分批交给同一个 stat 进程（进程数从 O(n)
    // 降到个位数），是首选；`| while read` 版本多 fork 一个循环 shell，仅在 find
    // 不支持 `-exec +` 的 ROM 上兜底；`ls -la` 只在 find 完全不可用时使用。
    final strategies = <(String, String Function(String))>[
      (
        'find+stat',
        (dir) => 'find "$dir" -maxdepth 1 -mindepth 1 '
            '-exec stat -L -c "$_statFormat" {} + 2>&1',
      ),
      (
        'find-pipe-stat',
        (dir) => 'find "$dir" -maxdepth 1 -mindepth 1 2>&1 '
            '| while IFS= read -r f; do stat -L -c "$_statFormat" "\$f" 2>&1; done',
      ),
      (
        'ls-la',
        (dir) => 'ls -la "$dir" 2>&1',
      ),
    ];

    final notes = <String>[];
    for (final (name, build) in strategies) {
      final cmd = build(dir);
      try {
        final output = await runCommand(cmd, useRoot: true, fallbackSu: true);
        final text = output ?? '';
        final entries = name == 'ls-la'
            ? parseLsLongOutput(text, dir: dir, showHiddenFiles: showHiddenFiles)
            : parseStatPipeLines(text, showHiddenFiles: showHiddenFiles);
        if (entries.isNotEmpty) {
          debugPrint('[ZenFile] listFiles(root) ok via $name: ${entries.length} items');
          if (name != 'find+stat') {
            _logDiag('listFiles(root) 降级到策略 $name 才成功: dir=$dir, ${entries.length} 项');
          }
          return _toModels(entries);
        }
        notes.add('$name=>${_snippet(text)}');
      } catch (e) {
        notes.add('$name=>EXCEPTION: $e');
      }
    }

    // 全部策略都没拿到条目：把每步的原始输出记进诊断日志（避免再出现
    // 「就是空的，查不到原因」）。仅在受限目录且结果为空时触发。
    _logDiag('listFiles(root) 全部策略为空: dir=$dir; ${notes.join(" || ")}');
    return [];
  }

  static Future<void> deleteItem(String path, {required bool useRoot}) async {
    final fuse = _normalize(path);
    final raw = _toFuseBypassPath(fuse);
    // FUSE 直接路径优先、底层路径回退：底层 ext4 上其它应用的
    // Android/{data,obb} 文件/目录属主为对应 app uid（0660/0771），
    // shell（Shizuku uid 2000）无权限，只能经 FUSE 直接子路径操作；
    // root 两条路径均可用。
    final cmd = raw != fuse
        ? 'rm -rf "$fuse" 2>/dev/null || rm -rf "$raw"'
        : 'rm -rf "$fuse"';
    await runCommand(cmd, useRoot: useRoot);
    // 结果校验：删除后源应不存在。剪切（cut）等场景若静默失败会导致
    // 「移动变成复制一份」——必须让调用方感知失败。
    if (await _exists(path, useRoot: useRoot)) {
      throw Exception('Delete failed (source still exists): $path');
    }
  }

  /// stat 单个路径（受限路径走底层绕过 + FUSE 回退）。返回 null 表示不存在。
  /// 复制/上传链路用于替代 Dart IO 的 typeSync/lengthSync——Android 11+
  /// FUSE 层使 app 进程对其它应用的 Android/{data,obb} 文件不可见，
  /// 只能经 shell/root 在 /data/media/0 底层路径访问。
  /// 底层路径与 FUSE 直达路径双试：小米/华为等 ROM 底层放行、FUSE 拦 shell；
  /// vivo 等 ROM 恰好相反（拦底层、放行 FUSE 直达）。
  static Future<FileItemModel?> statItem(String path, {required bool useRoot}) async {
    final fuse = _normalize(path);
    final raw = _toFuseBypassPath(fuse);
    final String cmd;
    if (raw != fuse) {
      cmd = 'stat -L -c "%F|%s|%Y|%n" "$raw" 2>/dev/null || stat -L -c "%F|%s|%Y|%n" "$fuse" 2>/dev/null || stat -c "%F|%s|%Y|%n" "$fuse" 2>/dev/null';
    } else {
      cmd = 'stat -L -c "%F|%s|%Y|%n" "$fuse" 2>/dev/null || stat -c "%F|%s|%Y|%n" "$fuse" 2>/dev/null';
    }
    final output = await runCommand(cmd, useRoot: useRoot);
    final line = output?.trim();
    if (line == null || line.isEmpty) return null;
    final parts = line.split('|');
    if (parts.length < 4) return null;
    final isDir = parts[0].toLowerCase().contains('directory');
    return FileItemModel.fromCustom(
      path: _fromFuseBypassPath(parts.sublist(3).join('|')),
      isDirectory: isDir,
      size: int.tryParse(parts[1]) ?? 0,
      modified: DateTime.fromMillisecondsSinceEpoch((int.tryParse(parts[2]) ?? 0) * 1000),
    );
  }

  static Future<void> renameItem(String oldPath, String newName, {required bool useRoot}) async {
    final fuseOld = _normalize(oldPath);
    final rawOld = _toFuseBypassPath(fuseOld);
    final fuseNew = _normalize(p.join(p.dirname(oldPath), newName));
    final rawNew = _toFuseBypassPath(fuseNew);

    // 仅大小写不同的改名（a.jpg → a.JPG）：FUSE 大小写不敏感，直接 mv 会被当作
    // 同名改名静默忽略（返回成功但目录项大小写不变），且下方 _exists 校验同样
    // 是大小写不敏感的、查不出来。改走「临时名 → 目标名」两步 mv 强制落盘。
    final isCaseOnly = fuseNew != fuseOld &&
        fuseNew.toLowerCase() == fuseOld.toLowerCase();
    if (isCaseOnly) {
      final dir = p.dirname(fuseOld);
      final fuseTmp =
          p.join(dir, '.zenfile_case_${DateTime.now().millisecondsSinceEpoch}.tmp');
      final rawTmp = _toFuseBypassPath(fuseTmp);
      // 第一步：原 → 临时（同样 FUSE 优先、底层回退）
      if (rawOld != fuseOld || rawTmp != fuseTmp) {
        await runCommand('mv "$fuseOld" "$fuseTmp" 2>/dev/null || mv "$rawOld" "$rawTmp"', useRoot: useRoot);
      } else {
        await runCommand('mv "$fuseOld" "$fuseTmp"', useRoot: useRoot);
      }
      if (!await _exists(fuseTmp, useRoot: useRoot)) {
        throw Exception('Rename failed (step1): $oldPath');
      }
      // 第二步：临时 → 目标；失败回滚到原名，不留 .tmp 残留
      try {
        if (rawNew != fuseNew || rawTmp != fuseTmp) {
          await runCommand('mv "$fuseTmp" "$fuseNew" 2>/dev/null || mv "$rawTmp" "$rawNew"', useRoot: useRoot);
        } else {
          await runCommand('mv "$fuseTmp" "$fuseNew"', useRoot: useRoot);
        }
      } catch (e) {
        try {
          await runCommand('mv "$fuseTmp" "$fuseOld" 2>/dev/null || true', useRoot: useRoot);
        } catch (_) {}
        rethrow;
      }
      // 大小写精确校验：_exists 大小写不敏感，必须 ls + grep -Fx 逐字匹配目标名
      final lsOut = await runCommand(
            'ls -1 "$dir" | grep -Fx -- "$newName"',
            useRoot: useRoot,
          ) ??
          '';
      if (lsOut.trim() != newName) {
        throw Exception('Rename failed (case not applied): $oldPath -> $newName');
      }
      return;
    }

    // 与 moveItem/deleteItem/copyItem 一致的「FUSE 直接路径优先、底层路径回退」
    // 双跳：底层 /data/media/0 上其它应用的 Android/{data,obb} 文件属主为对应
    // app uid，shell（Shizuku uid 2000）无权限；FUSE 直接路径对 shell 可写
    // （其它文件管理器经 FUSE 路径可正常重命名 Android/data 内文件）。
    final String cmd;
    if (rawOld != fuseOld || rawNew != fuseNew) {
      cmd = 'mv "$fuseOld" "$fuseNew" 2>/dev/null || mv "$rawOld" "$rawNew"';
    } else {
      cmd = 'mv "$fuseOld" "$fuseNew"';
    }
    await runCommand(cmd, useRoot: useRoot);
    // 结果校验：重命名后新路径应存在，否则抛出（避免静默无效）。
    if (!await _exists(fuseNew, useRoot: useRoot)) {
      throw Exception('Rename failed: $oldPath -> $newName');
    }
  }

  static Future<void> createFolder(String parentPath, String name, {required bool useRoot}) async {
    final fuseParent = _normalize(parentPath);
    final rawParent = _toFuseBypassPath(fuseParent);
    final fuseTarget = p.join(fuseParent, name);
    final rawTarget = p.join(rawParent, name);
    _logDiag('createFolder parent=$parentPath fuse=$fuseTarget raw=$rawTarget');

    if (isAndroidDataObbRoot(parentPath)) {
      throw Exception(
        'Android/data 或 Android/obb 根目录下不允许直接创建，请进入具体应用目录后再试',
      );
    }

    // ⚠️ 旧实现只对底层 /data/media/0 路径 mkdir —— 与其它应用 Android/{data,obb}
    // 属主为对应 app uid（0771）、shell(uid 2000) 无写权限的现实恰好相反，必然失败
    // 且无结果校验，表现为「点了新建没反应」。改为 FUSE 直达优先 + 底层回退 + 复核。
    //
    // 顺序：先 shell 再 SAF。MT 管理器同为「shell(Shizuku) 直接写 + stat 复核」，
    // 成功则用户完全无感；SAF 需按包名目录逐个授权，放在兜底位可避免
    // 每进一个应用目录就弹一次系统选择器。_writeWithFallback 已用 shell stat
    // 复核结果，shell 假失败会被捕获并落到 SAF，不存在「看似成功实则没建」。
    try {
      await _writeWithFallback(
        fuseTarget,
        rawTarget,
        useRoot,
        (target) => 'mkdir -p "$target" 2>&1',
      );
      return;
    } catch (e) {
      _logDiag('createFolder shell failed: $e');
    }
    // shell 两条路径都写不动：纯 Shizuku 受限目录退到 SAF（需已授权目录树）。
    if (!useRoot && _isRestrictedAndroidPath(parentPath)) {
      final ok = await SafAndroidDataService.createFolderViaSaf(
        parentPath,
        name,
        isObb: _isObbSubPath(parentPath),
      );
      if (ok) {
        _logDiag('createFolder via SAF ok: $fuseTarget');
        return;
      }
      _logDiag('createFolder via SAF failed too: $fuseTarget');
    }
    throw Exception(
      '创建文件夹失败，已尝试 shell(FUSE/底层) 与 SAF 均不可写：$fuseTarget',
    );
  }

  static Future<void> createFile(String parentPath, String name, {required bool useRoot}) async {
    final fuseParent = _normalize(parentPath);
    final rawParent = _toFuseBypassPath(fuseParent);
    final fuseTarget = p.join(fuseParent, name);
    final rawTarget = p.join(rawParent, name);
    _logDiag('createFile parent=$parentPath fuse=$fuseTarget raw=$rawTarget');

    if (isAndroidDataObbRoot(parentPath)) {
      throw Exception(
        'Android/data 或 Android/obb 根目录下不允许直接创建，请进入具体应用目录后再试',
      );
    }

    // 同 createFolder：shell(FUSE 优先 + 底层回退 + stat 复核) → SAF 兜底。
    try {
      await _writeWithFallback(
        fuseTarget,
        rawTarget,
        useRoot,
        (target) => 'mkdir -p "${p.dirname(target)}" 2>/dev/null; touch "$target" 2>&1',
      );
      return;
    } catch (e) {
      _logDiag('createFile shell failed: $e');
    }
    if (!useRoot && _isRestrictedAndroidPath(parentPath)) {
      final ok = await SafAndroidDataService.createFileViaSaf(
        parentPath,
        name,
        isObb: _isObbSubPath(parentPath),
      );
      if (ok) {
        _logDiag('createFile via SAF ok: $fuseTarget');
        return;
      }
      _logDiag('createFile via SAF failed too: $fuseTarget');
    }
    throw Exception(
      '新建文件失败，已尝试 shell(FUSE/底层) 与 SAF 均不可写：$fuseTarget',
    );
  }

  /// Android/{data,obb} **根层**。
  /// Android 11+ 连 SAF 都禁止授予这两层（只能授权到其内部的具体包名目录），
  /// 因此任何在这两层直接新建/写入的尝试都注定失败。过去会静默无反应，
  /// 现显式抛错，由 UI 提示用户「请进入具体应用目录后再操作」。
  static bool isAndroidDataObbRoot(String path) {
    final n = path.replaceAll(RegExp(r'/+'), '/').replaceAll(RegExp(r'/+$'), '');
    return n == '/storage/emulated/0/Android/data' ||
        n == '/storage/emulated/0/Android/obb';
  }

  /// 是否位于 Android/obb 之下（含 obb 根本身，旧的 contains('/Android/obb/')
  /// 判定会漏掉 obb 根目录，导致 obb 根误用 data 的 SAF 树）。
  static bool _isObbSubPath(String path) {
    final n = path.replaceAll(RegExp(r'/+'), '/');
    return n.contains('/Android/obb/') || n.endsWith('/Android/obb');
  }

  /// 是否为 FUSE 受限区（其它应用的 Android/data、Android/obb 文件）。
  /// 镜像 file_manager_provider._isRestrictedAndroidPath：自身包名目录可读写，不在此列。
  static bool _isRestrictedAndroidPath(String path) {
    const prefix = '/storage/emulated/0/Android/';
    if (!path.startsWith(prefix)) return false;
    final sub = path.substring(prefix.length).replaceAll(RegExp(r'/+'), '');
    if (sub != 'data' && !sub.startsWith('data/') && sub != 'obb' && !sub.startsWith('obb/')) {
      return false;
    }
    // ⚠️ 必须与 applicationId 一致（v2.0.0 起为 zenfile2）。
    return !sub.startsWith('data/com.sequl.zenfile2') && !sub.startsWith('obb/com.sequl.zenfile2');
  }

  /// 复制文件/目录。
  ///
  /// **纯 Shizuku（无 root）受限源（其它应用的 Android/{data,obb}）**：shell 物理上
  /// 读不到文件内容——FUSE 仅开放元数据（cp 写出 0 字节且退出码 0），底层
  /// /data/media/0 属主 0660（app uid）shell 亦无读权限；且部分 ROM 上 `stat`
  /// 源会返回 null，使「大小一致性校验」整段被跳过，最终静默留下 0 字节文件。
  /// 因此此类场景**直接走 SAF（ContentResolver）读取真实字节**，跳过注定失败的
  /// shell 尝试；SAF 不可用（未授权/异常）才回退 shell 作最后兜底。
  ///
  /// **root / 普通路径**：维持原「底层 /data/media/0 优先、FUSE 直达回退」双跳，
  /// 复制后校验目标存在且（文件）大小一致，不一致自动重试，仍失败抛异常。
  static Future<void> copyItem(String srcPath, String destPath, {required bool useRoot}) async {
    final fuseSrc = _normalize(srcPath);
    final rawSrc = _toFuseBypassPath(fuseSrc);
    final fuseDest = _normalize(destPath);
    final rawDest = _toFuseBypassPath(fuseDest);
    final isObb = rawSrc.contains('/obb/');
    final restrictedShizuku = !useRoot && _isRestrictedAndroidPath(srcPath);

    // 纯 Shizuku 受限源：shell 读不到内容，直接 SAF 读取真实字节。
    if (restrictedShizuku) {
      if (await SafAndroidDataService.copyFileViaSaf(srcPath, destPath, isObb: isObb)) return;
      // SAF 失败（未授权/不支持）再尝试 shell 作为最后兜底（通常仍 0 字节或失败）。
    }

    final String cmd;
    if (rawSrc != fuseSrc || rawDest != fuseDest) {
      // 底层 /data/media/0 优先（root / 多数 ROM 底层可读真实内容），FUSE 直达兜底。
      cmd = 'cp -r "$rawSrc" "$rawDest" 2>/dev/null || cp -r "$fuseSrc" "$fuseDest"';
    } else {
      cmd = 'cp -r "$fuseSrc" "$fuseDest"';
    }
    await runCommand(cmd, useRoot: useRoot);
    if (!await _exists(destPath, useRoot: useRoot)) {
      // shell 完全失败：纯 Shizuku 受限场景经 SAF（已授权目录树）读取真实内容写出。
      if (await SafAndroidDataService.copyFileViaSaf(srcPath, destPath, isObb: isObb)) return;
      throw Exception('Copy failed: $srcPath -> $destPath');
    }
    // 大小一致性校验（仅文件，目录元数据无意义）
    final srcStat = await statItem(srcPath, useRoot: useRoot);
    if (srcStat != null && !srcStat.isDirectory) {
      final destStat = await statItem(destPath, useRoot: useRoot);
      if (destStat == null || destStat.size != srcStat.size) {
        debugPrint('[ZenFile] copyItem size mismatch $srcPath (${srcStat.size}) -> $destPath (${destStat?.size})');
        if (rawSrc != fuseSrc || rawDest != fuseDest) {
          // 删除不完整目标，改用 FUSE 直达路径重试（底层不可读时）
          await runCommand('rm -rf "$fuseDest" 2>/dev/null || rm -rf "$rawDest"', useRoot: useRoot);
          await runCommand('cp -r "$fuseSrc" "$fuseDest"', useRoot: useRoot);
          final retryStat = await statItem(destPath, useRoot: useRoot);
          if (retryStat != null && retryStat.size == srcStat.size) return;
        }
        // shell 两条路径均读不到内容（纯 Shizuku）：经 SAF 读取真实内容写出。
        if (await SafAndroidDataService.copyFileViaSaf(srcPath, destPath, isObb: isObb)) return;
        throw Exception('Copy size mismatch: $srcPath -> $destPath');
      }
    }
  }

  /// shell stat 检测路径是否存在（受限路径底层/FUSE 双试，用于复制等结果校验）。
  static Future<bool> _exists(String path, {required bool useRoot}) async {
    final fuse = _normalize(path);
    final raw = _toFuseBypassPath(fuse);
    final cmd = raw != fuse
        ? 'stat -c "%n" "$raw" 2>/dev/null || stat -c "%n" "$fuse" 2>/dev/null'
        : 'stat -c "%n" "$fuse" 2>/dev/null';
    try {
      final out = await runCommand(cmd, useRoot: useRoot);
      return out != null && out.trim().isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  static Future<void> moveItem(String srcPath, String destPath, {required bool useRoot}) async {
    final fuseSrc = _normalize(srcPath);
    final rawSrc = _toFuseBypassPath(fuseSrc);
    final fuseDest = _normalize(destPath);
    final rawDest = _toFuseBypassPath(fuseDest);
    // 与 copyItem 一致的双跳策略（见其注释）。
    final String cmd;
    if (rawSrc != fuseSrc || rawDest != fuseDest) {
      cmd = 'mv "$fuseSrc" "$fuseDest" 2>/dev/null || mv "$rawSrc" "$rawDest"';
    } else {
      cmd = 'mv "$fuseSrc" "$fuseDest"';
    }
    await runCommand(cmd, useRoot: useRoot);
    // 结果校验：mv 原子成功时源消失、目标存在；跨文件系统（EXDEV）或
    // 权限失败时源仍存在 → 抛异常，由调用方决定回退 copy+delete。
    final srcGone = !await _exists(srcPath, useRoot: useRoot);
    final destExists = await _exists(destPath, useRoot: useRoot);
    if (!srcGone || !destExists) {
      throw Exception('Move failed: $srcPath -> $destPath');
    }
  }

  /// 通过反射访问 StorageManager 内部 API 获取存储卷信息（ES 文件管理器方案）。
  /// 返回卷列表，每个卷包含 path、isEmulated 等字段。
  /// 用于检测主存储卷的实际挂载点，以绕过部分 ROM 的 FUSE 限制。
  static Future<List<Map<String, dynamic>>> getStorageVolumes() async {
    if (!Platform.isAndroid) return [];
    try {
      final res = await _channel.invokeMethod<List<dynamic>>('getStorageVolumes');
      if (res == null) return [];
      return res.map((m) => Map<String, dynamic>.from(m as Map)).toList();
    } catch (_) {
      return [];
    }
  }

  /// 获取主存储卷（emulated）的底层路径。
  /// 若反射调用成功则返回其 path；否则返回 null，由调用方回退到 /storage/emulated/0。
  static Future<String?> getPrimaryStoragePath() async {
    final volumes = await getStorageVolumes();
    for (final vol in volumes) {
      if (vol['isEmulated'] == true || vol['isEmulated'] == true) {
        final path = vol['path'] as String?;
        if (path != null && path.isNotEmpty) return path;
      }
    }
    // Fallback: 尝试从卷列表中取第一条有 path 的卷
    for (final vol in volumes) {
      final path = vol['path'] as String?;
      if (path != null && path.isNotEmpty) return path;
    }
    return null;
  }

  /// 直接用 Java File API 在 app 进程内访问原始路径（绕开 shell 进程）。
  /// 适用于 shell 进程被 SELinux 限制但 app 进程可以访问的场景。
  static Future<List<FileItemModel>?> listRawPath(String path,
      {bool showHiddenFiles = false}) async {
    if (!Platform.isAndroid) return null;
    final rawPath = _toFuseBypassPath(path);
    debugPrint('[ZenFile] listRawPath (Kotlin): rawPath=$rawPath');
    try {
      final res = await _channel.invokeMethod<List<dynamic>>('listRawPath', {'path': rawPath});
      if (res == null) return null;
      final items = <FileItemModel>[];
      for (final entry in res) {
        final map = Map<String, dynamic>.from(entry as Map);
        final name = map['name'] as String;
        if (!showHiddenFiles && name.startsWith('.') && name != '.' && name != '..') continue;
        items.add(FileItemModel.fromCustom(
          path: _fromFuseBypassPath(p.join(rawPath, name)),
          isDirectory: map['isDirectory'] as bool? ?? false,
          size: (map['length'] as num?)?.toInt() ?? 0,
          modified: DateTime.fromMillisecondsSinceEpoch((map['lastModified'] as num?)?.toInt() ?? 0),
        ));
      }
      debugPrint('[ZenFile] listRawPath (Kotlin): got ${items.length} items');
      return items;
    } catch (e) {
      debugPrint('[ZenFile] listRawPath (Kotlin) failed: $e');
      return null;
    }
  }

  /// 统计目录内所有文件的总字节数（递归）。受限路径（Android/data、Android/obb 等）
  /// 下 Dart IO 会被 FUSE 层拦截返回 0，必须经 shell du 在底层 /data/media/0 路径
  /// （或 FUSE 直达路径）上统计，与 listFiles 的访问方式一致。
  /// 返回 null 表示计算失败（由调用方回退 Dart IO）。
  ///
  /// 注意：不能在 shell 命令里用 `||` 做双路径回退——awk/cut 管道总是 exit 0，
  /// 在 vivo 等 ROM 上底层路径被 SELinux 拦截返回「假 0」（exit 0）时会吞掉回退，
  /// 导致 FUSE 直达路径永不执行（表现为文件夹大小恒为 0 B）。
  /// 因此改为 Dart 层双路径：底层结果无效（0/失败）时再试 FUSE 直达路径。
  static Future<int?> getFolderSizeShell(String path, {required bool useRoot}) async {
    final fuse = _normalize(path);
    final raw = _toFuseBypassPath(fuse);

    Future<int?> runDu(String p) async {
      // du -sb：递归统计字节数，输出 "<bytes>\t<path>"，cut -f1 取字节列。
      final cmd = 'du -sb "$p" 2>/dev/null | cut -f1';
      try {
        final output = await runCommand(cmd, useRoot: useRoot);
        final trimmed = output?.trim();
        if (trimmed == null || trimmed.isEmpty) return null;
        // 取最后一个非空行（避免路径/环境噪音干扰）
        for (final line in trimmed.split('\n').reversed) {
          if (line.trim().isEmpty) continue;
          return int.tryParse(line.trim());
        }
        return null;
      } catch (_) {
        return null;
      }
    }

    // 底层 /data/media/0 优先；若结果为 0/失败且存在 FUSE 直达路径，则回退
    // FUSE 路径（小米/华为拦 FUSE 放底层、vivo 相反，需双试）。
    final rawSize = await runDu(raw);
    if (rawSize != null && rawSize > 0) return rawSize;
    if (raw != fuse) {
      final fuseSize = await runDu(fuse);
      if (fuseSize != null && fuseSize > 0) return fuseSize;
      // 两层都 0/失败：返回底层结果（空目录为 0，权限假 0 也无法再突破）
      return rawSize;
    }
    return rawSize;
  }

  /// 静默安装单个 APK（root 或 shizuku 执行 pm install）。
  /// 返回 true 表示安装成功，false 表示失败。
  static Future<bool> installApkSilently(String path, {required bool useRoot}) async {
    if (!Platform.isAndroid) return false;
    try {
      // 优先 pm install -r（不带 -d 降级标志）。-d 需要 INSTALL_ALLOW_DOWNGRADE
      // 权限，部分 ROM 的 shell 不具备，会直接报"权限不足"导致静默安装失败。
      // 仅在明确是降级安装（报错含 downgrade）时，再补 -d 重试一次。
      var output = await runCommand('pm install -r "$path" 2>&1', useRoot: useRoot);
      if (output != null && output.toLowerCase().contains('success')) return true;
      if (output != null && output.toLowerCase().contains('downgrade')) {
        output = await runCommand('pm install -r -d "$path" 2>&1', useRoot: useRoot);
        return output != null && output.toLowerCase().contains('success');
      }
      return false;
    } catch (e) {
      debugPrint('[ZenFile] installApkSilently failed: $e');
      return false;
    }
  }

  /// 静默安装多个 APK split（root 或 shizuku）。
  /// 使用 pm install-create / install-write / install-commit 会话机制。
  static Future<bool> installSplitApksSilently(List<String> paths, {required bool useRoot}) async {
    if (!Platform.isAndroid || paths.isEmpty) return false;
    if (paths.length == 1) {
      return installApkSilently(paths.first, useRoot: useRoot);
    }
    try {
      // 1. 创建安装会话
      final createOut = await runCommand('pm install-create -r 2>&1', useRoot: useRoot);
      if (createOut == null || !createOut.contains('[')) return false;
      final match = RegExp(r'\[(\d+)\]').firstMatch(createOut);
      if (match == null) return false;
      final sessionId = match.group(1)!;

      // 2. 逐个写入 APK
      // 语法：pm install-write [-S BYTES] SESSION_ID SPLIT_NAME PATH
      // SPLIT_NAME 用真实文件名（如 base.apk / config.arm64_v8a.apk），
      // -S 传该文件实际字节大小（可选，但显式传入更可靠）。
      for (final apkPath in paths) {
        int sizeBytes = 0;
        try {
          final f = await File(apkPath).length();
          sizeBytes = f;
        } catch (_) {}
        final splitName = p.basename(apkPath);
        final writeOut = await runCommand(
          'pm install-write -S $sizeBytes $sessionId "$splitName" "$apkPath" 2>&1',
          useRoot: useRoot,
        );
        if (writeOut == null || !writeOut.toLowerCase().contains('success')) {
          await runCommand('pm install-abandon $sessionId 2>&1', useRoot: useRoot);
          return false;
        }
      }

      // 3. 提交安装
      final commitOut = await runCommand('pm install-commit $sessionId 2>&1', useRoot: useRoot);
      return commitOut != null && commitOut.toLowerCase().contains('success');
    } catch (e) {
      debugPrint('[ZenFile] installSplitApksSilently failed: $e');
      return false;
    }
  }
}

/// SAF (Storage Access Framework) 服务：用于在 Shizuku/root 不可用时
/// 通过系统文件选择器授权访问 Android/data 等受限目录。
/// 这是 Android 11+ 官方推荐的访问方式，无需 Shizuku 或 root。
class SafAndroidDataService {
  static const MethodChannel _channel = MethodChannel('com.sequl.zenfile/saf');

  /// 已授权的 Android/data SAF tree URI（持久化存储的 key）
  static const String _prefKeyAndroidDataUri = 'saf_android_data_tree_uri';
  static const String _prefKeyAndroidObbUri = 'saf_android_obb_tree_uri';

  /// 请求 SAF 授权访问 Android/data（系统文件选择器直接定位到该目录）。
  /// 返回授权的 tree URI 字符串，用户取消返回 null。
  static Future<String?> requestAndroidDataAccess() async {
    if (!Platform.isAndroid) return null;
    try {
      final result = await _channel.invokeMethod<Map<dynamic, dynamic>>(
        'requestSafWithInitialUri',
        {'initialDocId': 'primary:Android/data'},
      );
      if (result == null) return null;
      final uri = result['uri'] as String?;
      if (uri != null) {
        await _saveTreeUri(_prefKeyAndroidDataUri, uri);
        // 同时按「用户实际选择的树根」归档到按包名粒度的存储。
        // 一个 tree 只覆盖它自己的包名目录，必须逐个归档，后续 _treeUriForRel
        // 才能精确命中；否则每次进新包名目录都会重复弹一次选择器。
        final actual = _treeRootDocId(uri);
        if (actual != null) {
          final prefs = await SharedPreferences.getInstance();
          await prefs.setString('$_prefTreePrefix$actual', uri);
        }
        debugPrint('[ZenFile] SAF Android/data authorized: $uri');
      }
      return uri;
    } catch (e) {
      debugPrint('[ZenFile] SAF request failed: $e');
      return null;
    }
  }

  /// 请求 SAF 授权访问 Android/obb。
  static Future<String?> requestAndroidObbAccess() async {
    if (!Platform.isAndroid) return null;
    try {
      final result = await _channel.invokeMethod<Map<dynamic, dynamic>>(
        'requestSafWithInitialUri',
        {'initialDocId': 'primary:Android/obb'},
      );
      if (result == null) return null;
      final uri = result['uri'] as String?;
      if (uri != null) {
        await _saveTreeUri(_prefKeyAndroidObbUri, uri);
        // 同 [requestAndroidDataAccess]：按实际树根归档，避免重复授权。
        final actual = _treeRootDocId(uri);
        if (actual != null) {
          final prefs = await SharedPreferences.getInstance();
          await prefs.setString('$_prefTreePrefix$actual', uri);
        }
      }
      return uri;
    } catch (e) {
      debugPrint('[ZenFile] SAF obb request failed: $e');
      return null;
    }
  }

  /// 获取已存储的 Android/data SAF tree URI。
  ///
  /// ⚠️ 兼容语义：历史上此处读写的是「一整个 Android/data 根」的 tree URI，但
  /// Android 11+ 的 ACTION_OPEN_DOCUMENT_TREE **禁止授予 Android/data 根目录**，
  /// 只能授予到『具体包名目录』这一层——因此不存在一个能覆盖所有包名的 tree。
  /// 现改为返回已授权集合中第一个 data 树的 URI，仅供「是否授权过」的判断使用；
  /// 真正的读/写操作必须走 [_treeUriForRel] 按目标包名精确取树。
  static Future<String?> getAndroidDataTreeUri() async {
    for (final e in (await _loadTreeMap()).entries) {
      if (e.key.startsWith('Android/data/')) return e.value;
    }
    return null;
  }

  /// 获取已存储的 Android/obb SAF tree URI（语义同 [getAndroidDataTreeUri]）。
  static Future<String?> getAndroidObbTreeUri() async {
    for (final e in (await _loadTreeMap()).entries) {
      if (e.key.startsWith('Android/obb/')) return e.value;
    }
    return null;
  }

  /// 检查是否已有 Android/data 的 SAF 授权。
  static Future<bool> hasAndroidDataAccess() async {
    final uri = await getAndroidDataTreeUri();
    return uri != null && uri.isNotEmpty;
  }

  // ───────────────────────── SAF 按包名粒度的树管理 ─────────────────────────

  /// 已授权树归档：key=树根相对路径（如 `Android/data/com.tencent.mm`），value=treeUri。
  static const String _prefTreePrefix = 'saf_tree_';

  static Future<Map<String, String>> _loadTreeMap() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final map = <String, String>{};
      for (final key in prefs.getKeys()) {
        if (!key.startsWith(_prefTreePrefix)) continue;
        final uri = prefs.getString(key);
        if (uri != null && uri.isNotEmpty) {
          map[key.substring(_prefTreePrefix.length)] = uri;
        }
      }
      return map;
    } catch (_) {
      return {};
    }
  }

  /// 本地绝对路径 → 相对 `/storage/emulated/0` 的路径。非该前缀则原样返回。
  static String _relFromLocal(String localPath) {
    const root = '/storage/emulated/0/';
    final n = localPath.replaceAll(RegExp(r'/+'), '/');
    return n.startsWith(root) ? n.substring(root.length) : n;
  }

  /// 由 treeUri 反解它实际代表的树根相对路径（去掉 `primary:` 前缀）。
  /// 用于识别「用户实际选了哪个目录」——EXTRA_INITIAL_URI 只是导航起点，
  /// 用户完全可能选到别的目录。
  static String? _treeRootDocId(String treeUri) {
    try {
      final segs = Uri.parse(treeUri).pathSegments;
      if (segs.length >= 2 && segs[0] == 'tree') {
        final docId = segs[1];
        return docId.startsWith('primary:')
            ? docId.substring('primary:'.length)
            : docId;
      }
    } catch (_) {}
    return null;
  }

  /// 解析一个相对路径所属的「可授权树根」。
  /// `Android/data/com.tencent.mm/files/x` → 树根 `Android/data/com.tencent.mm`。
  /// 返回 null 表示该层级不可被 SAF 授权（Android/data 根、Android/obb 根、
  /// 或非 Android 区路径）——这类路径只能靠 root/shizuku shell 写入。
  static String? _treeRootForRel(String rel) {
    final segs = rel.split('/').where((s) => s.isNotEmpty).toList();
    if (segs.length < 3) return null;
    if (segs[0] != 'Android') return null;
    if (segs[1] != 'data' && segs[1] != 'obb') return null;
    return '${segs[0]}/${segs[1]}/${segs[2]}';
  }

  /// 公开入口：确保 [localPath] 所属的 SAF 树已授权（未授权则按需弹一次选择器）。
  /// 返回是否已可用。用于批量操作（复制/压缩）前统一预授权，避免逐文件时反复弹窗。
  static Future<bool> ensureTreeForPath(String localPath) async {
    final rel = _relFromLocal(localPath);
    if (!rel.startsWith('Android/')) return false;
    final uri = await _treeUriForRel(rel);
    return uri != null && uri.isNotEmpty;
  }

  /// 取得（必要时引导用户授权）覆盖 [rel] 的 SAF tree URI；不可用时返回 null。
  ///
  /// 授权粒度固定在**包名目录层**（如 `Android/data/com.tencent.mm`）：这正是
  /// Android 11+ 唯一允许的层级，也是 MT 管理器采用的方案。系统会 EXTRA_INITIAL_URI
  /// 把选择器直接定位到该包名目录，用户只需点「使用此文件夹」。
  static Future<String?> _treeUriForRel(String rel) async {
    final wanted = _treeRootForRel(rel);
    if (wanted == null) {
      debugPrint('[ZenFile] SAF: rel "$rel" has no authorizable tree root (root-level not grantable)');
      return null;
    }
    final prefs = await SharedPreferences.getInstance();
    final cached = prefs.getString('$_prefTreePrefix$wanted');
    if (cached != null && cached.isNotEmpty) return cached;

    final res = await _channel.invokeMethod<Map<dynamic, dynamic>>(
      'requestSafWithInitialUri',
      {'initialDocId': 'primary:$wanted'},
    );
    final uri = res?['uri'] as String?;
    if (uri == null || uri.isEmpty) return null;
    await prefs.setString('$_prefTreePrefix$wanted', uri);

    // 用户可能没按建议选（选到了别的包名目录）：按实际树根再归档一份，
    // 并检查本次目标是否在树的覆盖范围内，不在则明确失败而不是硬着头皮调用。
    final actual = _treeRootDocId(uri);
    if (actual != null && actual != wanted) {
      await prefs.setString('$_prefTreePrefix$actual', uri);
      final covered = rel == actual || rel.startsWith('$actual/');
      debugPrint('[ZenFile] SAF: granted tree=$actual, need=$wanted, covered=$covered');
      if (!covered) return null;
    }
    return uri;
  }

  /// 使用 SAF 列出 Android/data 目录内容。
  /// 返回 FileItemModel 列表，失败返回 null。
  static Future<List<FileItemModel>?> listAndroidDataViaSAF({
    bool showHiddenFiles = false,
  }) async {
    final treeUri = await getAndroidDataTreeUri();
    if (treeUri == null) return null;
    return _listViaSAF(treeUri, '', showHiddenFiles: showHiddenFiles);
  }

  /// 使用 SAF 列出指定子路径的内容。
  /// [subPath] 相对于 Android/data（或 obb）的子路径，如 "com.tencent.mm" 或 ""。
  /// [isObb] 为 true 时基于 Android/obb 树构建 document ID。
  static Future<List<FileItemModel>?> listAndroidDataSubDirViaSAF(
    String subPath, {
    bool showHiddenFiles = false,
    bool isObb = false,
  }) async {
    final treeUri = isObb ? await getAndroidObbTreeUri() : await getAndroidDataTreeUri();
    if (treeUri == null) return null;

    // 构建子路径的 document URI
    String pathUri = '';
    if (subPath.isNotEmpty) {
      // 将子路径转换为 SAF document ID 格式
      final base = isObb ? 'Android/obb' : 'Android/data';
      final docId = 'primary:$base/$subPath';
      pathUri = 'content://com.android.externalstorage.documents/document/${Uri.encodeComponent(docId)}';
    }

    return _listViaSAF(treeUri, pathUri, showHiddenFiles: showHiddenFiles);
  }

  /// 使用 SAF 列出目录内容。
  static Future<List<FileItemModel>?> _listViaSAF(
    String treeUri,
    String pathUri, {
    bool showHiddenFiles = false,
  }) async {
    try {
      final List<dynamic> result = await _channel.invokeMethod('listDirectory', {
        'rootUri': treeUri,
        'pathUri': pathUri,
      });

      final items = <FileItemModel>[];
      for (final entry in result) {
        final map = Map<String, dynamic>.from(entry as Map);
        final name = map['name'] as String;
        if (!showHiddenFiles && name.startsWith('.') && name != '.' && name != '..') continue;

        // SAF URI 路径转换为本地路径格式
        final safPath = map['path'] as String;
        final localPath = _safUriToLocalPath(safPath);

        items.add(FileItemModel.fromCustom(
          path: localPath,
          isDirectory: map['isDirectory'] as bool? ?? false,
          size: (map['size'] as num?)?.toInt() ?? 0,
          modified: DateTime.fromMillisecondsSinceEpoch((map['modified'] as num?)?.toInt() ?? 0),
        ));
      }
      debugPrint('[ZenFile] SAF listDirectory: got ${items.length} items');
      return items;
    } catch (e) {
      debugPrint('[ZenFile] SAF listDirectory failed: $e');
      return null;
    }
  }

  /// 将 SAF document URI 转换为本地文件路径。
  /// 例如: content://com.android.externalstorage.documents/tree/primary%3AAndroid%2Fdata/document/primary%3AAndroid%2Fdata%2Fcom.tencent.mm
  /// → /storage/emulated/0/Android/data/com.tencent.mm
  static String _safUriToLocalPath(String safUri) {
    try {
      final uri = Uri.parse(safUri);
      final docId = uri.pathSegments.last;
      final decoded = Uri.decodeComponent(docId);
      // decoded 格式: "primary:Android/data/com.tencent.mm"
      if (decoded.startsWith('primary:')) {
        final relPath = decoded.substring('primary:'.length);
        return '/storage/emulated/0/$relPath';
      }
    } catch (_) {}
    return safUri;
  }

  /// 经 SAF（已授权目录树）把受限源文件 [srcLocalPath] 的真实内容读取并写出到
  /// [destLocalPath]。这是纯 Shizuku（无 root）场景下唯一能读到其它应用
  /// Android/{data,obb} 文件内容的路径（shell 在 FUSE 只得到元数据、底层 0660 无权限）。
  /// 复用原生 `downloadFile`：把本地路径映射为 SAF document URI 后由 ContentResolver 读取。
  /// 未授权时自动弹系统选择器请求授权；拒绝或失败返回 false，由调用方决定是否抛异常。
  static Future<bool> copyFileViaSaf(String srcLocalPath, String destLocalPath, {bool isObb = false}) async {
    final rel = _relFromLocal(srcLocalPath);
    if (!rel.startsWith('Android/')) return false;
    final treeUri = await _treeUriForRel(rel);
    if (treeUri == null || treeUri.isEmpty) return false;
    try {
      final docId = 'primary:$rel';
      final docUri = _buildSafDocUri(treeUri, docId);
      final out = await _channel.invokeMethod('downloadFile', {
        'rootUri': treeUri,
        'uri': docUri,
        'localPath': destLocalPath,
      });
      return out == true;
    } catch (e) {
      debugPrint('[ZenFile] SAF copyFileViaSaf failed: $e');
      return false;
    }
  }

  /// 将本地路径映射到 SAF 父目录的 document URI（基于已授权的 Android/data 或 obb 树）。
  /// [parentLocalPath] 形如 /storage/emulated/0/Android/data/com.tencent.mm/Telegram Images。
  /// 返回 {'treeUri':..., 'parentUri':...}；未授权（且用户拒绝授权）则返回 null。
  /// [isObb] 已废弃：树按目标路径自动判定（旧的 contains('/Android/obb/') 会把
  /// obb 根误判成 data）。保留参数仅为兼容既有调用点，不再参与取树。
  static Future<Map<String, String>?> _resolveSafParent(String parentLocalPath, {bool isObb = false}) async {
    final rel = _relFromLocal(parentLocalPath);
    if (!rel.startsWith('Android/')) return null;
    // 按目标包名精确取/请求树：不再依赖「一个全局 Android/data 授权」，
    // 后者在 Android 11+ 上根本无法获得（根层级被系统禁止授权）。
    final treeUri = await _treeUriForRel(rel);
    if (treeUri == null || treeUri.isEmpty) return null;
    final parentUri = _buildSafDocUri(treeUri, 'primary:$rel');
    return {'treeUri': treeUri, 'parentUri': parentUri};
  }

  /// 经 SAF（已授权树）把受限源 [srcLocalPath]（文件或目录，自动递归）真实内容
  /// 下载写出到 [destLocalPath]。用于纯 Shizuku 下压缩位于其它应用 Android/{data,obb}
  /// 内的源文件——dart:io 读不到内容（shell 在 FUSE 只得到元数据、底层 0660 无权限），
  /// 必须走 ContentResolver 读取真实字节。未授权自动请求；失败返回 false。
  static Future<bool> downloadPathViaSaf(String srcLocalPath, String destLocalPath, {bool isObb = false}) async {
    final rel = _relFromLocal(srcLocalPath);
    if (!rel.startsWith('Android/')) return false;
    final treeUri = await _treeUriForRel(rel);
    if (treeUri == null || treeUri.isEmpty) return false;
    final docId = 'primary:$rel';
    final docUri = _buildSafDocUri(treeUri, docId);
    try {
      final out = await _channel.invokeMethod('downloadSaf', {
        'rootUri': treeUri,
        'uri': docUri,
        'localPath': destLocalPath,
      });
      return out == true;
    } catch (e) {
      debugPrint('[ZenFile] SAF downloadPathViaSaf failed: $e');
      return false;
    }
  }

  /// 经 SAF（已授权树）在受限目录下新建文件夹。
  /// 纯 Shizuku（无 root）下 shell(uid 2000) 经 FUSE 无其它应用 Android/{data,obb} 写权限，
  /// 故走 DocumentsContract.createDocument（与 MT 管理器同源方案）。未授权自动请求。
  /// 返回是否成功。
  static Future<bool> createFolderViaSaf(String parentLocalPath, String name, {bool isObb = false}) async {
    final resolved = await _resolveSafParent(parentLocalPath, isObb: isObb);
    if (resolved == null) return false;
    try {
      final result = await _channel.invokeMethod('createDirectory', {
        'rootUri': resolved['treeUri'],
        'parentUri': resolved['parentUri'],
        'name': name,
      });
      return result != null && result.toString().isNotEmpty;
    } catch (e) {
      debugPrint('[ZenFile] SAF createFolderViaSaf failed: $e');
      return false;
    }
  }

  /// 经 SAF 在受限目录下新建空文件（等同于 touch）。其余同 [createFolderViaSaf]。
  static Future<bool> createFileViaSaf(String parentLocalPath, String name, {bool isObb = false}) async {
    final resolved = await _resolveSafParent(parentLocalPath, isObb: isObb);
    if (resolved == null) return false;
    final ext = name.contains('.') ? name.split('.').last.toLowerCase() : '';
    final mime = _safMimeForExt(ext);
    try {
      final result = await _channel.invokeMethod('createDocumentFile', {
        'rootUri': resolved['treeUri'],
        'parentUri': resolved['parentUri'],
        'name': name,
        'mimeType': mime,
      });
      return result != null && result.toString().isNotEmpty;
    } catch (e) {
      debugPrint('[ZenFile] SAF createFileViaSaf failed: $e');
      return false;
    }
  }

  /// 经 SAF 把本地文件上传（创建并写入内容）到受限父目录下，文件名 [fileName]。
  /// 用于压缩包等需要写入内容的场景（纯 Shizuku 无 shell 写权限）。
  static Future<bool> uploadFileViaSaf(String localPath, String parentLocalPath, String fileName, {bool isObb = false}) async {
    final resolved = await _resolveSafParent(parentLocalPath, isObb: isObb);
    if (resolved == null) return false;
    try {
      final result = await _channel.invokeMethod('uploadFile', {
        'rootUri': resolved['treeUri'],
        'parentUri': resolved['parentUri'],
        'localPath': localPath,
        'fileName': fileName,
      });
      return result == true;
    } catch (e) {
      debugPrint('[ZenFile] SAF uploadFileViaSaf failed: $e');
      return false;
    }
  }

  /// 受限目录下新建文件常用的 MIME 推断（Dart 侧无通用 MimeTypeMap，内联常见映射）。
  static String _safMimeForExt(String ext) {
    const map = {
      'txt': 'text/plain',
      'log': 'text/plain',
      'csv': 'text/csv',
      'json': 'application/json',
      'xml': 'application/xml',
      'html': 'text/html',
      'htm': 'text/html',
      'css': 'text/css',
      'js': 'application/javascript',
      'md': 'text/markdown',
      'pdf': 'application/pdf',
      'png': 'image/png',
      'jpg': 'image/jpeg',
      'jpeg': 'image/jpeg',
      'gif': 'image/gif',
      'webp': 'image/webp',
      'mp3': 'audio/mpeg',
      'wav': 'audio/x-wav',
      'mp4': 'video/mp4',
      'zip': 'application/zip',
      'apk': 'application/vnd.android.package-archive',
    };
    return map[ext] ?? 'application/octet-stream';
  }

  /// 由 document ID 构建可被原生 `downloadFile` 解析的 content:// document URI。
  /// 复用与本库 `listAndroidDataSubDirViaSAF` 完全相同的范式：
  /// `content://com.android.externalstorage.documents/document/<encodeComponent(docId)>`。
  /// 原生侧 `getDocumentId(Uri.parse(uri))` 会解码该 docId，再经
  /// `buildDocumentUriUsingTree(rootUri, docId)` 重建，与 listDirectory 行为一致。
  static String _buildSafDocUri(String treeUri, String docId) {
    // 仅取 treeUri 的 authority（downloadFile 只用 rootUri 参数，docId 由 uri 反向解析）。
    final uri = Uri.parse(treeUri);
    final authority = uri.authority.isNotEmpty ? uri.authority : 'com.android.externalstorage.documents';
    final encDoc = Uri.encodeComponent(docId);
    return 'content://$authority/document/$encDoc';
  }

  static Future<void> _saveTreeUri(String key, String uri) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(key, uri);
    } catch (_) {}
  }

  static Future<String?> _getTreeUri(String key) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getString(key);
    } catch (_) {
      return null;
    }
  }
}
