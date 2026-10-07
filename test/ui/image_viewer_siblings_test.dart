// 回归测试：从「浏览页」直接打开图片（调用方**不传** siblingPaths / siblingItems）
// 时必须满足三条 —— 这正是 v3.5.0 ~ v3.5.4 的退化点：
//   1. 首帧立即渲染（`_imageList` 不能为空 ⇒ itemCount 不能是 0，否则用户看到空白）；
//   2. 目录扫描完成后拿到完整兄弟列表（旧版因 isolate 闭包捕获 `this` 抛
//      `Illegal argument in isolate message` 且被 `catch (_)` 吞掉 ⇒ 恒「1 of 1」）；
//   3. 拿到列表后当前页要落在正确的那一张，且可以左右滑动切换。
//
// 同目录的非图片文件（.mp4 / .txt）不得进入列表。
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:photo_view/photo_view_gallery.dart';
import 'package:zenfile/l10n/generated/app_localizations.dart';
import 'package:zenfile/ui/screens/image_viewer_screen.dart';

/// 1x1 的合法 PNG —— 必须能被真正解码，否则 `Image` 的解码失败会走
/// `FlutterError.onError` 直接把测试判失败（生产代码没有 errorBuilder）。
final Uint8List _kPng1x1 = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
);

/// 等后台目录扫描落地。
///
/// 扫描跑在真实 isolate 里，回包要靠**真实事件循环**投递（`pump(Duration)`
/// 只推进假时钟）；而 `_findSiblings` 里 `await` 的续体又落在假 zone 的微任务
/// 队列里（只能靠 `pump()` 冲刷）—— 所以两者必须交替进行。
Future<void> _settleIsolateScan(
  WidgetTester tester,
  Finder target, {
  int maxSpins = 60,
}) async {
  var spins = 0;
  while (spins < maxSpins && target.evaluate().isEmpty) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pump();
    spins++;
  }
  await tester.pumpAndSettle();
  expect(spins, lessThan(maxSpins), reason: '目录扫描迟迟不落地：$target 始终没出现');
}

void main() {
  late Directory dir;
  late List<String> imagePaths;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('zf_iv_siblings_');
    imagePaths = <String>[];
    for (var i = 0; i < 42; i++) {
      final path = p.join(dir.path, 'img_${i.toString().padLeft(2, '0')}.png');
      File(path).writeAsBytesSync(_kPng1x1);
      imagePaths.add(path);
    }
    // 同目录的非图片文件：既验证过滤，也验证不再对每个非图片文件读文件头。
    File(p.join(dir.path, 'clip.mp4')).writeAsBytesSync(List<int>.filled(64, 0));
    File(p.join(dir.path, 'notes.txt')).writeAsStringSync('hello');
  });

  tearDown(() {
    // 图片解码器/文件句柄可能仍持有该文件（Windows 下 deleteSync 会报 errno 32），
    // 这是临时目录，删不掉不影响断言，忽略即可。
    try {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  Widget wrap(String path) => MaterialApp(
    localizationsDelegates: L10n.localizationsDelegates,
    home: ImageViewerScreen(imagePath: path),
  );

  testWidgets('无 siblingPaths：首帧即渲染 → 扫到 42 张 → 定位当前页 → 可左右滑动', (tester) async {
    await tester.pumpWidget(wrap(imagePaths[7]));

    // 1. 首帧占位：立刻是「1 of 1」，而不是 itemCount=0 的空白
    expect(
      find.text('1 of 1'),
      findsOneWidget,
      reason: '首帧必须有内容占位（旧版 _imageList 为空 ⇒ 空白等好几秒）',
    );
    expect(find.byType(PhotoViewGallery), findsOneWidget);

    // 2. 扫描完成后：总数 42（.mp4 / .txt 被过滤）、当前页是第 8 张
    await _settleIsolateScan(tester, find.text('8 of 42'));
    expect(
      find.text('8 of 42'),
      findsOneWidget,
      reason: '出现「1 of 1」说明 isolate 传参又抛错被兜底吞掉了；'
          '「1 of 42」说明跳页没等新列表 rebuild',
    );

    // 3. 左右滑动
    await tester.fling(
      find.byType(PhotoViewGallery),
      const Offset(-300, 0),
      900,
    );
    await tester.pumpAndSettle();
    expect(find.text('9 of 42'), findsOneWidget, reason: '左滑应切到下一张');

    await tester.fling(
      find.byType(PhotoViewGallery),
      const Offset(300, 0),
      900,
    );
    await tester.pumpAndSettle();
    expect(find.text('8 of 42'), findsOneWidget, reason: '右滑应回到上一张');
  });

  testWidgets('传入 siblingPaths 时直接用给定列表（计数与当前页都正确）', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: L10n.localizationsDelegates,
        home: ImageViewerScreen(
          imagePath: imagePaths[7],
          siblingPaths: imagePaths,
        ),
      ),
    );
    await tester.pump();

    expect(find.text('8 of 42'), findsOneWidget);
    expect(find.text('img_07.png'), findsOneWidget, reason: '标题取当前图片文件名');
  });

  testWidgets('路径分隔符混用（Windows / 与 \\）也要定位到当前页而非 1 of N', (tester) async {
    final mixed = imagePaths[7].replaceAll(r'\', '/');
    expect(mixed, isNot(imagePaths[7]), reason: 'Windows 下才可能出现混用');

    await tester.pumpWidget(wrap(mixed));
    await _settleIsolateScan(tester, find.text('8 of 42'));
    expect(find.text('8 of 42'), findsOneWidget);
  });

  testWidgets('目录里只有非图片文件时不报错，退化为单张', (tester) async {
    final lone = Directory.systemTemp.createTempSync('zf_iv_lone_');
    addTearDown(() {
      try {
        if (lone.existsSync()) lone.deleteSync(recursive: true);
      } catch (_) {}
    });
    final only = p.join(lone.path, 'a.png');
    File(only).writeAsBytesSync(_kPng1x1);
    File(p.join(lone.path, 'a.mp4')).writeAsBytesSync(List<int>.filled(64, 0));

    await tester.pumpWidget(wrap(only));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 800)),
    );
    await tester.pumpAndSettle();
    expect(find.text('1 of 1'), findsOneWidget);
  });
}
