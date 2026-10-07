import 'dart:io';
import 'package:auto_size_text/auto_size_text.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import '../../core/navigator_key.dart';
import '../../providers/file_manager_provider.dart';
import '../../providers/media_provider.dart';
import '../../core/icon_fonts/broken_icons.dart';
import '../../core/utils.dart';
import '../../services/pin_service.dart';
import 'file_action_dialogs.dart';
import 'cut_destination_sheet.dart';
import 'create_archive_dialog.dart';
import 'batch_rename_dialog.dart';
import '../../services/folder_share_service.dart';
import 'package:zenfile/l10n/generated/app_localizations.dart';
import 'bulk_crypt_actions.dart';
import 'action_bar_button.dart';
import '../../services/file_hash_service.dart';
import '../../services/file_birth_time_service.dart';

class SelectionActionBar extends StatelessWidget {
  final FileManagerProvider provider;

  const SelectionActionBar({super.key, required this.provider});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final selectedCount = provider.selectedPaths.length;
    final hasClipboard = provider.hasClipboard;

    return Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.08),
            blurRadius: 16,
            offset: const Offset(0, -4),
          ),
        ],
      ),
      child: SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Selected count indicator
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 6),
              decoration: BoxDecoration(
                color: theme.colorScheme.primary.withValues(alpha: 0.06),
                border: Border(
                  bottom: BorderSide(
                    color: theme.colorScheme.primary.withValues(alpha: 0.1),
                  ),
                ),
              ),
              child: Center(
                child: Text(
                  L10n.of(context).selectedcount(provider.selectedPaths.length),
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: theme.colorScheme.primary,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: ActionBarButton(
                    icon: Broken.document_copy,
                    label: L10n.of(context).ui_copy,
                    hideLabel: provider.hideActionText,
                    onTap: () {
                      provider.copySelected();
                      // ScaffoldMessenger.of(context).showSnackBar(
                      //   SnackBar(content: Text('Copied $selectedCount item(s)')),
                      // );
                    },
                  ),
                ),
                Expanded(
                  child: ActionBarButton(
                    icon: Broken.scissor,
                    label: L10n.of(context).ui_cut,
                    hideLabel: provider.hideActionText,
                    onTap: () {
                      handleCutWithDestination(
                        context,
                        provider,
                        paths: provider.selectedPaths.toList(),
                        defaultCut: () async => provider.cutSelected(),
                      );
                      // ScaffoldMessenger.of(context).showSnackBar(
                      //   SnackBar(content: Text('Cut $selectedCount item(s)')),
                      // );
                    },
                  ),
                ),
                Expanded(
                  child: ActionBarButton(
                    icon: Broken.edit,
                    label: L10n.of(context).msgc8ce4b36,
                    hideLabel: provider.hideActionText,
                    onTap: () async {
                      if (selectedCount == 1) {
                        final path = provider.selectedPaths.first;
                        final currentName = p.basename(path);
                        final newName =
                            await FileActionDialogs.showRenameDialog(
                              context,
                              currentName: currentName,
                              title: L10n.of(context).msgc8ce4b36,
                              hint: L10n.of(context).msgf139c5cf,
                              actionText: L10n.of(context).msgc8ce4b36,
                            );
                        if (newName != null && newName.isNotEmpty) {
                          await provider.renameFile(path, newName);
                          provider.clearSelection();
                        }
                      } else if (selectedCount > 1) {
                        await BatchRenameDialog.show(context, provider);
                      }
                    },
                  ),
                ),
                Expanded(
                  child: ActionBarButton(
                    icon: Broken.tick_square,
                    label: L10n.of(context).ui_select_all,
                    hideLabel: provider.hideActionText,
                    onTap: () {
                      provider.selectAll();
                    },
                  ),
                ),
                Expanded(
                  child: ActionBarButton(
                    icon: Broken.trash,
                    label: L10n.of(context).ui_delete,
                    color: Colors.redAccent,
                    hideLabel: provider.hideActionText,
                    onTap: () async {
                      final confirm =
                          await FileActionDialogs.showDeleteConfirmDialog(
                            context,
                            title: L10n.of(context).msgcd0b9aca,
                            content: L10n.of(
                              context,
                            ).selectedcount2(provider.selectedPaths.length),
                          );
                      if (confirm) {
                        try {
                          await provider.deleteSelected();
                        } catch (e) {
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text(
                                  L10n.of(context).msg_delete_failed(e),
                                ),
                                behavior: SnackBarBehavior.floating,
                              ),
                            );
                          }
                        }
                      }
                    },
                  ),
                ),
                Expanded(
                  child: PopupMenuButton<String>(
                    icon: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Broken.more,
                          size: 24,
                          color: theme.colorScheme.primary,
                        ),
                        if (!provider.hideActionText) ...[
                          const SizedBox(height: 4),
                          AutoSizeText(
                            L10n.of(context).ui_more,
                            minFontSize: 8,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w500,
                              color: theme.colorScheme.primary,
                            ),
                          ),
                        ],
                      ],
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                    position: PopupMenuPosition.under,
                    elevation: 8,
                    onSelected: (action) async {
                      if (action == 'encrypt') {
                        if (provider.activeTab.isCryptRemote) {
                          // 远程加密目录：加密＝选择本地文件加密后上传
                          await BulkCryptActions.encryptUploadRemoteCrypt(
                            context,
                            provider,
                          );
                        } else if (provider.activeTab.isRemote) {
                          // 普通远程目录：加密＝原地加密（下载→加密→回写→删原明文）
                          await BulkCryptActions.encryptRemoteInPlace(
                            context,
                            provider,
                            provider.selectedPaths.toList(),
                          );
                        } else {
                          await BulkCryptActions.encryptSelected(
                            context,
                            provider,
                          );
                        }
                      } else if (action == 'encrypt_upload') {
                        await BulkCryptActions.encryptUploadRemoteCrypt(
                          context,
                          provider,
                        );
                      } else if (action == 'decrypt') {
                        if (provider.activeTab.isCryptRemote ||
                            provider.activeTab.isRemote) {
                          // 远程：解密＝解密到本地 + 明文回写替换远程原密文
                          await BulkCryptActions.decryptRemoteInPlace(
                            context,
                            provider,
                            provider.selectedPaths.toList(),
                          );
                          provider.clearSelection();
                        } else {
                          await BulkCryptActions.decryptSelected(
                            context,
                            provider,
                          );
                        }
                      } else if (action == 'extract') {
                        final selectedPaths = provider.selectedPaths.toList();
                        final archivePath = selectedPaths.firstWhere(
                          (p) => FileUtils.isArchive(p),
                          orElse: () => '',
                        );
                        if (archivePath.isNotEmpty) {
                          await provider.extractArchiveDirectly(
                            context,
                            archivePath,
                          );
                        }
                      } else if (action == 'archive') {
                        // 缓存选中路径，避免弹窗异步过程中 selectedPaths 被其他操作修改
                        final selectedPaths = provider.selectedPaths.toList();
                        final initialName = selectedPaths.length == 1
                            ? p.basename(selectedPaths.first)
                            : (p.basename(provider.currentPath).isEmpty
                                  ? 'archive'
                                  : p.basename(provider.currentPath));
                        final res = await CreateArchiveDialog.show(
                          context,
                          initialName: initialName,
                          isMultiSelection: selectedCount > 1,
                        );
                        if (res != null) {
                          // 用根 navigator 的 context 而非 widget context：
                          // createArchive 内部会 selectedPaths.clear() 退出选择模式，
                          // 导致 SelectionActionBar unmount、widget context 失效。
                          // 用 navigatorKey.currentContext 确保 startCompression 显示的
                          // 进度弹窗和后续刷新不依赖已 unmount 的 widget。
                          final rootContext =
                              navigatorKey.currentContext ?? context;
                          await provider.createArchive(
                            archiveName: res.archiveName,
                            format: res.format,
                            compressionLevel: res.compressionLevel,
                            password: res.password,
                            splitSizeMB: res.splitSizeMB,
                            deleteSource: res.deleteSource,
                            separateArchives: res.separateArchives,
                            targetPaths: selectedPaths,
                            context: rootContext,
                          );
                        }
                      } else if (action == 'paste') {
                        await provider.pasteFile(context);
                        provider.clearSelection();
                      } else if (action == 'share') {
                        final selectedPaths = provider.selectedPaths.toList();
                        await FolderShareService.sharePaths(
                          context,
                          selectedPaths,
                        );
                      } else if (action == 'favorite') {
                        final selectedPaths = provider.selectedPaths.toList();
                        if (selectedPaths.isEmpty) return;
                        final group =
                            await FileActionDialogs.showFavoriteGroupPicker(
                              context,
                              existingGroups: provider.getFavoriteGroups(),
                            );
                        if (group == null) return;
                        final isRemote = provider.currIsRemote;
                        final connectionId =
                            provider.activeTab.remoteConnection?.id;
                        for (final path in selectedPaths) {
                          final name = p.basename(path);
                          final isDir = isRemote
                              ? true
                              : Directory(path).existsSync();
                          provider.addFavorite(
                            path,
                            name,
                            isDir,
                            isRemote: isRemote,
                            connectionId: connectionId,
                            group: group.isEmpty ? null : group,
                          );
                        }
                        provider.clearSelection();
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text(
                                L10n.of(context).msg_favorited(
                                  p.basename(selectedPaths.first),
                                ),
                              ),
                              behavior: SnackBarBehavior.floating,
                              duration: const Duration(seconds: 2),
                            ),
                          );
                        }
                      } else if (action == 'open_with') {
                        final selectedPaths = provider.selectedPaths.toList();
                        if (selectedPaths.length == 1) {
                          await provider.showOpenWithSheet(
                            context,
                            selectedPaths.first,
                          );
                        } else {
                          for (final path in selectedPaths) {
                            await provider.openWithSystemChooser(path);
                          }
                        }
                        provider.clearSelection();
                      } else if (action == 'pin_to_top') {
                        final selected = provider.selectedPaths.toList();
                        final allPinned = selected.every(
                          (p) => PinService.isPinned(p),
                        );
                        for (final path in selected) {
                          if (allPinned) {
                            await PinService.unpin(path);
                          } else {
                            await PinService.pin(path);
                          }
                        }
                        provider.refreshDirectoryView();
                        provider.clearSelection();
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text(
                                allPinned
                                    ? L10n.of(context).msga9b87614
                                    : L10n.of(context).ui_pinned_selected,
                              ),
                              behavior: SnackBarBehavior.floating,
                            ),
                          );
                        }
                      } else if (action == 'set_as_home') {
                        final selectedPaths = provider.selectedPaths.toList();
                        if (selectedPaths.isNotEmpty) {
                          await provider.setAsHomeDirectory(
                            selectedPaths.first,
                          );
                        }
                        provider.clearSelection();
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text(L10n.of(context).ui_set_as_home),
                              behavior: SnackBarBehavior.floating,
                              duration: const Duration(seconds: 2),
                            ),
                          );
                        }
                      } else if (action == 'properties') {
                        _showPropertiesModal(context, provider);
                      }
                    },
                    itemBuilder: (context) {
                      final selected = provider.selectedPaths.toList();
                      final allPinned =
                          selected.isNotEmpty &&
                          selected.every((p) => PinService.isPinned(p));
                      final hasArchive = selected.any(
                        (p) => FileUtils.isArchive(p),
                      );
                      final selectedModels = provider.currentFiles
                          .where((f) => selected.contains(f.path))
                          .toList();
                      final anyEncrypted = selectedModels.any(
                        (m) => m.isEncrypted,
                      );
                      final anyPlain = selectedModels.any(
                        (m) => !m.isEncrypted,
                      );
                      final hasSingleDirectory =
                          selected.length == 1 &&
                          selectedModels.isNotEmpty &&
                          selectedModels.first.isDirectory;
                      final isCryptRemote = provider.activeTab.isCryptRemote;
                      return [
                        // 远程加密目录：额外提供「加密上传」
                        if (isCryptRemote)
                          PopupMenuItem(
                            value: 'encrypt_upload',
                            child: Row(
                              children: [
                                Icon(
                                  Icons.upload_outlined,
                                  size: 20,
                                  color: Theme.of(context).colorScheme.primary,
                                ),
                                const SizedBox(width: 12),
                                Text(
                                  L10n.of(context).crypt_remote_upload,
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        // 明文条目一律提供「加密」（含加密目录里的明文条目 →
                        // 原地加密）。旧逻辑 `!isCryptRemote` 会在加密目录里藏掉入口。
                        if (anyPlain)
                          PopupMenuItem(
                            value: 'encrypt',
                            child: Row(
                              children: [
                                const Icon(Broken.lock, size: 20),
                                const SizedBox(width: 12),
                                Text(
                                  L10n.of(context).vault_action_encrypt,
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        if (anyEncrypted)
                          PopupMenuItem(
                            value: 'decrypt',
                            child: Row(
                              children: [
                                const Icon(Broken.unlock, size: 20),
                                const SizedBox(width: 12),
                                Text(
                                  // 远程「解密」＝解密到本地 + 回写替换远程原密文
                                  L10n.of(context).crypt_action_decrypt,
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        if (hasArchive)
                          PopupMenuItem(
                            value: 'extract',
                            child: Row(
                              children: [
                                const Icon(Broken.box, size: 20),
                                const SizedBox(width: 12),
                                Text(
                                  L10n.of(context).ui_extract,
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        PopupMenuItem(
                          value: 'archive',
                          child: Row(
                            children: [
                              const Icon(Broken.box_add, size: 20),
                              const SizedBox(width: 12),
                              Text(
                                L10n.of(context).ui_compress,
                                style: const TextStyle(
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                            ],
                          ),
                        ),
                        if (hasClipboard)
                          PopupMenuItem(
                            value: 'paste',
                            child: Row(
                              children: [
                                const Icon(Broken.clipboard, size: 20),
                                const SizedBox(width: 12),
                                Text(
                                  L10n.of(context).msg419be096,
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        PopupMenuItem(
                          value: 'share',
                          child: Row(
                            children: [
                              const Icon(Icons.share_outlined, size: 20),
                              const SizedBox(width: 12),
                              Text(
                                L10n.of(context).ui_share,
                                style: const TextStyle(
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                            ],
                          ),
                        ),
                        PopupMenuItem(
                          value: 'favorite',
                          child: Row(
                            children: [
                              const Icon(Broken.folder_favorite, size: 20),
                              const SizedBox(width: 12),
                              Text(
                                L10n.of(context).ui_favorite,
                                style: const TextStyle(
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                            ],
                          ),
                        ),
                        PopupMenuItem(
                          value: 'pin_to_top',
                          child: Row(
                            children: [
                              Icon(
                                allPinned
                                    ? Icons.push_pin_rounded
                                    : Icons.push_pin_outlined,
                                size: 20,
                                color: allPinned ? Colors.orange : null,
                              ),
                              const SizedBox(width: 12),
                              Text(
                                allPinned
                                    ? L10n.of(context).ui_unpin
                                    : L10n.of(context).ui_pin_to_top,
                                style: const TextStyle(
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                            ],
                          ),
                        ),
                        if (hasSingleDirectory)
                          PopupMenuItem(
                            value: 'set_as_home',
                            child: Row(
                              children: [
                                const Icon(Broken.home_2, size: 20),
                                const SizedBox(width: 12),
                                Text(
                                  L10n.of(context).ui_set_as_home,
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        PopupMenuItem(
                          value: 'open_with',
                          child: Row(
                            children: [
                              const Icon(Broken.export, size: 20),
                              const SizedBox(width: 12),
                              Text(
                                L10n.of(context).msg2a4cfb07,
                                style: const TextStyle(
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                            ],
                          ),
                        ),
                        PopupMenuItem(
                          value: 'properties',
                          child: Row(
                            children: [
                              const Icon(Broken.info_circle, size: 20),
                              const SizedBox(width: 12),
                              Text(
                                L10n.of(context).ui_properties,
                                style: const TextStyle(
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ];
                    },
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  void _showPropertiesModal(
    BuildContext context,
    FileManagerProvider provider,
  ) {
    final selectedPaths = provider.selectedPaths.toList();
    if (selectedPaths.isEmpty) return;

    showDialog(
      context: context,
      builder: (context) => PropertiesModalDialog(
        selectedPaths: selectedPaths,
        provider: provider,
      ),
    );
  }
}

class PropertiesModalDialog extends StatefulWidget {
  final List<String> selectedPaths;
  final FileManagerProvider provider;

  const PropertiesModalDialog({
    super.key,
    required this.selectedPaths,
    required this.provider,
  });

  @override
  State<PropertiesModalDialog> createState() => PropertiesModalDialogState();
}

class PropertiesModalDialogState extends State<PropertiesModalDialog> {
  bool _isLoading = true;
  int _totalBytes = 0;
  int _folderCount = 0;
  int _fileCount = 0;
  DateTime? _lastModified;
  DateTime? _creationTime;
  String _permissions = '';
  String _mimeType = '';
  bool _isHashing = false;
  double? _hashProgress;
  String? _hashMd5;
  String? _hashSha1;
  String? _hashSha256;
  String? _hashError;

  /// 是否显示「校验和」标签页：仅单个本地文件适用（文件夹 / 多选 / 远程不适用）。
  bool _hashApplicable = false;
  bool _hashStarted = false;
  final TextEditingController _verifyController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _hashApplicable = _isHashCandidate();
    _calculateProperties();
  }

  @override
  void dispose() {
    _verifyController.dispose();
    super.dispose();
  }

  /// 能否计算哈希：单个、非远程、且是文件（受限路径回退当前列表条目判断）。
  bool _isHashCandidate() {
    if (widget.selectedPaths.length != 1) return false;
    final path = widget.selectedPaths.first;
    if (path.startsWith('remote://') || path.startsWith('cryptremote://')) {
      return false;
    }
    final type = FileSystemEntity.typeSync(path);
    if (type == FileSystemEntityType.directory) return false;
    if (type == FileSystemEntityType.file) return true;
    for (final f in widget.provider.currentFiles) {
      if (f.path == path) return !f.isDirectory;
    }
    return false;
  }

  Future<void> _calculateProperties() async {
    int bytes = 0;
    int folders = 0;
    int files = 0;
    // 统一通过全局 navigator 取 L10n；做空安全，避免在异步段抛未捕获异常
    // 导致对话框卡在加载态（表现为「点击无响应」）。
    final navCtx = navigatorKey.currentContext;
    L10n? l10n() => navCtx == null ? null : L10n.of(navCtx);

    try {
      final currentFilesMap = {
        for (var f in widget.provider.currentFiles) f.path: f,
      };

      for (final path in widget.selectedPaths) {
        try {
          final type = FileSystemEntity.typeSync(path);
          if (type == FileSystemEntityType.directory) {
            folders++;
            final dir = Directory(path);
            if (dir.existsSync()) {
              if (widget.selectedPaths.length == 1) {
                final stat = dir.statSync();
                _lastModified = stat.modified;
                final canRead = (stat.mode & 0x100) != 0;
                final canWrite = (stat.mode & 0x80) != 0;
                final l = l10n();
                if (l != null) {
                  if (canRead && canWrite) {
                    _permissions = '${l.prop_read} / ${l.prop_write}';
                  } else if (canRead) {
                    _permissions = l.prop_read;
                  } else if (canWrite) {
                    _permissions = l.prop_write;
                  }
                }
              }
              try {
                await for (final entity in dir.list(
                  recursive: true,
                  followLinks: false,
                )) {
                  if (entity is File) {
                    files++;
                    bytes += await entity.length();
                  } else if (entity is Directory) {
                    folders++;
                  }
                }
              } catch (_) {}
            }
          } else if (type == FileSystemEntityType.file) {
            files++;
            final f = File(path);
            if (f.existsSync()) {
              bytes += f.lengthSync();
              if (widget.selectedPaths.length == 1) {
                final stat = f.statSync();
                _lastModified = stat.modified;
                final canRead = (stat.mode & 0x100) != 0;
                final canWrite = (stat.mode & 0x80) != 0;
                final l = l10n();
                if (l != null) {
                  if (canRead && canWrite) {
                    _permissions = '${l.prop_read} / ${l.prop_write}';
                  } else if (canRead) {
                    _permissions = l.prop_read;
                  } else if (canWrite) {
                    _permissions = l.prop_write;
                  }
                }
              }
            }
          } else {
            // Fallback：受限路径（Shizuku）走当前列表条目；远程路径改走 MediaProvider
            // 的远程大小缓存，避免分类页进入属性页时远程文件大小显示为 0。
            final item = currentFilesMap[path];
            if (item != null) {
              if (item.isDirectory) {
                folders++;
              } else {
                files++;
                bytes += item.size;
              }
            } else if (MediaProvider.isRemotePath(path)) {
              files++;
              bytes += MediaProvider.getCachedRemoteFileSize(path);
              if (widget.selectedPaths.length == 1) {
                _lastModified = MediaProvider.getCachedRemoteFileModified(path);
              }
            }
          }
        } catch (_) {
          final item = currentFilesMap[path];
          if (item != null) {
            if (item.isDirectory) {
              folders++;
            } else {
              files++;
              bytes += item.size;
            }
          }
        }
      }

      // 创建时间：仅在本地文件 / 文件夹（已成功 stat 出 _lastModified）时解析。
      // 文件系统 birth time（statx）→ MediaStore DATE_ADDED 逐级回退；
      // 都取不到则保持 null、不显示该行（详见 FileBirthTimeService）。
      if (widget.selectedPaths.length == 1 && _lastModified != null) {
        _creationTime = await _fetchCreationTime(
          widget.selectedPaths.first,
          _lastModified!.millisecondsSinceEpoch,
        );
      }

      if (widget.selectedPaths.length == 1) {
        final pStr = widget.selectedPaths.first;
        final ext = pStr.contains('.')
            ? pStr.substring(pStr.lastIndexOf('.')).toLowerCase()
            : '';
        final l = l10n();
        if (l != null) {
          if (folders > 0) {
            _mimeType = l.prop_folder_directory;
          } else {
            _mimeType = ext.isNotEmpty ? '${l.prop_file} ($ext)' : l.prop_file;
          }
        }
      }
    } catch (_) {
      // 忽略计算过程中的异常，保证对话框一定能渲染出内容
    } finally {
      if (mounted) {
        setState(() {
          _totalBytes = bytes;
          _folderCount = folders;
          _fileCount = files;
          _isLoading = false;
        });
      }
    }
  }

  /// 创建时间：优先文件系统真实 birth time（libc statx，**文件夹同样可取得**），
  /// 取不到再回退原生 MediaStore DATE_ADDED（只索引文件，文件夹必然取不到）。
  /// 两路都拿不到时返回 null，UI 隐藏该行 —— 宁可没有，也不拿修改时间冒充（issue #39）。
  Future<DateTime?> _fetchCreationTime(String path, int modifiedMillis) async {
    return FileBirthTimeService.resolve(
      path,
      knownModified: modifiedMillis > 0
          ? DateTime.fromMillisecondsSinceEpoch(modifiedMillis)
          : null,
    );
  }

  /// 用户切到「校验和」标签页时触发一次计算（重复切换不重算）。
  void _ensureHashStarted() {
    if (_hashStarted) return;
    _hashStarted = true;
    _computeHash();
  }

  /// 流式计算本地文件的 MD5 / SHA-1 / SHA-256，并上报进度。
  /// 文件夹 / 远程路径不会进入该标签页，故此处无需额外判路径类型。
  Future<void> _computeHash() async {
    final path = widget.selectedPaths.first;
    if (mounted) {
      setState(() {
        _isHashing = true;
        _hashError = null;
        _hashProgress = null;
      });
    }
    try {
      final res = await FileHashService.compute(
        path,
        onProgress: (processed, total) {
          if (!mounted || total <= 0) return;
          setState(() => _hashProgress = processed / total);
        },
      );
      if (mounted) {
        setState(() {
          _hashMd5 = res.md5;
          _hashSha1 = res.sha1;
          _hashSha256 = res.sha256;
          _hashProgress = 1;
          _isHashing = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _hashError = e.toString();
          _isHashing = false;
        });
      }
    }
  }

  /// 从剪贴板粘贴待比对的官方哈希值。
  Future<void> _pasteVerifyHash() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text?.trim();
    if (text == null || text.isEmpty) return;
    _verifyController.text = text;
    _verifyController.selection = TextSelection.collapsed(offset: text.length);
    if (mounted) setState(() {});
  }

  /// 自动识别粘贴内容的算法（按长度）并与本地结果比对，返回结论横幅。
  /// 长度 32 → MD5，40 → SHA-1，64 → SHA-256；比对大小写不敏感、忽略空白与分隔符。
  Widget? _buildVerifyResult(ThemeData theme, L10n l10n) {
    if (_verifyController.text.trim().isEmpty) return null;
    if (_hashError != null) return null;
    if (_hashMd5 == null || _hashSha1 == null || _hashSha256 == null) return null;

    final input = _verifyController.text
        .replaceAll(RegExp(r'[\s\-:]'), '')
        .toLowerCase();
    String? expected;
    if (input.length == 32) {
      expected = _hashMd5;
    } else if (input.length == 40) {
      expected = _hashSha1;
    } else if (input.length == 64) {
      expected = _hashSha256;
    }
    if (expected == null) {
      return _verifyBanner(
        theme,
        Broken.info_circle,
        theme.colorScheme.outline,
        l10n.prop_verify_unknown,
      );
    }
    final ok = expected == input;
    return _verifyBanner(
      theme,
      ok ? Broken.tick_circle : Broken.close_circle,
      ok ? Colors.green : theme.colorScheme.error,
      ok ? l10n.prop_verify_match : l10n.prop_verify_mismatch,
    );
  }

  Widget _verifyBanner(
    ThemeData theme,
    IconData icon,
    Color color,
    String text,
  ) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Row(
        children: [
          Icon(icon, size: 18, color: color),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w500,
                color: color,
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = L10n.of(context);
    final count = widget.selectedPaths.length;
    final isSingle = count == 1;
    final nameDisplay = isSingle
        ? p.basename(widget.selectedPaths.first)
        : l10n.prop_items_selected(count);

    if (_isLoading) {
      return Scaffold(
        appBar: _buildAppBar(theme, l10n),
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const CircularProgressIndicator(),
              const SizedBox(height: 16),
              Text(l10n.msg3be9abab, style: const TextStyle(color: Colors.grey)),
            ],
          ),
        ),
      );
    }

    final propertiesTab = _buildPropertiesTab(theme, l10n, isSingle, nameDisplay);

    return DefaultTabController(
      length: _hashApplicable ? 2 : 1,
      child: Scaffold(
        appBar: _buildAppBar(
          theme,
          l10n,
          bottom: _hashApplicable
              ? TabBar(
                  // 切到「校验和」时才真正读盘计算，避免只看属性也扫一遍大文件。
                  onTap: (index) {
                    if (index == 1) _ensureHashStarted();
                  },
                  tabs: [
                    Tab(text: l10n.ui_properties),
                    Tab(text: l10n.prop_tab_checksum),
                  ],
                )
              : null,
        ),
        body: _hashApplicable
            ? TabBarView(
                children: [propertiesTab, _buildChecksumTab(theme, l10n)],
              )
            : propertiesTab,
      ),
    );
  }

  /// 全屏属性页顶栏：左侧关闭按钮 + 标题，可选底部标签栏。
  PreferredSizeWidget _buildAppBar(
    ThemeData theme,
    L10n l10n, {
    PreferredSizeWidget? bottom,
  }) {
    return AppBar(
      leading: IconButton(
        icon: const Icon(Broken.close_circle),
        onPressed: () => Navigator.pop(context),
      ),
      title: Row(
        children: [
          Icon(Broken.info_circle, color: theme.colorScheme.primary, size: 24),
          const SizedBox(width: 10),
          Text(
            l10n.ui_properties,
            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
          ),
        ],
      ),
      bottom: bottom,
    );
  }

  /// 「属性」标签页：名称、路径、大小、时间、类型、权限；多选时改为汇总 + 文件清单。
  Widget _buildPropertiesTab(
    ThemeData theme,
    L10n l10n,
    bool isSingle,
    String nameDisplay,
  ) {
    final count = widget.selectedPaths.length;
    final isFolderType = _mimeType == l10n.prop_folder_directory;
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (isSingle) ...[
            _CopyablePropertyRow(label: l10n.ui_name, value: nameDisplay),
            _CopyablePropertyRow(
              label: l10n.ui_path,
              value: widget.selectedPaths.first,
            ),
            _CopyablePropertyRow(
              label: l10n.ui_size,
              value:
                  '${FileUtils.formatBytes(_totalBytes, 2)} ($_totalBytes ${l10n.prop_bytes})',
            ),
            if (isFolderType)
              _CopyablePropertyRow(
                label: l10n.ui_contains,
                value: l10n.prop_contains_format(_folderCount - 1, _fileCount),
              ),
            if (_lastModified != null)
              _CopyablePropertyRow(
                label: l10n.msg1303e638,
                value: FileUtils.formatDate(_lastModified!),
              ),
            if (_creationTime != null)
              _CopyablePropertyRow(
                label: l10n.prop_created,
                value: FileUtils.formatDate(_creationTime!),
              ),
            if (_mimeType.isNotEmpty)
              _CopyablePropertyRow(label: l10n.ui_type, value: _mimeType),
            if (_permissions.isNotEmpty)
              _CopyablePropertyRow(
                label: l10n.ui_permissions,
                value: _permissions,
              ),
          ] else ...[
            _CopyablePropertyRow(
              label: l10n.msg880a18f3,
              value: l10n.prop_items_summary(count, _folderCount, _fileCount),
            ),
            _CopyablePropertyRow(
              label: l10n.msgea9ecb93,
              value:
                  '${FileUtils.formatBytes(_totalBytes, 2)} ($_totalBytes ${l10n.prop_bytes})',
            ),
            const SizedBox(height: 12),
            Text(
              l10n.msg7704aa2c,
              style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
            ),
            const SizedBox(height: 8),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 180),
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceVariant.withValues(alpha: 0.5),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: widget.selectedPaths
                        .map(
                          (path) => Padding(
                            padding: const EdgeInsets.only(bottom: 6.0),
                            child: SelectableText(
                              p.basename(path),
                              style: const TextStyle(
                                fontSize: 13,
                                fontFamily: 'monospace',
                              ),
                            ),
                          ),
                        )
                        .toList(),
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// 「校验和」标签页：即时展示 MD5 / SHA-1 / SHA-256，并支持粘贴官方哈希自动比对。
  /// 上半部（哈希值）可滚动、下半部（粘贴比对）固定贴底，保证哈希再长也不会把
  /// 粘贴框与比对结论挤出屏幕。
  Widget _buildChecksumTab(ThemeData theme, L10n l10n) {
    final verifyResult = _buildVerifyResult(theme, l10n);
    final mutedColor = theme.colorScheme.onSurface.withValues(alpha: 0.6);
    final hashesReady =
        _hashMd5 != null && _hashSha1 != null && _hashSha256 != null;

    return Column(
      children: [
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  l10n.prop_checksum_note,
                  style: TextStyle(fontSize: 12, color: mutedColor),
                ),
                const SizedBox(height: 16),
                if (_isHashing)
                  Row(
                    children: [
                      SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          value: _hashProgress,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          l10n.prop_hashing,
                          style: const TextStyle(fontSize: 13),
                        ),
                      ),
                      if (_hashProgress != null)
                        Text(
                          '${(_hashProgress! * 100).round()}%',
                          style: TextStyle(fontSize: 12, color: mutedColor),
                        ),
                    ],
                  )
                else if (_hashError != null)
                  _CopyablePropertyRow(
                    label: l10n.prop_hash_failed,
                    value: _hashError!,
                  )
                else if (hashesReady) ...[
                  _buildHashRow(theme, l10n, l10n.prop_md5, _hashMd5!),
                  _buildHashRow(theme, l10n, l10n.prop_sha1, _hashSha1!),
                  _buildHashRow(theme, l10n, l10n.prop_sha256, _hashSha256!),
                ],
              ],
            ),
          ),
        ),
        const Divider(height: 1),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: _verifyController,
                autocorrect: false,
                enableSuggestions: false,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(
                  isDense: true,
                  hintText: l10n.prop_verify_hint,
                  hintStyle: const TextStyle(fontSize: 13),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  suffixIcon: IconButton(
                    tooltip: l10n.ui_paste,
                    icon: const Icon(Broken.document_copy, size: 18),
                    onPressed: _pasteVerifyHash,
                  ),
                ),
              ),
              if (verifyResult != null) ...[
                const SizedBox(height: 12),
                verifyResult,
              ],
            ],
          ),
        ),
      ],
    );
  }

  /// 单个哈希值展示块：算法名与复制按钮同一行，哈希值独占一行等宽字体，
  /// 避免算法名被窄列挤压换行（此前 SHA-256 会被拆成「SHA-25 / 6」）。
  Widget _buildHashRow(
    ThemeData theme,
    L10n l10n,
    String label,
    String value,
  ) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                label,
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 13,
                  color: theme.colorScheme.primary,
                ),
              ),
              const Spacer(),
              InkWell(
                onTap: () {
                  Clipboard.setData(ClipboardData(text: value));
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text(l10n.label1(label)),
                      duration: const Duration(seconds: 1),
                    ),
                  );
                },
                borderRadius: BorderRadius.circular(6),
                child: Padding(
                  padding: const EdgeInsets.all(4),
                  child: Icon(
                    Broken.document_copy,
                    size: 16,
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 2),
          SelectableText(
            value,
            style: TextStyle(
              fontFamily: 'monospace',
              fontSize: 12.5,
              height: 1.4,
              color: theme.colorScheme.onSurface.withValues(alpha: 0.9),
            ),
          ),
        ],
      ),
    );
  }
}

class _CopyablePropertyRow extends StatelessWidget {
  final String label;
  final String value;

  const _CopyablePropertyRow({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    if (value.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.only(bottom: 8.0),
      child: InkWell(
        onTap: () {
          Clipboard.setData(ClipboardData(text: value));
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(L10n.of(context).label1(label)),
              duration: const Duration(seconds: 1),
            ),
          );
        },
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6.0, horizontal: 8.0),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                flex: 3,
                child: Text(
                  label,
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 13,
                    color: theme.colorScheme.primary,
                  ),
                ),
              ),
              Expanded(
                flex: 7,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Text(
                        value,
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                        ),
                        softWrap: true,
                      ),
                    ),
                    const SizedBox(width: 4),
                    Icon(
                      Broken.document_copy,
                      size: 14,
                      color: theme.colorScheme.onSurface.withValues(alpha: 0.4),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
