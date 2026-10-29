// Standalone device probe. Uses the isolated profile package and its own cache.
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:sorryread_mobile/features/reader/data/reader_repository.dart';
import 'package:sorryread_mobile/features/reader/data/reader_source.dart';
import 'package:sorryread_mobile/features/reader/presentation/reader_asset_icon.dart';
import 'package:sorryread_mobile/features/reader/presentation/reader_status_bar.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MaterialApp(home: SourceReview()));
}

class BrowserOnlyAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async => ResponseBody.fromString('<html><body>Loading</body></html>', 200);
  @override
  void close({bool force = false}) {}
}

class SourceReview extends StatefulWidget {
  const SourceReview({super.key});
  @override
  State<SourceReview> createState() => _SourceReviewState();
}

class _SourceReviewState extends State<SourceReview> {
  ReaderRepository? repository;
  final results = <String>[];
  int? battery;
  bool charging = false;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => probe());
  }

  void record(String message) {
    debugPrint('SOURCE_REVIEW $message');
    if (mounted) setState(() => results.add(message));
  }

  Future<void> probe() async {
    final httpHashes = <String, String>{};
    final rules =
        (jsonDecode(await rootBundle.loadString('assets/reader_sources.json'))
                as List)
            .map((e) => SourceRule(Map<String, dynamic>.from(e as Map)))
            .toList();
    final base = await getApplicationSupportDirectory();
    for (final browserOnly in [false, true]) {
      final repo = ReaderRepository(
        Directory(
          '${base.path}/source-review-${browserOnly ? 'browser' : 'http'}',
        ),
        rules,
      );
      if (mounted) setState(() => repository = repo);
      try {
        if (browserOnly) repo.http.httpClientAdapter = BrowserOnlyAdapter();
        final timer = Stopwatch()..start();
        final status = await repo.platform.batteryStatus();
        if (mounted) {
          setState(() {
            battery = status.level;
            charging = status.charging;
          });
        }
        final source = repo.source(
          '18mh',
          'https://18mh.net/novel/detail/7600',
        );
        final catalog = await repo.catalog(
          source,
          'https://18mh.net/novel/detail/7600',
          refresh: true,
        );
        record(
          '${browserOnly ? 'browser' : 'http'} catalog=${catalog.chapters.length}',
        );
        for (final link in catalog.chapters.take(2)) {
          final body = await repo.chapter(
            source,
            link,
            catalog.chapters,
            refresh: true,
          );
          if (body.paragraphs.isEmpty || body.title != link.title) {
            throw StateError('chapter mismatch');
          }
          record(
            '${browserOnly ? 'browser' : 'http'} chapter paragraphs=${body.paragraphs.length}, titleMatches=true',
          );
          if (!browserOnly) {
            httpHashes[link.url] = body.hash;
          } else {
            record('browser matchesHTTP=${httpHashes[link.url] == body.hash}');
            if (httpHashes[link.url] != body.hash) {
              throw StateError('browser body differs from HTTP body');
            }
          }
        }
        record(
          '${browserOnly ? 'browser' : 'http'} PASS elapsed=${timer.elapsedMilliseconds}ms webView=${repo.webView != null}',
        );
      } catch (e) {
        record('${browserOnly ? 'browser' : 'http'} FAIL $e');
      }
      if (mounted) setState(() => repository = null);
      await WidgetsBinding.instance.endOfFrame;
      repo.dispose();
    }
    record('DONE');
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: const Color(0xfff5efdc),
    body: SafeArea(
      child: Stack(
        children: [
          if (repository != null)
            Positioned.fill(
              child: ValueListenableBuilder(
                valueListenable: repository!.dynamicView,
                builder: (context, controller, _) => controller == null
                    ? const SizedBox.shrink()
                    :
                      // Match the production reader's mounted, covered browser viewport.
                      WebViewWidget(controller: controller),
              ),
            ),
          Positioned.fill(
            child: ColoredBox(
              color: const Color(0xfff5efdc),
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('18mh 连接与解析检查', style: TextStyle(fontSize: 20)),
                    const SizedBox(height: 20),
                    for (final result in results) Text(result),
                    const Spacer(),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceAround,
                      children: [
                        for (final entry in [
                          ('catalog', '目录'),
                          ('night', '夜间'),
                          ('day', '日间'),
                          ('settings', '设置'),
                        ])
                          Column(
                            children: [
                              ReaderAssetIcon(
                                entry.$1,
                                color: const Color(0xff33352e),
                              ),
                              const SizedBox(height: 6),
                              Text(entry.$2),
                            ],
                          ),
                      ],
                    ),
                    const SizedBox(height: 24),
                    ReaderStatusBar(
                      level: battery,
                      charging: charging,
                      time: DateTime.now(),
                      chapterTitle: '第108章 山间来信',
                      ink: const Color(0xff33352e),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    ),
  );
}
