import 'dart:io';
import 'package:flutter/material.dart';
import '../../core/icon_fonts/broken_icons.dart';
import '../../core/utils.dart';
import 'package:zenfile/l10n/generated/app_localizations.dart';

enum ConflictResult {
  overwrite,
  keepBoth,
  skip,
  rename,
  cancel,
}

class ConflictDialogResponse {
  final ConflictResult result;
  final bool applyToAll;
  final String? customName;

  ConflictDialogResponse({
    required this.result,
    required this.applyToAll,
    this.customName,
  });
}

/// 冲突弹窗里「大小 / 修改时间」的来源。
///
/// 本地文件的这两项由弹窗自己 `stat()` 取得；**远程文件没有本地路径**，只能由
/// 调用方从远程目录列表条目带入。若不给（继续传 `File('')`），Dart 的
/// `File('').stat()` 不会抛异常，而是返回 `size: -1 / 1970-01-01`；经 `formatBytes`
/// 后大小变成「0 B」、时间变成「1970-01-01」，弹窗就把这两个伪值当真实信息展示
/// （远程粘贴重名时的历史表现）。
///
/// 字段为 null 表示「未知」，弹窗显示 `—`。
class ConflictFileInfo {
  final int? size;
  final DateTime? modified;
  const ConflictFileInfo({this.size, this.modified});
}

/// 解析冲突弹窗一侧的「大小 / 修改时间」。
///
/// - [given] 非空（远程条目 / 调用方已知）→ 直接采用，**不做本地 stat**；
/// - 否则对本地 [file] 做 `stat()`：`notFound`（含**空路径** —— Dart 对
///   `File('').stat()` 不抛异常，而是返回 `size: -1 / 1970-01-01`）以及任何异常
///   都归为**未知**，由弹窗显示 `—`，绝不把伪值当真实信息展示。
///
/// 抽成顶层函数以便单测（widget 测试里 FakeAsync 不驱动 `dart:io`，无法覆盖真实
/// stat 分支）。
Future<ConflictFileInfo> resolveConflictFileInfo(
  File file,
  ConflictFileInfo? given,
) async {
  if (given != null) return given;
  try {
    final stat = await file.stat();
    if (stat.type == FileSystemEntityType.notFound) {
      return const ConflictFileInfo();
    }
    return ConflictFileInfo(
      size: stat.size >= 0 ? stat.size : null,
      modified: stat.modified.millisecondsSinceEpoch > 0 ? stat.modified : null,
    );
  } catch (_) {
    return const ConflictFileInfo();
  }
}

class ConflictDialog extends StatefulWidget {
  final String fileName;
  final File sourceFile;
  final File destFile;

  /// 远程文件（或尚未落盘的目标）的信息：给了就不再对本侧做本地 `stat()`。
  final ConflictFileInfo? sourceInfo;
  final ConflictFileInfo? destInfo;

  const ConflictDialog({
    super.key,
    required this.fileName,
    required this.sourceFile,
    required this.destFile,
    this.sourceInfo,
    this.destInfo,
  });

  static Future<ConflictDialogResponse?> show(
    BuildContext context, {
    required String fileName,
    required File sourceFile,
    required File destFile,
    ConflictFileInfo? sourceInfo,
    ConflictFileInfo? destInfo,
  }) {
    return showDialog<ConflictDialogResponse>(
      context: context,
      barrierDismissible: false,
      builder: (_) => ConflictDialog(
        fileName: fileName,
        sourceFile: sourceFile,
        destFile: destFile,
        sourceInfo: sourceInfo,
        destInfo: destInfo,
      ),
    );
  }

  @override
  State<ConflictDialog> createState() => _ConflictDialogState();
}

class _ConflictDialogState extends State<ConflictDialog> {
  bool _applyToAll = false;
  ConflictFileInfo _sourceInfo = const ConflictFileInfo();
  ConflictFileInfo _destInfo = const ConflictFileInfo();
  bool _infosLoaded = false;

  @override
  void initState() {
    super.initState();
    _loadStats();
  }

  /// 解析两侧的「大小 / 修改时间」（实现见顶层的 [resolveConflictFileInfo]）。
  ///
  /// 无论成败都会把 `_infosLoaded` 置 true —— 弹窗绝不会卡在转圈上
  /// （历史实现里 stat 抛异常就永远转圈，远程冲突时用户只看到无限 loading）。
  Future<void> _loadStats() async {
    final src = await resolveConflictFileInfo(widget.sourceFile, widget.sourceInfo);
    final dst = await resolveConflictFileInfo(widget.destFile, widget.destInfo);
    if (!mounted) return;
    setState(() {
      _sourceInfo = src;
      _destInfo = dst;
      _infosLoaded = true;
    });
  }

  /// 源文件是否比目标新。
  ///
  /// 任一侧修改时间未知时返回 null → 不判定、两侧都不显示「较新」角标
  /// （远程目录列表拿不到 mtime 的协议很常见，不能靠未知值比较）。
  bool? get _srcNewer {
    final src = _sourceInfo.modified;
    final dst = _destInfo.modified;
    if (src == null || dst == null || src == dst) return null;
    return src.isAfter(dst);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return AlertDialog(
      title: Row(
        children: [
          Icon(Broken.warning_2, color: Colors.orange, size: 28),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              L10n.of(context).msg_file_exists,
              style: TextStyle(fontWeight: FontWeight.bold),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      content: SizedBox(
        width: MediaQuery.of(context).size.width * 0.9,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              L10n.of(context).msg_file_exists_desc(widget.fileName),
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurface.withOpacity(0.8),
              ),
            ),
            const SizedBox(height: 20),
            
            // Side-by-side or stacked file details comparison
            // 两侧时间都已知才判断「较新」，否则不给高亮（避免拿未知值比较）。
            if (_infosLoaded)
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Existing File Card
                  Expanded(
                    child: _buildFileComparisonCard(
                      theme: theme,
                      title: L10n.of(context).msg_existing_file,
                      size: _destInfo.size,
                      modified: _destInfo.modified,
                      isNewer: _srcNewer == false,
                    ),
                  ),
                  const SizedBox(width: 12),
                  // New File Card
                  Expanded(
                    child: _buildFileComparisonCard(
                      theme: theme,
                      title: L10n.of(context).msge48a7157,
                      size: _sourceInfo.size,
                      modified: _sourceInfo.modified,
                      isNewer: _srcNewer == true,
                    ),
                  ),
                ],
              )
            else
              const Center(
                child: Padding(
                  padding: EdgeInsets.all(16.0),
                  child: CircularProgressIndicator(),
                ),
              ),
            const SizedBox(height: 20),

            // Checkbox for Apply to All
            InkWell(
              onTap: () => setState(() => _applyToAll = !_applyToAll),
              borderRadius: BorderRadius.circular(8),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 8.0, horizontal: 4.0),
                child: Row(
                  children: [
                    SizedBox(
                      width: 24,
                      height: 24,
                      child: Checkbox(
                        value: _applyToAll,
                        onChanged: (val) => setState(() => _applyToAll = val ?? false),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        L10n.of(context).msge59e35b5,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                          color: theme.colorScheme.onSurface.withOpacity(0.8),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 20),

            // Action Buttons Layout
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Row 1: Skip + Overwrite
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: () => Navigator.pop(
                          context,
                          ConflictDialogResponse(result: ConflictResult.skip, applyToAll: _applyToAll),
                        ),
                        style: OutlinedButton.styleFrom(
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                        ),
                        child: Text(L10n.of(context).msg_skip_file),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: OutlinedButton(
                        onPressed: () => Navigator.pop(
                          context,
                          ConflictDialogResponse(result: ConflictResult.overwrite, applyToAll: _applyToAll),
                        ),
                        style: OutlinedButton.styleFrom(
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                        ),
                        child: Text(L10n.of(context).msg_overwrite_file),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                // Row 2: Keep Both + Rename
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: () => Navigator.pop(
                          context,
                          ConflictDialogResponse(result: ConflictResult.keepBoth, applyToAll: _applyToAll),
                        ),
                        style: OutlinedButton.styleFrom(
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                        ),
                        child: Text(L10n.of(context).msg27dfaae5),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: OutlinedButton(
                        onPressed: () async {
                          final newName = await _showRenameDialog(context, widget.fileName);
                          if (newName != null && newName.isNotEmpty && context.mounted) {
                            Navigator.pop(
                              context,
                              ConflictDialogResponse(
                                result: ConflictResult.rename,
                                applyToAll: _applyToAll,
                                customName: newName,
                              ),
                            );
                          }
                        },
                        style: OutlinedButton.styleFrom(
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                        ),
                        child: Text(L10n.of(context).msgc8ce4b36),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                // Row 3: Cancel (left aligned)
                Row(
                  children: [
                    TextButton(
                      onPressed: () => Navigator.pop(
                        context,
                        ConflictDialogResponse(result: ConflictResult.cancel, applyToAll: false),
                      ),
                      style: TextButton.styleFrom(
                        foregroundColor: Colors.redAccent,
                      ),
                      child: Text(L10n.of(context).msg_cancel_paste, style: TextStyle(fontWeight: FontWeight.bold)),
                    ),
                  ],
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFileComparisonCard({
    required ThemeData theme,
    required String title,
    required int? size,
    required DateTime? modified,
    required bool isNewer,
  }) {
    // 远程条目常常拿不到大小/时间（列表接口不返回）→ 显示「—」而不是 0 / 1970。
    final sizeText = (size != null && size >= 0)
        ? FileUtils.formatBytes(size, 2)
        : '—';
    final dateText = modified != null ? FileUtils.formatDate(modified) : '—';
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceVariant.withOpacity(0.3),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: isNewer ? theme.colorScheme.primary.withOpacity(0.4) : theme.dividerColor.withOpacity(0.1),
          width: isNewer ? 1.8 : 1.0,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 6,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(
                title,
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 13,
                  color: isNewer ? theme.colorScheme.primary : theme.colorScheme.onSurface,
                ),
              ),
              if (isNewer)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.primary.withOpacity(0.15),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    L10n.of(context).msg_newer,
                    style: TextStyle(
                      fontSize: 9,
                      fontWeight: FontWeight.bold,
                      color: theme.colorScheme.primary,
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            sizeText,
            style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
          ),
          const SizedBox(height: 4),
          Text(
            dateText,
            style: TextStyle(
              fontSize: 11,
              color: theme.colorScheme.onSurface.withOpacity(0.6),
            ),
          ),
        ],
      ),
    );
  }

  Future<String?> _showRenameDialog(BuildContext context, String currentName) {
    final controller = TextEditingController(text: currentName);
    // 选中文件名主体（不含扩展名），光标落在扩展名前，避免误改后缀名。
    final dot = currentName.lastIndexOf('.');
    final cutoff = dot > 0 ? dot : currentName.length;
    controller.selection = TextSelection(baseOffset: 0, extentOffset: cutoff);
    return showDialog<String>(
      context: context,
      builder: (ctx) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          controller.selection = TextSelection(baseOffset: 0, extentOffset: cutoff);
        });
        return AlertDialog(
          title: Text(L10n.of(context).msg6cfbf05d),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          content: TextField(
            controller: controller,
            autofocus: true,
            decoration: InputDecoration(
              labelText: L10n.of(context).msg_new_file_name,
              border: OutlineInputBorder(),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, controller.text.trim()),
              child: Text(L10n.of(context).msgc8ce4b36),
            ),
          ],
        );
      },
    );
  }
}
