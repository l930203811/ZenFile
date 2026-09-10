/// Scrypt 密钥派生 + HKDF 实现
///
/// 严格对齐 rclone crypt 的密钥派生（backend/crypt/cipher.go 的 Cipher.Key）：
/// - Scrypt(N=16384, r=8, p=1, keyLen=**80**)
/// - 80 字节切分：dataKey(32) + nameKey(32) + nameTweak(16)
library;

import 'dart:convert';
import 'dart:typed_data';
import 'package:crypto/crypto.dart' as crypto;
import 'package:pinenacl/src/key_derivation/pbkdf2.dart';
import 'crypt_config.dart';

/// ============================================================
/// Salsa20/8 核心函数（用于 Scrypt 的 BlockMix）
/// ============================================================
///
/// 严格对齐 RFC 7914 第 3 节 `salsa20_word_specification`（与 golang
/// x/crypto/scrypt、libsodium、rclone/OpenList 完全一致）。
/// 注意：scrypt 把整个 64 字节块直接当成状态，**不注入** sigma 常数。

/// Salsa20/8 核心变换：对 16 个 uint32 进行 8 轮（= 4 个 double-round）变换
///
/// RFC 7914 section 3 的逐字列变换 + 行变换，循环 4 次（Salsa20/8）。
/// 输入/输出都是 64 字节（16 个 uint32，小端序）。
/// 偏移 `block.length - 64` 的写法已逐行核对 RFC 7914 与 golang 源码。
Uint8List _salsa20Core8(Uint8List input) {
  assert(input.length == 64);

  // 解析为 16 个 uint32（小端序）
  final x = List<int>.filled(16, 0);
  for (var i = 0; i < 16; i++) {
    x[i] = (input[i * 4]) |
        (input[i * 4 + 1] << 8) |
        (input[i * 4 + 2] << 16) |
        (input[i * 4 + 3] << 24);
  }

  // 保存原始值
  final z = List<int>.from(x);

  // Salsa20/8 = 4 个 double-round（每轮 = 一次列变换 + 一次行变换）。
  for (var i = 0; i < 4; i++) {
    // ---- 列变换 (Column rounds) ----
    x[4] ^= _rotl((x[0] + x[12]) & 0xffffffff, 7);
    x[8] ^= _rotl((x[4] + x[0]) & 0xffffffff, 9);
    x[12] ^= _rotl((x[8] + x[4]) & 0xffffffff, 13);
    x[0] ^= _rotl((x[12] + x[8]) & 0xffffffff, 18);
    x[9] ^= _rotl((x[5] + x[1]) & 0xffffffff, 7);
    x[13] ^= _rotl((x[9] + x[5]) & 0xffffffff, 9);
    x[1] ^= _rotl((x[13] + x[9]) & 0xffffffff, 13);
    x[5] ^= _rotl((x[1] + x[13]) & 0xffffffff, 18);
    x[14] ^= _rotl((x[10] + x[6]) & 0xffffffff, 7);
    x[2] ^= _rotl((x[14] + x[10]) & 0xffffffff, 9);
    x[6] ^= _rotl((x[2] + x[14]) & 0xffffffff, 13);
    x[10] ^= _rotl((x[6] + x[2]) & 0xffffffff, 18);
    x[3] ^= _rotl((x[15] + x[11]) & 0xffffffff, 7);
    x[7] ^= _rotl((x[3] + x[15]) & 0xffffffff, 9);
    x[11] ^= _rotl((x[7] + x[3]) & 0xffffffff, 13);
    x[15] ^= _rotl((x[11] + x[7]) & 0xffffffff, 18);
    // ---- 行变换 (Row rounds) ----
    x[1] ^= _rotl((x[0] + x[3]) & 0xffffffff, 7);
    x[2] ^= _rotl((x[1] + x[0]) & 0xffffffff, 9);
    x[3] ^= _rotl((x[2] + x[1]) & 0xffffffff, 13);
    x[0] ^= _rotl((x[3] + x[2]) & 0xffffffff, 18);
    x[6] ^= _rotl((x[5] + x[4]) & 0xffffffff, 7);
    x[7] ^= _rotl((x[6] + x[5]) & 0xffffffff, 9);
    x[4] ^= _rotl((x[7] + x[6]) & 0xffffffff, 13);
    x[5] ^= _rotl((x[4] + x[7]) & 0xffffffff, 18);
    x[11] ^= _rotl((x[10] + x[9]) & 0xffffffff, 7);
    x[8] ^= _rotl((x[11] + x[10]) & 0xffffffff, 9);
    x[9] ^= _rotl((x[8] + x[11]) & 0xffffffff, 13);
    x[10] ^= _rotl((x[9] + x[8]) & 0xffffffff, 18);
    x[12] ^= _rotl((x[15] + x[14]) & 0xffffffff, 7);
    x[13] ^= _rotl((x[12] + x[15]) & 0xffffffff, 9);
    x[14] ^= _rotl((x[13] + x[12]) & 0xffffffff, 13);
    x[15] ^= _rotl((x[14] + x[13]) & 0xffffffff, 18);
  }

  // 输出 = 原始值 + 变换后的值
  final output = Uint8List(64);
  for (var i = 0; i < 16; i++) {
    final v = (x[i] + z[i]) & 0xffffffff;
    output[i * 4] = v & 0xff;
    output[i * 4 + 1] = (v >> 8) & 0xff;
    output[i * 4 + 2] = (v >> 16) & 0xff;
    output[i * 4 + 3] = (v >> 24) & 0xff;
  }

  return output;
}

/// 32 位整数循环左移
int _rotl(int v, int n) {
  v &= 0xffffffff;
  return ((v << n) | (v >> (32 - n))) & 0xffffffff;
}

/// ============================================================
/// Scrypt 核心算法
/// ============================================================

/// Scrypt 密钥派生函数
///
/// 参数：
/// - [password]: 密码
/// - [salt]: 盐值
/// - [N]: CPU/内存开销参数（必须是 2 的幂，rclone 使用 16384）
/// - [r]: 块大小参数（rclone 使用 8）
/// - [p]: 并行化参数（rclone 使用 1）
/// - [keyLength]: 输出密钥长度（rclone 使用 64）
Uint8List scrypt(
  List<int> password,
  List<int> salt, {
  int N = 16384,
  int r = 8,
  int p = 1,
  int keyLength = 64,
}) {
  // 1. PBKDF2 初始派生：128 * r * p 字节
  final initialLen = 128 * r * p;
  final initial = PBKDF2.hmac_sha256(
    Uint8List.fromList(password),
    Uint8List.fromList(salt),
    1,
    initialLen,
  );

  // 2. 对每个 p 块执行 ROMix
  final blockSize = 128 * r;
  for (var i = 0; i < p; i++) {
    final block = initial.sublist(i * blockSize, (i + 1) * blockSize);
    final mixed = _romix(block, N, r);
    initial.setRange(i * blockSize, (i + 1) * blockSize, mixed);
  }

  // 3. 再次 PBKDF2 派生最终密钥
  return PBKDF2.hmac_sha256(
    Uint8List.fromList(password),
    initial,
    1,
    keyLength,
  );
}

/// ROMix 函数：Scrypt 的内存困难核心
Uint8List _romix(Uint8List block, int N, int r) {
  final blockSize = 128 * r;
  assert(block.length == blockSize);

  // 分配 V 数组：N 个块，每个 blockSize 字节
  // 为了内存效率，使用 List<Uint8List>
  final v = List<Uint8List>.filled(N, Uint8List(0), growable: false);

  var x = Uint8List.fromList(block);

  // 第一次循环：x = BlockMix(x)，存入 V
  for (var i = 0; i < N; i++) {
    v[i] = Uint8List.fromList(x);
    x = _blockMix(x, r);
  }

  // 第二次循环：x = BlockMix(x XOR V[Integerify(x)])
  for (var i = 0; i < N; i++) {
    final j = _integerify(x, r) % N;
    final vj = v[j];
    for (var k = 0; k < blockSize; k++) {
      x[k] ^= vj[k];
    }
    x = _blockMix(x, r);
  }

  return x;
}

/// BlockMix 函数（严格对齐 RFC 7914 / golang x/crypto/scrypt）
///
/// 标准算法：X = B[2r-1]，然后对每个 i = 0..2r-1：
///   T = X XOR B[i]
///   X = Salsa20/8(T)
///   Y[i] = X
/// **关键**：输出 Y 的写入是**交织**的（golang blockMix 的展开实现）：
///   - 偶块索引 2k    → Y[k]        （输出前半段 [0 .. r-1]）
///   - 奇块索引 2k+1  → Y[r + k]    （输出后半段 [r .. 2r-1]）
/// r = 1 时交织等价于顺序写；r > 1 时二者结果不同，必须用交织写才能与
/// rclone / OpenList 兼容。
Uint8List _blockMix(Uint8List block, int r) {
  final blockSize = 128 * r;
  assert(block.length == blockSize);

  // 初始 X = 块的最后 64 字节（B[2r-1]）
  final x = Uint8List.fromList(block.sublist(block.length - 64, block.length));
  final y = Uint8List(blockSize);

  for (var i = 0; i < 2 * r; i++) {
    final start = i * 64;
    for (var j = 0; j < 64; j++) {
      x[j] ^= block[start + j];
    }
    final salsaOut = _salsa20Core8(x);
    x.setAll(0, salsaOut);
    // 交织写出（golang x/crypto/scrypt blockMix）
    if (i % 2 == 0) {
      final k = i ~/ 2;
      y.setRange(k * 64, k * 64 + 64, x);
    } else {
      final k = (i - 1) ~/ 2;
      y.setRange((k + r) * 64, (k + r) * 64 + 64, x);
    }
  }

  return y;
}

/// Integerify：取最后一个 64 字节子块 B[2r-1] 的**前 8 字节**，按小端序
/// 解释为无符号 64 位整数，用作 ROMix 的 V 数组下标。
///
/// 严格对齐 RFC 7914 / golang `integer()`：`j = (2*r - 1) * 16` 个 uint32
/// 处读取 2 个 uint32（= 块尾倒数第 64 字节起的 8 字节），即偏移
/// `(2*r - 1) * 64 = block.length - 64`。这是 B[2r-1] 的**低 64 位**；
/// 对 2 的幂 N 取模时只有低 log2(N) 位参与，等价于 RFC 的 "B[2r-1] 整体
/// 小端整数 mod N"。注意：**不能**读整个块的最后 8 字节（那是子块的高 8 字节）。
int _integerify(Uint8List block, int r) {
  final offset = (2 * r - 1) * 64; // = block.length - 64
  final low = block[offset] |
      (block[offset + 1] << 8) |
      (block[offset + 2] << 16) |
      (block[offset + 3] << 24);
  final high = block[offset + 4] |
      (block[offset + 5] << 8) |
      (block[offset + 6] << 16) |
      (block[offset + 7] << 24);
  return low | (high << 32);
}

/// ============================================================
/// HKDF (HMAC-based Key Derivation Function)
/// ============================================================

/// HKDF-SHA256 密钥派生
///
/// 用于从 Scrypt 派生的主密钥中拆分出多个子密钥。
/// rclone crypt 中，Scrypt 已经直接派生 64 字节（前 32 文件名 + 后 32 内容），
/// 但在某些场景下仍需要 HKDF 进行额外派生。
class Hkdf {
  final Uint8List _prk;

  Hkdf._(this._prk);

  /// HKDF-Extract：从 inputKeyingMaterial + salt 派生伪随机密钥
  factory Hkdf.extract({
    required List<int> inputKeyingMaterial,
    List<int>? salt,
  }) {
    final hmac = crypto.Hmac(crypto.sha256, salt ?? Uint8List(32));
    final prk = hmac.convert(inputKeyingMaterial).bytes;
    return Hkdf._(Uint8List.fromList(prk));
  }

  /// HKDF-Expand：从伪随机密钥派生指定长度的输出密钥
  Uint8List expand(int length, {List<int>? info}) {
    final hashLen = 32; // SHA256 输出长度
    final n = (length / hashLen).ceil();
    if (n > 255) {
      throw ArgumentError('HKDF-Expand output length too large');
    }

    final okm = BytesBuilder();
    var previous = <int>[];

    for (var i = 1; i <= n; i++) {
      final hmac = crypto.Hmac(crypto.sha256, _prk);
      final input = <int>[
        ...previous,
        if (info != null) ...info,
        i,
      ];
      final output = hmac.convert(input).bytes;
      okm.add(output);
      previous = output;
    }

    final result = okm.toBytes();
    return result.sublist(0, length);
  }
}

/// ============================================================
/// rclone crypt 密钥派生（便捷函数）
/// ============================================================

/// rclone crypt 派生的密钥集合
///
/// 对应 rclone `Cipher` 的 dataKey / nameKey / nameTweak 三个字段。
class RcloneDerivedKeys {
  /// 内容加密密钥（32 字节，NACL SecretBox XSalsa20-Poly1305）
  final Uint8List dataKey;

  /// 文件名加密密钥（32 字节，AES-256，用于 EME 宽块加密）
  final Uint8List nameKey;

  /// EME tweak（16 字节）
  ///
  /// EME 用它做「扇区号」式的随机化：同一明文 + 同一 tweak 必得同一密文，
  /// 这正是 rclone 需要的（文件名必须确定性加密，否则无法按名查找）。
  final Uint8List nameTweak;

  /// 兼容旧字段名（文件名加密密钥）
  Uint8List get filenameKey => nameKey;

  RcloneDerivedKeys({
    required this.dataKey,
    required this.nameKey,
    required this.nameTweak,
  });
}

/// 密钥派生结果缓存
///
/// Scrypt(N=16384, r=8, p=1) 在纯 Dart（无原生加速）上开销可观，
/// 而列目录时每渲染一个文件名都要用到 nameKey，绝不能重复派生。
final Map<String, RcloneDerivedKeys> _keyCache = {};

/// 清空密钥派生缓存（保险箱锁定、或密码/盐变更时调用）
void clearDerivedKeyCache() => _keyCache.clear();

/// 从密码和盐值派生 rclone crypt 密钥
///
/// 严格对齐 rclone `Cipher.Key()`：
/// - 密码/盐按 **UTF-8** 取字节
/// - 盐为空时改用 rclone 内置的 [defaultSaltBytes]
/// - scrypt(N=16384, r=8, p=1, keyLen=80)
/// - 切分：dataKey = [0,32)，nameKey = [32,64)，nameTweak = [64,80)
RcloneDerivedKeys deriveRcloneKeys(String password, {String? salt}) {
  final cacheKey = '${password.length}:$password ${salt ?? ''}';
  final cached = _keyCache[cacheKey];
  if (cached != null) return cached;

  // rclone 用 []byte(password)，即 UTF-8 字节。
  // 不能用 codeUnits —— 那对中文等非 ASCII 密码会给出 UTF-16 码元，与 rclone 不一致。
  final passwordBytes = Uint8List.fromList(utf8.encode(password));

  // rclone：salt 为空时用内置 defaultSalt，而不是空字节数组。
  final Uint8List saltBytes;
  if (salt != null && salt.isNotEmpty) {
    saltBytes = Uint8List.fromList(utf8.encode(salt));
  } else {
    saltBytes = Uint8List.fromList(defaultSaltBytes);
  }

  final derived = scrypt(
    passwordBytes,
    saltBytes,
    N: scryptN,
    r: scryptR,
    p: scryptP,
    keyLength: scryptKeyLength, // 80
  );

  final keys = RcloneDerivedKeys(
    dataKey: Uint8List.fromList(derived.sublist(0, keyLengthData)),
    nameKey: Uint8List.fromList(
      derived.sublist(keyLengthData, keyLengthData + keyLengthFilename),
    ),
    nameTweak: Uint8List.fromList(
      derived.sublist(
        keyLengthData + keyLengthFilename,
        keyLengthData + keyLengthFilename + keyLengthNameTweak,
      ),
    ),
  );

  _keyCache[cacheKey] = keys;
  return keys;
}
