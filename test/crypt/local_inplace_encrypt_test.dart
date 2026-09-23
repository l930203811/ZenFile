import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zenfile/services/crypt/crypt_config.dart';
import 'package:zenfile/services/crypt/crypt_mount.dart';
import 'package:zenfile/services/crypt/crypt_mount_service.dart';
import 'package:zenfile/services/crypt/crypt_operations.dart';
import 'package:zenfile/services/crypt/rclone_crypt.dart';
import 'package:zenfile/services/crypt/vault_crypt_service.dart';

/// **本地**（非远程）原地加密文件夹的回归。
///
/// 用户反馈：「原地加密的文件夹解密后再次原地加密该文件夹，该文件夹不会被加密，
/// 名字显示明文，不过文件夹内的文件倒是可以正常加密。」
///
/// 根因不在于加解密本身，而在于**挂载点的根正好落在目标文件夹自己身上**：
/// `VaultCryptService.encryptInPlace` 把挂载点建在被加密条目的**父目录**上，
/// 所以「此前对这个文件夹**里面的**某个文件/子文件夹做过原地加密」这一步，
/// 就已经把挂载点登记到了这个文件夹自身；之后再对**这个文件夹**加密时，
/// `CryptOperations.encryptDirectory` 会命中末尾那条守卫 ——
/// 「目标目录 == 挂载点 physicalPath → 跳过给目录改名」（守卫的初衷是保护
/// 存储根级别的挂载点：根被改名后 `containsPath` 失配）。于是只加密子项、
/// 目录名保持明文，与用户描述完全一致。
///
/// 这里钉住的不变式：**只要父目录不是存储根，对文件夹原地加密后它的名字必须变成密文**
/// （无论此前挂载点落在哪里），并且父目录仍被登记为「原地加密目录」，
/// 供浏览层按需临时挂载。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root; // 充当「父目录」（代替 /storage/emulated/0/...）

  setUp(() async {
    SharedPreferences.setMockInitialValues({
      VaultCryptService.kMasterPasswordKey: 'master-pw',
      VaultCryptService.kMasterSaltKey: 'master-salt',
      VaultCryptService.kFilenameEncodingKey: 'base32',
      VaultCryptService.kEncryptedSuffixKey: '.bin',
    });
    FlutterSecureStorage.setMockInitialValues({});
    root = await Directory.systemTemp.createTemp('local_inplace_');
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  /// 与 `VaultCryptService._loadLegacyConfig()` 读出来的配置一致，
  /// 用于算出期望的密文名（EME 是确定性加密）。
  final crypt = RcloneCrypt(
    config: RcloneCryptConfig(
      password: 'master-pw',
      salt: 'master-salt',
      filenameEncryption: FilenameEncryption.standard,
      directoryNameEncryption: true,
      filenameEncoding: FilenameEncoding.base32,
      encryptedSuffix: '.bin',
    ),
  );

  Directory makeFolder(String name, {String? parent}) {
    final dir = Directory(p.join(parent ?? root.path, name))..createSync(recursive: true);
    return dir;
  }

  Future<List<String>> childNames(String dir) async =>
      (await Directory(dir).list().toList()).map((e) => p.basename(e.path)).toList();

  Future<bool> hasMountAt(String path) async {
    final mounts = await CryptMountService.loadMountPoints();
    return mounts.any(
      (m) => CryptMountService.normalizePosix(m.physicalPath) ==
          CryptMountService.normalizePosix(path),
    );
  }

  group('文件夹原地加密：目录名必须一并变密文', () {
    test('加密 → 解密 → 再加密：第二次仍要把目录名换成密文', () async {
      final folder = makeFolder('Secret');
      await File(p.join(folder.path, 'a.txt')).writeAsBytes(List.filled(3000, 3));
      final svc = VaultCryptService.instance;

      // ① 加密：目录名 → 密文
      await svc.encryptInPlace(sourcePath: folder.path);
      final cipherName = crypt.encryptDirName('Secret');
      expect(await Directory(folder.path).exists(), isFalse,
          reason: '第一次加密后磁盘上不应再有明文目录名');
      expect(await Directory(p.join(root.path, cipherName)).exists(), isTrue);

      // ② 解密：目录名还原（浏览层传来的是虚拟/明文路径）
      await svc.decryptInPlace(encryptedPath: folder.path);
      expect(await Directory(folder.path).exists(), isTrue,
          reason: '解密后目录名应还原为明文');
      expect(await File(p.join(folder.path, 'a.txt')).exists(), isTrue);

      // ③ 再加密：**这条以前会失败** —— 目录名保持明文、只有子项被加密
      await svc.encryptInPlace(sourcePath: folder.path);
      expect(await Directory(folder.path).exists(), isFalse,
          reason: '再次原地加密必须把目录名换成密文（用户反馈的 bug）');
      expect(await Directory(p.join(root.path, cipherName)).exists(), isTrue);
      expect(await childNames(p.join(root.path, cipherName)), isNot(contains('a.txt')),
          reason: '子项同样应为密文名');
    });

    test('文件夹里有条目先被原地加密过（挂载点落在文件夹自身）→ 加密该文件夹仍必须改名',
        () async {
      final folder = makeFolder('Docs');
      final inner = File(p.join(folder.path, 'note.txt'));
      await inner.writeAsBytes(List.filled(2500, 5));

      // 触发路径：先加密**文件夹里面**的文件 →
      // encryptInPlace 把挂载点建在它的父目录，也就是这个文件夹自己。
      await VaultCryptService.instance.encryptInPlace(sourcePath: inner.path);
      expect(await hasMountAt(folder.path), isTrue,
          reason: '前置：挂载点此时确实落在文件夹自身（守卫的触发条件）');

      // 现在加密这个文件夹本身
      await VaultCryptService.instance.encryptInPlace(sourcePath: folder.path);

      expect(await Directory(folder.path).exists(), isFalse,
          reason: '挂载点的根必须让位：目录名仍要变成密文');
      final cipherDir = Directory(p.join(root.path, crypt.encryptDirName('Docs')));
      expect(await cipherDir.exists(), isTrue);
      final names = await childNames(cipherDir.path);
      expect(names, isNot(contains('note.txt')));
      expect(CryptOperations.isCipherDirName(names.single,
          CryptMountPoint(physicalPath: root.path, config: crypt.config)),
          isTrue, reason: '子项也应为密文名');
    });

    test('改名后父目录仍被登记（浏览层据此临时挂载，不显示密文名）', () async {
      final folder = makeFolder('Vault2');
      await File(p.join(folder.path, 'x.txt')).writeAsBytes(List.filled(1200, 9));

      await VaultCryptService.instance.encryptInPlace(sourcePath: folder.path);

      final dirs = await CryptMountService.loadEncryptedDirs();
      expect(dirs.map(CryptMountService.normalizePosix), contains(
        CryptMountService.normalizePosix(root.path),
      ), reason: '父目录登记表是根目录/父目录下密文的唯一依托，改名后必须存在');
    });

    test('父目录已有挂载点时复用（不重复建、不误删）', () async {
      final parent = makeFolder('Shared');
      final folder = makeFolder('Sub', parent: parent.path);
      await File(p.join(folder.path, 'y.txt')).writeAsBytes(List.filled(1500, 4));

      // 父目录先有挂载点（模拟此前在父目录里加密过别的东西）
      await CryptMountService.addMountPoint(
        CryptMountPoint(physicalPath: parent.path, config: crypt.config, name: 'Shared'),
      );

      await VaultCryptService.instance.encryptInPlace(sourcePath: folder.path);

      expect(await Directory(folder.path).exists(), isFalse,
          reason: '父目录挂载点已覆盖 → 目录名正常变密文');
      expect(await hasMountAt(parent.path), isTrue, reason: '父目录挂载点必须保留');
    });

    test('目标目录里已解密的普通子目录不受影响', () async {
      final folder = makeFolder('Mixed');
      final plainSub = makeFolder('plainSub', parent: folder.path);
      await File(p.join(plainSub.path, 'k.txt')).writeAsString('plain');
      await File(p.join(folder.path, 'z.txt')).writeAsBytes(List.filled(800, 1));

      await VaultCryptService.instance.encryptInPlace(sourcePath: folder.path);

      final cipherDir = Directory(p.join(root.path, crypt.encryptDirName('Mixed')));
      expect(await cipherDir.exists(), isTrue);
      final names = await childNames(cipherDir.path);
      // 子目录名同样应已加密（rclone 语义：目录名不带后缀，走 encryptDirName）
      for (final n in names) {
        expect(n, isNot('plainSub'));
        expect(n, isNot('z.txt'));
      }
    });
  });
}
