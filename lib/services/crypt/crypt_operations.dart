/// 加密目录枚举与原地加解密操作
///
/// 提供加密目录的文件列表枚举（自动解密文件名），
/// 以及文件/文件夹的原地加密和解密操作。
library;

import 'dart:io';
import 'package:path/path.dart' as p;
import '../../core/utils.dart';
import 'crypt_batch_runner.dart';
import 'crypt_stream_server.dart';
import 'crypt_config.dart';
import 'crypt_mount.dart';
import 'crypt_mount_service.dart';
import 'crypt_tree_walker.dart';
import 'filename_cipher.dart';
import 'stream_cipher.dart';
import 'rclone_crypt.dart';

/// 加密文件项（枚举目录时返回）
class CryptFileEntry {
  /// 解密后的文件名
  final String name;

  /// 解密后的完整路径（虚拟路径）
  final String virtualPath;

  /// 加密后的完整路径（物理路径）
  final String physicalPath;

  /// 是否为目录
  final bool isDirectory;

  /// 解密后的文件大小（仅文件有效）
  final int size;

  /// 最后修改时间
  final DateTime modified;

  /// 是否真实被加密（文件名/目录名解密成功）。
  /// 用于浏览页只给真实加密的条目显示🔐角标，其余正常显示。
  final bool isEncrypted;

  /// 「明文同名冲突」：同一父目录下存在与本项目**解密名相同**的明文条目。
  ///
  /// 典型场景：相机检测不到密文目录（名字是密文），重建同名明文目录继续写
  /// 新照片 → 浏览父目录时密文条目（显示解密名）与明文条目的虚拟路径完全
  /// 重合，且 `resolvePhysicalPath` 的「明文已存在」短路会让两个条目都打开
  /// 明文目录 → 用户看到「点哪个都是新文件、已加密内容消失」。
  /// 浏览层应改用 [physicalPath] 作为该条目的跳转路径。
  final bool plainNameClash;

  CryptFileEntry({
    required this.name,
    required this.virtualPath,
    required this.physicalPath,
    required this.isDirectory,
    this.size = 0,
    required this.modified,
    this.isEncrypted = false,
    this.plainNameClash = false,
  });

  /// 文件扩展名（解密后的）
  String get extension => p.extension(name);
}

/// 加密目录里一组图片兄弟：可直接渲染的地址 + 显示名（两者等长并行）。
class CryptImageSiblings {
  /// 可直接交给图片查看器渲染的地址：明文为本地路径，加密条目为流式解密 URL。
  final List<String> paths;

  /// 与 [paths] 等长的显示名（加密条目为**解密后**的真实文件名）。
  final List<String> names;

  const CryptImageSiblings(this.paths, this.names);
}

/// 收集与 [current] 同目录的图片兄弟，供图片查看器左右滑动切换上一张 / 下一张。
///
/// 加密条目在磁盘上是密文（或 `cryptremote://` 虚拟路径），查看器自己渲染不了，
/// 必须先换成流式解密 URL —— 未运行流服务器时加密项无从渲染，直接返回 null 退回
/// 单张展示，也不往列表里塞无法渲染的项（那会让滑动过程中出现空白页）。
///
/// ⚠️ **必须异步**：函数开头要 `await CryptStreamServer.instance.ensureInitialized()`。
/// 流式解密服务器只在 provider 的 `_ensureCryptMountsLoaded()` 末尾启动，而保险箱
/// （沙盒）与「远程加密」浏览页走的是 `CryptMountService` + `CryptDirectoryLister`，
/// 全程不碰 provider 的挂载点缓存 ⇒ 用户第一次点开加密图片时服务器**还没启动**。
/// 旧实现同步读 `isRunning` 得到 false，直接返回 null ⇒ 查看器只拿到 1 张
/// ⇒ 「原地加密能左右滑、沙盒加密不能左右滑」（用户 2026-10-19 反馈的差异）。
Future<CryptImageSiblings?> collectCryptImageSiblings(
  List<CryptFileEntry> entries,
  CryptFileEntry current, {
  /// 条目所属挂载点（保险箱沙盒 / 原地加密目录）。给了就顺手注册到流式服务器：
  /// 沙盒目录可能还没被 provider 的挂载点缓存覆盖，不注册的话流请求会 404
  /// （图片显示成一直转圈 / 空白）。
  CryptMountPoint? mount,
}) async {
  if (!FileUtils.isImage(current.name)) return null;
  try {
    await CryptStreamServer.instance.ensureInitialized();
    if (mount != null) {
      if (mount.isRemote) {
        CryptStreamServer.instance.registerRemoteMount(mount);
      } else {
        CryptStreamServer.instance.registerMount(mount);
      }
    }
  } catch (_) {}
  final streamReady = CryptStreamServer.instance.isRunning;
  final paths = <String>[];
  final names = <String>[];
  for (final e in entries) {
    if (e.isDirectory || !FileUtils.isImage(e.name)) continue;
    if (e.isEncrypted) {
      // 名字解密成功 ⇒ 磁盘上一定是密文，只能走流式解密。
      if (!streamReady) return null;
      paths.add(CryptStreamServer.instance.getStreamUrl(e.virtualPath));
    } else if (e.virtualPath.startsWith('cryptremote://')) {
      // 远程加密目录里的**明文**条目：`cryptremote://` 虚拟路径既不能直接渲染，
      // 也不适合塞进流式解密链路（那不是密文）。跳过，避免出现空白页。
      continue;
    } else if (await File(e.virtualPath).exists()) {
      // 真正存在于磁盘上的明文（未加密的普通文件）→ 直接渲染。
      paths.add(e.virtualPath);
    } else {
      // 「名字没解开」但磁盘上也没有这个明文路径 ⇒ 其实就是密文（沙盒里
      // 目录名不加密时 decryptFileName 会退化成恒等函数，isEncrypted 可能为 false）。
      if (!streamReady) return null;
      paths.add(CryptStreamServer.instance.getStreamUrl(e.virtualPath));
    }
    names.add(e.name);
  }
  return paths.isEmpty ? null : CryptImageSiblings(paths, names);
}

/// 加密目录枚举器
class CryptDirectoryLister {
  final CryptMountPoint _mount;

  CryptDirectoryLister(this._mount);

  /// 枚举加密目录中的文件和子目录
  ///
  /// [virtualDirPath] 解密后的目录路径（虚拟路径）
  /// [showHidden] 是否显示隐藏文件
  /// [onlyEncrypted] 为 true 时只返回文件名/目录名能被成功解密的条目，
  ///   用于「保险箱-原地加密」列表，避免把挂载点内未加密的普通文件也显示成已加密。
  Future<List<CryptFileEntry>> listDirectory(
    String virtualDirPath, {
    bool showHidden = false,
    bool onlyEncrypted = false,
  }) async {
    // 将虚拟路径转换为物理路径。
    //
    // ⚠️ 必须用 resolvePhysicalPath，不能直接用 virtualToPhysical：
    // 后者对**最后一段**统一走 encryptFileName（会追加加密后缀），而目录名在
    // rclone 里是不带后缀的 —— 于是「点击加密文件夹进入」时算出的
    // `<密文目录名>.bin` 在磁盘上根本不存在 → 抛 Directory not found →
    // 浏览页整目录空白（用户看到的「文件夹消失 / 打不开」）。
    // resolvePhysicalPath 内含「去后缀重试 + 目录扫描反查」两级兜底。
    var physicalDirPath = await _mount.resolvePhysicalPath(virtualDirPath);
    if (!await Directory(physicalDirPath).exists()) {
      if (await Directory(virtualDirPath).exists()) {
        // 挂载点内「未加密的普通子目录」：本身就是明文，直接按明文枚举
        physicalDirPath = virtualDirPath;
      } else {
        throw FileSystemException('Directory not found', physicalDirPath);
      }
    }

    final dir = Directory(physicalDirPath);
    if (!await dir.exists()) {
      throw FileSystemException('Directory not found', physicalDirPath);
    }

    final entries = <CryptFileEntry>[];
    final entities = await dir.list().toList();

    for (final entity in entities) {
      final physicalName = p.basename(entity.path);

      // 跳过 rclone crypt 的配置文件
      if (physicalName == 'rclone.conf' || physicalName == '.rclone.conf') {
        continue;
      }

      // 跳过加/解密中途的临时文件（失败残留时不应显示给用户）
      if (physicalName.endsWith(CryptOperations._tmpSuffix)) {
        continue;
      }

      // 尝试解密文件名
      String virtualName;
      var decryptionSucceeded = false;
      try {
        if (entity is Directory) {
          virtualName = _mount.crypt.decryptDirName(physicalName);
        } else {
          virtualName = _mount.crypt.decryptFileName(physicalName);
        }
        decryptionSucceeded = true;
      } catch (_) {
        // 解密失败，可能不是加密文件，保留原名
        virtualName = physicalName;
      }

      // 保险箱「原地加密」列表只应显示真实已加密的文件/目录。
      //
      // ⚠️ 判据**不能**用「上面没抛异常」：`directoryNameEncryption=false` 时
      // `decryptDirName` 退化成恒等函数（原样返回、永不抛），于是**任何**目录名
      // 都算「解密成功」 ⇒ 保险箱列表把挂载点内所有普通文件夹都当成已加密条目
      // 列出来（用户反馈：把配置改成「不加密目录名」后，列表冒出存储根下全部
      // 文件夹；改回「加密目录名」又只剩真正的那一个 —— 因为前后只差这个判据）。
      // 文件名侧同理（`filenameEncryption=off` 时名字不参与加密）。
      // 这里改用 [CryptOperations.isCipherDirName] / [isCipherFileName] 的
      // **往返校验**判据：名字映射一旦退化成恒等，它必然返回 false（即
      // 「名字级信号失效 ⇒ 不认」），与浏览层的加密判定同源，避免「列表里有、
      // 实际并未加密」。
      if (onlyEncrypted) {
        final reallyCipher = entity is Directory
            ? CryptOperations.isCipherDirName(physicalName, _mount)
            : CryptOperations.isCipherFileName(physicalName, _mount);
        if (!reallyCipher) {
          continue;
        }
      }

      // 隐藏文件过滤
      if (!showHidden && virtualName.startsWith('.')) {
        continue;
      }

      // 计算文件大小（解密后的大小）
      var size = 0;
      if (entity is File) {
        try {
          final stat = await entity.stat();
          size = calculateDecryptedSize(stat.size);
        } catch (_) {
          size = 0;
        }
      }

      final stat = await entity.stat();

      entries.add(CryptFileEntry(
        name: virtualName,
        virtualPath: p.join(virtualDirPath, virtualName),
        physicalPath: entity.path,
        isDirectory: entity is Directory,
        size: size,
        modified: stat.modified,
        isEncrypted: decryptionSucceeded,
      ));
    }

    // 明文同名冲突标记：解密名与同目录下某个**明文条目**的磁盘名相同时，
    // 该密文条目的虚拟路径会与明文条目的真实路径重合（浏览层两个条目指向
    // 同一路径，且 resolvePhysicalPath 的「明文已存在」短路会让它们全部
    // 落到明文目录上）。打上标记后，浏览层用 physicalPath 直达密文条目。
    final plainNames = entries
        .where((e) => !e.isEncrypted)
        .map((e) => e.name)
        .toSet();
    if (plainNames.isNotEmpty) {
      for (var i = 0; i < entries.length; i++) {
        final e = entries[i];
        if (e.isEncrypted && plainNames.contains(e.name)) {
          entries[i] = CryptFileEntry(
            name: e.name,
            virtualPath: e.virtualPath,
            physicalPath: e.physicalPath,
            isDirectory: e.isDirectory,
            size: e.size,
            modified: e.modified,
            isEncrypted: e.isEncrypted,
            plainNameClash: true,
          );
        }
      }
    }

    // 按名称排序
    entries.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));

    return entries;
  }
}

/// 原地加密/解密操作
class CryptOperations {
  final CryptMountPoint _mount;

  CryptOperations(this._mount);

  /// 名字是否**可能**是 rclone crypt 密文（纯字符串判定：零 I/O、零密钥派生）。
  ///
  /// 依据严格对齐 [FilenameCipher]：密文主体 = PKCS7 补齐到 16 字节倍数后的
  /// EME 密文，再经 base32/base64 编码。因此「去掉配置后缀后能被对应编码解出、
  /// 且字节数是 16 的倍数」才可能成立（base32768 例外，见实现内注释）。
  /// 这一步能滤掉绝大多数普通名字
  /// （DCIM / Download / Android / IMG_20260101.jpg …），
  /// 用于「该目录到底该不该按加密目录处理」的低成本预筛。
  ///
  /// ⚠️ 只是**必要非充分**条件：命中后仍需按文件头的 RCLONE magic 二次确认。
  static bool mayBeCipherName(String name, RcloneCryptConfig config) {
    final stems = <String>[name];
    final suffix = config.encryptedSuffix;
    // 文件名解密会先剥掉配置后缀；目录名解密不剥后缀 —— 两种形态都要试。
    // （顺带兼容「后缀配置与加密时不一致」，如 OpenList 空后缀 + 本地 .bin）
    if (suffix.isNotEmpty && name.endsWith(suffix)) {
      stems.add(name.substring(0, name.length - suffix.length));
    }
    for (final stem in stems) {
      if (stem.isEmpty) continue;
      try {
        final raw = decodeFilename(stem, config.filenameEncoding);
        if (raw.isEmpty) continue;
        if (config.filenameEncoding == FilenameEncoding.base32768) {
          // base32768 每字符承载 15 bit，而 15*字符数 不是 8 的倍数，
          // 解码得到的字节数**不必然是** 16 的倍数，只能做长度下限判定。
          if (raw.length >= nameCipherBlockSize) return true;
        } else if (raw.length % nameCipherBlockSize == 0) {
          return true;
        }
      } catch (_) {}
    }
    return false;
  }

  /// 读文件头判断是否为真实的 rclone crypt 密文（比对 RCLONE magic）。
  static Future<bool> isEncryptedFile(String path) async {
    try {
      final file = File(path);
      if (!await file.exists()) return false;
      final raf = await file.open(mode: FileMode.read);
      try {
        final head = await raf.read(fileMagicSize);
        if (head.length < fileMagicSize) return false;
        for (var i = 0; i < fileMagicSize; i++) {
          if (head[i] != fileHeaderMagicBytes[i]) return false;
        }
        return true;
      } finally {
        await raf.close();
      }
    } catch (_) {
      return false;
    }
  }

  /// 目录内是否**确实**存在 rclone crypt 密文。
  ///
  /// 用于判断「未被任何持久化挂载点覆盖的目录」（典型：存储根目录 ——
  /// 根挂载点会命中全盘所有路径，因此被禁止）该不该按加密目录处理。
  /// 只有目录内**确有**密文时才返回 true，普通目录一律 false，
  /// 避免把整个存储卷进加密视图。
  ///
  /// [maxEntries] 限制扫描条目数，防止超大目录带来额外开销。
  static Future<bool> dirContainsCiphertext(
    String dirPath, {
    required RcloneCryptConfig config,
    int maxEntries = 2000,
  }) async {
    try {
      final dir = Directory(dirPath);
      if (!await dir.exists()) return false;
      var scanned = 0;
      await for (final entity in dir.list(followLinks: false)) {
        if (++scanned > maxEntries) break;
        final name = p.basename(entity.path);
        // 跳过 rclone 配置文件与加解密中途的临时残留
        if (name == 'rclone.conf' || name == '.rclone.conf') continue;
        if (name.endsWith(tmpSuffix)) continue;
        if (!mayBeCipherName(name, config)) continue;
        if (entity is File) {
          if (await isEncryptedFile(entity.path)) return true;
        } else {
          // 目录读不到 magic 头：通过名字级筛查（密文长度必为 16 的倍数）即认定
          return true;
        }
      }
      return false;
    } catch (_) {
      return false;
    }
  }

  /// 目录名 [name] 是否**确实是密文目录名**（能被 [mount] 的密钥解密回另一个名字）。
  ///
  /// 这是「目录实体本身是否被加密」的唯一可靠信号：原地加密目录时
  /// [encryptDirectory] 会把**目录名一并换成密文名**（rclone 语义），
  /// 因此密文目录在磁盘上的名字必定可解密回原名；普通目录名则不可能。
  ///
  /// ⚠️ 唯一例外：目标目录**本身就是加密挂载点根**时，[encryptDirectory] 会
  /// 跳过改名 —— 那种目录名字是明文、子项却是密文，本方法判不出来
  /// （详见 [isDirectoryStillEncrypted] 的「挂载点根容器」分支：由登记表兜底）。
  ///
  /// [RcloneCrypt.decryptDirName] 对随手起的明文名也可能「解码成功」得到垃圾
  /// 名字（长度与 PKCS7 填充恰好过关），所以加**往返校验**：
  /// 密文名必定满足 `encryptDirName(decryptDirName(name)) == name`
  /// （EME 是确定性加密），明文名几乎不可能满足。
  ///
  /// 顺带兼容「目录名也带上加密后缀」的形态（外部工具/其它编码写入的目录名）。
  static bool isCipherDirName(String name, CryptMountPoint mount) {
    if (name.isEmpty || name == '.' || name == '..') return false;
    final stems = <String>[name];
    final suffix = mount.config.encryptedSuffix;
    if (suffix.isNotEmpty &&
        name.length > suffix.length &&
        name.endsWith(suffix)) {
      stems.add(name.substring(0, name.length - suffix.length));
    }
    for (final stem in stems) {
      try {
        final plain = mount.crypt.decryptDirName(stem);
        if (plain.isEmpty || plain == stem) continue;
        if (plain.contains('/') || plain.contains('\u0000')) continue;
        final reEncrypted = mount.crypt.encryptDirName(plain);
        if (reEncrypted == stem || reEncrypted == name) return true;
      } catch (_) {}
    }
    return false;
  }

  /// 文件名 [name] 是否为 [mount] 配置下的密文名（与 [isCipherDirName] 同一套
  /// 往返校验，只是走**文件名**通道：文件名带 `encryptedSuffix`，目录名不带）。
  ///
  /// 用途：把本地文件写进远程加密目录时判断「这份东西是不是已经是密文」——
  /// 名字能往返说明它**就是用当前挂载点这把钥匙加密的**，于是内容可以按原字节
  /// 直传、不再二次加密（否则服务端会存下「密文的密文」，客户端解密后拿到的
  /// 还是密文，用户看到的是乱码文件）。
  ///
  /// `filenameEncryption = off` 时名字不参与加密、名字级信号完全失效 → 返回
  /// false，调用方退回「按内容重新加密」（对任意字节流都是无损的）。
  static bool isCipherFileName(String name, CryptMountPoint mount) {
    if (name.isEmpty || name == '.' || name == '..') return false;
    if (mount.config.filenameEncryption == FilenameEncryption.off) return false;
    final stems = <String>[name];
    final suffix = mount.config.encryptedSuffix;
    if (suffix.isNotEmpty &&
        name.length > suffix.length &&
        name.endsWith(suffix)) {
      stems.add(name.substring(0, name.length - suffix.length));
    }
    for (final stem in stems) {
      try {
        final plain = mount.crypt.decryptFileName(stem);
        if (plain.isEmpty || plain == stem) continue;
        if (plain.contains('/') || plain.contains('\u0000')) continue;
        final reEncrypted = mount.crypt.encryptFileName(plain);
        if (reEncrypted == stem || reEncrypted == name) return true;
      } catch (_) {}
    }
    return false;
  }

  /// [mount] 的配置是否**无法从名字判断目录有没有被加密**。
  ///
  /// - `directoryNameEncryption = false`（目录名不加密）：加密目录在磁盘上
  ///   也叫明文名 → 名字级信号完全失效；
  /// - `filenameEncryption = off`：连文件名都不加密，磁盘上全是明文名 → 同样失效。
  ///
  /// 这两种配置下只能退回「目录内确有密文」的内容判定。代价是「夹带密文的普通
  /// 目录」也会被算作加密目录（配置本身决定了无法区分），但宁可多加密也不漏：
  /// 反过来判定会让用户往**真加密目录**里粘贴时得到未加密的明文文件。
  static bool _nameSignalUnavailable(CryptMountPoint mount) =>
      !mount.config.directoryNameEncryption ||
      mount.config.filenameEncryption == FilenameEncryption.off;

  /// 目录 [dirPath] 是否需要按「加密内容」做加解密传输（**源目录**判定）。
  ///
  /// 与 [isDirectoryStillEncrypted]（目标目录该不该自动加密）语义不同：
  /// 源方向**没有**「把新文件静默加密」的风险，而解密传输本身是**逐条**处理的
  /// （明文条目原样复制，见 `_decryptDirCryptToPlain`），所以只要目录名是密文名
  /// **或**目录里有密文，就应当走 crypt 传输 —— 否则用户从「夹带密文文件的普通
  /// 目录」里复制出来的密文文件会原样落到明文目标；往加密目录里复制时还会因为
  /// 走「整目录加密」分支而把已有密文**二次加密**。
  static Future<bool> dirNeedsCryptTransfer(
    String dirPath, {
    required CryptMountPoint mount,
  }) async {
    try {
      if (!await Directory(dirPath).exists()) return false;
    } catch (_) {
      return false;
    }
    if (isCipherDirName(p.basename(dirPath), mount)) return true;
    try {
      return await dirContainsCiphertext(dirPath, config: mount.config);
    } catch (_) {
      return true;
    }
  }

  /// 目录 [dirPath] 是否**本身就是一个加密目录实体**（判据只取磁盘事实）。
  ///
  /// 与「该目录是否被某个加密挂载点覆盖」**无关**：挂载点会因历史登记
  /// （`CryptMountService` 的挂载点表 / 原地加密目录登记表 / 导入清单）长期
  /// 残留，一路覆盖到**已经解密**的明文目录上，据此判定就会把明文目录当成
  /// 加密目标，静默加密用户新复制进来的文件。
  ///
  /// ⚠️ 同样**不能**用「目录里有密文子项」当作加密证据（早期实现的错误）：
  /// - 用户只把目录里的**某一个文件**原地加密（其余仍是明文）→ 目录没被加密；
  /// - 用户从 OpenList/别处**拷来一个密文文件**放进普通文件夹 → 目录没被加密；
  /// - 「挂载点根」更是**容器**：`encryptInPlace` 把挂载点建在被加密条目的
  ///   父目录上，容器自身的名字始终是明文。
  ///
  /// 上述三种情况旧判据都返回 true → 用户再往里复制/剪切文件时被**静默加密**
  /// （用户反馈：「文件夹没有加密，但文件夹中有一个文件加密，复制/剪切其他文件
  /// 进去，其他文件也被加密了」）。
  ///
  /// 现在只认一个信号：**目录名本身是密文名**（[isCipherDirName]）。
  /// - 原地加密的目录（除挂载点根外）名字必定已是密文 → true；
  /// - 目录整体解密后名字还原为明文、普通目录、夹带零星密文的普通目录 → false。
  /// - 例外：名字不加密的配置（见 [_nameSignalUnavailable]）退回内容判定。
  ///
  /// 注意：加密目录「新文件继续加密」**不依赖本判定**。密文目录的虚拟路径经
  /// [CryptMountPoint.resolvePhysicalPath] 会解析到磁盘上的密文路径
  /// （≠ 虚拟路径），调用方据此走「→ 加密目录」分支。
  ///
  /// ⚠️ **「挂载点根容器」分支**（2026-09-19 方案 B）：「整体原地加密过、但目录名
  /// 保持明文」的文件夹会由 `CryptMountService.addInPlaceContainerDir` 登记 ——
  /// 本判定对**已登记且目录内确有密文**的目录返回 true，让它继续自动加密新粘贴
  /// 进来的文件。
  ///
  /// - 登记表是唯一可信的区分依据：这种目录的磁盘特征（名字明文 + 子项密文）与
  ///   「普通文件夹夹带零星密文」**完全一样**，只看磁盘必然二义；
  /// - 必须**同时**要求目录内确有密文：用户把容器解密/清空后残留的登记不得让明文
  ///   目录重新被判成加密目录（与「解密了就不再自动加密」的规则一致）；
  /// - 子目录不参与该分支（`CryptMountService.isInPlaceContainerDir` 只比对自身）：
  ///   容器内真正的加密子目录在磁盘上名字已是密文名，由 `resolvePhysicalPath`
  ///   解析出「≠ 虚拟路径」的另一条分支负责；容器内**已解密**的子目录必须继续按
  ///   明文处理。
  ///
  /// 成因：`CryptOperations.encryptDirectory` 末尾的守卫 —— 目标目录 == 挂载点
  /// `physicalPath` 时跳过给目录改名（否则挂载点根改名后 `containsPath` 失配 →
  /// 重启后解密层找不到挂载点 → 目录显示密文名甚至空白，历史事故）。而
  /// `VaultCryptService.encryptInPlace` 把挂载点建在被加密条目的**父目录**上，
  /// 所以「先加密过该文件夹里的某个文件/子文件夹」这一步就已经把挂载点登记在该
  /// 文件夹自身上，之后再加密**这个文件夹**即命中守卫。（登记写入就在
  /// [encryptDirectory] 命中守卫的那个 `else` 分支里，注销见 [decryptDirectory]
  /// 末尾 —— 加/解密流程即唯一真相源，不在各调用方重复判断。）
  ///
  /// 回归护栏：`test/crypt/crypt_inplace_roundtrip_test.dart` 的
  /// 「原地加密文件夹：目录名与容器登记」用例组。
  ///
  /// 两处共用本方法，务必保持唯一实现、不要各自复制一份：
  /// - 复制/剪切的目标目录该不该继续加密（`FileManagerProvider._analyzeCryptDestDir`）；
  /// - 保险箱导入清单条目是否已失效（`VaultImportStore.stillEncrypted`）。
  ///（**源**目录走 [dirNeedsCryptTransfer]，语义不同，别混用。）
  static Future<bool> isDirectoryStillEncrypted(
    String dirPath, {
    required CryptMountPoint mount,
  }) async {
    try {
      if (!await Directory(dirPath).exists()) return false;
    } catch (_) {
      return false;
    }
    if (isCipherDirName(p.basename(dirPath), mount)) return true;
    // 「整体原地加密过、但目录名保持明文」的挂载点根容器（方案 B）：
    // 登记表是唯一可信的区分依据，且必须再看一眼目录内是否确有密文 ——
    // 用户解密/清空后残留的登记不得让明文目录重新被判成加密目录。
    if (await CryptMountService.isInPlaceContainerDir(dirPath)) {
      try {
        return await dirContainsCiphertext(dirPath, config: mount.config);
      } catch (_) {
        return true;
      }
    }
    // 名字级信号失效的配置：只能看内容（保守）
    if (!_nameSignalUnavailable(mount)) return false;
    try {
      return await dirContainsCiphertext(dirPath, config: mount.config);
    } catch (_) {
      return true;
    }
  }

  /// 加密单个文件（原地加密）
  ///
  /// 将普通文件加密为 crypt 格式，加密后原文件被替换为加密文件。
  ///
  /// 实现要点（修复「加密到一半卡死」）：
  /// - **流式处理**：按 64KiB 分块读 → 加密 → 写，内存占用恒定，
  ///   不再把整个文件 `readAsBytes()` 读进内存（大文件会 OOM）。
  /// - **原子写入**：先写 `*.zencrypt_tmp`，成功后才删除原文件并改名，
  ///   中途失败/取消时原文件保持完好，不会丢数据。
  /// - 保留原文件修改时间。
  Future<String> encryptFile(String sourcePath,
      {void Function(int bytes, int total)? onFileProgress}) async {
    final sourceFile = File(sourcePath);
    if (!await sourceFile.exists()) {
      throw FileSystemException('File not found', sourcePath);
    }

    // 提前取时间戳（删除后读不到）
    final sourceStat = await sourceFile.stat();

    final dir = p.dirname(sourcePath);
    final fileName = p.basename(sourcePath);
    final encryptedFileName = _mount.crypt.encryptFileName(fileName);
    final encryptedPath = p.join(dir, encryptedFileName);

    final tmpPath = '$encryptedPath$_tmpSuffix';
    final tmpFile = File(tmpPath);

    final int totalBytes = await sourceFile.length();
    var written = 0;

    RandomAccessFile? raf;
    try {
      raf = await tmpFile.open(mode: FileMode.write);
      final encrypter = _mount.crypt.createEncrypter();

      // 流式：分块读取 → 加密 → 写盘
      await for (final chunk in sourceFile.openRead()) {
        final out = encrypter.process(chunk);
        if (out.isNotEmpty) {
          await raf.writeFrom(out);
        }
        written += chunk.length;
        onFileProgress?.call(written, totalBytes);
      }
      final tail = encrypter.finish();
      if (tail.isNotEmpty) {
        await raf.writeFrom(tail);
      }
      await raf.close();
      raf = null;

      await tmpFile.setLastModified(sourceStat.modified);

      // 原子替换：先删原文件，再把临时文件改名为最终名
      await sourceFile.delete();
      await tmpFile.rename(encryptedPath);

      return encryptedPath;
    } catch (e) {
      // 任何失败都清理临时文件，原文件保持不变
      if (raf != null) {
        try {
          await raf.close();
        } catch (_) {}
      }
      if (await tmpFile.exists()) {
        try {
          await tmpFile.delete();
        } catch (_) {}
      }
      rethrow;
    }
  }

  /// 解密单个文件（原地解密）
  ///
  /// 同样采用流式处理 + 原子写入，避免大文件 OOM 与中断丢数据。
  Future<String> decryptFile(String encryptedPath,
      {void Function(int bytes, int total)? onFileProgress}) async {
    final encryptedFile = File(encryptedPath);
    if (!await encryptedFile.exists()) {
      throw FileSystemException('Encrypted file not found', encryptedPath);
    }

    final sourceStat = await encryptedFile.stat();

    final dir = p.dirname(encryptedPath);
    final encryptedFileName = p.basename(encryptedPath);
    final decryptedFileName = _mount.crypt.decryptFileName(encryptedFileName);
    final decryptedPath = p.join(dir, decryptedFileName);

    final tmpPath = '$decryptedPath$_tmpSuffix';
    final tmpFile = File(tmpPath);

    final int totalBytes = await encryptedFile.length();
    var written = 0;

    RandomAccessFile? raf;
    try {
      raf = await tmpFile.open(mode: FileMode.write);
      final decrypter = _mount.crypt.createDecrypter();

      await for (final chunk in encryptedFile.openRead()) {
        final out = decrypter.process(chunk);
        if (out.isNotEmpty) {
          await raf.writeFrom(out);
        }
        written += chunk.length;
        onFileProgress?.call(written, totalBytes);
      }
      final tail = decrypter.finish();
      if (tail.isNotEmpty) {
        await raf.writeFrom(tail);
      }
      await raf.close();
      raf = null;

      await tmpFile.setLastModified(sourceStat.modified);

      await encryptedFile.delete();
      await tmpFile.rename(decryptedPath);

      return decryptedPath;
    } catch (e) {
      if (raf != null) {
        try {
          await raf.close();
        } catch (_) {}
      }
      if (await tmpFile.exists()) {
        try {
          await tmpFile.delete();
        } catch (_) {}
      }
      rethrow;
    }
  }

  /// 加密单个文件到**指定目标路径**（非破坏性，保留源文件）。
  ///
  /// 与 [encryptFile]（原地替换、删源）不同：本方法把 [sourcePath] 加密后写入
  /// [destEncryptedPath]，**不动源文件**。用于「复制明文文件到加密目录」「把加密
  /// 文件解密到另一个明文目录（复制场景，源密文保留）」等需求。
  ///
  /// 沿用流式 + 原子写（先写 `*.zencrypt_tmp`，成功后才改名）机制，
  /// 中途失败只清理临时文件，不破坏 [sourcePath]。
  /// [onFileProgress] 为**字节级**进度回调（已读字节, 源文件总字节），
  /// 供复制/移动时的进度弹窗实时刷新；分母取源文件大小（密文略大于明文，
  /// 差异只有几十字节头，不影响观感）。
  Future<String> encryptFileTo(
    String sourcePath,
    String destEncryptedPath, {
    void Function(int bytes, int total)? onFileProgress,
  }) async {
    final sourceFile = File(sourcePath);
    if (!await sourceFile.exists()) {
      throw FileSystemException('File not found', sourcePath);
    }
    final sourceStat = await sourceFile.stat();

    // 确保目标父目录存在（例如把加密文件落到之前不存在的目录）
    final destParent = Directory(p.dirname(destEncryptedPath));
    if (!await destParent.exists()) {
      await destParent.create(recursive: true);
    }

    final int totalBytes = await sourceFile.length();
    var written = 0;

    final tmpPath = '$destEncryptedPath$_tmpSuffix';
    final tmpFile = File(tmpPath);
    RandomAccessFile? raf;
    try {
      raf = await tmpFile.open(mode: FileMode.write);
      final encrypter = _mount.crypt.createEncrypter();
      await for (final chunk in sourceFile.openRead()) {
        final out = encrypter.process(chunk);
        if (out.isNotEmpty) await raf.writeFrom(out);
        written += chunk.length;
        onFileProgress?.call(written, totalBytes);
      }
      final tail = encrypter.finish();
      if (tail.isNotEmpty) await raf.writeFrom(tail);
      await raf.close();
      raf = null;

      await tmpFile.setLastModified(sourceStat.modified);

      // 目标已存在则先删再替换（覆盖写入）
      if (await File(destEncryptedPath).exists()) {
        await File(destEncryptedPath).delete();
      }
      await tmpFile.rename(destEncryptedPath);
      return destEncryptedPath;
    } catch (e) {
      if (raf != null) {
        try {
          await raf.close();
        } catch (_) {}
      }
      if (await tmpFile.exists()) {
        try {
          await tmpFile.delete();
        } catch (_) {}
      }
      rethrow;
    }
  }

  /// 解密单个加密文件到**指定明文目标路径**（非破坏性，保留源密文）。
  ///
  /// 与 [decryptFile]（原地替换、删密文）不同：本方法把 [encryptedPath] 解密后
  /// 写入 [destPlainPath]，**不动源密文**。用于「复制密文文件到明文目录」等
  /// 非破坏性场景。同样采用流式 + 原子写。
  /// [onFileProgress] 为字节级进度回调（已读字节, 源密文总字节），与
  /// [encryptFileTo] 对称，用于复制/移动时的实时进度显示。
  Future<String> decryptFileTo(
    String encryptedPath,
    String destPlainPath, {
    void Function(int bytes, int total)? onFileProgress,
  }) async {
    final encryptedFile = File(encryptedPath);
    if (!await encryptedFile.exists()) {
      throw FileSystemException('Encrypted file not found', encryptedPath);
    }
    final sourceStat = await encryptedFile.stat();

    final destParent = Directory(p.dirname(destPlainPath));
    if (!await destParent.exists()) {
      await destParent.create(recursive: true);
    }

    final int totalBytes = await encryptedFile.length();
    var written = 0;

    final tmpPath = '$destPlainPath$_tmpSuffix';
    final tmpFile = File(tmpPath);
    RandomAccessFile? raf;
    try {
      raf = await tmpFile.open(mode: FileMode.write);
      final decrypter = _mount.crypt.createDecrypter();
      await for (final chunk in encryptedFile.openRead()) {
        final out = decrypter.process(chunk);
        if (out.isNotEmpty) await raf.writeFrom(out);
        written += chunk.length;
        onFileProgress?.call(written, totalBytes);
      }
      final tail = decrypter.finish();
      if (tail.isNotEmpty) await raf.writeFrom(tail);
      await raf.close();
      raf = null;

      await tmpFile.setLastModified(sourceStat.modified);

      if (await File(destPlainPath).exists()) {
        await File(destPlainPath).delete();
      }
      await tmpFile.rename(destPlainPath);
      return destPlainPath;
    } catch (e) {
      if (raf != null) {
        try {
          await raf.close();
        } catch (_) {}
      }
      if (await tmpFile.exists()) {
        try {
          await tmpFile.delete();
        } catch (_) {}
      }
      rethrow;
    }
  }

  /// 原子写入时使用的临时文件后缀。
  ///
  /// 公开常量：浏览层做「目录内是否含密文」探测时也要跳过这些残留临时文件，
  /// 否则失败残留会被误判成密文条目。
  static const String tmpSuffix = '.zencrypt_tmp';

  /// 兼容旧引用（内部使用）
  static const String _tmpSuffix = tmpSuffix;

  /// 加密文件夹（递归加密所有文件和子文件夹）
  ///
  /// [sourceDirPath] 源文件夹路径
  /// [onProgress] 进度回调（已处理文件数，总文件数）
  /// [skipEncrypted] 为 true 时跳过「已经是 rclone/OpenList 加密」的文件
  ///   （文件头带 RCLONE magic）和已加密的目录名，避免对导入文件夹里
  ///   混有的已加密文件做二次加密（二次加密会破坏文件）。用于保险箱「导入并
  ///   原地加密」一个含加密+普通文件混合的文件夹。
  Future<void> encryptDirectory(
    String sourceDirPath, {
    void Function(int processed, int total)? onProgress,
    void Function(int bytes, int total)? onFileProgress,
    bool skipEncrypted = false,
    bool renameTopDir = true,
  }) async {
    // 先统计文件总数
    final allFiles = await _listAllFiles(sourceDirPath);
    final total = allFiles.length;
    var processed = 0;
    void bump() {
      processed++;
      onProgress?.call(processed, total);
    }

    // ── 阶段 ①：算出全部加密作业（**保留原始目录路径**）──
    //
    // 加密一个文件只会改它自己的名字，不会动任何其它路径，所以「先把整棵树
    // 的文件都加密完」是安全的；目录改名统一推迟到阶段 ③，顺序等价于原来的
    // 深度优先后序（见 [_collectSubDirsPostOrder]）。
    final jobs = <CryptBatchJob>[];
    for (final file in allFiles) {
      if (skipEncrypted && await _isEncryptedFile(file)) {
        // 已加密文件：跳过，但仍计入进度，避免进度卡在中途
        bump();
        continue;
      }
      final stat = await File(file).stat();
      final encryptedPath = p.join(
        p.dirname(file),
        _mount.crypt.encryptFileName(p.basename(file)),
      );
      jobs.add(
        CryptBatchJob(
          srcPath: file,
          targetPath: encryptedPath,
          tmpPath: '$encryptedPath$tmpSuffix',
          readBytes: stat.size,
          modifiedMs: stat.modified.millisecondsSinceEpoch,
        ),
      );
    }

    // ── 阶段 ②：并行加密文件（多 isolate；见 CryptBatchRunner 的文件头）──
    //
    // 数据面是纯 Dart 的 XSalsa20-Poly1305（实测 8.6 MiB/s），单线程是硬天花板，
    // 唯一有效的手段是多核并行。
    await CryptBatchRunner.run(
      dataKey: _mount.crypt.derivedKeys.dataKey,
      jobs: jobs,
      encrypting: true,
      onBytes: onFileProgress,
      onJobDone: bump,
    );

    // ── 阶段 ③：目录改名，**最深优先**（后序）──
    final subDirs = <Directory>[];
    await _collectSubDirsPostOrder(Directory(sourceDirPath), subDirs);
    for (final dir in subDirs) {
      final parentDir = p.dirname(dir.path);
      final dirName = p.basename(dir.path);
      var alreadyEncryptedDir = false;
      if (skipEncrypted) {
        try {
          _mount.crypt.decryptDirName(dirName);
          alreadyEncryptedDir = true;
        } catch (_) {}
      }
      if (alreadyEncryptedDir) continue;
      final encryptedDirPath = p.join(
        parentDir,
        _mount.crypt.encryptDirName(dirName),
      );
      await dir.rename(encryptedDirPath);
    }

    // [renameTopDir] == false：调用方只借本方法做「文件/子目录就地加密」，
    // 顶层目录名必须原样保留 —— 密文目录改名会与已有密文目录撞名、让挂载点
    // `containsPath` 失配；明文目录改名则会让随后的搬运失去源路径。
    // 见 [mergeNewFilesIntoEncryptedDir]。
    if (!renameTopDir) return;

    // 最后加密文件夹名称本身（如果不是挂载点根目录）
    if (!p.equals(sourceDirPath, _mount.physicalPath)) {
      final dir = p.dirname(sourceDirPath);
      final dirName = p.basename(sourceDirPath);
      // 已加密的目录名不再重复加密
      var alreadyEncryptedDir = false;
      if (skipEncrypted) {
        try {
          _mount.crypt.decryptDirName(dirName);
          alreadyEncryptedDir = true;
        } catch (_) {}
      }
      if (!alreadyEncryptedDir) {
        final encryptedDirName = _mount.crypt.encryptDirName(dirName);
        final encryptedDirPath = p.join(dir, encryptedDirName);
        await Directory(sourceDirPath).rename(encryptedDirPath);
      }
    } else {
      // 目标目录**恰好就是挂载点根**：目录名不加密（改名会让挂载点
      // `containsPath` 失配 → 重启后解密层找不到挂载点）→ 磁盘上只剩
      // 「名字明文 + 子项密文」。这种形态与「普通文件夹里夹带零星密文」
      // **磁盘特征完全一样**，只能靠登记表区分；不登记的话，之后往这个
      // 文件夹里复制/剪切的新文件不会被自动加密
      // （见 [isDirectoryStillEncrypted] 的「挂载点根容器」分支）。
      // 解密时由 [decryptDirectory] 注销。
      await CryptMountService.addInPlaceContainerDir(sourceDirPath);
    }
  }

  /// 增量加密：把「同名明文目录」里的新增条目**合并进已有密文目录**（不改目录名）。
  ///
  /// 场景（用户报障）：原地加密 `/DCIM/Camera` 会把目录名换成密文名 ⇒ 相机下次
  /// 拍照时 `/DCIM/Camera` 已不存在 ⇒ 系统**新建同名明文目录**继续写 ⇒ 新照片
  /// 永远是明文。而「再执行一次原地加密」修不好：EME 是确定性加密 ⇒
  /// `encryptDirName('Camera')` 恒定 ⇒ rename 的目标就是那个已存在的密文目录，
  /// 而 [encryptDirectory] 阶段④**没有同名检查** ⇒ 直接抛异常。
  ///
  /// 所以这里只做「并入」，一步都不改目录名：
  /// ① 密文目录**内部**混进的明文文件（复制/工具写入绕过了自动加密）→ 就地加密；
  /// ② 父目录下的**同名明文目录**（名字 = `decryptDirName(密文目录名)`）→ 整棵树
  ///    就地加密（[encryptDirectory] 传 `renameTopDir: false`）→ 顶层子项逐个搬进
  ///    密文目录（同一文件系统内 rename，几乎零成本）；
  /// ③ 只有明文目录确实空了才删除它（非空 = 有失败或被占用，保留现场排查）。
  ///
  /// 同名冲突按**明文名**加 `_1/_2…` 后缀后重新加密（见 [_uniqueCipherNameFor]）——
  /// 直接给密文名加后缀会让解密层认不出这个条目。
  ///
  /// 返回搬进来的顶层条目数（0 = 没有新增内容）。
  /// 调用方负责用正确密钥解析出挂载点（见 `vault_explorer_screen._resolveCryptMountForPath`）。
  Future<int> mergeNewFilesIntoEncryptedDir(
    String cipherDirPath, {
    void Function(int processed, int total)? onProgress,
    void Function(int bytes, int total)? onFileProgress,
  }) async {
    final cipherDir = Directory(cipherDirPath);
    if (!await cipherDir.exists()) {
      throw FileSystemException('Directory not found', cipherDirPath);
    }

    // ① 密文目录内部：把漏掉的明文文件就地加密（已加密的由 skipEncrypted 跳过）
    await encryptDirectory(
      cipherDirPath,
      skipEncrypted: true,
      renameTopDir: false, // 密文目录名绝不能动
      onProgress: onProgress,
      onFileProgress: onFileProgress,
    );

    // ② 同名明文目录。先用「往返校验」确认这个目录名确实是密文名——
    // `decryptDirName` 对随手起的明文名也可能解码出垃圾，不能只看它抛不抛。
    final cipherName = p.basename(cipherDirPath);
    if (!isCipherDirName(cipherName, _mount)) return 0;
    final String plainName;
    try {
      plainName = _mount.crypt.decryptDirName(cipherName);
    } catch (_) {
      return 0;
    }
    if (plainName.isEmpty || plainName == cipherName) return 0;
    final plainDirPath = p.join(p.dirname(cipherDirPath), plainName);
    if (p.equals(plainDirPath, cipherDirPath)) return 0;
    final plainDir = Directory(plainDirPath);
    if (!await plainDir.exists()) return 0;

    // ②a 明文目录整棵树就地加密，但顶层目录名不动
    await encryptDirectory(
      plainDirPath,
      skipEncrypted: true,
      renameTopDir: false,
      onProgress: onProgress,
      onFileProgress: onFileProgress,
    );

    // ②b 顶层子项逐个搬进密文目录
    var merged = 0;
    final children = <String>[];
    await for (final entity in plainDir.list()) {
      children.add(p.basename(entity.path));
    }
    for (final childName in children) {
      final srcPath = p.join(plainDirPath, childName);
      final isDir =
          FileSystemEntity.typeSync(srcPath) == FileSystemEntityType.directory;
      final destName = await _uniqueCipherNameFor(
        targetDir: cipherDirPath,
        cipherChildName: childName,
        isDirectory: isDir,
      );
      final destPath = p.join(cipherDirPath, destName);
      if (isDir) {
        await Directory(srcPath).rename(destPath);
      } else {
        await File(srcPath).rename(destPath);
      }
      merged++;
    }

    // ③ 只在确实空了时删除：非空说明有失败或被占用，保留现场供排查
    try {
      if (await plainDir.list().isEmpty) {
        await plainDir.delete();
      }
    } catch (_) {
      // 删不掉不算失败：残留的空目录不是密文条目，解密层不会把它列出来
    }
    return merged;
  }

  /// 给要搬进 [targetDir] 的密文子项求一个不冲突的名字。
  ///
  /// ⚠️ 冲突时必须回到**明文名**上加后缀再重新加密：磁盘上存的是密文名，直接给
  /// 密文名加 `_1` 会让 `decryptFileName` 认不出这个条目 —— 密文名必须满足
  /// `encrypt(decrypt(name)) == name`。扩展名保留在末尾
  ///（`IMG_0001.jpg` → `IMG_0001_1.jpg`）。
  Future<String> _uniqueCipherNameFor({
    required String targetDir,
    required String cipherChildName,
    required bool isDirectory,
  }) async {
    if (FileSystemEntity.typeSync(p.join(targetDir, cipherChildName)) ==
        FileSystemEntityType.notFound) {
      return cipherChildName;
    }
    final crypt = _mount.crypt;
    String plain;
    try {
      plain = isDirectory
          ? crypt.decryptDirName(cipherChildName)
          : crypt.decryptFileName(cipherChildName);
    } catch (_) {
      plain = cipherChildName; // 名字不可解（配置不加密名字）→ 用原名加后缀
    }
    final ext = p.extension(plain);
    final stem =
        ext.isEmpty ? plain : plain.substring(0, plain.length - ext.length);
    for (var i = 1; i < 1000; i++) {
      final candidate = '${stem}_$i$ext';
      final cipherCandidate = isDirectory
          ? crypt.encryptDirName(candidate)
          : crypt.encryptFileName(candidate);
      if (FileSystemEntity.typeSync(p.join(targetDir, cipherCandidate)) ==
          FileSystemEntityType.notFound) {
        return cipherCandidate;
      }
    }
    throw FileSystemException('无法为新条目找到可用名字', cipherChildName);
  }
  /// 收集 [dir] 下的**全部子目录**，按「后序」排列 = 最深的最先。
  ///
  /// 加/解密都必须**先改深层目录名、再改浅层**：改名一个子目录不会影响它
  /// 父目录的路径，反过来就会让已收集的深层路径全部失效。改造前的递归实现
  /// 天然满足这一点，改成「两阶段并行 + 集中改名」后必须显式保证同一个顺序。
  /// 实现见 [CryptTreeWalker.listSubDirsDeepestFirst]。
  ///
  /// 注意**不包含** [dir] 自身 —— 顶层目录名由调用方单独处理
  ///（挂载点根目录有特殊语义，不能改名）。
  Future<void> _collectSubDirsPostOrder(
    Directory dir,
    List<Directory> out,
  ) async {
    final paths = await CryptTreeWalker.listSubDirsDeepestFirst(dir.path);
    for (final path in paths) {
      out.add(Directory(path));
    }
  }

  /// 判断物理文件是否已为 rclone/OpenList 加密（文件头带 RCLONE magic）
  Future<bool> _isEncryptedFile(String path) async {
    try {
      final file = File(path);
      if (!await file.exists()) return false;
      final raf = await file.open(mode: FileMode.read);
      try {
        final head = await raf.read(fileMagicSize);
        if (head.length < fileMagicSize) return false;
        for (var i = 0; i < fileMagicSize; i++) {
          if (head[i] != fileHeaderMagicBytes[i]) return false;
        }
        return true;
      } finally {
        await raf.close();
      }
    } catch (_) {
      return false;
    }
  }

  /// 解密文件夹（递归解密所有文件和子文件夹）
  Future<void> decryptDirectory(
    String encryptedDirPath, {
    void Function(int processed, int total)? onProgress,
    void Function(int bytes, int total)? onFileProgress,
  }) async {
    // 先统计文件总数
    final allFiles = await _listAllFiles(encryptedDirPath);
    final total = allFiles.length;
    var processed = 0;
    void bump() {
      processed++;
      onProgress?.call(processed, total);
    }

    // ── 阶段 ①：算出全部解密作业 ──
    //
    // 作业用的是**当前（仍是密文名的）目录路径**；阶段 ② 不会改任何目录名，
    // 所以这些路径在并行解密期间始终有效。目录改名推迟到阶段 ③。
    //
    // ⚠️ 明文文件必须跳过：CryptBatchRunner 对单作业失败是 fail 整批语义，
    // 混合目录（部分已解密/孤儿重修）里只要有一个明文文件，整批就失败，
    // 阶段 ③ 的目录改名永远走不到 ⇒ 冲突永远无法收敛（2026-10-03 实测）。
    final jobs = <CryptBatchJob>[];
    for (final file in allFiles) {
      if (!await isEncryptedFile(file)) continue;
      final stat = await File(file).stat();
      final decryptedPath = p.join(
        p.dirname(file),
        _mount.crypt.decryptFileName(p.basename(file)),
      );
      jobs.add(
        CryptBatchJob(
          srcPath: file,
          targetPath: decryptedPath,
          tmpPath: '$decryptedPath$tmpSuffix',
          readBytes: stat.size,
          modifiedMs: stat.modified.millisecondsSinceEpoch,
        ),
      );
    }

    // ── 阶段 ②：并行解密文件 ──
    await CryptBatchRunner.run(
      dataKey: _mount.crypt.derivedKeys.dataKey,
      jobs: jobs,
      encrypting: false,
      onBytes: onFileProgress,
      onJobDone: bump,
    );

    // ── 阶段 ③：目录改名，**最深优先**（后序）──
    final subDirs = <Directory>[];
    await _collectSubDirsPostOrder(Directory(encryptedDirPath), subDirs);
    for (final dir in subDirs) {
      final parentDir = p.dirname(dir.path);
      final encryptedDirName = p.basename(dir.path);
      try {
        final decryptedDirName = _mount.crypt.decryptDirName(encryptedDirName);
        await dir.rename(p.join(parentDir, decryptedDirName));
      } catch (_) {
        // 解密失败，保留原名
      }
    }

    // 最后解密文件夹名称本身
    if (!p.equals(encryptedDirPath, _mount.physicalPath)) {
      final dir = p.dirname(encryptedDirPath);
      final encryptedDirName = p.basename(encryptedDirPath);
      final decryptedDirName = _mount.crypt.decryptDirName(encryptedDirName);
      final decryptedDirPath = p.join(dir, decryptedDirName);
      final target = Directory(decryptedDirPath);
      if (await target.exists()) {
        // plainNameClash（2026-10-03 用户实测）：同名明文目录已存在且非空
        // ⇒ rename 报 errno 39 ⇒ 半完成态（文件已解密、目录名未还原），
        // 随后注销登记产生「无登记密文名孤儿」⇒ 自动加密/解密/监听全部
        // 失明，重试解密永远 errno 39。⇒ 目标已存在时改为「内容逐项并入
        // + 删除空壳」，等效完成目录名解密，冲突收敛。
        await _mergeDecryptedDirInto(Directory(encryptedDirPath), target);
      } else {
        await Directory(encryptedDirPath).rename(decryptedDirPath);
      }
    }

    // 该目录已整体解密：注销「挂载点根容器」登记（连带其子目录记录），
    // 否则之后往这个已解密的文件夹里粘贴仍会被自动加密。
    // ⚠️ 放在这里（而不是各调用方）是为了让加/解密流程成为唯一真相源：
    // 保险箱页、pane、媒体页、VFS 都会调本方法，判断散到调用方必然漏。
    await CryptMountService.removeInPlaceContainerDir(encryptedDirPath);
  }

  /// 把 [src]（内容已解密为明文）的全部内容逐项并入 [dst]，最后删除已空的
  /// [src]。仅用于目录名解密时目标明文目录已存在的 plainNameClash 场景。
  /// 同分区 rename 零拷贝；dst 同名文件保留、src 侧生成唯一名（不覆盖用户
  /// 已有文件）；src 删除失败（有未收敛残留）时抛出，由上层报错、下次
  /// 重试解密继续走本方法收敛。
  Future<void> _mergeDecryptedDirInto(Directory src, Directory dst) async {
    await for (final e in src.list(followLinks: false)) {
      final name = p.basename(e.path);
      var target = p.join(dst.path, name);
      if (e is Directory) {
        final t = Directory(target);
        if (await t.exists()) {
          // 同名子目录：递归并入（不必同名密文——本方法处理的是明文内容）
          await _mergeDecryptedDirInto(e, t);
          continue;
        }
        await e.rename(target);
      } else if (e is File) {
        if (await File(target).exists()) {
          final ext = p.extension(name);
          final base = p.basenameWithoutExtension(name);
          var i = 1;
          do {
            target = p.join(dst.path, '$base ($i)$ext');
            i++;
          } while (await File(target).exists());
        }
        await e.rename(target);
      } else {
        // 符号链接等非常规条目：留在 src，由末尾 delete 失败暴露
        continue;
      }
    }
    // 非 recursive：只有 src 已空才成功——有残留说明没并入干净，必须抛
    await src.delete();
  }

  /// 列出目录下所有文件（递归）。实现在纯 Dart 的 [CryptTreeWalker]。
  Future<List<String>> _listAllFiles(String dirPath) =>
      CryptTreeWalker.listFilesRecursive(dirPath);
}
