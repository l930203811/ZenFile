import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:zenfile/l10n/generated/app_localizations.dart';
import '../providers/file_manager_provider.dart';

class IntentHandlerService {
  static const MethodChannel _channel = MethodChannel('com.sequl.zenfile/root_shizuku');

  // Registry to map resolved local cache paths back to their original content:// URIs
  static final Map<String, String> _resolvedUris = {};

  /// Checks if a cache path was resolved from a content URI.
  static bool isIncomingCacheFile(String cachePath) {
    return _resolvedUris.containsKey(cachePath);
  }

  /// Gets the original content URI associated with a cache path, if any.
  static String? getOriginalUri(String cachePath) {
    return _resolvedUris[cachePath];
  }

  /// Resolves an incoming intent path (handling content:// URIs) and opens the file.
  static Future<void> handleIncomingIntent(BuildContext context, String rawPath) async {
    if (rawPath.isEmpty) return;

    String targetPath = rawPath;
    bool isCache = false;

    if (rawPath.startsWith('content://')) {
      try {
        final result = await _channel.invokeMethod('resolveContentUri', {'uri': rawPath});
        if (result != null && result['success'] == true) {
          final path = result['path'] as String;
          isCache = result['isCache'] as bool? ?? true;
          if (isCache) {
            // 仅当复制到应用私有缓存时才登记，便于后续写回原 content URI
            _resolvedUris[path] = rawPath;
          }
          targetPath = path;
        }
      } on PlatformException catch (e) {
        debugPrint('Error resolving content URI: $e');
        if (!context.mounted) return;
        final l10n = L10n.of(context);
        if (e.code == 'NO_PERMISSION') {
          await showDialog<void>(
            context: context,
            barrierDismissible: false,
            builder: (ctx) => AlertDialog(
              title: Text(l10n.share_permission_title),
              content: Text(l10n.share_permission_message),
              actions: <Widget>[
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(),
                  child: Text(l10n.ui_confirm),
                ),
              ],
            ),
          );
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('读取共享文件出错：$e')),
          );
        }
        return;
      } catch (e) {
        debugPrint('Error resolving content URI: $e');
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('读取共享文件出错：$e')),
          );
        }
        return;
      }
    }

    if (!context.mounted) return;
    final provider = context.read<FileManagerProvider>();

    // 仅当解析到文件原始真实路径时才允许「打开文件所在位置」；
    // 复制到缓存的文件（如 WhatsApp 等私有 content provider）无用户可访问的原始位置，禁用该项
    final canLocate = !isCache;

    final choice = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        final l10n = L10n.of(ctx);
        return AlertDialog(
          title: Text(l10n.open_with_title),
          actionsAlignment: MainAxisAlignment.start,
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(ctx).pop('open'),
              child: Text(l10n.open_file),
            ),
            TextButton(
              onPressed: canLocate ? () => Navigator.of(ctx).pop('location') : null,
              child: Text(l10n.open_in_location),
            ),
            TextButton(
              onPressed: () => Navigator.of(ctx).pop('cancel'),
              child: Text(l10n.ui_cancel),
            ),
          ],
        );
      },
    );

    // 以下在 await 之后使用 context，先做 mounted 守卫以消除跨 gap 警告
    if (!context.mounted) return;
    if (choice == null || choice == 'cancel') return;

    // 选择「打开文件所在位置」：跳回首页并切到浏览页，定位并居中高亮该文件
    if (choice == 'location' && canLocate) {
      final lastSlash = targetPath.lastIndexOf('/');
      final parentPath = lastSlash > 0 ? targetPath.substring(0, lastSlash) : targetPath;
      provider.setPendingBrowseNavigation(parentPath, [targetPath]);
      provider.setNavigateToBrowseTab(true);
      Navigator.of(context).popUntil((route) => route.isFirst);
      return;
    }

    // 选择「打开」（或不可定位时退化为直接打开）
    if (provider.hasNativeViewer(targetPath)) {
      await provider.openFileNatively(context, targetPath);
    } else {
      await provider.openFile(context, targetPath);
    }
  }

  /// Writes edited file contents back to the original content URI.
  static Future<bool> saveContentUriFile(String cachePath, String content) async {
    final originalUri = _resolvedUris[cachePath];
    if (originalUri == null) return false;

    try {
      final bool? success = await _channel.invokeMethod<bool>('writeContentUri', {
        'uri': originalUri,
        'content': content,
      });
      return success ?? false;
    } catch (e) {
      debugPrint('Error saving to content URI: $e');
      return false;
    }
  }
}
