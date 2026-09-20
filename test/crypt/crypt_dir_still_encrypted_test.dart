import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:zenfile/services/crypt/crypt_config.dart';
import 'package:zenfile/services/crypt/crypt_mount.dart';
import 'package:zenfile/services/crypt/crypt_operations.dart';

/// 「目录当前是否**本身就是一个加密目录实体**」判据的回归
/// （`CryptOperations.isDirectoryStillEncrypted` / `isCipherDirName`）。
///
/// 覆盖用户先后反馈的两个 bug：
/// 1. 原地加密的文件夹解密后，其他文件复制/剪切进来仍然被加密；
/// 2. **文件夹没有加密，但文件夹中有一个文件加密**（只原位加密了其中一个文件，
///    或从别处拷来一个密文文件），复制/剪切其他文件进去，其他文件也被加密。
///
/// 收敛结论（判据只能看「目录名本身是不是密文名」）：
/// - 原地加密目录时目录名会一并换成密文名 → 「目录被加密」的充要外在特征；
/// - 「目录里有密文子项」**不是**目录被加密的证据（夹带零星密文、挂载点根容器
///   都会命中）→ 早期实现据此判定，才导致往普通文件夹里粘贴被静默加密；
/// - 「是不是挂载点根」也不能用：挂载点是建在被加密条目的**父目录**上的容器。
void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('crypt_dir_enc_');
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

  Future<bool> stillEncrypted(Directory dir, CryptMountPoint m) =>
      CryptOperations.isDirectoryStillEncrypted(dir.path, mount: m);

  group('isCipherDirName（密文目录名判定）', () {
    test('真实密文目录名 → true；普通目录名 → false', () {
      final c = cfg();
      final m = mountFor(root, c);

      final encName = m.crypt.encryptDirName('Secret');
      expect(encName, isNot('Secret'));
      expect(CryptOperations.isCipherDirName(encName, m), isTrue);
      expect(CryptOperations.isCipherDirName('Secret', m), isFalse);
      expect(CryptOperations.isCipherDirName('test', m), isFalse);
      expect(CryptOperations.isCipherDirName('DCIM', m), isFalse);
      expect(CryptOperations.isCipherDirName('My Folder', m), isFalse);
      expect(CryptOperations.isCipherDirName('aaaaaaaaaaaaaaaaaaaa', m), isFalse);
      expect(CryptOperations.isCipherDirName('', m), isFalse);
    });

    test('目录名带了配置后缀（外部工具写入）→ 仍能识别', () {
      final c = cfg();
      final m = mountFor(root, c);
      final encName = '${m.crypt.encryptDirName('Secret')}.bin';

      expect(CryptOperations.isCipherDirName(encName, m), isTrue);
    });
  });

  group('isDirectoryStillEncrypted（目录实体是否加密）', () {
    test('普通文件夹里只有一个被原地加密的文件（其余明文）→ 目录不算加密', () async {
      final c = cfg();
      final m = mountFor(root, c);
      final ops = CryptOperations(m);
      await File(p.join(root.path, 'plain.txt')).writeAsString('plain');
      final secret = File(p.join(root.path, 'secret.mp4'));
      await secret.writeAsBytes(List.filled(4096, 3));
      await ops.encryptFile(secret.path);

      expect(await stillEncrypted(root, m), isFalse,
          reason: '目录名仍是明文 → 目录本身没被加密，新粘贴进来的文件不应被加密');
    });

    test('普通文件夹里**只有**一个被原地加密的文件 → 目录仍不算加密（最易误判）', () async {
      final c = cfg();
      final m = mountFor(root, c);
      final ops = CryptOperations(m);
      final f = File(p.join(root.path, 'only.mp4'));
      await f.writeAsBytes(List.filled(4096, 7));

      await ops.encryptFile(f.path);

      expect((await root.list().toList()).length, 1);
      expect(
        await CryptOperations.isEncryptedFile((await root.list().toList()).single.path),
        isTrue,
        reason: '前置：目录里确实躺着一个密文文件',
      );
      expect(await stillEncrypted(root, m), isFalse,
          reason: '「目录里有密文」≠「目录被加密」（用户反馈的核心回归）');
    });

    test('原地加密的文件被解密后 → 目录不算加密（用户反馈 1）', () async {
      final c = cfg();
      final m = mountFor(root, c);
      final ops = CryptOperations(m);
      final f = File(p.join(root.path, 'note.txt'));
      await f.writeAsBytes(List.filled(3000, 7));
      final enc = await ops.encryptFile(f.path);

      await ops.decryptFile(enc);

      expect(File(p.join(root.path, 'note.txt')).existsSync(), isTrue);
      expect(await stillEncrypted(root, m), isFalse,
          reason: '已解密/未加密的目录不得被判定为加密，否则新复制进来的文件会被静默加密');
    });

    test('挂载点根容器（原地加密的挂载点建在被加密条目的父目录）→ 不算加密', () async {
      final c = cfg();
      final m = mountFor(root, c);
      final ops = CryptOperations(m);
      final sub = Directory(p.join(root.path, 'Secret'))..createSync();
      await File(p.join(sub.path, 'inner.txt')).writeAsBytes(List.filled(3000, 5));

      // 容器 root 里只有那一个加密文件夹
      await ops.encryptDirectory(sub.path);
      expect((await root.list().toList()).length, 1);

      expect(await stillEncrypted(root, m), isFalse,
          reason: 'root 是容器（名字未变），往 root 里粘贴不应触发加密');
    });

    test('加密前后 resolvePhysicalPath 都等于虚拟路径 → 旧判据无法区分两者', () async {
      final c = cfg();
      final m = mountFor(root, c);
      final ops = CryptOperations(m);
      final f = File(p.join(root.path, 'a.bin'));
      await f.writeAsBytes(List.filled(3000, 3));
      final enc = await ops.encryptFile(f.path);

      // 加密中：虚拟路径在磁盘上存在（目录名没变）→ 第 1 步直接返回自身
      expect(await m.resolvePhysicalPath(root.path), root.path);

      await ops.decryptFile(enc);

      // 解密后：同样是自身 → 「是不是挂载点根 / 是否解析回自身」全都区分不出来
      expect(await m.resolvePhysicalPath(root.path), root.path);

      // 能区分两者的只有「目录名本身是不是密文名」
      expect(await stillEncrypted(root, m), isFalse);
    });

    test('目录整体加密后（目录名变密文）→ 仍加密', () async {
      final c = cfg();
      final m = mountFor(root, c);
      final ops = CryptOperations(m);
      final sub = Directory(p.join(root.path, 'Secret'))..createSync();
      await File(p.join(sub.path, 'inner.txt')).writeAsBytes(List.filled(3000, 5));

      await ops.encryptDirectory(sub.path);

      final encDir = Directory((await root.list().toList()).single.path);
      expect(encDir.path, isNot(p.join(root.path, 'Secret')),
          reason: '目录整体加密应同时加密目录名');
      expect(await stillEncrypted(encDir, m), isTrue);
    });

    test('目录整体加密后，往「虚拟路径」解析出的密文目录 → 仍加密', () async {
      final c = cfg();
      final m = mountFor(root, c);
      final ops = CryptOperations(m);
      final sub = Directory(p.join(root.path, 'Secret'))..createSync();
      await File(p.join(sub.path, 'inner.txt')).writeAsBytes(List.filled(3000, 5));
      await ops.encryptDirectory(sub.path);

      // 浏览页拿到的是虚拟路径（磁盘上的真实名字已是密文名）
      final resolved = await m.resolvePhysicalPath(p.join(root.path, 'Secret'));
      expect(resolved, isNot(p.join(root.path, 'Secret')));
      expect(await stillEncrypted(Directory(resolved), m), isTrue,
          reason: '加密文件夹内粘贴新文件仍应继续加密');
    });

    test('目录整体解密后 → 不再加密', () async {
      final c = cfg();
      final m = mountFor(root, c);
      final ops = CryptOperations(m);
      final sub = Directory(p.join(root.path, 'Secret'))..createSync();
      await File(p.join(sub.path, 'inner.txt')).writeAsBytes(List.filled(3000, 5));
      await ops.encryptDirectory(sub.path);
      final encDir = Directory((await root.list().toList()).single.path);

      await ops.decryptDirectory(encDir.path);

      final plainDir = Directory(p.join(root.path, 'Secret'));
      expect(plainDir.existsSync(), isTrue);
      expect(await stillEncrypted(plainDir, m), isFalse);
    });

    test('密文名空壳目录（内容已清空）→ 仍视为加密', () async {
      final c = cfg();
      final m = mountFor(root, c);
      final encName = m.crypt.encryptDirName('Secret');
      final shell = Directory(p.join(root.path, encName))..createSync();

      expect(encName, isNot('Secret'));
      expect(await stillEncrypted(shell, m), isTrue,
          reason: '目录名仍是密文名 → 不能当明文目录处理');
    });

    test('只有明文文件的普通目录 → 不加密', () async {
      final c = cfg();
      final m = mountFor(root, c);
      await File(p.join(root.path, 'readme.txt')).writeAsString('plain text');
      final sub = Directory(p.join(root.path, 'photos'))..createSync();
      await File(p.join(sub.path, 'a.jpg')).writeAsBytes(List.filled(64, 1));

      expect(await stillEncrypted(root, m), isFalse);
      expect(await stillEncrypted(sub, m), isFalse);
    });

    test('空目录 → 不加密', () async {
      final c = cfg();
      final m = mountFor(root, c);
      final empty = Directory(p.join(root.path, 'empty'))..createSync();

      expect(await stillEncrypted(empty, m), isFalse);
    });

    test('目录不存在 → 不加密', () async {
      final c = cfg();
      final m = mountFor(root, c);

      expect(await stillEncrypted(Directory(p.join(root.path, 'nope')), m), isFalse);
    });

    test('目录名不加密的配置（directoryNameEncryption=false）→ 退回内容判定', () async {
      // 该配置下磁盘上目录名永远是明文，名字级信号失效：只能看目录内有没有密文，
      // 否则用户往真·加密目录里粘贴会得到未加密的明文文件。
      final c = RcloneCryptConfig(
        password: 'master-pw',
        salt: 'master-salt',
        filenameEncryption: FilenameEncryption.standard,
        directoryNameEncryption: false,
        filenameEncoding: FilenameEncoding.base64,
        encryptedSuffix: '.bin',
      );
      final m = mountFor(root, c);
      final ops = CryptOperations(m);

      final plainOnly = Directory(p.join(root.path, 'plainDir'))..createSync();
      await File(p.join(plainOnly.path, 'a.txt')).writeAsString('plain');
      expect(await stillEncrypted(plainOnly, m), isFalse, reason: '无密文 → 非加密');

      final secret = File(p.join(root.path, 'only.mp4'));
      await secret.writeAsBytes(List.filled(4096, 7));
      await ops.encryptFile(secret.path);
      expect(await stillEncrypted(root, m), isTrue,
          reason: '名字不加密的配置下无法从名字区分，只能保守按加密目录处理');
    });
  });
}
