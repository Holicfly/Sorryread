import 'dart:math' as math;
import 'dart:ui' as ui;

import '../../../data/imported_books.dart';
import '../../local_books/local_book_parser.dart';
import 'reader_source.dart';

class LocalReaderSource {
  const LocalReaderSource(this.store, this.book);

  final ImportedBooks store;
  final ImportedBook book;

  String _url(int index) => '$localBookUrl${book.hash}/$index';

  Future<ImportedBook> current() async {
    final saved = await store.book(book.hash);
    if (saved == null ||
        saved.epoch != book.epoch ||
        !saved.ready ||
        !await store.original(saved).exists()) {
      throw const ReaderFailure('本机原文件不可用，请在本地图书中重新导入或等待同步。');
    }
    return saved;
  }

  Future<ReaderCatalog> catalog() async {
    final saved = await current();
    final units = await store.catalog(saved.hash);
    if (units.length != saved.unitCount || units.isEmpty) {
      throw const ReaderFailure('本地图书目录尚未就绪。');
    }
    return ReaderCatalog([
      for (var i = 0; i < units.length; i++)
        ChapterLink(units[i].title, _url(i)),
    ]);
  }

  Map<String, dynamic>? positionFor(ImportedBook saved) {
    if (saved.hash != book.hash ||
        saved.epoch != book.epoch ||
        !saved.ready ||
        saved.position == null) {
      return null;
    }
    final index = saved.index;
    return <String, dynamic>{
      'chapterUrl': _url(index),
      'chapterIndex': index,
      'chapterCount': saved.unitCount,
      'bookProgressChapterUrl': _url(index),
      'progress': saved.progress,
    };
  }

  Future<Map<String, dynamic>?> position() async {
    final saved = await current();
    final position = positionFor(saved);
    if (position == null) return null;
    final anchor = await store.readerAnchor(saved.hash);
    return anchor != null &&
            anchor['chapterIndex'] == saved.index &&
            (saved.comic || anchor['progress'] == saved.progress)
        ? {...position, ...anchor}
        : position;
  }

  Future<ReaderChapter> chapter(ChapterLink link) async {
    final saved = await current();
    final index = int.tryParse(link.url.split('/').last);
    if (index == null ||
        index < 0 ||
        index >= saved.unitCount ||
        link.url != _url(index)) {
      throw const ReaderFailure('本地章节地址无效。');
    }
    final blocks = await store.blocks(saved.hash, index);
    final paths = blocks.map((block) => block.image).nonNulls.toSet().toList();
    final images = paths.isEmpty
        ? null
        : await readBookImages(store.original(saved).path, paths);
    final paragraphs = <String>[];
    final illustrations = <int, ReaderIllustration>{};
    final decoded = <String, ReaderIllustration>{};
    for (final block in blocks) {
      if (block.image == null) {
        paragraphs.addAll(
          block.text
              .split(RegExp(r'\n+'))
              .map((line) => line.trim())
              .where((line) => line.isNotEmpty),
        );
        continue;
      }
      final cached = decoded[block.image];
      if (cached != null) {
        illustrations[paragraphs.length] = cached;
        paragraphs.add('\uFFFC' * ReaderIllustration.anchorLength);
        continue;
      }
      final bytes = images?[block.image];
      ui.Codec? codec;
      try {
        if (bytes == null) throw const FormatException('图片资源缺失');
        final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
        codec = await ui.instantiateImageCodecWithSize(
          buffer,
          getTargetSize: (width, height) {
            final budget = math.max(160000, 3000000 ~/ paths.length);
            final scale = math.min(
              1.0,
              math.min(
                1500 / width,
                math.min(4600 / height, math.sqrt(budget / (width * height))),
              ),
            );
            return ui.TargetImageSize(
              width: math.max(1, (width * scale).round()),
              height: math.max(1, (height * scale).round()),
            );
          },
        );
        final frame = await codec.getNextFrame();
        illustrations[paragraphs.length] = decoded[block.image!] =
            ReaderIllustration(frame.image);
        paragraphs.add('\uFFFC' * ReaderIllustration.anchorLength);
      } catch (_) {
        paragraphs.add('〔图片无法读取〕');
      } finally {
        codec?.dispose();
      }
    }
    if (paragraphs.isEmpty) throw const ReaderFailure('本地章节没有可读内容。');
    return ReaderChapter(
      link.title,
      link.url,
      paragraphs,
      illustrations: illustrations,
      comic: saved.comic,
    )..prepareMetrics();
  }
}
