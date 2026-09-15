import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/icon_fonts/broken_icons.dart';
import 'package:zenfile/l10n/generated/app_localizations.dart';
import '../../providers/file_manager_provider.dart';
import '../../services/preferences_service.dart';

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
  static Future<bool> showDeleteConfirmDialog(
    BuildContext context, {
    required String title,
    required String content,
  }) async {
    // 开关关闭 → 直接删除，不再弹窗
    if (!PreferencesService.getDeleteConfirmEnabled()) return true;
    return showConfirmDialog(
      context,
      title: title,
      content: content,
      showSkipCheckbox: true,
    );
  }

  static Future<bool> showConfirmDialog(
    BuildContext context, {
    required String title,
    required String content,
    bool showSkipCheckbox = false,
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
  const ActionItem({
    required this.icon,
    required this.label,
    required this.onTap,
    this.destructive = false,
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
                        color: theme.colorScheme.onSurface.withOpacity(0.15),
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
    final color = item.destructive
        ? theme.colorScheme.error
        : theme.colorScheme.primary;
    final labelColor = item.destructive
        ? theme.colorScheme.error
        : theme.colorScheme.onSurface;
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: () {
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
  }) {
    final items = <ActionItem>[
      if (isArchive)
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
        ),
      if (showInLocation)
        ActionItem(
          icon: Broken.folder_open,
          label: L10n.of(context).msgcd8264f1,
          onTap: () => onAction('show_in_location'),
        ),
      if (openWith)
        ActionItem(
          icon: Broken.eye,
          label: L10n.of(context).msg2a4cfb07,
          onTap: () => onAction('open_with'),
        ),
      ActionItem(
        icon: Broken.box_add,
        label: L10n.of(context).ui_compress,
        onTap: () => onAction('archive'),
      ),
      if (filePath != null)
        ActionItem(
          icon: isEncrypted ? Icons.lock_open : Icons.lock,
          label: isEncrypted
              ? L10n.of(context).crypt_action_decrypt
              : L10n.of(context).vault_action_encrypt,
          onTap: () => onAction(isEncrypted ? 'decrypt' : 'encrypt'),
        ),
      ActionItem(
        icon: Broken.folder_favorite,
        label: L10n.of(context).ui_favorite,
        onTap: () => onAction('favorite'),
      ),
      ActionItem(
        icon: Broken.info_circle,
        label: L10n.of(context).ui_properties,
        onTap: () => onAction('properties'),
      ),
      if (showShare)
        ActionItem(
          icon: Icons.share_outlined,
          label: L10n.of(context).ui_share,
          onTap: () => onAction('share'),
        ),
    ];
    return ActionGridSheet.show(context, items: items);
  }
}
