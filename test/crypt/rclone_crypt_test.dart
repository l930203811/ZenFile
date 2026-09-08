/// rclone crypt 兼容加密库 - 单元测试
///
/// 测试覆盖：
/// 1. Scrypt 密钥派生
/// 2. 文件名加密/解密（standard / obfuscate / off）
/// 3. 文件头解析/生成
/// 4. 流式加密/解密
/// 5. 文件大小换算
/// 6. 端到端测试
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:zenfile/services/crypt/crypt.dart';

void main() {
  group('Scrypt 密钥派生', () {
    test('派生 64 字节密钥', () {
      final keys = deriveRcloneKeys('password', salt: 'salt');
      expect(keys.filenameKey.length, 32);
      expect(keys.dataKey.length, 32);
    });

    test('相同密码和盐值派生相同密钥', () {
      final keys1 = deriveRcloneKeys('testpassword', salt: 'testsalt');
      final keys2 = deriveRcloneKeys('testpassword', salt: 'testsalt');
      expect(keys1.filenameKey, equals(keys2.filenameKey));
      expect(keys1.dataKey, equals(keys2.dataKey));
    });

    test('不同密码派生不同密钥', () {
      final keys1 = deriveRcloneKeys('password1', salt: 'salt');
      final keys2 = deriveRcloneKeys('password2', salt: 'salt');
      expect(keys1.filenameKey, isNot(equals(keys2.filenameKey)));
    });

    test('不同盐值派生不同密钥', () {
      final keys1 = deriveRcloneKeys('password', salt: 'salt1');
      final keys2 = deriveRcloneKeys('password', salt: 'salt2');
      expect(keys1.filenameKey, isNot(equals(keys2.filenameKey)));
    });

    test('空盐值也能派生密钥', () {
      final keys = deriveRcloneKeys('password');
      expect(keys.filenameKey.length, 32);
      expect(keys.dataKey.length, 32);
    });
  });

  group('文件名加密/解密', () {
    final config = RcloneCryptConfig(
      password: 'testpassword',
      salt: 'testsalt',
      filenameEncryption: FilenameEncryption.standard,
      filenameEncoding: FilenameEncoding.base32,
      encryptedSuffix: '.bin',
    );
    final crypt = RcloneCrypt(config: config);

    test('standard 模式：加密后文件名不同', () {
      const plain = 'video.mp4';
      final encrypted = crypt.encryptFileName(plain);
      expect(encrypted, isNot(equals(plain)));
      expect(encrypted.endsWith('.bin'), isTrue);
    });

    test('standard 模式：加密后解密还原', () {
      const plain = 'video.mp4';
      final encrypted = crypt.encryptFileName(plain);
      final decrypted = crypt.decryptFileName(encrypted);
      expect(decrypted, equals(plain));
    });

    test('standard 模式：中文文件名', () {
      const plain = '视频文件.mp4';
      final encrypted = crypt.encryptFileName(plain);
      final decrypted = crypt.decryptFileName(encrypted);
      expect(decrypted, equals(plain));
    });

    test('standard 模式：长文件名', () {
      final plain = 'a' * 100 + '.txt';
      final encrypted = crypt.encryptFileName(plain);
      final decrypted = crypt.decryptFileName(encrypted);
      expect(decrypted, equals(plain));
    });

    test('standard 模式：相同文件名加密结果相同（确定性加密）', () {
      const plain = 'test.txt';
      final enc1 = crypt.encryptFileName(plain);
      final enc2 = crypt.encryptFileName(plain);
      expect(enc1, equals(enc2));
    });

    test('off 模式：不加密', () {
      final offConfig = config.copyWith(filenameEncryption: FilenameEncryption.off);
      final offCrypt = RcloneCrypt(config: offConfig);
      const plain = 'video.mp4';
      final encrypted = offCrypt.encryptFileName(plain);
      expect(encrypted, equals(plain));
      final decrypted = offCrypt.decryptFileName(encrypted);
      expect(decrypted, equals(plain));
    });

    test('obfuscate 模式：加密后解密还原', () {
      final obfConfig = config.copyWith(filenameEncryption: FilenameEncryption.obfuscate);
      final obfCrypt = RcloneCrypt(config: obfConfig);
      const plain = 'video.mp4';
      final encrypted = obfCrypt.encryptFileName(plain);
      expect(encrypted, isNot(equals(plain)));
      final decrypted = obfCrypt.decryptFileName(encrypted);
      expect(decrypted, equals(plain));
    });

    test('base64 编码', () {
      final b64Config = config.copyWith(filenameEncoding: FilenameEncoding.base64);
      final b64Crypt = RcloneCrypt(config: b64Config);
      const plain = 'test.txt';
      final encrypted = b64Crypt.encryptFileName(plain);
      final decrypted = b64Crypt.decryptFileName(encrypted);
      expect(decrypted, equals(plain));
    });

    test('目录名加密', () {
      const plain = 'MyDocuments';
      final encrypted = crypt.encryptDirName(plain);
      expect(encrypted, isNot(equals(plain)));
      final decrypted = crypt.decryptDirName(encrypted);
      expect(decrypted, equals(plain));
    });

    test('目录名加密关闭', () {
      final noDirConfig = config.copyWith(directoryNameEncryption: false);
      final noDirCrypt = RcloneCrypt(config: noDirConfig);
      const plain = 'MyDocuments';
      final encrypted = noDirCrypt.encryptDirName(plain);
      expect(encrypted, equals(plain));
    });
  });

  group('文件头', () {
    test('生成和解析文件头', () {
      final header = RcloneFileHeader.create();
      // rclone 文件头 = magic(8) + nonce(24)，没有 version / salt
      expect(header.nonce.length, equals(fileHeaderNonceLength));

      final bytes = header.toBytes();
      expect(bytes.length, equals(fileHeaderSize));

      // magic 必须是大写 "RCLONE\x00\x00"（小写会与 rclone 不兼容）
      expect(
        String.fromCharCodes(bytes.sublist(0, fileMagicSize)),
        equals('RCLONE\x00\x00'),
      );

      final parsed = RcloneFileHeader.parse(bytes);
      expect(parsed.nonce, equals(header.nonce));
    });

    test('文件头 magic 验证', () {
      final bytes = Uint8List(32);
      // 写入错误的 magic
      bytes.setRange(0, 8, 'wrongmag'.codeUnits);
      expect(
        () => RcloneFileHeader.parse(bytes),
        throwsA(isA<FormatException>()),
      );
    });

    test('文件头数据不足', () {
      final bytes = Uint8List(16);
      expect(
        () => RcloneFileHeader.parse(bytes),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('流式加密/解密', () {
    final config = RcloneCryptConfig(
      password: 'testpassword',
      salt: 'testsalt',
      filenameEncryption: FilenameEncryption.standard,
      filenameEncoding: FilenameEncoding.base32,
      encryptedSuffix: '.bin',
    );
    final crypt = RcloneCrypt(config: config);

    test('小文件加密解密', () {
      final plainData = Uint8List.fromList('Hello, World!'.codeUnits);

      final encrypter = crypt.createEncrypter();
      final encrypted = <int>[
        ...encrypter.process(plainData),
        ...encrypter.finish(),
      ];

      expect(encrypted.length, greaterThan(plainData.length));

      final decrypter = crypt.createDecrypter();
      final decrypted = <int>[
        ...decrypter.process(encrypted),
        ...decrypter.finish(),
      ];

      expect(decrypted, equals(plainData));
    });

    test('大文件（多块）加密解密', () {
      // 生成 200KB 数据（超过 64KB 块大小，约 4 块）
      final plainData = Uint8List(200 * 1024);
      for (var i = 0; i < plainData.length; i++) {
        plainData[i] = i % 256;
      }

      final encrypter = crypt.createEncrypter();
      final encrypted = <int>[
        ...encrypter.process(plainData.sublist(0, 50 * 1024)),
        ...encrypter.process(plainData.sublist(50 * 1024, 100 * 1024)),
        ...encrypter.process(plainData.sublist(100 * 1024, 150 * 1024)),
        ...encrypter.process(plainData.sublist(150 * 1024)),
        ...encrypter.finish(),
      ];

      final decrypter = crypt.createDecrypter();
      final decrypted = <int>[
        ...decrypter.process(encrypted),
        ...decrypter.finish(),
      ];

      expect(decrypted.length, equals(plainData.length));
      expect(decrypted, equals(plainData));
    });

    test('空文件加密解密', () {
      final encrypter = crypt.createEncrypter();
      final encrypted = <int>[...encrypter.finish()];

      // 空文件只有文件头
      expect(encrypted.length, equals(32));

      final decrypter = crypt.createDecrypter();
      final decrypted = <int>[
        ...decrypter.process(encrypted),
        ...decrypter.finish(),
      ];

      expect(decrypted.length, equals(0));
    });

    test('单块大小文件（64KB）', () {
      final plainData = Uint8List(cryptBlockSize);
      for (var i = 0; i < plainData.length; i++) {
        plainData[i] = (i * 7) % 256;
      }

      final encrypter = crypt.createEncrypter();
      final encrypted = <int>[
        ...encrypter.process(plainData),
        ...encrypter.finish(),
      ];

      final decrypter = crypt.createDecrypter();
      final decrypted = <int>[
        ...decrypter.process(encrypted),
        ...decrypter.finish(),
      ];

      expect(decrypted, equals(plainData));
    });
  });

  group('文件大小换算', () {
    test('空文件加密大小', () {
      expect(calculateEncryptedSize(0), equals(32));
    });

    test('小块文件加密大小', () {
      // rclone：块开销只有 Poly1305 tag(16)，nonce 不落盘
      // 100 字节明文：32 头 + 100 密文 + 16 tag = 148
      expect(calculateEncryptedSize(100), equals(32 + 100 + blockOverhead));
    });

    test('单块文件加密大小', () {
      // 64KB 明文：32 头 + (64KB + 16)
      expect(
          calculateEncryptedSize(cryptBlockSize),
          equals(32 + cryptBlockSize + blockOverhead));
    });

    test('多块文件加密大小', () {
      // 100KB 明文：1 块完整 (64KB+16) + 1 块 (36KB+16) + 32 头
      final plainSize = 100 * 1024;
      final expected = 32 +
          (cryptBlockSize + blockOverhead) +
          ((plainSize - cryptBlockSize) + blockOverhead);
      expect(calculateEncryptedSize(plainSize), equals(expected));
    });

    test('加密大小反向计算', () {
      const plainSize = 12345;
      final encryptedSize = calculateEncryptedSize(plainSize);
      final decryptedSize = calculateDecryptedSize(encryptedSize);
      expect(decryptedSize, equals(plainSize));
    });

    test('空文件解密大小', () {
      expect(calculateDecryptedSize(32), equals(0));
    });
  });

  group('端到端测试', () {
    test('完整流程：创建加密器 -> 加密文件名和内容 -> 解密还原', () {
      final config = RcloneCryptConfig(
        password: 'mypassword123',
        salt: 'mysalt456',
        filenameEncryption: FilenameEncryption.standard,
        directoryNameEncryption: true,
        filenameEncoding: FilenameEncoding.base32,
        encryptedSuffix: '.bin',
      );
      final crypt = RcloneCrypt(config: config);

      // 加密文件名
      const fileName = '我的视频.mp4';
      final encryptedName = crypt.encryptFileName(fileName);
      expect(encryptedName.endsWith('.bin'), isTrue);
      expect(encryptedName, isNot(contains(fileName)));

      // 解密文件名
      final decryptedName = crypt.decryptFileName(encryptedName);
      expect(decryptedName, equals(fileName));

      // 加密目录名
      const dirName = '我的文件夹';
      final encryptedDir = crypt.encryptDirName(dirName);
      final decryptedDir = crypt.decryptDirName(encryptedDir);
      expect(decryptedDir, equals(dirName));

      // 加密文件内容
      final plainContent = Uint8List(50 * 1024);
      for (var i = 0; i < plainContent.length; i++) {
        plainContent[i] = (i * 13 + 7) % 256;
      }

      final encrypter = crypt.createEncrypter();
      final encryptedContent = <int>[
        ...encrypter.process(plainContent),
        ...encrypter.finish(),
      ];

      // 验证加密内容不等于明文
      var isDifferent = false;
      for (var i = 0; i < plainContent.length && i < encryptedContent.length; i++) {
        if (encryptedContent[i + 32] != plainContent[i]) {
          isDifferent = true;
          break;
        }
      }
      expect(isDifferent, isTrue);

      // 解密文件内容
      final decrypter = crypt.createDecrypter();
      final decryptedContent = <int>[
        ...decrypter.process(encryptedContent),
        ...decrypter.finish(),
      ];

      expect(decryptedContent, equals(plainContent));
    });

    test('不同密码无法解密', () {
      final config1 = RcloneCryptConfig(
        password: 'password1',
        filenameEncryption: FilenameEncryption.standard,
        filenameEncoding: FilenameEncoding.base32,
        encryptedSuffix: '.bin',
      );
      final crypt1 = RcloneCrypt(config: config1);

      final config2 = RcloneCryptConfig(
        password: 'password2',
        filenameEncryption: FilenameEncryption.standard,
        filenameEncoding: FilenameEncoding.base32,
        encryptedSuffix: '.bin',
      );
      final crypt2 = RcloneCrypt(config: config2);

      // 用 crypt1 加密（使用超过 64KB 的数据，确保 process() 会处理完整块）
      final plainData = Uint8List(100 * 1024);
      for (var i = 0; i < plainData.length; i++) {
        plainData[i] = i % 256;
      }
      final encrypter = crypt1.createEncrypter();
      final encrypted = <int>[
        ...encrypter.process(plainData),
        ...encrypter.finish(),
      ];

      // 用 crypt2 解密应该失败（Poly1305 tag 验证失败）
      final decrypter = crypt2.createDecrypter();
      expect(
        () => decrypter.process(encrypted),
        throwsA(anything),
      );
    });
  });
}
