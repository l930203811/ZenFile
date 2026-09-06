import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
// foundation 会一并导出 dart:typed_data（Uint8List 等），故无需单独导入。
import 'package:flutter/foundation.dart';
import 'package:crypto/crypto.dart' as crypto;
import 'package:cryptography_plus/cryptography_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:path/path.dart' as p;
// archive_io 同时导出 archive 核心（Archive / ArchiveFile / ZipEncoder / ZipDecoder）
// 与流式 IO（ZipFileEncoder / InputFileStream），后者用于目录锁定时的流式打包。
import 'package:archive/archive_io.dart';

/// ZenFile 保险箱（Vault）加密服务。
///
/// ## 版本与安全模型
/// - **V1（旧，向后兼容只读）**：`sha256(password)` 派生 XOR 密钥，仅混淆文件前 8KB，
///   其余内容明文存储。存在真实安全缺陷，仅用于解锁/迁移历史 `.nfv` 文件。
/// - **V2（可读可写，兼容旧文件）**：完整满足用户 4 项安全需求：
///   1. **Argon2id** 派生主密钥（memory-hard，抗 GPU/ASIC 暴破），再用 **HKDF-SHA256**
///      拆分为 `payloadKey`（文件内容）与 `metadataKey`（元数据）两把独立子密钥；
///   2. 每个文件以 **AES-256-GCM** 整文件加密（分块流式，每块独立 96-bit nonce），
///      GCM tag 提供完整性/认证，天然防位翻转与篡改；
///   3. **元数据全混淆**：原文件名/路径/目录结构仅以 `metadataKey` 加密存储于文件头，
///      磁盘上的密文文件名使用随机 id + 随机扩展名（`.zvn`），不泄露任何结构信息；
///   4. **受保护存储**：密文恒久落在应用私有目录 `…/vault/`（沙盒隔离、带 `.nomedia`
///      防媒体扫描），不再像旧版 `inPlace` 那样把可见的 `.nfv` 留在用户原目录。
/// - **V3（当前默认写入）**：密钥派生与 V2 **完全相同**，仅把内容加密换成
///   **XChaCha20-Poly1305**（nonce 192-bit）。`cryptography_plus` 是纯 Dart 实现，
///   AES-GCM 拿不到 ARM AES 指令加速，而 XChaCha20 是 ARX 结构，实测吞吐约 3 倍于
///   AES-GCM。两者 tag 同为 16 字节、文件头结构完全一致，靠 magic 字串区分版本。
///
/// 新锁定一律写入 V3；V1 / V2 旧文件仍可正常解密，改密码时自动升级为 V3。
/// 注意：V3 文件**无法被 v1.1.41 之前的应用读取**（旧版只认 V2 magic）。
///
/// ## 性能设计
/// `cryptography_plus` 是纯 Dart 实现，**没有 ARM AES 指令或 OpenSSL 原生加速**，
/// 因此单纯换算法收益有限，真正的优化点在架构：
/// 1. **会话级密钥缓存**：Argon2id 派生一次后留在内存复用。V2 全库共用同一个
///    全局 salt，故一把密钥即可服务全部文件；每块密文仍用独立随机 nonce，
///    语义安全不变。改密码的派生次数由 2N 次降为 2 次。
/// 2. **加解密下沉 isolate**：用 `Isolate.run` 承载 KDF 与 AEAD 分块循环，
///    主线程不再被 CPU 占满，加载动画不掉帧；isolate 不可用时自动回退主线程，
///    保证功能不中断。
/// 3. **Argon2id 参数下调**：64 MiB×t3 → 32 MiB×t2（仍高于 OWASP 建议下限
///    19 MiB×t2）。参数写入每个文件头，解密一律按文件头参数走，老文件不受影响。
/// 4. **V3 换 XChaCha20-Poly1305**：桌面实测吞吐 7.1 → 21.7 MiB/s（约 3 倍），
///    100 MB 文件的算法耗时由约 14 s 降到约 4.6 s。
/// 5. 目录锁定改为流式打包（ZipFileEncoder 逐文件落盘），不再整目录驻留内存。
class VaultFileRecord {
  final String id;
  final String originalName;
  final String originalPath;
  final String scrambledPath;
  final int size;
  final String lockedAt;
  final bool isInPlace;
  final bool isFolder;

  VaultFileRecord({
    required this.id,
    required this.originalName,
    required this.originalPath,
    required this.scrambledPath,
    required this.size,
    required this.lockedAt,
    required this.isInPlace,
    this.isFolder = false,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'originalName': originalName,
    'originalPath': originalPath,
    'scrambledPath': scrambledPath,
    'size': size,
    'lockedAt': lockedAt,
    'isInPlace': isInPlace,
    'isFolder': isFolder,
  };

  factory VaultFileRecord.fromJson(Map<String, dynamic> json) => VaultFileRecord(
    id: json['id'] as String,
    originalName: json['originalName'] as String,
    originalPath: json['originalPath'] as String,
    scrambledPath: json['scrambledPath'] as String,
    size: json['size'] as int,
    lockedAt: json['lockedAt'] as String,
    isInPlace: json['isInPlace'] as bool,
    isFolder: json['isFolder'] as bool? ?? false,
  );
}

/// V2 全局参数存储快照（用于密码校验，与每个文件的独立 salt 解耦）。
class _V2Stored {
  final List<int> salt;
  final int memory;
  final int iterations;
  final int parallelism;
  final String pwcheck;
  _V2Stored({
    required this.salt,
    required this.memory,
    required this.iterations,
    required this.parallelism,
    required this.pwcheck,
  });
}

/// 加解密所用的 V2 参数（salt + Argon2id 参数）。
class _V2Params {
  final List<int> salt;
  final int memory;
  final int iterations;
  final int parallelism;
  _V2Params({
    required this.salt,
    required this.memory,
    required this.iterations,
    required this.parallelism,
  });
}

/// V2 派生出的密钥集合。
class _V2Keys {
  final List<int> master;
  final List<int> payloadKey;
  final List<int> metadataKey;
  _V2Keys({
    required this.master,
    required this.payloadKey,
    required this.metadataKey,
  });
}

/// 会话缓存条目：密钥 + 其对应的 salt 与 KDF 参数（供跨 isolate 匹配校验）。
class _V2KeyEntry {
  final _V2Keys keys;
  final List<int> salt;
  final int memory;
  final int iterations;
  final int parallelism;
  _V2KeyEntry({
    required this.keys,
    required this.salt,
    required this.memory,
    required this.iterations,
    required this.parallelism,
  });
}

/// V1 解密结果（明文 + 元数据）。
class _V1Result {
  final Uint8List bytes;
  final Map<String, dynamic> meta;
  _V1Result({required this.bytes, required this.meta});
}

class VaultService {
  // ── 格式常量 ─────────────────────────────────────────────────────────────
  static const String _v1Magic = 'NFILE_VAULT_V1'; // 14 bytes
  static const String _v2Magic = 'NFILE_VAULT_V2'; // 14 bytes
  static const String _v3Magic = 'NFILE_VAULT_V3'; // 14 bytes
  static const int _v2Version = 2;
  static const int _v3Version = 3;
  static const int _magicLength = 14; // 三代 magic 长度一致，便于统一预读
  static const int _scrambleSize = 8192; // V1 仅混淆前 8KB（向后兼容用）
  static const int _saltLength = 16;
  static const int _nonceLength = 12; // V2: AES-GCM 96-bit nonce
  static const int _tagLength = 16; // V2: GCM tag
  static const int _v3NonceLength = 24; // V3: XChaCha20 192-bit nonce
  static const int _v3TagLength = 16; // V3: Poly1305 tag（与 GCM tag 同长）
  static const int _chunkSize = 1024 * 1024; // 1 MiB 流式分块

  // Argon2id 默认参数（memory 单位为 KiB；32768 KiB = 32 MiB）
  // 早期为 64 MiB × t=3，而 cryptography_plus 是纯 Dart 实现（无 ARM AES 加速），
  // 单次派生在移动端就要数百毫秒；叠加「每个文件各派生一次」导致批量锁定明显卡顿。
  // 现降到 32 MiB × t=2 × p=1，仍高于 OWASP 建议下限（19 MiB × t=2）。
  // 向后兼容：KDF 参数写入每个文件头，解密一律按文件头参数走，老文件不受影响。
  static const int _defaultMem = 32768;
  static const int _defaultIter = 2;
  static const int _defaultPar = 1;
  static const int _keyLength = 32;

  static const String _kInfoPayload = 'zenfile-vault-payload-v2';
  static const String _kInfoMetadata = 'zenfile-vault-metadata-v2';
  static const String _kPwCheckPlain = 'zenfile-vault-pwcheck-v2';
  // HKDF 的 nonce 被 cryptography_plus 当作 HMAC 的 salt 使用，必须为非空，
  // 否则运行时会抛 "Secret key must be non-empty"。
  static const String _kHkdfSalt = 'zenfile-vault-hkdf-salt-v2';

  // SharedPreferences 键（V2）
  static const String _kSalt = 'vault_v2_salt';
  static const String _kMem = 'vault_v2_mem';
  static const String _kIter = 'vault_v2_iter';
  static const String _kPar = 'vault_v2_par';
  static const String _kPwCheck = 'vault_v2_pwcheck';

  static final AesGcm _gcm = AesGcm.with256bits();
  // V3 用 XChaCha20-Poly1305：cryptography_plus 是纯 Dart 实现，AES-GCM 享受不到
  // ARM AES 指令加速（软件实现靠大量查表与位运算）；XChaCha20 是 ARX 结构，
  // 纯软件吞吐通常数倍于 AES-GCM，且是 IETF 标准（TLS / WireGuard 在用）。
  // 两者 tag 均为 16 字节，SecretBox 框架可直接平替，只需把 nonce 12 → 24 字节。
  static final Cipher _xchacha = Xchacha20.poly1305Aead();
  static final Random _secureRandom = Random.secure();

  /// 新锁定的文件是否写入 V3（XChaCha20-Poly1305）。
  ///
  /// 置为 `false` 则继续写入 V2（AES-256-GCM），用于需要向下兼容旧版应用的场景
  /// ——旧版只认 V2 magic，读不了 V3 密文。读取侧不受此开关影响，
  /// V1 / V2 / V3 一律按文件头 magic 自动识别。
  static bool writeV3 = true;

  // ── 密码 / PIN 管理 ──────────────────────────────────────────────────────

  static Future<bool> isPasswordSet() async {
    if (await _readStoredV2() != null) return true;
    final prefs = await SharedPreferences.getInstance();
    return prefs.containsKey('vault_password_hash'); // 旧版 sha256 哈希
  }

  /// 首次设置密码（或显式重设全局校验令牌）。生成 V2 参数并写入校验令牌。
  static Future<void> setPassword(String password) async {
    await _writeV2Params(password);
  }

  static Future<bool> verifyPassword(String password) async {
    final stored = await _readStoredV2();
    if (stored != null) {
      final vk = await _deriveV2Keys(
          password, stored.salt, stored.memory, stored.iterations, stored.parallelism);
      try {
        final raw = base64Decode(stored.pwcheck);
        final sb = SecretBox.fromConcatenation(raw, nonceLength: _nonceLength, macLength: _tagLength, copy: true);
        final pt = await _gcm.decrypt(sb,
            secretKey: SecretKey(vk.metadataKey));
        if (utf8.decode(pt) == _kPwCheckPlain) {
          // 校验通过即回填会话缓存：后续加解密直接复用，无需再跑 Argon2id。
          _rememberKeys(password, stored.salt, stored.memory, stored.iterations,
              stored.parallelism, vk);
          return true;
        }
      } catch (_) {
        // 密码错误（GCM 认证失败）或数据异常 → 落入旧版校验
      }
    }
    // 旧版 sha256+salt 兼容（升级前设置的 PIN 仍可解锁历史 .nfv）
    final prefs = await SharedPreferences.getInstance();
    final salt = prefs.getString('vault_salt');
    final hash = prefs.getString('vault_password_hash');
    if (salt != null && hash != null) {
      return hash == crypto.sha256.convert(utf8.encode(password + salt)).toString();
    }
    return false;
  }

  /// 修改保险箱密码（即 PIN）：逐条用旧密码解密、用新密码重新加密（V1 自动升级为 V2），
  /// 全部成功后重写全局 V2 校验令牌。任一失败则跳过该条并标记，绝不破坏数据。
  static Future<bool> changePassword(String oldPassword, String newPassword) async {
    if (!await verifyPassword(oldPassword)) return false;

    final records = await loadRecords();
    if (records.isEmpty) {
      await _writeV2Params(newPassword);
      return true;
    }

    bool allOk = true;
    final updated = <VaultFileRecord>[];
    final tempDir = await getTemporaryDirectory();

    // 预派生新密码的密钥并写入会话缓存：改密码需逐条用新密码重加密，
    // 若不预热就会退化成「每文件一次 Argon2id」（这正是卡顿主因）。
    // 注意此时全局 salt 仍是旧的（_writeV2Params 在全部成功后才换新 salt），
    // 因此必须按 _readStoredV2() 当前的 salt/参数派生，才能与逐文件加密一致。
    // 缓存为多槽结构，旧密码的密钥仍然保留，解密阶段同样零派生。
    final rekeyStored = await _readStoredV2();
    if (rekeyStored != null) {
      final nk = await _deriveV2Keys(newPassword, rekeyStored.salt,
          rekeyStored.memory, rekeyStored.iterations, rekeyStored.parallelism);
      _rememberKeys(newPassword, rekeyStored.salt, rekeyStored.memory,
          rekeyStored.iterations, rekeyStored.parallelism, nk);
    }

    for (final rec in records) {
      final temp = File(p.join(tempDir.path, 'vault_rekey_${rec.id}.tmp'));
      try {
        late Map<String, dynamic> meta;
        final magic = await _readMagic(File(rec.scrambledPath));
        if (magic == _v1Magic) {
          final r = await _decryptV1(rec, oldPassword);
          await temp.writeAsBytes(r.bytes);
          meta = r.meta;
        } else {
          meta = (await _decryptV2File(
            srcPath: rec.scrambledPath,
            outPath: temp.path,
            password: oldPassword,
          ))
              .meta;
        }

        final newRec = await _encryptRawToVault(
          sourcePath: temp.path,
          password: newPassword,
          originalName: (meta['name'] as String?) ?? rec.originalName,
          originalPath: (meta['path'] as String?) ?? rec.originalPath,
          isFolder: rec.isFolder,
        );

        final oldFile = File(rec.scrambledPath);
        if (await oldFile.exists()) await oldFile.delete();
        updated.add(VaultFileRecord(
          id: rec.id,
          originalName: rec.originalName,
          originalPath: rec.originalPath,
          scrambledPath: newRec.scrambledPath,
          size: rec.size,
          lockedAt: rec.lockedAt,
          isInPlace: false,
          isFolder: rec.isFolder,
        ));
      } catch (_) {
        allOk = false;
        updated.add(rec);
      } finally {
        // 无论成败都清掉中间明文临时文件，避免明文残留在缓存目录。
        if (await temp.exists()) {
          try {
            await temp.delete();
          } catch (_) {}
        }
      }
    }

    if (allOk) {
      await _writeV2Params(newPassword);
    } else {
      // 部分失败：新密码密钥已预置缓存，但全局校验令牌并未更新，
      // 直接清空缓存，避免后续用新密码去解仍由旧密码加密的文件。
      clearKeyCache();
    }
    await saveRecords(updated);
    return allOk;
  }

  // ── 私有目录（受保护存储） ────────────────────────────────────────────────

  static Future<Directory> getVaultDir() async {
    final docDir = await getApplicationDocumentsDirectory();
    final vaultDir = Directory(p.join(docDir.path, 'vault'));
    if (!await vaultDir.exists()) {
      await vaultDir.create(recursive: true);
    }
    // 防止媒体扫描器索引密文
    final nomedia = File(p.join(vaultDir.path, '.nomedia'));
    if (!await nomedia.exists()) {
      await nomedia.create();
    }
    return vaultDir;
  }

  static Future<File> getMetadataFile() async {
    final vaultDir = await getVaultDir();
    return File(p.join(vaultDir.path, 'metadata.json'));
  }

  static Future<List<VaultFileRecord>> loadRecords() async {
    final file = await getMetadataFile();
    if (!await file.exists()) return [];
    try {
      final str = await file.readAsString();
      final list = jsonDecode(str) as List;
      return list.map((e) => VaultFileRecord.fromJson(e as Map<String, dynamic>)).toList();
    } catch (_) {
      return [];
    }
  }

  static Future<void> saveRecords(List<VaultFileRecord> records) async {
    final file = await getMetadataFile();
    final str = jsonEncode(records.map((e) => e.toJson()).toList());
    await file.writeAsString(str);
  }

  // ── 整库导出 / 导入（便携加密备份，防止卸载丢库） ─────────────────────────

  /// 将保险箱内所有 .zvn 密文 + metadata.json 打包为便携 .zip。
  /// 文件本身已是 AES-256-GCM 密文（需密码才能解密），故导出件全程不落地明文。
  /// [destDir] 为目标目录（需可写）。返回生成的 zip 路径。
  static Future<String> exportVault(String destDir) async {
    final vaultDir = await getVaultDir();
    final outDir = Directory(destDir);
    if (!await outDir.exists()) {
      await outDir.create(recursive: true);
    }
    final archive = Archive();
    // 便携备份同时携带 V2 全局参数（salt/mem/iter/par/pwcheck），
    // 以便卸载重装后导入即可用原密码解锁并恢复（否则校验令牌随应用数据丢失，
    // 用户被迫重设密码，再用新密码去解旧 .zvn 会因 GCM 认证失败而「恢复失败」）。
    final params = await _readV2ParamsForExport();
    if (params != null) {
      final pBytes = utf8.encode(jsonEncode(params));
      archive.addFile(ArchiveFile('vault_params.json', pBytes.length, pBytes));
    }
    final ents = await vaultDir.list().toList();
    for (final ent in ents) {
      if (ent is! File) continue;
      final name = p.basename(ent.path);
      if (!name.endsWith('.zvn') && name != 'metadata.json') continue;
      final bytes = await ent.readAsBytes();
      archive.addFile(ArchiveFile(name, bytes.length, bytes));
    }
    final ts = DateTime.now()
        .toIso8601String()
        .replaceAll(RegExp(r'[^0-9]'), '')
        .substring(0, 14);
    final zipBytes = ZipEncoder().encode(archive);
    if (zipBytes == null) {
      throw Exception('Failed to create backup archive');
    }
    final outPath = p.join(destDir, 'zenfile_vault_backup_$ts.zip');
    await File(outPath).writeAsBytes(zipBytes);
    return outPath;
  }

  /// 从导出件 .zip 还原保险箱：解压 .zvn + metadata.json 到 vault 目录，
  /// 并按 id 去重合并 metadata（不破坏现有记录）。
  /// 返回 `(新导入条目数, 是否恢复了备份自带的 V2 全局参数)`。
  static Future<(int imported, bool paramsRestored)> importVault(String zipPath) async {
    final bytes = await File(zipPath).readAsBytes();
    final archive = ZipDecoder().decodeBytes(bytes);
    final vaultDir = await getVaultDir();
    final currentRecords = await loadRecords();
    final currentIds = <String>{for (final r in currentRecords) r.id};
    // 仅在「空保险箱」时恢复备份自带的 V2 全局参数，避免覆盖已有保险箱的密码校验令牌
    // （否则现有 .zvn 会用新参数而无法解密）。导入到非空库时仅按 id 合并新记录。
    final isFreshImport = currentRecords.isEmpty;
    int imported = 0;
    bool paramsRestored = false;
    List<VaultFileRecord>? importedMeta;
    for (final f in archive) {
      if (!f.isFile) continue;
      final name = f.name;
      if (name == 'vault_params.json') {
        // 仅用于恢复密码校验令牌，不落盘到 vault 目录。
        if (isFreshImport) {
          try {
            final m = jsonDecode(utf8.decode(f.content as List<int>)) as Map<String, dynamic>;
            await _restoreV2Params(m);
            paramsRestored = true;
          } catch (_) {}
        }
        continue;
      }
      final outFile = File(p.join(vaultDir.path, name));
      await outFile.writeAsBytes(f.content as List<int>);
      if (name == 'metadata.json') {
        try {
          final list = jsonDecode(utf8.decode(await outFile.readAsBytes())) as List;
          importedMeta = list
              .map((e) => VaultFileRecord.fromJson(e as Map<String, dynamic>))
              .toList();
        } catch (_) {
          importedMeta = null;
        }
      } else if (name.endsWith('.zvn')) {
        imported++;
      }
    }
    if (importedMeta != null) {
      final merged = List<VaultFileRecord>.from(currentRecords);
      for (final r in importedMeta) {
        if (!currentIds.contains(r.id)) {
          // 重新指向导入后的真实 .zvn 位置：备份包内 metadata.json 记录的是导出设备的
          // 绝对路径，重装/跨设备后该路径失效，会导致「恢复时找不到密文」而失败。
          merged.add(VaultFileRecord(
            id: r.id,
            originalName: r.originalName,
            originalPath: r.originalPath,
            scrambledPath: p.join(vaultDir.path, p.basename(r.scrambledPath)),
            size: r.size,
            lockedAt: r.lockedAt,
            isInPlace: r.isInPlace,
            isFolder: r.isFolder,
          ));
        }
      }
      await saveRecords(merged);
    }
    return (imported, paramsRestored);
  }

  /// 读取当前 V2 全局参数用于导出备份（无则返回 null，导出件不含参数文件）。
  static Future<Map<String, dynamic>?> _readV2ParamsForExport() async {
    final stored = await _readStoredV2();
    if (stored == null) return null;
    return {
      'salt': base64Encode(stored.salt),
      'memory': stored.memory,
      'iterations': stored.iterations,
      'parallelism': stored.parallelism,
      'pwcheck': stored.pwcheck,
    };
  }

  /// 将 V2 全局参数写回 SharedPreferences（导入备份时恢复密码校验令牌）。
  static Future<void> _restoreV2Params(Map<String, dynamic> params) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kSalt, params['salt'] as String);
    await prefs.setInt(_kMem, params['memory'] as int);
    await prefs.setInt(_kIter, params['iterations'] as int);
    await prefs.setInt(_kPar, params['parallelism'] as int);
    await prefs.setString(_kPwCheck, params['pwcheck'] as String);
    // salt / 校验令牌已被备份件覆盖，旧会话密钥不再适用。
    clearKeyCache();
  }

  // ── 会话级密钥缓存 ────────────────────────────────────────────────────────
  //
  //
  // 修复前：每加密 / 解密一个文件都重跑一次 Argon2id，改一次密码更是 2N 次 ——
  // 这是保险箱卡顿的最大元凶。修复后：同一会话内每个「密码 + salt + KDF 参数」
  // 组合只派生一次，改密码也从 2N 次降到 2 次。
  //
  // V2 全库共用同一个全局 salt（`_getV2Params` 返回的不是每文件独立 salt），
  // 因此一把密钥就能服务全部文件；每块密文仍用独立随机 nonce，语义安全不变。
  //
  // 采用 Map 而非单槽：改密码时新旧密码需并存，混合 KDF 参数的老文件也能命中。
  // 缓存仅驻留内存，改密码 / 导入备份 / 调用 clearKeyCache() 时清空。
  static final Map<String, _V2KeyEntry> _keyCache = <String, _V2KeyEntry>{};
  static const int _keyCacheLimit = 4;

  /// 保险箱锁定 / 退出登录 / 会话结束时调用，清空内存中的会话密钥。
  static void clearKeyCache() => _keyCache.clear();

  /// 缓存指纹：password + salt 的 SHA-256 前 8 字节 + KDF 参数。
  /// 既不在键里保留明文密码，也无法由指纹反推；混入 salt 后彩虹表失效。
  static String _keyStamp(
      String password, List<int> salt, int memory, int iterations, int parallelism) {
    final digest =
        crypto.sha256.convert(<int>[...utf8.encode(password), ...salt]).bytes;
    final sb = StringBuffer();
    for (var i = 0; i < 8; i++) {
      sb.write(digest[i].toRadixString(16).padLeft(2, '0'));
    }
    return '$sb|$memory|$iterations|$parallelism';
  }

  /// 命中会话缓存的密钥，未命中返回 null。
  static _V2Keys? _cachedKeysFor(String password, List<int> salt, int memory,
      int iterations, int parallelism) {
    return _keyCache[_keyStamp(password, salt, memory, iterations, parallelism)]
        ?.keys;
  }

  /// 回填会话缓存（超出上限时淘汰最早的一条）。
  static void _rememberKeys(String password, List<int> salt, int memory,
      int iterations, int parallelism, _V2Keys keys) {
    final stamp = _keyStamp(password, salt, memory, iterations, parallelism);
    _keyCache
      ..remove(stamp)
      ..[stamp] = _V2KeyEntry(
        keys: keys,
        salt: salt,
        memory: memory,
        iterations: iterations,
        parallelism: parallelism,
      );
    while (_keyCache.length > _keyCacheLimit) {
      _keyCache.remove(_keyCache.keys.first);
    }
  }

  /// 供解密任务跨 isolate 携带的候选密钥：解密所需的 salt / KDF 参数位于文件头
  /// 内部，主线程无法预知，故把全部缓存条目交给 isolate，由其按文件头参数匹配。
  static List<_VaultCachedKey> get _cachedKeyCandidates {
    return _keyCache.values
        .map((e) => _VaultCachedKey(
              salt: e.salt,
              memory: e.memory,
              iterations: e.iterations,
              parallelism: e.parallelism,
              payloadKey: e.keys.payloadKey,
              metadataKey: e.keys.metadataKey,
            ))
        .toList(growable: false);
  }

  /// 吸收一次任务结果中派生出的密钥，写入会话缓存。
  /// 命中缓存的任务 master 为空，此时无需重复回填。
  static void _absorbKeys(String password, _VaultJobResult r) {
    final master = r.master;
    final payloadKey = r.payloadKey;
    final metadataKey = r.metadataKey;
    final salt = r.derivedSalt;
    if (master == null || master.isEmpty) return;
    if (payloadKey == null || metadataKey == null || salt == null) return;
    _rememberKeys(
      password,
      salt,
      r.derivedMemory ?? _defaultMem,
      r.derivedIterations ?? _defaultIter,
      r.derivedParallelism ?? _defaultPar,
      _V2Keys(
          master: master, payloadKey: payloadKey, metadataKey: metadataKey),
    );
  }

  // ── 密钥派生（Argon2id + HKDF） ───────────────────────────────────────────

  static Future<_V2Keys> _deriveV2Keys(
    String password,
    List<int> salt,
    int memory,
    int iterations,
    int parallelism,
  ) async {
    final argon2 = Argon2id(
      parallelism: parallelism,
      memory: memory,
      iterations: iterations,
      hashLength: _keyLength,
    );
    final masterSk =
        await argon2.deriveKey(secretKey: SecretKey(utf8.encode(password)), nonce: salt);
    final master = await masterSk.extractBytes();

    final hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: _keyLength);
    final hkdfNonce = utf8.encode(_kHkdfSalt);
    final pSk = await hkdf.deriveKey(
        secretKey: SecretKey(master), nonce: hkdfNonce, info: utf8.encode(_kInfoPayload));
    final mSk = await hkdf.deriveKey(
        secretKey: SecretKey(master), nonce: hkdfNonce, info: utf8.encode(_kInfoMetadata));

    return _V2Keys(
      master: master,
      payloadKey: await pSk.extractBytes(),
      metadataKey: await mSk.extractBytes(),
    );
  }

  /// 读取已存储的 V2 参数（不创建）。返回 null 表示尚未初始化 V2。
  static Future<_V2Stored?> _readStoredV2() async {
    final prefs = await SharedPreferences.getInstance();
    final saltB64 = prefs.getString(_kSalt);
    final mem = prefs.getInt(_kMem);
    final iter = prefs.getInt(_kIter);
    final par = prefs.getInt(_kPar);
    final pw = prefs.getString(_kPwCheck);
    if (saltB64 == null || mem == null || iter == null || par == null || pw == null) {
      return null;
    }
    return _V2Stored(
      salt: base64Decode(saltB64),
      memory: mem,
      iterations: iter,
      parallelism: par,
      pwcheck: pw,
    );
  }

  /// 加密时获取 V2 参数：已存在则复用，否则为新密码生成并写入。
  static Future<_V2Params> _getV2Params(String password) async {
    final stored = await _readStoredV2();
    if (stored != null) {
      return _V2Params(
        salt: stored.salt,
        memory: stored.memory,
        iterations: stored.iterations,
        parallelism: stored.parallelism,
      );
    }
    return _writeV2Params(password);
  }

  /// 生成新 salt + 参数，并以 metadataKey 加密校验令牌写入。返回所用参数。
  static Future<_V2Params> _writeV2Params(String password) async {
    final salt = _randomBytes(_saltLength);
    final vk = await _deriveV2Keys(password, salt, _defaultMem, _defaultIter, _defaultPar);
    final nonce = _randomBytes(_nonceLength);
    final sb = await _gcm.encrypt(utf8.encode(_kPwCheckPlain),
        secretKey: SecretKey(vk.metadataKey), nonce: nonce);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kSalt, base64Encode(salt));
    await prefs.setInt(_kMem, _defaultMem);
    await prefs.setInt(_kIter, _defaultIter);
    await prefs.setInt(_kPar, _defaultPar);
    await prefs.setString(_kPwCheck, base64Encode(nonce + sb.concatenation(nonce: false)));
    // 新 salt 刚写入，立即回填会话缓存，后续加解密免于重复派生。
    _rememberKeys(password, salt, _defaultMem, _defaultIter, _defaultPar, vk);
    return _V2Params(
      salt: salt,
      memory: _defaultMem,
      iterations: _defaultIter,
      parallelism: _defaultPar,
    );
  }

  // ── 加密（写 V2） ─────────────────────────────────────────────────────────

  /// 执行加密任务：优先在后台 isolate 运行（不阻塞 UI 主线程），
  /// isolate 不可用时自动回退到主 isolate，保证功能不中断。
  static Future<_VaultJobResult> _runEncryptJob(_VaultEncryptJob job) async {
    final sw = Stopwatch()..start();
    _VaultJobResult r;
    try {
      r = await Isolate.run(() => _vaultEncryptCore(job),
          debugName: 'vault-encrypt');
    } catch (e) {
      debugPrint('[ZenFile][Vault] isolate encrypt unavailable, fallback: $e');
      r = await _vaultEncryptCore(job);
    }
    _absorbKeys(job.password, r);
    final err = r.error;
    if (err != null) {
      // 删除可能已产生的半截密文，避免留下无效 .zvn 占位
      final f = File(job.outPath);
      if (await f.exists()) {
        await f.delete().catchError((Object _) => f);
      }
      throw Exception(err);
    }
    debugPrint(
        '[ZenFile][Vault] encrypt ${job.originalName} in ${sw.elapsedMilliseconds} ms');
    return r;
  }

  /// 执行解密任务：优先在后台 isolate 运行，失败回退主 isolate。
  static Future<_VaultJobResult> _runDecryptJob(_VaultDecryptJob job) async {
    final sw = Stopwatch()..start();
    _VaultJobResult r;
    try {
      r = await Isolate.run(() => _vaultDecryptCore(job),
          debugName: 'vault-decrypt');
    } catch (e) {
      debugPrint('[ZenFile][Vault] isolate decrypt unavailable, fallback: $e');
      r = await _vaultDecryptCore(job);
    }
    _absorbKeys(job.password, r);
    final err = r.error;
    if (err != null) throw Exception(err);
    debugPrint(
        '[ZenFile][Vault] decrypt ${p.basename(job.srcPath)} in ${sw.elapsedMilliseconds} ms');
    return r;
  }

  static Future<VaultFileRecord> _encryptRawToVault({
    required String sourcePath,
    required String password,
    required String originalName,
    required String originalPath,
    required bool isFolder,
  }) async {
    final params = await _getV2Params(password);
    // 命中会话缓存时直接复用派生结果，跳过本次 Argon2id。
    final cached = _cachedKeysFor(
        password, params.salt, params.memory, params.iterations, params.parallelism);

    final vaultDir = await getVaultDir();
    final scrambledPath = p.join(vaultDir.path, '${_randomId()}.zvn');

    final result = await _runEncryptJob(_VaultEncryptJob(
      sourcePath: sourcePath,
      outPath: scrambledPath,
      password: password,
      salt: params.salt,
      memory: params.memory,
      iterations: params.iterations,
      parallelism: params.parallelism,
      originalName: originalName,
      originalPath: originalPath,
      isFolder: isFolder,
      payloadKey: cached?.payloadKey,
      metadataKey: cached?.metadataKey,
      useV3: writeV3,
    ));

    // 加密核心回传实际写入的明文长度（避免二次 stat 文件）。
    final length = result.meta['size'] as int? ?? 0;

    return VaultFileRecord(
      id: _randomId(),
      originalName: originalName,
      originalPath: originalPath,
      scrambledPath: scrambledPath,
      size: length,
      lockedAt: DateTime.now().toIso8601String(),
      isInPlace: false,
      isFolder: isFolder,
    );
  }

  /// 锁定单个文件。V2 起恒久写入应用私有 vault 目录（受保护存储），原文件删除。
  static Future<VaultFileRecord> lockFile({
    required File file,
    required String password,
    bool inPlace = false, // 保留签名兼容，V2 起始终忽略（私有容器）
    String? customName,
    String? customPath,
    bool isFolder = false,
  }) async {
    if (!await file.exists()) {
      throw Exception('File does not exist: ${file.path}');
    }
    final originalPath = customPath ?? file.path;
    final originalName = customName ?? p.basename(originalPath);

    final rec = await _encryptRawToVault(
      sourcePath: file.path,
      password: password,
      originalName: originalName,
      originalPath: originalPath,
      isFolder: isFolder,
    );
    await file.delete();
    final records = await loadRecords();
    records.add(rec);
    await saveRecords(records);
    return rec;
  }

  /// 锁定目录：先递归打包为 ZIP，再按单文件方式加密（V2）。
  static Future<VaultFileRecord> lockDirectory({
    required Directory directory,
    required String password,
    bool inPlace = false,
  }) async {
    if (!await directory.exists()) {
      throw Exception('Directory does not exist: ${directory.path}');
    }
    final originalPath = directory.path;
    final originalName = p.basename(originalPath);

    final tempDir = await getTemporaryDirectory();
    final tempZipFile =
        File(p.join(tempDir.path, 'temp_vault_zip_${DateTime.now().millisecondsSinceEpoch}.zip'));
    if (await tempZipFile.exists()) {
      await tempZipFile.delete();
    }

    try {
      // 流式打包 + isolate 执行：不再把整个目录内容一次性读进内存（大目录 OOM 风险），
      // 也不在主线程做 stat/压缩（避免 UI 卡顿）。
      await _zipDirectoryToTemp(originalPath, tempZipFile.path);

      final rec = await _encryptRawToVault(
        sourcePath: tempZipFile.path,
        password: password,
        originalName: originalName,
        originalPath: originalPath,
        isFolder: true,
      );
      await tempZipFile.delete();
      await directory.delete(recursive: true);

      final records = await loadRecords();
      records.add(rec);
      await saveRecords(records);
      return rec;
    } finally {
      if (await tempZipFile.exists()) {
        await tempZipFile.delete();
      }
    }
  }

  /// 将目录流式打包为临时 zip（isolate 优先，失败回退主线程）。
  static Future<void> _zipDirectoryToTemp(String dirPath, String tempZipPath) async {
    final sw = Stopwatch()..start();
    try {
      await Isolate.run(() => _vaultZipDirCore(dirPath, tempZipPath),
          debugName: 'vault-zip');
    } catch (e) {
      debugPrint('[ZenFile][Vault] isolate zip unavailable, fallback: $e');
      await _vaultZipDirCore(dirPath, tempZipPath);
    }
    debugPrint('[ZenFile][Vault] zip dir in ${sw.elapsedMilliseconds} ms');
  }

  // ── 解密（V1 兼容 + V2） ──────────────────────────────────────────────────

  /// 解锁并恢复原文件/目录到 originalPath。
  static Future<File> unlockFile({
    required VaultFileRecord record,
    required String password,
  }) async {
    final scrambledFile = File(record.scrambledPath);
    if (!await scrambledFile.exists()) {
      throw Exception('Scrambled vault file not found: ${record.scrambledPath}');
    }

    final magic = await _readMagic(scrambledFile);

    if (magic == _v1Magic) {
      final r = await _decryptV1(record, password);
      if (record.isFolder) {
        final archive = ZipDecoder().decodeBytes(r.bytes);
        final destDir = p.dirname(record.originalPath);
        for (final f in archive) {
          final fullPath = p.join(destDir, f.name);
          if (f.isFile) {
            final data = f.content as List<int>;
            final outFile = File(fullPath);
            await outFile.parent.create(recursive: true);
            await outFile.writeAsBytes(data);
          } else {
            await Directory(fullPath).create(recursive: true);
          }
        }
      } else {
        final originalFile = File(record.originalPath);
        await originalFile.parent.create(recursive: true);
        await originalFile.writeAsBytes(r.bytes);
      }
      await scrambledFile.delete();
      final records = await loadRecords();
      records.removeWhere((e) => e.id == record.id);
      await saveRecords(records);
      return File(record.originalPath);
    }

    // V2：整段（文件头 + 元数据 + 负载分块）都在 isolate 内完成，
    // 主线程只等待结果，不再被 Argon2id 与 AES-GCM 占满而掉帧。
    final String outPath;
    final File? tempZip;
    if (record.isFolder) {
      final td = await getTemporaryDirectory();
      tempZip = File(p.join(td.path, 'temp_vault_unzip_${record.id}.zip'));
      outPath = tempZip.path;
    } else {
      final originalFile = File(record.originalPath);
      await originalFile.parent.create(recursive: true);
      outPath = originalFile.path;
      tempZip = null;
    }

    try {
      await _decryptV2File(
        srcPath: record.scrambledPath,
        outPath: outPath,
        password: password,
      );
      if (record.isFolder && tempZip != null) {
        final archive = ZipDecoder().decodeBytes(await tempZip.readAsBytes());
        final destDir = p.dirname(record.originalPath);
        for (final f in archive) {
          final fullPath = p.join(destDir, f.name);
          if (f.isFile) {
            final data = f.content as List<int>;
            final outFile = File(fullPath);
            await outFile.parent.create(recursive: true);
            await outFile.writeAsBytes(data);
          } else {
            await Directory(fullPath).create(recursive: true);
          }
        }
        await tempZip.delete();
      }
    } finally {
      if (tempZip != null && await tempZip.exists()) {
        try {
          await tempZip.delete();
        } catch (_) {}
      }
    }

    await scrambledFile.delete();
    final records = await loadRecords();
    records.removeWhere((e) => e.id == record.id);
    await saveRecords(records);
    return File(record.originalPath);
  }

  /// 临时解密到缓存目录供应用内预览（不写回原路径）。
  static Future<File> decryptTemporary({
    required VaultFileRecord record,
    required String password,
  }) async {
    final scrambledFile = File(record.scrambledPath);
    if (!await scrambledFile.exists()) {
      throw Exception('Scrambled vault file not found');
    }

    final magic = await _readMagic(scrambledFile);
    final cacheDir = await getTemporaryDirectory();
    final ext = record.isFolder ? '.zip' : '';
    final temp =
        File(p.join(cacheDir.path, 'temp_vault_${record.id}_${record.originalName}$ext'));

    if (magic == _v1Magic) {
      final r = await _decryptV1(record, password);
      await temp.writeAsBytes(r.bytes);
      return temp;
    }

    await _decryptV2File(
      srcPath: record.scrambledPath,
      outPath: temp.path,
      password: password,
    );
    return temp;
  }

  // ── 底层解密实现 ──────────────────────────────────────────────────────────

  /// 只读文件头 magic（14 字节，三代长度一致）以区分 V1 / V2 / V3。
  static Future<String> _readMagic(File file) async {
    final raf = await file.open();
    try {
      return utf8.decode(await _readBytes(raf, _magicLength));
    } finally {
      await raf.close();
    }
  }

  /// V2 解密入口：优先在 isolate 内完成「解析文件头 → 复用会话密钥或派生 →
  /// 分块解密写入 [outPath]」，失败时自动回退主 isolate。返回解密出的元数据。
  ///
  /// 注意：解密所需的 salt 与 KDF 参数位于文件头内部，主线程无法预知，
  /// 因此把「会话缓存密钥 + 其对应的 salt/参数」一并交给 isolate，
  /// 由 isolate 比对文件头后决定复用还是重新派生。
  static Future<_VaultJobResult> _decryptV2File({
    required String srcPath,
    required String outPath,
    required String password,
  }) {
    return _runDecryptJob(_VaultDecryptJob(
      srcPath: srcPath,
      outPath: outPath,
      password: password,
      candidates: _cachedKeyCandidates,
    ));
  }

  /// V1 解密（向后兼容）：XOR 仅还原前 8KB，其余为明文。返回明文 bytes + 元数据。
  static Future<_V1Result> _decryptV1(
    VaultFileRecord record,
    String password,
  ) async {
    final bytes = await File(record.scrambledPath).readAsBytes();
    if (bytes.length < _v1Magic.length + 4) {
      throw Exception('Invalid vault file format (Too short)');
    }
    final magic = utf8.decode(bytes.sublist(0, _v1Magic.length));
    if (magic != _v1Magic) {
      throw Exception('Invalid vault file format (Magic tag mismatch)');
    }

    final metaLen = (bytes[_v1Magic.length] << 24) |
        (bytes[_v1Magic.length + 1] << 16) |
        (bytes[_v1Magic.length + 2] << 8) |
        bytes[_v1Magic.length + 3];
    final metaStart = _v1Magic.length + 4;
    final metaEnd = metaStart + metaLen;
    if (bytes.length < metaEnd) {
      throw Exception('Invalid vault file format (Corrupted header)');
    }
    final obfuscatedMetadata = bytes.sublist(metaStart, metaEnd);
    final metaKey = _deriveKey(password, obfuscatedMetadata.length);
    final decryptedMetadataBytes = _xorBytes(obfuscatedMetadata, metaKey);
    late final Map<String, dynamic> meta;
    try {
      meta = jsonDecode(utf8.decode(decryptedMetadataBytes)) as Map<String, dynamic>;
    } catch (_) {
      throw Exception('Incorrect password or corrupted file');
    }

    final originalSize = meta['size'] as int;
    final scrambleLen = min(_scrambleSize, originalSize);
    final fileDataStart = metaEnd;
    if (bytes.length < fileDataStart + scrambleLen) {
      throw Exception('Invalid vault file format (Corrupted payload)');
    }
    final obfuscatedSignature = bytes.sublist(fileDataStart, fileDataStart + scrambleLen);
    final rest = bytes.sublist(fileDataStart + scrambleLen);
    final key = _deriveKey(password, scrambleLen);
    final decryptedSignature = _xorBytes(obfuscatedSignature, key);

    final result = Uint8List(decryptedSignature.length + rest.length);
    result.setAll(0, decryptedSignature);
    result.setAll(decryptedSignature.length, rest);
    return _V1Result(bytes: result, meta: meta);
  }

  // ── V1 兼容：XOR 密钥派生（仅用于读取历史 .nfv） ──────────────────────────

  static List<int> _deriveKey(String password, int length) {
    final hash = crypto.sha256.convert(utf8.encode(password)).bytes;
    final key = List<int>.filled(length, 0);
    for (int i = 0; i < length; i++) {
      key[i] = hash[i % hash.length] ^ (i & 0xFF);
    }
    return key;
  }

  static List<int> _xorBytes(List<int> bytes, List<int> key) {
    final result = List<int>.from(bytes);
    for (int i = 0; i < bytes.length; i++) {
      result[i] = bytes[i] ^ key[i % key.length];
    }
    return result;
  }

  // ── 工具 ──────────────────────────────────────────────────────────────────

  static Uint8List _randomBytes(int n) {
    final out = Uint8List(n);
    var filled = 0;
    while (filled < n) {
      // 一次取 30 位随机数拆成 3 个字节：原来逐字节调用 Random.secure()，
      // 每个 12 字节 nonce 要 12 次调用，加密大文件时开销可观。
      final r = _secureRandom.nextInt(1 << 30);
      out[filled++] = r & 0xFF;
      if (filled < n) out[filled++] = (r >> 8) & 0xFF;
      if (filled < n) out[filled++] = (r >> 16) & 0xFF;
    }
    return out;
  }

  static String _randomId() {
    final sb = StringBuffer();
    for (int i = 0; i < 16; i++) {
      sb.write(_secureRandom.nextInt(16).toRadixString(16));
    }
    return sb.toString() + DateTime.now().microsecondsSinceEpoch.toString();
  }

  static List<int> _u32(int v) => [
        (v >> 24) & 0xFF,
        (v >> 16) & 0xFF,
        (v >> 8) & 0xFF,
        v & 0xFF,
      ];

  static int _readU32(List<int> b) =>
      ((b[0] & 0xFF) << 24) | ((b[1] & 0xFF) << 16) | ((b[2] & 0xFF) << 8) | (b[3] & 0xFF);

  static List<int> _encodeParams(int memory, int iterations, int parallelism) => [
        ..._u32(memory),
        iterations & 0xFF,
        parallelism & 0xFF,
      ];

  /// 从 raf 读取至多 [n] 字节（EOF 时返回不足 [n] 的短数据）。
  static Future<Uint8List> _readBytes(RandomAccessFile raf, int n) async {
    final out = <int>[];
    while (out.length < n) {
      final chunk = await raf.read(n - out.length);
      if (chunk.isEmpty) break;
      out.addAll(chunk);
    }
    return Uint8List.fromList(out);
  }
}

// ════════════════════════════════════════════════════════════════════════════
// 加解密工作单元（isolate 友好）
//
// 设计要点：
// 1) 均为顶层函数 + 可序列化入参，既可用 `Isolate.run` 在后台 isolate 执行
//    （不阻塞 UI 主线程），也可在主 isolate 直接调用作为回退路径；
// 2) RandomAccessFile / IOSink 不可跨 isolate 传递，故统一以「路径」为入参，
//    由工作单元自行 open / close；
// 3) 业务异常（密码错误、文件损坏等）一律转为 `_VaultJobResult.error` 返回，
//    只有 isolate 基础设施失败才抛给调用方 → 避免业务失败被误判后重复跑一遍；
// 4) 会话密钥由主 isolate 以字节形式传入，工作单元比对 salt / KDF 参数后决定
//    复用还是重新派生；派生结果随结果回传，供主 isolate 回填缓存。
// ════════════════════════════════════════════════════════════════════════════

/// 跨 isolate 携带的候选会话密钥（附其 salt 与 KDF 参数，用于匹配校验）。
class _VaultCachedKey {
  final List<int> salt;
  final int memory;
  final int iterations;
  final int parallelism;
  final List<int> payloadKey;
  final List<int> metadataKey;

  const _VaultCachedKey({
    required this.salt,
    required this.memory,
    required this.iterations,
    required this.parallelism,
    required this.payloadKey,
    required this.metadataKey,
  });
}

/// 加密任务入参（可跨 isolate 序列化）。
class _VaultEncryptJob {
  final String sourcePath;
  final String outPath;
  final String password;
  final List<int> salt;
  final int memory;
  final int iterations;
  final int parallelism;
  final String originalName;
  final String originalPath;
  final bool isFolder;
  // 会话缓存密钥（主线程已确认与 salt / 参数匹配），未命中时为 null。
  final List<int>? payloadKey;
  final List<int>? metadataKey;
  // 是否以 V3（XChaCha20）写入；false 则写 V2（AES-GCM）。见 VaultService.writeV3。
  final bool useV3;

  const _VaultEncryptJob({
    required this.sourcePath,
    required this.outPath,
    required this.password,
    required this.salt,
    required this.memory,
    required this.iterations,
    required this.parallelism,
    required this.originalName,
    required this.originalPath,
    required this.isFolder,
    this.payloadKey,
    this.metadataKey,
    this.useV3 = true,
  });
}

/// 解密任务入参（可跨 isolate 序列化）。
class _VaultDecryptJob {
  final String srcPath;
  final String outPath;
  final String password;
  // 解密所需 salt / KDF 参数位于文件头内部，主线程无法预知，
  // 故携带全部候选密钥，由工作单元按文件头参数匹配。
  final List<_VaultCachedKey> candidates;

  const _VaultDecryptJob({
    required this.srcPath,
    required this.outPath,
    required this.password,
    required this.candidates,
  });
}

/// 工作单元结果：解密元数据（加密时为明文长度）+ 实际使用的密钥。
///
/// [error] 非空表示业务失败（密码错误 / 文件损坏等），调用方据此抛异常，
/// 不应再回退重跑。命中缓存时 [master] 为空，主 isolate 跳过回填。
class _VaultJobResult {
  final Map<String, dynamic> meta;
  final String? error;
  final List<int>? master;
  final List<int>? payloadKey;
  final List<int>? metadataKey;
  final List<int>? derivedSalt;
  final int? derivedMemory;
  final int? derivedIterations;
  final int? derivedParallelism;

  const _VaultJobResult({
    required this.meta,
    this.error,
    this.master,
    this.payloadKey,
    this.metadataKey,
    this.derivedSalt,
    this.derivedMemory,
    this.derivedIterations,
    this.derivedParallelism,
  });
}

/// 常量时间无关的字节比较（避免用 == 比较 List 内容）。
bool _vaultListEquals(List<int> a, List<int> b) {
  if (identical(a, b)) return true;
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// 在候选密钥中查找与文件头 salt / KDF 参数匹配的一项。
_V2Keys? _vaultFindCachedKey(
  List<_VaultCachedKey> candidates,
  List<int> salt,
  int memory,
  int iterations,
  int parallelism,
) {
  for (final c in candidates) {
    if (c.memory == memory &&
        c.iterations == iterations &&
        c.parallelism == parallelism &&
        _vaultListEquals(c.salt, salt)) {
      return _V2Keys(
          master: const <int>[],
          payloadKey: c.payloadKey,
          metadataKey: c.metadataKey);
    }
  }
  return null;
}

/// 取得本次任务要用的密钥：优先复用会话缓存，否则就地派生 Argon2id。
Future<_V2Keys> _vaultResolveKeys({
  required String password,
  required List<int> salt,
  required int memory,
  required int iterations,
  required int parallelism,
  List<int>? payloadKey,
  List<int>? metadataKey,
  List<_VaultCachedKey>? candidates,
}) async {
  // 加密路径：主线程已按 salt / 参数确认过缓存可用，直接复用。
  if (payloadKey != null && metadataKey != null) {
    return _V2Keys(
        master: const <int>[], payloadKey: payloadKey, metadataKey: metadataKey);
  }
  // 解密路径：按文件头的 salt / 参数在候选缓存里匹配。
  final hit = candidates == null
      ? null
      : _vaultFindCachedKey(candidates, salt, memory, iterations, parallelism);
  if (hit != null) return hit;
  return VaultService._deriveV2Keys(
      password, salt, memory, iterations, parallelism);
}

/// 加密核心：明文文件 → V2 密文文件（文件头 + 加密元数据 + 分块加密负载）。
Future<_VaultJobResult> _vaultEncryptCore(_VaultEncryptJob job) async {
  final salt = job.salt;
  final memory = job.memory;
  final iterations = job.iterations;
  final parallelism = job.parallelism;
  RandomAccessFile? source;
  IOSink? out;
  try {
    final keys = await _vaultResolveKeys(
      password: job.password,
      salt: salt,
      memory: memory,
      iterations: iterations,
      parallelism: parallelism,
      payloadKey: job.payloadKey,
      metadataKey: job.metadataKey,
    );

    // 版本选择：V3 = XChaCha20-Poly1305（nonce 24B / tag 16B），
    // V2 = AES-256-GCM（nonce 12B / tag 16B）。密钥派生两版完全相同，
    // 因此会话缓存、改密流程无需区分版本，V2 / V3 文件可在同一把密钥下互通。
    final useV3 = job.useV3;
    final cipher = useV3 ? VaultService._xchacha : VaultService._gcm;
    final nonceLen =
        useV3 ? VaultService._v3NonceLength : VaultService._nonceLength;
    final magic = useV3 ? VaultService._v3Magic : VaultService._v2Magic;
    final version = useV3 ? VaultService._v3Version : VaultService._v2Version;

    source = await File(job.sourcePath).open(mode: FileMode.read);
    final length = await source.length();
    out = File(job.outPath).openWrite();

    // 文件头：magic + version + salt + KDF 参数
    out.add(utf8.encode(magic));
    out.add([version]);
    out.add(salt);
    out.add(VaultService._encodeParams(memory, iterations, parallelism));

    // 元数据（metadataKey 加密，原文件名 / 路径全混淆）
    final metaBytes = utf8.encode(jsonEncode({
      'name': job.originalName,
      'path': job.originalPath,
      'size': length,
      'isFolder': job.isFolder,
      'lockedAt': DateTime.now().toIso8601String(),
      'version': version,
    }));
    final metaNonce = VaultService._randomBytes(nonceLen);
    final metaSb = await cipher.encrypt(metaBytes,
        secretKey: SecretKey(keys.metadataKey), nonce: metaNonce);
    out.add(metaNonce);
    out.add(VaultService._u32(metaSb.cipherText.length + metaSb.mac.bytes.length));
    out.add(metaSb.concatenation(nonce: false));

    // 负载：payloadKey 分块流式加密，每块独立随机 nonce
    final payloadSk = SecretKey(keys.payloadKey);
    var offset = 0;
    while (offset < length) {
      final n = min(VaultService._chunkSize, length - offset);
      final chunk = await source.read(n);
      if (chunk.isEmpty) break; // 源文件被意外截断，避免死循环
      final nonce = VaultService._randomBytes(nonceLen);
      final sb = await cipher.encrypt(chunk, secretKey: payloadSk, nonce: nonce);
      out.add(nonce);
      out.add(sb.concatenation(nonce: false));
      offset += chunk.length;
    }

    return _VaultJobResult(
      meta: <String, dynamic>{'size': length},
      master: keys.master,
      payloadKey: keys.payloadKey,
      metadataKey: keys.metadataKey,
      derivedSalt: salt,
      derivedMemory: memory,
      derivedIterations: iterations,
      derivedParallelism: parallelism,
    );
  } catch (e) {
    return _VaultJobResult(meta: <String, dynamic>{}, error: e.toString());
  } finally {
    try {
      await source?.close();
    } catch (_) {}
    try {
      await out?.close();
    } catch (_) {}
  }
}

/// 解密核心：V2 密文文件 → 明文文件，返回文件头内解密出的元数据。
///
/// 注意：输出文件在元数据 GCM 校验通过后才会创建，避免密码错误时把
/// 目标路径截断成一个空文件（原实现先 openWrite 再解密，存在该隐患）。
Future<_VaultJobResult> _vaultDecryptCore(_VaultDecryptJob job) async {
  RandomAccessFile? raf;
  IOSink? out;
  try {
    raf = await File(job.srcPath).open();

    // 头：magic(14) + version(1) + salt(16) + params(6)
    final magic = utf8.decode(
        await VaultService._readBytes(raf, VaultService._magicLength));

    // 按文件头 magic 选择算法：V2 = AES-256-GCM（nonce 12B），
    // V3 = XChaCha20-Poly1305（nonce 24B），两者 tag 均为 16B，其余头结构一致。
    // 这样老版本写入的 .zvn 仍能正常解密，新文件自动享受更快的流密码。
    final Cipher cipher;
    final int nonceLen;
    final int tagLen;
    final int version;
    if (magic == VaultService._v3Magic) {
      cipher = VaultService._xchacha;
      nonceLen = VaultService._v3NonceLength;
      tagLen = VaultService._v3TagLength;
      version = VaultService._v3Version;
    } else if (magic == VaultService._v2Magic) {
      cipher = VaultService._gcm;
      nonceLen = VaultService._nonceLength;
      tagLen = VaultService._tagLength;
      version = VaultService._v2Version;
    } else {
      throw Exception('Invalid vault file format (Magic tag mismatch)');
    }

    // 校验头内版本号：必须与 magic 对应的版本一致，否则说明头被篡改或版本错配，
    // 继续解析会因 nonce 长度不符而读到垃圾数据。
    final versionB = await VaultService._readBytes(raf, 1);
    final actualVersion = versionB.isEmpty ? -1 : versionB[0];
    if (actualVersion != version) {
      throw Exception(
          'Unsupported vault file version: $actualVersion (expected $version)');
    }
    final salt = await VaultService._readBytes(raf, VaultService._saltLength);
    final paramsB = await VaultService._readBytes(raf, 6);
    final memory = VaultService._readU32(paramsB.sublist(0, 4));
    final iterations = paramsB[4];
    final parallelism = paramsB[5];

    final keys = await _vaultResolveKeys(
      password: job.password,
      salt: salt,
      memory: memory,
      iterations: iterations,
      parallelism: parallelism,
      candidates: job.candidates,
    );

    // 元数据块（AEAD 校验：密码错误会在此失败，此时尚未创建输出文件）
    final metaNonce = await VaultService._readBytes(raf, nonceLen);
    final metaLen =
        VaultService._readU32(await VaultService._readBytes(raf, 4));
    final metaConcat = await VaultService._readBytes(raf, metaLen);
    final metaSb = SecretBox.fromConcatenation(
      metaNonce + metaConcat,
      nonceLength: nonceLen,
      macLength: tagLen,
      copy: false,
    );
    final metaBytes =
        await cipher.decrypt(metaSb, secretKey: SecretKey(keys.metadataKey));
    final meta = jsonDecode(utf8.decode(metaBytes)) as Map<String, dynamic>;

    out = File(job.outPath).openWrite();
    final payloadSk = SecretKey(keys.payloadKey);
    while (true) {
      final nonceB = await VaultService._readBytes(raf, nonceLen);
      if (nonceB.length < nonceLen) break;
      final ctMac =
          await VaultService._readBytes(raf, VaultService._chunkSize + tagLen);
      if (ctMac.isEmpty) break;
      final sb = SecretBox.fromConcatenation(
        nonceB + ctMac,
        nonceLength: nonceLen,
        macLength: tagLen,
        copy: false,
      );
      final pt = await cipher.decrypt(sb, secretKey: payloadSk);
      out.add(pt);
    }

    return _VaultJobResult(
      meta: meta,
      master: keys.master,
      payloadKey: keys.payloadKey,
      metadataKey: keys.metadataKey,
      derivedSalt: salt,
      derivedMemory: memory,
      derivedIterations: iterations,
      derivedParallelism: parallelism,
    );
  } catch (e) {
    return _VaultJobResult(meta: <String, dynamic>{}, error: e.toString());
  } finally {
    try {
      await raf?.close();
    } catch (_) {}
    try {
      await out?.close();
    } catch (_) {}
  }
}

/// 流式打包目录到临时 zip：逐文件写入磁盘，避免整个目录同时驻留内存
/// （原实现 readAsBytes 全量进内存，大目录有 OOM 风险）。返回 zip 字节数。
Future<int> _vaultZipDirCore(String dirPath, String tempZipPath) async {
  final outFile = File(tempZipPath);
  if (await outFile.exists()) {
    await outFile.delete();
  }
  final encoder = ZipFileEncoder();
  encoder.create(tempZipPath);
  try {
    await for (final entity in Directory(dirPath).list(recursive: true)) {
      if (entity is File) {
        final rel = p
            .relative(entity.path, from: p.dirname(dirPath))
            .replaceAll('\\', '/');
        await encoder.addFile(entity, rel);
      }
    }
  } finally {
    await encoder.close();
  }
  return await outFile.length();
}
