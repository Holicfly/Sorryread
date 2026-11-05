// Runs in the independent .dev application, using synthetic local data only.
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sorryread_mobile/app/dependencies.dart';
import 'package:sorryread_mobile/app/reader_app.dart';
import 'package:sorryread_mobile/app/router.dart';
import 'package:sorryread_mobile/data/local_library.dart';
import 'package:sorryread_mobile/design_system/components.dart';
import 'package:sorryread_mobile/features/bookshelf/presentation/book_cover.dart';
import 'package:sorryread_mobile/features/discover/data/discover_repository.dart';
import 'package:sorryread_mobile/features/profile/data/app_information.dart';
import 'package:sorryread_mobile/features/profile/presentation/about_page.dart';
import 'package:sorryread_mobile/features/profile/presentation/profile_page.dart';
import 'package:sorryread_mobile/features/profile/presentation/reading_history_page.dart';
import 'package:sorryread_mobile/features/reader/data/reader_repository.dart';
import 'package:sorryread_mobile/features/reader/data/reader_source.dart';
import 'package:sorryread_mobile/features/sync/application/sync_controller.dart';
import 'package:sorryread_mobile/features/sync/presentation/sync_page.dart';
import 'package:sorryread_mobile/features/sync/presentation/sync_wash.dart';
import 'package:sorryread_mobile/sync_engine/sync_coordinator.dart';
import 'package:sorryread_mobile/sync_engine/sync_transport.dart';

import '../test/app_shell_test.dart' show StaticSyncController;
import '../test/profile_pages_test.dart' show seedHistory;
import '../test/support/test_runtime.dart';

class _ReviewReader extends ReaderRepository {
  _ReviewReader(super.directory, super.rules);
  @override
  Future<String> fetch(SourceRule source, String url) async {
    if (!url.contains('/chapter/')) {
      return '<div id="chapters"><a href="/chapter/1">第一章 山间清晨</a><a href="/chapter/2">第二章 湖畔故事</a></div>';
    }
    final title = url.endsWith('/1') ? '第一章 山间清晨' : '第二章 湖畔故事';
    return '<h1>$title</h1><div id="content">${List.generate(40, (i) => '<p>第$i 段：阳光穿过枝叶，在书页上留下细碎的光影。山间有风，书中有远方。</p>').join()}</div>';
  }
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('profile refinements and actual reading history on Android', (
    tester,
  ) async {
    final support = await getApplicationSupportDirectory();
    final root = Directory('${support.path}/cross-device-reading-review');
    await root.create(recursive: true);
    final report = <String, dynamic>{'passed': false};
    Future<void> phase(String value) async {
      report['phase'] = value;
      await File('${root.path}/result.json')
          .writeAsString(jsonEncode(report), flush: true);
    }

    Future<void> until(bool Function() ready) async {
      for (var i = 0; i < 150 && !ready(); i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(ready(), isTrue);
    }

    Future<void> capture(String name, {bool settle = true}) async {
      if (settle) {
        await tester.pumpAndSettle();
      } else {
        await tester.pump();
      }
      final boundary = tester.renderObject<RenderRepaintBoundary>(
        find.byKey(const Key('phone-review')),
      );
      final frame = await boundary.toImage(pixelRatio: 2);
      final bytes = await frame.toByteData(format: ui.ImageByteFormat.png);
      await File('${root.path}/$name.png')
          .writeAsBytes(bytes!.buffer.asUint8List());
      frame.dispose();
    }

    await phase('setup');
    // Test bindings omit ServicesBinding's compiled-license registration.
    LicenseRegistry.addLicense(() async* {
      final bytes = await rootBundle.load('NOTICES.Z');
      final notices = utf8.decode(gzip.decode(bytes.buffer.asUint8List()));
      for (final entry in notices.split('\n${'-' * 80}\n')) {
        final split = entry.indexOf('\n\n');
        if (split >= 0) {
          yield LicenseEntryWithLineBreaks(
            entry.substring(0, split).split('\n'),
            entry.substring(split + 2),
          );
        }
      }
    });
    final sync = await testRepository();
    await seedHistory(sync);
    final ticketFile = File('${support.path}/cross-device-ticket.json');
    String? desktopTitle;
    if (await ticketFile.exists()) {
      await phase('desktop-reading-sync');
      final ticket = PairTicket.parse(
        await ticketFile.readAsString(),
        allowLoopback: true,
      );
      await ticketFile.delete();
      final engine = SyncCoordinator(
        sync,
        MemoryPeerStorage(),
        allowLoopback: true,
      );
      try {
        final peer = await engine.pair(ticket);
        await engine.synchronize(peer, manual: true);
        await engine.synchronize(peer, manual: true);
        final book = (await sync.books()).single;
        desktopTitle = book.title;
        final local = LocalLibrary(sync);
        await local.initialize();
        final overview = await local.readingOverview(DateTime.now());
        final desktop = overview.entries.singleWhere(
          (entry) => entry.title == book.title,
        );
        expect(desktop.onDesktop, isTrue);
        expect(desktop.onPhone, isFalse);
        expect(desktop.milliseconds, 120000);
        report['desktopReadingMs'] = desktop.milliseconds;
        await local.close();
      } finally {
        await engine.cancel();
      }
    }
    final privacyHistory = LocalLibrary(sync);
    await privacyHistory.initialize();
    final privacyTime = DateTime.now();
    await privacyHistory.recordReading(
      {'title': '特殊书籍验收示例', 'author': '验收作者', 'sourceId': 'yeshe'},
      privacyTime.add(const Duration(minutes: 1)),
      60000,
    );
    await privacyHistory.close();
    await sync.logBatch(true, List.generate(24, (i) => '真机验收同步记录 $i'));
    final source = SourceRule({
      'id': 'review',
      'baseUrl': 'https://example.invalid',
      'dynamic': false,
      'detail': <String, dynamic>{},
      'catalog': {'itemSelector': '#chapters a'},
      'chapter': {'contentSelector': '#content', 'titleSelector': 'h1'},
    });
    final reader = _ReviewReader(Directory('${root.path}/reader'), [source]);
    await reader.directory.create(recursive: true);
    final book = const DiscoverBook(
      '真机阅读计时验收',
      'https://example.invalid/book/1',
      DiscoverMode.normal,
      sourceId: 'review',
      sourceName: '合成验收',
    ).toShelfBook();
    await sync.setFavorite(book, true);
    addTearDown(() async {
      report['failures'] = binding.failureMethodsDetails
          .map((e) => e.details)
          .toList();
      await phase(report['phase'] as String);
      await tester.pumpWidget(const SizedBox.shrink());
      reader.dispose();
      await sync.close();
    });
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          syncRepositoryProvider.overrideWith((ref) async => sync),
          readerRepositoryProvider.overrideWith((ref) async {
            ref.keepAlive();
            return reader;
          }),
          peerStorageProvider.overrideWithValue(MemoryPeerStorage()),
          backgroundSyncEnabledProvider.overrideWithValue(false),
          syncControllerProvider.overrideWith(
            () => StaticSyncController(const SyncViewState()),
          ),
        ],
        child: const RepaintBoundary(
          key: Key('phone-review'),
          child: ReaderApp(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final container = ProviderScope.containerOf(
      tester.element(find.byType(ReaderApp)),
    );
    final router = container.read(appRouterProvider);
    if (desktopTitle != null) {
      await phase('shelf-actions-dock');
      final dock = find.byKey(const Key('floating-dock'));
      final normal = tester.getRect(dock);
      await tester.longPress(
        find.byWidgetPredicate(
          (widget) => widget is BookCover && widget.title == book.title,
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.getRect(dock).height, greaterThan(normal.height));
      expect(tester.getRect(dock).bottom, normal.bottom);
      await capture('dock-single');
      await tester.tap(
        find.byWidgetPredicate(
          (widget) => widget is BookCover && widget.title == desktopTitle,
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.getRect(dock), normal);
      expect(find.byIcon(Icons.check_rounded), findsNWidgets(2));
      await capture('dock-multi');
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(tester.getRect(dock), normal);
      expect(find.byType(NavigationBar), findsOneWidget);
      report['shelfDockPassed'] = true;
    }
    await phase('profile');
    await tester.tap(
      find.descendant(
        of: find.byType(NavigationBar),
        matching: find.text('我的'),
      ),
    );
    await tester.pumpAndSettle();
    for (final text in [
      '常用功能',
      '偏好与其他',
      '书签与笔记',
      '下载与导入',
      '备份与恢复',
      '阅读设置',
      '主题外观',
      '隐私设置',
    ]) {
      expect(find.text(text), findsNothing);
    }
    final widths = <double>[];
    for (final element
        in find
            .descendant(
              of: find.byType(ProfilePage),
              matching: find.byType(SurfaceBlock),
            )
            .evaluate()) {
      final rect = tester.getRect(find.byWidget(element.widget));
      expect(rect.left, AppSpacing.listInset);
      widths.add(rect.width);
    }
    report['profileWidths'] = widths;
    await capture('profile');
    await phase('connected-animation');
    final controller =
        container.read(syncControllerProvider.notifier) as StaticSyncController;
    final peer = LinkedPeer(
      serverId: '22222222222222222222222222222222',
      name: 'HOLICFLY',
      endpoints: ['https://192.168.1.2:12345'],
      pin: List.filled(64, 'a').join(),
      credential: List.filled(64, 'b').join(),
    );
    controller.setStatus(
      SyncViewState(peer: peer, connected: true, lastSuccess: DateTime.now()),
    );
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    final painter =
        tester
                .widget<CustomPaint>(
                  find.byKey(const Key('connected-sync-wash')),
                )
                .painter!
            as SyncWashPainter;
    final firstTime = painter.clock.value;
    await capture('profile-connected-a', settle: false);
    await tester.pump(const Duration(seconds: 3));
    expect(painter.clock.value, greaterThan(firstTime + 2));
    report['washClockAdvancedSeconds'] = painter.clock.value - firstTime;
    await capture('profile-connected-b', settle: false);
    controller.setStatus(const SyncViewState());
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('connected-sync-wash')), findsNothing);
    await tester.ensureVisible(find.text('关于应用'));
    await tester.tap(find.text('关于应用'));
    await tester.pumpAndSettle();
    expect(find.byType(AboutPage), findsOneWidget);
    expect(find.byKey(const Key('floating-dock')), findsNothing);
    final version = await container.read(appVersionProvider.future);
    expect(version, matches(RegExp(r'^\d+\.\d+\.\d+')));
    report['version'] = version;
    await capture('about');
    await phase('licenses');
    await tester.ensureVisible(find.text('开源组件声明'));
    await tester.tap(find.text('开源组件声明'));
    await tester.pumpAndSettle();
    final licenses = await container.read(componentLicensesProvider.future);
    expect(
      licenses.map((e) => e.name),
      containsAll(['flutter', 'dio', '霞鹜文楷 / LXGW WenKai']),
    );
    report['licenseCount'] = licenses.length;
    await capture('licenses');
    await tester.tap(find.text(licenses.first.name));
    await tester.pumpAndSettle();
    expect(find.byType(SelectableText), findsWidgets);
    await phase('sync');
    for (final path in ['/profile/sync', '/profile/sync/records']) {
      router.go(path);
      await tester.pumpAndSettle();
      final page = path.endsWith('records')
          ? find.byType(SyncRecordsPage)
          : find.byType(SyncPage);
      final appBar = find.descendant(of: page, matching: find.byType(AppBar));
      final material = find
          .descendant(of: appBar, matching: find.byType(Material))
          .first;
      final before = tester.widget<Material>(material).color;
      if (!path.endsWith('records')) {
        expect(
          tester.widget<AppBar>(appBar).backgroundColor,
          Colors.transparent,
        );
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
        await capture('sync-continuous-background');
        report['syncBackgroundTransparent'] = true;
      }
      await tester.drag(
        find.descendant(of: page, matching: find.byType(Scrollable)).first,
        const Offset(0, -450),
      );
      await tester.pumpAndSettle();
      expect(tester.widget<Material>(material).color, before);
      expect(tester.widget<Material>(material).elevation, 0);
      await capture(
        path.endsWith('records') ? 'sync-records-scrolled' : 'sync-scrolled',
      );
    }
    await phase('history');
    router.go('/profile/history');
    await tester.pumpAndSettle();
    expect(find.byType(ReadingHistoryPage), findsOneWidget);
    final history = find.byKey(const Key('reading-history-scroll'));
    expect(
      find.descendant(of: history, matching: find.byType(InkWell)),
      findsNothing,
    );
    expect(
      find.descendant(
        of: history,
        matching: find.byWidgetPredicate(
          (widget) =>
              widget is Image && widget.key != const Key('reading-device-icon'),
        ),
      ),
      findsNothing,
    );
    expect(find.text('查看详情'), findsNothing);
    if (desktopTitle != null) {
      expect(find.text(desktopTitle), findsOneWidget);
      final icons = tester.widgetList<Image>(
        find.byKey(const Key('reading-device-icon')),
      );
      expect(icons.where((icon) => icon.semanticLabel == '电脑阅读'), hasLength(1));
    }
    expect(find.text('***'), findsOneWidget);
    expect(find.text('特殊书籍验收示例'), findsNothing);
    await capture('history');
    await tester.tap(find.text('***'));
    await tester.pumpAndSettle();
    expect(find.text('特殊书籍验收示例'), findsOneWidget);
    expect(find.text('***'), findsNothing);
    expect(router.routeInformationProvider.value.uri.path, '/profile/history');
    await capture('history-title-revealed');
    await tester.tap(find.text('特殊书籍验收示例'));
    await tester.pumpAndSettle();
    expect(find.text('***'), findsOneWidget);
    router.go('/profile');
    await tester.pumpAndSettle();
    router.go('/profile/history');
    await tester.pumpAndSettle();
    expect(find.text('***'), findsOneWidget);
    report['specialTitleToggleAndResetPassed'] = true;
    final dock = tester.getRect(find.byKey(const Key('reading-month-dock')));
    report['dockBounds'] = [dock.left, dock.top, dock.width, dock.height];
    for (var i = 0; i < 10; i++) {
      await tester.drag(history, const Offset(0, -500));
      await tester.pumpAndSettle();
    }
    final last = find.text('最后一条记录：穿过山川与星河的漫长旅程');
    expect(last, findsOneWidget);
    expect(
      tester
          .getRect(
            find.ancestor(of: last, matching: find.byType(SurfaceBlock)).first,
          )
          .bottom,
      lessThan(dock.top),
    );
    await capture('history-bottom');
    final local = await container.read(localLibraryProvider.future);
    final previousChapters = (await local.readingOverview(DateTime.now()))
        .month
        .chapters;
    await phase('reading');
    router.go('/reader', extra: book);
    await until(
      () => find.byKey(const Key('reader-content')).evaluate().isNotEmpty,
    );
    await tester.pump(const Duration(seconds: 2));
    final status = find.byKey(const Key('reader-status-bar'));
    final footerGap =
        tester.view.physicalSize.height / tester.view.devicePixelRatio -
        tester.getRect(status).bottom;
    expect(footerGap, greaterThanOrEqualTo(8));
    report['readerFooterBottomGap'] = footerGap;
    await capture('reader-footer');
    final body = find.byKey(const Key('reader-content'));
    await tester.tapAt(tester.getCenter(body));
    await tester.pumpAndSettle();
    await tester.tap(find.text('下一章').hitTestable());
    await until(
      () => tester
          .widget<Text>(find.byKey(const Key('reader-chapter-status')))
          .data!
          .contains('第二章'),
    );
    await tester.pump(const Duration(seconds: 2));
    router.go('/profile/history');
    await tester.pumpAndSettle();
    final overview = await local.readingOverview(DateTime.now());
    final actual = overview.entries.singleWhere(
      (entry) => entry.title == book.title,
    );
    expect(actual.milliseconds, greaterThan(3000));
    expect(actual.position!.chapterIndex, 1);
    expect(overview.month.chapters, previousChapters + 2);
    report['actualReadingMs'] = actual.milliseconds;
    report['actualChapterIndex'] = actual.position!.chapterIndex;
    report['monthlyChapters'] = overview.month.chapters;
    await capture('history-after-reading');
    expect(tester.takeException(), isNull);
    report['passed'] = true;
    await phase('complete');
  });
}
