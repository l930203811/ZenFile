import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zenfile/services/crypt/crypt_config.dart';
import 'package:zenfile/services/crypt/crypt_mount.dart';
import 'package:zenfile/services/crypt/crypt_operations.dart';
import 'package:zenfile/services/crypt/vault_import_store.dart';

/// 保险箱「原地加密」导入清单的失效清理回归。
///
/// 覆盖用户反馈：原地加密后在浏览页**解密**或**删除原文件**，
/// 保险箱「原地加密文件」区域仍然显示那些条目。
///
/// 根因：导入清单（SharedPreferences）里的记录不会随磁盘状态变化而作废。
/// 修复：加载清单前跑 [VaultImportStore.pruneStale]。
void main() {
  late Directory root;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    root = await Directory.systemTemp.createTemp('vault_import_');
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  RcloneCryptConfig cfg() => RcloneCryptConfig(
        password: 'master-pw',
        salt: 'master-salt',
        filenameEncryption: FilenameEncryption.standard,
        directoryNameEncryption: true,
        filenameEncoding: FilenameEncoding.base64,
        encryptedSuffix: '.bin',
      );

  CryptMountPoint mountFor(Directory dir, RcloneCryptConfig c) =>
      CryptMountPoint(physicalPath: dir.path, config: c, name: p.basename(dir.path));

  Future<void> markEncrypted(String path, {required bool isDirectory}) async {
    await VaultImportStore.upsert(VaultImportEntry(
      path: path,
      isDirectory: isDirectory,
      encrypted: true,
    ));
    final loaded = await VaultImportStore.load();
    expect(loaded.map((e) => e.path), contains(path), reason: '前置：条目应已写入');
  }

  Future<bool> stillInStore(String path) async {
    final loaded = await VaultImportStore.load();
    return loaded.any((e) => e.path == path);
  }

  test('仍为密文的文件 → 保留', () async {
    final c = cfg();
    final m = mountFor(root, c);
    final ops = CryptOperations(m);
    final src = File(p.join(root.path, 'a.mp4'));
    await src.writeAsBytes(List.filled(2048, 7));
    final enc = await ops.encryptFile(src.path);

    await markEncrypted(enc, isDirectory: false);

    final kept = await VaultImportStore.pruneStale([m]);
    expect(kept.map((e) => e.path), contains(enc));
    expect(await stillInStore(enc), isTrue);
  });

  test('文件被原地解密（密文路径消失）→ 清理', () async {
    final c = cfg();
    final m = mountFor(root, c);
    final ops = CryptOperations(m);
    final src = File(p.join(root.path, 'b.mp4'));
    await src.writeAsBytes(List.filled(2048, 9));
    final enc = await ops.encryptFile(src.path);
    await markEncrypted(enc, isDirectory: false);

    // 模拟用户在浏览页解密
    await ops.decryptFile(enc);
    expect(File(enc).existsSync(), isFalse);
    expect(File(p.join(root.path, 'b.mp4')).existsSync(), isTrue);

    final kept = await VaultImportStore.pruneStale([m]);
    expect(kept, isEmpty);
    expect(await stillInStore(enc), isFalse);
  });

  test('原文件被删除 → 清理', () async {
    final c = cfg();
    final m = mountFor(root, c);
    final ops = CryptOperations(m);
    final src = File(p.join(root.path, 'c.mp4'));
    await src.writeAsBytes(List.filled(2048, 5));
    final enc = await ops.encryptFile(src.path);
    await markEncrypted(enc, isDirectory: false);

    // 模拟用户在浏览页删除密文
    await File(enc).delete();

    final kept = await VaultImportStore.pruneStale([m]);
    expect(kept, isEmpty);
    expect(await stillInStore(enc), isFalse);
  });

  test('仍为密文的目录 → 保留', () async {
    final c = cfg();
    final m = mountFor(root, c);
    final ops = CryptOperations(m);
    final sub = Directory(p.join(root.path, 'MyFolder'))..createSync();
    await File(p.join(sub.path, 'inner.txt')).writeAsBytes(List.filled(3000, 3));
    await ops.encryptDirectory(sub.path);
    expect(Directory(sub.path).existsSync(), isFalse, reason: '目录名应已变密文');

    final encDir = (await root.list().toList()).single.path;
    await markEncrypted(encDir, isDirectory: true);

    final kept = await VaultImportStore.pruneStale([m]);
    expect(kept.map((e) => e.path), contains(encDir));
  });

  test('目录被整体解密 → 清理', () async {
    final c = cfg();
    final m = mountFor(root, c);
    final ops = CryptOperations(m);
    final sub = Directory(p.join(root.path, 'Secret'))..createSync();
    await File(p.join(sub.path, 'inner.txt')).writeAsBytes(List.filled(3000, 3));
    await ops.encryptDirectory(sub.path);
    final encDir = (await root.list().toList()).single.path;
    await markEncrypted(encDir, isDirectory: true);

    // 模拟用户在浏览页解密整个文件夹
    await ops.decryptDirectory(encDir);
    expect(Directory(p.join(root.path, 'Secret')).existsSync(), isTrue);

    final kept = await VaultImportStore.pruneStale([m]);
    expect(kept, isEmpty);
    expect(await stillInStore(encDir), isFalse);
  });

  test('路径存在但已非密文（同名明文）→ 清理', () async {
    final c = cfg();
    final m = mountFor(root, c);
    final plain = File(p.join(root.path, 'plain.txt'));
    await plain.writeAsString('just a plain text file, definitely not rclone');
    await markEncrypted(plain.path, isDirectory: false);

    final kept = await VaultImportStore.pruneStale([m]);
    expect(kept, isEmpty);
  });

  test('整个存储不可见（父目录不存在）→ 保守保留，绝不误清', () async {
    final c = cfg();
    final m = mountFor(root, c);
    final gone = p.join(root.path, 'unmounted_dir', 'x.mp4');
    await markEncrypted(gone, isDirectory: false);

    final kept = await VaultImportStore.pruneStale([m]);
    expect(kept.map((e) => e.path), contains(gone));
    expect(await stillInStore(gone), isTrue);
  });

  test('无可用挂载点（拿不到密钥）时目录条目保留', () async {
    final plainDir = Directory(p.join(root.path, 'SomeDir'))..createSync();
    await markEncrypted(plainDir.path, isDirectory: true);

    // 没有任何挂载点 → 无法判定目录是否已解密 → 不得清理
    final kept = await VaultImportStore.pruneStale(const []);
    expect(kept.map((e) => e.path), contains(plainDir.path));

    // 密码未补齐的挂载点同样不可用于判定
    final noPw = CryptMountPoint(
      physicalPath: root.path,
      config: const RcloneCryptConfig(password: ''),
      name: 'r',
    );
    final kept2 = await VaultImportStore.pruneStale([noPw]);
    expect(kept2.map((e) => e.path), contains(plainDir.path));
  });

  group('detectEncrypted（导入时的「已加密」预检）', () {
    test('夹带一个密文文件的普通文件夹 → 不算已加密（不得静默跳过用户的加密请求）', () async {
      final c = cfg();
      final m = mountFor(root, c);
      final ops = CryptOperations(m);
      final container = Directory(p.join(root.path, 'container'))..createSync();
      await File(p.join(container.path, 'plain.txt')).writeAsString('plain');
      final secret = File(p.join(container.path, 'one.mp4'));
      await secret.writeAsBytes(List.filled(4096, 3));
      await ops.encryptFile(secret.path);

      expect(await VaultImportStore.detectEncrypted(container.path, [m]), isFalse,
          reason: '目录名是明文 → 该目录本身没被加密，用户选它加密时不能被跳过');
      // 容器里那个密文文件本身仍是密文实体（加密该目录时由 skipEncrypted 跳过）
      final cipherPath = (await container.list().toList())
          .map((e) => e.path)
          .firstWhere((e) => !e.endsWith('plain.txt'));
      expect(await VaultImportStore.detectEncrypted(cipherPath, [m]), isTrue);
    });

    test('目录名是密文名的加密目录 → 算已加密', () async {
      final c = cfg();
      final m = mountFor(root, c);
      final ops = CryptOperations(m);
      final sub = Directory(p.join(root.path, 'Secret'))..createSync();
      await File(p.join(sub.path, 'inner.txt')).writeAsBytes(List.filled(3000, 5));
      await ops.encryptDirectory(sub.path);
      final encDir = (await root.list().toList()).single.path;

      expect(await VaultImportStore.detectEncrypted(encDir, [m]), isTrue);
    });

    test('密文文件 / 普通文件 → 按 magic 头区分', () async {
      final c = cfg();
      final m = mountFor(root, c);
      final ops = CryptOperations(m);
      final f = File(p.join(root.path, 'a.mp4'));
      await f.writeAsBytes(List.filled(2048, 7));
      final enc = await ops.encryptFile(f.path);

      expect(await VaultImportStore.detectEncrypted(enc, [m]), isTrue);
      final plain = File(p.join(root.path, 'b.mp4'));
      await plain.writeAsBytes(List.filled(2048, 1));
      expect(await VaultImportStore.detectEncrypted(plain.path, [m]), isFalse);
    });
  });
}
