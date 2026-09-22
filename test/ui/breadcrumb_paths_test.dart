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
          rootLabel: '根目录',
        ),
        ['根目录', 'storage', 'emulated', '0', 'Download'],
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

  group('标签与目标必须一一对应（用户反馈：点 `0` 跳到 /storage/emulated）', () {
    /// UI 用 `List.generate(labels.length)` 且按同一下标取 `targets[index]`，
    /// 所以两者长度必须相等，且**每格目标就是那格标签指向的目录**。
    /// 历史 bug：本地分支 labels 比 targets 少一项（`/` 那段没配标签），
    /// 于是所有标签集体错位指向上一层，点 `0` 会退到 `/storage/emulated`。
    void expectAligned({
      required String currentPath,
      required bool isRemoteTab,
      required String remoteRoot,
      String connName = '',
    }) {
      final labels = labelsOf(
        currentPath: currentPath,
        isRemoteTab: isRemoteTab,
        remoteRoot: remoteRoot,
        connName: connName,
      );
      final targets = targetsOf(
        currentPath: currentPath,
        isRemoteTab: isRemoteTab,
        remoteRoot: remoteRoot,
        connName: connName,
      );
      expect(labels.length, targets.length,
          reason: '$currentPath：标签数必须等于目标数（否则 UI 会错位）');
      expect(targets.last, currentPath, reason: '最后一段必须指向当前路径本身');
    }

    test('/storage/emulated/0 的子目录：点 `0` 应落在 /storage/emulated/0', () {
      const current = '/storage/emulated/0/我的文件夹';
      final labels =
          labelsOf(currentPath: current, isRemoteTab: false, remoteRoot: '/');
      final targets =
          targetsOf(currentPath: current, isRemoteTab: false, remoteRoot: '/');
      expectAligned(currentPath: current, isRemoteTab: false, remoteRoot: '/');

      // 按标签找「那一格」——正是用户手指点的东西
      final idx = labels.indexOf('0');
      expect(idx, isNot(-1));
      expect(targets[idx], '/storage/emulated/0',
          reason: '点标签 `0` 必须进入 /storage/emulated/0，不能退到 /storage/emulated');
      expect(labels.indexOf('storage'), 1);
      expect(targets[1], '/storage');
    });

    test('本地 / 远程（含 remote:// 与 cryptremote://）一律对齐', () {
      expectAligned(currentPath: '/storage/emulated/0/Download', isRemoteTab: false, remoteRoot: '/');
      expectAligned(currentPath: '/', isRemoteTab: false, remoteRoot: '/');
      expectAligned(currentPath: '/dav/115网盘', isRemoteTab: true, remoteRoot: '/dav', connName: '115');
      expectAligned(currentPath: '/dav', isRemoteTab: true, remoteRoot: '/dav');
      expectAligned(currentPath: '/share/docs', isRemoteTab: true, remoteRoot: '/', connName: 'NAS');
      expectAligned(
          currentPath: 'remote://abc|/dav/115网盘',
          isRemoteTab: true,
          remoteRoot: '/dav',
          connName: '115');
      expectAligned(
          currentPath: 'cryptremote://abc|/dav/加密夹',
          isRemoteTab: true,
          remoteRoot: '/dav',
          connName: '115');
    });
  });
}
