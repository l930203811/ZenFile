import 'package:flutter/material.dart';
import '../../core/icon_fonts/broken_icons.dart';

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
              child: const Text('取消'),
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
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              style: FilledButton.styleFrom(
                backgroundColor: Colors.red,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              child: const Text('删除'),
            ),
          ],
        );
      },
    );
    return result ?? false;
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
              child: const Text('确定'),
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
  }) {
    final theme = Theme.of(context);
    return showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (ctx) {
        return Container(
          decoration: BoxDecoration(
            color: theme.colorScheme.surface,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
          ),
          child: SafeArea(
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
                if (showInLocation)
                  _buildTile(ctx, theme, icon: Broken.folder_open, title: '在位置中显示', value: 'show_in_location', onAction: onAction),
                if (showShare)
                  _buildTile(ctx, theme, icon: Icons.share_outlined, title: '分享', value: 'share', onAction: onAction),
                if (isArchive)
                  _buildTile(ctx, theme, icon: Broken.archive, title: '解压', value: 'extract', onAction: onAction),
                _buildTile(ctx, theme, icon: Broken.box_add, title: '压缩', value: 'archive', onAction: onAction),
                _buildTile(ctx, theme, icon: Broken.document_copy, title: '复制', value: 'copy', onAction: onAction),
                _buildTile(ctx, theme, icon: Broken.scissor, title: '剪切', value: 'cut', onAction: onAction),
                _buildTile(ctx, theme, icon: Broken.edit, title: '重命名', value: 'rename', onAction: onAction),
                _buildDeleteTile(ctx, theme, onAction: onAction),
                const SizedBox(height: 8),
              ],
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
      title: const Text('删除', style: TextStyle(fontWeight: FontWeight.w600, color: Colors.redAccent)),
      onTap: () { Navigator.pop(ctx); onAction('delete'); },
    );
  }
}
