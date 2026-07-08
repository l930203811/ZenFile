import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:zenfile/main.dart';
import 'package:zenfile/providers/file_manager_provider.dart';
import 'package:zenfile/providers/media_provider.dart';

void main() {
  testWidgets('ZenFileApp initialization smoke test', (WidgetTester tester) async {
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider(create: (_) => FileManagerProvider()),
          ChangeNotifierProvider(create: (_) => MediaProvider()),
        ],
        child: const ZenFileApp(),
      ),
    );

    expect(find.byType(MaterialApp), findsOneWidget);
  });
}
