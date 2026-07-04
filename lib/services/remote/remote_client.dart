
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
  Future<List<RemoteFileItem>> listDirectory(String path);
  Future<void> createDirectory(String path);
  Future<void> createFile(String path);
  Future<void> delete(String path, bool isDir);
  Future<void> rename(String oldPath, String newPath);
  Future<void> downloadFile(String remotePath, String localPath, Function(double progress) onProgress);
  Future<void> uploadFile(String localPath, String remotePath, Function(double progress) onProgress);

  /// Returns a URL that can be used for streaming playback, or null if streaming is not supported.
  /// Currently only WebDAV supports this (returns HTTP URL with Basic Auth).
  String? getStreamUrl(String remotePath);

  /// Returns the file size in bytes, or -1 if unknown.
  /// Used by RemoteStreamingService for progressive streaming support.
  Future<int> getFileSize(String remotePath);
}
