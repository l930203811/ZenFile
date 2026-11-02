import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'recycle_bin_service.dart';

/// 收集分块哈希的最终摘要（[Hash.startChunkedConversion] 只回吐一个 Digest）。
class _DigestSink implements Sink<Digest> {
  Digest? value;

  @override
  void add(Digest data) => value = data;

  @override
  void close() {}
}

/// 「空间」页**扫描去重**的扫描与清理实现。
///
/// ## 判定口径
/// 1. 先按**文件大小**分组：大小不同的文件不可能相同（大小是最便宜的一刀）。
/// 2. 同尺寸的候选文件再算 **SHA-256 全文摘要**，摘要相同才判定为重复。
///    ⇒ 绝不会出现「名字不同、内容不同却被当成重复删掉」的误判。
/// 3. 组内按修改时间**从新到旧**排序：清理时**推荐保留最新的那份**、勾选较旧的副本
///    （用户要求「推荐勾选旧文件」）。
///
/// ## 扫描范围与剪枝
/// 默认根 = 内部存储根；跳过隐藏目录、`Android/{data,obb}`、本应用缓存目录、
/// 回收站、Windows 系统目录，以及小于 [minFileSize] 的碎文件（缩略图/缓存图标
/// 会产生海量无意义「重复」，纯噪音且拖慢扫描）。
///
/// ## 约定
/// 扫描与哈希全部在独立 isolate 中执行，逐帧回报进度，UI 线程不被阻塞；
/// 任何异常都不外抛——扫描失败只该是「没找到重复」，不该变成新的崩溃源。
class DuplicateScanService {
  DuplicateScanService._();

  /// 小于该体积的文件不参与扫描（默认 64KB）。
  static const int defaultMinFileSize = 64 * 1024;

  /// 当前正在跑的 isolate（用于页面退出时中止扫描）。
  static Isolate? _activeIsolate;
  static Completer<DupScanResult>? _activeCompleter;

  /// 中止正在进行的扫描（用户返回上一页时调用）。
  ///
  /// 全盘哈希可能持续几十秒，退出页面后没人再关心结果，必须让 isolate
  /// 立刻停下并释放 CPU / IO，否则后台会一直烧电。
  static void cancelActive() {
    _activeIsolate?.kill(priority: Isolate.immediate);
    final c = _activeCompleter;
    if (c != null && !c.isCompleted) {
      c.complete(const DupScanResult(groups: [], scanned: 0, candidates: 0));
    }
    _activeIsolate = null;
    _activeCompleter = null;
  }

  /// 扫描重复文件。
  ///
  /// [onProgress] 每处理一批文件回调一次（scanned = 已遍历文件数，
  /// candidates = 已进入哈希阶段的候选数）。
  static Future<DupScanResult> scan({
    String? rootPath,
    int minFileSize = defaultMinFileSize,
    void Function(int scanned, int candidates)? onProgress,
  }) async {
    final root = (rootPath == null || rootPath.isEmpty)
        ? '/storage/emulated/0'
        : rootPath;
    // 同一时刻只保留一个扫描 isolate：重复触发（连点刷新）先停掉旧的。
    cancelActive();
    final port = ReceivePort();
    final completer = Completer<DupScanResult>();
    _activeCompleter = completer;
    Isolate? isolate;
    try {
      isolate = await Isolate.spawn(
        _scanEntry,
        <Object>[port.sendPort, root, minFileSize],
        errorsAreFatal: true,
      );
      _activeIsolate = isolate;
      port.listen((message) {
        if (message is Map && message['progress'] == true) {
          final scanned = message['scanned'] as int? ?? 0;
          final candidates = message['candidates'] as int? ?? 0;
          onProgress?.call(scanned, candidates);
          return;
        }
        if (message is List) {
          if (!completer.isCompleted) {
            completer.complete(_resultFromWire(message));
          }
        } else if (message is Map && message['error'] != null) {
          if (!completer.isCompleted) {
            completer.complete(const DupScanResult(groups: [], scanned: 0, candidates: 0));
          }
        }
      });
      return await completer.future;
    } catch (_) {
      return const DupScanResult(groups: [], scanned: 0, candidates: 0);
    } finally {
      if (identical(_activeIsolate, isolate)) {
        _activeIsolate = null;
        _activeCompleter = null;
      }
      if (!completer.isCompleted) {
        completer.complete(
          const DupScanResult(groups: [], scanned: 0, candidates: 0),
        );
      }
      port.close();
      isolate?.kill(priority: Isolate.immediate);
    }
  }

  /// 删除（或移入回收站）指定文件，返回实际释放的字节数。
  ///
  /// 逐个处理，单个文件失败（被占用 / 无权限）不影响其余；
  /// 回收站开启时优先 [RecycleBinService.moveToTrash]（用户可撤销）。
  static Future<DupCleanResult> deleteFiles(List<DupFile> files) async {
    var deleted = 0;
    var freed = 0;
    var failed = 0;
    final useTrash = RecycleBinService.isEnabled();
    for (final f in files) {
      try {
        if (useTrash) {
          await RecycleBinService.moveToTrash(f.path);
        } else {
          final file = File(f.path);
          if (!file.existsSync()) continue;
          await file.delete();
        }
        deleted++;
        freed += f.size;
      } catch (_) {
        failed++;
      }
    }
    return DupCleanResult(deleted: deleted, freedBytes: freed, failed: failed);
  }

  // ---------------------------------------------------------------------------
  // isolate 侧实现
  // ---------------------------------------------------------------------------

  static void _scanEntry(List<Object> args) {
    final sendPort = args[0] as SendPort;
    final root = args[1] as String;
    final minSize = args[2] as int;
    try {
      final wire = _scanSync(root, minSize, sendPort);
      sendPort.send(wire);
    } catch (e) {
      sendPort.send(<String, Object?>{'error': e.toString()});
    }
  }

  /// 扫描主体（纯同步，运行在 isolate 中）。
  ///
  /// 返回值必须是**可跨 isolate 克隆**的纯数据结构：
  /// `[ {size:int, files:[{path:String, size:int, modified:int}]}, ... ]`
  static List<Object?> _scanSync(String root, int minSize, SendPort progress) {
    final bySize = <int, List<List<Object>>>{};
    var scanned = 0;
    var lastTick = 0;
    var hashTick = 0;

    void walk(Directory dir) {
      List<FileSystemEntity> entries;
      try {
        entries = dir.listSync(followLinks: false);
      } catch (_) {
        return;
      }
      for (final e in entries) {
        final name = p.basename(e.path);
        if (name.startsWith('.')) continue;
        if (e is Directory) {
          if (_skipDir(e.path, name)) continue;
          walk(e);
        } else if (e is File) {
          scanned++;
          try {
            final size = e.lengthSync();
            if (size >= minSize) {
              bySize
                  .putIfAbsent(size, () => <List<Object>>[])
                  .add(<Object>[
                e.path,
                size,
                e.statSync().modified.millisecondsSinceEpoch,
              ]);
            }
          } catch (_) {}
          if (scanned - lastTick >= 200) {
            lastTick = scanned;
            progress.send(<String, Object?>{
              'progress': true,
              'scanned': scanned,
              'candidates': 0,
            });
          }
        }
      }
    }

    final rootDir = Directory(root);
    if (!rootDir.existsSync()) return <Object?>[];
    walk(rootDir);

    // 只有「同尺寸且不止一个」的文件才值得算哈希。
    final candidates = <int, List<List<Object>>>{};
    var candidateCount = 0;
    bySize.forEach((size, list) {
      if (list.length > 1) {
        candidates[size] = list;
        candidateCount += list.length;
      }
    });

    final groups = <Object?>[];
    var hashed = 0;
    candidates.forEach((size, list) {
      final buckets = <String, List<List<Object>>>{};
      for (final entry in list) {
        final path = entry[0] as String;
        String digest;
        try {
          final d = _sha256OfFile(File(path));
          if (d == null) continue;
          digest = d;
        } catch (_) {
          continue;
        }
        buckets.putIfAbsent(digest, () => <List<Object>>[]).add(entry);
        hashed++;
        if (hashed - hashTick >= 50) {
          hashTick = hashed;
          progress.send(<String, Object?>{
            'progress': true,
            'scanned': scanned,
            'candidates': hashed,
          });
        }
      }
      buckets.forEach((_, files) {
        if (files.length < 2) return;
        // 组内：修改时间从新到旧（第一项 = 推荐保留的那份）
        files.sort((a, b) => (b[2] as int).compareTo(a[2] as int));
        groups.add(<String, Object?>{
          'size': size,
          'files': files
              .map((f) => <String, Object?>{
                    'path': f[0] as String,
                    'size': f[1] as int,
                    'modified': f[2] as int,
                  })
              .toList(),
        });
      });
    });

    // 可释放体积从大到小 —— 用户先看到最值得清理的。
    groups.sort((a, b) {
      final ga = (a as Map)['files'] as List;
      final gb = (b as Map)['files'] as List;
      final sa = ((a)['size'] as int) * (ga.length - 1);
      final sb = ((b)['size'] as int) * (gb.length - 1);
      return sb.compareTo(sa);
    });

    return <Object?>[groups, scanned, candidateCount];
  }

  /// 分块计算 SHA-256（1MB 缓冲）。
  ///
  /// 直接 `readAsBytesSync()` 在 4K 视频这类超大文件上会瞬间吃掉几百 MB 内存，
  /// 甚至把 isolate 撑爆；分块读取内存占用恒定，速度差异可忽略。
  static String? _sha256OfFile(File file) {
    RandomAccessFile? raf;
    try {
      raf = file.openSync();
      final sink = _DigestSink();
      final out = sha256.startChunkedConversion(sink);
      final buf = Uint8List(1 << 20);
      while (true) {
        final n = raf.readIntoSync(buf);
        if (n <= 0) break;
        out.add(n == buf.length ? buf : Uint8List.sublistView(buf, 0, n));
      }
      out.close();
      return sink.value?.toString();
    } catch (_) {
      return null;
    } finally {
      try {
        raf?.closeSync();
      } catch (_) {}
    }
  }

  /// 目录剪枝：这些目录里的文件不参与去重。
  static bool _skipDir(String path, String name) {
    if (name.startsWith('.')) return true;
    if (name == 'node_modules') return true;
    final norm = path.replaceAll('\\', '/');
    // 系统私有目录：普通应用读不到，也不该建议用户删
    if (norm.endsWith('/Android/data') || norm.endsWith('/Android/obb')) {
      return true;
    }
    // 本应用缓存/中间产物（清理由「垃圾清理」负责，不进重复文件）
    const cacheDirs = <String>[
      '/storage/emulated/0/ZenFile/cache',
      '/storage/emulated/0/ZenFile/RemoteDecrypted',
      '/storage/emulated/0/ZenFile/apk_install',
      '/storage/emulated/0/ZenFile/apk_extract',
      '/storage/emulated/0/ZenFile/crash',
    ];
    for (final d in cacheDirs) {
      if (norm == d) return true;
    }
    // 回收站里的文件不参与去重（用户已决定不要它们）
    if (norm == RecycleBinService.trashDirectoryPath) return true;
    // Windows 系统目录（桌面端调试用，避免 AppData 之类几十万文件拖死扫描）
    const winSkip = <String>{
      'AppData',
      'Application Data',
      'Windows',
      'Program Files',
      'Program Files (x86)',
      'ProgramData',
      r'$Recycle.Bin',
      'System Volume Information',
    };
    if (winSkip.contains(name) &&
        (Platform.isWindows)) {
      return true;
    }
    return false;
  }

  static DupScanResult _resultFromWire(List<Object?> wire) {
    if (wire.length < 3) {
      return const DupScanResult(groups: [], scanned: 0, candidates: 0);
    }
    final rawGroups = wire[0] as List? ?? const [];
    final groups = <DupGroup>[];
    for (final g in rawGroups) {
      final map = g as Map;
      final size = map['size'] as int? ?? 0;
      final files = <DupFile>[];
      for (final f in (map['files'] as List? ?? const [])) {
        final fm = f as Map;
        files.add(DupFile(
          path: fm['path'] as String? ?? '',
          size: fm['size'] as int? ?? size,
          modified: DateTime.fromMillisecondsSinceEpoch(
            fm['modified'] as int? ?? 0,
          ),
        ));
      }
      if (files.length > 1) groups.add(DupGroup(size: size, files: files));
    }
    return DupScanResult(
      groups: groups,
      scanned: wire[1] as int? ?? 0,
      candidates: wire[2] as int? ?? 0,
    );
  }
}

/// 一个重复文件条目。
class DupFile {
  final String path;
  final int size;
  final DateTime modified;

  const DupFile({
    required this.path,
    required this.size,
    required this.modified,
  });

  String get name => p.basename(path);

  /// 所在目录（列表里给用户看上下文，同名文件才知道该删哪个）。
  String get directory => p.dirname(path);
}

/// 一组内容完全相同的文件（[files] 已按修改时间从新到旧排序）。
class DupGroup {
  final int size;
  final List<DupFile> files;

  const DupGroup({required this.size, required this.files});

  /// 该组可释放的字节数 = 保留一份后其余副本的总和。
  int get wastedBytes => size * (files.length - 1);

  /// 推荐保留的那份（最新修改）。
  DupFile get keeper => files.first;
}

/// 扫描结果。
class DupScanResult {
  final List<DupGroup> groups;
  final int scanned;
  final int candidates;

  const DupScanResult({
    required this.groups,
    required this.scanned,
    required this.candidates,
  });

  bool get isEmpty => groups.isEmpty;

  int get totalWasted => groups.fold(0, (sum, g) => sum + g.wastedBytes);

  int get totalFiles => groups.fold(0, (sum, g) => sum + g.files.length);
}

/// 清理结果。
class DupCleanResult {
  final int deleted;
  final int freedBytes;
  final int failed;

  const DupCleanResult({
    required this.deleted,
    required this.freedBytes,
    required this.failed,
  });
}
