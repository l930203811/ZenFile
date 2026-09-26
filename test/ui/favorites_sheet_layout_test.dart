import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 复刻 `FavoritesSheet` 的布局骨架，专门钉住「面板高度随内容自适应」这条约束。
///
/// 这里最容易踩的坑：把列表区的 `Flexible` 写成 `Expanded`。
/// 旧版是右侧抽屉（父级高度已确定）所以能用 `Expanded`；改成底部面板后高度
/// 由内容决定，`Expanded` 在高度无界的滚动列里会直接抛异常，同时也会顶掉
/// 「折叠后变矮」的自适应行为。
class _Harness extends StatelessWidget {
  const _Harness({required this.items});

  final int items;

  @override
  Widget build(BuildContext context) {
    final maxHeight = MediaQuery.of(context).size.height * 0.68;
    return AnimatedSize(
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOut,
      alignment: Alignment.bottomCenter,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxHeight),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(width: 36, height: 4, color: Colors.black26),
            Container(key: const ValueKey('header'), height: 40, color: Colors.blue),
            Flexible(
              child: SingleChildScrollView(
                child: Column(
                  children: [
                    for (var i = 0; i < items; i++)
                      Container(key: ValueKey('item$i'), height: 40, color: Colors.grey),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

Future<void> _openSheet(
  WidgetTester tester,
  Widget Function(BuildContext context, StateSetter setState) onBuild,
) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (ctx) => Center(
            child: TextButton(
              onPressed: () => showModalBottomSheet<void>(
                context: ctx,
                isScrollControlled: true,
                builder: (_) => StatefulBuilder(builder: onBuild),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

double _screenHeight(WidgetTester tester) =>
    tester.view.physicalSize.height / tester.view.devicePixelRatio;

void main() {
  testWidgets('内容少：面板按实际内容收矮，不占满上限', (tester) async {
    await _openSheet(tester, (ctx, setState) => const _Harness(items: 2));

    final height = tester.getSize(find.byType(_Harness)).height;
    // 4（把手）+ 40（标题）+ 2×40（条目）= 124
    expect(height, closeTo(124, 1));
    expect(height, lessThan(_screenHeight(tester) * 0.68));
  });

  testWidgets('内容多：封顶 68% 屏高，超出部分靠内部滚动', (tester) async {
    await _openSheet(tester, (ctx, setState) => const _Harness(items: 50));

    final height = tester.getSize(find.byType(_Harness)).height;
    expect(height, closeTo(_screenHeight(tester) * 0.68, 1));
    final beforeY = tester.getTopLeft(find.byKey(const ValueKey('item49'))).dy;
    await tester.drag(find.byType(SingleChildScrollView), const Offset(0, -2000));
    await tester.pumpAndSettle();
    final afterY = tester.getTopLeft(find.byKey(const ValueKey('item49'))).dy;
    // 能真的滚起来 = 超出上限的部分交回给内部滚动，而不是被裁掉
    expect(afterY, lessThan(beforeY));
  });

  testWidgets('折叠收起后：面板跟着自动收矮（本次改造的核心诉求）', (tester) async {
    var items = 12;
    late StateSetter sheetSetState;
    await _openSheet(tester, (ctx, setState) {
      sheetSetState = setState;
      return _Harness(items: items);
    });

    final before = tester.getSize(find.byType(_Harness)).height;
    // 12×40 + 44 = 524 > 上限，此时已封顶
    expect(before, closeTo(_screenHeight(tester) * 0.68, 1));

    // 触发重建：条目从 12 条收到 2 条（等价于某个分组被折叠）
    sheetSetState(() => items = 2);
    await tester.pumpAndSettle();

    final after = tester.getSize(find.byType(_Harness)).height;
    expect(after, closeTo(124, 1));
    expect(after, lessThan(before));
  });
}
