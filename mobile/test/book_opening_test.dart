import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sorryread_mobile/features/bookshelf/presentation/book_opening.dart';

Offset projected(Matrix4 m, double x, double y) =>
    MatrixUtils.transformPoint(m, Offset(x, y));

void main() {
  test('free edge is toward observer, bounded enlargement, no back face and exact endpoints', () {
    const source = Rect.fromLTWH(24, 180, 100, 156), viewport = Size(390, 844);
    for (final t in [.01, .25, .5, .75, .99]) {
      final geometry = BookOpeningGeometry(source, viewport, t);
      final m = geometry.coverTransform, size = geometry.coverSize;
      final st = projected(m, 0, 0), sb = projected(m, 0, size.height);
      final ft = projected(m, size.width, 0),
          fb = projected(m, size.width, size.height);
      final freeW = m.entry(3, 0) * size.width + m.entry(3, 3);
      expect(
        m.entry(2, 0),
        lessThan(0),
        reason: 'Right free edge has nearer depth',
      );
      expect(freeW, inInclusiveRange(.8399, 1));
      expect((fb - ft).distance, greaterThan((sb - st).distance));
      expect(
        (fb - ft).distance / (sb - st).distance,
        lessThanOrEqualTo(1 / .84 + .0001),
      );
      expect(ft.dy, lessThan(st.dy));
      expect(fb.dy, greaterThan(sb.dy));
      expect(
        ft.dx,
        greaterThan(st.dx),
        reason: 'Front never rotates past 90 degrees or mirrors',
      );
    }
    final edge = BookOpeningGeometry(source, viewport, 1);
    expect(
      (projected(edge.coverTransform, edge.coverSize.width, 0) -
              projected(edge.coverTransform, 0, 0))
          .dx
          .abs(),
      lessThan(.000001),
    );
    final closed = BookOpeningGeometry(source, viewport, 0);
    expect(projected(closed.coverTransform, 0, 0), source.topLeft);
    expect(
      projected(
        closed.coverTransform,
        closed.coverSize.width,
        closed.coverSize.height,
      ).dx,
      closeTo(source.right, .000001),
    );
    expect(
      projected(
        closed.coverTransform,
        closed.coverSize.width,
        closed.coverSize.height,
      ).dy,
      closeTo(source.bottom, .000001),
    );
  });

  testWidgets(
    'static cover, live paper, paint order, and exact reverse lifecycle',
    (tester) async {
      final animation = AnimationController(
        vsync: tester,
        duration: const Duration(milliseconds: 600),
      );
      addTearDown(animation.dispose);
      var mounts = 0, unmounts = 0, closed = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: BookOpeningTransition(
            opening: BookOpening(
              const Rect.fromLTWH(24, 180, 100, 156),
              1,
              '山间来信',
              '20%',
              onClosed: () => closed++,
            ),
            animation: animation,
            child: _ReaderProbe(
              onMount: () => mounts++,
              onUnmount: () => unmounts++,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final first = tester
          .widget<Transform>(find.byKey(const ValueKey('book-front-cover')))
          .transform
          .clone();
      final cover = tester.widget<FittedBox>(find.byType(FittedBox).first);
      expect(cover.fit, BoxFit.contain);
      for (final t in [.25, .5, .75]) {
        animation.value = t;
        await tester.pump();
        expect(
          mounts,
          1,
          reason: 'Reader is mounted from the first opening frame',
        );
        expect(find.byKey(const Key('reading-page')), findsOneWidget);
        expect(
          identical(
            tester.widget<FittedBox>(find.byType(FittedBox).first),
            cover,
          ),
          isTrue,
          reason: 'Cover subtree is not reconstructed each tick',
        );
        final stack = tester.widget<Stack>(
          find
              .ancestor(
                of: find.byKey(const ValueKey('book-paper')),
                matching: find.byType(Stack),
              )
              .first,
        );
        final paperIndex = stack.children.indexWhere(
          (w) => w is Positioned && w.child.key == const ValueKey('book-paper'),
        );
        final coverIndex = stack.children.indexWhere(
          (w) =>
              w is Positioned &&
              w.child.key == const ValueKey('book-front-cover'),
        );
        expect(
          coverIndex,
          greaterThan(paperIndex),
          reason: 'Cover always paints in front of paper',
        );
      }
      animation.value = 1;
      await tester.pump();
      await tester.pump();
      expect(find.byKey(const Key('reading-page')), findsOneWidget);
      expect(mounts, 1);
      final snapshot =
          tester
                  .widget<ListenableBuilder>(
                    find.descendant(
                      of: find.byKey(const ValueKey('book-paper')),
                      matching: find.byType(ListenableBuilder),
                    ),
                  )
                  .listenable
              as SnapshotController;
      animation.reverse();
      await tester.pump();
      expect(
        snapshot.allowSnapshotting,
        true,
        reason: 'Closing freezes asynchronous reader content',
      );
      await tester.pump(const Duration(milliseconds: 100));
      animation.value = 0;
      await tester.pump();
      final last = tester
          .widget<Transform>(find.byKey(const ValueKey('book-front-cover')))
          .transform;
      for (var i = 0; i < 16; i++) {
        expect(last.storage[i], closeTo(first.storage[i], .000001));
      }
      expect(mounts, 1);
      expect(unmounts, 0);
      expect(
        closed,
        1,
        reason: 'Completion follows animation state, no fixed timer',
      );
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'closing keeps paper and cover geometry when system bars change',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final animation = AnimationController(
        vsync: tester,
        duration: const Duration(milliseconds: 600),
      );
      addTearDown(animation.dispose);
      const reader = SizedBox(key: Key('viewport-reader'));
      await tester.pumpWidget(
        MaterialApp(
          home: BookOpeningTransition(
            opening: const BookOpening(
              Rect.fromLTWH(20, 160, 100, 156),
              0,
              '来信',
              '20%',
            ),
            animation: animation,
            child: reader,
          ),
        ),
      );
      animation.forward();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pump();
      await tester.pumpAndSettle();
      expect(animation.isCompleted, isTrue);
      final readerContext = tester.element(
        find.byKey(const Key('viewport-reader')),
      );
      final before = MediaQuery.of(readerContext);
      animation.reverse();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      final paperBefore = tester
          .widget<Transform>(find.byKey(const ValueKey('book-paper')))
          .transform
          .clone();
      tester.view.physicalSize = const Size(390, 800);
      tester.view.padding = const FakeViewPadding(top: 32, bottom: 16);
      await tester.pump();
      final paperAfter = tester
          .widget<Transform>(find.byKey(const ValueKey('book-paper')))
          .transform;
      expect(
        MediaQuery.of(readerContext),
        before,
        reason: 'Reader typography/insets remain frozen while closing',
      );
      for (var i = 0; i < 16; i++) {
        expect(
          paperAfter.storage[i],
          closeTo(paperBefore.storage[i], .000001),
          reason: 'Native surface changes cannot jump the shared plane',
        );
      }
      animation.value = 0;
      await tester.pump();
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('shelf release waits for real route overlay completion', (
    tester,
  ) async {
    final navigator = GlobalKey<NavigatorState>();
    var closed = 0;
    await tester.pumpWidget(
      MaterialApp(navigatorKey: navigator, home: const Scaffold()),
    );
    navigator.currentState!.push(
      PageRouteBuilder<void>(
        opaque: false,
        transitionDuration: const Duration(milliseconds: 600),
        reverseTransitionDuration: const Duration(milliseconds: 600),
        pageBuilder: (_, _, _) => const ColoredBox(color: Colors.white),
        transitionsBuilder: (_, animation, _, child) => BookOpeningTransition(
          opening: BookOpening(
            const Rect.fromLTWH(20, 160, 100, 156),
            0,
            '来信',
            '20%',
            onClosed: () => closed++,
          ),
          animation: animation,
          child: child,
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump();
    navigator.currentState!.pop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 590));
    expect(
      closed,
      0,
      reason: 'push future is finished but the overlay is still closing',
    );
    await tester.pump(const Duration(milliseconds: 20));
    await tester.pump();
    expect(
      closed,
      1,
      reason: 'overlay completion releases the frozen shelf exactly once',
    );
    expect(find.byType(BookOpeningTransition), findsNothing);
  });
}

class _ReaderProbe extends StatefulWidget {
  const _ReaderProbe({required this.onMount, required this.onUnmount});
  final VoidCallback onMount, onUnmount;
  @override
  State<_ReaderProbe> createState() => _ReaderProbeState();
}

class _ReaderProbeState extends State<_ReaderProbe> {
  @override
  void initState() {
    super.initState();
    widget.onMount();
  }

  @override
  void dispose() {
    widget.onUnmount();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      const ColoredBox(key: Key('reading-page'), color: Colors.white);
}
