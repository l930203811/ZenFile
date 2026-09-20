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
