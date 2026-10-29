import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sorryread_mobile/features/reader/data/reader_fonts.dart';
import 'package:sorryread_mobile/features/reader/data/reader_source.dart';
import 'package:sorryread_mobile/features/reader/presentation/reader_layout.dart';
import 'package:sorryread_mobile/features/reader/presentation/reader_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('all five bundled fonts match pinned files and load offline', () async {
    final fonts = ReaderFonts();
    expect(readingFonts.map((f) => f.id), [
      'system',
      'song',
      'hei',
      'kai',
      'sourceHan',
      'wenkai',
    ]);
    final manifest = jsonDecode(
      await rootBundle.loadString('assets/fonts/manifest.json'),
    ) as List;
    expect(await fonts.load('system'), isNull);
    for (final font in readingFonts.where((f) => f.asset.isNotEmpty)) {
      final bytes = await rootBundle.load(font.asset);
      expect(
        sha256
            .convert(
              bytes.buffer.asUint8List(
                bytes.offsetInBytes,
                bytes.lengthInBytes,
              ),
            )
            .toString(),
        font.sha,
      );
      expect(
        manifest.singleWhere((e) => e['id'] == font.id)['sha256'],
        font.sha,
      );
      final family = await fonts.load(font.id);
      expect(family, isNotNull);
      expect(await fonts.load(font.id), family);
      final layout = ReaderLayout(
        ReaderChapter('第一章 山间来信', 'https://example.invalid/1', [
          '这是字号、行间距与中文标点的排版检查。😀 ${'阅读是一段安静的旅程。' * 30}',
        ]),
        342,
        680,
        TextStyle(fontSize: 22, height: 1.8, fontFamily: family),
        TextScaler.noScaling,
      );
      expect(layout.pages, isNotEmpty);
      expect(layout.blocks.last.painter.width, lessThanOrEqualTo(342));
      layout.dispose();
    }
    for (final removed in ['founderHei', 'founderKai', 'unknown']) {
      expect(ReaderPreferences.fromJson({'font': removed}).font, 'system');
    }
  });
}
