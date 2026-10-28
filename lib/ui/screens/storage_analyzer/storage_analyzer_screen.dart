import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../../core/icon_fonts/broken_icons.dart';
import '../../../providers/file_manager_provider.dart';
import '../../../core/utils.dart';
import '../../../services/app_manager_service.dart';
import '../../../services/junk_clean_service.dart';
import '../../../services/preferences_service.dart';
import '../media_category_screen.dart';
import '../../../models/media_type.dart';
import 'app_manager_screen.dart';
import 'package:zenfile/l10n/generated/app_localizations.dart';
import '../../widgets/circled_back_button.dart';

class StorageAnalyzerScreen extends StatefulWidget {
  final String? initialVolumePath;
  const StorageAnalyzerScreen({super.key, this.initialVolumePath});

  @override
  State<StorageAnalyzerScreen> createState() => _StorageAnalyzerScreenState();
}

class _StorageAnalyzerScreenState extends State<StorageAnalyzerScreen> with SingleTickerProviderStateMixin {
  bool _isScanning = true;
  String _currentScanningItem = '';

  /// 扫描防重入：AppBar 刷新按钮可被连点，且进入页面时会自动后台重扫，
  /// 不拦住会出现两路并发遍历同一棵树。
  bool _scanInFlight = false;

  /// 扫描进度文本的更新节流时间戳。逐文件 setState 会让一整个内部存储
  /// （数万个文件）把 UI 线程淹掉，进度文本只需「看起来在动」即可。
  DateTime _lastProgressTick = DateTime.fromMillisecondsSinceEpoch(0);

  int _appsSize = 0;
  int _imagesSize = 0;
  int _videosSize = 0;
  int _audioSize = 0;
  int _docsSize = 0;
  int _systemSize = 0;
  int _totalUsedSize = 0;
  int _totalStorageSize = 0;

  /// 垃圾清理：三个来源的可清理体积（下标见 `JunkCleanService.idxXxx`）。
  List<int> _junkBytes = const [0, 0, 0];
  bool _junkScanning = false;
  bool _junkCleaning = false;

  late AnimationController _radialController;

  @override
  void initState() {
    super.initState();
    _radialController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    );

    // 先尝试用上次的扫描结果秒开，再在后台静默重扫校正 ⇒ 关掉应用再进来
    // 不再从零遍历（用户反馈的「每次都花太长时间」）。
    final cached = PreferencesService.getSpaceScanCache();
    if (_isCacheUsable(cached)) {
      _applyCache(cached!);
      _isScanning = false;
      _radialController.forward();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _startStorageScan(silent: true);
      });
    } else {
      _startStorageScan();
    }

    // 垃圾体积扫描与主扫描并行：不阻塞页面首帧。
    unawaited(_scanJunk());
  }

  /// 缓存是否可用：路径一致 + 未超过 24 小时。（超时后仍会后台重扫覆盖。）
  bool _isCacheUsable(Map<String, dynamic>? c) {
    if (c == null) return false;
    final path = widget.initialVolumePath ?? '/storage/emulated/0';
    if ((c['path'] as String? ?? '') != path) return false;
    final ts = c['updatedAt'] as int? ?? 0;
    if (ts <= 0) return false;
    final age = DateTime.now().millisecondsSinceEpoch - ts;
    return age < const Duration(hours: 24).inMilliseconds;
  }

  void _applyCache(Map<String, dynamic> c) {
    _appsSize = c['apps'] as int? ?? 0;
    _imagesSize = c['images'] as int? ?? 0;
    _videosSize = c['videos'] as int? ?? 0;
    _audioSize = c['audio'] as int? ?? 0;
    _docsSize = c['docs'] as int? ?? 0;
    _systemSize = c['system'] as int? ?? 0;
    _totalUsedSize = c['totalUsed'] as int? ?? 0;
    _totalStorageSize = c['total'] as int? ?? 0;
  }

  @override
  void dispose() {
    _radialController.dispose();
    super.dispose();
  }

  /// 执行一次完整扫描。
  ///
  /// [silent] 为 true 时不切到「扫描中」视图（页面上已有缓存数据），
  /// 扫描完成后原地刷新数字，用于「秒开 + 后台校正」。
  Future<void> _startStorageScan({bool silent = false}) async {
    if (!mounted || _scanInFlight) return;
    _scanInFlight = true;
    final l10n = L10n.of(context);
    final provider = context.read<FileManagerProvider>();
    final path = widget.initialVolumePath ?? '/storage/emulated/0';

    if (!silent) {
      setState(() {
        _isScanning = true;
        _currentScanningItem = l10n.msgb1a2c3d4;
      });
    }

    try {
      // 1. 实时重取总容量 / 已用容量。
      //    此前这里只读 provider 的内存快照（仅在启动与首页下拉刷新时更新），
      //    所以在本页点刷新按钮永远显示打开应用那一刻的旧值，重启应用才正确。
      try {
        await provider.updateStorageSpace();
      } catch (_) {}
      _totalStorageSize = provider.totalStorageBytes > 0
          ? provider.totalStorageBytes
          : 128 * 1024 * 1024 * 1024;
      _totalUsedSize = provider.usedStorageBytes > 0
          ? provider.usedStorageBytes
          : 84 * 1024 * 1024 * 1024;

      // 2. 应用占用。原生 getInstalledApps 会对每个包做 queryStatsForPackage /
      //    loadLabel / getPackageInfo（逐包 IPC），一次调用已是秒级开销；
      //    这里原先调用两次（includeSystem false + true）⇒ 白跑一遍全部包。
      //    includeSystem:true 的返回已包含全部，直接在 Dart 侧求和即可。
      if (!silent) {
        setState(() {
          _currentScanningItem = l10n.msgc2d3e4f5;
        });
      }
      try {
        final allApps = await AppManagerService.getInstalledApps(
          includeSystem: true,
        );
        int appsSum = 0;
        for (final app in allApps) {
          appsSum += app.apkSize;
        }
        _appsSize = appsSum;
      } catch (_) {
        _appsSize = 0;
      }

      // 3. 递归统计各分类体积
      try {
        final rootDir = Directory(path);
        if (rootDir.existsSync()) {
          int imgBytes = 0;
          int vidBytes = 0;
          int audBytes = 0;
          int docBytes = 0;

          final stream = rootDir.list(recursive: true, followLinks: false);
          await for (final entity in stream.handleError((_) {})) {
            if (entity is! File) continue;
            try {
              final size = entity.lengthSync();
              final lowerPath = entity.path.toLowerCase();

              if (FileUtils.isImage(lowerPath)) {
                imgBytes += size;
              } else if (FileUtils.isVideo(lowerPath)) {
                vidBytes += size;
              } else if (FileUtils.isAudio(lowerPath)) {
                audBytes += size;
              } else {
                // Check documents
                const docExts = ['.pdf', '.doc', '.docx', '.xls', '.xlsx', '.ppt', '.pptx', '.txt', '.csv', '.odt', '.ods', '.odp', '.rtf', '.epub'];
                if (docExts.any((ext) => lowerPath.endsWith(ext)) || FileUtils.isTextOrCode(lowerPath)) {
                  docBytes += size;
                }
              }

              // 进度文本节流：每 ≤200ms 才允许一次 setState
              if (!silent) {
                final now = DateTime.now();
                if (now.difference(_lastProgressTick).inMilliseconds >= 200) {
                  _lastProgressTick = now;
                  final fileName = entity.path.split('/').last.split('\\').last;
                  if (mounted) {
                    setState(() {
                      _currentScanningItem = fileName;
                    });
                  }
                }
              }
            } catch (_) {}
          }

          _imagesSize = imgBytes;
          _videosSize = vidBytes;
          _audioSize = audBytes;
          _docsSize = docBytes;
        }
      } catch (_) {}

      // 4. 系统/其他 = 已用总量 - 各分类之和
      final double calculatedUsed =
          (_appsSize + _imagesSize + _videosSize + _audioSize + _docsSize)
              .toDouble();
      _systemSize = max(0, _totalUsedSize - calculatedUsed.toInt());

      // 5. 落缓存，供下次进入秒开
      unawaited(
        PreferencesService.saveSpaceScanCache({
          'path': path,
          'apps': _appsSize,
          'images': _imagesSize,
          'videos': _videosSize,
          'audio': _audioSize,
          'docs': _docsSize,
          'system': _systemSize,
          'totalUsed': _totalUsedSize,
          'total': _totalStorageSize,
          'updatedAt': DateTime.now().millisecondsSinceEpoch,
        }),
      );
    } finally {
      _scanInFlight = false;
      if (mounted) {
        setState(() {
          _isScanning = false;
        });
        _radialController.forward(from: 0);
      }
    }
  }

  int get _junkTotalBytes =>
      _junkBytes[JunkCleanService.idxZenfileCache] +
      _junkBytes[JunkCleanService.idxLegacyCache] +
      _junkBytes[JunkCleanService.idxAppTemp];

  /// 后台扫描垃圾体积（统计在独立 isolate 中执行，不阻塞 UI）。
  Future<void> _scanJunk() async {
    if (_junkScanning) return;
    _junkScanning = true;
    try {
      final r = await JunkCleanService.scan();
      if (mounted) {
        setState(() => _junkBytes = r);
      }
    } catch (_) {
      // 扫描失败按「没有垃圾」处理，不打扰用户
    } finally {
      _junkScanning = false;
    }
  }

  Future<void> _onTapJunkClean() async {
    if (_junkCleaning || _junkScanning || !mounted) return;
    final l10n = L10n.of(context);
    final total = _junkTotalBytes;
    if (total <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.junk_clean_none)),
      );
      return;
    }
    final confirmed = await _confirmJunkClean(l10n, total);
    if (confirmed != true || !mounted) return;

    setState(() => _junkCleaning = true);
    try {
      final freed = await JunkCleanService.clean();
      if (!mounted) return;
      // 清理后：刷新垃圾体积 + 静默重扫存储（已用容量变了）。
      await _scanJunk();
      if (mounted) {
        unawaited(_startStorageScan(silent: true));
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              l10n.junk_clean_done(FileUtils.formatBytes(freed, 1)),
            ),
          ),
        );
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l10n.junk_clean_failed)),
        );
      }
    } finally {
      if (mounted) setState(() => _junkCleaning = false);
    }
  }

  Future<bool?> _confirmJunkClean(L10n l10n, int totalBytes) {
    final cacheBytes = _junkBytes[JunkCleanService.idxZenfileCache] +
        _junkBytes[JunkCleanService.idxLegacyCache];
    final tempBytes = _junkBytes[JunkCleanService.idxAppTemp];
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.junk_clean_confirm_title),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              l10n.junk_clean_confirm_body(
                FileUtils.formatBytes(totalBytes, 1),
              ),
            ),
            if (cacheBytes > 0) ...[
              const SizedBox(height: 12),
              _buildJunkRow(ctx, l10n.junk_clean_cache_item,
                  FileUtils.formatBytes(cacheBytes, 1)),
            ],
            if (tempBytes > 0) ...[
              _buildJunkRow(ctx, l10n.junk_clean_temp_item,
                  FileUtils.formatBytes(tempBytes, 1)),
            ],
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(l10n.ui_cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(l10n.ui_confirm),
          ),
        ],
      ),
    );
  }

  Widget _buildJunkRow(BuildContext ctx, String label, String size) {
    final theme = Theme.of(ctx);
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Row(
        children: [
          Expanded(
            child: Text(label, style: theme.textTheme.bodySmall),
          ),
          Text(
            size,
            style: theme.textTheme.bodySmall
                ?.copyWith(fontWeight: FontWeight.bold),
          ),
        ],
      ),
    );
  }
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      appBar: AppBar(
        elevation: 0,
        backgroundColor: theme.colorScheme.surface,
        leading: const CircledBackButton(),
        title: Text(
          L10n.of(context).msga22ddaae,
          style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh_rounded),
            onPressed: () => _startStorageScan(),
            tooltip: L10n.of(context).msgaae779d4,
          ),
        ],
      ),
      body: _isScanning ? _buildScanningView(theme, isDark) : _buildAnalyticsView(theme, isDark),
    );
  }

  Widget _buildScanningView(ThemeData theme, bool isDark) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Stack(
              alignment: Alignment.center,
              children: [
                SizedBox(
                  width: 130,
                  height: 130,
                  child: CircularProgressIndicator(
                    strokeWidth: 4,
                    backgroundColor: theme.colorScheme.primary.withValues(alpha: 0.1),
                    valueColor: AlwaysStoppedAnimation<Color>(theme.colorScheme.primary),
                  ),
                ),
                Container(
                  width: 90,
                  height: 90,
                  decoration: BoxDecoration(
                    color: theme.colorScheme.primary.withValues(alpha: 0.08),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    Broken.document_filter,
                    size: 38,
                    color: theme.colorScheme.primary,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 32),
            Text(
              L10n.of(context).msg7ae97495,
              style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Text(
              L10n.of(context).msge4f5a6b7,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: theme.textTheme.bodySmall?.color?.withValues(alpha: 0.6),
                fontSize: 14,
              ),
            ),
            const SizedBox(height: 24),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceVariant.withValues(alpha: 0.2),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: theme.dividerColor.withValues(alpha: 0.05)),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  const SizedBox(width: 12),
                  Flexible(
                    child: Text(
                      _currentScanningItem,
                      style: TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 12,
                        color: theme.colorScheme.primary,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAnalyticsView(ThemeData theme, bool isDark) {
    final l10n = L10n.of(context);
    final double usedPercent = _totalStorageSize > 0 ? (_totalUsedSize / _totalStorageSize) * 100 : 0.0;
    final int freeSize = max(0, _totalStorageSize - _totalUsedSize);

    return SingleChildScrollView(
      physics: const BouncingScrollPhysics(),
      child: Column(
        children: [
          // Circular progress card
          Container(
            margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 20),
            decoration: BoxDecoration(
              color: theme.colorScheme.surface,
              borderRadius: BorderRadius.circular(24),
              border: Border.all(color: theme.dividerColor.withValues(alpha: 0.08)),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.02),
                  blurRadius: 10,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: Row(
              children: [
                // Custom Radial Chart Painter
                AnimatedBuilder(
                  animation: _radialController,
                  builder: (context, child) {
                    return SizedBox(
                      width: 110,
                      height: 110,
                      child: CustomPaint(
                        painter: StorageRadialPainter(
                          apps: _appsSize,
                          images: _imagesSize,
                          videos: _videosSize,
                          audio: _audioSize,
                          docs: _docsSize,
                          system: _systemSize,
                          total: _totalStorageSize,
                          animationVal: _radialController.value,
                          isDark: isDark,
                        ),
                      ),
                    );
                  },
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        L10n.of(context).msga5e5bf71,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.textTheme.bodyMedium?.color?.withValues(alpha: 0.5),
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        FileUtils.formatBytes(_totalStorageSize, 2),
                        style: theme.textTheme.headlineSmall?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          Container(
                            width: 8,
                            height: 8,
                            decoration: const BoxDecoration(
                              shape: BoxShape.circle,
                              color: Color(0xFF10B981), // Green free space
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              l10n.msgf5a6b7c8(FileUtils.formatBytes(freeSize, 2)),
                              style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 12.5),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          Container(
                            width: 8,
                            height: 8,
                            decoration: const BoxDecoration(
                              shape: BoxShape.circle,
                              color: Color(0xFFEF4444), // Red used space
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              l10n.msga6b7c8d9(
                                FileUtils.formatBytes(_totalUsedSize, 2),
                                usedPercent.toStringAsFixed(1),
                              ),
                              style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 12.5),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),

          // 垃圾清理：应用缓存 + 临时文件（详见 JunkCleanService）
          _buildJunkCleanCard(theme, isDark, l10n),

          // Categories Breakdown Title
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20.0, vertical: 8.0),
            child: Row(
              children: [
                Text(
                  L10n.of(context).msg652be256,
                  style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
                ),
              ],
            ),
          ),

          // Category items
          _buildCategoryCard(
            context: context,
            title: L10n.of(context).cat_apps,
            size: _appsSize,
            color: const Color(0xFFEC4899), // Pink
            icon: Broken.mobile,
            theme: theme,
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const AppManagerScreen()),
              );
            },
          ),
          _buildCategoryCard(
            context: context,
            title: L10n.of(context).cat_images,
            size: _imagesSize,
            color: const Color(0xFF8B5CF6), // Violet
            icon: Broken.image,
            theme: theme,
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => const MediaCategoryScreen(mediaType: MediaType.images),
                ),
              );
            },
          ),
          _buildCategoryCard(
            context: context,
            title: L10n.of(context).cat_videos,
            size: _videosSize,
            color: const Color(0xFFEF4444), // Red
            icon: Broken.video,
            theme: theme,
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => const MediaCategoryScreen(mediaType: MediaType.videos),
                ),
              );
            },
          ),
          _buildCategoryCard(
            context: context,
            title: L10n.of(context).cat_audios,
            size: _audioSize,
            color: const Color(0xFFF97316), // Orange
            icon: Broken.music,
            theme: theme,
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => const MediaCategoryScreen(mediaType: MediaType.audios),
                ),
              );
            },
          ),
          _buildCategoryCard(
            context: context,
            title: L10n.of(context).cat_documents,
            size: _docsSize,
            color: const Color(0xFF3B82F6), // Blue
            icon: Broken.document,
            theme: theme,
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => const MediaCategoryScreen(mediaType: MediaType.documents),
                ),
              );
            },
          ),
          _buildCategoryCard(
            context: context,
            title: L10n.of(context).msgc8d9e0f1,
            size: _systemSize,
            color: const Color(0xFF64748B), // Slate
            icon: Broken.category_2,
            theme: theme,
            onTap: () {}, // No viewer for system/other
          ),
          
          const SizedBox(height: 32),
        ],
      ),
    );
  }

  /// 垃圾清理卡片：可清理体积 +「立即清理」。放在存储总览卡片下方。
  Widget _buildJunkCleanCard(ThemeData theme, bool isDark, L10n l10n) {
    final total = _junkTotalBytes;
    const color = Color(0xFF14B8A6); // teal
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: theme.dividerColor.withValues(alpha: 0.06)),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(12),
            ),
            child: const Icon(Broken.broom, color: color, size: 22),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  l10n.junk_clean_title,
                  style: const TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 14.5,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  _junkScanning
                      ? l10n.junk_clean_scanning
                      : total > 0
                          ? l10n.junk_clean_scannable(
                              FileUtils.formatBytes(total, 1),
                            )
                          : l10n.junk_clean_none,
                  style: TextStyle(
                    color: theme.textTheme.bodySmall
                        ?.color?.withValues(alpha: 0.55),
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          if (_junkCleaning)
            const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2.4),
            )
          else
            FilledButton.tonal(
              onPressed: _onTapJunkClean,
              style: FilledButton.styleFrom(
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.symmetric(horizontal: 14),
              ),
              child: Text(l10n.junk_clean_button),
            ),
        ],
      ),
    );
  }
  Widget _buildCategoryCard({
    required BuildContext context,
    required String title,
    required int size,
    required Color color,
    required IconData icon,
    required ThemeData theme,
    required VoidCallback onTap,
  }) {
    final l10n = L10n.of(context);
    final double proportion = _totalStorageSize > 0 ? (size / _totalStorageSize) : 0.0;
    final String percentStr = (proportion * 100).toStringAsFixed(1);

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: theme.dividerColor.withValues(alpha: 0.06)),
      ),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(icon, color: color, size: 22),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          title,
                          style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14.5),
                        ),
                        Text(
                          FileUtils.formatBytes(size, 2),
                          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: LinearProgressIndicator(
                        value: proportion,
                        backgroundColor: color.withValues(alpha: 0.1),
                        valueColor: AlwaysStoppedAnimation<Color>(color),
                        minHeight: 5,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      l10n.msgb7c8d9e0(percentStr),
                      style: TextStyle(
                        color: theme.textTheme.bodySmall?.color?.withValues(alpha: 0.5),
                        fontSize: 11,
                      ),
                    ),
                  ],
                ),
              ),
              if (title != L10n.of(context).msgc8d9e0f1) ...[
                const SizedBox(width: 12),
                Icon(
                  Broken.arrow_right_3,
                  size: 16,
                  color: theme.textTheme.bodySmall?.color?.withValues(alpha: 0.4),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class StorageRadialPainter extends CustomPainter {
  final int apps;
  final int images;
  final int videos;
  final int audio;
  final int docs;
  final int system;
  final int total;
  final double animationVal;
  final bool isDark;

  StorageRadialPainter({
    required this.apps,
    required this.images,
    required this.videos,
    required this.audio,
    required this.docs,
    required this.system,
    required this.total,
    required this.animationVal,
    required this.isDark,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final double center = size.width / 2;
    final double radius = min(size.width, size.height) / 2 - 8;
    final Rect rect = Rect.fromCircle(center: Offset(center, center), radius: radius);

    final Paint trackPaint = Paint()
      ..color = isDark ? Colors.white.withValues(alpha: 0.08) : Colors.black.withValues(alpha: 0.05)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 14;

    canvas.drawCircle(Offset(center, center), radius, trackPaint);

    if (total == 0) return;

    final double factor = animationVal * 2 * pi;
    double startAngle = -pi / 2;

    void drawSegment(int segmentSize, Color color) {
      if (segmentSize <= 0) return;
      final double sweepAngle = (segmentSize / total) * factor;

      final Paint segmentPaint = Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 14
        ..strokeCap = StrokeCap.round;

      canvas.drawArc(rect, startAngle, sweepAngle, false, segmentPaint);
      startAngle += sweepAngle;
    }

    // Draw in order of categories
    drawSegment(apps, const Color(0xFFEC4899));
    drawSegment(images, const Color(0xFF8B5CF6));
    drawSegment(videos, const Color(0xFFEF4444));
    drawSegment(audio, const Color(0xFFF97316));
    drawSegment(docs, const Color(0xFF3B82F6));
    drawSegment(system, const Color(0xFF64748B));
  }

  @override
  bool shouldRepaint(covariant StorageRadialPainter oldDelegate) {
    return oldDelegate.animationVal != animationVal;
  }
}
