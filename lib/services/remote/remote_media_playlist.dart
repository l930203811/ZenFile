/// 远程媒体播放列表构建的**纯逻辑**：不依赖 Flutter、provider 或网络，
/// 便于单测（见 test/remote/remote_media_playlist_test.dart）。
///
/// 背景：从远程浏览页/分类页点开一个视频时，播放器需要拿到「同一远程目录里
/// 其它视频」组成播放列表，条目统一写成 `remote://{connId}|{远程路径}`，
/// 由 `VideoPlayerScreen._resolveRemotePath` 在切换时按需建立流，因此这里
/// 不预先建流、不访问网络。
library;

import 'package:path/path.dart' as p;

/// 远程视频扩展名白名单。
/// 与本地播放列表（`VideoPlayerScreen._resolvePlaylist`）保持接近，
/// 额外补上远程常见的 `.rmvb/.rm/.3gp`（部分 NAS 上仍以这些格式存片）。
const List<String> kRemoteVideoExtensions = <String>[
  '.mp4', '.mkv', '.avi', '.mov', '.flv', '.wmv', '.webm',
  '.m4v', '.ts', '.mpg', '.mpeg', '.3gp', '.rmvb', '.rm',
];

/// 远程音频扩展名白名单。
const List<String> kRemoteAudioExtensions = <String>[
  '.mp3', '.aac', '.wav', '.flac', '.ogg', '.m4a', '.wma',
  '.opus', '.ape', '.aiff',
];

/// 一条候选条目：[path] 远程真实路径，[name] 显示名（含扩展名）。
typedef RemoteMediaCandidate = ({String path, String name, bool isDirectory});

/// 从目录条目里筛出同类型媒体文件，按文件名（不区分大小写）升序。
///
/// 排除三类：
/// - 目录本身；
/// - `cryptremote://` 虚拟路径 —— 加密目录的条目属于加密链路
///   （`_openRemoteCryptFile` 等），混进普通 `remote://` 播放列表会把
///   密文虚拟路径当成明文播放地址；
/// - 扩展名不在白名单内的文件。
///
/// 大小写不敏感：NAS 上常见的 `MOV_0001.MP4` 也必须能被识别。
List<RemoteMediaCandidate> selectRemoteMediaFiles(
  Iterable<RemoteMediaCandidate> candidates, {
  required bool isVideo,
}) {
  final exts = isVideo ? kRemoteVideoExtensions : kRemoteAudioExtensions;
  return candidates
      .where((c) => !c.isDirectory)
      .where((c) => !c.path.startsWith('cryptremote://'))
      .where((c) => exts.contains(p.extension(c.name).toLowerCase()))
      .toList()
    ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
}

/// 把候选列表转成播放列表条目：`remote://{connId}|{远程路径}`。
List<String> buildRemotePlaylistPaths(
  String connectionId,
  List<RemoteMediaCandidate> files,
) =>
    files.map((f) => 'remote://$connectionId|${f.path}').toList();

/// 当前文件在播放列表中的下标。
/// 找不到（例如扩展名白名单外、或目录被外部改动）时返回 0：
/// 宁可高亮错一项，也不要让播放器的「上一个/下一个」整体失效。
int remotePlaylistIndexOf(
  List<RemoteMediaCandidate> files,
  String currentPath,
) {
  final i = files.indexWhere((f) => f.path == currentPath);
  return i < 0 ? 0 : i;
}

/// `AudioPlayerScreen` 队列里远程条目的 id 基准值。
///
/// 取 **负数**，与 MediaStore 的音频 id（正整数）天然隔开：
/// - `AudioPlayerScreen._updateBackgroundItem` 只在 `song.id > 0` 时才去查
///   MediaStore 封面 —— 负数直接跳过，不会拿一个不存在的 id 去骚扰媒体库；
/// - `AudioArtworkWidget` 对 `id <= 100 || id == 0` 已有降级分支，负数命中该分支，
///   显示默认音符图标而不是空占位。
const int kRemoteAudioSongIdBase = -1000;

/// 把远程音频播放列表转成 `AudioPlayerScreen` 队列所需的 `SongModel` 构造 map。
///
/// **为什么这样就能支持远程音频队列（而不是「大改」）**：
/// `AudioPlayerScreen` 的队列类型是 `List<SongModel>`，而 `SongModel` 只是
/// `Map<String, dynamic>` 的薄包装。项目里早就有两处在塞**手工构造**的 SongModel：
///
/// - 保险箱加密音频（`file_manager_provider` 里 `SongModel(songMap)`，`_data`
///   指向「不在 MediaStore 里的临时解密路径」）；
/// - 自定义路径扫描音频（`media_provider` 里伪造 `_id: 800000 + n`）。
///
/// 远程音频只是第三种同类场景：`_data` 填 `remote://{connId}|{远程路径}`，
/// 播放器 `_openTrack` 里既有的 `_resolveRemotePath`（WebDAV 直连 / 本地代理 /
/// 下载兜底）会自动把它解析成可播放的流，切歌时同理。因此**播放器侧无需改动**。
///
/// [playlistUris] 与 [titles] 一一对应，前者形如 `remote://{connId}|{path}`。
List<Map<String, dynamic>> buildRemoteAudioSongMaps(
  List<String> playlistUris,
  List<String> titles,
) {
  final out = <Map<String, dynamic>>[];
  for (var i = 0; i < playlistUris.length; i++) {
    final name = i < titles.length ? titles[i] : p.basename(playlistUris[i]);
    out.add(<String, dynamic>{
      '_id': kRemoteAudioSongIdBase - i,
      '_data': playlistUris[i],
      'title': p.basenameWithoutExtension(name),
      'artist': '',
      'album': '',
      'duration': 0,
      'size': 0,
      'display_name': name,
      'display_name_wo_ext': p.basenameWithoutExtension(name),
      'is_music': true,
    });
  }
  return out;
}
