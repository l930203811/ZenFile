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

  /// 使用指定密钥解密单个块
  Uint8List _decryptWithKey(Uint8List key, Uint8List ciphertextAndTag, Uint8List nonce) {
    // 使用 pinenacl SecretBox 直接解密单个块
    // 块格式：ciphertext + tag，nonce 通过参数传入
    final secretBox = SecretBox(key);
    return Uint8List.fromList(
      secretBox.decrypt(ByteList(ciphertextAndTag), nonce: nonce),
    );
  }

  /// 从指定偏移写入明文数据（自动加密）
  ///
  /// [offset] 明文偏移（从 0 开始）
  /// [data] 要写入的明文数据
  Future<void> write(int offset, List<int> data) async {
    _ensureOpen();
    if (_mode == CryptFileMode.read) {
      throw StateError('Cannot write to file opened in read mode');
    }

    if (data.isEmpty) return;

    // 简化实现：将数据分块加密后写入
    // 注意：这是一个简化实现，不支持在文件中间插入数据（会覆盖后续内容）
    // 完整的随机写入需要读取-修改-写回受影响的块

    final encrypter = RcloneStreamEncrypter(
      dataKey: _crypt.derivedKeys.dataKey,
      header: _header,
    );

    // 如果 offset > 0，需要先读取现有数据并保留
    // 统一处理：读取现有内容（如果需要），然后重新加密整个文件
    // 这样可以确保所有块使用连续的 nonce，且避免 append 模式下 setPosition 不生效的问题
    List<int> allData;
    if (offset == 0) {
      allData = data;
    } else {
      // 读取现有数据到 offset 位置
      final existingData = await read(0, offset);
      allData = <int>[...existingData, ...data];
    }

    final encrypted = <int>[
      ...encrypter.process(allData),
      ...encrypter.finish(),
    ];

    // 关闭当前文件，用 writeAsBytes 写入整个文件，然后重新打开
    // 注意：append 模式下 setPosition 不影响写入位置，所以需要这种方式
    await _raf.close();
    await File(_path).writeAsBytes(encrypted);

    // 重新打开文件：使用 append 模式（不会截断文件）
    // 注意：write 模式下使用 FileMode.write 会截断文件，导致刚刚写入的数据丢失
    _raf = await File(_path).open(mode: FileMode.append);

    _decryptedSize = allData.length;
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

/// 扩展方法，用于 let 表达式
extension _LetExtension<T> on T {
  R let<R>(R Function(T) block) => block(this);
}
