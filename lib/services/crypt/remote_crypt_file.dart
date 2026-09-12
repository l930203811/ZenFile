/// 远程加密文件随机读取（客户端解密）
///
/// 镜像 [CryptFile] 的内容解密逻辑，但密文来自远程后端
/// （SFTP / WebDAV / SMB / FTP 上的 rclone crypt 文件）：
/// 通过 [RemoteClient.downloadRange] 按块拉取密文区间到本地临时文件，
/// 再用客户端密钥在本地解密，从而支持「边取边解边播」的随机读（seek）。
///
/// v1 只读：仅实现读取，不做远程写入。
library;

import 'dart:io';
import 'dart:typed_data';
import 'package:pinenacl/api.dart';
import 'package:pinenacl/src/authenticated_encryption/secret.dart';
import '../remote/remote_client.dart';
import '../webdav_debug_log.dart';
import 'rclone_crypt.dart';

class RemoteCryptFile {
  /// 服务器端密文文件路径
  final String _serverPath;
  final RcloneCrypt _crypt;
  final RemoteClient _client;

  RcloneFileHeader? _header;
  int _decryptedSize = 0;
  bool _isOpen = false;

  /// 密文总大小（[open] 时取一次并缓存）。
  ///
  /// ⚠️ 此前 [read] 每次都调用 `client.getFileSize()` —— 流式服务器按 64KB 分块，
  /// 等于**每 64KB 就要多一次网络往返**（getFileSize + downloadRange 共 2 次）。
  /// 播放几百 MB 的视频时往返次数上千，实测表现为「进了播放页但速率几乎不动」。
  /// 密文大小在播放期间不会变化，缓存即可。
  int _encSize = 0;

  RemoteCryptFile._(this._serverPath, this._crypt, this._client);

  /// 打开远程加密文件（下载文件头并解析 nonce / 明文大小）
  static Future<RemoteCryptFile> open(
    String serverPath,
    RcloneCrypt crypt,
    RemoteClient client,
  ) async {
    final file = RemoteCryptFile._(serverPath, crypt, client);
    await file._open();
    return file;
  }

  Future<void> _open() async {
    // 下载 32 字节文件头（magic + nonce）
    final tmp = _tmpFilePath();
    try {
      await _client.downloadRange(_serverPath, tmp, 0, fileHeaderSize);
    } catch (e) {
      await _safeDelete(tmp);
      rethrow;
    }
    final head = await File(tmp).readAsBytes();
    await _safeDelete(tmp);
    if (head.length < fileHeaderSize) {
      throw FormatException('远程加密文件头不完整: ${head.length} 字节');
    }
    _header = RcloneFileHeader.parse(head);
    final encSize = await _resolveEncryptedSize();
    _encSize = encSize;
    _decryptedSize = calculateDecryptedSize(encSize);
    _isOpen = true;
  }

  /// 确定密文总大小。
  ///
  /// ⚠️ 不能只信 `client.getFileSize()`：部分后端（OpenList 302 模式 / 某些
  /// WebDAV 实现）对它返回 **-1 或 0**，于是 `calculateDecryptedSize` 得到 0，
  /// 流式服务器直接 404 —— 表现为「能进播放页、图片黑屏、零下载」。
  /// 兜底走**父目录枚举**：枚举路径已被浏览页验证可用，其 `size` 就是密文大小。
  Future<int> _resolveEncryptedSize() async {
    final direct = await _client.getFileSize(_serverPath);
    if (direct > fileHeaderSize) return direct;

    final idx = _serverPath.lastIndexOf('/');
    if (idx <= 0) return direct;
    final parent = _serverPath.substring(0, idx);
    final name = _serverPath.substring(idx + 1);
    WebdavDebugLog.log(
        '远程加密 getFileSize 无效($direct)，回退父目录枚举: $_serverPath');
    try {
      final items = await _client.listDirectory(parent);
      for (final it in items) {
        if (it.path == _serverPath || it.name == name) {
          if (it.size > fileHeaderSize) {
            WebdavDebugLog.log('远程加密 父目录枚举取到密文大小=${it.size}');
            return it.size;
          }
        }
      }
      WebdavDebugLog.log('远程加密 父目录枚举未找到该条目: $name');
    } catch (e) {
      WebdavDebugLog.log('远程加密 父目录枚举失败: $e');
    }
    return direct;
  }

  /// 解密后的文件大小
  int get length => _decryptedSize;

  /// 文件是否已打开
  bool get isOpen => _isOpen;

  /// 从指定偏移读取指定长度的明文数据
  ///
  /// [offset] 明文偏移（从 0 开始），[length] 要读取的字节数（默认读到文件末尾）。
  Future<Uint8List> read(int offset, [int? length]) async {
    _ensureOpen();

    var readLength = length;
    if (readLength == null || offset + readLength > _decryptedSize) {
      readLength = _decryptedSize - offset;
    }
    if (readLength <= 0 || offset >= _decryptedSize) {
      return Uint8List(0);
    }

    final startBlock = offset ~/ cryptBlockSize;
    final endBlock = (offset + readLength - 1) ~/ cryptBlockSize;
    final encStart =
        fileHeaderSize + startBlock * (cryptBlockSize + blockOverhead);
    var encEnd =
        fileHeaderSize + (endBlock + 1) * (cryptBlockSize + blockOverhead);

    // 末尾块可能不足一个整块：按真实加密大小裁切，避免越界下载。
    final encSize = _encSize > fileHeaderSize
        ? _encSize
        : await _client.getFileSize(_serverPath);
    if (encSize > fileHeaderSize && encEnd > encSize) encEnd = encSize;
    if (encEnd <= encStart) return Uint8List(0);

    // 一次拉取覆盖所需所有块的密文区间（远少于「每块一次请求」）
    final tmp = _tmpFilePath();
    try {
      await _client.downloadRange(_serverPath, tmp, encStart, encEnd - encStart);
    } catch (e) {
      await _safeDelete(tmp);
      rethrow;
    }
    final encBytes = await File(tmp).readAsBytes();
    await _safeDelete(tmp);

    final result = BytesBuilder();
    const blockLen = cryptBlockSize + blockOverhead;
    for (var blockIndex = startBlock; blockIndex <= endBlock; blockIndex++) {
      final blockOffsetInBuffer = (blockIndex - startBlock) * blockLen;
      final avail = encBytes.length - blockOffsetInBuffer;
      if (avail <= 0) break;
      // ⚠️ 每个块只取 `blockLen` 字节（最后一块可能不足整块，取 avail）。
      // 切勿取「到缓冲区末尾」——多块时会把后续块也一起吃进来导致解密失败。
      final take = avail < blockLen ? avail : blockLen;
      final blockData = Uint8List.sublistView(
        encBytes,
        blockOffsetInBuffer,
        blockOffsetInBuffer + take,
      );
      final plainBlock = _decryptBlock(blockData, blockIndex);

      final blockStart = blockIndex * cryptBlockSize;
      final blockEnd = blockStart + plainBlock.length;
      final copyStart = offset > blockStart ? offset - blockStart : 0;
      final copyEnd = (offset + readLength) < blockEnd
          ? (offset + readLength) - blockStart
          : plainBlock.length;
      if (copyEnd > copyStart) {
        result.add(plainBlock.sublist(copyStart, copyEnd));
      }
    }
    return result.toBytes();
  }

  /// 解密单个块。rclone 块格式：`ciphertext + tag(16)`，nonce 由
  /// 「文件头 nonce + blockIndex」派生（与 [CryptFile] 完全一致）。
  Uint8List _decryptBlock(Uint8List blockData, int blockIndex) {
    if (blockData.length < blockOverhead) {
      throw FormatException('无效的加密块大小: ${blockData.length}');
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

  Future<void> close() async {
    _isOpen = false;
  }

  void _ensureOpen() {
    if (!_isOpen) {
      throw StateError('File is not open');
    }
  }

  String _tmpFilePath() {
    final dir = Directory.systemTemp.path;
    return '$dir/zenfile_rc_${DateTime.now().microsecondsSinceEpoch}_'
        '${identityHashCode(this)}.bin';
  }

  Future<void> _safeDelete(String path) async {
    try {
      final f = File(path);
      if (await f.exists()) await f.delete();
    } catch (_) {}
  }
}
