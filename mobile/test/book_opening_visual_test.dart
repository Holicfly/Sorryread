import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sorryread_mobile/features/bookshelf/presentation/book_cover.dart';
import 'package:sorryread_mobile/features/bookshelf/presentation/book_opening.dart';
import 'package:sorryread_mobile/features/reader/presentation/reader_loading_paper.dart';

void main() {
  testWidgets('render lift and hinge frames for visual review', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final animation = AnimationController(
      vsync: tester,
      duration: const Duration(milliseconds: 600),
    );
    addTearDown(animation.dispose);
    await tester.runAsync(() async {
      final loader = FontLoader('Roboto')
        ..addFont(rootBundle.load('assets/fonts/wenkai.ttf'));
      await loader.load();
    });
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    await tester.runAsync(() async {
      final context = tester.element(find.byType(SizedBox).first);
      await Future.wait([
        for (var n = 1; n <= 6; n++)
          precacheImage(
            ResizeImage(AssetImage('assets/covers/cover_$n.png'), width: 120),
            context,
          ),
        precacheImage(
          const ResizeImage(AssetImage('assets/covers/spine.png'), width: 120),
          context,
        ),
      ]);
    });
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(fontFamily: 'Roboto'),
        home: RepaintBoundary(
          key: const Key('frame'),
          child: Stack(
            children: [
              const ColoredBox(
                color: Color(0xfff7f5ed),
                child: SizedBox.expand(),
              ),
              const Positioned(
                left: 20,
                top: 65,
                child: Text(
                  '我的书架',
                  style: TextStyle(fontSize: 28, color: Colors.black),
                ),
              ),
              for (var i = 0; i < 6; i++)
                Positioned(
                  left: 20 + i % 3 * 122.0,
                  top: 160 + i ~/ 3 * 210.0,
                  width: 100,
                  height: 100 / BookCover.aspectRatio,
                  child: BookCover(design: i, title: '山间来信', progress: '20%'),
                ),
              BookOpeningTransition(
                opening: const BookOpening(
                  Rect.fromLTWH(20, 160, 100, 156.294),
                  2,
                  '山间来信',
                  '20%',
                ),
                animation: animation,
                child: Scaffold(
                  backgroundColor: const Color(0xffd9e5ee),
                  body: Padding(
                    padding: const EdgeInsets.fromLTRB(20, 20, 20, 30),
                    child: Text(
                      '第一章 山间来信\n\n${'山间有风，书中有远方。我们沿着小路走向远处的村庄，天色渐渐明亮。\n\n' * 9}',
                      style: const TextStyle(
                        fontSize: 23,
                        height: 1.8,
                        color: Colors.black,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      final context = tester.element(find.byKey(const Key('frame')));
      await Future.wait([
        for (var design = 1; design <= 6; design++)
          precacheImage(
            ResizeImage(
              AssetImage('assets/covers/cover_$design.png'),
              width: 120,
            ),
            context,
          ),
        precacheImage(
          const ResizeImage(AssetImage('assets/covers/spine.png'), width: 120),
          context,
        ),
      ]);
    });
    await tester.pump();
    final directory = Directory('../artifacts/book-opening-v029/frames');
    await tester.runAsync(() => directory.create(recursive: true));
    var i = 0;
    for (final t in [0.0, .25, .5, .75, 1.0]) {
      animation.value = t;
      await tester.pump();
      await tester.runAsync(() async {
        final boundary = tester.renderObject<RenderRepaintBoundary>(
          find.byKey(const Key('frame')),
        );
        final frame = await boundary.toImage(pixelRatio: 1);
        final bytes = await frame.toByteData(format: ui.ImageByteFormat.png);
        await File('${directory.path}/open-${i++}.png')
            .writeAsBytes(bytes!.buffer.asUint8List());
        frame.dispose();
      });
      expect(tester.takeException(), isNull);
    }
    await tester.pump(); // The same live body remains mounted after opening.
    animation.reverse();
    i = 0;
    for (final elapsed in [0, 150, 150, 150, 150]) {
      await tester.pump(Duration(milliseconds: elapsed));
      await tester.runAsync(() async {
        final boundary = tester.renderObject<RenderRepaintBoundary>(
          find.byKey(const Key('frame')),
        );
        final frame = await boundary.toImage(pixelRatio: 1);
        final bytes = await frame.toByteData(format: ui.ImageByteFormat.png);
        await File('${directory.path}/close-${i++}.png')
            .writeAsBytes(bytes!.buffer.asUint8List());
        frame.dispose();
      });
      expect(tester.takeException(), isNull);
    }
    animation.stop();
  });

  testWidgets('render visible slow loading inside the opening paper', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final animation = AnimationController(
      vsync: tester,
      duration: const Duration(milliseconds: 600),
    );
    addTearDown(animation.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: RepaintBoundary(
          key: const Key('loading-frame'),
          child: BookOpeningTransition(
            opening: const BookOpening(
              Rect.fromLTWH(20, 160, 100, 156.294),
              2,
              '山间来信',
              '20%',
            ),
            animation: animation,
            child: const Scaffold(
              backgroundColor: Color(0xffd9e5ee),
              body: ReaderLoadingPaper(
                ink: Colors.black,
                accent: Color(0xff516a50),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.runAsync(() async {
      await Future.wait([
        precacheImage(
          const ResizeImage(
            AssetImage('assets/covers/cover_3.png'),
            width: 120,
          ),
          tester.element(find.byKey(const Key('loading-frame'))),
        ),
        precacheImage(
          const ResizeImage(AssetImage('assets/covers/spine.png'), width: 120),
          tester.element(find.byKey(const Key('loading-frame'))),
        ),
      ]);
    });
    final directory = Directory('../artifacts/book-opening-v029/frames');
    await tester.runAsync(() => directory.create(recursive: true));
    var i = 0;
    for (final t in [0.0, .25, .5, .75, 1.0]) {
      animation.value = t;
      await tester.pump(const Duration(milliseconds: 150));
      await tester.runAsync(() async {
        final boundary = tester.renderObject<RenderRepaintBoundary>(
          find.byKey(const Key('loading-frame')),
        );
        final frame = await boundary.toImage(pixelRatio: 1);
        final bytes = await frame.toByteData(format: ui.ImageByteFormat.png);
        await File('${directory.path}/loading-open-${i++}.png')
            .writeAsBytes(bytes!.buffer.asUint8List());
        frame.dispose();
      });
      expect(find.byKey(const Key('reader-loading-paper')), findsOneWidget);
      expect(tester.takeException(), isNull);
    }
    await tester.pumpWidget(const SizedBox());
  });
}
