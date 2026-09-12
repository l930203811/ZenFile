import 'dart:io';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:path/path.dart' as p;
import 'package:mime/mime.dart';
import 'package:open_filex/open_filex.dart';
import '../../core/icon_fonts/broken_icons.dart';
import '../../core/utils.dart';
import '../../providers/file_manager_provider.dart';
import '../../services/vault_service.dart';
import 'package:path_provider/path_provider.dart';
import 'image_viewer_screen.dart';
import 'video_player/video_player_screen.dart';
import 'audio_player/audio_player_screen.dart';
import 'text_editor_screen.dart';
import 'internal_file_picker_screen.dart';
import 'crypt_mount_edit_screen.dart';
import 'crypt_settings_screen.dart';
import 'vault_help_screen.dart';
import 'vault_session_unlock_dialog.dart';
import '../../services/crypt/crypt.dart';
import 'archive_viewer_screen.dart';
import 'remote_crypt_explorer_screen.dart';
import '../widgets/archive_type_icon.dart';
import '../widgets/progress_overlay.dart';
import '../widgets/remote_path_picker.dart';
import '../widgets/outlined_add_button.dart';
import 'package:zenfile/l10n/generated/app_localizations.dart';

class VaultExplorerScreen extends StatefulWidget {
  /// 不再需要解锁密码作为参数：加解密一律使用「加密设置」中的主密码，
  /// 解锁密码（门禁）与加密密钥已完全解耦。
  const VaultExplorerScreen({super.key});

  @override
  State<VaultExplorerScreen> createState() => _VaultExplorerScreenState();
}

class _VaultExplorerScreenState extends State<VaultExplorerScreen> {
  List<VaultFileRecord> _records = [];
  List<VaultFileRecord> _filteredRecords = [];
  bool _isLoading = true;
  String _searchQuery = '';
  final TextEditingController _searchController = TextEditingController();

  // 折叠区展开状态（备份恢复，默认收缩）
  bool _backupExpanded = false;

  // 新版原地加密文件列表（挂载点扫描得到）
  List<CryptFileEntry> _inPlaceFiles = [];
  bool _isLoadingInPlace = true;

  // 远程加密文件列表（密文在后端，客户端解密枚举，只读）
  List<CryptFileEntry> _remoteCryptFiles = [];
  bool _isLoadingRemote = true;

  // 导入清单（持久化）：未加密条目进「未加密文件」，已加密条目进「原地加密文件」
  List<VaultImportEntry> _importEntries = [];

  // 已加密导入条目的解密后文件名缓存（key=物理路径，value=解密名）
  Map<String, String> _importDecryptedNames = {};

  // 三区域展开状态（默认展开，避免进入保险箱看不到内容）
  bool _inplaceExpanded = true;
  bool _remoteCryptExpanded = true;
  bool _sandboxExpanded = true;

  // 需求2：两个列表的多选状态
  /// 选中的沙盒加密条目物理路径（scrambledPath）
  final Set<String> _selectedSandbox = {};

  /// 选中的原地加密条目物理路径（_InPlaceItem.path）
  final Set<String> _selectedInPlace = {};

  /// 是否处于多选模式（有任意选中项即视为进入多选）
  bool get _selectionMode =>
      _selectedSandbox.isNotEmpty || _selectedInPlace.isNotEmpty;

  /// 已选总数
  int get _selectionCount => _selectedSandbox.length + _selectedInPlace.length;

  /// 长按进入多选并选中该项
  void _enterSelection({String? sandboxPath, String? inplacePath}) {
    setState(() {
      if (sandboxPath != null) _selectedSandbox.add(sandboxPath);
      if (inplacePath != null) _selectedInPlace.add(inplacePath);
    });
  }

  void _toggleSandboxSelection(String path) {
    setState(() {
      if (!_selectedSandbox.remove(path)) _selectedSandbox.add(path);
    });
  }

  void _toggleInPlaceSelection(String path) {
    setState(() {
      if (!_selectedInPlace.remove(path)) _selectedInPlace.add(path);
    });
  }

  /// 退出多选并清空选择
  void _exitSelection() {
    if (!_selectionMode) return;
    setState(() {
      _selectedSandbox.clear();
      _selectedInPlace.clear();
    });
  }

  /// 全选两个列表中的全部条目
  void _selectAllVisible() {
    setState(() {
      for (final r in _filteredRecords) {
        _selectedSandbox.add(r.scrambledPath);
      }
      for (final it in _inplaceItems) {
        _selectedInPlace.add(it.path);
      }
    });
  }

  /// 导入清单中检测为已加密的条目
  List<VaultImportEntry> get _encryptedImports =>
      _importEntries.where((e) => e.encrypted).toList();

  /// 缓存的浏览页 Provider 引用。
  ///
  /// ⚠️ `deactivate()` 阶段 context 已开始失效，直接 `context.read` 可能抛异常，
  /// 而刷新逻辑外层有 try/catch 兜底 → 异常被静默吞掉 → 浏览页不刷新（仍显示密文名）。
  /// 因此在 `didChangeDependencies` 里先抓一份引用。
  FileManagerProvider? _fileManager;

  /// 是否已订阅浏览页 Provider 的加密挂载点版本号（避免重复订阅）。
  bool _revisionAttached = false;

  /// 浏览页加密挂载点变化（加密/解密/粘贴密文后）时自动重扫原地加密列表。
  void _onCryptRevision() {
    if (mounted) _loadInPlaceEncryptedFiles();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final fm = context.read<FileManagerProvider>();
    _fileManager = fm;
    // 订阅一次加密挂载点版本号：浏览页加/解密或粘贴密文后，保险箱列表自动刷新。
    if (!_revisionAttached) {
      _revisionAttached = true;
      fm.cryptMountRevision.addListener(_onCryptRevision);
    }
  }

  @override
  void activate() {
    super.activate();
    // 从浏览页返回保险箱（复制/移动 OpenList 密文后）重新扫描原地加密列表，
    // 让新拷入的密文即时出现在保险箱「原地加密」区域，无需重启应用。
    _loadInPlaceEncryptedFiles();
  }

  @override
  void initState() {
    super.initState();
    _loadVaultData();
    _loadInPlaceEncryptedFiles();
    _loadImportEntries();
    _searchController.addListener(_onSearchChanged);
  }

  @override
  void deactivate() {
    // 离开保险箱时同步刷新浏览页：导入/原地加解密会改变磁盘上的文件名，
    // 而浏览页缓存的列表不会自动重载，导致退出后仍显示密文名（需重启应用才更新）。
    _refreshBrowser();
    super.deactivate();
  }

  /// 刷新浏览页（重新加载加密挂载点 + 重载当前目录）
  ///
  /// 用 `showLoading: false` 避免闪一下全屏 loading。
  Future<void> _refreshBrowser() async {
    try {
      final fm = _fileManager;
      if (fm == null) return;
      // 刷新挂载点 + 重新枚举所有已打开的本地标签页，让浏览页即时显示解密后的文件，
      // 无需整机重启（此前「导入/原地加解密后浏览页仍是密文」即因挂载点仅在重启时重建）。
      await fm.refreshAllBrowserTabs();
    } catch (_) {}
  }

  /// 加载导入清单，并尝试把已加密条目的文件名解密为真实名称用于显示。
  Future<void> _loadImportEntries() async {
    try {
      final entries = await VaultImportStore.load();
      final decryptedNames = await _decryptImportNames(entries);
      if (!mounted) return;
      setState(() {
        _importEntries = entries;
        _importDecryptedNames = decryptedNames;
      });
    } catch (_) {}
  }

  /// 对导入清单中标记为已加密的条目尝试解密文件名。
  ///
  /// 优先使用匹配路径的已持久化挂载点配置，否则回退到「加密设置」中
  /// 保存的主密码/盐/编码/后缀。失败则保留原加密名。
  Future<Map<String, String>> _decryptImportNames(List<VaultImportEntry> entries) async {
    final result = <String, String>{};
    try {
      final mounts = await _loadMountsWithMasterPassword();
      final cryptCache = <RcloneCryptConfig, RcloneCrypt>{};

      for (final entry in entries.where((e) => e.encrypted)) {
        try {
          CryptMountPoint? matchedMount;
          for (final m in mounts) {
            if (m.containsPath(entry.path)) {
              matchedMount = m;
              break;
            }
          }
          // 无匹配挂载点时按路径解析（绑定优先，回退默认档案）
          final config = matchedMount?.config ??
              await VaultCryptService.instance.getMasterConfig(path: entry.path);
          if (config == null) continue;

          final crypt = cryptCache.putIfAbsent(config, () => RcloneCrypt(config: config));
          final name = p.basename(entry.path);
          result[entry.path] = crypt.decryptFileName(name);
        } catch (_) {
          // 解密失败：不缓存，后续显示原加密名
        }
      }
    } catch (_) {}
    return result;
  }

  /// 加载已持久化的加密挂载点，并用「加密设置」的主密码补齐空密码。
  ///
  /// ⚠️ 持久化不落盘密码，必须补主密码；绝不可用保险箱**解锁密码**——
  /// 门禁密码与加密密钥已完全解耦（改解锁密码不影响任何加密文件）。
  Future<List<CryptMountPoint>> _loadMountsWithMasterPassword() async {
    final master = await VaultCryptService.instance.readMasterPassword();
    final mounts = await CryptMountService.loadMountPoints();
    if (master == null) return mounts;

    final result = <CryptMountPoint>[];
    for (final m in mounts) {
      if (m.config.password.isEmpty) {
        try {
          // 按挂载点自身路径解析：它可能绑定了非默认档案
          final cfg = await VaultCryptService.instance.getMasterConfig(
            path: m.physicalPath,
          );
          result.add(m.copyWith(password: cfg?.password ?? master));
          continue;
        } catch (e) {
          // 单个挂载点重建失败不应拖垮整体流程，保留原配置继续
          debugPrint('[vault] 挂载点重建失败 ${m.physicalPath}: $e');
        }
      }
      result.add(m);
    }
    return result;
  }

  /// 为 [path] 解析一个用于加解密的 crypt 挂载点：
  /// 1. 优先复用已持久化的「原地加密」挂载点（含其安全存储中的密码）；
  /// 2. 否则回退到「加密设置」里配置的主密码/盐（crypt_last_password），
  ///    并在 [path] 的父目录按此凭据创建一个挂载点（按需持久化，
  ///    但存储根目录除外 —— 根挂载点必须只存在于内存，见下）；
  /// 3. 若用户尚未在加密设置中配置主密码，返回 null（调用方应引导去加密设置页）。
  Future<CryptMountPoint?> _resolveCryptMountForPath(String path) async {
    final mounts = await _loadMountsWithMasterPassword();
    for (final m in mounts) {
      // 跳过沙盒挂载点与「整机根目录」级别的挂载点：后者 containsPath 命中全盘，
      // 会把整个存储当成加密目录（历史事故），历史遗留配置一律不予采用。
      if (m.isSandboxMode || CryptMountService.isStorageRootPath(m.physicalPath)) {
        continue;
      }
      if (m.containsPath(path)) return m;
    }
    // 按路径解析（绑定优先），该目录可能用的是非默认档案
    final master = await VaultCryptService.instance.getMasterConfig(path: path);
    if (master == null) return null;
    final parentDir = p.dirname(path);
    final mount = CryptMountPoint(
      physicalPath: parentDir,
      config: master,
      name: p.basename(parentDir),
      isSandboxMode: false,
    );
    // 存储根目录严禁持久化为挂载点（同上）；本次加解密用返回的临时挂载点即可，
    // 后续的浏览显示/打开由 file_manager_provider 按需探测重建。
    if (!CryptMountService.isStorageRootPath(parentDir)) {
      await CryptMountService.addMountPoint(mount);
    }
    return mount;
  }

  /// 加载新版原地加密的文件/文件夹列表
  Future<void> _loadInPlaceEncryptedFiles() async {
    setState(() => _isLoadingInPlace = true);
    try {
      final mounts = await _loadMountsWithMasterPassword();

      // 待扫描目录（与浏览页探测来源保持完全一致）：
      // ① 所有持久化的非沙盒挂载点；
      // ② 「原地加密目录登记表」里记录的目录（含存储根目录，允许建临时挂载点）；
      // ③ 导入清单中已加密条目的所在父目录；
      // ④ 主存储根目录（按每份档案各建一个根挂载点扫描后合并）。
      //
      // ②③④是必需的：原地加密可能发生在「未持久化挂载点」的目录（尤其是存储
      // 根目录），或用户把 OpenList 加密文件复制到某个目录后——这些密文没有持久
      // 化挂载点可依托，只能在这里显式补扫一次，否则保险箱列表看不到它们。
      final targets = <CryptMountPoint>[];
      final seen = <String>{};
      for (final m in mounts) {
        if (m.isSandboxMode) continue; // 只显示原地加密的
        if (seen.add(p.normalize(m.physicalPath))) targets.add(m);
      }

      // ② 登记表里的已知加密目录（用户确实在那里加密过，允许含存储根目录）
      try {
        final recorded = await CryptMountService.loadEncryptedDirs();
        for (final dir in recorded) {
          if (dir.isEmpty) continue;
          if (!await Directory(dir).exists()) continue;
          if (seen.contains(p.normalize(dir))) continue;
          final cfg = await VaultCryptService.instance.getMasterConfig(path: dir);
          if (cfg == null) continue;
          seen.add(p.normalize(dir));
          targets.add(CryptMountPoint(physicalPath: dir, config: cfg, name: p.basename(dir)));
        }
      } catch (e) {
        debugPrint('[vault] 扫描登记加密目录失败: $e');
      }

      // ③ 导入清单中已加密条目的所在父目录（用户从别处拷入的 OpenList 密文）
      try {
        final imports = await VaultImportStore.load();
        for (final e in imports.where((x) => x.encrypted)) {
          final dir = p.dirname(e.path);
          if (dir.isEmpty) continue;
          if (!await Directory(dir).exists()) continue;
          if (seen.contains(p.normalize(dir))) continue;
          final cfg = await VaultCryptService.instance.getMasterConfig(path: dir);
          if (cfg == null) continue;
          seen.add(p.normalize(dir));
          targets.add(CryptMountPoint(physicalPath: dir, config: cfg, name: p.basename(dir)));
        }
      } catch (e) {
        debugPrint('[vault] 扫描导入加密目录失败: $e');
      }

      // ④ 主存储根目录：按每份档案各建一个根挂载点扫描后合并
      final primary = Directory('/storage/emulated/0').existsSync()
          ? '/storage/emulated/0'
          : (Directory('/sdcard').existsSync() ? '/sdcard' : null);
      if (primary != null && !seen.contains(p.normalize(primary))) {
        final profiles = await CryptProfileService.instance.loadProfiles();
        if (profiles.isEmpty) {
          final master = await VaultCryptService.instance.getMasterConfig();
          if (master != null) {
            seen.add(p.normalize(primary));
            targets.add(
              CryptMountPoint(
                physicalPath: primary,
                config: master,
                name: p.basename(primary),
              ),
            );
          }
        } else {
          for (final profile in profiles) {
            seen.add(p.normalize(primary));
            targets.add(
              CryptMountPoint(
                physicalPath: primary,
                config: profile.toConfig(),
                name: p.basename(primary),
              ),
            );
          }
        }
      }

      final List<CryptFileEntry> allFiles = [];
      for (final mount in targets) {
        try {
          final lister = CryptDirectoryLister(mount);
          final entries = await lister.listDirectory(
            mount.physicalPath,
            onlyEncrypted: true, // 只显示真实已加密的文件/目录
          );
          allFiles.addAll(entries);
        } catch (e) {
          // 单个目录扫描失败不应拖垮整页：记录日志并继续，绝不静默吞掉。
          debugPrint('[vault] 扫描挂载点 ${mount.physicalPath} 失败: $e');
        }
      }

      // ⑤ 关联的远程加密目录（密文在后端，客户端解密枚举，只读）→ 独立列表
      List<CryptFileEntry> remoteEntries = [];
      try {
        remoteEntries = await context
            .read<FileManagerProvider>()
            .listAllRemoteCryptDirs(onlyEncrypted: true);
      } catch (e) {
        debugPrint('[vault] 扫描远程加密目录失败: $e');
      }

      if (mounted) {
        setState(() {
          _inPlaceFiles = allFiles;
          _remoteCryptFiles = remoteEntries;
          _isLoadingInPlace = false;
          _isLoadingRemote = false;
        });
      }
    } catch (e) {
      debugPrint('[vault] 加载原地加密文件失败: $e');
      if (mounted) {
        setState(() => _isLoadingInPlace = false);
      }
    }
  }

  /// 「关联远程加密目录」：选择远程服务器上的 rclone crypt 目录并登记。
  ///
  /// 记录使用**当前默认加密档案**（若有）；解密时按档案 id 取回密码。
  /// 需要已配置主密码/档案（否则无处取密钥）。
  Future<void> _linkRemoteCryptDir() async {
    final l10n = L10n.of(context);
    final master = await VaultCryptService.instance.getMasterConfig();
    if (master == null) {
      _showNeedPasswordDialog(l10n);
      return;
    }
    final picked = await showRemotePathPicker(context);
    if (picked == null || !picked.startsWith('remote://')) return;
    final rest = picked.substring('remote://'.length);
    final idx = rest.indexOf('|');
    if (idx < 0) return;
    final connId = rest.substring(0, idx);
    final serverPath = rest.substring(idx + 1);
    if (connId.isEmpty || serverPath.isEmpty) return;

    final active = await CryptProfileService.instance.activeProfile();
    await CryptMountService.addRemoteEncryptedDir(
      connId,
      serverPath,
      profileId: active?.id,
    );
    if (!mounted) return;
    await context.read<FileManagerProvider>().refreshCryptMountPoints();
    if (!mounted) return;
    await _loadInPlaceEncryptedFiles();
    if (mounted) _toast(l10n.vault_link_remote_crypt_success);
  }

  /// 取消关联一条远程加密目录记录（该条目所属的关联根）
  Future<void> _unlinkRemoteCrypt(String virtualPath) async {
    if (!virtualPath.startsWith('cryptremote://')) return;
    final rest = virtualPath.substring('cryptremote://'.length);
    final idx = rest.indexOf('|');
    if (idx < 0) return;
    final connId = rest.substring(0, idx);
    final serverPath = rest.substring(idx + 1);

    final records = await CryptMountService.loadRemoteEncryptedDirs();
    String? matchServer;
    for (final r in records) {
      if (r.connId == connId &&
          (serverPath == r.serverPath ||
              serverPath.startsWith('${r.serverPath}/'))) {
        matchServer = r.serverPath;
        break;
      }
    }
    if (matchServer == null) return;

    await CryptMountService.removeRemoteEncryptedDir(connId, matchServer);
    if (!mounted) return;
    await context.read<FileManagerProvider>().refreshCryptMountPoints();
    if (!mounted) return;
    await _loadInPlaceEncryptedFiles();
  }


  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    );
  }

  Future<void> _exportBackup() async {
    final l10n = L10n.of(context);
    // 导出到公开目录 /storage/emulated/0/ZenFile/Backups/safe，
    // 避免落到 Android/data 应用私有目录导致无权限设备无法找回/导入。
    const preferred = '/storage/emulated/0/ZenFile/Backups/safe';

    // 1) 先提示导出路径，由用户确认/取消。
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text(l10n.vault_export_backup),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(l10n.vault_export_backup_confirm),
            const SizedBox(height: 10),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceVariant.withOpacity(0.4),
                borderRadius: BorderRadius.circular(12),
              ),
              child: SelectableText(
                preferred,
                style: const TextStyle(fontSize: 13, fontFamily: 'monospace'),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(l10n.ui_cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(l10n.ui_confirm),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    // 2) 执行导出（带加载指示）。
    if (!mounted) return;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => ProgressOverlay(message: l10n.vault_exporting),
    );
    String? exportedPath;
    try {
      exportedPath = await VaultCryptService.instance.exportBackup(preferred);
    } catch (_) {
      // 兜底：公开目录不可写时退回应用私有外部目录，保证导出功能不彻底失效
      try {
        final fallback = (await getExternalStorageDirectory())?.path ??
            (await getApplicationDocumentsDirectory()).path;
        exportedPath = await VaultCryptService.instance.exportBackup(fallback);
      } catch (e) {
        if (mounted) Navigator.pop(context);
        _toast(l10n.vault_export_failed);
        return;
      }
    }
    if (mounted) Navigator.pop(context);
    _toast('${l10n.vault_backup_exported}: $exportedPath');

    // 3) 导出完成后询问是否打开文件所在位置（应用内文件浏览器定位并高亮）。
    final open = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text(l10n.vault_backup_exported),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SelectableText(
              exportedPath!,
              style: const TextStyle(fontSize: 13, fontFamily: 'monospace'),
            ),
            const SizedBox(height: 12),
            Text(l10n.vault_open_backup_location),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(l10n.ui_cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(l10n.ui_confirm),
          ),
        ],
      ),
    );
    if (open == true && mounted) {
      final fm = context.read<FileManagerProvider>();
      // 返回首页并切到「浏览」页：先置位 navigateToBrowseTab，由首页
      // ValueListenableBuilder 在 pop 回首页后完成顶层 Tab 切换；再 popUntil
      // 一路弹回首页（关闭保险箱/工具箱等上层路由），最后定位并高亮备份文件所在文件夹。
      // 与图片查看器「在位置中显示」、全局搜索跳转行为一致，解决从抽屉/分类页进入时
      // 弹回后仍停留在分类页或卡在工具箱页的问题。
      fm.setNavigateToBrowseTab(true);
      Navigator.of(context).popUntil((route) => route.isFirst);
      await fm.showFileInLocation(exportedPath);
    }
  }

  Future<void> _importBackup() async {
    final l10n = L10n.of(context);
    // 优先定位到默认导出备份目录，但允许在应用内浏览器自行浏览到其它路径选择备份文件。
    String startPath = '/storage/emulated/0/ZenFile/Backups/safe';
    final safeDir = Directory(startPath);
    if (!await safeDir.exists()) {
      final backupsDir = Directory('/storage/emulated/0/ZenFile/Backups');
      if (await backupsDir.exists()) {
        startPath = backupsDir.path;
      } else {
        // 默认目录尚不存在：尝试创建以便定位；失败则回退到内部存储根。
        try {
          await safeDir.create(recursive: true);
        } catch (_) {
          startPath = '/storage/emulated/0';
        }
      }
    }
    final selected = await InternalFilePickerScreen.show(
      context,
      rootPath: '/storage/emulated/0',
      initialPath: startPath,
    );
    if (selected == null || selected.isEmpty) return;
    final path = selected.first;
    if (!path.toLowerCase().endsWith('.zip')) {
      _toast(l10n.vault_import_only_zip);
      return;
    }
    if (!mounted) return;

    // 导入会用备份覆盖当前沙盒与加密配置，先确认
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text(l10n.vault_import_backup),
        content: Text(l10n.vault_import_backup_confirm),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(l10n.ui_cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(l10n.ui_confirm),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    final fm = context.read<FileManagerProvider>();
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => ProgressOverlay(message: l10n.vault_importing_backup),
    );
    try {
      final imported = await VaultCryptService.instance.importBackup(path);
      // 主密码与挂载点已随备份更新 → 重建挂载点后再刷新列表
      await fm.refreshCryptMountPoints();
      await _loadVaultData();
      await _loadInPlaceEncryptedFiles();
      if (mounted) Navigator.pop(context);
      _toast('${l10n.vault_backup_imported}: $imported');
    } catch (e) {
      if (mounted) Navigator.pop(context);
      _toast(l10n.vault_import_failed);
    }
  }

  @override
  void dispose() {
    _fileManager?.cryptMountRevision.removeListener(_onCryptRevision);
    _searchController.dispose();
    super.dispose();
  }

  /// 加载保险箱列表（沙盒加密条目）
  ///
  /// 旧版 V2/V3 自研格式已彻底移除，此处只扫描 rclone crypt 沙盒
  /// （`vault_crypt/` 挂载点）。不再有持久化的记录表 —— 磁盘即事实来源。
  Future<void> _loadVaultData() async {
    setState(() => _isLoading = true);
    try {
      final sandboxRecords = await _loadCryptSandboxRecords();
      if (mounted) {
        setState(() {
          _records = sandboxRecords;
          _filteredRecords = _searchQuery.isEmpty
              ? _records
              : _records
                  .where((r) => r.originalName.toLowerCase().contains(_searchQuery))
                  .toList();
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isLoading = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(L10n.of(context).vault_load_error(e.toString()))),
        );
      }
    }
  }

  /// 扫描 rclone crypt 沙盒目录，把条目适配成 [VaultFileRecord]。
  Future<List<VaultFileRecord>> _loadCryptSandboxRecords() async {
    try {
      final mounts = await _loadMountsWithMasterPassword();
      CryptMountPoint? sandbox;
      for (final m in mounts) {
        if (m.isSandboxMode) {
          sandbox = m;
          break;
        }
      }
      if (sandbox == null) return const <VaultFileRecord>[];

      final lister = CryptDirectoryLister(sandbox);
      final entries = await lister.listDirectory(sandbox.physicalPath);
      // 一次性读取来源映射（沙盒密文名与原始路径无关，恢复位置全靠它）
      final origins = await VaultCryptService.instance.getSandboxOrigins();

      final result = <VaultFileRecord>[];
      for (final e in entries) {
        result.add(
          VaultFileRecord(
            id: 'crypt:${e.physicalPath}',
            originalName: e.name,
            originalPath: origins[e.physicalPath] ?? e.virtualPath,
            scrambledPath: e.physicalPath,
            size: e.size,
            lockedAt: e.modified.toIso8601String(),
            isFolder: e.isDirectory,
          ),
        );
      }
      return result;
    } catch (e) {
      debugPrint('[vault] 加载 crypt 沙盒条目失败: $e');
      return const <VaultFileRecord>[];
    }
  }

  void _onSearchChanged() {
    setState(() {
      _searchQuery = _searchController.text.toLowerCase();
      if (_searchQuery.isEmpty) {
        _filteredRecords = _records;
      } else {
        _filteredRecords = _records
            .where((rec) => rec.originalName.toLowerCase().contains(_searchQuery))
            .toList();
      }
    });
  }

  /// 导入文件/文件夹：先让用户选择加密方式，再执行加密
  ///
  /// - 原地加密：文件夹内「已经是 rclone/OpenList 加密」的文件自动跳过（不重复加密），
  ///   仅加密普通文件；加密后留在原位置（CryptVFS 浏览页即时显示解密名）。
  /// - 沙盒加密：文件移入保险箱私有目录并加密，由「沙盒加密文件」区域接管。
  Future<void> _importFiles({String? presetMethod}) async {
    final l10n = L10n.of(context);
    final fileManager = context.read<FileManagerProvider>();
    final rootPath =
        fileManager.rootPath.isNotEmpty ? fileManager.rootPath : '/storage/emulated/0';
    final selectedPaths =
        await InternalFilePickerScreen.show(context, rootPath: rootPath);
    if (selectedPaths == null || selectedPaths.isEmpty || !mounted) return;

    // 选择加密方式：原地加密 / 沙盒加密（presetMethod 由区域「+」按钮预置，跳过选择弹窗）
    final method = presetMethod ?? await _showImportMethodDialog();
    if (method == null || !mounted) return;

    // 选择加密配置：尚未配置 → 引导去「加密设置」新建，保存后自动继续；
    // 已配置多份 → 弹窗选择，默认选中「默认配置」那一份。
    final profile = await _promptSelectProfile(isSandbox: method == 'sandbox');
    if (profile == null || !mounted) return;

    // 沙盒整体只挂一份密钥：切换会影响沙盒内所有文件，需二次确认后把整份
    // 沙盒绑定到所选配置；原地加密则按路径各自绑定，无需二次确认。
    if (method == 'sandbox') {
      final active = await CryptProfileService.instance.activeProfile();
      if (active?.id != profile.id) {
        final ok = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: Text(l10n.crypt_profile_sandbox_title),
            content: Text(l10n.crypt_profile_sandbox_message),
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
        if (ok != true) return;
        // 切换沙盒密钥：设为默认 + 绑定沙盒目录 + 更新沙盒挂载点配置，
        // 否则新增加密仍会沿用旧挂载点的旧密钥。
        await CryptProfileService.instance.setActive(profile.id);
        final sandboxDir = await VaultCryptService.instance.getSandboxDir();
        await CryptProfileService.instance.bindPath(sandboxDir, profile.id);
        final existingSandbox =
            await VaultCryptService.instance.getSandboxMount();
        if (existingSandbox != null) {
          await CryptMountService.addMountPoint(
            existingSandbox.copyWith(config: profile.toConfig()),
          );
        }
      }
    }

    // await 之前先捕获导航器/提示条，避免跨异步使用 BuildContext
    final navigator = Navigator.of(context);
    final scaffoldMessenger = ScaffoldMessenger.of(context);

    pushProgressRoute(navigator, message: l10n.vault_importing);

    var encryptCount = 0; // 新执行加密的项
    var skipCount = 0; // 已是加密、跳过的项
    var failCount = 0;
    Object? lastError;
    try {
      // 挂载点读取失败不应阻断导入：仅影响「是否已加密」的识别，降级为未加密
      List<CryptMountPoint> mounts = const [];
      try {
        mounts = await _loadMountsWithMasterPassword();
      } catch (e) {
        debugPrint('[vault] 加载加密挂载点失败，降级为未加密识别: $e');
      }

      for (final path in selectedPaths) {
        try {
          final isDir = Directory(path).existsSync();
          final isFile = !isDir && File(path).existsSync();
          if (!isDir && !isFile) {
            failCount++;
            debugPrint('[vault] 导入路径不存在: $path');
            continue;
          }

          if (method == 'sandbox') {
            // 沙盒加密：移入保险箱私有目录并加密
            await VaultCryptService.instance.encryptToSandbox(
              sourcePath: path,
            );
            await VaultImportStore.remove(path);
            encryptCount++;
            continue;
          }

          // 原地加密：先把所选配置绑定到父目录，确保用这份密钥加密、后续浏览/解密也用它
          await CryptProfileService.instance.bindPath(p.dirname(path), profile.id);

          final encrypted = await VaultImportStore.detectEncrypted(path, mounts);
          if (encrypted) {
            // 已是 rclone/OpenList 加密：不重复加密，登记为导入项
            // （用于浏览页即时挂载 + 「原地加密文件」区域显示）
            final stat = isDir
                ? await Directory(path).stat()
                : await File(path).stat();
            await VaultImportStore.upsert(
              VaultImportEntry(
                path: path,
                isDirectory: isDir,
                encrypted: true,
                size: stat.size,
                modifiedMs: stat.modified.millisecondsSinceEpoch,
              ),
            );
            skipCount++;
            continue;
          }

          // 解析/创建原地加密挂载点（含主密码）；无主密码则引导去设置
          final mount = await _resolveCryptMountForPath(path);
          if (mount == null) {
            if (mounted) {
              navigator.pop();
              _showNeedPasswordDialog(l10n);
            }
            return;
          }

          final ops = CryptOperations(mount);
          String newPath;
          if (isDir) {
            // 跳过目录内已有的加密文件，只加密普通文件
            await ops.encryptDirectory(
              path,
              skipEncrypted: true,
              onProgress: (_, __) {},
            );
            final isMountRoot = p.equals(path, mount.physicalPath);
            newPath = isMountRoot
                ? path
                : p.join(
                    p.dirname(path),
                    mount.crypt.encryptDirName(p.basename(path)),
                  );
          } else {
            newPath = await ops.encryptFile(path);
          }

          // 登记为已加密导入项（与挂载点扫描去重，便于浏览页即时挂载）
          final newStat = isDir
              ? await Directory(newPath).stat()
              : await File(newPath).stat();
          await VaultImportStore.upsert(
            VaultImportEntry(
              path: newPath,
              isDirectory: isDir,
              encrypted: true,
              size: newStat.size,
              modifiedMs: newStat.modified.millisecondsSinceEpoch,
            ),
          );
          encryptCount++;
        } catch (e) {
          // 单项失败不影响其余条目
          failCount++;
          lastError = e;
          debugPrint('[vault] 导入条目失败 $path: $e');
        }
      }

      await _loadImportEntries();
      await _loadInPlaceEncryptedFiles();
      await _loadVaultData();
      await _refreshBrowser();

      if (mounted) {
        navigator.pop(); // 关闭进度
        final msg = failCount > 0
            ? l10n.vault_import_partial('$encryptCount', '$skipCount', '$failCount')
            : l10n.vault_import_done('$encryptCount', '$skipCount');
        scaffoldMessenger.showSnackBar(SnackBar(content: Text(msg)));
      }
    } catch (e) {
      debugPrint('[vault] 导入流程异常: $e');
      if (mounted) {
        navigator.pop(); // 关闭进度
        scaffoldMessenger.showSnackBar(
          SnackBar(content: Text(l10n.vault_import_failed_detail('${lastError ?? e}'))),
        );
      }
    }
  }

  /// 导入时弹出加密方式选择（原地加密 / 沙盒加密）
  ///
  /// 返回 'inplace' / 'sandbox' / null（用户取消）
  Future<String?> _showImportMethodDialog() async {
    final theme = Theme.of(context);
    final l10n = L10n.of(context);
    return showModalBottomSheet<String>(
      context: context,
      backgroundColor: theme.colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: theme.colorScheme.onSurface.withOpacity(0.2),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Text(
                l10n.vault_select_encryption_method,
                style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 20),
              _buildEncryptionOptionCard(
                icon: Icons.lock_outline,
                color: Colors.teal,
                title: l10n.vault_inplace_encrypt,
                subtitle: l10n.vault_inplace_encrypt_desc,
                onTap: () => Navigator.pop(context, 'inplace'),
              ),
              const SizedBox(height: 12),
              _buildEncryptionOptionCard(
                icon: Icons.security,
                color: theme.colorScheme.primary,
                title: l10n.vault_sandbox_encrypt,
                subtitle: l10n.vault_sandbox_encrypt_desc,
                onTap: () => Navigator.pop(context, 'sandbox'),
              ),
              const SizedBox(height: 16),
            ],
          ),
        ),
      ),
    );
  }

  /// 提示先去设置加密密码
  void _showNeedPasswordDialog(L10n l10n) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.vault_need_set_password),
        content: Text(l10n.vault_need_set_password_desc),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(l10n.ui_cancel),
          ),
          FilledButton(
            onPressed: () {
              Navigator.pop(ctx);
              Navigator.push(context,
                  MaterialPageRoute(builder: (_) => const CryptMountEditScreen()));
            },
            child: Text(l10n.vault_go_set_password),
          ),
        ],
      ),
    );
  }

  /// 为导入流程选择加密配置档案：
  /// - 尚未配置任何密码 → 提示并跳转「加密设置」新建，保存后自动继续（返回新建的档案）；
  /// - 仅一份 → 直接使用（无需弹窗）；
  /// - 多份 → 弹窗选择，默认选中「默认配置」那一份。
  /// 返回用户最终选定的档案；用户取消或最终仍无配置时返回 null。
  Future<CryptProfile?> _promptSelectProfile({bool isSandbox = false}) async {
    final l10n = L10n.of(context);
    if (!mounted) return null;

    var profiles = await CryptProfileService.instance.loadProfiles();
    if (!mounted) return null;

    // ① 没有任何配置：引导去「加密设置」新建，保存后自动继续
    if (profiles.isEmpty) {
      final go = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(l10n.vault_need_set_password),
          content: Text(l10n.vault_need_set_password_desc),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(l10n.ui_cancel),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(l10n.vault_go_set_password),
            ),
          ],
        ),
      );
      if (go != true || !mounted) return null;
      // 跳转到新建配置页，返回后重新读取（保存即自动选中该配置）
      await Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => const CryptMountEditScreen()),
      );
      if (!mounted) return null;
      profiles = await CryptProfileService.instance.loadProfiles();
      if (profiles.isEmpty) return null; // 用户未保存，放弃导入
    }

    // ② 仅一份：直接使用
    if (profiles.length == 1) return profiles.first;

    // ③ 多份：弹窗选择，默认选中「默认配置」，并提供「确定」按钮确认选中项。
    // 修复：原先默认配置虽预选，但点选其它配置才能「确认」，默认配置只能靠重复点击同一个
    // 已选项（不直观）或关掉弹窗（返回 null 导致导入中止）。现改为点选仅高亮、「确定」才确认，
    // 默认配置因此也能被正常选中并导入。
    final active = await CryptProfileService.instance.activeProfile();
    final initialId = profiles
        .firstWhere((p) => p.id == active?.id, orElse: () => profiles.first)
        .id;
    String? selectedId = initialId;
    final picked = await showModalBottomSheet<CryptProfile>(
      context: context,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSt) => SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 18, 20, 6),
                child: Text(
                  l10n.crypt_profile_select_title,
                  style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                ),
              ),
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: profiles.length,
                  itemBuilder: (context, index) {
                    final pr = profiles[index];
                    return RadioListTile<String>(
                      value: pr.id,
                      groupValue: selectedId,
                      title: Text(pr.name),
                      subtitle: Text(
                        '${pr.filenameEncoding.name}${pr.encryptedSuffix.isEmpty ? '' : ' · ${pr.encryptedSuffix}'}',
                        style: const TextStyle(fontSize: 12),
                      ),
                      onChanged: (v) => setSt(() => selectedId = v),
                    );
                  },
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
                child: Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: () => Navigator.pop(ctx, null),
                        child: Text(l10n.ui_cancel),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: FilledButton(
                        onPressed: () {
                          final sel = profiles.firstWhere(
                            (p) => p.id == selectedId,
                            orElse: () => profiles.first,
                          );
                          Navigator.pop(ctx, sel);
                        },
                        child: Text(l10n.ui_confirm),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
    return picked;
  }

  /// 构建加密选项卡片
  Widget _buildEncryptionOptionCard({
    required IconData icon,
    required Color color,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
  }) {
    final theme = Theme.of(context);
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: color.withOpacity(0.08),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: color.withOpacity(0.2)),
          ),
          child: Row(
            children: [
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: color.withOpacity(0.15),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(icon, color: color, size: 26),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: TextStyle(fontSize: 12, color: theme.colorScheme.onSurface.withOpacity(0.6)),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              Icon(Icons.chevron_right, color: theme.colorScheme.onSurface.withOpacity(0.4)),
            ],
          ),
        ),
      ),
    );
  }

  /// 计算 crypt 沙盒条目的恢复目标路径
  ///
  /// 沙盒密文名与原始路径无关，「恢复到原位置」依赖 [VaultCryptService] 记录的
  /// 来源映射；没有记录（如旧版本写入的文件）时降级到 Download 目录，避免误写到
  /// 沙盒虚拟路径 —— 该路径只存在于 crypt 视图里，磁盘上并不存在。
  Future<String> _resolveCryptRestorePath(VaultFileRecord record) async {
    // await 之前先取 context 相关值，避免跨异步使用 BuildContext
    final fm = context.read<FileManagerProvider>();
    final root = fm.rootPath.isNotEmpty ? fm.rootPath : '/storage/emulated/0';

    final known = await VaultCryptService.instance.getSandboxOrigin(record.scrambledPath);
    if (known != null && known.isNotEmpty) {
      final stillInSandbox = await VaultCryptService.instance.isSandboxEncrypted(known);
      if (!stillInSandbox) return known;
    }
    return p.join(root, 'Download', record.originalName);
  }

  Future<void> _unlockFile(VaultFileRecord record) async {
    // 需求5：解密（恢复到原位置）前先过保险箱会话闸门
    if (!await requireVaultSessionUnlock(context)) return;
    final l10n = L10n.of(context);
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => ProgressOverlay(message: l10n.vault_restoring),
    );

    try {
      // 解密并移回原位置（旧版 V2/V3 已移除，只剩 crypt 沙盒一条通路）
      final originalPath = await _resolveCryptRestorePath(record);
      await VaultCryptService.instance.decryptFromSandbox(
        sandboxPath: record.scrambledPath,
        originalPath: originalPath,
      );
      Navigator.pop(context); // Dismiss loader
      await _loadVaultData();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(L10n.of(context).msg_restored(record.originalName)),
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          ),
        );
      }
    } catch (e) {
      Navigator.pop(context);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(L10n.of(context).msg_restore_failed(e.toString()))),
        );
      }
    }
  }

  Future<void> _deletePermanently(VaultFileRecord record) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(L10n.of(context).msg_permanent_delete),
        content: Text(L10n.of(context).msg_permanent_delete_content(record.originalName)),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(L10n.of(context).ui_cancel),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, true),
              style: TextButton.styleFrom(foregroundColor: Colors.red),
              child: Text(L10n.of(context).msg96d2b75f),
            ),
        ],
      ),
    );

    if (confirm != true) return;

    try {
      // 删除磁盘密文实体 + 清理来源记录（没有持久化记录表，磁盘即事实来源）
      final file = File(record.scrambledPath);
      if (await file.exists()) {
        await file.delete();
      } else {
        final dir = Directory(record.scrambledPath);
        if (await dir.exists()) {
          await dir.delete(recursive: true);
        }
      }
      await VaultCryptService.instance.removeSandboxOrigin(record.scrambledPath);
      await _loadVaultData();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(L10n.of(context).msg_file_deleted)),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(L10n.of(context).msg_delete_failed(e.toString()))),
        );
      }
    }
  }

  Future<void> _previewFile(VaultFileRecord record) async {
    // 需求3/5：临时解密查看前先过保险箱会话闸门
    // （本次启动已解锁则免验证；未解锁 / 重启后需先验证保险箱密码）。
    if (!await requireVaultSessionUnlock(context)) return;
    // 目录要预览需整目录递归解密，成本高且无对应查看器，
    // 引导用户用「恢复」还原到原位置后查看。
    if (record.isFolder) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(L10n.of(context).vault_restore_folder_hint)),
        );
      }
      return;
    }

    final l10n = L10n.of(context);
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => Center(
        child: Card(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const CircularProgressIndicator(),
                const SizedBox(height: 16),
                Text(L10n.of(context).msg_decrypting, style: const TextStyle(fontWeight: FontWeight.bold)),
              ],
            ),
          ),
        ),
      ),
    );

    try {
      // 解密到临时文件用于预览（旧版 V2/V3 已移除，只剩 crypt 通路）
      final tempFile = await VaultCryptService.instance.decryptToTemp(
        encryptedPath: record.scrambledPath,
      );
      Navigator.pop(context); // Dismiss loading dialog

      final path = tempFile.path;

      if (record.isFolder) {
        await Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => ArchiveViewerScreen(archivePath: path),
          ),
        );
      } else {
        final mimeType = lookupMimeType(path) ?? '';

        if (mimeType.startsWith('image/')) {
          await Navigator.push(context, MaterialPageRoute(builder: (_) => ImageViewerScreen(imagePath: path)));
        } else if (mimeType.startsWith('video/')) {
          await Navigator.push(context, MaterialPageRoute(builder: (_) => VideoPlayerScreen(videoPath: path)));
        } else if (mimeType.startsWith('audio/')) {
          await Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => AudioPlayerScreen(
                audioPath: path,
                title: record.originalName,
              ),
            ),
          );
        } else if (FileUtils.isTextOrCode(path)) {
          await Navigator.push(context, MaterialPageRoute(builder: (_) => TextEditorScreen(filePath: path)));
        } else {
          await OpenFilex.open(path);
        }
      }

      // Cleanup temporary file safely
      try {
        if (await tempFile.exists()) {
          await tempFile.delete();
        }
      } catch (_) {}
    } catch (e) {
      Navigator.pop(context); // Dismiss loading dialog
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l10n.vault_decrypt_open_failed(e.toString()))),
        );
      }
    }
  }

  void _showInfoDialog(VaultFileRecord record) {
    showDialog(
      context: context,
      builder: (context) {
        final theme = Theme.of(context);
        return AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          title: Row(
            children: [
              const Icon(Broken.info_circle, color: Colors.blueAccent),
              const SizedBox(width: 8),
              Text(L10n.of(context).msg_security_details, style: const TextStyle(fontWeight: FontWeight.bold)),
            ],
          ),
          content: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                _buildInfoTile(L10n.of(context).msg_original_name, record.originalName, theme),
                _buildInfoTile(L10n.of(context).msg_original_path, record.originalPath, theme),
                _buildInfoTile(L10n.of(context).msg_scrambled_path, record.scrambledPath, theme),
                _buildInfoTile(L10n.of(context).msg_size_label, FileUtils.formatBytes(record.size, 2), theme),
                _buildInfoTile(L10n.of(context).msg_locked_at, record.lockedAt, theme),
                _buildInfoTile(
                  L10n.of(context).msg_protection_mode,
                  L10n.of(context).msg_isolated_move,
                  theme,
                  valueColor: Colors.greenAccent,
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(L10n.of(context).ui_close, style: const TextStyle(fontWeight: FontWeight.bold)),
            ),
          ],
        );
      },
    );
  }

  Widget _buildInfoTile(String label, String value, ThemeData theme, {Color? valueColor}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label.toUpperCase(),
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.bold,
              color: theme.colorScheme.onSurface.withOpacity(0.5),
              letterSpacing: 0.8,
            ),
          ),
          const SizedBox(height: 2),
          SelectableText(
            value,
            style: TextStyle(
              fontSize: 13.5,
              fontWeight: FontWeight.w600,
              color: valueColor ?? theme.colorScheme.onSurface,
            ),
          ),
          const SizedBox(height: 4),
          Divider(color: theme.colorScheme.onSurface.withOpacity(0.08)),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = L10n.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return Scaffold(
      // 需求2：多选时底部弹出操作栏（解密 / 删除 / 全选 / 退出）
      bottomNavigationBar: _selectionMode ? _buildSelectionBar(theme, isDark) : null,
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: isDark
                ? [const Color(0xFF0B0F19), const Color(0xFF111827), const Color(0xFF030712)]
                : [theme.colorScheme.primaryContainer.withOpacity(0.3), theme.colorScheme.surface, theme.colorScheme.surface],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
        ),
        child: SafeArea(
          child: SingleChildScrollView(
            physics: const BouncingScrollPhysics(),
            child: Column(
              children: [
              // Custom Header Bar
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 12.0),
                child: Row(
                  children: [
                    IconButton(
                      icon: const Icon(Broken.arrow_left, size: 26),
                      onPressed: () => Navigator.pop(context),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      L10n.of(context).msgbb590f19,
                      style: theme.textTheme.headlineSmall?.copyWith(
                        fontWeight: FontWeight.bold,
                        letterSpacing: 0.5,
                      ),
                    ),
                    const Spacer(),
                    // 右上角：帮助入口（原「已激活」徽标）
                    TextButton.icon(
                      onPressed: () => Navigator.push(
                        context,
                        MaterialPageRoute(builder: (_) => const VaultHelpScreen()),
                      ),
                      icon: Icon(
                        Broken.info_circle,
                        size: 18,
                        color: theme.colorScheme.onSurface.withOpacity(0.75),
                      ),
                      label: Text(
                        L10n.of(context).vault_help,
                        style: TextStyle(
                          fontWeight: FontWeight.w600,
                          fontSize: 13,
                          color: theme.colorScheme.onSurface.withOpacity(0.85),
                        ),
                      ),
                      style: TextButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                        minimumSize: Size.zero,
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        backgroundColor: theme.colorScheme.onSurface.withOpacity(0.06),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                    ),
                  ],
                ),
              ),

              // 黄色卸载警告（独立区域，不与安全设置/备份恢复同卡）
              _buildSecurityWarningBanner(theme, isDark),

              // 安全设置 + 备份/恢复 折叠分组
              _buildSecuritySettings(theme, isDark),

              // 加密设置入口（原地加密管理）- 样式与安全设置按钮一致
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 6.0),
                child: Container(
                  margin: const EdgeInsets.fromLTRB(0, 2, 0, 2),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: theme.colorScheme.outline.withOpacity(0.18),
                      width: 1,
                    ),
                    color: isDark ? Colors.white.withOpacity(0.02) : Colors.black.withOpacity(0.01),
                  ),
                  child: InkWell(
                    onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const CryptSettingsScreen())),
                    borderRadius: BorderRadius.circular(12),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Flexible(
                            child: Text(
                              // 需求1：按钮标题显示「配置密码」（设置页 AppBar 仍为「加密设置」）
                              L10n.of(context).vault_config_password,
                              textAlign: TextAlign.start,
                              style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          const SizedBox(width: 6),
                          Icon(
                            Icons.chevron_right_rounded,
                            size: 22,
                            color: theme.colorScheme.onSurface.withOpacity(0.6),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),

              // Search Box
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 10.0),
                child: TextField(
                  controller: _searchController,
                  decoration: InputDecoration(
                    hintText: L10n.of(context).ui_search_obfuscated,
                    prefixIcon: const Icon(Broken.search_normal),
                    suffixIcon: _searchController.text.isNotEmpty
                        ? IconButton(
                            icon: const Icon(Icons.clear_rounded),
                            onPressed: () {
                              _searchController.clear();
                              FocusScope.of(context).unfocus();
                            },
                          )
                        : null,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(16),
                      borderSide: BorderSide(color: theme.colorScheme.outline.withOpacity(0.2)),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(16),
                      borderSide: BorderSide(color: theme.colorScheme.outline.withOpacity(0.1)),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(16),
                      borderSide: BorderSide(color: theme.colorScheme.primary, width: 1.5),
                    ),
                    filled: true,
                    fillColor: isDark ? Colors.white.withOpacity(0.02) : Colors.black.withOpacity(0.01),
                    contentPadding: const EdgeInsets.symmetric(vertical: 0),
                  ),
                ),
              ),

              // 区域二：原地加密（挂载点扫描 + 导入的已加密项）
              _buildCollapsibleSection(
                theme: theme,
                isDark: isDark,
                title: l10n.vault_inplace_encrypt,
                icon: Icons.lock_outline,
                color: Colors.teal,
                count: _inplaceItems.length,
                expanded: _inplaceExpanded,
                onToggle: () =>
                    setState(() => _inplaceExpanded = !_inplaceExpanded),
                body: _sectionBody(_isLoadingInPlace, _buildInPlaceFilesList(theme, isDark)),
                trailing: OutlinedAddButton(
                  tooltip: l10n.vault_import_files,
                  onPressed: () => _importFiles(presetMethod: 'inplace'),
                ),
              ),

              // 区域二点五：远程加密（密文在后端，客户端解密枚举，只读）
              _buildCollapsibleSection(
                theme: theme,
                isDark: isDark,
                title: l10n.vault_remote_encrypt,
                icon: Icons.cloud_outlined,
                color: Colors.blueAccent,
                count: _remoteCryptItems.length,
                expanded: _remoteCryptExpanded,
                onToggle: () =>
                    setState(() => _remoteCryptExpanded = !_remoteCryptExpanded),
                body: _sectionBody(_isLoadingRemote, _buildRemoteCryptFilesList(theme, isDark)),
                trailing: OutlinedAddButton(
                  tooltip: l10n.vault_link_remote_crypt,
                  onPressed: _linkRemoteCryptDir,
                ),
              ),

              // 区域三：沙盒加密
              _buildCollapsibleSection(
                theme: theme,
                isDark: isDark,
                title: l10n.vault_sandbox_encrypt,
                icon: Icons.security,
                color: theme.colorScheme.primary,
                count: _filteredRecords.length,
                expanded: _sandboxExpanded,
                onToggle: () =>
                    setState(() => _sandboxExpanded = !_sandboxExpanded),
                body: _sectionBody(_isLoading, _buildFilesList(theme, isDark)),
                trailing: OutlinedAddButton(
                  tooltip: l10n.vault_import_files,
                  onPressed: () => _importFiles(presetMethod: 'sandbox'),
                ),
              ),

              const SizedBox(height: 24),
            ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildSecuritySettings(ThemeData theme, bool isDark) {
    final l10n = L10n.of(context);
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 备份/恢复：可下拉折叠标题（居中展示，默认收缩）
          _buildCollapsibleHeader(
            theme,
            title: l10n.vault_backup_restore,
            expanded: _backupExpanded,
            onTap: () => setState(() => _backupExpanded = !_backupExpanded),
          ),
          // 折叠内容：导出备份 / 导入备份
          _buildCollapsibleBody(
            expanded: _backupExpanded,
            child: Column(
              children: [
                _buildSecurityNavTile(
                  theme,
                  icon: Broken.security_safe,
                  title: l10n.vault_export_backup,
                  subtitle: l10n.vault_export_backup_desc,
                  onTap: _exportBackup,
                ),
                _buildSecurityNavTile(
                  theme,
                  icon: Broken.import,
                  title: l10n.vault_import_backup,
                  subtitle: l10n.vault_import_backup_desc,
                  onTap: _importBackup,
                ),
              ],
            ),
          ),
          const SizedBox(height: 6),
        ],
      ),
    );
  }

  /// 黄色卸载警告：独立卡片区域（不嵌入安全设置/备份恢复卡片），⚠️ 纯展示
  Widget _buildSecurityWarningBanner(ThemeData theme, bool isDark) {
    final l10n = L10n.of(context);
    const amber = Color(0xFFF5A623);
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: isDark ? amber.withOpacity(0.16) : amber.withOpacity(0.11),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: amber.withOpacity(0.45), width: 1),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.warning_amber_rounded, color: amber, size: 20),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              l10n.vault_uninstall_warning,
              style: TextStyle(
                fontSize: 12.5,
                height: 1.4,
                fontWeight: FontWeight.w500,
                color: isDark ? const Color(0xFFFFD54F) : const Color(0xFF7A5B00),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 可下拉折叠标题：靠左展示 + 细边框 + 旋转箭头，点击展开/收缩。
  Widget _buildCollapsibleHeader(
    ThemeData theme, {
    required String title,
    required bool expanded,
    required VoidCallback onTap,
  }) {
    return Container(
      margin: const EdgeInsets.fromLTRB(0, 8, 0, 8),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: theme.colorScheme.outline.withOpacity(0.18),
          width: 1,
        ),
      ),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Flexible(
                child: Text(
                  title,
                  textAlign: TextAlign.start,
                  style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 6),
              AnimatedRotation(
                turns: expanded ? 0.5 : 0,
                duration: const Duration(milliseconds: 200),
                child: Icon(
                  Icons.keyboard_arrow_down_rounded,
                  size: 22,
                  color: theme.colorScheme.onSurface.withOpacity(0.6),
                ),
              ),
          ],
        ),
      ),
      ),
    );
  }

  /// 折叠区主体：展开/收缩平滑动画
  Widget _buildCollapsibleBody({required bool expanded, required Widget child}) {
    return AnimatedCrossFade(
      firstChild: const SizedBox(width: double.infinity, height: 0),
      secondChild: child,
      crossFadeState: expanded ? CrossFadeState.showSecond : CrossFadeState.showFirst,
      duration: const Duration(milliseconds: 220),
      sizeCurve: Curves.easeInOut,
    );
  }

  Widget _buildSecurityNavTile(
    ThemeData theme, {
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
  }) {
    return ListTile(
      leading: Icon(icon, size: 24, color: theme.colorScheme.primary),
      title: Text(title, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
      subtitle: Text(
        subtitle,
        style: TextStyle(fontSize: 12.5, color: theme.colorScheme.onSurface.withOpacity(0.55)),
      ),
      trailing: Icon(
        Icons.chevron_right_rounded,
        color: theme.colorScheme.onSurface.withOpacity(0.4),
      ),
      onTap: onTap,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16),
    );
  }

  /// 可折叠区域：标题按钮 + 数量角标 + 展开/收起的正文
  Widget _buildCollapsibleSection({
    required ThemeData theme,
    required bool isDark,
    required String title,
    required IconData icon,
    required Color color,
    required int count,
    required bool expanded,
    required VoidCallback onToggle,
    required Widget body,
    Widget? trailing,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 6.0),
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: theme.colorScheme.outline.withOpacity(0.18)),
          color: isDark ? Colors.white.withOpacity(0.02) : Colors.black.withOpacity(0.01),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            InkWell(
              onTap: onToggle,
              borderRadius: BorderRadius.circular(12),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
                child: Row(
                  children: [
                    Icon(icon, size: 18, color: color),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        title,
                        style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                      decoration: BoxDecoration(
                        color: color.withOpacity(0.15),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Text(
                        '$count',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                          color: color,
                        ),
                      ),
                    ),
                    if (trailing != null) ...[
                      const SizedBox(width: 4),
                      trailing,
                    ],
                    const SizedBox(width: 6),
                    Icon(
                      expanded ? Icons.keyboard_arrow_up_rounded : Icons.keyboard_arrow_down_rounded,
                      size: 22,
                      color: theme.colorScheme.onSurface.withOpacity(0.6),
                    ),
                  ],
                ),
              ),
            ),
            if (expanded) body,
          ],
        ),
      ),
    );
  }

  /// 区域正文：加载中显示小转圈，否则显示列表
  Widget _sectionBody(bool loading, Widget child) {
    if (!loading) return child;
    return const Padding(
      padding: EdgeInsets.symmetric(vertical: 20),
      child: Center(
        child: SizedBox(
          width: 24,
          height: 24,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      ),
    );
  }

  /// 区域为空时的提示
  Widget _buildEmptyHint(ThemeData theme, String text) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 16),
      child: Center(
        child: Text(
          text,
          style: TextStyle(fontSize: 12.5, color: theme.colorScheme.onSurface.withOpacity(0.45)),
        ),
      ),
    );
  }

  Widget _buildFilesList(ThemeData theme, bool isDark) {
    if (_filteredRecords.isEmpty) {
      return _buildEmptyHint(theme, L10n.of(context).vault_no_files);
    }
    return ListView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      itemCount: _filteredRecords.length,
      padding: const EdgeInsets.only(bottom: 12, left: 12, right: 12),
      itemBuilder: (context, index) {
        final rec = _filteredRecords[index];
        final fileIcon = rec.isFolder
            ? FileUtils.getFolderIcon(context.watch<FileManagerProvider>().folderIconOption)
            : FileUtils.getIconForFile(rec.originalName);
        final fileColor = rec.isFolder
            ? theme.colorScheme.primary
            : FileUtils.getColorForFile(rec.originalName, context);
        
        final selected = _selectedSandbox.contains(rec.scrambledPath);
        return Container(
          margin: const EdgeInsets.symmetric(vertical: 5.0),
          decoration: BoxDecoration(
            color: selected
                ? theme.colorScheme.primary.withOpacity(0.12)
                : (isDark ? Colors.white.withOpacity(0.02) : Colors.black.withOpacity(0.01)),
            borderRadius: BorderRadius.circular(18),
            border: Border.all(
              color: selected
                  ? theme.colorScheme.primary.withOpacity(0.6)
                  : theme.colorScheme.outline.withOpacity(0.05),
              width: selected ? 1.6 : 1.2,
            ),
          ),
          child: ListTile(
            onTap: () => _selectionMode
                ? _toggleSandboxSelection(rec.scrambledPath)
                : _previewFile(rec),
            onLongPress: () => _enterSelection(sandboxPath: rec.scrambledPath),
            contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
            leading: _selectionMode
                ? SizedBox(
                    width: 48,
                    height: 48,
                    child: Center(
                      child: Icon(
                        selected
                            ? Icons.check_circle_rounded
                            : Icons.radio_button_unchecked_rounded,
                        color: selected
                            ? theme.colorScheme.primary
                            : theme.colorScheme.onSurface.withOpacity(0.3),
                        size: 26,
                      ),
                    ),
                  )
                : Container(
                    width: 48,
                    height: 48,
                    decoration: BoxDecoration(
                      color: fileColor.withOpacity(0.12),
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: !rec.isFolder && FileUtils.isArchive(rec.originalName)
                        ? ArchiveTypeIcon(label: FileUtils.getArchiveTypeLabel(rec.originalName), color: fileColor, iconScale: 24 / 28)
                        : Icon(
                            fileIcon,
                            color: fileColor,
                            size: 24,
                          ),
                  ),
            title: Text(
              rec.originalName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: 14.5,
              ),
            ),
            subtitle: Padding(
              padding: const EdgeInsets.only(top: 4.0),
              child: Row(
                children: [
                  Text(
                    rec.isFolder ? L10n.of(context).msg1f4c1042 : FileUtils.formatBytes(rec.size, 1),
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: theme.colorScheme.onSurface.withOpacity(0.5),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Container(
                    width: 4,
                    height: 4,
                    decoration: BoxDecoration(
                      color: theme.colorScheme.onSurface.withOpacity(0.3),
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Icon(
                    Broken.lock,
                    size: 13,
                    color: theme.colorScheme.primary,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    L10n.of(context).vault_badge_sandbox,
                    style: TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w600,
                      color: theme.colorScheme.primary,
                    ),
                  ),
                ],
              ),
            ),
            trailing: PopupMenuButton<String>(
              icon: Icon(
                Icons.more_vert_rounded,
                color: theme.colorScheme.onSurface.withOpacity(0.6),
              ),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              onSelected: (val) {
                if (val == 'unlock') {
                  _unlockFile(rec);
                } else if (val == 'info') {
                  _showInfoDialog(rec);
                } else if (val == 'config') {
                  _chooseProfileFor(rec.scrambledPath, isSandbox: true);
                } else if (val == 'delete') {
                  _deletePermanently(rec);
                }
              },
              itemBuilder: (context) => [
                PopupMenuItem(
                  value: 'unlock',
                  child: Row(
                    children: [
                      const Icon(Broken.unlock, size: 18),
                      const SizedBox(width: 10),
                      Text(L10n.of(context).ui_restore_unhide, style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600)),
                    ],
                  ),
                ),
                PopupMenuItem(
                  value: 'config',
                  child: Row(
                    children: [
                      const Icon(Icons.key_outlined, size: 18),
                      const SizedBox(width: 10),
                      Text(L10n.of(context).crypt_profile_action_config, style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600)),
                    ],
                  ),
                ),
                const PopupMenuDivider(),
                PopupMenuItem(
                  value: 'delete',
                  child: Row(
                    children: [
                      Icon(Broken.trash, size: 18, color: theme.colorScheme.error),
                      const SizedBox(width: 10),
                      Text(
                        L10n.of(context).msg96d2b75f,
                        style: TextStyle(
                          fontSize: 13.5,
                          fontWeight: FontWeight.w600,
                          color: theme.colorScheme.error,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  /// 原地加密区域展示项：挂载点扫描项 ∪ 导入的已加密项（按物理路径去重）
  List<_InPlaceItem> get _inplaceItems {
    final items = <_InPlaceItem>[];
    final seen = <String>{};
    for (final f in _inPlaceFiles) {
      if (seen.add(f.physicalPath)) {
        items.add(_InPlaceItem(
          name: f.name,
          path: f.physicalPath,
          displayPath: f.virtualPath,
          isDirectory: f.isDirectory,
          size: f.size,
          modified: f.modified,
          isRemote: f.physicalPath.startsWith('cryptremote://'),
        ));
      }
    }
    for (final e in _encryptedImports) {
      if (seen.add(e.path)) {
        items.add(_InPlaceItem(
          name: _importDecryptedNames[e.path] ?? e.name,
          path: e.path,
          displayPath: e.path,
          isDirectory: e.isDirectory,
          size: e.size,
          modified: e.modified,
          fromImport: true,
        ));
      }
    }
    return items;
  }

  /// 远程加密区域展示项（cryptremote:// 条目，只读）
  List<_InPlaceItem> get _remoteCryptItems {
    final items = <_InPlaceItem>[];
    final seen = <String>{};
    for (final f in _remoteCryptFiles) {
      if (seen.add(f.physicalPath)) {
        items.add(_InPlaceItem(
          name: f.name,
          path: f.physicalPath,
          displayPath: f.virtualPath,
          isDirectory: f.isDirectory,
          size: f.size,
          modified: f.modified,
          isRemote: true,
        ));
      }
    }
    return items;
  }

  /// 构建「原地加密文件」区域列表（菜单：浏览 / 解密）
  Widget _buildInPlaceFilesList(ThemeData theme, bool isDark,
      {List<_InPlaceItem>? itemsOverride, bool allowSelection = true}) {
    final l10n = L10n.of(context);
    final items = itemsOverride ?? _inplaceItems;
    if (items.isEmpty) return _buildEmptyHint(theme, l10n.vault_no_files);
    return ListView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      itemCount: items.length,
      padding: const EdgeInsets.only(bottom: 12, left: 12, right: 12),
      itemBuilder: (context, index) {
        final item = items[index];
        final fileIcon = item.isDirectory
            ? FileUtils.getFolderIcon(context.watch<FileManagerProvider>().folderIconOption)
            : FileUtils.getIconForFile(item.name);
        final fileColor = item.isDirectory
            ? Colors.teal
            : FileUtils.getColorForFile(item.name, context);

        final selected = _selectedInPlace.contains(item.path);
        return Container(
          margin: const EdgeInsets.symmetric(vertical: 5.0),
          decoration: BoxDecoration(
            color: selected
                ? Colors.teal.withOpacity(0.16)
                : (isDark ? Colors.teal.withOpacity(0.05) : Colors.teal.withOpacity(0.03)),
            borderRadius: BorderRadius.circular(18),
            border: Border.all(
              color: selected ? Colors.teal.withOpacity(0.7) : Colors.teal.withOpacity(0.2),
              width: selected ? 1.6 : 1.2,
            ),
          ),
          child: ListTile(
            onTap: () {
              if (allowSelection && _selectionMode) {
                _toggleInPlaceSelection(item.path);
              } else if (item.isRemote && !item.isDirectory) {
                // 远程加密文件：流式解密播放/查看
                context.read<FileManagerProvider>().openFile(context, item.path);
              } else {
                _browseTo(item.path, isDirectory: item.isDirectory);
              }
            },
            onLongPress: allowSelection ? () => _enterSelection(inplacePath: item.path) : null,
            contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
            leading: allowSelection && _selectionMode
                ? SizedBox(
                    width: 48,
                    height: 48,
                    child: Center(
                      child: Icon(
                        selected
                            ? Icons.check_circle_rounded
                            : Icons.radio_button_unchecked_rounded,
                        color: selected
                            ? Colors.teal
                            : theme.colorScheme.onSurface.withOpacity(0.3),
                        size: 26,
                      ),
                    ),
                  )
                : Container(
                    width: 48,
                    height: 48,
                    decoration: BoxDecoration(
                      color: fileColor.withOpacity(0.12),
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Icon(fileIcon, color: fileColor, size: 26),
                  ),
            title: Row(
              children: [
                Expanded(
                  child: Text(
                    item.name,
                    style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14.5),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: Colors.teal.withOpacity(0.15),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    l10n.vault_badge_inplace,
                    style: const TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Colors.teal),
                  ),
                ),
              ],
            ),
            subtitle: Text(
              item.isDirectory
                  ? '${l10n.vault_item_folder} · ${item.displayPath}'
                  : '${_formatSize(item.size)} · ${item.displayPath}',
              style: TextStyle(fontSize: 11.5, color: theme.colorScheme.onSurface.withOpacity(0.5)),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            trailing: PopupMenuButton<String>(
              icon: Icon(Icons.more_vert, color: theme.colorScheme.onSurface.withOpacity(0.5)),
              onSelected: (value) {
                if (value == 'browse') {
                  _browseTo(item.path, isDirectory: item.isDirectory);
                } else if (value == 'decrypt') {
                  _decryptPath(path: item.path, isDirectory: item.isDirectory);
                } else if (value == 'config') {
                  _chooseProfileFor(item.path);
                } else if (value == 'unlink') {
                  _unlinkRemoteCrypt(item.path);
                }
              },
              itemBuilder: (context) {
                // 远程加密条目：v1 只读 → 仅「浏览」（目录）/「取消关联」
                if (item.isRemote) {
                  return [
                    if (item.isDirectory)
                      PopupMenuItem(
                        value: 'browse',
                        child: Row(
                          children: [
                            const Icon(Icons.folder_open, size: 18),
                            const SizedBox(width: 10),
                            Text(l10n.crypt_action_browse, style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600)),
                          ],
                        ),
                      ),
                    PopupMenuItem(
                      value: 'unlink',
                      child: Row(
                        children: [
                          const Icon(Icons.link_off, size: 18),
                          const SizedBox(width: 10),
                          Text(l10n.vault_unlink_remote_crypt, style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600)),
                        ],
                      ),
                    ),
                  ];
                }
                return [
                  PopupMenuItem(
                    value: 'browse',
                    child: Row(
                      children: [
                        const Icon(Icons.folder_open, size: 18),
                        const SizedBox(width: 10),
                        Text(l10n.crypt_action_browse, style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600)),
                      ],
                    ),
                  ),
                  PopupMenuItem(
                    value: 'decrypt',
                    child: Row(
                      children: [
                        const Icon(Icons.lock_open, size: 18),
                        const SizedBox(width: 10),
                        Text(l10n.crypt_action_decrypt, style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600)),
                      ],
                    ),
                  ),
                  PopupMenuItem(
                    value: 'config',
                    child: Row(
                      children: [
                        const Icon(Icons.key_outlined, size: 18),
                        const SizedBox(width: 10),
                        Text(l10n.crypt_profile_action_config, style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600)),
                      ],
                    ),
                  ),
                ];
              },
            ),
          ),
        );
      },
    );
  }

  /// 远程加密区域列表（只读：浏览 / 流式播放 / 取消关联）。复用原地加密 tile。
  Widget _buildRemoteCryptFilesList(ThemeData theme, bool isDark) =>
      _buildInPlaceFilesList(theme, isDark,
          itemsOverride: _remoteCryptItems, allowSelection: false);

  /// 为某个路径选择它应使用的加密配置档案（绑定并持久化）
  ///
  /// 密文无法反推密钥，所以「这份文件用的是哪组密码」必须显式记录。
  /// 绑定后浏览页显示、解密、打开都会用该档案；未绑定的路径回退当前默认档案。
  Future<void> _chooseProfileFor(String path, {bool isSandbox = false}) async {
    final l10n = L10n.of(context);
    final profiles = await CryptProfileService.instance.loadProfiles();
    if (!mounted) return;
    if (profiles.isEmpty) {
      _toast(l10n.crypt_profile_empty);
      return;
    }

    final bindings = await CryptProfileService.instance.loadBindings();
    final currentId = CryptProfileService.matchBindingId(bindings, path);

    final picked = await showModalBottomSheet<CryptProfile>(
      context: context,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 18, 20, 6),
              child: Text(
                l10n.crypt_profile_select_title,
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: profiles.length,
                itemBuilder: (context, index) {
                  final p = profiles[index];
                  return RadioListTile<String>(
                    value: p.id,
                    groupValue: currentId,
                    title: Text(p.name),
                    subtitle: Text(
                      '${p.filenameEncoding.name}${p.encryptedSuffix.isEmpty ? '' : ' · ${p.encryptedSuffix}'}',
                      style: const TextStyle(fontSize: 12),
                    ),
                    onChanged: (_) => Navigator.pop(ctx, p),
                  );
                },
              ),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (picked == null || !mounted) return;

    // 沙盒整体只挂一份密钥：切换会影响沙盒内所有文件，必须二次确认
    if (isSandbox) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(l10n.crypt_profile_sandbox_title),
          content: Text(l10n.crypt_profile_sandbox_message),
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
      if (ok != true) return;
    }

    await CryptProfileService.instance.bindPath(path, picked.id);
    await _loadInPlaceEncryptedFiles();
    await _loadVaultData();
    await _refreshBrowser();
    if (mounted) _toast(l10n.crypt_profile_bound_done);
  }

  /// 跳转到浏览页查看指定文件/文件夹
  ///
  /// 与导出备份「打开文件所在位置」一致：先置位跳转，再 popUntil 回首页。
  void _browseTo(String path, {bool isDirectory = false}) {
    // 远程加密项：进入主浏览页（与主浏览页能力完全一致：重命名/删除/新建/流式播放/加解密）
    if (path.startsWith('cryptremote://')) {
      final target = isDirectory ? path : _remoteCryptParent(path);
      final provider = context.read<FileManagerProvider>();
      provider.setPendingBrowseNavigation(target, [path]);
      Navigator.of(context).popUntil((route) => route.isFirst);
      return;
    }
    final provider = context.read<FileManagerProvider>();
    final targetDir = Directory(path).existsSync() ? path : p.dirname(path);
    provider.setPendingBrowseNavigation(targetDir, [path]);
    Navigator.of(context).popUntil((route) => route.isFirst);
  }

  /// 远程加密虚拟路径的父目录（`cryptremote://conn|/a/b/c` → `cryptremote://conn|/a/b`）
  String _remoteCryptParent(String virtualPath) {
    final idx = virtualPath.indexOf('|');
    if (idx < 0) return virtualPath;
    final prefix = virtualPath.substring(0, idx + 1);
    final serverPath = virtualPath.substring(idx + 1);
    final parts = serverPath.split('/')..removeWhere((s) => s.isEmpty);
    if (parts.isEmpty) return virtualPath;
    parts.removeLast();
    return '$prefix/${parts.join('/')}';
  }

  /// 解密 rclone/OpenList 加密的文件/文件夹
  ///
  /// 先尝试用「加密设置」里已配置的主密码和盐；若解密失败（密码/盐对不上），
  /// 弹出输入框让用户重新填写密码与盐后重试。
  Future<void> _decryptPath({
    required String path,
    required bool isDirectory,
  }) async {
    // 需求5：解密前先过保险箱会话闸门
    if (!await requireVaultSessionUnlock(context)) return;
    final l10n = L10n.of(context);
    final navigator = Navigator.of(context);
    final scaffoldMessenger = ScaffoldMessenger.of(context);

    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.vault_decrypt_confirm_title),
        content: Text(l10n.vault_decrypt_confirm_desc(p.basename(path))),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: Text(l10n.ui_cancel)),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(l10n.vault_decrypt_action)),
        ],
      ),
    );
    if (confirm != true) return;

    final progress = ValueNotifier<double?>(null);
    var loadingShown = false;
    void showLoading() {
      if (loadingShown) return;
      loadingShown = true;
      pushProgressRoute(navigator, message: l10n.vault_decrypting, progress: progress);
    }

    void hideLoading() {
      if (!loadingShown) return;
      loadingShown = false;
      navigator.pop();
    }

    Object? firstError;
    try {
      showLoading();
      final mount = await _resolveCryptMountForPath(path);
      if (mount == null) {
        // 尚未在加密设置中配置主密码 → 引导去设置页，不弹内联输入框
        hideLoading();
        _showNeedPasswordDialog(l10n);
        return;
      }

      try {
        final ops = CryptOperations(mount);
        if (isDirectory) {
          await ops.decryptDirectory(
            path,
            onProgress: (done, total) =>
                progress.value = total > 0 ? done / total : null,
          );
        } else {
          await ops.decryptFile(path);
        }
        await _afterDecrypt(path);
        if (mounted) {
          hideLoading();
          scaffoldMessenger.showSnackBar(
            SnackBar(content: Text(l10n.vault_decrypt_success)),
          );
        }
        return;
      } catch (e) {
        firstError = e;
      }

      // 已配置的主密码/盐对不上 → 引导去加密设置重新配置（不再弹内联输入框）
      hideLoading();
      _showNeedPasswordDialog(l10n);
    } catch (e) {
      if (mounted) {
        hideLoading();
        scaffoldMessenger.showSnackBar(
          SnackBar(content: Text(l10n.vault_decrypt_failed('${firstError ?? e}'))),
        );
      }
    } finally {
      progress.dispose();
    }
  }

  /// 解密成功后：从导入清单移除并刷新各区域
  Future<void> _afterDecrypt(String path) async {
    await VaultImportStore.remove(path);
    await _loadImportEntries();
    await _loadInPlaceEncryptedFiles();
    // 同步刷新浏览页：解密后磁盘上已变回普通文件名，
    // 浏览页缓存不重载就仍显示密文名（需重启应用才更新）。
    await _refreshBrowser();
  }

  // ===================== 需求2：多选操作 =====================

  /// 底部多选操作栏：退出 / 已选数量 / 全选 / 解密 / 删除
  Widget _buildSelectionBar(ThemeData theme, bool isDark) {
    final l10n = L10n.of(context);
    return Material(
      color: isDark ? const Color(0xFF111827) : theme.colorScheme.surface,
      elevation: 8,
      child: SafeArea(
        top: false,
        child: Container(
          height: 60,
          padding: const EdgeInsets.symmetric(horizontal: 6),
          child: Row(
            children: [
              IconButton(
                icon: const Icon(Icons.close_rounded),
                tooltip: l10n.ui_cancel,
                onPressed: _exitSelection,
              ),
              Expanded(
                child: Text(
                  l10n.prop_items_selected(_selectionCount),
                  style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13.5),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              IconButton(
                icon: const Icon(Icons.select_all_rounded),
                tooltip: l10n.ui_select_all,
                onPressed: _selectAllVisible,
              ),
              const SizedBox(width: 4),
              FilledButton.tonalIcon(
                onPressed: _decryptSelected,
                icon: const Icon(Icons.lock_open_rounded, size: 18),
                label: Text(l10n.vault_decrypt_action),
              ),
              const SizedBox(width: 6),
              FilledButton.icon(
                onPressed: _deleteSelected,
                style: FilledButton.styleFrom(
                  backgroundColor: theme.colorScheme.error,
                  foregroundColor: theme.colorScheme.onError,
                ),
                icon: const Icon(Broken.trash, size: 18),
                label: Text(l10n.ui_delete),
              ),
              const SizedBox(width: 6),
            ],
          ),
        ),
      ),
    );
  }

  /// 批量解密：沙盒条目恢复到原位置；原地加密条目原地解密。
  Future<void> _decryptSelected() async {
    if (!await requireVaultSessionUnlock(context)) return;
    if (!mounted) return;
    final l10n = L10n.of(context);
    final sandboxRecs = _records
        .where((r) => _selectedSandbox.contains(r.scrambledPath))
        .toList();
    final inplaceItems =
        _inplaceItems.where((i) => _selectedInPlace.contains(i.path)).toList();
    final total = sandboxRecs.length + inplaceItems.length;
    if (total == 0) return;

    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.vault_decrypt_action),
        content: Text(l10n.prop_items_selected(total)),
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
    if (confirm != true || !mounted) return;

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => ProgressOverlay(message: l10n.vault_decrypting),
    );

    var ok = 0;
    var fail = 0;
    for (final rec in sandboxRecs) {
      try {
        final originalPath = await _resolveCryptRestorePath(rec);
        await VaultCryptService.instance.decryptFromSandbox(
          sandboxPath: rec.scrambledPath,
          originalPath: originalPath,
        );
        ok++;
      } catch (e) {
        debugPrint('[vault] 批量解密（沙盒）失败 ${rec.scrambledPath}: $e');
        fail++;
      }
    }
    for (final item in inplaceItems) {
      try {
        final mount = await _resolveCryptMountForPath(item.path);
        if (mount == null) {
          fail++;
          continue;
        }
        final ops = CryptOperations(mount);
        if (item.isDirectory) {
          await ops.decryptDirectory(item.path);
        } else {
          await ops.decryptFile(item.path);
        }
        await VaultImportStore.remove(item.path);
        ok++;
      } catch (e) {
        debugPrint('[vault] 批量解密（原地）失败 ${item.path}: $e');
        fail++;
      }
    }

    if (mounted) Navigator.of(context).pop(); // 关闭进度覆盖层
    _exitSelection();
    await _loadVaultData();
    await _loadImportEntries();
    await _loadInPlaceEncryptedFiles();
    await _refreshBrowser();
    if (mounted) {
      _toast(fail == 0
          ? l10n.vault_decrypt_success
          : l10n.vault_decrypt_failed('$fail/$total'));
    }
  }

  /// 批量永久删除（沙盒密文 / 原地加密实体）
  Future<void> _deleteSelected() async {
    if (!await requireVaultSessionUnlock(context)) return;
    if (!mounted) return;
    final l10n = L10n.of(context);
    final sandboxRecs = _records
        .where((r) => _selectedSandbox.contains(r.scrambledPath))
        .toList();
    final inplaceItems =
        _inplaceItems.where((i) => _selectedInPlace.contains(i.path)).toList();
    final total = sandboxRecs.length + inplaceItems.length;
    if (total == 0) return;

    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.msg_permanent_delete),
        content: Text(l10n.ui_delete_items_confirm(total)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(l10n.ui_cancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(
              foregroundColor: Theme.of(ctx).colorScheme.error,
            ),
            child: Text(l10n.ui_delete),
          ),
        ],
      ),
    );
    if (confirm != true || !mounted) return;

    var ok = 0;
    var fail = 0;
    for (final rec in sandboxRecs) {
      try {
        await _deleteSandboxRecord(rec);
        ok++;
      } catch (e) {
        debugPrint('[vault] 批量删除（沙盒）失败 ${rec.scrambledPath}: $e');
        fail++;
      }
    }
    for (final item in inplaceItems) {
      try {
        await _deleteInPlaceItem(item);
        ok++;
      } catch (e) {
        debugPrint('[vault] 批量删除（原地）失败 ${item.path}: $e');
        fail++;
      }
    }

    _exitSelection();
    await _loadVaultData();
    await _loadImportEntries();
    await _loadInPlaceEncryptedFiles();
    await _refreshBrowser();
    if (mounted) {
      _toast(fail == 0
          ? l10n.msg_file_deleted
          : l10n.msg_delete_failed('$fail/$total'));
    }
  }

  /// 删除单个沙盒密文实体并清理来源映射
  Future<void> _deleteSandboxRecord(VaultFileRecord record) async {
    final file = File(record.scrambledPath);
    if (await file.exists()) {
      await file.delete();
    } else {
      final dir = Directory(record.scrambledPath);
      if (await dir.exists()) {
        await dir.delete(recursive: true);
      }
    }
    await VaultCryptService.instance.removeSandboxOrigin(record.scrambledPath);
  }

  /// 删除单个原地加密实体并清理导入清单记录
  Future<void> _deleteInPlaceItem(_InPlaceItem item) async {
    final type = FileSystemEntity.typeSync(item.path);
    if (type == FileSystemEntityType.directory) {
      await Directory(item.path).delete(recursive: true);
    } else if (type == FileSystemEntityType.file) {
      await File(item.path).delete();
    }
    await VaultImportStore.remove(item.path);
  }

  String _formatSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }
}

/// 「原地加密文件」区域的统一展示项
///
/// 用于把两种来源合并到同一个列表：
/// - 挂载点目录扫描出来的加密条目
/// - 用户导入时被识别为已加密（rclone/OpenList）的条目
class _InPlaceItem {
  /// 显示名称
  final String name;

  /// 物理路径（真实存在于磁盘上的路径，用于浏览/解密）
  final String path;

  /// 副标题展示路径（扫描项用解密后的虚拟路径，导入项用原路径）
  final String displayPath;

  final bool isDirectory;
  final int size;
  final DateTime modified;

  /// 是否来自导入清单（而非挂载点扫描）
  final bool fromImport;

  /// 是否为**远程加密**条目（path 形如 `cryptremote://...`，v1 只读）
  final bool isRemote;

  _InPlaceItem({
    required this.name,
    required this.path,
    required this.displayPath,
    required this.isDirectory,
    this.size = 0,
    DateTime? modified,
    this.fromImport = false,
    this.isRemote = false,
  }) : modified = modified ?? DateTime.now();
}
