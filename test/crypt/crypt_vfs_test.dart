/// CryptVFS 加密虚拟文件系统 - 单元测试
///
/// 测试覆盖：
/// 1. 挂载点管理
/// 2. 路径映射
/// 3. 加密文件随机读写
/// 4. 加密目录枚举
/// 5. 原地加密/解密操作
/// 6. CryptVFS 集成测试
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:zenfile/services/crypt/crypt.dart';

void main() {
  late Directory tempDir;
  late RcloneCryptConfig config;
  late RcloneCrypt crypt;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('crypt_vfs_test_');
    config = RcloneCryptConfig(
      password: 'testpassword123',
      salt: 'testsalt456',
      filenameEncryption: FilenameEncryption.standard,
      directoryNameEncryption: true,
      filenameEncoding: FilenameEncoding.base32,
      encryptedSuffix: '.bin',
    );
    crypt = RcloneCrypt(config: config);
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  group('挂载点管理', () {
    test('挂载和卸载', () {
      final manager = CryptMountManager();
      final mount = CryptMountPoint(
        physicalPath: tempDir.path,
        config: config,
      );

      expect(manager.mountPoints, isEmpty);

      manager.mount(mount);
      expect(manager.mountPoints.length, equals(1));
      expect(manager.mountPoints.first.physicalPath, equals(tempDir.path));

      final result = manager.unmount(tempDir.path);
      expect(result, isTrue);
      expect(manager.mountPoints, isEmpty);
    });

    test('重复挂载抛出异常', () {
      final manager = CryptMountManager();
      final mount = CryptMountPoint(
        physicalPath: tempDir.path,
        config: config,
      );

      manager.mount(mount);
      expect(() => manager.mount(mount), throwsStateError);
    });

    test('查找包含路径的挂载点', () {
      final manager = CryptMountManager();
      final mount = CryptMountPoint(
        physicalPath: tempDir.path,
        config: config,
      );
      manager.mount(mount);

      // 挂载点根目录
      expect(manager.findMountPointForPath(tempDir.path), isNotNull);

      // 挂载点内的子路径
      final subPath = p.join(tempDir.path, 'subdir', 'file.txt');
      expect(manager.findMountPointForPath(subPath), isNotNull);

      // 挂载点外的路径
      expect(manager.findMountPointForPath('/other/path'), isNull);
    });

    test('判断路径是否加密', () {
      final manager = CryptMountManager();
      final mount = CryptMountPoint(
        physicalPath: tempDir.path,
        config: config,
      );
      manager.mount(mount);

      expect(manager.isEncryptedPath(tempDir.path), isTrue);
      expect(manager.isEncryptedPath(p.join(tempDir.path, 'file.txt')), isTrue);
      expect(manager.isEncryptedPath('/other/path'), isFalse);
    });

    test('最长匹配挂载点', () {
      final manager = CryptMountManager();
      final parentDir = Directory(p.join(tempDir.path, 'parent'));
      final childDir = Directory(p.join(parentDir.path, 'child'));
      parentDir.createSync(recursive: true);
      childDir.createSync(recursive: true);

      final parentMount = CryptMountPoint(
        physicalPath: parentDir.path,
        config: config,
        name: 'parent',
      );
      final childMount = CryptMountPoint(
        physicalPath: childDir.path,
        config: config,
        name: 'child',
      );

      manager.mount(parentMount);
      manager.mount(childMount);

      // 子目录内的路径应该匹配子挂载点
      final filePath = p.join(childDir.path, 'file.txt');
      final found = manager.findMountPointForPath(filePath);
      expect(found, isNotNull);
      expect(found!.name, equals('child'));
    });
  });

  group('路径映射', () {
    late CryptMountPoint mount;

    setUp(() {
      mount = CryptMountPoint(
        physicalPath: tempDir.path,
        config: config,
      );
    });

    test('虚拟路径转物理路径（文件名加密）', () {
      final virtualPath = p.join(tempDir.path, 'document.txt');
      final physicalPath = mount.virtualToPhysical(virtualPath);

      expect(physicalPath, isNot(equals(virtualPath)));
      expect(physicalPath.endsWith('.bin'), isTrue);
    });

    test('虚拟路径转物理路径（目录名加密）', () {
      final virtualPath = p.join(tempDir.path, 'MyFolder', 'file.txt');
      final physicalPath = mount.virtualToPhysical(virtualPath);

      expect(physicalPath, isNot(equals(virtualPath)));
      // 目录名不应该包含 .bin 后缀
      final segments = p.split(physicalPath);
      final dirSegment = segments[segments.length - 2];
      expect(dirSegment.endsWith('.bin'), isFalse);
    });

    test('物理路径转虚拟路径（往返一致）', () {
      final virtualPath = p.join(tempDir.path, 'test file.mp4');
      final physicalPath = mount.virtualToPhysical(virtualPath);
      final recoveredVirtualPath = mount.physicalToVirtual(physicalPath);

      expect(recoveredVirtualPath, equals(virtualPath));
    });

    test('挂载点根目录路径映射', () {
      expect(mount.virtualToPhysical(tempDir.path), equals(tempDir.path));
      expect(mount.physicalToVirtual(tempDir.path), equals(tempDir.path));
    });

    test('中文文件名路径映射', () {
      final virtualPath = p.join(tempDir.path, '中文文件.txt');
      final physicalPath = mount.virtualToPhysical(virtualPath);
      final recoveredVirtualPath = mount.physicalToVirtual(physicalPath);

      expect(recoveredVirtualPath, equals(virtualPath));
    });
  });

  group('加密文件随机读写', () {
    test('写入和读取小文件', () async {
      final encryptedPath = p.join(tempDir.path, 'test.bin');
      final plainData = Uint8List.fromList('Hello, CryptVFS!'.codeUnits);

      // 写入
      final writeFile = await CryptFile.open(
        encryptedPath,
        crypt,
        mode: CryptFileMode.write,
      );
      await writeFile.write(0, plainData);
      await writeFile.close();

      // 读取
      final readFile = await CryptFile.open(
        encryptedPath,
        crypt,
        mode: CryptFileMode.read,
      );
      expect(readFile.length, equals(plainData.length));
      final readData = await readFile.read(0);
      await readFile.close();

      expect(readData, equals(plainData));
    });

    test('写入和读取大文件（多块）', () async {
      final encryptedPath = p.join(tempDir.path, 'large.bin');
      // 生成 200KB 数据（超过 64KB 块大小）
      final plainData = Uint8List(200 * 1024);
      for (var i = 0; i < plainData.length; i++) {
        plainData[i] = (i * 7 + 3) % 256;
      }

      // 写入
      final writeFile = await CryptFile.open(
        encryptedPath,
        crypt,
        mode: CryptFileMode.write,
      );
      await writeFile.write(0, plainData);
      await writeFile.close();

      // 读取全部
      final readFile = await CryptFile.open(
        encryptedPath,
        crypt,
        mode: CryptFileMode.read,
      );
      expect(readFile.length, equals(plainData.length));
      final readData = await readFile.read(0);
      await readFile.close();

      expect(readData.length, equals(plainData.length));
      expect(readData, equals(plainData));
    });

    test('随机读取（从中间偏移读取）', () async {
      final encryptedPath = p.join(tempDir.path, 'random.bin');
      final plainData = Uint8List(100 * 1024);
      for (var i = 0; i < plainData.length; i++) {
        plainData[i] = i % 256;
      }

      // 写入
      final writeFile = await CryptFile.open(
        encryptedPath,
        crypt,
        mode: CryptFileMode.write,
      );
      await writeFile.write(0, plainData);
      await writeFile.close();

      // 从偏移 50KB 读取 10KB
      final readFile = await CryptFile.open(
        encryptedPath,
        crypt,
        mode: CryptFileMode.read,
      );
      final offset = 50 * 1024;
      final length = 10 * 1024;
      final readData = await readFile.read(offset, length);
      await readFile.close();

      expect(readData.length, equals(length));
      expect(readData, equals(plainData.sublist(offset, offset + length)));
    });

    test('空文件', () async {
      final encryptedPath = p.join(tempDir.path, 'empty.bin');

      // 写入空文件
      final writeFile = await CryptFile.open(
        encryptedPath,
        crypt,
        mode: CryptFileMode.write,
      );
      await writeFile.write(0, Uint8List(0));
      await writeFile.close();

      // 读取空文件
      final readFile = await CryptFile.open(
        encryptedPath,
        crypt,
        mode: CryptFileMode.read,
      );
      expect(readFile.length, equals(0));
      final readData = await readFile.read(0);
      await readFile.close();

      expect(readData, isEmpty);
    });

    test('追加写入', () async {
      final encryptedPath = p.join(tempDir.path, 'append.bin');
      final data1 = Uint8List.fromList('First part. '.codeUnits);
      final data2 = Uint8List.fromList('Second part.'.codeUnits);

      // 写入第一部分
      final writeFile = await CryptFile.open(
        encryptedPath,
        crypt,
        mode: CryptFileMode.write,
      );
      await writeFile.write(0, data1);
      await writeFile.close();

      // 追加第二部分
      final appendFile = await CryptFile.open(
        encryptedPath,
        crypt,
        mode: CryptFileMode.append,
      );
      await appendFile.write(appendFile.length, data2);
      await appendFile.close();

      // 读取全部
      final readFile = await CryptFile.open(
        encryptedPath,
        crypt,
        mode: CryptFileMode.read,
      );
      final readData = await readFile.read(0);
      await readFile.close();

      final expected = <int>[...data1, ...data2];
      expect(readData, equals(expected));
    });
  });

  group('加密目录枚举', () {
    test('枚举加密目录', () async {
      final mount = CryptMountPoint(
        physicalPath: tempDir.path,
        config: config,
      );

      // 创建一些测试文件（写入真正的加密格式内容）
      final file1 = File(p.join(tempDir.path, crypt.encryptFileName('document.txt')));
      final encrypter1 = RcloneStreamEncrypter(dataKey: crypt.derivedKeys.dataKey);
      final encrypted1 = <int>[
        ...encrypter1.process('Document content'.codeUnits),
        ...encrypter1.finish(),
      ];
      await file1.writeAsBytes(encrypted1);

      final file2 = File(p.join(tempDir.path, crypt.encryptFileName('image.jpg')));
      final encrypter2 = RcloneStreamEncrypter(dataKey: crypt.derivedKeys.dataKey);
      final encrypted2 = <int>[
        ...encrypter2.process(Uint8List(1024)),
        ...encrypter2.finish(),
      ];
      await file2.writeAsBytes(encrypted2);

      final subDir = Directory(p.join(tempDir.path, crypt.encryptDirName('MyFolder')));
      await subDir.create();

      // 枚举目录
      final lister = CryptDirectoryLister(mount);
      final entries = await lister.listDirectory(tempDir.path);

      expect(entries.length, equals(3));
      expect(entries.any((e) => e.name == 'document.txt'), isTrue);
      expect(entries.any((e) => e.name == 'image.jpg'), isTrue);
      expect(entries.any((e) => e.name == 'MyFolder'), isTrue);

      // 验证目录标记
      final folderEntry = entries.firstWhere((e) => e.name == 'MyFolder');
      expect(folderEntry.isDirectory, isTrue);

      final fileEntry = entries.firstWhere((e) => e.name == 'document.txt');
      expect(fileEntry.isDirectory, isFalse);
      expect(fileEntry.size, greaterThan(0));
    });

    test('隐藏文件过滤', () async {
      final mount = CryptMountPoint(
        physicalPath: tempDir.path,
        config: config,
      );

      // 创建普通文件和隐藏文件（写入真正的加密格式内容）
      final visibleFile = File(p.join(tempDir.path, crypt.encryptFileName('visible.txt')));
      final encrypterV = RcloneStreamEncrypter(dataKey: crypt.derivedKeys.dataKey);
      await visibleFile.writeAsBytes([
        ...encrypterV.process([1, 2, 3]),
        ...encrypterV.finish(),
      ]);

      final hiddenFile = File(p.join(tempDir.path, crypt.encryptFileName('.hidden.txt')));
      final encrypterH = RcloneStreamEncrypter(dataKey: crypt.derivedKeys.dataKey);
      await hiddenFile.writeAsBytes([
        ...encrypterH.process([4, 5, 6]),
        ...encrypterH.finish(),
      ]);

      final lister = CryptDirectoryLister(mount);

      // 不显示隐藏文件
      final entriesWithoutHidden = await lister.listDirectory(tempDir.path, showHidden: false);
      expect(entriesWithoutHidden.length, equals(1));
      expect(entriesWithoutHidden.first.name, equals('visible.txt'));

      // 显示隐藏文件
      final entriesWithHidden = await lister.listDirectory(tempDir.path, showHidden: true);
      expect(entriesWithHidden.length, equals(2));
    });
  });

  group('原地加密/解密操作', () {
    test('加密单个文件', () async {
      final mount = CryptMountPoint(
        physicalPath: tempDir.path,
        config: config,
      );

      // 创建普通文件
      final sourceFile = File(p.join(tempDir.path, 'test.txt'));
      final sourceContent = 'This is a test file for encryption.';
      await sourceFile.writeAsString(sourceContent);

      // 加密
      final operations = CryptOperations(mount);
      final encryptedPath = await operations.encryptFile(sourceFile.path);

      // 验证源文件已被删除
      expect(await sourceFile.exists(), isFalse);

      // 验证加密文件存在
      expect(await File(encryptedPath).exists(), isTrue);
      expect(encryptedPath.endsWith('.bin'), isTrue);

      // 验证加密文件内容不是明文
      final encryptedContent = await File(encryptedPath).readAsBytes();
      expect(encryptedContent, isNot(contains(sourceContent.codeUnits)));

      // 解密验证
      final decryptedPath = await operations.decryptFile(encryptedPath);
      final decryptedContent = await File(decryptedPath).readAsString();
      expect(decryptedContent, equals(sourceContent));
    });

    test('解密单个文件', () async {
      final mount = CryptMountPoint(
        physicalPath: tempDir.path,
        config: config,
      );

      // 创建加密文件
      final plainContent = 'Secret content here.';
      final encryptedFileName = crypt.encryptFileName('secret.txt');
      final encryptedFile = File(p.join(tempDir.path, encryptedFileName));

      final encrypter = RcloneStreamEncrypter(dataKey: crypt.derivedKeys.dataKey);
      final encryptedData = <int>[
        ...encrypter.process(plainContent.codeUnits),
        ...encrypter.finish(),
      ];
      await encryptedFile.writeAsBytes(encryptedData);

      // 解密
      final operations = CryptOperations(mount);
      final decryptedPath = await operations.decryptFile(encryptedFile.path);

      expect(await encryptedFile.exists(), isFalse);
      expect(await File(decryptedPath).exists(), isTrue);
      expect(p.basename(decryptedPath), equals('secret.txt'));

      final decryptedContent = await File(decryptedPath).readAsString();
      expect(decryptedContent, equals(plainContent));
    });

    test('加密文件夹（递归）', () async {
      final mount = CryptMountPoint(
        physicalPath: tempDir.path,
        config: config,
      );

      // 创建测试文件夹结构
      final testDir = Directory(p.join(tempDir.path, 'TestFolder'));
      await testDir.create();
      await File(p.join(testDir.path, 'file1.txt')).writeAsString('File 1');
      await File(p.join(testDir.path, 'file2.txt')).writeAsString('File 2');

      final subDir = Directory(p.join(testDir.path, 'SubFolder'));
      await subDir.create();
      await File(p.join(subDir.path, 'file3.txt')).writeAsString('File 3');

      // 加密文件夹
      final operations = CryptOperations(mount);
      await operations.encryptDirectory(testDir.path);

      // 验证原文件夹名已被加密
      expect(await testDir.exists(), isFalse);
      final entities = await tempDir.list().toList();
      expect(entities.length, equals(1));
      expect(entities.first is Directory, isTrue);

      // 解密文件夹
      final encryptedDirPath = entities.first.path;
      await operations.decryptDirectory(encryptedDirPath);

      // 验证恢复
      final decryptedDir = Directory(p.join(tempDir.path, 'TestFolder'));
      expect(await decryptedDir.exists(), isTrue);
      expect(await File(p.join(decryptedDir.path, 'file1.txt')).exists(), isTrue);
      expect(await File(p.join(decryptedDir.path, 'file2.txt')).exists(), isTrue);
      expect(await File(p.join(decryptedDir.path, 'SubFolder', 'file3.txt')).exists(), isTrue);
    });
  });

  group('CryptVFS 集成测试', () {
    test('完整流程：挂载 -> 枚举 -> 读写 -> 卸载', () async {
      final vfs = CryptVFS();

      // 挂载
      final mount = CryptMountPoint(
        physicalPath: tempDir.path,
        config: config,
      );
      vfs.mount(mount);

      expect(vfs.isEncryptedPath(tempDir.path), isTrue);
      expect(vfs.mountPoints.length, equals(1));

      // 创建加密文件
      final testFile = File(p.join(tempDir.path, crypt.encryptFileName('hello.txt')));
      final encrypter = RcloneStreamEncrypter(dataKey: crypt.derivedKeys.dataKey);
      final encryptedData = <int>[
        ...encrypter.process('Hello World!'.codeUnits),
        ...encrypter.finish(),
      ];
      await testFile.writeAsBytes(encryptedData);

      // 枚举目录
      final entries = await vfs.listDirectory(tempDir.path);
      expect(entries.length, equals(1));
      expect(entries.first.name, equals('hello.txt'));

      // 读取文件
      final file = await vfs.openFile(
        p.join(tempDir.path, 'hello.txt'),
        mode: CryptFileMode.read,
      );
      final content = await file.read(0);
      await file.close();
      expect(String.fromCharCodes(content), equals('Hello World!'));

      // 卸载
      vfs.unmount(tempDir.path);
      expect(vfs.mountPoints, isEmpty);
      expect(vfs.isEncryptedPath(tempDir.path), isFalse);
    });

    test('路径映射集成', () async {
      final vfs = CryptVFS();
      vfs.mount(CryptMountPoint(
        physicalPath: tempDir.path,
        config: config,
      ));

      final virtualPath = p.join(tempDir.path, 'test', 'file.mp4');
      final physicalPath = vfs.virtualToPhysical(virtualPath);
      final recoveredPath = vfs.physicalToVirtual(physicalPath);

      expect(recoveredPath, equals(virtualPath));

      // 非挂载点路径不改变
      expect(vfs.virtualToPhysical('/other/path'), equals('/other/path'));
      expect(vfs.physicalToVirtual('/other/path'), equals('/other/path'));
    });
  });
}
