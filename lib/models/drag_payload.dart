import '../services/remote/remote_client.dart';

class DragPayload {
  final String path;
  final bool isDirectory;
  final List<String> paths;
  final bool isRemote;
  final List<RemoteFileItem>? remoteItems;

  DragPayload({
    required this.path,
    required this.isDirectory,
    required this.paths,
    this.isRemote = false,
    this.remoteItems,
  });
}
