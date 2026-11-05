// AOT profile harness with real Android input. It has no test clock or user data.
import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';
import 'dart:ui' as ui;

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sorryread_mobile/app/dependencies.dart';
import 'package:sorryread_mobile/app/reader_app.dart';
import 'package:sorryread_mobile/app/router.dart';
import 'package:sorryread_mobile/data/sync_repository.dart';
import 'package:sorryread_mobile/features/reader/data/reader_repository.dart';
import 'package:sorryread_mobile/features/reader/data/reader_source.dart';
import 'package:sorryread_mobile/features/sync/application/sync_controller.dart';

import '../test/support/test_runtime.dart' show MemoryPeerStorage;

class _ProfileReader extends ReaderRepository {
  _ProfileReader(super.directory, super.rules);
  @override
  Future<(String, String)> fetchSearch(
    SourceRule source,
    String url, {
    String method = 'GET',
    Map<String, String>? form,
    CancelToken? cancelToken,
  }) async {
    await Future<void>.delayed(
      Duration(milliseconds: source.id == 's7' ? 5000 : 20),
    );
    return (
      '<table id="results">${List.generate(50, (i) => '<tr><td><a href="/book/$i">山间来信 ${i + 1}</a></td><td>作者：林间</td></tr>').join()}</table>',
      url,
    );
  }
}

class _NoSync extends SyncController {
  @override
  Future<SyncViewState> build() async => const SyncViewState();
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final root = await getApplicationSupportDirectory();
  final report = File('${root.path}/normal-search-profile.json');
  final control = File('${root.path}/normal-search-control.json');
  if (await control.exists()) await control.delete();
  final failures = <String>[];
  final oldError = FlutterError.onError;
  FlutterError.onError = (details) {
    failures.add('${details.exceptionAsString()}\n${details.stack}');
    oldError?.call(details);
  };
  final sync = SyncRepository(SyncDatabase(NativeDatabase.memory()));
  await sync.initialize();
  const names = [
    '书海阁小说网',
    '梦书中文',
    '起点中文网',
    '我的书城网',
    '晋江文学城',
    '豆瓣阅读',
    '笔趣书屋',
    '香书小说',
  ];
  final directory = Directory('${root.path}/normal-search-fixture');
  await directory.create(recursive: true);
  final reader = _ProfileReader(directory, [
    for (var i = 0; i < names.length; i++)
      SourceRule({
        'id': 's$i',
        'name': names[i],
        'baseUrl': 'https://s$i.invalid/',
        'dynamic': false,
        'detail': <String, dynamic>{},
        'catalog': {'itemSelector': '#chapters a'},
        'chapter': {'contentSelector': '#content', 'titleSelector': 'h1'},
        'search': {
          'uriTemplate': 'https://s$i.invalid/search?q={keyword}',
          'resultSelector': '#results tr',
          'titleLinkSelector': 'td:nth-child(1) a',
          'authorSelector': 'td:nth-child(2)',
        },
      }),
  ]);
  final container = ProviderContainer(
    overrides: [
      syncRepositoryProvider.overrideWith((ref) async => sync),
      readerRepositoryProvider.overrideWith((ref) async {
        ref.keepAlive();
        return reader;
      }),
      peerStorageProvider.overrideWithValue(MemoryPeerStorage()),
      backgroundSyncEnabledProvider.overrideWithValue(false),
      syncControllerProvider.overrideWith(_NoSync.new),
    ],
  );
  final frames = <ui.FrameTiming>[];
  final windows = <Map<String, int>>[];
  final appKey = GlobalKey();
  var dockBlurEnabled = true;
  SchedulerBinding.instance.addTimingsCallback(frames.addAll);
  runApp(
    UncontrolledProviderScope(
      container: container,
      child: Listener(
        key: appKey,
        behavior: HitTestBehavior.translucent,
        onPointerDown: (event) {
          final view = WidgetsBinding.instance.platformDispatcher.views.first;
          final height = view.physicalSize.height / view.devicePixelRatio;
          if (event.position.dy > 230 && event.position.dy < height - 120) {
            windows.add({'startUs': developer.Timeline.now});
          }
        },
        onPointerUp: (_) {
          if (windows.isNotEmpty && !windows.last.containsKey('endUs')) {
            windows.last['endUs'] = developer.Timeline.now + 450000;
          }
        },
        child: const ReaderApp(),
      ),
    ),
  );
  container.read(appRouterProvider).go('/discover/results?mode=normal&q=性能验收');
  Future<void> save() async {
    final refresh = WidgetsBinding
        .instance
        .platformDispatcher
        .views
        .first
        .display
        .refreshRate;
    final sampled = frames.where((frame) {
      final stamp = frame.timestampInMicroseconds(ui.FramePhase.vsyncStart);
      return windows.any(
        (window) =>
            stamp >= window['startUs']! &&
            stamp <= (window['endUs'] ?? developer.Timeline.now),
      );
    }).toList();
    await report.writeAsString(
      jsonEncode({
        'profileMode': kProfileMode,
        'phase': 'ready',
        'refreshRateHz': refresh,
        'dockBlurEnabled': dockBlurEnabled,
        'failures': failures,
        'windows': windows,
        'frames': [
          for (final frame in sampled)
            {
              'vsyncUs': frame.timestampInMicroseconds(
                ui.FramePhase.vsyncStart,
              ),
              'buildUs': frame.buildDuration.inMicroseconds,
              'rasterUs': frame.rasterDuration.inMicroseconds,
              'totalUs': frame.totalSpan.inMicroseconds,
            },
        ],
      }),
      flush: true,
    );
  }

  await Future<void>.delayed(const Duration(seconds: 1));
  await save();
  var polling = false;
  Timer.periodic(const Duration(milliseconds: 200), (_) async {
    if (polling) return;
    polling = true;
    try {
      if (await control.exists()) {
        final command = (await control.readAsString()).trim();
        await control.delete();
        if (command == 'blur-on' || command == 'blur-off') {
          dockBlurEnabled = command == 'blur-on';
          var filters = 0;
          void visit(Element element) {
            if (element.widget is BackdropFilter) {
              (element.findRenderObject()! as RenderBackdropFilter).enabled =
                  dockBlurEnabled;
              filters++;
            }
            element.visitChildren(visit);
          }

          appKey.currentContext!.visitChildElements(visit);
          if (filters != 1) {
            failures.add('Expected one dock filter; found $filters');
          }
          frames.clear();
          windows.clear();
        } else if (command == 'reset') {
          frames.clear();
          windows.clear();
        }
        await save();
      }
    } finally {
      polling = false;
    }
  });
}
