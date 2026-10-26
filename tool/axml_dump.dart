// 调试：dump AXML 解析结果。
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';

import '../lib/services/apk_clone/axml.dart';

void main(List<String> args) {
  final apk = File(args[0]).readAsBytesSync();
  final archive = ZipDecoder().decodeBytes(Uint8List.fromList(apk), verify: false);
  final f = archive.findFile('AndroidManifest.xml');
  stdout.writeln('manifest found: ${f != null}, size=${f?.content.length}');
  if (f == null) {
    for (final file in archive.files.take(10)) {
      stdout.writeln('  entry: ${file.name} isFile=${file.isFile}');
    }
    return;
  }
  final doc = AxmlDocument.parse(Uint8List.fromList(f.content as List<int>));
  stdout.writeln('strings: ${doc.strings.length}, resourceIds: ${doc.resourceIds.length}, nodes: ${doc.nodes.length}');
  var shown = 0;
  for (final n in doc.nodes) {
    if (n.kind == AxNodeKind.startElement && shown < 12) {
      final attrs = n.attributes
          .map((a) => '${doc.attrName(a)}=${doc.attrStringValue(a) ?? docAttr(a)}')
          .join(', ');
      stdout.writeln('elem <${doc.elementName(n.name)}> attrs: $attrs');
      shown++;
    }
  }
}

String docAttr(AxAttribute a) => 'type=0x${a.dataType.toRadixString(16)} data=${a.data.toRadixString(16)}';
