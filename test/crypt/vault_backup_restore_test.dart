import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zenfile/services/crypt/crypt_mount.dart';
import 'package:zenfile/services/crypt/crypt_mount_service.dart';
import 'package:zenfile/services/crypt/crypt_operations.dart';
import 'package:zenfile/services/crypt/vault_crypt_service.dart';

/// 保险箱「便携备份 → 恢复」的回归。
///
/// 覆盖用户反馈：备份成功后删掉沙盒加密列表里的文件，再从备份导入恢复 ——
/// 提示「恢复成功」、条目数量也对，但**沙盒加密列表里看不到恢复回来的文件**。
///
/// 根因：[VaultCryptService.importBackup] 里的 `saveMountPoints(const [])`
/// （语义是「主密码可能已随备份变化 → 旧挂载点全部作废」）会把**沙盒挂载点**
/// 与原地加密挂载点**一并清空**（两者同表存储），而它注释里那句
/// 「沙盒挂载点由 ensureSandboxMount 按需重建」其实**没有任何人调用**：
/// 保险箱列表 `vault_explorer_screen._loadCryptSandboxRecords` 是直接读
/// `CryptMountService.loadMountPoints()` 找 `isSandboxMode` 挂载点的，
/// 查不到就 `return const []`。密文其实已经写回磁盘，只是列表列不出来。
///
/// 这里钉住恢复后的**不变式**（比断言 UI 更稳）：挂载点登记表里必须存在沙盒
/// 挂载点，且它拿到的密钥能解开备份里的密文（解出的文件名 == 原文件名）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp; // 代替 getApplicationDocumentsDirectory()
  late String sandboxDir; // tmp/vault_crypt

  setUp(() async {
    SharedPreferences.setMockInitialValues({
      VaultCryptService.kMasterPasswordKey: 'master-pw',
      VaultCryptService.kMasterSaltKey: 'master-salt',
    });
    FlutterSecureStorage.setMockInitialValues({});
    tmp = await Directory.systemTemp.createTemp('vault_backup_');
    VaultCryptService.sandboxDocsDirOverride = tmp.path;
    sandboxDir = await VaultCryptService.instance.getSandboxDir();
  });

  tearDown(() async {
    VaultCryptService.sandboxDocsDirOverride = null;
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  /// 模拟保险箱列表的读法：**直接看登记表**，不经 `ensureSandboxMount()`。
  /// （`listSandboxFiles()` 会顺手把挂载点建出来，会掩盖这个 bug。）
  Future<CryptMountPoint?> sandboxMountFromRegistry() async {
    final mounts = await CryptMountService.loadMountPoints();
    for (final m in mounts) {
      if (m.isSandboxMode) return m;
    }
    return null;
  }

  Future<List<File>> sandboxCipherFiles() async {
    if (!await Directory(sandboxDir).exists()) return const <File>[];
    return Directory(sandboxDir)
        .listSync()
        .whereType<File>()
        .where((f) => p.basename(f.path) != '.nomedia')
        .toList();
  }

  test('备份 → 删文件 → 恢复：沙盒挂载点必须重建，列表能解出恢复的文件', () async {
    // 1) 造一份沙盒密文（等同用户「导入文件到保险箱」）
    final src = File(p.join(tmp.path, 'secret.mp4'));
    await src.writeAsBytes(List.filled(4096, 7));
    await VaultCryptService.instance.encryptToSandbox(sourcePath: src.path);
    expect(await src.exists(), isFalse, reason: '沙盒加密应把原文件移走');

    final before = await sandboxCipherFiles();
    expect(before, hasLength(1), reason: '沙盒里应有 1 份密文');
    expect(await sandboxMountFromRegistry(), isNotNull,
        reason: '前置：加密后登记表里应有沙盒挂载点');

    // 2) 导出备份
    final zip = await VaultCryptService.instance.exportBackup(
      p.join(tmp.path, 'backup'),
    );
    expect(File(zip).existsSync(), isTrue, reason: '备份包应落盘');

    // 3) 用户把沙盒加密列表里的文件删掉
    for (final f in before) {
      await f.delete();
    }
    expect(await sandboxCipherFiles(), isEmpty);

    // 4) 从备份导入恢复
    final imported = await VaultCryptService.instance.importBackup(zip);
    expect(imported, 1, reason: '提示给用户的条目数');
    expect(await sandboxCipherFiles(), hasLength(1),
        reason: '密文应已写回沙盒目录');

    // 5) 关键不变式：登记表里必须重新出现沙盒挂载点。
    //    缺了它，保险箱列表 `_loadCryptSandboxRecords` 会直接返回空 ——
    //    正是用户看到的「提示成功但列表里没有文件」。
    final sandbox = await sandboxMountFromRegistry();
    expect(sandbox, isNotNull,
        reason: '恢复后没有沙盒挂载点 → 保险箱列表必然为空');
    expect(sandbox!.physicalPath, sandboxDir);
    expect(sandbox.isSandboxMode, isTrue);
    expect(sandbox.config.password, isNotEmpty,
        reason: '挂载点必须带上（刚恢复的）主密码，否则解不开备份里的密文');

    // 6) 列表真的能列出恢复回来的文件（等价的 _loadCryptSandboxRecords 调用）
    final entries =
        await CryptDirectoryLister(sandbox).listDirectory(sandbox.physicalPath);
    expect(entries.map((e) => e.name), contains('secret.mp4'),
        reason: '恢复后必须能解出原文件名，而不是密文名/空列表');
  });

  test('空沙盒也能导出/导入，不报错也不留下坏状态', () async {
    final zip = await VaultCryptService.instance.exportBackup(
      p.join(tmp.path, 'backup'),
    );
    expect(await VaultCryptService.instance.importBackup(zip), 0);
    expect(await sandboxCipherFiles(), isEmpty);
  });

  test('恢复后主密码换成备份里的那一组（挂载点重建用的是新密码）', () async {
    // 备份时用 A 密码
    final src = File(p.join(tmp.path, 'a.txt'));
    await src.writeAsString('vault content');
    await VaultCryptService.instance.encryptToSandbox(sourcePath: src.path);
    final zip = await VaultCryptService.instance.exportBackup(
      p.join(tmp.path, 'backupA'),
    );

    // 用户把当前主密码改成了 B（模拟换机/改密码后误导入旧备份）
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(VaultCryptService.kMasterPasswordKey, 'other-pw');

    await VaultCryptService.instance.importBackup(zip);

    final sandbox = await sandboxMountFromRegistry();
    expect(sandbox, isNotNull);
    expect(sandbox!.config.password, 'master-pw',
        reason: '必须用备份里的主密码重建，否则恢复出来的密文永远解不开');
    final entries =
        await CryptDirectoryLister(sandbox).listDirectory(sandbox.physicalPath);
    expect(entries.map((e) => e.name), contains('a.txt'));
  });
}
