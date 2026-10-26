// 对照实验：对 zclone_test.apk 按 apksig 分段算法在 Dart 重算 digest，
// 与 Java/apksig 的 4c823e58 对比，定位 Dart 实现差异。
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

String hex(List<int> d) =>
    d.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

void main(List<String> args) {
  final apk = File(args.isNotEmpty
          ? args[0]
          : 'D:/Xiangmu/clone_out/zclone_test.apk')
      .readAsBytesSync();
  final bd = ByteData.sublistView(apk);

  // 解析 EOCD
  var eocdStart = -1;
  for (var i = apk.length - 22; i >= apk.length - 65557 && i >= 0; i--) {
    if (bd.getUint32(i, Endian.little) == 0x06054b50) {
      final commentLen = bd.getUint16(i + 20, Endian.little);
      if (i + 22 + commentLen == apk.length) {
        eocdStart = i;
        break;
      }
    }
  }
  final cdOffset = bd.getUint32(eocdStart + 16, Endian.little);
  final cdSize = bd.getUint32(eocdStart + 12, Endian.little);
  final blockSize = bd.getUint64(cdOffset - 24, Endian.little);
  final sigBlockStart = cdOffset - 8 - blockSize;
  stdout.writeln('len=${apk.length} cdOffset=$cdOffset cdSize=$cdSize '
      'blockSize=$blockSize sigBlockStart=$sigBlockStart eocd=$eocdStart');

  // 三段（verify 端语义）
  final s1 = Uint8List.sublistView(apk, 0, sigBlockStart);
  final s2 = Uint8List.sublistView(apk, cdOffset, cdOffset + cdSize);
  final s3raw = Uint8List.sublistView(apk, eocdStart);
  final s3 = Uint8List.fromList(s3raw);
  ByteData.sublistView(s3).setUint32(16, sigBlockStart, Endian.little);

  const chunkSize = 1048576;
  final allDigests = BytesBuilder();
  var chunkIndex = 0;
  for (final section in [s1, s2, s3]) {
    for (var off = 0; off < section.length; off += chunkSize, chunkIndex++) {
      final take = (off + chunkSize) < section.length
          ? chunkSize
          : (section.length - off);
      final prefix = ByteData(5)
        ..setUint8(0, 0xa5)
        ..setUint32(1, chunkIndex, Endian.little);
      final input = BytesBuilder()
        ..add(prefix.buffer.asUint8List())
        ..add(Uint8List.sublistView(section, off, off + take));
      allDigests.add(sha256.convert(input.toBytes()).bytes);
    }
  }
  final finalDigest = sha256.convert(allDigests.toBytes()).bytes;
  stdout.writeln('dart digest: ${hex(finalDigest)}');
  stdout.writeln('java actual: 4c823e580101d344a463466607bf90ce56a6179abe6e5d948ad9221ca1022b9f');
  stdout.writeln('chunk count: $chunkIndex');
}
