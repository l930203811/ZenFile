import 'dart:convert';
import 'dart:typed_data';

/// 二进制 AndroidManifest.xml（AXML）解析与改写（纯 Dart，零依赖）。
///
/// AXML 是 ResChunk 树：RES_XML(0x0003) 之下依次为
/// 字符串池(0x0001)、属性资源映射表(0x0180)、namespace/element 节点流。
///
/// 改写采用「全量重建」策略：解析 → 在节点树上修改 → 重新序列化，
/// 所有长度/偏移重算 —— 避免原地改字符串导致偏移错位（字符串长度变化
/// 会移动整个池的偏移表）。输出统一用 UTF-16 字符串池（系统解析器对
/// 两种编码都支持，UTF-16 序列化更简单可靠）。
class AxmlDocument {
  /// 字符串池内容（索引即全文件引用）。
  List<String> strings;

  /// 属性资源映射表（RES_XML_RESOURCE_MAP）。
  List<int> resourceIds;

  /// 节点流（namespace / element 的 start 与 end，按原始顺序）。
  List<AxNode> nodes;

  AxmlDocument({
    required this.strings,
    required this.resourceIds,
    required this.nodes,
  });

  // ------------------------------------------------------------------
  // 解析
  // ------------------------------------------------------------------

  /// 从二进制解析。输入必须是完整的 AXML 文件内容。
  static AxmlDocument parse(Uint8List bytes) {
    final bd = ByteData.sublistView(bytes);
    int off = 0;

    // 外层 RES_XML header（type 0x0003）。
    final fileType = bd.getUint16(off, Endian.little);
    if (fileType != 0x0003) {
      throw FormatException(
        'not an AXML document: type=0x${fileType.toRadixString(16)}',
      );
    }
    off += 8; // type + headerSize + size

    List<String>? strings;
    List<int>? resourceIds;
    final nodes = <AxNode>[];

    while (off + 8 <= bytes.length) {
      final type = bd.getUint16(off, Endian.little);
      final headerSize = bd.getUint16(off + 2, Endian.little);
      final size = bd.getUint32(off + 4, Endian.little);
      if (size < 8 || off + size > bytes.length) break;

      switch (type) {
        case 0x0001: // string pool
          strings = _parseStringPool(bytes, bd, off, headerSize, size);
          break;
        case 0x0180: // resource map
          final count = (size - headerSize) ~/ 4;
          resourceIds = List<int>.generate(
            count,
            (i) => bd.getUint32(off + headerSize + i * 4, Endian.little),
          );
          break;
        case 0x0100: // start namespace
        case 0x0101: // end namespace
          // ResXMLTree_namespaceExt 布局：**prefix 在前(+16)、uri 在后(+20)**。
          // AxNode 语义约定 ns=uri 索引、name=prefix 索引，切勿对调——
          // 对调后 androidNs 解析出的是前缀索引，所有按 ns 匹配的改写全部失效。
          nodes.add(
            AxNode(
              kind: type == 0x0100
                  ? AxNodeKind.startNamespace
                  : AxNodeKind.endNamespace,
              ns: bd.getUint32(off + 20, Endian.little),
              name: bd.getUint32(off + 16, Endian.little),
            ),
          );
          break;
        case 0x0102: // start element
          final base = off + 16; // 跳过 header + lineNumber + comment
          // attrExt: ns(4) name(4) attributeStart(2) attributeSize(2)
          //          attributeCount(2) idIndex(2) classIndex(2) styleIndex(2)
          final attrCount = bd.getUint16(base + 12, Endian.little);
          final attrs = <AxAttribute>[];
          for (var i = 0; i < attrCount; i++) {
            final a = base + 20 + i * 20;
            attrs.add(
              AxAttribute(
                ns: bd.getUint32(a, Endian.little),
                name: bd.getUint32(a + 4, Endian.little),
                rawValue: bd.getUint32(a + 8, Endian.little),
                size: bd.getUint16(a + 12, Endian.little),
                dataType: bd.getUint8(a + 15),
                data: bd.getUint32(a + 16, Endian.little),
              ),
            );
          }
          nodes.add(
            AxNode(
              kind: AxNodeKind.startElement,
              ns: bd.getUint32(base, Endian.little),
              name: bd.getUint32(base + 4, Endian.little),
              attributes: attrs,
            ),
          );
          break;
        case 0x0103: // end element
          nodes.add(
            AxNode(
              kind: AxNodeKind.endElement,
              ns: bd.getUint32(off + 16, Endian.little),
              name: bd.getUint32(off + 20, Endian.little),
            ),
          );
          break;
        default:
          break; // 未知 chunk 原样跳过
      }
      off += size;
    }

    if (strings == null) {
      throw const FormatException('AXML missing string pool');
    }
    return AxmlDocument(
      strings: strings,
      resourceIds: resourceIds ?? const <int>[],
      nodes: nodes,
    );
  }

  static List<String> _parseStringPool(
    Uint8List bytes,
    ByteData bd,
    int off,
    int headerSize,
    int size,
  ) {
    final stringCount = bd.getUint32(off + 8, Endian.little);
    final flags = bd.getUint32(off + 16, Endian.little);
    final stringsStart = bd.getUint32(off + 20, Endian.little);
    final isUtf8 = (flags & 0x100) != 0;
    final dataBase = off + stringsStart;
    final strings = <String>[];
    for (var i = 0; i < stringCount; i++) {
      final strOff =
          dataBase + bd.getUint32(off + headerSize + i * 4, Endian.little);
      strings.add(
        isUtf8
            ? _readUtf8PoolString(bytes, strOff)
            : _readUtf16PoolString(bd, strOff),
      );
    }
    return strings;
  }

  static String _readUtf16PoolString(ByteData bd, int off) {
    var len = bd.getUint16(off, Endian.little);
    int head = 2;
    if (len & 0x8000 != 0) {
      len = ((len & 0x7FFF) << 16) | bd.getUint16(off + 2, Endian.little);
      head = 4;
    }
    final sb = StringBuffer();
    for (var i = 0; i < len; i++) {
      sb.writeCharCode(bd.getUint16(off + head + i * 2, Endian.little));
    }
    return sb.toString();
  }

  static String _readUtf8PoolString(Uint8List bytes, int off) {
    var charLen = bytes[off];
    int p = 1;
    if (charLen & 0x80 != 0) {
      charLen = ((charLen & 0x7F) << 8) | bytes[off + 1];
      p = 2;
    }
    var byteLen = bytes[off + p];
    int q = p + 1;
    if (byteLen & 0x80 != 0) {
      byteLen = ((byteLen & 0x7F) << 8) | bytes[off + p + 1];
      q = p + 2;
    }
    return utf8.decode(
      bytes.sublist(off + q, off + q + byteLen),
      allowMalformed: true,
    );
  }

  // ------------------------------------------------------------------
  // 序列化
  // ------------------------------------------------------------------

  /// 序列化为完整 AXML（字符串池统一 UTF-16）。
  Uint8List serialize() {
    final out = BytesBuilder();

    // --- 字符串池 chunk ---
    final pool = _buildStringPool(strings);
    out.add(pool);

    // --- resource map chunk（存在才写）---
    if (resourceIds.isNotEmpty) {
      final mapSize = 8 + resourceIds.length * 4;
      final mapBd = ByteData(mapSize);
      mapBd.setUint16(0, 0x0180, Endian.little);
      mapBd.setUint16(2, 8, Endian.little);
      mapBd.setUint32(4, mapSize, Endian.little);
      for (var i = 0; i < resourceIds.length; i++) {
        mapBd.setUint32(8 + i * 4, resourceIds[i], Endian.little);
      }
      out.add(mapBd.buffer.asUint8List());
    }

    // --- 节点流 ---
    for (final node in nodes) {
      out.add(_serializeNode(node));
    }

    // --- 外层 RES_XML 包裹 ---
    final body = out.toBytes();
    final docSize = 8 + body.length;
    final head = ByteData(8);
    head.setUint16(0, 0x0003, Endian.little);
    head.setUint16(2, 8, Endian.little);
    head.setUint32(4, docSize, Endian.little);
    final result = BytesBuilder();
    result.add(head.buffer.asUint8List());
    result.add(body);
    return result.toBytes();
  }

  /// 字符串池 chunk（UTF-16 编码，headerSize 固定 28）。
  static Uint8List _buildStringPool(List<String> strings) {
    // 每个字符串的 UTF-16 编码（含长度头与终止符）。
    final encoded = strings.map(_encodeUtf16PoolString).toList();
    final offsets = <int>[];
    int cursor = 0;
    for (final e in encoded) {
      offsets.add(cursor);
      cursor += e.length;
    }
    final stringsDataSize = cursor;
    // 数据区起始 = header 28 + 偏移表 stringCount*4；整体补齐到 4 字节。
    final stringsStart = 28 + strings.length * 4;
    final dataSize = _align4(stringsStart + stringsDataSize) - stringsStart;
    final chunkSize = stringsStart + dataSize;

    final bd = ByteData(chunkSize);
    bd.setUint16(0, 0x0001, Endian.little);
    bd.setUint16(2, 28, Endian.little);
    bd.setUint32(4, chunkSize, Endian.little);
    bd.setUint32(8, strings.length, Endian.little);
    bd.setUint32(12, 0, Endian.little); // styleCount
    bd.setUint32(16, 0, Endian.little); // flags: UTF-16
    bd.setUint32(20, stringsStart, Endian.little);
    bd.setUint32(24, 0, Endian.little); // stylesStart

    for (var i = 0; i < encoded.length; i++) {
      bd.setUint32(28 + i * 4, offsets[i], Endian.little);
    }
    var p = stringsStart;
    for (final e in encoded) {
      bd.buffer.asUint8List().setAll(p, e);
      p += e.length;
    }
    return bd.buffer.asUint8List();
  }

  /// 单个字符串的池内编码：变长 u16 长度 + UTF-16 字符 + 0x0000 终止。
  static Uint8List _encodeUtf16PoolString(String s) {
    final units = s.codeUnits;
    final lenHeader = units.length >= 0x8000 ? 4 : 2;
    final bd = ByteData(lenHeader + units.length * 2 + 2);
    var p = 0;
    if (lenHeader == 4) {
      bd.setUint16(0, 0x8000 | (units.length >> 16), Endian.little);
      bd.setUint16(2, units.length & 0xFFFF, Endian.little);
      p = 4;
    } else {
      bd.setUint16(0, units.length, Endian.little);
      p = 2;
    }
    for (var i = 0; i < units.length; i++) {
      bd.setUint16(p + i * 2, units[i], Endian.little);
    }
    bd.setUint16(p + units.length * 2, 0, Endian.little);
    return bd.buffer.asUint8List();
  }

  static Uint8List _serializeNode(AxNode node) {
    switch (node.kind) {
      case AxNodeKind.startNamespace:
      case AxNodeKind.endNamespace:
        final bd = ByteData(24);
        bd.setUint16(
          0,
          node.kind == AxNodeKind.startNamespace ? 0x0100 : 0x0101,
          Endian.little,
        );
        bd.setUint16(2, 16, Endian.little);
        bd.setUint32(4, 24, Endian.little);
        bd.setUint32(8, 0, Endian.little); // lineNumber
        bd.setUint32(12, 0xFFFFFFFF, Endian.little); // comment
        // 布局与解析端一致：prefix(+16) 在前、uri(+20) 在后。
        bd.setUint32(16, node.name, Endian.little);
        bd.setUint32(20, node.ns, Endian.little);
        return bd.buffer.asUint8List();
      case AxNodeKind.endElement:
        final bd = ByteData(24);
        bd.setUint16(0, 0x0103, Endian.little);
        bd.setUint16(2, 16, Endian.little);
        bd.setUint32(4, 24, Endian.little);
        bd.setUint32(8, 0, Endian.little);
        bd.setUint32(12, 0xFFFFFFFF, Endian.little);
        bd.setUint32(16, node.ns, Endian.little);
        bd.setUint32(20, node.name, Endian.little);
        return bd.buffer.asUint8List();
      case AxNodeKind.startElement:
        final attrs = node.attributes;
        // header 16 + attrExt 20 + attrs*20
        final size = 16 + 20 + attrs.length * 20;
        final bd = ByteData(size);
        bd.setUint16(0, 0x0102, Endian.little);
        bd.setUint16(2, 16, Endian.little);
        bd.setUint32(4, size, Endian.little);
        bd.setUint32(8, 0, Endian.little); // lineNumber
        bd.setUint32(12, 0xFFFFFFFF, Endian.little); // comment
        final base = 16;
        bd.setUint32(base, node.ns, Endian.little);
        bd.setUint32(base + 4, node.name, Endian.little);
        bd.setUint16(base + 8, 20, Endian.little); // attributeStart
        bd.setUint16(base + 10, 20, Endian.little); // attributeSize
        bd.setUint16(base + 12, attrs.length, Endian.little);
        bd.setUint16(base + 14, 0, Endian.little); // idIndex
        bd.setUint16(base + 16, 0, Endian.little); // classIndex
        bd.setUint16(base + 18, 0, Endian.little); // styleIndex
        for (var i = 0; i < attrs.length; i++) {
          final a = attrs[i];
          final p = base + 20 + i * 20;
          bd.setUint32(p, a.ns, Endian.little);
          bd.setUint32(p + 4, a.name, Endian.little);
          bd.setUint32(p + 8, a.rawValue, Endian.little);
          bd.setUint16(p + 12, 8, Endian.little); // typed value size
          bd.setUint8(p + 14, 0); // res0
          bd.setUint8(p + 15, a.dataType);
          bd.setUint32(p + 16, a.data, Endian.little);
        }
        return bd.buffer.asUint8List();
    }
  }

  static int _align4(int v) => (v + 3) & ~3;

  // ------------------------------------------------------------------
  // 便捷访问（供改写逻辑使用）
  // ------------------------------------------------------------------

  int indexOf(String s) => strings.indexOf(s);

  /// 追加字符串并返回其索引（已存在则返回现有索引）。
  int intern(String s) {
    final i = strings.indexOf(s);
    if (i != -1) return i;
    strings.add(s);
    return strings.length - 1;
  }

  /// 元素名的字符串值（索引越界返回空串）。
  String elementName(int index) =>
      (index >= 0 && index < strings.length) ? strings[index] : '';

  /// 属性名字符串值。
  String attrName(AxAttribute a) => elementName(a.name);

  /// 属性的字符串值（仅当值为字符串类型）。
  String? attrStringValue(AxAttribute a) {
    if (a.dataType == 0x03 && a.data >= 0 && a.data < strings.length) {
      return strings[a.data];
    }
    if (a.rawValue != 0xFFFFFFFF && a.rawValue < strings.length) {
      return strings[a.rawValue];
    }
    return null;
  }
}

enum AxNodeKind { startNamespace, endNamespace, startElement, endElement }

class AxNode {
  final AxNodeKind kind;
  int ns;
  int name;
  List<AxAttribute> attributes;
  AxNode({
    required this.kind,
    required this.ns,
    required this.name,
    this.attributes = const <AxAttribute>[],
  });
}

class AxAttribute {
  int ns;
  int name;
  int rawValue;
  int dataType;
  int data;
  int size;
  AxAttribute({
    required this.ns,
    required this.name,
    required this.rawValue,
    required this.dataType,
    required this.data,
    this.size = 8,
  });
}
