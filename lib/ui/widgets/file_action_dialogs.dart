import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/icon_fonts/broken_icons.dart';
import '../../core/file_name_validation.dart';
import '../../core/utils.dart';
import '../../services/apk_installer_service.dart';
import 'package:zenfile/l10n/generated/app_localizations.dart';
import '../../providers/file_manager_provider.dart';
import '../../services/preferences_service.dart';
import 'package:path/path.dart' as p;

/// 删除确认弹窗中展示的单个待删条目（文件图标 + 文件名）。
class DeleteConfirmItem {
  const DeleteConfirmItem({required this.name, this.isDirectory = false});

  /// 显示名（不含路径）。
  final String name;

  /// 是否目录：决定图标用文件夹还是按扩展名判定的文件图标。
  final bool isDirectory;
}

/// 待删条目集合：自带「预览上限 + 隐藏计数」。
///
/// 用户一次选中上千个文件时，弹窗只列前 [FileActionDialogs.maxPreviewItems]
/// 条，剩余合并成一行「还有 N 项」——既保住「看清删的是什么」的预览意义，
/// 又不让弹窗首帧去 build 几千个行。
class DeleteConfirmItems {
  /// 从完整条目列表构造（内部自行截断到预览上限）。
  factory DeleteConfirmItems.from(Iterable<DeleteConfirmItem> all) {
    final preview = all
        .take(FileActionDialogs.maxPreviewItems)
        .toList(growable: false);
    return DeleteConfirmItems._(preview, all.length);
  }

  const DeleteConfirmItems._(this.items, this.totalCount);

  /// 实际参与预览的条目（已截断）。
  final List<DeleteConfirmItem> items;

  /// 待删条目真实总数。
  final int totalCount;

  /// 因超上限而未逐条展示的条数。
  int get hiddenCount => totalCount - items.length;

  bool get isNotEmpty => totalCount > 0;
}

class FileActionDialogs {
  static Future<String?> showTextInputDialog(
    BuildContext context, {
    required String title,
    required String hint,
    String initialValue = '',
    required String actionText,

    /// 为 true 时自动选中文件名主体（不含扩展名），光标落在扩展名前，
    /// 方便重命名且不易误改后缀名。一般仅重命名场景使用。
    bool selectNameWithoutExtension = false,
  }) async {
    final controller = TextEditingController(text: initialValue);
    // 计算初始选择范围：有扩展名则选中主体（不含点），否则全选整个名称。
    TextSelection? initialSelection;
    if (selectNameWithoutExtension) {
      final dot = initialValue.lastIndexOf('.');
      final cutoff = dot > 0 ? dot : initialValue.length;
      initialSelection = TextSelection(baseOffset: 0, extentOffset: cutoff);
      controller.selection = initialSelection;
    }

    return showDialog<String>(
      context: context,
      builder: (context) {
        // autofocus 可能把光标移到文本末尾，首帧后再强制应用「选中主体」范围。
        if (initialSelection != null) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            controller.selection = initialSelection!;
          });
        }
        return AlertDialog(
          title: Text(title),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
          ),
          content: TextField(
            controller: controller,
            decoration: InputDecoration(
              hintText: hint,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide(
                  color: Theme.of(context).colorScheme.primary,
                  width: 2,
                ),
              ),
            ),
            autofocus: true,
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(L10n.of(context).ui_cancel),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, controller.text),
              style: FilledButton.styleFrom(
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              child: Text(actionText),
            ),
          ],
        );
      },
    );
  }

  /// 删除确认的统一入口：
  /// 设置中「删除文件确认」开关关闭时直接返回 true（跳过弹窗），
  /// 开启时弹出带「删除不再提示」复选框的确认对话框。
  ///
  /// [items] 非空时，弹窗会附带一块「待删条目预览」（图标 + 文件名），
  /// 高度随条数自适应，让用户在点下删除前看清到底删了哪些东西。
  static Future<bool> showDeleteConfirmDialog(
    BuildContext context, {
    required String title,
    required String content,
    DeleteConfirmItems? items,
  }) async {
    // 开关关闭 → 直接删除，不再弹窗
    if (!PreferencesService.getDeleteConfirmEnabled()) return true;
    return showConfirmDialog(
      context,
      title: title,
      content: content,
      showSkipCheckbox: true,
      items: items,
    );
  }

  /// 预览区最多逐条列出的条数（超出合并为「还有 N 项」）。
  static const int maxPreviewItems = 50;

  /// 预览区最多同时可见的行数（超出部分在预览区内部滚动）。
  static const int maxVisibleRows = 5;

  /// 单行高度（含留白），用于按条数推算预览区高度。
  static const double previewRowExtent = 52.0;

  /// 由路径列表构造 [DeleteConfirmItems]：各删除入口共用同一套取名 / 判目录
  /// 逻辑，避免每个调用点各写一份 `p.basename` + `existsSync`。
  ///
  /// - 名称走 [FileUtils.zipEntryDisplayName]：zip:// 的目录条目带尾斜杠，
  ///   `p.basename` 会拿到空串；
  /// - 是否目录：zip 条目看尾斜杠，本地条目 `Directory.existsSync()`，
  ///   远程条目（`remote://`）判不出，按文件处理（只影响图标）；
  /// - 先 `toList()` 做纯 O(n) 计数，**截断之后**才做同步 stat —— 不会为
  ///   上千个选中项各打一次盘。
  static DeleteConfirmItems itemsFromPaths(Iterable<String> paths) {
    final all = paths.toList(growable: false);
    final preview = all
        .take(maxPreviewItems)
        .map(
          (path) => DeleteConfirmItem(
            name: _displayNameForPath(path),
            isDirectory: _isDirectoryPathSync(path),
          ),
        )
        .toList(growable: false);
    return DeleteConfirmItems._(preview, all.length);
  }

  static String _displayNameForPath(String path) {
    final name = FileUtils.zipEntryDisplayName(path) ?? p.posix.basename(path);
    return name.isEmpty ? path : name;
  }

  static bool _isDirectoryPathSync(String path) {
    if (path.endsWith('/')) return true; // zip:// 目录条目
    if (path.startsWith('remote://') || path.startsWith('zip://')) return false;
    try {
      return Directory(path).existsSync();
    } catch (_) {
      return false;
    }
  }

  static Future<bool> showConfirmDialog(
    BuildContext context, {
    required String title,
    required String content,
    bool showSkipCheckbox = false,
    DeleteConfirmItems? items,
  }) async {
    var dontAskAgain = false;
    final result = await showDialog<bool>(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setState) {
            return AlertDialog(
              title: Text(title),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(content),
                  if (items != null && items.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    _DeleteItemsPreview(items: items),
                  ],
                  if (showSkipCheckbox) ...[
                    const SizedBox(height: 8),
                    CheckboxListTile(
                      value: dontAskAgain,
                      onChanged: (v) =>
                          setState(() => dontAskAgain = v ?? false),
                      controlAffinity: ListTileControlAffinity.leading,
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      title: Text(
                        L10n.of(context).ui_delete_confirm_dont_ask,
                        style: const TextStyle(fontSize: 13),
                      ),
                    ),
                  ],
                ],
              ),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(20),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: Text(L10n.of(context).ui_cancel),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(context, true),
                  style: FilledButton.styleFrom(
                    backgroundColor: Colors.red,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  child: Text(L10n.of(context).ui_delete),
                ),
              ],
            );
          },
        );
      },
    );
    // 勾选了"删除不再提示"且确认删除 → 持久化关闭删除确认
    if (result == true && dontAskAgain) {
      PreferencesService.saveDeleteConfirmEnabled(false);
      try {
        context.read<FileManagerProvider>().setDeleteConfirmEnabled(false);
      } catch (_) {}
    }
    return result ?? false;
  }

  /// 显示重命名输入对话框，并在检测到文件后缀名变更时提示用户确认。
  /// 返回最终确认的新名称；用户取消则返回 null。
  static Future<String?> showRenameDialog(
    BuildContext context, {
    required String currentName,
    required String title,
    required String hint,
    required String actionText,
  }) async {
    final newName = await showTextInputDialog(
      context,
      title: title,
      hint: hint,
      initialValue: currentName,
      actionText: actionText,
      selectNameWithoutExtension: true,
    );
    if (newName == null || newName.isEmpty || newName == currentName) {
      return newName;
    }
    // 名称合法性校验：拒绝含路径分隔符等的非法名称。历史上重命名对用户
    // 输入零校验，名称带 '/' 会拼出嵌套路径（a.jpg → a.jpg/a.jpg），
    // rename() 失败后的兜底逻辑会把同名文件夹真的建出来——表现为
    // 「自动创建同名文件夹、文件躺在文件夹里」。
    final problem = validateFileName(newName);
    if (problem != null) {
      await showWarningDialog(
        context,
        title: L10n.of(context).msg_name_invalid_title,
        content: fileNameProblemText(L10n.of(context), problem),
      );
      return null;
    }
    // 检测后缀名是否变更（针对文件，非目录）
    final oldExt = _extractExtension(currentName);
    final newExt = _extractExtension(newName);
    // 目录通常无后缀或后缀无意义；仅当原文件名存在后缀且发生变更时提示
    if (oldExt.isNotEmpty && oldExt.toLowerCase() != newExt.toLowerCase()) {
      final l10n = L10n.of(context);
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (ctx) {
          return AlertDialog(
            title: Text(l10n.msg_rename_extension_warning_title),
            content: Text(l10n.msg_rename_extension_warning_content),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(20),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: Text(l10n.ui_cancel),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                style: FilledButton.styleFrom(
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                child: Text(l10n.msg_rename_extension_confirm),
              ),
            ],
          );
        },
      );
      if (confirmed != true) {
        return null;
      }
    }
    return newName;
  }

  /// 提取文件名后缀（不含点），无后缀返回空字符串
  static String _extractExtension(String name) {
    final lastDot = name.lastIndexOf('.');
    // 文件名以点开头（如 .gitignore）视为无后缀
    if (lastDot <= 0) return '';
    return name.substring(lastDot + 1);
  }

  static Future<void> showWarningDialog(
    BuildContext context, {
    required String title,
    required String content,
  }) async {
    await showDialog<void>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text(title),
          content: Text(content),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
          ),
          actions: [
            FilledButton(
              onPressed: () => Navigator.pop(context),
              style: FilledButton.styleFrom(
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              child: Text(L10n.of(context).ui_confirm),
            ),
          ],
        );
      },
    );
  }

  /// 收藏时选择分组。
  /// 返回 null 表示用户取消；返回 '' 表示默认分组；返回非空字符串表示分组名。
  static Future<String?> showFavoriteGroupPicker(
    BuildContext context, {
    required List<String> existingGroups,
    String? currentGroup,
  }) async {
    final l10n = L10n.of(context);
    final newGroupController = TextEditingController(text: currentGroup);
    const newGroupValue = '__new__';
    final isExisting =
        currentGroup != null &&
        currentGroup.isNotEmpty &&
        existingGroups.contains(currentGroup);
    String? selectedGroup = isExisting
        ? currentGroup
        : (currentGroup != null && currentGroup.isNotEmpty
              ? newGroupValue
              : null);

    return showDialog<String?>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSt) => AlertDialog(
          title: Text(l10n.ui_select_group),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
          ),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                InputDecorator(
                  decoration: InputDecoration(labelText: l10n.ui_group),
                  child: DropdownButtonHideUnderline(
                    child: DropdownButton<String?>(
                      value: selectedGroup,
                      isDense: true,
                      isExpanded: true,
                      items: [
                        DropdownMenuItem(
                          value: null,
                          child: Text(l10n.ui_default_group),
                        ),
                        ...existingGroups.map(
                          (g) => DropdownMenuItem(value: g, child: Text(g)),
                        ),
                        DropdownMenuItem(
                          value: newGroupValue,
                          child: Text(l10n.ui_new_group),
                        ),
                      ],
                      onChanged: (v) => setSt(() => selectedGroup = v),
                    ),
                  ),
                ),
                if (selectedGroup == newGroupValue) ...[
                  const SizedBox(height: 12),
                  TextField(
                    controller: newGroupController,
                    decoration: InputDecoration(labelText: l10n.ui_group_name),
                  ),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(l10n.ui_cancel),
            ),
            FilledButton(
              onPressed: () {
                String? group;
                if (selectedGroup == newGroupValue) {
                  group = newGroupController.text.trim();
                  if (group.isEmpty) {
                    ScaffoldMessenger.of(ctx).showSnackBar(
                      SnackBar(content: Text(l10n.msg_please_enter_group_name)),
                    );
                    return;
                  }
                } else {
                  group = selectedGroup;
                }
                Navigator.pop(ctx, group ?? '');
              },
              style: FilledButton.styleFrom(
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              child: Text(l10n.ui_save),
            ),
          ],
        ),
      ),
    );
  }

  /// 编辑已有收藏（名称 / 路径 / 分组）。
  /// 预填 initial* 值；确认返回 [FavoriteEditResult]，取消返回 null。
  static Future<FavoriteEditResult?> showFavoriteEditor(
    BuildContext context, {
    required List<String> existingGroups,
    required String initialPath,
    required String initialName,
    String? initialGroup,
  }) async {
    final l10n = L10n.of(context);
    final pathController = TextEditingController(text: initialPath);
    final nameController = TextEditingController(text: initialName);
    final newGroupController = TextEditingController(text: initialGroup);
    const newGroupValue = '__new__';
    final isExisting =
        initialGroup != null &&
        initialGroup.isNotEmpty &&
        existingGroups.contains(initialGroup);
    String? selectedGroup = isExisting
        ? initialGroup
        : (initialGroup != null && initialGroup.isNotEmpty
              ? newGroupValue
              : null);

    return showDialog<FavoriteEditResult>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSt) => AlertDialog(
          title: Text(l10n.ui_edit_favorite),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
          ),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: pathController,
                  decoration: InputDecoration(labelText: l10n.ui_path),
                  keyboardType: TextInputType.text,
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: nameController,
                  decoration: InputDecoration(labelText: l10n.ui_name),
                  keyboardType: TextInputType.text,
                ),
                const SizedBox(height: 12),
                InputDecorator(
                  decoration: InputDecoration(labelText: l10n.ui_group),
                  child: DropdownButtonHideUnderline(
                    child: DropdownButton<String?>(
                      value: selectedGroup,
                      isDense: true,
                      isExpanded: true,
                      items: [
                        DropdownMenuItem(
                          value: null,
                          child: Text(l10n.ui_default_group),
                        ),
                        ...existingGroups.map(
                          (g) => DropdownMenuItem(value: g, child: Text(g)),
                        ),
                        DropdownMenuItem(
                          value: newGroupValue,
                          child: Text(l10n.ui_new_group),
                        ),
                      ],
                      onChanged: (v) => setSt(() => selectedGroup = v),
                    ),
                  ),
                ),
                if (selectedGroup == newGroupValue) ...[
                  const SizedBox(height: 12),
                  TextField(
                    controller: newGroupController,
                    decoration: InputDecoration(labelText: l10n.ui_group_name),
                  ),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(l10n.ui_cancel),
            ),
            FilledButton(
              onPressed: () {
                final path = pathController.text.trim();
                final name = nameController.text.trim();
                if (path.isEmpty) {
                  ScaffoldMessenger.of(ctx).showSnackBar(
                    SnackBar(content: Text(l10n.msg_please_enter_path)),
                  );
                  return;
                }
                if (name.isEmpty) {
                  ScaffoldMessenger.of(ctx).showSnackBar(
                    SnackBar(content: Text(l10n.msg_please_enter_name)),
                  );
                  return;
                }
                String? group;
                if (selectedGroup == newGroupValue) {
                  group = newGroupController.text.trim();
                  if (group.isEmpty) {
                    ScaffoldMessenger.of(ctx).showSnackBar(
                      SnackBar(content: Text(l10n.msg_please_enter_group_name)),
                    );
                    return;
                  }
                } else {
                  group = selectedGroup;
                }
                Navigator.pop(ctx, FavoriteEditResult(path, name, group));
              },
              style: FilledButton.styleFrom(
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              child: Text(l10n.ui_save),
            ),
          ],
        ),
      ),
    );
  }
}

/// 编辑收藏的返回结果
class FavoriteEditResult {
  final String path;
  final String name;
  final String? group;
  FavoriteEditResult(this.path, this.name, this.group);
}

class ActionItem {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool destructive;
  /// false 时按钮置灰不可点（对当前条目不适用的动作，如 zip:// 条目的
  /// 加密/收藏/分享等），避免用户点了没反应误以为是 bug。
  final bool enabled;
  const ActionItem({
    required this.icon,
    required this.label,
    required this.onTap,
    this.destructive = false,
    this.enabled = true,
  });
}

class ActionGridSheet {
  static Future<void> show(
    BuildContext context, {
    String? title,
    required List<ActionItem> items,
  }) {
    final theme = Theme.of(context);
    final int cols = items.length > 8 ? 4 : 3;
    return showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) {
        return Container(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(ctx).size.height * 0.85,
          ),
          decoration: BoxDecoration(
            color: theme.colorScheme.surface,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
          ),
          child: SafeArea(
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Center(
                    child: Container(
                      width: 38,
                      height: 4,
                      margin: const EdgeInsets.only(top: 12, bottom: 8),
                      decoration: BoxDecoration(
                        color: theme.colorScheme.onSurface.withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                  if (title != null)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
                      child: Text(
                        title,
                        style: theme.textTheme.titleMedium,
                        textAlign: TextAlign.center,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  if (title != null)
                    Divider(height: 1, thickness: 1, color: theme.colorScheme.onSurface.withValues(alpha: 0.1)),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 4, 12, 16),
                    child: GridView.count(
                      crossAxisCount: cols,
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      childAspectRatio: 0.92,
                      mainAxisSpacing: 4,
                      crossAxisSpacing: 4,
                      children: items
                          .map((a) => _ActionGridTile(item: a, theme: theme))
                          .toList(),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _ActionGridTile extends StatelessWidget {
  final ActionItem item;
  final ThemeData theme;
  const _ActionGridTile({required this.item, required this.theme});

  @override
  Widget build(BuildContext context) {
    // 置灰态：图标与文字降低不透明度，点击无响应（也不关闭面板）
    final disabled = !item.enabled;
    final color = item.destructive
        ? theme.colorScheme.error
        : theme.colorScheme.primary;
    final labelColor = item.destructive
        ? theme.colorScheme.error
        : theme.colorScheme.onSurface;
    return Opacity(
      opacity: disabled ? 0.38 : 1.0,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: disabled ? null : () {
          Navigator.pop(context);
          item.onTap();
        },
      child: Column(
        mainAxisAlignment: MainAxisAlignment.start,
        children: [
          Icon(item.icon, size: 26, color: color),
          const SizedBox(height: 6),
          Expanded(
            child: Align(
              alignment: Alignment.topCenter,
              child: Text(
                item.label,
                style: TextStyle(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w600,
                  color: labelColor,
                ),
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
        ],
      ),
      ),
    );
  }
}

class FileActionSheet {
  static Future<void> show(
    BuildContext context,
    Function(String) onAction, {
    bool isArchive = false,
    bool showShare = false,
    bool showInLocation = false,
    bool openWith = false,
    bool showSetAsHome = false,
    bool isCurrentHome = false,
    String? filePath,
    bool isEncrypted = false,
    bool isPinned = false,
  }) {
    // zip 内条目（zip:// 虚拟路径）：v2 写能力上线后「压缩」失去意义
    // （嵌套压缩会生成幽灵包），替换为「解压当前条目」到 zip 所在真实目录；
    // 顶部 isArchive 的解压项与替换后的解压项重复，一并隐藏。
    //
    // 已实现且可用的写动作：copy / cut / delete / rename / extract（走 zip 重写
    // 链路）；其余动作（设为首页/在位置中显示/打开方式/加密/置顶/收藏/属性/分享）
    // 只认真实文件系统路径，对 zip:// 虚拟路径均无效 —— 统一置灰不可点，
    // 避免用户点击无反应误以为是 bug。
    final isZipEntry = filePath?.startsWith('zip://') ?? false;
    // 仅本地 .apk 文件显示「克隆到分身」：远程/加密/zip 内条目无法直接 pm install
    // （路径以 / 开头即可排除 zip://、remote://、cryptremote:// 等虚拟路径）。
    final isLocalApk = filePath != null &&
        filePath.startsWith('/') &&
        ApkInstallerService.isApk(filePath);
    final items = <ActionItem>[
      if (isArchive && !isZipEntry)
        ActionItem(
          icon: Broken.archive,
          label: L10n.of(context).ui_extract,
          onTap: () => onAction('extract'),
        ),
      ActionItem(
        icon: Broken.document_copy,
        label: L10n.of(context).ui_copy,
        onTap: () => onAction('copy'),
      ),
      ActionItem(
        icon: Broken.scissor,
        label: L10n.of(context).ui_cut,
        onTap: () => onAction('cut'),
      ),
      ActionItem(
        icon: Broken.trash,
        label: L10n.of(context).ui_delete,
        destructive: true,
        onTap: () => onAction('delete'),
      ),
      ActionItem(
        icon: Broken.edit,
        label: L10n.of(context).msgc8ce4b36,
        onTap: () => onAction('rename'),
      ),
      // 顺序与分类页一致：分类页此位置为「在位置中显示」，浏览页对应为「设为首页」
      if (showSetAsHome)
        ActionItem(
          icon: isCurrentHome ? Icons.home_outlined : Broken.home_2,
          label: isCurrentHome
              ? L10n.of(context).ui_cancel_set_as_home
              : L10n.of(context).ui_set_as_home,
          onTap: () => onAction(isCurrentHome ? 'clear_home' : 'set_as_home'),
          enabled: !isZipEntry,
        ),
      if (showInLocation)
        ActionItem(
          icon: Broken.folder_open,
          label: L10n.of(context).msgcd8264f1,
          onTap: () => onAction('show_in_location'),
          enabled: !isZipEntry,
        ),
      if (openWith)
        ActionItem(
          icon: Broken.eye,
          label: L10n.of(context).msg2a4cfb07,
          onTap: () => onAction('open_with'),
          enabled: !isZipEntry,
        ),
      // APK 特有动作：克隆到分身（Shizuku/root 多用户多开，见 AppCloneFlow）
      if (isLocalApk)
        ActionItem(
          icon: Broken.people,
          label: L10n.of(context).ui_clone_clone_to_user,
          onTap: () => onAction('app_clone'),
        ),
      // 压缩包内条目：压缩 → 解压（extractZipEntriesToParent）；普通条目：压缩
      isZipEntry
          ? ActionItem(
              icon: Broken.archive,
              label: L10n.of(context).ui_extract,
              onTap: () => onAction('extract'),
            )
          : ActionItem(
              icon: Broken.box_add,
              label: L10n.of(context).ui_compress,
              onTap: () => onAction('archive'),
            ),
      if (filePath != null)
        ActionItem(
          icon: isEncrypted ? Broken.unlock : Broken.lock,
          label: isEncrypted
              ? L10n.of(context).crypt_action_decrypt
              : L10n.of(context).vault_action_encrypt,
          onTap: () => onAction(isEncrypted ? 'decrypt' : 'encrypt'),
          enabled: !isZipEntry,
        ),
      ActionItem(
        icon: Icons.push_pin,
        label: isPinned
            ? L10n.of(context).ui_unpin
            : L10n.of(context).ui_pin_to_top,
        onTap: () => onAction(isPinned ? 'unpin' : 'pin_to_top'),
        enabled: !isZipEntry,
      ),
      ActionItem(
        icon: Broken.folder_favorite,
        label: L10n.of(context).ui_favorite,
        onTap: () => onAction('favorite'),
        enabled: !isZipEntry,
      ),
      ActionItem(
        icon: Broken.info_circle,
        label: L10n.of(context).ui_properties,
        onTap: () => onAction('properties'),
        enabled: !isZipEntry,
      ),
      if (showShare)
        ActionItem(
          icon: Icons.share_outlined,
          label: L10n.of(context).ui_share,
          onTap: () => onAction('share'),
          enabled: !isZipEntry,
        ),
    ];
    return ActionGridSheet.show(
      context,
      items: items,
      title: filePath != null ? p.basename(filePath) : null,
    );
  }
}

/// 删除确认弹窗的「待删条目预览」：图标 + 文件名，高度随条数自适应。
///
/// 高度算法：可见行数 = min(条数, [FileActionDialogs.maxVisibleRows])，
/// 超出的条数在预览区**内部**滚动；若还有因超上限被合并的条目，末尾再补
/// 一行「还有 N 项」并占掉一行高度。这样 1 个文件时是一行紧凑小条，
/// 几十个文件时是五屏高的可滚动列表，都不会把对话框顶出屏幕。
class _DeleteItemsPreview extends StatelessWidget {
  const _DeleteItemsPreview({required this.items});

  final DeleteConfirmItems items;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = L10n.of(context);
    final hidden = items.hiddenCount;
    final rows = items.items.length > FileActionDialogs.maxVisibleRows
        ? FileActionDialogs.maxVisibleRows
        : items.items.length;
    // 「还有 N 项」也按一行计高度，避免它把列表顶出约束。
    final visibleRows = rows + (hidden > 0 ? 1 : 0);
    // 高度随条数自适应，但**再取一道屏高上限**：AlertDialog 的内容不会自动
    // 滚动（Flutter 官方注释明确要求「有放不下的风险就该自己套
    // SingleChildScrollView」），小屏上 6 行 + 标题 + 复选框 + 按钮会把
    // 对话框顶出屏幕。上限取屏高 40%，超出的行在预览区内部滚动。
    final targetHeight = visibleRows * FileActionDialogs.previewRowExtent;
    final screenCap = MediaQuery.sizeOf(context).height * 0.4;
    final maxHeight = targetHeight <= screenCap ? targetHeight : screenCap;
    return Container(
      constraints: BoxConstraints(maxHeight: maxHeight),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceVariant.withValues(alpha: 0.3),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: theme.colorScheme.outline.withValues(alpha: 0.12),
        ),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final item in items.items) _DeleteItemRow(item: item),
              if (hidden > 0)
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 15,
                  ),
                  child: Text(
                    l10n.ui_delete_more_items(hidden),
                    style: TextStyle(
                      fontSize: 12,
                      color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 预览区单行：左侧按类型着色的图标，右侧文件名（超长省略）。
class _DeleteItemRow extends StatelessWidget {
  const _DeleteItemRow({required this.item});

  final DeleteConfirmItem item;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // 目录统一用主题色文件夹；文件走 FileUtils 的扩展名判定，
    // 与列表页图标同源（用户在看到弹窗时能对上号）。
    final icon = item.isDirectory
        ? Broken.folder
        : FileUtils.getIconForFile(item.name);
    final color = item.isDirectory
        ? theme.colorScheme.primary
        : FileUtils.getColorForFile(item.name, context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Row(
        children: [
          Icon(icon, size: 20, color: color),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              item.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }
}
