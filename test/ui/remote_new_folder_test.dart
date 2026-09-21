import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zenfile/l10n/generated/app_localizations.dart';
import 'package:zenfile/services/remote/remote_client.dart';
import 'package:zenfile/ui/widgets/remote_path_picker.dart';

/// 「远程目录选择器 → 新建文件夹」的回归。
///
/// 四个入口共用 `createRemoteFolderInteractive`：
///   ① 分类页「远程」加号（media_category_screen）
///   ② 媒体分类设置页（media_category_settings_screen）
///   ③ 保险箱「关联远程加密目录」（vault_explorer_screen）
///   ④ 设置-备份与恢复的自定义远程目录（backup_settings_screen → RemoteDirectoryPickerScreen）
///
/// 这里只钉住与入口无关的公共部分：弹窗标题走 l10n、路径拼接不产生双斜杠、
/// 取消/空名不建目录、创建失败必须给用户反馈（不能静默失败）。
class _FakeRemoteClient extends RemoteClient {
  final List<String> created = [];

  /// 为 true 时 `createDirectory` 抛异常，模拟权限不足 / 目录已存在。
  bool shouldThrow = false;

  @override
  Future<void> connect() async {}

  @override
  Future<void> disconnect() async {}

  @override
  Future<List<RemoteFileItem>> listDirectory(String path,
          {bool forceRefresh = false}) async =>
      const [];

  @override
  Future<void> createDirectory(String path) async {
    if (shouldThrow) throw Exception('permission denied');
    created.add(path);
  }

  @override
  Future<void> createFile(String path) async {}

  @override
  Future<void> delete(String path, bool isDir) async {}

  @override
  Future<void> rename(String oldPath, String newPath) async {}

  @override
  Future<void> downloadFile(String remotePath, String localPath,
      Function(double progress) onProgress) async {}

  @override
  Future<void> downloadRange(
      String remotePath, String localPath, int startByte, int length) async {}

  @override
  Future<void> uploadFile(String localPath, String remotePath,
      Function(double progress) onProgress) async {}

  @override
  Future<String?> getStreamUrl(String remotePath) async => null;

  @override
  Future<int> getFileSize(String remotePath) async => 0;
}

void main() {
  /// 把 helper 挂到一个真实按钮上（helper 内部要 ScaffoldMessenger，故需在
  /// Scaffold 之下的 context 调用）。
  Future<bool? Function()> mount(
    WidgetTester tester,
    _FakeRemoteClient client,
    String currentPath,
  ) async {
    bool? result;
    await tester.pumpWidget(MaterialApp(
      locale: const Locale('zh'),
      localizationsDelegates: L10n.localizationsDelegates,
      supportedLocales: L10n.supportedLocales,
      home: Scaffold(
        body: Builder(
          builder: (ctx) => Center(
            child: ElevatedButton(
              onPressed: () async {
                result = await createRemoteFolderInteractive(
                  context: ctx,
                  client: client,
                  currentPath: currentPath,
                );
              },
              child: const Text('go'),
            ),
          ),
        ),
      ),
    ));
    return () => result;
  }

  testWidgets('输入名称 → 在「当前远程目录」下建同名文件夹，标题走 l10n（中文）',
      (tester) async {
    final client = _FakeRemoteClient();
    final got = await mount(tester, client, '/share');

    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();

    // 弹窗标题即「新建文件夹」，说明按钮/弹窗文案全部走 l10n key（10 语言齐备）
    expect(find.text('新建文件夹'), findsOneWidget);

    await tester.enterText(find.byType(TextField), '2026备份');
    await tester.tap(find.text('创建'));
    await tester.pumpAndSettle();

    expect(client.created, ['/share/2026备份']);
    expect(got(), isTrue);
  });

  testWidgets('当前路径以 / 结尾时不产生双斜杠', (tester) async {
    final client = _FakeRemoteClient();
    await mount(tester, client, '/share/');

    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'sub');
    await tester.tap(find.text('创建'));
    await tester.pumpAndSettle();

    expect(client.created, ['/share/sub']);
  });

  testWidgets('SMB 根目录（/）下新建 → /名称', (tester) async {
    final client = _FakeRemoteClient();
    await mount(tester, client, '/');

    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'docs');
    await tester.tap(find.text('创建'));
    await tester.pumpAndSettle();

    expect(client.created, ['/docs']);
  });

  testWidgets('取消 → 返回 false，不发任何创建请求', (tester) async {
    final client = _FakeRemoteClient();
    final got = await mount(tester, client, '/share');

    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();

    expect(client.created, isEmpty);
    expect(got(), isFalse);
  });

  testWidgets('空名称 / 纯空格 → 不建目录，也不报错', (tester) async {
    final client = _FakeRemoteClient();
    final got = await mount(tester, client, '/share');

    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '   ');
    await tester.tap(find.text('创建'));
    await tester.pumpAndSettle();

    expect(client.created, isEmpty);
    expect(got(), isFalse);
    expect(find.byType(SnackBar), findsNothing);
  });

  testWidgets('创建失败（权限不足）→ 返回 false 且必须弹提示，不能静默失败',
      (tester) async {
    final client = _FakeRemoteClient()..shouldThrow = true;
    final got = await mount(tester, client, '/share');

    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'no_perm');
    await tester.tap(find.text('创建'));
    await tester.pumpAndSettle();

    expect(got(), isFalse);
    expect(find.byType(SnackBar), findsOneWidget);
  });

  group('底栏排版：低 DPI / 系统大字号 + 其它语言都不许溢出', () {
    /// 真机回归：德语 `Neuer Ordner` / `Abbrechen` / `Diesen Ordner auswählen`
    /// 三个按钮挤在同一行时，主按钮被整个顶出屏幕右侧（只看到 "Diesen…"）。
    /// 修法是把「次要操作」与「主操作」拆成两行，文案再带 ellipsis 兜底。
    Future<void> pumpBar(
      WidgetTester tester, {
      required String locale,
      required double textScale,
    }) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(MaterialApp(
        locale: Locale(locale),
        localizationsDelegates: L10n.localizationsDelegates,
        supportedLocales: L10n.supportedLocales,
        builder: (ctx, child) => MediaQuery(
          data: MediaQuery.of(ctx)
              .copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
        home: Scaffold(
          bottomNavigationBar: Builder(
            builder: (ctx) => buildRemotePickerActionBar(
              context: ctx,
              onCreateFolder: () {},
              onSelect: () {},
              onCancel: () {},
            ),
          ),
        ),
      ));
      await tester.pumpAndSettle();
    }

    const locales = ['de', 'de', 'ru', 'fr', 'zh'];
    const scales = [1.0, 1.5, 1.5, 2.0, 1.0];
    for (var i = 0; i < locales.length; i++) {
      final locale = locales[i];
      final scale = scales[i];

      testWidgets('$locale × 字号 $scale × 360dp：不溢出且主按钮完整在屏内',
          (tester) async {
        await pumpBar(tester, locale: locale, textScale: scale);

        // 任何 RenderFlex overflow 都会被这里抓到（旧版单行布局在此必失败）
        expect(tester.takeException(), isNull, reason: '底栏不得溢出');

        final screenWidth =
            tester.view.physicalSize.width / tester.view.devicePixelRatio;
        final selectRect = tester.getRect(find.byType(FilledButton));
        expect(selectRect.right, lessThanOrEqualTo(screenWidth),
            reason: '主按钮右边缘不得超出屏幕');

        final newFolderIcon = tester.getRect(
          find.byIcon(Icons.create_new_folder_outlined),
        );
        expect(newFolderIcon.left, greaterThanOrEqualTo(0),
            reason: '「新建文件夹」不得被推出左边界');
        expect(newFolderIcon.bottom, lessThanOrEqualTo(selectRect.top),
            reason: '次要操作在前一行、主操作独占后一行');

        // 优化目标：主按钮**独占一整行**（不再和「新建文件夹 / 取消」抢宽度）。
        // 断言宽度而非文案是否被省略——`flutter test` 用的是等宽占位字体
        // （每个字形 = 一个方块，实测宽度约真实字体的 2 倍），拿它断言文案宽度
        // 没有意义；「按钮拿到满行宽度」才是与字体无关的硬约束。
        expect(selectRect.width, greaterThanOrEqualTo(screenWidth - 24 - 1),
            reason: '主按钮必须横向铺满整行（左右各 12 padding）');
      });
    }
  });
}
