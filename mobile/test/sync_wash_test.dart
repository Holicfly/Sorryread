import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sorryread_mobile/features/sync/presentation/sync_wash.dart';

class _BuildProbe extends StatelessWidget {
  const _BuildProbe(this.onBuild);
  final VoidCallback onBuild;
  @override
  Widget build(BuildContext context) {
    onBuild();
    return const SizedBox(width: 320, height: 120);
  }
}

void main() {
  testWidgets(
    'only connected wash moves; hidden, background and reduced motion pause it',
    (tester) async {
      final flags = ValueNotifier((
        connected: true,
        visible: true,
        reduced: false,
      ));
      addTearDown(flags.dispose);
      var contentBuilds = 0;
      final child = _BuildProbe(() => contentBuilds++);
      await tester.pumpWidget(
        MaterialApp(
          home: Center(
            child: ValueListenableBuilder(
              valueListenable: flags,
              builder: (context, value, _) => TickerMode(
                enabled: value.visible,
                child: MediaQuery(
                  data: MediaQuery.of(context)
                      .copyWith(disableAnimations: value.reduced),
                  child: RepaintBoundary(
                    key: const Key('wash-frame'),
                    child: SyncWash(connected: value.connected, child: child),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      SyncWashPainter painter() =>
          tester
                  .widget<CustomPaint>(
                    find.byKey(const Key('connected-sync-wash')),
                  )
                  .painter!
              as SyncWashPainter;
      Future<Uint8List> pixels() async {
        return (await tester.runAsync(() async {
          final image = await tester
              .renderObject<RenderRepaintBoundary>(
                find.byKey(const Key('wash-frame')),
              )
              .toImage();
          final bytes = await image.toByteData(
            format: ui.ImageByteFormat.rawRgba,
          );
          image.dispose();
          return bytes!.buffer.asUint8List();
        }))!;
      }

      final initial = await pixels();
      final builds = contentBuilds;
      await tester.pump(const Duration(seconds: 2));
      expect(painter().clock.value, greaterThan(0));
      expect(listEquals(initial, await pixels()), isFalse);
      expect(contentBuilds, builds);

      flags.value = (connected: true, visible: false, reduced: false);
      await tester.pump();
      var frozen = painter().clock.value;
      await tester.pump(const Duration(seconds: 2));
      expect(painter().clock.value, frozen);
      flags.value = (connected: true, visible: true, reduced: false);
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(painter().clock.value, greaterThan(frozen));

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      frozen = painter().clock.value;
      await tester.pump(const Duration(seconds: 2));
      expect(painter().clock.value, frozen);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(painter().clock.value, greaterThan(frozen));

      flags.value = (connected: true, visible: true, reduced: true);
      await tester.pump();
      frozen = painter().clock.value;
      await tester.pump(const Duration(seconds: 2));
      expect(painter().clock.value, frozen);
      flags.value = (connected: false, visible: true, reduced: false);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('connected-sync-wash')), findsNothing);
      final context = tester.element(find.byType(SyncWash));
      final surface = Theme.of(context).colorScheme.surface.toARGB32();
      final idle = await pixels();
      final offset = (60 * 320 + 20) * 4;
      expect(idle.sublist(offset, offset + 4), [
        (surface >> 16) & 255,
        (surface >> 8) & 255,
        surface & 255,
        surface >> 24,
      ]);
      await tester.pumpWidget(const SizedBox.shrink());
      expect(tester.takeException(), isNull);
    },
  );
}
