import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:sorryread_mobile/data/local_library.dart';
import 'package:sorryread_mobile/data/reading_history.dart';
import 'package:sorryread_mobile/data/sync_repository.dart';
import 'package:sorryread_mobile/design_system/components.dart';
import 'package:sorryread_mobile/features/profile/data/app_information.dart';
import 'package:sorryread_mobile/features/profile/data/reader_profile.dart';
import 'package:sorryread_mobile/features/profile/presentation/about_page.dart';
import 'package:sorryread_mobile/features/profile/presentation/component_licenses_page.dart';
import 'package:sorryread_mobile/features/profile/presentation/edit_profile_page.dart';
import 'package:sorryread_mobile/features/profile/presentation/profile_page.dart';
import 'package:sorryread_mobile/features/profile/presentation/reading_history_page.dart';
import 'package:sorryread_mobile/features/sync/application/sync_controller.dart';
import 'package:sorryread_mobile/features/sync/presentation/sync_page.dart';
import 'package:sorryread_mobile/sync_engine/sync_transport.dart';

import 'app_shell_test.dart' show launch, navigationLabel, router;

Future<void> seedHistory(SyncRepository repo) async {
  final now = DateTime.now();
  await repo.setMeta(
    'local:daily-saying',
    jsonEncode({'date': localDate(now), 'text': '山间有风，书中有远方。'}),
  );
  final local = LocalLibrary(repo);
  await local.initialize();
  const books = [
    ('山间来信', '林间', '落在窗边的光', 22, 68, 38),
    ('长风与远山', '江月', '月下重逢', 101, 110, 71),
    ('与时间同行', '周岸', '合欢树', 4, 14, 24),
    ('星星的来信', '许知远', '驯服', 16, 22, 15),
    ('人间草木', '汪曾祺', '夏天的昆虫', 11, 29, 53),
    ('最后一条记录：穿过山川与星河的漫长旅程', '作者乙', '有风的地方', 7, 40, 18),
  ];
  for (var i = 0; i < books.length; i++) {
    final book = books[i];
    await local.recordReading(
      {'title': book.$1, 'author': book.$2},
      DateTime(now.year, now.month, now.day - i * 2, 19, 10),
      book.$6 * 60000,
      position: ReadingPosition(
        chapterUrl: 'https://example.invalid/book/$i/chapter/${book.$4}',
        chapterTitle: book.$3,
        chapterIndex: book.$4,
        chapterCount: book.$5,
        progress: .5,
      ),
    );
  }
  await local.close();
}

Future<void> capture(WidgetTester tester, Finder page, String name) async {
  if (!const bool.fromEnvironment('PROFILE_SCREENSHOTS')) return;
  final context = tester.element(page);
  await tester.runAsync(
    () => Future.wait([
      for (final image in tester.widgetList<Image>(find.byType(Image)))
        precacheImage(image.image, context),
    ]),
  );
  await tester.pumpAndSettle();
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.ancestor(of: page, matching: find.byType(RepaintBoundary)).last,
  );
  await tester.runAsync(() async {
    final frame = await boundary.toImage(pixelRatio: 2);
    final bytes = await frame.toByteData(format: ui.ImageByteFormat.png);
    final file = File('../artifacts/profile-style-review/$name.png');
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes!.buffer.asUint8List());
    frame.dispose();
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final nativeCalls = <MethodCall>[];
  final version = RegExp(
    r'^version:\s*([^+\s]+)',
    multiLine: true,
  ).firstMatch(File('pubspec.yaml').readAsStringSync())!.group(1)!;
  setUpAll(() async {
    // Widget bindings omit compiled licenses. For visual review, use the
    // notices from the locally compiled Android bundle when available.
    final notices = File(
      '../artifacts/profile-refresh-review/compiled-NOTICES.txt',
    );
    if (const bool.fromEnvironment('PROFILE_SCREENSHOTS') &&
        notices.existsSync()) {
      LicenseRegistry.addLicense(() async* {
        for (final entry in notices.readAsStringSync().split(
          '\n${'-' * 80}\n',
        )) {
          final split = entry.indexOf('\n\n');
          if (split >= 0) {
            yield LicenseEntryWithLineBreaks(
              entry.substring(0, split).split('\n'),
              entry.substring(split + 2),
            );
          }
        }
      });
    }
    await (FontLoader(
      'Roboto',
    )..addFont(rootBundle.load('assets/fonts/hei.otf'))).load();
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
  });
  setUp(() {
    nativeCalls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(AppInformation.channel, (call) async {
          nativeCalls.add(call);
          return call.method == 'version' ? version : null;
        });
  });
  tearDown(
    () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(AppInformation.channel, null),
  );

  testWidgets(
    'profile has one group; about opens the project and actual component declarations',
    (tester) async {
      await launch(tester, seed: seedHistory, syncState: const SyncViewState());
      await tester.tap(navigationLabel('我的'));
      await tester.pumpAndSettle();
      expect(
        find.ancestor(
          of: find.byKey(const Key('reader-information')),
          matching: find.byType(SurfaceBlock),
        ),
        findsNothing,
      );
      expect(
        find.descendant(
          of: find.byKey(const Key('reading-statistics-card')),
          matching: find.byType(FeatureIconBadge),
        ),
        findsNWidgets(4),
      );
      for (final removed in [
        '常用功能',
        '偏好与其他',
        '书签与笔记',
        '下载与导入',
        '备份与恢复',
        '阅读设置',
        '主题外观',
        '隐私设置',
      ]) {
        expect(find.text(removed), findsNothing);
      }
      final blocks = find.descendant(
        of: find.byType(ProfilePage),
        matching: find.byType(SurfaceBlock),
      );
      for (final block in blocks.evaluate()) {
        expect(
          tester.getRect(find.byWidget(block.widget)).left,
          AppSpacing.listInset,
        );
        expect(
          tester.getRect(find.byWidget(block.widget)).right,
          390 - AppSpacing.listInset,
        );
      }
      await capture(tester, find.byType(ProfilePage), 'profile');
      await tester.ensureVisible(find.text('关于应用'));
      await tester.tap(find.text('关于应用'));
      await tester.pumpAndSettle();
      expect(find.byType(AboutPage), findsOneWidget);
      expect(find.byKey(const Key('floating-dock')), findsNothing);
      expect(find.text('Ver $version'), findsOneWidget);
      expect(
        tester
            .widget<ClipRRect>(find.byKey(const Key('about-app-icon')))
            .borderRadius,
        BorderRadius.circular(26),
      );
      expect(
        tester.getRect(find.byKey(const Key('about-github'))).left,
        AppSpacing.listInset,
      );
      await tester.tap(find.byKey(const Key('about-github')));
      await tester.pumpAndSettle();
      expect(
        nativeCalls.where((call) => call.method == 'openUrl').single.arguments,
        projectUrl,
      );
      await capture(tester, find.byType(AboutPage), 'about');
      await tester.ensureVisible(find.text('开源组件声明'));
      await tester.tap(find.text('开源组件声明'));
      await tester.pumpAndSettle();
      expect(find.byType(ComponentLicensesPage), findsOneWidget);
      final container = ProviderScope.containerOf(
        tester.element(find.byType(ComponentLicensesPage)),
      );
      final components = (await tester.runAsync(
        () => container.read(componentLicensesProvider.future),
      ))!;
      await tester.pumpAndSettle();
      expect(
        components.map((c) => c.name),
        containsAll([
          '思源宋体 / Source Han Serif',
          '思源黑体 / Source Han Sans',
          'Noto Sans CJK',
          '霞鹜臻楷 / LXGW ZhenKai',
          '霞鹜文楷 / LXGW WenKai',
        ]),
      );
      expect(
        components.every(
          (c) => c.texts.isNotEmpty && c.texts.every((text) => text.isNotEmpty),
        ),
        isTrue,
      );
      await capture(tester, find.byType(ComponentLicensesPage), 'licenses');
      final first = components.first;
      await tester.tap(find.text(first.name));
      await tester.pumpAndSettle();
      expect(find.byType(SelectableText), findsWidgets);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'profile keeps its default avatar until a preset is saved and reloads it from storage',
    (tester) async {
      await launch(tester, seed: seedHistory, syncState: const SyncViewState());
      router(tester).go('/profile');
      await tester.pumpAndSettle();
      final avatar = find.byKey(const Key('profile-avatar'));
      final input = find.byKey(const Key('profile-nickname-input'));
      final firstChoice = find.byKey(const ValueKey('preset-avatar-1'));
      final thirdChoice = find.byKey(const ValueKey('preset-avatar-3'));
      Finder profileImage() =>
          find.descendant(of: avatar, matching: find.byType(CircleAvatar));
      expect(
        tester.widget<CircleAvatar>(profileImage()).foregroundImage,
        isNull,
      );
      expect(find.text('本地读者'), findsOneWidget);
      await tester.tap(avatar);
      await tester.pumpAndSettle();
      expect(find.byType(EditProfilePage), findsOneWidget);
      expect(find.byType(CircleAvatar), findsNWidgets(6));
      expect(find.text('选择头像'), findsNothing);
      expect(
        tester.widget<InkWell>(firstChoice).splashFactory,
        NoSplash.splashFactory,
      );
      expect(
        tester.widget<TextField>(input).decoration!.border,
        isA<OutlineInputBorder>(),
      );
      await tester.tap(firstChoice);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(
        tester.widget<CircleAvatar>(profileImage()).foregroundImage,
        isNull,
      );
      await tester.tap(avatar);
      await tester.pumpAndSettle();
      await tester.enterText(input, '  山间读者  ');
      await tester.tap(thirdChoice);
      await tester.ensureVisible(find.text('保存'));
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(find.byType(EditProfilePage), findsNothing);
      expect(find.text('山间读者'), findsOneWidget);
      expect(
        tester.widget<CircleAvatar>(profileImage()).foregroundImage,
        const AssetImage('assets/avatars/avatar-3.png'),
      );
      final container = ProviderScope.containerOf(
        tester.element(find.byType(ProfilePage)),
      );
      container.invalidate(readerProfileProvider);
      await tester.pumpAndSettle();
      expect(container.read(readerProfileProvider).requireValue.avatarId, 3);
      expect(find.text('山间读者'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  for (final scenario in [
    (name: 'normal', size: const Size(390, 844), scale: 1.0, dark: false),
    (name: 'large-text', size: const Size(320, 640), scale: 2.0, dark: false),
    (name: 'dark', size: const Size(390, 844), scale: 1.0, dark: true),
  ]) {
    testWidgets(
      'profile keeps trailing labels and arrows aligned: ${scenario.name}',
      (tester) async {
        final peer = LinkedPeer(
          serverId: '22222222222222222222222222222222',
          name: 'HOLICFLY',
          endpoints: ['https://192.168.1.2:12345'],
          pin: List.filled(64, 'a').join(),
          credential: List.filled(64, 'b').join(),
        );
        await launch(
          tester,
          size: scenario.size,
          scale: scenario.scale,
          brightness: scenario.dark ? Brightness.dark : Brightness.light,
          disableAnimations: true,
          seed: seedHistory,
          syncState: SyncViewState(
            peer: peer,
            connected: true,
            lastSuccess: DateTime.now(),
          ),
        );
        router(tester).go('/profile');
        await tester.pumpAndSettle();
        await capture(
          tester,
          find.byType(ProfilePage),
          'profile-connected-${scenario.name}',
        );
        await tester.scrollUntilVisible(
          find.text('关于应用'),
          250,
          scrollable: find.descendant(
            of: find.byKey(const PageStorageKey('profile-scroll')),
            matching: find.byType(Scrollable),
          ),
        );
        final arrows = <double>[], descriptions = <double>[];
        for (final title in ['阅读记录', '本地存储', '关于应用']) {
          arrows.add(
            tester.getRect(find.byKey(ValueKey('profile-arrow-$title'))).right,
          );
          descriptions.add(
            tester
                .getRect(find.byKey(ValueKey('profile-description-$title')))
                .right,
          );
        }
        for (var i = 1; i < arrows.length; i++) {
          expect(arrows[i], closeTo(arrows.first, .1));
          expect(descriptions[i], closeTo(descriptions.first, .1));
        }
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final scenario in [
    (name: 'normal', size: const Size(390, 844), scale: 1.0, dark: false),
    (name: 'large-text', size: const Size(320, 640), scale: 2.0, dark: false),
    (name: 'dark', size: const Size(390, 844), scale: 1.0, dark: true),
    (name: 'landscape', size: const Size(844, 390), scale: 1.0, dark: false),
  ]) {
    testWidgets(
      'read-only timeline and floating month dock fit ${scenario.name}',
      (tester) async {
        await launch(
          tester,
          size: scenario.size,
          scale: scenario.scale,
          brightness: scenario.dark ? Brightness.dark : Brightness.light,
          seed: seedHistory,
          syncState: const SyncViewState(),
        );
        router(tester).go('/profile/history');
        await tester.pumpAndSettle();
        final page = find.byType(ReadingHistoryPage);
        expect(page, findsOneWidget);
        expect(find.byKey(const Key('floating-dock')), findsNothing);
        expect(find.text('查看详情'), findsNothing);
        expect(find.text('继续阅读'), findsNothing);
        expect(find.text('本周'), findsNothing);
        if (scenario.scale == 1) {
          final today = localDate(DateTime.now());
          final firstEntry = find.byKey(
            ValueKey('history-$today-山间来信\u001f林间'),
          );
          expect(tester.getSize(firstEntry).height, lessThan(100));
        }
        expect(
          find.descendant(
            of: page,
            matching: find.byWidgetPredicate(
              (widget) =>
                  widget is Image &&
                  widget.key != const Key('reading-device-icon'),
            ),
          ),
          findsNothing,
        );
        expect(
          find.descendant(
            of: find.byKey(const Key('reading-history-scroll')),
            matching: find.byType(InkWell),
          ),
          findsNothing,
        );
        final dock = find.byKey(const Key('reading-month-dock'));
        final rect = tester.getRect(dock);
        expect(
          rect.width,
          closeTo(
            scenario.size.width.clamp(0, AppSpacing.maxPageWidth) -
                2 * AppSpacing.listInset,
            .1,
          ),
        );
        expect(rect.bottom, lessThan(scenario.size.height - 24));
        expect(tester.takeException(), isNull);
        await capture(tester, page, 'history-${scenario.name}');
        await tester.tap(find.text('山间来信'));
        await tester.pumpAndSettle();
        expect(
          GoRouterState.of(tester.element(page)).uri.path,
          '/profile/history',
        );
        final scroll = find.byKey(const Key('reading-history-scroll'));
        await tester.drag(scroll, const Offset(0, -6000));
        await tester.pumpAndSettle();
        final last = find.text('最后一条记录：穿过山川与星河的漫长旅程');
        expect(last, findsOneWidget);
        expect(tester.getRect(last).bottom, lessThan(rect.top));
        expect(tester.getRect(dock), rect);
        await capture(tester, page, 'history-${scenario.name}-bottom');
        expect(tester.takeException(), isNull);
        router(tester).go('/profile/about');
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.byKey(const Key('about-github')));
        await tester.pumpAndSettle();
        await capture(tester, find.byType(AboutPage), 'about-${scenario.name}');
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('scrolling sync headers keeps the background and compact height', (
    tester,
  ) async {
    await launch(
      tester,
      syncState: const SyncViewState(),
      seed: (repo) =>
          repo.logBatch(true, List.generate(24, (index) => '测试同步记录 $index')),
    );
    for (final path in ['/profile/sync', '/profile/sync/records']) {
      router(tester).go(path);
      await tester.pumpAndSettle();
      final page = path.endsWith('/records')
          ? find.byType(SyncRecordsPage)
          : find.byType(SyncPage);
      final appBar = find.descendant(of: page, matching: find.byType(AppBar));
      if (path == '/profile/sync') {
        expect(
          tester
              .widget<Scaffold>(
                find
                    .descendant(of: page, matching: find.byType(Scaffold))
                    .first,
              )
              .backgroundColor,
          Colors.transparent,
        );
        expect(
          tester.widget<AppBar>(appBar).backgroundColor,
          Colors.transparent,
        );
        final boundary = tester.renderObject<RenderRepaintBoundary>(
          find.ancestor(of: page, matching: find.byType(RepaintBoundary)).last,
        );
        final pixels = (await tester.runAsync(() async {
          final image = await boundary.toImage();
          final bytes = await image.toByteData(
            format: ui.ImageByteFormat.rawRgba,
          );
          final result = (
            width: image.width,
            bytes: bytes!.buffer.asUint8List(),
          );
          image.dispose();
          return result;
        }))!;
        var delta = 0;
        for (var channel = 0; channel < 3; channel++) {
          delta +=
              (pixels.bytes[(23 * pixels.width + 2) * 4 + channel] -
                      pixels.bytes[(24 * pixels.width + 2) * 4 + channel])
                  .abs();
        }
        expect(
          delta,
          lessThanOrEqualTo(6),
          reason:
              'The gradient must continue across the system safe-area boundary',
        );
      }
      final context = tester.element(appBar);
      final style = AppBarTheme.of(context);
      expect(style.toolbarHeight, 48);
      expect(style.surfaceTintColor, Colors.transparent);
      expect(style.scrolledUnderElevation, 0);
      expect(style.elevation, 0);
      final before = tester.getRect(appBar);
      final scrolls = find.descendant(
        of: page,
        matching: find.byType(Scrollable),
      );
      if (scrolls.evaluate().isNotEmpty) {
        await tester.drag(scrolls.first, const Offset(0, -500));
      }
      await tester.pumpAndSettle();
      expect(tester.getRect(appBar), before);
      expect(tester.takeException(), isNull);
    }
  });

  for (final scenario in [
    (name: 'connected', connected: true, width: 400.0, scale: 1.0),
    (name: 'offline-large-text', connected: false, width: 320.0, scale: 1.7),
  ]) {
    testWidgets('sync layout fits ${scenario.name}', (tester) async {
      final peer = LinkedPeer(
        serverId: '2' * 32,
        name: 'HOLICFLY',
        endpoints: ['https://192.168.1.2:12345'],
        pin: 'a' * 64,
        credential: 'b' * 64,
      );
      await launch(
        tester,
        size: Size(scenario.width, 880),
        scale: scenario.scale,
        syncState: SyncViewState(
          peer: peer,
          connected: scenario.connected,
          lastSuccess: DateTime.now(),
        ),
        seed: (repo) => repo.logBatch(true, [
          '同步完成：上传 1 项，接收 0 项',
          '手机 → 电脑 · 《山间来信》\n阅读进度：第 23 章 · 33%',
          '同步完成：上传 0 项，接收 1 项',
        ]),
      );
      router(tester).go('/profile/sync');
      await tester.pumpAndSettle();
      final page = find.byType(SyncPage);
      expect(
        find.text(scenario.connected ? '已连接桌面端' : '已配对，等待连接'),
        findsOneWidget,
      );
      expect(
        tester.getTopLeft(find.text('立即同步')).dy,
        lessThan(tester.getTopLeft(find.textContaining('上次同步 ·')).dy),
      );
      await capture(tester, page, 'sync-layout-${scenario.name}');
      await tester.scrollUntilVisible(
        find.text('HOLICFLY'),
        150,
        scrollable: find
            .descendant(of: page, matching: find.byType(Scrollable))
            .first,
      );
      final device = find.ancestor(
        of: find.text('HOLICFLY'),
        matching: find.byType(SurfaceBlock),
      );
      expect(device, findsOneWidget);
      expect(
        find.descendant(
          of: device,
          matching: find.byIcon(Icons.chevron_right_rounded),
        ),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    });
  }
}
