
class RemoteFileItem {
  final String name;
  final String path;
  final bool isDirectory;
  final int size;
  final DateTime modified;

  RemoteFileItem({
    required this.name,
    required this.path,
    required this.isDirectory,
    required this.size,
    required this.modified,
  });

  String get formattedSize {
    if (isDirectory) return '';
    if (size <= 0) return '0 B';
    const suffixes = ['B', 'KB', 'MB', 'GB', 'TB'];
    var i = 0;
    var doubleSize = size.toDouble();
    while (doubleSize >= 1024 && i < suffixes.length - 1) {
      doubleSize /= 1024;
      i++;
    }
    return '${doubleSize.toStringAsFixed(1)} ${suffixes[i]}';
  }
}

abstract class RemoteClient {
  Future<void> connect();
  Future<void> disconnect();
  Future<List<RemoteFileItem>> listDirectory(String path, {bool forceRefresh = false});
  Future<void> createDirectory(String path);
  Future<void> createFile(String path);
  Future<void> delete(String path, bool isDir);
  Future<void> rename(String oldPath, String newPath);
  Future<void> downloadFile(String remotePath, String localPath, Function(double progress) onProgress);

  /// 下载远程文件的指定字节范围到本地文件，用于生成缩略图等只需文件头部的场景。
  /// [startByte] 起始字节偏移（inclusive），[length] 要下载的字节数。
  /// 下载结果写入 localPath（只包含请求范围内的字节）。
  Future<void> downloadRange(String remotePath, String localPath, int startByte, int length);
  Future<void> uploadFile(String localPath, String remotePath, Function(double progress) onProgress);

  /// Returns a URL that can be used for streaming playback, or null if streaming is not supported.
  /// Currently only WebDAV supports this (returns HTTP URL with Basic Auth).
  String? getStreamUrl(String remotePath);

  /// Returns the file size in bytes, or -1 if unknown.
  /// Used by RemoteStreamingService for progressive streaming support.
  Future<int> getFileSize(String remotePath);

  // 取消令牌：设置为 true 时，进行中的 downloadFile/uploadFile 应尽快退出
  bool _cancelled = false;
  bool get isCancelled => _cancelled;
  void cancel() {
    _cancelled = true;
  }
  void resetCancel() {
    _cancelled = false;
  }

  /// 上传完成后最终化：部分服务端（飞牛 NAS、openlist 等）在传输期间把数据写入
  /// 临时文件（如 `file-<数字>`），传输结束后才重命名为目标文件。
  ///
  /// 默认实现：列出目录，若存在完整临时文件且目标文件不存在，则主动 rename。
  /// 子类可覆盖以实现更精确的检测逻辑（如 FTP 的 [FtpRemoteClient]）。
  ///
  /// 返回值：目标文件是否已最终化（存在、无临时文件、大小达标）。
  Future<bool> finalizeUpload(String remoteDir, String targetName, int expectedSize) async {
    return true; // 默认实现：不做任何检测，视为已最终化
  }
}
