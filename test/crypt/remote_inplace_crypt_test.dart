/// 远程原地加密 / 解密 + 「远程密文复制到本地即明文」的端到端回归。
///
/// 对应三条用户诉求：
/// 1. 远程加密文件复制/剪切到本地 → 先过保险箱闸门，落盘即**明文**（不再是一份密文）；
/// 2. 远程目录菜单里的「加密 / 解密」不能报错：加密 = 下载 → 本地加密 → 回传覆盖；
///    解密 = 下载留存本地 → 明文回写替换服务端原密文；
/// 3. 远程加解密的进度弹窗与本地一致（双层圆环 ⇒ 必须喂真实的字节级进度）。
///
/// 实现方式：用**真实临时目录**冒充远程后端（[_FakeServerClient]），
/// 把 `FileManagerProvider` 真正跑起来（真挂载点、真 rclone crypt、真文件字节），
/// 只把「远程客户端」和「临时目录根」两处换成注入点，避免只能靠真机复现。
///
/// 关键不变量（改这条链路时不要破坏）：
/// * **先上传成功，才删除原件** —— 任何时刻都不会出现「两边都没有」的空窗；
/// * 原地加密后父目录必须登记为「关联的远程加密目录」，否则服务端只剩一串
///   base32 密文名，用户看起来就是文件被搞坏了；
/// * 目录内已无密文时要注销登记，否则同目录里后来放进去的明文会被当成密文。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zenfile/models/network_connection_model.dart';
import 'package:zenfile/providers/file_manager_provider.dart';
import 'package:zenfile/services/crypt/crypt.dart';
import 'package:zenfile/services/network_connections_service.dart';
import 'package:zenfile/services/preferences_service.dart';
import 'package:zenfile/services/remote/remote_client.dart';

/// 用真实临时目录冒充远程后端的客户端。
///
/// 服务端路径（`/crypt/a.txt`）直接映射到 `root/crypt/a.txt`，于是加解密链路里
/// 所有「字节是否真的变了」都能用 `File(...).readAsBytes()` 直接断言。
/// 目录删除刻意做成**非递归**（真实 FTP/SFTP 的 `delete(dir)` 也常只删空目录），
/// 以此验证 `_deleteRemoteTree` 的自底向上兜底真的生效。
class _FakeServerClient extends RemoteClient {
  _FakeServerClient(this.root);

  final Directory root;
  final List<String> calls = [];

  String _local(String remote) {
    final segs = remote.split('/').where((s) => s.isNotEmpty);
    return p.joinAll([root.path, ...segs]);
  }

  String _remoteOf(String name, String parent) {
    final rel = p.relative(p.join(_local(parent), name), from: root.path);
    return '/${rel.replaceAll('\\', '/')}';
  }

  @override
  Future<void> connect() async {}

  @override
  Future<void> disconnect() async {}

  @override
  Future<List<RemoteFileItem>> listDirectory(
    String path, {
    bool forceRefresh = false,
  }) async {
    calls.add('list:$path');
    final dir = Directory(_local(path));
    if (!dir.existsSync()) return const [];
    final out = <RemoteFileItem>[];
    for (final e in dir.listSync()) {
      final name = p.basename(e.path);
      final st = e.statSync();
      out.add(RemoteFileItem(
        name: name,
        path: _remoteOf(name, path),
        isDirectory: e is Directory,
        size: e is Directory ? 0 : st.size,
        modified: st.modified,
      ));
    }
    return out;
  }

  @override
  Future<void> createDirectory(String path) async {
    Directory(_local(path)).createSync(recursive: true);
  }

  @override
  Future<void> createFile(String path) async {
    final f = File(_local(path));
    f.parent.createSync(recursive: true);
    f.createSync();
  }

  @override
  Future<void> delete(String path, bool isDir) async {
    calls.add('delete:$path');
    // 非递归：目录非空时抛错，逼调用方先把子项清干净。
    if (isDir) {
      Directory(_local(path)).deleteSync();
    } else {
      File(_local(path)).deleteSync();
    }
  }

  @override
  Future<void> rename(String oldPath, String newPath) async {
    final from = _local(oldPath);
    final to = _local(newPath);
    Directory(p.dirname(to)).createSync(recursive: true);
    if (Directory(from).existsSync()) {
      Directory(from).renameSync(to);
    } else {
      File(from).renameSync(to);
    }
  }

  @override
  Future<void> downloadFile(
    String remotePath,
    String localPath,
    Function(double) onProgress,
  ) async {
    calls.add('download:$remotePath');
    final bytes = await File(_local(remotePath)).readAsBytes();
    final dst = File(localPath);
    await dst.parent.create(recursive: true);
    await dst.writeAsBytes(bytes, flush: true);
    onProgress(0.5);
    onProgress(1.0);
  }

  @override
  Future<void> downloadRange(
    String remotePath,
    String localPath,
    int startByte,
    int length,
  ) async {
    final bytes = await File(_local(remotePath)).readAsBytes();
    final start = startByte.clamp(0, bytes.length);
    final end = (start + length).clamp(start, bytes.length);
    await File(localPath).writeAsBytes(bytes.sublist(start, end), flush: true);
  }

  @override
  Future<void> uploadFile(
    String localPath,
    String remotePath,
    Function(double) onProgress,
  ) async {
    calls.add('upload:$remotePath');
    final bytes = await File(localPath).readAsBytes();
    final dst = File(_local(remotePath));
    await dst.parent.create(recursive: true);
    await dst.writeAsBytes(bytes, flush: true);
    onProgress(0.5);
    onProgress(1.0);
  }

  @override
  Future<String?> getStreamUrl(String remotePath) async => null;

  @override
  Future<int> getFileSize(String remotePath) async {
    final f = File(_local(remotePath));
    return f.existsSync() ? f.lengthSync() : -1;
  }
}

void main() {
  // `FileManagerProvider._gateContext` 兜底会读 `navigatorKey.currentContext`
  // （即 `WidgetsBinding.instance`），必须先把测试 binding 初始化好，否则
  // 会用「Binding has not yet been initialized」把整条链路打断。
  TestWidgetsFlutterBinding.ensureInitialized();

  const connId = 'conn-inplace';
  const serverBase = '/crypt';

  late Directory serverRoot;
  late Directory localRoot;
  late _FakeServerClient client;
  late FileManagerProvider provider;
  late NetworkConnectionModel conn;

  /// 与 `VaultCryptService._loadLegacyConfig()` 从 mock SharedPreferences 读出来的
  /// 完全一致（见 setUp 里的键值）—— 测试里用它算期望的密文名。
  final cfg = RcloneCryptConfig(
    password: 'test-pw',
    salt: 'test-salt',
    filenameEncryption: FilenameEncryption.standard,
    directoryNameEncryption: true,
    filenameEncoding: FilenameEncoding.base32,
    encryptedSuffix: '.bin',
  );
  final crypt = RcloneCrypt(config: cfg);

  List<int> payload(int size) =>
      List<int>.generate(size, (i) => (i * 37 + 11) & 0xff);

  File serverFile(String name, [String dir = serverBase]) => File(p.joinAll([
        serverRoot.path,
        ...dir.split('/').where((s) => s.isNotEmpty),
        name,
      ]));

  /// 把明文加密写成服务端密文文件（模拟「这个目录本来就是加密目录」）。
  Future<String> putCipher(String plainName, List<int> plain) async {
    final encName = crypt.encryptFileName(plainName);
    final f = serverFile(encName);
    final cf = await CryptFile.open(f.path, crypt, mode: CryptFileMode.write);
    await cf.write(0, plain);
    await cf.close();
    return encName;
  }

  /// 按主密码解开一个本地文件，返回明文。
  Future<List<int>> readPlain(String path) async {
    final cf = await CryptFile.open(path, crypt);
    final out = <int>[];
    var pos = 0;
    while (pos < cf.length) {
      final chunk = await cf.read(pos, cf.length - pos);
      if (chunk.isEmpty) break;
      out.addAll(chunk);
      pos += chunk.length;
    }
    await cf.close();
    return out;
  }

  setUp(() async {
    // 保险箱主密码：走 legacy 单组凭据（档案库为空时 getMasterConfig 会回退到它）。
    SharedPreferences.setMockInitialValues({
      VaultCryptService.kMasterPasswordKey: 'test-pw',
      VaultCryptService.kMasterSaltKey: 'test-salt',
      VaultCryptService.kFilenameEncodingKey: 'base32',
      VaultCryptService.kEncryptedSuffixKey: '.bin',
    });
    await PreferencesService.init();

    serverRoot = await Directory.systemTemp.createTemp('zenfile_srv_');
    localRoot = await Directory.systemTemp.createTemp('zenfile_loc_');
    await Directory(p.join(serverRoot.path, 'crypt')).create(recursive: true);

    client = _FakeServerClient(serverRoot);
    conn = NetworkConnectionModel(
      id: connId,
      name: 'fake-remote',
      type: 'WebDav',
      host: '127.0.0.1',
      port: 80,
      username: 'u',
      password: 'p',
    );
    NetworkConnectionsService.builderForTest = (_) => client;
    await NetworkConnectionsService.saveConnection(conn);

    FileManagerProvider.cryptTempRootOverride =
        p.join(localRoot.path, 'crypt_tmp');

    provider = FileManagerProvider();
    // 直接把当前标签页摆成「已连接、正在浏览 /crypt 的远程标签」，
    // 省掉 openRemoteTab 里那一整套远端列目录的初始化。
    final tab = provider.activeTab;
    tab.isRemote = true;
    tab.remoteClient = client;
    tab.remoteConnection = conn;
    tab.currentPath = serverBase;
  });

  tearDown(() async {
    NetworkConnectionsService.builderForTest = null;
    FileManagerProvider.cryptTempRootOverride = null;
    try {
      await CryptStreamServer.instance.close();
    } catch (_) {}
    try {
      if (await serverRoot.exists()) await serverRoot.delete(recursive: true);
    } catch (_) {}
    try {
      if (await localRoot.exists()) await localRoot.delete(recursive: true);
    } catch (_) {}
  });

  group('远程原地加密（菜单里的「加密」不再报错）', () {
    test('单文件：服务端换成密文名 + 真密文内容，原明文被删除', () async {
      final plain = payload(5000);
      final src = serverFile('note.txt');
      await src.writeAsBytes(plain, flush: true);

      await provider.encryptRemoteInPlace(['$serverBase/note.txt']);

      expect(src.existsSync(), isFalse, reason: '上传成功后原明文必须删除');
      final encName = crypt.encryptFileName('note.txt');
      final cipher = serverFile(encName);
      expect(cipher.existsSync(), isTrue, reason: '服务端应出现密文名文件');
      expect(await CryptOperations.isEncryptedFile(cipher.path), isTrue);
      // 内容必须能按主密码原样解回来 —— 这是「加密没搞坏文件」的硬证据。
      expect(await readPlain(cipher.path), plain);
    });

    test('加密后父目录被登记为「关联的远程加密目录」', () async {
      await serverFile('a.txt').writeAsBytes(payload(128), flush: true);

      await provider.encryptRemoteInPlace(['$serverBase/a.txt']);

      final records = await CryptMountService.loadRemoteEncryptedDirs();
      expect(
        records.where((r) => r.connId == connId && r.serverPath == serverBase),
        isNotEmpty,
        reason: '不登记的话，用户回到该目录只会看到一串 base32 乱码名',
      );
    });

    test('目录递归加密，并删除原目录（非递归 delete 需自底向上兜底）', () async {
      final dir = Directory(p.join(serverRoot.path, 'crypt', 'Docs'))
        ..createSync(recursive: true);
      await File(p.join(dir.path, 'a.txt')).writeAsBytes(payload(300), flush: true);
      await File(p.join(dir.path, 'b.txt')).writeAsBytes(payload(700), flush: true);

      await provider.encryptRemoteInPlace(['$serverBase/Docs']);

      expect(dir.existsSync(), isFalse, reason: '原明文目录必须删除');
      final encDir = Directory(
        p.join(serverRoot.path, 'crypt', crypt.encryptDirName('Docs')),
      );
      expect(encDir.existsSync(), isTrue);
      final names = encDir.listSync().map((e) => p.basename(e.path)).toSet();
      expect(names, {
        crypt.encryptFileName('a.txt'),
        crypt.encryptFileName('b.txt'),
      });
      expect(
        await readPlain(p.join(encDir.path, crypt.encryptFileName('a.txt'))),
        payload(300),
      );
    });

    test('目录「加密 → 解密 → 再加密」：第二次加密仍必须把目录名换成密文', () async {
      // 用户反馈：原地加密 → 解密 → 再次原地加密时，目录名仍是明文
      // （目录内的文件倒是加密了）。用真实字节复刻整条往返链路。
      final dir = Directory(p.join(serverRoot.path, 'crypt', 'Docs'))
        ..createSync(recursive: true);
      await File(p.join(dir.path, 'a.txt')).writeAsBytes(payload(300), flush: true);

      // ① 首次原地加密
      await provider.encryptRemoteInPlace(['$serverBase/Docs']);
      final encDirName = crypt.encryptDirName('Docs');
      final encDir = Directory(p.join(serverRoot.path, 'crypt', encDirName));
      expect(encDir.existsSync(), isTrue, reason: '① 首次加密应生成密文目录');

      // ② 原地解密（明文回写替换）
      await provider.decryptRemoteInPlace(
        ['cryptremote://$connId|$serverBase/$encDirName'],
      );
      expect(dir.existsSync(), isTrue, reason: '② 解密后应回到明文目录');

      // ③ 再次原地加密
      await provider.encryptRemoteInPlace(['$serverBase/Docs']);

      expect(dir.existsSync(), isFalse,
          reason: '③ 再次加密后明文目录必须消失（目录名应换成密文）');
      expect(encDir.existsSync(), isTrue,
          reason: '③ 再次加密后应重新出现密文目录');
      final names = encDir.listSync().map((e) => p.basename(e.path)).toSet();
      expect(names, {crypt.encryptFileName('a.txt')});
    });

    test('加密目录里的明文条目用 cryptremote 虚拟路径可原地加密（不再静默跳过）', () async {
      // 复刻用户操作：目录已被登记为「关联加密目录」（crypt 视图），其中有一个
      // **尚未加密**的明文条目。用户在 crypt 视图里对它点「加密」——旧逻辑会把
      // 「加密」入口藏掉 / 查表按明文名 miss 后静默 continue，表现为"没反应"。
      await CryptMountService.addRemoteEncryptedDir(connId, serverBase);
      final dir = Directory(p.join(serverRoot.path, 'crypt', 'Docs'))
        ..createSync(recursive: true);
      await File(p.join(dir.path, 'a.txt')).writeAsBytes(payload(256), flush: true);

      await provider.encryptRemoteInPlace(
        ['cryptremote://$connId|$serverBase/Docs'],
      );

      expect(dir.existsSync(), isFalse, reason: '明文目录必须被换成密文名');
      final encDir =
          Directory(p.join(serverRoot.path, 'crypt', crypt.encryptDirName('Docs')));
      expect(encDir.existsSync(), isTrue, reason: 'cryptremote 虚拟路径也要能命中并加密');
      expect(
        encDir.listSync().map((e) => p.basename(e.path)).toSet(),
        {crypt.encryptFileName('a.txt')},
      );
    });

    test('服务端查不到条目时给出可见错误（不再"什么都不发生"）', () async {
      // 一个都不存在 → 必须抛错（UI 会弹失败提示），而不是静默返回。
      await expectLater(
        provider.encryptRemoteInPlace(
          ['cryptremote://$connId|$serverBase/NoSuchDir'],
        ),
        throwsA(isA<StateError>()),
      );
    });

    test('进度：条目进度单调不减且收尾于 1.0，字节进度收尾于 2×明文大小', () async {
      await serverFile('big.bin').writeAsBytes(payload(4096), flush: true);

      final overall = <double>[];
      final bytes = <(int, int)>[];
      await provider.encryptRemoteInPlace(
        ['$serverBase/big.bin'],
        onProgress: (_, prog) => overall.add(prog),
        onFileProgress: (b, t) => bytes.add((b, t)),
      );

      expect(overall, isNotEmpty);
      expect(overall.first, 0.0);
      expect(overall.last, closeTo(1.0, 1e-9));
      for (var i = 1; i < overall.length; i++) {
        expect(overall[i], greaterThanOrEqualTo(overall[i - 1]),
            reason: '进度回退会让内圈圆环倒转');
      }
      // 分母 = 明文大小 ×2（下载一段 + 上传一段），收尾必须走满。
      expect(bytes.last, (8192, 8192));
      for (var i = 1; i < bytes.length; i++) {
        expect(bytes[i].$1, greaterThanOrEqualTo(bytes[i - 1].$1));
        expect(bytes[i].$2, bytes[i - 1].$2, reason: '同一文件的分母必须恒定');
      }
    });
  });

  group('远程原地解密（默认把明文回写替换服务端密文）', () {
    test('本地留明文副本 + 服务端换成明文 + 原密文删除 + 登记注销', () async {
      final plain = payload(6000);
      final encName = await putCipher('photo.jpg', plain);
      await CryptMountService.addRemoteEncryptedDir(connId, serverBase);

      final dest = p.join(localRoot.path, 'RemoteDecrypted');
      await provider.decryptRemoteInPlace(
        ['cryptremote://$connId|$serverBase/$encName'],
        destDir: dest,
      );

      // ① 本地明文副本
      final local = File(p.join(dest, 'photo.jpg'));
      expect(local.existsSync(), isTrue);
      expect(await local.readAsBytes(), plain);

      // ② 服务端原目录换成同名明文
      final remotePlain = serverFile('photo.jpg');
      expect(remotePlain.existsSync(), isTrue, reason: '应把明文回写到远程原目录');
      expect(await remotePlain.readAsBytes(), plain);

      // ③ 原密文删除
      expect(serverFile(encName).existsSync(), isFalse);

      // ④ 目录内已无密文 → 注销登记，否则之后放进去的明文会被当成密文
      final records = await CryptMountService.loadRemoteEncryptedDirs();
      expect(
        records.where((r) => r.connId == connId && r.serverPath == serverBase),
        isEmpty,
      );
    });

    test('replaceRemote=false：只取本地副本，服务端密文保持不动', () async {
      final plain = payload(2048);
      final encName = await putCipher('keep.txt', plain);
      await CryptMountService.addRemoteEncryptedDir(connId, serverBase);

      final dest = p.join(localRoot.path, 'OnlyLocal');
      await provider.decryptRemoteInPlace(
        ['cryptremote://$connId|$serverBase/$encName'],
        destDir: dest,
        replaceRemote: false,
      );

      expect(await File(p.join(dest, 'keep.txt')).readAsBytes(), plain);
      expect(serverFile(encName).existsSync(), isTrue, reason: '服务端不得改动');
      expect(serverFile('keep.txt').existsSync(), isFalse);
      expect(client.calls.any((c) => c.startsWith('upload:')), isFalse);
      // 仍留有密文 → 登记保留
      final records = await CryptMountService.loadRemoteEncryptedDirs();
      expect(
        records.where((r) => r.connId == connId && r.serverPath == serverBase),
        isNotEmpty,
      );
    });

    test('decryptDownloadFromRemoteCrypt 等价于 replaceRemote=false', () async {
      final plain = payload(1024);
      final encName = await putCipher('dl.bin', plain);
      await CryptMountService.addRemoteEncryptedDir(connId, serverBase);

      final dest = p.join(localRoot.path, 'Downloaded');
      await provider.decryptDownloadFromRemoteCrypt(
        ['cryptremote://$connId|$serverBase/$encName'],
        destDir: dest,
      );

      expect(await File(p.join(dest, 'dl.bin')).readAsBytes(), plain);
      expect(serverFile(encName).existsSync(), isTrue);
    });

    test('默认落盘目录（RemoteDecrypted）在 decrypt+replace 完成后自动清理', () async {
      final plain = payload(1500);
      final encName = await putCipher('clip.mp4', plain);
      await CryptMountService.addRemoteEncryptedDir(connId, serverBase);

      // 不传 destDir → 走默认 RemoteDecrypted（受 cryptTempRootOverride 重定向到
      // localRoot/crypt_tmp/RemoteDecrypted/<opId>），完成后应整体清理。
      await provider.decryptRemoteInPlace(
        ['cryptremote://$connId|$serverBase/$encName'],
      );

      // 远程端已被明文替换（清理不能影响「回写」行为）
      expect(serverFile('clip.mp4').existsSync(), isTrue,
          reason: '解密+回写的行为不能因清理而失效');
      // 默认中转目录必须被整体清理，否则 RemoteDecrypted 越积越多
      final stagingRoot = p.join(localRoot.path, 'crypt_tmp', 'RemoteDecrypted');
      expect(Directory(stagingRoot).existsSync(), isFalse,
          reason: 'decrypt+replace 的本地明文只是中转，必须自动清理');
    });
  });

  group('cryptremote 浏览视图：条目加密状态按实际判定', () {
    test('目录里的明文条目不再被标成加密（否则只能点「解密」且必然失败）', () async {
      await putCipher('secret.jpg', payload(512));
      await serverFile('plain.txt').writeAsString('just a plain file');
      await CryptMountService.addRemoteEncryptedDir(connId, serverBase);

      final virtual = 'cryptremote://$connId|$serverBase';
      await provider.loadDirectory(virtual, showLoading: false);

      final byName = {
        for (final f in provider.currentFiles.where((f) => !f.isDirectory))
          f.name: f,
      };
      expect(byName.keys, containsAll(['secret.jpg', 'plain.txt']));
      expect(byName['secret.jpg']!.isEncrypted, isTrue);
      expect(
        byName['plain.txt']!.isEncrypted,
        isFalse,
        reason: '明文条目恒标加密会让菜单只剩「解密」，点了必然失败',
      );
    });

    test('原地加密后按真实路径重进该目录 → 自动切到解密视图（明文名 + 🔒）', () async {
      await serverFile('movie.mp4').writeAsBytes(payload(900), flush: true);

      await provider.encryptRemoteInPlace(['$serverBase/movie.mp4']);
      // 「回到目录」这一动作在真实交互里就是 loadDirectory(serverPath)
      await provider.loadDirectory(serverBase, showLoading: false);

      expect(provider.activeTab.isCryptRemote, isTrue,
          reason: '命中登记表后必须改写为 cryptremote:// 视图');
      final names = provider.currentFiles.map((f) => f.name).toList();
      expect(names, contains('movie.mp4'));
      expect(names.any((n) => n.contains('.bin')), isFalse,
          reason: '不能把密文名直接暴露给用户');
    });
  });

  group('本地：加密文件复制/剪切到普通目录 → 保持密文（不自动解密）', () {
    late Directory plainDir;
    late Directory secretDir;
    late CryptMountPoint secretMount;
    late List<int> plainBytes;
    late String cipherName;

    setUp(() async {
      // 本组操作全在本地标签页上（setUp 里那个远程标签先切回本地）。
      final tab = provider.activeTab;
      tab.isRemote = false;
      tab.remoteClient = null;
      tab.isCryptRemote = false;

      plainDir =
          await Directory(p.join(localRoot.path, 'plain')).create(recursive: true);
      tab.currentPath = plainDir.path;

      secretDir =
          await Directory(p.join(localRoot.path, 'Secret')).create(recursive: true);
      plainBytes = payload(2048);
      await File(p.join(secretDir.path, 'note.txt'))
          .writeAsBytes(plainBytes, flush: true);
      // 挂载点根 == 该目录自身 → 目录名保持明文，靠「容器登记」被判定为加密目录。
      // 这正是用户在浏览页里看到的形态：文件夹名正常，里面的文件在磁盘上是密文。
      secretMount = CryptMountPoint(
        physicalPath: secretDir.path,
        config: cfg,
        name: 'Secret',
      );
      await CryptOperations(secretMount).encryptDirectory(secretDir.path);
      cipherName = crypt.encryptFileName('note.txt');

      // 前置：磁盘上只剩密文，且目录被正确登记为加密目录。
      expect(File(p.join(secretDir.path, cipherName)).existsSync(), isTrue);
      expect(File(p.join(secretDir.path, 'note.txt')).existsSync(), isFalse);
      expect(await CryptMountService.isInPlaceContainerDir(secretDir.path), isTrue);
    });

    test('复制到普通目录：目标是同名密文，明文名绝不出现', () async {
      await provider.debugCryptTransfer(
        source: p.join(secretDir.path, 'note.txt'), // 浏览页里的虚拟（解密名）路径
        destFolder: plainDir.path,
        isCut: false,
      );

      expect(File(p.join(plainDir.path, 'note.txt')).existsSync(), isFalse,
          reason: '复制不得把密文自动解密成明文');
      final copied = File(p.join(plainDir.path, cipherName));
      expect(copied.existsSync(), isTrue, reason: '应原样搬运密文并保留磁盘密文名');
      expect(await CryptOperations.isEncryptedFile(copied.path), isTrue);
      expect(
        await copied.readAsBytes(),
        await File(p.join(secretDir.path, cipherName)).readAsBytes(),
        reason: '字节必须逐字节一致',
      );
      // 是一份**合法密文**（能用主密码解回原文），不是「明文名 + 密文内容」的坏文件
      expect(await readPlain(copied.path), plainBytes);
      // 复制保留源
      expect(File(p.join(secretDir.path, cipherName)).existsSync(), isTrue);
    });

    test('剪切到普通目录：目标同样是密文，且源被移除', () async {
      await provider.debugCryptTransfer(
        source: p.join(secretDir.path, 'note.txt'),
        destFolder: plainDir.path,
        isCut: true,
      );

      expect(File(p.join(plainDir.path, 'note.txt')).existsSync(), isFalse);
      final moved = File(p.join(plainDir.path, cipherName));
      expect(moved.existsSync(), isTrue);
      expect(await readPlain(moved.path), plainBytes);
      expect(File(p.join(secretDir.path, cipherName)).existsSync(), isFalse,
          reason: '剪切必须删掉源密文');
    });

    test('加密目录整目录复制到普通目录：整棵树仍是密文', () async {
      final sub = Directory(p.join(secretDir.path, 'Docs'))..createSync();
      await File(p.join(sub.path, 'a.txt')).writeAsBytes(payload(300), flush: true);
      await CryptOperations(secretMount).encryptDirectory(sub.path);
      final encDirName = crypt.encryptDirName('Docs');

      await provider.debugCryptTransfer(
        source: p.join(secretDir.path, 'Docs'),
        destFolder: plainDir.path,
        isCut: false,
      );

      expect(Directory(p.join(plainDir.path, 'Docs')).existsSync(), isFalse,
          reason: '不得把加密目录整棵解密出来');
      final copiedDir = Directory(p.join(plainDir.path, encDirName));
      expect(copiedDir.existsSync(), isTrue);
      expect(
        await readPlain(p.join(copiedDir.path, crypt.encryptFileName('a.txt'))),
        payload(300),
      );
    });

    test('明文复制进加密目录 → 仍会被加密（另一方向未被误伤）', () async {
      final incoming = File(p.join(plainDir.path, 'incoming.txt'));
      await incoming.writeAsBytes(payload(1500), flush: true);

      await provider.debugCryptTransfer(
        source: incoming.path,
        destFolder: secretDir.path,
        isCut: false,
      );

      expect(File(p.join(secretDir.path, 'incoming.txt')).existsSync(), isFalse,
          reason: '不得在加密目录里留下明文文件/明文名');
      final enc = File(p.join(secretDir.path, crypt.encryptFileName('incoming.txt')));
      expect(enc.existsSync(), isTrue);
      expect(await readPlain(enc.path), payload(1500));
    });
  });

  group('远程加密目录 → 本地：落盘仍是密文', () {
    test('浏览层放进剪贴板的是「后端密文名 + 密文全路径」→ 下载即落密文', () async {
      final cipherName = await putCipher('note.txt', payload(1024));
      await CryptMountService.addRemoteEncryptedDir(connId, serverBase);

      await provider.loadDirectory(
        'cryptremote://$connId|$serverBase',
        showLoading: false,
      );

      // 复刻浏览页的「复制」动作：`setRemoteClipboard([item.remoteSource!])`。
      final items = provider.currentFiles.where((f) => !f.isDirectory).toList();
      expect(items, hasLength(1));
      final item = items.single;
      // 显示名是解密名（用户友好），但 remoteSource 必须携带后端的密文事实。
      expect(item.name, 'note.txt');
      expect(item.remoteSource, isNotNull);
      provider.setRemoteClipboard(
        [item.remoteSource!],
        isCut: false,
        connection: conn,
      );

      final copied = provider.remoteClipboardItems.single;
      expect(
        copied.name,
        cipherName,
        reason: '剪贴板必须带**密文名**：远程→本地下载链路用的就是 remoteItem.name，'
            '若这里是明文名，落盘就会变成「明文名 + 密文内容」的坏文件',
      );
      expect(copied.path, '$serverBase/$cipherName', reason: '必须是后端密文全路径');
      // ⚠️ 落盘链路（`_pasteFileToTab` → `_pasteFromRemoteToLocal`）只做
      // `client.downloadFile(item.path, join(target, item.name))`，不经过任何解密分支；
      // 「边下载边解密」那段曾被加进来又被用户否决，已彻底删除。
    });
  });

  group('远程加解密后导航不冻结（面包屑 / 返回）', () {
    test('远程路径向上导航落到合法 remote:// 路径，绝不产生空服务端路径', () {
      // 从 cryptremote:// 子目录向上：必须退回普通 remote:// 视图（不能留空服务端
      // 路径的 cryptremote://，否则挂载点解析失败 / WebDAV 列目录挂起）。
      expect(
        FileManagerProvider.remoteParentPathForTest(
          'cryptremote://$connId|$serverBase/sub/deep'),
        'remote://$connId|$serverBase/sub',
      );
      // cryptremote 根（登记目录本身）向上 → 普通远程根
      expect(
        FileManagerProvider.remoteParentPathForTest('cryptremote://$connId|$serverBase'),
        'remote://$connId|/',
      );
      // 普通远程子目录向上
      expect(
        FileManagerProvider.remoteParentPathForTest('remote://$connId|/a/b/c'),
        'remote://$connId|/a/b',
      );
      // 普通远程根向上 → 仍是根（不越界）
      expect(
        FileManagerProvider.remoteParentPathForTest('remote://$connId|/'),
        'remote://$connId|/',
      );
      // 本地路径不受影响（无 '|'）
      expect(
        FileManagerProvider.remoteParentPathForTest('/storage/emulated/0/DCIM'),
        isNull,
      );
    });

    test('畸形面包屑路径不被误路由进 cryptremote 分支（否则 WebDAV 挂起冻结）', () async {
      // 复刻 bug：加解密把父目录登记后，currentPath 变成 cryptremote://…，此时
      // 面包屑按 '/' 切分重建出 '/cryptremote:' 这类畸形路径。旧实现会命中
      // 「自动识别远程加密目录」分支，被强制重路由进 cryptremote 视图、用垃圾服务端
      // 路径列目录——WebDAV 无超时一直挂起。修复后该路径应落到普通远程分支（不冻结）。
      await CryptMountService.addRemoteEncryptedDir(connId, serverBase);
      final tab = provider.activeTab;
      tab.isRemote = true;
      tab.remoteClient = client;
      tab.remoteConnection = conn;
      tab.isCryptRemote = false;
      tab.currentPath = 'cryptremote://$connId$serverBase';

      // 畸形路径（对应旧面包屑逻辑产生的 '/cryptremote:'）
      await provider.loadDirectory('/cryptremote:', showLoading: false);

      // 关键不变量：没有被强制推进 cryptremote 视图（说明没触发那个会挂起的重路由）。
      expect(tab.isCryptRemote, isFalse,
          reason: '畸形路径被误路由进 cryptremote 分支就会用垃圾路径列目录挂起');
      // 且调用能正常返回、不抛异常（页面恢复响应）。
      expect(tab.isLoading, isFalse);
    });
  });
}

