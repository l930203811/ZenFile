import 'dart:async';

import 'package:flutter/material.dart';

import '../../../core/icon_fonts/broken_icons.dart';
import '../../../core/utils.dart';
import '../../../services/duplicate_scan_service.dart';
import 'package:zenfile/l10n/generated/app_localizations.dart';
import '../../widgets/circled_back_button.dart';

/// 「重复文件」页：扫描内容完全相同的文件，**默认勾选较旧的副本**、
/// 推荐保留最新的一份，一键清理腾出空间。
///
/// 默认只是**推荐**：所有条目（含最新那份）都可以手动勾选/取消 —— 用户可能
/// 想留下的恰好是旧副本（比如新的一份在临时目录、旧的在归档目录）。
///
/// 入口在「空间」（存储分析）页的「扫描去重」卡片。
class DuplicateFilesScreen extends StatefulWidget {
  /// 扫描根（空间页会传入当前卷路径），为空则用内部存储根。
  final String? rootPath;

  const DuplicateFilesScreen({super.key, this.rootPath});

  @override
  State<DuplicateFilesScreen> createState() => _DuplicateFilesScreenState();
}

class _DuplicateFilesScreenState extends State<DuplicateFilesScreen> {
  bool _scanning = true;
  bool _cleaning = false;
  int _scannedFiles = 0;
  int _candidateFiles = 0;

  DupScanResult? _result;

  /// 已勾选待清理的文件路径。初始 = 每组除「最新那份」外的全部副本，
  /// 之后完全由用户决定（任意条目都可勾/取消，包括最新那份）。
  final Set<String> _selected = <String>{};

  /// 折叠的分组下标（默认全部展开：用户要一眼看到将被删除的是哪些文件）。
  final Set<int> _collapsed = <int>{};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _startScan();
    });
  }

  @override
  void dispose() {
    // 退出页面即中止后台扫描 isolate（全盘哈希可能还要跑几十秒）。
    DuplicateScanService.cancelActive();
    super.dispose();
  }

  Future<void> _startScan() async {
    if (!mounted) return;
    setState(() {
      _scanning = true;
      _scannedFiles = 0;
      _candidateFiles = 0;
      _result = null;
      _selected.clear();
      _collapsed.clear();
    });

    final result = await DuplicateScanService.scan(
      rootPath: widget.rootPath,
      onProgress: (scanned, candidates) {
        if (!mounted) return;
        // 进度节流：每 150ms 才刷一次，避免上万次 setState 把 UI 淹掉。
        final now = DateTime.now();
        if (now.difference(_lastTick).inMilliseconds < 150) return;
        _lastTick = now;
        setState(() {
          _scannedFiles = scanned;
          _candidateFiles = candidates;
        });
      },
    );

    if (!mounted) return;
    setState(() {
      _scanning = false;
      _result = result;
      _scannedFiles = result.scanned;
      // 默认勾选：每组除「最新那份」（files.first）以外的所有副本。
      // 这只是初始状态，用户可以随意改选（含把最新那份也勾上）。
      for (final group in result.groups) {
        for (var i = 1; i < group.files.length; i++) {
          _selected.add(group.files[i].path);
        }
      }
    });
  }

  DateTime _lastTick = DateTime.fromMillisecondsSinceEpoch(0);

  int get _selectedBytes {
    final result = _result;
    if (result == null) return 0;
    var bytes = 0;
    for (final group in result.groups) {
      for (final f in group.files) {
        if (_selected.contains(f.path)) bytes += f.size;
      }
    }
    return bytes;
  }

  int get _selectedCount => _selected.length;

  Future<void> _onClean() async {
    final result = _result;
    if (result == null || _cleaning || _selectedCount == 0) return;
    final l10n = L10n.of(context);
    final count = _selectedCount;
    final bytes = _selectedBytes;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.dup_clean_confirm_title),
        content: Text(l10n.dup_clean_confirm_body(
          count,
          FileUtils.formatBytes(bytes, 1),
        )),
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
    if (confirmed != true || !mounted) return;

    // 取出待删条目（含 size，用于统计释放体积）。
    final targets = <DupFile>[];
    for (final group in result.groups) {
      for (final f in group.files) {
        if (_selected.contains(f.path)) targets.add(f);
      }
    }

    setState(() => _cleaning = true);
    DupCleanResult cleanResult;
    try {
      cleanResult = await DuplicateScanService.deleteFiles(targets);
    } catch (_) {
      cleanResult = const DupCleanResult(deleted: 0, freedBytes: 0, failed: 1);
    }
    if (!mounted) return;

    // 原地更新结果：删掉已清理的条目；某组只剩 1 个文件即视为不再是重复组。
    // 有失败时不做精细回填，改为整页重扫（见下）——失败的文件可能还在，
    // 靠重扫拿到的才是真实状态。
    final removedPaths = <String>{for (final f in targets) f.path};
    final survivors = <DupGroup>[];
    if (cleanResult.failed == 0) {
      for (final group in result.groups) {
        final kept =
            group.files.where((f) => !removedPaths.contains(f.path)).toList();
        if (kept.length > 1) {
          survivors.add(DupGroup(size: group.size, files: kept));
        }
      }
    } else {
      survivors.addAll(result.groups);
    }

    setState(() {
      _cleaning = false;
      _result = DupScanResult(
        groups: survivors,
        scanned: result.scanned,
        candidates: result.candidates,
      );
      _selected.removeAll(removedPaths);
    });

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          cleanResult.deleted > 0
              ? l10n.dup_clean_done(
                  cleanResult.deleted,
                  FileUtils.formatBytes(cleanResult.freedBytes, 1),
                )
              : l10n.dup_failed,
        ),
      ),
    );

    // 有失败（被占用 / 权限）时重扫一次，把真实剩余状态摆正。
    if (cleanResult.failed > 0) {
      unawaited(_startScan());
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = L10n.of(context);
    final result = _result;
    final hasSelection = _selectedCount > 0;

    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      appBar: AppBar(
        elevation: 0,
        backgroundColor: theme.colorScheme.surface,
        leading: const CircledBackButton(),
        title: Text(
          l10n.dup_files_title,
          style: theme.textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.bold,
          ),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh_rounded),
            tooltip: l10n.dup_scan_button,
            onPressed: _scanning || _cleaning ? null : _startScan,
          ),
        ],
      ),
      body: _buildBody(theme, l10n, result),
      bottomNavigationBar: (result != null && !_scanning && result.groups.isNotEmpty)
          ? _buildBottomBar(theme, l10n, hasSelection)
          : null,
    );
  }

  Widget _buildBody(ThemeData theme, L10n l10n, DupScanResult? result) {
    if (_scanning) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const SizedBox(
                width: 42,
                height: 42,
                child: CircularProgressIndicator(strokeWidth: 3),
              ),
              const SizedBox(height: 20),
              Text(
                l10n.dup_scanning,
                style: theme.textTheme.titleSmall
                    ?.copyWith(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 8),
              Text(
                '$_scannedFiles · $_candidateFiles',
                style: TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 12,
                  color: theme.colorScheme.primary,
                ),
              ),
            ],
          ),
        ),
      );
    }

    if (result == null || result.groups.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                Broken.tick_circle,
                size: 46,
                color: theme.colorScheme.primary.withValues(alpha: 0.7),
              ),
              const SizedBox(height: 16),
              Text(
                l10n.dup_none,
                style: theme.textTheme.titleSmall
                    ?.copyWith(fontWeight: FontWeight.w600),
              ),
            ],
          ),
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 16),
      physics: const BouncingScrollPhysics(),
      itemCount: result.groups.length + 1,
      itemBuilder: (context, index) {
        if (index == 0) {
          return Padding(
            padding: const EdgeInsets.fromLTRB(6, 4, 6, 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  l10n.dup_found(
                    result.groups.length,
                    FileUtils.formatBytes(result.totalWasted, 1),
                  ),
                  style: theme.textTheme.titleSmall
                      ?.copyWith(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 4),
                Text(
                  l10n.dup_auto_hint,
                  style: TextStyle(
                    fontSize: 12,
                    color:
                        theme.textTheme.bodySmall?.color?.withValues(alpha: 0.6),
                  ),
                ),
              ],
            ),
          );
        }
        final groupIndex = index - 1;
        return _buildGroupCard(theme, l10n, groupIndex, result.groups[groupIndex]);
      },
    );
  }

  Widget _buildGroupCard(
    ThemeData theme,
    L10n l10n,
    int index,
    DupGroup group,
  ) {
    final collapsed = _collapsed.contains(index);
    final groupSelected = group.files.where((f) => _selected.contains(f.path));
    // 全选判定按「整组」算：允许把最新那份也勾上（用户可能就想删它、留别的副本）。
    final allChecked = groupSelected.length == group.files.length;
    final someChecked = groupSelected.isNotEmpty;

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: theme.dividerColor.withValues(alpha: 0.06)),
      ),
      child: Column(
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(16),
            onTap: () {
              setState(() {
                if (collapsed) {
                  _collapsed.remove(index);
                } else {
                  _collapsed.add(index);
                }
              });
            },
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(9),
                    decoration: BoxDecoration(
                      color: const Color(0xFF6366F1).withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Icon(
                      Broken.copy,
                      size: 18,
                      color: Color(0xFF6366F1),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '${FileUtils.formatBytes(group.size, 1)} · ${l10n.dup_group_count(group.files.length)}',
                          style: const TextStyle(
                            fontWeight: FontWeight.w700,
                            fontSize: 13.5,
                          ),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          l10n.dup_reclaimable(
                            FileUtils.formatBytes(group.wastedBytes, 1),
                          ),
                          style: TextStyle(
                            fontSize: 11.5,
                            color: theme.textTheme.bodySmall?.color
                                ?.withValues(alpha: 0.6),
                          ),
                        ),
                      ],
                    ),
                  ),
                  // 组内勾选状态：全选 / 部分 / 未选（三态）
                  Checkbox(
                    value: allChecked ? true : (someChecked ? null : false),
                    tristate: true,
                    onChanged: (_) {
                      setState(() {
                        if (allChecked) {
                          for (final f in group.files) {
                            _selected.remove(f.path);
                          }
                        } else {
                          for (final f in group.files) {
                            _selected.add(f.path);
                          }
                        }
                      });
                    },
                  ),
                  Icon(
                    collapsed
                        ? Icons.keyboard_arrow_down_rounded
                        : Icons.keyboard_arrow_up_rounded,
                    size: 20,
                    color: theme.textTheme.bodySmall?.color?.withValues(alpha: 0.5),
                  ),
                ],
              ),
            ),
          ),
          if (!collapsed) ...[
            Divider(
              height: 1,
              color: theme.dividerColor.withValues(alpha: 0.06),
            ),
            for (final f in group.files) _buildFileRow(theme, l10n, f, group),
            const SizedBox(height: 4),
          ],
        ],
      ),
    );
  }

  Widget _buildFileRow(
    ThemeData theme,
    L10n l10n,
    DupFile file,
    DupGroup group,
  ) {
    final isKeeper = identical(file, group.keeper) || file.path == group.keeper.path;
    final checked = _selected.contains(file.path);
    // 每一行都可勾选 —— 包括「最新那份」：用户可能想保留别的副本、删掉这份
    // （例如最新那份在临时目录里，他想留归档目录里的旧副本）。
    // 默认勾选策略仍在 [_startScan] 里（只勾旧副本），这里只放开手动操作。
    return InkWell(
      onTap: () {
        setState(() {
          if (checked) {
            _selected.remove(file.path);
          } else {
            _selected.add(file.path);
          }
        });
      },
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 2, 12, 2),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Checkbox(
              value: checked,
              onChanged: (v) {
                setState(() {
                  if (v == true) {
                    _selected.add(file.path);
                  } else {
                    _selected.remove(file.path);
                  }
                });
              },
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.only(top: 10, bottom: 10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            file.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: isKeeper
                                  ? FontWeight.w700
                                  : FontWeight.w500,
                              decoration:
                                  checked ? TextDecoration.lineThrough : null,
                              color: checked
                                  ? theme.textTheme.bodySmall?.color
                                      ?.withValues(alpha: 0.6)
                                  : null,
                            ),
                          ),
                        ),
                        // 「保留」只是**默认推荐**：用户一旦勾选它（要删掉它），
                        // 标签就必须消失，否则和删除线自相矛盾。
                        if (isKeeper && !checked) ...[
                          const SizedBox(width: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 1,
                            ),
                            decoration: BoxDecoration(
                              color: const Color(0xFF10B981)
                                  .withValues(alpha: 0.14),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Text(
                              l10n.dup_keep_label,
                              style: const TextStyle(
                                fontSize: 10,
                                fontWeight: FontWeight.w700,
                                color: Color(0xFF10B981),
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      file.directory,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 11,
                        color: theme.textTheme.bodySmall?.color
                            ?.withValues(alpha: 0.55),
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      FileUtils.formatDateCompact(file.modified),
                      style: TextStyle(
                        fontSize: 10.5,
                        color: theme.textTheme.bodySmall?.color
                            ?.withValues(alpha: 0.45),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBottomBar(ThemeData theme, L10n l10n, bool hasSelection) {
    return Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        border: Border(
          top: BorderSide(color: theme.dividerColor.withValues(alpha: 0.08)),
        ),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      l10n.dup_selected(_selectedCount),
                      style: const TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 13,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      l10n.dup_reclaimable(
                        FileUtils.formatBytes(_selectedBytes, 1),
                      ),
                      style: TextStyle(
                        fontSize: 11.5,
                        color: theme.textTheme.bodySmall?.color
                            ?.withValues(alpha: 0.6),
                      ),
                    ),
                  ],
                ),
              ),
              FilledButton.icon(
                onPressed: (!hasSelection || _cleaning) ? null : _onClean,
                icon: _cleaning
                    ? const SizedBox(
                        width: 15,
                        height: 15,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : const Icon(Broken.trash, size: 17),
                label: Text(l10n.dup_clean_button),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
