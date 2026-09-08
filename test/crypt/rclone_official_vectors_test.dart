/// rclone/OpenList 官方兼容性回归测试
///
/// 所有向量均来自 rclone v1.75.1 官方源码：
/// - `backend/crypt/cipher.go`（常量、EME、PKCS7、密钥派生）
/// - `backend/crypt/cipher_test.go`（测试向量）
/// - OpenList 的 crypt 驱动（`drivers/crypt/driver.go`）直接调用同一实现，
///   因此通过这些向量 == 与 OpenList 互操作。
///
/// 这些是**黄金标准**：任何一项失败都意味着不再兼容 rclone/OpenList。
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:zenfile/services/crypt/crypt_config.dart';
import 'package:zenfile/services/crypt/eme.dart';
import 'package:zenfile/services/crypt/filename_cipher.dart';
import 'package:zenfile/services/crypt/stream_cipher.dart';

void main() {
  group('AES-256（FIPS-197 官方向量）', () {
    test('Appendix C.3 AES-256 加解密', () {
      final key = _hex(
          '000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f');
      final plain = _hex('00112233445566778899aabbccddeeff');
      const expected = '8ea2b7ca516745bfeafc49904b496089';

      final aes = Aes256(key);
      expect(_toHex(aes.encryptBlock(plain)), equals(expected));
      expect(_toHex(aes.decryptBlock(aes.encryptBlock(plain))),
          equals(_toHex(plain)));
    });
  });

  group('文件名加密（rclone TestEncryptSegmentBase32 官方向量）', () {
    // rclone: newCipher(NameEncryptionStandard, "", "", true, base32)
    // 空密码 → 全零 nameKey(32) 与 nameTweak(16)
    late FilenameCipher cipher;

    setUp(() {
      cipher = FilenameCipher(
        filenameKey: Uint8List(keyLengthFilename),
        nameTweak: Uint8List(keyLengthNameTweak),
        encryption: FilenameEncryption.standard,
        encoding: FilenameEncoding.base32,
        suffix: '.bin',
      );
    });

    const vectors = {
      '': '',
      '1': 'p0e52nreeaj0a5ea7s64m4j72s',
      '12': 'l42g6771hnv3an9cgc8cr2n1ng',
      '123': 'qgm4avr35m5loi1th53ato71v0',
      '1234': '8ivr2e9plj3c3esisjpdisikos',
      '12345': 'rh9vu63q3o29eqmj4bg6gg7s44',
      '123456': 'bn717l3alepn75b2fb2ejmi4b4',
      '1234567': 'n6bo9jmb1qe3b1ogtj5qkf19k8',
      '12345678': 'u9t24j7uaq94dh5q53m3s4t9ok',
      '123456789': '37hn305g6j12d1g0kkrl7ekbs4',
      '1234567890': 'ot8d91eplaglb62k2b1trm2qv0',
      '12345678901': 'h168vvrgb53qnrtvvmb378qrcs',
      '123456789012': 's3hsdf9e29ithrqbjqu01t8q2s',
      '1234567890123': 'cf3jimlv1q2oc553mv7s3mh3eo',
      '12345678901234': 'moq0uqdlqrblrc5pa5u5c7hq9g',
      '123456789012345': 'eeam3li4rnommi3a762h5n7meg',
      '1234567890123456':
          'mijbj0frqf6ms7frcr6bd9h0env53jv96pjaaoirk7forcgpt70g',
    };

    test('加密结果与 rclone 逐字节一致', () {
      for (final e in vectors.entries) {
        expect(cipher.encryptDirName(e.key), equals(e.value),
            reason: 'encryptSegment("${e.key}")');
      }
    });

    test('解密可还原原文', () {
      for (final e in vectors.entries) {
        if (e.key.isEmpty) continue;
        expect(cipher.decryptDirName(e.value), equals(e.key),
            reason: 'decryptSegment("${e.value}")');
      }
    });
  });

  group('base32hex 编码（rclone TestEncodeFileNameBase32 官方向量）', () {
    const vectors = {
      '': '',
      '1': '64',
      '12': '64p0',
      '123': '64p36',
      '1234': '64p36d0',
      '12345': '64p36d1l',
      '123456': '64p36d1l6o',
      '1234567': '64p36d1l6org',
      '12345678': '64p36d1l6orjg',
    };

    test('编解码一致', () {
      for (final e in vectors.entries) {
        final bytes = Uint8List.fromList(e.key.codeUnits);
        final encoded = encodeFilename(bytes, FilenameEncoding.base32);
        expect(encoded, equals(e.value), reason: 'encode("${e.key}")');
        // 往返
        final decoded = decodeFilename(encoded, FilenameEncoding.base32);
        expect(String.fromCharCodes(decoded), equals(e.key));
      }
    });
  });

  group('文件大小换算（rclone TestEncryptedSize 官方向量）', () {
    test('EncryptedSize', () {
      expect(calculateEncryptedSize(0), equals(32));
      expect(calculateEncryptedSize(1), equals(32 + 16 + 1));
      expect(calculateEncryptedSize(65536), equals(32 + 16 + 65536));
      expect(calculateEncryptedSize(65537),
          equals(32 + 16 + 65536 + 16 + 1));
      expect(calculateEncryptedSize(1 << 20), equals(32 + 16 * (16 + 65536)));
    });

    test('DecryptedSize 与 EncryptedSize 互逆', () {
      for (final size in [0, 1, 100, 65535, 65536, 65537, 1 << 20]) {
        expect(calculateDecryptedSize(calculateEncryptedSize(size)),
            equals(size),
            reason: 'size=$size');
      }
    });
  });

  group('文件内容流式加解密', () {
    // rclone 测试：空密码 → 全零 dataKey
    final dataKey = Uint8List(keyLengthData);

    test('多尺寸往返一致（含块边界）', () {
      for (final size in [0, 1, 100, 65535, 65536, 65537, 200000]) {
        final plain = Uint8List.fromList(
            List.generate(size, (i) => (i * 31 + 7) & 0xFF));

        final enc = RcloneStreamEncrypter(
          dataKey: dataKey,
          header: RcloneFileHeader(nonce: Uint8List(fileHeaderNonceLength)),
        );
        final out = BytesBuilder();
        out.add(enc.process(plain));
        out.add(enc.finish());
        final cipher = out.toBytes() as Uint8List;

        // 文件头必须是 RCLONE magic
        expect(String.fromCharCodes(cipher.sublist(0, fileMagicSize)),
            equals('RCLONE\x00\x00'));
        // 长度符合公式
        expect(cipher.length, equals(calculateEncryptedSize(size)));

        final dec = RcloneStreamDecrypter(dataKey: dataKey);
        final dOut = BytesBuilder();
        dOut.add(dec.process(cipher));
        dOut.add(dec.finish());
        expect(_eq(dOut.toBytes(), plain), isTrue, reason: 'size=$size');
      }
    });

    test('随机 nonce（不指定 header）往返一致', () {
      // 回归用例：早期实现在初始化列表里调用了两次 `RcloneFileHeader.create()`，
      // 落盘 nonce 与加密 nonce 是两个随机数，导致文件永远无法解密。
      // 这里强制走「不传 header」的路径。
      for (final size in [13, 70000, 200000]) {
        final plain = Uint8List.fromList(
            List.generate(size, (i) => (i * 13 + 5) & 0xFF));

        final enc = RcloneStreamEncrypter(dataKey: dataKey);
        final out = BytesBuilder();
        out.add(enc.process(plain));
        out.add(enc.finish());
        final cipher = out.toBytes() as Uint8List;

        final dec = RcloneStreamDecrypter(dataKey: dataKey);
        final dOut = BytesBuilder();
        dOut.add(dec.process(cipher));
        dOut.add(dec.finish());

        expect(dOut.toBytes().length, equals(size), reason: 'size=$size');
        expect(_eq(dOut.toBytes(), plain), isTrue, reason: 'size=$size');
      }
    });

    test('分块流式喂数据结果一致', () {
      const total = 300000;
      final plain = Uint8List.fromList(
          List.generate(total, (i) => (i * 17 + 3) & 0xFF));

      final enc = RcloneStreamEncrypter(
        dataKey: dataKey,
        header: RcloneFileHeader(nonce: Uint8List(fileHeaderNonceLength)),
      );
      final out = BytesBuilder();
      var pos = 0;
      while (pos < total) {
        final n = (total - pos) < 8192 ? (total - pos) : 8192;
        out.add(enc.process(Uint8List.sublistView(plain, pos, pos + n)));
        pos += n;
      }
      out.add(enc.finish());
      final cipher = out.toBytes() as Uint8List;

      final dec = RcloneStreamDecrypter(dataKey: dataKey);
      final dOut = BytesBuilder();
      pos = 0;
      while (pos < cipher.length) {
        final n =
            (cipher.length - pos) < 7777 ? (cipher.length - pos) : 7777;
        dOut.add(dec.process(Uint8List.sublistView(cipher, pos, pos + n)));
        pos += n;
      }
      dOut.add(dec.finish());
      expect(_eq(dOut.toBytes(), plain), isTrue);
    });
  });
}

Uint8List _hex(String s) => Uint8List.fromList(
      List.generate(s.length ~/ 2,
          (i) => int.parse(s.substring(i * 2, i * 2 + 2), radix: 16)),
    );

String _toHex(List<int> b) =>
    b.map((e) => e.toRadixString(16).padLeft(2, '0')).join();

bool _eq(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
