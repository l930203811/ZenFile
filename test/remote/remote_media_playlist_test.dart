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

  group('buildRemoteAudioSongMaps · 远程音频队列', () {
    test('每个条目映射成 SongModel 构造 map，_data 为 remote:// URI', () {
      final maps = buildRemoteAudioSongMaps(
        ['remote://smb1|/Music/a.mp3', 'remote://smb1|/Music/b.flac'],
        ['a.mp3', 'b.flac'],
      );

      expect(maps.length, 2);
      expect(maps[0]['_data'], 'remote://smb1|/Music/a.mp3');
      expect(maps[0]['title'], 'a');
      expect(maps[0]['display_name'], 'a.mp3');
      expect(maps[0]['display_name_wo_ext'], 'a');
      expect(maps[0]['is_music'], true);
      expect(maps[1]['_data'], 'remote://smb1|/Music/b.flac');
    });

    test('id 全为负数：跳过 MediaStore 封面查询', () {
      final maps = buildRemoteAudioSongMaps(
        ['remote://c|/1.mp3', 'remote://c|/2.mp3', 'remote://c|/3.mp3'],
        ['1.mp3', '2.mp3', '3.mp3'],
      );
      final ids = maps.map((m) => m['_id'] as int).toList();

      expect(ids.every((id) => id < 0), true,
          reason: 'AudioPlayerScreen 只在 song.id > 0 时才去查 MediaStore 封面');
    });

    test('id 互不相同：否则队列高亮会错位', () {
      final maps = buildRemoteAudioSongMaps(
        ['remote://c|/1.mp3', 'remote://c|/2.mp3'],
        ['1.mp3', '2.mp3'],
      );
      final ids = maps.map((m) => m['_id'] as int).toSet();
      expect(ids.length, 2);
    });

    test('id 落在 AudioArtworkWidget 的降级区间（<= 100）', () {
      final maps = buildRemoteAudioSongMaps(['remote://c|/1.mp3'], ['1.mp3']);
      expect((maps.single['_id'] as int) <= 100, true);
    });

    test('artist / album 留空，由播放器按 l10n 显示「未知艺术家 / 单曲」', () {
      final maps = buildRemoteAudioSongMaps(['remote://c|/1.mp3'], ['1.mp3']);
      expect(maps.single['artist'], '');
      expect(maps.single['album'], '');
      expect(maps.single['duration'], 0);
    });

    test('titles 比 playlist 短时不越界，用 URI 兜底推导文件名', () {
      final maps = buildRemoteAudioSongMaps(
        ['remote://c|/dir/song.mp3', 'remote://c|/dir/other.mp3'],
        ['song.mp3'],
      );
      expect(maps.length, 2);
      expect(maps[0]['title'], 'song');
      expect(maps[1]['title'], 'other');
    });

    test('空列表返回空（调用方据此退化为单曲播放）', () {
      expect(buildRemoteAudioSongMaps(const [], const []), isEmpty);
    });

    test('扩展名留在 display_name、从 title 去掉（与本地音频行为一致）', () {
      final maps = buildRemoteAudioSongMaps(
        ['remote://c|/Music/zhou - qingtian.mp3'],
        ['zhou - qingtian.mp3'],
      );
      expect(maps.single['title'], 'zhou - qingtian');
      expect(maps.single['display_name'], 'zhou - qingtian.mp3');
    });
  });
}
