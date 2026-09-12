/// CryptDirectoryLister「挂载点内明文子目录」回归测试
///
/// 历史 bug：`listDirectory` 直接用 `_mount.virtualToPhysical(virtualDirPath)`
/// 作为要枚举的物理目录。而 `virtualToPhysical` 会把虚拟名**重新加密**，
/// 于是挂载点内「未加密的普通子目录」会算出一个磁盘上不存在的路径 →
/// 抛 `Directory not found`。
///
/// 后果（用户可见）：
/// - `file_manager_provider.loadDirectory` 的 CryptVFS 分支捕获异常后把
///   `currentFiles` 置空 → 进入该目录显示**完全空白**，表现为
///   「原地加密后浏览页的加密文件/文件夹消失了（重启后更明显）」。
///
/// 修复：映射结果不存在但**原路径存在**时，说明该目录本身是明文目录，
/// 直接按明文目录枚举。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:zenfile/services/crypt/crypt_config.dart';
import 'package:zenfile/services/crypt/crypt_mount.dart';
import 'package:zenfile/services/crypt/crypt_operations.dart';

void main() {
  late Directory mountRoot;

  setUp(() {
    mountRoot = Directory.systemTemp.createTempSync('zenfile_lister_');
  });

  tearDown(() {
    if (mountRoot.existsSync()) {
      mountRoot.deleteSync(recursive: true);
    }
  });

  CryptMountPoint buildMount() => CryptMountPoint(
        physicalPath: mountRoot.path,
        config: const RcloneCryptConfig(password: 'test-pass'),
      );

  group('CryptDirectoryLister.listDirectory 明文子目录兜底', () {
    test('挂载点内的明文子目录可正常枚举（修复前抛 Directory not found）', () async {
      // 挂载点根下一个未加密的普通子目录 + 一个普通文件
      final plainDir = Directory(p.join(mountRoot.path, '普通目录'))..createSync();
      File(p.join(plainDir.path, 'a.txt')).writeAsStringSync('hello');

      final lister = CryptDirectoryLister(buildMount());

      // 修复前这里会抛 FileSystemException('Directory not found')
      final entries = await lister.listDirectory(plainDir.path);

      expect(entries, isNotEmpty, reason: '明文目录不应因为名字无法映射而变成空目录');
      expect(
        entries.map((e) => e.name),
        contains('a.txt'),
        reason: '明文目录内的文件必须被枚举出来',
      );
    });

    test('挂载点根本身仍可正常枚举', () async {
      File(p.join(mountRoot.path, 'root.txt')).writeAsStringSync('hi');

      final entries = await CryptDirectoryLister(buildMount())
          .listDirectory(mountRoot.path);

      expect(entries.map((e) => e.name), contains('root.txt'));
    });

    test('既不存在映射也不存在原路径时，仍抛异常（不掩盖真实错误）', () async {
      final lister = CryptDirectoryLister(buildMount());
      expect(
        () => lister.listDirectory(p.join(mountRoot.path, '并不存在的目录')),
        throwsA(isA<FileSystemException>()),
      );
    });
  });
}
