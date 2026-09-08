/// 文件名/目录名加密解密 + 编码实现
///
/// 严格对齐 rclone crypt 的文件名加密：
/// - standard: PKCS7 填充 + EME(AES-256) 宽块加密 + base32/base64/base32768 编码
/// - obfuscate: 简单混淆
/// - off: 不加密
library;

import 'dart:convert';
import 'dart:typed_data';
import 'crypt_config.dart';
import 'eme.dart';

/// ============================================================
/// 文件名编码器
/// ============================================================

/// base32 编码器（rclone 的 caseInsensitiveBase32Encoding）
///
/// rclone 用的是 **`base32.HexEncoding`**（RFC4648 的 base32hex 扩展字母表），
/// 而不是标准 base32！字母表为 `0123456789abcdefghijklmnopqrstuv`。
/// 再去掉 `=` padding 并转小写。
///
/// 官方向量：encode("1") == "64"（标准 base32 会得到 "ge"，两者不兼容）。
class _Base32Codec {
  /// base32hex 字母表（RFC4648 "Extended Hex" 字母表的小写形式）
  static const String _alphabet = '0123456789abcdefghijklmnopqrstuv';

  static String encode(Uint8List data) {
    if (data.isEmpty) return '';

    final result = StringBuffer();
    var bits = 0;
    var value = 0;

    for (final byte in data) {
      value = (value << 8) | byte;
      bits += 8;
      while (bits >= 5) {
        bits -= 5;
        result.write(_alphabet[(value >> bits) & 0x1f]);
      }
    }

    if (bits > 0) {
      result.write(_alphabet[(value << (5 - bits)) & 0x1f]);
    }

    return result.toString();
  }

  static Uint8List decode(String encoded) {
    if (encoded.isEmpty) return Uint8List(0);

    // rclone 要求密文不带 padding，且大小写不敏感（先转小写）
    final lower = encoded.toLowerCase();

    final result = BytesBuilder();
    var bits = 0;
    var value = 0;

    for (final char in lower.codeUnits) {
      final int index;
      if (char >= 0x30 && char <= 0x39) {
        index = char - 0x30; // '0'..'9' → 0..9
      } else if (char >= 0x61 && char <= 0x76) {
        index = char - 0x61 + 10; // 'a'..'v' → 10..31
      } else {
        throw FormatException('Invalid base32hex character: $char');
      }
      value = (value << 5) | index;
      bits += 5;
      if (bits >= 8) {
        bits -= 8;
        result.addByte((value >> bits) & 0xff);
      }
    }

    return result.toBytes();
  }
}

/// base64 URL 安全编码器（rclone 使用 base64 URL 安全，不带 padding）
class _Base64UrlCodec {
  static String encode(Uint8List data) {
    return base64Url.encode(data).replaceAll('=', '');
  }

  static Uint8List decode(String encoded) {
    // 补全 padding
    var padded = encoded;
    while (padded.length % 4 != 0) {
      padded += '=';
    }
    return base64Url.decode(padded);
  }
}

/// base32768 编码器（rclone 支持，使用 UTF-16 字符范围）
///
/// base32768 使用 2^15 = 32768 个字符，每个字符表示 15 位。
/// rclone 使用的字符范围是 U+4E00 到 U+4E00 + 32767（CJK 统一表意文字）。
class _Base32768Codec {
  static const int _base = 32768;
  static const int _startChar = 0x4E00; // CJK 统一表意文字起始

  static String encode(Uint8List data) {
    if (data.isEmpty) return '';

    final result = StringBuffer();
    var bits = 0;
    var value = 0;

    for (final byte in data) {
      value = (value << 8) | byte;
      bits += 8;
      while (bits >= 15) {
        bits -= 15;
        final code = _startChar + ((value >> bits) & (_base - 1));
        result.writeCharCode(code);
      }
    }

    if (bits > 0) {
      final code = _startChar + ((value << (15 - bits)) & (_base - 1));
      result.writeCharCode(code);
    }

    return result.toString();
  }

  static Uint8List decode(String encoded) {
    if (encoded.isEmpty) return Uint8List(0);

    final result = BytesBuilder();
    var bits = 0;
    var value = 0;

    for (final code in encoded.codeUnits) {
      final index = code - _startChar;
      if (index < 0 || index >= _base) {
        throw FormatException('Invalid base32768 character: U+${code.toRadixString(16)}');
      }
      value = (value << 15) | index;
      bits += 15;
      while (bits >= 8) {
        bits -= 8;
        result.addByte((value >> bits) & 0xff);
      }
    }

    return result.toBytes();
  }
}

/// 编码文件名
String encodeFilename(Uint8List data, FilenameEncoding encoding) {
  switch (encoding) {
    case FilenameEncoding.base32:
      return _Base32Codec.encode(data);
    case FilenameEncoding.base64:
      return _Base64UrlCodec.encode(data);
    case FilenameEncoding.base32768:
      return _Base32768Codec.encode(data);
  }
}

/// 解码文件名
Uint8List decodeFilename(String encoded, FilenameEncoding encoding) {
  switch (encoding) {
    case FilenameEncoding.base32:
      return _Base32Codec.decode(encoded);
    case FilenameEncoding.base64:
      return _Base64UrlCodec.decode(encoded);
    case FilenameEncoding.base32768:
      return _Base32768Codec.decode(encoded);
  }
}

/// ============================================================
/// 文件名加密器
/// ============================================================

/// rclone crypt 文件名加密器
class FilenameCipher {
  final Uint8List _filenameKey;
  final FilenameEncryption _encryption;
  final FilenameEncoding _encoding;
  final String _suffix;

  late final Aes256? _aes;
  Uint8List? _nameTweak;

  FilenameCipher({
    required Uint8List filenameKey,
    required FilenameEncryption encryption,
    required FilenameEncoding encoding,
    required String suffix,
    Uint8List? nameTweak,
  })  : _filenameKey = filenameKey,
        _encryption = encryption,
        _encoding = encoding,
        _suffix = suffix {
    if (_encryption == FilenameEncryption.standard) {
      // rclone: `c.block, err = aes.NewCipher(c.nameKey[:])` → AES-256
      _aes = Aes256(filenameKey);
      _nameTweak = nameTweak;
    } else {
      _aes = null;
    }
  }

  /// 加密文件名
  String encrypt(String plainName) {
    if (plainName.isEmpty) {
      throw ArgumentError('Filename cannot be empty');
    }

    switch (_encryption) {
      case FilenameEncryption.off:
        return plainName;

      case FilenameEncryption.standard:
        return '${_encryptStandard(plainName)}$_suffix';

      case FilenameEncryption.obfuscate:
        return '${_encryptObfuscate(plainName)}$_suffix';
    }
  }

  /// 解密文件名
  String decrypt(String encryptedName) {
    // 去掉加密后缀
    var name = encryptedName;
    if (_suffix.isNotEmpty && name.endsWith(_suffix)) {
      name = name.substring(0, name.length - _suffix.length);
    }

    if (name.isEmpty) {
      throw ArgumentError('Encrypted filename cannot be empty');
    }

    switch (_encryption) {
      case FilenameEncryption.off:
        return name;

      case FilenameEncryption.standard:
        return _decryptStandard(name);

      case FilenameEncryption.obfuscate:
        return _decryptObfuscate(name);
    }
  }

  /// 加密目录名（与文件名加密相同，但目录名不加后缀）
  String encryptDirName(String plainName) {
    if (plainName.isEmpty || plainName == '.') return plainName;

    switch (_encryption) {
      case FilenameEncryption.off:
        return plainName;
      case FilenameEncryption.standard:
        return _encryptStandard(plainName);
      case FilenameEncryption.obfuscate:
        return _encryptObfuscate(plainName);
    }
  }

  /// 解密目录名
  String decryptDirName(String encryptedName) {
    if (encryptedName.isEmpty || encryptedName == '.') return encryptedName;

    switch (_encryption) {
      case FilenameEncryption.off:
        return encryptedName;
      case FilenameEncryption.standard:
        return _decryptStandard(encryptedName);
      case FilenameEncryption.obfuscate:
        return _decryptObfuscate(encryptedName);
    }
  }

  /// ============================================================
  /// standard 模式：PKCS7 + EME(AES-256) + 编码
  /// ============================================================
  ///
  /// 严格对齐 rclone `encryptSegment` / `decryptSegment`：
  /// ```go
  /// padded := pkcs7.Pad(16, []byte(plaintext))
  /// ct := eme.Transform(c.block, c.nameTweak[:], padded, DirectionEncrypt)
  /// return c.fileNameEnc.EncodeToString(ct)
  /// ```
  /// EME 是**确定性**加密：同一文件名 + 同一 tweak 必得同一密文，
  /// 这是 rclone 能按名字查找文件的前提。

  String _encryptStandard(String plainName) {
    if (plainName.isEmpty) return '';

    final aes = _aes;
    final tweak = _nameTweak;
    if (aes == null || tweak == null) {
      throw StateError('standard 文件名加密需要 nameKey 与 nameTweak');
    }

    final padded = pkcs7Pad(nameCipherBlockSize, utf8.encode(plainName));
    final ciphertext = emeTransform(aes, tweak, padded, true);
    return encodeFilename(ciphertext, _encoding);
  }

  String _decryptStandard(String encodedName) {
    if (encodedName.isEmpty) return '';

    final aes = _aes;
    final tweak = _nameTweak;
    if (aes == null || tweak == null) {
      throw StateError('standard 文件名解密需要 nameKey 与 nameTweak');
    }

    final raw = decodeFilename(encodedName, _encoding);
    if (raw.length % nameCipherBlockSize != 0) {
      throw FormatException('文件名密文长度不是 16 的倍数: ${raw.length}');
    }
    if (raw.isEmpty) {
      throw FormatException('文件名密文为空');
    }
    if (raw.length > 2048) {
      throw FormatException('文件名密文过长: ${raw.length}');
    }

    final padded = emeTransform(aes, tweak, raw, false);
    final plain = pkcs7Unpad(nameCipherBlockSize, padded);
    return utf8.decode(plain);
  }

  /// ============================================================
  /// obfuscate 模式：简单 XOR + 位移混淆
  /// ============================================================
  ///
  /// rclone 的 obfuscate 算法：
  /// 1. 从文件名密钥派生一个 256 字节的置换表
  /// 2. 对每个字节进行置换
  /// 3. 这不是真正的加密，只是混淆，防止文件名被直接识别

  late final List<int> _obfuscateTable = _buildObfuscateTable();

  List<int> _buildObfuscateTable() {
    // 从文件名密钥派生 256 字节的伪随机序列
    final table = List<int>.generate(256, (i) => i);
    var keyIndex = 0;
    var j = 0;

    // Fisher-Yates shuffle，使用文件名密钥作为种子
    for (var i = 255; i > 0; i--) {
      j = (j + table[i] + _filenameKey[keyIndex % _filenameKey.length]) % 256;
      final temp = table[i];
      table[i] = table[j];
      table[j] = temp;
      keyIndex++;
    }

    return table;
  }

  String _encryptObfuscate(String plainName) {
    final plainBytes = utf8.encode(plainName);
    final result = BytesBuilder();

    for (var i = 0; i < plainBytes.length; i++) {
      var b = plainBytes[i];
      // 位移：每个字节加上其位置索引（mod 256）
      b = (b + i) % 256;
      // 置换
      b = _obfuscateTable[b];
      result.addByte(b);
    }

    final encoded = encodeFilename(result.toBytes(), _encoding);
    return encoded;
  }

  String _decryptObfuscate(String encodedName) {
    final decoded = decodeFilename(encodedName, _encoding);
    // 构建逆置换表
    final inverseTable = List<int>.filled(256, 0);
    for (var i = 0; i < 256; i++) {
      inverseTable[_obfuscateTable[i]] = i;
    }

    final result = BytesBuilder();
    for (var i = 0; i < decoded.length; i++) {
      var b = decoded[i];
      // 逆置换
      b = inverseTable[b];
      // 逆位移
      b = (b - i) % 256;
      if (b < 0) b += 256;
      result.addByte(b);
    }

    return utf8.decode(result.toBytes());
  }
}
