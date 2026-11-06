import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:archive/archive.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sorryread_mobile/app/dependencies.dart';
import 'package:sorryread_mobile/app/reader_app.dart';
import 'package:sorryread_mobile/data/local_library.dart';
import 'package:sorryread_mobile/data/sync_repository.dart';
import 'package:sorryread_mobile/design_system/components.dart';
import 'package:sorryread_mobile/features/bookshelf/presentation/book_cover.dart';
import 'package:sorryread_mobile/features/bookshelf/presentation/book_opening.dart';
import 'package:sorryread_mobile/features/bookshelf/presentation/shelf_actions_dock.dart';
import 'package:sorryread_mobile/features/discover/data/discover_repository.dart';
import 'package:sorryread_mobile/features/local_books/local_book_parser.dart';
import 'package:sorryread_mobile/features/reader/data/reader_repository.dart';
import 'package:sorryread_mobile/features/reader/presentation/reader_curl.dart';
import 'package:sorryread_mobile/features/reader/presentation/reader_layout.dart';
import 'package:sorryread_mobile/features/reader/presentation/reader_page.dart';
import 'package:sorryread_mobile/features/reader/presentation/reader_scroll_sliver.dart';
import 'package:sorryread_mobile/features/sync/application/sync_controller.dart';
import 'package:sorryread_mobile/features/sync/presentation/sync_status_card.dart';
import 'package:sorryread_mobile/sync_engine/sync_transport.dart';

import '../test/app_shell_test.dart'
    show StaticSyncController, navigationLabel, router;
import '../test/support/test_runtime.dart';

Future<File> _comic(Directory directory) async {
  final archive = Archive();
  void add(String path, List<int> bytes) {
    archive.addFile(ArchiveFile(path, bytes.length, bytes));
  }

  add(
    'META-INF/container.xml',
    utf8.encode(
      '<container><rootfiles><rootfile full-path="book.opf"/></rootfiles></container>',
    ),
  );
  add(
    'book.opf',
    utf8.encode(
      '<package><metadata><title>漫画验收</title></metadata><manifest>'
      '<item id="pages" href="pages.xhtml" media-type="application/xhtml+xml"/>'
      '<item id="cover" href="first.png" media-type="image/png" properties="cover-image"/>'
      '</manifest><spine><itemref idref="pages"/></spine></package>',
    ),
  );
  add(
    'pages.xhtml',
    utf8.encode('<body><img src="first.png"/><img src="second.png"/></body>'),
  );
  for (final (path, color) in [
    ('first.png', const Color(0xff3f7678)),
    ('second.png', const Color(0xff63699a)),
  ]) {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.drawColor(const Color(0xffefede3), BlendMode.src);
    final paint = Paint()..color = color;
    for (var i = 0; i < 4; i++) {
      final panel = Rect.fromLTWH(16, 16.0 + 273 * i, 208, 252);
      canvas.drawRect(panel, paint);
      canvas.drawCircle(
        panel.center,
        40,
        Paint()..color = const Color(0xffefede3),
      );
    }
    final picture = recorder.endRecording();
    final image = await picture.toImage(240, 1120);
    picture.dispose();
    final png = (await image.toByteData(format: ui.ImageByteFormat.png))!;
    add(path, png.buffer.asUint8List());
    image.dispose();
  }
  return File('${directory.path}/漫画验收.epub')
      .writeAsBytes(ZipEncoder().encode(archive)!);
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  tearDownAll(() async {
    final support = await getApplicationSupportDirectory();
    await File('${support.path}/local-book-captures/result.json').writeAsString(
      jsonEncode(
        binding.results.map((test, value) => MapEntry(test, value.toString())),
      ),
    );
  });
  testWidgets(
    'import, open and manage local books through the normal Android UI',
    (tester) async {
      final support = await getApplicationSupportDirectory();
      final captures = await Directory('${support.path}/local-book-captures')
          .create();
      final root = await support.createTemp('local-book-test-');
      final repo = SyncRepository(
        SyncDatabase(NativeDatabase.memory()),
        bookDirectory: Directory('${root.path}/books'),
      );
      await repo.initialize();
      final store = repo.importedBooks!;
      final reader = ReaderRepository(Directory('${root.path}/reader'), []);
      await reader.write('preferences', {'mode': 'curl', 'font': 'system'});
      final peer = LinkedPeer(
        serverId: '2' * 32,
        name: '测试电脑',
        endpoints: ['https://127.0.0.1:12345'],
        pin: 'a' * 64,
        credential: 'b' * 64,
      );
      final peerStorage = MemoryPeerStorage()..peer = peer;
      final novel = await File('${root.path}/山间来信.txt').writeAsString(
        ['第一章 溪流', '第二章 山风', '第三章 来信']
            .map(
              (title) =>
                  '$title\n${List.filled(32, '山间有风。阳光穿过枝叶，在书页上留下细碎的光影。我们沿着溪流慢慢走，听水声从石缝间穿过。').join('\n\n')}',
            )
            .join('\n\n'),
      );
      final comic = await _comic(root);
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(bookPicker, (call) async {
        expect(call.method, 'choose');
        return [
          {'name': '山间来信.txt', 'path': novel.path},
          {'name': '漫画验收.epub', 'path': comic.path},
        ];
      });
      addTearDown(() async {
        messenger.setMockMethodCallHandler(bookPicker, null);
        await tester.pumpWidget(const SizedBox.shrink());
        reader.dispose();
        await repo.close();
        await root.delete(recursive: true);
      });
      const captureKey = Key('local-book-capture');
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            syncRepositoryProvider.overrideWith((ref) async => repo),
            readerRepositoryProvider.overrideWith((ref) async {
              ref.keepAlive();
              return reader;
            }),
            peerStorageProvider.overrideWithValue(peerStorage),
            backgroundSyncEnabledProvider.overrideWithValue(false),
            syncControllerProvider.overrideWith(
              () => StaticSyncController(
                SyncViewState(peer: peer, connected: true),
              ),
            ),
          ],
          child: const RepaintBoundary(key: captureKey, child: ReaderApp()),
        ),
      );

      Future<void> waitFor(Finder finder) async {
        for (var i = 0; i < 90 && finder.evaluate().isEmpty; i++) {
          await tester.pump(const Duration(milliseconds: 40));
        }
        expect(finder, findsOneWidget);
      }

      Future<void> capture(String name) async {
        final boundary = tester.renderObject<RenderRepaintBoundary>(
          find.byKey(captureKey),
        );
        final image = await boundary.toImage(pixelRatio: 1.75);
        final png = (await image.toByteData(format: ui.ImageByteFormat.png))!;
        await File('${captures.path}/$name.png')
            .writeAsBytes(png.buffer.asUint8List());
        image.dispose();
      }

      Future<void> tap(Finder finder) async {
        await tester.tap(finder);
        await tester.pumpAndSettle();
      }

      Finder cover(String title) => find
          .byWidgetPredicate(
            (widget) => widget is BookCover && widget.title == title,
          )
          .hitTestable();
      final dock = find.byKey(const Key('floating-dock'));
      Finder action(String label) => find.descendant(
        of: find.byType(ShelfActionsDock),
        matching: find.text(label),
      );
      final importedTab = find.byKey(const Key('shelf-tab-imported'));
      final favoritesTab = find.byKey(const Key('shelf-tab-favorites'));
      final content = find.byKey(const Key('reader-content'));
      final opening = find.byType(BookOpeningTransition);
      await tester.pumpAndSettle();
      await tap(navigationLabel('发现'));
      final import = find.byKey(const Key('discover-import-books'));
      final heading = find.descendant(
        of: find.byKey(const Key('discover-heading')),
        matching: find.text('发现'),
      );
      expect(
        tester.getCenter(import).dy,
        closeTo(tester.getCenter(heading).dy, 1),
      );
      expect(tester.widget<TextButton>(import).style?.backgroundColor, isNull);
      await capture('discover');
      await tester.tap(import);
      await waitFor(find.text('已处理 2 本图书，可在书架查看'));
      await tap(navigationLabel('书架'));
      await waitFor(importedTab);
      await tap(importedTab);
      expect(tester.widget<PageTextTab>(importedTab).selected, isTrue);
      final tabs = tester.getRect(find.byKey(const Key('bookshelf-tabs')));
      final sync = tester.getRect(find.byType(SyncStatusEntry));
      expect(sync.left, greaterThan(tabs.right));
      expect(sync.center.dy, closeTo(tabs.center.dy, 1));
      expect((await repo.books()).every((book) => !book.recent), isTrue);
      await tester.pump(const Duration(seconds: 4));
      await tester.pumpAndSettle();
      await capture('bookshelf');

      final books = await repo.books();
      final textBook = books.singleWhere((book) => book.title == '山间来信');
      final comicBook = books.singleWhere((book) => book.title == '漫画验收');
      final imported = textBook.imported!;
      await store.updatePosition(imported.hash, imported.epoch, 1, .35);
      await tester.tap(cover(textBook.title));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 120));
      expect(
        tester.widget<BookOpeningTransition>(opening).animation.value,
        inExclusiveRange(0, 1),
      );
      await capture('opening');
      await waitFor(content);
      await tester.pump(const Duration(milliseconds: 800));
      await tester.pumpAndSettle();
      expect(find.byType(ReaderPage), findsOneWidget);
      expect(
        tester.widget<BookOpeningTransition>(opening).animation.isCompleted,
        isTrue,
      );
      expect(find.byType(NavigationBar).hitTestable(), findsNothing);
      await capture('novel');
      await tap(content);
      await tap(find.text('目录').hitTestable());
      expect(find.text('第二章 山风'), findsWidgets);
      await tap(find.text('第三章 来信').hitTestable().last);
      for (
        var i = 0;
        i < 60 && (await store.book(imported.hash))?.index != 2;
        i++
      ) {
        await tester.pump(const Duration(milliseconds: 60));
      }
      expect((await store.book(imported.hash))!.index, 2);
      expect((await repo.books()).every((book) => !book.recent), isTrue);
      expect(
        await store.readerAnchor(imported.hash),
        containsPair('chapterIndex', 2),
      );
      router(tester).pop();
      await tester.pumpAndSettle();
      expect(find.byType(ReaderPage), findsNothing);

      await tester.tap(cover(comicBook.title));
      await waitFor(content);
      await tester.pumpAndSettle();
      expect(find.byType(ReaderScrollSliver), findsWidgets);
      expect(
        tester
            .widgetList<CustomPaint>(
              find.descendant(of: content, matching: find.byType(CustomPaint)),
            )
            .map((paint) => paint.painter)
            .whereType<BlockPainter>()
            .any((painter) => painter.block.plainText == '插图'),
        isTrue,
      );
      await capture('comic-scroll');
      await tap(content);
      await tap(find.text('设置').hitTestable());
      await tap(find.text('仿真').hitTestable());
      expect(find.byType(ReaderScrollSliver), findsNothing);
      await tester.tapAt(tester.getRect(content).center - const Offset(0, 90));
      await tester.pumpAndSettle();
      final paper = tester.getRect(content);
      final gesture = await tester.startGesture(
        Offset(paper.right - 12, paper.bottom - 90),
      );
      await gesture.moveBy(const Offset(-100, -65));
      await tester.pump();
      expect(
        tester
            .widgetList<CustomPaint>(
              find.descendant(of: content, matching: find.byType(CustomPaint)),
            )
            .map((paint) => paint.painter)
            .whereType<PaperCurlPainter>(),
        isNotEmpty,
      );
      await capture('comic-curl');
      await gesture.up();
      await tester.pumpAndSettle();
      router(tester).pop();
      await tester.pumpAndSettle();

      await repo.setFavorite(textBook, true);
      final online = const DiscoverBook(
        '在线样本',
        'https://example.invalid/book',
        DiscoverMode.normal,
        sourceId: 'test',
        sourceName: '本地验收',
      ).toShelfBook();
      await repo.setFavorite(online, true);
      final container = ProviderScope.containerOf(
        tester.element(find.byType(ReaderApp)),
      );
      await (await container.read(localLibraryProvider.future))
          .setPinned(textBook.id, true);
      await tester.pumpAndSettle();
      await tap(importedTab);
      await tester.longPress(cover(textBook.title));
      await tester.pumpAndSettle();
      expect(find.text('取消置顶'), findsOneWidget);
      expect(action('移动至分组'), findsOneWidget);
      expect(
        tester
            .widget<InkWell>(
              find
                  .ancestor(of: action('移动至分组'), matching: find.byType(InkWell))
                  .first,
            )
            .onTap,
        isNull,
      );
      await tap(cover(comicBook.title));
      await capture('local-multiselect');
      expect(container.read(shelfSelectionProvider), {
        textBook.id,
        comicBook.id,
      });
      expect(
        container.read(shelfSelectionProvider.notifier).tab,
        ShelfTab.imported,
      );
      expect((await store.book(comicBook.imported!.hash))!.favorite, isFalse);
      expect(find.text('置顶'), findsOneWidget);
      expect(action('收藏'), findsOneWidget);
      expect(find.text('删除'), findsOneWidget);
      expect(find.text('移动至分组'), findsOneWidget);
      expect(
        tester
            .widget<InkWell>(
              find
                  .ancestor(
                    of: find.text('移动至分组'),
                    matching: find.byType(InkWell),
                  )
                  .first,
            )
            .onTap,
        isNull,
      );
      await tap(action('收藏'));
      await waitFor(navigationLabel('书架'));
      await tap(favoritesTab);
      await tester.longPress(cover(textBook.title));
      await tester.pumpAndSettle();
      expect(find.text('删除'), findsOneWidget);
      final singleDock = tester.getRect(dock);
      await tap(find.text('删除'));
      expect(tester.getRect(dock), singleDock);
      expect(find.text('从当前设备移出'), findsOneWidget);
      expect(find.text('从双端移除'), findsOneWidget);
      await capture('remove-scope');
      await tap(cover(online.title));
      expect(find.text('取消收藏'), findsOneWidget);
      expect(find.text('删除'), findsNothing);
      expect(find.text('移动至分组'), findsOneWidget);
      await tap(cover(online.title));
      await tap(cover(comicBook.title));
      expect(find.text('取消收藏'), findsOneWidget);
      expect(find.text('删除'), findsOneWidget);
      expect(find.text('移动至分组'), findsOneWidget);
      final batchDock = tester.getRect(dock);
      await tap(find.text('删除'));
      expect(tester.getRect(dock), batchDock);
      await tap(find.text('从当前设备移出'));
      await waitFor(navigationLabel('书架'));
      expect((await repo.books()).map((book) => book.title), [online.title]);
      expect((await store.operations(peer.serverId)).map((op) => op.action), [
        'removeHere',
        'removeHere',
      ]);

      if (const bool.fromEnvironment('EPUB_BOUNDARY_REVIEW')) {
        final source = File('${support.path}/epub-boundary-source.epub');
        final imported = await store.importFile(source, '明天过后.epub');
        expect(imported.comic, isFalse);
        final book = (await repo.books()).singleWhere(
          (b) => b.id == imported.id,
        );
        final chapters = await store.catalog(imported.hash);
        expect(chapters.length, greaterThan(10));
        final navigator = router(tester);
        final start = ReaderOpenRequest(
          book,
          chapterUrl: '$localBookUrl${imported.hash}/0',
        );
        final status = find.byKey(const Key('reader-chapter-status'));
        String chapter() => tester.widget<Text>(status).data!;
        String page() => tester
            .widgetList<Semantics>(
              find.descendant(of: content, matching: find.byType(Semantics)),
            )
            .map((widget) => widget.properties.label)
            .whereType<String>()
            .singleWhere((label) => RegExp(r'，第 \d+ 页$').hasMatch(label));

        Future<void> open(String mode) async {
          await reader.write('preferences', {'mode': mode, 'font': 'system'});
          navigator.push('/reader', extra: start);
          await waitFor(content);
          await tester.pumpAndSettle();
          await tester.pump(const Duration(milliseconds: 400));
        }

        await open('scroll');
        final first = chapter();
        final seen = {first};
        for (var i = 0; i < 10; i++) {
          await tester.drag(content, const Offset(0, -330));
          await tester.pumpAndSettle();
          seen.add(chapter());
        }
        expect(seen, contains(contains('版权信息')));
        expect(seen.length, greaterThanOrEqualTo(4), reason: seen.join(' → '));
        final advanced = chapter();
        await capture('epub-original-scroll-forward');
        for (var i = 0; i < 8 && chapter() == advanced; i++) {
          await tester.drag(content, const Offset(0, 340));
          await tester.pumpAndSettle();
        }
        expect(chapter(), isNot(advanced));
        navigator.pop();
        await tester.pumpAndSettle();

        await open('curl');
        final rect = tester.getRect(content);
        final pages = <String>[page()];
        for (var i = 0; i < 5; i++) {
          await tester.tapAt(Offset(rect.right - 24, rect.center.dy));
          await tester.pump();
          if (i == 1) {
            await tester.pump(const Duration(milliseconds: 420));
            await capture('epub-original-curl');
          }
          await tester.pumpAndSettle();
          pages.add(page());
        }
        expect(pages.toSet(), hasLength(6), reason: pages.join(' → '));
        for (var i = 4; i >= 0; i--) {
          await tester.tapAt(
            Offset(rect.left + rect.width * .15, rect.center.dy),
          );
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 830));
          await tester.pumpAndSettle();
          expect(page(), pages[i], reason: '反向翻页回到 $i');
        }
        await capture('epub-original-curl-return');
        final remoteIndex = chapters.length - 1;
        expect(
          await store.receive(peer.serverId, imported.epoch, {
            ...imported.state,
            'position': {'index': remoteIndex, 'progress': 0},
          }),
          isNotNull,
        );
        final remoteTitle = chapters[remoteIndex].title;
        for (var i = 0; i < 80 && !chapter().contains(remoteTitle); i++) {
          await tester.pump(const Duration(milliseconds: 50));
        }
        expect(chapter(), contains(remoteTitle));
        await File('${captures.path}/epub-boundaries.json').writeAsString(
          jsonEncode({
            'scroll': seen.toList(),
            'curl': pages,
            'remote': chapter(),
          }),
        );
      }
      expect(tester.takeException(), isNull);
    },
  );
}
