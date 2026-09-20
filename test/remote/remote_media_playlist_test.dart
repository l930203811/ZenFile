import 'package:flutter_test/flutter_test.dart';
import 'package:zenfile/services/remote/remote_media_playlist.dart';

/// 远程视频/音频播放列表的纯逻辑单测。
///
/// 这些函数决定「从远程浏览页点开一个视频后，播放器列表里会出现哪些文件」，
/// 出错的表现很隐蔽：少一个文件没人发现，多一个密文路径却会让播放器直接黑屏。
void main() {
  RemoteMediaCandidate file(String path, {bool isDir = false}) =>
      (path: path, name: path.split('/').last, isDirectory: isDir);

  group('selectRemoteMediaFiles · 过滤', () {
    test('只保留视频白名单扩展名', () {
      final result = selectRemoteMediaFiles([
        file('/m/a.mp4'),
        file('/m/b.txt'),
        file('/m/c.mkv'),
        file('/m/d.jpg'),
      ], isVideo: true);

      expect(result.map((e) => e.name), ['a.mp4', 'c.mkv']);
    });

    test('扩展名大小写不敏感（NAS 上常见的 IMG_0001.MP4）', () {
      final result = selectRemoteMediaFiles([
        file('/m/MOV_0001.MP4'),
        file('/m/clip.MkV'),
      ], isVideo: true);

      expect(result.map((e) => e.name), ['clip.MkV', 'MOV_0001.MP4']);
    });

    test('排除目录：即使名字伪装成 .mp4', () {
      final result = selectRemoteMediaFiles([
        file('/m/looks-like.mp4', isDir: true),
        file('/m/real.mp4'),
      ], isVideo: true);

      expect(result.map((e) => e.name), ['real.mp4']);
    });

    test('排除 cryptremote:// 虚拟路径（加密目录走独立链路，不能混进明文列表）', () {
      final result = selectRemoteMediaFiles([
        (path: 'cryptremote://c1|/enc/abc.mp4', name: '真实名字.mp4', isDirectory: false),
        file('/m/plain.mp4'),
      ], isVideo: true);

      expect(result.map((e) => e.name), ['plain.mp4']);
    });

    test('无扩展名 / 隐藏文件 / 无点号名字被排除', () {
      final result = selectRemoteMediaFiles([
        file('/m/.nomedia'),
        file('/m/README'),
        file('/m/ok.mp4'),
      ], isVideo: true);

      expect(result.map((e) => e.name), ['ok.mp4']);
    });

    test('音频与视频白名单互不通用', () {
      final items = [
        file('/m/a.mp4'),
        file('/m/b.mp3'),
        file('/m/c.flac'),
      ];

      expect(selectRemoteMediaFiles(items, isVideo: true).map((e) => e.name),
          ['a.mp4']);
      expect(selectRemoteMediaFiles(items, isVideo: false).map((e) => e.name),
          ['b.mp3', 'c.flac']);
    });

    test('远程常见但本地少见的格式也在白名单内（rmvb/rm/3gp/ts）', () {
      final result = selectRemoteMediaFiles([
        file('/m/a.rmvb'),
        file('/m/b.RM'),
        file('/m/c.3gp'),
        file('/m/d.ts'),
      ], isVideo: true);

      expect(result.map((e) => e.name), ['a.rmvb', 'b.RM', 'c.3gp', 'd.ts']);
    });

    test('空输入返回空列表', () {
      expect(selectRemoteMediaFiles(const [], isVideo: true), isEmpty);
    });

    test('排序：按文件名不区分大小写升序（与大小写敏感的顺序不同）', () {
      // 大写 ASCII 小于小写，直接 compareTo 会得到 B, a, c；要求的是 a, B, c
      final result = selectRemoteMediaFiles([
        file('/m/c.mp4'),
        file('/m/B.mp4'),
        file('/m/a.mp4'),
      ], isVideo: true);

      expect(result.map((e) => e.name), ['a.mp4', 'B.mp4', 'c.mp4']);
    });
  });

  group('buildRemotePlaylistPaths', () {
    test('统一构造成 remote://{connId}|{远程路径}', () {
      final uris = buildRemotePlaylistPaths('conn-1', [
        file('/Movies/a.mp4'),
        file('/Movies/sub/b.mp4'),
      ]);

      expect(uris, [
        'remote://conn-1|/Movies/a.mp4',
        'remote://conn-1|/Movies/sub/b.mp4',
      ]);
    });

    test('英文竖线分隔的连接 ID 与路径可被反向解析（与播放器 _resolveRemotePath 约定一致）', () {
      final uri = buildRemotePlaylistPaths('c1', [file('/a b/c.mp4')]).single;
      final body = uri.substring('remote://'.length);
      final sep = body.indexOf('|');

      expect(body.substring(0, sep), 'c1');
      expect(body.substring(sep + 1), '/a b/c.mp4');
    });
  });

  group('remotePlaylistIndexOf', () {
    test('命中当前文件返回其下标', () {
      final files = [
        file('/m/a.mp4'),
        file('/m/b.mp4'),
        file('/m/c.mp4'),
      ];

      expect(remotePlaylistIndexOf(files, '/m/b.mp4'), 1);
    });

    test('未命中返回 0（宁可不选中，也不能让上一个/下一个整体失效）', () {
      final files = [file('/m/a.mp4'), file('/m/b.mp4')];

      expect(remotePlaylistIndexOf(files, '/other/x.mp4'), 0);
    });

    test('空列表返回 0', () {
      expect(remotePlaylistIndexOf(const [], '/m/a.mp4'), 0);
    });

    test('只按完整路径匹配，同名的不同目录文件不算命中', () {
      final files = [file('/m/a.mp4'), file('/n/a.mp4')];

      expect(remotePlaylistIndexOf(files, '/n/a.mp4'), 1);
      expect(remotePlaylistIndexOf(files, '/x/a.mp4'), 0);
    });
  });

  group('端到端：目录条目 → 播放列表', () {
    test('从 SMB 目录条目得到列表、标题与当前下标', () {
      final entries = [
        (path: '/Public/Movies/2.mp4', name: '2.mp4', isDirectory: false),
        (path: '/Public/Movies/1.mp4', name: '1.mp4', isDirectory: false),
        (path: '/Public/Movies/cover.jpg', name: 'cover.jpg', isDirectory: false),
        (path: '/Public/Movies/Sub', name: 'Sub', isDirectory: true),
      ];
      final files = selectRemoteMediaFiles(entries, isVideo: true);

      expect(buildRemotePlaylistPaths('smb1', files), [
        'remote://smb1|/Public/Movies/1.mp4',
        'remote://smb1|/Public/Movies/2.mp4',
      ]);
      expect(files.map((f) => f.name).toList(), ['1.mp4', '2.mp4']);
      expect(remotePlaylistIndexOf(files, '/Public/Movies/2.mp4'), 1);
    });
  });
}
