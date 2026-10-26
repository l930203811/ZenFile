import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// APK Signature Scheme v2 签名器（纯 Dart，零外部依赖）。
///
/// 结构遵循 Android 官方格式：在 ZIP 条目区与中央目录之间插入
/// `APK Sig Block 42` 签名块（id 0x7109871a），算法 RSA-PKCS1v15-SHA256
/// （0x0103）。摘要覆盖三段：ZIP 条目区 / 中央目录 / EOCD。
///
/// 签名密钥为内置固定密钥（见 [_nHex]/[_dHex]，RSA-2048）：
///  - 所有克隆包同签名 ⇒ 克隆包之间可覆盖升级；
///  - 密钥公开嵌入在开源代码里（与 App Cloner 同类工具一致），不存在安全
///    边界 —— 它只用于让克隆包获得一个「不同于原应用」的稳定身份。
class ApkV2Signer {
  ApkV2Signer._();

  static const String _kSigBlockMagic = 'APK Sig Block 42';

  /// RSA-PKCS1v15-SHA256 的 v2 算法 id。
  static const int _kAlgRsaPkcs1Sha256 = 0x0103;

  /// APK Signing Block v2 的 pair id。
  static const int _kSigningBlockId = 0x7109871a;

  // 内置克隆签名密钥（openssl 生成，PKCS#8 拆出的模数/私钥指数）。
  static const String _nHex =
      '00c0485e33195ea32deea2f0cbf1430ba0c7939a2b208266a927e9aef03e4a21'
      '35625cfce675da14f4b3ff711a8109b47c3cc04472b1d6bae6f76daadd201472'
      'ca7bb4d5d0615591013e9313f2efae1d38b0d24c0fcc25ed88f2054d771af2e5'
      'c57dfbb3257c4080c2824fe484835f47a85dd66313ff79b254b14632a456005b'
      '765329b9610f6925080e4334e367da47f3332f5a183175d8bb2302bbd92a1a57'
      '5f10b09ef35f98dd85010f729f22ce44f670146eec8e9a82c4ce80bfd88eb60b'
      '75ad16b31166af56af1fc93eb032573cbc6f469751d22214ab9dc59fa1f46a4f'
      'bf018c1e5eca5a44421644c04f2b6221d74be63512db33484362d8056549d450'
      'b9';

  static const String _dHex =
      '0b9fd4620e749434e0aa65184f3b98665dea64759aff87294eca67d30a50fcf4'
      'f73f5be2aad9464f0cdab281c1af4e83fc403b631bb1399760f9f64c6bf61082'
      '813c0b790f8956bcd68599bd2414489bf6c49fe88c94f66943086308824e90e9'
      '819647dc4a48b4000e54ba21f0b73fe3c3d88420df5f0212f0aca7bf1b9be5eb'
      '846913ba35b018c77189ecef702ece7ed68efb32944b78f5ee86a76f9074e277'
      'de677abca2a3c025f438331776f1b122ffb04578b2c6f81e405cb4baedd26805'
      '5aa829214f8b176c01f7d82e35e7a61fb605bab7fc15d4b99d40e4d7d81477bb'
      '2c4e1174efab83c682d25f5b6e8e425b2a01d22c74675c07be52641549214d49';

  /// 克隆签名证书（X.509 DER，base64）。
  static const String _certB64 =
      'MIIDWTCCAkGgAwIBAgIUIU+HYfeh0Xj0XHgVSfP6Z3WWIlgwDQYJKoZIhvcNAQEL'
      'BQAwOzEaMBgGA1UEAwwRWmVuRmlsZSBBcHAgQ2xvbmUxEDAOBgNVBAoMB1plbkZp'
      'bGUxCzAJBgNVBAYTAkNOMCAXDTI2MTAyNjAwMzkyNVoYDzIwNTYxMDE4MDAzOTI1'
      'WjA7MRowGAYDVQQDDBFaZW5GaWxlIEFwcCBDbG9uZTEQMA4GA1UECgwHWmVuRmls'
      'ZTELMAkGA1UEBhMCQ04wggEiMA0GCSqGSIb3DQEBAQUAA4IBDwAwggEKAoIBAQDA'
      'SF4zGV6jLe6i8MvxQwugx5OaKyCCZqkn6a7wPkohNWJc/OZ12hT0s/9xGoEJtHw8'
      'wERysda65vdtqt0gFHLKe7TV0GFVkQE+kxPy764dOLDSTA/MJe2I8gVNdxry5cV9'
      '+7MlfECAwoJP5ISDX0eoXdZjE/95slSxRjKkVgBbdlMpuWEPaSUIDkM042faR/Mz'
      'L1oYMXXYuyMCu9kqGldfELCe81+Y3YUBD3KfIs5E9nAUbuyOmoLEzoC/2I62C3Wt'
      'FrMRZq9Wrx/JPrAyVzy8b0aXUdIiFKudxZ+h9GpPvwGMHl7KWkRCFkTATytiIddL'
      '5jUS2zNIQ2LYBWVJ1FC5AgMBAAGjUzBRMB0GA1UdDgQWBBQq7f1WSPlBQBIGKT4W'
      'KvnbIQsMbjAfBgNVHSMEGDAWgBQq7f1WSPlBQBIGKT4WKvnbIQsMbjAPBgNVHRMB'
      'Af8EBTADAQH/MA0GCSqGSIb3DQEBCwUAA4IBAQAnXtT5aAgaV4whn8kYb87BnTYB'
      'MPiikvpH+3Z/T02p5AZvoyI1nEUkSXwdwi5QWl3UXIXNPFn1Znimds0HBEfRrh8i'
      'QlYvN7DymoUoOM8jWZrpdRnFLCW3BaH2EOyGo5rVGu4j/Mv8PpP7xqxjRhmp6JOV'
      'SmQ89PLmfIfICKr1mYOjIwY78+GCR8tNGXi94k+/7YEePGKmjFbJ7i6dFusJrLt2'
      '42k7JRtZoG6pm8/Z6g+MVftejFmLgFe1uYw3rEM6ZeyiyTnprvgD940z/VSvKp5s'
      '4N5dxnd1sf7FaGGDZilQoSEaOhylGVmdFovcKuPOUo1wt0JM1vHuzciyz+lo';

  /// SubjectPublicKeyInfo（X.509 SPKI DER，base64），v2 块的 public key 字段。
  static const String _spkiB64 =
      'MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAwEheMxleoy3uovDL8UML'
      'oMeTmisggmapJ+mu8D5KITViXPzmddoU9LP/cRqBCbR8PMBEcrHWuub3bardIBRyy'
      'nu01dBhVZEBPpMT8u+uHTiw0kwPzCXtiPIFTXca8uXFffuzJXxAgMKCT+SEg19Hq'
      'F3WYxP/ebJUsUYypFYAW3ZTKblhD2klCA5DNONn2kfzMy9aGDF12LsjArvZKhpXX'
      'xCwnvNfmN2FAQ9ynyLORPZwFG7sjpqCxM6Av9iOtgt1rRazEWavVq8fyT6wMlc8v'
      'G9Gl1HSIhSrncWfofRqT78BjB5eylpEQhZEwE8rYiHXS+Y1EtszSENi2AVlSdRQu'
      'QIDAQAB';

  /// 对未签名的 [apk]（完整 ZIP，含 EOCD）插入 v2 签名块。
  ///
  /// [centralDirOffset] / [eocdOffset] 来自 [ApkZipRewriter] 的输出，
  /// 决定三段的边界；签名块插入后这些偏移会整体平移，函数会同步修正
  /// 中央目录里的 local header 偏移与 EOCD。
  static Uint8List sign(
    Uint8List apk, {
    required int centralDirOffset,
    required int eocdOffset,
  }) {
    final block = _buildSigningBlock(apk, centralDirOffset, eocdOffset);

    // 签名块插在 ZIP 条目区（section 1）之后、中央目录（section 2）之前：
    //  - section 1 的所有 local header 位置**不变** ⇒ 中央目录里记录的
    //    local header 偏移**不需要修正**；
    //  - 唯一要改的是 EOCD 里的中央目录起始偏移（+block.length）。
    final delta = block.length;
    final out = BytesBuilder();
    out.add(apk.sublist(0, centralDirOffset));
    out.add(block);
    out.add(apk.sublist(centralDirOffset, eocdOffset));

    // EOCD：修正中央目录偏移。
    final eocd = Uint8List.sublistView(apk, eocdOffset);
    final patchedEocd = Uint8List.fromList(eocd);
    final bd = ByteData.sublistView(patchedEocd);
    final oldOffset = bd.getUint32(16, Endian.little);
    bd.setUint32(16, oldOffset + delta, Endian.little);
    out.add(patchedEocd);

    return out.toBytes();
  }

  static Uint8List _buildSigningBlock(
      Uint8List apk, int centralDirOffset, int eocdOffset) {
    // ---- 1. 三段摘要 ----
    final digest = _computeDigest(apk, centralDirOffset, eocdOffset);

    // ---- 2. signed data = digests + certificates + additional attributes ----
    final cert = base64Decode(_certB64);
    // digests / signatures 字段 = u32 长度前缀的「条目序列」，每个条目自身
    // 也是 u32 长度前缀（u32 算法 id + u32 长度前缀的 digest/signature）。
    final digests = _lpBytes(
        _lpBytes(_encodeDigestPair(_kAlgRsaPkcs1Sha256, digest)));
    final certificates = _lpBytes(_lpBytes(cert));
    const additionalAttrs = <int>[];
    final signedData = BytesBuilder();
    signedData.add(digests);
    signedData.add(certificates);
    signedData.add(_lpBytes(additionalAttrs));
    final signedDataBytes = signedData.toBytes();

    // ---- 3. RSA 签名 ----
    final signature = _rsaSignPkcs1Sha256(signedDataBytes);
    final signatures = _lpBytes(
        _lpBytes(_encodeSignaturePair(_kAlgRsaPkcs1Sha256, signature)));

    // ---- 4. signer 序列 ----
    final spki = base64Decode(_spkiB64);
    final signer = BytesBuilder();
    signer.add(_lpBytes(signedDataBytes));
    signer.add(signatures);
    signer.add(_lpBytes(spki));
    final signerValue = signer.toBytes();
    final signers = _lpBytes(_lpBytes(signerValue));

    // ---- 5. 组装签名块 ----
    // ID-value pair 格式：u64 长度（= 4 + value 长度）+ u32 id + value。
    final pairValue = signers;
    final pair = BytesBuilder();
    final pairBd = ByteData(12)
      ..setUint64(0, 4 + pairValue.length, Endian.little)
      ..setUint32(8, _kSigningBlockId, Endian.little);
    pair.add(pairBd.buffer.asUint8List());
    pair.add(pairValue);
    final pairs = pair.toBytes();

    // block: u64 size + pairs + u64 size + magic(16)
    // size 字段的值 = 不含第一个 size 字段本身的块长。
    final blockSize = pairs.length + 8 + 16;
    final bd = ByteData(8 + pairs.length + 8 + 16);
    var p = 0;
    bd.setUint64(p, blockSize, Endian.little);
    p += 8;
    bd.buffer.asUint8List().setAll(p, pairs);
    p += pairs.length;
    bd.setUint64(p, blockSize, Endian.little);
    p += 8;
    final magic = utf8.encode(_kSigBlockMagic);
    bd.buffer.asUint8List().setAll(p, magic);
    return bd.buffer.asUint8List();
  }

  /// v2 摘要（CHUNKED_SHA256，与 apksig 逐字节一致）：
  ///  - 输入三段：条目区（含 4KB 对齐填充）/ 中央目录 / EOCD（其 CD offset
  ///    字段 = 签名块起点 = 条目区总长；未签名 APK 中该字段恰为条目区原长）；
  ///  - **三段各自独立按 1MB 分块**（apksig ChunkSupplier 语义：每段从自身
  ///    0 偏移切块，块不跨段合并）；
  ///  - 每个 chunk 计算前加 5 字节前缀：0xa5 + u32(chunk 字节数,
  ///    little-endian)（apksig ChunkDigester 写入的是 chunk 长度，非索引）；
  ///  - 最终摘要 = SHA-256([0x5a, u32LE(chunk 总数)] + 所有 chunk 摘要串联)。
  static Uint8List _computeDigest(
      Uint8List apk, int centralDirOffset, int eocdOffset) {
    // EOCD 的 CD offset 字段在签名后 = centralDirOffset + 签名块长；验证端
    // 会把它重写回签名块起点（= centralDirOffset，即未签名文件的值）。
    // 因此摘要输入第三段 = 原 EOCD 原样。
    final sections = <Uint8List>[
      Uint8List.sublistView(apk, 0, centralDirOffset),
      Uint8List.sublistView(apk, centralDirOffset, eocdOffset),
      Uint8List.sublistView(apk, eocdOffset),
    ];

    const chunkSize = 1048576;
    final chunkDigests = BytesBuilder();
    // 聚合输入以 5 字节头开始：0x5a + u32LE(chunk 总数)（apksig ChunkDigests
    // 的 concatOfDigestsOfChunks 布局）。
    final chunkCount = sections.fold<int>(
        0, (n, s) => n + (s.length + chunkSize - 1) ~/ chunkSize);
    final header = ByteData(5)
      ..setUint8(0, 0x5a)
      ..setUint32(1, chunkCount, Endian.little);
    chunkDigests.add(header.buffer.asUint8List());
    for (final section in sections) {
      for (var off = 0; off < section.length; off += chunkSize) {
        final take = (off + chunkSize) < section.length
            ? chunkSize
            : (section.length - off);
        final prefix = ByteData(5)
          ..setUint8(0, 0xa5)
          ..setUint32(1, take, Endian.little);
        final input = BytesBuilder()
          ..add(prefix.buffer.asUint8List())
          ..add(Uint8List.sublistView(section, off, off + take));
        chunkDigests.add(sha256.convert(input.toBytes()).bytes);
      }
    }
    return Uint8List.fromList(
        sha256.convert(chunkDigests.toBytes()).bytes);
  }

  static Uint8List _encodeDigestPair(int algId, Uint8List digest) {
    final bd = BytesBuilder();
    final algBd = ByteData(4)..setUint32(0, algId, Endian.little);
    bd.add(algBd.buffer.asUint8List());
    bd.add(_lpBytes(digest));
    return bd.toBytes();
  }

  static Uint8List _encodeSignaturePair(int algId, Uint8List sig) {
    // 与 digest pair 结构一致：u32 算法 + 长度前缀签名。
    return _encodeDigestPair(algId, sig);
  }

  /// u32 长度前缀。
  static Uint8List _lpBytes(List<int> data) {
    final bd = ByteData(4 + data.length);
    bd.setUint32(0, data.length, Endian.little);
    bd.buffer.asUint8List().setAll(4, data);
    return bd.buffer.asUint8List();
  }

  // ------------------------------------------------------------------
  // RSA PKCS#1 v1.5 签名（SHA-256），纯 BigInt 实现
  // ------------------------------------------------------------------

  static Uint8List _rsaSignPkcs1Sha256(Uint8List message) {
    final digest = Uint8List.fromList(sha256.convert(message).bytes);
    // EMSA-PKCS1-v1_5: 0x00 0x01 FF..FF 0x00 || DigestInfo || hash
    // DigestInfo(SHA-256) 前缀（DER）：3051300d060960864801650304020105000420
    const digestInfoPrefix = <int>[
      0x30, 0x31, 0x30, 0x0d, 0x06, 0x09, 0x60, 0x86, 0x48, 0x01, //
      0x65, 0x03, 0x04, 0x02, 0x01, 0x05, 0x00, 0x04, 0x20,
    ];
    final n = BigInt.parse(_nHex, radix: 16);
    final d = BigInt.parse(_dHex, radix: 16);
    final k = 256; // 模长字节数（2048 位）

    final tLen = digestInfoPrefix.length + digest.length;
    if (k - tLen - 3 < 8) {
      throw StateError('RSA key too small for signature');
    }
    final em = BytesBuilder();
    em.addByte(0x00);
    em.addByte(0x01);
    for (var i = 0; i < k - tLen - 3; i++) {
      em.addByte(0xFF);
    }
    em.addByte(0x00);
    em.add(digestInfoPrefix);
    em.add(digest);
    final m = BigInt.parse(_toHex(em.toBytes()), radix: 16);
    final s = m.modPow(d, n);
    final hex = _toHexPadded(s, k);
    return Uint8List.fromList(hex);
  }

  static String _toHex(List<int> bytes) =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  static List<int> _toHexPadded(BigInt value, int byteLen) {
    var hex = value.toRadixString(16);
    if (hex.length.isOdd) hex = '0$hex';
    final target = byteLen * 2;
    if (hex.length > target) hex = hex.substring(hex.length - target);
    while (hex.length < target) {
      hex = '0$hex';
    }
    final out = List<int>.filled(byteLen, 0);
    for (var i = 0; i < byteLen; i++) {
      out[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return out;
  }
}
