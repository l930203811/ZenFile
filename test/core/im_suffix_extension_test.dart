import 'package:flutter/material.dart' show Icons;
import 'package:flutter_test/flutter_test.dart';
import 'package:zenfile/core/utils.dart';

/// QQ / 微信等 IM 在目标目录已有同名文件时会追加序号：`app.apk` → `app.apk.1`。
///
/// 这组测试锁住「有效扩展名」的归一化边界——它同时决定图标、分类、缩略图、
/// 打开方式、APK 安装入口，误伤（把真实名字改掉）或漏判（`.apk.1` 认不出来）
/// 都会直接变成用户可见的 bug：
/// - 漏判：`.apk.1` 被当成 zip bundle 去解压安装 → 「点了安装没反应」；
/// - 误伤：把 `.zip.001`（分卷真实扩展名）剥成 `.zip`，或改掉 `README.1`。
void main() {
  group('hasImAppendedSuffix（是否 IM 追加序号）', () {
    test('典型 IM 追加 → true', () {
      expect(FileUtils.hasImAppendedSuffix('app.apk.1'), isTrue);
      expect(FileUtils.hasImAppendedSuffix('movie.mp4.2'), isTrue);
      expect(FileUtils.hasImAppendedSuffix('a.zip.12'), isTrue);
      expect(FileUtils.hasImAppendedSuffix('note.txt.999'), isTrue);
      expect(FileUtils.hasImAppendedSuffix('com.tencent.mm.apk.1'), isTrue);
      expect(FileUtils.hasImAppendedSuffix('photo.jpg.9999'), isTrue);
    });

    test('正常文件名 → false', () {
      expect(FileUtils.hasImAppendedSuffix('app.apk'), isFalse);
      expect(FileUtils.hasImAppendedSuffix('archive.tar.gz'), isFalse);
      expect(FileUtils.hasImAppendedSuffix('noext'), isFalse);
      expect(FileUtils.hasImAppendedSuffix('.nomedia'), isFalse);
      expect(FileUtils.hasImAppendedSuffix('app.apk.'), isFalse);
    });

    test('点号前没有扩展名 → false（`README.1` 可能是用户真实文件名，不猜）', () {
      expect(FileUtils.hasImAppendedSuffix('README.1'), isFalse);
      expect(FileUtils.hasImAppendedSuffix('file.2'), isFalse);
      expect(FileUtils.hasImAppendedSuffix('x.1'), isFalse);
    });

    test('前导零（zip/rar 分卷）→ false，绝不剥', () {
      expect(FileUtils.hasImAppendedSuffix('archive.zip.001'), isFalse);
      expect(FileUtils.hasImAppendedSuffix('archive.rar.002'), isFalse);
      expect(FileUtils.hasImAppendedSuffix('a.7z.010'), isFalse);
    });

    test('超长数字 / 含非数字 → false（不像 IM 追加，保持保守）', () {
      expect(FileUtils.hasImAppendedSuffix('app.apk.10000'), isFalse);
      expect(FileUtils.hasImAppendedSuffix('app.apk.1a'), isFalse);
      expect(FileUtils.hasImAppendedSuffix('app.apk.1 2'), isFalse);
      expect(FileUtils.hasImAppendedSuffix('app.apk.-1'), isFalse);
    });
  });

  group('stripImAppendedSuffix（去掉 IM 追加序号）', () {
    test('常规剥离', () {
      expect(FileUtils.stripImAppendedSuffix('app.apk.1'), 'app.apk');
      expect(FileUtils.stripImAppendedSuffix('archive.tar.gz.2'), 'archive.tar.gz');
    });

    test('完整路径只处理最后一段', () {
      expect(
        FileUtils.stripImAppendedSuffix('/storage/emulated/0/Download/app.apk.1'),
        '/storage/emulated/0/Download/app.apk',
      );
      // 目录名里带 `.1` 不受影响（只处理最后一段）
      expect(
        FileUtils.stripImAppendedSuffix('/storage/emulated/0/a.1/app.apk'),
        '/storage/emulated/0/a.1/app.apk',
      );
    });

    test('Windows 反斜杠分隔符同样支持', () {
      expect(
        FileUtils.stripImAppendedSuffix(r'C:\Users\me\app.apk.1'),
        r'C:\Users\me\app.apk',
      );
    });

    test('不该剥的原样返回', () {
      expect(FileUtils.stripImAppendedSuffix('README.1'), 'README.1');
      expect(FileUtils.stripImAppendedSuffix('archive.zip.001'), 'archive.zip.001');
      expect(FileUtils.stripImAppendedSuffix('app.apk'), 'app.apk');
      expect(FileUtils.stripImAppendedSuffix('/a/b/c'), '/a/b/c');
    });
  });

  group('effectiveExtension / effectiveExtensionWithDot', () {
    test('归一化后取扩展名', () {
      expect(FileUtils.effectiveExtension('app.apk.1'), 'apk');
      expect(FileUtils.effectiveExtensionWithDot('app.apk.1'), '.apk');
      expect(FileUtils.effectiveExtension('/d/movie.mp4.2'), 'mp4');
      expect(FileUtils.effectiveExtensionWithDot('/d/movie.mp4.2'), '.mp4');
    });

    test('大小写统一为小写', () {
      expect(FileUtils.effectiveExtensionWithDot('photo.JPG'), '.jpg');
      expect(FileUtils.effectiveExtensionWithDot('Photo.JpG.1'), '.jpg');
    });

    test('无扩展名 / 前导点 → 空串', () {
      expect(FileUtils.effectiveExtensionWithDot('noext'), '');
      expect(FileUtils.effectiveExtensionWithDot('.nomedia'), '');
      expect(FileUtils.effectiveExtensionWithDot('app.apk.'), '');
      expect(FileUtils.effectiveExtension('noext'), '');
    });

    test('多段扩展名只取最后一段（分卷仍可见 .001）', () {
      expect(FileUtils.effectiveExtensionWithDot('archive.tar.gz'), '.gz');
      expect(FileUtils.effectiveExtensionWithDot('archive.zip.001'), '.001');
    });
  });

  group('类型判定接入归一化（用户可见效果）', () {
    test('安装包：apk.1 必须认出来，否则会被当 zip 解压安装', () {
      expect(FileUtils.isInstallPackage('app.apk.1'), isTrue);
      expect(FileUtils.isInstallPackage('app.apk'), isTrue);
      expect(FileUtils.isInstallPackage('bundle.xapk.1'), isTrue);
      expect(FileUtils.isInstallPackage('archive.zip.1'), isFalse);
      expect(FileUtils.getInstallPackageTypeLabel('app.apk.1'), 'APK');
      expect(FileUtils.getInstallPackageTypeLabel('bundle.xapk.2'), 'XAPK');
      expect(FileUtils.getIconForFile('app.apk.1'), Icons.android_rounded);
    });

    test('图片 / 视频 / 音频', () {
      expect(FileUtils.isImage('photo.jpg.1'), isTrue);
      expect(FileUtils.isVideo('clip.mp4.1'), isTrue);
      expect(FileUtils.isAudio('song.mp3.1'), isTrue);
      expect(FileUtils.getImageTypeLabel('photo.jpg.1'), 'JPG');
      expect(FileUtils.getVideoTypeLabel('clip.mkv.3'), 'MKV');
      expect(FileUtils.getAudioTypeLabel('song.flac.1'), 'FLAC');
    });

    test('SVG 单独判定（isImage 刻意排除 SVG）', () {
      expect(FileUtils.isSvg('icon.svg.1'), isTrue);
      expect(FileUtils.isSvg('icon.svg'), isTrue);
      expect(FileUtils.isImage('icon.svg.1'), isFalse);
    });

    test('压缩包 / 文档', () {
      expect(FileUtils.isArchive('data.zip.1'), isTrue);
      expect(FileUtils.isArchive('data.zip'), isTrue);
      expect(FileUtils.isDocument('report.pdf.1'), isTrue);
      expect(FileUtils.isDocument('report.pdf'), isTrue);
      expect(FileUtils.getDocumentTypeLabel('report.pdf.1'), 'PDF');
    });

    test('文本 / 代码', () {
      expect(FileUtils.isTextOrCode('note.txt.1'), isTrue);
      expect(FileUtils.isTextOrCode('main.dart.1'), isTrue);
      expect(FileUtils.isTextOrCode('app.apk.1'), isFalse);
    });
  });

  group('回归护栏（不该被这次归一化改动影响）', () {
    test('zip 分卷 .001 仍是压缩包，标签保留 001', () {
      expect(FileUtils.isArchive('archive.zip.001'), isTrue);
      expect(FileUtils.getArchiveTypeLabel('archive.zip.001'), '001');
    });

    test('多段扩展名不受影响', () {
      expect(FileUtils.isArchive('archive.tar.gz'), isTrue);
      expect(FileUtils.getArchiveTypeLabel('archive.tar.gz'), 'GZ');
      expect(FileUtils.isArchive('archive.tar.bz2'), isTrue);
    });

    test('普通文件名判定与归一化前完全一致', () {
      expect(FileUtils.isInstallPackage('app.apk'), isTrue);
      expect(FileUtils.isImage('photo.png'), isTrue);
      expect(FileUtils.isVideo('clip.mp4'), isTrue);
      expect(FileUtils.isAudio('song.mp3'), isTrue);
      expect(FileUtils.isArchive('data.zip'), isTrue);
      expect(FileUtils.isDocument('report.docx'), isTrue);
      expect(FileUtils.isTextOrCode('lib/main.dart'), isTrue);
      expect(FileUtils.isInstallPackage('photo.png'), isFalse);
    });

    test('无扩展名文件按文本处理（历史行为）', () {
      expect(FileUtils.isTextOrCode('hosts'), isTrue);
      expect(FileUtils.isTextOrCode('/etc/hosts'), isTrue);
    });

    test('相似但非 IM 追加的名字不被改写，判定也保持原样', () {
      // 这两个是「点号前无扩展名」，按原名字判定：既不剥，也不该突然变成文档/安装包
      expect(FileUtils.stripImAppendedSuffix('README.1'), 'README.1');
      expect(FileUtils.isInstallPackage('README.1'), isFalse);
      expect(FileUtils.isDocument('README.1'), isFalse);
    });
  });
}
