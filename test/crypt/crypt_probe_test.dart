/// 「目录是否该按加密目录处理」的探测逻辑回归测试
///
/// 历史 bug（用户可见）：
/// 原地加密发生在**存储根目录**（`/storage/emulated/0`）下时，
/// `encryptInPlace` / `_resolveCryptMountForPath` 会把根目录**持久化**成 crypt 挂载点。
/// 根挂载点的 `containsPath` 会命中全盘所有路径 → 整个存储被当成加密目录
/// （浏览页所有文件夹上锁、进入后内容空白），因此浏览层/解密层都明确忽略它。
/// 但忽略之后，根目录下的密文又只能显示成密文名
/// （用户反馈：「导入原地加密，浏览页看到的仍然是加密后的文件」）。
///
/// 修复思路：根挂载点继续保持禁止，改为**按需探测** ——
/// 只有当目录内**确实**存在 rclone crypt 密文时才临时挂载该目录。
/// 本文件覆盖该探测逻辑的关键点：
///   1. `mayBeCipherName`：零 I/O 的名字级预筛，必须放过密文名、滤掉普通名；
///   2. `isEncryptedFile`：文件头 RCLONE magic 二次确认；
///   3. `dirContainsCiphertext`：目录级探测（含「普通目录必须返回 false」的反例）；
///   4. `CryptMountService.isStorageRootPath`：根路径判定必须覆盖 /sdcard 等别名。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:zenfile/services/crypt/crypt_config.dart';
import 'package:zenfile/services/crypt/crypt_mount.dart';
import 'package:zenfile/services/crypt/crypt_mount_service.dart';
import 'package:zenfile/services/crypt/crypt_operations.dart';
import 'package:zenfile/services/crypt/rclone_crypt.dart';

/// 构造一个指向 [dir] 的挂载点（仅内存，不落盘），供 CryptOperations 使用。
CryptMountPoint mountFor(String dir, RcloneCryptConfig config) =>
    CryptMountPoint(physicalPath: dir, config: config);

const _probeConfig = RcloneCryptConfig(
  password: 'test-password',
  salt: 'test-salt',
  filenameEncoding: FilenameEncoding.base64,
  encryptedSuffix: '.bin',
);

void main() {
  group('CryptOperations.mayBeCipherName（名字级预筛）', () {
    const base64Cfg = RcloneCryptConfig(
      password: 'pw',
      filenameEncoding: FilenameEncoding.base64,
      encryptedSuffix: '.bin',
    );
    const base32Cfg = RcloneCryptConfig(
      password: 'pw',
      filenameEncoding: FilenameEncoding.base32,
      encryptedSuffix: '.bin',
    );

    test('真实密文名（base64 + .bin）应被识别', () {
      // 用户实测截图里的真实文件名：22 字符 = 16 字节明文（PKCS7 补齐后）的
      // base64（无 padding）长度。更长的名字由下方「真实加密器往返」用例覆盖。
      for (final name in const [
        '2RtBBUF27I3AgLFkQvhQHg.bin',
        'AGOXYI_qStS2qsRKEEBDXQ.bin',
      ]) {
        expect(
          CryptOperations.mayBeCipherName(name, base64Cfg),
          isTrue,
          reason: '$name 应被识别为密文名',
        );
      }
    });

    test('普通文件名/目录名必须被滤掉（否则整目录会被误判为加密目录）', () {
      // 这些都是存储根目录下真实存在的常见条目 —— 一旦误判，
      // 整个存储会被卷进加密视图（历史事故：所有文件夹上锁、进入后空白）。
      for (final name in const [
        'DCIM',
        'Download',
        'Android',
        'Pictures',
        'Music',
        'Documents',
        'ZenFile',
        'IMG_20260101.jpg',
        'video.mp4',
        'com.tencent.mm',
        'rclone.conf',
      ]) {
        expect(
          CryptOperations.mayBeCipherName(name, base64Cfg),
          isFalse,
          reason: '不应把普通名字 $name 当成密文（base64）',
        );
        expect(
          CryptOperations.mayBeCipherName(name, base32Cfg),
          isFalse,
          reason: '不应把普通名字 $name 当成密文（base32）',
        );
      }
    });

    test('加解密中途的临时残留文件不应被当成密文', () {
      expect(
        CryptOperations.mayBeCipherName(
          '2RtBBUF27I3AgLFkQvhQHg.bin.zencrypt_tmp',
          base64Cfg,
        ),
        isFalse,
      );
    });

    test('通过真实加密器的往返：密文名命中、明文名不命中', () {
      for (final enc in FilenameEncoding.values) {
        final config = RcloneCryptConfig(
          password: 'test-password',
          salt: 'test-salt',
          filenameEncoding: enc,
          encryptedSuffix: '.bin',
        );
        final crypt = RcloneCrypt(config: config);
        const plain = '我的照片.jpg';
        final encrypted = crypt.encryptFileName(plain);

        expect(
          CryptOperations.mayBeCipherName(encrypted, config),
          isTrue,
          reason: '$enc：真实密文名应被识别（$encrypted）',
        );
        expect(
          CryptOperations.mayBeCipherName(plain, config),
          isFalse,
          reason: '$enc：明文名不应被识别',
        );
      }
    });
  });

  group('CryptOperations.isEncryptedFile（magic 二次确认）', () {
    late Directory tmp;
    setUp(() => tmp = Directory.systemTemp.createTempSync('zenfile_probe_'));
    tearDown(() {
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });

    test('真实加密文件应被识别', () async {
      final src = File(p.join(tmp.path, 'plain.txt'));
      await src.writeAsString('hello zenfile');
      final encryptedPath =
          await CryptOperations(mountFor(tmp.path, _probeConfig))
              .encryptFile(src.path);

      expect(await CryptOperations.isEncryptedFile(encryptedPath), isTrue);
    });

    test('普通文件、短文件与不存在的文件都不应被识别', () async {
      final plain = File(p.join(tmp.path, 'plain.txt'));
      await plain.writeAsString('hello zenfile');
      expect(await CryptOperations.isEncryptedFile(plain.path), isFalse);

      final tiny = File(p.join(tmp.path, 'tiny.bin'));
      await tiny.writeAsBytes(const [1, 2, 3]);
      expect(await CryptOperations.isEncryptedFile(tiny.path), isFalse);

      expect(
        await CryptOperations.isEncryptedFile(p.join(tmp.path, 'nope.bin')),
        isFalse,
      );
    });
  });

  group('CryptOperations.dirContainsCiphertext（目录级探测）', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('zenfile_dirprobe_'));
    tearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });

    test('含密文的目录返回 true（模拟「原地加密在存储根目录」）', () async {
      final src = File(p.join(dir.path, 'photo.jpg'));
      await src.writeAsString('fake-image-bytes');
      await CryptOperations(mountFor(dir.path, _probeConfig))
          .encryptFile(src.path);

      expect(
        await CryptOperations.dirContainsCiphertext(
          dir.path,
          config: _probeConfig,
        ),
        isTrue,
      );
    });

    test('只含普通内容的目录必须返回 false（关键反例）', () async {
      await File(p.join(dir.path, 'photo.jpg')).writeAsString('x');
      await File(p.join(dir.path, 'video.mp4')).writeAsString('x');
      await Directory(p.join(dir.path, 'DCIM')).create();
      await Directory(p.join(dir.path, 'Download')).create();
      // 名字「像」密文（长度恰为 16 的倍数）但内容没有 RCLONE magic：
      // 必须靠 magic 二次确认挡掉，否则整个目录会被误判成加密目录。
      await File(p.join(dir.path, 'AGOXYI_qStS2qsRKEEBDXQ.bin'))
          .writeAsString('not-encrypted-at-all');

      expect(
        await CryptOperations.dirContainsCiphertext(
          dir.path,
          config: _probeConfig,
        ),
        isFalse,
      );
    });

    test('不存在的目录返回 false', () async {
      expect(
        await CryptOperations.dirContainsCiphertext(
          p.join(dir.path, 'nope'),
          config: _probeConfig,
        ),
        isFalse,
      );
    });
  });

  group('CryptMountService.isStorageRootPath（根路径判定）', () {
    test('根级别路径全部命中（含 /sdcard 等别名）', () {
      for (final path in const [
        '/storage/emulated/0',
        '/storage/emulated',
        '/storage',
        '/sdcard',
        '/',
        '/storage/emulated/0/', // 末尾斜杠应被 normalize 归一
      ]) {
        expect(
          CryptMountService.isStorageRootPath(path),
          isTrue,
          reason: '$path 应判定为根路径',
        );
      }
    });

    test('普通目录不应被误判为根路径', () {
      for (final path in const [
        '/storage/emulated/0/DCIM',
        '/storage/emulated/0/Download',
        '/storage/emulated/0/ZenFile',
        '/storage/1234-5678/photos',
      ]) {
        expect(
          CryptMountService.isStorageRootPath(path),
          isFalse,
          reason: '$path 不应判定为根路径',
        );
      }
    });
  });
}
