import 'dart:convert';
import 'dart:typed_data';

/// resources.arsc 改写（纯 Dart）。
///
/// 两类改写：
/// 1. ResTablePackage(0x0200) 头部的包名（定长 256 字节 UTF-16 数组，原地覆盖）。
/// 2. 全局字符串池（ResTable 内第一个子 chunk，0x0001）中的字符串值——
///    个别应用的 provider `android:authorities` 以资源引用形式写入
///    （@string/xxx），真实值存在字符串池里，AXML 层改不到，必须在这里
///    改写，否则安装报「软件包冲突」。
///
/// 字符串池重建后 chunk 大小会变化 ⇒ 其后所有 chunk 位移。安全性依据：
/// 表内偏移全部是**相对偏移**——ResTable_package 的 typeStrings/keyStrings
/// 相对 package chunk 起点计数，字符串引用一律走索引。唯一需要同步修正
/// 的是 ResTable 头部的总 size 字段。
class ArscRewriter {
  /// 把 [bytes] 中所有 package 的名称改为 [newPackage]，并把全局字符串池中
  /// 等于 [originalPackage] 或以其为前缀的字符串改写为新包名。
  ///
  /// 返回新的字节数组；结构异常或无需改动时原样返回。
  static Uint8List rewrite(
    Uint8List bytes,
    String originalPackage,
    String newPackage,
  ) {
    final bd = ByteData.sublistView(bytes);
    if (bd.getUint16(0, Endian.little) != 0x0002) return bytes;

    // ResTable 是唯一顶层 chunk；package(0x0200) 与全局字符串池(0x0001)
    // 都是它的**子 chunk**，从表头之后开始遍历。
    final tableHeaderSize = bd.getUint16(2, Endian.little);
    int off = tableHeaderSize;
    var changed = false;
    while (off + 8 <= bytes.length) {
      final type = bd.getUint16(off, Endian.little);
      final size = bd.getUint32(off + 4, Endian.little);
      if (size < 8 || off + size > bytes.length) break;
      if (type == 0x0200) {
        // ResTablePackage: header(8) + id(4) + name(128 * u16) + ...
        _writePackageName(bd, off + 12, newPackage);
        changed = true;
      }
      off += size;
    }
    if (!changed) return bytes;

    final pooled = _rewriteGlobalStringPool(bytes, originalPackage, newPackage);
    return pooled ?? bytes;
  }

  /// 改写全局字符串池中含原包名的字符串值。
  /// 无需改动时返回 null（调用方沿用原字节）。
  static Uint8List? _rewriteGlobalStringPool(
    Uint8List bytes,
    String originalPackage,
    String newPackage,
  ) {
    final bd = ByteData.sublistView(bytes);
    // ResTable 头固定 12 字节，其后第一个子 chunk 即全局字符串池。
    const poolBase = 12;
    if (bd.getUint16(0, Endian.little) != 0x0002) return null;
    if (bd.getUint16(poolBase, Endian.little) != 0x0001) return null;

    final headerSize = bd.getUint16(poolBase + 2, Endian.little);
    final chunkSize = bd.getUint32(poolBase + 4, Endian.little);
    final stringCount = bd.getUint32(poolBase + 8, Endian.little);
    final styleCount = bd.getUint32(poolBase + 12, Endian.little);
    final flags = bd.getUint32(poolBase + 16, Endian.little);
    final stringsStart = bd.getUint32(poolBase + 20, Endian.little);
    final stylesStart = bd.getUint32(poolBase + 24, Endian.little);
    final isUtf8 = (flags & 0x100) != 0;
    if (chunkSize <= 0 || poolBase + chunkSize > bytes.length) return null;

    // 解码全部字符串。
    final offsets = List<int>.filled(stringCount, 0);
    final strings = List<String?>.filled(stringCount, null);
    var dirty = false;
    for (var i = 0; i < stringCount; i++) {
      offsets[i] = bd.getUint32(poolBase + headerSize + i * 4, Endian.little);
      final abs = poolBase + stringsStart + offsets[i];
      strings[i] = _decodeString(bd, abs, isUtf8);
      final s = strings[i]!;
      if (s == originalPackage || s.startsWith('$originalPackage.')) {
        strings[i] = s == originalPackage
            ? newPackage
            : newPackage + s.substring(originalPackage.length);
        dirty = true;
      }
    }
    if (!dirty) return null;

    // 重新编码 + 重建偏移表。
    final encoded = <Uint8List>[];
    final newOffsets = List<int>.filled(stringCount, 0);
    var rawDataLen = 0;
    for (var i = 0; i < stringCount; i++) {
      newOffsets[i] = rawDataLen;
      final enc = _encodeString(strings[i]!, isUtf8);
      encoded.add(enc);
      rawDataLen += enc.length;
    }

    // 偏移区 = 字符串偏移表(stringCount) + 样式偏移表(styleCount)，共
    // (stringCount+styleCount)*4 字节；其后才是字符串数据。两者都必须
    // 4 字节对齐，否则后续数据错位、Android 报「style offsets extend
    // past style data start」。
    final offsetTableBytes = (stringCount + styleCount) * 4;
    var dataBase = headerSize + offsetTableBytes;
    dataBase += (4 - (dataBase % 4)) % 4;
    final dataPad = (4 - (rawDataLen % 4)) % 4;

    // 样式区（stylesStart..chunkSize）原样保留：内部相对偏移自洽，
    // span 引用的字符串索引不变。
    final stylesLen = stylesStart > 0 && stylesStart < chunkSize
        ? chunkSize - stylesStart
        : 0;
    final styleOffsetTableLen = styleCount * 4;

    final newChunkSize = dataBase + rawDataLen + dataPad + stylesLen;

    final out = Uint8List(newChunkSize);
    final obd = ByteData.sublistView(out);

    // 头部：类型/头长不变，size/stringsStart 更新，其余字段保留。
    // （out 就是池 chunk 本身，字段偏移相对池起点，不再加 poolBase。）
    out.setRange(0, headerSize, bytes, poolBase);
    obd.setUint16(2, headerSize, Endian.little);
    obd.setUint32(4, newChunkSize, Endian.little);
    obd.setUint32(8, stringCount, Endian.little);
    obd.setUint32(12, styleCount, Endian.little);
    obd.setUint32(20, dataBase, Endian.little);
    if (stylesLen > 0) {
      obd.setUint32(24, dataBase + rawDataLen + dataPad, Endian.little);
    }

    // 字符串偏移表。
    for (var i = 0; i < stringCount; i++) {
      obd.setUint32(headerSize + i * 4, newOffsets[i], Endian.little);
    }
    // 样式偏移表原样复制（紧接字符串偏移表之后）。
    if (styleOffsetTableLen > 0) {
      out.setRange(
        headerSize + stringCount * 4,
        headerSize + stringCount * 4 + styleOffsetTableLen,
        bytes,
        poolBase + headerSize + stringCount * 4,
      );
    }
    var p = dataBase;
    for (final enc in encoded) {
      out.setRange(p, p + enc.length, enc);
      p += enc.length;
    }
    // 数据区尾部对齐补零。
    for (var i = 0; i < dataPad; i++) {
      out[p + i] = 0;
    }
    p += dataPad;
    if (stylesLen > 0) {
      out.setRange(p, p + stylesLen, bytes, poolBase + stylesStart);
    }

    // 拼接：池前字节 + 新池 + 池后字节，并修正 ResTable 总 size。
    final delta = newChunkSize - chunkSize;
    final result = Uint8List(bytes.length + delta);
    result.setRange(0, poolBase, bytes);
    result.setRange(poolBase, poolBase + newChunkSize, out);
    result.setRange(
      poolBase + newChunkSize,
      result.length,
      bytes,
      poolBase + chunkSize,
    );
    final rbd = ByteData.sublistView(result);
    rbd.setUint32(4, rbd.getUint32(4, Endian.little) + delta, Endian.little);
    return result;
  }

  static String _decodeString(ByteData bd, int abs, bool utf8Pool) {
    var p = abs;
    if (utf8Pool) {
      int varint8() {
        final b0 = bd.getUint8(p++);
        if (b0 & 0x80 != 0) {
          return ((b0 & 0x7F) << 8) | bd.getUint8(p++);
        }
        return b0;
      }

      varint8(); // u16 字符数（含代理对计数差异，此处忽略）
      final byteLen = varint8();
      final units = <int>[];
      for (var i = 0; i < byteLen; i++) {
        units.add(bd.getUint8(p + i));
      }
      return utf8.decode(units, allowMalformed: true);
    } else {
      int varint16() {
        final b0 = bd.getUint16(p, Endian.little);
        p += 2;
        if (b0 & 0x8000 != 0) {
          final b1 = bd.getUint16(p, Endian.little);
          p += 2;
          return ((b0 & 0x7FFF) << 16) | b1;
        }
        return b0;
      }

      final u16len = varint16();
      return String.fromCharCodes([
        for (var i = 0; i < u16len; i++) bd.getUint16(p + i * 2, Endian.little),
      ]);
    }
  }

  static Uint8List _encodeString(String s, bool utf8Pool) {
    if (utf8Pool) {
      final u8 = utf8.encode(s);
      final lenHead = _varint8(s.length) + _varint8(u8.length);
      final out = Uint8List(lenHead.length + u8.length + 1);
      var p = 0;
      for (final b in lenHead) {
        out[p++] = b;
      }
      out.setRange(p, p + u8.length, u8);
      out[out.length - 1] = 0;
      return out;
    } else {
      final headLen = s.length < 0x8000 ? 2 : 4;
      final bd = ByteData(headLen + s.length * 2 + 2);
      var p = 0;
      // 长度 varint（1-2 个 u16）。
      if (s.length < 0x8000) {
        bd.setUint16(p, s.length, Endian.little);
        p += 2;
      } else {
        bd.setUint16(p, 0x8000 | (s.length >> 16), Endian.little);
        bd.setUint16(p + 2, s.length & 0xFFFF, Endian.little);
        p += 4;
      }
      for (var i = 0; i < s.length; i++) {
        bd.setUint16(p + i * 2, s.codeUnitAt(i), Endian.little);
      }
      bd.setUint16(p + s.length * 2, 0, Endian.little);
      return bd.buffer.asUint8List();
    }
  }

  static List<int> _varint8(int v) {
    if (v < 0x80) return [v];
    return [0x80 | (v >> 8), v & 0xFF];
  }

  /// 在 [offset] 写入 UTF-16 包名（null 结尾，剩余清零）。最多 128 字符。
  static void _writePackageName(ByteData bd, int offset, String name) {
    for (var i = 0; i < 128; i++) {
      bd.setUint16(
        offset + i * 2,
        i < name.length ? name.codeUnitAt(i) : 0,
        Endian.little,
      );
    }
  }

  /// 从 ARSC 里读出 package 名称（调试/校验用）。
  static String? readPackageName(Uint8List bytes) {
    final bd = ByteData.sublistView(bytes);
    if (bd.getUint16(0, Endian.little) != 0x0002) return null;
    int off = bd.getUint16(2, Endian.little);
    while (off + 8 <= bytes.length) {
      final type = bd.getUint16(off, Endian.little);
      final size = bd.getUint32(off + 4, Endian.little);
      if (size < 8 || off + size > bytes.length) break;
      if (type == 0x0200) {
        final units = <int>[];
        for (var i = 0; i < 128; i++) {
          final u = bd.getUint16(off + 12 + i * 2, Endian.little);
          if (u == 0) break;
          units.add(u);
        }
        return utf8.decode(
          utf8.encode(String.fromCharCodes(units)),
          allowMalformed: true,
        );
      }
      off += size;
    }
    return null;
  }
}
