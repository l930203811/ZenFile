import 'dart:typed_data';

import 'package:archive/archive.dart';

import 'apk_signer.dart';
import 'apk_zip.dart';
import 'arsc.dart';
import 'axml.dart';

/// APK 克隆引擎：把一个应用重打包为**可共存安装**的克隆安装包（纯 Dart）。
///
/// 处理链：读源 APK → 改写二进制 Manifest（包名 / authorities / 自定义
/// permission / taskAffinity / extractNativeLibs）→ 改写 resources.arsc
/// 的 package 名 → 重排 ZIP（arsc STORED+对齐）→ 插入 APK Signature
/// Scheme v2 签名块 → 输出单文件安装包。
///
/// 兼容性边界（与 App Cloner 同类工具一致）：
///  - 克隆包签名 ≠ 原签名 ⇒ 强签名校验类应用（银行/支付/Google 服务）克隆后
///    不可用；
///  - 仅支持**单 APK** 应用；App Bundle 拆分应用（splitSourceDirs 非空）
///    由调用方在 UI 层拦截提示。
class ApkCloneEngine {
  ApkCloneEngine._();

  /// 从源 APK 的 Manifest 解析出包名。
  static String? parsePackageName(Uint8List sourceApk) {
    try {
      final archive = ZipDecoder().decodeBytes(sourceApk, verify: false);
      final f = archive.findFile('AndroidManifest.xml');
      if (f == null) return null;
      final doc = AxmlDocument.parse(
        Uint8List.fromList(f.content as List<int>),
      );
      return _readPackageAttr(doc);
    } catch (_) {
      return null;
    }
  }

  static String? _readPackageAttr(AxmlDocument doc) {
    for (final node in doc.nodes) {
      if (node.kind != AxNodeKind.startElement) continue;
      if (doc.elementName(node.name) != 'manifest') continue;
      for (final a in node.attributes) {
        if (doc.attrName(a) == 'package' && a.ns == 0xFFFFFFFF) {
          return doc.attrStringValue(a);
        }
      }
      break;
    }
    return null;
  }

  /// 执行克隆，返回完整的新 APK 字节。
  ///
  /// [originalPackage] 传 null 时自动从源 APK 解析。
  static Uint8List cloneToBytes({
    required Uint8List sourceApk,
    required String newPackage,
    String? originalPackage,
  }) {
    final archive = ZipDecoder().decodeBytes(sourceApk, verify: false);
    final manifestFile = archive.findFile('AndroidManifest.xml');
    if (manifestFile == null) {
      throw const ApkCloneException('AndroidManifest.xml not found');
    }
    final manifestBytes = Uint8List.fromList(manifestFile.content as List<int>);

    final origPkg =
        originalPackage ?? _readPackageAttr(AxmlDocument.parse(manifestBytes));
    if (origPkg == null || origPkg.isEmpty) {
      throw const ApkCloneException('cannot read package name from manifest');
    }

    // ---- 1. Manifest 改写 ----
    final doc = AxmlDocument.parse(manifestBytes);
    _rewriteManifest(doc, originalPackage: origPkg, newPackage: newPackage);
    final newManifest = doc.serialize();

    // ---- 2. resources.arsc 包名 + 字符串池改写 ----
    Uint8List? Function(String, List<int>) rewriteEntry = (name, data) =>
        name == 'AndroidManifest.xml' ? newManifest : null;
    final arscFile = archive.findFile('resources.arsc');
    if (arscFile != null) {
      final newArsc = ArscRewriter.rewrite(
        Uint8List.fromList(arscFile.content as List<int>),
        origPkg,
        newPackage,
      );
      rewriteEntry = (name, data) {
        if (name == 'AndroidManifest.xml') return newManifest;
        if (name == 'resources.arsc') return newArsc;
        return null;
      };
    }

    // ---- 3. ZIP 重排（arsc STORED+对齐，剔除旧签名）----
    final zip = ApkZipRewriter.rewrite(sourceApk, rewriteEntry: rewriteEntry);

    // ---- 4. v2 签名 ----
    return ApkV2Signer.sign(
      zip.bytes,
      centralDirOffset: zip.centralDirOffset,
      eocdOffset: zip.eocdOffset,
    );
  }

  /// 加固 / 加壳特征库（按库名 / 路径片段识别常见 Android 加固方案）。
  ///
  /// 命中任一即说明应用**运行时身份**（包名、ContentProvider authority、
  /// 文件路径等）被写进了受保护、运行时才解密的原生库或壳载荷里 ——
  /// 单纯改写 manifest + arsc 字符串池**覆盖不到**这些引用，克隆包安装可
  /// 共存但运行期很可能因身份不匹配而崩溃或无法正常使用。
  static const Map<String, String> _kHardeningMarkers = <String, String>{
    'libexec.so': '爱加密(iJiami)',
    'ijm_lib': '爱加密(iJiami)',
    'libzxprotect.so': '腾讯宙斯盾',
    'libshella': '360加固',
    'libshellx': '360加固',
    'libjiagu': '360加固',
    'libxguard': '百度加固',
    'libmsaoaidsec.so': '百度加固',
    'libnllvm': '网易易盾',
    'libnleaves.so': '网易易盾',
    'libg3c_': '网易易盾',
    'libdexhelper.so': '爱加密(iJiami)',
    'libdexjni.so': '爱加密(iJiami)',
    'libsgmain.so': '阿里聚安全',
    'libsgsecuritybody.so': '阿里聚安全',
    'libmobisec.so': '同盾/网秦加固',
    'libappsecurity.so': '应用加固壳',
  };

  /// 扫描源 APK，返回命中的加固方案标签；空列表表示未识别到加固特征。
  ///
  /// 同时用启发式兜底：APK 体积较大但 dex 极小 ⇒ 真实代码被打包进原生载荷
  /// （典型加壳特征）。返回顺序不保证去重以外的稳定性。
  static List<String> detectHardening(Uint8List sourceApk) {
    final markers = <String>{};
    var totalDexSize = 0;
    final apkSize = sourceApk.length;
    try {
      final archive = ZipDecoder().decodeBytes(sourceApk, verify: false);
      for (final f in archive.files) {
        final name = f.name.toLowerCase();
        if (name.endsWith('.so') ||
            name.contains('ijm_lib') ||
            name.contains('libexec')) {
          for (final k in _kHardeningMarkers.keys) {
            if (name.contains(k.toLowerCase())) {
              markers.add(_kHardeningMarkers[k]!);
            }
          }
        }
        if (name.endsWith('.dex')) totalDexSize += f.size;
      }
    } catch (_) {
      return const [];
    }
    // 启发式：大 APK + 极小 dex ⇒ 代码加壳（真实 dex 在原生载荷里）。
    if (apkSize > 8 * 1024 * 1024 && totalDexSize < 256 * 1024) {
      markers.add('代码加壳(DEX极小)');
    }
    return markers.toList();
  }
}

class ApkCloneException implements Exception {
  final String message;
  const ApkCloneException(this.message);
  @override
  String toString() => message;
}

// ---------------------------------------------------------------------------
// Manifest 改写规则
// ---------------------------------------------------------------------------

/// 值里含原包名前缀、需要跟着改的属性名（组件类名 `name` **不在**此列：
/// 类仍在原 dex，类名与 manifest package 无关，改了会找不到类）。
const _kPrefixReplaceAttrNames = <String>{
  'authorities',
  'permission',
  'readPermission',
  'writePermission',
  'taskAffinity',
  'sharedUserId',
  'targetPackage',
  'process',
};

/// 自定义 permission 定义元素（其 `name` 一律加新包名前缀，避免与原应用
/// 同名 permission 冲突 —— Android 12+ 安装时同名不同签名 permission 会拒装）。
const _kPermissionElements = <String>{
  'permission',
  'permission-group',
  'permission-tree',
};

void _rewriteManifest(
  AxmlDocument doc, {
  required String originalPackage,
  required String newPackage,
}) {
  // android namespace 的字符串索引（ns 字段存 URI 字符串索引）。
  // 优先取 namespace 声明节点的 uri 索引；个别 manifest 不带 namespace
  // 节点（属性仍带 ns 索引），此时直接从字符串池反查 URI 兜底。
  int? androidNs;
  for (final node in doc.nodes) {
    if (node.kind == AxNodeKind.startNamespace &&
        doc.elementName(node.name) == 'android') {
      androidNs = node.ns;
      break;
    }
  }
  androidNs ??=
      doc.strings.indexOf('http://schemas.android.com/apk/res/android') >= 0
      ? doc.strings.indexOf('http://schemas.android.com/apk/res/android')
      : null;

  final usesPermissionNames = <String>{
    'uses-permission',
    'uses-permission-sdk-23',
    'uses-permission-sdk-m',
  };

  for (final node in doc.nodes) {
    if (node.kind != AxNodeKind.startElement) continue;
    final elem = doc.elementName(node.name);

    if (elem == 'manifest') {
      _replaceAttrByName(
        doc,
        node,
        'package',
        0xFFFFFFFF,
        (v) => newPackage,
        exactMatch: true,
      );
      // android:sharedUserId 规范上声明在 **manifest 元素**（不是 application）。
      // 克隆包签名 ≠ 原签名，保留会因共享 UID 签名不兼容直接拒装
      //（「软件包与现有软件包存在冲突」）；克隆作为独立沙箱运行，直接摘除。
      _removeAttrByName(doc, node, 'sharedUserId', androidNs);
      continue;
    }

    if (elem == 'original-package') {
      // <original-package android:name="原包名"> 会让安装器把克隆包登记为
      // 原应用的升级通道 ⇒ 与已安装的原应用「存在冲突」。整对元素移除。
      _removeElementPair(doc, node);
      continue;
    }

    if (elem == 'application') {
      // sharedUserId 整条摘除：克隆包签名 ≠ 原签名，保留 sharedUserId 会因
      // 共享 UID 签名不兼容直接拒装（「与现有软件包存在冲突」）；克隆作为
      // 独立沙箱运行，不需要与原应用共享 UID。
      _removeAttrByName(doc, node, 'sharedUserId', androidNs);
      // extractNativeLibs=true：ZIP 重排后复用的 STORED native lib 不再
      // 保证页对齐（zipalign 的对齐信息不随条目迁移），未压缩 so 必须靠
      // 安装期解压落地，规避页对齐校验。
      if (androidNs != null) {
        _ensureExtractNativeLibs(doc, node, androidNs);
      }
      // application 级的 taskAffinity / process 等同包名标识也要跟着改，
      // 否则克隆包与原应用共享进程名/任务亲和性 ⇒ 安装报
      // 「软件包与现有软件包存在冲突」。
      _replacePrefixAttrs(doc, node, originalPackage, newPackage);
      continue;
    }

    if (_kPermissionElements.contains(elem)) {
      // name 改写与 uses-permission 的规则保持一致：包名前缀段做前缀替换，
      // 其余段前置新包名 —— 避免定义与使用声明改写结果不一致
      //（定义改成了 X、使用声明改成了 Y ⇒ 权限对不上而丢失）。
      _replaceAttrByName(doc, node, 'name', androidNs, (v) {
        if (v.startsWith('$newPackage.')) return v;
        final replaced = _replacePrefix(v, originalPackage, newPackage);
        return replaced == v ? '$newPackage.$v' : replaced;
      });
      _replacePrefixAttrs(doc, node, originalPackage, newPackage);
      continue;
    }

    if (elem == 'provider') {
      // authorities 可能是逗号 / 空白 / 分号分隔的多个值，逐段替换——
      // 漏改任何一个都会与原应用（已安装）同名 provider 冲突 ⇒ 安装报
      // 「软件包与现有软件包存在冲突」。此处**全量**改写：包名前缀段做
      // 前缀替换，其余段（第三方 SDK 的非包名 authority，同样被原应用
      // 注册占用）统一追加克隆尾缀，保证与原应用全部错开。
      _replaceAttrByName(
        doc,
        node,
        'authorities',
        androidNs,
        (v) => v
            .split(RegExp(r'[,\s;]+'))
            .where((s) => s.trim().isNotEmpty)
            .map((s) {
              final seg = s.trim();
              final fixed = seg.startsWith('$originalPackage.')
                  ? newPackage + seg.substring(originalPackage.length)
                  : (seg == originalPackage
                        ? newPackage
                        : '$seg.${_cloneSuffix(newPackage)}');
              return fixed;
            })
            .join(','),
      );
      _replacePrefixAttrs(doc, node, originalPackage, newPackage);
      continue;
    }

    if (usesPermissionNames.contains(elem)) {
      // 仅替换自定义 permission 的使用声明（android.permission.* 不动）。
      _replaceAttrByName(
        doc,
        node,
        'name',
        androidNs,
        (v) => _replacePrefix(v, originalPackage, newPackage),
      );
      continue;
    }

    if (elem == 'instrumentation') {
      _replaceAttrByName(
        doc,
        node,
        'targetPackage',
        androidNs,
        (v) => _replacePrefix(v, originalPackage, newPackage),
      );
      continue;
    }

    // activity / service / receiver / activity-alias 等：仅 taskAffinity。
    _replacePrefixAttrs(doc, node, originalPackage, newPackage);
  }
}

void _replacePrefixAttrs(
  AxmlDocument doc,
  AxNode node,
  String originalPackage,
  String newPackage,
) {
  for (final a in node.attributes) {
    final name = doc.attrName(a);
    if (!_kPrefixReplaceAttrNames.contains(name)) continue;
    final v = doc.attrStringValue(a);
    if (v == null) continue;
    final fixed = _replacePrefix(v, originalPackage, newPackage);
    if (fixed != v) _setString(doc, a, fixed);
  }
}

void _replaceAttrByName(
  AxmlDocument doc,
  AxNode node,
  String attrName,
  int? androidNs,
  String Function(String) transform, {
  bool exactMatch = false,
}) {
  for (final a in node.attributes) {
    if (doc.attrName(a) != attrName) continue;
    if (!exactMatch && androidNs != null && a.ns != androidNs) {
      // 非 android: 命名空间的同名属性不处理（自定义 styleable 等）。
      if (a.ns != 0xFFFFFFFF) continue;
    }
    final v = doc.attrStringValue(a);
    if (v == null) continue;
    _setString(doc, a, transform(v));
    return; // package / authorities 等单值属性处理完即止
  }
}

String _replacePrefix(String v, String originalPackage, String newPackage) {
  if (v == originalPackage) return newPackage;
  // 幂等保护：provider 分支已对 authorities 做过前缀替换，随后
  // _replacePrefixAttrs 再扫同一属性时不能二次替换（否则出现
  // 「xxx.zclone1.zclone1」双尾缀）。
  if (v == newPackage || v.startsWith('$newPackage.')) return v;
  if (v.startsWith('$originalPackage.')) {
    return newPackage + v.substring(originalPackage.length);
  }
  return v;
}

/// 克隆尾缀（newPackage 相对 originalPackage 的增量，如 `.zclone1`），
/// 用于给非包名前缀的 authority 追加唯一化后缀。
String _cloneSuffix(String newPackage) {
  final lastDot = newPackage.lastIndexOf('.');
  return lastDot < 0 ? '.${newPackage}' : newPackage.substring(lastDot);
}

/// 按属性名移除属性（ns 非空时校验命名空间，避免误删自定义 styleable 同名项）。
void _removeAttrByName(
  AxmlDocument doc,
  AxNode node,
  String attrName,
  int? androidNs,
) {
  node.attributes = node.attributes.where((a) {
    if (doc.attrName(a) != attrName) return true;
    if (androidNs != null && a.ns != androidNs) return true;
    return false;
  }).toList();
}

/// 移除一个空元素：start 节点与其后紧邻的同名 end 节点成对删除。
/// 仅用于 manifest 级空元素（original-package 等），不处理含子节点的情况。
void _removeElementPair(AxmlDocument doc, AxNode startNode) {
  final idx = doc.nodes.indexOf(startNode);
  if (idx < 0) return;
  doc.nodes.removeAt(idx);
  if (idx < doc.nodes.length &&
      doc.nodes[idx].kind == AxNodeKind.endElement &&
      doc.nodes[idx].name == startNode.name) {
    doc.nodes.removeAt(idx);
  }
}

void _setString(AxmlDocument doc, AxAttribute a, String value) {
  // 字符串池保持原索引不变、新串追加尾部 ⇒ 其它 attr 的引用不受影响。
  final idx = doc.intern(value);
  a.dataType = 0x03; // STRING
  a.data = idx;
  a.rawValue = idx;
}

/// 确保 application 元素带 `android:extractNativeLibs="true"`。
void _ensureExtractNativeLibs(AxmlDocument doc, AxNode node, int androidNs) {
  // android:extractNativeLibs 的资源 id（0x010104ea，与平台 attr 表一致，
  // aapt dump xmltree 解析结果即此值；写错 id 会导致属性无法被系统识别）。
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
