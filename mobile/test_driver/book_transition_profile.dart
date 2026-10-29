// Isolated profile-mode harness: real pointer input and real engine frames.
// No WidgetTester clock, no synthetic delays or screenshot work in samples.
import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';
import 'dart:ui' as ui;

import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sorryread_mobile/app/dependencies.dart';
import 'package:sorryread_mobile/app/reader_app.dart';
import 'package:sorryread_mobile/data/sync_repository.dart';
import 'package:sorryread_mobile/features/bookshelf/presentation/book_opening.dart';
import 'package:sorryread_mobile/features/reader/data/reader_repository.dart';
import 'package:sorryread_mobile/features/reader/data/reader_font_warmup.dart';
import 'package:sorryread_mobile/features/reader/data/reader_source.dart';
import 'package:sorryread_mobile/features/sync/application/sync_controller.dart';

import '../test/support/test_runtime.dart' show MemoryPeerStorage;

class _ProfileReader extends ReaderRepository {
  _ProfileReader(super.directory, super.rules);
  int catalogCalls = 0;
  final body = ReaderChapter(
    '第一章 山间来信',
    'https://fixture.invalid/chapter/1',
    List.generate(140, (i) => '第$i 段：山间有风，书中有远方。这是用于开合书性能验收的合成正文，验证实际阅读器负载。'),
  )..prepareMetrics();
  @override
  Future<ReaderCatalog> catalog(
    SourceRule source,
    String detailUrl, {
    bool refresh = false,
  }) async {
    await Future<void>.delayed(
      Duration(milliseconds: catalogCalls++ == 0 ? 1200 : 0),
    );
    return const ReaderCatalog([
      ChapterLink('第一章 山间来信', 'https://fixture.invalid/chapter/1'),
    ]);
  }

  @override
  Future<ReaderChapter> chapter(
    SourceRule source,
    ChapterLink link,
    List<ChapterLink> catalog, {
    bool refresh = false,
  }) async => body;
  @override
  Future<String> fetch(SourceRule source, String url) async {
    await Future<void>.delayed(const Duration(milliseconds: 80));
    if (url.contains('/chapter/')) {
      return '<h1>第一章 山间来信</h1><div id="content">${List.generate(140, (i) => '<p>第$i 段：山间有风，书中有远方。这是用于开合书性能验收的合成正文，验证实际阅读器负载。</p>').join()}</div>';
    }
    return '<div id="chapters"><a href="/chapter/1">第一章 山间来信</a></div>';
  }
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final support = await getApplicationSupportDirectory();
  final output = support;
  final report = File('${output.path}/v029-performance.json');
  final control = File('${output.path}/v029-control.json');
  if (await report.exists()) await report.delete();
  if (await control.exists()) await control.delete();
  final info = await developer.Service.controlWebServer(enable: true);
  if (info.serverUri != null) {
    await File('${output.path}/v029-vm-uri.txt')
        .writeAsString(info.serverUri.toString());
  }
  final failures = <String>[];
  final previous = FlutterError.onError;
  FlutterError.onError = (e) {
    failures.add('${e.exceptionAsString()}\n${e.stack}');
    previous?.call(e);
  };
  final sync = SyncRepository(SyncDatabase(NativeDatabase.memory()));
  await sync.initialize();
  final reader = _ProfileReader(
    Directory(
      '${support.path}/v029-reader-${DateTime.now().millisecondsSinceEpoch}',
    ),
    [
      SourceRule({
        'id': 'fixture',
        'baseUrl': 'https://fixture.invalid',
        'dynamic': false,
        'detail': <String, dynamic>{},
        'catalog': {'itemSelector': '#chapters a'},
        'chapter': {'titleSelector': 'h1', 'contentSelector': '#content'},
      }),
    ],
  );
  await reader.write('preferences', {
    'font': 'wenkai',
    'fontSize': 22,
    'palette': 2,
    'mode': 'scroll',
  });
  for (var i = 0; i < 3; i++) {
    final metadata = <String, dynamic>{
      'kind': 'book',
      'title': '山间来信 ${i + 1}',
      'sourceId': 'fixture',
      'sourceName': '性能验收',
      'detailUrl': 'https://fixture.invalid/book/$i',
      'chapterUrl': '',
      'chapterTitle': '',
      'progress': 0.0,
      'active': true,
    };
    final id = 'book:fixture|https://fixture.invalid/book/$i';
    await sync.localChange(id, 'favorite', metadata);
    await sync.localChange(id, 'recent', metadata);
  }
  final key = GlobalKey();
  final frames = <ui.FrameTiming>[];
  final windows = <Map<String, dynamic>>[];
  final paperReady = <int>[];
  String label = 'idle', lastControl = '';
  bool writing = false, polling = false;
  void collect(List<ui.FrameTiming> f) => frames.addAll(f);
  SchedulerBinding.instance.addTimingsCallback(collect);
  Future<void> save() async {
    if (writing) return;
    writing = true;
    try {
      await report.writeAsString(
        jsonEncode({
          'profileMode': kProfileMode,
          'phase': 'ready',
          'failures': failures,
          'refreshRateHz': WidgetsBinding
              .instance
              .platformDispatcher
              .views
              .first
              .display
              .refreshRate,
          'windows': windows,
          'paperReadyUs': paperReady,
          'timelineClockUs': developer.Timeline.now,
          'rawFrames': [
            for (final f in frames)
              {
                'vsyncUs': f.timestampInMicroseconds(ui.FramePhase.vsyncStart),
                'buildStartUs': f.timestampInMicroseconds(
                  ui.FramePhase.buildStart,
                ),
                'buildUs': f.buildDuration.inMicroseconds,
                'rasterUs': f.rasterDuration.inMicroseconds,
                'rasterStartUs': f.timestampInMicroseconds(
                  ui.FramePhase.rasterStart,
                ),
                'totalUs': f.totalSpan.inMicroseconds,
                'vsyncOverheadUs': f.vsyncOverhead.inMicroseconds,
              },
          ],
        }),
        flush: true,
      );
    } finally {
      writing = false;
    }
  }

  void beginWindow() {
    windows.add(<String, dynamic>{
      'name': label,
      'startUs': developer.Timeline.now,
    });
    label = 'idle';
  }

  void pointer(PointerUpEvent event) {
    if (label.endsWith('-open') || label.endsWith('-close')) beginWindow();
  }

  bool transitionStatus(BookOpeningStatus event) {
    if (event.status == AnimationStatus.reverse && label.endsWith('-close')) {
      beginWindow();
    }
    if ((event.status == AnimationStatus.completed ||
            event.status == AnimationStatus.dismissed) &&
        windows.isNotEmpty) {
      final window = windows.last;
      if (window['endUs'] == null) window['endUs'] = developer.Timeline.now;
    }
    return false;
  }

  runApp(
    ProviderScope(
      overrides: [
        readerFontWarmupProvider.overrideWithValue(
          () => warmStoredReaderFont(reader.directory),
        ),
        syncRepositoryProvider.overrideWith((ref) async => sync),
        readerRepositoryProvider.overrideWith((ref) async {
          ref.keepAlive();
          return reader;
        }),
        peerStorageProvider.overrideWithValue(MemoryPeerStorage()),
        backgroundSyncEnabledProvider.overrideWithValue(false),
      ],
      child: NotificationListener<BookPaperReady>(
        onNotification: (_) {
          paperReady.add(developer.Timeline.now);
          return false;
        },
        child: NotificationListener<BookOpeningStatus>(
          onNotification: transitionStatus,
          child: Listener(
            key: key,
            behavior: HitTestBehavior.translucent,
            onPointerUp: pointer,
            child: const ReaderApp(),
          ),
        ),
      ),
    ),
  );
  await Future<void>.delayed(const Duration(seconds: 1));
  await save();
  Timer.periodic(const Duration(milliseconds: 100), (_) async {
    if (polling) return;
    polling = true;
    try {
      if (!await control.exists()) return;
      final text = await control.readAsString();
      if (text == lastControl) return;
      lastControl = text;
      final command = jsonDecode(text) as Map<String, dynamic>;
      if (command['action'] == 'report') {
        await save();
      } else {
        label = command['label'] as String? ?? 'idle';
      }
    } on FormatException {
      /* Wait for the host's atomic replacement. */
    } finally {
      polling = false;
    }
  });
}
