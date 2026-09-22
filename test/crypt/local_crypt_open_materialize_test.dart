/// 本地加密文件「打开」链路回归。
///
/// 对应两条用户诉求：
/// 1. 浏览页点击**原地加密**的文件（音视频 / 图片除外）要能正常打开 ——
///    此前 apk 之类点不开：`openFile` 的 APK 安装 / 外部打开分支直接拿 crypt
///    视图给出的**虚拟明文路径**（磁盘上是密文名，该路径并不存在）去装；
/// 2. 临时解密出的明文副本要在操作结束后**自动清理**（既不能立刻删 ——
///    系统安装器/外部应用还没读完；也不能留着 —— 明文躺在缓存里等于加密白做）。
///
/// 实现方式：真实临时目录 + 真 rclone crypt 跑 `FileManagerProvider`，
/// 只把「临时目录根」和「清理延迟」两处换成注入点。
///
/// 关键不变量（改这条链路时不要破坏）：
/// * 非音视频/图片的加密文件**必须**落地成磁盘上真实存在的文件，且文件名用
///   **解密后的真实名**（扩展名决定系统/内置查看器能否识别类型）；
/// * 音视频 / 图片**不得**落地（它们有专用流式解密链路，转成实体反而丢掉
///   边解边播能力）；
/// * 落地出的临时文件必须**延迟自动清理**。
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zenfile/providers/file_manager_provider.dart';
import 'package:zenfile/services/crypt/crypt.dart';
import 'package:zenfile/services/preferences_service.dart';

void main() {
  late Directory root;
  late Directory docsDir;
  late FileManagerProvider provider;

  final cfg = RcloneCryptConfig(
    password: 'test-pw',
    salt: 'test-salt',
    filenameEncryption: FilenameEncryption.standard,
    directoryNameEncryption: true,
    filenameEncoding: FilenameEncoding.base32,
    encryptedSuffix: '.bin',
  );
  final crypt = RcloneCrypt(config: cfg);

  List<int> payload(int size) =>
      List<int>.generate(size, (i) => (i * 31 + 7) & 0xff);

  /// 把明文加密写成磁盘上的密文文件（模拟「这个文件已被原地加密」）。
  Future<void> putCipher(String plainName, List<int> plain) async {
    final f = File(p.join(docsDir.path, crypt.encryptFileName(plainName)));
    final cf = await CryptFile.open(f.path, crypt, mode: CryptFileMode.write);
    await cf.write(0, plain);
    await cf.close();
  }

  setUp(() async {
    // 保险箱主密码：走 legacy 单组凭据（档案库为空时 getMasterConfig 会回退到它）
    SharedPreferences.setMockInitialValues({
      VaultCryptService.kMasterPasswordKey: 'test-pw',
      VaultCryptService.kMasterSaltKey: 'test-salt',
      VaultCryptService.kFilenameEncodingKey: 'base32',
      VaultCryptService.kEncryptedSuffixKey: '.bin',
    });
    FlutterSecureStorage.setMockInitialValues({});
    await PreferencesService.init();

    root = await Directory.systemTemp.createTemp('zenfile_localcrypt_');
    docsDir = Directory(p.join(root.path, 'Docs'))..createSync(recursive: true);

    FileManagerProvider.cryptTempRootOverride = p.join(root.path, 'crypt_tmp');
    FileManagerProvider.cryptTempCleanupDelayOverride = null;

    // 持久化一个覆盖 Docs 的挂载点。密码刻意留空 —— 线上持久化挂载点就是
    // 不落盘密码、由主密码补齐，这里顺带把这条补齐链路也压住。
    await CryptMountService.saveMountPoints([
      CryptMountPoint(
        physicalPath: docsDir.path,
        config: RcloneCryptConfig(
          password: '',
          salt: 'test-salt',
          filenameEncryption: FilenameEncryption.standard,
          directoryNameEncryption: true,
          filenameEncoding: FilenameEncoding.base32,
          encryptedSuffix: '.bin',
        ),
        name: 'Docs',
      ),
    ]);

    provider = FileManagerProvider();
  });

  tearDown(() async {
    FileManagerProvider.cryptTempRootOverride = null;
    FileManagerProvider.cryptTempCleanupDelayOverride = null;
    VaultCryptService.sandboxDocsDirOverride = null;
    try {
      await CryptStreamServer.instance.close();
    } catch (_) {}
    try {
      if (await root.exists()) await root.delete(recursive: true);
    } catch (_) {}
  });

  group('本地加密文件落地（openFile 交给系统安装器 / 外部应用前的必经一步）', () {
    test('原地加密的 apk：落地成真实文件，文件名带正确扩展名、内容是明文', () async {
      final plain = payload(4096);
      await putCipher('app.apk', plain);

      final virtualPath = p.join(docsDir.path, 'app.apk');
      expect(File(virtualPath).existsSync(), isFalse,
          reason: 'crypt 视图给的是虚拟明文路径，磁盘上并不存在 —— 正是 bug 的起点');

      final landed =
          await provider.materializeLocalCryptFileForTest(virtualPath);

      expect(landed, isNot(virtualPath),
          reason: '必须换成磁盘上真实存在的落地路径，否则安装器/外部应用读不到');
      expect(p.basename(landed).endsWith('app.apk'), isTrue,
          reason: '落地文件名必须保留解密后的扩展名，否则判不出类型（apk 装不上）');
      expect(File(landed).existsSync(), isTrue);
      expect(await File(landed).readAsBytes(), plain);
    });

    test('原地加密的音视频 / 图片：不落地，原样返回交给流式解密链路', () async {
      await putCipher('movie.mp4', payload(2048));
      await putCipher('song.mp3', payload(1024));
      await putCipher('photo.jpg', payload(512));

      for (final name in ['movie.mp4', 'song.mp3', 'photo.jpg']) {
        final virtualPath = p.join(docsDir.path, name);
        final landed =
            await provider.materializeLocalCryptFileForTest(virtualPath);
        expect(landed, virtualPath,
            reason: '$name 应保持原路径走流式解密，转成实体反而丢失边解边播能力');
      }
    });

    test('未加密的普通文件：原样返回，不做任何多余处理', () async {
      final f = File(p.join(docsDir.path, 'plain.txt'))
        ..writeAsStringSync('hello');
      expect(
        await provider.materializeLocalCryptFileForTest(f.path),
        f.path,
      );
    });

    test('落地出的临时明文副本：到点自动清理', () async {
      FileManagerProvider.cryptTempCleanupDelayOverride =
          const Duration(milliseconds: 30);
      await putCipher('data.zip', payload(2048));

      final landed = await provider.materializeLocalCryptFileForTest(
        p.join(docsDir.path, 'data.zip'),
      );
      expect(File(landed).existsSync(), isTrue,
          reason: '刚落地时必须还在（外部应用/查看器正要读它）');

      await Future<void>.delayed(const Duration(milliseconds: 400));
      expect(File(landed).existsSync(), isFalse,
          reason: '到期必须自动删除明文副本，不能让明文长期留在缓存里');
    });
  });

  group('沙盒加密（保险箱）条目同样走这条落地链路', () {
    test('沙盒加密文件：落地成真实文件（保险箱点击预览的前提）', () async {
      VaultCryptService.sandboxDocsDirOverride = root.path;
      final sandbox = await VaultCryptService.instance.ensureSandboxMount();

      // 用沙盒挂载点自己的 crypt 写一个密文条目
      final encName = sandbox.crypt.encryptFileName('report.pdf');
      final f = File(p.join(sandbox.physicalPath, encName));
      final cf = await CryptFile.open(f.path, sandbox.crypt,
          mode: CryptFileMode.write);
      await cf.write(0, payload(3000));
      await cf.close();

      // 保险箱列表交给统一链路的是「沙盒根 + 解密后的明文名」
      final virtualPath = p.join(sandbox.physicalPath, 'report.pdf');
      final landed =
          await provider.materializeLocalCryptFileForTest(virtualPath);

      expect(landed, isNot(virtualPath));
      expect(p.basename(landed).endsWith('report.pdf'), isTrue,
          reason: '临时文件名沿用密文名会丢扩展名 → MIME 判不出 → 打开失败');
      expect(File(landed).existsSync(), isTrue);
      expect(await File(landed).readAsBytes(), payload(3000));
    });
  });
}
