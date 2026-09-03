import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:math';
import 'package:crypto/crypto.dart' as crypto;
import 'package:cryptography_plus/cryptography_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:path/path.dart' as p;
import 'package:archive/archive.dart';

/// ZenFile 保险箱（Vault）加密服务。
///
/// ## 版本与安全模型
/// - **V1（旧，向后兼容只读）**：`sha256(password)` 派生 XOR 密钥，仅混淆文件前 8KB，
///   其余内容明文存储。存在真实安全缺陷，仅用于解锁/迁移历史 `.nfv` 文件。
/// - **V2（当前，默认）**：完整满足用户 4 项安全需求：
///   1. **Argon2id** 派生主密钥（memory-hard，抗 GPU/ASIC 暴破），再用 **HKDF-SHA256**
///      拆分为 `payloadKey`（文件内容）与 `metadataKey`（元数据）两把独立子密钥；
///   2. 每个文件以 **AES-256-GCM** 整文件加密（分块流式，每块独立 96-bit nonce），
///      GCM tag 提供完整性/认证，天然防位翻转与篡改；
///   3. **元数据全混淆**：原文件名/路径/目录结构仅以 `metadataKey` 加密存储于文件头，
///      磁盘上的密文文件名使用随机 id + 随机扩展名（`.zvn`），不泄露任何结构信息；
///   4. **受保护存储**：密文恒久落在应用私有目录 `…/vault/`（沙盒隔离、带 `.nomedia`
///      防媒体扫描），不再像旧版 `inPlace` 那样把可见的 `.nfv` 留在用户原目录。
///
/// 新锁定一律写入 V2；旧 V1 文件在解锁 / 改名密码（changePassword）时自动升级为 V2。
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
  static const int _v2Version = 2;
  static const int _scrambleSize = 8192; // V1 仅混淆前 8KB（向后兼容用）
  static const int _saltLength = 16;
  static const int _nonceLength = 12; // AES-GCM 96-bit nonce
  static const int _tagLength = 16; // GCM tag
  static const int _chunkSize = 1024 * 1024; // 1 MiB 流式分块

  // Argon2id 默认参数（memory 单位为 KiB；65536 KiB = 64 MiB）
  static const int _defaultMem = 65536;
  static const int _defaultIter = 3;
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
  static final Random _secureRandom = Random.secure();

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
        if (utf8.decode(pt) == _kPwCheckPlain) return true;
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
    for (final rec in records) {
      try {
        final tempDir = await getTemporaryDirectory();
        final temp = File(p.join(tempDir.path, 'vault_rekey_${rec.id}.tmp'));
        final sink = temp.openWrite();
        late Map<String, dynamic> meta;
        final raf0 = await File(rec.scrambledPath).open();
        final magic = utf8.decode(await _readBytes(raf0, _v2Magic.length));
        await raf0.setPosition(0);
        if (magic == _v1Magic) {
          final r = await _decryptV1(rec, oldPassword);
          sink.add(r.bytes);
          meta = r.meta;
        } else {
          meta = await _decryptV2ToSink(raf0, oldPassword, sink);
        }
        await sink.close();
        await raf0.close();

        final raf1 = await temp.open(mode: FileMode.read);
        final len = await temp.length();
        final newRec = await _encryptRawToVault(
          source: raf1,
          length: len,
          password: newPassword,
          originalName: (meta['name'] as String?) ?? rec.originalName,
          originalPath: (meta['path'] as String?) ?? rec.originalPath,
          isFolder: rec.isFolder,
        );
        await raf1.close();
        await temp.delete();

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
      }
    }

    if (allOk) {
      await _writeV2Params(newPassword);
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
    return _V2Params(
      salt: salt,
      memory: _defaultMem,
      iterations: _defaultIter,
      parallelism: _defaultPar,
    );
  }

  // ── 加密（写 V2） ─────────────────────────────────────────────────────────

  static Future<VaultFileRecord> _encryptRawToVault({
    required RandomAccessFile source,
    required int length,
    required String password,
    required String originalName,
    required String originalPath,
    required bool isFolder,
  }) async {
    final params = await _getV2Params(password);
    final vk = await _deriveV2Keys(
        password, params.salt, params.memory, params.iterations, params.parallelism);

    final vaultDir = await getVaultDir();
    final scrambledPath = p.join(vaultDir.path, '${_randomId()}.zvn');
    final out = File(scrambledPath).openWrite();

    // 文件头
    out.add(utf8.encode(_v2Magic));
    out.add([_v2Version]);
    out.add(params.salt);
    out.add(_encodeParams(params.memory, params.iterations, params.parallelism));

    // 元数据（metadataKey 加密，全混淆）
    final metaMap = {
      'name': originalName,
      'path': originalPath,
      'size': length,
      'isFolder': isFolder,
      'lockedAt': DateTime.now().toIso8601String(),
      'version': _v2Version,
    };
    final metaBytes = utf8.encode(jsonEncode(metaMap));
    final metaNonce = _randomBytes(_nonceLength);
    final metaSb =
        await _gcm.encrypt(metaBytes, secretKey: SecretKey(vk.metadataKey), nonce: metaNonce);
    out.add(metaNonce);
    out.add(_u32(metaSb.cipherText.length + metaSb.mac.bytes.length));
    out.add(metaSb.concatenation(nonce: false));

    // 负载（payloadKey 整文件分块流式加密）
    int offset = 0;
    while (offset < length) {
      final n = min(_chunkSize, length - offset);
      final chunk = await source.read(n);
      final nonce = _randomBytes(_nonceLength);
      final sb =
          await _gcm.encrypt(chunk, secretKey: SecretKey(vk.payloadKey), nonce: nonce);
      out.add(nonce);
      out.add(sb.concatenation(nonce: false));
      offset += n;
    }
    await out.close();

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
    final length = await file.length();

    final raf = await file.open(mode: FileMode.read);
    try {
      final rec = await _encryptRawToVault(
        source: raf,
        length: length,
        password: password,
        originalName: originalName,
        originalPath: originalPath,
        isFolder: isFolder,
      );
      await raf.close();
      await file.delete();
      final records = await loadRecords();
      records.add(rec);
      await saveRecords(records);
      return rec;
    } catch (e) {
      await raf.close();
      rethrow;
    }
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

    final archive = Archive();
    await for (final entity in directory.list(recursive: true)) {
      if (entity is File) {
        final relPath =
            p.relative(entity.path, from: p.dirname(originalPath)).replaceAll('\\', '/');
        final bytes = await entity.readAsBytes();
        archive.addFile(ArchiveFile(relPath, bytes.length, bytes));
      }
    }
    final zipBytes = ZipEncoder().encode(archive);
    if (zipBytes == null) {
      throw Exception('Failed to zip directory contents');
    }

    final tempDir = await getTemporaryDirectory();
    final tempZipFile =
        File(p.join(tempDir.path, 'temp_vault_zip_${DateTime.now().millisecondsSinceEpoch}.zip'));
    await tempZipFile.writeAsBytes(zipBytes);

    try {
      final raf = await tempZipFile.open(mode: FileMode.read);
      final rec = await _encryptRawToVault(
        source: raf,
        length: zipBytes.length,
        password: password,
        originalName: originalName,
        originalPath: originalPath,
        isFolder: true,
      );
      await raf.close();
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

    final raf = await scrambledFile.open();
    final magic = utf8.decode(await _readBytes(raf, _v2Magic.length));
    await raf.setPosition(0);

    if (magic == _v1Magic) {
      final r = await _decryptV1(record, password);
      await raf.close();
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

    // V2
    IOSink sink;
    File? tempZip;
    if (record.isFolder) {
      final td = await getTemporaryDirectory();
      tempZip = File(p.join(td.path, 'temp_vault_unzip_${record.id}.zip'));
      sink = tempZip.openWrite();
    } else {
      final originalFile = File(record.originalPath);
      await originalFile.parent.create(recursive: true);
      sink = originalFile.openWrite();
    }
    try {
      await _decryptV2ToSink(raf, password, sink);
      await sink.close();
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
      await raf.close();
      try {
        await sink.close();
      } catch (_) {}
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

    final raf = await scrambledFile.open();
    final magic = utf8.decode(await _readBytes(raf, _v2Magic.length));
    await raf.setPosition(0);
    final cacheDir = await getTemporaryDirectory();
    final ext = record.isFolder ? '.zip' : '';

    if (magic == _v1Magic) {
      final r = await _decryptV1(record, password);
      await raf.close();
      final temp =
          File(p.join(cacheDir.path, 'temp_vault_${record.id}_${record.originalName}$ext'));
      await temp.writeAsBytes(r.bytes);
      return temp;
    }

    final temp =
        File(p.join(cacheDir.path, 'temp_vault_${record.id}_${record.originalName}$ext'));
    final sink = temp.openWrite();
    try {
      await _decryptV2ToSink(raf, password, sink);
      await sink.close();
    } finally {
      await raf.close();
    }
    return temp;
  }

  // ── 底层解密实现 ──────────────────────────────────────────────────────────

  /// V2 解密：从 raf 当前位置读取头 + 元数据 + 负载，流式写入 [sink]，返回元数据 Map。
  static Future<Map<String, dynamic>> _decryptV2ToSink(
    RandomAccessFile raf,
    String password,
    IOSink sink,
  ) async {
    // 头：magic(14) + version(1) + salt(16) + params(6)
    final magic = utf8.decode(await _readBytes(raf, _v2Magic.length));
    if (magic != _v2Magic) throw Exception('Invalid vault file format (Magic tag mismatch)');
    await _readBytes(raf, 1); // version
    final salt = await _readBytes(raf, _saltLength);
    final paramsB = await _readBytes(raf, 6);
    final memory = _readU32(paramsB.sublist(0, 4));
    final iterations = paramsB[4];
    final parallelism = paramsB[5];

    final vk = await _deriveV2Keys(password, salt, memory, iterations, parallelism);

    // 元数据块
    final metaNonce = await _readBytes(raf, _nonceLength);
    final metaLen = _readU32(await _readBytes(raf, 4));
    final metaConcat = await _readBytes(raf, metaLen);
    final metaSb = SecretBox.fromConcatenation(
        metaNonce + metaConcat, nonceLength: _nonceLength, macLength: _tagLength, copy: true);
    final metaBytes = await _gcm.decrypt(metaSb,
        secretKey: SecretKey(vk.metadataKey));
    final meta = jsonDecode(utf8.decode(metaBytes)) as Map<String, dynamic>;

    // 负载分块解密
    while (true) {
      final nonceB = await _readBytes(raf, _nonceLength);
      if (nonceB.length < _nonceLength) break;
      final ctMac = await _readBytes(raf, _chunkSize + _tagLength);
      if (ctMac.isEmpty) break;
      final sb = SecretBox.fromConcatenation(
          nonceB + ctMac, nonceLength: _nonceLength, macLength: _tagLength, copy: true);
      final pt = await _gcm.decrypt(sb,
          secretKey: SecretKey(vk.payloadKey));
      sink.add(pt);
    }
    return meta;
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
    for (int i = 0; i < n; i++) {
      out[i] = _secureRandom.nextInt(256);
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
