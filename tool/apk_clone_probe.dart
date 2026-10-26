// 引擎验证探针：把一个真实 APK 跑完整克隆链，输出到临时目录。
// 用法：dart run tool/apk_clone_probe.dart <源APK> <输出APK> <新包名>
import 'dart:io';
import 'dart:typed_data';

import '../lib/services/apk_clone/apk_clone_engine.dart';

Future<void> main(List<String> args) async {
  final source = File(args[0]);
  final output = File(args[1]);
  final newPackage = args[2];

  final src = Uint8List.fromList(source.readAsBytesSync());
  stdout.writeln('source: ${source.path} (${src.length} bytes)');

  final orig = ApkCloneEngine.parsePackageName(src);
  stdout.writeln('original package: $orig');

  final sw = Stopwatch()..start();
  final cloned = ApkCloneEngine.cloneToBytes(
    sourceApk: src,
    newPackage: newPackage,
    originalPackage: orig,
  );
  sw.stop();
  stdout.writeln('cloned: ${cloned.length} bytes in ${sw.elapsedMilliseconds}ms');

  output.parent.createSync(recursive: true);
  output.writeAsBytesSync(cloned);
  stdout.writeln('written: ${output.path}');

  // 自校验：新包名能被解析回来。
  final check = ApkCloneEngine.parsePackageName(cloned);
  stdout.writeln('verify package in cloned apk: $check');
}
