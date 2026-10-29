import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:html/dom.dart';
import 'package:html/parser.dart' as html;

import 'reader_selectors.dart';

typedef Rule = Map<String, dynamic>;

class ReaderFailure implements Exception {
  const ReaderFailure(this.message);
  final String message;
  @override
  String toString() => message;
}

class ReaderDomSnapshot {
  const ReaderDomSnapshot(this.url, this.state, this.markup);
  final String url, state, markup;

  bool matches(String requestUrl) =>
      urlKey(url) == urlKey(requestUrl) &&
      const ['interactive', 'complete'].contains(state);
}

ReaderDomSnapshot decodeReaderDomSnapshot(String raw) {
  dynamic value = jsonDecode(raw);
  // Android may JSON-quote the string returned by JSON.stringify a second time.
  if (value is String) value = jsonDecode(value);
  final data = value as Map;
  return ReaderDomSnapshot(
    data['url'] as String,
    data['state'] as String,
    data['html'] as String,
  );
}

class ChapterLink {
  const ChapterLink(this.title, this.url);
  final String title, url;
  Map<String, dynamic> toJson() => {'title': title, 'url': url};
  factory ChapterLink.fromJson(Map<String, dynamic> json) =>
      ChapterLink(json['title'] as String, json['url'] as String);
}

class ReaderCatalog {
  const ReaderCatalog(this.chapters, {this.warning = ''});
  final List<ChapterLink> chapters;
  final String warning;
  Map<String, dynamic> toJson() => {
    'chapters': chapters.map((c) => c.toJson()).toList(),
    'warning': warning,
  };
  factory ReaderCatalog.fromJson(Map<String, dynamic> json) => ReaderCatalog(
    (json['chapters'] as List)
        .map((c) => ChapterLink.fromJson(Map<String, dynamic>.from(c as Map)))
        .toList(),
    warning: json['warning'] as String? ?? '',
  );
}

class ReaderChapter {
  ReaderChapter(this.title, this.url, this.paragraphs);
  final String title, url;
  final List<String> paragraphs;
  String get text => paragraphs.join('\n\n');
  late final String hash = sha256.convert(utf8.encode(text)).toString();
  late final List<int> _scalarStarts = _measureScalars();
  List<int> _measureScalars() {
    final offsets = <int>[0];
    for (final paragraph in paragraphs) {
      offsets.add(offsets.last + paragraph.runes.length + 2);
    }
    return offsets;
  }

  int scalarStart(int paragraph) => _scalarStarts[paragraph];
  int get scalarLength => _scalarStarts.last;

  void prepareMetrics() {
    hash;
    scalarLength;
  }

  Map<String, dynamic> toJson() => {
    'title': title,
    'url': url,
    'paragraphs': paragraphs,
  };
  factory ReaderChapter.fromJson(Map<String, dynamic> json) => ReaderChapter(
    json['title'] as String,
    json['url'] as String,
    List<String>.from(json['paragraphs'] as List),
  );
}

class SourceRule {
  SourceRule(this.json);
  final Rule json;
  String get id => json['id'] as String;
  bool get dynamicPage => json['dynamic'] == true;
  Rule get catalog => Map<String, dynamic>.from(json['catalog'] as Map);
  Rule get chapter => Map<String, dynamic>.from(json['chapter'] as Map);
  String get contentSelector =>
      chapter['contentSelector'] as String? ??
      '.chapter-content, .reading-content, .read-content, #chapter-content, #content, article';
  String catalogUrl(String detailUrl) {
    final template = catalog['uriTemplate'] as String? ?? '';
    if (template.isEmpty) return detailUrl;
    final pattern = (json['detail'] as Map)['bookUrlPattern'] as String?;
    final id = pattern == null
        ? null
        : RegExp(pattern, caseSensitive: false).firstMatch(detailUrl)?.group(1);
    if (id == null) throw const ReaderFailure('无法识别书籍编号，请检查书籍链接。');
    return template.replaceAll('{bookId}', id);
  }
}

String urlKey(String value) =>
    Uri.parse(value)
        .removeFragment()
        .toString()
        .replaceFirst(RegExp(r'/+$'), '');

String? elementUrl(Element element, String base) {
  final raw = element.attributes['href'] ?? element.attributes['value'];
  if (raw == null || raw.trim().isEmpty) return null;
  final uri = Uri.tryParse(base)?.resolve(raw.trim());
  if (uri == null ||
      !['http', 'https'].contains(uri.scheme) ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty) {
    return null;
  }
  return uri.removeFragment().toString();
}

String _selector(Rule rule, String key) => (rule[key] as String? ?? '')
    .replaceAll('p[style=font-size:12px;]', 'p[style="font-size:12px;"]');
List<Element> select(Document document, String selector) =>
    readerSelect(document, selector);

/// Detect usable DOM rather than a class-name substring in scripts or CSS.
bool readerPageReady(SourceRule source, String markup, String url) {
  final document = html.parse(markup);
  final chapterPage = source.id == '18mh'
      ? Uri.parse(url).path.startsWith('/novel_chapter/')
      : select(document, _selector(source.catalog, 'itemSelector')).isEmpty;
  final selector = chapterPage
      ? source.contentSelector
      : _selector(source.catalog, 'itemSelector');
  return select(document, selector).any((n) => n.text.trim().isNotEmpty);
}

List<ChapterLink> parseCatalogPage(
  SourceRule source,
  String markup,
  String url,
) {
  final document = html.parse(markup);
  var nodes = select(document, _selector(source.catalog, 'itemSelector'));
  if (source.catalog['htmlTransform'] == 'WxsyVisibleItems') {
    final leading = RegExp(
      r'\.section-list\.ycxsid>li:nth-child\(\d+\)\{display:none\}',
      caseSensitive: false,
    ).allMatches(markup).length;
    final trailing = RegExp(
      r'\.section-list\.ycxsid>li:nth-last-child\(\d+\)\{display:none\}',
      caseSensitive: false,
    ).allMatches(markup).length;
    nodes = nodes
        .skip(leading)
        .take((nodes.length - leading - trailing).clamp(0, nodes.length))
        .toList();
  }
  if (source.catalog['isDescending'] == true) nodes = nodes.reversed.toList();
  String title(Element node) {
    if (source.id == 'yeshe') {
      final copy = node.clone(true);
      for (final label in copy.querySelectorAll('span')) {
        label.remove();
      }
      return copy.text.trim();
    }
    if (source.id != '18mh') return node.text.trim();
    final badge =
        node
            .querySelector('.detail-page__chapter-badge, .jm-dt-ch__no')
            ?.text
            .trim() ??
        '';
    final name =
        node
            .querySelector('.detail-page__chapter-title, .jm-dt-ch__t')
            ?.text
            .trim() ??
        '';
    if (name.isEmpty) return badge.isEmpty ? node.text.trim() : badge;
    return badge.isEmpty || name.startsWith(badge) ? name : '$badge $name';
  }

  return [
    for (final n in nodes)
      if (n.text.trim().isNotEmpty && elementUrl(n, url) != null)
        ChapterLink(title(n), elementUrl(n, url)!),
  ];
}

List<String> catalogPages(SourceRule source, String markup, String url) {
  final nodes = select(
    html.parse(markup),
    _selector(source.catalog, 'nextPageSelector'),
  );
  final options = nodes.where((n) => n.localName == 'option').toList();
  if (options.isNotEmpty) {
    return options
        .map((n) => elementUrl(n, url))
        .whereType<String>()
        .toSet()
        .toList();
  }
  final next = nodes
      .where(
        (n) =>
            RegExp(r'下一页|下页|next|[›»]', caseSensitive: false).hasMatch(n.text),
      )
      .firstOrNull;
  return next == null || elementUrl(next, url) == null
      ? []
      : [elementUrl(next, url)!];
}

final _encodedScript = RegExp(
  r'''<script[^>]*>\s*document\.write(?:ln)?\s*\(\s*qsbs\.bb\(\s*['"]([^'"]+)['"]\s*\)\s*\)\s*;?\s*</script>''',
  caseSensitive: false,
  dotAll: true,
);

ReaderChapter parseChapterPage(
  SourceRule source,
  String markup,
  ChapterLink link,
) {
  final document = html.parse(markup);
  final title = select(
    document,
    _selector(source.chapter, 'titleSelector'),
  ).firstOrNull?.text.trim();
  final selector = source.contentSelector;
  var nodes = select(document, selector);
  // Prefer the inner content container when dynamic pages nest wrappers.
  if (source.dynamicPage && nodes.isNotEmpty) {
    nodes = nodes.where((n) => n.querySelector(selector) == null).toList();
    nodes = [nodes.reduce((a, b) => a.text.length >= b.text.length ? a : b)];
  }
  if (nodes.isEmpty) throw const ReaderFailure('未找到章节正文，书源规则可能已变化。');
  var fragment = nodes
      .map((n) => '<section>${n.innerHtml}</section>')
      .join('\n');
  final transform = source.chapter['contentTransform'];
  String decode(Match match) =>
      utf8.decode(base64.decode(base64.normalize(match.group(1)!)));
  if (transform == 'DecodeBase64Payload') {
    final matches = _encodedScript.allMatches(fragment).toList();
    if (matches.isEmpty) throw const ReaderFailure('章节编码数据缺失，请重试。');
    fragment = matches.map(decode).join('\n');
  } else if (transform == 'DecodeEmbeddedBase64Scripts') {
    fragment = fragment.replaceAllMapped(_encodedScript, decode);
  }
  final body = html.parse(fragment);
  for (final node in select(
    body,
    [
      'script, style, noscript, iframe, nav, button, .advert, [hidden], [aria-hidden="true"]',
      _selector(source.chapter, 'removeSelectors'),
    ].where((s) => s.isNotEmpty).join(', '),
  ).toList()) {
    node.remove();
  }
  final buffer = StringBuffer();
  void visit(Node node) {
    if (node is Text) {
      buffer.write(node.data);
      return;
    }
    if (node is! Element) return;
    final style = node.attributes['style'] ?? '';
    if (RegExp(
      r'display\s*:\s*none|visibility\s*:\s*hidden',
      caseSensitive: false,
    ).hasMatch(style)) {
      return;
    }
    final block = const {
      'p',
      'div',
      'section',
      'article',
      'li',
      'dd',
      'dt',
      'blockquote',
      'pre',
      'h1',
      'h2',
      'h3',
    }.contains(node.localName);
    if (block || node.localName == 'br') buffer.write('\n');
    for (final child in node.nodes) {
      visit(child);
    }
    if (block) buffer.write('\n');
  }

  visit(body.body!);
  var text = buffer.toString().replaceAll('\r', '\n').replaceAll('\u00a0', ' ');
  final filter = source.chapter['filterTextPattern'] as String? ?? '';
  if (filter.isNotEmpty) {
    text = text.replaceAll(
      RegExp(filter, caseSensitive: false, dotAll: true),
      '',
    );
  }
  final paragraphs = text
      .split('\n')
      .map((s) => s.replaceAll(RegExp(r'[ \t]+'), ' ').trim())
      .where((s) => s.isNotEmpty)
      .toList();
  final heading = title?.isNotEmpty == true ? title! : link.title;
  if (paragraphs.isNotEmpty && paragraphs.first == heading) {
    paragraphs.removeAt(0);
  }
  if (paragraphs.isEmpty) throw const ReaderFailure('章节正文为空，请重试或检查书源。');
  return ReaderChapter(heading, link.url, paragraphs);
}

String? chapterContinuation(
  SourceRule source,
  String markup,
  String url,
  List<ChapterLink> catalog,
) {
  final node = select(
    html.parse(markup),
    _selector(source.chapter, 'nextPageSelector'),
  ).firstOrNull;
  if (node == null) return null;
  final next = elementUrl(node, url);
  if (next == null || catalog.any((c) => urlKey(c.url) == urlKey(next))) {
    return null;
  }
  if (RegExp(r'下一章|没有了|书末页|>>').hasMatch(node.text) &&
      !RegExp(r'[-_]\d+\.html').hasMatch(next)) {
    return null;
  }
  return next;
}
