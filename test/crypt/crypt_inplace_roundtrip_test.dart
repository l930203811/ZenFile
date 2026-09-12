import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:zenfile/services/crypt/crypt_operations.dart';
import 'package:zenfile/services/crypt/crypt_mount.dart';
import 'package:zenfile/services/crypt/crypt_mount_service.dart';
import 'package:zenfile/services/crypt/crypt_config.dart';

/// 原地加密「加密 → 浏览显示 → 进入子目录 → 打开」全链路回归。
///
/// 覆盖历史缺陷：根目录下的原地加密在浏览页显示密文名、点进文件夹一片空白、
/// 音频/视频/图片统统打不开。根因是加密目录在磁盘上的名字是密文，
/// 浏览页拿到的却是虚拟（解密后）路径，若拿不到挂载点就无法还原真实路径。
void main() {
  late Directory root;

  setUp(() async {
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
