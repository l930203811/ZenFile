import 'package:flutter_test/flutter_test.dart';
import 'package:zenfile/services/crypt/crypt_config.dart';
import 'package:zenfile/services/crypt/crypt_mount.dart';
import 'package:zenfile/services/crypt/remote_crypt_auto_assoc.dart';
import 'package:zenfile/services/remote/remote_client.dart';

/// 「自动关联远程加密文件」就地判定的回归。
///
/// 2026-10-24 用户报障：开关开启后浏览远程加密目录仍是密文。根因是 provider
/// 只拿**默认配置**做往返校验，而加密上传允许指定 profileId —— 「用 B 档案
/// 加密、默认却是 A」时整体失配。本测试锁定 [RemoteCryptAutoAssoc] 的多候选
/// 行为，防止回归。
void main() {
  RcloneCryptConfig cfg({
    String password = 'master-pw',
    String? salt = 'master-salt',
    FilenameEncryption enc = FilenameEncryption.standard,
    String suffix = '.bin',
  }) => RcloneCryptConfig(
    password: password,
    salt: salt,
    filenameEncryption: enc,
    directoryNameEncryption: true,
    filenameEncoding: FilenameEncoding.base64,
    encryptedSuffix: suffix,
  );

  RemoteFileItem file(String name) => RemoteFileItem(
    name: name,
    path: '/srv/enc/$name',
    isDirectory: false,
    size: 1,
    modified: DateTime(2026, 10, 24),
  );

  RemoteFileItem dir(String name) => RemoteFileItem(
    name: name,
    path: '/srv/enc/$name',
    isDirectory: true,
    size: 0,
    modified: DateTime(2026, 10, 24),
  );

  group('RemoteCryptAutoAssoc.matchConfigIndex', () {
    test('同配置加密的密文列表 → 命中该配置', () {
      final c = cfg();
      final m = CryptMountPoint(physicalPath: '/srv/enc', config: c);
      final items = [
        file(m.crypt.encryptFileName('a.jpg')),
        file(m.crypt.encryptFileName('b.mp4')),
        file(m.crypt.encryptFileName('c.txt')),
      ];
      expect(
        RemoteCryptAutoAssoc.matchConfigIndex(
          items,
          serverDir: '/srv/enc',
          configs: [c],
        ),
        0,
      );
    });

    test('B 档案加密的列表，默认配置失配 ⇒ 命中后续候选（核心回归）', () {
      final a = cfg(password: 'pw-A', salt: 'salt-A');
      final b = cfg(password: 'pw-B', salt: 'salt-B');
      final mb = CryptMountPoint(physicalPath: '/srv/enc', config: b);
      final items = [
        file(mb.crypt.encryptFileName('a.jpg')),
        file(mb.crypt.encryptFileName('b.mp4')),
      ];
      expect(
        RemoteCryptAutoAssoc.matchConfigIndex(
          items,
          serverDir: '/srv/enc',
          configs: [a, b],
        ),
        1,
      );
    });

    test('纯明文列表 → null', () {
      final items = [file('photo.jpg'), file('video.mp4'), dir('DCIM')];
      expect(
        RemoteCryptAutoAssoc.matchConfigIndex(
          items,
          serverDir: '/srv/enc',
          configs: [cfg()],
        ),
        isNull,
      );
    });

    test('判据二：目录名本身是密文 + 目录内仅 1 个密文文件 → 命中', () {
      final c = cfg();
      final m = CryptMountPoint(physicalPath: '/srv/enc', config: c);
      final cipherDirName = m.crypt.encryptDirName('Photos');
      final items = [file(m.crypt.encryptFileName('only-one.jpg'))];
      expect(
        RemoteCryptAutoAssoc.matchConfigIndex(
          items,
          serverDir: '/srv/$cipherDirName',
          configs: [c],
        ),
        0,
      );
    });

    test('目录名明文 + 单个密文文件 → null（判据一不够、判据二不满足）', () {
      final c = cfg();
      final m = CryptMountPoint(physicalPath: '/srv/enc', config: c);
      final items = [file(m.crypt.encryptFileName('only-one.jpg'))];
      expect(
        RemoteCryptAutoAssoc.matchConfigIndex(
          items,
          serverDir: '/srv/enc',
          configs: [c],
        ),
        isNull,
      );
    });

    test('混合目录：2 个密文 + 3 个普通文件（密文占少数）→ 命中', () {
      // 2026-10-24 用户报障：加密目录里同时有普通文件时不肯关联，只有删光
      // 普通文件才认。名字级往返校验足够强，2 个命中即定罪，与占比无关。
      final c = cfg();
      final m = CryptMountPoint(physicalPath: '/srv/enc', config: c);
      final items = [
        file(m.crypt.encryptFileName('a.jpg')),
        file(m.crypt.encryptFileName('b.mp4')),
        file('plain1.txt'),
        file('plain2.txt'),
        file('plain3.txt'),
      ];
      expect(
        RemoteCryptAutoAssoc.matchConfigIndex(
          items,
          serverDir: '/srv/enc',
          configs: [c],
        ),
        0,
      );
    });

    test('单个密文文件 + 多个普通文件（目录名明文）→ null', () {
      final c = cfg();
      final m = CryptMountPoint(physicalPath: '/srv/enc', config: c);
      final items = [
        file(m.crypt.encryptFileName('only-one.jpg')),
        file('plain1.txt'),
        file('plain2.txt'),
        file('plain3.txt'),
      ];
      expect(
        RemoteCryptAutoAssoc.matchConfigIndex(
          items,
          serverDir: '/srv/enc',
          configs: [c],
        ),
        isNull,
      );
    });

    test('filenameEncryption=off 的候选被跳过', () {
      final off = cfg(enc: FilenameEncryption.off);
      final on = cfg();
      final m = CryptMountPoint(physicalPath: '/srv/enc', config: on);
      final items = [
        file(m.crypt.encryptFileName('a.jpg')),
        file(m.crypt.encryptFileName('b.mp4')),
      ];
      expect(
        RemoteCryptAutoAssoc.matchConfigIndex(
          items,
          serverDir: '/srv/enc',
          configs: [off, on],
        ),
        1,
      );
    });

    test('空列表 / 空候选 → null', () {
      expect(
        RemoteCryptAutoAssoc.matchConfigIndex(
          const [],
          serverDir: '/srv/enc',
          configs: [cfg()],
        ),
        isNull,
      );
      expect(
        RemoteCryptAutoAssoc.matchConfigIndex(
          [file('a')],
          serverDir: '/srv/enc',
          configs: const [],
        ),
        isNull,
      );
    });
  });
}
