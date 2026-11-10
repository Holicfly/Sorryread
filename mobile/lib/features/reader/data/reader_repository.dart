import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:webview_flutter/webview_flutter.dart';

import 'reader_platform.dart';
import 'reader_source.dart';

Map<String, dynamic> _decodeMap(String text) =>
    Map<String, dynamic>.from(jsonDecode(text) as Map);
String _encodeMap(Map<String, dynamic> value) => jsonEncode(value);
String _decodeUtf8(Uint8List bytes) => utf8.decode(bytes, allowMalformed: true);
ReaderChapter _measureChapter(ReaderChapter chapter) =>
    chapter..prepareMetrics();
ReaderChapter _cachedChapter(Map<String, dynamic> json) =>
    ReaderChapter.fromJson(json)..prepareMetrics();
ReaderCatalog _cachedCatalog(Map<String, dynamic> json) =>
    ReaderCatalog.fromJson(json);
bool _pageReady((SourceRule, String, String) input) =>
    readerPageReady(input.$1, input.$2, input.$3);
(List<ChapterLink>, List<String>) _parseCatalog(
  (SourceRule, String, String) input,
) => (
  parseCatalogPage(input.$1, input.$2, input.$3),
  catalogPages(input.$1, input.$2, input.$3),
);
(ReaderChapter, String?) _parseChapter(
  (SourceRule, String, ChapterLink, List<ChapterLink>) input,
) => (
  parseChapterPage(input.$1, input.$2, input.$3),
  chapterContinuation(input.$1, input.$2, input.$3.url, input.$4),
);

final readerRepositoryProvider = FutureProvider.autoDispose<ReaderRepository>((
  ref,
) async {
  final directory = await getApplicationSupportDirectory();
  final rules =
      (jsonDecode(await rootBundle.loadString('assets/reader_sources.json'))
              as List)
          .map((v) => SourceRule(Map<String, dynamic>.from(v as Map)))
          .toList();
  final result = ReaderRepository(
    Directory('${directory.path}/reading'),
    rules,
  );
  ref.onDispose(result.dispose);
  return result;
});

class ReaderRepository {
  ReaderRepository(this.directory, this.rules);
  final Directory directory;
  final List<SourceRule> rules;
  final platform = ReaderPlatform();
  final Dio http = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(seconds: 20),
      headers: {
        'User-Agent': 'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 Chrome/136.0 Mobile Safari/537.36',
      },
    ),
  );
  final _cancel = CancelToken();
  final _chapterRequests = <String, Future<ReaderChapter>>{};
  Future<void> _dynamicTail = Future.value();
  Timer? _trimTimer;
  bool _disposed = false;
  bool readingBusy = false;
  final dynamicView = ValueNotifier<WebViewController?>(null);
  WebViewController? get webView => dynamicView.value;
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _trimTimer?.cancel();
    _cancel.cancel();
    http.close(force: true);
    dynamicView.dispose();
  }

  String key(String value) => sha256.convert(utf8.encode(value)).toString();
  File file(String name) => File('${directory.path}/$name.json');

  Future<Map<String, dynamic>?> read(String name) async {
    try {
      final text = await file(name).readAsString();
      return text.length > 16384
          ? await compute(_decodeMap, text)
          : _decodeMap(text);
    } on FileSystemException {
      return null;
    } on FormatException {
      return null;
    } on TypeError {
      return null;
    }
  }

  Future<void> write(String name, Map<String, dynamic> value) async {
    await directory.create(recursive: true);
    final target = file(name);
    final temp = File('${target.path}.tmp');
    final text =
        value.containsKey('paragraphs') || value.containsKey('chapters')
        ? await compute(_encodeMap, value)
        : jsonEncode(value);
    await temp.writeAsString(text, flush: true);
    await temp.rename(target.path);
  }

  SourceRule source(String id, String detailUrl) {
    final host = Uri.tryParse(detailUrl)?.host;
    final rule =
        rules.where((s) => s.id == id.toLowerCase()).firstOrNull ??
        rules
            .where(
              (s) => host != null && (s.host == host || s.legacyHost == host),
            )
            .firstOrNull;
    if (rule == null) throw const ReaderFailure('该书源尚无手机解析规则，无法加载正文。');
    return rule;
  }

  Future<String> fetch(SourceRule source, String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null ||
        !['http', 'https'].contains(uri.scheme) ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty) {
      throw const ReaderFailure('章节链接无效。');
    }
    if (source.dynamicPage) {
      // 18mh currently serves the catalog and .article lines in its response.
      // Prefer that DOM: no script timers, trackers or browser work while reading.
      try {
        final markup = await _httpHtml(source, url);
        if (await compute(_pageReady, (source, markup, url))) return markup;
      } on ReaderFailure {
        if (_cancel.isCancelled) rethrow;
        // A browser-rendered response may still work when HTTP is challenged.
      }
      // Foreground jumps and speculative loads share one WebView. Serialize all
      // navigation so one chapter cannot accidentally capture another page's DOM.
      final next = _dynamicTail.then((_) => _dynamicHtml(source, url));
      _dynamicTail = next.then<void>(
        (_) {},
        onError: (Object _, StackTrace _) {},
      );
      return next;
    }
    return _httpHtml(source, url);
  }

  Future<(String, String)> fetchSearch(
    SourceRule source,
    String url, {
    String method = 'GET',
    Map<String, String>? form,
    CancelToken? cancelToken,
  }) async {
    var resolved = url;
    final markup = await _httpHtml(
      source,
      url,
      method: method,
      form: form,
      cancelToken: cancelToken,
      cookie: (source.json['search'] as Map?)?['cookieHeader'] as String?,
      onResolved: (value) => resolved = value,
    );
    return (markup, resolved);
  }

  Future<String> _httpHtml(
    SourceRule source,
    String url, {
    String method = 'GET',
    Map<String, String>? form,
    CancelToken? cancelToken,
    String? cookie,
    void Function(String)? onResolved,
  }) async {
    try {
      var target = url, requestMethod = method;
      var payload = form;
      late Response<List<int>> response;
      for (var redirects = 0; ; redirects++) {
        response = await http.request<List<int>>(
          target,
          data: payload,
          cancelToken: cancelToken ?? _cancel,
          options: Options(
            method: requestMethod,
            contentType: payload == null
                ? null
                : Headers.formUrlEncodedContentType,
            responseType: ResponseType.bytes,
            followRedirects: onResolved == null,
            validateStatus: onResolved == null
                ? null
                : (code) => code != null && code >= 200 && code < 400,
            headers: {
              'Referer': source.json['baseUrl'],
              if (cookie?.isNotEmpty == true) 'Cookie': cookie,
            },
          ),
        );
        if (onResolved == null ||
            ![301, 302, 303, 307, 308].contains(response.statusCode)) {
          break;
        }
        final location = response.headers.value('location');
        if (redirects >= 5 || location == null) {
          throw const ReaderFailure('搜索跳转异常，请稍后重试。');
        }
        final next = Uri.parse(target).resolve(location);
        if (!source.allowsSearchUrl(next)) {
          throw const ReaderFailure('书源跳转到了其他网站，已停止搜索。');
        }
        target = next.toString();
        // Match browser form submission semantics; 307/308 retain POST bodies.
        if (response.statusCode == 303 ||
            ([301, 302].contains(response.statusCode) &&
                requestMethod == 'POST')) {
          requestMethod = 'GET';
          payload = null;
        }
      }
      onResolved?.call(response.realUri.toString());
      final bytes = Uint8List.fromList(response.data!);
      if (bytes.length > 8 * 1024 * 1024) {
        throw const ReaderFailure('章节页面过大，已停止加载。');
      }
      final head = latin1.decode(bytes.take(4096).toList());
      final encoding =
          RegExp(r'''charset\s*=\s*["']?\s*([\w-]+)''', caseSensitive: false)
              .firstMatch(
                '${response.headers.value('content-type') ?? ''}\n$head',
              )
              ?.group(1)
              ?.toLowerCase();
      if (encoding == null || ['utf-8', 'utf8'].contains(encoding)) {
        return bytes.length > 16384
            ? await compute(_decodeUtf8, bytes)
            : _decodeUtf8(bytes);
      }
      return await platform.decode(
        ['gbk', 'gb2312'].contains(encoding) ? 'GB18030' : encoding,
        bytes,
      );
    } on DioException catch (e) {
      throw ReaderFailure(
        e.response?.statusCode == null
            ? '网络连接失败，请检查网络后重试。'
            : '书源返回 ${e.response!.statusCode}，请稍后重试。',
      );
    }
  }

  Future<String> _dynamicHtml(SourceRule source, String url) async {
    if (_cancel.isCancelled) throw const ReaderFailure('阅读已结束。');
    var controller = webView;
    if (controller == null) {
      controller = WebViewController();
      await controller.setJavaScriptMode(JavaScriptMode.unrestricted);
      if (_cancel.isCancelled) throw const ReaderFailure('阅读已结束。');
      dynamicView.value = controller;
    }
    String? networkError;
    await controller.setNavigationDelegate(
      NavigationDelegate(
        onWebResourceError: (error) {
          if (error.isForMainFrame == true && error.errorCode != -3) {
            networkError = error.description;
          }
        },
      ),
    );
    await controller.loadRequest(
      Uri.parse(url),
      headers: {'Referer': source.json['baseUrl'] as String},
    );
    for (var i = 0; i < 40; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 500));
      if (_cancel.isCancelled) throw const ReaderFailure('阅读已结束。');
      if (networkError != null) {
        throw ReaderFailure('书源页面连接失败（$networkError）。请确认 VPN 已覆盖本应用后重试。');
      }
      // WebView.getUrl() changes before the old document has been replaced.
      // Capture DOM URL, parse state and HTML in one JS task to avoid accepting
      // the previous chapter under the newly requested URL.
      final raw = await controller.runJavaScriptReturningResult(
        'JSON.stringify({url:location.href,state:document.readyState,html:document.documentElement.outerHTML})',
      );
      final snapshot = await compute(decodeReaderDomSnapshot, raw.toString());
      if (!snapshot.matches(url)) continue;
      final text = snapshot.markup;
      if (await compute(_pageReady, (source, text, url))) {
        return text;
      }
    }
    throw const ReaderFailure('动态书源正文未能加载，请稍后重试。');
  }

  Future<ReaderCatalog> catalog(
    SourceRule source,
    String detailUrl, {
    bool refresh = false,
  }) async {
    final name = 'catalog-${key(detailUrl)}';
    final cached = await read(name);
    if (!refresh && cached != null) return compute(_cachedCatalog, cached);
    final pending = [source.catalogUrl(detailUrl)];
    final visited = <String>{}, chapterKeys = <String>{};
    final chapters = <ChapterLink>[];
    var warning = '';
    for (var i = 0; i < pending.length; i++) {
      if (i >= 100) {
        warning = '目录超过 100 页，当前显示已加载部分。';
        break;
      }
      final url = pending[i];
      if (!visited.add(urlKey(url))) continue;
      try {
        final markup = await fetch(source, url);
        final parsed = await compute(_parseCatalog, (source, markup, url));
        for (final chapter in parsed.$1) {
          if (chapterKeys.add(urlKey(chapter.url))) chapters.add(chapter);
        }
        for (final page in parsed.$2) {
          if (!pending.any((p) => urlKey(p) == urlKey(page))) pending.add(page);
        }
      } on Exception {
        if (chapters.isEmpty) rethrow;
        warning = '部分目录加载失败，可刷新重试。';
        break;
      }
    }
    if (chapters.isEmpty) throw const ReaderFailure('未解析到章节目录，书源可能暂时不可用。');
    final result = ReaderCatalog(chapters, warning: warning);
    await write(name, result.toJson());
    return result;
  }

  Future<ReaderChapter> chapter(
    SourceRule source,
    ChapterLink link,
    List<ChapterLink> catalog, {
    bool refresh = false,
  }) {
    final key = link.url;
    return _chapterRequests.putIfAbsent(key, () async {
      try {
        return await _chapter(source, link, catalog, refresh: refresh);
      } finally {
        _chapterRequests.remove(key);
      }
    });
  }

  Future<ReaderChapter> _chapter(
    SourceRule source,
    ChapterLink link,
    List<ChapterLink> catalog, {
    bool refresh = false,
  }) async {
    final name = 'chapter-${key(link.url)}';
    final cached = await read(name);
    if (!refresh && cached != null) return compute(_cachedChapter, cached);
    final paragraphs = <String>[];
    final visited = <String>{};
    var url = link.url, title = link.title;
    for (var i = 0; i < 20; i++) {
      if (!visited.add(urlKey(url))) {
        throw const ReaderFailure('正文分页链接循环，已停止加载。');
      }
      final markup = await fetch(source, url);
      final parsed = await compute(_parseChapter, (
        source,
        markup,
        ChapterLink(title, url),
        catalog,
      ));
      final part = parsed.$1;
      if (i == 0) title = part.title;
      paragraphs.addAll(part.paragraphs);
      final next = parsed.$2;
      if (next == null) break;
      if (i == 19) throw const ReaderFailure('章节分页超过上限，暂时无法显示完整正文。');
      url = next;
    }
    final result = await compute(
      _measureChapter,
      ReaderChapter(title, link.url, paragraphs),
    );
    await write(name, result.toJson());
    _scheduleTrim();
    return result;
  }

  void _scheduleTrim() {
    if (_cancel.isCancelled) return;
    _trimTimer?.cancel();
    _trimTimer = Timer(const Duration(seconds: 2), () {
      if (readingBusy) {
        _scheduleTrim();
      } else {
        unawaited(_trimCache().catchError((Object _) {}));
      }
    });
  }

  Future<void> _trimCache() async {
    final files = await directory
        .list()
        .where(
          (e) =>
              e is File &&
              e.path.contains('chapter-') &&
              e.path.endsWith('.json'),
        )
        .cast<File>()
        .toList();
    final stats = await Future.wait(
      files.map((f) async => (f, await f.stat())),
    );
    stats.sort((a, b) => a.$2.modified.compareTo(b.$2.modified));
    var bytes = stats.fold<int>(0, (sum, e) => sum + e.$2.size),
        count = stats.length;
    for (final item in stats) {
      if (count <= 150 && bytes <= 40 * 1024 * 1024) break;
      await item.$1.delete();
      bytes -= item.$2.size;
      count--;
    }
  }
}
