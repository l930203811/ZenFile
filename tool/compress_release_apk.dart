// 发布包体积压缩工具（配合 GitHub Release 发版使用）。
//
// 把 flutter build 产物里 STORED 的 native lib / PNG / tflite 等
// 重压为 DEFLATE（extractNativeLibs 同步翻成 true，否则安装器会因
// 「未压缩 .so 未对齐」拒装），resources.arsc 保持 STORED + 4 字节对齐，
// 复用克隆引擎的 ApkZipRewriter（对齐做法与 zipalign 相同）。
//
// 输出为【未签名】ZIP —— 旧 v2/v3 签名已随重排失效，必须用发布 keystore
// 重新签名（apksigner sign，同证书即升级兼容），随后 aapt/apksigner 复核。
//
// 用法：dart run tool/compress_release_apk.dart <in.apk> <out.apk>
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:zenfile/services/apk_clone/apk_zip.dart';
import 'package:zenfile/services/apk_clone/axml.dart';

void main(List<String> args) {
  if (args.length != 2) {
    stderr.writeln('usage: dart run tool/compress_release_apk.dart <in.apk> <out.apk>');
    exit(2);
  }
  final inPath = args[0];
  final outPath = args[1];

  final sourceApk = File(inPath).readAsBytesSync();
  final before = sourceApk.length;

  // ---- Manifest：extractNativeLibs false → true ----
  final archive = ZipDecoder().decodeBytes(sourceApk, verify: false);
  final mf = archive.findFile('AndroidManifest.xml');
  if (mf == null) {
    stderr.writeln('AndroidManifest.xml not found');
    exit(1);
  }
  final doc = AxmlDocument.parse(
    Uint8List.fromList(mf.content as List<int>),
  );

  int? androidNs;
  for (final node in doc.nodes) {
    if (node.kind == AxNodeKind.startNamespace &&
        doc.elementName(node.name) == 'android') {
      androidNs = node.ns;
      break;
    }
  }
  const nsUri = 'http://schemas.android.com/apk/res/android';
  androidNs ??= doc.strings.indexOf(nsUri) >= 0
      ? doc.strings.indexOf(nsUri)
      : null;
  if (androidNs == null) {
    stderr.writeln('android namespace not found in manifest');
    exit(1);
  }

  var flipped = false;
  for (final node in doc.nodes) {
    if (node.kind != AxNodeKind.startElement) continue;
    if (doc.elementName(node.name) != 'application') continue;
    _ensureExtractNativeLibs(doc, node, androidNs);
    flipped = true;
    break;
  }
  if (!flipped) {
    stderr.writeln('<application> element not found');
    exit(1);
  }
  final newManifest = doc.serialize();

  // ---- ZIP 重排：STORED 条目重压（arsc 由 rewriter 保持 STORED+对齐）----
  final out = ApkZipRewriter.rewrite(
    sourceApk,
    rewriteEntry: (name, data) =>
        name == 'AndroidManifest.xml' ? newManifest : Uint8List.fromList(data),
    recompressStoredEntry: (name) => name != 'resources.arsc',
  );
  File(outPath).writeAsBytesSync(out.bytes);

  final after = out.bytes.length;
  stdout.writeln('$inPath -> $outPath');
  stdout.writeln(
    'size: $before (${(before / 1048576).toStringAsFixed(1)} MB)'
    ' -> $after (${(after / 1048576).toStringAsFixed(1)} MB),'
    ' saved ${((before - after) / 1048576).toStringAsFixed(1)} MB',
  );
}

/// 与 apk_clone_engine.dart 的 `_ensureExtractNativeLibs` 同逻辑：
/// application 元素带 `android:extractNativeLibs="true"`（已存在则翻转，
/// 缺失则新增，并确保 resource map 里有正确的 attr 资源 id）。
void _ensureExtractNativeLibs(AxmlDocument doc, AxNode node, int androidNs) {
  // android:extractNativeLibs 的资源 id（0x010104ea，与平台 attr 表一致）。
  const extractNativeLibsId = 0x010104ea;
  for (final a in node.attributes) {
    if (a.ns == androidNs && doc.attrName(a) == 'extractNativeLibs') {
      a.dataType = 0x12; // INT_BOOLEAN
      a.data = 0xFFFFFFFF; // true
      a.rawValue = 0xFFFFFFFF;
      _ensureResourceId(doc, doc.attrName(a), extractNativeLibsId);
      return;
    }
  }
  final nameIdx = doc.intern('extractNativeLibs');
  node.attributes = [
    ...node.attributes,
    AxAttribute(
      ns: androidNs,
      name: nameIdx,
      rawValue: 0xFFFFFFFF,
      dataType: 0x12,
      data: 0xFFFFFFFF,
    ),
  ];
  _ensureResourceId(doc, 'extractNativeLibs', extractNativeLibsId);
}

/// resource map 按「属性名字符串索引」给出资源 id；新增属性时把表扩到
/// 对应索引并填入 id，系统才能识别该属性。
void _ensureResourceId(AxmlDocument doc, String attrName, int resourceId) {
  final idx = doc.strings.indexOf(attrName);
  if (idx < 0) return;
  if (idx < doc.resourceIds.length) {
    doc.resourceIds[idx] = resourceId;
    return;
  }
  final expanded = List<int>.from(doc.resourceIds);
  while (expanded.length < idx) {
    expanded.add(0);
  }
  expanded.add(resourceId);
  doc.resourceIds = expanded;
}
