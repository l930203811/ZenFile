import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:zenfile/services/crypt/crypt_config.dart';
import 'package:zenfile/services/crypt/crypt_file.dart';
import 'package:zenfile/services/crypt/crypt_mount.dart';
import 'package:zenfile/services/crypt/crypt_operations.dart';

/// 「本地已加密文件写进关联的远程加密目录时**不二次加密**」的端到端契约。
///
/// 场景：保险箱把某个远程目录关联为加密目录后，从**本地原地加密目录**
/// （或之前从该远程目录下载下来的密文）复制文件进去 —— 这些内容本来就是同一把
/// 钥匙产生的密文，再加密一次会让服务端存下「密文的密文」，客户端读回来拿到的
/// 仍是密文（用户看到的是乱码文件）。
///
/// 直传的两个前提（缺一不可），本测试逐条锁定：
/// 1. 磁盘名是**当前远程挂载点配置下的密文名**（往返校验 ⇒ 同一把钥匙）；
/// 2. 内容是带 rclone magic 的真实密文。
///
/// 以及「前提不满足时必须无损回退」：用别的密码产生的密文走常规链路重新加密后，
/// 用远程钥匙解出来应当**恰好是用户原来那份密文文件**（再解一层就拿回明文）。
void main() {
  late Directory root;
  late Directory localDir;
  late Directory remoteDir;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('crypt_pass_through_');
    localDir = await Directory(p.join(root.path, 'local')).create(recursive: true);
    remoteDir = await Directory(p.join(root.path, 'remote')).create(recursive: true);
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  RcloneCryptConfig cfg({
    String password = 'master-pw',
    String salt = 'master-salt',
  }) =>
      RcloneCryptConfig(
        password: password,
        salt: salt,
        filenameEncryption: FilenameEncryption.standard,
        directoryNameEncryption: true,
        filenameEncoding: FilenameEncoding.base64,
        encryptedSuffix: '.bin',
      );

  CryptMountPoint mountAt(Directory dir, RcloneCryptConfig c) =>
      CryptMountPoint(physicalPath: dir.path, config: c, name: p.basename(dir.path));

  List<int> payload(int size) =>
      List<int>.generate(size, (i) => (i * 37 + 11) & 0xff);

  /// 模拟「原地加密」：把明文写成一份 crypt 密文文件，返回落盘文件。
  Future<File> writeCipher(
    Directory dir,
    CryptMountPoint mount,
    String plainName,
    List<int> plainBytes,
  ) async {
    final encName = mount.crypt.encryptFileName(plainName);
    final f = File(p.join(dir.path, encName));
    final cf = await CryptFile.open(f.path, mount.crypt, mode: CryptFileMode.write);
    await cf.write(0, plainBytes);
    await cf.close();
    return f;
  }

  /// 按 [mount] 解密读取整个文件（模拟「远程客户端解密」）。
  Future<List<int>> readPlain(CryptMountPoint mount, String cipherPath) async {
    final cf = await CryptFile.open(cipherPath, mount.crypt);
    final out = <int>[];
    var pos = 0;
    while (pos < cf.length) {
      final chunk = await cf.read(pos, cf.length - pos);
      if (chunk.isEmpty) break;
      out.addAll(chunk);
      pos += chunk.length;
    }
    await cf.close();
    return out;
  }

  group('同一把钥匙：密文直传后仍然可读', () {
    test('磁盘名能往返解回真实名 → 服务端名与磁盘名逐字节相同', () async {
      final local = mountAt(localDir, cfg());
      final remote = mountAt(remoteDir, cfg());

      final cipher = await writeCipher(localDir, local, 'photo.jpg', payload(4096));
      final diskName = p.basename(cipher.path);

      expect(CryptOperations.isCipherFileName(diskName, remote), isTrue);
      // 上传时「真实名 → 重新加密」必须得到原密文名，否则直传会把名字换掉。
      final plain = remote.crypt.decryptFileName(diskName);
      expect(plain, 'photo.jpg');
      expect(remote.crypt.encryptFileName(plain), diskName);
    });

    test('内容按原字节直传后，用远程钥匙解出来就是原文', () async {
      final local = mountAt(localDir, cfg());
      final remote = mountAt(remoteDir, cfg());

      final bytes = payload(200 * 1024);
      final cipher = await writeCipher(localDir, local, 'video.mp4', bytes);

      // 直传 = 不碰内容（服务端拿到的就是这份文件）。
      expect(await readPlain(remote, cipher.path), bytes);
      // 且它确实是密文，不是碰巧能读的明文。
      expect(await CryptOperations.isEncryptedFile(cipher.path), isTrue);
    });

    test('原地加密目录：目录名与子项都保持密文名（可逐条直传）', () async {
      final local = mountAt(localDir, cfg());
      final remote = mountAt(remoteDir, cfg());

      final encDir =
          Directory(p.join(localDir.path, local.crypt.encryptDirName('Secret')));
      await encDir.create();
      await writeCipher(encDir, local, 'a.txt', payload(100));
      await writeCipher(encDir, local, 'b.txt', payload(200));

      // 目录名：用远程配置判也是密文目录名 → 目录名原样保留
      final dirName = p.basename(encDir.path);
      expect(CryptOperations.isCipherDirName(dirName, remote), isTrue);
      expect(remote.crypt.encryptDirName(remote.crypt.decryptDirName(dirName)), dirName);

      // 子项：逐个都是可直传的密文，且内容读得回来
      final files = encDir.listSync().whereType<File>().toList();
      expect(files.length, 2);
      for (final e in files) {
        expect(CryptOperations.isCipherFileName(p.basename(e.path), remote), isTrue);
        expect(await CryptOperations.isEncryptedFile(e.path), isTrue);
      }
      final aCipher = files.firstWhere(
        (e) => remote.crypt.decryptFileName(p.basename(e.path)) == 'a.txt',
      );
      expect(await readPlain(remote, aCipher.path), payload(100));
    });
  });

  group('钥匙不同：不得直传，且常规链路必须无损', () {
    test('别的密码产生的密文名 → 判定为 false（不会误直传）', () async {
      final other = mountAt(localDir, cfg(password: 'other-pw', salt: 'other-salt'));
      final remote = mountAt(remoteDir, cfg());

      final cipher = await writeCipher(localDir, other, 'photo.jpg', payload(512));
      expect(CryptOperations.isCipherFileName(p.basename(cipher.path), remote), isFalse);
      // 内容判定仍为真密文 —— 说明「不直传」是名字级（钥匙不同）决定的
      expect(await CryptOperations.isEncryptedFile(cipher.path), isTrue);
    });

    test('回退「重新加密」对任意字节流无损：解出来正是原来那份密文', () async {
      final other = mountAt(localDir, cfg(password: 'other-pw', salt: 'other-salt'));
      final remote = mountAt(remoteDir, cfg());

      final originalPlain = payload(3000);
      final cipher = await writeCipher(localDir, other, 'photo.jpg', originalPlain);
      final originalCipherBytes = await cipher.readAsBytes();

      // 常规链路：把这份密文当普通文件再加密一次（无损包装）
      final wrapped =
          await writeCipher(remoteDir, remote, 'photo.jpg', originalCipherBytes);

      expect(
        await readPlain(remote, wrapped.path),
        originalCipherBytes,
        reason: '外层解出来必须是用户原来那份密文文件',
      );
      // 再用原密码解那层内层密文，仍然拿回最初的明文 —— 两级都在，用户不丢数据
      expect(await readPlain(other, cipher.path), originalPlain);
    });
  });
}
