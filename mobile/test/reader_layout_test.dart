import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sorryread_mobile/features/reader/data/reader_source.dart';
import 'package:sorryread_mobile/features/reader/presentation/reader_layout.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('incremental layout preserves pages, chunks and indexed anchors', () async {
    final body = ReaderChapter('增量排版', 'https://example.invalid/incremental', [
      '段落😀，含英文 ABC 和标点。' * 300,
      '下一段正文。' * 60,
    ]);
    const style = TextStyle(fontSize: 22, height: 1.8);
    final eager = ReaderLayout(body, 342, 680, style, TextScaler.noScaling);
    addTearDown(eager.dispose);
    var yields = 0;
    final prepared = await ReaderLayout.prepare(
      body,
      342,
      680,
      style,
      TextScaler.noScaling,
      cancelled: () => false,
      yieldWork: () async {
        yields++;
      },
    );
    expect(prepared, isNotNull);
    addTearDown(prepared!.dispose);
    expect(yields, greaterThan(0));
    expect(prepared.scrollHeight, eager.scrollHeight);
    expect(prepared.pageCount, eager.pages.length);
    expect(prepared.pages.length, eager.pages.length);
    for (var i = 0; i < prepared.pageCount; i++) {
      final anchor = prepared.anchorForPage(i);
      expect(anchor.paragraph, eager.pages[i].anchor.paragraph);
      expect(anchor.offset, eager.pages[i].anchor.offset);
    }
    // Compare binary lookup with the rendered block/line geometry, including
    // exact boundaries and paragraph spacing, rather than elapsed-time guesses.
    var top = 0.0;
    for (final block in prepared.blocks) {
      if (block.paragraph >= 0) {
        for (var line = 0; line < block.lines.length; line++) {
          final anchor = prepared.anchorForScroll(
            top + block.lineTop(line) + .01,
          );
          expect(anchor.paragraph, block.paragraph);
          expect(anchor.offset, block.lineOffset(line));
          if (anchor.paragraph != 0 || anchor.offset != 0) {
            expect(
              prepared.scrollFor(anchor),
              closeTo(top + block.lineTop(line), .01),
            );
          }
        }
      }
      top += block.height;
    }
  });

  test(
    'obsolete incremental layout can be cancelled between batches',
    () async {
      var cancelled = false;
      final prepared = await ReaderLayout.prepare(
        ReaderChapter('取消', 'https://example.invalid/cancel', [
          '长章节😀。' * 15000,
        ]),
        300,
        600,
        const TextStyle(fontSize: 22, height: 1.8),
        TextScaler.noScaling,
        cancelled: () => cancelled,
        yieldWork: () async {
          cancelled = true;
        },
      );
      expect(cancelled, isTrue);
      expect(prepared, isNull);
    },
  );
  test(
    '100k-character chapter and single long paragraph retain every line',
    () {
      final body = ReaderChapter('长章节', 'https://example.invalid/long', [
        '中文段落😀，' * 17000,
      ]);
      final layout = ReaderLayout(
        body,
        342,
        720,
        const TextStyle(fontSize: 22, height: 1.8),
        TextScaler.noScaling,
      );
      addTearDown(layout.dispose);
      final slices = layout.pages.expand((p) => p.slices).toList();
      expect(
        slices.fold<double>(0, (sum, s) => sum + s.bottom - s.top),
        closeTo(
          layout.blocks.fold<double>(0, (sum, b) => sum + b.painter.height),
          .01,
        ),
      );
      expect(layout.pages.length, greaterThan(100));
      final chunks = layout.blocks.where((b) => b.paragraph == 0).toList();
      expect(
        chunks.map((b) => b.painter.text!.toPlainText()).join().substring(2),
        body.paragraphs.single,
      );
      for (var i = 1; i < chunks.length; i++) {
        expect(chunks[i].startOffset, chunks[i - 1].endOffset);
        expect(chunks[i].indent, 0);
      }
    },
  );
  for (final fontSize in [14.0, 22.0, 36.0]) {
    test(
      'pagination covers every rendered line exactly once at $fontSize pt',
      () {
        final chapter = ReaderChapter('标题', 'https://example.invalid/1', [
          '这是第一段。' * 18,
          '长段落😀含有标点符号，继续阅读。' * 180,
          '最后一段。' * 8,
        ]);
        final layout = ReaderLayout(
          chapter,
          272,
          480,
          TextStyle(fontSize: fontSize, height: 1.8),
          TextScaler.noScaling,
        );
        addTearDown(layout.dispose);
        expect(layout.pages.length, greaterThan(2));
        for (final block in layout.blocks) {
          final slices = layout.pages
              .expand((p) => p.slices)
              .where((s) => s.block == block)
              .toList();
          expect(slices.first.top, 0);
          expect(slices.last.bottom, closeTo(block.painter.height, .01));
          for (var i = 1; i < slices.length; i++) {
            expect(slices[i].top, closeTo(slices[i - 1].bottom, .01));
          }
          for (final slice in slices) {
            expect(slice.y, greaterThanOrEqualTo(-.01));
            expect(
              slice.y + slice.bottom - slice.top,
              lessThanOrEqualTo(480.01),
            );
          }
        }
        for (var i = 1; i < layout.pages.length; i++) {
          final current = layout.pages[i].anchor,
              previous = layout.pages[i - 1].anchor;
          expect(
            current.paragraph > previous.paragraph ||
                (current.paragraph == previous.paragraph &&
                    current.offset >= previous.offset),
            isTrue,
          );
          expect(layout.pageFor(current), i);
        }
      },
    );
  }
  test(
    'font size and width changes restore the same paragraph and nearby line',
    () {
      final chapter = ReaderChapter(
        '标题',
        'https://example.invalid/1',
        List.generate(30, (i) => '第 $i 段：${'中文内容😀，继续阅读。' * 12}'),
      );
      final small = ReaderLayout(
        chapter,
        342,
        680,
        const TextStyle(fontSize: 22, height: 1.8),
        TextScaler.noScaling,
      );
      final large = ReaderLayout(
        chapter,
        272,
        470,
        const TextStyle(fontSize: 30, height: 1.8),
        TextScaler.noScaling,
      );
      addTearDown(small.dispose);
      addTearDown(large.dispose);
      final anchor = small.pages[8].anchor;
      final page = large.pages[large.pageFor(anchor)];
      expect(page.anchor.paragraph, lessThanOrEqualTo(anchor.paragraph));
      final y = large.scrollFor(anchor), restored = large.anchorForScroll(y);
      expect(restored.paragraph, anchor.paragraph);
      expect(restored.offset, lessThanOrEqualTo(anchor.offset));
    },
  );
}
