import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sorryread_mobile/data/local_library.dart';
import 'package:sorryread_mobile/features/reader/presentation/reader_page.dart';
import 'package:sorryread_mobile/features/reader/presentation/reader_preferences.dart';

import 'reader_page_test.dart' show mountReader, flushReader;

void main() {
  testWidgets(
    'only visible chapters enter local history; warmed chapters and background do not',
    (tester) async {
      final (reader, _) = await mountReader(
        tester,
        startChapter: 4,
        preferences: const ReaderPreferences(mode: PageMode.scroll),
      );
      await flushReader(tester);
      expect(
        reader.requested,
        containsAll([
          'https://example.invalid/chapter/3',
          'https://example.invalid/chapter/5',
        ]),
      );
      final container = ProviderScope.containerOf(
        tester.element(find.byType(ReaderPage)),
      );
      final local = (await tester.runAsync(
        () => container.read(localLibraryProvider.future),
      ))!;
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 30)),
      );
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await flushReader(tester);
      final first = (await tester.runAsync(
        () => local.readingOverview(DateTime.now()),
      ))!;
      expect(first.entries, hasLength(1));
      expect(first.entries.single.position!.chapterIndex, 4);
      expect(first.month.chapters, 1);
      final before = first.month.milliseconds;
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 40)),
      );
      expect(
        (await tester.runAsync(() => local.readingOverview(DateTime.now())))!
            .month
            .milliseconds,
        before,
      );
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await flushReader(tester);
      final body = find.byKey(const Key('reader-content'));
      await tester.tapAt(tester.getCenter(body));
      await tester.pumpAndSettle();
      await tester.tap(find.text('下一章').hitTestable());
      await flushReader(tester);
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 30)),
      );
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await flushReader(tester);
      final second = (await tester.runAsync(
        () => local.readingOverview(DateTime.now()),
      ))!;
      expect(second.entries, hasLength(1));
      expect(second.entries.single.position!.chapterIndex, 5);
      expect(second.month.chapters, 2);
      expect(second.month.milliseconds, greaterThan(before));
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      expect(tester.takeException(), isNull);
    },
  );
}
