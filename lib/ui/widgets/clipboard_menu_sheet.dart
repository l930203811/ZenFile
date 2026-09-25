import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../../core/icon_fonts/broken_icons.dart';
import '../../core/utils.dart';
import '../../l10n/generated/app_localizations.dart';
import '../../providers/file_manager_provider.dart';

/// 剪贴板面板（**全项目唯一实现**，单窗口 + 双窗口共用）。
///
/// ## 为什么抽成共享组件
/// `directory_screen`（单窗口）与 `pane_browser`（双窗口）原本各有一份逐字相同的
/// 剪贴板面板。本项目的铁律之一是「同一功能有多份实现时，改一处 ≠ 改完」（已踩
/// 过 4 次），所以这里合并成一份：调用方只提供「粘贴这件事怎么做」（`onPaste`），
/// 其余 UI 与语义全部在本文件维护。
///
/// ## 按钮语义（从左到右：清除 / 粘贴 / 粘贴并清除）
/// - **粘贴**：默认**不清空**剪贴板。便于把同一批文件依次粘到多个远程客户端、
///   多个目录（「复制到多处」的高频诉求）。
/// - **粘贴并清除**：粘贴后清空剪贴板（旧行为，一次性场景用）。
/// - **剪切模式**下不显示「粘贴并清除」：剪切本质是「移动」，源条目粘贴后即从
///   原处消失，剪贴板里剩的是死路径，重复粘贴必然失败 —— 保留它没有意义。此时
///   由「粘贴」按钮直接承担「移动并清空」，避免出现两个行为完全相同的按钮。
///
/// ## 显示内容
/// 列表项按**真实文件类型**给图标与配色（复用 [FileUtils.getIconForFile] /
/// [FileUtils.getColorForFile]，与文件列表页保持一致；目录用用户设置里的文件夹
/// 图标样式），而不是之前统一的灰白纸张图标。
Future<void> showClipboardMenuSheet(
  BuildContext context, {
  required FileManagerProvider provider,
  required Future<void> Function({required bool clearAfterPaste}) onPaste,
}) {
  final l10n = L10n.of(context);
  final theme = Theme.of(context);
  final isCut = provider.isCut;
  final items = _collectClipboardItems(provider);
  final prefix = isCut ? l10n.ui_cut : l10n.ui_copy;
  const maxItemHeight = 200.0;

  return showDialog<void>(
    context: context,
    barrierColor: Colors.black26,
    builder: (sheetContext) => Stack(
      children: [
        GestureDetector(
          onTap: () => Navigator.pop(sheetContext),
          child: Container(color: Colors.transparent),
        ),
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          child: Container(
            margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
            decoration: BoxDecoration(
              color: theme.colorScheme.surface,
              borderRadius: BorderRadius.circular(16),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.2),
                  blurRadius: 20,
                  offset: const Offset(0, 8),
                ),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // 标题：剪切/复制 + 条目数
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                  child: Row(
                    children: [
                      Icon(
                        isCut ? Broken.scissor : Broken.clipboard,
                        size: 16,
                        color: isCut
                            ? Colors.orange
                            : theme.colorScheme.primary,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          l10n.ui_cut_copy_items(prefix, items.length),
                          style: theme.textTheme.labelMedium?.copyWith(
                            fontWeight: FontWeight.bold,
                            color: isCut
                                ? Colors.orange
                                : theme.colorScheme.primary,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ),
                // 剪切模式：说明「粘贴」为何只剩一个按钮（否则用户会以为按钮丢了）
                if (isCut)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 2),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            l10n.ui_cut_paste_hint,
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: theme.colorScheme.onSurface.withOpacity(
                                0.5,
                              ),
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ),
                // 条目列表
                Flexible(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(
                      maxHeight: maxItemHeight,
                    ),
                    child: ListView.builder(
                      shrinkWrap: true,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 4,
                      ),
                      itemCount: items.length,
                      itemBuilder: (_, i) => _ClipboardItemRow(
                        item: items[i],
                        folderIconOption: provider.folderIconOption,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 4),
                // 操作按钮：清除 / 粘贴 / 粘贴并清除
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
                  child: Row(
                    children: [
                      // 清除（最左，描边小按钮）
                      Expanded(
                        flex: 2,
                        child: OutlinedButton(
                          onPressed: () {
                            Navigator.pop(sheetContext);
                            provider.clearClipboard();
                          },
                          style: OutlinedButton.styleFrom(
                            foregroundColor: theme.colorScheme.error,
                            side: BorderSide(
                              color: theme.colorScheme.error.withOpacity(0.25),
                            ),
                            padding: const EdgeInsets.symmetric(
                              vertical: 8,
                              horizontal: 4,
                            ),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(10),
                            ),
                          ),
                          child: _ButtonLabel(
                            text: l10n.ui_clear,
                            fontSize: 13,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      // 粘贴（保留剪贴板）：连续粘到多处的入口
                      Expanded(
                        flex: isCut ? 5 : 3,
                        child: ElevatedButton.icon(
                          onPressed: () async {
                            Navigator.pop(sheetContext);
                            // 剪切必须清空（源已被移走，留着是死路径）；
                            // 复制则保留，便于连续粘贴到多个目录。
                            await onPaste(clearAfterPaste: isCut);
                          },
                          icon: const Icon(Icons.content_paste, size: 16),
                          label: _ButtonLabel(
                            text: l10n.ui_paste,
                            fontSize: 14,
                            bold: true,
                          ),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: theme.colorScheme.primary,
                            foregroundColor: theme.colorScheme.onPrimary,
                            padding: const EdgeInsets.symmetric(
                              vertical: 8,
                              horizontal: 4,
                            ),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(10),
                            ),
                          ),
                        ),
                      ),
                      // 粘贴并清除（最右）：剪切模式下不显示（与「粘贴」行为相同）
                      if (!isCut) ...[
                        const SizedBox(width: 8),
                        Expanded(
                          flex: 4,
                          child: ElevatedButton.icon(
                            onPressed: () async {
                              Navigator.pop(sheetContext);
                              await onPaste(clearAfterPaste: true);
                            },
                            icon: const Icon(Icons.content_paste_go, size: 16),
                            label: _ButtonLabel(
                              text: l10n.ui_paste_and_clear,
                              fontSize: 14,
                              bold: true,
                            ),
                            style: ElevatedButton.styleFrom(
                              // 次强调色：避免与「粘贴」两个实心主色按钮并排、
                              // 让用户误触「顺手清空」。
                              backgroundColor:
                                  theme.colorScheme.primaryContainer,
                              foregroundColor:
                                  theme.colorScheme.onPrimaryContainer,
                              padding: const EdgeInsets.symmetric(
                                vertical: 8,
                                horizontal: 4,
                              ),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(10),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    ),
  );
}

/// 剪贴板里的一条内容（只取展示所需字段）。
class _ClipboardEntry {
  final String name;
  final bool isDirectory;

  const _ClipboardEntry({required this.name, required this.isDirectory});
}

/// 把 provider 的剪贴板内容拍平成展示条目。
///
/// 在弹面板**之前**调用（只算一次）：本地条目判断是否为目录需要一次 `stat`，
/// 放在 build 里会随重建反复触发同步 IO。
List<_ClipboardEntry> _collectClipboardItems(FileManagerProvider provider) {
  if (provider.isRemoteClipboard) {
    return provider.remoteClipboardItems
        .map(
          (e) =>
              _ClipboardEntry(name: e.name, isDirectory: e.isDirectory),
        )
        .toList();
  }
  return provider.clipboardPaths.map((path) {
    var isDir = false;
    try {
      isDir = FileSystemEntity.isDirectorySync(path);
    } catch (_) {
      // 受限目录（Android/data、/data 等）元数据被 FUSE 拦截时按文件图标显示，
      // 不影响粘贴本身。
    }
    return _ClipboardEntry(name: p.basename(path), isDirectory: isDir);
  }).toList();
}

/// 剪贴板列表的一行：真实文件类型图标 + 文件名。
class _ClipboardItemRow extends StatelessWidget {
  final _ClipboardEntry item;
  final String folderIconOption;

  const _ClipboardItemRow({
    required this.item,
    required this.folderIconOption,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final icon = item.isDirectory
        ? FileUtils.getFolderIcon(folderIconOption)
        : FileUtils.getIconForFile(item.name);
    final color = item.isDirectory
        ? theme.colorScheme.primary
        : FileUtils.getColorForFile(item.name, context);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Icon(icon, size: 16, color: color),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              item.name,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurface.withOpacity(0.7),
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}

/// 按钮文案：`FittedBox` 兜住「非中文语言 + 系统大字号」下的横排溢出
/// （例如德语 "Einfügen und löschen" 比中文长得多），必要时等比缩小而不截断。
class _ButtonLabel extends StatelessWidget {
  final String text;
  final double fontSize;
  final bool bold;

  const _ButtonLabel({
    required this.text,
    required this.fontSize,
    this.bold = false,
  });

  @override
  Widget build(BuildContext context) {
    return FittedBox(
      fit: BoxFit.scaleDown,
      child: Text(
        text,
        maxLines: 1,
        style: TextStyle(
          fontSize: fontSize,
          fontWeight: bold ? FontWeight.bold : FontWeight.w500,
        ),
      ),
    );
  }
}
