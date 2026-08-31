import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zenfile/services/vault_service.dart';

// flutter test 的运行环境没有 path_provider 的原生实现，必须 mock 平台通道。
const _pathChannel = MethodChannel('plugins.flutter.io/path_provider');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory testRoot;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    await prefs.clear();

    testRoot = await Directory.systemTemp.createTemp('vault_test_');
    _pathChannel.setMockMethodCallHandler((call) async {
      switch (call.method) {
        case 'getApplicationDocumentsDirectory':
        case 'getApplicationSupportDirectory':
        case 'getTemporaryDirectory':
          return testRoot.path;
        default:
          return null;
      }
    });
  });

  tearDown(() async {
    _pathChannel.setMockMethodCallHandler(null);
    if (await testRoot.exists()) {
      await testRoot.delete(recursive: true);
    }
  });

  Future<Directory> _tmp() => getTemporaryDirectory();

  test('V2 锁定→解锁 往返（小文件 + 跨块大文件，错误密码被拒）', () async {
    const pw = 'correct horse battery staple';
    await VaultService.setPassword(pw);
    expect(await VaultService.verifyPassword(pw), isTrue);
    expect(await VaultService.verifyPassword('wrong'), isFalse);

    final tmp = await _tmp();

    // 小文件
    final smallContent =
        utf8.encode('Hello ZenFile Vault V2 🔒 元数据混淆测试') as Uint8List;
    final smallFile = File(p.join(tmp.path, 'small.bin'));
    await smallFile.writeAsBytes(smallContent);

    // 大文件（跨越多个 1MiB 分块，>2.5MB）
    final largeContent = Uint8List.fromList(
        List<int>.generate(2500000, (i) => (i * 31 + 7) & 0xFF));
    final largeFile = File(p.join(tmp.path, 'large.bin'));
    await largeFile.writeAsBytes(largeContent);

    final smallRec = await VaultService.lockFile(file: smallFile, password: pw);
    expect(await smallFile.exists(), isFalse); // 原文件被移除
    final largeRec = await VaultService.lockFile(file: largeFile, password: pw);

    // 密文落在应用私有 vault/ 目录，扩展名 .zvn，元数据已打乱
    expect(await File(smallRec.scrambledPath).exists(), isTrue);
    expect(smallRec.scrambledPath.endsWith('.zvn'), isTrue);
    expect(smallRec.isInPlace, isFalse);
    expect(smallRec.originalName, 'small.bin'); // 元数据仍正确还原

    // 解锁小文件
    final outSmall =
        await VaultService.unlockFile(record: smallRec, password: pw);
    expect(await outSmall.readAsBytes(), equals(smallContent));

    // 解锁跨块大文件
    final outLarge =
        await VaultService.unlockFile(record: largeRec, password: pw);
    expect(await outLarge.readAsBytes(), equals(largeContent));

    // 错误密码被 GCM MAC 拒绝
    await expectLater(
      VaultService.unlockFile(record: smallRec, password: 'wrong-pw'),
      throwsA(anything),
    );
  });

  test('V2 修改密码（changePassword）重新加密，旧密码失效/新密码可用', () async {
    const oldPw = 'old-pw-123';
    const newPw = 'new-pw-456';
    await VaultService.setPassword(oldPw);

    final tmp = await _tmp();
    final content = utf8.encode('change password rekey payload 中文测试');
    final f = File(p.join(tmp.path, 'cp.bin'));
    await f.writeAsBytes(content);
    final rec = await VaultService.lockFile(file: f, password: oldPw);

    expect(await VaultService.changePassword(oldPw, newPw), isTrue);
    expect(await VaultService.verifyPassword(oldPw), isFalse);
    expect(await VaultService.verifyPassword(newPw), isTrue);

    // 旧密码解锁失败（原 .zvn 已被删除/重加密）
    await expectLater(
      VaultService.unlockFile(record: rec, password: oldPw),
      throwsA(anything),
    );

    // 新密码可解锁（从记录表载入更新后的记录）
    final records = await VaultService.loadRecords();
    final updatedRec = records.firstWhere((r) => r.id == rec.id);
    final out = await VaultService.unlockFile(record: updatedRec, password: newPw);
    expect(await out.readAsBytes(), equals(content));
  });
}
