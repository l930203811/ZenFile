import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zenfile/services/crypt/crypt_operations.dart';
import 'package:zenfile/services/crypt/crypt_mount.dart';
import 'package:zenfile/services/crypt/crypt_mount_service.dart';
import 'package:zenfile/services/crypt/crypt_config.dart';

/// 原地加密「加密 → 浏览显示 → 进入子目录 → 打开」全链路回归。
///
/// 覆盖历史缺陷：根目录下的原地加密在浏览页显示密文名、点进文件夹一片空白、
/// 音频/视频/图片统统打不开。根因是加密目录在磁盘上的名字是密文，
/// 浏览页拿到的却是虚拟（解密后）路径，若拿不到挂载点就无法还原真实路径。
///
/// 另覆盖「整体原地加密、但目录名保持明文」的容器目录（目标目录恰好是挂载点根）
/// 及其登记表：这类目录与「普通文件夹夹带零星密文」磁盘特征一样，只能靠
/// `CryptMountService` 的容器登记区分（方案 B）。
void main() {
  late Directory root;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    root = await Directory.systemTemp.createTemp('inplace_');
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  RcloneCryptConfig cfg({
    String suffix = '.bin',
    FilenameEncoding enc = FilenameEncoding.base64,
  }) =>
      RcloneCryptConfig(
        password: 'master-pw',
        salt: 'master-salt',
        filenameEncryption: FilenameEncryption.standard,
        directoryNameEncryption: true,
        filenameEncoding: enc,
        encryptedSuffix: suffix,
      );

  CryptMountPoint mountFor(String dir, RcloneCryptConfig c) =>
      CryptMountPoint(physicalPath: dir, config: c, name: p.basename(dir));

  group('加密 → 枚举（显示原文件名）', () {
    test('单个文件', () async {
      final c = cfg();
      final m = mountFor(root.path, c);
      final ops = CryptOperations(m);

      final src = File(p.join(root.path, 'hello.mp4'));
      await src.writeAsBytes(List.filled(5000, 7));
      final encName = p.basename(await ops.encryptFile(src.path));

      expect(CryptOperations.mayBeCipherName(encName, c), isTrue);
      expect(await CryptOperations.dirContainsCiphertext(root.path, config: c), isTrue);

      final entries = await CryptDirectoryLister(m).listDirectory(root.path);
      expect(entries.map((e) => e.name), contains('hello.mp4'));
      expect(entries.single.isEncrypted, isTrue);
    });

    test('整个目录', () async {
      final c = cfg();
      final m = mountFor(root.path, c);
      final ops = CryptOperations(m);

      final sub = Directory(p.join(root.path, 'MyFolder'))..createSync();
      await File(p.join(sub.path, 'a.txt')).writeAsBytes(List.filled(3000, 3));
      await ops.encryptDirectory(sub.path);

      expect(await CryptOperations.dirContainsCiphertext(root.path, config: c), isTrue);
      final entries = await CryptDirectoryLister(m).listDirectory(root.path);
      expect(entries.map((e) => e.name), contains('MyFolder'));
    });

    test('base32 编码', () async {
      final c = cfg(enc: FilenameEncoding.base32);
      final m = mountFor(root.path, c);
      final ops = CryptOperations(m);
      final src = File(p.join(root.path, 'song.mp3'));
      await src.writeAsBytes(List.filled(6000, 5));
      final encName = p.basename(await ops.encryptFile(src.path));
      expect(CryptOperations.mayBeCipherName(encName, c), isTrue);
      final entries = await CryptDirectoryLister(m).listDirectory(root.path);
      expect(entries.map((e) => e.name), contains('song.mp3'));
    });

    test('空后缀（OpenList 风格）', () async {
      final c = cfg(suffix: '');
      final m = mountFor(root.path, c);
      final ops = CryptOperations(m);
      final src = File(p.join(root.path, 'clip.mov'));
      await src.writeAsBytes(List.filled(4000, 2));
      await ops.encryptFile(src.path);
      final entries = await CryptDirectoryLister(m).listDirectory(root.path);
      expect(entries.map((e) => e.name), contains('clip.mov'));
    });

    test('混合内容：只解密密文、明文原样保留', () async {
      final c = cfg();
      final m = mountFor(root.path, c);
      final ops = CryptOperations(m);

      await Directory(p.join(root.path, 'DCIM')).create();

      final src = File(p.join(root.path, 'secret.png'));
      await src.writeAsBytes(List.filled(4000, 9));
      await ops.encryptFile(src.path);

      final entries = await CryptDirectoryLister(m).listDirectory(root.path);
      final byName = {for (final e in entries) e.name: e};
      expect(byName.containsKey('secret.png'), isTrue);
      expect(byName.containsKey('DCIM'), isTrue);
      // 明文目录不应被标记为加密
      expect(byName['DCIM']!.isEncrypted, isFalse);
      expect(byName['secret.png']!.isEncrypted, isTrue);
    });
  });

  group('进入加密子目录（虚拟路径 → 真实路径）', () {
    test('挂载点在父目录时，可枚举加密后的子目录内容', () async {
      final c = cfg();
      final m = mountFor(root.path, c);
      final ops = CryptOperations(m);

      final sub = Directory(p.join(root.path, 'Vault'))..createSync();
      await File(p.join(sub.path, 'movie.mp4')).writeAsBytes(List.filled(9000, 1));
      await File(p.join(sub.path, 'note.txt')).writeAsBytes(List.filled(900, 2));
      await ops.encryptDirectory(sub.path);

      // 磁盘上已不存在明文目录名
      expect(Directory(p.join(root.path, 'Vault')).existsSync(), isFalse);

      // 用虚拟路径枚举 —— 这正是浏览页点击文件夹时的入参
      final inner = await CryptDirectoryLister(m)
          .listDirectory(p.join(root.path, 'Vault'));
      final names = inner.map((e) => e.name).toList()..sort();
      expect(names, ['movie.mp4', 'note.txt']);
      // physicalPath 必须指向磁盘上真实存在的密文文件
      for (final e in inner) {
        expect(File(e.physicalPath).existsSync(), isTrue);
      }
    });

    test('resolvePhysicalPath 能把虚拟文件还原成磁盘上的密文文件', () async {
      final c = cfg();
      final m = mountFor(root.path, c);
      final ops = CryptOperations(m);

      final sub = Directory(p.join(root.path, 'Vault'))..createSync();
      final f = File(p.join(sub.path, 'track.flac'));
      await f.writeAsBytes(List.filled(7000, 4));
      await ops.encryptDirectory(sub.path);

      final virtual = p.join(root.path, 'Vault', 'track.flac');
      final physical = await m.resolvePhysicalPath(virtual);
      expect(File(physical).existsSync(), isTrue);
      expect(await CryptOperations.isEncryptedFile(physical), isTrue);
      expect(m.crypt.decryptFileName(p.basename(physical)), 'track.flac');
    });

    test('三层嵌套目录', () async {
      final c = cfg();
      final m = mountFor(root.path, c);
      final ops = CryptOperations(m);

      final deep = Directory(p.join(root.path, 'A', 'B', 'C'))..createSync(recursive: true);
      await File(p.join(deep.path, 'deep.bin')).writeAsBytes(List.filled(2000, 6));
      await ops.encryptDirectory(p.join(root.path, 'A'));

      final level1 = await CryptDirectoryLister(m)
          .listDirectory(p.join(root.path, 'A'));
      expect(level1.map((e) => e.name), contains('B'));

      final level2 = await CryptDirectoryLister(m)
          .listDirectory(p.join(root.path, 'A', 'B'));
      expect(level2.map((e) => e.name), contains('C'));

      final level3 = await CryptDirectoryLister(m)
          .listDirectory(p.join(root.path, 'A', 'B', 'C'));
      expect(level3.map((e) => e.name), contains('deep.bin'));
    });
  });

  group('原地加密文件夹：目录名与容器登记', () {
    test('挂载点根是父目录（普通路径）→ 文件夹名一并变密文，不写容器登记', () async {
      final c = cfg();
      final m = mountFor(root.path, c);

      final sub = Directory(p.join(root.path, 'Secret'))..createSync();
      await File(p.join(sub.path, 'a.txt')).writeAsBytes(List.filled(3000, 3));

      await CryptOperations(m).encryptDirectory(sub.path);

      expect(Directory(p.join(root.path, 'Secret')).existsSync(), isFalse,
          reason: 'encryptDirectory 末尾会把目录名一并换成密文名');
      final left = await root.list().toList();
      expect(left.length, 1);
      expect(
        CryptOperations.isCipherDirName(p.basename(left.single.path), m),
        isTrue,
      );
      expect(await CryptMountService.isInPlaceContainerDir(sub.path), isFalse,
          reason: '目录名已加密 → 名字级判据够用，不需要容器登记');
    });

    test('挂载点根就是该文件夹自身（先加密过它里面的文件）→ 名字明文 + 写入容器登记', () async {
      final c = cfg();
      final folder = Directory(p.join(root.path, 'Secret'))..createSync();
      await File(p.join(folder.path, 'a.txt')).writeAsBytes(List.filled(3000, 3));

      // 触发路径：encryptInPlace 把挂载点建在被加密条目的**父目录**上，
      // 所以先对「Secret/a.txt」做过一次原地加密后，挂载点就登记在 Secret 自身。
      final m = CryptMountPoint(
        physicalPath: folder.path,
        config: c,
        name: 'Secret',
      );

      await CryptOperations(m).encryptDirectory(folder.path);

      expect(Directory(folder.path).existsSync(), isTrue,
          reason: '目标目录 == 挂载点根 → 跳过改名（改名会让挂载点 containsPath 失配）');
      final children = await folder.list().toList();
      expect(children.length, 1);
      expect(p.basename(children.single.path), isNot('a.txt'),
          reason: '内部文件仍会被加密改名');
      expect(await CryptOperations.isEncryptedFile(children.single.path), isTrue);

      // 方案 B：加密时写入容器登记 → 判据继续把它当加密目录，
      // 之后往这个文件夹里复制/剪切的新文件仍会被自动加密。
      expect(await CryptMountService.isInPlaceContainerDir(folder.path), isTrue,
          reason: 'encryptDirectory 命中挂载点根守卫时应自动登记');
      expect(
        await CryptOperations.isDirectoryStillEncrypted(folder.path, mount: m),
        isTrue,
      );
      expect(await m.resolvePhysicalPath(folder.path), folder.path,
          reason: '「是否解析回自身」无法区分该形态与普通目录 → 只能靠登记表');
    });

    test('容器目录整体解密后 → 登记注销，判据回到非加密', () async {
      final c = cfg();
      final folder = Directory(p.join(root.path, 'Secret'))..createSync();
      await File(p.join(folder.path, 'a.txt')).writeAsBytes(List.filled(3000, 3));
      final m = CryptMountPoint(
        physicalPath: folder.path,
        config: c,
        name: 'Secret',
      );
      final ops = CryptOperations(m);
      await ops.encryptDirectory(folder.path);
      expect(await CryptMountService.isInPlaceContainerDir(folder.path), isTrue,
          reason: '前置：已登记');

      await ops.decryptDirectory(folder.path);

      expect(File(p.join(folder.path, 'a.txt')).existsSync(), isTrue,
          reason: '前置：内容已解密回明文名');
      expect(await CryptMountService.isInPlaceContainerDir(folder.path), isFalse,
          reason: 'decryptDirectory 末尾应注销登记');
      expect(
        await CryptOperations.isDirectoryStillEncrypted(folder.path, mount: m),
        isFalse,
        reason: '解密后不得继续自动加密新文件',
      );
    });

    test('登记残留但目录内已无密文 → 仍判非加密', () async {
      final c = cfg();
      final m = mountFor(root.path, c);
      final plain = Directory(p.join(root.path, 'Plain'))..createSync();
      await File(p.join(plain.path, 'a.txt')).writeAsString('plain');
      await CryptMountService.addInPlaceContainerDir(plain.path);

      expect(
        await CryptOperations.isDirectoryStillEncrypted(plain.path, mount: m),
        isFalse,
        reason: '登记必须与「目录内确有密文」同时成立，否则解密/清空后会误判',
      );
    });

    test('普通文件夹里夹带一个密文文件（未登记）→ 判非加密（用户反馈的静默加密回归）', () async {
      final c = cfg();
      final m = mountFor(root.path, c);
      final ops = CryptOperations(m);
      await File(p.join(root.path, 'plain.txt')).writeAsString('plain');
      final secret = File(p.join(root.path, 'secret.mp4'));
      await secret.writeAsBytes(List.filled(4096, 3));
      await ops.encryptFile(secret.path);

      expect(await CryptMountService.isInPlaceContainerDir(root.path), isFalse);
      expect(
        await CryptOperations.isDirectoryStillEncrypted(root.path, mount: m),
        isFalse,
        reason: '「目录里有密文」≠「目录被加密」，不能靠登记表以外的东西兜底',
      );
    });

    test('容器内的子目录不因父目录被登记而算加密', () async {
      final c = cfg();
      final m = mountFor(root.path, c);
      final parent = Directory(p.join(root.path, 'Container'))..createSync();
      await CryptMountService.addInPlaceContainerDir(parent.path);
      final child = Directory(p.join(parent.path, 'sub'))..createSync();
      await File(p.join(child.path, 'x.txt')).writeAsString('plain');

      expect(
        await CryptOperations.isDirectoryStillEncrypted(child.path, mount: m),
        isFalse,
        reason: '登记只对自身生效：容器内已解密的子目录必须继续按明文处理',
      );
    });

    test('容器根内粘贴的新文件：按 encryptFileName 落盘，且浏览层能解析回来', () async {
      final c = cfg();
      final folder = Directory(p.join(root.path, 'Secret'))..createSync();
      await File(p.join(folder.path, 'a.txt')).writeAsBytes(List.filled(3000, 3));
      final m = CryptMountPoint(
        physicalPath: folder.path,
        config: c,
        name: 'Secret',
      );
      final ops = CryptOperations(m);
      await ops.encryptDirectory(folder.path);

      // 模拟粘贴：明文文件 → 容器根，落盘名 = encryptFileName(...)
      // （与 `FileManagerProvider._cryptAwareTransferFile` 的「明文 → 密文」分支一致）
      final src = File(p.join(root.path, 'incoming.txt'));
      await src.writeAsBytes(List.filled(1500, 9));
      final encName = m.crypt.encryptFileName('incoming.txt');
      await ops.encryptFileTo(src.path, p.join(folder.path, encName));

      expect(File(p.join(folder.path, 'incoming.txt')).existsSync(), isFalse,
          reason: '不得在加密容器里留下明文文件');
      final onDisk = File(p.join(folder.path, encName));
      expect(onDisk.existsSync(), isTrue);
      expect(await CryptOperations.isEncryptedFile(onDisk.path), isTrue);

      // 浏览层拿到的是虚拟路径 → 必须命中刚落的密文文件，并能枚举出解密名
      expect(
        await m.resolvePhysicalPath(p.join(folder.path, 'incoming.txt')),
        onDisk.path,
      );
      final entries = await CryptDirectoryLister(m).listDirectory(folder.path);
      expect(entries.map((e) => e.name), contains('incoming.txt'));
    });
  });

  group('加密目录登记表（CryptMountService）', () {
    test('normalizePosix 折叠斜杠并去掉尾部斜杠', () {
      expect(CryptMountService.normalizePosix('/storage/emulated/0/'),
          '/storage/emulated/0');
      expect(CryptMountService.normalizePosix('//storage//emulated//0'),
          '/storage/emulated/0');
      expect(CryptMountService.normalizePosix('D:\\\\a\\\\b'), 'D:/a/b');
    });

    test('isStorageRootPath 识别根别名、放过普通目录', () {
      for (final r in const [
        '/storage/emulated/0',
        '/storage/emulated/0/',
        '/storage/emulated',
        '/storage',
        '/sdcard',
        '/',
      ]) {
        expect(CryptMountService.isStorageRootPath(r), isTrue, reason: r);
      }
      for (final d in const [
        '/storage/emulated/0/DCIM',
        '/storage/emulated/0/Download',
        '/storage/emulated/10',
        '',
      ]) {
        expect(CryptMountService.isStorageRootPath(d), isFalse, reason: d);
      }
    });
  });
}
