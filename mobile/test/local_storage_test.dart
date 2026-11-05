import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sorryread_mobile/design_system/app_theme.dart';
import 'package:sorryread_mobile/features/profile/data/local_storage.dart';
import 'package:sorryread_mobile/features/profile/presentation/local_storage_page.dart';

import 'app_shell_test.dart' as app_test;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final calls = <String>[];
  late Map<String, dynamic> snapshot;
  Completer<void>? pending;
  bool fail = false;

  setUpAll(() async {
    await (FontLoader(
      'Roboto',
    )..addFont(rootBundle.load('assets/fonts/hei.otf'))).load();
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
  });

  setUp(() {
    calls.clear();
    pending = null;
    fail = false;
    snapshot = {
      'necessary': 168 * 1024 * 1024,
      'downloads': 7 * 1024 * 1024,
      'cache': 36 * 1024 * 1024,
      'deviceTotal': 128 * 1024 * 1024 * 1024,
      'deviceFree': 53 * 1024 * 1024 * 1024,
      'indexCount': 25230,
      'indexUpdated': DateTime(2026, 11, 3).millisecondsSinceEpoch,
    };
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(LocalStorageRepository.channel, (call) async {
          calls.add(call.method);
          if (call.method == 'snapshot') return snapshot;
          await pending?.future;
          if (fail) {
            throw PlatformException(code: 'storage', message: '操作未完成，请重试');
          }
          if (call.method == 'clearCache') snapshot['cache'] = 0;
          if (call.method == 'deleteYesheIndex') {
            snapshot['downloads'] = 0;
            snapshot['indexCount'] = 0;
          }
          return snapshot;
        });
  });

  Future<void> launch(
    WidgetTester tester, {
    bool downloads = false,
    double width = 393,
    double scale = 1,
    bool dark = false,
  }) async {
    tester.view.physicalSize = Size(width, 880);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      ProviderScope(
        child: RepaintBoundary(
          key: const Key('storage-capture'),
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: dark ? AppTheme.dark : AppTheme.light,
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: TextScaler.linear(scale)),
              child: child!,
            ),
            home: LocalStoragePage(downloadsOnly: downloads),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> capture(WidgetTester tester, String name) async {
    if (!const bool.fromEnvironment('STORAGE_SCREENSHOTS')) return;
    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(const Key('storage-capture')),
    );
    await tester.runAsync(() async {
      final image = await boundary.toImage(pixelRatio: 2);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      final file = File('../artifacts/local-storage-review/$name.png');
      await file.parent.create(recursive: true);
      await file.writeAsBytes(bytes!.buffer.asUint8List());
      image.dispose();
    });
  }

  testWidgets(
    'overview shows app-only storage without manual refresh or device space',
    (tester) async {
      await launch(tester);
      expect(find.text('211.0 MB'), findsOneWidget);
      expect(find.text('设备空间'), findsNothing);
      expect(find.byTooltip('刷新占用'), findsNothing);
      expect(find.byType(RefreshIndicator), findsNothing);
      await tester.drag(
        find.byKey(const ValueKey('local-storage-scroll')),
        const Offset(0, 360),
      );
      await tester.pumpAndSettle();
      expect(calls.where((call) => call == 'snapshot'), hasLength(1));
      expect(find.text('查看'), findsNothing);
      expect(tester.takeException(), isNull);
      await capture(tester, 'overview');
      await tester.scrollUntilVisible(find.text('您已下载到本地的资源，如不需要可随时清理'), 180);
      await tester.scrollUntilVisible(find.text('清理缓存'), 250);
      await tester.pumpAndSettle();
      await capture(tester, 'overview-actions');
    },
  );

  testWidgets(
    'profile entry opens storage and aggregate management, then returns',
    (tester) async {
      await app_test.launch(tester);
      app_test.router(tester).go('/profile');
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(find.text('本地存储'), 200);
      await tester.tap(find.text('本地存储'));
      await tester.pumpAndSettle();
      expect(find.byType(LocalStoragePage), findsOneWidget);
      expect(find.byType(NavigationBar), findsNothing);
      await tester.scrollUntilVisible(find.text('管理'), 200);
      await tester.tap(find.text('管理'));
      await tester.pumpAndSettle();
      expect(find.text('夜社书目索引'), findsOneWidget);
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(find.text('本地存储'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'cache clearing needs confirmation, prevents repeats and preserves index',
    (tester) async {
      await launch(tester);
      await tester.scrollUntilVisible(find.text('清理缓存'), 250);
      await tester.tap(find.text('清理缓存'));
      await tester.pumpAndSettle();
      expect(calls, isNot(contains('clearCache')));
      await capture(tester, 'cache-confirmation');
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(calls, isNot(contains('clearCache')));
      await tester.tap(find.text('清理缓存'));
      await tester.pumpAndSettle();
      pending = Completer<void>();
      await tester.tap(find.text('确认清理'));
      await tester.pumpAndSettle();
      expect(find.text('清理中…'), findsOneWidget);
      pending!.complete();
      await tester.pumpAndSettle();
      expect(calls.where((c) => c == 'clearCache').length, 1);
      expect(snapshot['downloads'], 7 * 1024 * 1024);
      expect(snapshot['cache'], 0);
      expect(find.text('缓存已清理'), findsOneWidget);
    },
  );

  testWidgets('one aggregate index entry deletes to an empty state', (
    tester,
  ) async {
    await launch(tester, downloads: true);
    expect(find.byTooltip('刷新占用'), findsNothing);
    expect(find.byType(RefreshIndicator), findsNothing);
    expect(find.text('夜社书目索引'), findsOneWidget);
    expect(find.text('删除'), findsOneWidget);
    expect(find.textContaining('25230'), findsOneWidget);
    await capture(tester, 'downloads');
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();
    expect(calls, isNot(contains('deleteYesheIndex')));
    await tester.tap(find.text('删除索引'));
    await tester.pumpAndSettle();
    expect(snapshot['cache'], 36 * 1024 * 1024);
    expect(snapshot['necessary'], 168 * 1024 * 1024);
    expect(find.text('暂无已下载的资源'), findsOneWidget);
  });

  testWidgets('failed deletion keeps the index and allows retry', (
    tester,
  ) async {
    await launch(tester, downloads: true);
    fail = true;
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除索引'));
    await tester.pumpAndSettle();
    expect(find.text('操作未完成，请重试'), findsOneWidget);
    expect(find.text('删除'), findsOneWidget);
    expect(find.text('夜社书目索引'), findsOneWidget);
  });

  for (final width in [320.0, 393.0]) {
    testWidgets('large text fits at $width', (tester) async {
      await launch(tester, width: width, scale: 1.8);
      expect(tester.takeException(), isNull);
      await tester.scrollUntilVisible(find.text('清理缓存'), 250);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('清理缓存'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  }
  testWidgets('dark theme and zero occupation render', (tester) async {
    snapshot['necessary'] = 0;
    snapshot['downloads'] = 0;
    snapshot['cache'] = 0;
    await launch(tester, dark: true);
    expect(tester.takeException(), isNull);
    await capture(tester, 'dark-empty');
  });
}
