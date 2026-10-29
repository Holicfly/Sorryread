import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sorryread_mobile/features/discover/data/yeshe_index.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  const label = String.fromEnvironment('SPEED_LABEL', defaultValue: 'baseline');
  const full = bool.fromEnvironment('FULL_CRAWL');
  const resumeOnly = bool.fromEnvironment('RESUME_ONLY');
  testWidgets('isolated yeshe speed $label', (tester) async {
    final root = await getApplicationSupportDirectory();
    final file = File('${root.path}/yeshe-speed-$label.json');
    final repo = YesheIndexRepository();
    final report = <String, dynamic>{'label': label, 'passed': false};
    Future<void> save(String phase) async {
      report['phase'] = phase;
      await file.writeAsString(jsonEncode(report), flush: true);
    }

    addTearDown(() async {
      await repo.pause();
      report['failures'] = binding.failureMethodsDetails
          .map((e) => e.details)
          .toList();
      await save(report['phase'] as String? ?? 'startup');
    });
    await save('startup');
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: Center(child: Text('独立测试包：夜社下载测速'))),
      ),
    );
    Future<YesheIndexStatus> waitFor(
      bool Function(YesheIndexStatus) ready, {
      int seconds = 90,
    }) async {
      final deadline = DateTime.now().add(Duration(seconds: seconds));
      while (DateTime.now().isBefore(deadline)) {
        final s = await repo.status();
        if (ready(s)) return s;
        // A resumed native service clears the previous run's error on its worker.
        if (s.error.isNotEmpty &&
            DateTime.now().isAfter(
              deadline.subtract(Duration(seconds: seconds - 2)),
            )) {
          fail(s.error);
        }
        await Future<void>.delayed(const Duration(milliseconds: 150));
      }
      fail('Native cache wait timed out');
    }

    await repo.pause();
    await waitFor((s) => !s.running);
    if (resumeOnly) {
      report['before'] = (await repo.status()).data;
      await repo.start();
      final complete = await waitFor((s) => s.complete, seconds: 90);
      expect(complete.pages, (complete.total + 29) ~/ 30);
      expect(complete.count, complete.total);
      final (books, count) = await repo.search('', 0);
      expect(books.length, 50);
      expect(count, complete.total);
      report['complete'] = complete.data;
      report['passed'] = true;
      await save('complete');
      await tester.pumpWidget(const SizedBox.shrink());
      return;
    }
    if (full) {
      final legacy = await repo.status();
      if (legacy.pages > 0 && !legacy.complete) {
        await repo.start();
        final resumed = await waitFor((s) => s.pages >= legacy.pages + 8);
        await repo.pause();
        await waitFor((s) => !s.running);
        expect(resumed.count, greaterThanOrEqualTo(legacy.count));
        report['legacyResume'] = {'before': legacy.data, 'after': resumed.data};
      }
    }
    await repo.refresh();
    final before = await repo.status();
    report['before'] = before.data;
    final watch = Stopwatch()..start();
    await repo.start();
    await save('measuring');
    var s = await waitFor((s) => s.pages >= 24, seconds: 180);
    await repo.pause();
    s = await waitFor((s) => !s.running);
    watch.stop();
    report['sample'] = {
      'pages': s.pages,
      'milliseconds': watch.elapsedMilliseconds,
      'pagesPerSecond': s.pages * 1000 / watch.elapsedMilliseconds,
      'state': s.data,
    };
    await save('sample-complete');
    final pausedPages = s.pages;
    await Future<void>.delayed(const Duration(seconds: 2));
    expect((await repo.status()).pages, pausedPages);
    if (full) {
      await repo.start();
      await waitFor((s) => s.pages >= pausedPages + 8);
      report['gate'] = 'yeshe-speed-continue';
      final gate = File('${root.path}/yeshe-speed-continue');
      if (await gate.exists()) await gate.delete();
      await save('background');
      final deadline = DateTime.now().add(const Duration(minutes: 2));
      while (!await gate.exists() && DateTime.now().isBefore(deadline)) {
        report['backgroundState'] = (await repo.status()).data;
        await save('background');
        await Future<void>.delayed(const Duration(seconds: 1));
      }
      expect(
        await gate.exists(),
        isTrue,
        reason: 'Host background gate not received',
      );
      await save('full-crawl');
      final end = DateTime.now().add(const Duration(minutes: 10));
      while (DateTime.now().isBefore(end)) {
        s = await repo.status();
        report['current'] = s.data;
        await save('full-crawl');
        if (s.error.isNotEmpty) fail(s.error);
        if (s.complete) break;
        await Future<void>.delayed(const Duration(seconds: 2));
      }
      expect(s.complete, isTrue);
      expect(s.pages, (s.total + 29) ~/ 30);
      expect(s.count, s.total);
      final (books, count) = await repo.search('', 0);
      expect(books.length, 50);
      expect(count, s.total);
      final found = await repo.search(books.first.title, 0);
      expect(found.$1.any((b) => b.url == books.first.url), isTrue);
      report['complete'] = s.data;
    }
    report['passed'] = true;
    await save('complete');
    await tester.pumpWidget(const SizedBox.shrink());
  }, timeout: const Timeout(Duration(minutes: 14)));
}
