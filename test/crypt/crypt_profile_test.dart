import 'package:flutter_test/flutter_test.dart';
import 'package:zenfile/services/crypt/crypt.dart';

CryptProfileService _service() =>
    CryptProfileService.withStorage(InMemoryCryptProfileStorage());

CryptProfile _profile(String name, String password, {String? id, bool isActive = false}) =>
    CryptProfile(
      id: id ?? 'id_$name',
      name: name,
      password: password,
      salt: 'salt_$name',
      filenameEncoding: FilenameEncoding.base32,
      encryptedSuffix: '.bin',
      isActive: isActive,
    );

void main() {
  group('CryptProfile 名称唯一性', () {
    test('trim + 忽略大小写视为重名', () {
      final profiles = [_profile('工作', 'pw1'), _profile('私人', 'pw2')];
      expect(
        CryptProfileService.nameExistsIn(profiles, '工作'),
        isTrue,
      );
      expect(
        CryptProfileService.nameExistsIn(profiles, '  工作  '),
        isTrue,
      );
      expect(CryptProfileService.nameExistsIn(profiles, '其它'), isFalse);
    });

    test('编辑自身时排除自身不算重名', () {
      final p = _profile('工作', 'pw1', id: 'A');
      expect(
        CryptProfileService.nameExistsIn([p], '工作', exceptId: 'A'),
        isFalse,
      );
      expect(CryptProfileService.nameExistsIn([p], '工作'), isTrue);
    });

    test('空名称不参与查重', () {
      expect(CryptProfileService.nameExistsIn([_profile('a', 'p')], ''), isFalse);
    });
  });

  group('CryptProfileService 增删改', () {
    test('第一份档案自动成为默认', () async {
      final s = _service();
      final created = await s.addOrUpdate(_profile('A', 'pwA'));
      expect(created.isActive, isTrue);

      final second = await s.addOrUpdate(_profile('B', 'pwB'));
      expect(second.isActive, isFalse, reason: '默认档案已存在，新增不应抢默认');
      expect((await s.activeProfile())?.id, created.id);
    });

    test('重名新增抛 ArgumentError', () async {
      final s = _service();
      await s.addOrUpdate(_profile('A', 'pwA'));
      // 不同 id + 同名 = 真正的重复
      expect(
        () => s.addOrUpdate(_profile('A', 'pwB', id: 'another')),
        throwsA(isA<ArgumentError>()),
      );
      // 同 id = 更新自身，不应报重名
      await s.addOrUpdate(_profile('A', 'pwA2', id: 'id_A'));
      expect((await s.byId('id_A'))!.password, 'pwA2');
    });

    test('setActive 会取消其它档案的默认标记', () async {
      final s = _service();
      final a = await s.addOrUpdate(_profile('A', 'pwA'));
      final b = await s.addOrUpdate(_profile('B', 'pwB'));
      await s.setActive(b.id);
      expect((await s.byId(a.id))!.isActive, isFalse);
      expect((await s.byId(b.id))!.isActive, isTrue);
      expect((await s.activeProfile())?.id, b.id);
    });

    test('删除默认档案后由剩余第一份接管，并清理绑定', () async {
      final s = _service();
      final a = await s.addOrUpdate(_profile('A', 'pwA'));
      final b = await s.addOrUpdate(_profile('B', 'pwB'));
      await s.bindPath('/storage/emulated/0/secret', a.id);
      await s.bindPath('/storage/emulated/0/other', b.id);

      await s.delete(a.id);

      expect((await s.activeProfile())?.id, b.id);
      final bindings = await s.loadBindings();
      expect(bindings.containsKey('/storage/emulated/0/secret'), isFalse);
      expect(bindings['/storage/emulated/0/other'], b.id);
    });
  });

  group('路径绑定解析', () {
    test('最长祖先前缀优先', () {
      final bindings = {
        '/storage/emulated/0': 'root',
        '/storage/emulated/0/a': 'a',
        '/storage/emulated/0/a/b': 'ab',
      };
      expect(
        CryptProfileService.matchBindingId(bindings, '/storage/emulated/0/a/b/c.txt'),
        'ab',
      );
      expect(
        CryptProfileService.matchBindingId(bindings, '/storage/emulated/0/a/x'),
        'a',
      );
      expect(
        CryptProfileService.matchBindingId(bindings, '/storage/emulated/0/z'),
        'root',
      );
    });

    test('不能误命中同名前缀目录', () {
      final bindings = {'/storage/emulated/0/ab': 'hit'};
      expect(
        CryptProfileService.matchBindingId(bindings, '/storage/emulated/0/abc/f'),
        isNull,
      );
    });

    test('绑定优先于默认档案，未绑定时回退默认', () async {
      final s = _service();
      final def = await s.addOrUpdate(_profile('默认', 'pwDefault'));
      final other = await s.addOrUpdate(_profile('其它', 'pwOther'));
      await s.bindPath('/storage/emulated/0/photos', other.id);

      expect(
        (await s.resolveFor('/storage/emulated/0/photos/a.jpg'))?.id,
        other.id,
      );
      expect(
        (await s.resolveFor('/storage/emulated/0/downloads/a.jpg'))?.id,
        def.id,
      );
    });

    test('绑定路径按 POSIX 归一（反斜杠/重复斜杠/末尾斜杠）', () async {
      final s = _service();
      final p = await s.addOrUpdate(_profile('A', 'pwA'));
      await s.bindPath('\\\\storage\\\\emulated\\\\0\\\\dcim\\\\', p.id);
      expect(
        (await s.resolveFor('/storage/emulated/0/dcim/IMG.jpg'))?.id,
        p.id,
      );
    });
  });

  group('档案 → rclone 配置', () {
    test('空盐转为 null（走 rclone 默认盐）', () {
      final cfg = _profile('A', 'pw', id: 'x').copyWith(salt: '').toConfig();
      expect(cfg.salt, isNull);
      expect(cfg.password, 'pw');
      expect(cfg.filenameEncryption, FilenameEncryption.standard);
    });

    test('同一档案派生出的配置能正确加解密文件名', () {
      final cfg = _profile('A', 'pwA').toConfig();
      final crypt = RcloneCrypt(config: cfg);
      final enc = crypt.encryptFileName('video.mp4');
      expect(crypt.decryptFileName(enc), 'video.mp4');
    });

    test('不同密码的档案解不开彼此的文件名', () {
      final a = RcloneCrypt(config: _profile('A', 'pwA').toConfig());
      final b = RcloneCrypt(config: _profile('B', 'pwB').toConfig());
      final enc = a.encryptFileName('secret.txt');
      expect(
        () => b.decryptFileName(enc),
        throwsA(anything),
      );
    });
  });
}
