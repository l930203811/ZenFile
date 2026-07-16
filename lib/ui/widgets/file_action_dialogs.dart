import 'package:flutter/material.dart';
import '../../core/icon_fonts/broken_icons.dart';
import 'package:zenfile/l10n/generated/app_localizations.dart';

class FileActionDialogs {
  static Future<String?> showTextInputDialog(
    BuildContext context, {
    required String title,
    required String hint,
    String initialValue = '',
    required String actionText,
  }) async {
    final controller = TextEditingController(text: initialValue);
    
    return showDialog<String>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text(title),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
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

  static Future<bool> showConfirmDialog(
    BuildContext context, {
    required String title,
    required String content,
  }) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text(title),
          content: Text(content),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
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
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
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
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
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
}

class FileActionSheet {
  static Future<void> show(BuildContext context, Function(String) onAction, {
    bool isArchive = false,
    bool showShare = false,
    bool showInLocation = false,
    bool openWith = false,
    bool showSetAsHome = false,
  }) {
    final theme = Theme.of(context);
    return showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (ctx) {
        return Container(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(ctx).size.height * 0.8,
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
                      width: 38, height: 4, margin: const EdgeInsets.only(top: 12, bottom: 8),
                      decoration: BoxDecoration(color: theme.colorScheme.onSurface.withOpacity(0.15), borderRadius: BorderRadius.circular(2)),
                    ),
                  ),
                  const SizedBox(height: 8),
                  // 顺序与 _showSingleItemOptions 保持一致：解压、复制、剪切、删除、重命名、在位置中显示、打开方式、压缩、分享、收藏
                  if (isArchive)
                    _buildTile(ctx, theme, icon: Broken.archive, title: L10n.of(ctx).ui_extract, value: 'extract', onAction: onAction),
                  _buildTile(ctx, theme, icon: Broken.document_copy, title: L10n.of(context).ui_copy, value: 'copy', onAction: onAction),
                  _buildTile(ctx, theme, icon: Broken.scissor, title: L10n.of(context).ui_cut, value: 'cut', onAction: onAction),
                  _buildDeleteTile(ctx, theme, onAction: onAction),
                  _buildTile(ctx, theme, icon: Broken.edit, title: L10n.of(context).msgc8ce4b36, value: 'rename', onAction: onAction),
                  if (showInLocation)
                    _buildTile(ctx, theme, icon: Broken.folder_open, title: L10n.of(context).msgcd8264f1, value: 'show_in_location', onAction: onAction),
                  if (openWith)
                    _buildTile(ctx, theme, icon: Broken.eye, title: L10n.of(context).msg2a4cfb07, value: 'open_with', onAction: onAction),
                  _buildTile(ctx, theme, icon: Broken.box_add, title: L10n.of(context).ui_compress, value: 'archive', onAction: onAction),
                  if (showShare)
                    _buildTile(ctx, theme, icon: Icons.share_outlined, title: L10n.of(context).ui_share, value: 'share', onAction: onAction),
                  _buildTile(ctx, theme, icon: Broken.folder_favorite, title: L10n.of(ctx).ui_favorite, value: 'favorite', onAction: onAction),
                  if (showSetAsHome)
                    _buildTile(ctx, theme, icon: Broken.home_2, title: L10n.of(ctx).ui_set_as_home, value: 'set_as_home', onAction: onAction),
                  const SizedBox(height: 8),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  static Widget _buildTile(BuildContext ctx, ThemeData theme, {required IconData icon, required String title, required String value, required Function(String) onAction}) {
    return ListTile(
      leading: Icon(icon, size: 22),
      title: Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
      onTap: () { Navigator.pop(ctx); onAction(value); },
    );
  }

  static Widget _buildDeleteTile(BuildContext ctx, ThemeData theme, {required Function(String) onAction}) {
    return ListTile(
      leading: const Icon(Broken.trash, size: 22, color: Colors.redAccent),
      title: Text(L10n.of(ctx).ui_delete, style: const TextStyle(fontWeight: FontWeight.w600, color: Colors.redAccent)),
      onTap: () { Navigator.pop(ctx); onAction('delete'); },
    );
  }
}
