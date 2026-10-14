import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:permission_handler/permission_handler.dart';
import 'package:archive/archive_io.dart';
import 'package:dart_lz4/dart_lz4.dart';
import 'package:charset/charset.dart';
import 'package:just_zstd/just_zstd.dart';
import 'package:zenfile/l10n/generated/app_localizations.dart';
import '../providers/file_manager_provider.dart';
import '../services/root_shizuku_service.dart';
import 'archive_service.dart';
import 'package:provider/provider.dart';
import '../core/navigator_key.dart';
import '../ui/widgets/background_operation_progress_dialog.dart';

/// 用于压缩时聚合文件/空目录结构和总大小（流式压缩前一次性统计，避免每次再 list）
class _CompressionPlan {
  final List<_FileEntry> files;
  final List<String> emptyDirs;
  final int totalFileCount;
  final int totalByteCount;
  _CompressionPlan(this.files, this.emptyDirs, this.totalFileCount, this.totalByteCount);
}

/// 节流包装：避免 SendPort 每轮发送（每一个字节块/每一个文件都），控制在 ~100ms 间隔，
/// 否则高频跨 isolate 回传会导致主 isolate 队列堆积卡死。
class _ProgressThrottler {
  final SendPort sendPort;
  /// 进度区间折算：多任务（逐文件压缩）时把单任务进度 [0,1] 线性映射到
  /// [progBase, progBase + progSpan]，使总进度条跨任务连续推进。
  /// 默认 0.0 / 1.0 即不平移，单包模式行为与原来完全一致。
  final double progBase;
  final double progSpan;
  int _lastSentMs = 0;
  double _lastProgress = -1;
  String _lastFile = '';
  int _lastIndex = -1;
  int _lastBytes = -1;
  int _lastFileBytes = -1;
  _ProgressThrottler(this.sendPort, {this.progBase = 0.0, this.progSpan = 1.0});

  void send(double progress, String currentFile,
      {bool force = false,
      int bytesProcessed = 0,
      int totalBytes = 0,
      int currentFileBytes = 0,
      int currentFileTotal = 0,
      int currentIndex = 0,
      int totalFiles = 0}) {
    final scaled = (progBase + progress * progSpan).clamp(0.0, 1.0);
    final now = DateTime.now().millisecondsSinceEpoch;
    final bool changed = (scaled - _lastProgress).abs() > 0.001 ||
        currentFile != _lastFile ||
        currentIndex != _lastIndex ||
        (bytesProcessed - _lastBytes).abs() > 1024 * 1024 ||
        (currentFileBytes - _lastFileBytes).abs() > 256 * 1024;
    if (!force && !changed) return;
    if (!force && now - _lastSentMs < 100 && scaled < 0.999) return;
    _lastSentMs = now;
    _lastProgress = scaled;
    _lastFile = currentFile;
    _lastIndex = currentIndex;
    _lastBytes = bytesProcessed;
    _lastFileBytes = currentFileBytes;
    sendPort.send({
      'status': 'progress',
      'progress': scaled,
      'currentFile': currentFile,
      'bytesProcessed': bytesProcessed,
      'totalBytes': totalBytes,
      'currentFileBytes': currentFileBytes,
      'currentFileTotal': currentFileTotal,
      'currentIndex': currentIndex,
      'totalFiles': totalFiles,
    });
  }
}

/// 流式把一个大文件分块拷贝到目的地（输入/输出为抽象的「块写入」回调），
/// 避免 readAsBytes / writeAsBytes 在大文件（>2GB 或 RAM 有限）时 OOM 崩溃。
/// 单块 1 MB；在 copy 过程中按字节数累加进度。
const int _kChunkSize = 1024 * 1024; // 1 MiB

/// 把 ArchiveFile 的内容流式分块写到输出文件，避免大文件一次性 writeAsBytes 导致内存峰值。
/// ArchiveFile 的 content 可能是 `List<int>` 或内部 InputStream 实现；这里统一按块提取和写出。
/// [onChunkWritten] 每写一块回调一次（written 为当前文件已写字节数），用于当前文件进度环。
Future<void> _streamWriteArchiveFile(dynamic content, File outFile,
    {int chunkSize = _kChunkSize, void Function(int written)? onChunkWritten}) async {
  final sink = outFile.openWrite();
  try {
    if (content is List<int>) {
      final bytes = content;
      if (bytes.length <= chunkSize) {
        if (bytes.isNotEmpty) {
          sink.add(bytes);
          onChunkWritten?.call(bytes.length);
        }
      } else {
        for (int i = 0; i < bytes.length; i += chunkSize) {
          final end = (i + chunkSize > bytes.length) ? bytes.length : i + chunkSize;
          sink.add(Uint8List.fromList(bytes.sublist(i, end)));
          onChunkWritten?.call(end);
          await sink.flush();
          await Future<void>.delayed(Duration.zero);
        }
      }
    } else if (content is InputStreamBase) {
      // 旧实现只处理 List<int>，遇到「流式 content」（如 InputStreamBase 条目）
      // 会一声不响地写出 0 字节文件 —— 与「解压出来全是 0 字节」的反馈同源，
      // 这里补上分块读取写出。
      int written = 0;
      while (!content.isEOS) {
        final bytes = content.readBytes(chunkSize).toUint8List();
        if (bytes.isEmpty) break;
        sink.add(bytes);
        written += bytes.length;
        onChunkWritten?.call(written);
        await sink.flush();
        await Future<void>.delayed(Duration.zero);
      }
    }
    await sink.flush();
  } finally {
    await sink.close();
  }
}

/// 把 [src] 压缩包通过「流式解码器」解包到临时 TAR 文件，
/// 替代旧版 readAsBytes + decodeBytes 的整包内存方案。
/// 返回临时 TAR 文件路径（调用方负责删除）。
Future<String> _streamDecompressToTar(File src, String format, _ProgressThrottler t) async {
  final tmpDir = Directory.systemTemp;
  final tarTmp = File(p.join(tmpDir.path, 'zenfile_extract_${DateTime.now().millisecondsSinceEpoch}.tar'));
  final total = src.lengthSync();
  final lower = src.path.toLowerCase();

  try {
    if (lower.endsWith('.tar.gz') || lower.endsWith('.tgz')) {
      // tar.gz：使用 GZipDecoder.decodeStream 流式，全程不驻留整包
      t.send(0.08, 'Decoding tar.gz wrapper…', force: true);
      final input = InputFileStream(src.path);
      final output = OutputFileStream(tarTmp.path);
      try {
        GZipDecoder().decodeStream(input, output);
        output.flush();
      } finally {
        try { input.closeSync(); } catch (_) {}
        try { output.closeSync(); } catch (_) {}
      }
      t.send(0.28, 'Tar wrapper decoded', force: true);
    } else if (lower.endsWith('.tar.bz2') || lower.endsWith('.tbz2')) {
      if (total <= 256 * 1024 * 1024) {
        t.send(0.08, 'Reading tar.bz2…', force: true);
        final bytes = await src.readAsBytes();
        t.send(0.18, 'Applying BZ2 decoder…', force: true);
        final decoded = BZip2Decoder().decodeBytes(bytes);
        t.send(0.26, 'Writing temp tar…', force: true);
        if (decoded.isNotEmpty) tarTmp.writeAsBytesSync(decoded);
      } else {
        t.send(0.08, 'Reading large tar.bz2 (may be slow)…', force: true);
        final bytes = await src.readAsBytes();
        t.send(0.20, 'Applying BZ2 decoder…', force: true);
        final decoded = BZip2Decoder().decodeBytes(bytes);
        t.send(0.28, 'Writing temp tar…', force: true);
        if (decoded.isNotEmpty) tarTmp.writeAsBytesSync(decoded);
      }
    } else if (lower.endsWith('.tar.lz4') || lower.endsWith('.tlz4')) {
      if (total <= 384 * 1024 * 1024) {
        t.send(0.08, 'Reading tar.lz4…', force: true);
        final bytes = await src.readAsBytes();
        t.send(0.20, 'Applying LZ4 decoder…', force: true);
        final decoded = lz4FrameDecode(bytes);
        t.send(0.28, 'Writing temp tar…', force: true);
        if (decoded.isNotEmpty) tarTmp.writeAsBytesSync(decoded);
      } else {
        t.send(0.08, 'Reading large tar.lz4…', force: true);
        final bytes = await src.readAsBytes();
        t.send(0.20, 'Applying LZ4 decoder…', force: true);
        final decoded = lz4FrameDecode(bytes);
        t.send(0.28, 'Writing temp tar…', force: true);
        if (decoded.isNotEmpty) tarTmp.writeAsBytesSync(decoded);
      }
    } else if (lower.endsWith('.tar.zst') || lower.endsWith('.tzst')) {
      if (total <= 384 * 1024 * 1024) {
        t.send(0.08, 'Reading tar.zst…', force: true);
        final bytes = await src.readAsBytes();
        t.send(0.20, 'Applying ZSTD decoder…', force: true);
        final decoded = const ZstdDecoder().decodeBytes(bytes);
        t.send(0.28, 'Writing temp tar…', force: true);
        if (decoded.isNotEmpty) tarTmp.writeAsBytesSync(decoded);
      } else {
        t.send(0.08, 'Reading large tar.zst…', force: true);
        final bytes = await src.readAsBytes();
        t.send(0.20, 'Applying ZSTD decoder…', force: true);
        final decoded = const ZstdDecoder().decodeBytes(bytes);
        t.send(0.28, 'Writing temp tar…', force: true);
        if (decoded.isNotEmpty) tarTmp.writeAsBytesSync(decoded);
      }
    } else {
      // fallback：直接复制
      await src.copy(tarTmp.path);
    }

    return tarTmp.path;
  } catch (_) {
    try { if (tarTmp.existsSync()) tarTmp.deleteSync(); } catch (_) {}
    rethrow;
  }
}

/// 压缩前一次性扫描所有源文件/目录并计算总大小（用于后续按字节计算进度）。
_CompressionPlan _buildCompressionPlan(List<String> sourcePaths, _ProgressThrottler t) {
  final files = <_FileEntry>[];
  final emptyDirs = <String>[];
  int totalBytes = 0;

  for (int pi = 0; pi < sourcePaths.length; pi++) {
    final path = sourcePaths[pi];
    final type = FileSystemEntity.typeSync(path);
    if (type == FileSystemEntityType.file) {
      final f = File(path);
      final len = f.existsSync() ? f.lengthSync() : 0;
      files.add(_FileEntry(path, p.basename(path)));
      totalBytes += len;
    } else if (type == FileSystemEntityType.directory) {
      final dir = Directory(path);
      if (!dir.existsSync()) continue;
      final list = dir.listSync(recursive: true);
      bool hasFiles = false;
      for (final sub in list) {
        if (sub is File) {
          hasFiles = true;
          final relPath = p.relative(sub.path, from: p.dirname(path));
          final len = sub.existsSync() ? sub.lengthSync() : 0;
          files.add(_FileEntry(sub.path, relPath));
          totalBytes += len;
        } else if (sub is Directory) {
          final relDirPath = p.relative(sub.path, from: p.dirname(path));
          emptyDirs.add(relDirPath);
        }
      }
      if (!hasFiles && list.isEmpty) emptyDirs.add(p.basename(path));
    }
    final prog = 0.08 * ((pi + 1) / sourcePaths.length);
    t.send(prog, 'Scanning: ${p.basename(path)}');
  }
  return _CompressionPlan(files, emptyDirs, files.length, totalBytes);
}

class BackgroundOperation {
  final String id;
  final String title;
  final String archiveName;
  final bool isCompression;
  final String? destinationDir;
  /// 压缩操作生成的压缩包完整路径（用于成功后高亮定位）
  final String? destinationPath;
  double progress; // 0.0 to 1.0
  String currentFile;
  bool isRunningInBackground;
  // 速度追踪（字节/秒）
  double speedBytesPerSecond;
  // 已处理字节数
  int bytesProcessed;
  // 总字节数
  int totalBytes;
  // 当前文件的已处理字节数（内圈进度环）
  int currentFileBytes;
  // 当前文件总字节数（内圈进度环；0 表示未知/未开始）
  int currentFileTotal;
  // 当前处理到第几个文件（1 基；0 表示未知）+ 本次操作的文件总数（0 表示未知）
  int currentFileIndex;
  int totalFiles;

  /// 受限目录（纯 Shizuku 无 root）下，压缩结果需经 SAF 上传：先写到本地临时文件，
  /// 完成后由 _onOperationComplete 经 DocumentsContract 上传到目标目录（shell 无写权限）。
  final String? safLocalPath;
  final String? safParentDir;
  final String? safFileName;
  final bool safIsObb;

  BackgroundOperation({
    required this.id,
    required this.title,
    required this.archiveName,
    required this.isCompression,
    this.destinationDir,
    this.destinationPath,
    this.progress = 0.0,
    this.currentFile = '',
    this.isRunningInBackground = false,
    this.speedBytesPerSecond = 0.0,
    this.bytesProcessed = 0,
    this.totalBytes = 0,
    this.currentFileBytes = 0,
    this.currentFileTotal = 0,
    this.currentFileIndex = 0,
    this.totalFiles = 0,
    this.safLocalPath,
    this.safParentDir,
    this.safFileName,
    this.safIsObb = false,
  });
}

class _FileEntry {
  final String fullPath;
  final String relPath;
  _FileEntry(this.fullPath, this.relPath);
}

/// 压缩/解压操作的最终结果。调用方（provider）据此决定后续动作：
/// 密码类失败要重新弹窗索要密码，而不是只弹一句「失败」。
enum ArchiveOpResult {
  success,

  /// 用户点了「取消」/ 从通知里取消。
  cancelled,

  /// 压缩包已加密但没提供密码。
  passwordRequired,

  /// 提供了密码但校验失败。
  passwordInvalid,

  /// 其它失败（已由服务层弹出错误提示）。
  failed,
}

class BackgroundArchiveService {
  static final BackgroundArchiveService instance = BackgroundArchiveService._();
  BackgroundArchiveService._() {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'cancelOperationFromNotification') {
        cancelOperation();
      }
    });
  }

  static const _channel = MethodChannel('com.sequl.zenfile/notifications');

  final ValueNotifier<BackgroundOperation?> activeOperation = ValueNotifier(null);

  Isolate? _activeIsolate;
  ReceivePort? _receivePort;
  StreamSubscription? _portSubscription;
  VoidCallback? _onCompleteCallback;
  // 速度追踪
  int? _lastSpeedTrackTime;
  int? _lastSpeedTrackBytes;

  /// 进度对话框的关闭回调，作为 ValueListenableBuilder 的兜底机制
  void Function()? dialogCloseCallback;

  /// 直接存储对话框的 BuildContext，用于在 _onOperationComplete 中强制关闭
  BuildContext? _activeDialogContext;

  /// 对话框关闭的定时器兜底：操作完成后最多 5 秒强制关闭对话框
  Timer? _dialogCloseTimer;

  /// 存储对话框的 BuildContext，由 BackgroundOperationProgressDialog 在 show 时调用
  void setActiveDialogContext(BuildContext context) {
    _activeDialogContext = context;
  }

  /// 强制关闭进度对话框（多重兜底机制）
  void _forceCloseDialog() {
    final ctx = _activeDialogContext;
    _activeDialogContext = null;
    dialogCloseCallback = null;
    _dialogCloseTimer?.cancel();
    _dialogCloseTimer = null;

    if (ctx != null) {
      try {
        if (Navigator.canPop(ctx)) {
          Navigator.pop(ctx);
          return;
        }
      } catch (_) {}

      try {
        scheduleMicrotask(() {
          try {
            if (Navigator.canPop(ctx)) {
              Navigator.pop(ctx);
            }
          } catch (_) {}
        });
      } catch (_) {}
    }
  }

  /// 直接持有 provider 引用，避免 onComplete 回调捕获时机不对导致刷新丢失
  FileManagerProvider? _refreshProvider;
  BuildContext? _savedContext;

  /// 当前解压操作的结果槽（startExtraction 返回值）；非解压操作为 null。
  Completer<ArchiveOpResult>? _extractResult;

  /// 捕获的 ScaffoldMessengerState：在显示 bottom sheet / dialog 之前尽早保存
  ScaffoldMessengerState? _scaffoldMessenger;

  /// 清理「已被 kill 的 isolate 留下的」临时文件。
  ///
  /// 分块压缩（zenfile_zip_*.tmp）与 TAR.* 解压（zenfile_extract_*.tar）都会在
  /// systemTemp 里落盘中间产物，正常结束由 finally 删除；但用户点「取消」时
  /// isolate 被直接 kill，finally 不会执行 ⇒ 残留文件可能很大。
  /// 这里只清 1 小时以上的旧文件，绝不会碰到正在运行的操作的临时文件。
  static void cleanupStaleTempFiles() {
    Future<void>(() async {
      try {
        final dir = Directory.systemTemp;
        if (!dir.existsSync()) return;
        final cutoff = DateTime.now().subtract(const Duration(hours: 1));
        await for (final e in dir.list(followLinks: false)) {
          if (e is! File) continue;
          final name = p.basename(e.path);
          if (!name.startsWith('zenfile_zip_') &&
              !name.startsWith('zenfile_extract_') &&
              !name.startsWith('zenfile_compress_')) {
            continue;
          }
          try {
            if (e.statSync().modified.isBefore(cutoff)) e.deleteSync();
          } catch (_) {}
        }
      } catch (_) {}
    });
  }

  Future<void> startCompression({
    required BuildContext context,
    required List<String> sourcePaths,
    required String destinationPath,
    required String format,
    required int level,
    required bool deleteSource,
    String? targetRefreshDir,
    VoidCallback? onComplete,
    FileManagerProvider? provider,
    /// ZIP 加密密码（仅 ZIP 格式生效；tar.* 无密码概念，非 ZIP 格式下忽略）。
    String? password,
    /// 分卷大小（MB）：压缩完成后按该大小把成品切成 .001/.002… 分卷。
    /// null 或 <= 0 时不分卷。逐文件模式下每个包各自独立分卷。
    int? splitSizeMB,
    /// 逐文件压缩：每个源路径生成一个独立压缩包（basename.format，同目录），
    /// 与 ArchiveService.createArchive 的 separateArchives 语义一致。
    bool separateArchives = false,
    /// 实际写盘路径。受限目录（纯 Shizuku 无 root）下传临时文件，再经 SAF 上传。
    String? writeDestinationPath,
    /// SAF 上传信息：压缩完成的临时文件 -> 受限父目录下的目标文件名。
    String? safLocalPath,
    String? safParentDir,
    String? safFileName,
    bool safIsObb = false,
  }) async {
    final effectiveContext = context.mounted ? context : (navigatorKey.currentContext ?? context);
    final archiveName = p.basename(destinationPath);
    // 顺手清理被 kill 的 isolate 留下的中间文件（不影响正在进行的操作）
    cleanupStaleTempFiles();
    // 逐文件压缩：把每个源路径展开为一个独立任务（basename.format，同目录），
    // 与 ArchiveService.createArchive(separateArchives: true) 语义一致；
    // 单包模式只有一个任务。所有任务在同一个 isolate 内串行执行，进度跨包连续。
    final jobs = <Map<String, dynamic>>[];
    if (separateArchives) {
      for (final src in sourcePaths) {
        final name = p.basenameWithoutExtension(src);
        jobs.add({
          'sourcePaths': <String>[src],
          'destinationPath': _uniqueArchivePath(
              p.join(p.dirname(destinationPath), '$name.$format')),
        });
      }
    } else {
      jobs.add({
        'sourcePaths': sourcePaths,
        'destinationPath': writeDestinationPath ?? destinationPath,
      });
    }
    // 逐文件模式下传入的 destinationPath（archiveName.format）并不会真实存在，
    // 用第一个成品包作为完成 SnackBar「打开位置」的高亮目标。
    final resultPath =
        jobs.isNotEmpty ? jobs.first['destinationPath'] as String : destinationPath;
    final operation = BackgroundOperation(
      id: 'compress_${DateTime.now().millisecondsSinceEpoch}',
      title: L10n.of(effectiveContext).msg2f0138ad,
      archiveName: archiveName,
      isCompression: true,
      destinationDir: targetRefreshDir ?? p.dirname(destinationPath),
      destinationPath: resultPath,
      safLocalPath: safLocalPath,
      safParentDir: safParentDir,
      safFileName: safFileName,
      safIsObb: safIsObb,
    );

    activeOperation.value = operation;
    _scaffoldMessenger ??= ScaffoldMessenger.of(effectiveContext);
    _onCompleteCallback = onComplete;
    _refreshProvider = provider;
    _savedContext = effectiveContext;

    _dialogCloseTimer?.cancel();
    _dialogCloseTimer = null;

    BackgroundOperationProgressDialog.show(effectiveContext, this);

    _receivePort = ReceivePort();

    _activeIsolate = await Isolate.spawn(
      _compressIsolateTask,
      {
        'sendPort': _receivePort!.sendPort,
        'format': format,
        'level': level,
        'deleteSource': deleteSource,
        'password': password,
        'splitSizeMB': splitSizeMB,
        'jobs': jobs,
      },
    );

    _portSubscription = _receivePort!.listen((message) {
      if (message is Map<String, dynamic>) {
        final status = message['status'] as String;
        if (status == 'progress') {
          final progress = message['progress'] as double;
          final currentFile = message['currentFile'] as String;
          final bytesProcessed = message['bytesProcessed'] as int? ?? 0;
          final totalBytes = message['totalBytes'] as int? ?? 0;
          final currentFileBytes = message['currentFileBytes'] as int? ?? 0;
          final currentFileTotal = message['currentFileTotal'] as int? ?? 0;
          final currentIndex = message['currentIndex'] as int? ?? 0;
          final totalFiles = message['totalFiles'] as int? ?? 0;

          // 计算速度（字节/秒）
          final now = DateTime.now().millisecondsSinceEpoch;
          final elapsed = now - (_lastSpeedTrackTime ?? now);
          if (elapsed > 500 && bytesProcessed > 0) {
            final bytesDelta = bytesProcessed - (_lastSpeedTrackBytes ?? 0);
            operation.speedBytesPerSecond = (bytesDelta / (elapsed / 1000.0));
            _lastSpeedTrackTime = now;
            _lastSpeedTrackBytes = bytesProcessed;
          } else if (_lastSpeedTrackTime == null) {
            _lastSpeedTrackTime = now;
            _lastSpeedTrackBytes = bytesProcessed;
          }

          operation.progress = progress;
          operation.currentFile = currentFile;
          operation.bytesProcessed = bytesProcessed;
          operation.totalBytes = totalBytes;
          operation.currentFileBytes = currentFileBytes;
          operation.currentFileTotal = currentFileTotal;
          operation.currentFileIndex = currentIndex;
          operation.totalFiles = totalFiles;
          activeOperation.value = operation;
          // ignore: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
          activeOperation.notifyListeners();

          if (operation.isRunningInBackground) {
            _updateNotification(operation);
          }
        } else if (status == 'completed') {
          _onOperationComplete(effectiveContext, operation, L10n.of(effectiveContext).msga2292820);
        } else if (status == 'error') {
          final error = message['error'] as String;
          _onOperationComplete(
              effectiveContext, operation, error, isError: true);
        }
      }
    });
  }

  /// 开始解压；返回的 Future 在本次解压真正结束时完成（成功 / 取消 / 各类失败），
  /// 供调用方在「密码错误」时重新弹窗索要密码（真机反馈：旧实现密码问题完全静默，
  /// 用户以为压缩包损坏）。
  Future<ArchiveOpResult> startExtraction({
    required BuildContext context,
    required String archivePath,
    required String destinationDir,
    String? password,
    FileManagerProvider? provider,
  }) async {
    final archiveName = p.basename(archivePath);
    // 顺手清理被 kill 的 isolate 留下的中间文件（不影响正在进行的操作）
    cleanupStaleTempFiles();
    final operation = BackgroundOperation(
      id: 'extract_${DateTime.now().millisecondsSinceEpoch}',
      title: L10n.of(context).msg0683ca6b,
      archiveName: archiveName,
      isCompression: false,
      destinationDir: destinationDir,
    );

    activeOperation.value = operation;
    _scaffoldMessenger ??= ScaffoldMessenger.of(context);
    // 记录 provider / context：完成后原地刷新结果目录（解压产物立刻可见）
    _refreshProvider = provider;
    _savedContext = context;

    _dialogCloseTimer?.cancel();
    _dialogCloseTimer = null;

    // 本次解压的结果槽（下一次解压会覆盖；旧的 Completer 不再被等待）
    final completer = _extractResult = Completer<ArchiveOpResult>();

    BackgroundOperationProgressDialog.show(context, this);

    _receivePort = ReceivePort();

    _activeIsolate = await Isolate.spawn(
      _extractIsolateTask,
      {
        'sendPort': _receivePort!.sendPort,
        'archivePath': archivePath,
        'destinationDir': destinationDir,
        'password': password,
      },
    );

    _portSubscription = _receivePort!.listen((message) {
      if (message is Map<String, dynamic>) {
        final status = message['status'] as String;
        if (status == 'progress') {
          final progress = message['progress'] as double;
          final currentFile = message['currentFile'] as String;
          final bytesProcessed = message['bytesProcessed'] as int? ?? 0;
          final totalBytes = message['totalBytes'] as int? ?? 0;
          final currentFileBytes = message['currentFileBytes'] as int? ?? 0;
          final currentFileTotal = message['currentFileTotal'] as int? ?? 0;
          final currentIndex = message['currentIndex'] as int? ?? 0;
          final totalFiles = message['totalFiles'] as int? ?? 0;

          // 计算速度（字节/秒）
          final now = DateTime.now().millisecondsSinceEpoch;
          final elapsed = now - (_lastSpeedTrackTime ?? now);
          if (elapsed > 500 && bytesProcessed > 0) {
            final bytesDelta = bytesProcessed - (_lastSpeedTrackBytes ?? 0);
            operation.speedBytesPerSecond = (bytesDelta / (elapsed / 1000.0));
            _lastSpeedTrackTime = now;
            _lastSpeedTrackBytes = bytesProcessed;
          } else if (_lastSpeedTrackTime == null) {
            _lastSpeedTrackTime = now;
            _lastSpeedTrackBytes = bytesProcessed;
          }

          operation.progress = progress;
          operation.currentFile = currentFile;
          operation.bytesProcessed = bytesProcessed;
          operation.totalBytes = totalBytes;
          operation.currentFileBytes = currentFileBytes;
          operation.currentFileTotal = currentFileTotal;
          operation.currentFileIndex = currentIndex;
          operation.totalFiles = totalFiles;
          activeOperation.value = operation;
          // ignore: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
          activeOperation.notifyListeners();

          if (operation.isRunningInBackground) {
            _updateNotification(operation);
          }
        } else if (status == 'completed') {
          _onOperationComplete(context, operation, L10n.of(context).msg1f216eda);
        } else if (status == 'error') {
          final error = message['error'] as String;
          final code = message['code'] as String? ?? 'other';
          // 密码类失败不弹「失败」提示（信息对用户无意义且会盖住重试弹窗），
          // 由调用方重新弹「输入密码」框。
          final silent = code == 'password_required' || code == 'password_invalid';
          _onOperationComplete(effectiveContextOf(context), operation, error,
              isError: true, errorCode: code, silent: silent);
        }
      }
    });

    return completer.future;
  }

  /// 消息回调里可能出现 context 已 unmount 的情况（弹窗被系统回收），
  /// 这里统一退回全局 navigatorKey / 保存的 context，保证仍能提示与刷新。
  BuildContext effectiveContextOf(BuildContext context) {
    if (context.mounted) return context;
    return navigatorKey.currentContext ?? _savedContext ?? context;
  }

  void cancelOperation() {
    _dialogCloseTimer?.cancel();
    _dialogCloseTimer = null;
    _activeIsolate?.kill(priority: Isolate.beforeNextEvent);
    _activeIsolate = null;
    _portSubscription?.cancel();
    _portSubscription = null;
    _receivePort?.close();
    _receivePort = null;

    final operation = activeOperation.value;
    if (operation != null) {
      _cancelNotification(operation);
      activeOperation.value = null;
    }
    _forceCloseDialog();
    // 用户主动取消：让 startExtraction 的等待方收尾（否则 Future 永远悬着）
    _finishPendingExtraction(ArchiveOpResult.cancelled);
  }

  void runInBackground() async {
    final operation = activeOperation.value;
    if (operation == null) return;

    final status = await Permission.notification.request();
    if (status.isGranted) {
      operation.isRunningInBackground = true;
      // ignore: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
      activeOperation.notifyListeners();
      _updateNotification(operation);
    } else {
      operation.isRunningInBackground = true;
      // ignore: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
      activeOperation.notifyListeners();
    }
  }

  Future<void> _updateNotification(BackgroundOperation operation) async {
    if (!Platform.isAndroid) return;
    try {
      final progressInt = (operation.progress * 100).toInt();
      // 通知动作按钮文案随应用内语言变化（原生侧没有 locale 变体资源）。
      final notifCtx = navigatorKey.currentContext;
      final notifL10n = notifCtx == null ? null : L10n.of(notifCtx);
      await _channel.invokeMethod('showProgressNotification', {
        'id': operation.id.hashCode,
        'title': operation.title,
        'message': '${operation.archiveName} ($progressInt%)',
        'progress': progressInt,
        'max': 100,
        'indeterminate': operation.progress <= 0.0,
        if (notifL10n != null) 'openLabel': notifL10n.ui_open,
        if (notifL10n != null) 'cancelLabel': notifL10n.ui_cancel,
      });
    } catch (e) {
      debugPrint('Error updating notification: $e');
    }
  }

  Future<void> _cancelNotification(BackgroundOperation operation) async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod('cancelNotification', {
        'id': operation.id.hashCode,
      });
    } catch (_) {}
  }

  void _onOperationComplete(BuildContext context, BackgroundOperation operation, String message,
      {bool isError = false, String errorCode = 'other', bool silent = false}) async {
    if (activeOperation.value == null) return;

    // 在 async gap 之前捕获所有需要的上下文引用
    final scaffoldMessenger = _scaffoldMessenger ?? ScaffoldMessenger.of(context);
    final isCompress = operation.isCompression;
    final destDir = operation.destinationDir;
    final destPath = operation.destinationPath;
    final archiveName = operation.archiveName;

    _activeIsolate = null;
    _portSubscription?.cancel();
    _portSubscription = null;
    _receivePort?.close();
    _receivePort = null;

    final onComplete = _onCompleteCallback;
    _onCompleteCallback = null;

    activeOperation.value = null;
    _forceCloseDialog();

    await Future.delayed(const Duration(milliseconds: 350));

    // 受限目录（纯 Shizuku 无 root）压缩结果：临时文件经 SAF 上传到目标目录后删除本地临时文件。
    // shell(uid 2000) 经 FUSE 无其它应用 Android/{data,obb} 写权限，必须走 DocumentsContract。
    if (!isError &&
        operation.safLocalPath != null &&
        operation.safParentDir != null &&
        operation.safFileName != null) {
      try {
        final uploaded = await SafAndroidDataService.uploadFileViaSaf(
          operation.safLocalPath!,
          operation.safParentDir!,
          operation.safFileName!,
          isObb: operation.safIsObb,
        );
        if (uploaded) {
          try {
            await File(operation.safLocalPath!).delete();
          } catch (_) {}
        } else {
          debugPrint('[ZenFile][Archive] SAF upload failed for ${operation.safLocalPath}');
        }
      } catch (e) {
        debugPrint('[ZenFile][Archive] SAF upload error: $e');
      }
    }

    if (operation.isRunningInBackground) {
      if (Platform.isAndroid) {
        final id = operation.id.hashCode;
        await _channel.invokeMethod('showProgressNotification', {
          'id': id,
          'title': isError ? 'Operation failed' : 'Success',
          'message': isError ? 'Compression/extraction failed.' : '${operation.archiveName} processed successfully.',
          'progress': 100,
          'max': 100,
          'indeterminate': false,
        });
        Future.delayed(const Duration(seconds: 5), () {
          _channel.invokeMethod('cancelNotification', {'id': id});
        });
      }
    }

    // 失败提示。旧实现 isError 分支什么都不显示（message 参数根本没被用到），
    // 用户看到的是「进度条消失、什么都没有」⇒ 以为压缩包损坏/操作成功但文件是空的。
    // 密码类错误保持静默，由调用方重新弹「输入密码」框（避免两条提示打架）。
    if (isError && !silent && context.mounted) {
      final l10n = L10n.of(context);
      final title = isCompress
          ? l10n.msg_archive_compress_failed
          : l10n.msg_archive_extract_failed;
      final detail = errorCode == 'content_unavailable'
          ? l10n.msg_archive_content_unavailable
          : message;
      scaffoldMessenger.showSnackBar(
        SnackBar(
          content: Text('$title\n$detail'),
          backgroundColor: Colors.red.shade700,
          duration: const Duration(seconds: 6),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }

    if (!isError && destDir != null && context.mounted) {
      final nonNullDestDir = destDir;
      final l10n = L10n.of(context);
      final msg = isCompress ? l10n.msg_compress_open_location : l10n.msgc18fb099;
      scaffoldMessenger.showSnackBar(
        SnackBar(
          content: Row(
            children: [
              Expanded(child: Text(msg)),
              TextButton(
                onPressed: () {
                  scaffoldMessenger.hideCurrentSnackBar();
                  try {
                    // 用全局根 navigatorKey 替代可能被回收、或解析到
                    // 嵌套/弹出路由所在导航器的 context，保证在“分类页压缩包类别 /
                    // 最近文件 / 浏览页”等任意入口解压后点“确定”都能正确跳转。
                    final navContext = navigatorKey.currentContext;
                    if (navContext == null) {
                      debugPrint('[ZenFile][Archive] 确定: navigatorKey.currentContext 为 null');
                      return;
                    }
                    final provider = Provider.of<FileManagerProvider>(navContext, listen: false);
                    String highlightPath;
                    if (isCompress && destPath != null) {
                      highlightPath = destPath;
                    } else {
                      final baseName = p.basenameWithoutExtension(archiveName);
                      highlightPath = p.join(nonNullDestDir, baseName);
                    }
                    debugPrint('[ZenFile][Archive] 确定: highlightPath=$highlightPath');
                    // 与全局搜索“打开所在位置”完全一致的导航模式（home 监听器现在
                    // 无论当前在哪个标签都会消费 pending）：
                    // 1) 设置待导航目录 + 待高亮文件；
                    // 2) 触发切到浏览标签的 notifier（内部先置 false 再置 true，保证触发）；
                    // 3) 用全局根导航器退出所有子页面（压缩包查看器 / 分类子页 / 最近页）。
                    provider.setPendingBrowseNavigation(p.dirname(highlightPath), [highlightPath]);
                    provider.setNavigateToBrowseTab(true);
                    navigatorKey.currentState?.popUntil((route) => route.isFirst);
                    debugPrint('[ZenFile][Archive] 确定: 导航已触发');
                  } catch (e) {
                    debugPrint('[ZenFile][Archive] 确定: 导航异常 $e');
                  }
                },
                child: Text(l10n.ui_confirm, style: const TextStyle(color: Colors.white)),
              ),
              TextButton(
                onPressed: () {
                  scaffoldMessenger.hideCurrentSnackBar();
                },
                child: Text(l10n.ui_cancel, style: const TextStyle(color: Colors.white70)),
              ),
            ],
          ),
          backgroundColor: Colors.green,
          duration: const Duration(seconds: 8),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }

    // 完成后自动刷新「结果所在目录」：压缩包 / 解压产物立刻出现在列表里，
    // 不再需要用户手动下拉刷新（旧实现只有压缩会刷新，解压必须点弹窗里的
    // 「确定 → 打开所在位置」才会刷新）。
    // 只刷新用户当前正停留的目录：解压目标可能是别的目录（或用户已切到其它
    // 页面/标签），无条件 loadDirectory(destDir) 会把用户从当前位置拽走。
    if (!isError && destDir != null) {
      FileManagerProvider? provider = _refreshProvider;
      if (provider == null && _savedContext != null) {
        try {
          provider =
              Provider.of<FileManagerProvider>(_savedContext!, listen: false);
        } catch (e) {
          debugPrint('Error resolving provider for refresh: $e');
        }
      }
      if (provider != null) {
        if (provider.currentPath == destDir) {
          try {
            await provider.loadDirectory(destDir,
                showLoading: false, clearCache: true);
          } catch (e) {
            debugPrint('Error refreshing via provider: $e');
          }
        }
      } else if (onComplete != null) {
        try {
          await Future.delayed(Duration.zero, () {
            try {
              onComplete();
            } catch (_) {}
          });
        } catch (_) {}
      }
    }

    _finishPendingExtraction(
        isError ? _resultForErrorCode(errorCode) : ArchiveOpResult.success);
  }

  /// 把失败码映射成调用方语义。
  ArchiveOpResult _resultForErrorCode(String code) {
    switch (code) {
      case 'password_required':
        return ArchiveOpResult.passwordRequired;
      case 'password_invalid':
        return ArchiveOpResult.passwordInvalid;
      default:
        return ArchiveOpResult.failed;
    }
  }

  void _finishPendingExtraction(ArchiveOpResult result) {
    final completer = _extractResult;
    _extractResult = null;
    if (completer != null && !completer.isCompleted) {
      completer.complete(result);
    }
  }

  /// 把一个文件以「逐块 deflate + 逐块上报进度」的方式加入 ZIP。
  ///
  /// 背景：package:archive 3.6.1 的 `ZipEncoder.addFile` 对需压缩条目会先
  /// `content.toUint8List()` 整读、再 `Deflate(...).getBytes()` 同步压缩，中间
  /// 没有任何回调 —— 于是「压缩一个大文件」期间进度条一动不动，用户以为卡死。
  ///
  /// 这里改为自己分块 deflate 到临时文件，再把「已压缩数据」交给 ZipEncoder 透传
  /// （rawContent + DEFLATE + crc32）：输出与原生路径完全一致（central directory、
  /// WinZip-AES 加密仍由 encoder 统一生成），但
  /// 1) 每块之后都能上报真实字节进度（外圈 + 内圈）；
  /// 2) 不再需要把整文件读进内存（原生路径是整读 + deflate 输出双份）。
  ///
  /// 返回 false 表示本条未加入（调用方回退到 `enc.addFile`），确保任何异常都不会
  /// 让压缩失败。空文件也返回 false（走原生路径，代价可忽略）。
  static bool _addZipEntryWithProgress({
    required ZipFileEncoder enc,
    required File src,
    required String entryPath,
    required int fileSize,
    required int? level,
    required _ProgressThrottler t,
    required int processedBytesBefore,
    required int totalBytes,
    required int index,
    required int totalFiles,
  }) {
    if (fileSize <= 0) return false;

    File? tmp;
    RandomAccessFile? raf;
    OutputFileStream? out;
    try {
      tmp = File(p.join(Directory.systemTemp.path,
          'zenfile_zip_${DateTime.now().microsecondsSinceEpoch}_$index.tmp'));
      out = OutputFileStream(tmp.path);
      raf = src.openSync();

      final buf = Uint8List(_kChunkSize);
      Deflate? defl;
      int crc32 = 0;
      int processed = 0;

      while (true) {
        final n = raf.readIntoSync(buf, 0, buf.length);
        if (n <= 0) break;
        // 用 InputStream 包住本块，读完后校验 isEOS：deflate 在窗口尚未腾出
        // 空间时可能提前返回（zlib 的 need_more），残留数据必须继续喂给它，
        // 否则会静默丢字节 ⇒ 压缩包损坏。确认吃干净才继续读下一块。
        final inStream =
            n == buf.length ? InputStream(buf) : InputStream(buf, length: n);
        if (defl == null) {
          defl = Deflate.buffer(inStream,
              level: level, flush: Deflate.NO_FLUSH, output: out);
        } else {
          defl.addBuffer(inStream, flush: Deflate.NO_FLUSH);
        }
        if (!inStream.isEOS) {
          // 极端情况下没能吃下整块：放弃分块路径，由调用方回退到
          // archive 包原生单文件路径，保证输出正确性优先。
          debugPrint('[ZenFile][Archive] deflate 未消费完整块，回退原生路径');
          return false;
        }
        crc32 = getCrc32(n == buf.length ? buf : buf.sublist(0, n), crc32);
        processed += n;
        final denom = totalBytes <= 0 ? 1 : totalBytes;
        t.send(
          (0.10 + ((processedBytesBefore + processed) / denom) * 0.80)
              .clamp(0.0, 0.90),
          entryPath,
          bytesProcessed: processedBytesBefore + processed,
          totalBytes: totalBytes,
          currentFileBytes: processed,
          currentFileTotal: fileSize,
          currentIndex: index,
          totalFiles: totalFiles,
        );
      }

      if (defl == null) return false; // 读不到内容（文件消失等）：交给原生路径
      defl.addBytes(const <int>[], flush: Deflate.FINISH);
      defl.finish();
      out.closeSync();
      out = null;
      raf.closeSync();
      raf = null;

      // 用「已压缩数据」构造条目：ZipEncoder 会走 rawContent 透传分支，
      // 不再重复压缩；crc32 由我们分块算出，避免它再整读一遍。
      final afOut = ArchiveFile(
          entryPath, fileSize, InputFileStream(tmp.path), ArchiveFile.DEFLATE);
      afOut.crc32 = crc32;
      afOut.lastModTime =
          src.lastModifiedSync().millisecondsSinceEpoch ~/ 1000;
      afOut.mode = src.statSync().mode;
      enc.addArchiveFile(afOut); // 内部 autoClose：关闭 InputFileStream
      return true;
    } catch (e) {
      debugPrint('[ZenFile][Archive] 分块压缩回退原生路径: $e');
      return false;
    } finally {
      try { raf?.closeSync(); } catch (_) {}
      try { out?.closeSync(); } catch (_) {}
      try {
        if (tmp != null && tmp.existsSync()) tmp.deleteSync();
      } catch (_) {}
    }
  }

/// 压缩 isolate 入口：串行执行所有 job（逐文件模式下多个、单包模式一个），
/// 全部完成后才上报 completed。进度按 job 数分段折算，跨包连续。
static void _compressIsolateTask(Map<String, dynamic> args) async {
    final sendPort = args['sendPort'] as SendPort;
    final format = args['format'] as String;
    final level = args['level'] as int;
    final deleteSource = args['deleteSource'] as bool;
    final password = args['password'] as String?;
    final splitSizeMB = args['splitSizeMB'] as int?;
    final jobs = (args['jobs'] as List<dynamic>)
        .map((e) => e as Map<String, dynamic>)
        .toList();
    final t = _ProgressThrottler(sendPort);

    if (jobs.isEmpty) {
      sendPort.send({'status': 'error', 'error': 'No files to compress'});
      return;
    }

    try {
      for (int j = 0; j < jobs.length; j++) {
        final job = jobs[j];
        final base = j / jobs.length;
        final span = 1.0 / jobs.length;
        if (jobs.length > 1) {
          // 多包模式：每个包开始时强制刷新一次当前包名，让用户看到逐包进度
          t.send(base + 0.001, p.basename(job['destinationPath'] as String),
              force: true);
        }
        await _compressOneJob(
          sourcePaths: (job['sourcePaths'] as List<dynamic>).cast<String>(),
          destinationPath: job['destinationPath'] as String,
          format: format,
          level: level,
          deleteSource: deleteSource,
          password: password,
          splitSizeMB: splitSizeMB,
          sendPort: sendPort,
          progBase: base,
          progSpan: span,
        );
      }
      t.send(1.0, 'Archive created successfully', force: true);
      await Future.delayed(const Duration(milliseconds: 200));
      sendPort.send({'status': 'completed'});
    } catch (e, stackTrace) {
      final msg = 'Compression failed: ${e.toString()}';
      debugPrint('$msg\n$stackTrace');
      sendPort.send({'status': 'error', 'error': msg});
    }
  }

  /// 单个压缩任务的完整流程：扫描 → 编码 → 分卷切割 → 删除源文件。
  /// [progBase]/[progSpan] 把本任务 [0,1] 的进度折算到总进度的对应区间，
  /// 使逐文件压缩（多 job）时总进度条连续推进；单包时默认 0/1 不平移。
  static Future<void> _compressOneJob({
    required List<String> sourcePaths,
    required String destinationPath,
    required String format,
    required int level,
    required bool deleteSource,
    required String? password,
    required int? splitSizeMB,
    required SendPort sendPort,
    double progBase = 0.0,
    double progSpan = 1.0,
  }) async {
    final t =
        _ProgressThrottler(sendPort, progBase: progBase, progSpan: progSpan);

    t.send(0.0, 'Scanning files...', force: true);

    // ---- Phase 1：扫描并构建 plan（8% 以内）----
    final plan = _buildCompressionPlan(sourcePaths, t);
    if (plan.files.isEmpty && plan.emptyDirs.isEmpty) {
      throw Exception('No files to compress');
    }
    final normDest = destinationPath.toLowerCase();
    plan.files.removeWhere((e) => e.fullPath.toLowerCase() == normDest);

    final int totalBytes = plan.totalByteCount <= 0 ? 1 : plan.totalByteCount;
    int processedBytes = 0;

    // 扫描结束：此时总字节数已知，带上字节让弹窗立刻显示 "0 B / 总量"，
    // 而不是一直挂着 0 B / 0 B（看起来像没开始）。
    t.send(0.09, 'Starting compression…', force: true,
        bytesProcessed: 0, totalBytes: totalBytes);
    await Future<void>.delayed(Duration.zero);

    // ---- Phase 2：根据格式选压缩路径 ----
    // ZIP：逐条目「分块 deflate 到临时文件 → 交给 ZipFileEncoder 透传」
    // （_addZipEntryWithProgress）。package:archive 3.6.1 的 ZipFileEncoder.addFile
    // 对每个条目会整读 content + 一次性同步 deflate，期间没有任何回调：大文件
    // 压缩时进度条会从头到尾停着不动（真机反馈「以为卡死了」/「0 B / 0 B」），
    // 内存峰值也是「整文件 + 压缩结果」双份。改为分块后既能逐块上报真实进度，
    // 也不再需要整文件进内存；带密码时仍由 ZipEncoder 逐条目做 WinZip-AES 加密，
    // 密码经 zipEncodePassword 转 UTF-8 字节串，与 ArchiveService 编码路径及
    // decodeZip 的候选解密逻辑保持对称（第三方工具亦可正常解开）。
    if (format == 'zip') {
      final pw = password;
      final enc = ZipFileEncoder(
        password: (pw != null && pw.isNotEmpty)
            ? ArchiveService.zipEncodePassword(pw)
            : null,
      );
      enc.create(destinationPath, level: level);
      int compressedBytes = 0;
      try {
        for (int i = 0; i < plan.files.length; i++) {
          final entry = plan.files[i];
          final src = File(entry.fullPath);
          if (!src.existsSync()) continue;
          final fileSize = src.lengthSync();
          // 切到当前文件：先报一次 0 字节，让「当前文件」与内圈立刻跟随
          t.send(0.10 + (compressedBytes / totalBytes) * 0.80, entry.relPath,
              bytesProcessed: compressedBytes,
              totalBytes: totalBytes,
              currentFileBytes: 0,
              currentFileTotal: fileSize,
              currentIndex: i + 1,
              totalFiles: plan.files.length);
          // 分块 deflate + 逐块上报真实进度；失败则回退 archive 包原生单文件路径
          // （原生路径整读整压、期间无进度，只作为兜底）。
          final ok = _addZipEntryWithProgress(
            enc: enc,
            src: src,
            entryPath: entry.relPath,
            fileSize: fileSize,
            level: level,
            t: t,
            processedBytesBefore: compressedBytes,
            totalBytes: totalBytes,
            index: i + 1,
            totalFiles: plan.files.length,
          );
          if (!ok) {
            await enc.addFile(src, entry.relPath);
          }
          compressedBytes += fileSize;
          // 修：此前这里的 prog 是「本文件开始前」算出来的，导致整包进度永远
          // 落后一个文件（多文件时最后一格不动）。现在按累加后的字节重算。
          t.send(
              (0.10 + (compressedBytes / totalBytes) * 0.80).clamp(0.0, 0.90),
              entry.relPath,
              bytesProcessed: compressedBytes,
              totalBytes: totalBytes,
              currentFileBytes: fileSize,
              currentFileTotal: fileSize,
              currentIndex: i + 1,
              totalFiles: plan.files.length);
          // 让出事件循环：进度消息经 SendPort 到达主 isolate 后能被及时处理
          await Future<void>.delayed(Duration.zero);
        }
        for (final d in plan.emptyDirs) {
          final normalized = d.endsWith('/') ? d : '$d/';
          final af = ArchiveFile(normalized, 0, null);
          af.isFile = false;
          enc.addArchiveFile(af);
        }
        // 加密包在 encoder 收尾时还要做一遍 AES（整包同步，无法细分进度），
        // 文案上明确告知，避免用户以为停在 95% 卡死。
        t.send(0.95, (pw != null && pw.isNotEmpty) ? 'Encrypting…' : 'Finalizing…',
            force: true,
            bytesProcessed: compressedBytes, totalBytes: totalBytes);
        await enc.close();
      } catch (e) {
        try { enc.closeSync(); } catch (_) {}
        rethrow;
      }
    } else if (format == 'tar') {
      // TarEncoder.add → TarFile.write → output.writeInputStream(InputStreamBase) 是真流式，
      // 不会整包 toUint8List，可以继续用。
      final output = OutputFileStream(destinationPath);
      final enc = TarEncoder();
      enc.start(output);
      for (int i = 0; i < plan.files.length; i++) {
        final entry = plan.files[i];
        final src = File(entry.fullPath);
        if (!src.existsSync()) continue;
        final size = src.lengthSync();
        t.send(0.10 + (processedBytes / totalBytes) * 0.88, entry.relPath,
            currentFileBytes: 0, currentFileTotal: size,
            currentIndex: i + 1, totalFiles: plan.files.length);
        final fileStream = InputFileStream(src.path);
        final af = ArchiveFile.stream(entry.relPath, size, fileStream);
        af.lastModTime = src.lastModifiedSync().millisecondsSinceEpoch ~/ 1000;
        af.mode = src.statSync().mode;
        enc.add(af);
        fileStream.closeSync();
        processedBytes += size;
        t.send(0.10 + (processedBytes / totalBytes) * 0.88, entry.relPath,
            currentFileBytes: size, currentFileTotal: size,
            currentIndex: i + 1, totalFiles: plan.files.length);
        await Future<void>.delayed(Duration.zero);
      }
      for (final d in plan.emptyDirs) {
        final normalized = d.endsWith('/') ? d : '$d/';
        final af = ArchiveFile(normalized, 0, null);
        af.isFile = false;
        enc.add(af);
      }
      enc.finish();
      output.closeSync();
    } else {
      // tar.gz / tar.bz2 / tar.lz4 / tar.zst：先生成 TAR 临时文件，再流式编码外层。
      // TAR 临时文件：TarEncoder 是真流式；tar.gz 用 GZipEncoder（Deflate.buffer）。
      final tmpDir = Directory.systemTemp;
      final tarTmp = File(p.join(tmpDir.path, 'zenfile_compress_${DateTime.now().millisecondsSinceEpoch}.tar'));
      try {
        // Step 2a：流式写出 TAR（0.10 → 0.55 用 bytes 推进）
        final output = OutputFileStream(tarTmp.path);
        final enc = TarEncoder();
        enc.start(output);
        for (int i = 0; i < plan.files.length; i++) {
          final entry = plan.files[i];
          final src = File(entry.fullPath);
          if (!src.existsSync()) continue;
          final size = src.lengthSync();
          t.send(0.10 + (processedBytes / totalBytes) * 0.45, entry.relPath,
              currentFileBytes: 0, currentFileTotal: size,
              currentIndex: i + 1, totalFiles: plan.files.length);
          final fileStream = InputFileStream(src.path);
          final af = ArchiveFile.stream(entry.relPath, size, fileStream);
          af.lastModTime = src.lastModifiedSync().millisecondsSinceEpoch ~/ 1000;
          af.mode = src.statSync().mode;
          enc.add(af);
          fileStream.closeSync();
          processedBytes += size;
          t.send(0.10 + (processedBytes / totalBytes) * 0.45, entry.relPath,
              currentFileBytes: size, currentFileTotal: size,
              currentIndex: i + 1, totalFiles: plan.files.length);
          await Future<void>.delayed(Duration.zero);
        }
        for (final d in plan.emptyDirs) {
          final normalized = d.endsWith('/') ? d : '$d/';
          final af = ArchiveFile(normalized, 0, null);
          af.isFile = false;
          enc.add(af);
        }
        enc.finish();
        output.closeSync();

        // Step 2b：把 TAR 流式编码到目标压缩格式（按字节推进 0.55 → 0.98）
        t.send(0.56, 'Encoding $format archive…', force: true);
        await _encodeTarToCompressedFormat(tarTmp, destinationPath, format, level, t);
      } finally {
        if (tarTmp.existsSync()) {
          try { tarTmp.deleteSync(); } catch (_) {}
        }
      }
    }

    t.send(0.985, 'Finalizing…', force: true);

    // ---- Phase 2.5：分卷切割（如果需要）----
    // 与 ArchiveService._splitArchiveIntoParts 同策略：按 chunkSize 分块 IO，
    // 不把整个压缩包读入 RAM；产出 dest.001 / dest.002 …，并删除未分卷的整包。
    // 逐文件模式下每个 job 各自独立分卷。
    if (splitSizeMB != null && splitSizeMB > 0) {
      final chunkSize = splitSizeMB * 1024 * 1024;
      final srcFile = File(destinationPath);
      if (srcFile.existsSync()) {
        final total = srcFile.lengthSync();
        if (total > chunkSize) {
          _splitFileIntoParts(srcFile, destinationPath, chunkSize);
          srcFile.deleteSync();
        }
      }
    }

    // ---- Phase 3：删除源文件 ----
    if (deleteSource) {
      for (final path in sourcePaths) {
        try {
          final type = FileSystemEntity.typeSync(path);
          if (type == FileSystemEntityType.directory) {
            Directory(path).deleteSync(recursive: true);
          } else if (type == FileSystemEntityType.file) {
            File(path).deleteSync();
          }
        } catch (_) {}
      }
    }
  }

  /// 把已生成的压缩包按 chunkSize 切成 .001/.002… 分卷（分块 IO，不整包读入内存）。
  /// 与 ArchiveService._splitArchiveIntoParts 行为一致：调用方负责删除原整包。
  static void _splitFileIntoParts(File srcFile, String destBase, int chunkSize) {
    final raf = srcFile.openSync();
    try {
      final total = raf.lengthSync();
      final buf = Uint8List(chunkSize);
      int remaining = total;
      int partNum = 1;
      while (remaining > 0) {
        final toRead = remaining > chunkSize ? chunkSize : remaining;
        final read = raf.readIntoSync(buf, 0, toRead);
        if (read <= 0) break;
        final partExt = partNum.toString().padLeft(3, '0');
        final partFile = File('$destBase.$partExt');
        final partRaf = partFile.openSync(mode: FileMode.write);
        try {
          if (read == chunkSize) {
            partRaf.writeFromSync(buf);
          } else {
            partRaf.writeFromSync(Uint8List.fromList(buf.sublist(0, read)));
          }
        } finally {
          partRaf.closeSync();
        }
        remaining -= read;
        partNum++;
      }
    } finally {
      raf.closeSync();
    }
  }

  /// 生成不冲突的压缩包路径：目标已存在时按 name(1).ext / name(2).ext 递增，
  /// 与普通单包路径的自动重命名行为一致，避免逐文件模式静默覆盖已有文件。
  static String _uniqueArchivePath(String dest) {
    if (!File(dest).existsSync()) return dest;
    final dir = p.dirname(dest);
    final base = p.basenameWithoutExtension(dest);
    final ext = p.extension(dest);
    int counter = 1;
    String candidate;
    do {
      candidate = p.join(dir, '$base($counter)$ext');
      counter++;
    } while (File(candidate).existsSync());
    return candidate;
  }

  /// 把已生成的 TAR 文件根据格式编码成对应压缩格式，流式读写，不把整包一次性读入内存。
  static Future<void> _encodeTarToCompressedFormat(
      File tarFile, String destinationPath, String format, int level, _ProgressThrottler t) async {
    final int total = tarFile.lengthSync();
    if (total <= 0) {
      tarFile.copySync(destinationPath);
      return;
    }

    try {
      int processed = 0;

      if (format == 'tar.gz') {
        // tar.gz：GZipEncoder 流式 InputFileStream -> OutputFileStream
        final input = InputFileStream(tarFile.path);
        final outStream = OutputFileStream(destinationPath);
        try {
          GZipEncoder().encode(input, level: level, output: outStream);
        } finally {
          try { input.closeSync(); } catch (_) {}
          try { outStream.closeSync(); } catch (_) {}
        }
        t.send(0.98, 'tar.gz encoded', force: true);
      } else if (format == 'tar.bz2') {
        final output = File(destinationPath)..createSync(recursive: true);
        final sink = output.openWrite();
        try {
          if (total > 1024 * 1024 * 1024) {
            // 过大时直接降级为复制 tar
            final raf = tarFile.openSync();
            try {
              final buf = Uint8List(_kChunkSize);
              while (true) {
                final read = raf.readIntoSync(buf);
                if (read <= 0) break;
                processed += read;
                if (read == _kChunkSize) {
                  sink.add(buf);
                } else {
                  sink.add(Uint8List.fromList(buf.sublist(0, read)));
                }
                t.send(0.56 + (processed / total) * 0.4, 'Copying tar (too large for bz2)…');
                await Future<void>.delayed(Duration.zero);
              }
            } finally { raf.closeSync(); }
          } else {
            final bytesBuilder = BytesBuilder(copy: false);
            final raf = tarFile.openSync();
            try {
              final buf = Uint8List(_kChunkSize);
              while (true) {
                final read = raf.readIntoSync(buf);
                if (read <= 0) break;
                processed += read;
                if (read == _kChunkSize) {
                  bytesBuilder.add(buf);
                } else {
                  bytesBuilder.add(Uint8List.fromList(buf.sublist(0, read)));
                }
                t.send(0.56 + (processed / total) * 0.4, 'Reading tar…');
              }
            } finally { raf.closeSync(); }
            t.send(0.96, 'Applying BZ2…', force: true);
            final raw = bytesBuilder.takeBytes();
            final encoded = BZip2Encoder().encode(raw);
            if (encoded.isNotEmpty) sink.add(encoded);
          }
          await sink.flush();
          await sink.close();
        } catch (_) {
          try { await sink.close(); } catch (_) {}
          rethrow;
        }
      } else if (format == 'tar.lz4') {
        final output = File(destinationPath)..createSync(recursive: true);
        final sink = output.openWrite();
        try {
          if (total > 512 * 1024 * 1024) {
            final raf = tarFile.openSync();
            try {
              final buf = Uint8List(_kChunkSize);
              while (true) {
                final read = raf.readIntoSync(buf);
                if (read <= 0) break;
                processed += read;
                if (read == _kChunkSize) {
                  sink.add(buf);
                } else {
                  sink.add(Uint8List.fromList(buf.sublist(0, read)));
                }
                t.send(0.56 + (processed / total) * 0.4, 'Copying tar (too large for lz4)…');
                await Future<void>.delayed(Duration.zero);
              }
            } finally { raf.closeSync(); }
          } else {
            final bb = BytesBuilder(copy: false);
            final raf = tarFile.openSync();
            try {
              final buf = Uint8List(_kChunkSize);
              while (true) {
                final read = raf.readIntoSync(buf);
                if (read <= 0) break;
                processed += read;
                bb.add(read == _kChunkSize ? buf : Uint8List.fromList(buf.sublist(0, read)));
                t.send(0.56 + (processed / total) * 0.4, 'Reading tar…');
              }
            } finally { raf.closeSync(); }
            t.send(0.96, 'Applying LZ4…', force: true);
            final raw = bb.takeBytes();
            final encoded = lz4FrameEncode(raw);
            if (encoded.isNotEmpty) sink.add(encoded);
          }
          await sink.flush();
          await sink.close();
        } catch (_) {
          try { await sink.close(); } catch (_) {}
          rethrow;
        }
      } else if (format == 'tar.zst') {
        final output = File(destinationPath)..createSync(recursive: true);
        final sink = output.openWrite();
        try {
          if (total > 512 * 1024 * 1024) {
            final raf = tarFile.openSync();
            try {
              final buf = Uint8List(_kChunkSize);
              while (true) {
                final read = raf.readIntoSync(buf);
                if (read <= 0) break;
                processed += read;
                if (read == _kChunkSize) {
                  sink.add(buf);
                } else {
                  sink.add(Uint8List.fromList(buf.sublist(0, read)));
                }
                t.send(0.56 + (processed / total) * 0.4, 'Copying tar (too large for zst)…');
                await Future<void>.delayed(Duration.zero);
              }
            } finally { raf.closeSync(); }
          } else {
            final bb = BytesBuilder(copy: false);
            final raf = tarFile.openSync();
            try {
              final buf = Uint8List(_kChunkSize);
              while (true) {
                final read = raf.readIntoSync(buf);
                if (read <= 0) break;
                processed += read;
                bb.add(read == _kChunkSize ? buf : Uint8List.fromList(buf.sublist(0, read)));
                t.send(0.56 + (processed / total) * 0.4, 'Reading tar…');
              }
            } finally { raf.closeSync(); }
            t.send(0.96, 'Applying ZSTD…', force: true);
            final raw = bb.takeBytes();
            final encoded = const ZstdEncoder().encodeBytes(raw);
            if (encoded.isNotEmpty) sink.add(encoded);
          }
          await sink.flush();
          await sink.close();
        } catch (_) {
          try { await sink.close(); } catch (_) {}
          rethrow;
        }
      } else {
        // 格式未知：复制 TAR
        await tarFile.copy(destinationPath);
      }
    } catch (_) {
      rethrow;
    }
  }

  /// 修复 ZIP 文件中非 UTF-8 编码的文件名（如 GBK 编码的中文文件名）
  static String _fixZipFilename(String name) {
    bool hasGarbled = false;
    for (int i = 0; i < name.length; i++) {
      final codeUnit = name.codeUnitAt(i);
      if (codeUnit >= 0x80 && codeUnit <= 0xFF) {
        hasGarbled = true;
        break;
      }
    }
    if (!hasGarbled) return name;

    try {
      final bytes = name.codeUnits;
      final decoded = gbk.decode(bytes);
      return decoded;
    } catch (_) {
      return name;
    }
  }

  static void _extractIsolateTask(Map<String, dynamic> args) async {
    final sendPort = args['sendPort'] as SendPort;
    final archivePath = args['archivePath'] as String;
    final destinationDir = args['destinationDir'] as String;
    final password = args['password'] as String?;
    final t = _ProgressThrottler(sendPort);

    String? tempTarPath;

    try {
      t.send(0.0, 'Reading archive…', force: true);
      final file = File(archivePath);
      if (!file.existsSync()) {
        sendPort.send({'status': 'error', 'error': 'Archive file not found'});
        return;
      }
      final int totalArchiveBytes = file.lengthSync();
      final lowerPath = archivePath.toLowerCase();

      // ===== 单文件解压器（.gz / .bz2 / .lz4 / .zst）：优先流式，全程不存大字节数组 =====
      if (lowerPath.endsWith('.gz') &&
          !lowerPath.endsWith('.tar.gz') &&
          !lowerPath.endsWith('.tgz')) {
        await _extractSingleFileGzStream(file, destinationDir, t);
        t.send(1.0, 'Archive extracted successfully', force: true);
        await Future.delayed(const Duration(milliseconds: 200));
        sendPort.send({'status': 'completed'});
        return;
      }
      if (lowerPath.endsWith('.bz2') && !lowerPath.endsWith('.tar.bz2') && !lowerPath.endsWith('.tbz2')) {
        await _extractSingleFile(file, destinationDir, (bytes, total) {
          return BZip2Decoder().decodeBytes(bytes);
        }, t, totalArchiveBytes, 'Decoding BZ2…');
        t.send(1.0, 'Archive extracted successfully', force: true);
        await Future.delayed(const Duration(milliseconds: 200));
        sendPort.send({'status': 'completed'});
        return;
      }
      if (lowerPath.endsWith('.lz4') && !lowerPath.endsWith('.tar.lz4') && !lowerPath.endsWith('.tlz4')) {
        await _extractSingleFile(file, destinationDir, (bytes, total) {
          return lz4FrameDecode(bytes);
        }, t, totalArchiveBytes, 'Decoding LZ4…');
        t.send(1.0, 'Archive extracted successfully', force: true);
        await Future.delayed(const Duration(milliseconds: 200));
        sendPort.send({'status': 'completed'});
        return;
      }
      if ((lowerPath.endsWith('.zst') || lowerPath.endsWith('.zstd')) &&
          !lowerPath.endsWith('.tar.zst') &&
          !lowerPath.endsWith('.tzst')) {
        await _extractSingleFile(file, destinationDir, (bytes, total) {
          return const ZstdDecoder().decodeBytes(bytes);
        }, t, totalArchiveBytes, 'Decoding ZSTD…');
        t.send(1.0, 'Archive extracted successfully', force: true);
        await Future.delayed(const Duration(milliseconds: 200));
        sendPort.send({'status': 'completed'});
        return;
      }

      // ===== .7z / .rar：koni_archive 纯 Dart 解码（RAR4/RAR5、7z AES-256，支持密码） =====
      if (ArchiveService.isKoniArchivePath(lowerPath)) {
        t.send(0.05, 'Preparing to extract…', force: true);
        await ArchiveService.extractKoniArchive(
          archivePath: archivePath,
          destinationDir: destinationDir,
          password: password,
          wrapInSubfolder: true,
          onProgress: (currentFile, bytesProcessed, totalBytes, currentFileBytes,
              currentFileTotal, progress, currentIndex, totalFiles) {
            t.send(0.10 + progress * 0.90, currentFile,
                bytesProcessed: bytesProcessed,
                totalBytes: totalBytes,
                currentFileBytes: currentFileBytes,
                currentFileTotal: currentFileTotal,
                currentIndex: currentIndex,
                totalFiles: totalFiles);
          },
        );
        t.send(1.0, 'Archive extracted successfully', force: true);
        await Future.delayed(const Duration(milliseconds: 200));
        sendPort.send({'status': 'completed'});
        return;
      }

      // ===== 归档类：ZIP / TAR / TAR.* =====
      t.send(0.05, 'Preparing to extract…', force: true);

      late Archive archive;
      // 需要保持引用以便在所有文件提取完成后才关闭
      InputFileStream? zipInputToClose;
      // 注意：tempTarPath 在方法开头已声明（供 finally 清理），此处不得重新声明，
      // 否则外层变量永远是 null ⇒ TAR.* 解压留下的临时文件再也不会被删除。

      if (lowerPath.endsWith('.zip') || lowerPath.contains('.zip.')) {
        final input = InputFileStream(archivePath);
        zipInputToClose = input;
        // requirePasswordIfEncrypted：加密 ZIP 且没给密码时立刻抛
        // ArchivePasswordRequiredException，而不是让 archive 包解出「空内容」——
        // 后者会静默写出一堆 0 字节文件，用户误以为压缩包损坏（真机反馈）。
        archive = ArchiveService.decodeZip(
          input,
          (password != null && password.isNotEmpty) ? password : null,
          requirePasswordIfEncrypted: true,
        );
      } else if (lowerPath.endsWith('.tar')) {
        final input = InputFileStream(archivePath);
        archive = TarDecoder().decodeBuffer(input);
        try { input.closeSync(); } catch (_) {}
      } else {
        // TAR.*：优先用「流式解压外层 → 临时 TAR 文件 → TarDecoder 读临时文件」
        t.send(0.07, 'Unwrapping outer compression…', force: true);
        tempTarPath = await _streamDecompressToTar(file, 'tar', t);

        final input = InputFileStream(tempTarPath);
        archive = TarDecoder().decodeBuffer(input);
        try { input.closeSync(); } catch (_) {}
      }

      // 在 try 块外声明变量，以便在 finally 块后访问
      int totalExtractBytes = 0;
      int extractedBytes = 0;

      try {
        t.send(0.28, 'Analyzing archive structure…', force: true);

        // 分析根目录结构，判断是否自动创建子文件夹
        final rootEntries = <String>{};
        for (int i = 0; i < archive.length; i++) {
          final name = _fixZipFilename(archive[i].name);
          if (name.isEmpty || name == '/') continue;
          final firstSegment = name.split('/').first;
          if (firstSegment.isNotEmpty) rootEntries.add(firstSegment);
        }

        final bool shouldCreateFolder;
        if (rootEntries.length == 1) {
          final singleEntry = rootEntries.first;
          final isFolder = archive.any((f) {
            final n = _fixZipFilename(f.name);
            return n == singleEntry || n.startsWith('$singleEntry/');
          }) && archive.any((f) {
            final n = _fixZipFilename(f.name);
            return n.startsWith('$singleEntry/');
          });
          shouldCreateFolder = !isFolder;
        } else {
          shouldCreateFolder = true;
        }

        String actualDestDir = destinationDir;
        if (shouldCreateFolder) {
          final archiveBaseName = p.basenameWithoutExtension(archivePath);
          actualDestDir = p.join(destinationDir, archiveBaseName);
          Directory(actualDestDir).createSync(recursive: true);
        }

        final totalFiles = archive.length;
        // 计算总字节数（用于速度/ETA 计算）
        for (final f in archive) {
          if (f.isFile) totalExtractBytes += f.size;
        }
        for (int i = 0; i < totalFiles; i++) {
          final fileEntry = archive[i];
          final filename = _fixZipFilename(fileEntry.name);
          final fileTotal = fileEntry.isFile ? fileEntry.size : 0;
          // 进度按「已解出字节 / 总字节」折算：只按文件数会导致单个大文件期间
          // 外圈进度完全不动（用户反馈「解压进度条没有转动」）。
          double overallProgress(int bytes) {
            if (totalExtractBytes <= 0) return 0.30 + (i / totalFiles) * 0.70;
            return (0.30 + (bytes / totalExtractBytes) * 0.70).clamp(0.30, 0.99);
          }
          t.send(overallProgress(extractedBytes), filename,
              bytesProcessed: extractedBytes,
              totalBytes: totalExtractBytes,
              currentFileBytes: 0,
              currentFileTotal: fileTotal,
              currentIndex: i + 1,
              totalFiles: totalFiles);

          final outPath = p.join(actualDestDir, filename);
          if (fileEntry.isFile) {
            final outFile = File(outPath);
            outFile.createSync(recursive: true);
            final dynamic content = fileEntry.content;
            // 内容取不到（加密条目缺密码、条目已损坏等）时宁可整包报错，
            // 也不要静默产出 0 字节文件让用户以为是压缩包损坏。
            if (content == null && fileEntry.size > 0) {
              throw ArchiveContentUnavailableException(filename);
            }
            await _streamWriteArchiveFile(content, outFile,
                onChunkWritten: (written) {
              t.send(overallProgress(extractedBytes + written), filename,
                  bytesProcessed: extractedBytes + written,
                  totalBytes: totalExtractBytes,
                  currentFileBytes: written,
                  currentFileTotal: fileTotal,
                  currentIndex: i + 1,
                  totalFiles: totalFiles);
            });
            extractedBytes += fileEntry.size;
          } else {
            Directory(outPath).createSync(recursive: true);
          }
          if (i & 15 == 15) {
            await Future<void>.delayed(Duration.zero);
          }
        }
      } finally {
        // ✅ 在所有文件提取完成后才关闭 ZIP 输入流
        if (zipInputToClose != null) {
          try { zipInputToClose.closeSync(); } catch (_) {}
        }
      }

      t.send(1.0, 'Archive extracted successfully', force: true, bytesProcessed: extractedBytes, totalBytes: totalExtractBytes);
      await Future.delayed(const Duration(milliseconds: 200));
      sendPort.send({'status': 'completed'});
    } catch (e, stackTrace) {
      final msg = 'Extraction failed: ${e.toString()}';
      debugPrint('$msg\n$stackTrace');
      // 分类上报失败原因：密码类问题由调用方弹窗重试，不再只往日志里丢。
      final code = ArchiveService.classifyError(e);
      sendPort.send({'status': 'error', 'error': e.toString(), 'code': code});
    } finally {
      final tarTmp = tempTarPath;
      if (tarTmp != null && tarTmp.isNotEmpty) {
        try {
          final f = File(tarTmp);
          if (f.existsSync()) f.deleteSync();
        } catch (_) {}
      }
    }
  }

  /// 单文件 .gz：用 GZipDecoder.decodeStream 流式解码，全程不驻留整包字节。
  static Future<void> _extractSingleFileGzStream(File src, String destDir, _ProgressThrottler t) async {
    final name = p.basenameWithoutExtension(src.path);
    final out = File(p.join(destDir, name))..createSync(recursive: true);

    try {
      final input = InputFileStream(src.path);
      final output = OutputFileStream(out.path);
      try {
        GZipDecoder().decodeStream(input, output);
        output.flush();
      } finally {
        try { input.closeSync(); } catch (_) {}
        try { output.closeSync(); } catch (_) {}
      }
      t.send(0.95, 'Decoded GZ stream…');
    } finally {
    }
  }

  /// 解压单文件压缩包（bz2/lz4/zst，这些库目前没有流式 API）：
  /// 小文件走同步；大文件仍要兜底，但至少分块写输出，降低峰值内存。
  static Future<void> _extractSingleFile(
    File src,
    String destDir,
    List<int> Function(Uint8List bytes, int totalLen) decoder,
    _ProgressThrottler t,
    int totalBytes,
    String stageLabel,
  ) async {
    final name = p.basenameWithoutExtension(src.path);
    final out = File(p.join(destDir, name))..createSync(recursive: true);

    if (totalBytes > 128 * 1024 * 1024) {
      t.send(0.15, 'Reading $stageLabel (large file)…', force: true);
      final bytes = await src.readAsBytes();
      t.send(0.55, 'Applying decoder…', force: true);
      final decoded = decoder(Uint8List.fromList(bytes), totalBytes);
      t.send(0.88, 'Writing output…', force: true);
      await _streamWriteArchiveFile(decoded, out);
    } else {
      t.send(0.2, 'Reading…', force: true);
      final bytes = await src.readAsBytes();
      t.send(0.6, stageLabel, force: true);
      final decoded = decoder(Uint8List.fromList(bytes), totalBytes);
      t.send(0.92, 'Writing output…', force: true);
      if (decoded.isNotEmpty) {
        await out.writeAsBytes(decoded is Uint8List ? decoded : Uint8List.fromList(decoded));
      }
    }
  }
}
