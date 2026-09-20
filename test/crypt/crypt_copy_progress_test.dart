import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:zenfile/services/crypt/crypt_config.dart';
import 'package:zenfile/services/crypt/crypt_mount.dart';
import 'package:zenfile/services/crypt/crypt_operations.dart';

/// 「复制/剪切文件进加密目录」时进度回调必须是**字节级增量**的回归。
///
/// 覆盖用户反馈：往加密文件夹里粘贴文件时，弹窗进度条没有任何实时进度
/// （外圈只在条目间跳变、内圈恒为 0、速率恒显示「—」）。
///
/// 根因：加密粘贴链路走的是「非破坏性写目标」的
/// [CryptOperations.encryptFileTo] / [CryptOperations.decryptFileTo]，
/// 而这两个方法当初**没有** `onFileProgress` 参数 —— 只有原地版
/// `encryptFile` / `decryptFile` 有。provider 拿不到任何字节回调，只能自己
/// 按「第几个条目」编一个假进度。
///
/// 断言契约：
/// 1. 回调被调用**多次**（逐 64KiB 分块），而不是结束时才跳一次；
/// 2. 字节单调递增、不回退；
/// 3. 末次 `bytes` == 源文件总字节，且分母 `total` == 源文件大小；
/// 4. 0 字节文件不产生回调（分母由此为 0，调用方必须自己对齐首末帧）。
void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('crypt_copy_progress_');
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  RcloneCryptConfig cfg() => RcloneCryptConfig(
        password: 'master-pw',
        salt: 'master-salt',
        filenameEncryption: FilenameEncryption.standard,
        directoryNameEncryption: true,
        filenameEncoding: FilenameEncoding.base64,
        encryptedSuffix: '.bin',
      );

  CryptMountPoint mountFor(Directory dir) =>
      CryptMountPoint(physicalPath: dir.path, config: cfg(), name: p.basename(dir.path));

  /// 生成可校验内容的测试文件（字节值可重现，便于往返比对）。
  List<int> payload(int size) =>
      List<int>.generate(size, (i) => (i * 31 + 7) & 0xff);

  group('encryptFileTo 进度回调', () {
    test('多分块文件：多次回调、单调递增、末次到达总字节', () async {
      final m = mountFor(root);
      final ops = CryptOperations(m);

      final bytes = payload(300 * 1024); // 5 个 64KiB 分块
      final src = File(p.join(root.path, 'big.mp4'));
      await src.writeAsBytes(bytes);

      final seen = <int>[];
      var reportedTotal = -1;
      final out = await ops.encryptFileTo(
        src.path,
        p.join(root.path, 'big.enc.bin'),
        onFileProgress: (b, t) {
          seen.add(b);
          reportedTotal = t;
        },
      );

      expect(reportedTotal, bytes.length, reason: '分母必须是源文件总字节');
      expect(seen.length, greaterThan(1),
          reason: '必须逐块回调；只回调一次等于进度条直接跳到 100%');
      expect(seen.last, bytes.length, reason: '末次必须到达总字节，否则进度条永远填不满');
      for (var i = 1; i < seen.length; i++) {
        expect(seen[i], greaterThan(seen[i - 1]), reason: '字节必须单调递增');
      }
      expect(File(out).existsSync(), isTrue);
      expect(await src.length(), bytes.length, reason: '复制语义：保留源文件');
    });

    test('0 字节文件不产生回调（分母为 0，由调用方对齐首末帧）', () async {
      final m = mountFor(root);
      final ops = CryptOperations(m);

      final src = File(p.join(root.path, 'empty.txt'));
      await src.writeAsBytes(const []);

      final seen = <int>[];
      await ops.encryptFileTo(
        src.path,
        p.join(root.path, 'empty.enc.bin'),
        onFileProgress: (b, t) => seen.add(b),
      );

      expect(seen, isEmpty);
    });
  });

  group('decryptFileTo 进度回调', () {
    test('往返：加密后解密回原文，且解密过程同样逐块上报', () async {
      final m = mountFor(root);
      final ops = CryptOperations(m);

      final bytes = payload(220 * 1024);
      final src = File(p.join(root.path, 'video.mp4'));
      await src.writeAsBytes(bytes);

      final encPath = await ops.encryptFileTo(
        src.path,
        p.join(root.path, 'video.enc.bin'),
      );

      final seen = <int>[];
      var reportedTotal = -1;
      final plainPath = await ops.decryptFileTo(
        encPath,
        p.join(root.path, 'video.out.mp4'),
        onFileProgress: (b, t) {
          seen.add(b);
          reportedTotal = t;
        },
      );

      expect(seen.length, greaterThan(1), reason: '解密也必须逐块回调');
      expect(seen.last, reportedTotal);
      expect(reportedTotal, await File(encPath).length(),
          reason: '解密分母取源密文大小');
      for (var i = 1; i < seen.length; i++) {
        expect(seen[i], greaterThan(seen[i - 1]));
      }

      final roundTrip = await File(plainPath).readAsBytes();
      expect(roundTrip.length, bytes.length);
      expect(roundTrip, equals(bytes), reason: '加解密往返必须字节一致');
    });
  });
}
