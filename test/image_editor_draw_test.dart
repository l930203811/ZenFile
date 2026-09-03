import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zenfile/l10n/generated/app_localizations.dart';
import 'package:zenfile/ui/screens/image_editor_screen.dart';

Future<Uint8List> makePng() async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawRect(
    const Rect.fromLTWH(0, 0, 320, 240),
    Paint()..color = const Color(0xFFFF0000),
  );
  final img = await recorder.endRecording().toImage(320, 240);
  final data = await img.toByteData(format: ui.ImageByteFormat.png);
  return data!.buffer.asUint8List();
}

Widget wrap(Widget child) => MaterialApp(
  localizationsDelegates: const [
    GlobalMaterialLocalizations.delegate,
    GlobalWidgetsLocalizations.delegate,
    GlobalCupertinoLocalizations.delegate,
    L10n.delegate,
  ],
  supportedLocales: L10n.supportedLocales,
  locale: const Locale('en'),
  home: child,
);

final _painterFinder = find.byWidgetPredicate(
  (w) =>
      w is CustomPaint &&
      w.painter != null &&
      w.painter!.runtimeType.toString() == '_DrawPreviewPainter',
);

dynamic get painter => (_painterFinder.evaluate().single.widget as CustomPaint)
    .painter as dynamic;

Rect displayRect() => painter.displayRect as Rect;

List<Map<dynamic, dynamic>> get strokes =>
    (painter.strokes as List).cast<Map<dynamic, dynamic>>();

Offset toGlobal(Offset local) {
  final box = _painterFinder.evaluate().single.renderObject! as RenderBox;
  return box.localToGlobal(local);
}

/// 归一化点 → 全局坐标（基于 painter 的 displayRect）。
Offset normToGlobal(Offset n) {
  final d = displayRect();
  return toGlobal(Offset(d.left + n.dx * d.width, d.top + n.dy * d.height));
}

void main() {
  testWidgets('text box create, edit, commit, handle drag', (tester) async {
    await tester.runAsync(() async {
      final png = await makePng();
      final file = File(
        '${Directory.systemTemp.path}/editor_draw_test_${DateTime.now().millisecondsSinceEpoch}.png',
      );
      await file.writeAsBytes(png);

      await tester.pumpWidget(wrap(ImageEditorScreen(imagePath: file.path)));
      await tester.pump();
      await Future<void>.delayed(const Duration(milliseconds: 500));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      // 切到绘图 tab
      await tester.tap(find.text('Draw'));
      await tester.pump();
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      // 点击文本工具 → 中心区框
      await tester.tap(find.text('Text'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      expect(strokes.length, 1, reason: '文本工具应创建 1 个中心区框对象');
      expect(strokes[0]['tool'], 'text');

      // 点击区框中心 → 就地输入
      await tester.tapAt(normToGlobal(const Offset(0.5, 0.5)));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.byType(TextField), findsOneWidget);

      // 输入文本
      await tester.enterText(find.byType(TextField), 'Hello');
      await tester.pump();

      // 点击区框外空白处 → 提交
      await tester.tapAt(normToGlobal(const Offset(0.05, 0.1)));
      await tester.pump();
      await Future<void>.delayed(const Duration(milliseconds: 700));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      // ignore: avoid_print
      print('strokes after commit: $strokes');
      expect(
        strokes.isNotEmpty && strokes[0]['text'] == 'Hello',
        isTrue,
        reason: '提交后文本应写回对象',
      );

      // 手柄拖拽：从右下角向外拖 → 放大
      final obj = strokes[0];
      final br = normToGlobal(
        Offset(
          ((obj['x'] as num) + (obj['w'] as num)).toDouble(),
          ((obj['y'] as num) + (obj['h'] as num)).toDouble(),
        ),
      );
      final g = await tester.startGesture(br);
      await tester.pump();
      await g.moveBy(const Offset(60, 30));
      await tester.pump();
      // ignore: avoid_print
      print('mid-drag objDraftRect: ${painter.objDraftRect}');
      await g.moveBy(const Offset(30, 20));
      await tester.pump();
      await g.up();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      final obj2 = strokes[0];
      // ignore: avoid_print
      print('obj after handle drag: $obj2');
      expect(
        (obj2['w'] as num) > (obj['w'] as num) ||
            (obj2['h'] as num) > (obj['h'] as num),
        isTrue,
        reason: '手柄向外拖拽应放大区框',
      );
    });
  });

  testWidgets('handle drag works while text editing (input box hidden)', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final png = await makePng();
      final file = File(
        '${Directory.systemTemp.path}/editor_draw_test3_${DateTime.now().millisecondsSinceEpoch}.png',
      );
      await file.writeAsBytes(png);

      await tester.pumpWidget(wrap(ImageEditorScreen(imagePath: file.path)));
      await tester.pump();
      await Future<void>.delayed(const Duration(milliseconds: 500));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      await tester.tap(find.text('Draw'));
      await tester.pump();
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      await tester.tap(find.text('Text'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      // 点击区框中心 → 进入就地输入（隐藏的 1×1 TextField）
      await tester.tapAt(normToGlobal(const Offset(0.5, 0.5)));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.byType(TextField), findsOneWidget);

      // 输入中实时文字应传给画笔（绘制在区框内）
      await tester.enterText(find.byType(TextField), 'Hi');
      await tester.pump();
      expect(painter.editText, 'Hi', reason: '输入中文字应实时绘制到区框');
      expect(painter.textEditIdx, greaterThan(-1));

      // 输入中直接拖右下角手柄 → 区框放大，且不中断输入（输入框仍存在）
      final before = Rect.fromLTWH(
        (strokes[0]['x'] as num).toDouble(),
        (strokes[0]['y'] as num).toDouble(),
        (strokes[0]['w'] as num).toDouble(),
        (strokes[0]['h'] as num).toDouble(),
      );
      final br = normToGlobal(before.bottomRight);
      final g = await tester.startGesture(br);
      await tester.pump();
      await g.moveBy(const Offset(80, 40));
      await tester.pump();
      await g.up();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.byType(TextField), findsOneWidget, reason: '手柄拖拽不应中断输入');
      final after = Rect.fromLTWH(
        (strokes[0]['x'] as num).toDouble(),
        (strokes[0]['y'] as num).toDouble(),
        (strokes[0]['w'] as num).toDouble(),
        (strokes[0]['h'] as num).toDouble(),
      );
      expect(
        after.width > before.width || after.height > before.height,
        isTrue,
        reason: '输入中手柄拖拽应放大区框',
      );

      // 提交：文字写回且保留缩放后的尺寸
      await tester.tapAt(normToGlobal(const Offset(0.05, 0.1)));
      await tester.pump();
      await Future<void>.delayed(const Duration(milliseconds: 700));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(strokes[0]['text'], 'Hi', reason: '提交后文字应写回对象');
      expect(
        (strokes[0]['h'] as num) > before.height,
        isTrue,
        reason: '提交后应保留输入中缩放的区框高度（文字随框放大）',
      );
    });
  });

  testWidgets('ellipse drag creates shape object', (tester) async {
    await tester.runAsync(() async {
      final png = await makePng();
      final file = File(
        '${Directory.systemTemp.path}/editor_draw_test4_${DateTime.now().millisecondsSinceEpoch}.png',
      );
      await file.writeAsBytes(png);

      await tester.pumpWidget(wrap(ImageEditorScreen(imagePath: file.path)));
      await tester.pump();
      await Future<void>.delayed(const Duration(milliseconds: 500));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      await tester.tap(find.text('Draw'));
      await tester.pump();
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      await tester.tap(find.text('Ellipse'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(strokes.isEmpty, isTrue);

      // 拖拽过程中草稿应实时更新（画笔画出椭圆预览）
      final g = await tester.startGesture(normToGlobal(const Offset(0.2, 0.2)));
      await tester.pump();
      await g.moveBy(const Offset(150, 100));
      await tester.pump();
      expect(painter.draftStart, isNotNull, reason: '拖拽中应有椭圆草稿');
      expect(
        (painter.draftEnd as Offset) != (painter.draftStart as Offset),
        isTrue,
        reason: '拖拽中草稿终点应跟随手指',
      );
      await g.up();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(strokes.length, 1, reason: '松手应提交 1 个椭圆对象');
      expect(strokes[0]['tool'], 'ellipse');
      expect((strokes[0]['w'] as num) > 0, isTrue);
      expect((strokes[0]['h'] as num) > 0, isTrue);
    });
  });

  testWidgets('rect drag creates shape object', (tester) async {
    await tester.runAsync(() async {
      final png = await makePng();
      final file = File(
        '${Directory.systemTemp.path}/editor_draw_test2_${DateTime.now().millisecondsSinceEpoch}.png',
      );
      await file.writeAsBytes(png);

      await tester.pumpWidget(wrap(ImageEditorScreen(imagePath: file.path)));
      await tester.pump();
      await Future<void>.delayed(const Duration(milliseconds: 500));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      await tester.tap(find.text('Draw'));
      await tester.pump();
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      await tester.tap(find.text('Rectangle'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(strokes.isEmpty, isTrue, reason: '矩形工具不应预建对象');

      // 从左上空白拖到中部
      final g = await tester.startGesture(normToGlobal(const Offset(0.1, 0.1)));
      await tester.pump();
      await g.moveBy(
        normToGlobal(const Offset(0.5, 0.4)) -
            normToGlobal(const Offset(0.1, 0.1)),
      );
      await tester.pump();
      // ignore: avoid_print
      print(
        'mid-drag draft: ${painter.draftStart} -> ${painter.draftEnd}',
      );
      await tester.pump(const Duration(milliseconds: 50));
      await g.up();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      // ignore: avoid_print
      print('strokes after rect drag: $strokes');
      expect(strokes.length, 1, reason: '拖拽应提交 1 个矩形对象');
      expect(strokes[0]['tool'], 'rect');
      expect((strokes[0]['w'] as num) > 0, isTrue);
    });
  });
}
