import 'package:path/path.dart' as p;

import '../remote/remote_client.dart';
import 'crypt_config.dart';
import 'crypt_mount.dart';
import 'crypt_operations.dart';

/// 一个候选加密配置 + 它的来源标识。
///
/// [profileId] 为 null 表示来自默认档案 / legacy（[_cryptConfigKey] 相同即
/// 视为同一凭据）。命中的候选会连同 profileId 一起登记进「关联远程加密
/// 目录」，供之后构造挂载点时按 id 取回同一份配置。
class CryptCandidate {
  final String? profileId;
  final RcloneCryptConfig config;

  const CryptCandidate(this.profileId, this.config);

  /// 凭据去重键：密码/盐/文件名加密参数完全相同就只跑一次判定。
  String get configKey =>
      '${config.password}|${config.salt ?? ''}|${config.filenameEncryption.name}'
      '|${config.filenameEncoding.name}|${config.encryptedSuffix}'
      '|${config.directoryNameEncryption}';
}

/// 「自动关联远程加密文件」的就地判定（**纯逻辑，零 IO**）。
///
/// 与 provider 的关系：provider 只负责准备候选配置（默认档案 / 全部档案）与
/// 登记副作用，判定本身全部在这里 —— 因此可以完整单测，真机排查时也能凭
/// 返回下标直接知道「是哪个配置命中的」。
///
/// ## 为什么必须支持多配置候选
/// 加密上传（`FileManagerProvider.encryptUploadToRemoteDir`）允许指定
/// `profileId`，用户设备上完全可能是「用 B 档案加密、当前默认是 A 档案」。
/// 只拿默认配置做往返校验会整体失配，表现为「开关开了却什么都不发生」
/// （2026-10-24 用户报障）。
class RemoteCryptAutoAssoc {
  const RemoteCryptAutoAssoc._();

  /// 目录内容判据的最多扫描条数（密文往返校验是纯 CPU，200 条足够判定，
  /// 又能把万级目录的单次耗时压到毫秒级）。
  static const int maxScan = 200;

  /// 目录内容判据的命中数下限。
  ///
  /// ⚠️ **不设占比上限**（2026-10-24 用户报障）：加密目录里常常同时躺着普通
  /// 文件（用户只加密了其中一部分），旧实现要求「密文占比 ≥60%」时，混合目录
  /// 要删掉全部普通文件才肯关联。名字级往返校验（解密 → 再加密 → 逐字节比对）
  /// 对单个明文名巧合命中的概率约 1e-5（base32 字母表 + 16 字节块长 + PKCS7 +
  /// UTF-8 四重约束），因此 **2 个命中即足够定罪**，与占比无关。
  static const int minMatched = 2;

  /// 用 [configs] 逐一尝试把 [items] 判定为密文列表，返回**命中的配置下标**；
  /// 全部未命中返回 `null`。
  ///
  /// 判据一（目录内容）：≥[minMatched] 项命中，**不看占比** —— 混合目录
  ///   （密文 + 普通文件共存）同样关联；只有密文项享受解密视图，普通项原样显示
  ///   （逐条目往返校验见 [RemoteCryptDirectoryLister]）。
  /// 判据二（目录自身名字）：本目录名本身就是密文名，且目录内 ≥1 项命中。
  ///   覆盖「用户在父目录看到这个密文文件夹，点进去时里面只有一两个文件」
  ///   （不够判据一的门槛）。目录名不带后缀干扰，往返校验比文件名更强。
  ///
  /// [serverDir] 仅用于判据二取目录名；判定不依赖它是否存在。
  static int? matchConfigIndex(
    List<RemoteFileItem> items, {
    required String serverDir,
    required List<RcloneCryptConfig> configs,
  }) {
    if (items.isEmpty || configs.isEmpty) return null;
    final ownName = p.posix.basename(serverDir);
    for (var i = 0; i < configs.length; i++) {
      final config = configs[i];
      if (config.password.isEmpty) continue;
      // 文件名不加密（只加密内容）⇒ 名字空间就是明文，无从判定。
      if (config.filenameEncryption == FilenameEncryption.off) continue;
      // 判定只用 config/crypt，physicalPath 不参与（密文名校验与路径无关）。
      final mount = CryptMountPoint(
        physicalPath: serverDir,
        config: config,
        name: ownName,
      );
      var scanned = 0;
      var matched = 0;
      for (final it in items) {
        final name = it.name;
        if (name.isEmpty || name == '.' || name == '..') continue;
        if (++scanned > maxScan) break;
        final ok = it.isDirectory
            ? CryptOperations.isCipherDirName(name, mount)
            : CryptOperations.isCipherFileName(name, mount);
        if (ok) matched++;
      }
      if (scanned == 0) continue;
      if (matched >= minMatched) {
        return i;
      }
      if (matched >= 1 &&
          ownName.isNotEmpty &&
          ownName != '/' &&
          CryptOperations.isCipherDirName(ownName, mount)) {
        return i;
      }
    }
    return null;
  }
}
