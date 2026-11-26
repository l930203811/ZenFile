/// 加密文件随机读写
///
/// 基于 rclone crypt 格式，支持随机访问（seek）的文件读写。
/// 读取时自动解密，写入时自动加密。
library;

import 'dart:io';
import 'dart:typed_data';
import 'package:pinenacl/api.dart';
import 'package:pinenacl/src/authenticated_encryption/secret.dart';
import 'crypt_config.dart';
import 'stream_cipher.dart';
import 'rclone_crypt.dart';

/// 加密文件打开模式
enum CryptFileMode {
  /// 只读模式
  read,

  /// 只写模式（覆盖原有内容）
  write,

  /// 追加模式（在文件末尾追加）
  append,
}

/// 加密文件（支持随机访问的读写）
///
/// ## 使用示例
///
/// ```dart
/// // 读取加密文件
/// final file = CryptFile.open('/path/to/encrypted.bin', crypt, mode: CryptFileMode.read);
/// final data = await file.read(0, 1024); // 从偏移 0 读取 1024 字节
/// await file.close();
///
/// // 写入加密文件
/// final file = CryptFile.open('/path/to/encrypted.bin', crypt, mode: CryptFileMode.write);
/// await file.write(0, plainData); // 从偏移 0 写入数据
/// await file.close();
/// ```
class CryptFile {
  final String _path;
  final RcloneCrypt _crypt;
  final CryptFileMode _mode;
  late RandomAccessFile _raf;

  RcloneFileHeader? _header;
  int _decryptedSize = 0;
  bool _isOpen = false;

  CryptFile._(this._path, this._crypt, this._mode);

  /// 打开加密文件
  static Future<CryptFile> open(
    String path,
    RcloneCrypt crypt, {
    CryptFileMode mode = CryptFileMode.read,
  }) async {
    final file = CryptFile._(path, crypt, mode);
    await file._open();
    return file;
  }

  Future<void> _open() async {
    switch (_mode) {
      case CryptFileMode.read:
        _raf = await File(_path).open(mode: FileMode.read);
        await _readHeader();
        break;
      case CryptFileMode.write:
        _raf = await File(_path).open(mode: FileMode.write);
        // 写入新的文件头
        _header = RcloneFileHeader.create();
        await _raf.writeFrom(_header!.toBytes());
        _decryptedSize = 0;
        break;
      case CryptFileMode.append:
        _raf = await File(_path).open(mode: FileMode.append);
        // 读取现有文件头
        final length = await _raf.length();
        if (length >= fileHeaderSize) {
          await _raf.setPosition(0);
          await _readHeader();
        } else {
          // 文件太小，创建新文件头并写入
          _header = RcloneFileHeader.create();
          await _raf.setPosition(0);
          await _raf.writeFrom(_header!.toBytes());
          _decryptedSize = 0;
        }
        break;
    }
    _isOpen = true;
  }

  Future<void> _readHeader() async {
    await _raf.setPosition(0);
    final headerBytes = await _raf.read(fileHeaderSize);
    _header = RcloneFileHeader.parse(headerBytes);

    // 计算解密后的文件大小
    final encryptedSize = await _raf.length();
    _decryptedSize = calculateDecryptedSize(encryptedSize);
  }

  /// 获取解密后的文件大小
  int get length => _decryptedSize;

  /// 获取加密后的文件大小
  Future<int> get encryptedLength async => _raf.length();

  /// 文件是否已打开
  bool get isOpen => _isOpen;

  /// 从指定偏移读取指定长度的明文数据
  ///
  /// [offset] 明文偏移（从 0 开始）
  /// [length] 要读取的字节数（默认读取到文件末尾）
  Future<Uint8List> read(int offset, [int? length]) async {
    _ensureOpen();
    if (_mode == CryptFileMode.write) {
      throw StateError('Cannot read from file opened in write mode');
    }

    // 计算实际读取长度
    var readLength = length;
    if (readLength == null || offset + readLength > _decryptedSize) {
      readLength = _decryptedSize - offset;
    }
    if (readLength <= 0) {
      return Uint8List(0);
    }

    // 计算需要读取的块范围
    final startBlock = offset ~/ cryptBlockSize;
    final endBlock = (offset + readLength - 1) ~/ cryptBlockSize;

    final result = BytesBuilder();

    for (var blockIndex = startBlock; blockIndex <= endBlock; blockIndex++) {
      // 计算该块在密文中的位置
      final blockOffsetInEncrypted = fileHeaderSize + blockIndex * (cryptBlockSize + blockOverhead);
      final blockSize = cryptBlockSize + blockOverhead;

      // 读取该块的密文
      await _raf.setPosition(blockOffsetInEncrypted);
      final blockData = await _raf.read(blockSize);

      // 解密该块
      final plainBlock = _decryptBlock(blockData, blockIndex);

      // 计算需要从该块取的数据范围
      final blockStart = blockIndex * cryptBlockSize;
      final blockEnd = blockStart + plainBlock.length;

      final copyStart = offset > blockStart ? offset - blockStart : 0;
      final copyEnd = (offset + readLength) < blockEnd ? (offset + readLength) - blockStart : plainBlock.length;

      if (copyEnd > copyStart) {
        result.add(plainBlock.sublist(copyStart, copyEnd));
      }
    }

    return result.toBytes();
  }

  /// 解密单个块
  ///
  /// rclone 块格式：`ciphertext + tag(16)`。
  /// nonce **不在块里**，而是由「文件头 nonce + blockIndex」派生。
  Uint8List _decryptBlock(Uint8List blockData, int blockIndex) {
    if (blockData.length < blockOverhead) {
      throw FormatException('Invalid encrypted block size: ${blockData.length}');
    }
    final header = _header;
    if (header == null) {
      throw StateError('文件头未初始化，无法确定块 nonce');
    }

    final nonce = deriveBlockNonce(header.nonce, blockIndex);

    return Uint8List.fromList(
      SecretBox(_crypt.derivedKeys.dataKey).decrypt(
        ByteList(blockData),
        nonce: nonce,
      ),
    );
  }

  /// 从指定偏移写入明文数据（自动加密，块级读-改-写）
  ///
  /// [offset] 明文偏移（从 0 开始）；[data] 要写入的明文数据。
  /// 语义：从 [offset] 覆盖写入，写入后的文件明文长度恰为 `offset + data.length`
  /// （与旧实现一致：旧实现把 `[0..offset)` + data 整体重加密写回，超出部分被截断）。
  ///
  /// 性能：rclone crypt 每块的 nonce 由「文件头 nonce + 块号」派生，块与块之间
  /// 相互独立，因此修改 [offset..] 之后的内容只需重写受影响的块。旧实现会把
  /// `[0..offset)` 全部读入内存并**整文件重加密重写**，文件越大内存和 IO 越爆炸。
  ///
  /// ⚠️ 平台差异（重要）：append 模式句柄在 Android（O_APPEND）上**写入永远
  /// 落在 EOF**，setPosition 只影响读取；Windows 上定位写则被尊重。因此按
  /// 模式分流：write 模式走定位写；append 模式只有「纯尾部追加」走顺序写，
  /// 其余通过临时文件重建后原子替换。
  Future<void> write(int offset, List<int> data) async {
    _ensureOpen();
    if (_mode == CryptFileMode.read) {
      throw StateError('Cannot write to file opened in read mode');
    }

    if (data.isEmpty) return;

    final header = _header;
    if (header == null) {
      throw StateError('文件头未初始化，无法确定块 nonce');
    }

    final plainData = Uint8List.fromList(data);
    final oldPlainLen = _decryptedSize;

    // offset 超出现有明文长度时按追加处理（与旧实现的 read 夹取行为一致）
    final effectiveOffset = offset > oldPlainLen ? oldPlainLen : offset;
    final newPlainLen = effectiveOffset + plainData.length;
    final newBlockCount = (newPlainLen + cryptBlockSize - 1) ~/ cryptBlockSize;
    final firstChanged = effectiveOffset ~/ cryptBlockSize;

    // 1. 先在内存中生成所有受影响块的新密文（拼接旧块头需要 _raf 仍可读）
    final changedCount = newBlockCount - firstChanged;
    final newBlocks = List<Uint8List>.filled(changedCount, Uint8List(0));
    final secretBox = SecretBox(_crypt.derivedKeys.dataKey);
    for (var i = 0; i < changedCount; i++) {
      final blockIndex = firstChanged + i;
      newBlocks[i] = await _encryptBlock(
        header, secretBox, blockIndex,
        effectiveOffset, plainData, newPlainLen,
      );
    }

    if (_mode == CryptFileMode.write) {
      // write 模式：FileMode.write 句柄支持定位写（O_TRUNC 已在 open 时发生）
      for (var i = 0; i < changedCount; i++) {
        final blockIndex = firstChanged + i;
        await _raf.setPosition(
            fileHeaderSize + blockIndex * (cryptBlockSize + blockOverhead));
        await _raf.writeFrom(newBlocks[i]);
      }
      await _truncateToNewLayout(newBlockCount, newPlainLen);
      _decryptedSize = newPlainLen;
      return;
    }

    // append 模式
    final pureAppend = effectiveOffset == oldPlainLen &&
        oldPlainLen % cryptBlockSize == 0;
    if (pureAppend) {
      // 纯尾部追加：所有新块都位于现有密文之后，顺序写入自然落在 EOF。
      // 先定位到 EOF：Windows append 按当前位置写；Android O_APPEND 下无影响。
      await _raf.setPosition(await _raf.length());
      for (final block in newBlocks) {
        await _raf.writeFrom(block);
      }
      _decryptedSize = newPlainLen;
      return;
    }

    // 中间写入 / 末尾残块扩展：O_APPEND 定位写不可用 → 临时文件重建后替换
    await _rebuildViaTempFile(header, firstChanged, newBlocks, newPlainLen);
  }

  /// 生成第 [blockIndex] 块的新密文（cipher+tag）。
  ///
  /// 块头若位于覆盖起点之前（跨块写入的首块），从旧密文解出对应前缀拼接。
  Future<Uint8List> _encryptBlock(
    RcloneFileHeader header,
    SecretBox secretBox,
    int blockIndex,
    int effectiveOffset,
    Uint8List plainData,
    int newPlainLen,
  ) async {
    final blockPlainStart = blockIndex * cryptBlockSize;
    final blockPlainLen = (cryptBlockSize < newPlainLen - blockPlainStart)
        ? cryptBlockSize
        : newPlainLen - blockPlainStart;
    final newBlockPlain = Uint8List(blockPlainLen);

    final headKeepLen = effectiveOffset > blockPlainStart
        ? (effectiveOffset - blockPlainStart < blockPlainLen
            ? effectiveOffset - blockPlainStart
            : blockPlainLen)
        : 0;
    if (headKeepLen > 0) {
      final oldBlockPlain =
          _decryptBlock(await _readEncryptedBlock(blockIndex), blockIndex);
      newBlockPlain.setRange(0, headKeepLen, oldBlockPlain);
    }
    final dataStart = blockPlainStart + headKeepLen - effectiveOffset;
    if (dataStart < plainData.length) {
      final copyLen = blockPlainLen - headKeepLen < plainData.length - dataStart
          ? blockPlainLen - headKeepLen
          : plainData.length - dataStart;
      newBlockPlain.setRange(headKeepLen, headKeepLen + copyLen, plainData, dataStart);
    }

    // 用该块派生的 nonce 加密（pinenacl 返回 nonce+cipher+tag，去掉 nonce）
    final blockNonce = deriveBlockNonce(header.nonce, blockIndex);
    final sealed = secretBox.encrypt(newBlockPlain, nonce: blockNonce);
    return Uint8List.fromList(sealed.sublist(secretBoxNonceLength));
  }

  /// 长度变化时把密文文件截断到新的块布局
  Future<void> _truncateToNewLayout(int newBlockCount, int newPlainLen) async {
    final lastPlainLen = newPlainLen - (newBlockCount - 1) * cryptBlockSize;
    final newEncLen = fileHeaderSize +
        (newBlockCount - 1) * (cryptBlockSize + blockOverhead) +
        lastPlainLen +
        blockOverhead;
    final curEncLen = await _raf.length();
    if (curEncLen != newEncLen) {
      await _raf.truncate(newEncLen);
    }
  }

  /// append 模式下无法定位写时的重建路径：
  /// 临时文件 = 头 + 未变化块（从旧文件流式拷贝）+ 新块 → 原子替换。
  /// 内存占用 O(新块)，未变化前缀零重加密、零明文驻留。
  Future<void> _rebuildViaTempFile(
    RcloneFileHeader header,
    int firstChanged,
    List<Uint8List> newBlocks,
    int newPlainLen,
  ) async {
    final tmpPath = '$_path.zw';
    await _raf.close();

    final oldRaf = await File(_path).open(mode: FileMode.read);
    final tmpRaf = await File(tmpPath).open(mode: FileMode.write);
    try {
      await tmpRaf.writeFrom(header.toBytes());
      // 流式拷贝未变化的块 [0, firstChanged)
      final preservedEnd =
          fileHeaderSize + firstChanged * (cryptBlockSize + blockOverhead);
      await oldRaf.setPosition(fileHeaderSize);
      var copied = fileHeaderSize;
      final chunk = Uint8List(1 << 20);
      while (copied < preservedEnd) {
        final n =
            (preservedEnd - copied < chunk.length) ? preservedEnd - copied : chunk.length;
        final bytes = await oldRaf.read(n);
        if (bytes.isEmpty) break;
        await tmpRaf.writeFrom(bytes);
        copied += bytes.length;
      }
      for (final block in newBlocks) {
        await tmpRaf.writeFrom(block);
      }
    } finally {
      await oldRaf.close();
      await tmpRaf.close();
    }

    // 原子替换（Windows 上目标被占用时 rename 会失败，先删再换）
    final tmpFile = File(tmpPath);
    try {
      await tmpFile.rename(_path);
    } catch (_) {
      await File(_path).delete();
      await tmpFile.rename(_path);
    }
    _raf = await File(_path).open(mode: FileMode.append);
    _decryptedSize = newPlainLen;
  }

  /// 读取第 [blockIndex] 个密文块（cipher+tag）
  Future<Uint8List> _readEncryptedBlock(int blockIndex) async {
    final blockSize = cryptBlockSize + blockOverhead;
    await _raf.setPosition(fileHeaderSize + blockIndex * blockSize);
    final blockData = await _raf.read(blockSize);
    if (blockData.length < blockOverhead) {
      throw FormatException('Invalid encrypted block size: ${blockData.length}');
    }
    return Uint8List.fromList(blockData);
  }

  /// 刷新缓冲区
  Future<void> flush() async {
    _ensureOpen();
    await _raf.flush();
  }

  /// 关闭文件
  Future<void> close() async {
    if (_isOpen) {
      try {
        await _raf.flush();
      } catch (_) {
        // flush 可能在某些平台失败，忽略并继续关闭
      }
      try {
        await _raf.close();
      } catch (_) {
        // 忽略关闭错误
      }
      _isOpen = false;
    }
  }

  void _ensureOpen() {
    if (!_isOpen) {
      throw StateError('File is not open');
    }
  }
}
