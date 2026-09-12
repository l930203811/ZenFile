/// 远程加密目录枚举（客户端解密文件名）
///
/// 通过 [RemoteClient.listDirectory] 拿到后端上的密文名，再用 [RcloneCrypt]
/// 在本地解密文件名/目录名，因此列表展示的是**解密后**的真实名称，且不下载
/// 任何文件内容（零网络内容流量、零密钥外发）。
///
/// 条目虚拟路径统一为 `cryptremote://{connId}|{serverEncryptedPath}`，
/// 供流式解密（[CryptStreamServer]）与后续导航复用。
library;

import '../remote/remote_client.dart';
import 'crypt_mount.dart';
import 'crypt_operations.dart';
import 'rclone_crypt.dart';

class RemoteCryptDirectoryLister {
  final CryptMountPoint _mount;
  final RemoteClient _client;

  RemoteCryptDirectoryLister(this._mount, this._client);

  /// 枚举远程加密目录
  ///
  /// [virtualDirPath] 虚拟目录路径（`cryptremote://{connId}|{serverEncryptedPath}`）。
  /// [onlyEncrypted] 为 true 时只返回文件名/目录名能被成功解密的条目，
  ///   用于保险箱「原地加密」列表，避免把后端上未加密的普通文件显示成已加密。
  Future<List<CryptFileEntry>> listDirectory(
    String virtualDirPath, {
    bool showHidden = false,
    bool onlyEncrypted = false,
  }) async {
    final serverPath = _mount.virtualToRemoteServerPath(virtualDirPath);
    final items = await _client.listDirectory(serverPath);

    final entries = <CryptFileEntry>[];
    for (final item in items) {
      final physicalName = item.name;

      // 跳过 rclone crypt 配置文件
      if (physicalName == 'rclone.conf' || physicalName == '.rclone.conf') {
        continue;
      }

      String virtualName;
      var decryptionSucceeded = false;
      try {
        virtualName = item.isDirectory
            ? _mount.crypt.decryptDirName(physicalName)
            : _mount.crypt.decryptFileName(physicalName);
        decryptionSucceeded = true;
      } catch (_) {
        // 解密失败，可能不是加密条目，保留原名
        virtualName = physicalName;
      }

      if (onlyEncrypted && !decryptionSucceeded) continue;
      if (!showHidden && virtualName.startsWith('.')) continue;

      final childVirtualPath =
          'cryptremote://${_mount.remoteConnId}|${item.path}';

      var size = 0;
      if (!item.isDirectory) {
        try {
          size = calculateDecryptedSize(item.size);
        } catch (_) {
          size = 0;
        }
      }

      entries.add(CryptFileEntry(
        name: virtualName,
        virtualPath: childVirtualPath,
        physicalPath: childVirtualPath,
        isDirectory: item.isDirectory,
        size: size,
        modified: item.modified,
        isEncrypted: decryptionSucceeded,
      ));
    }

    entries.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return entries;
  }
}
