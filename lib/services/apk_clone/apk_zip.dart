import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';

/// APK ZIP 重写器（纯 Dart）。
///
/// 从原始 APK 解析全部条目后重排输出：
///  - `resources.arsc` → **STORED + 4 字节对齐**（Android 11+ 对 targetSdk≥30
///    的 APK 硬性要求 arsc 未压缩且对齐，archive 库的 ZipEncoder 无法控制
///    对齐，故输出端自写）；
///  - `AndroidManifest.xml` → 按调用方改写后重压缩；
///  - **其余条目 → 原样复用源包的压缩流**（不重压）。这样克隆体积与源包
///    基本一致——源包用什么压缩级别/是否 STORED，克隆包就保持原样，避免
///    「换一级压缩导致体积漂移」（曾出现本应用 74→45MB、汽水音乐 122→131MB
///    的双向漂移）；同时省掉对全部条目的解压+重压，克隆速度大幅提升；
///  - `META-INF/` 下旧签名产物 → 丢弃（由后续 APK Signature Scheme v2 重签）。
///
/// 注意：源包里 STORED 的 native lib 复用后不再保证页对齐，因此引擎侧
/// 必须同步把 manifest 的 `extractNativeLibs` 强制为 true（见
/// `_ensureExtractNativeLibs`），否则未对齐的未压缩 .so 会被安装器拒收。
///
/// 对齐通过 local file header 的 **extra field padding** 实现（与 zipalign
/// 相同的做法），central directory 写入**完全相同**的 extra —— Android 的
/// 安装器会校验 local/central 头一致性，extra 不一致会被拒装。
class ApkZipOutput {
  final Uint8List bytes;

  /// 中央目录起始偏移（v2 签名的 section 1/2 边界）。
  final int centralDirOffset;

  /// 中央目录之后、EOCD 之前的偏移约定（v2 签名需要 3 段边界）。
  final int eocdOffset;

  const ApkZipOutput({
    required this.bytes,
    required this.centralDirOffset,
    required this.eocdOffset,
  });
}

class _Entry {
  final String name;

  /// 未压缩内容（decode 路径：manifest / arsc / raw 兜底失败时）。
  final Uint8List? data;

  /// 源包的原始压缩流（reuse 路径；非 null 时直接写入，不重压）。
  final Uint8List? raw;

  /// raw 路径的压缩方法（0=STORE / 8=DEFLATE）。
  final int rawMethod;

  /// raw 路径的原始 CRC32 与未压缩大小。
  final int rawCrc;
  final int rawSize;

  final bool align4; // 写入时做 4 字节对齐（extra field padding）

  /// decode 路径是否 STORED 写出。
  final bool decodeStored;

  _Entry.decode(
    this.name,
    this.data, {
    required bool stored,
    required this.align4,
  }) : raw = null,
       rawMethod = 0,
       rawCrc = 0,
       rawSize = 0,
       decodeStored = stored;

  _Entry.raw(
    this.name,
    this.raw, {
    required this.rawMethod,
    required this.rawCrc,
    required this.rawSize,
  }) : data = null,
       align4 = false,
       decodeStored = false;
}

class ApkZipRewriter {
  /// 解析原始 APK 并返回重排后的 ZIP。
  ///
  /// [rewriteEntry] 允许调用方按条目名改写内容（如 manifest / arsc），
  /// 返回 null 表示内容不变。
  ///
  /// [recompressStoredEntry] 命中的 **STORED** 条目改走 decode → DEFLATE
  /// 重压路径（体积收益来自未压缩的 native lib / PNG / tflite 等）。
  /// 仅对 method==STORE 的条目生效——已 DEFLATE 的条目重压只会漂移甚至
  /// 反弹（汽水音乐 122→131MB 的教训），一律原样复用；`resources.arsc`
  /// 由 needRewrite 路径接管（保持 STORED+对齐），调用方无需排除。
  static ApkZipOutput rewrite(
    Uint8List sourceApk, {
    Uint8List? Function(String name, List<int> data)? rewriteEntry,
    bool Function(String name)? recompressStoredEntry,
  }) {
    final archive = ZipDecoder().decodeBytes(sourceApk, verify: false);
    final entries = <_Entry>[];
    for (final f in archive.files) {
      if (!f.isFile) continue;
      final name = f.name;
      // 旧 v1 签名产物全部丢弃（含 META-INF 下的 SF/RSA/DSA/EC/MF）。
      if (_isSignatureFile(name)) continue;

      final needRewrite =
          name == 'AndroidManifest.xml' || name == 'resources.arsc';
      if (needRewrite) {
        final data = Uint8List.fromList(f.content as List<int>);
        final rewritten = rewriteEntry?.call(name, data);
        final useData = rewritten ?? data;
        final isArsc = name == 'resources.arsc';
        entries.add(
          _Entry.decode(name, useData, stored: isArsc, align4: isArsc),
        );
        continue;
      }

      // STORED 条目按调用方指令重压（decode → DEFLATE）。
      if ((recompressStoredEntry?.call(name) ?? false) &&
          (f.compressionType ?? 8) == 0) {
        final data = Uint8List.fromList(f.content as List<int>);
        entries.add(_Entry.decode(name, data, stored: false, align4: false));
        continue;
      }

      // 其余条目：优先原样复用源包压缩流（method 仅支持 STORE/DEFLATE）。
      final method = f.compressionType ?? 8;
      Uint8List? raw;
      if (method == 0 || method == 8) {
        try {
          final rc = f.rawContent;
          final bytes = rc?.readBytes(rc.length);
          if (bytes != null && bytes.length > 0) {
            raw = bytes.toUint8List();
          }
        } catch (_) {
          raw = null;
        }
      }
      if (raw != null) {
        entries.add(
          _Entry.raw(
            name,
            raw,
            rawMethod: method,
            rawCrc: f.crc32 ?? crc32(raw),
            rawSize: f.size,
          ),
        );
      } else {
        // 兜底：解压后按 DEFLATE 重压（罕见压缩方法的条目）。
        final data = Uint8List.fromList(f.content as List<int>);
        entries.add(_Entry.decode(name, data, stored: false, align4: false));
      }
    }

    // --- 序列化 ---
    final out = BytesBuilder();
    final centralRecords = <Uint8List>[];

    for (final e in entries) {
      Uint8List comp;
      int method;
      int crc;
      int uncompLen;
      if (e.raw != null) {
        comp = e.raw!;
        method = e.rawMethod;
        crc = e.rawCrc;
        uncompLen = e.rawSize;
      } else if (e.decodeStored) {
        comp = e.data!;
        method = 0;
        crc = crc32(e.data!);
        uncompLen = e.data!.length;
      } else {
        final codec = ZLibCodec(raw: true, level: 6);
        comp = Uint8List.fromList(codec.encoder.convert(e.data!));
        method = 8;
        crc = crc32(e.data!);
        uncompLen = e.data!.length;
      }
      final nameBytes = utf8OrLatin(e.name);

      // 对齐：让 entry **数据**的起始偏移落在 4 的倍数上。
      Uint8List extra = Uint8List(0);
      if (e.align4) {
        final dataStartNoExtra =
            out.length + 30 + nameBytes.length + 4; // 4 = 最小 extra 头
        final pad = (4 - (dataStartNoExtra % 4)) % 4;
        final bd = ByteData(4 + pad);
        bd.setUint16(0, 0x0000, Endian.little); // 未知 extra id，解析器会跳过
        bd.setUint16(2, pad, Endian.little);
        extra = bd.buffer.asUint8List();
      }

      final lfhOffset = out.length;
      final lfh = ByteData(30);
      lfh.setUint32(0, 0x04034b50, Endian.little);
      lfh.setUint16(4, 20, Endian.little); // version needed
      lfh.setUint16(6, 0, Endian.little); // flags
      lfh.setUint16(8, method, Endian.little);
      lfh.setUint16(10, 0, Endian.little); // mod time
      lfh.setUint16(12, 0x21, Endian.little); // mod date (1980-1-1)
      lfh.setUint32(14, crc, Endian.little);
      lfh.setUint32(18, comp.length, Endian.little);
      lfh.setUint32(22, uncompLen, Endian.little);
      lfh.setUint16(26, nameBytes.length, Endian.little);
      lfh.setUint16(28, extra.length, Endian.little);
      out.add(lfh.buffer.asUint8List());
      out.add(nameBytes);
      if (extra.isNotEmpty) out.add(extra);
      out.add(comp);

      // central directory record（extra 与 local 完全一致）
      final cd = ByteData(46);
      cd.setUint32(0, 0x02014b50, Endian.little);
      cd.setUint16(4, 20, Endian.little); // version made by
      cd.setUint16(6, 20, Endian.little); // version needed
      cd.setUint16(8, 0, Endian.little);
      cd.setUint16(10, method, Endian.little);
      cd.setUint16(12, 0, Endian.little);
      cd.setUint16(14, 0x21, Endian.little);
      cd.setUint32(16, crc, Endian.little);
      cd.setUint32(20, comp.length, Endian.little);
      cd.setUint32(24, uncompLen, Endian.little);
      cd.setUint16(28, nameBytes.length, Endian.little);
      cd.setUint16(30, extra.length, Endian.little);
      cd.setUint16(32, 0, Endian.little); // comment len
      cd.setUint16(34, 0, Endian.little); // disk number
      cd.setUint16(36, 0, Endian.little); // internal attrs
      cd.setUint32(38, 0, Endian.little); // external attrs
      cd.setUint32(42, lfhOffset, Endian.little);
      final rec = BytesBuilder();
      rec.add(cd.buffer.asUint8List());
      rec.add(nameBytes);
      if (extra.isNotEmpty) rec.add(extra);
      centralRecords.add(rec.toBytes());
    }

    final centralDirOffset = out.length;
    for (final rec in centralRecords) {
      out.add(rec);
    }
    final centralSize = out.length - centralDirOffset;
    final eocdOffset = out.length;

    final eocd = ByteData(22);
    eocd.setUint32(0, 0x06054b50, Endian.little);
    eocd.setUint16(8, entries.length, Endian.little);
    eocd.setUint16(10, entries.length, Endian.little);
    eocd.setUint32(12, centralSize, Endian.little);
    eocd.setUint32(16, centralDirOffset, Endian.little);
    eocd.setUint16(20, 0, Endian.little); // comment len
    out.add(eocd.buffer.asUint8List());

    return ApkZipOutput(
      bytes: out.toBytes(),
      centralDirOffset: centralDirOffset,
      eocdOffset: eocdOffset,
    );
  }

  static bool _isSignatureFile(String name) {
    final upper = name.toUpperCase();
    if (!upper.startsWith('META-INF/')) return false;
    return upper.endsWith('.SF') ||
        upper.endsWith('.RSA') ||
        upper.endsWith('.DSA') ||
        upper.endsWith('.EC') ||
        upper.endsWith('.MF');
  }

  static Uint8List utf8OrLatin(String name) {
    // APK 条目名总是 ASCII/UTF-8（ZIP 规范未设 UTF-8 flag 时按 CP437，
    // 但 APK 生态统一 UTF-8；这里条目名不含非 ASCII，直接 utf8 编码即可）。
    return Uint8List.fromList(name.codeUnits);
  }
}

/// CRC-32（IEEE 802.3，查表法）。
int crc32(List<int> data) {
  final table = _crcTable ??= _buildCrcTable();
  var crc = 0xFFFFFFFF;
  for (final b in data) {
    crc = table[(crc ^ b) & 0xFF] ^ (crc >> 8);
  }
  return (crc ^ 0xFFFFFFFF) & 0xFFFFFFFF;
}

List<int>? _crcTable;

List<int> _buildCrcTable() {
  final table = List<int>.filled(256, 0);
  for (var i = 0; i < 256; i++) {
    var c = i;
    for (var k = 0; k < 8; k++) {
      c = (c & 1) != 0 ? (0xEDB88320 ^ (c >> 1)) : (c >> 1);
    }
    table[i] = c;
  }
  return table;
}
