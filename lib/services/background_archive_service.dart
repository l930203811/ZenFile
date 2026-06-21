import 'package:zenfile/l10n/generated/app_localizations.dart';

import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:permission_handler/permission_handler.dart';
import 'package:archive/archive_io.dart';
import 'package:dart_lz4/dart_lz4.dart';
import 'package:charset/charset.dart';
import 'package:just_zstd/just_zstd.dart';
import '../providers/file_manager_provider.dart';
import 'package:provider/provider.dart';
import '../ui/widgets/background_operation_progress_dialog.dart';

class BackgroundOperation {
  final String id;
  final String title;
  final String archiveName;
  final bool isCompression;
  final String? destinationDir;
  double progress; // 0.0 to 1.0
  String currentFile;
  bool isRunningInBackground;

  BackgroundOperation({
    required this.id,
    required this.title,
    required this.archiveName,
    required this.isCompression,
    this.destinationDir,
    this.progress = 0.0,
    this.currentFile = '',
    this.isRunningInBackground = false,
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

  /// 进度对话框的关闭回调，作为 ValueListenableBuilder 的兜底机制
  /// 对话框在 show 时设置此回调，_onOperationComplete 中作为强制关闭兜底
  void Function()? dialogCloseCallback;

  /// 直接存储对话框的 BuildContext，用于在 _onOperationComplete 中强制关闭
  /// 避免依赖 ValueListenableBuilder → addPostFrameCallback 这条不可靠的链
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
      // 机制1：直接同步关闭（如果不在 build 阶段）
      try {
        if (Navigator.canPop(ctx)) {
          Navigator.pop(ctx);
          return;
        }
      } catch (_) {}

      // 机制2：scheduleMicrotask 兜底（比 addPostFrameCallback 更快）
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

  /// 捕获的 ScaffoldMessengerState：在显示 bottom sheet / dialog 之前尽早保存
  /// 避免在 long-press 路径中，bottom sheet 弹出后 context 失效导致 SnackBar 无法显示
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
  }) async {
    final archiveName = p.basename(destinationPath);
    final operation = BackgroundOperation(
      id: 'compress_${DateTime.now().millisecondsSinceEpoch}',
      title: L10n.of(context).msg2f0138ad,
      archiveName: archiveName,
      isCompression: true,
      destinationDir: targetRefreshDir ?? p.dirname(destinationPath),
    );

    activeOperation.value = operation;
    _scaffoldMessenger ??= ScaffoldMessenger.of(context);
    _onCompleteCallback = onComplete;

    // 启动定时器兜底：如果30秒后对话框仍未关闭，强制关闭
    _dialogCloseTimer?.cancel();
    _dialogCloseTimer = Timer(const Duration(seconds: 30), () {
      _forceCloseDialog();
    });

    // Show progress dialog
    BackgroundOperationProgressDialog.show(context, this);

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

          operation.progress = progress;
          operation.currentFile = currentFile;
          activeOperation.value = operation;
          // ignore: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
          activeOperation.notifyListeners();

          if (operation.isRunningInBackground) {
            _updateNotification(operation);
          }
        } else if (status == 'completed') {
          _onOperationComplete(context, operation, L10n.of(context).msga2292820);
        } else if (status == 'error') {
          final error = message['error'] as String;
          _onOperationComplete(context, operation, 'Compression failed: $error', isError: true);
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

    // 启动定时器兜底：如果30秒后对话框仍未关闭，强制关闭
    _dialogCloseTimer?.cancel();
    _dialogCloseTimer = Timer(const Duration(seconds: 30), () {
      _forceCloseDialog();
    });

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

          operation.progress = progress;
          operation.currentFile = currentFile;
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
    // 防止重复触发：检查 activeOperation 是否已经被清空
    if (activeOperation.value == null) return;

    _activeIsolate = null;
    _portSubscription?.cancel();
    _portSubscription = null;
    _receivePort?.close();
    _receivePort = null;

    // 保存并清理回调
    final onComplete = _onCompleteCallback;
    _onCompleteCallback = null;

    // 关键修复：直接强制关闭对话框，不再依赖 ValueListenableBuilder → addPostFrameCallback 链
    // 先清理 activeOperation（触发 ValueListenableBuilder 重建作为辅助关闭手段）
    activeOperation.value = null;
    // 再直接强制关闭（主力关闭手段，使用存储的对话框 context）
    _forceCloseDialog();

    // 等待对话框关闭动画完成
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

    // 解压成功：显示'是/否'弹窗提示，不自动跳转（仅在用户点击确认后导航）
    // 压缩成功：不需要 SnackBar，loadDirectory 刷新目录即可（和三点菜单行为一致）
    if (!isError && !operation.isCompression && operation.destinationDir != null) {
      final l10n = L10n.of(context);
      (_scaffoldMessenger ?? ScaffoldMessenger.of(context)).showSnackBar(
        SnackBar(
          content: Row(
            children: [
              Expanded(child: Text(l10n.msgc18fb099)),
              TextButton(
                onPressed: () {
                  (_scaffoldMessenger ?? ScaffoldMessenger.of(context)).hideCurrentSnackBar();
                  try {
                    final provider = Provider.of<FileManagerProvider>(context, listen: false);
                    final destDir = operation.destinationDir!;
                    // 强制切换到浏览 Tab（绕过 HomeScreen 的 scheduleMicrotask 间接导航）
                    provider.setNavigateToBrowseTab(true);
                    Navigator.popUntil(context, (route) => route.isFirst);
                    // 直接加载解压目录，不依赖 HomeScreen 的 scheduleMicrotask
                    scheduleMicrotask(() {
                      provider.loadDirectory(destDir, showLoading: false, clearCache: true);
                    });
                  } catch (_) {}
                },
                child: Text(l10n.ui_confirm, style: const TextStyle(color: Colors.white)),
              ),
              TextButton(
                onPressed: () {
                  (_scaffoldMessenger ?? ScaffoldMessenger.of(context)).hideCurrentSnackBar();
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

    // 压缩/解压成功后，统一通过 onComplete 回调刷新目录
    // 不再依赖 context.mounted（长按路径中 context 可能已失效）
    if (!isError && onComplete != null) {
      try {
        // 使用 addPostFrameCallback 确保对话框关闭后再刷新，避免 UI 冲突
        WidgetsBinding.instance.addPostFrameCallback((_) {
          try {
            onComplete();
          } catch (_) {}
        });
      } catch (_) {}
    }
  }

  static void _compressIsolateTask(Map<String, dynamic> args) async {
    final sendPort = args['sendPort'] as SendPort;
    final sourcePaths = args['sourcePaths'] as List<String>;
    final destinationPath = args['destinationPath'] as String;
    final format = args['format'] as String;
    final level = args['level'] as int;
    final deleteSource = args['deleteSource'] as bool;

    try {
      sendPort.send({'status': 'progress', 'progress': 0.0, 'currentFile': 'Scanning files...'});

      final allFiles = <_FileEntry>[];
      final emptyDirs = <String>[];
      for (final path in sourcePaths) {
        final entityType = FileSystemEntity.typeSync(path);
        if (entityType == FileSystemEntityType.file) {
          allFiles.add(_FileEntry(path, p.basename(path)));
        } else if (entityType == FileSystemEntityType.directory) {
          final dir = Directory(path);
          if (dir.existsSync()) {
            final list = dir.listSync(recursive: true);
            bool hasFiles = false;
            for (final sub in list) {
              if (sub is File) {
                hasFiles = true;
                final relPath = p.relative(sub.path, from: p.dirname(path));
                allFiles.add(_FileEntry(sub.path, relPath));
              } else if (sub is Directory) {
                // 记录子目录（包括空目录）
                final relDirPath = p.relative(sub.path, from: p.dirname(path));
                emptyDirs.add(relDirPath);
              }
            }
            // 如果目录本身为空，记录该目录
            if (!hasFiles && list.isEmpty) {
              emptyDirs.add(p.basename(path));
            }
          }
        }
      }

      if (allFiles.isEmpty && emptyDirs.isEmpty) {
        sendPort.send({'status': 'error', 'error': 'No files to compress'});
        return;
      }

      // 阶段1：读取文件到内存 (0% → 25%)
      final archive = Archive();
      for (int i = 0; i < allFiles.length; i++) {
        final entry = allFiles[i];
        final progress = 0.05 + (i / allFiles.length) * 0.2;
        sendPort.send({
          'status': 'progress',
          'progress': progress,
          'currentFile': entry.relPath,
        });

        final bytes = File(entry.fullPath).readAsBytesSync();
        archive.addFile(ArchiveFile(entry.relPath, bytes.length, bytes));
      }

      // 添加空目录条目
      for (final dirPath in emptyDirs) {
        final normalizedDir = dirPath.endsWith('/') ? dirPath : '$dirPath/';
        archive.addFile(ArchiveFile(normalizedDir, 0, <int>[]));
      }

      // 阶段2：准备归档结构 (25% → 30%)
      sendPort.send({
        'status': 'progress',
        'progress': 0.3,
        'currentFile': 'Preparing archive structure...',
      });

      // 阶段3：编码压缩 (30% → 75%)
      sendPort.send({
        'status': 'progress',
        'progress': 0.35,
        'currentFile': 'Encoding archive...',
      });

      List<int>? encodedBytes;
      if (format == 'zip') {
        // ZIP 编码是最耗时的步骤，完成后跳到 75%
        encodedBytes = ZipEncoder().encode(archive, level: level);
      } else if (format == 'tar') {
        encodedBytes = TarEncoder().encode(archive);
      } else if (format == 'tar.gz') {
        final tarBytes = TarEncoder().encode(archive);
        sendPort.send({'status': 'progress', 'progress': 0.5, 'currentFile': 'Applying GZIP compression...'});
        encodedBytes = GZipEncoder().encode(tarBytes);
      } else if (format == 'tar.bz2') {
        final tarBytes = TarEncoder().encode(archive);
        sendPort.send({'status': 'progress', 'progress': 0.5, 'currentFile': 'Applying BZIP2 compression...'});
        encodedBytes = BZip2Encoder().encode(tarBytes);
      } else if (format == 'tar.lz4') {
        final tarBytes = TarEncoder().encode(archive);
        sendPort.send({'status': 'progress', 'progress': 0.5, 'currentFile': 'Applying LZ4 compression...'});
        encodedBytes = lz4FrameEncode(Uint8List.fromList(tarBytes));
      } else if (format == 'tar.zst') {
        final tarBytes = TarEncoder().encode(archive);
        sendPort.send({'status': 'progress', 'progress': 0.5, 'currentFile': 'Applying ZSTD compression...'});
        encodedBytes = const ZstdEncoder().encodeBytes(Uint8List.fromList(tarBytes));
      }

      if (encodedBytes == null) {
        sendPort.send({'status': 'error', 'error': 'Unsupported format'});
        return;
      }

      // 阶段4：编码完成 (75%)
      sendPort.send({
        'status': 'progress',
        'progress': 0.75,
        'currentFile': 'Encoding complete, saving to disk...',
      });

      // 阶段5：写入磁盘 (75% → 95%)
      final outFile = File(destinationPath);
      outFile.createSync(recursive: true);

      sendPort.send({
        'status': 'progress',
        'progress': 0.85,
        'currentFile': 'Writing archive to disk...',
      });

      // 使用 RandomAccessFile 并调用 flushSync，确保文件立即同步到磁盘
      final raf = outFile.openSync(mode: FileMode.write);
      raf.writeFromSync(encodedBytes);
      raf.flushSync();
      raf.closeSync();

      if (deleteSource) {
        for (final path in sourcePaths) {
          final type = FileSystemEntity.typeSync(path);
          if (type == FileSystemEntityType.directory) {
            Directory(path).deleteSync(recursive: true);
          } else if (type == FileSystemEntityType.file) {
            File(path).deleteSync();
          }
        }
      }

      sendPort.send({
        'status': 'progress',
        'progress': 0.95,
        'currentFile': 'Finalizing...',
      });
      await Future.delayed(const Duration(milliseconds: 100));

      sendPort.send({
        'status': 'progress',
        'progress': 1.0,
        'currentFile': 'Archive created successfully',
      });
      await Future.delayed(const Duration(milliseconds: 300));

      sendPort.send({'status': 'completed'});
    } catch (e) {
      sendPort.send({'status': 'error', 'error': e.toString()});
    }
  }

  /// 修复 ZIP 文件中非 UTF-8 编码的文件名（如 GBK 编码的中文文件名）
  /// ZIP 规范中，如果文件名包含非 ASCII 字符且没有 UTF-8 标志位，
  /// 解码器可能将原始字节当作 Latin-1 解码，导致中文乱码。
  /// 此方法检测这种情况并尝试用 GBK 解码还原正确文件名。
  static String _fixZipFilename(String name) {
    // 检查是否包含乱码特征：Latin-1 范围内的高位字符（0x80-0xFF）
    // 但不是有效的 UTF-8 序列
    bool hasGarbled = false;
    for (int i = 0; i < name.length; i++) {
      final codeUnit = name.codeUnitAt(i);
      if (codeUnit >= 0x80 && codeUnit <= 0xFF) {
        hasGarbled = true;
        break;
      }
    }
    if (!hasGarbled) return name;

    // 将字符串按 Latin-1 编码回字节，然后用 GBK 解码
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

    try {
      sendPort.send({'status': 'progress', 'progress': 0.0, 'currentFile': 'Reading archive bytes...'});

      final file = File(archivePath);
      if (!file.existsSync()) {
        sendPort.send({'status': 'error', 'error': 'Archive file not found'});
        return;
      }
      final bytes = file.readAsBytesSync();
      late Archive archive;
      final lowerPath = archivePath.toLowerCase();

      sendPort.send({'status': 'progress', 'progress': 0.1, 'currentFile': 'Decompressing archive...'});

      if (lowerPath.endsWith('.zip') || lowerPath.contains('.zip.')) {
        archive = ZipDecoder().decodeBytes(bytes, password: password != null && password.isNotEmpty ? password : null);
      } else if (lowerPath.endsWith('.tar.gz') || lowerPath.endsWith('.tgz')) {
        final tarBytes = GZipDecoder().decodeBytes(bytes);
        archive = TarDecoder().decodeBytes(tarBytes);
      } else if (lowerPath.endsWith('.tar.bz2') || lowerPath.endsWith('.tbz2')) {
        final tarBytes = BZip2Decoder().decodeBytes(bytes);
        archive = TarDecoder().decodeBytes(tarBytes);
      } else if (lowerPath.endsWith('.tar.lz4') || lowerPath.endsWith('.tlz4')) {
        final tarBytes = lz4FrameDecode(bytes);
        archive = TarDecoder().decodeBytes(Uint8List.fromList(tarBytes));
      } else if (lowerPath.endsWith('.tar.zst') || lowerPath.endsWith('.tzst')) {
        final tarBytes = const ZstdDecoder().decodeBytes(bytes);
        archive = TarDecoder().decodeBytes(Uint8List.fromList(tarBytes));
      } else if (lowerPath.endsWith('.tar')) {
        archive = TarDecoder().decodeBytes(bytes);
      } else if (lowerPath.endsWith('.gz')) {
        final decodedBytes = GZipDecoder().decodeBytes(bytes);
        final name = p.basenameWithoutExtension(archivePath);
        final destFile = File(p.join(destinationDir, name));
        destFile.createSync(recursive: true);
        destFile.writeAsBytesSync(decodedBytes);
        sendPort.send({'status': 'completed'});
        return;
      } else if (lowerPath.endsWith('.bz2')) {
        final decodedBytes = BZip2Decoder().decodeBytes(bytes);
        final name = p.basenameWithoutExtension(archivePath);
        final destFile = File(p.join(destinationDir, name));
        destFile.createSync(recursive: true);
        destFile.writeAsBytesSync(decodedBytes);
        sendPort.send({'status': 'completed'});
        return;
      } else if (lowerPath.endsWith('.lz4')) {
        final decodedBytes = lz4FrameDecode(bytes);
        final name = p.basenameWithoutExtension(archivePath);
        final destFile = File(p.join(destinationDir, name));
        destFile.createSync(recursive: true);
        destFile.writeAsBytesSync(Uint8List.fromList(decodedBytes));
        sendPort.send({'status': 'completed'});
        return;
      } else if (lowerPath.endsWith('.zst') || lowerPath.endsWith('.zstd')) {
        final decodedBytes = const ZstdDecoder().decodeBytes(bytes);
        final name = p.basenameWithoutExtension(archivePath);
        final destFile = File(p.join(destinationDir, name));
        destFile.createSync(recursive: true);
        destFile.writeAsBytesSync(Uint8List.fromList(decodedBytes));
        sendPort.send({'status': 'completed'});
        return;
      } else {
        archive = ZipDecoder().decodeBytes(bytes, password: password != null && password.isNotEmpty ? password : null);
      }

      sendPort.send({'status': 'progress', 'progress': 0.3, 'currentFile': 'Extracting files...'});

      // 分析压缩包根目录结构
      // 收集根层级的所有条目（第一级路径）
      final rootEntries = <String>{};
      for (int i = 0; i < archive.length; i++) {
        final name = _fixZipFilename(archive[i].name);
        if (name.isEmpty || name == '/') continue;
        final firstSegment = name.split('/').first;
        if (firstSegment.isNotEmpty) {
          rootEntries.add(firstSegment);
        }
      }

      // 判断是否需要自动创建文件夹：
      // - 如果根层级只有一个文件夹，则不创建（直接解压到目标目录）
      // - 如果根层级有多个文件/文件夹，则创建以压缩包名称命名的文件夹
      String actualDestDir = destinationDir;
      final bool shouldCreateFolder;
      if (rootEntries.length == 1) {
        // 只有一个根条目，检查它是否是文件夹
        final singleEntry = rootEntries.first;
        final isFolder = archive.any((f) {
          final name = _fixZipFilename(f.name);
          return name == singleEntry || name.startsWith('$singleEntry/');
        }) && archive.any((f) {
          final name = _fixZipFilename(f.name);
          return name.startsWith('$singleEntry/');
        });
        // 如果唯一根条目是文件夹，则不创建；否则创建
        shouldCreateFolder = !isFolder;
      } else {
        // 多个根条目，需要创建文件夹
        shouldCreateFolder = true;
      }

      if (shouldCreateFolder) {
        final archiveBaseName = p.basenameWithoutExtension(archivePath);
        actualDestDir = p.join(destinationDir, archiveBaseName);
        Directory(actualDestDir).createSync(recursive: true);
      }

      final totalFiles = archive.length;
      for (int i = 0; i < totalFiles; i++) {
        final file = archive[i];
        var filename = _fixZipFilename(file.name);
        final progress = 0.3 + (i / totalFiles) * 0.7;
        sendPort.send({
          'status': 'progress',
          'progress': progress,
          'currentFile': filename,
        });

        if (file.isFile) {
          final data = file.content as List<int>;
          final destFile = File(p.join(actualDestDir, filename));
          destFile.createSync(recursive: true);
          destFile.writeAsBytesSync(data);
        } else {
          Directory(p.join(actualDestDir, filename)).createSync(recursive: true);
        }
      }

      sendPort.send({
        'status': 'progress',
        'progress': 1.0,
        'currentFile': 'Archive extracted successfully',
      });
      await Future.delayed(const Duration(milliseconds: 300));

      sendPort.send({'status': 'completed'});
    } catch (e) {
      sendPort.send({'status': 'error', 'error': e.toString()});
    }
  }
}
