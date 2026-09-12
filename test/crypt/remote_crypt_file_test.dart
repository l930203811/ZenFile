/// RemoteCryptFile 单元测试
///
/// 用「本地已加密文件 + 伪造的 RemoteClient（按 Range 读该本地文件）」模拟
/// 远程后端，验证客户端解密的块数学：文件头解析、跨块随机读、末尾不足整块、
/// 越界裁剪等，与本地 [CryptFile] 行为保持一致。
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:zenfile/services/crypt/crypt.dart';
import 'package:zenfile/services/remote/remote_client.dart';

/// 伪造的远程客户端：把指定本地加密文件当作「远端文件」，仅实现按 Range 读取。
class _FakeRemoteClient extends RemoteClient {
  final File file;
  _FakeRemoteClient(this.file);

  @override
  Future<void> connect() async {}

  @override
  Future<void> disconnect() async {}

  @override
  Future<int> getFileSize(String remotePath) async => file.lengthSync();

  @override
  Future<void> downloadRange(
    String remotePath,
    String localPath,
    int startByte,
    int length,
  ) async {
    final bytes = await file.readAsBytes();
    final end = (startByte + length > bytes.length)
        ? bytes.length
        : startByte + length;
    final safeStart = startByte.clamp(0, bytes.length);
    final slice = bytes.sublist(safeStart, end < safeStart ? safeStart : end);
    await File(localPath).writeAsBytes(slice, flush: true);
  }

  @override
  Future<List<RemoteFileItem>> listDirectory(String path,
          {bool forceRefresh = false}) async =>
      const [];

  @override
  Future<void> createDirectory(String path) async {}

  @override
  Future<void> createFile(String path) async {}

  @override
  Future<void> delete(String path, bool isDir) async {}

  @override
  Future<void> rename(String oldPath, String newPath) async {}

  @override
  Future<void> downloadFile(
    String remotePath,
    String localPath,
    Function(double) onProgress,
  ) async {}

  @override
  Future<void> uploadFile(
    String localPath,
    String remotePath,
    Function(double) onProgress,
  ) async {}

  @override
  Future<String?> getStreamUrl(String remotePath) async => null;
}

/// 把明文按 rclone crypt 格式加密写入 [dir] 下的文件，返回（文件, 密文）
Future<(File, Uint8List)> _makeEncrypted(
  Directory dir,
  RcloneCrypt crypt,
  List<int> plain,
  String name,
) async {
  final encrypter = crypt.createEncrypter();
  final out = <int>[
    ...encrypter.process(plain),
    ...encrypter.finish(),
  ];
  final f = File('${dir.path}/$name');
  await f.writeAsBytes(out, flush: true);
  return (f, Uint8List.fromList(out));
}

void main() {
  late Directory tmp;
  final crypt = RcloneCrypt(
    config: const RcloneCryptConfig(password: 'test-password', salt: 'test-salt'),
  );

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('zenfile_rc_test');
  });

  tearDown(() async {
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });

  test('小文件（单块以内）解密读取', () async {
    final plain = List<int>.generate(1000, (i) => (i * 7 + 3) & 0xFF);
    final (file, _) = await _makeEncrypted(tmp, crypt, plain, 'small.bin');
    final rf = await RemoteCryptFile.open('/small.bin', crypt, _FakeRemoteClient(file));

    expect(rf.length, plain.length);
    expect(await rf.read(0), equals(plain));
    expect(await rf.read(100, 50), equals(plain.sublist(100, 150)));
  });

  test('多块文件：整读、跨块随机读、尾部读取', () async {
    // 约 3 个块（200000 > 2*65536），覆盖跨块与末尾不足整块
    final plain = List<int>.generate(200000, (i) => (i * 37 + 11) & 0xFF);
    final (file, _) = await _makeEncrypted(tmp, crypt, plain, 'big.bin');
    final rf = await RemoteCryptFile.open('/big.bin', crypt, _FakeRemoteClient(file));

    expect(rf.length, plain.length);
    // 整读
    expect(await rf.read(0), equals(plain));
    // 跨块边界（65536 前后）
    expect(await rf.read(65500, 200), equals(plain.sublist(65500, 65700)));
    // 恰好从一个块起点读到末尾
    expect(await rf.read(131072), equals(plain.sublist(131072)));
    // 尾部：超出末尾自动裁剪
    expect(await rf.read(199000, 5000), equals(plain.sublist(199000)));
  });

  test('恰好 64KB（单整块）与偏移越界', () async {
    final plain = List<int>.generate(64 * 1024, (i) => (i * 13 + 5) & 0xFF);
    final (file, _) = await _makeEncrypted(tmp, crypt, plain, 'block.bin');
    final rf = await RemoteCryptFile.open('/block.bin', crypt, _FakeRemoteClient(file));

    expect(rf.length, plain.length);
    expect(await rf.read(0), equals(plain));
    // offset == length → 空
    expect(await rf.read(plain.length), isEmpty);
    // offset > length → 空
    expect(await rf.read(plain.length + 10, 100), isEmpty);
  });
}
