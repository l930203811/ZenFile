/// rclone crypt 文件头解析/生成 + 流式加解密
///
/// 严格对齐 rclone v1.75.1 backend/crypt/cipher.go：
///
/// **文件头（32 字节）**
/// - 0-7:   magic `RCLONE\x00\x00`
/// - 8-31:  nonce（24 字节，加密时随机生成）
///
/// **加密块**
/// - 明文按 64KiB 分块，每块 `secretbox.Seal(plain, nonce, dataKey)`
/// - 落盘内容 = `ciphertext(n) || tag(16)`（**nonce 不落盘**）
/// - 每加密一块，nonce 自增 1（24 字节小端计数）
///
/// 早期实现曾在块头存 16 字节 nonce、并用 version/salt 填充文件头，
/// 与 rclone 完全不兼容，已按官方实现重写。
library;

import 'dart:math';
import 'dart:typed_data';
import 'package:pinenacl/api.dart';
import 'package:pinenacl/src/authenticated_encryption/secret.dart';
import 'crypt_config.dart';

/// ============================================================
/// 文件头
/// ============================================================

/// rclone crypt 文件头（magic + 24 字节 nonce）
class RcloneFileHeader {
  /// 24 字节 nonce
  final Uint8List nonce;

  RcloneFileHeader({required this.nonce})
      : assert(nonce.length == fileHeaderNonceLength);

  /// 生成新的文件头（nonce 由 CSPRNG 随机生成）
  factory RcloneFileHeader.create() {
    final random = Random.secure();
    final nonce = Uint8List(fileHeaderNonceLength);
    for (var i = 0; i < nonce.length; i++) {
      nonce[i] = random.nextInt(256);
    }
    return RcloneFileHeader(nonce: nonce);
  }

  /// 从文件头字节（至少 32 字节）解析
  factory RcloneFileHeader.parse(Uint8List data) {
    if (data.length < fileHeaderSize) {
      throw FormatException(
        'Invalid rclone crypt file header: expected at least $fileHeaderSize bytes, got ${data.length}',
      );
    }

    // 校验 magic
    for (var i = 0; i < fileMagicSize; i++) {
      if (data[i] != fileHeaderMagicBytes[i]) {
        throw FormatException('Invalid rclone crypt file header magic');
      }
    }

    return RcloneFileHeader(
      nonce: Uint8List.fromList(
        data.sublist(fileMagicSize, fileMagicSize + fileHeaderNonceLength),
      ),
    );
  }

  /// 序列化为 32 字节
  Uint8List toBytes() {
    final data = Uint8List(fileHeaderSize);
    data.setRange(0, fileMagicSize, fileHeaderMagicBytes);
    data.setRange(fileMagicSize, fileHeaderSize, nonce);
    return data;
  }
}

/// ============================================================
/// nonce 运算（rclone 的 nonce.carry / nonce.add）
/// ============================================================

/// nonce 自增 1（24 字节小端计数）
void incrementNonce(Uint8List nonce) {
  for (var i = 0; i < nonce.length; i++) {
    final digit = nonce[i];
    final newDigit = (digit + 1) & 0xFF;
    nonce[i] = newDigit;
    if (newDigit >= digit) {
      break; // 无进位，结束
    }
  }
}

/// nonce 加上一个 uint64（小端），返回新的 nonce
///
/// rclone `nonce.add()`：seek 时用 `initialNonce + blockIndex` 得到目标块 nonce。
Uint8List nonceAdd(Uint8List nonce, int x) {
  final out = Uint8List.fromList(nonce);
  var carry = 0;
  var v = x;
  for (var i = 0; i < 8; i++) {
    final digit = out[i];
    final xDigit = v & 0xFF;
    v >>= 8;
    carry += digit + xDigit;
    out[i] = carry & 0xFF;
    carry >>= 8;
  }
  return out;
}

/// 计算第 [blockIndex] 个数据块使用的 nonce
Uint8List deriveBlockNonce(Uint8List initialNonce, int blockIndex) =>
    nonceAdd(initialNonce, blockIndex);

/// ============================================================
/// 流式加密器
/// ============================================================

/// rclone crypt 流式加密器
///
/// 用法：反复 [process] 喂明文，最后 [finish] 收尾。
/// 内部缓冲固定 64KiB，**每次 process 的代价与已处理总量无关**（O(1)），
/// 不会像旧实现那样随文件增大而退化为 O(n²)。
class RcloneStreamEncrypter {
  final SecretBox _secretBox;
  final RcloneFileHeader _header;
  /// 加密一个块使用的 nonce（由文件头 nonce 递增而来）
  late final Uint8List _nonce;

  /// 明文缓冲（固定 64KiB）
  final Uint8List _buf = Uint8List(cryptBlockSize);
  int _bufLen = 0;
  bool _headerWritten = false;

  RcloneStreamEncrypter({
    required Uint8List dataKey,
    RcloneFileHeader? header,
  })  : _secretBox = SecretBox(dataKey),
        _header = header ?? RcloneFileHeader.create() {
    // 必须在构造体内取：若在初始化列表里写
    // `header ?? RcloneFileHeader.create()` 两次，未传 header 时会生成
    // **两个不同的随机 nonce** —— 落盘的 nonce 与加密用的 nonce 不一致，
    // 文件将永远无法解密。
    _nonce = Uint8List.fromList(_header.nonce);
  }

  /// 文件头（含随机 nonce）
  RcloneFileHeader get header => _header;

  /// 加密一段明文，返回密文（可能为空，数据被缓冲）
  List<int> process(List<int> data) {
    final out = BytesBuilder();

    if (!_headerWritten) {
      out.add(_header.toBytes());
      _headerWritten = true;
    }

    var srcPos = 0;
    while (srcPos < data.length) {
      final space = cryptBlockSize - _bufLen;
      final toCopy = space < (data.length - srcPos) ? space : (data.length - srcPos);

      // 逐段填充明文缓冲（不发生整缓冲区重建）
      if (data is Uint8List) {
        _buf.setRange(_bufLen, _bufLen + toCopy, data, srcPos);
      } else {
        for (var i = 0; i < toCopy; i++) {
          _buf[_bufLen + i] = data[srcPos + i];
        }
      }
      _bufLen += toCopy;
      srcPos += toCopy;

      if (_bufLen == cryptBlockSize) {
        out.add(_sealBlock(_buf));
        _bufLen = 0;
      }
    }

    return out.toBytes();
  }

  /// 收尾：加密剩余的不足一块的数据
  List<int> finish() {
    final out = BytesBuilder();

    if (!_headerWritten) {
      out.add(_header.toBytes());
      _headerWritten = true;
    }

    if (_bufLen > 0) {
      out.add(_sealBlock(Uint8List.sublistView(_buf, 0, _bufLen)));
      _bufLen = 0;
    }

    return out.toBytes();
  }

  /// 加密一个明文块，返回 `ciphertext + tag`
  Uint8List _sealBlock(Uint8List plainBlock) {
    // pinenacl 返回 nonce(24) + ciphertext + tag(16)；rclone 不落盘 nonce
    final sealed = _secretBox.encrypt(plainBlock, nonce: _nonce);
    final out = Uint8List.fromList(sealed.sublist(secretBoxNonceLength));
    incrementNonce(_nonce);
    return out;
  }
}

/// ============================================================
/// 流式解密器
/// ============================================================

/// 一个完整加密块的最大字节数（ciphertext 64KiB + tag 16）
const int encryptedBlockMaxSize = cryptBlockSize + blockOverhead;

/// rclone crypt 流式解密器
class RcloneStreamDecrypter {
  final SecretBox _secretBox;
  RcloneFileHeader? _header;
  late Uint8List _nonce;
  bool _initialized = false;

  /// 密文缓冲（最多一个完整块）
  final Uint8List _buf = Uint8List(encryptedBlockMaxSize);
  int _bufLen = 0;

  RcloneStreamDecrypter({required Uint8List dataKey})
      : _secretBox = SecretBox(dataKey);

  /// 文件头（解析后可用）
  RcloneFileHeader? get header => _header;

  /// 解密一段密文，返回明文
  List<int> process(List<int> data) {
    final out = BytesBuilder();
    var srcPos = 0;

    // 先解析文件头
    if (!_initialized) {
      while (srcPos < data.length && _bufLen < fileHeaderSize) {
        _buf[_bufLen++] = data[srcPos++];
      }
      if (_bufLen < fileHeaderSize) {
        return out.toBytes(); // 头部数据不足，等待更多
      }
      _header = RcloneFileHeader.parse(
        Uint8List.sublistView(_buf, 0, fileHeaderSize),
      );
      _nonce = Uint8List.fromList(_header!.nonce);
      _bufLen = 0;
      _initialized = true;
    }

    while (srcPos < data.length) {
      final space = encryptedBlockMaxSize - _bufLen;
      final toCopy =
          space < (data.length - srcPos) ? space : (data.length - srcPos);
      for (var i = 0; i < toCopy; i++) {
        _buf[_bufLen + i] = data[srcPos + i];
      }
      _bufLen += toCopy;
      srcPos += toCopy;

      // 只有累积满一个完整块才解密；最后一块由 finish() 处理
      if (_bufLen == encryptedBlockMaxSize) {
        final plain = _openBlock(Uint8List.sublistView(_buf, 0, _bufLen));
        out.add(plain);
        _bufLen = 0;
      }
    }

    return out.toBytes();
  }

  /// 收尾：解密剩余的最后一块
  List<int> finish() {
    final out = BytesBuilder();

    if (!_initialized) {
      if (_bufLen < fileHeaderSize) {
        return out.toBytes(); // 连头都没有
      }
      _header = RcloneFileHeader.parse(
        Uint8List.sublistView(_buf, 0, fileHeaderSize),
      );
      _nonce = Uint8List.fromList(_header!.nonce);
      _bufLen = 0;
      _initialized = true;
    }

    if (_bufLen > 0) {
      try {
        out.add(_openBlock(Uint8List.sublistView(_buf, 0, _bufLen)));
      } catch (_) {
        // 最后一块不完整/损坏：忽略（与 rclone 的 passBadBlocks 行为不同，
        // 但至少不让整个文件解密失败）
      }
      _bufLen = 0;
    }

    return out.toBytes();
  }

  /// 解密一个密文块（ciphertext + tag），返回明文
  Uint8List _openBlock(Uint8List encryptedBlock) {
    if (encryptedBlock.length < blockOverhead) {
      throw FormatException(
        'Invalid encrypted block: expected at least $blockOverhead bytes, got ${encryptedBlock.length}',
      );
    }
    final plain = _secretBox.decrypt(
      ByteList(encryptedBlock),
      nonce: _nonce,
    );
    incrementNonce(_nonce);
    return Uint8List.fromList(plain);
  }

  /// 解密指定块（随机访问用，不影响流式状态）
  ///
  /// [blockIndex] 从 0 开始；nonce 由「文件头 nonce + blockIndex」派生。
  Uint8List decryptBlockAt(int blockIndex, Uint8List encryptedBlock) {
    if (_header == null) {
      throw StateError('文件头尚未解析，无法确定 nonce');
    }
    final saveNonce = Uint8List.fromList(_nonce);
    _nonce = deriveBlockNonce(_header!.nonce, blockIndex);
    try {
      return _openBlock(encryptedBlock);
    } finally {
      _nonce = saveNonce;
    }
  }
}

/// ============================================================
/// 随机访问（seek）
/// ============================================================

/// 计算加密文件中指定明文偏移对应的块信息
class SeekInfo {
  /// 块索引
  final int blockIndex;

  /// 块内明文偏移
  final int blockOffset;

  /// 该块在密文中的起始偏移（含文件头）
  final int encryptedBlockOffset;

  /// 该块的密文大小（ciphertext + tag）
  final int encryptedBlockSize;

  SeekInfo({
    required this.blockIndex,
    required this.blockOffset,
    required this.encryptedBlockOffset,
    required this.encryptedBlockSize,
  });
}

/// 根据明文偏移计算 seek 信息
SeekInfo calculateSeekInfo(int plainOffset, int totalEncryptedSize) {
  const fullEncryptedBlockSize = encryptedBlockMaxSize;

  final blockIndex = plainOffset ~/ cryptBlockSize;
  final blockOffset = plainOffset % cryptBlockSize;
  final encryptedBlockOffset = fileHeaderSize + blockIndex * fullEncryptedBlockSize;

  final remainingEncrypted = totalEncryptedSize - encryptedBlockOffset;
  final encryptedBlockSize = remainingEncrypted < fullEncryptedBlockSize
      ? remainingEncrypted
      : fullEncryptedBlockSize;

  return SeekInfo(
    blockIndex: blockIndex,
    blockOffset: blockOffset,
    encryptedBlockOffset: encryptedBlockOffset,
    encryptedBlockSize: encryptedBlockSize,
  );
}

/// 计算加密后文件大小
int calculateEncryptedSize(int plainSize) {
  var size = fileHeaderSize;
  if (plainSize == 0) return size;

  final fullBlocks = plainSize ~/ cryptBlockSize;
  final lastBlockSize = plainSize % cryptBlockSize;

  size += fullBlocks * encryptedBlockMaxSize;
  if (lastBlockSize > 0) {
    size += lastBlockSize + blockOverhead;
  }
  return size;
}

/// 计算解密后文件大小
int calculateDecryptedSize(int encryptedSize) {
  if (encryptedSize <= fileHeaderSize) return 0;

  final dataSize = encryptedSize - fileHeaderSize;
  final fullBlocks = dataSize ~/ encryptedBlockMaxSize;
  final lastBlockSize = dataSize % encryptedBlockMaxSize;

  var plainSize = fullBlocks * cryptBlockSize;
  if (lastBlockSize > 0) {
    plainSize += lastBlockSize - blockOverhead;
  }
  return plainSize;
}
