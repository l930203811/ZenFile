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
  int _lastSentMs = 0;
  double _lastProgress = -1;
  String _lastFile = '';
  int _lastBytes = -1;
  _ProgressThrottler(this.sendPort);

  void send(double progress, String currentFile, {bool force = false, int bytesProcessed = 0, int totalBytes = 0}) {
    final now = DateTime.now().millisecondsSinceEpoch;
    final bool changed = (progress - _lastProgress).abs() > 0.001 || currentFile != _lastFile || (bytesProcessed - _lastBytes).abs() > 1024 * 1024;
    if (!force && !changed) return;
    if (!force && now - _lastSentMs < 100 && progress < 0.999) return;
    _lastSentMs = now;
    _lastProgress = progress;
    _lastFile = currentFile;
    _lastBytes = bytesProcessed;
    sendPort.send({
      'status': 'progress',
      'progress': progress.clamp(0.0, 1.0),
      'currentFile': currentFile,
      'bytesProcessed': bytesProcessed,
      'totalBytes': totalBytes,
    });
  }
}

/// 流式把一个大文件分块拷贝到目的地（输入/输出为抽象的「块写入」回调），
/// 避免 readAsBytes / writeAsBytes 在大文件（>2GB 或 RAM 有限）时 OOM 崩溃。
/// 单块 1 MB；在 copy 过程中按字节数累加进度。
const int _kChunkSize = 1024 * 1024; // 1 MiB

/// 把 ArchiveFile 的内容流式分块写到输出文件，避免大文件一次性 writeAsBytes 导致内存峰值。
/// ArchiveFile 的 content 可能是 `List<int>` 或内部 InputStream 实现；这里统一按块提取和写出。
Future<void> _streamWriteArchiveFile(dynamic content, File outFile, {int chunkSize = _kChunkSize}) async {
  final sink = outFile.openWrite();
  try {
    if (content is List<int>) {
      final bytes = content;
      if (bytes.length <= chunkSize) {
        if (bytes.isNotEmpty) sink.add(bytes);
      } else {
        for (int i = 0; i < bytes.length; i += chunkSize) {
          final end = (i + chunkSize > bytes.length) ? bytes.length : i + chunkSize;
          sink.add(Uint8List.fromList(bytes.sublist(i, end)));
          await sink.flush();
          await Future<void>.delayed(Duration.zero);
        }
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
  });
}

class _FileEntry {
  final String fullPath;
  final String relPath;
  _FileEntry(this.fullPath, this.relPath);
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

  /// 捕获的 ScaffoldMessengerState：在显示 bottom sheet / dialog 之前尽早保存
  ScaffoldMessengerState? _scaffoldMessenger;

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
  }) async {
    final effectiveContext = context.mounted ? context : (navigatorKey.currentContext ?? context);
    final archiveName = p.basename(destinationPath);
    final operation = BackgroundOperation(
      id: 'compress_${DateTime.now().millisecondsSinceEpoch}',
      title: L10n.of(effectiveContext).msg2f0138ad,
      archiveName: archiveName,
      isCompression: true,
      destinationDir: targetRefreshDir ?? p.dirname(destinationPath),
      destinationPath: destinationPath,
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
        'sourcePaths': sourcePaths,
        'destinationPath': destinationPath,
        'format': format,
        'level': level,
        'deleteSource': deleteSource,
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
          _onOperationComplete(effectiveContext, operation, 'Compression failed: $error', isError: true);
        }
      }
    });
  }

  Future<void> startExtraction({
    required BuildContext context,
    required String archivePath,
    required String destinationDir,
    String? password,
  }) async {
    final archiveName = p.basename(archivePath);
    final operation = BackgroundOperation(
      id: 'extract_${DateTime.now().millisecondsSinceEpoch}',
      title: L10n.of(context).msg0683ca6b,
      archiveName: archiveName,
      isCompression: false,
      destinationDir: destinationDir,
    );

    activeOperation.value = operation;
    _scaffoldMessenger ??= ScaffoldMessenger.of(context);

    _dialogCloseTimer?.cancel();
    _dialogCloseTimer = null;

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
          _onOperationComplete(context, operation, 'Extraction failed: $error', isError: true);
        }
      }
    });
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
      await _channel.invokeMethod('showProgressNotification', {
        'id': operation.id.hashCode,
        'title': operation.title,
        'message': '${operation.archiveName} ($progressInt%)',
        'progress': progressInt,
        'max': 100,
        'indeterminate': operation.progress <= 0.0,
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

  void _onOperationComplete(BuildContext context, BackgroundOperation operation, String message, {bool isError = false}) async {
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
                    final provider = Provider.of<FileManagerProvider>(context, listen: false);
                    String highlightPath;
                    if (isCompress && destPath != null) {
                      highlightPath = destPath;
                    } else {
                      final baseName = p.basenameWithoutExtension(archiveName);
                      highlightPath = p.join(nonNullDestDir, baseName);
                    }
                    provider.setNavigateToBrowseTab(true);
                    Navigator.popUntil(context, (route) => route.isFirst);
                    scheduleMicrotask(() {
                      provider.showFileInLocation(highlightPath);
                    });
                  } catch (_) {}
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

    if (!isError && isCompress && destDir != null) {
      bool refreshed = false;

      if (_refreshProvider != null) {
        try {
          await _refreshProvider!.loadDirectory(destDir, showLoading: false, clearCache: true);
          refreshed = true;
        } catch (e) {
          debugPrint('Error refreshing via provider: $e');
        }
      }

      if (!refreshed && _savedContext != null) {
        try {
          final provider = Provider.of<FileManagerProvider>(_savedContext!, listen: false);
          await provider.loadDirectory(destDir, showLoading: false, clearCache: true);
          refreshed = true;
        } catch (e) {
          debugPrint('Error refreshing via saved context: $e');
        }
      }

      if (!refreshed && onComplete != null) {
        try {
          await Future.delayed(Duration.zero, () {
            try {
              onComplete();
            } catch (_) {}
          });
        } catch (_) {}
      }

      if (!refreshed) {
        try {
          scheduleMicrotask(() {
            _refreshProvider?.loadDirectory(destDir, showLoading: false, clearCache: true);
          });
        } catch (_) {}
      }
    }
  }

  static void _compressIsolateTask(Map<String, dynamic> args) async {
    final sendPort = args['sendPort'] as SendPort;
    final sourcePaths = args['sourcePaths'] as List<String>;
    final destinationPath = args['destinationPath'] as String;
    final format = args['format'] as String;
    final level = args['level'] as int;
    final deleteSource = args['deleteSource'] as bool;
    final t = _ProgressThrottler(sendPort);

    try {
      t.send(0.0, 'Scanning files...', force: true);

      // ---- Phase 1：扫描并构建 plan（8% 以内）----
      final plan = _buildCompressionPlan(sourcePaths, t);
      if (plan.files.isEmpty && plan.emptyDirs.isEmpty) {
        sendPort.send({'status': 'error', 'error': 'No files to compress'});
        return;
      }
      final normDest = destinationPath.toLowerCase();
      plan.files.removeWhere((e) => e.fullPath.toLowerCase() == normDest);

      final int totalBytes = plan.totalByteCount <= 0 ? 1 : plan.totalByteCount;
      int processedBytes = 0;

      t.send(0.09, 'Starting compression…', force: true);
      await Future<void>.delayed(Duration.zero);

      // ---- Phase 2：根据格式选压缩路径 ----
      // ZIP：把所有文件读进内存 → 构建 Archive → ZipEncoder().encode() 一次性编码 → 写盘
      // 和 NFile 参考实现同方案，archive 包内部处理 ZIP 格式细节（Local Header / Central Dir / EOCD），
      // 绝对不会出现手写流式时 deflate stream 损坏的问题。
      // 大文件 OOM 风险：运行在独立 isolate 中，即便 OOM 也只杀 isolate 不杀主进程。
      if (format == 'zip') {
        final archive = Archive();
        int compressedBytes = 0;
        final totalBytes = plan.totalByteCount;
        for (int i = 0; i < plan.files.length; i++) {
          final entry = plan.files[i];
          final src = File(entry.fullPath);
          if (!src.existsSync()) continue;
          final bytes = src.readAsBytesSync();
          archive.addFile(ArchiveFile(entry.relPath, bytes.length, bytes));
          compressedBytes += bytes.length;
          final double prog = 0.10 + (i / plan.files.length) * 0.40;
          t.send(prog, entry.relPath, bytesProcessed: compressedBytes, totalBytes: totalBytes);
        }
        for (final d in plan.emptyDirs) {
          final normalized = d.endsWith('/') ? d : '$d/';
          final af = ArchiveFile(normalized, 0, null);
          af.isFile = false;
          archive.addFile(af);
        }
        t.send(0.55, 'Compressing ZIP...', force: true, bytesProcessed: compressedBytes, totalBytes: totalBytes);
        final encodedBytes = ZipEncoder().encode(archive, level: level);
        if (encodedBytes == null) {
          sendPort.send({'status': 'error', 'error': 'ZIP encoding failed: null result'});
          return;
        }
        t.send(0.90, 'Writing to disk...', force: true, bytesProcessed: compressedBytes, totalBytes: totalBytes);
        final outFile = File(destinationPath)..createSync(recursive: true);
        outFile.writeAsBytesSync(encodedBytes);
      } else if (format == 'tar') {
        // TarEncoder.add → TarFile.write → output.writeInputStream(InputStreamBase) 是真流式，
        // 不会整包 toUint8List，可以继续用。
        final output = OutputFileStream(destinationPath);
        final enc = TarEncoder();
        enc.start(output);
        for (final entry in plan.files) {
          final src = File(entry.fullPath);
          if (!src.existsSync()) continue;
          final size = src.lengthSync();
          t.send(0.10 + (processedBytes / totalBytes) * 0.88, entry.relPath);
          final fileStream = InputFileStream(src.path);
          final af = ArchiveFile.stream(entry.relPath, size, fileStream);
          af.lastModTime = src.lastModifiedSync().millisecondsSinceEpoch ~/ 1000;
          af.mode = src.statSync().mode;
          enc.add(af);
          fileStream.closeSync();
          processedBytes += size;
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
          for (final entry in plan.files) {
            final src = File(entry.fullPath);
            if (!src.existsSync()) continue;
            final size = src.lengthSync();
            t.send(0.10 + (processedBytes / totalBytes) * 0.45, entry.relPath);
            final fileStream = InputFileStream(src.path);
            final af = ArchiveFile.stream(entry.relPath, size, fileStream);
            af.lastModTime = src.lastModifiedSync().millisecondsSinceEpoch ~/ 1000;
            af.mode = src.statSync().mode;
            enc.add(af);
            fileStream.closeSync();
            processedBytes += size;
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

      t.send(1.0, 'Archive created successfully', force: true);
      await Future.delayed(const Duration(milliseconds: 200));
      sendPort.send({'status': 'completed'});
    } catch (e, stackTrace) {
      final msg = 'Compression failed: ${e.toString()}';
      debugPrint('$msg\n$stackTrace');
      sendPort.send({'status': 'error', 'error': msg});
    }
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

      // ===== 归档类：ZIP / TAR / TAR.* =====
      t.send(0.05, 'Preparing to extract…', force: true);

      late Archive archive;
      // 需要保持引用以便在所有文件提取完成后才关闭
      InputFileStream? zipInputToClose;
      String? tempTarPath;

      if (lowerPath.endsWith('.zip') || lowerPath.contains('.zip.')) {
        final input = InputFileStream(archivePath);
        zipInputToClose = input;
        archive = ZipDecoder().decodeBuffer(
          input,
          password: (password != null && password.isNotEmpty) ? password : null,
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
          final progress = 0.30 + (i / totalFiles) * 0.70;
          t.send(progress, filename, bytesProcessed: extractedBytes, totalBytes: totalExtractBytes);

          final outPath = p.join(actualDestDir, filename);
          if (fileEntry.isFile) {
            final outFile = File(outPath);
            outFile.createSync(recursive: true);
            final dynamic content = fileEntry.content;
            await _streamWriteArchiveFile(content, outFile);
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
      sendPort.send({'status': 'error', 'error': msg});
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
