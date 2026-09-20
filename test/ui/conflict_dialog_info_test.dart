import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zenfile/l10n/generated/app_localizations.dart';
import 'package:zenfile/l10n/generated/app_localizations_zh.dart';
import 'package:zenfile/ui/widgets/conflict_dialog.dart';

/// 「文件已存在」冲突弹窗的渲染回归（本地 ↔ 远程各粘贴链路共用）。
///
/// 覆盖历史缺陷：远程文件没有本地路径，旧调用方给两侧传 `File('')`。Dart 的
/// `File('').stat()` **不抛异常**，而是返回 `size: -1 / 1970-01-01`，经 `formatBytes`
/// 后弹窗显示「0 B · 1970-01-01」；且旧实现 stat 抛异常时 `_statsLoaded` 留在 false →
/// 永久转圈（用户只看到一个「死」弹窗）。
///
/// 这里只覆盖**渲染**：真实文件 stat 分支见
/// `test/ui/conflict_file_info_resolve_test.dart`（widget 测试的 FakeAsync 不驱动
/// `dart:io`，真实 stat 的 Future 永不完成）。
Widget _host(Widget child) => MaterialApp(
      locale: const Locale('zh'),
      localizationsDelegates: L10n.localizationsDelegates,
      supportedLocales: L10n.supportedLocales,
      home: Scaffold(body: child),
    );

/// 推进微任务并重建两帧（信息解析是 async，首帧还在 loading）。
Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump();
}

void main() {
  const fileName = 'app-arm64-v8a-release.apk';

  testWidgets('远程两侧 + 提供远程信息 → 显示真实大小/时间，绝不显示 0 B/1970', (tester) async {
    await tester.pumpWidget(_host(ConflictDialog(
      fileName: fileName,
      sourceFile: File(''),
      destFile: File(''),
      sourceInfo: ConflictFileInfo(
        size: 2 * 1024 * 1024,
        modified: DateTime(2026, 9, 19, 23, 40),
      ),
      destInfo: ConflictFileInfo(
        size: 4 * 1024 * 1024,
        modified: DateTime(2026, 9, 18, 12, 0),
      ),
    )));
    await _settle(tester);

    expect(find.textContaining(fileName), findsOneWidget);
    expect(find.text('2.00 MB'), findsOneWidget, reason: '新建（远程源）的真实大小');
    expect(find.text('4.00 MB'), findsOneWidget, reason: '现有（远程目标）的真实大小');
    expect(find.textContaining('2026-09-19'), findsOneWidget);
    expect(find.textContaining('2026-09-18'), findsOneWidget);

    // 关键回归：不得出现 Dart 对空路径 stat 得到的伪值（size=-1 → 「0 B」、
    // modified=epoch → 「1970-01-01」）
    expect(find.text('0 B'), findsNothing);
    expect(find.textContaining('1970'), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets('信息未知（远程列表拿不到 mtime/size）→ 显示 — 而不是 0 B / 1970', (tester) async {
    await tester.pumpWidget(_host(ConflictDialog(
      fileName: fileName,
      sourceFile: File(''),
      destFile: File(''),
      sourceInfo: const ConflictFileInfo(),
      destInfo: const ConflictFileInfo(),
    )));
    await _settle(tester);

    expect(find.text('—'), findsNWidgets(4), reason: '两张卡片的大小与时间各显示一个 —');
    expect(find.textContaining('1970'), findsNothing);
    expect(find.text('0 B'), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsNothing,
        reason: '信息解析必须结束，不能留下永久转圈');
  });

  testWidgets('修改时间未知时不给「较新」高亮（不拿未知值比较）', (tester) async {
    await tester.pumpWidget(_host(ConflictDialog(
      fileName: fileName,
      sourceFile: File(''),
      destFile: File(''),
      sourceInfo: const ConflictFileInfo(size: 100),
      destInfo: ConflictFileInfo(
        size: 200,
        modified: DateTime(2026, 9, 19, 23, 40),
      ),
    )));
    await _settle(tester);

    expect(find.text('100.00 B'), findsOneWidget, reason: 'size 已知仍照常显示');
    expect(find.text(L10nZh().msg_newer), findsNothing);
  });

  testWidgets('两侧时间都已知且源较新 → 只在「新建文件」卡片上出现一次「较新」', (tester) async {
    await tester.pumpWidget(_host(ConflictDialog(
      fileName: fileName,
      sourceFile: File(''),
      destFile: File(''),
      sourceInfo: ConflictFileInfo(
        size: 100,
        modified: DateTime(2026, 9, 19, 23, 40),
      ),
      destInfo: ConflictFileInfo(
        size: 200,
        modified: DateTime(2026, 9, 18, 10, 0),
      ),
    )));
    await _settle(tester);

    expect(find.text(L10nZh().msg_newer), findsOneWidget);
  });

  testWidgets('两侧时间都已知且目标较新 → 「较新」标在现有文件一侧（同样只出现一次）', (tester) async {
    await tester.pumpWidget(_host(ConflictDialog(
      fileName: fileName,
      sourceFile: File(''),
      destFile: File(''),
      sourceInfo: ConflictFileInfo(
        size: 100,
        modified: DateTime(2026, 9, 18, 10, 0),
      ),
      destInfo: ConflictFileInfo(
        size: 200,
        modified: DateTime(2026, 9, 19, 23, 40),
      ),
    )));
    await _settle(tester);

    expect(find.text(L10nZh().msg_newer), findsOneWidget);
  });
}
