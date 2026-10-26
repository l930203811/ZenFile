// 生成未签名重排 ZIP（供 apksigner 签名对照实验）。
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';

import '../lib/services/apk_clone/apk_zip.dart';

void main(List<String> args) {
  final src = File(args[0]).readAsBytesSync();
  final archive = ZipDecoder().decodeBytes(Uint8List.fromList(src), verify: false);
  final out = ApkZipRewriter.rewrite(Uint8List.fromList(src));
  File(args[1]).writeAsBytesSync(out.bytes);
  stdout.writeln('unsigned zip: ${args[1]} ${out.bytes.length} bytes '
      '(entries: ${archive.files.where((f) => f.isFile).length})');
}
