import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:zenfile/services/crypt/crypt_config.dart';
import 'package:zenfile/services/crypt/crypt_mount.dart';
import 'package:zenfile/services/crypt/crypt_operations.dart';

/// `CryptOperations.isCipherFileName` 的回归（「本地已加密文件直传」的判据）。
///
/// 用途：往关联的远程加密目录里写文件时，判断源文件**是不是已经是一份本挂载点
/// 能直接读的密文**——是则内容原字节直传、不再二次加密；否则按常规加密。
void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('crypt_cipher_name_');
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  RcloneCryptConfig cfg({
    String password = 'master-pw',
    String? salt = 'master-salt',
    FilenameEncryption enc = FilenameEncryption.standard,
    String suffix = '.bin',
  }) =>
      RcloneCryptConfig(
        password: password,
        salt: salt,
        filenameEncryption: enc,
        directoryNameEncryption: true,
        filenameEncoding: FilenameEncoding.base64,
        encryptedSuffix: suffix,
      );

  CryptMountPoint mountFor(RcloneCryptConfig c) =>
      CryptMountPoint(physicalPath: root.path, config: c, name: p.basename(root.path));

  group('isCipherFileName（密文文件名判定）', () {
    test('同一配置产生的密文名 → true，且能往返解回真实名', () {
      final c = cfg();
      final m = mountFor(c);

      final enc = m.crypt.encryptFileName('photo.jpg');
      expect(enc, isNot('photo.jpg'));
      expect(CryptOperations.isCipherFileName(enc, m), isTrue);
      expect(m.crypt.decryptFileName(enc), 'photo.jpg');
    });

    test('明文名一律 false（普通目录名 / 常见文件名 / 中文名）', () {
      final m = mountFor(cfg());
      for (final name in [
        'photo.jpg',
        'video.mp4',
        'DCIM',
        'Download',
        'IMG_20260101_120000.jpg',
        '我的文档.pdf',
        'README',
      ]) {
        expect(CryptOperations.isCipherFileName(name, m), isFalse,
            reason: '「$name」不该被判成密文名');
      }
    });

    test('空名 / . / .. → false（绝不参与判定）', () {
      final m = mountFor(cfg());
      expect(CryptOperations.isCipherFileName('', m), isFalse);
      expect(CryptOperations.isCipherFileName('.', m), isFalse);
      expect(CryptOperations.isCipherFileName('..', m), isFalse);
    });

    test('只是「普通名 + 加密后缀」不算密文名（photo.jpg.bin）', () {
      final m = mountFor(cfg());
      // 去后缀后的 `photo.jpg` 解不出合法明文（或往返对不上）→ 必须 false，
      // 否则普通文件会被当成密文直传、读出来是乱码。
      expect(CryptOperations.isCipherFileName('photo.jpg.bin', m), isFalse);
      expect(CryptOperations.isCipherFileName('report.xlsx.bin', m), isFalse);
    });

    test('别的密码/盐产生的密文名 → false（避免把别人的密文直传进来）', () {
      final other = mountFor(cfg(password: 'other-pw', salt: 'other-salt'));
      final encByOther = other.crypt.encryptFileName('photo.jpg');

      final m = mountFor(cfg());
      expect(CryptOperations.isCipherFileName(encByOther, m), isFalse);
      // 换回自己的配置则命中，确认上面的 false 来自「钥匙不同」而不是实现问题
      expect(CryptOperations.isCipherFileName(encByOther, other), isTrue);
    });

    test('filenameEncryption=off → 名字级信号失效，一律 false', () {
      final c = cfg(enc: FilenameEncryption.off);
      final m = mountFor(c);
      // off 时 encryptFileName 原样返回，名字不参与加密 → 不能据此判密文
      expect(CryptOperations.isCipherFileName('photo.jpg', m), isFalse);
      expect(m.crypt.encryptFileName('photo.jpg'), 'photo.jpg');
    });

    test('obfuscate 模式同样支持（往返校验，不是只认 base32/base64）', () {
      final c = cfg(enc: FilenameEncryption.obfuscate);
      final m = mountFor(c);
      final enc = m.crypt.encryptFileName('photo.jpg');
      expect(CryptOperations.isCipherFileName(enc, m), isTrue);
      expect(CryptOperations.isCipherFileName('photo.jpg', m), isFalse);
    });

    test('encryptedSuffix 为空时也成立（rclone 允许空后缀）', () {
      final c = cfg(suffix: '');
      final m = mountFor(c);
      final enc = m.crypt.encryptFileName('photo.jpg');
      expect(CryptOperations.isCipherFileName(enc, m), isTrue);
    });

    test('与 isCipherDirName 不混用：文件名的密文当目录名要能识别，反之亦然', () {
      final m = mountFor(cfg());
      final encFile = m.crypt.encryptFileName('photo.jpg');
      final encDir = m.crypt.encryptDirName('Secret');

      // 目录名不带后缀，用文件判定会因后缀不匹配而「看似成立」——这里只要求
      // 各自通道自洽：文件名判文件为真、判普通目录名为假；目录名判目录为真。
      expect(CryptOperations.isCipherFileName(encFile, m), isTrue);
      expect(CryptOperations.isCipherDirName(encDir, m), isTrue);
      expect(CryptOperations.isCipherFileName('Secret', m), isFalse);
      expect(CryptOperations.isCipherDirName('photo.jpg', m), isFalse);
    });
  });
}
