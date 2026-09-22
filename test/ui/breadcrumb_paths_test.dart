import 'package:flutter_test/flutter_test.dart';
import 'package:zenfile/providers/file_manager_provider.dart';

/// 面包屑「标签 + 目标路径」的回归（纯函数 `FileManagerProvider.breadcrumbPaths`）。
///
/// 背景（用户反馈）：WebDAV 连接把 `192.168.100.1:5244/dav` 里的 `/dav` 存成了
/// 连接的 `rootPath`。旧实现一律把根当成 `/`，于是「/dav/115网盘」被切成
/// `dav` + `115网盘` 两段、根目标算成 `/` → 点面包屑 `dav` 实际请求
/// `http://host/`（连接范围之外）→ **回不去网盘列表**（静默无反应）。
///
/// 这里钉住三件事：
///   ① 远程时根目标 = 连接真实根（可非 `/`），**绝不生成 `/`**；
///   ② `cryptremote://` / `remote://` 形式的路径同样以连接根为起点；
///   ③ 本地路径行为不变（仍以 `/` 为根）。
void main() {
  List<String> labelsOf({
    required String currentPath,
    required bool isRemoteTab,
    required String remoteRoot,
    String connName = '',
    String rootLabel = 'Root',
  }) =>
      FileManagerProvider.breadcrumbPaths(
        currentPath: currentPath,
        isRemoteTab: isRemoteTab,
        remoteRoot: remoteRoot,
        connName: connName,
        rootLabel: rootLabel,
      ).labels;

  List<String> targetsOf({
    required String currentPath,
    required bool isRemoteTab,
    required String remoteRoot,
    String connName = '',
    String rootLabel = 'Root',
  }) =>
      FileManagerProvider.breadcrumbPaths(
        currentPath: currentPath,
        isRemoteTab: isRemoteTab,
        remoteRoot: remoteRoot,
        connName: connName,
        rootLabel: rootLabel,
      ).targets;

  group('远程根非 /（WebDAV 的 /dav）', () {
    test('裸服务端路径：「/」根目标必须落在 /dav，而不是 /', () {
      final labels = labelsOf(
        currentPath: '/dav/115网盘',
        isRemoteTab: true,
        remoteRoot: '/dav',
        connName: '115',
      );
      final targets = targetsOf(
        currentPath: '/dav/115网盘',
        isRemoteTab: true,
        remoteRoot: '/dav',
        connName: '115',
      );

      expect(labels, ['115', '115网盘']);
      expect(targets, ['/dav', '/dav/115网盘']);
      expect(targets, isNot(contains('/')), reason: '远程绝不允许生成 / 目标');
    });

    test('连接名为空时，根段退回显示 rootPath 末段（dav）——正是用户点的那一段', () {
      final labels = labelsOf(
        currentPath: '/dav/115网盘',
        isRemoteTab: true,
        remoteRoot: '/dav',
      );
      expect(labels, ['dav', '115网盘']);
    });

    test('rootPath 带尾斜杠 / 缺失前导斜杠都要规范化', () {
      for (final raw in ['/dav/', 'dav', 'dav/']) {
        expect(
          targetsOf(
            currentPath: '/dav/115网盘',
            isRemoteTab: true,
            remoteRoot: raw,
            connName: '115',
          ),
          ['/dav', '/dav/115网盘'],
          reason: 'rootPath="$raw" 应规范化为 /dav',
        );
      }
    });

    test('已在连接根：只剩根段，点它回到 /dav', () {
      expect(labelsOf(currentPath: '/dav', isRemoteTab: true, remoteRoot: '/dav'),
          ['dav']);
      expect(
        targetsOf(currentPath: '/dav', isRemoteTab: true, remoteRoot: '/dav'),
        ['/dav'],
      );
    });

    test('remote:// 形式：根目标带上连接前缀，不是裸 /', () {
      expect(
        targetsOf(
          currentPath: 'remote://abc|/dav/115网盘',
          isRemoteTab: true,
          remoteRoot: '/dav',
          connName: '115',
        ),
        ['remote://abc|/dav', 'remote://abc|/dav/115网盘'],
      );
      expect(
        labelsOf(
          currentPath: 'remote://abc|/dav/115网盘',
          isRemoteTab: true,
          remoteRoot: '/dav',
          connName: '115',
        ),
        ['115', '115网盘'],
      );
    });

    test('cryptremote:// 形式：根目标保持虚拟前缀', () {
      expect(
        targetsOf(
          currentPath: 'cryptremote://abc|/dav/加密夹',
          isRemoteTab: true,
          remoteRoot: '/dav',
          connName: '115',
        ),
        ['cryptremote://abc|/dav', 'cryptremote://abc|/dav/加密夹'],
      );
      // 已在加密挂载根
      expect(
        targetsOf(
          currentPath: 'cryptremote://abc|/dav',
          isRemoteTab: true,
          remoteRoot: '/dav',
          connName: '115',
        ),
        ['cryptremote://abc|/dav'],
      );
    });
  });

  group('远程根为 / （SMB / FTP / SFTP 共享根）行为不变', () {
    test('逐段累加，根目标为 /', () {
      expect(
        labelsOf(
          currentPath: '/share/docs',
          isRemoteTab: true,
          remoteRoot: '/',
          connName: 'NAS',
        ),
        ['NAS', 'share', 'docs'],
      );
      expect(
        targetsOf(
          currentPath: '/share/docs',
          isRemoteTab: true,
          remoteRoot: '/',
          connName: 'NAS',
        ),
        ['/', '/share', '/share/docs'],
      );
    });
  });

  group('本地路径行为不变（仍以 / 为根）', () {
    test('/storage/emulated/0/Download', () {
      expect(
        labelsOf(
          currentPath: '/storage/emulated/0/Download',
          isRemoteTab: false,
          remoteRoot: '/',
        ),
        ['storage', 'emulated', '0', 'Download'],
      );
      expect(
        targetsOf(
          currentPath: '/storage/emulated/0/Download',
          isRemoteTab: false,
          remoteRoot: '/',
        ),
        [
          '/',
          '/storage',
          '/storage/emulated',
          '/storage/emulated/0',
          '/storage/emulated/0/Download',
        ],
      );
    });

    test('根目录：只剩一个 rootLabel，目标为 /', () {
      expect(
        labelsOf(currentPath: '/', isRemoteTab: false, remoteRoot: '/', rootLabel: '内部存储'),
        ['内部存储'],
      );
      expect(
        targetsOf(currentPath: '/', isRemoteTab: false, remoteRoot: '/'),
        ['/'],
      );
    });
  });
}
