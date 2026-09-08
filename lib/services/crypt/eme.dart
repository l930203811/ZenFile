/// AES-256 单块加密 + EME 宽块模式 + PKCS7 填充
///
/// 用于 rclone crypt 的**文件名加密**（standard 模式）。
///
/// rclone 的实现（backend/crypt/cipher.go → encryptSegment）：
/// ```go
/// paddedPlaintext := pkcs7.Pad(nameCipherBlockSize, []byte(plaintext))
/// ciphertext := eme.Transform(c.block, c.nameTweak[:], paddedPlaintext, eme.DirectionEncrypt)
/// return c.fileNameEnc.EncodeToString(ciphertext)
/// ```
/// 其中 `c.block` 是 `aes.NewCipher(nameKey)`（nameKey 32 字节 → AES-256），
/// `eme` 是 github.com/rfjakob/eme（Halevi-Rogaway EME）。
///
/// 本文件是 rfjakob/eme 的忠实 Dart 移植（含其 little-endian 的 GF(2^128)
/// multByTwo 语义），保证与 rclone/OpenList 逐字节一致。
library;

import 'dart:typed_data';

import 'crypt_config.dart';

/// ============================================================
/// AES-256（FIPS-197）单块实现
/// ============================================================

/// 生成 AES S-box（维基百科标准算法，避免手写 256 字节出错）
List<int> _buildSbox() {
  final sbox = List<int>.filled(256, 0);
  final exp = List<int>.filled(256, 0);
  final log = List<int>.filled(256, 0);

  var x = 1;
  for (var i = 0; i < 255; i++) {
    exp[i] = x;
    log[x] = i;
    // x = xtime(x) 即乘以 3（本原多项式 0x11B）
    x ^= (x << 1) ^ ((x & 0x80) != 0 ? 0x1B : 0);
    x &= 0xFF;
  }
  exp[255] = exp[0];
  log[0] = 0;

  // 0 的乘法逆元定义为 0
  sbox[0] = 0x63;
  for (var i = 1; i < 256; i++) {
    var inv = exp[255 - log[i]];
    var s = inv;
    for (var r = 0; r < 4; r++) {
      s = ((s << 1) | (s >> 7)) & 0xFF; // ROTL8
      inv ^= s;
    }
    sbox[i] = (inv ^ 0x63) & 0xFF;
  }
  return sbox;
}

final List<int> _sbox = _buildSbox();
final List<int> _invSbox = () {
  final inv = List<int>.filled(256, 0);
  for (var i = 0; i < 256; i++) {
    inv[_sbox[i]] = i;
  }
  return inv;
}();

/// 轮常量 Rcon[i]（i 从 1 开始）
const List<int> _rcon = [
  0x00, 0x01, 0x02, 0x04, 0x08, 0x10, 0x20, 0x40, //
  0x80, 0x1b, 0x36, 0x6c, 0xd8, 0xab, 0x4d, 0x9a, //
];

/// GF(2^8) 乘以 2
int _xtime(int a) => ((a << 1) ^ ((a & 0x80) != 0 ? 0x1B : 0)) & 0xFF;

/// AES-256 单块加密器
///
/// 状态布局遵循 FIPS-197：`state[r + 4*c]`（列优先）。
class Aes256 {
  /// 轮密钥字：60 个 32 位字（14 轮 + 初始），每字 4 字节 → 240 字节
  final Uint8List _w;

  Aes256(Uint8List key) : _w = Uint8List(4 * 60) {
    if (key.length != 32) {
      throw ArgumentError('AES-256 requires a 32-byte key, got ${key.length}');
    }
    _expandKey(key);
  }

  void _expandKey(Uint8List key) {
    for (var i = 0; i < 32; i++) {
      _w[i] = key[i];
    }
    for (var i = 8; i < 60; i++) {
      var t0 = _w[(i - 1) * 4 + 0];
      var t1 = _w[(i - 1) * 4 + 1];
      var t2 = _w[(i - 1) * 4 + 2];
      var t3 = _w[(i - 1) * 4 + 3];

      if (i % 8 == 0) {
        // RotWord + SubWord + Rcon
        final tmp = t0;
        t0 = _sbox[t1] ^ _rcon[i ~/ 8];
        t1 = _sbox[t2];
        t2 = _sbox[t3];
        t3 = _sbox[tmp];
      } else if (i % 8 == 4) {
        // SubWord
        t0 = _sbox[t0];
        t1 = _sbox[t1];
        t2 = _sbox[t2];
        t3 = _sbox[t3];
      }

      _w[i * 4 + 0] = _w[(i - 8) * 4 + 0] ^ t0;
      _w[i * 4 + 1] = _w[(i - 8) * 4 + 1] ^ t1;
      _w[i * 4 + 2] = _w[(i - 8) * 4 + 2] ^ t2;
      _w[i * 4 + 3] = _w[(i - 8) * 4 + 3] ^ t3;
    }
  }

  /// 加密单个 16 字节块
  Uint8List encryptBlock(Uint8List input) {
    final s = Uint8List.fromList(input);
    _addRoundKey(s, 0);

    for (var round = 1; round < 14; round++) {
      for (var i = 0; i < 16; i++) {
        s[i] = _sbox[s[i]];
      }
      _shiftRows(s);
      _mixColumns(s);
      _addRoundKey(s, round);
    }

    // 最后一轮没有 MixColumns
    for (var i = 0; i < 16; i++) {
      s[i] = _sbox[s[i]];
    }
    _shiftRows(s);
    _addRoundKey(s, 14);
    return s;
  }

  /// 解密单个 16 字节块
  Uint8List decryptBlock(Uint8List input) {
    final s = Uint8List.fromList(input);
    _addRoundKey(s, 14);

    for (var round = 13; round >= 1; round--) {
      _invShiftRows(s);
      for (var i = 0; i < 16; i++) {
        s[i] = _invSbox[s[i]];
      }
      _addRoundKey(s, round);
      _invMixColumns(s);
    }

    _invShiftRows(s);
    for (var i = 0; i < 16; i++) {
      s[i] = _invSbox[s[i]];
    }
    _addRoundKey(s, 0);
    return s;
  }

  void _addRoundKey(Uint8List s, int round) {
    final base = round * 16;
    for (var c = 0; c < 4; c++) {
      for (var r = 0; r < 4; r++) {
        s[r + 4 * c] ^= _w[base + 4 * c + r];
      }
    }
  }

  void _shiftRows(Uint8List s) {
    final t = Uint8List(16);
    for (var r = 0; r < 4; r++) {
      for (var c = 0; c < 4; c++) {
        t[r + 4 * c] = s[r + 4 * ((c + r) % 4)];
      }
    }
    s.setRange(0, 16, t);
  }

  void _invShiftRows(Uint8List s) {
    final t = Uint8List(16);
    for (var r = 0; r < 4; r++) {
      for (var c = 0; c < 4; c++) {
        t[r + 4 * ((c + r) % 4)] = s[r + 4 * c];
      }
    }
    s.setRange(0, 16, t);
  }

  void _mixColumns(Uint8List s) {
    for (var c = 0; c < 4; c++) {
      final i = 4 * c;
      final a0 = s[i], a1 = s[i + 1], a2 = s[i + 2], a3 = s[i + 3];
      s[i] = _xtime(a0) ^ (_xtime(a1) ^ a1) ^ a2 ^ a3;
      s[i + 1] = a0 ^ _xtime(a1) ^ (_xtime(a2) ^ a2) ^ a3;
      s[i + 2] = a0 ^ a1 ^ _xtime(a2) ^ (_xtime(a3) ^ a3);
      s[i + 3] = (_xtime(a0) ^ a0) ^ a1 ^ a2 ^ _xtime(a3);
    }
  }

  void _invMixColumns(Uint8List s) {
    for (var c = 0; c < 4; c++) {
      final i = 4 * c;
      final a0 = s[i], a1 = s[i + 1], a2 = s[i + 2], a3 = s[i + 3];
      s[i] = _gmul(a0, 14) ^ _gmul(a1, 11) ^ _gmul(a2, 13) ^ _gmul(a3, 9);
      s[i + 1] = _gmul(a0, 9) ^ _gmul(a1, 14) ^ _gmul(a2, 11) ^ _gmul(a3, 13);
      s[i + 2] = _gmul(a0, 13) ^ _gmul(a1, 9) ^ _gmul(a2, 14) ^ _gmul(a3, 11);
      s[i + 3] = _gmul(a0, 11) ^ _gmul(a1, 13) ^ _gmul(a2, 9) ^ _gmul(a3, 14);
    }
  }

  static int _gmul(int a, int b) {
    var result = 0;
    var aa = a;
    var bb = b;
    for (var i = 0; i < 8; i++) {
      if ((bb & 1) != 0) result ^= aa;
      final hi = (aa & 0x80) != 0;
      aa = (aa << 1) & 0xFF;
      if (hi) aa ^= 0x1B;
      bb >>= 1;
    }
    return result & 0xFF;
  }
}

/// ============================================================
/// EME（ECB-Mix-Encrypt）宽块加密模式
/// ============================================================

/// GF(2^128) 乘以 2（rfjakob/eme 的 multByTwo）
///
/// 注意字节序：该实现按 **little-endian** 处理 16 字节块
/// （byte[0] 为最低有效字节），这里逐行照搬以保证一致。
void _multByTwo(Uint8List out, Uint8List input) {
  final tmp = Uint8List(16);

  tmp[0] = (2 * input[0]) & 0xFF;
  // 常量时间写法：if (input[15] >= 128) tmp[0] ^= 135;
  tmp[0] = tmp[0] ^ (135 & (0xFF & -(input[15] >> 7)));
  for (var j = 1; j < 16; j++) {
    tmp[j] = (2 * input[j]) & 0xFF;
    tmp[j] = (tmp[j] + (input[j - 1] >> 7)) & 0xFF;
  }
  out.setRange(0, 16, tmp);
}

void _xorInto(Uint8List out, Uint8List a, [Uint8List? b]) {
  if (b == null) {
    for (var i = 0; i < 16; i++) {
      out[i] = a[i];
    }
    return;
  }
  for (var i = 0; i < 16; i++) {
    out[i] = a[i] ^ b[i];
  }
}

void _xorAccumulate(Uint8List acc, Uint8List block) {
  for (var i = 0; i < 16; i++) {
    acc[i] ^= block[i];
  }
}

/// 计算 L 表：LTable[i] = 2^(i+1) * AES(0)
List<Uint8List> _tabulateL(Aes256 aes, int m) {
  final li = aes.encryptBlock(Uint8List(16)); // AES(全零)
  final table = <Uint8List>[];
  final cur = Uint8List.fromList(li);
  for (var i = 0; i < m; i++) {
    _multByTwo(cur, cur);
    table.add(Uint8List.fromList(cur));
  }
  return table;
}

/// EME 加密/解密（rfjakob/eme 的 Transform 移植）
///
/// [inputData] 必须是 16 字节的整数倍，且长度在 1~128 个块之间。
/// [tweak] 必须 16 字节。
Uint8List emeTransform(
  Aes256 aes,
  Uint8List tweak,
  Uint8List inputData,
  bool encrypt,
) {
  if (tweak.length != 16) {
    throw ArgumentError('EME tweak must be 16 bytes, got ${tweak.length}');
  }
  if (inputData.length % nameCipherBlockSize != 0) {
    throw ArgumentError('EME input must be a multiple of 16 bytes');
  }
  final m = inputData.length ~/ nameCipherBlockSize;
  if (m == 0 || m > 128) {
    throw ArgumentError('EME operates on 1..128 blocks, got $m');
  }

  final c = Uint8List.fromList(inputData);
  final lTable = _tabulateL(aes, m);

  Uint8List _aes(Uint8List b) =>
      encrypt ? aes.encryptBlock(b) : aes.decryptBlock(b);

  // 第一次遍PPPj：PPj = Pj XOR L_j；PPPj = AES(PPj)
  final ppj = Uint8List(16);
  for (var j = 0; j < m; j++) {
    final pj = Uint8List.sublistView(c, j * 16, (j + 1) * 16);
    _xorInto(ppj, pj, lTable[j]);
    final out = _aes(ppj);
    c.setRange(j * 16, (j + 1) * 16, out);
  }

  // MP = (xorSum PPPj) XOR T
  final mp = Uint8List(16);
  _xorInto(mp, Uint8List.sublistView(c, 0, 16), tweak);
  for (var j = 1; j < m; j++) {
    _xorAccumulate(mp, Uint8List.sublistView(c, j * 16, (j + 1) * 16));
  }

  // MC = AES(MP)
  final mc = _aes(mp);

  // M = MP XOR MC
  final mVal = Uint8List(16);
  _xorInto(mVal, mp, mc);

  // CCCj = PPPj XOR 2^(j-1)*M  (j = 1..m-1)
  final cccj = Uint8List(16);
  for (var j = 1; j < m; j++) {
    _multByTwo(mVal, mVal);
    _xorInto(
      cccj,
      Uint8List.sublistView(c, j * 16, (j + 1) * 16),
      mVal,
    );
    c.setRange(j * 16, (j + 1) * 16, cccj);
  }

  // CCC1 = (xorSum CCCj for j>=1) XOR MC XOR T
  final ccc1 = Uint8List(16);
  _xorInto(ccc1, mc, tweak);
  for (var j = 1; j < m; j++) {
    _xorAccumulate(ccc1, Uint8List.sublistView(c, j * 16, (j + 1) * 16));
  }
  c.setRange(0, 16, ccc1);

  // CCj -> Cj：Cj = AES(CCCj) XOR L_j
  for (var j = 0; j < m; j++) {
    final block = Uint8List.sublistView(c, j * 16, (j + 1) * 16);
    final out = _aes(block);
    _xorInto(out, out, lTable[j]);
    c.setRange(j * 16, (j + 1) * 16, out);
  }

  return c;
}

/// ============================================================
/// PKCS7 填充
/// ============================================================

/// PKCS7 填充到 blockSize 的整数倍
Uint8List pkcs7Pad(int blockSize, List<int> data) {
  final padLen = blockSize - (data.length % blockSize);
  final out = Uint8List(data.length + padLen);
  out.setRange(0, data.length, data);
  for (var i = data.length; i < out.length; i++) {
    out[i] = padLen;
  }
  return out;
}

/// 去除 PKCS7 填充
Uint8List pkcs7Unpad(int blockSize, List<int> data) {
  if (data.isEmpty || data.length % blockSize != 0) {
    throw FormatException('Invalid PKCS7 padded data length ${data.length}');
  }
  final padLen = data[data.length - 1];
  if (padLen == 0 || padLen > blockSize || padLen > data.length) {
    throw FormatException('Invalid PKCS7 padding');
  }
  for (var i = data.length - padLen; i < data.length; i++) {
    if (data[i] != padLen) {
      throw FormatException('Invalid PKCS7 padding bytes');
    }
  }
  return Uint8List.fromList(data.sublist(0, data.length - padLen));
}
