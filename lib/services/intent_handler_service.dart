import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:zenfile/l10n/generated/app_localizations.dart';
import '../providers/file_manager_provider.dart';

class IntentHandlerService {
  static const MethodChannel _channel = MethodChannel('com.sequl.zenfile/root_shizuku');

  /// 收起首页之上的页面，露出首页（定位 / 打开前先把界面清干净）。
  ///
  /// 必须用 `rootNavigator: true`：调用方给的 context 若是**根 Navigator 自己**
  /// 的 context，非 root 的 `Navigator.of` 会取不到 NavigatorState（release 下
  /// 返回 null），`popUntil` 直接空指针 —— 处理链断在这里，就会出现「压缩包
  /// 已加载进浏览页、界面却还停在分类页」。
  static void _popToHome(BuildContext context) {
    Navigator.of(
      context,
      rootNavigator: true,
    ).popUntil((route) => route.isFirst);
  }

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
  ///
  /// [rawPath] 为外部分享的**原始 URI**（content:// 或直接的文件路径）。
  /// 路径决策（与原生 resolveContentUri 配合）：
  ///  · 解析到可读真实路径 ⇒ 不复制，直接用（普通目录「打开 / 打开所在位置」
  ///    都指向原位置）；
  ///  · 解析到真实路径但不可读（受限目录，典型 Android/data —— FUSE 对
  ///    MANAGE_EXTERNAL_STORAGE 同样拦截）⇒「所在位置」仍定位原目录
  ///    （浏览层有自己的受限目录通道）；「打开」才复制进 cache 后打开；
  ///  · 解析不到（WhatsApp 等私有 provider）⇒ 复制进 cache，禁用「所在位置」。
  static Future<void> handleIncomingIntent(BuildContext context, String rawPath) async {
    if (rawPath.isEmpty) return;

    String targetPath = rawPath;
    bool isCache = false;
    // 真实路径存在但当前不可读（受限目录）。仅对 content:// 解析结果有意义。
    bool restricted = false;
    // 受限目录分享的原始 URI：「打开」按需复制时要用。
    String? sourceUri;

    if (rawPath.startsWith('file://')) {
      // file:// URI（ES 等文件管理器常用）：还原成真实路径即可，不复制。
      // 不还原的话后面 `File(path).existsSync()` 恒 false，压缩包进不了
      // 浏览页的 zip:// 虚拟视图，普通文件也会走成「找不到文件」。
      final decoded = Uri.tryParse(rawPath)?.toFilePath() ?? '';
      if (decoded.isNotEmpty) targetPath = decoded;
    } else if (rawPath.startsWith('content://')) {
      sourceUri = rawPath;
      try {
        final result = await _channel.invokeMethod('resolveContentUri', {'uri': rawPath});
        if (result != null && result['success'] == true) {
          final path = result['path'] as String;
          isCache = result['isCache'] as bool? ?? true;
          restricted = result['restricted'] as bool? ?? false;
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
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text(L10n.of(context).e7(e))));
        }
        return;
      } catch (e) {
        debugPrint('Error resolving content URI: $e');
        if (context.mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text(L10n.of(context).e7(e))));
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

    // 选择「打开文件所在位置」：跳回首页并切到浏览页，定位并居中高亮该文件。
    // 受限目录（restricted）也允许：浏览层对 Android/data 等有自己的访问通道，
    // 只要解析到了真实路径就定位过去；只有复制进 cache 的（无原位置）才禁用。
    if (choice == 'location' && canLocate) {
      final lastSlash = targetPath.lastIndexOf('/');
      final parentPath = lastSlash > 0 ? targetPath.substring(0, lastSlash) : targetPath;
      provider.setPendingBrowseNavigation(parentPath, [targetPath]);
      provider.setNavigateToBrowseTab(true);
      _popToHome(context);
      return;
    }

    // 选择「打开」（或不可定位时退化为直接打开）。
    // 受限目录：FUSE 连 MANAGE_EXTERNAL_STORAGE 都拦，直接读会失败 ——
    // 先复制进 cache 再打开（登记写回映射，编辑后能存回原 URI）。
    if (restricted && sourceUri != null) {
      try {
        final result = await _channel.invokeMethod('copyContentUriToCache', {
          'uri': sourceUri,
        });
        if (result != null && result['success'] == true) {
          final cachePath = result['path'] as String;
          _resolvedUris[cachePath] = sourceUri;
          targetPath = cachePath;
        }
      } on PlatformException catch (e) {
        debugPrint('Error copying restricted file to cache: $e');
        if (!context.mounted) return;
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(L10n.of(context).e7(e))));
        return;
      }
    }

    if (!context.mounted) return;
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
