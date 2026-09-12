import 'dart:io';
import '../services/remote/remote_client.dart';

class FileItemModel {
  final FileSystemEntity entity;
  final String name;
  final String path;
  final bool isDirectory;
  final int size;
  final DateTime modified;

  /// 是否真实被加密（仅在加密挂载点目录内枚举时由 CryptVFS 标记）。
  /// 用于浏览页只给真实加密的条目显示🔐角标，其余正常显示。
  final bool isEncrypted;

  /// Remote file metadata — null for local files
  final RemoteFileItem? remoteSource;

  bool get isRemote => remoteSource != null;

  /// 用于图标/类型判断的显示路径。
  /// 远程加密条目的 [path] 是密文虚拟路径（如 `cryptremote://conn|/a/b/cipherName`），
  /// 直接用 [path] 取扩展名会得到 base32 密文扩展名，导致图标全部显示为未知格式。
  /// 此时 [name] 是解密后的真实文件名，因此类型判断应使用 [displayPath]。
  String get displayPath => path.startsWith('cryptremote://') ? name : path;

  FileItemModel({
    required this.entity,
    required this.name,
    required this.path,
    required this.isDirectory,
    required this.size,
    required this.modified,
    this.remoteSource,
    this.isEncrypted = false,
  });

  factory FileItemModel.fromEntity(FileSystemEntity entity) {
    try {
      final stat = entity.statSync();
      return FileItemModel(
        entity: entity,
        name: entity.path.split(Platform.pathSeparator).last,
        path: entity.path,
        isDirectory: entity is Directory,
        size: stat.size,
        modified: stat.modified,
      );
    } catch (_) {
      return FileItemModel(
        entity: entity,
        name: entity.path.split(Platform.pathSeparator).last,
        path: entity.path,
        isDirectory: entity is Directory,
        size: 0,
        modified: DateTime.fromMillisecondsSinceEpoch(0),
      );
    }
  }

  static Future<FileItemModel> fromEntityAsync(FileSystemEntity entity) async {
    try {
      final stat = await entity.stat();
      return FileItemModel(
        entity: entity,
        name: entity.path.split(Platform.pathSeparator).last,
        path: entity.path,
        isDirectory: entity is Directory,
        size: stat.size,
        modified: stat.modified,
      );
    } catch (_) {
      return FileItemModel(
        entity: entity,
        name: entity.path.split(Platform.pathSeparator).last,
        path: entity.path,
        isDirectory: entity is Directory,
        size: 0,
        modified: DateTime.fromMillisecondsSinceEpoch(0),
      );
    }
  }

  factory FileItemModel.fromCustom({
    required String path,
    required bool isDirectory,
    required int size,
    required DateTime modified,
  }) {
    final entity = isDirectory ? Directory(path) : File(path);
    return FileItemModel(
      entity: entity,
      name: path.split(Platform.pathSeparator).last,
      path: path,
      isDirectory: isDirectory,
      size: size,
      modified: modified,
    );
  }

  /// Build a FileItemModel from a remote file listing result.
  /// The [entity] is a stub (Directory or File at a fake local path) so that
  /// the rest of the app (icons, file-type detection) works unchanged.
  factory FileItemModel.fromRemoteFileItem(RemoteFileItem remote) {
    final stubEntity = remote.isDirectory ? Directory(remote.path) : File(remote.path);
    return FileItemModel(
      entity: stubEntity,
      name: remote.name,
      path: remote.path,
      isDirectory: remote.isDirectory,
      size: remote.size,
      modified: remote.modified,
      remoteSource: remote,
    );
  }

  bool get isHidden => name.startsWith('.') && name != '.' && name != '..';
}
