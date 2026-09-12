/// CryptStreamServer 远程加密（cryptremote）流式解密端到端测试
///
/// 用「本地已加密文件 + 伪造 RemoteClient（按 Range 读该文件）」模拟远程后端，
/// 真正启动 CryptStreamServer 并发 HTTP 请求，验证：
/// * 流式 URL 形如 `http://127.0.0.1:PORT/decrypt.mp4?path=...`（非 cryptremote:// 原样返回）；
/// * 完整 GET 能拿到**解密后**的明文（远程加密播放/看图的核心链路）；
/// * Range 请求返回 206 且区间正确（媒体播放器 seek 依赖）；
/// * 挂载点未注册时不会崩溃/挂起。
///
/// 远程加密播放问题几乎只能靠真机复现，这个测试把「服务器 + 块解密 + HTTP」
/// 三段在本机串起来，避免出现「改完只能靠用户真机试」的情况。
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:zenfile/models/network_connection_model.dart';
import 'package:zenfile/services/crypt/crypt.dart';
import 'package:zenfile/services/crypt/crypt_mount.dart';
import 'package:zenfile/services/crypt/crypt_stream_server.dart';
import 'package:zenfile/services/remote/remote_client.dart';

/// 伪造的远程客户端：把指定本地加密文件当作「远端文件」，仅实现按 Range 读取。
class _FakeRemoteClient extends RemoteClient {
  final File file;
  final List<String> requested = [];

  /// 为 true 时 `getFileSize` 返回 -1（模拟 OpenList 302 模式 / 某些 WebDAV
  /// 实现拿不到真实大小的情况），迫使实现走父目录枚举兜底。
  final bool brokenFileSize;

  _FakeRemoteClient(this.file, {this.brokenFileSize = false});

  @override
  Future<void> connect() async {}

  @override
  Future<void> disconnect() async {}

  @override
  Future<int> getFileSize(String remotePath) async =>
      brokenFileSize ? -1 : file.lengthSync();

  @override
  Future<void> downloadRange(
    String remotePath,
    String localPath,
    int startByte,
    int length,
  ) async {
    requested.add(remotePath);
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
      {bool forceRefresh = false}) async {
    if (!brokenFileSize) return const [];
    final name = file.uri.pathSegments.last;
    return [
      RemoteFileItem(
        name: name,
        path: '$path/$name',
        isDirectory: false,
        size: file.lengthSync(),
        modified: DateTime.now(),
      ),
    ];
  }

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

void main() {
  late Directory tmp;
  final crypt = RcloneCrypt(
    config: const RcloneCryptConfig(password: 'test-password', salt: 'test-salt'),
  );
  const connId = 'conn-1';
  const basePath = '/crypt';

  final conn = NetworkConnectionModel(
    id: connId,
    name: 'fake',
    type: 'webdav',
    host: '127.0.0.1',
    port: 80,
    username: 'u',
    password: 'p',
  );

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('zenfile_stream_test');
  });

  tearDown(() async {
    CryptStreamServer.remoteClientFactoryForTest = null;
    CryptStreamServer.connectionResolverForTest = null;
    try {
      await CryptStreamServer.instance.close();
    } catch (_) {}
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });

  /// 准备一个「远程加密文件」：明文 → 加密写入本地 → 由 [_FakeRemoteClient] 代理读取。
  /// 返回密文文件名（用真实的文件名加密算法生成）与明文。
  Future<(String, List<int>)> _prepareRemoteFile(List<int> plain, String realName) async {
    final encrypter = crypt.createEncrypter();
    final out = <int>[...encrypter.process(plain), ...encrypter.finish()];
    final cipherName = crypt.encryptFileName(realName);
    final f = File('${tmp.path}/$cipherName');
    await f.writeAsBytes(out, flush: true);
    return (cipherName, plain);
  }

  Future<CryptMountPoint> _registerMount() async {
    final mount = CryptMountPoint.remote(
      connId: connId,
      basePath: basePath,
      config: crypt.config,
    );
    await CryptStreamServer.instance.ensureInitialized();
    CryptStreamServer.instance.registerRemoteMount(mount);
    return mount;
  }

  test('流式 URL 必须是 http 且带真实扩展名', () async {
    final (cipherName, _) = await _prepareRemoteFile(
      List<int>.generate(1000, (i) => (i * 7 + 3) & 0xFF),
      'movie.mp4',
    );
    await _registerMount();

    final virtualPath = 'cryptremote://$connId|$basePath/$cipherName';
    final url = CryptStreamServer.instance.getStreamUrl(virtualPath);

    // 关键回归点：端口未就绪时会原样返回 cryptremote://…，播放器拿到非 http
    // 地址会「静默失败」（进得了播放页但零下载）。
    expect(url.startsWith('http://127.0.0.1'), isTrue, reason: '实际 URL: $url');
    expect(url.contains('/decrypt.mp4'), isTrue, reason: '实际 URL: $url');
    expect(url.contains('path='), isTrue);
  });

  test('完整 GET 返回解密后的明文', () async {
    final plain = List<int>.generate(200000, (i) => (i * 37 + 11) & 0xFF);
    final (cipherName, _) = await _prepareRemoteFile(plain, 'movie.mp4');
    final fakeClient = _FakeRemoteClient(File('${tmp.path}/$cipherName'));
    CryptStreamServer.remoteClientFactoryForTest = (c) async => fakeClient;
    CryptStreamServer.connectionResolverForTest = (id) => id == connId ? conn : null;
    await _registerMount();

    final virtualPath = 'cryptremote://$connId|$basePath/$cipherName';
    final url = CryptStreamServer.instance.getStreamUrl(virtualPath);

    final client = HttpClient();
    try {
      final req = await client.getUrl(Uri.parse(url));
      final resp = await req.close();
      expect(resp.statusCode, HttpStatus.ok);
      final body = await resp.fold<BytesBuilder>(
        BytesBuilder(),
        (b, chunk) => b..add(chunk),
      );
      final got = body.takeBytes();
      expect(got.length, plain.length);
      expect(got, equals(Uint8List.fromList(plain)));
      // 服务器确实向「远程」拉过数据（路径是后端密文全路径，不是虚拟路径）
      expect(fakeClient.requested, isNotEmpty);
      expect(fakeClient.requested.first, '$basePath/$cipherName');
    } finally {
      client.close();
    }
  });

  test('getFileSize 返回 -1 时回退父目录枚举（OpenList 实测场景）', () async {
    final plain = List<int>.generate(120000, (i) => (i * 17 + 5) & 0xFF);
    final (cipherName, _) = await _prepareRemoteFile(plain, 'photo.jpg');
    final fakeClient =
        _FakeRemoteClient(File('${tmp.path}/$cipherName'), brokenFileSize: true);
    CryptStreamServer.remoteClientFactoryForTest = (c) async => fakeClient;
    CryptStreamServer.connectionResolverForTest =
        (id) => id == connId ? conn : null;
    await _registerMount();

    final virtualPath = 'cryptremote://$connId|$basePath/$cipherName';
    final url = CryptStreamServer.instance.getStreamUrl(virtualPath);

    final client = HttpClient();
    try {
      final req = await client.getUrl(Uri.parse(url));
      final resp = await req.close();
      // 兜底失效时这里会是 404（解密大小被算成 0），正是用户报的
      // 「进了查看器但黑屏 / 播放页零下载」。
      expect(resp.statusCode, HttpStatus.ok, reason: '解密大小应来自父目录枚举');
      final body = await resp.fold<BytesBuilder>(
        BytesBuilder(),
        (b, chunk) => b..add(chunk),
      );
      expect(body.takeBytes(), equals(Uint8List.fromList(plain)));
    } finally {
      client.close();
    }
  });

  test('Range 请求返回 206 且区间正确（播放器 seek 依赖）', () async {
    final plain = List<int>.generate(200000, (i) => (i * 37 + 11) & 0xFF);
    final (cipherName, _) = await _prepareRemoteFile(plain, 'movie.mp4');
    final fakeClient = _FakeRemoteClient(File('${tmp.path}/$cipherName'));
    CryptStreamServer.remoteClientFactoryForTest = (c) async => fakeClient;
    CryptStreamServer.connectionResolverForTest = (id) => id == connId ? conn : null;
    await _registerMount();

    final virtualPath = 'cryptremote://$connId|$basePath/$cipherName';
    final url = CryptStreamServer.instance.getStreamUrl(virtualPath);

    final client = HttpClient();
    try {
      final req = await client.getUrl(Uri.parse(url));
      req.headers.set(HttpHeaders.rangeHeader, 'bytes=65500-65699');
      final resp = await req.close();
      expect(resp.statusCode, HttpStatus.partialContent);
      expect(resp.headers.value(HttpHeaders.contentRangeHeader),
          'bytes 65500-65699/200000');
      final body = await resp.fold<BytesBuilder>(
        BytesBuilder(),
        (b, chunk) => b..add(chunk),
      );
      expect(body.takeBytes(), equals(Uint8List.fromList(plain.sublist(65500, 65700))));
    } finally {
      client.close();
    }
  });

  test('多次 Range 复用同一条远程连接（不重复 connect）', () async {
    final plain = List<int>.generate(200000, (i) => (i * 37 + 11) & 0xFF);
    final (cipherName, _) = await _prepareRemoteFile(plain, 'movie.mp4');
    final fakeClient = _FakeRemoteClient(File('${tmp.path}/$cipherName'));
    var buildCount = 0;
    CryptStreamServer.remoteClientFactoryForTest = (c) async {
      buildCount++;
      return fakeClient;
    };
    CryptStreamServer.connectionResolverForTest = (id) => id == connId ? conn : null;
    await _registerMount();

    final virtualPath = 'cryptremote://$connId|$basePath/$cipherName';
    final url = CryptStreamServer.instance.getStreamUrl(virtualPath);

    final client = HttpClient();
    try {
      for (final r in ['bytes=0-99', 'bytes=100-199', 'bytes=200-299']) {
        final req = await client.getUrl(Uri.parse(url));
        req.headers.set(HttpHeaders.rangeHeader, r);
        final resp = await req.close();
        expect(resp.statusCode, HttpStatus.partialContent);
        await resp.drain<void>();
      }
    } finally {
      client.close();
    }
    // 每个 Range 都重建连接会造成连接风暴/服务端限流，必须复用。
    expect(buildCount, 1);
  });

  test('挂载点未注册时返回 404 而不是崩溃', () async {
    final (cipherName, _) = await _prepareRemoteFile(
      List<int>.generate(1000, (i) => i & 0xFF),
      'movie.mp4',
    );
    await CryptStreamServer.instance.ensureInitialized();
    // 故意不注册挂载点

    final virtualPath = 'cryptremote://$connId|$basePath/$cipherName';
    final url = CryptStreamServer.instance.getStreamUrl(virtualPath);
    expect(url.startsWith('http://127.0.0.1'), isTrue);

    final client = HttpClient();
    try {
      final req = await client.getUrl(Uri.parse(url));
      final resp = await req.close();
      expect(resp.statusCode, HttpStatus.notFound);
      await resp.drain<void>();
    } finally {
      client.close();
    }
  });
}
